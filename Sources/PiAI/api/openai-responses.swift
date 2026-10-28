import Foundation

// Port of packages/ai/src/api/openai-responses.ts
//
// Swift: `OpenAIResponsesOptions extends StreamOptions` adds `reasoningEffort`, `reasoningSummary`,
// `serviceTier` and `toolChoice`; they are read from `StreamOptions.extra` under those names
// (`toolChoice` falls back to the simple-options `StreamOptions.toolChoice` string).

private let OPENAI_TOOL_CALL_PROVIDERS: Set<String> = ["openai", "openai-codex", "opencode"]
// OpenAI Responses rejects max_output_tokens below 16: https://github.com/earendil-works/pi/issues/6265
private let OPENAI_RESPONSES_MIN_OUTPUT_TOKENS = 16
private let CHATGPT_USAGE_URL = "https://chatgpt.com/settings/usage"
// Fixed reasoning.effort while configuration_update items carry the thinking level.
private let CONFIGURATION_UPDATE_REQUEST_EFFORT = "medium"

/// OpenAI Responses-specific options (`OpenAIResponsesOptions`): the same struct as `StreamOptions`.
public typealias OpenAIResponsesOptions = StreamOptions

extension StreamOptions {
    /// `options.reasoningEffort`: "minimal" | "low" | "medium" | "high" | "xhigh" | "max"
    fileprivate var responsesReasoningEffort: String? { extra["reasoningEffort"]?.stringValue }
    /// `options.reasoningSummary`: "auto" | "detailed" | "concise" | null
    fileprivate var responsesReasoningSummary: String? { extra["reasoningSummary"]?.stringValue }
    /// `options.serviceTier` (`ResponseCreateParamsStreaming["service_tier"]`)
    fileprivate var responsesServiceTier: String? { extra["serviceTier"]?.stringValue }
    /// `options.toolChoice` (`ResponseCreateParamsStreaming["tool_choice"]`)
    fileprivate var responsesToolChoice: JsonValue? { extra["toolChoice"] ?? toolChoice.map(JsonValue.string) }
}

/// `Object.assign(target, source)` on an ordered header record (case-sensitive keys, existing keys keep their place).
private func assignHeaders(_ target: inout ProviderHeaders, _ source: ProviderHeaders) {
    for (key, value) in source {
        if let index = target.firstIndex(where: { $0.0 == key }) {
            target[index].1 = value
        } else {
            target.append((key, value))
        }
    }
}

/// `Object.assign(params, samplingParams)`.
private func assignParams(_ target: inout JsonObject, _ source: JsonObject) {
    for (key, value) in source { target[key] = value }
}

/// `model.thinkingLevelMap?.[level] ?? level`
private func mappedThinkingLevel(_ model: Model, _ level: String) -> String {
    if let key = ModelThinkingLevel(rawValue: level), case .some(.some(let mapped)) = model.thinkingLevelMap?[key] {
        return mapped
    }
    return level
}

/**
 * OpenAI API keys start with `sk-`; a different credential sent directly to OpenAI
 * is a Sign in with ChatGPT access token.
 */
private func isChatGPTSignIn(_ model: Model, _ apiKey: String?) -> Bool {
    model.provider == "openai" &&
        model.baseUrl == "https://api.openai.com/v1" &&
        apiKey != nil &&
        !apiKey!.hasPrefix("sk-")
}

private func hasHeader(_ headers: ProviderHeaders?, _ name: String) -> Bool {
    guard let headers else { return false }
    let expected = name.lowercased()
    for (key, value) in headers {
        if key.lowercased() == expected, let value, !jsTrim(value).isEmpty { return true }
    }
    return false
}

private func getClientApiKey(_ provider: String, _ apiKey: String?, _ headers: ProviderHeaders?) throws -> String {
    if let apiKey, !apiKey.isEmpty { return apiKey }
    if hasHeader(headers, "authorization") || hasHeader(headers, "cf-aig-authorization") { return "unused" }
    throw PiError("No API key for provider: \(provider)")
}

private func detectSessionAffinityFormat(_ model: Model) -> SessionAffinityFormat {
    model.provider == "openrouter" || model.baseUrl.contains("openrouter.ai") ? .openrouter : .openai
}

