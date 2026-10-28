import Foundation
@testable import PiAI

// Shared helpers for group G's ported tests (vitest `vi.waitFor`, deferred promises, `toMatchObject`).

/// A one-shot latch: the equivalent of `new Promise((resolve) => { open = resolve })`.
final class GGate: Sendable {
    private let state = Locked<(open: Bool, waiters: [CheckedContinuation<Void, Never>])>((false, []))
    init() {}
    func open() {
        let waiters = state.withLock { s -> [CheckedContinuation<Void, Never>] in
            s.open = true
            defer { s.waiters = [] }
            return s.waiters
        }
        waiters.forEach { $0.resume() }
    }
    func wait() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let resumeNow = state.withLock { s -> Bool in
                if s.open { return true }
                s.waiters.append(continuation)
                return false
            }
            if resumeNow { continuation.resume() }
        }
    }
}

/// `vi.waitFor`: retry `condition` until it holds or the timeout passes.
func gWaitFor(timeoutMs: Int = 2000, _ condition: @Sendable () async throws -> Bool) async rethrows -> Bool {
    let deadline = dateNow() + timeoutMs
    while dateNow() < deadline {
        if try await condition() { return true }
        try? await Task.sleep(nanoseconds: 5_000_000)
    }
    return try await condition()
}

/// Run `body` and return its thrown error, or nil when it did not throw.
func gCaught(_ body: () async throws -> Void) async -> (any Error)? {
    do {
        try await body()
        return nil
    } catch {
        return error
    }
}

func gIsAbortError(_ error: (any Error)?) -> Bool {
    if error is AbortError { return true }
    if let error = error as? PiError { return error.name == "AbortError" }
    return false
}

/// Render headers for order-sensitive comparison.
func gHeaders(_ headers: ProviderHeaders?) -> [String]? {
    headers?.map { "\($0.0)=\($0.1 ?? "<nil>")" }
}

func gOAuth(access: String, refresh: String, expires: Int, extra: JsonObject = JsonObject()) -> Credential {
    .oauth(OAuthCredentials(refresh: refresh, access: access, expires: expires, extra: extra))
}

func gApiKey(_ key: String?, env: ProviderEnv? = nil) -> Credential {
    .apiKey(ApiKeyCredential(key: key, env: env))
}

func gUserContext(_ text: String = "hi") -> Context {
    Context(messages: [.user(UserMessage(content: .string(text)))])
}

func gDoneMessage(_ model: Model, _ text: String) -> AssistantMessage {
    AssistantMessage(content: [.text(TextContent(text: text))], api: model.api, provider: model.provider, model: model.id, stopReason: .stop)
}

/// A provider stream that answers immediately with `start` and `done`.
func gRespond(_ model: Model, _ text: String = "ok") -> AssistantMessageEventStream {
    let stream = AssistantMessageEventStream()
    let message = gDoneMessage(model, text)
    stream.push(.start(partial: message))
    stream.push(.done(reason: .stop, message: message))
    stream.end(message)
    return stream
}

func gFetchResponse(status: Int, json: String, headers: [(String, String)] = [("content-type", "application/json")]) -> FetchResponse {
    FetchResponse(status: status, headers: Headers(headers), body: .data(Data(json.utf8)))
}
