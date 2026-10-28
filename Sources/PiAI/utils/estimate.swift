import Foundation

// Port of utils/estimate.ts

public struct ContextUsageEstimate: Sendable, Hashable {
    /// Estimated total context tokens.
    public var tokens: Int
    /// Tokens reported by the most recent applicable assistant usage block.
    public var usageTokens: Int
    /// Estimated tokens after the most recent applicable assistant usage block.
    public var trailingTokens: Int
    /// Index of the applicable message that provided usage, or null when none exists.
    public var lastUsageIndex: Int?
    public init(tokens: Int, usageTokens: Int, trailingTokens: Int, lastUsageIndex: Int?) {
        self.tokens = tokens; self.usageTokens = usageTokens; self.trailingTokens = trailingTokens; self.lastUsageIndex = lastUsageIndex
    }
}

private let CHARS_PER_TOKEN = 3.5
private let ESTIMATED_IMAGE_CHARS = 4800

public func calculateContextTokens(_ usage: Usage) -> Int {
    usage.totalTokens != 0 ? usage.totalTokens : usage.input + usage.output + usage.cacheRead + usage.cacheWrite
}

/// `JSON.stringify(value) ?? "undefined"` (JsonValue always serializes).
private func safeJsonStringify(_ value: JsonValue) -> String {
    value.serialized()
}

private func estimateTextAndImageContentChars(_ content: UserMessageContent) -> Int {
    switch content {
    case .string(let text): return text.utf16.count
    case .blocks(let blocks): return estimateTextAndImageContentChars(blocks)
    }
}

private func estimateTextAndImageContentChars(_ content: [UserContent]) -> Int {
    var chars = 0
    for block in content {
        switch block {
        case .text(let text): chars += text.text.utf16.count
        case .image: chars += ESTIMATED_IMAGE_CHARS
        }
    }
    return chars
}

public func estimateTextTokens(_ text: String) -> Int {
    Int((Double(text.utf16.count) / CHARS_PER_TOKEN).rounded(.up))
}

public func estimateTextAndImageContentTokens(_ content: UserMessageContent) -> Int {
    Int((Double(estimateTextAndImageContentChars(content)) / CHARS_PER_TOKEN).rounded(.up))
}

public func estimateTextAndImageContentTokens(_ content: [UserContent]) -> Int {
    Int((Double(estimateTextAndImageContentChars(content)) / CHARS_PER_TOKEN).rounded(.up))
}

public func estimateMessageTokens(_ message: Message) -> Int {
    var chars = 0

    switch message {
    case .system(let system):
        return estimateTextTokens(getSystemMessageText(system)) +
            estimateToolsTokens(system.toolsAdded?.map(\.json)) +
            estimateToolsTokens(system.toolsRemoved?.map(\.json))
    case .user(let user):
        return estimateTextAndImageContentTokens(user.content)
    case .toolResult(let toolResult):
        return estimateTextAndImageContentTokens(toolResult.content)
    case .assistant(let assistant):
        for block in assistant.content {
            switch block {
            case .text(let text): chars += text.text.utf16.count
            case .thinking(let thinking): chars += thinking.thinking.utf16.count
            case .toolCall(let toolCall): chars += toolCall.name.utf16.count + safeJsonStringify(.object(toolCall.arguments)).utf16.count
            }
        }
        return Int((Double(chars) / CHARS_PER_TOKEN).rounded(.up))
    }
}

private func getLastAssistantUsageInfo(_ messages: [Message]) -> (usage: Usage, index: Int)? {
    var latestPrefixTimestamp = Int.min
    var usageInfo: (usage: Usage, index: Int)?

    for i in messages.indices {
        let message = messages[i]
        if case .assistant(let assistant) = message {
            // A newer prefix message was inserted after this response (for example, a
            // compaction summary), so its usage cannot describe the current prefix.
            let usageAppliesToPrefix = assistant.timestamp >= latestPrefixTimestamp
            if usageAppliesToPrefix &&
                assistant.stopReason != .aborted &&
                assistant.stopReason != .error &&
                calculateContextTokens(assistant.usage) > 0 {
                usageInfo = (usage: assistant.usage, index: i)
            }
        }
        latestPrefixTimestamp = max(latestPrefixTimestamp, message.timestamp)
    }

    return usageInfo
}

public func estimateContextTokens(_ context: TranscriptContext) -> ContextUsageEstimate {
    estimateContextTokens(context.messages)
}

public func estimateContextTokens(_ messages: [Message]) -> ContextUsageEstimate {
    if let usageInfo = getLastAssistantUsageInfo(messages) {
        let usageTokens = calculateContextTokens(usageInfo.usage)
        var trailingTokens = 0
        for i in (usageInfo.index + 1)..<messages.count {
            trailingTokens += estimateMessageTokens(messages[i])
        }
        return ContextUsageEstimate(tokens: usageTokens + trailingTokens, usageTokens: usageTokens, trailingTokens: trailingTokens, lastUsageIndex: usageInfo.index)
    }

    var tokens = 0
    for message in messages { tokens += estimateMessageTokens(message) }
    return ContextUsageEstimate(tokens: tokens, usageTokens: 0, trailingTokens: tokens, lastUsageIndex: nil)
}

private func estimateToolsTokens(_ tools: [JsonValue]?) -> Int {
    guard let tools, !tools.isEmpty else { return 0 }
    return estimateTextTokens(safeJsonStringify(.array(tools)))
}
