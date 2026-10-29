import Foundation
import PiCodingAgent

/// One catalog for native completion, help and dispatch. Resource content remains in the runtime.
public struct CommandDescriptor: Sendable, Identifiable, Equatable {
    public enum Source: String, Sendable { case builtin = "Command", skill = "Skill", prompt = "Template", `extension` = "Extension" }
    public var id: String { name }
    public let name: String
    public let summary: String
    public let argumentHint: String?
    public let source: Source
    public let location: String?
    public init(name: String, summary: String, argumentHint: String? = nil, source: Source, location: String? = nil) {
        self.name = name; self.summary = summary; self.argumentHint = argumentHint; self.source = source; self.location = location
    }
    public static func builtins(includeQuit: Bool = false) -> [Self] {
        (includeQuit ? SlashCommand.allCases : SlashCommand.desktop).map {
            .init(name: $0.rawValue, summary: $0.summary, argumentHint: $0.argumentHint, source: .builtin)
        }
    }
    public static func suggestions(_ input: String, catalog: [Self]) -> [Self] {
        guard input.hasPrefix("/"), !input.dropFirst().contains(where: \.isWhitespace) else { return [] }
        let prefix = input.dropFirst().lowercased()
        return catalog.filter { $0.name.lowercased().hasPrefix(prefix) }
    }
    public static func help(_ catalog: [Self]) -> String {
        catalog.map { "/\($0.name) — \($0.summary) [\($0.source.rawValue)]" }.joined(separator: "\n")
    }
}

public extension CodingSessionHost {
    func commandCatalog(includeQuit: Bool = false) -> [CommandDescriptor] {
        var commands = CommandDescriptor.builtins(includeQuit: includeQuit)
        // Builtins win in the hosts. Extensions execute before template expansion in AgentSession.
        let reserved = Set(SlashCommand.allCases.map(\.rawValue) + ["exit"])
        var seen = reserved
        for command in session.extensionRunner?.getRegisteredCommands() ?? [] where !reserved.contains(command.name.lowercased()) {
            if seen.insert(command.invocationName).inserted {
                commands.append(.init(name: command.invocationName, summary: command.description, argumentHint: "arguments",
                    source: .extension, location: command.extensionID))
            }
        }
        for template in session.resourceLoader?.getPrompts().templates ?? [] where !reserved.contains(template.name.lowercased()) && seen.insert(template.name).inserted {
            commands.append(.init(name: template.name, summary: template.description, argumentHint: template.argumentHint,
                source: .prompt, location: template.filePath))
        }
        if session.settingsManager.getEnableSkillCommands() {
            for skill in session.resourceLoader?.getSkills().skills ?? [] where seen.insert("skill:" + skill.name).inserted {
                commands.append(.init(name: "skill:" + skill.name, summary: skill.description, argumentHint: "instructions",
                    source: .skill, location: skill.filePath))
            }
        }
        return commands
    }
    func resourceDiagnostics() -> [ResourceDiagnostic] {
        (session.resourceLoader?.getSkills().diagnostics ?? []) + (session.resourceLoader?.getPrompts().diagnostics ?? [])
    }
}
