import Foundation

// Port of utils/transcript.ts

/// Build the leading system message for a prompt and tool set. Returns undefined when
/// both are empty, so an empty transcript stays empty.
public func createInitialSystemMessage(_ systemPrompt: String?, _ tools: [Tool]?) -> SystemMessage? {
    let hasSystemPrompt = systemPrompt != nil && !systemPrompt!.isEmpty
    let hasTools = tools != nil && !tools!.isEmpty
    if !hasSystemPrompt && !hasTools { return nil }
    return SystemMessage(
        content: .string(systemPrompt ?? ""),
        toolsAdded: hasTools ? tools : nil,
        timestamp: 0
    )
}

/// Fold `Context.systemPrompt` and `Context.tools` into a leading system message.
/// This is the only entry point that produces a ``TranscriptContext``; every
/// provider-facing function expects the result.
public func normalizeContext(_ context: Context) -> TranscriptContext {
    let initialMessage = createInitialSystemMessage(context.systemPrompt, context.tools)
    let messages = initialMessage.map { [Message.system($0)] + context.messages } ?? context.messages
    return TranscriptContext(normalizedMessages: messages)
}

/// Any message list. Swift: `[Message]` (upstream accepts any `{ role }` list; the replay helpers only
/// read entries whose role is `"system"`).
public typealias TranscriptMessages = [Message]

private func isSystemMessage(_ message: Message) -> SystemMessage? {
    message.systemMessage
}

/// Return the leading system message, if the transcript starts with one.
public func getInitialSystemMessage(_ messages: TranscriptMessages) -> SystemMessage? {
    guard let first = messages.first else { return nil }
    return isSystemMessage(first)
}

/// Drop the leading system message for APIs that carry the prompt outside the message list.
public func withoutInitialSystemMessage(_ messages: [Message]) -> [Message] {
    getInitialSystemMessage(messages) != nil ? Array(messages.dropFirst()) : messages
}

/// Ordered `Map<string, Tool>` with JS `Map` semantics (`set` keeps an existing key's position).
private struct ToolMap {
    var names: [String] = []
    var tools: [String: Tool] = [:]
    mutating func set(_ name: String, _ tool: Tool) {
        if tools[name] == nil { names.append(name) }
        tools[name] = tool
    }
    mutating func delete(_ name: String) {
        guard tools.removeValue(forKey: name) != nil else { return }
        names.removeAll { $0 == name }
    }
    func get(_ name: String) -> Tool? { tools[name] }
    var values: [Tool] { names.map { tools[$0]! } }
}

/// Resolve the tools available after applying every transcript delta in order.
public func getCurrentTools(_ messages: TranscriptMessages) -> [Tool] {
    var tools = ToolMap()
    for message in messages {
        guard let message = isSystemMessage(message) else { continue }
        for tool in message.toolsRemoved ?? [] { tools.delete(tool.name) }
        for tool in message.toolsAdded ?? [] { tools.set(tool.name, tool) }
    }
    return tools.values
}

/// Replay every system message into one leading system message holding the current
/// prompt and tools. Later `content` is appended to the base prompt, `sections` are
/// patched by name, and tools are resolved with ``getCurrentTools``.
public func getCurrentSystemMessage(_ messages: TranscriptMessages) -> SystemMessage? {
    var content: [String] = []
    var sections: [(name: String, text: String)] = []
    var timestamp: Int?
    for message in messages {
        guard let message = isSystemMessage(message) else { continue }
        if timestamp == nil { timestamp = message.timestamp }
        let text = contentText(message.content)
        if !text.isEmpty { content.append(text) }
        for (name, value) in message.sections ?? [] {
            if let value {
                if let index = sections.firstIndex(where: { $0.name == name }) {
                    sections[index].text = value
                } else {
                    sections.append((name: name, text: value))
                }
            } else {
                sections.removeAll { $0.name == name }
            }
        }
    }
    let tools = getCurrentTools(messages)
    if timestamp == nil && tools.isEmpty { return nil }
    return SystemMessage(
        content: .string(content.joined(separator: "\n\n")),
        sections: sections.isEmpty ? nil : sections.map { (name: $0.name, text: Optional($0.text)) },
        toolsAdded: tools.isEmpty ? nil : tools,
        timestamp: timestamp ?? 0
    )
}

/// Render the current system prompt text after replaying every system message.
public func getCurrentSystemPrompt(_ messages: TranscriptMessages) -> String {
    guard let message = getCurrentSystemMessage(messages) else { return "" }
    return getSystemMessageText(message)
}

/// Rebuild the transcript for APIs without mid-conversation system messages: the replayed
/// system message leads, and every later system message is dropped.
public func collapseSystemMessages(_ context: TranscriptContext) -> TranscriptContext {
    let head = getCurrentSystemMessage(context.messages)
    let messages = context.messages.filter { $0.role != "system" }
    return TranscriptContext(normalizedMessages: head.map { [Message.system($0)] + messages } ?? messages)
}

/// Keep later system messages in place when the model accepts them; otherwise collapse them.
public func resolveTranscript(_ context: TranscriptContext, _ supportsMidConvoSystemMessages: Bool?) -> TranscriptContext {
    supportsMidConvoSystemMessages == true ? context : collapseSystemMessages(context)
}

/// Strip executable and display-only fields from a tool before transcript comparison or persistence.
/// Swift: `Tool` holds only declaration fields and `parameters` is already plain JSON.
public func toToolDeclaration(_ tool: Tool) -> Tool {
    Tool(
        name: tool.name,
        description: tool.description,
        parameters: tool.parameters,
        constrainedSampling: tool.constrainedSampling
    )
}

