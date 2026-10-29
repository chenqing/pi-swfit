import Foundation
import CryptoKit
import PiAI

/// Desktop drafts stay separate from model transcripts and are never submitted on restoration.
public struct ConversationDraftStore: Sendable {
    public let paths: HostPaths
    public init(paths: HostPaths) { self.paths = paths }

    public struct Draft: Identifiable, Sendable {
        public var id: String { sessionFile }
        public let sessionFile: String
        public let text: String
        public let connectionID: String?
        public let modified: Date
    }
    private struct Entry: Codable {
        let version: Int
        let sessionFile: String
        let text: String
        var connectionID: String?
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
    /// Includes legacy drafts: the workspace is identified by its canonical session directory.
    /// Transcripts already represented in the conversation list are excluded.
    public func unsent(cwd: String) throws -> [Draft] {
        let directory = URL(fileURLWithPath: paths.agentDir).appendingPathComponent("drafts")
        guard FileManager.default.fileExists(atPath: directory.path) else { return [] }
        let parent = HostPaths.canonicalWorkspace(paths.sessionDirectory(cwd: cwd))
        return try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.contentModificationDateKey])
            .filter { $0.pathExtension == "json" }.compactMap { file in
                let entry = try JSONDecoder().decode(Entry.self, from: Data(contentsOf: file))
                guard entry.version == 1, location(entry.sessionFile).file.lastPathComponent == file.lastPathComponent else {
                    throw PiError("A saved draft has an unsupported format")
                }
                guard !entry.text.isEmpty,
                      URL(fileURLWithPath: entry.sessionFile).deletingLastPathComponent().path == parent,
                      !FileManager.default.fileExists(atPath: entry.sessionFile) else { return nil }
                return Draft(sessionFile: entry.sessionFile, text: entry.text, connectionID: entry.connectionID,
                             modified: try file.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate ?? .distantPast)
            }.sorted { $0.modified > $1.modified }
    }
    public func save(_ text: String, for sessionFile: String, connectionID: String? = nil) throws {
        let (key, file) = location(sessionFile)
        let lock = try HostFileLock(file.path + ".lock"); defer { lock.release() }
        if text.isEmpty {
            if FileManager.default.fileExists(atPath: file.path) { try FileManager.default.removeItem(at: file) }
        } else {
            try writePrivateJSON(Entry(version: 1, sessionFile: key, text: text, connectionID: connectionID), to: file)
        }
    }
}
