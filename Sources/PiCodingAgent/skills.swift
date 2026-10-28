// Port: packages/coding-agent/src/core/skills.ts @ 42cb822f1c5d3153069dd0661bfd297424666cf1
import Foundation
import PiAI

public struct Skill: Sendable, Hashable {
    public var name: String
    public var description: String
    public var filePath: String
    public var baseDir: String
    public var sourceInfo: SourceInfo
    public var disableModelInvocation: Bool
}
public struct LoadSkillsResult: Sendable {
    public var skills: [Skill] = []
    public var diagnostics: [ResourceDiagnostic] = []
    public init(skills: [Skill] = [], diagnostics: [ResourceDiagnostic] = []) {
        self.skills = skills; self.diagnostics = diagnostics
    }
}
public struct LoadSkillsFromDirOptions: Sendable {
    public var dir: String
    public var source: String
    public init(dir: String, source: String) { self.dir = dir; self.source = source }
}
public struct LoadSkillsOptions: Sendable {
    public var cwd: String
    public var agentDir: String
    public var skillPaths: [String]
    public var includeDefaults: Bool
    public init(cwd: String, agentDir: String = getAgentDir(), skillPaths: [String] = [], includeDefaults: Bool = true) {
        self.cwd = cwd; self.agentDir = agentDir; self.skillPaths = skillPaths; self.includeDefaults = includeDefaults
    }
}

private func validateName(_ name: String) -> [String] {
    var errors: [String] = []
    if name.utf16.count > 64 { errors.append("name exceeds 64 characters (\(name.utf16.count))") }
    if name.range(of: "^[a-z0-9-]+$", options: .regularExpression) == nil {
        errors.append("name contains invalid characters (must be lowercase a-z, 0-9, hyphens only)")
    }
    if name.hasPrefix("-") || name.hasSuffix("-") { errors.append("name must not start or end with a hyphen") }
    if name.contains("--") { errors.append("name must not contain consecutive hyphens") }
    return errors
}
private func validateDescription(_ description: String?) -> [String] {
    guard let description, !description.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return ["description is required"] }
    return description.utf16.count > 1024 ? ["description exceeds 1024 characters (\(description.utf16.count))"] : []
}
private func createSkillSourceInfo(_ filePath: String, _ baseDir: String, _ source: String) -> SourceInfo {
    createSyntheticSourceInfo(filePath, source: ["user", "project", "path"].contains(source) ? "local" : source,
                              scope: source == "user" ? .user : source == "project" ? .project : .temporary, baseDir: baseDir)
}
private func isRegularSkillFile(_ path: String) -> Bool {
    let real = URL(fileURLWithPath: path).resolvingSymlinksInPath().path
    return (try? FileManager.default.attributesOfItem(atPath: real)[.type] as? FileAttributeType) == .typeRegular
}
public func loadSkillsFromDir(_ options: LoadSkillsFromDirOptions) -> LoadSkillsResult {
    var matcher = IgnoreMatcher(); var ancestors: Set<String> = []
    return loadSkillsFromDirInternal(options.dir, options.source, true, &matcher, options.dir, &ancestors)
}
private func loadSkillsFromDirInternal(_ dir: String, _ source: String, _ includeRootFiles: Bool,
                                       _ matcher: inout IgnoreMatcher, _ root: String,
                                       _ ancestors: inout Set<String>) -> LoadSkillsResult {
    var result = LoadSkillsResult()
    let canonical = URL(fileURLWithPath: dir).resolvingSymlinksInPath().path
    // Swift safety: terminate cyclic directory links; upstream recursion otherwise overflows.
    guard ancestors.insert(canonical).inserted else { return result }
    defer { ancestors.remove(canonical) }
    guard let entries = try? FileManager.default.contentsOfDirectory(atPath: dir).sorted() else { return result }
    let prefix = dir == root ? "" : String(dir.dropFirst(root.count + 1)) + "/"
    for name in [".gitignore", ".ignore", ".fdignore"] {
        if let content = try? String(contentsOfFile: dir + "/" + name, encoding: .utf8) {
            for line in content.components(separatedBy: .newlines) { matcher.add(line, prefix: prefix) }
        }
    }
    let declared = dir + "/SKILL.md"
    var directory: ObjCBool = false
    if isRegularSkillFile(declared),
       !matcher.ignores(prefix + "SKILL.md", isDirectory: false) { return loadSkillFromFile(declared, source) }
    for name in entries where !name.hasPrefix(".") && name != "node_modules" {
        let full = dir + "/" + name
        guard FileManager.default.fileExists(atPath: full, isDirectory: &directory),
              !matcher.ignores(prefix + name, isDirectory: directory.boolValue) else { continue }
        let child: LoadSkillsResult
        if directory.boolValue { child = loadSkillsFromDirInternal(full, source, false, &matcher, root, &ancestors) }
        else if includeRootFiles && name.hasSuffix(".md") && isRegularSkillFile(full) { child = loadSkillFromFile(full, source) }
        else { continue }
        result.skills += child.skills; result.diagnostics += child.diagnostics
    }
    return result
}
private func loadSkillFromFile(_ path: String, _ source: String) -> LoadSkillsResult {
    var result = LoadSkillsResult()
    let declared = URL(fileURLWithPath: path).lastPathComponent == "SKILL.md"
    let raw: String
    do { raw = try String(contentsOfFile: path, encoding: .utf8) }
    catch { result.diagnostics.append(.init(type: .warning, message: errorMessage(error), path: path)); return result }
    let frontmatter: JsonValue
    do { frontmatter = try parseFrontmatter(raw).frontmatter }
    catch {
        if declared { result.diagnostics.append(.init(type: .warning, message: errorMessage(error), path: path)) }
        return result
    }
    let description = frontmatter["description"]?.stringValue
    let hasDescription = !(description?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
    if !declared && !hasDescription { return result }
    let base = URL(fileURLWithPath: path).deletingLastPathComponent().path
    let givenName = frontmatter["name"]?.stringValue ?? ""
    let name = givenName.isEmpty ? URL(fileURLWithPath: base).lastPathComponent : givenName
    result.diagnostics = (validateDescription(description) + validateName(name)).map { .init(type: .warning, message: $0, path: path) }
    if hasDescription {
        result.skills = [.init(name: name, description: description!, filePath: path, baseDir: base,
                               sourceInfo: createSkillSourceInfo(path, base, source),
                               disableModelInvocation: frontmatter["disable-model-invocation"]?.boolValue == true)]
    }
    return result
}

public func formatSkillsForPrompt(_ skills: [Skill], fileReadTool: String = "read") -> String {
    let visible = skills.filter { !$0.disableModelInvocation }
    guard !visible.isEmpty else { return "" }
    var lines = ["\n\nThe following skills provide specialized instructions for specific tasks.",
        fileReadTool == "read" ? "Use the read tool to load a skill's file when the task matches its description." :
        fileReadTool == "bash" ? "Use bash to load a skill's file when the task matches its description." :
        "Load a skill's file when the task matches its description.",
        "When a skill file references a relative path, resolve it against the skill directory (parent of SKILL.md / dirname of the path) and use that absolute path in tool commands.", "", "<available_skills>"]
    for skill in visible {
        lines += ["  <skill>", "    <name>\(escapeSkillXml(skill.name))</name>",
                  "    <description>\(escapeSkillXml(skill.description))</description>",
                  "    <location>\(escapeSkillXml(skill.filePath))</location>", "  </skill>"]
    }
    lines.append("</available_skills>")
    return lines.joined(separator: "\n")
}
func escapeSkillXml(_ text: String) -> String {
    text.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
        .replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\"", with: "&quot;").replacingOccurrences(of: "'", with: "&apos;")
}

