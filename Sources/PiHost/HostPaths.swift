import Foundation
import CryptoKit
import PiAI
#if os(macOS)
import Darwin
#endif

public struct HostPaths: Sendable {
    public let agentDir: String
    public init(agentDir: String? = nil) {
        self.agentDir = ((agentDir ?? ProcessInfo.processInfo.environment["PF_AGENT_DIR"] ?? "~/.pf/agent") as NSString).expandingTildeInPath
    }
    public static func canonicalWorkspace(_ path: String) -> String {
        URL(fileURLWithPath: path).standardizedFileURL.resolvingSymlinksInPath().path
    }
    public func prepareSessionDirectory(cwd: String) throws {
        let directory = sessionDirectory(cwd: cwd)
        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory)
    }
    public func sessionDirectory(cwd: String) -> String {
        let id = SHA256.hash(data: Data(Self.canonicalWorkspace(cwd).utf8)).prefix(12).map { String(format: "%02x", $0) }.joined()
        return (agentDir as NSString).appendingPathComponent("sessions/\(id)")
    }
}

/// A non-blocking advisory lock shared by both native hosts. Never waits on an occupied session.
final class HostFileLock: @unchecked Sendable {
    private let descriptor: Locked<Int32>
    init(_ path: String) throws {
        #if os(macOS)
        try FileManager.default.createDirectory(at: URL(fileURLWithPath: path).deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let fd = open(path, O_CREAT | O_RDWR | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw PiError("Cannot open the session/configuration lock") }
        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else {
            close(fd); throw PiError("This session or configuration is open in another process. Close it there before continuing.")
        }
        descriptor = Locked(fd)
        #else
        throw PiError("The shared coding host currently requires macOS")
        #endif
    }
    func release() {
        #if os(macOS)
        let fd = descriptor.withLock { value in let result = value; value = -1; return result }
        if fd >= 0 { flock(fd, LOCK_UN); close(fd) }
        #endif
    }
    deinit { release() }
}

func writePrivateJSON<T: Encodable>(_ value: T, to file: URL) throws {
    try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    let data = try JSONEncoder().encode(value)
    try data.write(to: file, options: .atomic)
    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
}

public struct WorkspaceBookmark: Codable, Sendable {
    public var cwd: String
    public var connectionID: String
    public var sessionFile: String?
    public init(cwd: String, connectionID: String, sessionFile: String?) {
        self.cwd = cwd; self.connectionID = connectionID; self.sessionFile = sessionFile
    }
    public static func load(paths: HostPaths) throws -> Self? {
        let file = URL(fileURLWithPath: paths.agentDir).appendingPathComponent("playground.json")
        guard FileManager.default.fileExists(atPath: file.path) else { return nil }
        return try JSONDecoder().decode(Self.self, from: Data(contentsOf: file))
    }
    public func save(paths: HostPaths) throws {
        try writePrivateJSON(self, to: URL(fileURLWithPath: paths.agentDir).appendingPathComponent("playground.json"))
    }
}
