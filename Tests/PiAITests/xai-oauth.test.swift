import Foundation
import Testing
@testable import PiAI

// Port of packages/ai/test/xai-oauth.test.ts
// `vi.stubGlobal("fetch", ...)` + fake timers -> `createXaiOAuth(harness.runtime)` with a virtual clock;
// poll times are read from the clock when each token request arrives.

private let CLIENT_ID = "b1a00492-073a-47ea-816f-4c329264a828"
private let DEVICE_CODE_URL = "https://auth.x.ai/oauth2/device/code"
private let TOKEN_URL = "https://auth.x.ai/oauth2/token"
private let START_TIME = 1_783_627_200_000 // 2026-07-09T20:00:00Z

private func deviceCodeResponse(_ overrides: JsonObject = JsonObject()) -> FetchResponse {
    var body: JsonObject = [
        "device_code": "device-code",
        "user_code": "ABCD-1234",
        "verification_uri": "https://accounts.x.ai/oauth2/device",
        "expires_in": 900,
        "interval": 5,
    ]
    for (key, value) in overrides.dictionary { body[key] = value }
    return oauthJson(200, JsonValue.object(body).serialized())
}

/// `removing` drops fields (`{ field: undefined }` upstream).
private func tokenResponse(_ overrides: JsonObject = JsonObject(), removing: [String] = []) -> FetchResponse {
    var body: JsonObject = [
        "access_token": "access-token",
        "refresh_token": "refresh-token",
        "expires_in": 21_600,
        "token_type": "Bearer",
    ]
    for (key, value) in overrides.dictionary { body[key] = value }
    for key in removing { body[key] = Optional<JsonValue>.none }
    return oauthJson(200, JsonValue.object(body).serialized())
}

private struct DeviceCodeInfo: Equatable {
    var userCode: String
    var verificationUri: String
    var intervalSeconds: Int?
    var expiresInSeconds: Int?
}

private func loginXaiForTest(
    _ h: OAuthTestHarness,
    signal: AbortSignal = AbortController().signal,
    onDeviceCode: @escaping @Sendable (DeviceCodeInfo) -> Void = { _ in }
) async throws -> OAuthCredential {
    try await createXaiOAuth(h.runtime).login(ProviderAuthInteraction(
        signal: signal,
        prompt: { _ in throw PiError("Unexpected prompt") },
        notify: { event in
            if case .device_code(let userCode, let verificationUri, let intervalSeconds, let expiresInSeconds) = event {
                onDeviceCode(DeviceCodeInfo(userCode: userCode, verificationUri: verificationUri, intervalSeconds: intervalSeconds, expiresInSeconds: expiresInSeconds))
            }
        }
    ), nil)
}

private func refreshXaiForTest(_ h: OAuthTestHarness, _ refreshToken: String) async throws -> OAuthCredential {
    try await createXaiOAuth(h.runtime).refresh(
        OAuthCredential(refresh: refreshToken, access: "old-access", expires: 0),
        AbortController().signal
    )
}

@Suite struct XaiOAuthDeviceFlowTests {
    @Test func usesTheDeviceGrantDelaysPollingAndHandlesPendingAndSlowDown() async throws {
        let pollTimes = Locked<[Int]>([])
        let tokenReplies = Locked([
            oauthJson(400, #"{"error":"authorization_pending"}"#),
            oauthJson(400, #"{"error":"slow_down","interval":10}"#),
            tokenResponse(),
        ])
        let h = OAuthTestHarness(now: START_TIME)
        h.setHandler { [h] call in
            if call.url == DEVICE_CODE_URL {
                let form = call.form
                #expect(form.get("client_id") == CLIENT_ID)
                #expect(form.get("scope") == "openid profile email offline_access grok-cli:access api:access")
                #expect(form.get("referrer") == "pi")
                return deviceCodeResponse()
            }
            if call.url == TOKEN_URL {
                pollTimes.withLock { $0.append(h.now) }
                let form = call.form
                #expect(form.get("grant_type") == "urn:ietf:params:oauth:grant-type:device_code")
                #expect(form.get("client_id") == CLIENT_ID)
                #expect(form.get("device_code") == "device-code")
                guard let reply = tokenReplies.withLock({ $0.isEmpty ? nil : $0.removeFirst() }) else { throw PiError("Unexpected token poll") }
                return reply
            }
            throw PiError("Unexpected request: \(call.url)")
        }

        let deviceCodes = Locked<[DeviceCodeInfo]>([])
        let credentials = try await loginXaiForTest(h) { info in deviceCodes.withLock { $0.append(info) } }
        #expect(deviceCodes.current == [
            DeviceCodeInfo(userCode: "ABCD-1234", verificationUri: "https://accounts.x.ai/oauth2/device", intervalSeconds: 5, expiresInSeconds: 900),
        ])
        // slow_down raised the interval to 10 seconds
        #expect(pollTimes.current == [START_TIME + 5000, START_TIME + 10_000, START_TIME + 20_000])
        #expect(credentials.access == "access-token")
        #expect(credentials.refresh == "refresh-token")
        #expect(credentials.expires == START_TIME + 20_000 + 21_600_000 - 300_000)
        #expect(credentials.extra.isEmpty)
    }

    @Test func fallsBackToTheDefaultPollIntervalWhenTheResponseReportsInterval0() async throws {
        let pollTimes = Locked<[Int]>([])
        let h = OAuthTestHarness(now: START_TIME)
        h.setHandler { [h] call in
            if call.url == DEVICE_CODE_URL { return deviceCodeResponse(["interval": 0]) }
            pollTimes.withLock { $0.append(h.now) }
            return tokenResponse()
        }
        _ = try await loginXaiForTest(h)
        // RFC 8628 default interval is 5 seconds when the server does not require a wait.
        #expect(pollTimes.current == [START_TIME + 5000])
    }

