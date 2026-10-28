import Foundation
import Testing
@testable import PiAI

// Port of packages/ai/test/github-copilot-oauth.test.ts
// `vi.stubGlobal("fetch", ...)` and fake timers -> `createGitHubCopilotOAuth(harness.runtime)`.
// The harness `sleep` advances virtual time at once, so the `advanceTimersByTimeAsync` checkpoints become
// assertions on the recorded poll times and sleep durations.

private let neverAbortedSignal = AbortController().signal

private let testCopilotAccessToken = "tid=test;exp=9999999999;proxy-ep=proxy.individual.githubcopilot.com;"
private let testCopilotModelsUrl = "https://api.individual.githubcopilot.com/models"

private func jsonResponse(_ body: JsonValue, _ status: Int = 200, _ headers: [(String, String)] = []) -> FetchResponse {
    oauthJson(status, body.serialized(), headers: [("Content-Type", "application/json")] + headers)
}

private func emptyResponse() -> FetchResponse { oauthText(200, "") }

private func requireModelId(_ models: [Model], _ index: Int) throws -> String {
    guard index < models.count else { throw PiError("Expected a GitHub Copilot model at index \(index)") }
    return models[index].id
}

/// Swift has no generated `github-copilot.models.ts` and the builtin registry is empty in tests, so a
/// local catalog stands in: it is passed to `githubCopilotProvider(models:)` and as the flow's `knownModelIds`.
private let testCatalog: [Model] = ["claude-sonnet-4.5", "gpt-5.1", "gemini-3-pro-preview"].map { id in
    Model(id: id, name: id, api: "openai-completions", provider: "github-copilot", baseUrl: "https://api.individual.githubcopilot.com",
          reasoning: false, input: ["text"], cost: ModelCost(input: 0, output: 0, cacheRead: 0, cacheWrite: 0),
          contextWindow: 128000, maxTokens: 16000)
}

private func copilotProvider() -> Provider { githubCopilotProvider(models: testCatalog) }
private func providerModels() throws -> [Model] { try copilotProvider().getModels() }

private func copilotOAuth(_ h: OAuthTestHarness) -> OAuthAuth {
    createGitHubCopilotOAuth(h.runtime, knownModelIds: { Set(testCatalog.map(\.id)) })
}

/// `githubCopilotProvider()` with the OAuth flow bound to the test runtime.
private func testProvider(_ h: OAuthTestHarness) -> Provider {
    var provider = copilotProvider()
    provider.auth.oauth = copilotOAuth(h)
    return provider
}

private func model(_ id: String, picker: Bool, policy: String? = nil, toolCalls: Bool? = nil) -> JsonValue {
    var object: JsonObject = ["id": .string(id), "model_picker_enabled": .bool(picker)]
    if let policy { object["policy"] = .object(["state": .string(policy)]) }
    if let toolCalls { object["capabilities"] = .object(["supports": .object(["tool_calls": .bool(toolCalls)])]) }
    return .object(object)
}

private func deviceCodeBody(verificationUri: String = "https://github.com/login/device", interval: Double = 1, expiresIn: Double = 900) -> JsonValue {
    .object([
        "device_code": "device-code",
        "user_code": "ABCD-EFGH",
        "verification_uri": .string(verificationUri),
        "interval": .number(interval),
        "expires_in": .number(expiresIn),
    ])
}

private func stubGitHubCopilotLoginFetch(
    _ h: OAuthTestHarness,
    models: @escaping @Sendable () -> FetchResponse,
    policy: (@Sendable (String) throws -> FetchResponse)? = nil
) {
    h.setHandler { call in
        let url = call.url
        if url.hasSuffix("/login/device/code") { return jsonResponse(deviceCodeBody()) }
        if url.hasSuffix("/login/oauth/access_token") { return jsonResponse(["access_token": "ghu_refresh_token"]) }
        if url.contains("/copilot_internal/v2/token") {
            return jsonResponse(["token": .string(testCopilotAccessToken), "expires_at": 9999999999])
        }
        if url == testCopilotModelsUrl { return models() }
        if url.hasPrefix("\(testCopilotModelsUrl)/") && url.hasSuffix("/policy") {
            guard let policy else { throw PiError("Unexpected policy request: \(url)") }
            let modelId = String(url.dropFirst("\(testCopilotModelsUrl)/".count).dropLast("/policy".count))
            return try policy(modelId)
        }
        throw PiError("Unexpected fetch URL: \(url)")
    }
}

