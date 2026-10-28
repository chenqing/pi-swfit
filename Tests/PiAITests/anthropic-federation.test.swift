import Foundation
import Testing
@testable import PiAI

// Port of packages/ai/test/anthropic-federation.test.ts (auth resolution cases).
// Not ported: the SDK-level cases ("hands the SDK a federation config instead of a key", "threads authContext
// federation variables through Models", "lets an explicit API key win over federation env", "does not federate
// other anthropic-messages providers", and the SDK half of the SERVICE_ACCOUNT_ID case). They mock
// `@anthropic-ai/sdk` and exercise api/anthropic-messages, which belongs to the API group.

private let federationEnv: [String: String] = [
    "ANTHROPIC_FEDERATION_RULE_ID": "fdrl_test",
    "ANTHROPIC_ORGANIZATION_ID": "org-test",
    "ANTHROPIC_SERVICE_ACCOUNT_ID": "svac_test",
    "ANTHROPIC_IDENTITY_TOKEN_FILE": "/tmp/identity.jwt",
]

private func resolveWithEnv(_ env: [String: String]) async throws -> AuthResult? {
    try await anthropicProvider(models: []).auth.apiKey?.resolve(ApiKeyAuthInput(
        ctx: AuthContext(env: { env[$0] }, fileExists: { _ in false }),
        signal: AbortController().signal
    ))
}

private func isEmptyAuth(_ auth: ModelAuth) -> Bool {
    auth.apiKey == nil && auth.headers == nil && auth.baseUrl == nil
}

// https://github.com/earendil-works/pi/issues/10177
@Suite("Anthropic workload identity federation")
struct AnthropicFederationTests {
    @Test("resolves the federation variables as provider env with no request auth")
    func resolvesFederation() async throws {
        let result = try #require(try await resolveWithEnv(federationEnv))
        #expect(isEmptyAuth(result.auth))
        #expect(result.env == federationEnv)
        #expect(result.source == "workload identity federation")
    }

    @Test("passes ANTHROPIC_WORKSPACE_ID through when set")
    func passesWorkspaceId() async throws {
        var env = federationEnv
        env["ANTHROPIC_WORKSPACE_ID"] = "wrkspc_test"
        let result = try await resolveWithEnv(env)
        #expect(result?.env?["ANTHROPIC_WORKSPACE_ID"] == "wrkspc_test")
    }

    @Test("is not configured when a federation variable is missing")
    func missingVariable() async throws {
        var partial = federationEnv
        partial["ANTHROPIC_IDENTITY_TOKEN_FILE"] = nil
        #expect(try await resolveWithEnv(partial) == nil)
    }

    @Test("treats ANTHROPIC_SERVICE_ACCOUNT_ID as optional, like the SDK")
    func serviceAccountOptional() async throws {
        var partial = federationEnv
        partial["ANTHROPIC_SERVICE_ACCOUNT_ID"] = nil
        let result = try #require(try await resolveWithEnv(partial))
        #expect(isEmptyAuth(result.auth))
        #expect(result.env == partial)
        #expect(result.source == "workload identity federation")
    }

    @Test("keeps API key and auth token precedence over federation")
    func keyPrecedence() async throws {
        var withKey = federationEnv
        withKey["ANTHROPIC_API_KEY"] = "api-key"
        let keyResult = try #require(try await resolveWithEnv(withKey))
        #expect(keyResult.auth.apiKey == "api-key")
        #expect(keyResult.auth.headers == nil)
        #expect(keyResult.env == nil)
        #expect(keyResult.source == "ANTHROPIC_API_KEY")

        var withToken = federationEnv
        withToken["ANTHROPIC_AUTH_TOKEN"] = "auth-token"
        let tokenResult = try #require(try await resolveWithEnv(withToken))
        #expect(tokenResult.auth.apiKey == nil)
        #expect(gHeaders(tokenResult.auth.headers) == ["Authorization=Bearer auth-token"])
        #expect(tokenResult.env == nil)
        #expect(tokenResult.source == "ANTHROPIC_AUTH_TOKEN")
    }
}
