import Foundation
import PiAI

/// Desktop approval policy, independent of the upstream transcript and OS permissions.
public enum ChatPermissionMode: String, CaseIterable, Sendable, Identifiable {
    case manual, acceptEdits, bypassPermissions
    public var id: String { rawValue }
    public var title: String {
        switch self {
        case .manual: "Manual"
        case .acceptEdits: "Accept edits"
        case .bypassPermissions: "Bypass permissions"
        }
    }
    public var detail: String {
        switch self {
        case .manual: "Ask before changes and commands"
        case .acceptEdits: "Automatically accept workspace file edits"
        case .bypassPermissions: "Run tools without app approval prompts"
        }
    }

    // Only openCoding's host-owned tools receive a workspace. Generic tools must
    // not gain trust just by calling themselves “read” or “write”.
    func requiresApproval(tool: String, arguments: JsonValue, workspace: String?) -> Bool {
        if self == .bypassPermissions { return false }
        guard let workspace, let raw = arguments["path"]?.stringValue, !raw.isEmpty,
              tool == "read" || (self == .acceptEdits && ["edit", "write"].contains(tool)) else { return true }
        let root = URL(fileURLWithPath: workspace).standardizedFileURL.resolvingSymlinksInPath().path
        let expanded = (raw as NSString).expandingTildeInPath
        guard let target = Self.resolvedTarget(expanded.hasPrefix("/") ? expanded : (root as NSString).appendingPathComponent(expanded)) else { return true }
        guard target.hasPrefix(root == "/" ? "/" : root + "/") else { return true }
        if tool != "read" {
            let components = target.dropFirst(root.count).split(separator: "/")
            // Repository metadata and agent configuration still need an explicit decision.
            if components.contains(where: { [".git", ".pi", ".pf"].contains(String($0)) }) { return true }
        }
        return false
    }

    private static func resolvedTarget(_ path: String) -> String? {
        var ancestor = URL(fileURLWithPath: path).standardizedFileURL
        var missing: [String] = []
        // Foundation does not resolve parent symlinks reliably when the final file
        // does not exist yet. Resolve the nearest existing ancestor, then append.
        while !FileManager.default.fileExists(atPath: ancestor.path) {
            if (try? FileManager.default.attributesOfItem(atPath: ancestor.path)[.type]) as? FileAttributeType == .typeSymbolicLink {
                return nil // Dangling or cyclic link: require a decision.
            }
            let parent = ancestor.deletingLastPathComponent()
            guard parent.path != ancestor.path else { return nil }
            missing.append(ancestor.lastPathComponent); ancestor = parent
        }
        var resolved = ancestor.resolvingSymlinksInPath()
        for component in missing.reversed() { resolved.appendPathComponent(component) }
        return resolved.path
    }
}
