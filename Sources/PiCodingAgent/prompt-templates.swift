// Port: core/prompt-templates.ts @ aee933269ba79b84e7b7454097c1d4c426021d82.
import Foundation
import PiAI

public struct PromptTemplate: Sendable {
    public var name: String
    public var description: String
    public var argumentHint: String?
    public var content: String
    public var sourceInfo: SourceInfo
    public var filePath: String
    public init(name: String, description: String, argumentHint: String? = nil, content: String, sourceInfo: SourceInfo, filePath: String) {
        self.name = name; self.description = description; self.argumentHint = argumentHint
        self.content = content; self.sourceInfo = sourceInfo; self.filePath = filePath
    }
}
public struct LoadPromptTemplatesResult: Sendable {
    public var templates: [PromptTemplate]
    public var diagnostics: [ResourceDiagnostic]
    public init(templates: [PromptTemplate] = [], diagnostics: [ResourceDiagnostic] = []) {
        self.templates = templates; self.diagnostics = diagnostics
    }
}
public struct LoadPromptTemplatesOptions: Sendable {
    public var cwd: String
    public var agentDir: String
    public var promptPaths: [String]
    public var includeDefaults: Bool
    public init(cwd: String, agentDir: String = getAgentDir(), promptPaths: [String] = [], includeDefaults: Bool = true) {
        self.cwd = cwd; self.agentDir = agentDir; self.promptPaths = promptPaths; self.includeDefaults = includeDefaults
    }
}

/// Matches upstream's simple quoting rules; this is not shell evaluation or escaping.
public func parseCommandArgs(_ input: String) -> [String] {
    var args: [String] = [], current = "", hasToken = false
    var quote: Character?
    for character in input {
        if let active = quote {
            if character == active { quote = nil } else { current.append(character) }
        } else if character == "\"" || character == "'" { quote = character; hasToken = true }
        else if character.isWhitespace {
            if hasToken { args.append(current); current = ""; hasToken = false }
        } else { current.append(character); hasToken = true }
    }
    if hasToken { args.append(current) }
    return args
}

public func substituteArgs(_ content: String, _ args: [String]) -> String {
    let pattern = #"\$\{([0-9]+|ARGUMENTS|@):-([^}]*)\}|\$\{@:([0-9]+)(?::([0-9]+))?\}|\$(ARGUMENTS|@|[0-9]+)"#
    let regex = try! NSRegularExpression(pattern: pattern)
    let source = content as NSString
    var output = "", end = 0
    let all = args.joined(separator: " ")
    for match in regex.matches(in: content, range: NSRange(location: 0, length: source.length)) {
        output += source.substring(with: NSRange(location: end, length: match.range.location - end))
        func group(_ n: Int) -> String? {
            let range = match.range(at: n)
            return range.location == NSNotFound ? nil : source.substring(with: range)
        }
        func value(_ target: String) -> String {
            if target == "@" || target == "ARGUMENTS" { return all }
            guard let n = Int(target), n > 0, n <= args.count else { return "" }
            return args[n - 1]
        }
        if let target = group(1) {
            let v = value(target); output += v.isEmpty ? group(2)! : v
        } else if let raw = group(3) {
            let n = Int(raw) ?? Int.max
            let start = min(args.count, n > 0 ? n - 1 : 0)
            let count = min(args.count - start, group(4).flatMap(Int.init) ?? (group(4) == nil ? args.count : Int.max))
            output += args[start..<(start + count)].joined(separator: " ")
        } else { output += value(group(5)!) }
        end = NSMaxRange(match.range)
    }
    return output + source.substring(from: end)
}

public func loadPromptTemplates(_ options: LoadPromptTemplatesOptions) -> LoadPromptTemplatesResult {
    let cwd = resolvePath(options.cwd, FileManager.default.currentDirectoryPath)
    let agent = resolvePath(options.agentDir, cwd)
    var result = LoadPromptTemplatesResult()
    func load(_ file: String) {
        do {
            let parsed = try parseFrontmatter(String(contentsOfFile: file, encoding: .utf8))
            var description = parsed.frontmatter["description"]?.stringValue ?? ""
            if description.isEmpty, let line = parsed.body.components(separatedBy: "\n").first(where: { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) {
                description = String(line.prefix(60)) + (line.count > 60 ? "..." : "")
            }
            let scope: SourceScope = file.hasPrefix(agent + "/prompts/") ? .user : file.hasPrefix(cwd + "/.pi/prompts/") ? .project : .temporary
            result.templates.append(.init(name: URL(fileURLWithPath: file).deletingPathExtension().lastPathComponent,
                description: description, argumentHint: parsed.frontmatter["argument-hint"]?.stringValue,
                content: parsed.body, sourceInfo: createSyntheticSourceInfo(file, source: "local", scope: scope,
                    baseDir: URL(fileURLWithPath: file).deletingLastPathComponent().path), filePath: file))
        } catch { result.diagnostics.append(.init(type: .warning, message: errorMessage(error), path: file)) }
    }
    var paths = options.includeDefaults ? [agent + "/prompts", cwd + "/.pi/prompts"] : []
    paths += options.promptPaths.map { resolvePath($0.trimmingCharacters(in: .whitespacesAndNewlines), cwd) }
    for path in paths {
        var directory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &directory) else { continue }
        let files = directory.boolValue ? ((try? FileManager.default.contentsOfDirectory(atPath: path).sorted()) ?? []).map { path + "/" + $0 } : [path]
        for file in files where file.hasSuffix(".md") {
            let real = URL(fileURLWithPath: file).resolvingSymlinksInPath().path
            if (try? FileManager.default.attributesOfItem(atPath: real)[.type] as? FileAttributeType) == .typeRegular { load(file) }
        }
    }
    return result
}

public func expandPromptTemplate(_ text: String, templates: [PromptTemplate]) -> String {
    guard text.hasPrefix("/") else { return text }
    let parts = text.dropFirst().split(maxSplits: 1, whereSeparator: \.isWhitespace)
    guard let name = parts.first, let template = templates.first(where: { $0.name == name }) else { return text }
    return substituteArgs(template.content, parseCommandArgs(parts.count > 1 ? String(parts[1]) : ""))
}