    @Test func prefersVerificationUriCompleteWhenTheServerProvidesIt() async throws {
        let h = OAuthTestHarness { call in
            if call.url == DEVICE_CODE_URL {
                return deviceCodeResponse(["verification_uri_complete": "https://accounts.x.ai/oauth2/device?user_code=ABCD-1234"])
            }
            return tokenResponse()
        }
        let deviceCodes = Locked<[DeviceCodeInfo]>([])
        _ = try await loginXaiForTest(h) { info in deviceCodes.withLock { $0.append(info) } }
        #expect(deviceCodes.current == [
            DeviceCodeInfo(userCode: "ABCD-1234", verificationUri: "https://accounts.x.ai/oauth2/device?user_code=ABCD-1234", intervalSeconds: 5, expiresInSeconds: 900),
        ])
    }

    @Test func rejectsANonHttpsVerificationUriComplete() async throws {
        let h = OAuthTestHarness { _ in
            deviceCodeResponse(["verification_uri_complete": "http://accounts.x.ai/oauth2/device?user_code=ABCD-1234"])
        }
        let error = await gCaught { _ = try await loginXaiForTest(h) }
        #expect(errorMessage(error!).contains("Untrusted verification URI"))
    }

    @Test(arguments: ["http://accounts.x.ai/oauth2/device", "file:///etc/passwd", "not a url"])
    func rejectsANonHttpsVerificationUri(_ verificationUri: String) async throws {
        let h = OAuthTestHarness { _ in deviceCodeResponse(["verification_uri": .string(verificationUri)]) }
        let error = await gCaught { _ = try await loginXaiForTest(h) }
        #expect(errorMessage(error!).contains("Untrusted verification URI"))
    }

    @Test(arguments: ["access_denied", "authorization_denied"])
    func failsWhenDeviceAuthorizationIsDenied(_ errorCode: String) async throws {
        let requestCount = Locked(0)
        let h = OAuthTestHarness { _ in
            let count = requestCount.withLock { $0 += 1; return $0 }
            return count == 1
                ? deviceCodeResponse(["interval": 1])
                : oauthJson(400, JsonValue.object(["error": .string(errorCode)]).serialized())
        }
        let error = await gCaught { _ = try await loginXaiForTest(h) }
        #expect(errorMessage(error!) == "xAI device authorization was denied")
    }

    @Test func cancelsWhileWaitingForTheFirstTokenPoll() async throws {
        let controller = AbortController()
        let h = OAuthTestHarness { _ in deviceCodeResponse() }
        let error = await gCaught {
            _ = try await loginXaiForTest(h, signal: controller.signal) { _ in controller.abort() }
        }
        #expect(errorMessage(error!) == "Login cancelled")
        #expect(h.calls.current.count == 1)
    }

    @Test func refreshesTokensAndPreservesAnUnrotatedRefreshToken() async throws {
        let requestCount = Locked(0)
        let h = OAuthTestHarness { call in
            #expect(call.url == TOKEN_URL)
            let form = call.form
            #expect(form.get("grant_type") == "refresh_token")
            #expect(form.get("client_id") == CLIENT_ID)
            let count = requestCount.withLock { $0 += 1; return $0 }
            if count == 1 {
                #expect(form.get("refresh_token") == "old-refresh")
                return tokenResponse(["access_token": "new-access", "refresh_token": "new-refresh"])
            }
            #expect(form.get("refresh_token") == "keep-refresh")
            return tokenResponse(["access_token": "newer-access"], removing: ["refresh_token"])
        }

        let rotated = try await refreshXaiForTest(h, "old-refresh")
        let preserved = try await refreshXaiForTest(h, "keep-refresh")
        #expect(rotated.refresh == "new-refresh")
        #expect(rotated.access == "new-access")
        #expect(preserved.refresh == "keep-refresh")
        #expect(preserved.access == "newer-access")
        #expect(xaiOAuth.name == "xAI (Grok/X subscription)")
        let auth = try await xaiOAuth.toAuth(preserved)
        #expect(auth.apiKey == "newer-access")
        #expect(auth.headers == nil)
        #expect(auth.baseUrl == nil)
    }

    @Test func assumesAOneHourLifetimeWhenExpiresInIsMissing() async throws {
        let h = OAuthTestHarness(now: START_TIME) { _ in tokenResponse(removing: ["expires_in"]) }
        let credentials = try await refreshXaiForTest(h, "old-refresh")
        #expect(credentials.expires == START_TIME + 3_600_000 - 300_000)
    }

    @Test func rejectsTokenResponsesWithMissingFields() async throws {
        let h = OAuthTestHarness { _ in tokenResponse(removing: ["access_token"]) }
        let error = await gCaught { _ = try await refreshXaiForTest(h, "old-refresh") }
        #expect(errorMessage(error!) == "Invalid xAI OAuth response field: access_token")
    }

    @Test func surfacesTheUpstreamErrorCodeAndDescriptionOnRefreshFailure() async throws {
        let h = OAuthTestHarness { _ in
            oauthJson(400, #"{"error":"invalid_grant","error_description":"refresh token revoked"}"#)
        }
        let error = await gCaught { _ = try await refreshXaiForTest(h, "old-refresh") }
        #expect(errorMessage(error!) == "xAI OAuth token refresh failed (HTTP 400): invalid_grant: refresh token revoked")
    }
}
