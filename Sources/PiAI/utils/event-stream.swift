import Foundation

/// Port of `EventStream<T, R>` (utils/event-stream.ts).
///
/// A single-producer FIFO that consumers drain with `for await`. `push` after completion is
/// ignored; `end()` wakes every waiting consumer. `result()` resolves with the value extracted
/// from the completing event, or the value passed to `end(_:)`.
///
/// Difference from upstream: if the stream ends without ever producing a result, upstream's
/// `result()` promise never settles. Here waiters of `result()` are resumed with `nil` from
/// `resultIfAny()`; `result()` itself keeps upstream's contract for producers that always
/// complete (every provider does).
public class EventStream<T: Sendable, R: Sendable>: AsyncSequence, @unchecked Sendable {
    public typealias Element = T

    private struct State {
        var queue: [T] = []
        var head = 0
        var waiting: [CheckedContinuation<T?, Never>] = []
        var done = false
        var finalResult: R?
        var resultWaiters: [CheckedContinuation<R?, Never>] = []
    }

    private let state = Locked(State())
    private let isComplete: @Sendable (T) -> Bool
    private let extractResult: @Sendable (T) -> R

    public init(isComplete: @escaping @Sendable (T) -> Bool, extractResult: @escaping @Sendable (T) -> R) {
        self.isComplete = isComplete
        self.extractResult = extractResult
    }

    /// True once a completing event was pushed or `end()` was called.
    public var done: Bool { state.withLock { $0.done } }

    public func push(_ event: T) {
        let completes = isComplete(event)
        let result = completes ? extractResult(event) : nil
        let (waiter, resultWaiters): (CheckedContinuation<T?, Never>?, [CheckedContinuation<R?, Never>]) = state.withLock { s in
            if s.done { return (nil, []) }
            var resultWaiters: [CheckedContinuation<R?, Never>] = []
            if completes {
                s.done = true
                s.finalResult = result
                resultWaiters = s.resultWaiters
                s.resultWaiters = []
            }
            // Deliver to a waiting consumer or queue it
            if !s.waiting.isEmpty {
                return (s.waiting.removeFirst(), resultWaiters)
            }
            s.queue.append(event)
            return (nil, resultWaiters)
        }
        for w in resultWaiters { w.resume(returning: result) }
        waiter?.resume(returning: event)
    }

    public func end(_ result: R? = nil) {
        let (waiting, resultWaiters, value): ([CheckedContinuation<T?, Never>], [CheckedContinuation<R?, Never>], R?) = state.withLock { s in
            s.done = true
            // A promise resolves once: a result from a completing event wins over end(result).
            if let result, s.finalResult == nil { s.finalResult = result }
            let waiting = s.waiting
            s.waiting = []
            let resultWaiters = s.resultWaiters
            s.resultWaiters = []
            return (waiting, resultWaiters, s.finalResult)
        }
        // Notify all waiting consumers that we're done
        for w in waiting { w.resume(returning: nil) }
        for w in resultWaiters { w.resume(returning: value) }
    }

    /// Next event, or nil once the stream is done and drained.
    fileprivate func next() async -> T? {
        // Fast path: queued event or finished stream
        let poll: EventStreamPoll<T> = state.withLock { s in
            if s.head < s.queue.count {
                let event = s.queue[s.head]
                s.head += 1
                if s.head > 64 && s.head * 2 > s.queue.count {
                    s.queue.removeFirst(s.head)
                    s.head = 0
                }
                return .event(event)
            }
            return s.done ? .finished : .wait
        }
        switch poll {
        case .event(let event): return event
        case .finished: return nil
        case .wait:
            return await withCheckedContinuation { (continuation: CheckedContinuation<T?, Never>) in
                let immediate: T?? = state.withLock { s in
                    // Re-check under the lock: the producer may have pushed or ended meanwhile.
                    if s.head < s.queue.count {
                        let event = s.queue[s.head]
                        s.head += 1
                        return .some(event)
                    }
                    if s.done { return .some(nil) }
                    s.waiting.append(continuation)
                    return .none
                }
                if let immediate { continuation.resume(returning: immediate) }
            }
        }
    }

    /// Final result. Suspends until the stream completes.
    public func result() async -> R {
        // Upstream contract: every producer completes with a result.
        if let value = await resultIfAny() { return value }
        fatalError("EventStream ended without a result")
    }

    /// Final result, or nil if the stream ended without one.
    public func resultIfAny() async -> R? {
        if let value = state.withLock({ s -> R?? in s.done ? .some(s.finalResult) : .none }) { return value }
        return await withCheckedContinuation { (continuation: CheckedContinuation<R?, Never>) in
            let immediate: R?? = state.withLock { s in
                if s.done { return .some(s.finalResult) }
                s.resultWaiters.append(continuation)
                return .none
            }
            if let immediate { continuation.resume(returning: immediate) }
        }
    }

    public struct AsyncIterator: AsyncIteratorProtocol {
        let stream: EventStream<T, R>
        public mutating func next() async -> T? { await stream.next() }
    }

    public func makeAsyncIterator() -> AsyncIterator { AsyncIterator(stream: self) }
}

private enum EventStreamPoll<T> { case event(T), finished, wait }

/// Event stream of one assistant response. It also times the response: the final message (`done` or `error` event, or
/// the result passed to `end()`) gets `durationMs`, measured with a monotonic clock from the stream's creation, unless
/// the message already has one or its `timestamp` predates the stream. A stream that forwards a response which started
/// elsewhere, such as a deferred result fetched later, therefore leaves it untimed.
public final class AssistantMessageEventStream: EventStream<AssistantMessageEvent, AssistantMessage>, @unchecked Sendable {
    private let startedAt = dateNow()
    private let startedAtMonotonic = performanceNow()

    public init() {
        super.init(
            isComplete: { event in
                if case .done = event { return true }
                if case .error = event { return true }
                return false
            },
            extractResult: { event in
                switch event {
                case .done(_, let message): return message
                case .error(_, let error): return error
                default: fatalError("Unexpected event type for final result")
                }
            }
        )
    }

    public override func push(_ event: AssistantMessageEvent) {
        switch event {
        case .done(let reason, var message):
            time(&message)
            super.push(.done(reason: reason, message: message))
        case .error(let reason, var error):
            time(&error)
            super.push(.error(reason: reason, error: error))
        default:
            super.push(event)
        }
    }

    public override func end(_ result: AssistantMessage? = nil) {
        if var result {
            time(&result)
            super.end(result)
        } else {
            super.end(nil)
        }
    }

    private func time(_ message: inout AssistantMessage) {
        if done || message.durationMs != nil || message.timestamp < startedAt { return }
        message.durationMs = Swift.max(0, Int((performanceNow() - startedAtMonotonic).rounded()))
    }
}

/// Factory function for AssistantMessageEventStream (for use in extensions)
public func createAssistantMessageEventStream() -> AssistantMessageEventStream {
    AssistantMessageEventStream()
}
