import Foundation

// Port of packages/ai/src/auth/oauth/github-copilot.ts
// (named `oauth-github-copilot.swift`: SwiftPM forbids two `github-copilot.swift` in one target)

/**
 * GitHub Copilot OAuth flow
 */

private func decode(_ value: String) -> String { String(decoding: Data(base64Encoded: value) ?? Data(), as: UTF8.self) }
private let CLIENT_ID = decode("SXYxLmI1MDdhMDhjODdlY2ZlOTg=")

private let COPILOT_HEADERS: [(String, String)] = [
    ("User-Agent", "GitHubCopilotChat/0.35.0"),
    ("Editor-Version", "vscode/1.107.0"),
    ("Editor-Plugin-Version", "copilot-chat/0.35.0"),
    ("Copilot-Integration-Id", "vscode-chat"),
]
private let COPILOT_API_VERSION = "2026-06-01"

private struct DeviceCodeResponse: Sendable {
    var device_code: String
    var user_code: String
    var verification_uri: String
    var interval: Double?
    var expires_in: Double
}

private struct CopilotRetryPolicy: Sendable {
    var maxRetries: Int
    var maxElapsedMs: Int
}

private func normalizeDomain(_ input: String) -> String? {
    let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
    if trimmed.isEmpty { return nil }
    let url = trimmed.contains("://") ? WebURL(trimmed) : WebURL("https://\(trimmed)")
    return url?.hostname
}

private func getUrls(_ domain: String) -> (deviceCodeUrl: String, accessTokenUrl: String, copilotTokenUrl: String) {
    (
        deviceCodeUrl: "https://\(domain)/login/device/code",
        accessTokenUrl: "https://\(domain)/login/oauth/access_token",
        copilotTokenUrl: "https://api.\(domain)/copilot_internal/v2/token"
    )
}

/**
 * Parse the proxy-ep from a Copilot token and convert to API base URL.
 * Token format: tid=...;exp=...;proxy-ep=proxy.individual.githubcopilot.com;...
 * Returns API URL like https://api.individual.githubcopilot.com
 */
private func getBaseUrlFromToken(_ token: String) -> String? {
    guard let range = token.range(of: "proxy-ep=") else { return nil }
    let proxyHost = String(token[range.upperBound...].prefix { $0 != ";" })
    if proxyHost.isEmpty { return nil }
    // Convert proxy.xxx to api.xxx
    let apiHost = proxyHost.hasPrefix("proxy.") ? "api." + proxyHost.dropFirst("proxy.".count) : proxyHost
    return "https://\(apiHost)"
}

private func getGitHubCopilotBaseUrl(_ token: String?, _ enterpriseDomain: String?) -> String {
    // If we have a token, extract the base URL from proxy-ep
    if let token, !token.isEmpty {
        if let urlFromToken = getBaseUrlFromToken(token) { return urlFromToken }
    }
    // Fallback for enterprise or if token parsing fails
    if let enterpriseDomain, !enterpriseDomain.isEmpty { return "https://copilot-api.\(enterpriseDomain)" }
    return "https://api.individual.githubcopilot.com"
}

/// `value && typeof value === "object"`: objects and arrays; arrays have no named fields.
private func asRecord(_ value: JsonValue?) -> JsonObject? {
    switch value {
    case .object(let object)?: return object
    case .array?: return JsonObject()
    default: return nil
    }
}

