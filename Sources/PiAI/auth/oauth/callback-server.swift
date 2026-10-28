import Foundation

// Port of packages/ai/src/auth/oauth/callback-server.ts

/**
 * Loopback OAuth redirect handler shared by the browser sign-in flows.
 *
 * NOTE: Upstream uses node:http; the Swift port listens with Network.framework (`LoopbackHTTPServer`).
 */

public struct OAuthCallbackServerOptions<T: Sendable>: Sendable {
    /// Provider name used on the browser page, for example `OpenAI`.
    public var providerName: String
    /// Address to listen on.
    public var host: String
    /// Port to listen on; `0` picks a free port.
    public var port: Int
    public var path: String
    /// Host in `redirectUri` when it differs from `host`, for example `localhost`.
    public var redirectHost: String?
    /// Expected `state` parameter. Omit when the provider does not send one.
    public var state: String?
    public var expectedIssuer: String?
    public var requireIssuer: Bool
    /**
     * Finishes the sign-in with the received code before the browser page is sent, so the page can
     * show exchange failures. Pass `{ code in code }` to exchange the code later.
     */
    public var complete: @Sendable (String) async throws -> T
    public var signal: AbortSignal?
    public var timeoutMs: Int?

    public init(
        providerName: String,
        host: String,
        port: Int,
        path: String,
        redirectHost: String? = nil,
        state: String? = nil,
        expectedIssuer: String? = nil, requireIssuer: Bool = false,
        complete: @escaping @Sendable (String) async throws -> T,
        signal: AbortSignal? = nil,
        timeoutMs: Int? = nil
    ) {
        self.providerName = providerName; self.host = host; self.port = port; self.path = path
        self.redirectHost = redirectHost; self.state = state; self.complete = complete
        self.signal = signal; self.timeoutMs = timeoutMs
        self.expectedIssuer = expectedIssuer; self.requireIssuer = requireIssuer
    }
}

public final class OAuthCallbackServer<T: Sendable>: Sendable {
    public let redirectUri: String
    private let waitImpl: @Sendable () async throws -> T?
    private let cancelImpl: @Sendable () -> Void
    private let closeImpl: @Sendable () -> Void

    init(redirectUri: String, wait: @escaping @Sendable () async throws -> T?, cancel: @escaping @Sendable () -> Void, close: @escaping @Sendable () -> Void) {
        self.redirectUri = redirectUri; self.waitImpl = wait; self.cancelImpl = cancel; self.closeImpl = close
    }

    /**
     * Resolves with the result of `complete`, or `nil` after `cancel()`. Rejects when the provider
     * redirects with an error, `complete` fails, the signal aborts, or the timeout elapses.
     */
    public func wait() async throws -> T? { try await waitImpl() }
    /// Stop waiting for the browser unless a callback is already being completed.
    public func cancel() { cancelImpl() }
    public func close() { closeImpl() }
}

private struct CallbackServerState {
    var claimed = false
    var settled = false
    var timer: DispatchWorkItem?
    var abortListener: Int?
}

private func sendPage(_ status: Int, _ html: String) -> LoopbackHTTPResponse {
    LoopbackHTTPResponse(status: status, headers: [("content-type", "text/html; charset=utf-8"), ("cache-control", "no-store")], body: html)
}

