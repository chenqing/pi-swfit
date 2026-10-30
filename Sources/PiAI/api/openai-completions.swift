import Foundation

// Port of packages/ai/src/api/openai-completions.ts
//
// Swift notes:
// - `stream` / `streamSimple` are `streamOpenAICompletions` / `streamSimpleOpenAICompletions`.
// - `OpenAICompletionsOptions extends StreamOptions`: the provider-specific fields live in
//   `StreamOptions.extra` — `extra["toolChoice"]` (any `ChatCompletionToolChoiceOption` JSON; falls back to
//   the shared `toolChoice` string) and `extra["reasoningEffort"]` ("minimal" | "low" | "medium" | "high" |
//   "xhigh" | "max"). `thinkingBudgets` is the shared `StreamOptions.thinkingBudgets`.
// - Request params and chat messages are `JsonObject`s built in upstream object-literal key order.
// - Streaming scratch state (`argumentsStream`, `customInput`, `streamIndex`) lives in a side table keyed by
//   content index, never in the persisted message.

/// `OpenAICompletionsOptions` (see the file header for where the provider-specific fields live).
public typealias OpenAICompletionsOptions = StreamOptions

/// `options.reasoningEffort`
private func completionsReasoningEffort(_ options: OpenAICompletionsOptions?) -> ThinkingLevel? {
    guard let raw = options?.extra["reasoningEffort"]?.stringValue else { return nil }
    return ThinkingLevel(rawValue: raw)
}

/// `options.toolChoice` (`ChatCompletionToolChoiceOption`)
private func completionsToolChoice(_ options: OpenAICompletionsOptions?) -> JsonValue? {
    if let toolChoice = options?.extra["toolChoice"], !toolChoice.isNull { return toolChoice }
    return options?.toolChoice.map(JsonValue.string)
}

/// `value ?? undefined` with JSON null treated as nullish (`??` semantics).
private func nonNullish(_ value: JsonValue?) -> JsonValue? {
    if case .null? = value { return nil }
    return value
}

/// `String(value)` for a JSON value.
private func jsString(_ value: JsonValue) -> String {
    switch value {
    case .string(let s): return s
    case .number(let n): return JsonWriter.formatNumber(n)
    case .bool(let b): return b ? "true" : "false"
    case .null: return "null"
    case .array(let items): return items.map { $0.isNull ? "" : jsString($0) }.joined(separator: ",")
    case .object: return "[object Object]"
    }
}

/// `x || 0` for a numeric JSON field.
private func numberOrZero(_ value: JsonValue?) -> Int {
    guard case .number(let n)? = value, n.isFinite, n != 0 else { return 0 }
    return Int(n)
}

/**
 * Check if conversation messages contain tool calls or tool results.
 * This is needed because Anthropic (via proxy) requires the tools param
 * to be present when messages include tool_calls or tool role messages.
 */
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

private func hasToolHistory(_ messages: [Message]) -> Bool {
    for msg in messages {
        if case .toolResult = msg {
            return true
        }
        if case .assistant(let assistant) = msg {
            if assistant.content.contains(where: { $0.type == "toolCall" }) {
                return true
            }
        }
    }
    return false
}

// isTextContentBlock / isThinkingContentBlock / isToolCallBlock / isImageContentBlock:
// Swift pattern-matches the content enums directly.

private func isReasoningDetailObject(_ detail: JsonValue) -> JsonObject? {
    detail.objectValue
}

private func hasValidCommonReasoningDetailFields(_ candidate: JsonObject) -> Bool {
    let id = candidate["id"]
    let format = candidate["format"]
    let index = candidate["index"]
    return (id == nil || id == .null || id?.stringValue != nil)
        && (format == nil || format?.stringValue != nil)
        && (index == nil || index?.doubleValue != nil)
}

private func isOpenAIReasoningDetail(_ detail: JsonValue) -> Bool {
    guard let detail = isReasoningDetailObject(detail), hasValidCommonReasoningDetailFields(detail) else {
        return false
    }
    switch detail["type"]?.stringValue {
    case "reasoning.summary":
        return detail["summary"]?.stringValue != nil
    case "reasoning.encrypted":
        return detail["data"]?.stringValue != nil
    case "reasoning.text":
        let signature = detail["signature"]
        return detail["text"]?.stringValue != nil
            && (signature == nil || signature == .null || signature?.stringValue != nil)
    default:
        return false
    }
}

public struct ConvertCompletionsMessagesOptions: Sendable {
    public var grammarToolInputProperties: [String: String]?
    public init(grammarToolInputProperties: [String: String]? = nil) {
        self.grammarToolInputProperties = grammarToolInputProperties
    }
}

private struct OpenAICompatCacheControl {
    // type: "ephemeral"
    var ttl: String?

    var json: JsonValue {
        var o: JsonObject = ["type": "ephemeral"]
        if let ttl { o["ttl"] = .string(ttl) }
        return .object(o)
    }
}

/// `ResolvedOpenAICompletionsCompat`: `OpenAICompletionsCompat` with detected defaults filled in.
public struct ResolvedOpenAICompletionsCompat: Sendable {
    public var supportsStore: Bool
    public var supportsDeveloperRole: Bool
    public var supportsReasoningEffort: Bool
    public var supportsUsageInStreaming: Bool
    public var supportsFinishReason: Bool
    public var maxTokensField: MaxTokensField
    public var requiresToolResultName: Bool
    public var requiresAssistantAfterToolResult: Bool
    public var requiresThinkingAsText: Bool
    public var requiresReasoningContentOnAssistantMessages: Bool
    public var thinkingFormat: ThinkingFormat
    public var openRouterRouting: OpenRouterRouting
    public var vercelGatewayRouting: VercelGatewayRouting
    public var chatTemplateKwargs: ChatTemplateKwargs
    public var chatTemplateArgs: ChatTemplateKwargs
    public var zaiToolStream: Bool
    public var supportsStrictMode: Bool
    public var supportsOpenAIGrammarTools: Bool
    public var sendSessionAffinityHeaders: Bool
    public var sessionAffinityFormat: SessionAffinityFormat
    public var supportsLongCacheRetention: Bool
    public var cacheControlFormat: CacheControlFormat?
    public var supportsThinkingTokenBudget: Bool?
    public var thinkingTokenBudgetField: ThinkingTokenBudgetField?
    public var supportsMidConvoSystemMessages: Bool?
    public var supportsMidConvoToolAdditions: Bool?
    public var vllmPriority: Double?

    /// Swift convenience: standard OpenAI values (tests override individual fields).
    public init(
        supportsStore: Bool = true,
        supportsDeveloperRole: Bool = true,
        supportsReasoningEffort: Bool = true,
        supportsUsageInStreaming: Bool = true,
        supportsFinishReason: Bool = true,
        maxTokensField: MaxTokensField = .maxCompletionTokens,
        requiresToolResultName: Bool = false,
        requiresAssistantAfterToolResult: Bool = false,
        requiresThinkingAsText: Bool = false,
        requiresReasoningContentOnAssistantMessages: Bool = false,
        thinkingFormat: ThinkingFormat = .openai,
        openRouterRouting: OpenRouterRouting = OpenRouterRouting(json: nil),
        vercelGatewayRouting: VercelGatewayRouting = VercelGatewayRouting(json: nil),
        chatTemplateKwargs: ChatTemplateKwargs = [],
        chatTemplateArgs: ChatTemplateKwargs = [],
        zaiToolStream: Bool = false,
        supportsStrictMode: Bool = false,
        supportsOpenAIGrammarTools: Bool = false,
        sendSessionAffinityHeaders: Bool = false,
        sessionAffinityFormat: SessionAffinityFormat = .openai,
        supportsLongCacheRetention: Bool = true,
        cacheControlFormat: CacheControlFormat? = nil,
        supportsThinkingTokenBudget: Bool? = false,
        thinkingTokenBudgetField: ThinkingTokenBudgetField? = nil,
        supportsMidConvoSystemMessages: Bool? = false,
        supportsMidConvoToolAdditions: Bool? = false,
        vllmPriority: Double? = nil
    ) {
        self.supportsStore = supportsStore
        self.supportsDeveloperRole = supportsDeveloperRole
        self.supportsReasoningEffort = supportsReasoningEffort
        self.supportsUsageInStreaming = supportsUsageInStreaming
        self.supportsFinishReason = supportsFinishReason
        self.maxTokensField = maxTokensField
        self.requiresToolResultName = requiresToolResultName
        self.requiresAssistantAfterToolResult = requiresAssistantAfterToolResult
        self.requiresThinkingAsText = requiresThinkingAsText
        self.requiresReasoningContentOnAssistantMessages = requiresReasoningContentOnAssistantMessages
        self.thinkingFormat = thinkingFormat
        self.openRouterRouting = openRouterRouting
        self.vercelGatewayRouting = vercelGatewayRouting
        self.chatTemplateKwargs = chatTemplateKwargs
        self.chatTemplateArgs = chatTemplateArgs
        self.zaiToolStream = zaiToolStream
        self.supportsStrictMode = supportsStrictMode
        self.supportsOpenAIGrammarTools = supportsOpenAIGrammarTools
        self.sendSessionAffinityHeaders = sendSessionAffinityHeaders
        self.sessionAffinityFormat = sessionAffinityFormat
        self.supportsLongCacheRetention = supportsLongCacheRetention
        self.cacheControlFormat = cacheControlFormat
        self.supportsThinkingTokenBudget = supportsThinkingTokenBudget
        self.thinkingTokenBudgetField = thinkingTokenBudgetField
        self.supportsMidConvoSystemMessages = supportsMidConvoSystemMessages
        self.supportsMidConvoToolAdditions = supportsMidConvoToolAdditions
        self.vllmPriority = vllmPriority
    }
}