private func parseGitHubCopilotModelCatalog(
    _ raw: JsonValue,
    _ allowPolicyFallback: Bool,
    _ knownModelIds: Set<String>
) throws -> (availableModelIds: [String], policyModelIds: [String]) {
    guard case .array(let data)? = asRecord(raw)?["data"] else {
        throw PiError("Invalid Copilot models response")
    }

    let accountModels: [(id: String, pickerEnabled: Bool, policyState: JsonValue?)] = data.flatMap { rawItem -> [(id: String, pickerEnabled: Bool, policyState: JsonValue?)] in
        let item = asRecord(rawItem)
        guard let item, case .string(let id)? = item["id"] else { return [] }

        let capabilities = asRecord(item["capabilities"])
        let supports = asRecord(capabilities?["supports"])
        if supports?["tool_calls"] == .bool(false) { return [] }

        return [
            (
                id: id,
                pickerEnabled: item["model_picker_enabled"] == .bool(true),
                policyState: asRecord(item["policy"])?["state"]
            ),
        ]
    }
    let pickerModelIds = accountModels
        .filter { $0.pickerEnabled && $0.policyState != .string("disabled") }
        .map(\.id)
    let usePolicyFallback = allowPolicyFallback && pickerModelIds.isEmpty
    let availableModelIds =
        !pickerModelIds.isEmpty || !allowPolicyFallback
            ? pickerModelIds
            : accountModels.filter { $0.policyState == .string("enabled") }.map(\.id)
    let policyModelIds = accountModels
        .filter { model in
            model.policyState == .string("unconfigured") &&
                knownModelIds.contains(model.id) &&
                (model.pickerEnabled || usePolicyFallback)
        }
        .map(\.id)
    return (availableModelIds, policyModelIds)
}

private func fetchWithRateLimitRetry(
    _ rt: OAuthRuntime,
    _ url: String,
    method: String = "GET",
    headers: [(String, String)],
    body: String? = nil,
    _ signal: AbortSignal,
    _ retryPolicy: CopilotRetryPolicy
) async throws -> FetchResponse {
    let retryBudgetSignal =
        retryPolicy.maxRetries > 0 && retryPolicy.maxElapsedMs > 0
            ? AbortSignal.timeout(retryPolicy.maxElapsedMs)
            : nil
    let requestSignal = retryBudgetSignal.map { AbortSignal.any([signal, $0]) } ?? signal
    let retryDeadline = retryBudgetSignal != nil ? rt.now() + retryPolicy.maxElapsedMs : nil
    var retry = 0
    while true {
        defer { retry += 1 }
        let response = try await rt.fetch(
            url,
            method: method,
            headers: headers,
            body: body,
            signal: AbortSignal.any([requestSignal, AbortSignal.timeout(5000)])
        )
        if response.status != 429 || retry == retryPolicy.maxRetries { return response }

        let retryAfter = response.headers.get("retry-after")
        var delayMs = 500 * pow(2, Double(retry))
        if let retryAfter, !retryAfter.isEmpty {
            let seconds = jsParseFloat(retryAfter)
            delayMs = seconds.isNaN ? jsDateParse(retryAfter) - Double(rt.now()) : seconds * 1000
            if !delayMs.isFinite { return response }
        }
        delayMs = max(0, delayMs)
        if let retryDeadline, delayMs >= Double(retryDeadline - rt.now()) { return response }
        // `response.body?.cancel()`: the unread body is dropped with the response.
        try await rt.sleep(jsMillis(delayMs), requestSignal)
    }
}

private func fetchGitHubCopilotModels(
    _ rt: OAuthRuntime,
    _ knownModelIds: Set<String>,
    _ copilotToken: String,
    _ enterpriseDomain: String?,
    _ signal: AbortSignal,
    _ retryPolicy: CopilotRetryPolicy
) async throws -> (availableModelIds: [String], policyModelIds: [String]) {
    let baseUrl = getGitHubCopilotBaseUrl(copilotToken, enterpriseDomain)
    // Some Individual accounts return false for every picker flag despite explicit enabled policies.
    // Limit the fallback to that endpoint so other account types keep strict picker semantics.
    let allowPolicyFallback = baseUrl == "https://api.individual.githubcopilot.com"
    let response = try await fetchWithRateLimitRetry(
        rt,
        "\(baseUrl)/models",
        headers: [
            ("Accept", "application/json"),
            ("Authorization", "Bearer \(copilotToken)"),
        ] + COPILOT_HEADERS + [
            ("X-GitHub-Api-Version", COPILOT_API_VERSION),
        ],
        signal,
        retryPolicy
    )
    if !response.ok {
        throw PiError("\(response.status) \(response.statusText): \(try await response.text())")
    }
    return try parseGitHubCopilotModelCatalog(try await response.json(), allowPolicyFallback, knownModelIds)
}

