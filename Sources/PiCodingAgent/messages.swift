/**
 * Custom message types and transformers for the coding agent.
 *
 * Extends the base AgentMessage type with coding-agent specific message types,
 * and provides a transformer to convert them to LLM-compatible messages.
 */

import Foundation
import PiAI
import PiAgent

// Port of packages/coding-agent/src/core/messages.ts

public let COMPACTION_SUMMARY_PREFIX = """
The conversation history before this point was compacted into the following summary:

<summary>

"""

public let COMPACTION_SUMMARY_SUFFIX = """

</summary>
"""

public let BRANCH_SUMMARY_PREFIX = """
The following is a summary of a branch that this conversation came back from:

<summary>

"""

public let BRANCH_SUMMARY_SUFFIX = "</summary>"

/**
 * Message type for bash executions via the ! command.
 */
public struct BashExecutionMessage: Sendable, Hashable {
    public var role: String { "bashExecution" }
    public var command: String
    public var output: String
    public var exitCode: Int?
    public var cancelled: Bool
    public var truncated: Bool
    public var fullOutputPath: String?
    public var timestamp: Int
    /** If true, this message is excluded from LLM context (!! prefix) */
    public var excludeFromContext: Bool?
    public init(command: String, output: String, exitCode: Int?, cancelled: Bool, truncated: Bool, fullOutputPath: String? = nil, timestamp: Int, excludeFromContext: Bool? = nil) {
        self.command = command; self.output = output; self.exitCode = exitCode; self.cancelled = cancelled; self.truncated = truncated
        self.fullOutputPath = fullOutputPath; self.timestamp = timestamp; self.excludeFromContext = excludeFromContext
    }
}

/**
 * Message type for extension-injected messages via sendMessage().
 * These are custom messages that extensions can inject into the conversation.
 */
public struct CustomMessage: Sendable, Hashable {
    public var role: String { "custom" }
    public var customType: String
    public var content: UserMessageContent
    public var display: Bool
    public var details: JsonValue?
    public var timestamp: Int
    public init(customType: String, content: UserMessageContent, display: Bool, details: JsonValue? = nil, timestamp: Int) {
        self.customType = customType; self.content = content; self.display = display; self.details = details; self.timestamp = timestamp
    }
}

public struct BranchSummaryMessage: Sendable, Hashable {
    public var role: String { "branchSummary" }
    public var summary: String
    public var fromId: String?
    public var timestamp: Int
    public init(summary: String, fromId: String?, timestamp: Int) { self.summary = summary; self.fromId = fromId; self.timestamp = timestamp }
}

public struct CompactionSummaryMessage: Sendable, Hashable {
    public var role: String { "compactionSummary" }
    public var summary: String
    public var tokensBefore: Int
    public var timestamp: Int
    public init(summary: String, tokensBefore: Int, timestamp: Int) { self.summary = summary; self.tokensBefore = tokensBefore; self.timestamp = timestamp }
}

// Extend CustomAgentMessages via declaration merging
// Swift: the coding-agent message kinds travel as `AgentMessage.custom(CustomAgentMessage)` with the
// role as discriminator; the payload holds every field except `role` and `timestamp`, in upstream key order.

private func intJson(_ value: Int) -> JsonValue { .number(Double(value)) }

extension BashExecutionMessage {
    public var agentMessage: AgentMessage {
        var payload: JsonObject = ["command": .string(command), "output": .string(output)]
        // `exitCode: number | undefined` is a required key; JSON.stringify drops undefined.
        if let exitCode { payload["exitCode"] = intJson(exitCode) }
        payload["cancelled"] = .bool(cancelled)
        payload["truncated"] = .bool(truncated)
        if let fullOutputPath { payload["fullOutputPath"] = .string(fullOutputPath) }
        if let excludeFromContext { payload["excludeFromContext"] = .bool(excludeFromContext) }
        return .custom(CustomAgentMessage(role: "bashExecution", payload: .object(payload), timestamp: timestamp))
    }
    public init?(_ message: AgentMessage) {
        guard case .custom(let custom) = message, custom.role == "bashExecution" else { return nil }
        let p = custom.payload
        self.init(
            command: p["command"]?.stringValue ?? "", output: p["output"]?.stringValue ?? "", exitCode: p["exitCode"]?.intValue,
            cancelled: p["cancelled"]?.boolValue ?? false, truncated: p["truncated"]?.boolValue ?? false,
            fullOutputPath: p["fullOutputPath"]?.stringValue, timestamp: custom.timestamp, excludeFromContext: p["excludeFromContext"]?.boolValue
        )
    }
}

