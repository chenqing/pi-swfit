import Foundation

// Port of utils/text.ts

/// Extract and join text from message content.
public func contentText(_ content: UserMessageContent, separator: String = "\n") -> String {
    switch content {
    case .string(let s): return s
    case .blocks(let blocks): return blocks.compactMap { $0.textContent?.text }.joined(separator: separator)
    }
}

public func contentText(_ content: SystemMessageContent, separator: String = "\n") -> String {
    switch content {
    case .string(let s): return s
    case .blocks(let blocks): return blocks.map(\.text).joined(separator: separator)
    }
}

public func contentText(_ content: [UserContent], separator: String = "\n") -> String {
    content.compactMap { $0.textContent?.text }.joined(separator: separator)
}

public func contentText(_ content: [AssistantContent], separator: String = "\n") -> String {
    content.compactMap { $0.textContent?.text }.joined(separator: separator)
}

/// Render a system message as a complete prompt: its content followed by its sections.
public func getSystemMessageText(_ message: SystemMessage) -> String {
    var parts = [contentText(message.content)]
    for section in message.sections ?? [] {
        if let text = section.text { parts.append(text) }
    }
    return parts.filter { !$0.isEmpty }.joined(separator: "\n\n")
}

/// Render a later system message for APIs that accept system messages mid-conversation.
/// Section changes are framed by name so the model can relate them to the leading prompt.
/// This framing is request-time only and may change between versions.
public func renderSystemMessageUpdate(_ message: SystemMessage) -> String {
    var parts: [String] = []
    let text = contentText(message.content)
    if !text.isEmpty { parts.append(text) }
    for (name, value) in message.sections ?? [] {
        if let value {
            parts.append("Updated system prompt section \"\(name)\":\n\n\(value)")
        } else {
            parts.append("Removed system prompt section \"\(name)\".")
        }
    }
    return parts.joined(separator: "\n\n")
}
