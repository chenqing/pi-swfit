import Foundation

// Port of packages/ai/src/api/openai-responses-shared.ts
//
// Swift: SDK request/response types (`ResponseInput`, `ResponseStreamEvent`, `OpenAITool`, ...) are
// `JsonValue`s built with keys in upstream object-literal order. The streaming scratch fields upstream
// keeps on tool-call blocks (incremental arguments, `customInput`) live in side tables keyed by content index.

// =============================================================================
// Utilities
// =============================================================================

private func encodeTextSignatureV1(_ id: String?, _ phase: String? = nil) -> String {
    var payload: JsonObject = ["v": 1]
    if let id { payload["id"] = .string(id) }
    if let phase, !phase.isEmpty { payload["phase"] = .string(phase) }
    return JsonValue.object(payload).serialized()
}

private func parseTextSignature(_ signature: String?) -> (id: String, phase: String?)? {
    guard let signature, !signature.isEmpty else { return nil }
    if signature.hasPrefix("{") {
        if let parsed = try? JsonValue.parse(signature) {
            if parsed["v"] == .number(1), case .string(let id)? = parsed["id"] {
                if case .string(let phase)? = parsed["phase"], phase == "commentary" || phase == "final_answer" {
                    return (id, phase)
                }
                return (id, nil)
            }
        }
        // Fall through to legacy plain-string handling.
    }
    return (signature, nil)
}

/// `string | Array<ResponseInputText | ResponseInputImage>`
private func convertToolResultOutput(_ model: Model, _ content: [UserContent]) -> JsonValue {
    let textResult = content.compactMap { $0.textContent?.text }.joined(separator: "\n")
    let images = content.compactMap(\.imageContent)
    let hasText = !jsTrim(textResult).isEmpty

    if images.isEmpty || !model.input.contains("image") {
        return .string(sanitizeSurrogates(hasText ? textResult : !images.isEmpty ? "(see attached image)" : "(no tool output)"))
    }

    var output: [JsonValue] = []
    if hasText {
        output.append(["type": "input_text", "text": .string(sanitizeSurrogates(textResult))])
    }
    for image in images {
        output.append([
            "type": "input_image",
            "detail": "auto",
            "image_url": .string("data:\(image.mimeType);base64,\(image.data)"),
        ])
    }
    return .array(output)
}

public struct OpenAIResponsesStreamOptions: Sendable {
    public var onProviderStreamEvent: OnProviderStreamEvent?
    /// `ResponseCreateParamsStreaming["service_tier"]`
    public var serviceTier: String?
    public var grammarToolInputProperties: [String: String]?
    public var resolveServiceTier: (@Sendable (_ responseServiceTier: String?, _ requestServiceTier: String?) -> String?)?
    public var applyServiceTierPricing: (@Sendable (_ usage: inout Usage, _ serviceTier: String?) -> Void)?
    public init(
        onProviderStreamEvent: OnProviderStreamEvent? = nil,
        serviceTier: String? = nil,
        grammarToolInputProperties: [String: String]? = nil,
        resolveServiceTier: (@Sendable (String?, String?) -> String?)? = nil,
        applyServiceTierPricing: (@Sendable (inout Usage, String?) -> Void)? = nil
    ) {
        self.onProviderStreamEvent = onProviderStreamEvent
        self.serviceTier = serviceTier
        self.grammarToolInputProperties = grammarToolInputProperties
        self.resolveServiceTier = resolveServiceTier
        self.applyServiceTierPricing = applyServiceTierPricing
    }
}

public struct ConvertResponsesMessagesOptions: Sendable {
    public var includeSystemPrompt: Bool?
    public var grammarToolInputProperties: [String: String]?
    /// Whether later system messages are sent in place; otherwise they are folded into the leading prompt.
    public var supportsMidConvoSystemMessages: Bool?
    public var supportsAdditionalTools: Bool?
    public var supportsToolSearch: Bool?
    public var toolOptions: ConvertResponsesToolsOptions?
    /**
     * Effort for the reply being generated. When set, the thinking level is sent as
     * configuration_update items instead of a changing reasoning.effort, which would invalidate the
     * prompt cache. Each item sets the effort from that point on: one goes before every earlier
     * reply with the level recorded on it (`providerThinkingLevel`), and one with this effort goes
     * at the end. Earlier input therefore never changes. OpenAI documents the item before user
     * messages only. After tool results it was verified on gpt-6-luna (October 2026) to be accepted
     * and to apply to the next reply.
     */
    public var configurationUpdateEffort: String?
    public init(
        includeSystemPrompt: Bool? = nil,
        grammarToolInputProperties: [String: String]? = nil,
        supportsMidConvoSystemMessages: Bool? = nil,
        supportsAdditionalTools: Bool? = nil,
        supportsToolSearch: Bool? = nil,
        toolOptions: ConvertResponsesToolsOptions? = nil,
        configurationUpdateEffort: String? = nil
    ) {
        self.includeSystemPrompt = includeSystemPrompt
        self.grammarToolInputProperties = grammarToolInputProperties
        self.supportsMidConvoSystemMessages = supportsMidConvoSystemMessages
        self.supportsAdditionalTools = supportsAdditionalTools
        self.supportsToolSearch = supportsToolSearch
        self.toolOptions = toolOptions
        self.configurationUpdateEffort = configurationUpdateEffort
    }
}