extension CustomMessage {
    public var agentMessage: AgentMessage {
        var payload: JsonObject = ["customType": .string(customType), "content": content.json, "display": .bool(display)]
        if let details { payload["details"] = details }
        return .custom(CustomAgentMessage(role: "custom", payload: .object(payload), timestamp: timestamp))
    }
    public init?(_ message: AgentMessage) {
        guard case .custom(let custom) = message, custom.role == "custom" else { return nil }
        let p = custom.payload
        let content = p["content"].flatMap { try? UserMessageContent(json: $0) } ?? .blocks([])
        self.init(
            customType: p["customType"]?.stringValue ?? "", content: content, display: p["display"]?.boolValue ?? false,
            details: p["details"], timestamp: custom.timestamp
        )
    }
}

extension BranchSummaryMessage {
    public var agentMessage: AgentMessage {
        let payload: JsonObject = ["summary": .string(summary), "fromId": fromId.map(JsonValue.string) ?? .null]
        return .custom(CustomAgentMessage(role: "branchSummary", payload: .object(payload), timestamp: timestamp))
    }
    public init?(_ message: AgentMessage) {
        guard case .custom(let custom) = message, custom.role == "branchSummary" else { return nil }
        self.init(summary: custom.payload["summary"]?.stringValue ?? "", fromId: custom.payload["fromId"]?.stringValue, timestamp: custom.timestamp)
    }
}

extension CompactionSummaryMessage {
    public var agentMessage: AgentMessage {
        let payload: JsonObject = ["summary": .string(summary), "tokensBefore": intJson(tokensBefore)]
        return .custom(CustomAgentMessage(role: "compactionSummary", payload: .object(payload), timestamp: timestamp))
    }
    public init?(_ message: AgentMessage) {
        guard case .custom(let custom) = message, custom.role == "compactionSummary" else { return nil }
        self.init(summary: custom.payload["summary"]?.stringValue ?? "", tokensBefore: custom.payload["tokensBefore"]?.intValue ?? 0, timestamp: custom.timestamp)
    }
}

// MARK: - AgentMessage JSON (Swift-only: upstream stores messages as plain objects)

/// JSON for an `AgentMessage` as upstream writes it with `JSON.stringify`.
/// Custom messages are written as `{ role, ...payload, timestamp }`, except the coding-agent kinds,
/// which keep the key order of their upstream object literals.
public func agentMessageToJson(_ message: AgentMessage) -> JsonValue {
    switch message {
    case .system(let m): return m.json
    case .user(let m): return m.json
    case .assistant(let m): return m.json
    case .toolResult(let m): return m.json
    case .custom(let custom):
        var o: JsonObject = ["role": .string(custom.role)]
        let payload = custom.payload.objectValue ?? JsonObject()
        // Upstream object literal order: createCustomMessage / createBranchSummaryMessage /
        // createCompactionSummaryMessage put `timestamp` last; BashExecutionMessage puts it before
        // `excludeFromContext` (interface order is not observable, so payload order then timestamp).
        for (key, value) in payload where key != "role" && key != "timestamp" { o[key] = value }
        o["timestamp"] = intJson(custom.timestamp)
        return .object(o)
    }
}

/// Fill fields that older session files omit so strict message decoding accepts them.
/// Swift-only: upstream keeps whatever the file holds (`usage.totalTokens` undefined reads as falsy).
private func normalizeLegacyMessageJson(_ object: JsonObject) -> JsonObject {
    var o = object
    let role = o["role"]?.stringValue
    if role == "assistant", var usage = o["usage"]?.objectValue {
        for key in ["input", "output", "cacheRead", "cacheWrite", "totalTokens"] where usage[key] == nil || usage[key]!.isNull {
            usage[key] = 0
        }
        var cost = usage["cost"]?.objectValue ?? JsonObject()
        for key in ["input", "output", "cacheRead", "cacheWrite", "total"] where cost[key] == nil || cost[key]!.isNull {
            cost[key] = 0
        }
        usage["cost"] = .object(cost)
        o["usage"] = .object(usage)
    }
    if role == "toolResult", o["isError"] == nil || o["isError"]!.isNull {
        o["isError"] = false
    }
    return o
}

/// Decode an `AgentMessage` from upstream JSON. Unknown roles become `.custom`.
public func agentMessageFromJson(_ json: JsonValue) throws -> AgentMessage {
    guard var o = json.objectValue else { throw JsonShapeError("AgentMessage must be an object") }
    let role = o["role"]?.stringValue ?? ""
    switch role {
    case "system", "user", "assistant", "toolResult":
        o = normalizeLegacyMessageJson(o)
        return AgentMessage(try Message(json: .object(o)))
    default:
        var payload = JsonObject()
        for (key, value) in o where key != "role" && key != "timestamp" { payload[key] = value }
        let timestamp = o["timestamp"]?.intValue ?? 0
        return .custom(CustomAgentMessage(role: role, payload: .object(payload), timestamp: timestamp))
    }
}

/// Swift-only structural equality for `AgentMessage` (upstream compares object identity).
public func agentMessagesEqual(_ a: AgentMessage, _ b: AgentMessage) -> Bool {
    agentMessageToJson(a) == agentMessageToJson(b)
}

