import Foundation
import Testing
@testable import PiAI

// Port of packages/ai/test/openai-chatgpt-oauth.test.ts
// `vi.stubGlobal("fetch", ...)` -> `createOpenAIChatGPTOAuth(harness.runtime)`. Login starts the real
// loopback callback server on 127.0.0.1:1455, so the suite is serialized.

private let TOKEN_URL = "https://auth.openai.com/api/accounts/oauth/token"
private let REQUIRED_SCOPE = "openid profile email offline_access resource.invoke chatgpt.tokens.use.direct"
private let neverAbortedSignal = AbortController().signal
private let DEVICE_ID = "e61bbe28-07ef-466d-8e5d-a344f94ab305"

private func tokenResponse(_ scope: String = REQUIRED_SCOPE) -> JsonObject {
    [
        "access_token": "access-token",
        "refresh_token": "refresh-token",
        "expires_in": 3600,
        "id_token": "id-token",
        "scope": .string(scope),
    ]
}

private func stubTokenEndpoint(_ response: JsonObject, _ inspect: (@Sendable (URLSearchParams) -> Void)? = nil) -> OAuthTestHarness {
    OAuthTestHarness { call in
        #expect(call.url == TOKEN_URL)
        inspect?(call.form)
        return oauthJson(200, JsonValue.object(response).serialized())
    }
}

/// Answers the manual-code prompt with the redirect URL the browser would have been sent to.
private func loginInteraction(callbackClientId: String? = nil, onAuthorize: (@Sendable (WebURL) -> Void)? = nil) -> ProviderAuthInteraction {
    let authorizeUrl = Locked<WebURL?>(nil)
    return ProviderAuthInteraction(
        signal: neverAbortedSignal,
        prompt: { prompt in
            guard case .manual_code = prompt.kind else { throw PiError("Unexpected prompt: \(prompt.kind)") }
            guard let authorize = authorizeUrl.current else {
                throw PiError("Authorization URL was not emitted before the callback prompt")
            }
            var params: [(String, String)] = [
                ("code", "authorization-code"),
                ("state", authorize.searchParams.get("state") ?? ""),
            ]
            if let callbackClientId { params.append(("client_id", callbackClientId)) }
            return oauthCallbackUrl(authorize.searchParams.get("redirect_uri") ?? "", params)
        },
        notify: { event in
            guard case .auth_url(let url, _) = event, let parsed = WebURL(url) else { return }
            authorizeUrl.withLock { $0 = parsed }
            onAuthorize?(parsed)
        }
    )
}

private func connectedCredential() -> OAuthCredential {
    OAuthCredential(
        refresh: "old-refresh",
        access: "old-access",
        expires: 0,
        extra: [
            "clientId": "oaiapp_existing",
            "scopes": .array(REQUIRED_SCOPE.split(separator: " ").map { .string(String($0)) }),
        ]
    )
}

private func scopes(_ credential: OAuthCredential) -> [String]? {
    credential.extra["scopes"]?.arrayValue?.compactMap(\.stringValue)
}

private let requiredScopes = REQUIRED_SCOPE.split(separator: " ").map(String.init)

@Suite(.serialized) struct OpenAIChatGPTOAuthTests {
    @Test func registersAUserOwnedClientAndStoresItsIssuedIdAndGrantedScopes() async throws {
        let authorizeUrl = Locked<WebURL?>(nil)
        let exchangeBody = Locked<URLSearchParams?>(nil)
        let h = stubTokenEndpoint(tokenResponse()) { body in exchangeBody.withLock { $0 = body } }

        let credential = try await createOpenAIChatGPTOAuth(h.runtime).login(
            loginInteraction(callbackClientId: "oaiapp_issued", onAuthorize: { url in authorizeUrl.withLock { $0 = url } }),
            LoginOptions(getDeviceId: { DEVICE_ID })
        )

        let params = authorizeUrl.current?.searchParams
        #expect(params?.get("client_id") == "dynamic_agent_client")
        #expect(params?.get("agent_name_hint") == "Pi")
        #expect(params?.get("ext_agent_host_id") == "urn:uuid:\(DEVICE_ID)")
        #expect(params?.get("scope") == REQUIRED_SCOPE)
        #expect(params?.get("redirect_uri") == "http://127.0.0.1:1455/auth/callback")
        #expect(params?.get("resource") == "https://api.openai.com/v1")
        #expect(params?.get("code_challenge_method") == "S256")
        let body = exchangeBody.current
        #expect(body?.get("client_id") == "oaiapp_issued")
        #expect(body?.get("code") == "authorization-code")
        #expect(body?.get("resource") == "https://api.openai.com/v1")
        #expect(body?.get("code_verifier")?.isEmpty == false)
        #expect(credential.access == "access-token")
        #expect(credential.refresh == "refresh-token")
        #expect(credential.extra["clientId"]?.stringValue == "oaiapp_issued")
        #expect(scopes(credential) == requiredScopes)
    }

