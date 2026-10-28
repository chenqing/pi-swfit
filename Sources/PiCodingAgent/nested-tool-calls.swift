// Port of core/nested-tool-calls.ts @ 42cb822f1c5d3153069dd0661bfd297424666cf1.
import Foundation
import PiAI
import PiAgent

final class NestedCallRecorder: Sendable {
    struct State { var calls: [NestedToolCallRecord] = []; var bytes = 0; var complete = true; var usage: Usage? }
    private let state = Locked(State())
    func start(_ call: ToolCall) -> Int? {
        state.withLock { state in
            guard state.calls.count < 256 else { state.complete = false; return nil }
            let bytes = JsonValue.object(call.arguments).serialized().utf8.count
            let include = bytes <= 8192 && state.bytes + bytes <= 32768
            if include { state.bytes += bytes } else { state.complete = false }
            state.calls.append(.init(id: call.id, name: call.name, arguments: include ? call.arguments : nil,
                                     argumentsBytes: include ? nil : bytes, status: "unfinished"))
            return state.calls.count - 1
        }
    }
    func finish(_ index: Int?, _ outcome: AgentToolCallOutcome, elapsed: Int) {
        state.withLock { state in
            if let usage = outcome.result.usage { state.usage = state.usage.map { combineUsage($0, usage) } ?? usage }
            guard let index else { return }
            state.calls[index].status = outcome.isError ? "error" : "ok"
            state.calls[index].durationMs = elapsed
            if outcome.isError {
                let text = outcome.result.content.compactMap { if case .text(let block) = $0 { block.text } else { nil } }.joined(separator: "\n")
                state.calls[index].error = String(text.prefix(500))
            }
        }
    }
    func snapshot() -> (NestedToolCalls?, Usage?) {
        state.withLock { state in
            (state.calls.isEmpty && state.complete ? nil : .init(calls: state.calls, complete: state.complete && state.calls.allSatisfy { $0.status != "unfinished" }), state.usage)
        }
    }
}

final class NestedToolCallRunner: Sendable {
    struct Scope: Sendable {
        let recorder: NestedCallRecorder
        let signal: AbortSignal?
        var controller: AbortController? = nil
        var next = 1
        var holdsQueue = false
        var depth = 0
    }
    struct State {
        var scopes: [String: Scope] = [:]
        var finished: [String: NestedCallRecorder] = [:]
        var tail: Task<Void, Never>?
    }
    private let state = Locked(State())
    func withScope(_ id: String, signal: AbortSignal?, operation: @Sendable () async throws -> AgentToolResult) async throws -> AgentToolResult {
        let controller = AbortController()
        let combined = combineAbortSignals([signal, controller.signal])
        defer { combined.cleanup() }
        let root = state.withLock { state in
            guard state.scopes[id] == nil else { return false }
            state.scopes[id] = .init(recorder: NestedCallRecorder(), signal: combined.signal, controller: controller); return true
        }
        defer {
            if root {
                controller.abort()
                state.withLock { state in
                    if let scope = state.scopes.removeValue(forKey: id) {
                        if state.finished.count >= 256 { state.finished.removeAll() }
                        state.finished[id] = scope.recorder
                    }
                }
            }
        }
        return try await operation()
    }
    func execute(parent: String, name: String, args: JsonObject, signal: AbortSignal?, sequential: Bool,
                 run: @escaping @Sendable (ToolCall, AbortSignal?, ToolUpdateSink?) async throws -> AgentToolCallOutcome,
                 emit: @escaping @Sendable (AgentEvent, String) async -> Void) async throws -> AgentToolCallOutcome {
        let (id, scope) = try state.withLock { state -> (String, Scope) in
            guard var scope = state.scopes[parent], scope.depth < 32 else { throw PiError("Nested tool caller is inactive or nesting is too deep") }
            let id = parent + "/" + String(scope.next); scope.next += 1; state.scopes[parent] = scope
            return (id, scope)
        }
        let call = ToolCall(id: id, name: name, arguments: args)
        let index = scope.recorder.start(call), began = ContinuousClock.now
        let combined = combineAbortSignals([signal, scope.signal]); defer { combined.cleanup() }
        await emit(.toolExecutionStart(toolCallId: id, toolName: name, args: args), parent)
        let exclusive = sequential && !scope.holdsQueue
        let release = AsyncRelease()
        let previous: Task<Void, Never>? = exclusive ? state.withLock { state in
            let previous = state.tail
            state.tail = Task { await previous?.value; await release.wait() }
            return previous
        } : nil
        if let previous {
            let ready = AsyncRelease()
            Task { await previous.value; ready.finish() }
            let token = combined.signal?.addEventListener { ready.finish() }
            if combined.signal?.aborted == true { ready.finish() }
            await ready.wait()
            if let token { combined.signal?.removeEventListener(token) }
        }
        state.withLock { $0.scopes[id] = .init(recorder: scope.recorder, signal: combined.signal, holdsQueue: scope.holdsQueue || exclusive, depth: scope.depth + 1) }
        let outcome: AgentToolCallOutcome
        do {
            try combined.signal?.throwIfAborted()
            outcome = try await run(call, combined.signal) { partial in
                await emit(.toolExecutionUpdate(toolCallId: id, toolName: name, args: args, partialResult: partial), parent)
            }
        } catch { outcome = .init(toolCall: call, result: .init(content: [.text(.init(text: errorMessage(error)))], isError: true), isError: true) }
        state.withLock { $0.scopes[id] = nil }; release.finish()
        let duration = began.duration(to: .now).components
        let ms = Int(duration.seconds * 1000 + duration.attoseconds / 1_000_000_000_000_000)
        scope.recorder.finish(index, outcome, elapsed: ms)
        await emit(.toolExecutionEnd(toolCallId: id, toolName: name, result: outcome.result, isError: outcome.isError, durationMs: outcome.durationMs), parent)
        return outcome
    }
    func takeRecord(_ id: String) -> (NestedToolCalls?, Usage?) {
        state.withLock { $0.finished.removeValue(forKey: id) }?.snapshot() ?? (nil, nil)
    }
    func clear() {
        let controllers = state.withLock { state in
            let controllers = state.scopes.values.compactMap(\.controller)
            state.scopes.removeAll(); state.finished.removeAll(); return controllers
        }
        controllers.forEach { $0.abort() }
    }
}

private final class AsyncRelease: Sendable {
    private struct State { var done = false; var waiting: [CheckedContinuation<Void, Never>] = [] }
    private let state = Locked(State())
    func wait() async {
        await withCheckedContinuation { continuation in
            let done = state.withLock { state in if state.done { return true }; state.waiting.append(continuation); return false }
            if done { continuation.resume() }
        }
    }
    func finish() {
        let waiting = state.withLock { state in state.done = true; let waiting = state.waiting; state.waiting = []; return waiting }
        waiting.forEach { $0.resume() }
    }
}
