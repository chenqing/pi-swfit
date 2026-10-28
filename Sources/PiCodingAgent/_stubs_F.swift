import Foundation

// Swift-only stubs for upstream modules outside this port's scope (config.ts, utils/paths.ts).

// MARK: - config.ts (subset)

/// `APP_NAME` (`piConfig.name || "pi"`).
public let APP_NAME = "pi"
/// `CONFIG_DIR_NAME` (`piConfig.configDir || ".pi"`).
public let CONFIG_DIR_NAME = ".pi"
// e.g., PI_CODING_AGENT_DIR or TAU_CODING_AGENT_DIR
public let ENV_AGENT_DIR = "\(APP_NAME.uppercased())_CODING_AGENT_DIR"

public func expandTildePath(_ path: String) -> String {
    normalizePath(path)
}

public func getAgentDir() -> String {
    if let envDir = ProcessInfo.processInfo.environment[ENV_AGENT_DIR], !envDir.isEmpty {
        return expandTildePath(envDir)
    }
    return pathJoin(NSHomeDirectory(), CONFIG_DIR_NAME, "agent")
}

public func getSessionsDir() -> String {
    pathJoin(getAgentDir(), "sessions")
}

// MARK: - utils/paths.ts (subset)
// Not ported: Windows shell paths, unicode-space normalization, `@` prefix stripping, file:// URLs.

public func normalizePath(_ input: String) -> String {
    let home = NSHomeDirectory()
    if input == "~" { return home }
    if input.hasPrefix("~/") { return pathJoin(home, String(input.dropFirst(2))) }
    return input
}

public func resolvePath(_ input: String, _ baseDir: String = FileManager.default.currentDirectoryPath) -> String {
    let normalized = normalizePath(input)
    let normalizedBaseDir = normalizePath(baseDir)
    return normalized.hasPrefix("/") ? nodeResolvePath(normalized) : nodeResolvePath(normalizedBaseDir, normalized)
}

// MARK: - node:path helpers

/// `path.resolve(...segments)` (POSIX): absolute, normalized, no trailing slash, symlinks untouched.
func nodeResolvePath(_ segments: String...) -> String {
    var resolved = ""
    for segment in segments.reversed() where !segment.isEmpty {
        resolved = resolved.isEmpty ? segment : segment + "/" + resolved
        if segment.hasPrefix("/") { break }
    }
    if !resolved.hasPrefix("/") {
        resolved = FileManager.default.currentDirectoryPath + "/" + resolved
    }
    var parts: [Substring] = []
    for part in resolved.split(separator: "/", omittingEmptySubsequences: true) {
        if part == "." { continue }
        if part == ".." {
            if !parts.isEmpty { parts.removeLast() }
            continue
        }
        parts.append(part)
    }
    return "/" + parts.joined(separator: "/")
}

/// `path.join(...segments)` (POSIX).
func pathJoin(_ segments: String...) -> String {
    let joined = segments.filter { !$0.isEmpty }.joined(separator: "/")
    if joined.isEmpty { return "." }
    let absolute = joined.hasPrefix("/")
    let trailing = joined.hasSuffix("/")
    var parts: [Substring] = []
    for part in joined.split(separator: "/", omittingEmptySubsequences: true) {
        if part == "." { continue }
        if part == "..", let last = parts.last, last != ".." {
            parts.removeLast()
            continue
        }
        if part == "..", absolute { continue }
        parts.append(part)
    }
    var result = (absolute ? "/" : "") + parts.joined(separator: "/")
    if result.isEmpty { result = absolute ? "/" : "." }
    if trailing && !result.hasSuffix("/") { result += "/" }
    return result
}

/// `path.basename(p)`.
func pathBasename(_ path: String) -> String {
    (path as NSString).lastPathComponent
}