// ResolvedChatTemplateKwargValue = string | number | boolean | null -> JsonValue
// ChatCompletionInstructionMessageParam / KimiToolSystemMessageParam -> JsonObject

/// `OpenAIReasoningDetail` while it is being merged from stream deltas. Tracks keys assigned
/// `undefined` (by `||=` / `??=`) so the serialized key order matches upstream `JSON.stringify`.
private struct OpenAIReasoningDetail {
    var order: [String] = []
    var values = JsonObject()

    init(_ object: JsonObject) {
        for (key, value) in object { set(key, value) }
    }

    func get(_ key: String) -> JsonValue? { values[key] }

    /// Assigns a value; nil assigns `undefined` (the key keeps its position but is not serialized).
    mutating func set(_ key: String, _ value: JsonValue?) {
        if !order.contains(key) { order.append(key) }
        values[key] = value
    }

    var type: String? { values["type"]?.stringValue }

    var json: JsonValue {
        .object(JsonObject(order.compactMap { key in values[key].map { (key, $0) } }))
    }
}

private func parseOpenAIReasoningDetails(_ signature: String?) -> [JsonValue]? {
    guard let signature, !signature.isEmpty else { return nil }
    guard let parsed = try? JsonValue.parse(signature) else { return nil }
    guard case .array(let details) = parsed, details.count > 0, details.allSatisfy(isOpenAIReasoningDetail) else { return nil }
    return details
}

private func parseLegacyEncryptedReasoningDetail(_ signature: String?) -> JsonValue? {
    guard let signature, !signature.isEmpty else { return nil }
    guard let parsed = try? JsonValue.parse(signature) else { return nil }
    guard isOpenAIReasoningDetail(parsed),
          parsed["type"] == .string("reasoning.encrypted"),
          let id = parsed["id"]?.stringValue,
          !id.isEmpty,
          let data = parsed["data"]?.stringValue,
          !data.isEmpty
    else { return nil }
    return parsed
}

/// `!value` for a detail field (undefined, null, "", 0, false, NaN).
private func isFalsy(_ value: JsonValue?) -> Bool { !jsTruthy(value) }

private func fillMissingCommonReasoningDetailFields(_ target: inout OpenAIReasoningDetail, _ source: OpenAIReasoningDetail) {
    // target.id ??= source.id
    if nonNullish(target.get("id")) == nil { target.set("id", source.get("id")) }
    // target.format ||= source.format
    if isFalsy(target.get("format")) { target.set("format", source.get("format")) }
    // target.index ??= source.index
    if nonNullish(target.get("index")) == nil { target.set("index", source.get("index")) }
}

private func appendOpenAIReasoningDetail(_ details: inout [OpenAIReasoningDetail], _ detail: OpenAIReasoningDetail) {
    if var lastDetail = details.last {
        if detail.type == "reasoning.text" && lastDetail.type == "reasoning.text" {
            lastDetail.set("text", .string((lastDetail.get("text")?.stringValue ?? "") + (detail.get("text")?.stringValue ?? "")))
            // lastDetail.signature ||= detail.signature
            if isFalsy(lastDetail.get("signature")) { lastDetail.set("signature", detail.get("signature")) }
            fillMissingCommonReasoningDetailFields(&lastDetail, detail)
            details[details.count - 1] = lastDetail
            return
        }
        if detail.type == "reasoning.summary" && lastDetail.type == "reasoning.summary" {
            lastDetail.set("summary", .string((lastDetail.get("summary")?.stringValue ?? "") + (detail.get("summary")?.stringValue ?? "")))
            fillMissingCommonReasoningDetailFields(&lastDetail, detail)
            details[details.count - 1] = lastDetail
            return
        }
    }
    details.append(detail)
}

private let OPENAI_COMPLETIONS_REASONING_FIELDS = ["reasoning", "reasoning_content", "reasoning_text"]

private func isOpenAICompletionsReasoningField(_ field: String) -> Bool {
    OPENAI_COMPLETIONS_REASONING_FIELDS.contains(field)
}

private func resolveCacheRetention(_ cacheRetention: CacheRetention? = nil, _ env: ProviderEnv? = nil) -> CacheRetention {
    if let cacheRetention {
        return cacheRetention
    }
    if getProviderEnvValue("PI_CACHE_RETENTION", env) == "long" {
        return .long
    }
    return .short
}

/// Streaming scratch state of a tool call block (`StreamingToolCallBlock` minus the persisted fields).
private struct StreamingToolCallScratch {
    var argumentsStream: ToolCallArgumentsStream?
    var customInput: StreamingGrammarToolInput?
    var streamIndex: Int?
}

