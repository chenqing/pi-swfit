import Foundation

// Port of packages/ai/src/auth/oauth/kimi-coding.ts
// (named `oauth-kimi-coding.swift`: SwiftPM forbids two `kimi-coding.swift` in one target)

/**
 * Kimi Code (subscription) OAuth flow
 *
 * RFC 8628 device authorization grant against https://auth.kimi.com with JSON
 * responses. The access token authenticates requests to
 * https://api.kimi.com/coding as an `Authorization: Bearer` header.
 */

private let CLIENT_ID = "17e5f671-d194-4dfb-9706-5516cb48c098"
private let DEFAULT_OAUTH_HOST = "https://auth.kimi.com"
private let DEVICE_CODE_TIMEOUT_SECONDS: Double = 15 * 60
private let DEFAULT_POLL_INTERVAL_SECONDS: Double = 5
private let REQUEST_TIMEOUT_MS = 30 * 1000
private let REFRESH_MAX_RETRIES = 3

private struct DeviceAuthorization: Sendable {
    var deviceCode: String
    var userCode: String
    var verificationUri: String
    var verificationUriComplete: String
    var intervalSeconds: Double
    var expiresInSeconds: Double
}

private struct TokenResponse: Sendable {
    var access: String
    var refresh: String
    var expires: Int
}

private func getOauthHost(_ rt: OAuthRuntime) -> String {
    let override = rt.env("KIMI_CODE_OAUTH_HOST") ?? rt.env("KIMI_OAUTH_HOST")
    var host = override ?? DEFAULT_OAUTH_HOST
    while host.hasSuffix("/") { host.removeLast() }
    return host
}

private func requestSignal(_ signal: AbortSignal) -> AbortSignal {
    AbortSignal.any([AbortSignal.timeout(REQUEST_TIMEOUT_MS), signal])
}

private func formUrlEncode(_ fields: [(String, String)]) -> String {
    URLSearchParams(fields).toString()
}

/// An object or array body (`json && typeof json === "object"`), else nil.
private func readJson(_ response: FetchResponse) async -> JsonValue? {
    guard let json = try? await response.json() else { return nil }
    switch json {
    case .object, .array: return json
    default: return nil
    }
}

/// The verification URI is opened in the user's browser; only http(s) URLs are trusted.
private func trustedHttpUrl(_ value: String) -> String? {
    if value.isEmpty { return nil }
    guard let url = WebURL(value) else { return nil }
    if url.protocol != "https:" && url.protocol != "http:" { return nil }
    return url.href
}

private func stringify(_ json: JsonValue?) -> String { json?.serialized() ?? "null" }

private func startDeviceAuthorization(_ rt: OAuthRuntime, _ oauthHost: String, _ signal: AbortSignal) async throws -> DeviceAuthorization {
    let response = try await rt.fetch(
        "\(oauthHost)/api/oauth/device_authorization",
        method: "POST",
        headers: [
            ("Content-Type", "application/x-www-form-urlencoded"),
            ("Accept", "application/json"),
        ],
        body: formUrlEncode([("client_id", CLIENT_ID)]),
        signal: requestSignal(signal)
    )

    if !response.ok {
        let text = (try? await response.text()) ?? ""
        throw PiError("Kimi Code device authorization failed with status \(response.status)\(!text.isEmpty ? ": \(text)" : "")")
    }

    let json = await readJson(response)
    guard
        let deviceCode = json?["device_code"]?.stringValue,
        let userCode = json?["user_code"]?.stringValue,
        let rawUri = json?["verification_uri"]?.stringValue,
        let rawComplete = json?["verification_uri_complete"]?.stringValue,
        let verificationUri = trustedHttpUrl(rawUri),
        let verificationUriComplete = trustedHttpUrl(rawComplete)
    else {
        throw PiError("Invalid Kimi Code device authorization response: \(stringify(json))")
    }

    var intervalSeconds = DEFAULT_POLL_INTERVAL_SECONDS
    if case .number(let interval)? = json?["interval"], interval.isFinite, interval > 0 { intervalSeconds = interval }
    var expiresInSeconds = DEVICE_CODE_TIMEOUT_SECONDS
    if case .number(let expiresIn)? = json?["expires_in"], expiresIn.isFinite, expiresIn > 0 { expiresInSeconds = expiresIn }
    return DeviceAuthorization(
        deviceCode: deviceCode,
        userCode: userCode,
        verificationUri: verificationUri,
        verificationUriComplete: verificationUriComplete,
        intervalSeconds: intervalSeconds,
        expiresInSeconds: expiresInSeconds
    )
}

private func parseTokenResponse(_ rt: OAuthRuntime, _ json: JsonValue?, _ operation: String) throws -> TokenResponse {
    guard
        case .string(let accessToken)? = json?["access_token"], !accessToken.isEmpty,
        case .string(let refreshToken)? = json?["refresh_token"], !refreshToken.isEmpty,
        case .number(let expiresIn)? = json?["expires_in"], expiresIn.isFinite, expiresIn > 0
    else {
        throw PiError("Kimi Code token \(operation) response missing fields: \(stringify(json))")
    }
    return TokenResponse(
        access: accessToken,
        refresh: refreshToken,
        expires: jsMillis(Double(rt.now()) + expiresIn * 1000)
    )
}

