import Foundation
@testable import PiAI

// Shared helpers for the OAuth flow tests: the stand-ins for `vi.stubGlobal("fetch", ...)`,
// `vi.useFakeTimers()` / `vi.setSystemTime(...)` and `vi.stubEnv(...)`.

/// One recorded `fetch` call.
struct OAuthFetchCall: Sendable {
    var url: String
    var method: String
    var headers: Headers
    var body: String?
    var signal: AbortSignal?

    var json: JsonValue? { body.flatMap { try? JsonValue.parse($0) } }
    var form: URLSearchParams { URLSearchParams(body ?? "") }
}

/// A virtual clock plus a recording fake `fetch`. `sleep` advances virtual time at once (after the abort
/// check), so timer-driven flows run to completion without real waiting.
final class OAuthTestHarness: Sendable {
    typealias Handler = @Sendable (OAuthFetchCall) async throws -> FetchResponse

    private let time: Locked<Int>
    private let handler: Locked<Handler?>
    let calls = Locked<[OAuthFetchCall]>([])
    let sleeps = Locked<[Int]>([])
    let envValues: Locked<[String: String]>
    /// When set, `sleep` waits for a real abort instead of advancing time.
    let blockSleeps = Locked(false)

    init(now: Int = 1_773_014_400_000, env: [String: String] = [:], _ handler: Handler? = nil) {
        time = Locked(now)
        self.handler = Locked(handler)
        envValues = Locked(env)
    }

    var now: Int { time.current }
    func advance(_ ms: Int) { time.withLock { $0 += ms } }
    func setHandler(_ handler: @escaping Handler) { self.handler.withLock { $0 = handler } }
    var urls: [String] { calls.current.map(\.url) }

    var runtime: OAuthRuntime {
        OAuthRuntime(
            fetch: { [self] request in
                try request.signal?.throwIfAborted()
                let call = OAuthFetchCall(
                    url: request.url.absoluteString,
                    method: request.method,
                    headers: request.headers,
                    body: request.body.map { String(decoding: $0, as: UTF8.self) },
                    signal: request.signal
                )
                calls.withLock { $0.append(call) }
                guard let handler = handler.current else { throw PiError("Unexpected fetch: \(call.url)") }
                return try await handler(call)
            },
            now: { [self] in time.current },
            sleep: { [self] ms, signal in
                try signal?.throwIfAborted()
                sleeps.withLock { $0.append(ms) }
                if blockSleeps.current, let signal {
                    await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                        let id = signal.addEventListener { continuation.resume() }
                        if signal.aborted {
                            signal.removeEventListener(id)
                            continuation.resume()
                        }
                    }
                    try signal.throwIfAborted()
                }
                time.withLock { $0 += max(0, ms) }
                await Task.yield()
            },
            env: { [self] name in
                guard let value = envValues.current[name], !value.isEmpty else { return nil }
                return value
            }
        )
    }
}

func oauthJson(_ status: Int = 200, _ json: String, statusText: String = "", headers: [(String, String)] = [("content-type", "application/json")]) -> FetchResponse {
    FetchResponse(status: status, statusText: statusText, headers: Headers(headers), body: .data(Data(json.utf8)))
}

func oauthText(_ status: Int, _ text: String, statusText: String = "") -> FetchResponse {
    FetchResponse(status: status, statusText: statusText, headers: Headers([("content-type", "text/plain")]), body: .data(Data(text.utf8)))
}

/// Records prompts and events; answers prompts from `answer`.
final class OAuthTestInteraction: Sendable {
    let prompts = Locked<[AuthPrompt]>([])
    let events = Locked<[AuthEvent]>([])
    let controller: AbortController
    private let answer: @Sendable (AuthPrompt) async throws -> String

    init(controller: AbortController = AbortController(), _ answer: @escaping @Sendable (AuthPrompt) async throws -> String) {
        self.controller = controller
        self.answer = answer
    }

    var interaction: ProviderAuthInteraction {
        ProviderAuthInteraction(
            signal: controller.signal,
            prompt: { [self] prompt in
                prompts.withLock { $0.append(prompt) }
                return try await answer(prompt)
            },
            notify: { [self] event in events.withLock { $0.append(event) } }
        )
    }

    var authUrl: String? {
        for event in events.current { if case .auth_url(let url, _) = event { return url } }
        return nil
    }
}

/// A prompt answer that stays open until the prompt's signal aborts, then rejects.
@Sendable func oauthPendingPrompt(_ prompt: AuthPrompt) async throws -> String {
    guard let signal = prompt.signal else {
        try await Task.sleep(nanoseconds: 60_000_000_000)
        throw PiError("prompt aborted")
    }
    await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
        let fired = Locked(false)
        let resume: @Sendable () -> Void = {
            let first = fired.withLock { f -> Bool in
                if f { return false }
                f = true
                return true
            }
            if first { continuation.resume() }
        }
        _ = signal.addEventListener(resume)
        if signal.aborted { resume() }
    }
    throw PiError("prompt aborted")
}

/// GET a URL on a loopback callback server with the real `fetch`.
func oauthLoopbackGet(_ url: String, method: String = "GET") async throws -> (status: Int, contentType: String?, body: String) {
    let response = try await defaultFetch(FetchRequest(url: URL(string: url)!, method: method))
    return (response.status, response.headers.get("content-type"), try await response.text())
}

func oauthCallbackUrl(_ redirectUri: String, _ params: [(String, String)]) -> String {
    var search = WebURL(redirectUri)!.searchParams
    for (key, value) in params { search.set(key, value) }
    return WebURL(redirectUri)!.withSearch(search).href
}
