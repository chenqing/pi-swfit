import Foundation

// Port of packages/ai/src/api/google-generative-ai.ts
//
// Swift notes:
// - `stream` / `streamSimple` are `streamGoogleGenerativeAI` / `streamSimpleGoogleGenerativeAI`.
// - `GoogleOptions extends StreamOptions`: `toolChoice` is `StreamOptions.toolChoice` ("auto" | "none" | "any") and
//   `thinking` travels in `StreamOptions.extra["thinking"]` as `{ enabled, budgetTokens?, level? }` (the runtime
//   shape of `ProviderStreamOptions = StreamOptions & Record<string, unknown>`); see `GoogleThinkingOptions`.
// - `GenerateContentParameters` is JSON (`{ model, contents, config }`), which is what `onPayload` sees. The
//   non-JSON `config.abortSignal` is passed to `generateContentStream(_:abortSignal:)` instead, always with
//   `options.signal` (also when `onPayload` replaced the params).
// - Custom fetch: upstream rejects any `options.fetch` other than `globalThis.fetch`. Swift closures have no
//   identity, so every explicit `options.fetch` is rejected; the SDK client uses the ambient `GlobalFetch.current`
//   (`globalThis.fetch`).
// - `streamSimpleGoogleGenerativeAI` throws synchronously like upstream; `googleGenerativeAIApi()` turns that throw
//   into the stream's error event, as upstream `lazyApi` does.

/// `GoogleOptions extends StreamOptions`. `toolChoice`: `StreamOptions.toolChoice`; `thinking`:
/// `StreamOptions.extra["thinking"]` (see `GoogleThinkingOptions`).
public typealias GoogleOptions = StreamOptions

/// `GoogleOptions.thinking`.
public struct GoogleThinkingOptions: Sendable {
    public var enabled: Bool
    /// -1 for dynamic, 0 to disable
    public var budgetTokens: Int?
    /// `GoogleApiThinkingLevel` value. Kept as a string: an unknown value maps to no SDK level, as upstream.
    public var level: String?

    public init(enabled: Bool, budgetTokens: Int? = nil, level: GoogleApiThinkingLevel? = nil) {
        self.enabled = enabled
        self.budgetTokens = budgetTokens
        self.level = level?.rawValue
    }

    /// Reads `{ enabled, budgetTokens?, level? }`.
    public init(json: JsonValue) {
        enabled = json["enabled"].map(jsTruthy) ?? false
        budgetTokens = json["budgetTokens"]?.intValue
        level = json["level"]?.stringValue
    }

    /// `{ enabled, budgetTokens?, level? }`, the value stored in `StreamOptions.extra["thinking"]`.
    public var json: JsonValue {
        var object: JsonObject = ["enabled": .bool(enabled)]
        if let budgetTokens { object["budgetTokens"] = .number(Double(budgetTokens)) }
        if let level { object["level"] = .string(level) }
        return .object(object)
    }
}

/// `options?.thinking`.
private func getGoogleThinkingOption(_ options: GoogleOptions?) -> GoogleThinkingOptions? {
    guard let value = options?.extra["thinking"], !value.isNull else { return nil }
    return GoogleThinkingOptions(json: value)
}

// Counter for generating unique tool call IDs
private let toolCallCounter = Locked(0)