/**
 * Resolve cache retention preference.
 * Defaults to "short" and uses PI_CACHE_RETENTION for backward compatibility.
 */
private func resolveCacheRetention(_ cacheRetention: CacheRetention?, _ env: ProviderEnv?) -> CacheRetention {
    if let cacheRetention { return cacheRetention }
    if getProviderEnvValue("PI_CACHE_RETENTION", env) == "long" { return .long }
    return .short
}

/// `Required<OpenAIResponsesCompat>`
private struct ResolvedResponsesCompat {
    var supportsDeveloperRole: Bool
    var supportsMidConvoSystemMessages: Bool
    var sessionAffinityFormat: SessionAffinityFormat
    var supportsLongCacheRetention: Bool
    var supportsStrictMode: Bool
    var supportsOpenAIGrammarTools: Bool
    var supportsAdditionalTools: Bool
    var supportsToolSearch: Bool
    var supportsExplicitPromptCacheMode: Bool
    var supportsMaxOutputTokens: Bool
    var supportsMidConvoEffort: Bool
}

private func getCompat(_ model: Model) -> ResolvedResponsesCompat {
    let compat = OpenAIResponsesCompat(json: model.compat)
    return ResolvedResponsesCompat(
        supportsDeveloperRole: compat.supportsDeveloperRole ?? true,
        supportsMidConvoSystemMessages: compat.supportsMidConvoSystemMessages ?? false,
        sessionAffinityFormat: compat.sessionAffinityFormat ?? detectSessionAffinityFormat(model),
        supportsLongCacheRetention: compat.supportsLongCacheRetention ?? true,
        supportsStrictMode: compat.supportsStrictMode ?? false,
        supportsOpenAIGrammarTools: compat.supportsOpenAIGrammarTools ?? false,
        supportsAdditionalTools: compat.supportsAdditionalTools ?? false,
        supportsToolSearch: compat.supportsToolSearch ?? false,
        supportsExplicitPromptCacheMode: compat.supportsExplicitPromptCacheMode ?? false,
        supportsMaxOutputTokens: compat.supportsMaxOutputTokens ?? true,
        supportsMidConvoEffort: compat.supportsMidConvoEffort ?? false
    )
}

/// Effort to send in configuration_update items, or undefined to send it as reasoning.effort.
private func getConfigurationUpdateEffort(_ model: Model, _ options: OpenAIResponsesOptions?, _ compat: ResolvedResponsesCompat) -> String? {
    guard compat.supportsMidConvoEffort,
          let reasoningEffort = options?.responsesReasoningEffort, !reasoningEffort.isEmpty,
          // Sign in with ChatGPT rejects configuration_update items.
          !isChatGPTSignIn(model, options?.apiKey)
    else {
        return nil
    }
    return mappedThinkingLevel(model, reasoningEffort)
}

private func getPromptCacheRetention(_ compat: ResolvedResponsesCompat, _ cacheRetention: CacheRetention) -> String? {
    cacheRetention == .long && compat.supportsLongCacheRetention && !compat.supportsExplicitPromptCacheMode ? "24h" : nil
}

/// `ResponseCreateParamsStreaming["prompt_cache_options"]`
private func getPromptCacheOptions(_ compat: ResolvedResponsesCompat, _ cacheRetention: CacheRetention) -> JsonValue? {
    if !compat.supportsExplicitPromptCacheMode { return nil }
    if cacheRetention == .none { return ["mode": "explicit"] }
    if cacheRetention == .long && compat.supportsLongCacheRetention { return ["ttl": "30m"] }
    return nil
}

/**
 * Generate function for OpenAI Responses API
 */
