import Foundation

// Port of packages/ai/src/api/azure-openai-responses.ts
//
// Swift: `AzureOpenAIResponsesOptions extends AzureEndpointOptions` adds `reasoningEffort`, `toolChoice`
// and `reasoningSummary`; they are read from `StreamOptions.extra` under those names (`toolChoice` falls
// back to the simple-options `StreamOptions.toolChoice` string).

private let AZURE_TOOL_CALL_PROVIDERS: Set<String> = ["openai", "openai-codex", "opencode", "azure"]
// OpenAI Responses rejects max_output_tokens below 16: https://github.com/earendil-works/pi/issues/6265
private let OPENAI_RESPONSES_MIN_OUTPUT_TOKENS = 16

private func formatAzureOpenAIError(_ error: any Error) -> String {
    formatProviderError(normalizeProviderError(error), "Azure OpenAI API error")
}

/// Azure OpenAI Responses-specific options (`AzureOpenAIResponsesOptions`): the same struct as `StreamOptions`.
public typealias AzureOpenAIResponsesOptions = AzureEndpointOptions

extension StreamOptions {
    /// `options.reasoningEffort`: "minimal" | "low" | "medium" | "high" | "xhigh" | "max"
    fileprivate var azureReasoningEffort: String? { extra["reasoningEffort"]?.stringValue }
    /// `options.toolChoice` (`ResponseCreateParamsStreaming["tool_choice"]`)
    fileprivate var azureToolChoice: JsonValue? { extra["toolChoice"] ?? toolChoice.map(JsonValue.string) }
    /// `options.reasoningSummary`: "auto" | "detailed" | "concise" | null
    fileprivate var azureReasoningSummary: String? { extra["reasoningSummary"]?.stringValue }
}

/**
 * Generate function for Azure OpenAI Responses API
 */
public func streamAzureOpenAIResponses(
    _ model: Model,
    _ context: TranscriptContext,
    _ options: AzureOpenAIResponsesOptions? = nil
) -> AssistantMessageEventStream {
    let stream = AssistantMessageEventStream()
    let compat = OpenAIResponsesCompat(json: model.compat)
    let normalizedContext = resolveTranscript(context, compat.supportsMidConvoSystemMessages)

    // Start async processing
    Task {
        let deploymentName = resolveDeploymentName(model, options)

        var output = AssistantMessage(
            content: [],
            api: "azure-openai-responses",
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

        do {
            // Create Azure OpenAI client
            guard let apiKey = options?.apiKey, !apiKey.isEmpty else {
                throw PiError("No API key for provider: \(model.provider)")
            }
            let client = try createClient(model, apiKey, options)
            let grammarToolInputProperties = try createGrammarToolInputProperties(
                getDeclaredTools(normalizedContext.messages),
                compat.supportsOpenAIGrammarTools ?? false
            )
            var params = try buildParams(model, normalizedContext, options, deploymentName, grammarToolInputProperties)
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
                grammarToolInputProperties: grammarToolInputProperties
            ))

            if options?.signal?.aborted == true {
                throw PiError("Request was aborted")
            }

            if output.stopReason == .pending {
                throw PiError("Azure OpenAI Responses stream ended without a stop reason")
            }
            if output.stopReason == .aborted || output.stopReason == .error {
                throw PiError((output.errorMessage ?? "").isEmpty ? "An unknown error occurred" : output.errorMessage!)
            }

            stream.push(.done(reason: output.stopReason, message: output))
            stream.end()
        } catch {
            // Block `index`, `partialJson` and `customInput` live in side tables and are never persisted.
            output.stopReason = options?.signal?.aborted == true ? .aborted : .error
            output.errorMessage = formatAzureOpenAIError(error)
            stream.push(.error(reason: output.stopReason, error: output))
            stream.end()
        }
    }

    return stream
}

