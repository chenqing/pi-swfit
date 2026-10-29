#if os(macOS)
import AppKit
import PiAI
import PiHost
import PiCodingAgent

/// Line-oriented presentation of the same host command vocabulary as the desktop.
final class CLICommands: Sendable {
    let activeHost: Locked<CodingSessionHost>
    let connections: ConnectionStore
    let demo: Bool
    let printLine: @Sendable (String) -> Void
    let read: @Sendable () -> String?
    init(host: CodingSessionHost, connections: ConnectionStore, demo: Bool,
         printLine: @escaping @Sendable (String) -> Void, read: @escaping @Sendable () -> String? = { readLine() }) {
        activeHost = Locked(host); self.connections = connections; self.demo = demo; self.printLine = printLine; self.read = read
    }
    /// false means quit. Errors are reported by the REPL without ending the session.
    func execute(_ invocation: SlashCommand.Invocation) async throws -> Bool {
        let host = activeHost.current, session = host.session
        guard !session.isStreaming else { throw PiError("Wait for the current response to finish") }
        switch invocation.command {
        case .quit: return false
        case .help:
            printLine(SlashCommand.allCases.map { "/" + $0.rawValue + " — " + $0.summary }.joined(separator: "\n"))
        case .session: printLine(SlashCommand.describe(await session.getSessionStats()))
        case .settings:
            let model = await session.model
            printLine("Model: \(model.provider)/\(model.id)\nWorkspace: \(host.cwd)\nAgent directory: \(host.paths.agentDir)\nUse /model to switch a saved connection; edit connections in Pi Swift.")
        case .compact:
            _ = try await session.compact(invocation.argument.isEmpty ? nil : invocation.argument)
            printLine("Session compacted.")
        case .name:
            let title: String
            if invocation.argument.isEmpty {
                printLine("Conversation title (empty cancels):")
                guard let value = read(), !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return true }
                title = value
            } else { title = invocation.argument }
            try host.manager.appendSessionInfo(ConversationLibrary.validTitle(title))
            printLine("Conversation renamed.")
        case .copy:
            let last = await session.messages.reversed().compactMap { message -> String? in
                guard case .assistant(let assistant) = message else { return nil }
                let text = assistant.content.compactMap { if case .text(let part) = $0 { return part.text }; return nil }.joined()
                return text.isEmpty ? nil : text
            }.first
            guard let last else { throw PiError("No assistant response to copy") }
            try await MainActor.run {
                NSPasteboard.general.clearContents()
                guard NSPasteboard.general.setString(last, forType: .string) else { throw PiError("Could not copy the response") }
            }
            printLine("Copied last assistant response.")
        case .new:
            let next = try await host.newConversation()
            activeHost.withLock { $0 = next }
            await host.shutdown()
            printLine("New conversation.")
        case .model:
            guard !demo else { throw PiError("Model switching is unavailable in --demo") }
            let profiles = try connections.load().profiles
            let profile: ConnectionProfile
            if invocation.argument.isEmpty {
                guard let index = choose(profiles.map { "\($0.name) · \($0.provider)/\($0.modelID)" }) else { return true }
                profile = profiles[index]
            } else { profile = try SlashCommand.matchConnection(invocation.argument, profiles: profiles) }
            let key = try connections.key(for: profile)
            try await host.selectConnection(profile, key: key)
            printLine("Model: \(profile.modelID)")
        case .resume:
            let entries = try await SessionManager.list(host.cwd, host.manager.getSessionDir())
            guard let index = choose(entries.map { ($0.name ?? $0.firstMessage) + " · " + $0.id }) else { return true }
            let entry = entries[index]
            if entry.path == host.manager.getSessionFile() { printLine("Already in this conversation."); return true }
            let manager = try SessionManager.open(entry.path)
            let id = CodingSessionHost.savedConnectionID(manager)
            if demo, id != nil { throw PiError("Provider-backed conversations cannot be resumed in --demo") }
            let profile: ConnectionProfile?
            if let id, !demo {
                guard let saved = try connections.load().profile(id) else { throw PiError("Restore the saved connection before resuming this session") }
                profile = saved
            } else { profile = nil }
            let next = try await host.resuming(file: entry.path, profile: profile, key: profile.flatMap { try connections.key(for: $0) })
            activeHost.withLock { $0 = next }
            await host.shutdown()
            printLine("Resumed conversation.")
        }
        return true
    }
    private func choose(_ labels: [String]) -> Int? {
        guard !labels.isEmpty else { printLine("No saved choices available."); return nil }
        for (index, label) in labels.enumerated() { printLine("\(index + 1). \(label)") }
        printLine("Choose a number (empty cancels):")
        guard let line = read(), !line.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        guard let number = Int(line), labels.indices.contains(number - 1) else { printLine("Invalid selection; no changes made."); return nil }
        return number - 1
    }
}
#endif