public struct ConvertResponsesToolsOptions: Sendable {
    /// `boolean | null`; `.some(nil)` is an explicit `null`.
    public var strict: Bool??
    public var supportsStrictMode: Bool?
    public var supportsOpenAIGrammarTools: Bool?
    public var toolSearchResult: Bool?
    public init(strict: Bool?? = nil, supportsStrictMode: Bool? = nil, supportsOpenAIGrammarTools: Bool? = nil, toolSearchResult: Bool? = nil) {
        self.strict = strict
        self.supportsStrictMode = supportsStrictMode
        self.supportsOpenAIGrammarTools = supportsOpenAIGrammarTools
        self.toolSearchResult = toolSearchResult
    }
}

// =============================================================================
// Message conversion
// =============================================================================

/**
 * How a Responses transport expresses tool changes.
 *
 * `additional_tools` items accumulate: a later item adds tools and replaces same-name
 * definitions from earlier items, but it cannot replace a top-level tool and cannot remove any
 * tool (verified with strict schemas on the OpenAI, Codex, and Copilot backends, October 2026).
 * Like Codex, every tool is therefore declared in `additional_tools` items, starting with one
 * at the head of the input, and removals are announced as text. Synthetic tool search can
 * only add tools. Without mid-conversation system messages there is nothing to anchor.
 */
public func getResponsesToolSupport(
    supportsMidConvoSystemMessages: Bool? = nil,
    supportsAdditionalTools: Bool? = nil,
    supportsToolSearch: Bool? = nil
) -> TranscriptToolSupport {
    if supportsMidConvoSystemMessages == true && supportsAdditionalTools == true { return .changes }
    return supportsToolSearch == true ? .additions : .none
}

/**
 * Precedes every additional_tools item after the first. Without it, models read the latest item as
 * the complete tool set once a removal was announced; Codex precedes its incremental tool batches
 * with the same guidance. Restating the tools that are still unavailable keeps smaller models
 * (gpt-5.6-luna, gpt-6-luna) from calling them again after later loads (verified October 2026).
 */
private func renderIncrementalToolsNotice(_ unavailable: [String]) -> String {
    let notice =
        "This is an incremental tools update. Previously declared tools remain available unless explicitly marked unavailable. A tool declared again here is available again, and its latest definition replaces the earlier one."
    return !unavailable.isEmpty ? "\(notice)\nStill unavailable: \(unavailable.joined(separator: ", "))." : notice
}

private func renderToolRemovalNotice(_ names: [String]) -> String {
    "The following tools are no longer available. Do not call them:\n\(names.map { "- \($0)" }.joined(separator: "\n"))"
}

/// `part.replace(/[^a-zA-Z0-9_-]/g, "_")`, then the first 64 UTF-16 units, then trailing `_` removed.
private func normalizeIdPart(_ part: String) -> String {
    var units: [UInt16] = part.utf16.map { unit in
        let isAllowed = (unit >= 0x30 && unit <= 0x39) || (unit >= 0x41 && unit <= 0x5A) || (unit >= 0x61 && unit <= 0x7A) || unit == 0x5F || unit == 0x2D
        return isAllowed ? unit : 0x5F
    }
    if units.count > 64 { units = Array(units.prefix(64)) }
    while units.last == 0x5F { units.removeLast() }
    return String(decoding: units, as: UTF16.self)
}

/// `str.split("|")` as JS does it (every piece).
private func splitPipe(_ id: String) -> [String] {
    id.components(separatedBy: "|")
}