private func fetchJson(
    _ rt: OAuthRuntime,
    _ url: String,
    method: String = "GET",
    headers: [(String, String)],
    body: String? = nil,
    signal: AbortSignal
) async throws -> JsonValue {
    let response = try await rt.fetch(url, method: method, headers: headers, body: body, signal: signal)
    if !response.ok {
        let text = try await response.text()
        throw PiError("\(response.status) \(response.statusText): \(text)")
    }
    return try await response.json()
}

private func startDeviceFlow(_ rt: OAuthRuntime, _ domain: String, _ signal: AbortSignal) async throws -> DeviceCodeResponse {
    let urls = getUrls(domain)
    let data = try await fetchJson(
        rt,
        urls.deviceCodeUrl,
        method: "POST",
        headers: [
            ("Accept", "application/json"),
            ("Content-Type", "application/x-www-form-urlencoded"),
            ("User-Agent", "GitHubCopilotChat/0.35.0"),
        ],
        body: URLSearchParams([
            ("client_id", CLIENT_ID),
            ("scope", "read:user"),
        ]).toString(),
        signal: signal
    )

    guard let record = asRecord(data) else {
        throw PiError("Invalid device code response")
    }

    let interval = record["interval"]
    guard
        case .string(let deviceCode)? = record["device_code"],
        case .string(let userCode)? = record["user_code"],
        case .string(let verificationUri)? = record["verification_uri"],
        interval == nil || interval?.doubleValue != nil,
        case .number(let expiresIn)? = record["expires_in"]
    else {
        throw PiError("Invalid device code response fields")
    }

    // The verification URI is opened in the user's browser and to prevent `open` from
    // opening an executable or similar, we force it to be a URL.
    guard let parsedUri = WebURL(verificationUri) else {
        throw PiError("Untrusted verification_uri in device code response")
    }
    if parsedUri.protocol != "https:" && parsedUri.protocol != "http:" {
        throw PiError("Untrusted verification_uri in device code response")
    }

    return DeviceCodeResponse(
        device_code: deviceCode,
        user_code: userCode,
        verification_uri: parsedUri.href,
        interval: interval?.doubleValue,
        expires_in: expiresIn
    )
}

private func pollForGitHubAccessToken(
    _ rt: OAuthRuntime,
    _ domain: String,
    _ device: DeviceCodeResponse,
    _ signal: AbortSignal
) async throws -> String {
    let urls = getUrls(domain)
    return try await pollOAuthDeviceCodeFlow(OAuthDeviceCodePollOptions<String>(
        intervalSeconds: device.interval,
        expiresInSeconds: device.expires_in,
        waitBeforeFirstPoll: true,
        poll: {
            let raw = try await fetchJson(
                rt,
                urls.accessTokenUrl,
                method: "POST",
                headers: [
                    ("Accept", "application/json"),
                    ("Content-Type", "application/x-www-form-urlencoded"),
                    ("User-Agent", "GitHubCopilotChat/0.35.0"),
                ],
                body: URLSearchParams([
                    ("client_id", CLIENT_ID),
                    ("device_code", device.device_code),
                    ("grant_type", "urn:ietf:params:oauth:grant-type:device_code"),
                ]).toString(),
                signal: signal
            )

            if let record = asRecord(raw), case .string(let accessToken)? = record["access_token"] {
                return .complete(value: accessToken)
            }

            if let record = asRecord(raw), case .string(let error)? = record["error"] {
                let description = record["error_description"]?.stringValue
                let interval = record["interval"]
                if error == "authorization_pending" {
                    return .pending
                }

                if error == "slow_down" {
                    return .slow_down(intervalSeconds: interval?.doubleValue)
                }

                let descriptionSuffix = description.map { $0.isEmpty ? "" : ": \($0)" } ?? ""
                return .failed(message: "Device flow failed: \(error)\(descriptionSuffix)")
            }

            return .failed(message: "Invalid device token response")
        },
        signal: signal
    ), runtime: rt)
}

