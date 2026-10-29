import Foundation
import CryptoKit
import PiAI

/// Desktop drafts stay separate from model transcripts and are never submitted on restoration.
public struct ConversationDraftStore: Sendable {
    public let paths: HostPaths
    public init(paths: HostPaths) { self.paths = paths }

    private struct Entry: Codable {
        let version: Int
        let sessionFile: String
        let text: String
    }
    private func location(_ sessionFile: String) -> (key: String, file: URL) {
        let key = URL(fileURLWithPath: sessionFile).standardizedFileURL.resolvingSymlinksInPath().path
        let hash = SHA256.hash(data: Data(key.utf8)).map { String(format: "%02x", $0) }.joined()
        return (key, URL(fileURLWithPath: paths.agentDir).appendingPathComponent("drafts/\(hash).json"))
    }
    public func load(for sessionFile: String) throws -> String {
        let (key, file) = location(sessionFile)
        guard FileManager.default.fileExists(atPath: file.path) else { return "" }
        let entry = try JSONDecoder().decode(Entry.self, from: Data(contentsOf: file))
        guard entry.version == 1, entry.sessionFile == key else { throw PiError("This draft has an unsupported format or belongs to another conversation") }
        return entry.text
    }
    public func save(_ text: String, for sessionFile: String) throws {
        let (key, file) = location(sessionFile)
        let lock = try HostFileLock(file.path + ".lock"); defer { lock.release() }
        if text.isEmpty {
            if FileManager.default.fileExists(atPath: file.path) { try FileManager.default.removeItem(at: file) }
        } else {
            try writePrivateJSON(Entry(version: 1, sessionFile: key, text: text), to: file)
        }
    }
}
