// Port: packages/coding-agent/src/core/source-info.ts @ 42cb822f1c5d3153069dd0661bfd297424666cf1
public enum SourceScope: String, Sendable, Hashable { case user, project, temporary }
public enum SourceOrigin: String, Sendable, Hashable { case package; case topLevel = "top-level" }
public struct SourceInfo: Sendable, Hashable {
    public var path: String
    public var source: String
    public var scope: SourceScope
    public var origin: SourceOrigin
    public var baseDir: String?
}
public let BUILTIN_PATH_PREFIX = "builtin:"
public func getSyntheticPathSource(_ path: String) -> String? {
    if path.hasPrefix(BUILTIN_PATH_PREFIX) { return "builtin" }
    if path.hasPrefix("<"), path.hasSuffix(">") {
        let source = path.dropFirst().dropLast().split(separator: ":", omittingEmptySubsequences: false).first.map(String.init) ?? ""
        return source.isEmpty ? "temporary" : source
    }
    return nil
}
public func isSyntheticPath(_ path: String) -> Bool { path.hasPrefix(BUILTIN_PATH_PREFIX) || path.hasPrefix("<") }
public func createSyntheticSourceInfo(_ path: String, source: String, scope: SourceScope = .temporary,
                                      origin: SourceOrigin = .topLevel, baseDir: String? = nil) -> SourceInfo {
    SourceInfo(path: path, source: source, scope: scope, origin: origin, baseDir: baseDir)
}
// Not ported: createSourceInfo(PathMetadata), pending package-manager port.
