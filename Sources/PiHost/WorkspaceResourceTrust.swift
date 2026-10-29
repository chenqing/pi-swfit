import Foundation

/// An explicit host decision, separate from model connections and application tool approval.
public struct WorkspaceResourceTrust: Sendable {
    public let paths: HostPaths
    public init(paths: HostPaths) { self.paths = paths }
    private var file: URL { URL(fileURLWithPath: paths.agentDir).appendingPathComponent("trusted-workspaces.json") }
    private func load() throws -> Set<String> {
        guard FileManager.default.fileExists(atPath: file.path) else { return [] }
        return try JSONDecoder().decode(Set<String>.self, from: Data(contentsOf: file))
    }
    public func contains(_ cwd: String) throws -> Bool { try load().contains(HostPaths.canonicalWorkspace(cwd)) }
    public func set(_ cwd: String, trusted: Bool) throws {
        let lock = try HostFileLock(file.path + ".lock"); defer { lock.release() }
        var values = try load()
        let canonical = HostPaths.canonicalWorkspace(cwd)
        if trusted { values.insert(canonical) } else { values.remove(canonical) }
        try writePrivateJSON(values, to: file)
    }
}