/// Whether two tools declare the same interface to the model.
///
/// Both sides go through ``toToolDeclaration`` first and their serialized declarations are compared.
public func declarationsEqual(_ left: Tool, _ right: Tool) -> Bool {
    toToolDeclaration(left).json.serialized() == toToolDeclaration(right).json.serialized()
}

public struct ToolStateChanges: Sendable {
    public var toolsAdded: [Tool]
    public var toolsRemoved: [ToolReference]
    public init(toolsAdded: [Tool], toolsRemoved: [ToolReference]) { self.toolsAdded = toolsAdded; self.toolsRemoved = toolsRemoved }
}

/// Compare two complete tool states. A changed definition is a removal followed by an addition.
public func getToolStateChanges(_ previous: [Tool], _ current: [Tool]) -> ToolStateChanges {
    var previousTools = ToolMap()
    for tool in previous { previousTools.set(tool.name, tool) }
    var currentTools = ToolMap()
    for tool in current { currentTools.set(tool.name, tool) }
    return ToolStateChanges(
        toolsAdded: current
            .filter { tool in
                guard let previousTool = previousTools.get(tool.name) else { return true }
                return !declarationsEqual(previousTool, tool)
            }
            .map(toToolDeclaration),
        toolsRemoved: previous
            .filter { tool in
                guard let currentTool = currentTools.get(tool.name) else { return true }
                return !declarationsEqual(tool, currentTool)
            }
            .map { ToolReference(name: $0.name) }
    )
}

/// Every definition referenced by transcript tool state, in first-declaration order.
public func getDeclaredTools(_ messages: TranscriptMessages) -> [Tool] {
    var definitions = ToolMap()
    for message in messages {
        guard let message = isSystemMessage(message) else { continue }
        for tool in message.toolsAdded ?? [] { definitions.set(tool.name, tool) }
    }
    return definitions.values
}

/// Whether a tool name was declared twice with different definitions. A transport that can
/// only reference previously declared tools by name cannot replay such a history.
///
/// - Deprecated: No built-in transport needs this anymore: Anthropic expresses redefinitions with
///   inline `tool_definition` blocks. Kept for API compatibility and will be removed in a future release.
public func hasToolRedefinitions(_ messages: TranscriptMessages) -> Bool {
    var declared = ToolMap()
    for message in messages {
        guard let message = isSystemMessage(message) else { continue }
        for tool in message.toolsAdded ?? [] {
            if let previous = declared.get(tool.name), !declarationsEqual(previous, tool) { return true }
            declared.set(tool.name, tool)
        }
    }
    return false
}

/// Whether tool history contains a removal or same-name redeclaration that an addition-only transport cannot replay.
public func hasNonAdditiveToolChanges(_ messages: TranscriptMessages) -> Bool {
    findLastNonAdditiveToolChange(messages.compactMap(isSystemMessage)) >= 0
}

/// Index of the last system message with a removal or same-name redeclaration, or -1.
private func findLastNonAdditiveToolChange(_ systemMessages: [SystemMessage]) -> Int {
    // A name declared before counts as a redeclaration even after its removal: Kimi K3 ignores a
    // removed tool that a later tool message declares again (verified October 2026).
    var declared = Set<String>()
    var last = -1
    for index in systemMessages.indices {
        let message = systemMessages[index]
        if (message.toolsRemoved?.count ?? 0) > 0 { last = index }
        for tool in message.toolsAdded ?? [] {
            if declared.contains(tool.name) { last = index }
            declared.insert(tool.name)
        }
    }
    return last
}

/// How a transport can express tool changes after the first request.
///
/// - `"none"`: only the top-level tool list exists; it always holds the current tools.
/// - `"additions"`: tools can be added at a later message, but not removed or redefined.
/// - `"changes"`: every tool, including the initial ones, is declared in place, and a later
///   declaration under the same name replaces the earlier one. Removals are not expressible on
///   the wire, so the transport announces them as text and the removed tools stay declared.
public enum TranscriptToolSupport: String, Sendable, Hashable {
    case none, additions, changes
}

public struct TranscriptTools: Sendable {
    /// Tools sent in the top-level request field.
    public var requestTools: [Tool]
    /// Number of leading system messages whose tool changes `requestTools` already holds. Every
    /// later system message carries its own tool changes in place.
    public var foldedSystemMessages: Int
    public init(requestTools: [Tool], foldedSystemMessages: Int) { self.requestTools = requestTools; self.foldedSystemMessages = foldedSystemMessages }
}

/// Split tool declarations between the top-level request field and in-place changes.
///
/// With `"changes"`, the top-level list stays empty and every system message, including the
/// leading one, declares its tools in place: an in-place declaration can replace an earlier
/// in-place one, but not a top-level one. With `"additions"`, a removal or redefinition cannot be
/// expressed in place, so the top-level list becomes the tool state after the last such change;
/// later additions stay anchored, and the cached prefix is invalidated once per removal instead
/// of on every later addition. With `"none"`, the top-level list is the current tool set.
public func resolveTranscriptTools(_ messages: TranscriptMessages, _ support: TranscriptToolSupport) -> TranscriptTools {
    let systemMessages = messages.compactMap(isSystemMessage)
    if support == .none {
        return TranscriptTools(requestTools: getCurrentTools(systemMessages.map(Message.system)), foldedSystemMessages: systemMessages.count)
    }
    if support == .changes { return TranscriptTools(requestTools: [], foldedSystemMessages: 0) }
    let folded = max(
        getInitialSystemMessage(messages) != nil ? 1 : 0,
        findLastNonAdditiveToolChange(systemMessages) + 1
    )
    return TranscriptTools(requestTools: getCurrentTools(systemMessages.prefix(folded).map(Message.system)), foldedSystemMessages: folded)
}