public func streamOpenAICompletions(
    _ model: Model,
    _ context: TranscriptContext,
    _ options: OpenAICompletionsOptions? = nil
) -> AssistantMessageEventStream {
    let stream = AssistantMessageEventStream()
    let normalizedContext = resolveTranscript(context, getCompat(model).supportsMidConvoSystemMessages)

    Task {
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

        // `reasoning_details` are replay metadata, not user-visible stream deltas.
        // Keep them in memory during streaming and serialize once when the block is finalized.
        var streamedReasoningDetails: [OpenAIReasoningDetail]?
        func applyStreamedReasoningDetails(_ contentIndex: Int) {
            guard let streamedReasoningDetails, case .thinking(var block) = output.content[contentIndex] else { return }
            block.thinkingSignature = JsonValue.array(streamedReasoningDetails.map(\.json)).serialized()
            output.content[contentIndex] = .thinking(block)
        }

        do {
            let apiKey = try getClientApiKey(model.provider, options?.apiKey, options?.headers)
            let compat = getCompat(model)
            let grammarToolInputProperties = try createGrammarToolInputProperties(
                getDeclaredTools(normalizedContext.messages),
                compat.supportsOpenAIGrammarTools
            )
            let cacheRetention = resolveCacheRetention(options?.cacheRetention, options?.env)
            let cacheSessionId = cacheRetention == CacheRetention.none ? nil : options?.sessionId
            let client = try createClient(
                model,
                normalizedContext,
                apiKey,
                options?.headers,
                options?.fetch,
                cacheSessionId,
                compat,
                options?.identity
            )
            var params: JsonValue = .object(try buildParams(
                model,
                normalizedContext,
                options,
                compat,
                cacheRetention,
                grammarToolInputProperties
            ))
            if let nextParams = try await options?.onPayload?(params, model) {
                params = nextParams
            }
            let requestOptions = RequestOptions(
                signal: options?.signal,
                timeout: options?.timeoutMs,
                maxRetries: 0
            )
            let requestParams = params
            let (data, response, _) = try await retryProviderRequest(
                { try await client.chat.completions.create(requestParams, requestOptions).withResponse() },
                ProviderRetryOptions(
                    maxRetries: options?.maxRetries,
                    maxRetryDelayMs: options?.maxRetryDelayMs,
                    signal: options?.signal
                )
            )
            try await options?.onResponse?(ProviderResponse(status: response.status, headers: headersToRecord(response.headers)), model)
            stream.push(.start(partial: output))

            guard let openaiStream = data.stream else {
                throw PiError("openaiStream is not async iterable", name: "TypeError")
            }

            var textBlock: Int?
            var thinkingBlock: Int?
            var hasFinishReason = false
            var toolCallBlocksByIndex: [Int: Int] = [:]
            var toolCallBlocksById: [String: Int] = [:]
            var scratch: [Int: StreamingToolCallScratch] = [:]

            func toolCall(_ contentIndex: Int) -> ToolCall { output.content[contentIndex].toolCallContent! }
            func setToolCall(_ contentIndex: Int, _ block: ToolCall) { output.content[contentIndex] = .toolCall(block) }

            func appendCustomToolCallInput(_ contentIndex: Int, _ input: String?, _ close: Bool) throws -> String? {
                guard let customInput = scratch[contentIndex]?.customInput else { return nil }
                let update = try customInput.update(input, close: close)
                var block = toolCall(contentIndex)
                block.arguments = update.arguments
                setToolCall(contentIndex, block)
                return update.delta
            }
            func finishBlock(_ contentIndex: Int) throws {
                switch output.content[contentIndex] {
                case .text(let block):
                    stream.push(.textEnd(
                        contentIndex: contentIndex,
                        content: block.text,
                        partial: output
                    ))
                case .thinking:
                    applyStreamedReasoningDetails(contentIndex)
                    stream.push(.thinkingEnd(
                        contentIndex: contentIndex,
                        content: output.content[contentIndex].thinkingContent!.thinking,
                        partial: output
                    ))
                case .toolCall:
                    if scratch[contentIndex]?.customInput != nil {
                        if let delta = try appendCustomToolCallInput(contentIndex, nil, true) {
                            stream.push(.toolcallDelta(
                                contentIndex: contentIndex,
                                delta: delta,
                                partial: output
                            ))
                        }
                    } else {
                        var block = toolCall(contentIndex)
                        let parsed = scratch[contentIndex]?.argumentsStream?.finish() ?? ParsedToolCallArguments(arguments: JsonObject())
                        block.arguments = parsed.arguments
                        if let argumentsError = parsed.argumentsError { block.argumentsError = argumentsError }
                        setToolCall(contentIndex, block)
                    }
                    // Finalize in-place and strip the scratch buffers so replay only
                    // carries parsed arguments.
                    scratch[contentIndex] = nil
                    stream.push(.toolcallEnd(
                        contentIndex: contentIndex,
                        toolCall: toolCall(contentIndex),
                        partial: output
                    ))
                }
            }
            func ensureTextBlock() -> Int {
                if let textBlock { return textBlock }
                output.content.append(.text(TextContent(text: "")))
                let contentIndex = output.content.count - 1
                textBlock = contentIndex
                stream.push(.textStart(contentIndex: contentIndex, partial: output))
                return contentIndex
            }
            func ensureThinkingBlock(_ thinkingSignature: String) -> Int {
                if let thinkingBlock { return thinkingBlock }
                output.content.append(.thinking(ThinkingContent(
                    thinking: "",
                    thinkingSignature: thinkingSignature
                )))
                let contentIndex = output.content.count - 1
                thinkingBlock = contentIndex
                stream.push(.thinkingStart(contentIndex: contentIndex, partial: output))
                return contentIndex
            }
            func ensureToolCallBlock(_ toolCallDelta: JsonValue) -> Int {
                let streamIndex = toolCallDelta["index"]?.doubleValue.map { Int($0) }
                let functionDelta = nonNullish(toolCallDelta["function"])
                let customDelta = nonNullish(toolCallDelta["custom"])
                let name = (nonNullish(functionDelta?["name"]) ?? nonNullish(customDelta?["name"]))?.stringValue ?? ""
                let toolCallId = toolCallDelta["id"]?.stringValue.flatMap { $0.isEmpty ? nil : $0 }
                let isCustomDelta = jsTruthy(toolCallDelta["custom"]) && !jsTruthy(toolCallDelta["function"])
                var blockIndex = streamIndex.flatMap { toolCallBlocksByIndex[$0] }
                if blockIndex == nil, let toolCallId {
                    blockIndex = toolCallBlocksById[toolCallId]
                }
                if blockIndex == nil {
                    // Note: the "input" fallback here should/must not be taken.  in case the LLM makes up
                    // a tool we don't knwo about, we at least have a place to stash our stuff.
                    let customInputProperty = isCustomDelta ? (grammarToolInputProperties[name] ?? "input") : nil
                    let hasCustomInput = customInputProperty != nil
                    output.content.append(.toolCall(ToolCall(
                        id: toolCallId ?? "",
                        name: name,
                        arguments: hasCustomInput ? [customInputProperty!: ""] : JsonObject()
                    )))
                    let contentIndex = output.content.count - 1
                    scratch[contentIndex] = StreamingToolCallScratch(
                        argumentsStream: hasCustomInput ? nil : ToolCallArgumentsStream(),
                        customInput: hasCustomInput
                            ? StreamingGrammarToolInput(property: customInputProperty!)
                            : nil,
                        streamIndex: streamIndex
                    )
                    if let streamIndex {
                        toolCallBlocksByIndex[streamIndex] = contentIndex
                    }
                    if let toolCallId {
                        toolCallBlocksById[toolCallId] = contentIndex
                    }
                    blockIndex = contentIndex
                    stream.push(.toolcallStart(
                        contentIndex: contentIndex,
                        partial: output
                    ))
                }
                let contentIndex = blockIndex!
                if let streamIndex, scratch[contentIndex]?.streamIndex == nil {
                    scratch[contentIndex, default: StreamingToolCallScratch()].streamIndex = streamIndex
                    toolCallBlocksByIndex[streamIndex] = contentIndex
                }
                if let toolCallId {
                    toolCallBlocksById[toolCallId] = contentIndex
                }
                var block = toolCall(contentIndex)
                if block.name.isEmpty && !name.isEmpty {
                    block.name = name
                    setToolCall(contentIndex, block)
                }
                if isCustomDelta && scratch[contentIndex]?.customInput == nil {
                    let customInputProperty = grammarToolInputProperties[block.name] ?? "input"
                    block.arguments = [customInputProperty: ""]
                    setToolCall(contentIndex, block)
                    scratch[contentIndex, default: StreamingToolCallScratch()].customInput = StreamingGrammarToolInput(property: customInputProperty)
                    scratch[contentIndex]?.argumentsStream = nil
                }
                return contentIndex
            }

            for try await chunk in openaiStream {
                await options?.onProviderStreamEvent?(chunk, model)
                guard case .object(let chunkObject) = chunk else { continue }

                // OpenAI documents ChatCompletionChunk.id as the unique chat completion identifier,
                // and each chunk in a streamed completion carries the same id.
                if output.responseId == nil || output.responseId!.isEmpty {
                    output.responseId = chunkObject["id"]?.stringValue
                }
                if case .string(let chunkModel)? = chunkObject["model"], !chunkModel.isEmpty, chunkModel != model.id {
                    if output.responseModel == nil || output.responseModel!.isEmpty {
                        output.responseModel = chunkModel
                    }
                }
                if jsTruthy(chunkObject["usage"]) {
                    output.usage = parseChunkUsage(chunkObject["usage"]!, model)
                }

                guard case .array(let choices)? = chunkObject["choices"], let choice = choices.first, jsTruthy(choice) else { continue }

                // Fallback: some providers (e.g., Moonshot) return usage
                // in choice.usage instead of the standard chunk.usage
                if !jsTruthy(chunkObject["usage"]) && jsTruthy(choice["usage"]) {
                    output.usage = parseChunkUsage(choice["usage"]!, model)
                }

                if let finishReason = choice["finish_reason"], jsTruthy(finishReason) {
                    let reason = jsString(finishReason)
                    output.rawStopReason = reason
                    let finishReasonResult = mapStopReason(reason)
                    output.stopReason = finishReasonResult.stopReason
                    if let errorMessage = finishReasonResult.errorMessage {
                        output.errorMessage = errorMessage
                    }
                    hasFinishReason = true
                }

                if let delta = choice["delta"], jsTruthy(delta) {
                    // Handle reasoning before content: some proxies (e.g. LiteLLM) aggregate reasoning and
                    // answer into one delta, and the thinking block must precede the text block.
                    // Some endpoints return reasoning in reasoning_content (llama.cpp),
                    // or reasoning (other openai compatible endpoints)
                    // Use the first non-empty reasoning field to avoid duplication
                    // (e.g., chutes.ai returns both reasoning_content and reasoning with same content)
                    let reasoningFields = ["reasoning_content", "reasoning", "reasoning_text"]
                    var foundReasoningField: String?
                    for field in reasoningFields {
                        if case .string(let value)? = delta[field], !value.isEmpty {
                            foundReasoningField = field
                            break
                        }
                    }

                    if let foundReasoningField {
                        if case .string(let reasoningDelta)? = delta[foundReasoningField], !reasoningDelta.isEmpty {
                            let thinkingSignature =
                                model.provider == "opencode-go" && foundReasoningField == "reasoning"
                                    ? "reasoning_content"
                                    : foundReasoningField
                            let contentIndex = ensureThinkingBlock(thinkingSignature)
                            if case .thinking(var block) = output.content[contentIndex] {
                                block.thinking += reasoningDelta
                                output.content[contentIndex] = .thinking(block)
                            }
                            stream.push(.thinkingDelta(
                                contentIndex: contentIndex,
                                delta: reasoningDelta,
                                partial: output
                            ))
                        }
                    }

                    if case .array(let reasoningDetails)? = delta["reasoning_details"] {
                        for detail in reasoningDetails {
                            if !isOpenAIReasoningDetail(detail) { continue }
                            _ = ensureThinkingBlock("")
                            var details = streamedReasoningDetails ?? []
                            // Keep provider replay data in the existing signature slot. OpenRouter streams
                            // reasoning_details as deltas: consecutive text/summary deltas are merged into
                            // logical entries, while encrypted entries remain opaque and discrete.
                            appendOpenAIReasoningDetail(&details, OpenAIReasoningDetail(detail.objectValue!))
                            streamedReasoningDetails = details
                        }
                    }

                    if case .string(let content)? = delta["content"], !content.isEmpty {
                        let contentIndex = ensureTextBlock()
                        if case .text(var block) = output.content[contentIndex] {
                            block.text += content
                            output.content[contentIndex] = .text(block)
                        }
                        stream.push(.textDelta(
                            contentIndex: contentIndex,
                            delta: content,
                            partial: output
                        ))
                    }

                    if let toolCalls = delta["tool_calls"], jsTruthy(toolCalls) {
                        guard case .array(let toolCallDeltas) = toolCalls else {
                            throw PiError("choice.delta.tool_calls is not iterable", name: "TypeError")
                        }
                        for toolCallDelta in toolCallDeltas {
                            if toolCallDelta.isNull {
                                throw PiError("Cannot read properties of null (reading 'index')", name: "TypeError")
                            }
                            let contentIndex = ensureToolCallBlock(toolCallDelta)
                            var block = toolCall(contentIndex)
                            if block.id.isEmpty, let id = toolCallDelta["id"]?.stringValue, !id.isEmpty {
                                block.id = id
                                setToolCall(contentIndex, block)
                                toolCallBlocksById[id] = contentIndex
                            }
                            let functionDelta = nonNullish(toolCallDelta["function"])
                            let customDelta = nonNullish(toolCallDelta["custom"])
                            let name = (nonNullish(functionDelta?["name"]) ?? nonNullish(customDelta?["name"]))?.stringValue
                            if block.name.isEmpty, let name, !name.isEmpty {
                                block.name = name
                                setToolCall(contentIndex, block)
                            }

                            var toolDelta = ""
                            if case .string(let arguments)? = functionDelta?["arguments"], !arguments.isEmpty {
                                toolDelta = arguments
                                let argumentsStream = scratch[contentIndex]?.argumentsStream ?? ToolCallArgumentsStream()
                                scratch[contentIndex, default: StreamingToolCallScratch()].argumentsStream = argumentsStream
                                var updated = toolCall(contentIndex)
                                updated.arguments = argumentsStream.append(arguments)
                                setToolCall(contentIndex, updated)
                            } else if case .string(let input)? = customDelta?["input"], !input.isEmpty {
                                toolDelta = try appendCustomToolCallInput(contentIndex, input, false) ?? ""
                            }
                            stream.push(.toolcallDelta(
                                contentIndex: contentIndex,
                                delta: toolDelta,
                                partial: output
                            ))
                        }
                    }
                }
            }

            for contentIndex in output.content.indices {
                try finishBlock(contentIndex)
            }
            if options?.signal?.aborted == true {
                throw PiError("Request was aborted")
            }

            if output.stopReason == .aborted {
                throw PiError("Request was aborted")
            }
            if !hasFinishReason && !compat.supportsFinishReason {
                output.stopReason = output.content.contains(where: { $0.type == "toolCall" }) ? .toolUse : .stop
            }
            if output.stopReason == .error {
                throw PiError(output.errorMessage.flatMap { $0.isEmpty ? nil : $0 } ?? "Provider returned an error stop reason")
            }
            if (compat.supportsFinishReason && !hasFinishReason) || output.stopReason == .pending {
                throw PiError("Stream ended without finish_reason")
            }

            stream.push(.done(reason: output.stopReason, message: output))
            stream.end()
        } catch {
            for contentIndex in output.content.indices {
                if case .thinking = output.content[contentIndex] {
                    applyStreamedReasoningDetails(contentIndex)
                }
                // Streaming scratch buffers are only used during parsing; never persist them.
                // (Swift: they live in a side table that is discarded with this task.)
            }
            output.stopReason = options?.signal?.aborted == true ? .aborted : .error
            output.errorMessage = formatProviderError(normalizeProviderError(error))
            // Some providers via OpenRouter give additional information in this field.
            // normalizeProviderError already stringifies the parsed body (error.error)
            // into errorMessage, so only append the raw metadata when it is not already
            // present to avoid double-printing it.
            if let apiError = error as? OpenAI.APIError,
               let rawMetadata = apiError.error?["metadata"]?["raw"],
               jsTruthy(rawMetadata),
               !output.errorMessage!.contains(jsString(rawMetadata)) {
                output.errorMessage! += "\n\(jsString(rawMetadata))"
            }
            stream.push(.error(reason: output.stopReason, error: output))
            stream.end()
        }
    }

    return stream
}

