import Foundation

// Port of packages/ai/src/auth/oauth/xai.ts
// (named `oauth-xai.swift`: SwiftPM forbids two `xai.swift` in one target)

/**
 * xAI OAuth device-code flow.
 */

private let XAI_CLIENT_ID = "b1a00492-073a-47ea-816f-4c329264a828"
private let XAI_SCOPE = "openid profile email offline_access grok-cli:access api:access"
private let XAI_DEVICE_CODE_URL = "https://auth.x.ai/oauth2/device/code"
private let XAI_TOKEN_URL = "https://auth.x.ai/oauth2/token"
// Refresh slightly before the reported expiry to avoid using a token that dies mid-request.
private let REFRESH_SKEW_MS: Double = 5 * 60 * 1000
private let DEFAULT_TOKEN_LIFETIME_SECONDS: Double = 3600

private struct OAuthHttpResponse {
    var ok: Bool
    var status: Int
    var body: JsonObject
}

private struct XaiDeviceCode: Sendable {
    var deviceCode: String
    var userCode: String
    var verificationUri: String
    var verificationUriComplete: String?
    var intervalSeconds: Double?
    var expiresInSeconds: Double
}

private func requiredString(_ body: JsonObject, _ field: String) throws -> String {
    guard case .string(let value)? = body[field], !value.isEmpty else {
        throw PiError("Invalid xAI OAuth response field: \(field)")
    }
    return value
}

private func positiveNumber(_ body: JsonObject, _ field: String) throws -> Double {
    guard case .number(let value)? = body[field], value.isFinite, value > 0 else {
        throw PiError("Invalid xAI OAuth response field: \(field)")
    }
    return value
}

// The verification URI is opened in the user's browser; force it to be an https URL
// so a malicious response cannot make `open` launch something else.
private func validateVerificationUri(_ raw: String) throws -> String {
    guard let url = WebURL(raw) else {
        throw PiError("Untrusted verification URI in xAI OAuth response")
    }
    if url.protocol != "https:" {
        throw PiError("Untrusted verification URI in xAI OAuth response")
    }
    return url.href
}

private func postForm(_ rt: OAuthRuntime, _ url: String, _ fields: [(String, String)], _ signal: AbortSignal) async throws -> OAuthHttpResponse {
    let response: FetchResponse
    do {
        response = try await rt.fetch(
            url,
            method: "POST",
            headers: [
                ("Accept", "application/json"),
                ("Content-Type", "application/x-www-form-urlencoded"),
            ],
            body: URLSearchParams(fields).toString(),
            signal: signal
        )
    } catch {
        if signal.aborted {
            throw PiError("Login cancelled")
        }
        throw error
    }

    let body: JsonObject
    do {
        let parsed = try await response.json()
        body = parsed.objectValue ?? [:]
    } catch {
        if signal.aborted {
            throw PiError("Login cancelled")
        }
        throw PiError("xAI OAuth returned invalid JSON (HTTP \(response.status))")
    }
    return OAuthHttpResponse(
        ok: response.ok,
        status: response.status,
        body: body
    )
}

private func requestFailure(_ action: String, _ response: OAuthHttpResponse) -> PiError {
    let error = response.body["error"]?.stringValue
    let description = response.body["error_description"]?.stringValue
    let detail = [error, description].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: ": ")
    return PiError("xAI OAuth \(action) failed (HTTP \(response.status))\(!detail.isEmpty ? ": \(detail)" : "")")
}

private func parseDeviceCode(_ body: JsonObject) throws -> XaiDeviceCode {
    // RFC 8628 allows interval 0 (no minimum wait); fall back to the poller's
    // default instead of failing on non-positive or malformed values.
    let interval = body["interval"]
    var intervalSeconds: Double?
    if case .number(let value)? = interval, value.isFinite, value > 0 { intervalSeconds = value }
    var verificationUriComplete: String?
    if case .string(let value)? = body["verification_uri_complete"], !value.isEmpty {
        verificationUriComplete = try validateVerificationUri(value)
    }
    return XaiDeviceCode(
        deviceCode: try requiredString(body, "device_code"),
        userCode: try requiredString(body, "user_code"),
        verificationUri: try validateVerificationUri(try requiredString(body, "verification_uri")),
        verificationUriComplete: verificationUriComplete,
        intervalSeconds: intervalSeconds,
        expiresInSeconds: try positiveNumber(body, "expires_in")
    )
}

