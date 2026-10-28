import Foundation

// Port of packages/ai/src/auth/oauth/anthropic.ts
// (named `oauth-anthropic.swift`: SwiftPM forbids two `anthropic.swift` in one target)

/**
 * Anthropic OAuth flow (Claude Pro/Max)
 *
 * NOTE: This module runs a loopback HTTP server (`LoopbackHTTPServer`) for the OAuth callback.
 * It is only intended for CLI/app use, not browser environments.
 */

private func decode(_ value: String) -> String { String(decoding: Data(base64Encoded: value) ?? Data(), as: UTF8.self) }
private let CLIENT_ID = decode("OWQxYzI1MGEtZTYxYi00NGQ5LTg4ZWQtNTk0NGQxOTYyZjVl")
private let AUTHORIZE_URL = "https://claude.ai/oauth/authorize"
private let TOKEN_URL = "https://platform.claude.com/v1/oauth/token"
// `CALLBACK_HOST` is read from the environment when the flow is created (module load upstream); see `createAnthropicOAuth`.
// Preferred so the port can be forwarded into containers or over SSH. Anthropic accepts any loopback port,
// so login falls back to a free port when this one cannot be bound (#10571).
private let CALLBACK_PORT = 53692
private let CALLBACK_PATH = "/callback"
private let REDIRECT_URI = "http://localhost:\(CALLBACK_PORT)\(CALLBACK_PATH)"
private let COPY_CODE_REDIRECT_URI = "https://platform.claude.com/oauth/code/callback"
private let ANTHROPIC_BROWSER_LOGIN_METHOD = "browser"
private let ANTHROPIC_COPY_CODE_LOGIN_METHOD = "copy_code"
private let SCOPES =
    "org:create_api_key user:profile user:inference user:sessions:claude_code user:mcp_servers user:file_upload"

private func parseAuthorizationInput(_ input: String) -> (code: String?, state: String?) {
    let value = input.trimmingCharacters(in: .whitespacesAndNewlines)
    if value.isEmpty { return (nil, nil) }

    if let url = WebURL(value) {
        return (
            code: url.searchParams.get("code"),
            state: url.searchParams.get("state")
        )
    }
    // not a URL

    if value.contains("#") {
        let parts = value.split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false).map(String.init)
        // `value.split("#", 2)`: at most the first two `#`-separated pieces.
        let code = parts[0]
        let state = parts.count > 1 ? parts[1].split(separator: "#", omittingEmptySubsequences: false).first.map(String.init) : nil
        return (code, state)
    }

    if value.contains("code=") {
        let params = URLSearchParams(value)
        return (
            code: params.get("code"),
            state: params.get("state")
        )
    }

    return (code: value, state: nil)
}

private func formatErrorDetails(_ error: any Error) -> String {
    var details: [String] = []
    if let error = error as? PiError {
        details.append("\(error.name): \(error.message)")
    } else if let error = error as? FetchError {
        details.append("TypeError: \(error.message)")
        if let code = error.code { details.append("code=\(code)") }
        if let cause = error.cause { details.append("cause=\(cause)") }
    } else if error is AbortError {
        details.append("AbortError: \(errorMessage(error))")
    } else if error is FetchTimeoutError {
        details.append("TimeoutError: \(errorMessage(error))")
    } else {
        details.append("Error: \(errorMessage(error))")
    }
    // Not ported: errno and `stack` (no Swift equivalent).
    return details.joined(separator: "; ")
}

private func postJson(_ rt: OAuthRuntime, _ url: String, _ body: JsonObject, _ signal: AbortSignal) async throws -> String {
    let response = try await rt.fetch(
        url,
        method: "POST",
        headers: [
            ("Content-Type", "application/json"),
            ("Accept", "application/json"),
        ],
        body: JsonValue.object(body).serialized(),
        signal: AbortSignal.any([signal, AbortSignal.timeout(30_000)])
    )

    let responseBody = try await response.text()

    if !response.ok {
        throw PiError("HTTP request failed. status=\(response.status); url=\(url); body=\(responseBody)")
    }

    return responseBody
}