public func streamGoogleGenerativeAI(
    _ model: Model,
    _ context: TranscriptContext,
    _ options: GoogleOptions? = nil
) -> AssistantMessageEventStream {
    let stream = AssistantMessageEventStream()
    let normalizedContext = collapseSystemMessages(context)

    Task {
        var output = AssistantMessage(
            content: [],
            api: "google-generative-ai",
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
            if options?.fetch != nil {
                throw PiError("Custom fetch is not supported by the Google Generative AI adapter")
            }
            guard let apiKey = options?.apiKey, !apiKey.isEmpty else {
                throw PiError("No API key for provider: \(model.provider)")
            }
            let client = try createClient(model, apiKey, options?.headers, options?.identity)
            var params = try buildParams(model, normalizedContext, options)
            if let nextParams = try await options?.onPayload?(params, model) {
                params = nextParams
            }
            let requestParams = params
            let signal = options?.signal
            let googleStream = try await retryGoogleRequest({
                try await client.models.generateContentStream(requestParams, abortSignal: signal)
            }, options)

            stream.push(.start(partial: output))
            // Index of the current text/thinking block in `output.content` (always the last block).
            var currentBlock: Int? = nil
            func blockIndex() -> Int { output.content.count - 1 }
            func endCurrentBlock(_ index: Int) {
                switch output.content[index] {
                case .text(let text):
                    stream.push(.textEnd(contentIndex: blockIndex(), content: text.text, partial: output))
                case .thinking(let thinking):
                    stream.push(.thinkingEnd(contentIndex: blockIndex(), content: thinking.thinking, partial: output))
                case .toolCall:
                    break
                }
            }

            for try await chunk in googleStream {
                await options?.onProviderStreamEvent?(chunk, model)
                // @google/genai documents GenerateContentResponse.responseId as an output-only field
                // used to identify each response. Keep the first non-empty one from the stream.
                if output.responseId == nil || output.responseId!.isEmpty {
                    output.responseId = chunk["responseId"]?.stringValue
                }
                let candidate = chunk["candidates"]?[0]
                if case .array(let parts)? = candidate?["content"]?["parts"] {
                    for part in parts {
                        if case .string(let partText)? = part["text"] {
                            let isThinking = isThinkingPart(part)
                            let currentType = currentBlock.map { output.content[$0].type }
                            if currentBlock == nil ||
                                (isThinking && currentType != "thinking") ||
                                (!isThinking && currentType != "text") {
                                if let currentBlock {
                                    endCurrentBlock(currentBlock)
                                }
                                if isThinking {
                                    output.content.append(.thinking(ThinkingContent(thinking: "", thinkingSignature: nil)))
                                    currentBlock = blockIndex()
                                    stream.push(.thinkingStart(contentIndex: blockIndex(), partial: output))
                                } else {
                                    output.content.append(.text(TextContent(text: "")))
                                    currentBlock = blockIndex()
                                    stream.push(.textStart(contentIndex: blockIndex(), partial: output))
                                }
                            }
                            let index = currentBlock!
                            let partSignature = part["thoughtSignature"]?.stringValue
                            switch output.content[index] {
                            case .thinking(var thinking):
                                thinking.thinking += partText
                                thinking.thinkingSignature = retainThoughtSignature(thinking.thinkingSignature, partSignature)
                                output.content[index] = .thinking(thinking)
                                stream.push(.thinkingDelta(contentIndex: blockIndex(), delta: partText, partial: output))
                            case .text(var text):
                                text.text += partText
                                text.textSignature = retainThoughtSignature(text.textSignature, partSignature)
                                output.content[index] = .text(text)
                                stream.push(.textDelta(contentIndex: blockIndex(), delta: partText, partial: output))
                            case .toolCall:
                                break
                            }
                        }

                        if let functionCall = part["functionCall"], jsTruthy(functionCall) {
                            if let index = currentBlock {
                                endCurrentBlock(index)
                                currentBlock = nil
                            }

                            // Generate unique ID if not provided or if it's a duplicate
                            let providedId = functionCall["id"]?.stringValue
                            let needsNewId = providedId == nil || providedId!.isEmpty ||
                                output.content.contains { $0.toolCallContent?.id == providedId }
                            let toolCallId: String
                            if needsNewId {
                                let counter = toolCallCounter.withLock { value -> Int in
                                    value += 1
                                    return value
                                }
                                let name = functionCall["name"].map { $0.isNull ? "null" : jsToString($0) } ?? "undefined"
                                toolCallId = "\(name)_\(dateNow())_\(counter)"
                            } else {
                                toolCallId = providedId!
                            }

                            let thoughtSignature = part["thoughtSignature"]?.stringValue
                            let toolCall = ToolCall(
                                id: toolCallId,
                                name: functionCall["name"]?.stringValue ?? "",
                                arguments: functionCall["args"]?.objectValue ?? JsonObject(),
                                thoughtSignature: thoughtSignature?.isEmpty == false ? thoughtSignature : nil
                            )

                            output.content.append(.toolCall(toolCall))
                            stream.push(.toolcallStart(contentIndex: blockIndex(), partial: output))
                            stream.push(.toolcallDelta(
                                contentIndex: blockIndex(),
                                delta: JsonValue.object(toolCall.arguments).serialized(),
                                partial: output
                            ))
                            stream.push(.toolcallEnd(contentIndex: blockIndex(), toolCall: toolCall, partial: output))
                        }
                    }
                }

                if let finishReason = candidate?["finishReason"], jsTruthy(finishReason) {
                    let reason = jsToString(finishReason)
                    output.rawStopReason = reason
                    output.stopReason = try mapStopReasonGoogle(reason)
                    if output.content.contains(where: { $0.type == "toolCall" }) && output.stopReason == .stop {
                        output.stopReason = .toolUse
                    }
                }

                if let usageMetadata = chunk["usageMetadata"], jsTruthy(usageMetadata) {
                    func count(_ key: String) -> Int { usageMetadata[key]?.intValue ?? 0 }
                    output.usage = Usage(
                        input: count("promptTokenCount") - count("cachedContentTokenCount"),
                        output: count("candidatesTokenCount") + count("thoughtsTokenCount"),
                        cacheRead: count("cachedContentTokenCount"),
                        cacheWrite: 0,
                        reasoning: count("thoughtsTokenCount"),
                        totalTokens: count("totalTokenCount"),
                        cost: UsageCost(
                            input: 0,
                            output: 0,
                            cacheRead: 0,
                            cacheWrite: 0,
                            total: 0
                        )
                    )
                    calculateCost(model, &output.usage)
                }
            }

            if let currentBlock {
                endCurrentBlock(currentBlock)
            }

            if options?.signal?.aborted == true {
                throw PiError("Request was aborted")
            }

            if output.stopReason == .pending {
                throw PiError("Google stream ended without a finish reason")
            }
            if output.stopReason == .aborted || output.stopReason == .error {
                let errorMessage = output.rawStopReason.map { $0.isEmpty ? nil : $0 } ?? nil
                throw PiError(errorMessage.map { "Provider stopped with: \($0)" } ?? "An unknown error occurred")
            }

            stream.push(.done(reason: output.stopReason, message: output))
            stream.end()
        } catch {
            // Remove internal index property used during streaming: Swift keeps no scratch state in blocks.
            output.stopReason = options?.signal?.aborted == true ? .aborted : .error
            output.errorMessage = formatProviderError(normalizeProviderError(error))
            stream.push(.error(reason: output.stopReason, error: output))
            stream.end()
        }
    }

    return stream
}

