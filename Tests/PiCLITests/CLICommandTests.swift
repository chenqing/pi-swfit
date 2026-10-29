#if os(macOS)
import Foundation
import Testing
import PiAI
import PiAgent
import PiHost
import PiCodingAgent
@testable import PiCLI

private struct NoCredentials: PiHost.CredentialStore {
    func read(account: String) throws -> String? { nil }
    func write(_ secret: String, account: String) throws {}
    func remove(account: String) throws {}
}
struct CLICommandTests {
    @Test func commandsPreserveTranscriptAndResumeThroughLeasedHosts() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = HostPaths(agentDir: root.appendingPathComponent("agent").path)
        let model = Model(id: "fixture", name: "Fixture", api: "openai-completions", provider: "fixture", baseUrl: "https://example.invalid")
        let calls = Locked(0)
        let options = AgentOptions(initialState: AgentInitialState(model: model), streamFn: { _, _, _ in
            calls.withLock { $0 += 1 }
            let stream = createAssistantMessageEventStream()
            stream.push(.done(reason: .stop, message: AssistantMessage(content: [.text(TextContent(text: "fixture reply"))], api: model.api, provider: model.provider, model: model.id)))
            return stream
        })
        let host = try await CodingSessionHost.open(cwd: root.path, paths: paths, options: options)
        try await host.session.prompt("original")
        let file = try #require(host.manager.getSessionFile())
        let output = Locked<[String]>([])
        let store = ConnectionStore(paths: paths, credentials: NoCredentials())
        let commands = CLICommands(host: host, connections: store, demo: false,
                                   printLine: { line in output.withLock { $0.append(line) } }, read: { "1" })
        func run(_ line: String) async throws { _ = try await commands.execute(#require(SlashCommand.parse(line))) }
        let before = try Data(contentsOf: URL(fileURLWithPath: file))
        try await run("/session"); try await run("/help"); try await run("/settings")
        #expect(try Data(contentsOf: URL(fileURLWithPath: file)) == before)
        #expect(calls.current == 1)
        try await run("/name command fixture")
        #expect(host.manager.getSessionName() == "command fixture")
        let profile = ConnectionProfile(id: "next", name: "Next", modelID: "next-model", api: "openai-completions", endpoint: "https://example.invalid")
        try store.save(profile, apiKey: nil)
        try await run("/model Next")
        #expect(await host.session.model.id == "next-model")
        #expect(CodingSessionHost.savedConnectionID(host.manager) == profile.id)
        await #expect(throws: (any Error).self) { try await run("/model missing") }
        #expect(await host.session.model.id == "next-model")
        try await run("/new")
        #expect(commands.activeHost.current !== host)
        #expect(await commands.activeHost.current.session.messages.filter { $0.role == "user" || $0.role == "assistant" }.isEmpty)
        try await run("/resume")
        #expect(commands.activeHost.current.manager.getSessionFile() == file)
        #expect(await commands.activeHost.current.session.messages.filter { $0.role == "user" || $0.role == "assistant" }.count == 2)
        #expect(calls.current == 1)
        #expect(output.current.contains(where: { $0.contains("Resumed") }))
        let resumed = commands.activeHost.current
        resumed.session.setCompactionHandler { _, _, _, _ in
            CompactionResult(summary: "Fixture summary", firstKeptEntryId: nil, tokensBefore: 100)
        }
        try await run("/compact keep decisions")
        let transcript = try String(contentsOfFile: file, encoding: .utf8)
        #expect(transcript.contains("Fixture summary"))
        #expect(!transcript.contains("/compact keep decisions"))
        #expect(calls.current == 1)
        await commands.activeHost.current.shutdown()
    }
    @Test func newInMemoryConversationDoesNotCreatePersistentSession() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let model = Model(id: "fixture", name: "Fixture", api: "openai-completions", provider: "fixture", baseUrl: "https://example.invalid")
        let host = try await CodingSessionHost.open(cwd: root.path, paths: HostPaths(agentDir: root.appendingPathComponent("agent").path),
                                                  manager: SessionManager.inMemory(root.path), options: AgentOptions(initialState: AgentInitialState(model: model)))
        let next = try await host.newConversation()
        #expect(next.manager.getSessionFile() == nil)
        await next.shutdown(); await host.shutdown()
    }
}
struct CLINavigationTests {
    @Test func selectorsCancelLocallyAndForkRestoresEditableText() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = HostPaths(agentDir: root.appendingPathComponent("agent").path)
        let model = Model(id: "fixture", name: "Fixture", api: "openai-completions", provider: "fixture", baseUrl: "https://example.invalid", reasoning: true)
        let count = Locked(0)
        let host = try await CodingSessionHost.open(cwd: root.path, paths: paths,
            options: AgentOptions(initialState: AgentInitialState(model: model), streamFn: { _, _, _ in
                count.withLock { $0 += 1 }
                let stream = createAssistantMessageEventStream()
                stream.push(.done(reason: .stop, message: AssistantMessage(content: [.text(TextContent(text: "reply"))], api: model.api, provider: model.provider, model: model.id)))
                return stream
            }))
        try await host.session.prompt("edit me")
        let inputs = Locked(["", "1"])
        let controller = CLICommands(host: host, connections: ConnectionStore(paths: paths, credentials: NoCredentials()),
            demo: false, printLine: { _ in }, read: { inputs.withLock { $0.isEmpty ? nil : $0.removeFirst() } })
        _ = try await controller.execute(#require(SlashCommand.parse("/thinking high")))
        #expect(await host.session.thinkingLevel == .high)
        _ = try await controller.execute(#require(SlashCommand.parse("/fork")))
        #expect(controller.activeHost.current === host)
        _ = try await controller.execute(#require(SlashCommand.parse("/fork")))
        #expect(controller.activeHost.current !== host)
        #expect(controller.pendingDraft.current == "edit me")
        #expect(await controller.activeHost.current.session.messages.filter { $0.role == "user" }.isEmpty)
        #expect(count.current == 1)
        await controller.activeHost.current.shutdown()
    }
}

#endif
