import Foundation

// Port of packages/ai/src/auth/oauth/openai-chatgpt.ts
// (named `oauth-openai-chatgpt.swift` for consistency with the other `oauth-*` flow files)

/**
 * OpenAI Responses API token sharing through Sign in with ChatGPT.
 *
 * This public-client flow uses no client secret and sends the resulting user
 * access token directly to api.openai.com.
 */

// every login registers a new client with this ID; OpenAI returns the issued client ID in the callback
private let DYNAMIC_CLIENT_ID = "dynamic_agent_client"
private let AGENT_NAME_HINT = "Pi"
private func UUID_PATTERN() -> Regex<Substring> { /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/.ignoresCase() }
private let AUTHORIZE_URL = "https://auth.openai.com/api/accounts/authorize"
private let TOKEN_URL = "https://auth.openai.com/api/accounts/oauth/token"
private let RESOURCE = "https://api.openai.com/v1"
// `CALLBACK_HOST` is read from the environment when the flow is created (module load upstream); see `createOpenAIChatGPTOAuth`.
private let CALLBACK_PORT = 1455
private let CALLBACK_PATH = "/auth/callback"
private let REDIRECT_URI = "http://127.0.0.1:\(CALLBACK_PORT)\(CALLBACK_PATH)"
private let DIRECT_TOKEN_SCOPE = "chatgpt.tokens.use.direct"
private let SCOPE = "openid profile email offline_access resource.invoke \(DIRECT_TOKEN_SCOPE)"
// Refresh this long before the real expiry so a request never starts with a token about to expire.
private let EXPIRY_MARGIN_MS: Double = 3 * 60 * 1000

private struct AuthorizationResult: Sendable {
    var code: String
    var clientId: String
}

private struct CallbackServer: Sendable {
    var server: LoopbackHTTPServer
    var result: PendingResult<AuthorizationResult>
}

private func randomValue() -> String {
    var generator = SystemRandomNumberGenerator()
    return base64urlEncode((0..<32).map { _ in UInt8.random(in: .min ... .max, using: &generator) })
}

private func authorizationResultFromCallback(_ url: WebURL, _ expectedState: String) throws -> AuthorizationResult {
    let params = url.searchParams
    guard let code = params.get("code"), !code.isEmpty else { throw PiError("Missing authorization code") }
    guard let state = params.get("state"), !state.isEmpty else { throw PiError("Missing OAuth state") }
    if state != expectedState { throw PiError("OAuth state mismatch") }
    let clientId = params.get("client_id")?.trimmingCharacters(in: .whitespacesAndNewlines)
    guard let clientId, !clientId.isEmpty else {
        throw PiError("OpenAI OAuth registration callback did not contain an issued client ID")
    }
    return AuthorizationResult(code: code, clientId: clientId)
}

private func authorizationResultFromManualInput(_ input: String, _ expectedState: String) throws -> AuthorizationResult {
    guard let url = WebURL(input.trimmingCharacters(in: .whitespacesAndNewlines)) else {
        throw PiError("Paste the full callback URL from the browser")
    }
    let expected = WebURL(REDIRECT_URI)!
    if url.origin != expected.origin || url.pathname != expected.pathname {
        throw PiError("The pasted callback URL must start with \(REDIRECT_URI)")
    }
    if let error = url.searchParams.get("error"), !error.isEmpty { throw PiError("ChatGPT authorization failed: \(error)") }
    return try authorizationResultFromCallback(url, expectedState)
}

private func sendHtml(_ status: Int, _ body: String) -> LoopbackHTTPResponse {
    LoopbackHTTPResponse(status: status, headers: [("Content-Type", "text/html; charset=utf-8")], body: body)
}