/// Swift: upstream throws synchronously when no API key resolves; behind the lazy API wrapper that
/// surfaces as a setup error event. A Swift `StreamFunction` cannot throw, so the same error event is
/// returned on the stream.
public func streamSimpleOpenAICompletions(
    _ model: Model,
    _ context: TranscriptContext,
    _ options: SimpleStreamOptions? = nil
) -> AssistantMessageEventStream {
    do {
        _ = try getClientApiKey(model.provider, options?.apiKey, options?.headers)
    } catch {
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

    var base = buildBaseOptions(model, context, options, options?.apiKey)
    base.toolChoice = options?.toolChoice
    let clampedReasoning = options?.reasoning.map { clampThinkingLevel(model, ModelThinkingLevel($0)) }
    let reasoningEffort = clampedReasoning == .off ? nil : clampedReasoning?.thinkingLevel

    if let reasoningEffort {
        base.extra["reasoningEffort"] = .string(reasoningEffort.rawValue)
    }
    base.thinkingBudgets = options?.thinkingBudgets
    return streamOpenAICompletions(model, context, base)
}

/// `Object.assign(headers, { [key]: value })` on an ordered header record.
private func assignHeader(_ headers: inout [(String, String?)], _ key: String, _ value: String?) {
    if let index = headers.firstIndex(where: { $0.0 == key }) {
        headers[index].1 = value
    } else {
        headers.append((key, value))
    }
}

private func createClient(
    _ model: Model,
    _ context: TranscriptContext,
    _ apiKey: String,
    _ optionsHeaders: ProviderHeaders? = nil,
    _ fetch: FetchFunction? = nil,
    _ sessionId: String? = nil,
    _ compat: ResolvedOpenAICompletionsCompat? = nil,
    _ identity: ClientIdentity? = nil
) throws -> OpenAI {
    let compat = compat ?? getCompat(model)
    var headers = getIdentityHeaders(.init(model), identity)
    for (key, value) in model.headers ?? [] { assignHeader(&headers, key, value) }
    if model.provider == "github-copilot" {
        let hasImages = hasCopilotVisionInput(context.messages)
        let copilotHeaders = buildCopilotDynamicHeaders(
            messages: context.messages,
            hasImages: hasImages
        )
        for (key, value) in copilotHeaders { assignHeader(&headers, key, value) }
    }

    if let sessionId, !sessionId.isEmpty, compat.sendSessionAffinityHeaders {
        if compat.sessionAffinityFormat == .openrouter {
            assignHeader(&headers, "x-session-id", sessionId)
        } else {
            if compat.sessionAffinityFormat == .openai {
                assignHeader(&headers, "session_id", sessionId)
            }
            assignHeader(&headers, "x-client-request-id", sessionId)
            assignHeader(&headers, "x-session-affinity", sessionId)
        }
    }

    // Merge options headers last so they can override defaults
    if let optionsHeaders {
        for (key, value) in optionsHeaders { assignHeader(&headers, key, value) }
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
    _ options: OpenAICompletionsOptions? = nil,
    _ compatInput: ResolvedOpenAICompletionsCompat? = nil,
    _ cacheRetentionInput: CacheRetention? = nil,
    _ grammarToolInputPropertiesInput: [String: String]? = nil
) throws -> JsonObject {
    let compat = compatInput ?? getCompat(model)
    let cacheRetention = cacheRetentionInput ?? resolveCacheRetention(options?.cacheRetention, options?.env)
    let grammarToolInputProperties = try grammarToolInputPropertiesInput ?? createGrammarToolInputProperties(
        getDeclaredTools(context.messages),
        compat.supportsOpenAIGrammarTools
    )
    let reasoningEffort = completionsReasoningEffort(options)
    let transcriptTools = resolveTranscriptTools(
        context.messages,
        compat.supportsMidConvoSystemMessages == true && compat.supportsMidConvoToolAdditions == true
            ? .additions
            : .none
    )
    var messages = try convertMessages(model, context, compat, ConvertCompletionsMessagesOptions(
        grammarToolInputProperties: grammarToolInputProperties
    ))
    let cacheControl = getCompatCacheControl(compat, cacheRetention)

    var params: JsonObject = [
        "model": .string(model.id),
        "messages": .array(messages.map(JsonValue.object)),
        "stream": true,
    ]
    if (model.baseUrl.contains("api.openai.com") && cacheRetention != .none)
        || (cacheRetention == .long && compat.supportsLongCacheRetention) {
        if let promptCacheKey = clampOpenAIPromptCacheKey(options?.sessionId) {
            params["prompt_cache_key"] = .string(promptCacheKey)
        }
    }
    if cacheRetention == .long && compat.supportsLongCacheRetention {
        params["prompt_cache_retention"] = "24h"
    }

    if compat.supportsUsageInStreaming != false {
        params["stream_options"] = ["include_usage": true]
    }

    if compat.supportsStore {
        params["store"] = false
    }

    if let maxTokens = options?.maxTokens, maxTokens != 0 {
        if compat.maxTokensField == .maxTokens {
            // Deprecated by OpenAI, but some OpenAI-compatible providers only accept max_tokens.
            params["max_tokens"] = .number(Double(maxTokens))
        } else {
            params["max_completion_tokens"] = .number(Double(maxTokens))
        }
    }

    if let temperature = options?.temperature {
        params["temperature"] = .number(temperature)
    }

    var tools: [JsonObject]?
    if transcriptTools.requestTools.count > 0 {
        tools = try convertTools(transcriptTools.requestTools, compat)
        params["tools"] = .array(tools!.map(JsonValue.object))
        if compat.zaiToolStream {
            params["tool_stream"] = true
        }
    } else if hasToolHistory(context.messages) {
        // Anthropic (via LiteLLM/proxy) requires tools param when conversation has tool_calls/tool_results
        tools = []
        params["tools"] = .array([])
    }

    if let cacheControl {
        applyAnthropicCacheControl(&messages, &tools, cacheControl)
        params["messages"] = .array(messages.map(JsonValue.object))
        if let tools { params["tools"] = .array(tools.map(JsonValue.object)) }
    }

    if let toolChoice = completionsToolChoice(options), jsTruthy(toolChoice) {
        params["tool_choice"] = toolChoice
    }

    if let vllmPriority = compat.vllmPriority {
        params["priority"] = .number(vllmPriority)
    }

    let thinkingTokenBudgetField = resolveThinkingTokenBudgetField(compat)
    let thinkingBudget = resolveClampedThinkingBudget(model, options, params)
    let thinkingLevelMap = model.thinkingLevelMap
    /// `model.thinkingLevelMap?.[level]`: nil = undefined, `.some(nil)` = null.
    func mapped(_ level: ThinkingLevel) -> String?? { thinkingLevelMap?[ModelThinkingLevel(level)] }
    let mappedOff: String?? = thinkingLevelMap?[.off]
    /// `model.thinkingLevelMap?.off !== null`
    let offIsNotNull: Bool = { if case .some(.none) = mappedOff { return false } else { return true } }()

    if compat.thinkingFormat == .zai && model.reasoning {
        params["thinking"] = reasoningEffort != nil ? ["type": "enabled", "clear_thinking": false] : ["type": "disabled"]
        if let reasoningEffort, compat.supportsReasoningEffort {
            let mappedEffort = mapped(reasoningEffort)
            let effort: String? = mappedEffort == nil ? reasoningEffort.rawValue : mappedEffort!
            if let effort {
                params["reasoning_effort"] = .string(effort)
            }
        }
    } else if compat.thinkingFormat == .qwen && model.reasoning {
        params["enable_thinking"] = .bool(reasoningEffort != nil)
        if let reasoningEffort, compat.supportsReasoningEffort {
            let effort = (mapped(reasoningEffort) ?? nil) ?? reasoningEffort.rawValue
            params["reasoning_effort"] = .string(effort)
        }
    } else if compat.thinkingFormat == .qwenChatTemplate && model.reasoning {
        params["chat_template_kwargs"] = [
            "enable_thinking": .bool(reasoningEffort != nil),
            "preserve_thinking": true,
        ]
    } else if compat.thinkingFormat == .chatTemplate && model.reasoning {
        if let chatTemplateKwargs = buildChatTemplateValues(model, options, compat.chatTemplateKwargs, thinkingBudget) {
            params["chat_template_kwargs"] = .object(chatTemplateKwargs)
        }
    } else if compat.thinkingFormat == .baseten && model.reasoning {
        if let chatTemplateArgs = buildChatTemplateValues(model, options, compat.chatTemplateArgs, thinkingBudget) {
            params["chat_template_args"] = .object(chatTemplateArgs)
        }
        if compat.supportsReasoningEffort {
            let requestedEffort = reasoningEffort
            let mappedEffort: String?? = requestedEffort != nil ? mapped(requestedEffort!) : mappedOff
            let effort: String? = mappedEffort == nil ? requestedEffort?.rawValue : mappedEffort!
            if let effort {
                params["reasoning_effort"] = .string(effort)
            }
        }
    } else if compat.thinkingFormat == .deepseek && model.reasoning {
        if reasoningEffort != nil {
            params["thinking"] = ["type": "enabled"]
        } else if offIsNotNull {
            params["thinking"] = ["type": "disabled"]
        }
        if let reasoningEffort, compat.supportsReasoningEffort {
            params["reasoning_effort"] = .string((mapped(reasoningEffort) ?? nil) ?? reasoningEffort.rawValue)
        }
    } else if compat.thinkingFormat == .openrouter && model.reasoning {
        // OpenRouter normalizes reasoning across providers via a nested reasoning object.
        if let reasoningEffort {
            params["reasoning"] = [
                "effort": .string((mapped(reasoningEffort) ?? nil) ?? reasoningEffort.rawValue),
            ]
        } else if offIsNotNull {
            params["reasoning"] = ["effort": .string((mappedOff ?? nil) ?? "none")]
        }
    } else if compat.thinkingFormat == .antLing && model.reasoning && reasoningEffort != nil {
        if case .some(.some(let effort)) = mapped(reasoningEffort!) {
            params["reasoning"] = ["effort": .string(effort)]
        }
    } else if compat.thinkingFormat == .together && model.reasoning {
        params["reasoning"] = ["enabled": .bool(reasoningEffort != nil)]
        if let reasoningEffort, compat.supportsReasoningEffort {
            params["reasoning_effort"] = .string((mapped(reasoningEffort) ?? nil) ?? reasoningEffort.rawValue)
        }
    } else if compat.thinkingFormat == .stringThinking && model.reasoning {
        if let reasoningEffort {
            params["thinking"] = .string((mapped(reasoningEffort) ?? nil) ?? reasoningEffort.rawValue)
        } else if offIsNotNull {
            params["thinking"] = .string((mappedOff ?? nil) ?? "none")
        }
    } else if let reasoningEffort, model.reasoning && compat.supportsReasoningEffort {
        // OpenAI-style reasoning_effort
        params["reasoning_effort"] = .string((mapped(reasoningEffort) ?? nil) ?? reasoningEffort.rawValue)
    } else if reasoningEffort == nil && model.reasoning && compat.supportsReasoningEffort {
        if case .some(.some(let offValue)) = mappedOff {
            params["reasoning_effort"] = .string(offValue)
        }
    }

    // Cap reasoning with a top-level budget field. Independent of thinkingFormat: the
    // same server can serve zai, qwen or chat-template models. Reasoning and the answer
    // share max_tokens here, so an uncapped reasoning phase can consume the whole
    // response and leave no answer and no tool call.
    if let thinkingTokenBudgetField, let thinkingBudget {
        params[thinkingTokenBudgetField.rawValue] = .number(Double(thinkingBudget))
    }

    // OpenRouter provider routing preferences
    if let openRouterRouting = model.compat?["openRouterRouting"], jsTruthy(openRouterRouting) {
        params["provider"] = openRouterRouting
    }

    // Vercel AI Gateway provider routing preferences
    if let routing = model.compat?["vercelGatewayRouting"], jsTruthy(routing) {
        let only = routing["only"]
        let order = routing["order"]
        if jsTruthy(only) || jsTruthy(order) {
            var gatewayOptions = JsonObject()
            if jsTruthy(only) { gatewayOptions["only"] = only }
            if jsTruthy(order) { gatewayOptions["order"] = order }
            params["providerOptions"] = ["gateway": .object(gatewayOptions)]
        }
    }

    // Last so model and request sampling parameters override named request fields.
    if let samplingParams = resolveSamplingParams(model, reasoningEffort.map(ModelThinkingLevel.init) ?? .off, options?.samplingParams) {
        for (key, value) in samplingParams { params[key] = value }
    }

    return params
}

private func resolveThinkingTokenBudgetField(
    _ compat: ResolvedOpenAICompletionsCompat
) -> ThinkingTokenBudgetField? {
    if let thinkingTokenBudgetField = compat.thinkingTokenBudgetField { return thinkingTokenBudgetField }
    if compat.supportsThinkingTokenBudget == true { return .thinkingTokenBudget }
    return nil
}

private func resolveClampedThinkingBudget(
    _ model: Model,
    _ options: OpenAICompletionsOptions?,
    _ params: JsonObject
) -> Int? {
    guard let reasoningEffort = completionsReasoningEffort(options), model.reasoning else { return nil }
    let ceiling = nonNullish(params["max_tokens"])?.intValue ?? nonNullish(params["max_completion_tokens"])?.intValue ?? model.maxTokens
    let budget = clampThinkingBudgetToAnswerRoom(
        thinkingBudgetForLevel(reasoningEffort, options?.thinkingBudgets),
        ceiling
    )
    return budget > 0 ? budget : nil
}

private func buildChatTemplateValues(
    _ model: Model,
    _ options: OpenAICompletionsOptions?,
    _ values: ChatTemplateKwargs,
    _ thinkingBudget: Int? = nil
) -> JsonObject? {
    var resolvedValues = JsonObject()

    for (key, value) in values {
        if let resolved = resolveChatTemplateKwargValue(model, options, value, thinkingBudget) {
            resolvedValues[key] = resolved
        }
    }

    return resolvedValues.count > 0 ? resolvedValues : nil
}

private func resolveChatTemplateKwargValue(
    _ model: Model,
    _ options: OpenAICompletionsOptions?,
    _ value: ChatTemplateKwargValue,
    _ thinkingBudget: Int? = nil
) -> JsonValue? {
    guard case .variable(let variable, let omitWhenOff) = value else {
        return value.json
    }

    let reasoningEffort = completionsReasoningEffort(options)
    if reasoningEffort == nil && omitWhenOff == true {
        return nil
    }
    if variable == .thinkingEnabled {
        return .bool(reasoningEffort != nil)
    }
    if variable == .thinkingBudget {
        return thinkingBudget.map { .number(Double($0)) }
    }

    let mappedValue: String?? = reasoningEffort != nil
        ? model.thinkingLevelMap?[ModelThinkingLevel(reasoningEffort!)]
        : model.thinkingLevelMap?[.off]
    switch mappedValue {
    case .none: return reasoningEffort.map { .string($0.rawValue) }
    case .some(.none): return nil
    case .some(.some(let mapped)): return .string(mapped)
    }
}

private func getCompatCacheControl(
    _ compat: ResolvedOpenAICompletionsCompat,
    _ cacheRetention: CacheRetention
) -> OpenAICompatCacheControl? {
    if compat.cacheControlFormat != .anthropic || cacheRetention == .none {
        return nil
    }

    let ttl = cacheRetention == .long && compat.supportsLongCacheRetention ? "1h" : nil
    return OpenAICompatCacheControl(ttl: ttl)
}

private func applyAnthropicCacheControl(
    _ messages: inout [JsonObject],
    _ tools: inout [JsonObject]?,
    _ cacheControl: OpenAICompatCacheControl
) {
    addCacheControlToSystemPrompt(&messages, cacheControl)
    addCacheControlToLastTool(&tools, cacheControl)
    addCacheControlToLastConversationMessage(&messages, cacheControl)
}

private func addCacheControlToSystemPrompt(
    _ messages: inout [JsonObject],
    _ cacheControl: OpenAICompatCacheControl
) {
    for index in messages.indices {
        let role = messages[index]["role"]?.stringValue
        if role == "system" || role == "developer" {
            _ = addCacheControlToInstructionMessage(&messages[index], cacheControl)
            return
        }
    }
}

private func addCacheControlToLastConversationMessage(
    _ messages: inout [JsonObject],
    _ cacheControl: OpenAICompatCacheControl
) {
    for index in messages.indices.reversed() {
        let role = messages[index]["role"]?.stringValue
        if role == "user" || role == "assistant" || role == "tool" {
            if addCacheControlToMessage(&messages[index], cacheControl) {
                return
            }
        }
    }
}

private func addCacheControlToLastTool(
    _ tools: inout [JsonObject]?,
    _ cacheControl: OpenAICompatCacheControl
) {
    guard var list = tools, list.count > 0 else {
        return
    }

    list[list.count - 1]["cache_control"] = cacheControl.json
    tools = list
}

private func addCacheControlToInstructionMessage(
    _ message: inout JsonObject,
    _ cacheControl: OpenAICompatCacheControl
) -> Bool {
    addCacheControlToTextContent(&message, cacheControl)
}

private func addCacheControlToMessage(
    _ message: inout JsonObject,
    _ cacheControl: OpenAICompatCacheControl
) -> Bool {
    let role = message["role"]?.stringValue
    if role == "user" || role == "assistant" || role == "tool" {
        return addCacheControlToTextContent(&message, cacheControl)
    }
    return false
}

private func addCacheControlToTextContent(
    _ message: inout JsonObject,
    _ cacheControl: OpenAICompatCacheControl
) -> Bool {
    let content = message["content"]
    if case .string(let text)? = content {
        if text.isEmpty {
            return false
        }
        message["content"] = .array([
            [
                "type": "text",
                "text": .string(text),
                "cache_control": cacheControl.json,
            ],
        ])
        return true
    }

    guard case .array(var parts)? = content else {
        return false
    }

    for index in parts.indices.reversed() {
        if parts[index]["type"] == .string("text") {
            parts[index]["cache_control"] = cacheControl.json
            message["content"] = .array(parts)
            return true
        }
    }

    return false
}

/// `str.replace(/[^a-zA-Z0-9_-]/g, "_")` over UTF-16 code units.
private func replaceDisallowedToolCallIdChars(_ text: String) -> String {
    let units = text.utf16.map { unit -> UInt16 in
        switch unit {
        case 0x30...0x39, 0x41...0x5A, 0x61...0x7A, 0x5F, 0x2D: return unit
        default: return 0x5F
        }
    }
    return String(decoding: units, as: UTF16.self)
}

public func convertMessages(
    _ model: Model,
    _ context: TranscriptContext,
    _ compat: ResolvedOpenAICompletionsCompat,
    _ options: ConvertCompletionsMessagesOptions? = nil
) throws -> [JsonObject] {
    let normalizedContext = resolveTranscript(context, compat.supportsMidConvoSystemMessages)
    var params: [JsonObject] = []

    let normalizeToolCallId: (String) -> String = { id in
        // Handle pipe-separated IDs from OpenAI Responses API
        // Format: {call_id}|{id} where {id} can be 400+ chars with special chars (+, /, =)
        // These come from providers like github-copilot, openai-codex, opencode
        // Extract just the call_id part and normalize it
        // Multiple tool calls in the same turn can share call_id but differ by item_id.
        // Preserve item-level uniqueness when replaying into Chat Completions, which
        // requires distinct tool call ids.
        if let separator = id.utf16.firstIndex(of: 0x7C) {
            // Sanitize to allowed chars and truncate to 40 chars (OpenAI limit)
            let separatorIndex = id.utf16.distance(from: id.utf16.startIndex, to: separator)
            let callId = replaceDisallowedToolCallIdChars(jsSlice(id, 0, separatorIndex))
            let itemId = replaceDisallowedToolCallIdChars(jsSlice(id, separatorIndex + 1))
            let combinedId = itemId.utf16.count > 0 ? "\(callId)_\(itemId)" : callId
            if combinedId.utf16.count <= 40 {
                return combinedId
            }
            let hash = jsSlice(shortHash(id), 0, 8)
            let prefix = jsSlice(callId, 0, max(1, 40 - hash.utf16.count - 1))
            return "\(prefix)_\(hash)"
        }

        if model.provider == "openai" { return id.utf16.count > 40 ? jsSlice(id, 0, 40) : id }
        return id
    }

    let transformedMessages = transformMessages(normalizedContext.messages, model, { id, _, _ in normalizeToolCallId(id) })
    let transcriptTools = resolveTranscriptTools(
        normalizedContext.messages,
        compat.supportsMidConvoSystemMessages == true && compat.supportsMidConvoToolAdditions == true
            ? .additions
            : .none
    )
    let instructionRole = model.reasoning && compat.supportsDeveloperRole ? "developer" : "system"

    var lastRole: String?
    var systemIndex = 0

    var i = 0
    while i < transformedMessages.count {
        defer { i += 1 }
        let msg = transformedMessages[i]
        // Some providers don't allow user messages directly after tool results
        // Insert a synthetic assistant message to bridge the gap
        if compat.requiresAssistantAfterToolResult && lastRole == "toolResult" && msg.role == "user" {
            params.append([
                "role": "assistant",
                "content": "I have processed the tool results.",
            ])
        }

        switch msg {
        case .system(let system):
            // transformMessages keeps system messages in order, so their position matches the transcript.
            let currentSystemIndex = systemIndex
            systemIndex += 1
            let addedTools = currentSystemIndex >= transcriptTools.foldedSystemMessages ? (system.toolsAdded ?? []) : []
            if addedTools.count > 0 {
                let kimiToolMessage: JsonObject = [
                    "role": "system",
                    "tools": .array(try convertTools(addedTools, compat).map(JsonValue.object)),
                ]
                params.append(kimiToolMessage)
            }
            let text = i == 0 ? getSystemMessageText(system) : renderSystemMessageUpdate(system)
            if text.utf16.count > 0 {
                params.append(["role": .string(instructionRole), "content": .string(sanitizeSurrogates(text))])
            }
        case .user(let user):
            switch user.content {
            case .string(let text):
                params.append([
                    "role": "user",
                    "content": .string(sanitizeSurrogates(text)),
                ])
            case .blocks(let blocks):
                let content: [JsonValue] = blocks
                    .filter { item in
                        if case .text(let text) = item { return !text.text.isEmpty }
                        return true
                    }
                    .map { item -> JsonValue in
                        switch item {
                        case .text(let text):
                            return [
                                "type": "text",
                                "text": .string(sanitizeSurrogates(text.text)),
                            ]
                        case .image(let image):
                            return [
                                "type": "image_url",
                                "image_url": [
                                    "url": .string("data:\(image.mimeType);base64,\(image.data)"),
                                ],
                            ]
                        }
                    }
                if content.count == 0 { continue }
                params.append([
                    "role": "user",
                    "content": .array(content),
                ])
            }
        case .assistant(let assistant):
            // Some providers don't accept null content, use empty string instead
            var assistantMsg: JsonObject = [
                "role": "assistant",
                "content": compat.requiresAssistantAfterToolResult ? "" : .null,
            ]

            let assistantTextParts: [JsonValue] = assistant.content
                .compactMap(\.textContent)
                .filter { !jsTrim($0.text).isEmpty }
                .map { block in
                    [
                        "type": "text",
                        "text": .string(sanitizeSurrogates(block.text)),
                    ]
                }
            let assistantText = assistantTextParts.map { $0["text"]!.stringValue! }.joined()

            let thinkingBlocks = assistant.content.compactMap(\.thinkingContent)
            let toolCalls = assistant.content.compactMap(\.toolCallContent)
            let signedReasoningDetails = thinkingBlocks
                .lazy
                .compactMap { parseOpenAIReasoningDetails($0.thinkingSignature) }
                .first
            let legacyReasoningDetails = toolCalls
                .compactMap { parseLegacyEncryptedReasoningDetail($0.thoughtSignature) }
            let preservedReasoningDetails =
                signedReasoningDetails ?? (legacyReasoningDetails.count > 0 ? legacyReasoningDetails : nil)

            let nonEmptyThinkingBlocks = thinkingBlocks.filter { !jsTrim($0.thinking).isEmpty }
            if nonEmptyThinkingBlocks.count > 0 {
                if compat.requiresThinkingAsText {
                    // Convert thinking blocks to plain text (no tags to avoid model mimicking them)
                    let thinkingText = nonEmptyThinkingBlocks
                        .map { sanitizeSurrogates($0.thinking) }
                        .joined(separator: "\n\n")
                    assistantMsg["content"] = .array([["type": "text", "text": .string(thinkingText)]] + assistantTextParts)
                } else {
                    // Always send assistant content as a plain string (OpenAI Chat Completions
                    // API standard format). Sending as an array of {type:"text", text:"..."}
                    // objects is non-standard and causes some models (e.g. DeepSeek V3.2 via
                    // NVIDIA NIM) to mirror the content-block structure literally in their
                    // output, producing recursive nesting like [{'type':'text','text':'[{...}]'}].
                    if assistantText.utf16.count > 0 {
                        assistantMsg["content"] = .string(assistantText)
                    }

                    // reasoning_details is the structured alternative to a raw reasoning field.
                    if preservedReasoningDetails == nil {
                        // Use the signature from the first thinking block if available (for llama.cpp server + gpt-oss)
                        var signature = nonEmptyThinkingBlocks[0].thinkingSignature
                        if model.provider == "opencode-go" && signature == "reasoning" {
                            signature = "reasoning_content"
                        }
                        if let signature, !signature.isEmpty, isOpenAICompletionsReasoningField(signature) {
                            assistantMsg[signature] = .string(nonEmptyThinkingBlocks.map(\.thinking).joined(separator: "\n"))
                        }
                    }
                }
            } else if assistantText.utf16.count > 0 {
                // Always send assistant content as a plain string (OpenAI Chat Completions
                // API standard format). Sending as an array of {type:"text", text:"..."}
                // objects is non-standard and causes some models (e.g. DeepSeek V3.2 via
                // NVIDIA NIM) to mirror the content-block structure literally in their
                // output, producing recursive nesting like [{'type':'text','text':'[{...}]'}].
                assistantMsg["content"] = .string(assistantText)
            }

            if toolCalls.count > 0 {
                assistantMsg["tool_calls"] = .array(try toolCalls.map { tc -> JsonValue in
                    if let customInputProperty = options?.grammarToolInputProperties?[tc.name] {
                        return [
                            "id": .string(tc.id),
                            "type": "custom",
                            "custom": [
                                "name": .string(tc.name),
                                "input": .string(sanitizeSurrogates(try getGrammarToolInput(tc.name, tc.arguments, customInputProperty))),
                            ],
                        ]
                    }
                    return [
                        "id": .string(tc.id),
                        "type": "function",
                        "function": [
                            "name": .string(tc.name),
                            "arguments": .string(JsonValue.object(tc.arguments).serialized()),
                        ],
                    ]
                })
            }
            if let preservedReasoningDetails {
                assistantMsg["reasoning_details"] = .array(preservedReasoningDetails)
            }
            if compat.requiresReasoningContentOnAssistantMessages
                && model.reasoning
                && assistantMsg["reasoning_content"] == nil {
                assistantMsg["reasoning_content"] = ""
            }
            // Skip assistant messages that have no content and no tool calls.
            // Some providers require "either content or tool_calls, but not none".
            // Other providers also don't accept empty assistant messages.
            // This handles aborted assistant responses that got no content.
            let hasContent: Bool
            switch assistantMsg["content"] {
            case .string(let text)?: hasContent = text.utf16.count > 0
            case .array(let parts)?: hasContent = parts.count > 0
            default: hasContent = false
            }
            if !hasContent && assistantMsg["tool_calls"] == nil {
                continue
            }
            params.append(assistantMsg)
        case .toolResult:
            var imageBlocks: [JsonValue] = []
            var j = i

            while j < transformedMessages.count, case .toolResult(let toolMsg) = transformedMessages[j] {
                defer { j += 1 }

                // Extract text and image content
                let textResult = toolMsg.content
                    .compactMap(\.textContent)
                    .map(\.text)
                    .joined(separator: "\n")
                let hasImages = toolMsg.content.contains { $0.type == "image" }

                // Always send tool result with text (or placeholder if only images)
                let hasText = !jsTrim(textResult).isEmpty
                let toolResultText = hasText ? textResult : hasImages ? "(see attached image)" : "(no tool output)"
                // Some providers require the 'name' field in tool results
                var toolResultMsg: JsonObject = [
                    "role": "tool",
                    "content": .string(sanitizeSurrogates(toolResultText)),
                    "tool_call_id": .string(toolMsg.toolCallId),
                ]
                if compat.requiresToolResultName && !toolMsg.toolName.isEmpty {
                    toolResultMsg["name"] = .string(toolMsg.toolName)
                }
                params.append(toolResultMsg)

                if hasImages && model.input.contains("image") {
                    for block in toolMsg.content {
                        if case .image(let image) = block {
                            imageBlocks.append([
                                "type": "image_url",
                                "image_url": [
                                    "url": .string("data:\(image.mimeType);base64,\(image.data)"),
                                ],
                            ])
                        }
                    }
                }
            }

            i = j - 1

            if imageBlocks.count > 0 {
                if compat.requiresAssistantAfterToolResult {
                    params.append([
                        "role": "assistant",
                        "content": "I have processed the tool results.",
                    ])
                }

                params.append([
                    "role": "user",
                    "content": .array([
                        [
                            "type": "text",
                            "text": "Attached image(s) from tool result:",
                        ],
                    ] + imageBlocks),
                ])
                lastRole = "user"
            } else {
                lastRole = "toolResult"
            }

            continue
        }

        lastRole = msg.role
    }

    return params
}

private func convertTools(
    _ tools: [Tool],
    _ compat: ResolvedOpenAICompletionsCompat
) throws -> [JsonObject] {
    try tools.map { tool -> JsonObject in
        if let grammar = try resolveGrammarConstrainedSampling(tool, compat.supportsOpenAIGrammarTools) {
            return [
                "type": "custom",
                "custom": [
                    "name": .string(tool.name),
                    "description": .string(tool.description),
                    "format": [
                        "type": "grammar",
                        "grammar": [
                            "syntax": .string(grammar.format),
                            "definition": .string(grammar.definition),
                        ],
                    ],
                ],
            ]
        }

        let strict = try resolveJsonSchemaStrictSampling(tool, compat.supportsStrictMode != false)
        var function: JsonObject = [
            "name": .string(tool.name),
            "description": .string(tool.description),
            "parameters": try getJsonSchemaToolParameters(tool, strict),
        ]
        // Only include strict if provider supports it. Some reject unknown fields.
        if compat.supportsStrictMode != false {
            function["strict"] = .bool(strict ?? false)
        }
        return [
            "type": "function",
            "function": .object(function),
        ]
    }
}

private func parseChunkUsage(
    // OpenRouter adds billing fields to streamed usage at runtime,
    // although the OpenAI SDK does not type those fields.
    _ rawUsage: JsonValue,
    _ model: Model
) -> Usage {
    let promptTokens = numberOrZero(rawUsage["prompt_tokens"])
    let cacheReadTokens = (
        nonNullish(nonNullish(rawUsage["prompt_tokens_details"])?["cached_tokens"])
            ?? nonNullish(rawUsage["prompt_cache_hit_tokens"])
            ?? nonNullish(rawUsage["cached_tokens"])
    )?.doubleValue.map { Int($0) } ?? 0
    let cacheWriteTokens = numberOrZero(nonNullish(rawUsage["prompt_tokens_details"])?["cache_write_tokens"])

    // Follow documented OpenAI/OpenRouter semantics: cached_tokens is cache-read
    // tokens (hits). Providers disagree on placement: OpenAI/OpenRouter use
    // prompt_tokens_details.cached_tokens, DeepSeek uses prompt_cache_hit_tokens,
    // and Kimi documents top-level usage.cached_tokens on the final usage chunk.
    // OpenAI does not document or emit cache_write_tokens, but
    // OpenRouter-compatible providers can include it as a separate write count.
    // OpenRouter's own provider/tests affirm the separate mapping:
    // https://github.com/OpenRouterTeam/ai-sdk-provider/pull/409
    // Do not subtract writes from cached_tokens, otherwise spec-compliant
    // providers are under-reported. DS4 mirrors this contract too:
    // https://github.com/antirez/ds4/pull/29
    let input = max(0, promptTokens - cacheReadTokens - cacheWriteTokens)
    // OpenAI completion_tokens already includes reasoning_tokens.
    let outputTokens = numberOrZero(rawUsage["completion_tokens"])
    var usage = Usage(
        input: input,
        output: outputTokens,
        cacheRead: cacheReadTokens,
        cacheWrite: cacheWriteTokens,
        reasoning: numberOrZero(nonNullish(rawUsage["completion_tokens_details"])?["reasoning_tokens"]),
        totalTokens: input + outputTokens + cacheReadTokens + cacheWriteTokens,
        cost: UsageCost(input: 0, output: 0, cacheRead: 0, cacheWrite: 0, total: 0)
    )
    calculateCost(model, &usage)
    if isOpenRouterModel(model) {
        applyOpenRouterReportedCost(&usage, rawUsage)
    }
    return usage
}

private func mapStopReason(_ reason: String?) -> (stopReason: StopReason, errorMessage: String?) {
    guard let reason else { return (.stop, nil) }
    switch reason {
    case "stop", "end":
        return (.stop, nil)
    case "length":
        return (.length, nil)
    case "function_call", "tool_calls":
        return (.toolUse, nil)
    case "content_filter":
        return (.error, "Provider finish_reason: content_filter")
    case "network_error":
        return (.error, "Provider finish_reason: network_error")
    default:
        return (
            .error,
            "Provider finish_reason: \(reason)"
        )
    }
}

/**
 * Auto-detect compatibility settings from provider name and baseUrl.
 * Used as the base when model.compat is not set; explicit model.compat
 * entries override these detected values.
 */
private func detectCompat(_ model: Model) -> ResolvedOpenAICompletionsCompat {
    let provider = model.provider
    let baseUrl = model.baseUrl

    let isZai =
        provider == "zai" ||
        provider == "zai-coding-cn" ||
        baseUrl.contains("api.z.ai") ||
        baseUrl.contains("open.bigmodel.cn")
    let isTogether =
        provider == "together" || baseUrl.contains("api.together.ai") || baseUrl.contains("api.together.xyz")
    let isMoonshot = provider == "moonshotai" || provider == "moonshotai-cn" || baseUrl.contains("api.moonshot.")
    let isOpenRouter = provider == "openrouter" || baseUrl.contains("openrouter.ai")
    let isCloudflareWorkersAI = provider == "cloudflare-workers-ai" || baseUrl.contains("api.cloudflare.com")
    let isCloudflareAiGateway = provider == "cloudflare-ai-gateway" || baseUrl.contains("gateway.ai.cloudflare.com")
    let isNvidia = provider == "nvidia" || baseUrl.contains("integrate.api.nvidia.com")
    let isAntLing = provider == "ant-ling" || baseUrl.contains("api.ant-ling.com")
    let isCerebras = provider == "cerebras" || baseUrl.contains("cerebras.ai")
    let isDeepSeek = provider == "deepseek" || baseUrl.lowercased().contains("deepseek.com")

    let isNonStandard =
        isNvidia ||
        isCerebras ||
        provider == "xai" ||
        baseUrl.contains("api.x.ai") ||
        isTogether ||
        baseUrl.contains("chutes.ai") ||
        isDeepSeek ||
        isZai ||
        isMoonshot ||
        provider == "opencode" ||
        baseUrl.contains("opencode.ai") ||
        isCloudflareWorkersAI ||
        isCloudflareAiGateway ||
        isAntLing

    let useMaxTokens =
        baseUrl.contains("chutes.ai") ||
        isDeepSeek ||
        isMoonshot ||
        isCloudflareAiGateway ||
        isTogether ||
        isNvidia ||
        isAntLing ||
        isZai

    let isGrok = provider == "xai" || baseUrl.contains("api.x.ai")
    let isOpenRouterDeveloperRoleModel =
        isOpenRouter && (model.id.hasPrefix("anthropic/") || model.id.hasPrefix("openai/"))
    let cacheControlFormat: CacheControlFormat? = provider == "openrouter" && model.id.hasPrefix("anthropic/") ? .anthropic : nil

    return ResolvedOpenAICompletionsCompat(
        supportsStore: !isNonStandard,
        supportsDeveloperRole: isOpenRouterDeveloperRoleModel || (!isNonStandard && !isOpenRouter),
        supportsReasoningEffort:
            !isGrok && !isZai && !isMoonshot && !isTogether && !isCloudflareAiGateway && !isNvidia && !isAntLing,
        supportsUsageInStreaming: true,
        supportsFinishReason: true,
        maxTokensField: useMaxTokens ? .maxTokens : .maxCompletionTokens,
        requiresToolResultName: false,
        requiresAssistantAfterToolResult: false,
        requiresThinkingAsText: false,
        requiresReasoningContentOnAssistantMessages: isDeepSeek,
        thinkingFormat: isDeepSeek
            ? .deepseek
            : isZai
                ? .zai
                : isTogether
                    ? .together
                    : isAntLing
                        ? .antLing
                        : isOpenRouter
                            ? .openrouter
                            : .openai,
        openRouterRouting: OpenRouterRouting(json: nil),
        vercelGatewayRouting: VercelGatewayRouting(json: nil),
        chatTemplateKwargs: [],
        chatTemplateArgs: [],
        zaiToolStream: false,
        // OpenAI compatibility alone does not imply strict JSON-schema tool support.
        supportsStrictMode: false,
        supportsOpenAIGrammarTools: false,
        sendSessionAffinityHeaders: isOpenRouter,
        sessionAffinityFormat: isOpenRouter ? .openrouter : .openai,
        supportsLongCacheRetention: !(
            isTogether ||
            isCloudflareWorkersAI ||
            isCloudflareAiGateway ||
            isNvidia ||
            isAntLing
        ),
        cacheControlFormat: cacheControlFormat,
        supportsThinkingTokenBudget: false,
        thinkingTokenBudgetField: nil,
        supportsMidConvoSystemMessages: false,
        supportsMidConvoToolAdditions: false
    )
}

/**
 * Get resolved compatibility settings for a model.
 * Auto-detects from provider/URL then overrides with explicit model.compat.
 */
private func getCompat(_ model: Model) -> ResolvedOpenAICompletionsCompat {
    let detected = detectCompat(model)
    guard let rawCompat = model.compat else { return detected }
    let compat = OpenAICompletionsCompat(json: rawCompat)

    return ResolvedOpenAICompletionsCompat(
        supportsStore: compat.supportsStore ?? detected.supportsStore,
        supportsDeveloperRole: compat.supportsDeveloperRole ?? detected.supportsDeveloperRole,
        supportsReasoningEffort: compat.supportsReasoningEffort ?? detected.supportsReasoningEffort,
        supportsUsageInStreaming: compat.supportsUsageInStreaming ?? detected.supportsUsageInStreaming,
        supportsFinishReason: compat.supportsFinishReason ?? detected.supportsFinishReason,
        maxTokensField: compat.maxTokensField ?? detected.maxTokensField,
        requiresToolResultName: compat.requiresToolResultName ?? detected.requiresToolResultName,
        requiresAssistantAfterToolResult:
            compat.requiresAssistantAfterToolResult ?? detected.requiresAssistantAfterToolResult,
        requiresThinkingAsText: compat.requiresThinkingAsText ?? detected.requiresThinkingAsText,
        requiresReasoningContentOnAssistantMessages:
            compat.requiresReasoningContentOnAssistantMessages ??
            detected.requiresReasoningContentOnAssistantMessages,
        thinkingFormat: compat.thinkingFormat ?? detected.thinkingFormat,
        openRouterRouting: compat.openRouterRouting ?? OpenRouterRouting(json: nil),
        vercelGatewayRouting: compat.vercelGatewayRouting ?? detected.vercelGatewayRouting,
        chatTemplateKwargs: compat.chatTemplateKwargs ?? detected.chatTemplateKwargs,
        chatTemplateArgs: compat.chatTemplateArgs ?? detected.chatTemplateArgs,
        zaiToolStream: compat.zaiToolStream ?? detected.zaiToolStream,
        supportsStrictMode: compat.supportsStrictMode ?? detected.supportsStrictMode,
        supportsOpenAIGrammarTools: compat.supportsOpenAIGrammarTools ?? detected.supportsOpenAIGrammarTools,
        sendSessionAffinityHeaders: compat.sendSessionAffinityHeaders ?? detected.sendSessionAffinityHeaders,
        sessionAffinityFormat: compat.sessionAffinityFormat ?? detected.sessionAffinityFormat,
        supportsLongCacheRetention: compat.supportsLongCacheRetention ?? detected.supportsLongCacheRetention,
        cacheControlFormat: compat.cacheControlFormat ?? detected.cacheControlFormat,
        supportsThinkingTokenBudget: compat.supportsThinkingTokenBudget ?? detected.supportsThinkingTokenBudget,
        thinkingTokenBudgetField: compat.thinkingTokenBudgetField ?? detected.thinkingTokenBudgetField,
        supportsMidConvoSystemMessages:
            compat.supportsMidConvoSystemMessages ?? detected.supportsMidConvoSystemMessages,
        supportsMidConvoToolAdditions:
            compat.supportsMidConvoToolAdditions ?? detected.supportsMidConvoToolAdditions,
        vllmPriority: compat.vllmPriority
    )
}