/// Answers the enterprise-domain text prompt with "".
private func loginInteraction() -> OAuthTestInteraction {
    OAuthTestInteraction { prompt in
        guard case .text = prompt.kind else { throw PiError("Unexpected prompt: \(prompt.kind)") }
        return ""
    }
}

private func refreshGitHubCopilotModelsForTest(
    _ data: [JsonValue],
    proxyHost: String = "proxy.individual.githubcopilot.com"
) async throws -> OAuthCredential {
    let accessToken = "tid=test;exp=9999999999;proxy-ep=\(proxyHost);"
    let modelsUrl = "https://\(proxyHost.replacingOccurrences(of: "^proxy\\.", with: "api.", options: .regularExpression))/models"
    let h = OAuthTestHarness { call in
        if call.url.contains("/copilot_internal/v2/token") {
            return jsonResponse(["token": .string(accessToken), "expires_at": 9999999999])
        }
        if call.url == modelsUrl {
            #expect(call.headers.get("Authorization") == "Bearer \(accessToken)")
            return jsonResponse(["data": .array(data)])
        }
        throw PiError("Unexpected fetch URL: \(call.url)")
    }
    return try await copilotOAuth(h).refresh(
        OAuthCredential(refresh: "ghu_refresh_token", access: "old-access-token", expires: 0),
        neverAbortedSignal
    )
}

private func availableModelIds(_ credential: OAuthCredential) -> [String]? {
    credential.extra["availableModelIds"]?.arrayValue?.compactMap(\.stringValue)
}

/// The store + `createModels` half of the catalog tests.
private func availableThroughModels(_ credential: OAuthCredential) async throws -> [String] {
    let store = InMemoryCredentialStore()
    _ = try await store.modify("github-copilot") { _ in .oauth(credential) }
    let models = createModels(CreateModelsOptions(credentials: store))
    models.setProvider(copilotProvider())
    return try await models.getAvailable("github-copilot").map(\.id)
}

@Suite struct GitHubCopilotOAuthDeviceFlowTests {
    @Test func filtersModelsToTheAuthenticatedAccountPickerCatalog() async throws {
        let models = try providerModels()
        let pickerModelId = try requireModelId(models, 0)
        let disabledModelId = try requireModelId(models, 1)
        let hiddenModelId = try requireModelId(models, 2)

        let credentials = try await refreshGitHubCopilotModelsForTest([
            model(pickerModelId, picker: true, toolCalls: true),
            model(disabledModelId, picker: true, policy: "disabled", toolCalls: true),
            model(hiddenModelId, picker: false, policy: "enabled", toolCalls: true),
        ])
        #expect(availableModelIds(credentials) == [pickerModelId])
        #expect(try await availableThroughModels(credentials) == [pickerModelId])
    }

    @Test func fallsBackToExplicitlyEnabledPolicyModelsWhenThePickerCatalogIsEmpty() async throws {
        let enabledModelId = try requireModelId(try providerModels(), 0)
        let credentials = try await refreshGitHubCopilotModelsForTest([
            model(enabledModelId, picker: false, policy: "enabled", toolCalls: true),
            model("policy-disabled-model", picker: false, policy: "disabled", toolCalls: true),
            model("unconfigured-model", picker: false, toolCalls: true),
            model("tool-incapable-model", picker: false, policy: "enabled", toolCalls: false),
        ])
        #expect(availableModelIds(credentials) == [enabledModelId])
        #expect(try await availableThroughModels(credentials) == [enabledModelId])
    }

    @Test func doesNotFallBackToPolicyModelsForNonIndividualAccounts() async throws {
        let credentials = try await refreshGitHubCopilotModelsForTest(
            [model("gpt-4.1", picker: false, policy: "enabled", toolCalls: true)],
            proxyHost: "proxy.business.githubcopilot.com"
        )
        #expect(availableModelIds(credentials) == [])
    }

