import Foundation
import Testing
@testable import PiAI

// Port of packages/ai/test/meta-oauth.test.ts
// `vi.stubGlobal("fetch", ...)` + fake timers -> `createMetaOAuth(harness.runtime)` with a virtual clock.

private let CLIENT_ID = "1031625952748946"
private let DEVICE_AUTHORIZATION_URL = "https://auth.meta.com/oidc/device/authorization/"
private let DEVICE_TOKEN_URL = "https://auth.meta.com/oidc/device/token/"
private let MINT_URL = "https://api.meta.ai/muse-code/key"
private let DAY_MS = 24 * 60 * 60 * 1000

@Suite struct MetaOAuthTests {
    @Test func logsInWithTheDeviceFlowAndMintsAModelApiKey() async throws {
        let startTime = 1_788_393_600_000 // 2026-09-03T00:00:00Z
        let pollResponses = Locked([
            oauthJson(400, #"{"error":"authorization_pending"}"#),
            oauthJson(200, #"{"access_token":"identity-token","token_type":"Bearer"}"#),
        ])
        let h = OAuthTestHarness(now: startTime) { call in
            if call.url == DEVICE_AUTHORIZATION_URL {
                #expect(call.method == "POST")
                #expect(call.form.get("client_id") == CLIENT_ID)
                return oauthJson(200, #"{"device_code":"device-code-123","user_code":"ABCD-1234","verification_uri":"https://auth.meta.com/oauth/device/","verification_uri_complete":"https://auth.meta.com/oauth/device/?code=ABCD-1234","interval":5,"expires_in":600}"#)
            }
            if call.url == DEVICE_TOKEN_URL {
                let params = call.form
                #expect(params.get("grant_type") == "urn:ietf:params:oauth:grant-type:device_code")
                #expect(params.get("client_id") == CLIENT_ID)
                #expect(params.get("device_code") == "device-code-123")
                guard let response = pollResponses.withLock({ $0.isEmpty ? nil : $0.removeFirst() }) else {
                    throw PiError("Unexpected extra token poll")
                }
                return response
            }
            if call.url == MINT_URL {
                #expect(call.method == "POST")
                #expect(call.headers.get("Authorization") == "Bearer identity-token")
                return oauthJson(200, #"{"api_key":"LLM|minted-key"}"#)
            }
            throw PiError("Unexpected fetch URL: \(call.url)")
        }

        let i = OAuthTestInteraction { _ in throw PiError("Meta login should not prompt") }
        let credential = try await createMetaOAuth(h.runtime).login(i.interaction, nil)
        guard case .device_code(let userCode, let verificationUri, let intervalSeconds, let expiresInSeconds)? = i.events.current.first else {
            Issue.record("expected a device_code event first")
            return
        }
        #expect(userCode == "ABCD-1234")
        #expect(verificationUri == "https://auth.meta.com/oauth/device/?code=ABCD-1234")
        #expect(intervalSeconds == 5)
        #expect(expiresInSeconds == 600)

        #expect(credential.refresh == "identity-token")
        #expect(credential.access == "LLM|minted-key")
        #expect(credential.expires == startTime + 10000 + DAY_MS)
        #expect(credential.extra.isEmpty)
    }

    @Test func reMintsTheApiKeyFromTheStoredIdentityTokenOnRefresh() async throws {
        let now = 1_788_436_800_000 // 2026-09-03T12:00:00Z
        let h = OAuthTestHarness(now: now) { call in
            #expect(call.url == MINT_URL)
            #expect(call.headers.get("Authorization") == "Bearer identity-token")
            return oauthJson(200, #"{"api_key":"LLM|fresh-key"}"#)
        }
        let credential = try await createMetaOAuth(h.runtime).refresh(
            OAuthCredential(refresh: "identity-token", access: "LLM|old-key", expires: 1),
            AbortController().signal
        )
        #expect(credential.refresh == "identity-token")
        #expect(credential.access == "LLM|fresh-key")
        #expect(credential.expires == now + DAY_MS)
    }

    @Test func reportsTheSetupUrlWhenMetaIssuesNoKey() async throws {
        let h = OAuthTestHarness { _ in oauthJson(200, #"{"require_payment":true,"action_url":"https://dev.meta.ai/billing"}"#) }
        let error = await gCaught {
            _ = try await createMetaOAuth(h.runtime).refresh(
                OAuthCredential(refresh: "identity-token", access: "", expires: 1),
                AbortController().signal
            )
        }
        #expect(errorMessage(error!).contains("Complete setup at https://dev.meta.ai/billing"))
    }

    @Test func usesTheMintedKeyAsTheRequestApiKey() async throws {
        let auth = try await metaOAuth.toAuth(OAuthCredential(refresh: "identity-token", access: "LLM|key", expires: 1))
        #expect(auth.apiKey == "LLM|key")
        #expect(auth.headers == nil)
        #expect(auth.baseUrl == nil)
    }
}