private func refreshGitHubCopilotAccessToken(
    _ rt: OAuthRuntime,
    _ refreshToken: String,
    _ enterpriseDomain: String?,
    _ signal: AbortSignal
) async throws -> OAuthCredential {
    let domain = enterpriseDomain.flatMap { $0.isEmpty ? nil : $0 } ?? "github.com"
    let urls = getUrls(domain)

    let raw = try await fetchJson(
        rt,
        urls.copilotTokenUrl,
        headers: [
            ("Accept", "application/json"),
            ("Authorization", "Bearer \(refreshToken)"),
        ] + COPILOT_HEADERS,
        signal: signal
    )

    guard let record = asRecord(raw) else {
        throw PiError("Invalid Copilot token response")
    }

    guard case .string(let token)? = record["token"], case .number(let expiresAt)? = record["expires_at"] else {
        throw PiError("Invalid Copilot token response fields")
    }

    var extra = JsonObject()
    // `enterpriseUrl: undefined` is dropped when the credential is serialized.
    if let enterpriseDomain { extra["enterpriseUrl"] = .string(enterpriseDomain) }
    return OAuthCredential(
        refresh: refreshToken,
        access: token,
        expires: jsMillis(expiresAt * 1000 - 5 * 60 * 1000),
        extra: extra
    )
}

/**
 * Refresh GitHub Copilot token
 */
private func refreshGitHubCopilotToken(
    _ rt: OAuthRuntime,
    _ knownModelIds: Set<String>,
    _ refreshToken: String,
    _ enterpriseDomain: String?,
    _ signal: AbortSignal
) async throws -> OAuthCredential {
    var credentials = try await refreshGitHubCopilotAccessToken(rt, refreshToken, enterpriseDomain, signal)
    let (availableModelIds, _) = try await fetchGitHubCopilotModels(rt, knownModelIds, credentials.access, enterpriseDomain, signal, CopilotRetryPolicy(
        maxRetries: 0,
        maxElapsedMs: 0
    ))
    credentials.extra["availableModelIds"] = .array(availableModelIds.map(JsonValue.string))
    return credentials
}

/**
 * Enable a model for the user's GitHub Copilot account.
 * This is required for some models (like Claude, Grok) before they can be used.
 */
private func enableGitHubCopilotModel(
    _ rt: OAuthRuntime,
    _ token: String,
    _ modelId: String,
    _ enterpriseDomain: String?,
    _ signal: AbortSignal
) async throws -> Bool {
    let baseUrl = getGitHubCopilotBaseUrl(token, enterpriseDomain)
    let url = "\(baseUrl)/models/\(modelId)/policy"

    let response: FetchResponse
    do {
        response = try await fetchWithRateLimitRetry(
            rt,
            url,
            method: "POST",
            headers: [
                ("Content-Type", "application/json"),
                ("Authorization", "Bearer \(token)"),
            ] + COPILOT_HEADERS + [
                ("openai-intent", "chat-policy"),
                ("x-interaction-type", "chat-policy"),
            ],
            body: JsonValue.object(["state": "enabled"]).serialized(),
            signal,
            CopilotRetryPolicy(maxRetries: 2, maxElapsedMs: 5000)
        )
    } catch {
        if signal.aborted { throw error }
        return false
    }
    if response.status == 429 {
        throw PiError("\(response.status) \(response.statusText): \(try await response.text())")
    }
    return response.ok
}

/**
 * Enable the requested GitHub Copilot models and return the successful IDs.
 * Policy updates are best effort; exhausted rate limiting stops the batch.
 */
private func enableGitHubCopilotModels(
    _ rt: OAuthRuntime,
    _ token: String,
    _ modelIds: [String],
    _ enterpriseDomain: String?,
    _ signal: AbortSignal
) async throws -> [String] {
    var enabledModelIds: [String] = []
    for modelId in modelIds {
        do {
            if try await enableGitHubCopilotModel(rt, token, modelId, enterpriseDomain, signal) {
                enabledModelIds.append(modelId)
            }
        } catch {
            if signal.aborted { throw error }
            break
        }
    }
    return enabledModelIds
}

