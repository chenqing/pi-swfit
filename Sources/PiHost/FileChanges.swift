import Foundation
import PiAI

public struct CodingChangePreview: Sendable {
    public let path: String
    public let displayPath: String
    public let before: String?
    public let after: String
    public var diff: String { codingDiff(path: displayPath, before: before ?? "", after: after) }
    public func verifyUnchanged() throws {
        let current = FileManager.default.fileExists(atPath: path) ? try codingReadText(URL(fileURLWithPath: path)) : nil
        guard current == before else { throw PiError("File changed while awaiting approval. Ask the agent to read it again.") }
    }
}

func codingReadText(_ url: URL) throws -> String {
    let handle = try FileHandle(forReadingFrom: url); defer { try? handle.close() }
    let data = try handle.read(upToCount: 10 * 1024 * 1024 + 1) ?? Data()
    guard data.count <= 10 * 1024 * 1024, let text = String(data: data, encoding: .utf8), !text.contains("\0") else {
        throw PiError("Expected a UTF-8 text file no larger than 10 MiB")
    }
    return text
}

public func previewCodingChange(name: String, arguments: JsonValue, cwd: String) throws -> CodingChangePreview? {
    guard ["write", "edit"].contains(name) else { return nil }
    guard let raw = arguments["path"]?.stringValue, !raw.isEmpty else { throw PiError("path must not be empty") }
    let expanded = (raw as NSString).expandingTildeInPath
    let url = URL(fileURLWithPath: expanded.hasPrefix("/") ? expanded : (cwd as NSString).appendingPathComponent(expanded)).standardizedFileURL
    let original = FileManager.default.fileExists(atPath: url.path) ? try codingReadText(url) : nil
    let changed: String
    if name == "write" {
        guard let content = arguments["content"]?.stringValue else { throw PiError("content is required") }
        changed = content
    } else {
        guard let original else { throw PiError("File does not exist") }
        guard let edits = arguments["edits"]?.arrayValue, !edits.isEmpty else { throw PiError("edits must not be empty") }
        var replacements: [(Range<String.Index>, String)] = []
        for edit in edits {
            guard let old = edit["oldText"]?.stringValue, !old.isEmpty, let new = edit["newText"]?.stringValue,
                  let range = original.range(of: old), original.range(of: old, range: original.index(after: range.lowerBound)..<original.endIndex) == nil else {
                throw PiError("oldText must occur exactly once in the original file")
            }
            guard !replacements.contains(where: { $0.0.overlaps(range) }) else { throw PiError("Edits must not overlap") }
            replacements.append((range, new))
        }
        var result = original
        for (range, new) in replacements.sorted(by: { $0.0.lowerBound > $1.0.lowerBound }) { result.replaceSubrange(range, with: new) }
        changed = result
    }
    guard changed.utf8.count <= 10 * 1024 * 1024 else { throw PiError("File changes are limited to 10 MiB") }
    let prefix = URL(fileURLWithPath: cwd).standardizedFileURL.path + "/"
    let displayPath = url.path.hasPrefix(prefix) ? String(url.path.dropFirst(prefix.count)) : url.path
    return CodingChangePreview(path: url.path, displayPath: displayPath, before: original, after: changed)
}

/// A bounded textual diff; unchanged leading/trailing lines are omitted beyond three context lines.
public func codingDiff(path: String, before: String, after: String) -> String {
    let old = before.components(separatedBy: "\n"), new = after.components(separatedBy: "\n")
    var prefix = 0
    while prefix < min(old.count, new.count), old[prefix] == new[prefix] { prefix += 1 }
    if before == after { return "No changes to \(path)" }
    var suffix = 0
    while suffix < min(old.count, new.count) - prefix, old[old.count - 1 - suffix] == new[new.count - 1 - suffix] { suffix += 1 }
    let start = max(0, prefix - 3), tail = min(3, suffix)
    let lines = ["--- \(path)", "+++ \(path)", "@@ -\(start + 1),\(old.count - suffix + tail - start) +\(start + 1),\(new.count - suffix + tail - start) @@"]
        + old[start..<prefix].map { " " + $0 }
        + old[prefix..<(old.count - suffix)].map { "-" + $0 }
        + new[prefix..<(new.count - suffix)].map { "+" + $0 }
        + old[(old.count - suffix)..<(old.count - suffix + tail)].map { " " + $0 }
    var output = ""
    for (index, line) in lines.enumerated() {
        guard index < 400, output.utf8.count + line.utf8.count < 32_768 else { return output + "\n[Preview truncated; inspect the file for the complete change.]" }
        output += line + "\n"
    }
    return output
}