    @Test func doesNotRetryModelCatalogThrottlingDuringCredentialRefresh() async throws {
        let catalogRequestCount = Locked(0)
        let h = OAuthTestHarness { call in
            if call.url.contains("/copilot_internal/v2/token") {
                return jsonResponse(["token": .string(testCopilotAccessToken), "expires_at": 9999999999])
            }
            if call.url == testCopilotModelsUrl {
                catalogRequestCount.withLock { $0 += 1 }
                return jsonResponse(["error": "too many requests"], 429, [("Retry-After", "0")])
            }
            throw PiError("Unexpected fetch URL: \(call.url)")
        }
        let error = await gCaught {
            _ = try await copilotOAuth(h).refresh(
                OAuthCredential(refresh: "ghu_refresh_token", access: "old-access-token", expires: 0),
                neverAbortedSignal
            )
        }
        #expect(error.map(errorMessage)?.contains("429") == true)
        #expect(catalogRequestCount.current == 1)
    }

    @Test func reportsDeviceCodeDetailsThroughOnDeviceCode() async throws {
        let h = OAuthTestHarness(now: 1_773_014_400_000)
        h.setHandler { call in
            let url = call.url
            if url.hasSuffix("/login/device/code") { return jsonResponse(deviceCodeBody()) }
            if url.hasSuffix("/login/oauth/access_token") { return jsonResponse(["access_token": "ghu_refresh_token"]) }
            if url.contains("/copilot_internal/v2/token") {
                return jsonResponse(["token": .string(testCopilotAccessToken), "expires_at": 9999999999])
            }
            if url.hasSuffix("/models") { return jsonResponse(["data": []]) }
            if url.contains("/models/") && url.hasSuffix("/policy") { return emptyResponse() }
            throw PiError("Unexpected fetch URL: \(url)")
        }
        let i = loginInteraction()
        _ = try await copilotOAuth(h).login(i.interaction, nil)

        let deviceCodes = i.events.current.filter { $0.type == "device_code" }
        #expect(deviceCodes.count == 1)
        guard case .device_code(let userCode, let verificationUri, let intervalSeconds, let expiresInSeconds)? = deviceCodes.first else {
            Issue.record("expected a device_code event")
            return
        }
        #expect(userCode == "ABCD-EFGH")
        #expect(verificationUri == "https://github.com/login/device")
        #expect(intervalSeconds == 1)
        #expect(expiresInSeconds == 900)
        // The first access-token poll waits for the interval.
        #expect(h.sleeps.current.first == 1000)
    }

    @Test func updatesOnlyKnownToolCapableUnconfiguredAccountModelPolicies() async throws {
        let models = try providerModels()
        let configuredModelId = try requireModelId(models, 0)
        let unconfiguredModelId = try requireModelId(models, 1)
        let toolIncapableModelId = try requireModelId(models, 2)
        let catalogRequestCount = Locked(0)
        let policyModelIds = Locked<[String]>([])
        let h = OAuthTestHarness()
        stubGitHubCopilotLoginFetch(h, models: {
            catalogRequestCount.withLock { $0 += 1 }
            return jsonResponse(["data": [
                model(configuredModelId, picker: true, policy: "enabled", toolCalls: true),
                model(unconfiguredModelId, picker: true, policy: "unconfigured", toolCalls: true),
                model("remote-only-model", picker: true, policy: "unconfigured", toolCalls: true),
                model(toolIncapableModelId, picker: true, policy: "unconfigured", toolCalls: false),
            ]])
        }, policy: { modelId in
            policyModelIds.withLock { $0.append(modelId) }
            return emptyResponse()
        })

        _ = try await copilotOAuth(h).login(loginInteraction().interaction, nil)

        #expect(catalogRequestCount.current == 1)
        #expect(policyModelIds.current == [unconfiguredModelId])
    }

    @Test func retriesAThrottledPolicyUpdateAfterRetryAfter() async throws {
        let modelId = try requireModelId(try providerModels(), 0)
        let policyRequestCount = Locked(0)
        let h = OAuthTestHarness()
        stubGitHubCopilotLoginFetch(h, models: {
            jsonResponse(["data": [model(modelId, picker: true, policy: "unconfigured")]])
        }, policy: { _ in
            let count = policyRequestCount.withLock { $0 += 1; return $0 }
            return count == 1
                ? jsonResponse(["error": "too many requests"], 429, [("Retry-After", "1")])
                : emptyResponse()
        })

        let credential = try await copilotOAuth(h).login(loginInteraction().interaction, nil)

        #expect(policyRequestCount.current == 2)
        // Device-code wait (1s), then the Retry-After wait (1s) before the second policy request.
        #expect(h.sleeps.current == [1000, 1000])
        #expect(availableModelIds(credential) == [modelId])
    }