/// Upstream `streamSimple`. Throws synchronously when auth is missing or the thinking level mapping is unsupported.
public func streamSimpleGoogleGenerativeAI(
    _ model: Model,
    _ context: TranscriptContext,
    _ options: SimpleStreamOptions? = nil
) throws -> AssistantMessageEventStream {
    guard let apiKey = options?.apiKey, !apiKey.isEmpty else {
        throw PiError("No API key for provider: \(model.provider)")
    }

    var base = buildBaseOptions(model, context, options, apiKey)
    base.toolChoice = options?.toolChoice
    func withThinking(_ thinking: GoogleThinkingOptions) -> GoogleOptions {
        var result = base
        result.extra["thinking"] = thinking.json
        return result
    }
    guard let reasoning = options?.reasoning else {
        return streamGoogleGenerativeAI(model, context, withThinking(GoogleThinkingOptions(enabled: false)))
    }

    let clampedReasoning = clampThinkingLevel(model, ModelThinkingLevel(reasoning))
    guard let clampedLevel = clampedReasoning.thinkingLevel else {
        return streamGoogleGenerativeAI(model, context, withThinking(GoogleThinkingOptions(enabled: false)))
    }
    let resolvedLevel = try resolveGoogleThinkingLevel(model, clampedLevel)

    if usesGoogleThinkingLevel(model) {
        return streamGoogleGenerativeAI(model, context, withThinking(GoogleThinkingOptions(
            enabled: true,
            level: toGoogleThinkingLevel(resolvedLevel)
        )))
    }

    return streamGoogleGenerativeAI(model, context, withThinking(GoogleThinkingOptions(
        enabled: true,
        budgetTokens: getGoogleBudget(model, resolvedLevel, options?.thinkingBudgets)
    )))
}

/// `{ ...a, ...b }` over header lists: an exact key already present keeps its position and takes the later value.
private func spreadHeaders(_ sources: [ProviderHeaders?]) -> ProviderHeaders {
    var result: ProviderHeaders = []
    for source in sources {
        for (name, value) in source ?? [] {
            if let index = result.firstIndex(where: { $0.0 == name }) {
                result[index].1 = value
            } else {
                result.append((name, value))
            }
        }
    }
    return result
}

private func createClient(
    _ model: Model,
    _ apiKey: String? = nil,
    _ optionsHeaders: ProviderHeaders? = nil,
    _ identity: ClientIdentity? = nil
) throws -> GoogleGenAI {
    var httpOptions = JsonObject()
    if !model.baseUrl.isEmpty {
        httpOptions["baseUrl"] = .string(model.baseUrl)
        httpOptions["apiVersion"] = "" // baseUrl already includes version path, don't append
    }
    let modelHeaders: ProviderHeaders? = model.headers?.map { ($0.0, Optional($0.1)) }
    let headers = providerHeadersToRecord([spreadHeaders([getIdentityHeaders(.init(model), identity), modelHeaders, optionsHeaders])])
    if let headers {
        httpOptions["headers"] = .object(JsonObject(headers.map { ($0.0, JsonValue.string($0.1)) }))
    }

    return try GoogleGenAI(GoogleGenAI.Options(
        apiKey: apiKey,
        httpOptions: httpOptions.count > 0 ? httpOptions : nil,
        // Swift: the SDK uses the ambient `globalThis.fetch`.
        fetch: GlobalFetch.current
    ))
}

