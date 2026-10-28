// ResourceLoader's skills surface, aligned with resource-loader.ts @ 42cb822f1c5d3153069dd0661bfd297424666cf1.
// Not ported: npm/git package installation, themes, prompt templates, TypeScript extension loading.
import Foundation
import PiAI

public protocol ResourceLoader: Sendable {
    func getSkills() -> LoadSkillsResult
    func reload() throws
}
public struct DefaultResourceLoaderOptions: Sendable {
    public var cwd: String
    public var agentDir: String
    public var settingsManager: SettingsManager
    public var projectTrusted: Bool
    public var additionalSkillPaths: [String]
    public var homeDir: String
    public var noSkills: Bool
    public init(cwd: String, agentDir: String = getAgentDir(), settingsManager: SettingsManager,
                projectTrusted: Bool = false, additionalSkillPaths: [String] = [], noSkills: Bool = false, homeDir: String = NSHomeDirectory()) {
        self.cwd = cwd; self.agentDir = agentDir; self.settingsManager = settingsManager
        self.homeDir = homeDir; self.projectTrusted = projectTrusted; self.additionalSkillPaths = additionalSkillPaths; self.noSkills = noSkills
    }
}
public final class DefaultResourceLoader: ResourceLoader, @unchecked Sendable {
    private let options: DefaultResourceLoaderOptions
    private let state = Locked(LoadSkillsResult())
    public init(_ options: DefaultResourceLoaderOptions) { self.options = options }
    public func getSkills() -> LoadSkillsResult { state.withLock { $0 } }
    public func reload() throws {
        let cwd = resolvePath(options.cwd, FileManager.default.currentDirectoryPath)
        let agentDir = resolvePath(options.agentDir, cwd)
        let projectBase = cwd + "/.pi"
        let globalEntries = options.settingsManager.getGlobalSettings()["skills"]?.arrayValue?.compactMap(\.stringValue) ?? []
        let projectEntries = options.settingsManager.getProjectSettings()["skills"]?.arrayValue?.compactMap(\.stringValue) ?? []
        var result = LoadSkillsResult(), collisions: [ResourceDiagnostic] = []
        var realPaths: Set<String> = []
        func matches(_ file: String, _ pattern: String, base: String, exact: Bool) -> Bool {
            let parent = URL(fileURLWithPath: file).deletingLastPathComponent().path
            let declared = file.hasSuffix("/SKILL.md")
            let targets = [file] + (declared ? [parent] : [])
            let normalized = pattern.hasPrefix("~/") ? options.homeDir + String(pattern.dropFirst()) : pattern
            if exact { return targets.contains(resolvePath(normalized, base)) }
            guard let regex = try? NSRegularExpression(pattern: "^" + IgnoreMatcher.glob(normalized.hasPrefix("./") ? String(normalized.dropFirst(2)) : normalized) + "$") else { return false }
            return targets.contains { target in
                let relative = target.hasPrefix(base + "/") ? String(target.dropFirst(base.count + 1)) : target
                return [target, relative, URL(fileURLWithPath: target).lastPathComponent].contains {
                    regex.firstMatch(in: $0, range: NSRange($0.startIndex..., in: $0)) != nil
                }
            }
        }
        func enabled(_ file: String, entries: [String], base: String, auto: Bool) -> Bool {
            let patterns = entries.filter { $0.hasPrefix("!") || $0.hasPrefix("+") || $0.hasPrefix("-") || $0.contains("*") || $0.contains("?") }
            let includes = patterns.filter { !$0.hasPrefix("!") && !$0.hasPrefix("+") && !$0.hasPrefix("-") }
            var enabled = auto || includes.isEmpty || includes.contains { matches(file, $0, base: base, exact: false) }
            if patterns.filter({ $0.hasPrefix("!") }).contains(where: { matches(file, String($0.dropFirst()), base: base, exact: false) }) { enabled = false }
            if patterns.filter({ $0.hasPrefix("+") }).contains(where: { matches(file, String($0.dropFirst()), base: base, exact: true) }) { enabled = true }
            if patterns.filter({ $0.hasPrefix("-") }).contains(where: { matches(file, String($0.dropFirst()), base: base, exact: true) }) { enabled = false }
            return enabled
        }
        func add(_ path: String, scope: SourceScope, base: String, entries: [String], auto: Bool) {
            if auto && !FileManager.default.fileExists(atPath: path) { return }
            let loaded = loadSkills(.init(cwd: cwd, agentDir: agentDir, skillPaths: [path], includeDefaults: false))
            result.diagnostics += loaded.diagnostics.filter { $0.path.map { enabled($0, entries: entries, base: base, auto: auto) } ?? true }
            for var skill in loaded.skills where enabled(skill.filePath, entries: entries, base: base, auto: auto) {
                let canonical = URL(fileURLWithPath: skill.filePath).resolvingSymlinksInPath().path
                if realPaths.contains(canonical) { continue }
                if let winner = result.skills.first(where: { $0.name == skill.name }) {
                    collisions.append(.init(type: .collision, message: "name \"\(skill.name)\" collision", path: skill.filePath,
                        collision: .init(resourceType: "skill", name: skill.name, winnerPath: winner.filePath, loserPath: skill.filePath)))
                } else {
                    skill.sourceInfo = createSyntheticSourceInfo(skill.filePath, source: auto ? "auto" : "local", scope: scope, baseDir: base)
                    result.skills.append(skill); realPaths.insert(canonical)
                }
            }
        }
        func configured(_ entries: [String], base: String, scope: SourceScope) {
            for entry in entries where !entry.isEmpty && !entry.hasPrefix("!") && !entry.hasPrefix("+") && !entry.hasPrefix("-") && !entry.contains("*") && !entry.contains("?") {
                add(resolvePath(entry, base), scope: scope, base: base, entries: entries, auto: false)
            }
        }
        if !options.noSkills {
            configured(globalEntries, base: agentDir, scope: .user)
            if options.projectTrusted {
                configured(projectEntries, base: projectBase, scope: .project)
                add(projectBase + "/skills", scope: .project, base: projectBase, entries: projectEntries, auto: true)
                // Search ancestors only up to the nearest repository root, as package-manager.ts does.
                var dir = cwd
                while true {
                    let base = dir + "/.agents"
                    if base != options.homeDir + "/.agents" { add(base + "/skills", scope: .project, base: base, entries: projectEntries, auto: true) }
                    if FileManager.default.fileExists(atPath: dir + "/.git") { break }
                    let parent = URL(fileURLWithPath: dir).deletingLastPathComponent().path
                    if parent == dir { break }; dir = parent
                }
            }
            add(agentDir + "/skills", scope: .user, base: agentDir, entries: globalEntries, auto: true)
            add(options.homeDir + "/.agents/skills", scope: .user, base: options.homeDir + "/.agents", entries: globalEntries, auto: true)
        }
        for path in options.additionalSkillPaths { add(resolvePath(path, cwd), scope: .temporary, base: cwd, entries: [], auto: false) }
        result.diagnostics += collisions
        state.withLock { $0 = result }
    }
}