public func loadSkills(_ options: LoadSkillsOptions) -> LoadSkillsResult {
    let cwd = resolvePath(options.cwd, FileManager.default.currentDirectoryPath)
    let agentDir = resolvePath(options.agentDir, FileManager.default.currentDirectoryPath)
    let userDir = agentDir + "/skills", projectDir = cwd + "/" + CONFIG_DIR_NAME + "/skills"
    var result = LoadSkillsResult(); var paths: Set<String> = []; var collisions: [ResourceDiagnostic] = []
    func add(_ loaded: LoadSkillsResult) {
        result.diagnostics += loaded.diagnostics
        for skill in loaded.skills {
            let canonical = URL(fileURLWithPath: skill.filePath).resolvingSymlinksInPath().path
            if paths.contains(canonical) { continue }
            if let existing = result.skills.first(where: { $0.name == skill.name }) {
                collisions.append(.init(type: .collision, message: "name \"\(skill.name)\" collision", path: skill.filePath,
                    collision: .init(resourceType: "skill", name: skill.name, winnerPath: existing.filePath, loserPath: skill.filePath)))
            } else { result.skills.append(skill); paths.insert(canonical) }
        }
    }
    if options.includeDefaults {
        add(loadSkillsFromDir(.init(dir: userDir, source: "user")))
        add(loadSkillsFromDir(.init(dir: projectDir, source: "project")))
    }
    for path in options.skillPaths {
        let full = resolvePath(path.trimmingCharacters(in: .whitespacesAndNewlines), cwd)
        var directory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: full, isDirectory: &directory) else {
            result.diagnostics.append(.init(type: .warning, message: "skill path does not exist", path: full)); continue
        }
        var source = "path"
        if !options.includeDefaults {
            if full == userDir || full.hasPrefix(userDir + "/") { source = "user" }
            else if full == projectDir || full.hasPrefix(projectDir + "/") { source = "project" }
        }
        if directory.boolValue { add(loadSkillsFromDir(.init(dir: full, source: source))) }
        else if full.hasSuffix(".md") && isRegularSkillFile(full) { add(loadSkillFromFile(full, source)) }
        else { result.diagnostics.append(.init(type: .warning, message: "skill path is not a markdown file", path: full)) }
    }
    result.diagnostics += collisions
    return result
}

/// Session command expansion; unknown names pass through as in upstream AgentSession.
public func expandSkillCommand(_ text: String, skills: [Skill]) throws -> String {
    guard text.hasPrefix("/skill:") else { return text }
    let parts = text.dropFirst(7).split(separator: " ", maxSplits: 1, omittingEmptySubsequences: false)
    guard let name = parts.first, let skill = skills.first(where: { $0.name == name }) else { return text }
    let args = parts.count > 1 ? parts[1].trimmingCharacters(in: .whitespacesAndNewlines) : ""
    let body = try stripFrontmatter(String(contentsOfFile: skill.filePath, encoding: .utf8)).trimmingCharacters(in: .whitespacesAndNewlines)
    let block = "<skill name=\"\(skill.name)\" location=\"\(skill.filePath)\">\nReferences are relative to \(skill.baseDir).\n\n\(body)\n</skill>"
    return args.isEmpty ? block : block + "\n\n" + args
}
