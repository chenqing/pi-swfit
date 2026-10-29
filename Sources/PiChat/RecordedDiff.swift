import Foundation

/// Presentation of a unified tool diff; keeps original text and both source line numbers.
public struct RecordedDiff: Sendable {
    public enum Kind: Sendable { case metadata, hunk, context, added, removed }
    public struct Line: Identifiable, Sendable {
        public let id: Int
        public let text: String
        public let oldNumber: Int?
        public let newNumber: Int?
        public let kind: Kind
    }
    public let lines: [Line]
    public var hunks: [Int] { lines.filter { $0.kind == .hunk }.map(\.id) }
    public init(_ diff: String) {
        let header = try! NSRegularExpression(pattern: "^@@ -(\\d+)(?:,\\d+)? \\+(\\d+)(?:,\\d+)? @@")
        var old = 0, new = 0, inHunk = false
        var result: [Line] = []
        for (index, text) in diff.components(separatedBy: "\n").enumerated() {
            var kind: Kind = .metadata
            var oldNumber: Int?, newNumber: Int?
            if text.hasPrefix("diff --git ") { inHunk = false }
            if let match = header.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) {
                old = Int((text as NSString).substring(with: match.range(at: 1))) ?? 0
                new = Int((text as NSString).substring(with: match.range(at: 2))) ?? 0
                inHunk = true; kind = .hunk
            } else if inHunk {
                if text.hasPrefix("+") { kind = .added; newNumber = new; new += 1 }
                else if text.hasPrefix("-") { kind = .removed; oldNumber = old; old += 1 }
                else if text.hasPrefix(" ") { kind = .context; oldNumber = old; newNumber = new; old += 1; new += 1 }
            }
            result.append(Line(id: index, text: text, oldNumber: oldNumber, newNumber: newNumber, kind: kind))
        }
        lines = result
    }
}

public extension ChatToolCall {
    /// Compact human-facing action; status is presented separately so pending work is not called complete.
    var summary: String {
        if let path = RecordedChange.path(for: self) {
            let action: String
            switch name { case "read": action = "Read"; case "edit": action = "Edit"; case "write": action = "Write"; default: action = name }
            return action + " " + URL(fileURLWithPath: path).lastPathComponent
        }
        if name == "bash", let data = arguments.data(using: .utf8),
           let args = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let command = args["command"] as? String {
            return "Run " + String(command.split(separator: "\n").first.map(String.init)?.prefix(120) ?? "")
        }
        return name
    }
}