/// `{ access_token, refresh_token, expires_in }` read the way JS reads a parsed object: missing fields
/// become "" / 0 (upstream would carry `undefined` / NaN into the credential).
private func tokenCredential(_ rt: OAuthRuntime, _ data: JsonValue) -> OAuthCredential {
    let expiresIn = data["expires_in"]?.doubleValue ?? 0
    return OAuthCredential(
        refresh: data["refresh_token"]?.stringValue ?? "",
        access: data["access_token"]?.stringValue ?? "",
        expires: jsMillis(Double(rt.now()) + expiresIn * 1000 - 5 * 60 * 1000)
    )
}

private func exchangeAuthorizationCode(
    _ rt: OAuthRuntime,
    _ code: String,
    _ state: String,
    _ verifier: String,
    _ redirectUri: String,
    _ signal: AbortSignal
) async throws -> OAuthCredential {
    let responseBody: String
    do {
        responseBody = try await postJson(
            rt,
            TOKEN_URL,
            [
                "grant_type": "authorization_code",
                "client_id": .string(CLIENT_ID),
                "code": .string(code),
                "state": .string(state),
                "redirect_uri": .string(redirectUri),
                "code_verifier": .string(verifier),
            ],
            signal
        )
    } catch {
        throw PiError(
            "Token exchange request failed. url=\(TOKEN_URL); redirect_uri=\(redirectUri); response_type=authorization_code; details=\(formatErrorDetails(error))"
        )
    }

    let tokenData: JsonValue
    do {
        tokenData = try JsonValue.parse(responseBody)
    } catch {
        throw PiError(
            "Token exchange returned invalid JSON. url=\(TOKEN_URL); body=\(responseBody); details=\(formatErrorDetails(PiError(errorMessage(error), name: "SyntaxError")))"
        )
    }

    return tokenCredential(rt, tokenData)
}

private func loginAnthropic(_ rt: OAuthRuntime, _ callbackHost: String, _ interaction: ProviderAuthInteraction) async throws -> OAuthCredential {
    let (verifier, challenge) = await generatePKCE()
    let startCallbackServer: @Sendable (Int) async throws -> OAuthCallbackServer<String> = { port in
        try await startOAuthCallbackServer(OAuthCallbackServerOptions<String>(
            providerName: "Anthropic",
            host: callbackHost,
            port: port,
            path: CALLBACK_PATH,
            redirectHost: "localhost",
            state: verifier,
            complete: { code in code },
            signal: interaction.signal
        ))
    }
    // Without a callback server, login continues with the pasted redirect URL.
    var callback: OAuthCallbackServer<String>?
    do {
        callback = try await startCallbackServer(CALLBACK_PORT)
    } catch {
        callback = try? await startCallbackServer(0)
    }
    let redirectUri = callback?.redirectUri ?? REDIRECT_URI

    defer { callback?.close() }
    let authParams = URLSearchParams([
        ("code", "true"),
        ("client_id", CLIENT_ID),
        ("response_type", "code"),
        ("redirect_uri", redirectUri),
        ("scope", SCOPES),
        ("code_challenge", challenge),
        ("code_challenge_method", "S256"),
        ("state", verifier),
    ])
    interaction.notify(.auth_url(
        url: "\(AUTHORIZE_URL)?\(authParams.toString())",
        instructions:
            "Complete login in your browser. If the browser is on another machine, paste the final redirect URL here."
    ))

    let result = try await waitForCallbackOrManualInput(
        interaction,
        callback,
        message: "Complete login in your browser, or paste the authorization code / redirect URL here:",
        placeholder: redirectUri
    )
    var code: String?
    var state = verifier
    switch result {
    case .callback(let value):
        code = value
    case .manual(let input):
        let parsed = parseAuthorizationInput(input)
        if let parsedState = parsed.state, !parsedState.isEmpty, parsedState != verifier { throw PiError("OAuth state mismatch") }
        code = parsed.code
        state = parsed.state ?? verifier
    }

    guard let code, !code.isEmpty else { throw PiError("Missing authorization code") }
    interaction.notify(.progress(message: "Exchanging authorization code for tokens..."))
    return try await exchangeAuthorizationCode(rt, code, state, verifier, redirectUri, interaction.signal)
}