public func streamOpenAIResponses(
    _ model: Model,
    _ context: TranscriptContext,
    _ options: OpenAIResponsesOptions? = nil
) -> AssistantMessageEventStream {
    let stream = AssistantMessageEventStream()
    let normalizedContext = resolveTranscript(context, getCompat(model).supportsMidConvoSystemMessages)

    // Start async processing
    Task {
        let compat = getCompat(model)
        let configurationUpdateEffort = getConfigurationUpdateEffort(model, options, compat)
        var output = AssistantMessage(
            content: [],
            api: model.api,
            provider: model.provider,
            model: model.id,
            usage: Usage(
                input: 0,
                output: 0,
                cacheRead: 0,
                cacheWrite: 0,
                totalTokens: 0,
                cost: UsageCost(input: 0, output: 0, cacheRead: 0, cacheWrite: 0, total: 0)
            ),
            stopReason: .pending,
            timestamp: dateNow()
        )
        if let configurationUpdateEffort { output.providerThinkingLevel = configurationUpdateEffort }

        do {
            // Create OpenAI client
            let apiKey = try getClientApiKey(model.provider, options?.apiKey, options?.headers)
            let cacheRetention = resolveCacheRetention(options?.cacheRetention, options?.env)
            let cacheSessionId = cacheRetention == .none ? nil : options?.sessionId
            let grammarToolInputProperties = try createGrammarToolInputProperties(
                getDeclaredTools(normalizedContext.messages),
                compat.supportsOpenAIGrammarTools
            )
            let client = try createClient(
                model,
                normalizedContext,
                apiKey,
                options?.headers,
                options?.fetch,
                cacheSessionId,
                options?.identity
            )
            var params = try buildParams(
                model,
                normalizedContext,
                options,
                compat,
                grammarToolInputProperties,
                configurationUpdateEffort
            )
            if let nextParams = try await options?.onPayload?(.object(params), model) {
                params = nextParams.objectValue ?? JsonObject()
            }
            let requestOptions = RequestOptions(
                signal: options?.signal,
                timeout: options?.timeoutMs,
                maxRetries: 0
            )
            let requestParams = params
            let (data, response, _) = try await retryProviderRequest(
                { try await client.responses.create(.object(requestParams), requestOptions).withResponse() },
                ProviderRetryOptions(
                    maxRetries: options?.maxRetries,
                    maxRetryDelayMs: options?.maxRetryDelayMs,
                    signal: options?.signal
                )
            )
            try await options?.onResponse?(ProviderResponse(status: response.status, headers: headersToRecord(response.headers)), model)
            stream.push(.start(partial: output))

            guard let openaiStream = data.stream else {
                // `for await (const event of openaiStream)` on a non-iterable value.
                throw PiError("openaiStream is not async iterable", name: "TypeError")
            }
            try await processResponsesStream(openaiStream, &output, stream, model, OpenAIResponsesStreamOptions(
                onProviderStreamEvent: options?.onProviderStreamEvent,
                serviceTier: options?.responsesServiceTier,
                grammarToolInputProperties: grammarToolInputProperties,
                applyServiceTierPricing: { usage, serviceTier in applyServiceTierPricing(&usage, serviceTier, model) }
            ))

            if options?.signal?.aborted == true {
                throw PiError("Request was aborted")
            }

            if output.stopReason == .pending {
                throw PiError("OpenAI Responses stream ended without a stop reason")
            }
            if output.stopReason == .aborted || output.stopReason == .error {
                throw PiError((output.errorMessage ?? "").isEmpty ? "An unknown error occurred" : output.errorMessage!)
            }

            stream.push(.done(reason: output.stopReason, message: output))
            stream.end()
        } catch {
            // Block `index`, `partialJson` and `customInput` live in side tables and are never persisted.
            output.stopReason = options?.signal?.aborted == true ? .aborted : .error
            let errorMessage = formatProviderError(
                normalizeProviderError(error),
                "\(model.provider == "openai" ? "OpenAI" : model.provider) API error"
            )
            // Sign in with ChatGPT shares the subscription's usage limit with other apps.
            output.errorMessage = errorMessage.contains("subscription_sharing_usage_limit_exceeded")
                ? "\(errorMessage)\nCheck your ChatGPT usage: \(CHATGPT_USAGE_URL)"
                : errorMessage
            stream.push(.error(reason: output.stopReason, error: output))
            stream.end()
        }
    }

    return stream
}

public func streamSimpleOpenAIResponses(
    _ model: Model,
    _ context: TranscriptContext,
    _ options: SimpleStreamOptions? = nil
) -> AssistantMessageEventStream {
    do {
        _ = try getClientApiKey(model.provider, options?.apiKey, options?.headers)
    } catch {
        // Upstream throws synchronously; a Swift `StreamFunction` cannot throw, so the error ends the
        // stream the way `lazyStream` reports a setup failure.
        return createResponsesSetupErrorStream(model, error)
    }

    var base = buildBaseOptions(model, context, options, options?.apiKey)
    base.toolChoice = options?.toolChoice
    let clampedReasoning = options?.reasoning.map { clampThinkingLevel(model, ModelThinkingLevel($0)) }
    let reasoningEffort = clampedReasoning == .off ? nil : clampedReasoning

    var next = base
    next.extra["reasoningEffort"] = reasoningEffort.map { .string($0.rawValue) }
    return streamOpenAIResponses(model, context, next)
}

