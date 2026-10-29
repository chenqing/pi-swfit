import Foundation

/// One recorded tool edit, not a Git working-tree snapshot or an aggregate of repeated edits.
public struct RecordedChange: Identifiable, Sendable {
    public let id: String
    public let path: String
    public let diff: String
    public let added: Int
    public let removed: Int
    public init?(tool: ChatToolCall) {
        guard let diff = tool.diff, !diff.isEmpty else { return nil }
        id = tool.id; self.diff = diff
        path = Self.path(for: tool) ?? tool.name
        var added = 0, removed = 0, inHunk = false
        for line in diff.components(separatedBy: "\n") {
            if line.hasPrefix("diff --git ") { inHunk = false }
            else if line.hasPrefix("@@ ") { inHunk = true }
            else if inHunk {
                if line.hasPrefix("+") { added += 1 }
                if line.hasPrefix("-") { removed += 1 }
            }
        }
        self.added = added; self.removed = removed
    }
    public static func path(for tool: ChatToolCall) -> String? {
        guard let data = tool.arguments.data(using: .utf8),
              let args = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return args["path"] as? String
    }
}