    @Test func continuesPolicyUpdatesAfterATransportFailure() async throws {
        let models = try providerModels()
        let modelIds = [try requireModelId(models, 0), try requireModelId(models, 1)]
        let policyModelIds = Locked<[String]>([])
        let h = OAuthTestHarness()
        stubGitHubCopilotLoginFetch(h, models: {
            jsonResponse(["data": .array(modelIds.map { model($0, picker: true, policy: "unconfigured") })])
        }, policy: { modelId in
            let count = policyModelIds.withLock { $0.append(modelId); return $0.count }
            if count == 1 { throw PiError("fetch failed") }
            return emptyResponse()
        })

        _ = try await copilotOAuth(h).login(loginInteraction().interaction, nil)

        #expect(policyModelIds.current == modelIds)
    }

    @Test func stopsPolicyUpdatesAndPersistsAuthenticationWhenTheRetryDelayExceedsTheLoginBudget() async throws {
        let models = try providerModels()
        let firstModelId = try requireModelId(models, 0)
        let secondModelId = try requireModelId(models, 1)
        let policyModelIds = Locked<[String]>([])
        let h = OAuthTestHarness()
        stubGitHubCopilotLoginFetch(h, models: {
            jsonResponse(["data": [
                model(firstModelId, picker: true, policy: "unconfigured"),
                model(secondModelId, picker: true, policy: "unconfigured"),
            ]])
        }, policy: { modelId in
            policyModelIds.withLock { $0.append(modelId) }
            return jsonResponse(["error": "too many requests"], 429, [("Retry-After", "5")])
        })

        let store = InMemoryCredentialStore()
        let registry = createModels(CreateModelsOptions(credentials: store))
        registry.setProvider(testProvider(h))
        let credential = try await registry.login(
            "github-copilot",
            "oauth",
            AuthInteraction(signal: neverAbortedSignal, prompt: { _ in "" }, notify: { _ in })
        )

        guard case .oauth(let oauth) = credential else {
            Issue.record("expected an oauth credential")
            return
        }
        #expect(oauth.access == testCopilotAccessToken)
        #expect(policyModelIds.current == [firstModelId])
        #expect(try await store.read("github-copilot") == credential)
    }

    @Test func rejectsANonHttpVerificationUriBeforeItReachesOnDeviceCode() async throws {
        // A malicious enterprise OAuth server could return a verification_uri that
        // the browser launcher would otherwise hand to the OS. Ensure such values
        // are rejected at the deserialization boundary.
        let h = OAuthTestHarness { call in
            if call.url.hasSuffix("/login/device/code") {
                return jsonResponse(deviceCodeBody(verificationUri: "$(id>/tmp/pwned)"))
            }
            throw PiError("Unexpected fetch URL: \(call.url)")
        }
        let i = loginInteraction()
        let error = await gCaught { _ = try await copilotOAuth(h).login(i.interaction, nil) }
        #expect(error.map(errorMessage)?.contains("Untrusted verification_uri") == true)
        #expect(!i.events.current.contains { $0.type == "device_code" })
    }

    @Test func normalizesVerificationUriBeforeItReachesOnDeviceCode() async throws {
        let rawVerificationUri = "https://github.com/login/\u{1b}]8;;evil"
        let normalizedVerificationUri = WebURL(rawVerificationUri)!.href
        #expect(normalizedVerificationUri != rawVerificationUri)
        // `new URL(raw).href` in Node.
        #expect(normalizedVerificationUri == "https://github.com/login/%1B]8;;evil")

        let h = OAuthTestHarness(now: 1_773_014_400_000)
        h.setHandler { call in
            let url = call.url
            if url.hasSuffix("/login/device/code") { return jsonResponse(deviceCodeBody(verificationUri: rawVerificationUri)) }
            if url.hasSuffix("/login/oauth/access_token") { return jsonResponse(["access_token": "ghu_refresh_token"]) }
            if url.contains("/copilot_internal/v2/token") {
                return jsonResponse(["token": .string(testCopilotAccessToken), "expires_at": 9999999999])
            }
            if url.hasSuffix("/models") { return jsonResponse(["data": []]) }
            if url.contains("/models/") && url.hasSuffix("/policy") { return emptyResponse() }
            throw PiError("Unexpected fetch URL: \(url)")
        }
        let i = loginInteraction()
        _ = try await copilotOAuth(h).login(i.interaction, nil)

        let uris = i.events.current.compactMap { event -> String? in
            if case .device_code(_, let verificationUri, _, _) = event { return verificationUri }
            return nil
        }
        #expect(uris == [normalizedVerificationUri])
        #expect(!uris.contains(rawVerificationUri))
    }

