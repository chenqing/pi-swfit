import Foundation

// Port of packages/ai/src/auth/oauth/meta.ts
// (named `oauth-meta.swift`: SwiftPM forbids two `meta.swift` in one target)

/**
 * Meta Model API OAuth flow
 *
 * RFC 8628 device authorization grant against https://auth.meta.com (JSON
 * responses). Meta splits identity from API access: the resulting identity
 * token is not accepted for inference, so it is exchanged for a Model API
 * key via the Muse Code key-mint endpoint (minted keys live about a day).
 * The identity token is stored as `refresh` and the minted key as `access`,
 * so the standard OAuth scheduler re-mints the key when it expires with no
 * bespoke renewal machinery. The identity token itself is not renewable
 * (auth.meta.com answers grant_type=refresh_token with 404 and issues no
 * refresh_token), so a 401/403 from mint means the session is dead and the
 * user must sign in again.
 */

// Muse Code CLI client id.
private let CLIENT_ID = "1031625952748946"
private let AUTH_HOST = "https://auth.meta.com"
private let DEVICE_AUTHORIZATION_URL = "\(AUTH_HOST)/oidc/device/authorization/"
private let DEVICE_TOKEN_URL = "\(AUTH_HOST)/oidc/device/token/"
private let API_KEY_MINT_URL = "https://api.meta.ai/muse-code/key"
private let API_KEY_LIFETIME_MS = 24 * 60 * 60 * 1000
private let REQUEST_TIMEOUT_MS = 30 * 1000

private struct DeviceAuthorization: Sendable {
    var deviceCode: String
    var userCode: String
    var verificationUri: String
    var intervalSeconds: Double?
    var expiresInSeconds: Double?
}

private func requestSignal(_ signal: AbortSignal) -> AbortSignal {
    AbortSignal.any([AbortSignal.timeout(REQUEST_TIMEOUT_MS), signal])
}

/// An object or array body (`json && typeof json === "object"`), else nil.
private func readJson(_ response: FetchResponse) async -> JsonValue? {
    guard let json = try? await response.json() else { return nil }
    switch json {
    case .object, .array: return json
    default: return nil
    }
}

private func errorDetail(_ json: JsonValue?) -> String {
    for key in ["error_description", "detail", "message", "error"] {
        let value = json?[key]
        if case .string(let string)? = value {
            let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { return ": \(trimmed)" }
        }
    }
    return ""
}

/// The verification URI is opened in the user's browser; only http(s) URLs are trusted.
private func trustedHttpUrl(_ value: JsonValue?) -> String? {
    guard case .string(let string)? = value, !string.isEmpty else { return nil }
    guard let url = WebURL(string) else { return nil }
    if url.protocol != "https:" && url.protocol != "http:" { return nil }
    return url.href
}

private func positiveNumber(_ value: JsonValue?) -> Double? {
    if case .number(let number)? = value, number.isFinite, number > 0 { return number }
    return nil
}

private func startDeviceAuthorization(_ rt: OAuthRuntime, _ signal: AbortSignal) async throws -> DeviceAuthorization {
    let response = try await rt.fetch(
        DEVICE_AUTHORIZATION_URL,
        method: "POST",
        headers: [
            ("Content-Type", "application/x-www-form-urlencoded"),
            ("Accept", "application/json"),
        ],
        body: URLSearchParams([("client_id", CLIENT_ID)]).toString(),
        signal: requestSignal(signal)
    )
    let json = await readJson(response)
    if !response.ok {
        throw PiError("Meta device authorization failed with status \(response.status)\(errorDetail(json))")
    }
    let deviceCode = json?["device_code"]?.stringValue
    let userCode = json?["user_code"]?.stringValue
    let verificationUri = trustedHttpUrl(json?["verification_uri_complete"]) ?? trustedHttpUrl(json?["verification_uri"])
    guard let deviceCode, !deviceCode.isEmpty, let userCode, !userCode.isEmpty, let verificationUri else {
        throw PiError("Invalid Meta device authorization response: \(json?.serialized() ?? "null")")
    }
    return DeviceAuthorization(
        deviceCode: deviceCode,
        userCode: userCode,
        verificationUri: verificationUri,
        intervalSeconds: positiveNumber(json?["interval"]),
        expiresInSeconds: positiveNumber(json?["expires_in"])
    )
}

