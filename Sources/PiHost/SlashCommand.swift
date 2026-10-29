import Foundation
import PiAI
import PiCodingAgent

/// Native host commands. Names follow upstream; presentation belongs to each host.
public enum SlashCommand: String, CaseIterable, Sendable, Identifiable {
    case new, resume, name, model, thinking, tree, fork, settings, compact, session, copy, reload, help, quit
    public var id: String { rawValue }
    public var summary: String {
        switch self {
        case .new: "Start a new conversation"
        case .resume: "Resume a saved conversation"
        case .name: "Rename this conversation"
        case .model: "Choose a saved model connection"
        case .thinking: "Choose the model’s thinking level"
        case .tree: "Navigate branches in this conversation"
        case .fork: "Fork from a previous user message"
        case .settings: "Open connection settings"
        case .compact: "Summarize the current model context"
        case .session: "Show session info and usage"
        case .copy: "Copy the last assistant response"
        case .help: "Show available commands"
        case .quit: "Quit pf"
        case .reload: "Reload skills, templates and native extension resources"
        }
    }
    public var argumentHint: String? {
        switch self { case .thinking: "level"; case .name: "title"; case .model: "provider/model or connection"; case .compact: "instructions"; default: nil }
    }
    public static var desktop: [Self] { allCases.filter { $0 != .quit } }
    public static func suggestions(_ input: String, commands: [Self] = desktop) -> [Self] {
        guard input.hasPrefix("/"), !input.dropFirst().contains(where: \.isWhitespace) else { return [] }
        let prefix = String(input.dropFirst()).lowercased()
        return commands.filter { $0.rawValue.hasPrefix(prefix) }
    }
    public struct Invocation: Sendable, Equatable {
        public let command: SlashCommand
        public let argument: String
    }
    /// nil is ordinary prose (including absolute paths containing another slash).
    /// An unknown command fails locally rather than becoming a model request.
    public static func parse(_ input: String, catalog: [CommandDescriptor] = []) throws -> Invocation? {
        let value = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard value.hasPrefix("/"), !value.hasPrefix("//") else { return nil }
        let parts = value.dropFirst().split(maxSplits: 1, whereSeparator: \.isWhitespace)
        let token = parts.first.map(String.init) ?? ""
        guard !token.contains("/"), !token.hasPrefix("skill:") else { return nil }
        let name = token == "exit" ? "quit" : token.lowercased()
        guard let command = Self(rawValue: name) else {
            if catalog.contains(where: { $0.source != .builtin && $0.name == token }) { return nil }
            throw PiError("Unknown command /\(token). Use /help to see available commands.")
        }
        let argument = parts.count > 1 ? String(parts[1]).trimmingCharacters(in: .whitespacesAndNewlines) : ""
        guard argument.isEmpty || command.argumentHint != nil else { throw PiError("/\(command.rawValue) does not take arguments") }
        return Invocation(command: command, argument: argument)
    }
    public static func matchConnection(_ input: String, profiles: [ConnectionProfile]) throws -> ConnectionProfile {
        let matches = profiles.filter { $0.id == input || $0.name == input || $0.modelID == input || $0.provider + "/" + $0.modelID == input }
        guard matches.count == 1, let profile = matches.first else {
            throw PiError(matches.isEmpty ? "No saved connection matches \(input). Use /model to choose one." : "Several connections match \(input). Use a connection name or ID.")
        }
        return profile
    }
    public static func describe(_ stats: SessionStats) -> String {
        "Session: \(stats.sessionId)\nFile: \(stats.sessionFile ?? "In memory")\nMessages: \(stats.userMessages) user · \(stats.assistantMessages) assistant\nTools: \(stats.toolCalls) calls\nTokens: \(stats.tokens.input) in · \(stats.tokens.output) out · \(stats.tokens.cacheRead) cached\nCost: \(String(format: "$%.4f", stats.cost))"
    }
}