    @Test func usesTheAppsAgentNameAsTheNameHint() async throws {
        let authorizeUrl = Locked<WebURL?>(nil)
        let h = stubTokenEndpoint(tokenResponse())

        _ = try await createOpenAIChatGPTOAuth(h.runtime).login(
            loginInteraction(callbackClientId: "oaiapp_issued", onAuthorize: { url in authorizeUrl.withLock { $0 = url } }),
            LoginOptions(getDeviceId: { DEVICE_ID }, agentName: "my-app")
        )

        #expect(authorizeUrl.current?.searchParams.get("agent_name_hint") == "my-app")
    }

    @Test func rejectsRegistrationWithoutAnIssuedClientId() async throws {
        let h = stubTokenEndpoint(tokenResponse())

        let error = await gCaught {
            _ = try await createOpenAIChatGPTOAuth(h.runtime).login(loginInteraction(), LoginOptions(getDeviceId: { DEVICE_ID }))
        }
        #expect(error.map(errorMessage)?.contains("registration callback did not contain an issued client ID") == true)
        #expect(h.calls.current.isEmpty)
    }

    @Test func rejectsATokenResponseThatDidNotGrantDirectTokenUse() async throws {
        let h = stubTokenEndpoint(tokenResponse("openid profile email offline_access resource.invoke"))

        let error = await gCaught {
            _ = try await createOpenAIChatGPTOAuth(h.runtime).login(
                loginInteraction(callbackClientId: "oaiapp_issued"),
                LoginOptions(getDeviceId: { DEVICE_ID })
            )
        }
        #expect(error.map(errorMessage)?.contains("grant did not include chatgpt.tokens.use.direct") == true)
    }

    @Test func requiresADeviceIdBeforeStartingAuthorization() async throws {
        let authorizationStarted = Locked(false)
        let interaction = loginInteraction(onAuthorize: { _ in authorizationStarted.withLock { $0 = true } })
        let oauth = createOpenAIChatGPTOAuth(OAuthTestHarness().runtime)

        let first = await gCaught { _ = try await oauth.login(interaction, nil) }
        #expect(first.map(errorMessage)?.contains("requires a device ID") == true)
        let second = await gCaught { _ = try await oauth.login(interaction, LoginOptions(getDeviceId: { "not-a-uuid" })) }
        #expect(second.map(errorMessage)?.contains("requires a device ID") == true)
        #expect(authorizationStarted.current == false)
    }

    @Test func requiresRefreshResponsesToRotateTheRefreshToken() async throws {
        var responseWithoutRefresh = tokenResponse()
        responseWithoutRefresh["refresh_token"] = Optional<JsonValue>.none
        let h = stubTokenEndpoint(responseWithoutRefresh)

        let error = await gCaught { _ = try await createOpenAIChatGPTOAuth(h.runtime).refresh(connectedCredential(), neverAbortedSignal) }
        #expect(error.map(errorMessage)?.contains("token response has invalid refresh_token") == true)
    }

    @Test func refreshesWithTheCredentialsIssuedClientIdAndStoresReplacementScopes() async throws {
        let refreshBody = Locked<URLSearchParams?>(nil)
        var response = tokenResponse()
        response["access_token"] = "new-access"
        response["refresh_token"] = "new-refresh"
        let h = stubTokenEndpoint(response) { body in refreshBody.withLock { $0 = body } }

        let before = h.now
        let credential = try await createOpenAIChatGPTOAuth(h.runtime).refresh(connectedCredential(), neverAbortedSignal)

        // expires_in is 3600 seconds; the credential expires 3 minutes early so it is refreshed in time.
        #expect(credential.expires >= before + (3600 - 180) * 1000)
        #expect(credential.expires <= h.now + (3600 - 180) * 1000)

        let body = refreshBody.current
        #expect(body?.get("grant_type") == "refresh_token")
        #expect(body?.get("client_id") == "oaiapp_existing")
        #expect(body?.get("refresh_token") == "old-refresh")
        #expect(body?.get("resource") == "https://api.openai.com/v1")
        #expect(body?.has("scope") == false)
        #expect(credential.access == "new-access")
        #expect(credential.refresh == "new-refresh")
        #expect(credential.extra["clientId"]?.stringValue == "oaiapp_existing")
        #expect(scopes(credential) == requiredScopes)
    }
}