private func pollForToken(
    _ rt: OAuthRuntime,
    _ oauthHost: String,
    _ device: DeviceAuthorization,
    _ signal: AbortSignal
) async throws -> TokenResponse {
    try await pollOAuthDeviceCodeFlow(OAuthDeviceCodePollOptions<TokenResponse>(
        intervalSeconds: device.intervalSeconds,
        expiresInSeconds: device.expiresInSeconds,
        waitBeforeFirstPoll: true,
        poll: {
            let response = try await rt.fetch(
                "\(oauthHost)/api/oauth/token",
                method: "POST",
                headers: [
                    ("Content-Type", "application/x-www-form-urlencoded"),
                    ("Accept", "application/json"),
                ],
                body: formUrlEncode([
                    ("client_id", CLIENT_ID),
                    ("device_code", device.deviceCode),
                    ("grant_type", "urn:ietf:params:oauth:grant-type:device_code"),
                ]),
                signal: requestSignal(signal)
            )

            if response.status >= 500 {
                let text = (try? await response.text()) ?? ""
                return .failed(
                    message: "Kimi Code device token request failed with status \(response.status)\(!text.isEmpty ? ": \(text)" : "")"
                )
            }

            let json = await readJson(response)
            if response.ok, json?["access_token"]?.stringValue != nil {
                do {
                    return .complete(value: try parseTokenResponse(rt, json, "poll"))
                } catch {
                    return .failed(message: errorMessage(error))
                }
            }

            let error = json?["error"]?.stringValue
            let description = json?["error_description"]?.stringValue.map { ": \($0)" } ?? ""
            if error == "authorization_pending" {
                return .pending
            }
            if error == "slow_down" {
                var intervalSeconds: Double?
                if case .number(let interval)? = json?["interval"], interval > 0 { intervalSeconds = interval }
                return .slow_down(intervalSeconds: intervalSeconds)
            }
            if error == "expired_token" {
                return .failed(message: "Kimi Code device authorization expired. Please restart login.")
            }
            if error == "access_denied" {
                return .failed(message: "Kimi Code login was denied.")
            }
            return .failed(
                message: "Kimi Code device token request failed (status \(response.status))\(error.map { ": \($0)\(description)" } ?? "")"
            )
        },
        signal: signal
    ), runtime: rt)
}

private func isRetryableRefreshFailure(_ response: FetchResponse) -> Bool {
    response.status == 429 || response.status >= 500
}

private func refreshToken(_ rt: OAuthRuntime, _ oauthHost: String, _ refreshTokenValue: String, _ signal: AbortSignal) async throws -> TokenResponse {
    var lastError: (any Error)?
    for attempt in 0...REFRESH_MAX_RETRIES {
        if attempt > 0 {
            try await rt.sleep(1000 * (1 << (attempt - 1)), signal)
        }
        if signal.aborted {
            throw PiError("Kimi Code token refresh aborted")
        }

        let response: FetchResponse
        do {
            response = try await rt.fetch(
                "\(oauthHost)/api/oauth/token",
                method: "POST",
                headers: [
                    ("Content-Type", "application/x-www-form-urlencoded"),
                    ("Accept", "application/json"),
                ],
                body: formUrlEncode([
                    ("client_id", CLIENT_ID),
                    ("grant_type", "refresh_token"),
                    ("refresh_token", refreshTokenValue),
                ]),
                signal: requestSignal(signal)
            )
        } catch {
            lastError = error
            continue
        }

        let json = await readJson(response)
        if response.ok {
            return try parseTokenResponse(rt, json, "refresh")
        }

        // Unauthorized: the stored credential is dead; Models clears it and prompts re-login.
        if response.status == 401 || response.status == 403 || json?["error"]?.stringValue == "invalid_grant" {
            let description = json?["error_description"]?.stringValue.map { ": \($0)" } ?? ""
            throw PiError("Kimi Code token refresh unauthorized (status \(response.status))\(description)")
        }

        if isRetryableRefreshFailure(response) && attempt < REFRESH_MAX_RETRIES {
            lastError = PiError("Kimi Code token refresh failed with status \(response.status)")
            continue
        }

        let text = stringify(json)
        throw PiError("Kimi Code token refresh failed with status \(response.status)\(!text.isEmpty ? ": \(text)" : "")")
    }

    throw lastError ?? PiError("Kimi Code token refresh failed")
}

private func loginKimiCoding(_ rt: OAuthRuntime, _ interaction: ProviderAuthInteraction) async throws -> OAuthCredential {
    let oauthHost = getOauthHost(rt)
    let device = try await startDeviceAuthorization(rt, oauthHost, interaction.signal)
    interaction.notify(.device_code(
        userCode: device.userCode,
        verificationUri: device.verificationUriComplete,
        intervalSeconds: jsMillis(device.intervalSeconds),
        expiresInSeconds: jsMillis(device.expiresInSeconds)
    ))
    let token = try await pollForToken(rt, oauthHost, device, interaction.signal)
    return OAuthCredential(refresh: token.refresh, access: token.access, expires: token.expires)
}

func createKimiCodingOAuth(_ rt: OAuthRuntime = .live) -> OAuthAuth {
    OAuthAuth(
        name: "Kimi Code (subscription)",
        isSubscription: true,
        loginLabel: "Sign in with Kimi Code",

        login: { interaction, _ in try await loginKimiCoding(rt, interaction) },

        refresh: { credential, signal in
            let token = try await refreshToken(rt, getOauthHost(rt), credential.refresh, signal)
            return OAuthCredential(refresh: token.refresh, access: token.access, expires: token.expires)
        },

        toAuth: { credential in
            ModelAuth(headers: [("Authorization", "Bearer \(credential.access)")])
        }
    )
}

public let kimiCodingOAuth: OAuthAuth = createKimiCodingOAuth()