private func pollForIdentityToken(_ rt: OAuthRuntime, _ device: DeviceAuthorization, _ signal: AbortSignal) async throws -> String {
    try await pollOAuthDeviceCodeFlow(OAuthDeviceCodePollOptions<String>(
        intervalSeconds: device.intervalSeconds,
        expiresInSeconds: device.expiresInSeconds,
        waitBeforeFirstPoll: true,
        poll: {
            let response = try await rt.fetch(
                DEVICE_TOKEN_URL,
                method: "POST",
                headers: [
                    ("Content-Type", "application/x-www-form-urlencoded"),
                    ("Accept", "application/json"),
                ],
                body: URLSearchParams([
                    ("grant_type", "urn:ietf:params:oauth:grant-type:device_code"),
                    ("device_code", device.deviceCode),
                    ("client_id", CLIENT_ID),
                ]).toString(),
                signal: requestSignal(signal)
            )
            let json = await readJson(response)
            if response.ok, case .string(let accessToken)? = json?["access_token"], !accessToken.isEmpty {
                return .complete(value: accessToken)
            }
            switch json?["error"]?.stringValue {
            case "authorization_pending":
                return .pending
            case "slow_down":
                return .slow_down(intervalSeconds: positiveNumber(json?["interval"]))
            case "access_denied":
                return .failed(message: "Meta login was denied.")
            case "expired_token":
                return .failed(message: "Meta device authorization expired. Please restart login.")
            default:
                return .failed(
                    message: "Meta device token request failed with status \(response.status)\(errorDetail(json))"
                )
            }
        },
        signal: signal
    ), runtime: rt)
}

/// Exchange an identity token for a Model API key. Keys are valid for about a day.
private func mintApiKey(_ rt: OAuthRuntime, _ identityToken: String, _ signal: AbortSignal) async throws -> OAuthCredential {
    let response = try await rt.fetch(
        API_KEY_MINT_URL,
        method: "POST",
        headers: [
            ("Accept", "application/json"),
            ("Authorization", "Bearer \(identityToken)"),
            ("Content-Type", "application/json"),
            ("x-api-version", "1.0.0"),
        ],
        body: "{}",
        signal: requestSignal(signal)
    )
    let json = await readJson(response)
    if response.status == 401 || response.status == 403 {
        // Identity token is not renewable (see file header); only a fresh device flow helps.
        throw PiError(
            "Meta session expired (status \(response.status)). Run `/login meta` to sign in again.\(errorDetail(json))"
        )
    }
    if !response.ok {
        throw PiError("Meta API key mint failed with status \(response.status)\(errorDetail(json))")
    }
    guard case .string(let apiKey)? = json?["api_key"], !apiKey.isEmpty else {
        let actionUrl = trustedHttpUrl(json?["action_url"])
        throw PiError("Meta did not issue an API key.\(actionUrl.map { " Complete setup at \($0)" } ?? "")")
    }
    return OAuthCredential(refresh: identityToken, access: apiKey, expires: rt.now() + API_KEY_LIFETIME_MS)
}

private func loginMeta(_ rt: OAuthRuntime, _ interaction: ProviderAuthInteraction) async throws -> OAuthCredential {
    do {
        let device = try await startDeviceAuthorization(rt, interaction.signal)
        interaction.notify(.device_code(
            userCode: device.userCode,
            verificationUri: device.verificationUri,
            intervalSeconds: device.intervalSeconds.map(jsMillis),
            expiresInSeconds: device.expiresInSeconds.map(jsMillis)
        ))
        let identityToken = try await pollForIdentityToken(rt, device, interaction.signal)
        interaction.notify(.progress(message: "Enabling Meta Model API access..."))
        return try await mintApiKey(rt, identityToken, interaction.signal)
    } catch {
        // An in-flight fetch rejects with a DOMException on abort; the login UI matches on this message.
        if interaction.signal.aborted { throw PiError("Login cancelled") }
        throw error
    }
}

func createMetaOAuth(_ rt: OAuthRuntime = .live) -> OAuthAuth {
    OAuthAuth(
        name: "Meta (Muse subscription)",
        isSubscription: true,
        loginLabel: "Sign in with Meta",

        login: { interaction, _ in try await loginMeta(rt, interaction) },

        refresh: { credential, signal in try await mintApiKey(rt, credential.refresh, signal) },

        toAuth: { credential in
            ModelAuth(apiKey: credential.access)
        }
    )
}

public let metaOAuth: OAuthAuth = createMetaOAuth()