public func convertResponsesMessages(
    _ model: Model,
    _ context: TranscriptContext,
    _ allowedToolCallProviders: Set<String>,
    _ options: ConvertResponsesMessagesOptions? = nil
) throws -> [JsonValue] {
    let normalizedContext = resolveTranscript(context, options?.supportsMidConvoSystemMessages)
    var messages: [JsonValue] = []

    let buildForeignResponsesItemId = { (itemId: String) -> String in
        let normalized = "fc_\(shortHash(itemId))"
        return normalized.utf16.count > 64 ? String(decoding: normalized.utf16.prefix(64), as: UTF16.self) : normalized
    }

    let normalizeToolCallId = { (id: String, _: Model, source: AssistantMessage) -> String in
        if !allowedToolCallProviders.contains(model.provider) { return normalizeIdPart(id) }
        if !id.contains("|") { return normalizeIdPart(id) }
        let pieces = splitPipe(id)
        let callId = pieces[0]
        let itemId = pieces[1]
        let normalizedCallId = normalizeIdPart(callId)
        let isForeignToolCall = source.provider != model.provider || source.api != model.api
        var normalizedItemId = isForeignToolCall ? buildForeignResponsesItemId(itemId) : normalizeIdPart(itemId)
        // OpenAI Responses API requires item id to start with "fc"
        if !normalizedItemId.hasPrefix("fc_") {
            normalizedItemId = normalizeIdPart("fc_\(normalizedItemId)")
        }
        return "\(normalizedCallId)|\(normalizedItemId)"
    }

    let transformedMessages = transformMessages(normalizedContext.messages, model, normalizeToolCallId)
    let toolSupport = getResponsesToolSupport(
        supportsMidConvoSystemMessages: options?.supportsMidConvoSystemMessages,
        supportsAdditionalTools: options?.supportsAdditionalTools,
        supportsToolSearch: options?.supportsToolSearch
    )
    let transcriptTools = resolveTranscriptTools(normalizedContext.messages, toolSupport)
    var declaredAdditionalTools = false
    /// Tools announced as removed and not declared again since (insertion-ordered `Set`).
    var unavailableTools: [String] = []
    let compat = model.compat
    let instructionRole: JsonValue = model.reasoning && compat?["supportsDeveloperRole"] != .bool(false) ? "developer" : "system"
    let appendSystemToolAdditions = { (message: SystemMessage, seed: String, messages: inout [JsonValue]) throws in
        let tools = message.toolsAdded ?? []
        for tool in tools { unavailableTools.removeAll { $0 == tool.name } }
        if tools.isEmpty { return }
        if toolSupport == .changes {
            if declaredAdditionalTools {
                messages.append(["role": instructionRole, "content": .string(renderIncrementalToolsNotice(unavailableTools))])
            }
            declaredAdditionalTools = true
            messages.append([
                "type": "additional_tools",
                "role": "developer",
                "tools": .array(try convertResponsesTools(tools, options?.toolOptions)),
            ])
            return
        }
        if toolSupport != .additions { return }
        let names = tools.map(\.name)
        let callId = "pi_tool_load_\(shortHash("\(seed):\(names.joined(separator: ","))"))"
        messages.append([
            "type": "tool_search_call",
            "call_id": .string(callId),
            "execution": "client",
            "status": "completed",
            "arguments": ["query": .string(names.joined(separator: " ")), "limit": .number(Double(names.count))],
        ])
        var searchToolOptions = options?.toolOptions ?? ConvertResponsesToolsOptions()
        searchToolOptions.toolSearchResult = true
        messages.append([
            "type": "tool_search_output",
            "call_id": .string(callId),
            "execution": "client",
            "status": "completed",
            "tools": .array(try convertResponsesTools(tools, searchToolOptions)),
        ])
    }
    let includeInitialSystemMessage = options?.includeSystemPrompt ?? true
    let pushConfigurationUpdate = { (effort: String, messages: inout [JsonValue]) in
        messages.append([
            "type": "configuration_update",
            "reasoning": ["effort": .string(effort)],
        ])
    }

    var msgIndex = 0
    var sourceIndex = 0
    var systemIndex = 0
    for msg in transformedMessages {
        let isLeadingSystemMessage = sourceIndex == 0 && msg.role == "system"
        sourceIndex += 1
        switch msg {
        case .system(let systemMsg):
            // transformMessages keeps system messages in order, so their position matches the transcript.
            let anchorsToolChanges = systemIndex >= transcriptTools.foldedSystemMessages
            systemIndex += 1
            if anchorsToolChanges { try appendSystemToolAdditions(systemMsg, "system:\(msgIndex)", &messages) }
            if !isLeadingSystemMessage || includeInitialSystemMessage {
                var parts = [isLeadingSystemMessage ? getSystemMessageText(systemMsg) : renderSystemMessageUpdate(systemMsg)]
                if anchorsToolChanges {
                    // A redefinition is a removal plus an addition of the same name; only true removals are announced.
                    let added = Set((systemMsg.toolsAdded ?? []).map(\.name))
                    let removed = (systemMsg.toolsRemoved ?? []).map(\.name).filter { !added.contains($0) }
                    if !removed.isEmpty { parts.append(renderToolRemovalNotice(removed)) }
                    // Recorded after this message's additions, whose notice precedes this removal notice.
                    for name in removed where !unavailableTools.contains(name) { unavailableTools.append(name) }
                }
                let text = parts.filter { !$0.isEmpty }.joined(separator: "\n\n")
                if !text.isEmpty {
                    messages.append(["role": instructionRole, "content": .string(sanitizeSurrogates(text))])
                }
            }
        case .user(let userMsg):
            switch userMsg.content {
            case .string(let text):
                messages.append([
                    "role": "user",
                    "content": [["type": "input_text", "text": .string(sanitizeSurrogates(text))]],
                ])
            case .blocks(let blocks):
                let content: [JsonValue] = blocks.map { item in
                    switch item {
                    case .text(let text):
                        return ["type": "input_text", "text": .string(sanitizeSurrogates(text.text))]
                    case .image(let image):
                        return [
                            "type": "input_image",
                            "detail": "auto",
                            "image_url": .string("data:\(image.mimeType);base64,\(image.data)"),
                        ]
                    }
                }
                if content.isEmpty { continue }
                messages.append(["role": "user", "content": .array(content)])
            }
        case .assistant(let assistantMsg):
            var output: [JsonValue] = []
            let isSameProviderAndApi = assistantMsg.provider == model.provider && assistantMsg.api == model.api
            let isSameModel = isSameProviderAndApi && assistantMsg.model == model.id
            let isDifferentModel = isSameProviderAndApi && assistantMsg.model != model.id
            var textBlockIndex = 0

            for block in assistantMsg.content {
                switch block {
                case .thinking(let thinking):
                    if let signature = thinking.thinkingSignature, !signature.isEmpty {
                        let reasoningItem = try JsonValue.parse(signature)
                        output.append(reasoningItem)
                    }
                case .text(let textBlock):
                    let parsedSignature = parseTextSignature(textBlock.textSignature)
                    let fallbackMessageId = textBlockIndex == 0 ? "msg_pi_\(msgIndex)" : "msg_pi_\(msgIndex)_\(textBlockIndex)"
                    textBlockIndex += 1
                    // OpenAI requires id to be max 64 characters
                    var msgId = parsedSignature?.id ?? ""
                    if msgId.isEmpty {
                        msgId = fallbackMessageId
                    } else if msgId.utf16.count > 64 {
                        msgId = "msg_\(shortHash(msgId))"
                    }
                    var item: JsonObject = [
                        "type": "message",
                        "role": "assistant",
                        "content": [["type": "output_text", "text": .string(sanitizeSurrogates(textBlock.text)), "annotations": []]],
                        "status": "completed",
                        "id": .string(msgId),
                    ]
                    if let phase = parsedSignature?.phase { item["phase"] = .string(phase) }
                    output.append(.object(item))
                case .toolCall(let toolCall):
                    let pieces = splitPipe(toolCall.id)
                    let callId = pieces[0]
                    let customInputProperty = options?.grammarToolInputProperties?[toolCall.name]
                    var itemId: String? = pieces.count > 1 ? pieces[1] : nil

                    // For different-model messages, set id to undefined to avoid pairing validation.
                    // OpenAI tracks which item IDs were paired with rs_xxx reasoning items.
                    // By omitting the id, we avoid triggering that validation (like cross-provider does).
                    // Also drop ids that do not match the replayed item type: function_call ids must be fc_*
                    // and custom_tool_call ids must be ctc_*. Foreign tool call ids are normalized to fc_*, and
                    // a call can switch between the two types when grammar tool support differs.
                    let itemIdPrefix = customInputProperty == nil ? "fc_" : "ctc_"
                    if isDifferentModel || !(itemId?.hasPrefix(itemIdPrefix) ?? false) {
                        itemId = nil
                    }

                    var item: JsonObject
                    if let customInputProperty {
                        item = ["type": "custom_tool_call"]
                        if let itemId { item["id"] = .string(itemId) }
                        item["call_id"] = .string(callId)
                        item["name"] = .string(toolCall.name)
                        item["input"] = .string(sanitizeSurrogates(
                            try getGrammarToolInput(toolCall.name, toolCall.arguments, customInputProperty)
                        ))
                    } else {
                        item = ["type": "function_call"]
                        if let itemId { item["id"] = .string(itemId) }
                        item["call_id"] = .string(callId)
                        item["name"] = .string(toolCall.name)
                        item["arguments"] = .string(JsonValue.object(toolCall.arguments).serialized())
                    }
                    if isSameModel, let namespace = toolCall.namespace { item["namespace"] = .string(namespace) }
                    output.append(.object(item))
                }
            }
            if output.isEmpty { continue }
            if options?.configurationUpdateEffort != nil,
               isSameModel,
               let providerThinkingLevel = assistantMsg.providerThinkingLevel
            {
                pushConfigurationUpdate(providerThinkingLevel, &messages)
            }
            messages.append(contentsOf: output)
        case .toolResult(let toolResult):
            let callId = splitPipe(toolResult.toolCallId)[0]
            let output = convertToolResultOutput(model, toolResult.content)

            if options?.grammarToolInputProperties?[toolResult.toolName] != nil {
                messages.append(["type": "custom_tool_call_output", "call_id": .string(callId), "output": output])
            } else {
                messages.append(["type": "function_call_output", "call_id": .string(callId), "output": output])
            }
        }
        if !isLeadingSystemMessage { msgIndex += 1 }
    }
    if let configurationUpdateEffort = options?.configurationUpdateEffort {
        pushConfigurationUpdate(configurationUpdateEffort, &messages)
    }

    return messages
}