/// The error stream `lazyStream` produces when setup throws (`createSetupErrorMessage`).
func createResponsesSetupErrorStream(_ model: Model, _ error: any Error) -> AssistantMessageEventStream {
    let stream = AssistantMessageEventStream()
    let message = AssistantMessage(
        content: [],
        api: model.api,
        provider: model.provider,
        model: model.id,
        usage: Usage(),
        stopReason: .error,
        errorMessage: errorMessage(error),
        timestamp: dateNow()
    )
    stream.push(.error(reason: .error, error: message))
    stream.end(message)
    return stream
}

private func createClient(
    _ model: Model,
    _ context: TranscriptContext,
    _ apiKey: String,
    _ optionsHeaders: ProviderHeaders? = nil,
    _ fetch: FetchFunction? = nil,
    _ sessionId: String? = nil,
    _ identity: ClientIdentity? = nil
) throws -> OpenAI {
    let compat = getCompat(model)
    var headers = getIdentityHeaders(.init(model), identity)
    assignHeaders(&headers, (model.headers ?? []).map { ($0.0, Optional($0.1)) })
    if model.provider == "github-copilot" {
        let hasImages = hasCopilotVisionInput(context.messages)
        let copilotHeaders = buildCopilotDynamicHeaders(
            messages: context.messages,
            hasImages: hasImages
        )
        assignHeaders(&headers, copilotHeaders.map { ($0.0, Optional($0.1)) })
    }

    if let sessionId, !sessionId.isEmpty {
        if compat.sessionAffinityFormat == .openrouter {
            assignHeaders(&headers, [("x-session-id", sessionId)])
        } else {
            if compat.sessionAffinityFormat == .openai {
                assignHeaders(&headers, [("session_id", sessionId)])
            }
            assignHeaders(&headers, [("x-client-request-id", sessionId)])
        }
    }

    // Merge options headers last so they can override defaults
    if let optionsHeaders {
        assignHeaders(&headers, optionsHeaders)
    }

    return try OpenAI(OpenAI.ClientOptions(
        apiKey: apiKey,
        baseURL: model.baseUrl,
        fetch: fetch,
        defaultHeaders: .record(headers),
        dangerouslyAllowBrowser: true
    ))
}

