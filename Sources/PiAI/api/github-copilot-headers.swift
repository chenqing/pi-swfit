import Foundation

// Port of packages/ai/src/api/github-copilot-headers.ts

// Copilot expects X-Initiator to indicate whether the request is user-initiated
// or agent-initiated (e.g. follow-up after assistant/tool messages).
/// Returns `"user" | "agent"`.
public func inferCopilotInitiator(_ messages: [Message]) -> String {
    let last = messages.last
    return last != nil && last!.role != "user" ? "agent" : "user"
}

// Copilot requires Copilot-Vision-Request header when sending images
public func hasCopilotVisionInput(_ messages: [Message]) -> Bool {
    messages.contains { msg in
        if case .user(let user) = msg, case .blocks(let content) = user.content {
            return content.contains { $0.type == "image" }
        }
        if case .toolResult(let toolResult) = msg {
            return toolResult.content.contains { $0.type == "image" }
        }
        return false
    }
}

/// `buildCopilotDynamicHeaders({ messages, hasImages })`. Returns the headers in insertion order.
public func buildCopilotDynamicHeaders(messages: [Message], hasImages: Bool) -> [(String, String)] {
    var headers: [(String, String)] = [
        ("X-Initiator", inferCopilotInitiator(messages)),
        ("Openai-Intent", "conversation-edits"),
    ]

    if hasImages {
        headers.append(("Copilot-Vision-Request", "true"))
    }

    return headers
}