    @Test func waitsBeforePollingAndIncreasesTheIntervalAfterSlowDown() async throws {
        let startTime = 1_773_014_400_000 // 2026-03-09T00:00:00Z
        let accessTokenPollTimes = Locked<[Int]>([])
        let accessTokenResponses = Locked([
            jsonResponse(["error": "authorization_pending", "error_description": "pending"]),
            jsonResponse(["error": "slow_down", "error_description": "slow down", "interval": 7]),
            jsonResponse(["access_token": "ghu_refresh_token"]),
        ])
        let h = OAuthTestHarness(now: startTime)
        h.setHandler { [h] call in
            let url = call.url
            if url.hasSuffix("/login/device/code") {
                #expect(call.method == "POST")
                #expect(call.headers.get("Accept") == "application/json")
                #expect(call.headers.get("Content-Type") == "application/x-www-form-urlencoded")
                #expect(call.body?.contains("client_id=") == true)
                #expect(call.body?.contains("scope=read%3Auser") == true)
                return jsonResponse(deviceCodeBody(interval: 5))
            }
            if url.hasSuffix("/login/oauth/access_token") {
                accessTokenPollTimes.withLock { $0.append(h.now) }
                #expect(call.method == "POST")
                #expect(call.headers.get("Accept") == "application/json")
                #expect(call.headers.get("Content-Type") == "application/x-www-form-urlencoded")
                #expect(call.body?.contains("client_id=") == true)
                #expect(call.body?.contains("device_code=device-code") == true)
                #expect(call.body?.contains("grant_type=urn%3Aietf%3Aparams%3Aoauth%3Agrant-type%3Adevice_code") == true)
                guard let response = accessTokenResponses.withLock({ $0.isEmpty ? nil : $0.removeFirst() }) else {
                    throw PiError("Unexpected extra access token poll")
                }
                return response
            }
            if url.contains("/copilot_internal/v2/token") {
                return jsonResponse(["token": .string(testCopilotAccessToken), "expires_at": 9999999999])
            }
            if url.hasSuffix("/models") { return jsonResponse(["data": []]) }
            if url.contains("/models/") && url.hasSuffix("/policy") { return emptyResponse() }
            throw PiError("Unexpected fetch URL: \(url)")
        }

        _ = try await copilotOAuth(h).login(loginInteraction().interaction, nil)

        // slow_down carried a server-provided interval of 7 seconds.
        #expect(accessTokenPollTimes.current == [startTime + 5000, startTime + 10000, startTime + 17000])
    }

    @Test func timesOutAfterRepeatedSlowDownResponses() async throws {
        let startTime = 1_773_014_400_000 // 2026-03-09T00:00:00Z
        let accessTokenPollTimes = Locked<[Int]>([])
        let accessTokenResponses = Locked([
            jsonResponse(["error": "slow_down", "error_description": "slow down"]),
            jsonResponse(["error": "slow_down", "error_description": "still too fast"]),
            jsonResponse(["error": "authorization_pending", "error_description": "pending"]),
        ])
        let h = OAuthTestHarness(now: startTime)
        h.setHandler { [h] call in
            if call.url.hasSuffix("/login/device/code") { return jsonResponse(deviceCodeBody(interval: 5, expiresIn: 25)) }
            if call.url.hasSuffix("/login/oauth/access_token") {
                accessTokenPollTimes.withLock { $0.append(h.now) }
                guard let response = accessTokenResponses.withLock({ $0.isEmpty ? nil : $0.removeFirst() }) else {
                    throw PiError("Unexpected extra access token poll")
                }
                return response
            }
            throw PiError("Unexpected fetch URL: \(call.url)")
        }

        let error = await gCaught { _ = try await copilotOAuth(h).login(loginInteraction().interaction, nil) }
        #expect(error.map(errorMessage)?.contains("Device flow timed out after one or more slow_down responses") == true)
        #expect(accessTokenPollTimes.current == [startTime + 5000, startTime + 15000])
        #expect(h.now == startTime + 25000)
    }
}
