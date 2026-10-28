import Foundation
import Testing
@testable import PiAI

// Port of packages/ai/test/kimi-coding-oauth.test.ts
// `vi.stubGlobal("fetch", ...)`, `vi.stubEnv(...)` and fake timers -> `createKimiCodingOAuth(harness.runtime)`.

private let CLIENT_ID = "17e5f671-d194-4dfb-9706-5516cb48c098"
private let OAUTH_HOST = "https://auth.kimi.com"

private func deviceAuthorizationResponse(_ overrides: JsonObject = JsonObject()) -> FetchResponse {
    var body: JsonObject = [
        "user_code": "ABCD-1234",
        "device_code": "device-code-123",
        "verification_uri": "https://www.kimi.com/code",
        "verification_uri_complete": "https://www.kimi.com/code?user_code=ABCD-1234",
        "interval": 5,
        "expires_in": 600,
    ]
    for (key, value) in overrides.dictionary { body[key] = value }
    return oauthJson(200, JsonValue.object(body).serialized())
}

private func noPrompt() -> OAuthTestInteraction {
    OAuthTestInteraction { _ in throw PiError("Kimi Code login should not prompt") }
}

@Suite struct KimiCodingOAuthTests {
    @Test func logsInWithTheDeviceAuthorizationFlow() async throws {
        let startTime = 1_784_505_600_000 // 2026-07-20T00:00:00Z
        let pollResponses = Locked([
            oauthJson(400, #"{"error":"authorization_pending"}"#),
            oauthJson(200, #"{"access_token":"access-token","refresh_token":"refresh-token","expires_in":3600}"#),
        ])
        let pollTimes = Locked<[Int]>([])
        let h = OAuthTestHarness(now: startTime)
        h.setHandler { [h] call in
            if call.url == "\(OAUTH_HOST)/api/oauth/device_authorization" {
                #expect(call.method == "POST")
                #expect(call.headers.get("Content-Type") == "application/x-www-form-urlencoded")
                #expect(call.headers.get("Accept") == "application/json")
                #expect(call.form.get("client_id") == CLIENT_ID)
                return deviceAuthorizationResponse()
            }
            if call.url == "\(OAUTH_HOST)/api/oauth/token" {
                pollTimes.withLock { $0.append(h.now) }
                let params = call.form
                #expect(params.get("grant_type") == "urn:ietf:params:oauth:grant-type:device_code")
                #expect(params.get("client_id") == CLIENT_ID)
                #expect(params.get("device_code") == "device-code-123")
                guard let response = pollResponses.withLock({ $0.isEmpty ? nil : $0.removeFirst() }) else {
                    throw PiError("Unexpected extra token poll")
                }
                return response
            }
            throw PiError("Unexpected fetch URL: \(call.url)")
        }

        let i = noPrompt()
        let credential = try await createKimiCodingOAuth(h.runtime).login(i.interaction, nil)
        let events = i.events.current
        #expect(events.count == 1)
        guard case .device_code(let userCode, let verificationUri, let intervalSeconds, let expiresInSeconds)? = events.first else {
            Issue.record("expected a device_code event")
            return
        }
        #expect(userCode == "ABCD-1234")
        #expect(verificationUri == "https://www.kimi.com/code?user_code=ABCD-1234")
        #expect(intervalSeconds == 5)
        #expect(expiresInSeconds == 600)

        // waitBeforeFirstPoll: first poll happens after the 5s interval.
        #expect(pollTimes.current == [startTime + 5000, startTime + 10000])
        #expect(credential.access == "access-token")
        #expect(credential.refresh == "refresh-token")
        #expect(credential.expires == startTime + 10000 + 3600 * 1000)
        #expect(credential.extra.isEmpty)
    }

    @Test func failsWhenTheDeviceCodeExpires() async throws {
        let h = OAuthTestHarness { call in
            if call.url == "\(OAUTH_HOST)/api/oauth/device_authorization" { return deviceAuthorizationResponse() }
            if call.url == "\(OAUTH_HOST)/api/oauth/token" { return oauthJson(400, #"{"error":"expired_token"}"#) }
            throw PiError("Unexpected fetch URL: \(call.url)")
        }
        let error = await gCaught { _ = try await createKimiCodingOAuth(h.runtime).login(noPrompt().interaction, nil) }
        #expect(errorMessage(error!).contains("expired"))
    }

    @Test func failsWhenTheUserDeniesTheLogin() async throws {
        let h = OAuthTestHarness { call in
            if call.url == "\(OAUTH_HOST)/api/oauth/device_authorization" { return deviceAuthorizationResponse() }
            if call.url == "\(OAUTH_HOST)/api/oauth/token" { return oauthJson(400, #"{"error":"access_denied"}"#) }
            throw PiError("Unexpected fetch URL: \(call.url)")
        }
        let error = await gCaught { _ = try await createKimiCodingOAuth(h.runtime).login(noPrompt().interaction, nil) }
        #expect(errorMessage(error!).contains("denied"))
    }

    @Test func honorsTheKimiCodeOAuthHostOverride() async throws {
        let h = OAuthTestHarness(env: ["KIMI_CODE_OAUTH_HOST": "https://auth.example.com/"]) { call in
            if call.url == "https://auth.example.com/api/oauth/device_authorization" {
                return deviceAuthorizationResponse(["interval": 1])
            }
            if call.url == "https://auth.example.com/api/oauth/token" {
                return oauthJson(200, #"{"access_token":"a","refresh_token":"r","expires_in":60}"#)
            }
            throw PiError("Unexpected fetch URL: \(call.url)")
        }
        let credential = try await createKimiCodingOAuth(h.runtime).login(noPrompt().interaction, nil)
        #expect(credential.access == "a")
        #expect(credential.refresh == "r")
        #expect(h.urls == [
            "https://auth.example.com/api/oauth/device_authorization",
            "https://auth.example.com/api/oauth/token",
        ])
    }

    @Test func refreshesTokensAndReturnsABearerHeaderForRequests() async throws {
        let h = OAuthTestHarness { call in
            #expect(call.url == "\(OAUTH_HOST)/api/oauth/token")
            let params = call.form
            #expect(params.get("grant_type") == "refresh_token")
            #expect(params.get("refresh_token") == "old-refresh")
            #expect(params.get("client_id") == CLIENT_ID)
            return oauthJson(200, #"{"access_token":"new-access","refresh_token":"new-refresh","expires_in":3600}"#)
        }
        let before = h.now
        let credential = try await createKimiCodingOAuth(h.runtime).refresh(
            OAuthCredential(refresh: "old-refresh", access: "old-access", expires: before),
            AbortController().signal
        )
        #expect(credential.access == "new-access")
        #expect(credential.refresh == "new-refresh")
        #expect(credential.extra.isEmpty)
        #expect(credential.expires >= before + 3600 * 1000)

        let auth = try await kimiCodingOAuth.toAuth(credential)
        #expect(auth.apiKey == nil)
        #expect(gHeaders(auth.headers) == ["Authorization=Bearer new-access"])
    }

    @Test func retriesRefreshOn429AndFailsUnauthorizedOnInvalidGrant() async throws {
        // 429 once, then success.
        let calls = Locked(0)
        let h = OAuthTestHarness { _ in
            let count = calls.withLock { $0 += 1; return $0 }
            if count == 1 { return oauthJson(429, #"{"error":"temporarily_unavailable"}"#) }
            return oauthJson(200, #"{"access_token":"a","refresh_token":"r","expires_in":60}"#)
        }
        let refreshed = try await createKimiCodingOAuth(h.runtime).refresh(
            OAuthCredential(refresh: "old", access: "old", expires: 0),
            AbortController().signal
        )
        #expect(refreshed.access == "a")
        #expect(calls.current == 2)
        #expect(h.sleeps.current == [1000])

        // invalid_grant is not retried.
        h.setHandler { _ in oauthJson(400, #"{"error":"invalid_grant"}"#) }
        let error = await gCaught {
            _ = try await createKimiCodingOAuth(h.runtime).refresh(
                OAuthCredential(refresh: "old", access: "old", expires: 0),
                AbortController().signal
            )
        }
        #expect(errorMessage(error!).contains("unauthorized"))
    }
}