private func loginGitHubCopilot(
    _ rt: OAuthRuntime,
    _ knownModelIds: Set<String>,
    _ interaction: ProviderAuthInteraction
) async throws -> OAuthCredential {
    let input = try await interaction.prompt(AuthPrompt(.text(
        message: "GitHub Enterprise URL/domain (blank for github.com)",
        placeholder: "company.ghe.com"
    )))
    if interaction.signal.aborted { throw PiError("Login cancelled") }

    let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
    let enterpriseDomain = normalizeDomain(input)
    if !trimmed.isEmpty && (enterpriseDomain ?? "").isEmpty { throw PiError("Invalid GitHub Enterprise URL/domain") }
    let domain = enterpriseDomain.flatMap { $0.isEmpty ? nil : $0 } ?? "github.com"

    let device = try await startDeviceFlow(rt, domain, interaction.signal)
    interaction.notify(.device_code(
        userCode: device.user_code,
        verificationUri: device.verification_uri,
        intervalSeconds: device.interval.map(jsMillis),
        expiresInSeconds: jsMillis(device.expires_in)
    ))

    let githubAccessToken = try await pollForGitHubAccessToken(rt, domain, device, interaction.signal)
    var credentials = try await refreshGitHubCopilotAccessToken(
        rt,
        githubAccessToken,
        enterpriseDomain,
        interaction.signal
    )
    let models = try await fetchGitHubCopilotModels(
        rt,
        knownModelIds,
        credentials.access,
        enterpriseDomain,
        interaction.signal,
        CopilotRetryPolicy(
            maxRetries: 2,
            maxElapsedMs: 5000
        )
    )
    var enabledModelIds: [String] = []
    if !models.policyModelIds.isEmpty {
        interaction.notify(.progress(message: "Enabling models..."))
        enabledModelIds = try await enableGitHubCopilotModels(
            rt,
            credentials.access,
            models.policyModelIds,
            enterpriseDomain,
            interaction.signal
        )
    }
    // `[...new Set([...a, ...b])]`: first occurrence wins, order kept.
    var seen = Set<String>()
    let availableModelIds = (models.availableModelIds + enabledModelIds).filter { seen.insert($0).inserted }
    credentials.extra["availableModelIds"] = .array(availableModelIds.map(JsonValue.string))
    return credentials
}

private func copilotEnterpriseDomain(_ credential: OAuthCredential) -> String? {
    guard case .string(let enterpriseUrl)? = credential.extra["enterpriseUrl"], !enterpriseUrl.isEmpty else { return nil }
    return normalizeDomain(enterpriseUrl)
}

/// `Object.hasOwn(GITHUB_COPILOT_MODELS, id)`: the generated catalog is not ported, so the builtin
/// registry's `github-copilot` models stand in for it.
private func builtinGitHubCopilotModelIds() -> Set<String> {
    Set(getAllBuiltinModels("github-copilot").map(\.id))
}

func createGitHubCopilotOAuth(
    _ rt: OAuthRuntime = .live,
    knownModelIds: @escaping @Sendable () -> Set<String> = builtinGitHubCopilotModelIds
) -> OAuthAuth {
    OAuthAuth(
        name: "GitHub Copilot",
        isSubscription: true,
        login: { interaction, _ in try await loginGitHubCopilot(rt, knownModelIds(), interaction) },
        refresh: { credential, signal in
            try await refreshGitHubCopilotToken(rt, knownModelIds(), credential.refresh, copilotEnterpriseDomain(credential), signal)
        },

        /** Derive the credential-specific proxy endpoint for each request. */
        toAuth: { credential in
            ModelAuth(
                apiKey: credential.access,
                baseUrl: getGitHubCopilotBaseUrl(credential.access, copilotEnterpriseDomain(credential))
            )
        }
    )
}

public let githubCopilotOAuth: OAuthAuth = createGitHubCopilotOAuth()