public func startOAuthCallbackServer<T: Sendable>(
    _ options: OAuthCallbackServerOptions<T>
) async throws -> OAuthCallbackServer<T> {
    let providerName = options.providerName
    let signal = options.signal
    if signal?.aborted == true { throw PiError("Login cancelled") }

    // A cancelled or closed wait may never be observed.
    let waitPromise = PendingResult<T?>()

    let state = Locked(CallbackServerState())
    let finish: @Sendable (Result<T?, any Error>) -> Void = { result in
        let cleanup: (DispatchWorkItem?, Int?)? = state.withLock { s in
            if s.settled { return nil }
            s.settled = true
            return (s.timer, s.abortListener)
        }
        guard let (timer, abortListener) = cleanup else { return }
        timer?.cancel()
        if let abortListener { signal?.removeEventListener(abortListener) }
        waitPromise.settle(result)
    }
    let onAbort: @Sendable () -> Void = { finish(.failure(PiError("Login cancelled"))) }

    let server = try await LoopbackHTTPServer.listen(host: options.host, port: options.port) { request in
        guard let url = WebURL("http://localhost" + (request.url.hasPrefix("/") ? request.url : "/" + request.url)) else {
            return sendPage(404, oauthErrorHtml("Callback route not found."))
        }
        let params = url.searchParams
        if request.method != "GET" || url.pathname != options.path {
            return sendPage(404, oauthErrorHtml("Callback route not found."))
        }
        if options.state != nil && params.get("state") != options.state {
            return sendPage(400, oauthErrorHtml("State mismatch."))
        }
        if let expected = options.expectedIssuer {
            if let issuer = params.get("iss"), issuer != expected { return sendPage(400, oauthErrorHtml("Issuer mismatch.")) }
            if options.requireIssuer && params.get("iss") == nil { return sendPage(400, oauthErrorHtml("Missing issuer.")) }
        }
        if state.withLock({ $0.claimed || $0.settled }) {
            return sendPage(409, oauthErrorHtml("This sign-in has already been handled."))
        }
        if let error = params.get("error"), !error.isEmpty {
            let description = params.get("error_description") ?? error
            let page = sendPage(400, oauthErrorHtml("\(providerName) authorization failed.", description))
            finish(.failure(PiError("\(providerName) authorization failed: \(description)")))
            return page
        }
        guard let code = params.get("code"), !code.isEmpty else {
            return sendPage(400, oauthErrorHtml("Missing authorization code."))
        }
        // Re-check under the lock: requests run concurrently here, unlike Node's single thread.
        let alreadyClaimed = state.withLock { s -> Bool in
            if s.claimed || s.settled { return true }
            s.claimed = true
            return false
        }
        if alreadyClaimed {
            return sendPage(409, oauthErrorHtml("This sign-in has already been handled."))
        }
        do {
            let value = try await options.complete(code)
            let page = sendPage(200, oauthSuccessHtml("Signed in to \(providerName). You may now close this page."))
            finish(.success(value))
            return page
        } catch {
            let page = sendPage(502, oauthErrorHtml("\(providerName) sign-in failed.", errorMessage(error)))
            finish(.failure(error))
            return page
        }
    }

    server.onError { error in finish(.failure(error)) }
    if let signal {
        let id = signal.addEventListener(onAbort)
        state.withLock { $0.abortListener = id }
        if signal.aborted { onAbort() }
    }
    if let timeoutMs = options.timeoutMs {
        let timer = DispatchWorkItem { finish(.failure(PiError("\(providerName) sign-in timed out"))) }
        state.withLock { $0.timer = timer }
        DispatchQueue.global().asyncAfter(deadline: .now() + .milliseconds(max(0, timeoutMs)), execute: timer)
    }
    let redirectHost = options.redirectHost ?? options.host
    return OAuthCallbackServer(
        redirectUri: "http://\(redirectHost.contains(":") ? "[\(redirectHost)]" : redirectHost):\(server.port)\(options.path)",
        wait: { try await waitPromise.value() },
        cancel: {
            if !state.withLock({ $0.claimed }) { finish(.success(nil)) }
        },
        close: {
            finish(.failure(PiError("OAuth callback server closed")))
            server.close()
        }
    )
}

/// Result of `waitForCallbackOrManualInput`.
public enum OAuthCallbackOrManualInput<T: Sendable>: Sendable {
    case callback(value: T)
    case manual(input: String)

    /// "callback" | "manual"
    public var type: String {
        switch self {
        case .callback: return "callback"
        case .manual: return "manual"
        }
    }
}

/**
 * Wait for the browser callback, or for the user to paste the code or redirect URL when the browser
 * cannot reach the loopback server (for example over SSH). Without a callback server only the manual
 * prompt is used.
 */
public func waitForCallbackOrManualInput<T: Sendable>(
    _ interaction: ProviderAuthInteraction,
    _ callback: OAuthCallbackServer<T>?,
    message: String,
    placeholder: String
) async throws -> OAuthCallbackOrManualInput<T> {
    let manualAbort = AbortController()
    let manualError = Locked<(any Error)?>(nil)
    let manual = Task { () -> String? in
        do {
            let input = try await interaction.prompt(AuthPrompt(.manual_code(message: message, placeholder: placeholder), signal: manualAbort.signal))
            callback?.cancel()
            return input
        } catch {
            manualError.withLock { $0 = error }
            callback?.cancel()
            return nil
        }
    }
    defer { manualAbort.abort() }
    let value = try await callback?.wait()
    if let error = manualError.current { throw error }
    if let value { return .callback(value: value) }
    let input = await manual.value
    if let error = manualError.current { throw error }
    return .manual(input: input ?? "")
}