private func startCallbackServer(_ callbackHost: String, _ expectedState: String) async throws -> CallbackServer {
    let result = PendingResult<AuthorizationResult>()

    let server = try await LoopbackHTTPServer.listen(host: callbackHost, port: CALLBACK_PORT) { request in
        // `new URL(request.url || "", REDIRECT_URI)`: the request target is origin-relative.
        let target = request.url.hasPrefix("/") ? request.url : "/" + request.url
        guard let url = WebURL("http://127.0.0.1:\(CALLBACK_PORT)" + target) else {
            return sendHtml(500, oauthErrorHtml("Internal error while processing the callback."))
        }
        if url.pathname != CALLBACK_PATH {
            return sendHtml(404, oauthErrorHtml("Callback route not found."))
        }

        if let error = url.searchParams.get("error"), !error.isEmpty {
            let page = sendHtml(400, oauthErrorHtml("ChatGPT was not connected.", "Error: \(error)"))
            result.reject(PiError("ChatGPT authorization failed: \(error)"))
            return page
        }

        let authorizationResult: AuthorizationResult
        do {
            authorizationResult = try authorizationResultFromCallback(url, expectedState)
        } catch {
            return sendHtml(400, oauthErrorHtml(errorMessage(error)))
        }

        let page = sendHtml(200, oauthSuccessHtml("ChatGPT authentication completed. You can close this window."))
        result.resolve(authorizationResult)
        return page
    }

    server.onError { error in result.reject(error) }
    return CallbackServer(server: server, result: result)
}

private func requestToken(_ rt: OAuthRuntime, _ body: URLSearchParams, _ signal: AbortSignal) async throws -> JsonObject {
    let response = try await rt.fetch(
        TOKEN_URL,
        method: "POST",
        headers: [
            ("accept", "application/json"),
            ("content-type", "application/x-www-form-urlencoded"),
        ],
        body: body.toString(),
        signal: signal
    )
    if !response.ok {
        let responseBody = (try? await response.text()) ?? ""
        throw PiError("OpenAI OAuth token request failed (\(response.status)): \(responseBody.isEmpty ? response.statusText : responseBody)")
    }
    let data = try await response.json()
    guard case .object(let object) = data else {
        throw PiError("OpenAI OAuth token response must be an object")
    }
    return object
}

private func requireTokenString(_ value: JsonValue?, _ field: String) throws -> String {
    guard case .string(let string)? = value, !string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
        throw PiError("OpenAI OAuth token response has invalid \(field)")
    }
    return string
}

private func credentialFromTokenResponse(_ rt: OAuthRuntime, _ token: JsonObject, _ clientId: String) throws -> OAuthCredential {
    let access = try requireTokenString(token["access_token"], "access_token")
    let refresh = try requireTokenString(token["refresh_token"], "refresh_token")
    let scope = try requireTokenString(token["scope"], "scope")
    guard case .number(let expiresIn)? = token["expires_in"], expiresIn.isFinite, expiresIn > 0 else {
        throw PiError("OpenAI OAuth token response has invalid expires_in")
    }
    let scopes = scope.split(whereSeparator: { $0.isWhitespace }).map(String.init).filter { !$0.isEmpty }
    if !scopes.contains(DIRECT_TOKEN_SCOPE) {
        throw PiError("OpenAI OAuth grant did not include \(DIRECT_TOKEN_SCOPE)")
    }
    var extra = JsonObject()
    extra["clientId"] = .string(clientId)
    extra["scopes"] = .array(scopes.map(JsonValue.string))
    return OAuthCredential(
        refresh: refresh,
        access: access,
        expires: jsMillis(Double(rt.now()) + expiresIn * 1000 - EXPIRY_MARGIN_MS),
        extra: extra
    )
}

private func exchangeAuthorizationCode(
    _ rt: OAuthRuntime,
    _ code: String,
    _ verifier: String,
    _ clientId: String,
    _ signal: AbortSignal
) async throws -> OAuthCredential {
    let token = try await requestToken(
        rt,
        URLSearchParams([
            ("grant_type", "authorization_code"),
            ("client_id", clientId),
            ("code", code),
            ("code_verifier", verifier),
            ("redirect_uri", REDIRECT_URI),
            ("resource", RESOURCE),
        ]),
        signal
    )
    // Pi does not use the ID token to identify the user or read profile data.
    // Keep the presence check as part of the token-response contract.
    guard case .string(let idToken)? = token["id_token"], !idToken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
        throw PiError("OpenAI OAuth token response did not contain an ID token")
    }
    return try credentialFromTokenResponse(rt, token, clientId)
}

private func refreshAccessToken(_ rt: OAuthRuntime, _ credential: OAuthCredential, _ signal: AbortSignal) async throws -> OAuthCredential {
    guard case .string(let clientId)? = credential.extra["clientId"], !clientId.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
        throw PiError("Stored OpenAI OAuth credential does not contain an issued client ID; reconnect ChatGPT")
    }
    let token = try await requestToken(
        rt,
        URLSearchParams([
            ("grant_type", "refresh_token"),
            ("client_id", clientId),
            ("refresh_token", credential.refresh),
            ("resource", RESOURCE),
        ]),
        signal
    )
    return try credentialFromTokenResponse(rt, token, clientId)
}