private func buildParams(
    _ model: Model,
    _ context: TranscriptContext,
    _ options: OpenAIResponsesOptions?,
    _ compat: ResolvedResponsesCompat,
    _ grammarToolInputProperties: [String: String],
    _ configurationUpdateEffort: String?
) throws -> JsonObject {
    let transcriptTools = resolveTranscriptTools(context.messages, getResponsesToolSupport(
        supportsMidConvoSystemMessages: compat.supportsMidConvoSystemMessages,
        supportsAdditionalTools: compat.supportsAdditionalTools,
        supportsToolSearch: compat.supportsToolSearch
    ))
    let messages = try convertResponsesMessages(model, context, OPENAI_TOOL_CALL_PROVIDERS, ConvertResponsesMessagesOptions(
        grammarToolInputProperties: grammarToolInputProperties,
        supportsMidConvoSystemMessages: compat.supportsMidConvoSystemMessages,
        supportsAdditionalTools: compat.supportsAdditionalTools,
        supportsToolSearch: compat.supportsToolSearch,
        toolOptions: ConvertResponsesToolsOptions(
            supportsStrictMode: compat.supportsStrictMode,
            supportsOpenAIGrammarTools: compat.supportsOpenAIGrammarTools
        ),
        configurationUpdateEffort: configurationUpdateEffort
    ))

    let cacheRetention = resolveCacheRetention(options?.cacheRetention, options?.env)
    // Sign in with ChatGPT rejects these request fields.
    let omitUnsupportedFields = isChatGPTSignIn(model, options?.apiKey)
    var params: JsonObject = [
        "model": .string(model.id),
        "input": .array(messages),
        "stream": true,
    ]
    // `undefined` values are dropped by JSON serialization.
    params["prompt_cache_key"] = cacheRetention == .none ? nil : clampOpenAIPromptCacheKey(options?.sessionId).map(JsonValue.string)
    params["prompt_cache_retention"] = omitUnsupportedFields ? nil : getPromptCacheRetention(compat, cacheRetention).map(JsonValue.string)
    params["prompt_cache_options"] = omitUnsupportedFields ? nil : getPromptCacheOptions(compat, cacheRetention)
    params["store"] = false

    if let maxTokens = options?.maxTokens, maxTokens != 0, compat.supportsMaxOutputTokens, !omitUnsupportedFields {
        params["max_output_tokens"] = .number(Double(max(maxTokens, OPENAI_RESPONSES_MIN_OUTPUT_TOKENS)))
    }

    if let temperature = options?.temperature, !omitUnsupportedFields {
        params["temperature"] = .number(temperature)
    }

    if let serviceTier = options?.responsesServiceTier {
        params["service_tier"] = .string(serviceTier)
    }

    if !transcriptTools.requestTools.isEmpty {
        params["tools"] = .array(try convertResponsesTools(transcriptTools.requestTools, ConvertResponsesToolsOptions(
            supportsStrictMode: compat.supportsStrictMode,
            supportsOpenAIGrammarTools: compat.supportsOpenAIGrammarTools
        )))
    }

    if let toolChoice = options?.responsesToolChoice {
        params["tool_choice"] = toolChoice
    }

    let requestedReasoningEffort = options?.responsesReasoningEffort.flatMap { $0.isEmpty ? nil : $0 }
    let reasoningSummary = options?.responsesReasoningSummary.flatMap { $0.isEmpty ? nil : $0 }
    let reasoningEffort = options?.responsesReasoningEffort ?? (reasoningSummary != nil ? "medium" : nil)
    if model.reasoning {
        if let reasoningEffort, !reasoningEffort.isEmpty {
            let requestedEffort = requestedReasoningEffort.map { mappedThinkingLevel(model, $0) } ?? reasoningEffort
            let effort = configurationUpdateEffort == nil ? requestedEffort : CONFIGURATION_UPDATE_REQUEST_EFFORT
            params["reasoning"] = [
                "effort": .string(effort),
                "summary": .string(reasoningSummary ?? "auto"),
            ]
            params["include"] = ["reasoning.encrypted_content"]
        } else if model.provider != "github-copilot", !isExplicitNull(model.thinkingLevelMap?[.off]) {
            params["reasoning"] = [
                "effort": .string(model.thinkingLevelMap?[.off].flatMap { $0 } ?? "none"),
            ]
        }
        if model.provider == "xai" { params["include"] = ["reasoning.encrypted_content"] }
    }

    // Last so model and request sampling parameters override named request fields.
    let samplingParams = resolveSamplingParams(
        model,
        reasoningEffort.flatMap { ModelThinkingLevel(rawValue: $0) } ?? .off,
        options?.samplingParams
    )
    if let samplingParams {
        assignParams(&params, samplingParams)
    }

    return params
}

/// `model.thinkingLevelMap?.off === null`
private func isExplicitNull(_ value: String??) -> Bool {
    if case .some(.none) = value { return true }
    return false
}

/// `ResponseCreateParamsStreaming["service_tier"]`
private func getServiceTierCostMultiplier(_ model: Model, _ serviceTier: String?) -> Double {
    switch serviceTier {
    case "flex":
        return 0.5
    case "priority", "fast":
        return model.id == "gpt-5.5" ? 2.5 : 2
    default:
        return 1
    }
}

private func applyServiceTierPricing(_ usage: inout Usage, _ serviceTier: String?, _ model: Model) {
    let multiplier = getServiceTierCostMultiplier(model, serviceTier)
    if multiplier == 1 { return }

    usage.cost.input *= multiplier
    usage.cost.output *= multiplier
    usage.cost.cacheRead *= multiplier
    usage.cost.cacheWrite *= multiplier
    usage.cost.total = usage.cost.input + usage.cost.output + usage.cost.cacheRead + usage.cost.cacheWrite
}
