import Foundation

/// Port of the web `AbortController`.
public final class AbortController: Sendable {
    public let signal: AbortSignal

    public init() { signal = AbortSignal() }

    /// Abort with `reason` (default: an `AbortError`). Later calls are ignored.
    public func abort(_ reason: (any Error)? = nil) { signal.abort(reason) }
}

/// Port of the web `AbortSignal`.
///
/// Listeners run synchronously on the thread that calls `abort()`, in registration order, like
/// `addEventListener("abort", listener, { once: true })`.
public final class AbortSignal: Sendable {
    public typealias Listener = @Sendable () -> Void

    private struct State {
        var aborted = false
        var reason: (any Error)?
        var nextID = 0
        var listeners: [(id: Int, listener: Listener)] = []
    }

    private let state = Locked(State())

    init() {}

    /// A signal that is already aborted (`AbortSignal.abort(reason)`).
    public static func aborted(_ reason: (any Error)? = nil) -> AbortSignal {
        let signal = AbortSignal()
        signal.abort(reason)
        return signal
    }

    /// A signal that aborts after `ms` milliseconds with a `TimeoutError` (`AbortSignal.timeout(ms)`).
    public static func timeout(_ ms: Int) -> AbortSignal {
        let signal = AbortSignal()
        DispatchQueue.global().asyncAfter(deadline: .now() + .milliseconds(max(0, ms))) {
            signal.abort(PiError("The operation was aborted due to timeout", name: "TimeoutError"))
        }
        return signal
    }

    /// `AbortSignal.any(signals)`.
    public static func any(_ signals: [AbortSignal]) -> AbortSignal {
        let combined = AbortSignal()
        for signal in signals {
            if signal.aborted {
                combined.abort(signal.reason)
                return combined
            }
        }
        for signal in signals {
            signal.addEventListener { [weak combined] in combined?.abort(signal.reason) }
        }
        return combined
    }

    public var aborted: Bool { state.withLock { $0.aborted } }
    public var reason: (any Error)? { state.withLock { $0.reason } }

    /// Registers a one-shot listener. Returns a token for `removeEventListener`. Registering on an
    /// already-aborted signal does not call the listener (web semantics).
    @discardableResult
    public func addEventListener(_ listener: @escaping Listener) -> Int {
        state.withLock { s in
            s.nextID += 1
            if !s.aborted { s.listeners.append((s.nextID, listener)) }
            return s.nextID
        }
    }

    public func removeEventListener(_ id: Int) {
        state.withLock { s in s.listeners.removeAll { $0.id == id } }
    }

    /// `signal.throwIfAborted()`.
    public func throwIfAborted() throws {
        if let reason = state.withLock({ $0.aborted ? ($0.reason ?? AbortError()) : nil }) { throw reason }
    }

    fileprivate func abort(_ reason: (any Error)?) {
        let listeners: [Listener]? = state.withLock { s in
            guard !s.aborted else { return nil }
            s.aborted = true
            s.reason = reason ?? AbortError()
            let listeners = s.listeners.map(\.listener)
            s.listeners = []
            return listeners
        }
        listeners?.forEach { $0() }
    }
}

/// `DOMException("This operation was aborted", "AbortError")`.
public struct AbortError: Error, CustomStringConvertible, LocalizedError, Sendable {
    public var message: String
    public init(_ message: String = "This operation was aborted") { self.message = message }
    public var description: String { message }
    public var errorDescription: String? { message }
}

extension AbortSignal {
    /// Runs `operation` in a child task that is cancelled when this signal aborts. Bridges web-style
    /// abort signals to Swift cooperative cancellation (URLSession tasks, sleeps, tools).
    public func run<T: Sendable>(_ operation: @escaping @Sendable () async throws -> T) async throws -> T {
        try throwIfAborted()
        let task = Task { try await operation() }
        let id = addEventListener { task.cancel() }
        defer { removeEventListener(id) }
        if aborted { task.cancel() }
        return try await withTaskCancellationHandler {
            try await task.value
        } onCancel: {
            task.cancel()
        }
    }
}

// MARK: - utils/abort.ts

/// Create an operation-local signal for public APIs whose signal is optional.
public func operationSignal(_ signal: AbortSignal?) -> AbortSignal {
    signal ?? AbortController().signal
}

private func abortReason(_ signal: AbortSignal) -> any Error {
    signal.reason ?? PiError("The operation was aborted", name: "AbortError")
}

/// Stop waiting for an operation when its signal aborts while continuing to observe the abandoned operation.
public func raceWithAbortSignal<T: Sendable>(_ operation: @escaping @Sendable () async throws -> T, _ signal: AbortSignal) async throws -> T {
    if signal.aborted {
        Task { _ = try? await operation() }
        throw abortReason(signal)
    }
    return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<T, any Error>) in
        let settled = Locked(false)
        let settle: @Sendable (Result<T, any Error>) -> Bool = { result in
            let first = settled.withLock { s -> Bool in
                if s { return false }
                s = true
                return true
            }
            if first { continuation.resume(with: result) }
            return first
        }
        let id = signal.addEventListener { _ = settle(.failure(abortReason(signal))) }
        Task {
            let result: Result<T, any Error>
            do { result = .success(try await operation()) } catch { result = .failure(error) }
            signal.removeEventListener(id)
            _ = settle(result)
        }
        if signal.aborted { _ = settle(.failure(abortReason(signal))) }
    }
}

// MARK: - utils/abort-signals.ts

public struct CombinedAbortSignal: Sendable {
    public var signal: AbortSignal?
    public var cleanup: @Sendable () -> Void
}

public func combineAbortSignals(_ signals: [AbortSignal?]) -> CombinedAbortSignal {
    let active = signals.compactMap { $0 }
    if active.isEmpty { return CombinedAbortSignal(signal: nil, cleanup: {}) }
    if active.count == 1 { return CombinedAbortSignal(signal: active[0], cleanup: {}) }

    let controller = AbortController()
    var listeners: [(AbortSignal, Int)] = []
    let abort: @Sendable (AbortSignal) -> Void = { signal in
        if !controller.signal.aborted { controller.abort(signal.reason) }
    }
    for signal in active {
        if signal.aborted {
            abort(signal)
            break
        }
        listeners.append((signal, signal.addEventListener { abort(signal) }))
    }
    let registered = listeners
    return CombinedAbortSignal(signal: controller.signal, cleanup: {
        for (signal, id) in registered { signal.removeEventListener(id) }
    })
}

// MARK: - utils/sleep.ts

/// Abortable sleep. Throws the signal's reason when aborted.
public func sleep(_ ms: Int, _ signal: AbortSignal?) async throws {
    try signal?.throwIfAborted()
    guard ms > 0 else { return }
    try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
        let done = Locked(false)
        let finish: @Sendable (Result<Void, any Error>) -> Void = { result in
            let first = done.withLock { d -> Bool in
                if d { return false }
                d = true
                return true
            }
            if first { continuation.resume(with: result) }
        }
        let id = signal?.addEventListener { finish(.failure(signal?.reason ?? AbortError())) }
        DispatchQueue.global().asyncAfter(deadline: .now() + .milliseconds(ms)) {
            if let id { signal?.removeEventListener(id) }
            finish(.success(()))
        }
        if signal?.aborted == true { finish(.failure(signal?.reason ?? AbortError())) }
    }
}