// =============================================================================
// Tool conversion
// =============================================================================

public func convertResponsesTools(_ tools: [Tool], _ options: ConvertResponsesToolsOptions? = nil) throws -> [JsonValue] {
    let defaultStrict: Bool? = options?.strict == nil ? false : options!.strict!
    let supportsStrictMode = options?.supportsStrictMode ?? true
    let supportsOpenAIGrammarTools = options?.supportsOpenAIGrammarTools ?? false

    return try tools.map { tool in
        if let grammar = try resolveGrammarConstrainedSampling(tool, supportsOpenAIGrammarTools) {
            var custom: JsonObject = [
                "type": "custom",
                "name": .string(tool.name),
                "description": .string(tool.description),
                "format": [
                    "type": "grammar",
                    "syntax": .string(grammar.format),
                    "definition": .string(grammar.definition),
                ],
            ]
            if options?.toolSearchResult == true { custom["defer_loading"] = true }
            return .object(custom)
        }

        let constrainedStrict = try resolveJsonSchemaStrictSampling(tool, supportsStrictMode)
        let strict: Bool? = constrainedStrict ?? defaultStrict
        var functionTool: JsonObject = [
            "type": "function",
            "name": .string(tool.name),
            "description": .string(tool.description),
            "parameters": try getJsonSchemaToolParameters(tool, strict == true),
        ]
        if options?.toolSearchResult == true { functionTool["defer_loading"] = true }
        if supportsStrictMode {
            functionTool["strict"] = strict.map(JsonValue.bool) ?? .null
        }
        return .object(functionTool)
    }
}

