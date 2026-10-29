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
        let lines = RecordedDiff(diff).lines
        added = lines.filter { $0.kind == .added }.count
        removed = lines.filter { $0.kind == .removed }.count
    }
    public static func path(for tool: ChatToolCall) -> String? {
        guard let data = tool.arguments.data(using: .utf8),
              let args = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return args["path"] as? String
    }
}
