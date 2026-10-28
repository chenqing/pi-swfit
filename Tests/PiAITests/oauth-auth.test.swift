import Foundation
import Testing
@testable import PiAI

// Port of packages/ai/test/oauth-auth.test.ts
// `vi.stubGlobal("fetch", ...)` -> the flow factories with a test runtime.
// Not ported: the openai-codex cases (openai-codex.ts is not ported) and the `../src/oauth.ts`
// extension-barrel check (that module is not part of this port).

private let neverAbortedSignal = AbortController().signal

private func jsonResponse(_ body: JsonValue, _ status: Int = 200) -> FetchResponse {
    oauthJson(status, body.serialized(), headers: [("Content-Type", "application/json")])
}

private func credential(access: String, refresh: String = "r", expires: Int = 0, extra: JsonObject = JsonObject()) -> OAuthCredential {
    OAuthCredential(refresh: refresh, access: access, expires: expires, extra: extra)
}

private func modelAuthFields(_ auth: ModelAuth) -> [String] {
    var fields: [String] = []
    if let apiKey = auth.apiKey { fields.append("apiKey=\(apiKey)") }
    if let headers = gHeaders(auth.headers) { fields.append("headers=\(headers)") }
    if let baseUrl = auth.baseUrl { fields.append("baseUrl=\(baseUrl)") }
    return fields
}

@Suite(.serialized) struct OAuthAuthAdaptersTests {
    @Test func identifiesOnlySubscriptionBackedOAuthFlowsAsSubscriptions() {
        for oauth in [anthropicOAuth, openaiChatGPTOAuth, githubCopilotOAuth, kimiCodingOAuth, xaiOAuth] {
            #expect(oauth.isSubscription == true, "\(oauth.name)")
        }
        #expect(openRouterOAuth.isSubscription != true)
    }

    @Test func anthropicToAuthDerivesTheApiKeyFromTheAccessToken() async throws {
        let auth = try await anthropicOAuth.toAuth(credential(access: "token"))
        #expect(modelAuthFields(auth) == ["apiKey=token"])
    }

    @Test func openAIExposesChatGPTOAuthAlongsideApiKeyAuth() {
        let provider = openaiProvider()
        #expect(provider.auth.apiKey != nil)
        #expect(provider.auth.oauth?.name == "OpenAI (ChatGPT subscription)")
        #expect(provider.auth.oauth?.isSubscription == true)
        #expect(provider.auth.oauth?.loginLabel == "Sign in with ChatGPT")
    }

    @Test func openrouterDerivesTheApiKeyAndKeepsThePermanentCredentialOnRefresh() async throws {
        let permanent = credential(access: "token", refresh: "", expires: 9_007_199_254_740_991)
        #expect(modelAuthFields(try await openRouterOAuth.toAuth(permanent)) == ["apiKey=token"])
        #expect(try await openRouterOAuth.refresh(permanent, neverAbortedSignal) == permanent)
    }

    @Test func xAIToAuthDerivesTheApiKeyFromTheAccessToken() async throws {
        let auth = try await xaiOAuth.toAuth(credential(access: "token"))
        #expect(modelAuthFields(auth) == ["apiKey=token"])
    }

    @Test func githubCopilotToAuthDerivesBaseUrlFromTheTokenProxyEndpoint() async throws {
        let access = "tid=abc;exp=123;proxy-ep=proxy.enterprise.example;rest"
        let auth = try await githubCopilotOAuth.toAuth(credential(access: access))
        #expect(modelAuthFields(auth) == ["apiKey=\(access)", "baseUrl=https://api.enterprise.example"])
    }

    @Test func githubCopilotToAuthFallsBackToTheEnterpriseDomainThenTheIndividualEndpoint() async throws {
        let enterprise = try await githubCopilotOAuth.toAuth(
            credential(access: "no-proxy-ep", extra: ["enterpriseUrl": "https://company.ghe.com"])
        )
        #expect(enterprise.baseUrl == "https://copilot-api.company.ghe.com")

        let individual = try await githubCopilotOAuth.toAuth(credential(access: "no-proxy-ep"))
        #expect(individual.baseUrl == "https://api.individual.githubcopilot.com")
    }

    @Test func anthropicRefreshExchangesTheRefreshTokenAndReturnsATypedCredential() async throws {
        let h = OAuthTestHarness { _ in
            jsonResponse(["access_token": "new-access", "refresh_token": "new-refresh", "expires_in": 3600])
        }
        let refreshed = try await createAnthropicOAuth(h.runtime).refresh(
            credential(access: "old", refresh: "old-r"),
            neverAbortedSignal
        )
        #expect(Credential.oauth(refreshed).type == "oauth")
        #expect(refreshed.access == "new-access")
        #expect(refreshed.refresh == "new-refresh")
        #expect(refreshed.expires > h.now)
    }

    @Test func githubCopilotRefreshPreservesTheEnterpriseDomain() async throws {
        let h = OAuthTestHarness { call in
            if call.url.hasSuffix("/models") { return jsonResponse(["data": []]) }
            return jsonResponse(["token": "new-token", "expires_at": 9999999999])
        }
        let refreshed = try await createGitHubCopilotOAuth(h.runtime).refresh(
            credential(access: "old", refresh: "gh-token", extra: ["enterpriseUrl": "company.ghe.com"]),
            neverAbortedSignal
        )
        #expect(refreshed.access == "new-token")
        #expect(refreshed.extra["enterpriseUrl"]?.stringValue == "company.ghe.com")
        #expect(h.urls.first?.contains("api.company.ghe.com") == true)
    }
}

/// `models.getModels(provider)[0].provider` is the provider id; the builtin catalog is empty in
/// Swift tests, so the id is used directly.
@Suite struct OAuthThroughModelsGetAuthTests {
    @Test func resolvesStoredAnthropicOAuthCredentialsViaTheLazyFlowImport() async throws {
        let credentials = InMemoryCredentialStore()
        _ = try await credentials.modify("anthropic") { _ in
            // Keep this beyond getAuth()'s refresh window.
            .oauth(OAuthCredential(refresh: "r", access: "oauth-access-token", expires: dateNow() + 10 * 60_000))
        }
        let models = createModels(CreateModelsOptions(credentials: credentials))
        models.setProvider(anthropicProvider())

        let result = try await models.getAuth("anthropic")
        #expect(result?.auth.apiKey == "oauth-access-token")
        #expect(result?.source == "OAuth")
    }

    @Test func resolvesStoredGitHubCopilotOAuthCredentialsIncludingPerCredentialBaseUrl() async throws {
        let access = "tid=abc;exp=123;proxy-ep=proxy.business.githubcopilot.com;rest"
        let credentials = InMemoryCredentialStore()
        _ = try await credentials.modify("github-copilot") { _ in
            // Keep this beyond getAuth()'s refresh window.
            .oauth(OAuthCredential(refresh: "r", access: access, expires: dateNow() + 10 * 60_000))
        }
        let models = createModels(CreateModelsOptions(credentials: credentials))
        models.setProvider(githubCopilotProvider())

        let result = try await models.getAuth("github-copilot")
        #expect(result?.auth.apiKey == access)
        #expect(result?.auth.baseUrl == "https://api.business.githubcopilot.com")
    }
}