// =============================================================================
// Stream processing
// =============================================================================

/// Scratch state upstream keeps on a streaming tool-call block (`StreamingToolCall`).
private struct StreamingToolCallScratch {
    var argumentsStream: ToolCallArgumentsStream?
    var customInput: StreamingGrammarToolInput?
}

private enum ResponsesOutputSlotType { case thinking, text, toolCall }

private struct ResponsesOutputSlot {
    var type: ResponsesOutputSlotType
    var contentIndex: Int
}

/// `${value}` in a JS template literal.
private func jsTemplateString(_ value: JsonValue?) -> String {
    guard let value else { return "undefined" }
    switch value {
    case .null: return "null"
    case .bool(let b): return b ? "true" : "false"
    case .number(let n): return jsNumberToString(n)
    case .string(let s): return s
    case .array(let items): return items.map { $0.isNull ? "" : jsTemplateString($0) }.joined(separator: ",")
    case .object: return "[object Object]"
    }
}

/// `value ?? fallback` for a JSON field (`null` and `undefined` both fall back).
private func nonNull(_ value: JsonValue?) -> JsonValue? {
    guard let value, !value.isNull else { return nil }
    return value
}

/// `value || 0` for a token count.
private func tokenCount(_ value: JsonValue?) -> Int {
    guard case .number(let n)? = value, n != 0, !n.isNaN else { return 0 }
    return Int(n)
}

