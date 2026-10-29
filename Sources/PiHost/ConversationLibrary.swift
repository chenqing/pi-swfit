import Foundation
import PiAI
import PiCodingAgent

/// Desktop organization is separate from upstream transcripts. Archiving never moves or deletes them.
public struct ConversationPresentation: Codable, Sendable, Equatable {
    public var pinned = false
    public var archived = false
    public init() {}
}

public struct ConversationLibrary: Sendable {
    public let paths: HostPaths
    public init(paths: HostPaths) { self.paths = paths }
    private var file: URL { URL(fileURLWithPath: paths.agentDir).appendingPathComponent("conversation-library.json") }
    public func load() throws -> [String: ConversationPresentation] {
        guard FileManager.default.fileExists(atPath: file.path) else { return [:] }
        return try JSONDecoder().decode([String: ConversationPresentation].self, from: Data(contentsOf: file))
    }
    public func update(_ path: String, pinned: Bool? = nil, archived: Bool? = nil) throws {
        let lock = try HostFileLock(file.path + ".lock"); defer { lock.release() }
        var entries = try load()
        var item = entries[path] ?? ConversationPresentation()
        if let pinned { item.pinned = pinned }
        if let archived { item.archived = archived }
        entries[path] = item
        try writePrivateJSON(entries, to: file)
    }
    public static func validTitle(_ title: String) throws -> String {
        let value = title.replacingOccurrences(of: "[\\r\\n]+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty, value.count <= 120 else { throw PiError("Use a title between 1 and 120 characters") }
        return value
    }
    /// Active sessions must be renamed through their owning ChatSession instead.
    public func rename(_ path: String, title: String) throws {
        let value = try Self.validTitle(title)
        let lock = try HostFileLock(path + ".lock"); defer { lock.release() }
        guard FileManager.default.fileExists(atPath: path) else { throw PiError("This conversation is no longer available") }
        try SessionManager.open(path).appendSessionInfo(value)
    }
}
