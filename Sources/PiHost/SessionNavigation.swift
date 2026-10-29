import Foundation
import PiAI
import PiCodingAgent

public struct SessionNavigationItem: Identifiable, Sendable {
    public let id: String
    public let title: String
    public let detail: String
    public let depth: Int
    public let isCurrent: Bool
    public let isUser: Bool
}

public extension CodingSessionHost {
    /// Iterative traversal also keeps very long transcripts off the call stack.
    func navigationItems(forkOnly: Bool = false) -> [SessionNavigationItem] {
        let leaf = manager.getLeafId()
        let timestamp = ISO8601DateFormatter()
        timestamp.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        var result: [SessionNavigationItem] = []
        let roots = forkOnly ? manager.getEntries().map { SessionTreeNode(entry: $0) } : manager.getTree()
        var stack = roots.reversed().map { ($0, 0) }
        var seen: Set<String> = []
        while let (node, depth) = stack.popLast() {
            let entry = node.entry
            guard seen.insert(entry.id).inserted else { continue }
            let isUser = entry.messageEntry?.message.role == "user"
            let text = sessionEntryEditorText(entry)
            if !forkOnly || (isUser && !(text ?? "").isEmpty) {
                let title: String
                if let text { title = text }
                else if case .message(let item) = entry {
                    switch item.message {
                    case .assistant(let value):
                        title = value.content.compactMap { block -> String? in
                            if case .text(let part) = block { return part.text }
                            if case .toolCall(let tool) = block { return "Tool: " + tool.name }
                            return nil
                        }.joined(separator: " ")
                    case .toolResult(let value): title = value.toolName
                    default: title = "Context update"
                    }
                } else if case .branchSummary(let summary) = entry { title = summary.summary }
                else if case .thinkingLevelChange(let change) = entry { title = "Thinking: " + change.thinkingLevel }
                else if case .sessionInfo(let info) = entry { title = "Title: " + (info.name ?? "Untitled conversation") }
                else if case .custom(let info) = entry { title = info.customType == "pf.connection" ? "Model connection" : info.customType }
                else { title = node.label ?? entry.type.replacingOccurrences(of: "_", with: " ") }
                let rawRole = entry.messageEntry?.message.role ?? entry.type
                let role = ["user": "You", "assistant": "Assistant", "toolResult": "Tool result", "system": "Context",
                            "session_info": "Conversation", "custom": "Session", "thinking_level_change": "Thinking",
                            "branch_summary": "Branch summary" ][rawRole] ?? rawRole.replacingOccurrences(of: "_", with: " ").capitalized
                let date = timestamp.date(from: entry.timestamp)?.formatted(date: .abbreviated, time: .shortened) ?? entry.timestamp
                result.append(.init(id: entry.id, title: title, detail: role + " · " + date + (node.label.map { " · " + $0 } ?? ""),
                    depth: forkOnly ? 0 : depth, isCurrent: entry.id == leaf, isUser: isUser))
            }
            for child in node.children.reversed() { stack.append((child, depth + (node.children.count > 1 ? 1 : 0))) }
        }
        return result
    }

    func selectThinking(_ input: String) async throws -> ModelThinkingLevel {
        let levels = await session.getAvailableThinkingLevels()
        guard let level = ModelThinkingLevel(rawValue: input.lowercased()), levels.contains(level) else {
            throw PiError("Unknown thinking level \"\(input)\". Available levels: \(levels.map(\.rawValue).joined(separator: ", ")).")
        }
        try await session.setThinkingLevel(level)
        return level
    }
}