// MARK: - Dates (Swift-only helpers for `new Date(x).getTime()` / `toISOString()`)

nonisolated(unsafe) private let isoFormatterFractional: ISO8601DateFormatter = {
    let f = ISO8601DateFormatter()
    f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return f
}()
nonisolated(unsafe) private let isoFormatterPlain: ISO8601DateFormatter = {
    let f = ISO8601DateFormatter()
    f.formatOptions = [.withInternetDateTime]
    return f
}()
private let isoLock = NSLock()

/// `new Date(timestamp).getTime()` for ISO strings. Returns nil for invalid dates (NaN upstream).
public func parseIsoTimestamp(_ timestamp: String) -> Int? {
    isoLock.lock()
    defer { isoLock.unlock() }
    if let date = isoFormatterFractional.date(from: timestamp) ?? isoFormatterPlain.date(from: timestamp) {
        return Int((date.timeIntervalSince1970 * 1000).rounded())
    }
    return nil
}

/// `new Date(ms).toISOString()`.
public func toISOString(_ ms: Int) -> String {
    isoLock.lock()
    defer { isoLock.unlock() }
    return isoFormatterFractional.string(from: Date(timeIntervalSince1970: Double(ms) / 1000))
}

/**
 * Convert a BashExecutionMessage to user message text for LLM context.
 */
public func bashExecutionToText(_ msg: BashExecutionMessage) -> String {
    var text = "Ran `\(msg.command)`\n"
    if !msg.output.isEmpty {
        text += "```\n\(msg.output)\n```"
    } else {
        text += "(no output)"
    }
    if msg.cancelled {
        text += "\n\n(command cancelled)"
    } else if let exitCode = msg.exitCode, exitCode != 0 {
        text += "\n\nCommand exited with code \(exitCode)"
    }
    if msg.truncated, let fullOutputPath = msg.fullOutputPath, !fullOutputPath.isEmpty {
        text += "\n\n[Output truncated. Full output: \(fullOutputPath)]"
    }
    return text
}

public func createBranchSummaryMessage(_ summary: String, _ fromId: String?, _ timestamp: String) -> BranchSummaryMessage {
    BranchSummaryMessage(
        summary: summary,
        fromId: fromId,
        timestamp: parseIsoTimestamp(timestamp) ?? 0
    )
}

public func createCompactionSummaryMessage(
    _ summary: String,
    _ tokensBefore: Int,
    _ timestamp: String
) -> CompactionSummaryMessage {
    CompactionSummaryMessage(
        summary: summary,
        tokensBefore: tokensBefore,
        timestamp: parseIsoTimestamp(timestamp) ?? 0
    )
}

/** Convert CustomMessageEntry to AgentMessage format */
public func createCustomMessage(
    _ customType: String,
    _ content: UserMessageContent,
    _ display: Bool,
    _ details: JsonValue?,
    _ timestamp: String
) -> CustomMessage {
    CustomMessage(
        customType: customType,
        content: content,
        display: display,
        details: details,
        timestamp: parseIsoTimestamp(timestamp) ?? 0
    )
}

/**
 * Transform AgentMessages (including custom types) to LLM-compatible Messages.
 *
 * This is used by:
 * - Agent's transormToLlm option (for prompt calls and queued messages)
 * - Compaction's generateSummary (for summarization)
 * - Custom extensions and tools
 */
public func convertToLlm(_ messages: [AgentMessage]) -> [Message] {
    messages.compactMap { m -> Message? in
        switch m.role {
        case "bashExecution":
            guard let bash = BashExecutionMessage(m) else { return nil }
            // Skip messages excluded from context (!! prefix)
            if bash.excludeFromContext == true {
                return nil
            }
            return .user(UserMessage(content: .blocks([.text(TextContent(text: bashExecutionToText(bash)))]), timestamp: bash.timestamp))
        case "custom":
            guard let custom = CustomMessage(m) else { return nil }
            let content: [UserContent]
            switch custom.content {
            case .string(let text): content = [.text(TextContent(text: text))]
            case .blocks(let blocks): content = blocks
            }
            return .user(UserMessage(content: .blocks(content), timestamp: custom.timestamp))
        case "branchSummary":
            guard let summary = BranchSummaryMessage(m) else { return nil }
            return .user(UserMessage(
                content: .blocks([.text(TextContent(text: BRANCH_SUMMARY_PREFIX + summary.summary + BRANCH_SUMMARY_SUFFIX))]),
                timestamp: summary.timestamp
            ))
        case "compactionSummary":
            guard let summary = CompactionSummaryMessage(m) else { return nil }
            return .user(UserMessage(
                content: .blocks([
                    .text(TextContent(text: COMPACTION_SUMMARY_PREFIX + summary.summary + COMPACTION_SUMMARY_SUFFIX)),
                ]),
                timestamp: summary.timestamp
            ))
        case "system", "user", "assistant", "toolResult":
            return m.llmMessage
        default:
            return nil
        }
    }
}
