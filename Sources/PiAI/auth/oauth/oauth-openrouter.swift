import Foundation

// Port of packages/ai/src/auth/oauth/openrouter.ts
// (named `oauth-openrouter.swift`: SwiftPM forbids two `openrouter.swift` in one target)

/**
 * OpenRouter OAuth PKCE flow.
 *
 * OpenRouter exchanges an authorization code for a permanent, user-controlled
 * API key rather than an expiring access/refresh token pair. The callback is
 * handled by a one-shot loopback server on an ephemeral port, raced against a
 * manual prompt so remote/headless sessions can paste the redirect URL when
 * the browser cannot reach the loopback server.
 *
 * NOTE: This module runs a loopback HTTP server (via callback-server.swift) for the OAuth callback.
 * It is only intended for CLI/app use, not browser environments.
 */

private let AUTHORIZE_URL = "https://openrouter.ai/auth"
private let TOKEN_URL = "https://openrouter.ai/api/v1/auth/keys"
private let LOGIN_TIMEOUT_MS = 5 * 60 * 1000
private let TOKEN_EXCHANGE_TIMEOUT_MS = 30_000

private func getCallbackHost(_ rt: OAuthRuntime) -> String {
    rt.env("PI_OAUTH_CALLBACK_HOST") ?? "127.0.0.1"
}

private func parseAuthorizationInput(_ input: String) -> String? {
    let value = input.trimmingCharacters(in: .whitespacesAndNewlines)
    if value.isEmpty { return nil }

    if let url = WebURL(value) {
        return url.searchParams.get("code")
    }
    // not a URL

    if value.contains("code=") {
        return URLSearchParams(value).get("code")
    }

    return value
}

private func errorDetail(_ body: JsonObject) -> String? {
    if case .string(let value)? = body["error_description"] { return value }
    if case .string(let value)? = body["message"] { return value }
    if case .string(let value)? = body["error"] { return value }
    if case .object(let error)? = body["error"] {
        if case .string(let message)? = error["message"] { return message }
    }
    return nil
}

private func exchangeAuthorizationCode(
    _ rt: OAuthRuntime,
    _ code: String,
    _ verifier: String,
    _ signal: AbortSignal
) async throws -> OAuthCredential {
    if signal.aborted { throw PiError("Login cancelled") }
    let controller = AbortController()
    let onAbort = signal.addEventListener { controller.abort(signal.reason) }
    let timeout = DispatchWorkItem { controller.abort(PiError("OpenRouter OAuth token exchange timed out")) }
    DispatchQueue.global().asyncAfter(deadline: .now() + .milliseconds(TOKEN_EXCHANGE_TIMEOUT_MS), execute: timeout)

    let response: FetchResponse
    var body: JsonObject = [:]
    do {
        defer {
            timeout.cancel()
            signal.removeEventListener(onAbort)
        }
        do {
            response = try await rt.fetch(
                TOKEN_URL,
                method: "POST",
                headers: [("accept", "application/json"), ("content-type", "application/json")],
                body: JsonValue.object([
                    "code": .string(code),
                    "code_verifier": .string(verifier),
                    "code_challenge_method": "S256",
                ]).serialized(),
                signal: controller.signal
            )
            do {
                let parsed = try await response.json()
                if case .object(let object) = parsed { body = object }
            } catch {
                if response.ok { throw PiError("OpenRouter OAuth returned invalid JSON") }
            }
        } catch {
            if signal.aborted { throw PiError("Login cancelled") }
            if controller.signal.aborted { throw PiError("OpenRouter OAuth token exchange timed out") }
            throw error
        }
    }

    if !response.ok {
        let detail = errorDetail(body)
        throw PiError("OpenRouter OAuth key exchange failed (HTTP \(response.status))\(detail.map { $0.isEmpty ? "" : ": \($0)" } ?? "")")
    }

    guard case .string(let key)? = body["key"], !key.isEmpty else {
        throw PiError("OpenRouter OAuth response carries no \"key\"")
    }

    return OAuthCredential(
        refresh: "",
        access: key,
        expires: 9_007_199_254_740_991
    )
}

private func loginOpenRouter(_ rt: OAuthRuntime, _ interaction: ProviderAuthInteraction) async throws -> OAuthCredential {
    let (verifier, challenge) = await generatePKCE()
    // OpenRouter sends no `state`; the random path keeps stray requests from completing the sign-in.
    let callback = try await startOAuthCallbackServer(OAuthCallbackServerOptions<OAuthCredential>(
        providerName: "OpenRouter",
        host: getCallbackHost(rt),
        port: 0,
        path: "/oauth/callback/\(UUID().uuidString.lowercased())",
        complete: { code in try await exchangeAuthorizationCode(rt, code, verifier, interaction.signal) },
        signal: interaction.signal,
        timeoutMs: LOGIN_TIMEOUT_MS
    ))

    defer { callback.close() }
    let authorizeUrl = WebURL(AUTHORIZE_URL)!.withSearch(URLSearchParams([
        ("callback_url", callback.redirectUri),
        ("code_challenge", challenge),
        ("code_challenge_method", "S256"),
    ]))

    interaction.notify(.progress(message: "Listening for OpenRouter OAuth callback on \(callback.redirectUri)"))
    interaction.notify(.auth_url(
        url: authorizeUrl.href,
        instructions:
            "Complete sign-in in your browser. If the browser is on another machine, paste the final redirect URL here."
    ))

    let result = try await waitForCallbackOrManualInput(
        interaction,
        callback,
        message: "Complete sign-in in your browser, or paste the authorization code / redirect URL here:",
        placeholder: callback.redirectUri
    )
    switch result {
    case .callback(let value):
        return value
    case .manual(let input):
        guard let code = parseAuthorizationInput(input), !code.isEmpty else { throw PiError("Missing authorization code") }
        interaction.notify(.progress(message: "Exchanging authorization code for an API key..."))
        return try await exchangeAuthorizationCode(rt, code, verifier, interaction.signal)
    }
}

func createOpenRouterOAuth(_ rt: OAuthRuntime = .live) -> OAuthAuth {
    OAuthAuth(
        name: "OpenRouter OAuth",
        loginLabel: "Sign in with OpenRouter",
        login: { interaction, _ in try await loginOpenRouter(rt, interaction) },
        refresh: { credential, _ in credential },
        toAuth: { credential in
            ModelAuth(apiKey: credential.access)
        }
    )
}

public let openRouterOAuth: OAuthAuth = createOpenRouterOAuth()