private func loginAnthropicCopyCode(_ rt: OAuthRuntime, _ interaction: ProviderAuthInteraction) async throws -> OAuthCredential {
    let (verifier, challenge) = await generatePKCE()
    let authParams = URLSearchParams([
        ("code", "true"),
        ("client_id", CLIENT_ID),
        ("response_type", "code"),
        ("redirect_uri", COPY_CODE_REDIRECT_URI),
        ("scope", SCOPES),
        ("code_challenge", challenge),
        ("code_challenge_method", "S256"),
        ("state", verifier),
    ])
    interaction.notify(.auth_url(
        url: "\(AUTHORIZE_URL)?\(authParams.toString())",
        instructions: "Complete login in your browser, then copy the code Anthropic shows and paste it here."
    ))

    let input = try await interaction.prompt(AuthPrompt(
        .manual_code(message: "Paste the code Anthropic shows after you sign in:", placeholder: "code#state"),
        signal: interaction.signal
    ))
    let parsed = parseAuthorizationInput(input)
    if let parsedState = parsed.state, !parsedState.isEmpty, parsedState != verifier { throw PiError("OAuth state mismatch") }
    guard let code = parsed.code, !code.isEmpty else { throw PiError("Missing authorization code") }
    interaction.notify(.progress(message: "Exchanging authorization code for tokens..."))
    return try await exchangeAuthorizationCode(
        rt,
        code,
        parsed.state ?? verifier,
        verifier,
        COPY_CODE_REDIRECT_URI,
        interaction.signal
    )
}

/**
 * Refresh Anthropic OAuth token
 */
private func refreshAnthropicToken(_ rt: OAuthRuntime, _ refreshToken: String, _ signal: AbortSignal) async throws -> OAuthCredential {
    let responseBody: String
    do {
        responseBody = try await postJson(
            rt,
            TOKEN_URL,
            [
                "grant_type": "refresh_token",
                "client_id": .string(CLIENT_ID),
                "refresh_token": .string(refreshToken),
            ],
            signal
        )
    } catch {
        throw PiError("Anthropic token refresh request failed. url=\(TOKEN_URL); details=\(formatErrorDetails(error))")
    }

    let data: JsonValue
    do {
        data = try JsonValue.parse(responseBody)
    } catch {
        throw PiError(
            "Anthropic token refresh returned invalid JSON. url=\(TOKEN_URL); body=\(responseBody); details=\(formatErrorDetails(PiError(errorMessage(error), name: "SyntaxError")))"
        )
    }

    return tokenCredential(rt, data)
}

func createAnthropicOAuth(_ rt: OAuthRuntime = .live) -> OAuthAuth {
    let callbackHost = rt.env("PI_OAUTH_CALLBACK_HOST") ?? "127.0.0.1"
    return OAuthAuth(
        name: "Anthropic (Claude Pro/Max)",
        isSubscription: true,

        login: { interaction, _ in
            let method = try await interaction.prompt(AuthPrompt(.select(
                message: "Select Anthropic login method:",
                options: [
                    AuthPromptOption(id: ANTHROPIC_BROWSER_LOGIN_METHOD, label: "Browser login (default)"),
                    AuthPromptOption(id: ANTHROPIC_COPY_CODE_LOGIN_METHOD, label: "Copy code login (headless)"),
                ]
            )))

            if method == ANTHROPIC_COPY_CODE_LOGIN_METHOD {
                return try await loginAnthropicCopyCode(rt, interaction)
            }
            if method != ANTHROPIC_BROWSER_LOGIN_METHOD {
                throw PiError("Unknown Anthropic login method: \(method)")
            }

            return try await loginAnthropic(rt, callbackHost, interaction)
        },

        refresh: { credential, signal in try await refreshAnthropicToken(rt, credential.refresh, signal) },

        toAuth: { credential in
            ModelAuth(apiKey: credential.access)
        }
    )
}

public let anthropicOAuth: OAuthAuth = createAnthropicOAuth()