private func credentialsFromTokenResponse(_ rt: OAuthRuntime, _ body: JsonObject, _ previousRefreshToken: String? = nil) throws -> OAuthCredential {
    let access = try requiredString(body, "access_token")
    // xAI may omit refresh_token on refresh when the token is not rotated.
    let refresh =
        body["refresh_token"] == nil && previousRefreshToken.map({ !$0.isEmpty }) == true
            ? previousRefreshToken!
            : try requiredString(body, "refresh_token")
    let expiresInSeconds =
        body["expires_in"] == nil ? DEFAULT_TOKEN_LIFETIME_SECONDS : try positiveNumber(body, "expires_in")
    return OAuthCredential(
        refresh: refresh,
        access: access,
        expires: jsMillis(Double(rt.now()) + expiresInSeconds * 1000 - REFRESH_SKEW_MS)
    )
}

private func requestDeviceCode(_ rt: OAuthRuntime, _ signal: AbortSignal) async throws -> XaiDeviceCode {
    let response = try await postForm(
        rt,
        XAI_DEVICE_CODE_URL,
        [
            ("client_id", XAI_CLIENT_ID),
            ("scope", XAI_SCOPE),
            ("referrer", "pi"),
        ],
        signal
    )
    if !response.ok {
        throw requestFailure("device authorization", response)
    }
    return try parseDeviceCode(response.body)
}

private func pollForTokens(_ rt: OAuthRuntime, _ device: XaiDeviceCode, _ signal: AbortSignal) async throws -> OAuthCredential {
    try await pollOAuthDeviceCodeFlow(OAuthDeviceCodePollOptions<OAuthCredential>(
        intervalSeconds: device.intervalSeconds,
        expiresInSeconds: device.expiresInSeconds,
        waitBeforeFirstPoll: true,
        poll: {
            let response = try await postForm(
                rt,
                XAI_TOKEN_URL,
                [
                    ("grant_type", "urn:ietf:params:oauth:grant-type:device_code"),
                    ("client_id", XAI_CLIENT_ID),
                    ("device_code", device.deviceCode),
                ],
                signal
            )

            if response.ok {
                return .complete(value: try credentialsFromTokenResponse(rt, response.body))
            }

            let error = response.body["error"]?.stringValue
            if error == "authorization_pending" {
                return .pending
            }
            if error == "slow_down" {
                return .slow_down(intervalSeconds: response.body["interval"]?.doubleValue)
            }
            if error == "access_denied" || error == "authorization_denied" {
                return .failed(message: "xAI device authorization was denied")
            }
            if error == "expired_token" {
                return .failed(message: "xAI device code expired")
            }
            return .failed(message: requestFailure("device token polling", response).message)
        },
        signal: signal
    ), runtime: rt)
}

private func loginXai(_ rt: OAuthRuntime, _ interaction: ProviderAuthInteraction) async throws -> OAuthCredential {
    let device = try await requestDeviceCode(rt, interaction.signal)
    interaction.notify(.device_code(
        userCode: device.userCode,
        verificationUri: device.verificationUriComplete ?? device.verificationUri,
        intervalSeconds: device.intervalSeconds.map(jsMillis),
        expiresInSeconds: jsMillis(device.expiresInSeconds)
    ))
    return try await pollForTokens(rt, device, interaction.signal)
}

private func refreshXaiToken(_ rt: OAuthRuntime, _ refreshToken: String, _ signal: AbortSignal) async throws -> OAuthCredential {
    let response = try await postForm(
        rt,
        XAI_TOKEN_URL,
        [
            ("grant_type", "refresh_token"),
            ("client_id", XAI_CLIENT_ID),
            ("refresh_token", refreshToken),
        ],
        signal
    )
    if !response.ok {
        throw requestFailure("token refresh", response)
    }
    return try credentialsFromTokenResponse(rt, response.body, refreshToken)
}

func createXaiOAuth(_ rt: OAuthRuntime = .live) -> OAuthAuth {
    OAuthAuth(
        name: "xAI (Grok/X subscription)",
        isSubscription: true,
        loginLabel: "Sign in with SuperGrok or X Premium",
        login: { interaction, _ in try await loginXai(rt, interaction) },
        refresh: { credential, signal in try await refreshXaiToken(rt, credential.refresh, signal) },

        toAuth: { credential in
            ModelAuth(apiKey: credential.access)
        }
    )
}

public let xaiOAuth: OAuthAuth = createXaiOAuth()