public func streamSimpleAzureOpenAIResponses(
    _ model: Model,
    _ context: TranscriptContext,
    _ options: SimpleStreamOptions? = nil
) -> AssistantMessageEventStream {
    guard let apiKey = options?.apiKey, !apiKey.isEmpty else {
        // Upstream throws synchronously; a Swift `StreamFunction` cannot throw, so the error ends the
        // stream the way `lazyStream` reports a setup failure.
        return createResponsesSetupErrorStream(model, PiError("No API key for provider: \(model.provider)"))
    }

    var base = buildBaseOptions(model, context, options, apiKey)
    base.toolChoice = options?.toolChoice
    let clampedReasoning = options?.reasoning.map { clampThinkingLevel(model, ModelThinkingLevel($0)) }
    let reasoningEffort = clampedReasoning == .off ? nil : clampedReasoning

    var next = base
    next.extra["reasoningEffort"] = reasoningEffort.map { .string($0.rawValue) }
    return streamAzureOpenAIResponses(model, context, next)
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

private func createClient(_ model: Model, _ apiKey: String, _ options: AzureOpenAIResponsesOptions?) throws -> AzureOpenAI {
    var headers = getIdentityHeaders(.init(model), options?.identity)
    assignHeaders(&headers, (model.headers ?? []).map { ($0.0, Optional($0.1)) })

    if let optionsHeaders = options?.headers {
        assignHeaders(&headers, optionsHeaders)
    }

    let (baseUrl, apiVersion) = try resolveAzureConfig(model, options)

    return try AzureOpenAI(AzureOpenAI.AzureClientOptions(
        apiVersion: apiVersion,
        apiKey: apiKey,
        baseURL: baseUrl,
        fetch: options?.fetch,
        defaultHeaders: .record(headers),
        dangerouslyAllowBrowser: true
    ))
}

/// `model.thinkingLevelMap?.[level] ?? level`
private func mappedThinkingLevel(_ model: Model, _ level: String) -> String {
    if let key = ModelThinkingLevel(rawValue: level), case .some(.some(let mapped)) = model.thinkingLevelMap?[key] {
        return mapped
    }
    return level
}

private func buildParams(
    _ model: Model,
    _ context: TranscriptContext,
    _ options: AzureOpenAIResponsesOptions?,
    _ deploymentName: String,
    _ grammarToolInputProperties: [String: String]? = nil
) throws -> JsonObject {
    let compat = OpenAIResponsesCompat(json: model.compat)
    let grammarToolInputProperties = try grammarToolInputProperties ?? createGrammarToolInputProperties(
        getDeclaredTools(context.messages),
        compat.supportsOpenAIGrammarTools ?? false
    )
    let supportsAdditionalTools = compat.supportsAdditionalTools ?? false
    let supportsToolSearch = compat.supportsToolSearch ?? false
    let transcriptTools = resolveTranscriptTools(
        context.messages,
        getResponsesToolSupport(
            supportsMidConvoSystemMessages: compat.supportsMidConvoSystemMessages ?? false,
            supportsAdditionalTools: supportsAdditionalTools,
            supportsToolSearch: supportsToolSearch
        )
    )
    let messages = try convertResponsesMessages(model, context, AZURE_TOOL_CALL_PROVIDERS, ConvertResponsesMessagesOptions(
        grammarToolInputProperties: grammarToolInputProperties,
        supportsMidConvoSystemMessages: compat.supportsMidConvoSystemMessages ?? false,
        supportsAdditionalTools: supportsAdditionalTools,
        supportsToolSearch: supportsToolSearch,
        toolOptions: ConvertResponsesToolsOptions(
            supportsStrictMode: compat.supportsStrictMode ?? true,
            supportsOpenAIGrammarTools: compat.supportsOpenAIGrammarTools ?? false
        )
    ))

    var params: JsonObject = [
        "model": .string(deploymentName),
        "input": .array(messages),
        "stream": true,
    ]
    // `undefined` values are dropped by JSON serialization.
    params["prompt_cache_key"] = clampOpenAIPromptCacheKey(options?.sessionId).map(JsonValue.string)
    params["store"] = false

    if let maxTokens = options?.maxTokens, maxTokens != 0 {
        params["max_output_tokens"] = .number(Double(max(maxTokens, OPENAI_RESPONSES_MIN_OUTPUT_TOKENS)))
    }

    if let temperature = options?.temperature {
        params["temperature"] = .number(temperature)
    }

    if !transcriptTools.requestTools.isEmpty {
        params["tools"] = .array(try convertResponsesTools(transcriptTools.requestTools, ConvertResponsesToolsOptions(
            supportsStrictMode: compat.supportsStrictMode ?? true,
            supportsOpenAIGrammarTools: compat.supportsOpenAIGrammarTools ?? false
        )))
    }
    if let toolChoice = options?.azureToolChoice {
        params["tool_choice"] = toolChoice
    }

    let requestedReasoningEffort = options?.azureReasoningEffort.flatMap { $0.isEmpty ? nil : $0 }
    let reasoningSummary = options?.azureReasoningSummary.flatMap { $0.isEmpty ? nil : $0 }
    let reasoningEffort = options?.azureReasoningEffort ?? (reasoningSummary != nil ? "medium" : nil)
    if model.reasoning {
        if let reasoningEffort, !reasoningEffort.isEmpty {
            let effort = requestedReasoningEffort.map { mappedThinkingLevel(model, $0) } ?? reasoningEffort
            params["reasoning"] = [
                "effort": .string(effort),
                "summary": .string(reasoningSummary ?? "auto"),
            ]
            params["include"] = ["reasoning.encrypted_content"]
        } else if !isExplicitNull(model.thinkingLevelMap?[.off]) {
            params["reasoning"] = [
                "effort": .string(model.thinkingLevelMap?[.off].flatMap { $0 } ?? "none"),
            ]
        }
    }

    // Last so model and request sampling parameters override named request fields.
    let samplingParams = resolveSamplingParams(
        model,
        reasoningEffort.flatMap { ModelThinkingLevel(rawValue: $0) } ?? .off,
        options?.samplingParams
    )
    if let samplingParams {
        for (key, value) in samplingParams { params[key] = value }
    }

    return params
}

/// `model.thinkingLevelMap?.off === null`
private func isExplicitNull(_ value: String??) -> Bool {
    if case .some(.none) = value { return true }
    return false
}