public func processResponsesStream<S: AsyncSequence>(
    _ openaiStream: S,
    _ output: inout AssistantMessage,
    _ stream: AssistantMessageEventStream,
    _ model: Model,
    _ options: OpenAIResponsesStreamOptions? = nil
) async throws where S.Element == JsonValue {
    var sawTerminalResponseEvent = false
    /// Keyed by `output_index` as received (a missing index is its own key, like `Map.get(undefined)`).
    var outputSlots: [JsonValue?: ResponsesOutputSlot] = [:]
    var scratch: [Int: StreamingToolCallScratch] = [:]
    var reasoningBlocksById: [String: Int] = [:]

    func applyMessagePhaseStopReason(_ item: JsonValue) {
        if item["type"] == .string("message") && item["phase"] == .string("final_answer") {
            output.stopReason = .stop
        }
    }
    func getSlot(_ outputIndex: JsonValue?, _ type: ResponsesOutputSlotType) -> ResponsesOutputSlot? {
        guard let slot = outputSlots[outputIndex], slot.type == type else { return nil }
        return slot
    }
    func pushToolCallDelta(_ slot: ResponsesOutputSlot, _ delta: String?) {
        guard let delta else { return }
        stream.push(.toolcallDelta(contentIndex: slot.contentIndex, delta: delta, partial: output))
    }
    func toolCall(at index: Int) -> ToolCall {
        guard case .toolCall(let call) = output.content[index] else { fatalError("content \(index) is not a tool call") }
        return call
    }
    func setToolCall(_ index: Int, _ call: ToolCall) {
        output.content[index] = .toolCall(call)
    }
    func appendCustomToolCallInput(_ index: Int, _ input: String?, _ close: Bool) throws -> String? {
        guard let customInput = scratch[index]?.customInput else { return nil }
        let update = try customInput.update(input, close: close)
        var call = toolCall(at: index)
        call.arguments = update.arguments
        setToolCall(index, call)
        return update.delta
    }
    func createSlot(_ outputIndex: JsonValue?, _ item: JsonValue) -> ResponsesOutputSlot? {
        let type = item["type"]?.stringValue
        if type == "reasoning" {
            output.content.append(.thinking(ThinkingContent(thinking: "")))
            let slot = ResponsesOutputSlot(type: .thinking, contentIndex: output.content.count - 1)
            outputSlots[outputIndex] = slot
            stream.push(.thinkingStart(contentIndex: slot.contentIndex, partial: output))
            return slot
        }
        if type == "message" {
            applyMessagePhaseStopReason(item)
            output.content.append(.text(TextContent(text: "")))
            let slot = ResponsesOutputSlot(type: .text, contentIndex: output.content.count - 1)
            outputSlots[outputIndex] = slot
            stream.push(.textStart(contentIndex: slot.contentIndex, partial: output))
            return slot
        }
        if type == "function_call" {
            var block = ToolCall(
                id: "\(jsTemplateString(item["call_id"]))|\(jsTemplateString(item["id"]))",
                name: item["name"]?.stringValue ?? "",
                arguments: JsonObject()
            )
            if let namespace = item["namespace"] { block.namespace = namespace.stringValue }
            output.content.append(.toolCall(block))
            let slot = ResponsesOutputSlot(type: .toolCall, contentIndex: output.content.count - 1)
            let arguments = item["arguments"]?.stringValue ?? ""
            let argumentsStream = ToolCallArgumentsStream()
            block.arguments = argumentsStream.append(arguments)
            setToolCall(slot.contentIndex, block)
            scratch[slot.contentIndex] = StreamingToolCallScratch(argumentsStream: argumentsStream, customInput: nil)
            outputSlots[outputIndex] = slot
            stream.push(.toolcallStart(contentIndex: slot.contentIndex, partial: output))
            return slot
        }
        if type == "custom_tool_call" {
            let name = item["name"]?.stringValue ?? ""
            let inputProperty = options?.grammarToolInputProperties?[name] ?? "input"
            let input = item["input"]?.stringValue ?? ""
            var block = ToolCall(
                id: "\(jsTemplateString(item["call_id"]))|\(jsTemplateString(item["id"]))",
                name: name,
                arguments: [inputProperty: .string(input)]
            )
            if let namespace = item["namespace"] { block.namespace = namespace.stringValue }
            output.content.append(.toolCall(block))
            let slot = ResponsesOutputSlot(type: .toolCall, contentIndex: output.content.count - 1)
            scratch[slot.contentIndex] = StreamingToolCallScratch(
                argumentsStream: nil,
                customInput: StreamingGrammarToolInput(property: inputProperty, initialInput: input)
            )
            outputSlots[outputIndex] = slot
            stream.push(.toolcallStart(contentIndex: slot.contentIndex, partial: output))
            return slot
        }
        return nil
    }
    func getOrCreateSlot(_ outputIndex: JsonValue?, _ item: JsonValue) -> ResponsesOutputSlot? {
        outputSlots[outputIndex] ?? createSlot(outputIndex, item)
    }
    // Azure OpenAI can omit reasoning.encrypted_content from response.output_item.done
    // and provide it only in response.completed.response.output. Backfill the
    // persisted reasoning signature from the terminal response to keep store:false
    // multi-turn replay stateless. See https://github.com/earendil-works/pi/issues/6409.
    func backfillReasoningSignatures(_ responseOutput: [JsonValue]) throws {
        for item in responseOutput {
            guard item["type"] == .string("reasoning"), jsTruthy(item["encrypted_content"]) else { continue }
            guard let id = item["id"]?.stringValue, let index = reasoningBlocksById[id],
                  case .thinking(var block) = output.content[index],
                  let signature = block.thinkingSignature, !signature.isEmpty
            else { continue }

            let storedItem = try JsonValue.parse(signature)
            if jsTruthy(storedItem["encrypted_content"]) { continue }
            var updated = storedItem.objectValue ?? JsonObject()
            updated["encrypted_content"] = item["encrypted_content"]
            block.thinkingSignature = JsonValue.object(updated).serialized()
            output.content[index] = .thinking(block)
        }
    }
    func finalizeResponse(_ response: JsonValue?) throws {
        sawTerminalResponseEvent = true
        try backfillReasoningSignatures(nonNull(response?["output"])?.arrayValue ?? [])
        if case .string(let id)? = response?["id"], !id.isEmpty {
            output.responseId = id
        }
        if let usage = response?["usage"], jsTruthy(usage) {
            let inputDetails = usage["input_tokens_details"]
            let cachedTokens = tokenCount(inputDetails?["cached_tokens"])
            let cacheWriteTokens = tokenCount(inputDetails?["cache_write_tokens"])
            output.usage = Usage(
                // OpenAI includes cached and cache-write tokens in input_tokens, so subtract both.
                input: max(0, tokenCount(usage["input_tokens"]) - cachedTokens - cacheWriteTokens),
                output: tokenCount(usage["output_tokens"]),
                cacheRead: cachedTokens,
                cacheWrite: cacheWriteTokens,
                reasoning: tokenCount(usage["output_tokens_details"]?["reasoning_tokens"]),
                totalTokens: tokenCount(usage["total_tokens"]),
                cost: UsageCost(input: 0, output: 0, cacheRead: 0, cacheWrite: 0, total: 0)
            )
        }
        calculateCost(model, &output.usage)
        if let applyServiceTierPricing = options?.applyServiceTierPricing {
            let responseServiceTier = nonNull(response?["service_tier"])?.stringValue
            let serviceTier = options?.resolveServiceTier.map { $0(responseServiceTier, options?.serviceTier) }
                ?? (responseServiceTier ?? options?.serviceTier)
            applyServiceTierPricing(&output.usage, serviceTier)
        }
        // Map status to stop reason. For incomplete responses, retain the provider's
        // specific reason so max-output truncation and content filtering stay distinct.
        let status = response?["status"]?.stringValue
        let incompleteReason = response?["incomplete_details"]?["reason"]?.stringValue
        if let incompleteReason, !incompleteReason.isEmpty {
            output.rawStopReason = "\(jsTemplateString(response?["status"])).\(incompleteReason)"
        } else {
            output.rawStopReason = status
        }
        let mappedStop = try mapStopReason(status, incompleteReason?.isEmpty == false ? incompleteReason : nil)
        output.stopReason = mappedStop.stopReason
        output.errorMessage = mappedStop.errorMessage
        if output.content.contains(where: { $0.type == "toolCall" }) && output.stopReason == .stop {
            output.stopReason = .toolUse
        }
    }

    for try await event in openaiStream {
        await options?.onProviderStreamEvent?(event, model)
        let eventType = event["type"]?.stringValue
        let outputIndex = event["output_index"]
        if eventType == "response.created" {
            output.responseId = event["response"]?["id"]?.stringValue
        } else if eventType == "response.output_item.added" {
            _ = createSlot(outputIndex, event["item"] ?? .null)
        } else if eventType == "response.reasoning_summary_text.delta" || eventType == "response.reasoning_text.delta" {
            guard let slot = getSlot(outputIndex, .thinking), case .thinking(var block) = output.content[slot.contentIndex] else { continue }
            let delta = jsTemplateString(event["delta"])
            block.thinking += delta
            output.content[slot.contentIndex] = .thinking(block)
            stream.push(.thinkingDelta(contentIndex: slot.contentIndex, delta: delta, partial: output))
        } else if eventType == "response.reasoning_summary_part.done" {
            guard let slot = getSlot(outputIndex, .thinking), case .thinking(var block) = output.content[slot.contentIndex] else { continue }
            block.thinking += "\n\n"
            output.content[slot.contentIndex] = .thinking(block)
            stream.push(.thinkingDelta(contentIndex: slot.contentIndex, delta: "\n\n", partial: output))
        } else if eventType == "response.output_text.delta" || eventType == "response.refusal.delta" {
            guard let slot = getSlot(outputIndex, .text), case .text(var block) = output.content[slot.contentIndex] else { continue }
            let delta = jsTemplateString(event["delta"])
            block.text += delta
            output.content[slot.contentIndex] = .text(block)
            stream.push(.textDelta(contentIndex: slot.contentIndex, delta: delta, partial: output))
        } else if eventType == "response.function_call_arguments.delta" {
            guard let slot = getSlot(outputIndex, .toolCall), let argumentsStream = scratch[slot.contentIndex]?.argumentsStream else { continue }
            let delta = jsTemplateString(event["delta"])
            var call = toolCall(at: slot.contentIndex)
            call.arguments = argumentsStream.append(delta)
            setToolCall(slot.contentIndex, call)
            pushToolCallDelta(slot, delta)
        } else if eventType == "response.function_call_arguments.done" {
            guard let slot = getSlot(outputIndex, .toolCall), let argumentsStream = scratch[slot.contentIndex]?.argumentsStream else { continue }
            let arguments = jsTemplateString(event["arguments"])
            let replacement = argumentsStream.replace(arguments)
            var call = toolCall(at: slot.contentIndex)
            call.arguments = replacement.arguments
            setToolCall(slot.contentIndex, call)

            if let delta = replacement.delta, !delta.isEmpty { pushToolCallDelta(slot, delta) }
        } else if eventType == "response.custom_tool_call_input.delta" {
            guard let slot = getSlot(outputIndex, .toolCall), scratch[slot.contentIndex]?.customInput != nil else { continue }
            pushToolCallDelta(
                slot,
                try appendCustomToolCallInput(slot.contentIndex, jsTemplateString(event["delta"]), false)
            )
        } else if eventType == "response.custom_tool_call_input.done" {
            guard let slot = getSlot(outputIndex, .toolCall), scratch[slot.contentIndex]?.customInput != nil else { continue }
            pushToolCallDelta(slot, try appendCustomToolCallInput(slot.contentIndex, jsTemplateString(event["input"]), true))
        } else if eventType == "response.output_item.done" {
            let item = event["item"] ?? .null
            let itemType = item["type"]?.stringValue
            applyMessagePhaseStopReason(item)
            let slot = getOrCreateSlot(outputIndex, item)

            if itemType == "reasoning", let slot, slot.type == .thinking, case .thinking(var block) = output.content[slot.contentIndex] {
                let summaryText = (nonNull(item["summary"])?.arrayValue ?? []).map { jsTemplateString($0["text"]) }.joined(separator: "\n\n")
                let contentText = (nonNull(item["content"])?.arrayValue ?? []).map { jsTemplateString($0["text"]) }.joined(separator: "\n\n")
                block.thinking = !summaryText.isEmpty ? summaryText : !contentText.isEmpty ? contentText : block.thinking
                block.thinkingSignature = item.serialized()
                output.content[slot.contentIndex] = .thinking(block)
                if let id = item["id"]?.stringValue { reasoningBlocksById[id] = slot.contentIndex }
                stream.push(.thinkingEnd(contentIndex: slot.contentIndex, content: block.thinking, partial: output))
                outputSlots[outputIndex] = nil
            } else if itemType == "message", let slot, slot.type == .text, case .text(var block) = output.content[slot.contentIndex] {
                block.text = (nonNull(item["content"])?.arrayValue ?? []).map { part -> String in
                    let value = part["type"] == .string("output_text") ? part["text"] : part["refusal"]
                    return nonNull(value).map(jsTemplateString) ?? ""
                }.joined()
                block.textSignature = encodeTextSignatureV1(
                    nonNull(item["id"]).map(jsTemplateString),
                    nonNull(item["phase"]).map(jsTemplateString)
                )
                output.content[slot.contentIndex] = .text(block)
                stream.push(.textEnd(contentIndex: slot.contentIndex, content: block.text, partial: output))
                outputSlots[outputIndex] = nil
            } else if itemType == "function_call", let slot, slot.type == .toolCall, let argumentsStream = scratch[slot.contentIndex]?.argumentsStream {
                var call = toolCall(at: slot.contentIndex)
                let itemArguments = item["arguments"]?.stringValue ?? ""
                if !itemArguments.isEmpty { _ = argumentsStream.replace(itemArguments) }
                let parsed = argumentsStream.finish()
                call.arguments = parsed.arguments
                if let argumentsError = parsed.argumentsError { call.argumentsError = argumentsError }
                if let namespace = item["namespace"] { call.namespace = namespace.stringValue }
                setToolCall(slot.contentIndex, call)
                // Finalize in-place and strip the scratch buffer so replay only
                // carries parsed arguments.
                scratch[slot.contentIndex]?.argumentsStream = nil
                stream.push(.toolcallEnd(contentIndex: slot.contentIndex, toolCall: call, partial: output))
                outputSlots[outputIndex] = nil
            } else if itemType == "custom_tool_call", let slot, slot.type == .toolCall, scratch[slot.contentIndex]?.customInput != nil {
                let input = nonNull(item["input"]).map(jsTemplateString)
                pushToolCallDelta(slot, try appendCustomToolCallInput(slot.contentIndex, input, true))
                var call = toolCall(at: slot.contentIndex)
                if let namespace = item["namespace"] { call.namespace = namespace.stringValue }
                setToolCall(slot.contentIndex, call)
                scratch[slot.contentIndex]?.customInput = nil
                stream.push(.toolcallEnd(contentIndex: slot.contentIndex, toolCall: call, partial: output))
                outputSlots[outputIndex] = nil
            }
        } else if eventType == "response.completed" || eventType == "response.incomplete" {
            try finalizeResponse(event["response"])
        } else if eventType == "error" {
            throw PiError("Error Code \(jsTemplateString(event["code"])): \(jsTemplateString(event["message"]))")
        } else if eventType == "response.failed" {
            sawTerminalResponseEvent = true
            let response = event["response"]
            output.rawStopReason = response?["status"]?.stringValue
            let error = response?["error"]
            let details = response?["incomplete_details"]
            let msg: String
            if let error, jsTruthy(error) {
                let code = jsTruthy(error["code"]) ? jsTemplateString(error["code"]) : "unknown"
                let message = jsTruthy(error["message"]) ? jsTemplateString(error["message"]) : "no message"
                msg = "\(code): \(message)"
            } else if jsTruthy(details?["reason"]) {
                msg = "incomplete: \(jsTemplateString(details?["reason"]))"
            } else {
                msg = "Unknown error (no error details in response)"
            }
            throw PiError(msg)
        }
    }
    if !sawTerminalResponseEvent {
        throw PiError("OpenAI Responses stream ended before a terminal response event")
    }
    // The agent runs every tool call in the final message. Refuse to hand over calls whose
    // output_item.done never arrived: their arguments may be cut off or mixed up, e.g. when a
    // non-compliant server omits output_index. Finished calls have their scratch buffers removed.
    if output.stopReason == .toolUse {
        for (index, block) in output.content.enumerated() {
            guard case .toolCall(let toolCall) = block else { continue }
            if scratch[index]?.argumentsStream != nil || scratch[index]?.customInput != nil {
                throw PiError(
                    "OpenAI Responses stream completed with an unfinished tool call: \(toolCall.name) (\(toolCall.id))"
                )
            }
        }
    }
}

/// `status: OpenAI.Responses.ResponseStatus | undefined`
private func mapStopReason(_ status: String?, _ incompleteReason: String? = nil) throws -> (stopReason: StopReason, errorMessage: String?) {
    guard let status, !status.isEmpty else { return (.stop, nil) }
    switch status {
    case "completed":
        return (.stop, nil)
    case "incomplete":
        if incompleteReason == "max_output_tokens" {
            return (.length, nil)
        }
        return (
            .error,
            incompleteReason.map { "Response incomplete: \($0)" } ?? "Response incomplete without a provider reason"
        )
    case "failed", "cancelled":
        return (.error, nil)
    // These two are wonky ...
    case "in_progress", "queued":
        return (.stop, nil)
    default:
        throw PiError("Unhandled stop reason: \(status)")
    }
}