/// OpenAI identifies each installation ("agent host") by a stable URI such as `urn:uuid:<uuid>`.
private func agentHostId(_ deviceId: String?) throws -> String {
    guard let deviceId, !deviceId.isEmpty, (try? UUID_PATTERN().wholeMatch(in: deviceId)) != nil else {
        throw PiError("Sign in with ChatGPT requires a device ID (UUID) for this installation")
    }
    return "urn:uuid:\(deviceId.lowercased())"
}

private func loginOpenAIChatGPT(
    _ rt: OAuthRuntime,
    _ callbackHost: String,
    _ interaction: ProviderAuthInteraction,
    _ options: LoginOptions?
) async throws -> OAuthCredential {
    let hostId = try agentHostId(options?.getDeviceId?())
    let (verifier, challenge) = await generatePKCE()
    let state = randomValue()
    let nonce = randomValue()
    // Without this server, the browser's callback would reach whatever else holds the port (another
    // pending login or the Codex CLI), which rejects it as a state mismatch. Fail with a clear error instead.
    let callback: CallbackServer
    do {
        callback = try await startCallbackServer(callbackHost, state)
    } catch {
        guard let listenError = error as? LoopbackListenError, listenError.code == "EADDRINUSE" else { throw error }
        throw PiError(
            "Port \(CALLBACK_PORT) is in use, probably by an unfinished login in another pi session or by the Codex CLI. Cancel that login and try again."
        )
    }

    let authorizationUrl = WebURL(AUTHORIZE_URL)!.withSearch(URLSearchParams([
        ("client_id", DYNAMIC_CLIENT_ID),
        ("agent_name_hint", options?.agentName ?? AGENT_NAME_HINT),
        ("ext_agent_host_id", hostId),
        ("response_type", "code"),
        ("redirect_uri", REDIRECT_URI),
        ("resource", RESOURCE),
        ("scope", SCOPE),
        ("state", state),
        ("code_challenge", challenge),
        ("code_challenge_method", "S256"),
        ("nonce", nonce),
    ]))
    interaction.notify(.auth_url(
        url: authorizationUrl.href,
        instructions:
            "Complete sign-in in your browser. If the callback does not complete, paste the final redirect URL here."
    ))

    // `Promise.race([callback.result, manualCode])`: both settle the same once-only result.
    let race = callback.result
    let manualAbort = AbortController()
    Task {
        do {
            let input = try await interaction.prompt(AuthPrompt(
                .manual_code(
                    message: "Complete login in your browser, or paste the final redirect URL here:",
                    placeholder: REDIRECT_URI
                ),
                signal: AbortSignal.any([manualAbort.signal, interaction.signal])
            ))
            race.settle(Result { try authorizationResultFromManualInput(input, state) })
        } catch {
            race.reject(error)
        }
    }

    defer {
        manualAbort.abort()
        callback.server.close()
        // close() only stops accepting new connections. Browsers open spare connections ahead of
        // time, and one that has not sent a request yet stays open and attached to this server.
        // A later login in the same process starts a new server with a new state, but the browser
        // may send that login's callback over the spare connection. This server would then handle
        // it and reject it with "OAuth state mismatch", and the new login would never see it.
        callback.server.closeAllConnections()
    }
    do {
        let result = try await race.value()
        interaction.notify(.progress(message: "Exchanging authorization code for tokens..."))
        return try await exchangeAuthorizationCode(rt, result.code, verifier, result.clientId, interaction.signal)
    } catch {
        if interaction.signal.aborted { throw PiError("Login cancelled") }
        throw error
    }
}

func createOpenAIChatGPTOAuth(_ rt: OAuthRuntime = .live) -> OAuthAuth {
    let callbackHost = rt.env("PI_OAUTH_CALLBACK_HOST") ?? "127.0.0.1"
    return OAuthAuth(
        name: "OpenAI (ChatGPT subscription)",
        isSubscription: true,
        loginLabel: "Sign in with ChatGPT",
        login: { interaction, options in try await loginOpenAIChatGPT(rt, callbackHost, interaction, options) },
        refresh: { credential, signal in try await refreshAccessToken(rt, credential, signal) },
        toAuth: { credential in
            ModelAuth(apiKey: credential.access)
        }
    )
}

public let openaiChatGPTOAuth: OAuthAuth = createOpenAIChatGPTOAuth()