/// Returns `GenerateContentParameters` as JSON.
private func buildParams(
    _ model: Model,
    _ context: TranscriptContext,
    _ options: GoogleOptions? = nil
) throws -> JsonValue {
    let options = options ?? GoogleOptions()
    let contents = convertMessagesGoogle(model, context)
    let initialSystemMessage = getInitialSystemMessage(context.messages)
    let currentTools = getCurrentTools(context.messages)

    var generationConfig = JsonObject()
    if let temperature = options.temperature {
        generationConfig["temperature"] = .number(temperature)
    }
    if let maxTokens = options.maxTokens {
        generationConfig["maxOutputTokens"] = .number(Double(maxTokens))
    }

    let supportsStrictMode = supportsGoogleStrictToolSampling(model.id)
    let functionCallingMode = currentTools.count > 0
        ? try resolveGoogleFunctionCallingMode(currentTools, options.toolChoice, supportsStrictMode)
        : nil
    let systemInstruction = initialSystemMessage.map(getSystemMessageText) ?? ""
    var config = JsonObject()
    if generationConfig.count > 0 {
        for (key, value) in generationConfig { config[key] = value }
    }
    if !systemInstruction.isEmpty {
        config["systemInstruction"] = .string(sanitizeSurrogates(systemInstruction))
    }
    if currentTools.count > 0, let tools = try convertToolsGoogle(currentTools, false, supportsStrictMode) {
        config["tools"] = .array(tools)
    }
    if let functionCallingMode {
        config["toolConfig"] = ["functionCallingConfig": ["mode": .string(functionCallingMode)]]
    }

    let thinking = getGoogleThinkingOption(options)
    if let thinking, thinking.enabled, model.reasoning {
        var thinkingConfig: JsonObject = ["includeThoughts": true]
        if let level = thinking.level {
            if let apiLevel = GoogleApiThinkingLevel(rawValue: level) {
                thinkingConfig["thinkingLevel"] = .string(toGoogleSdkThinkingLevel(apiLevel))
            }
        } else if let budgetTokens = thinking.budgetTokens {
            thinkingConfig["thinkingBudget"] = .number(Double(budgetTokens))
        }
        config["thinkingConfig"] = .object(thinkingConfig)
    } else if model.reasoning, let thinking, !thinking.enabled {
        config["thinkingConfig"] = .object(try getDisabledGoogleThinkingConfig(model))
    }

    if let signal = options.signal {
        if signal.aborted {
            throw PiError("Request aborted")
        }
        // config.abortSignal = options.signal: Swift passes the signal to generateContentStream directly.
    }

    let params: JsonValue = [
        "model": .string(model.id),
        "contents": .array(contents),
        "config": .object(config),
    ]

    return params
}

private func getGoogleBudget(
    _ model: Model,
    _ level: ResolvedGoogleThinkingLevel,
    _ customBudgets: ThinkingBudgets? = nil
) -> Int {
    let custom: Int?
    switch level {
    case .minimal: custom = customBudgets?.minimal
    case .low: custom = customBudgets?.low
    case .medium: custom = customBudgets?.medium
    case .high: custom = customBudgets?.high
    }
    if let custom {
        return custom
    }

    if model.id.contains("2.5-pro") {
        let budgets: [ResolvedGoogleThinkingLevel: Int] = [
            .minimal: 128,
            .low: 2048,
            .medium: 8192,
            .high: 32768,
        ]
        return budgets[level]!
    }

    if model.id.contains("2.5-flash-lite") {
        let budgets: [ResolvedGoogleThinkingLevel: Int] = [
            .minimal: 512,
            .low: 2048,
            .medium: 8192,
            .high: 24576,
        ]
        return budgets[level]!
    }

    if model.id.contains("2.5-flash") {
        let budgets: [ResolvedGoogleThinkingLevel: Int] = [
            .minimal: 128,
            .low: 2048,
            .medium: 8192,
            .high: 24576,
        ]
        return budgets[level]!
    }

    return -1
}
