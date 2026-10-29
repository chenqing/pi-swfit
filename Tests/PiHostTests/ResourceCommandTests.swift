import Foundation
import Testing
import PiAI
import PiAgent
import PiCodingAgent
import PiChat
@testable import PiHost

private struct CommandFixture {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("pi-commands-" + UUID().uuidString)
    var paths: HostPaths { .init(agentDir: root.appendingPathComponent("agent").path) }
    let requests = Locked<[String]>([])
    var model: Model { .init(id: "fixture", name: "Fixture", api: "openai-completions", provider: "fixture", baseUrl: "https://example.invalid") }
    var stream: StreamFn { { model, context, _ in
        requests.withLock { $0.append(context.messages.compactMap { if case .user(let m) = $0 { return ({ switch m.content { case .string(let text): return text; case .blocks(let blocks): return blocks.compactMap { if case .text(let t) = $0 { return t.text }; return nil }.joined(separator: "\n") } })() }; return nil }.last ?? "") }
        let stream = createAssistantMessageEventStream()
        stream.push(.done(reason: .stop, message: AssistantMessage(content: [.text(TextContent(text: "Fixture reply"))], api: model.api, provider: model.provider, model: model.id)))
        return stream
    } }
    func write(_ path: String, _ text: String) throws {
        let url = root.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try text.write(to: url, atomically: true, encoding: .utf8)
    }
    func open(trusted: Bool? = nil, extensions: [NativeExtension] = []) async throws -> CodingSessionHost {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return try await CodingSessionHost.open(cwd: root.path, paths: paths,
            options: AgentOptions(initialState: AgentInitialState(model: model), streamFn: stream), projectTrusted: trusted, extensions: extensions)
    }
    func cleanup() { try? FileManager.default.removeItem(at: root) }
}

struct ResourceCommandTests {
    @Test @MainActor func interactiveSkillsFailBeforeSendingAndRetainEditableInput() async throws {
        let f = CommandFixture(); defer { f.cleanup() }
        try f.write("agent/skills/review/SKILL.md", "---\nname: review\ndescription: Review\n---\nReview body")
        let store = ConnectionStore(paths: f.paths, credentials: MemoryCredentials())
        let profile = ConnectionProfile(name: "Fixture", modelID: "fixture", api: "openai-completions", endpoint: "https://example.invalid")
        let chat = try await ChatSession.openCoding(cwd: f.root.path, profile: profile, store: store, streamFn: f.stream)
        chat.draft = "/skill:missing instructions"
        await chat.send()
        #expect(chat.draft == "/skill:missing instructions")
        #expect(chat.error?.contains("was not found") == true)
        #expect(chat.state == .failed && chat.messages.isEmpty && f.requests.current.isEmpty)
        chat.clearCommandError()
        #expect(chat.error == nil && chat.state == .idle && chat.draft == "/skill:missing instructions")
        try FileManager.default.removeItem(at: f.root.appendingPathComponent("agent/skills/review/SKILL.md"))
        chat.draft = "/skill:review keep decisions"
        await chat.send()
        #expect(chat.draft == "/skill:review keep decisions")
        #expect(chat.error?.contains("Could not read skill") == true)
        #expect(chat.messages.isEmpty && f.requests.current.isEmpty)
        try f.write("agent/skills/review/SKILL.md", "---\nname: review\ndescription: Review\n---\nRepaired skill")
        await chat.send()
        #expect(chat.error == nil && chat.draft.isEmpty && chat.state == .completed)
        #expect(f.requests.current.last?.contains("Repaired skill") == true)
        await chat.shutdown()
    }
    @Test func strictSkillExpansionIsOptInAndPreservesRuntimeFallback() async throws {
        let f = CommandFixture(); defer { f.cleanup() }
        let host = try await f.open()
        let count = host.manager.getEntries().count
        await #expect(throws: (any Error).self) { try await host.session.prompt("/skill:missing", .init(strictSkillCommands: true)) }
        #expect(host.manager.getEntries().count == count && f.requests.current.isEmpty)
        try await host.session.prompt("/skill:missing")
        #expect(f.requests.current.last == "/skill:missing")
        await host.shutdown()
    }

    @Test func trustDiscoveryFiltersAndReloadStayInSameSession() async throws {
        let f = CommandFixture(); defer { f.cleanup() }
        try f.write("agent/prompts/review.md", "Global $1")
        try f.write(".pi/prompts/review.md", "Project $1")
        try f.write(".pi/prompts/local.md", "Project only")
        try f.write("agent/prompts/hidden.md", "Hidden")
        try f.write("agent/settings.json", #"{"prompts":["!prompts/hidden.md"]}"#)
        let host = try await f.open(trusted: false)
        let file = host.manager.getSessionFile()
        #expect(host.commandCatalog().contains { $0.name == "review" })
        #expect(!host.commandCatalog().contains { $0.name == "local" || $0.name == "hidden" })
        try await host.session.prompt("/review \"quoted file\"")
        #expect(f.requests.current.last == "Global quoted file")
        try f.write("agent/prompts/added.md", "Added ${1:-default}")
        try await host.session.reloadResources()
        #expect(host.manager.getSessionFile() == file)
        #expect(host.commandCatalog().contains { $0.name == "added" })
        try await host.session.prompt("/added")
        #expect(f.requests.current.last == "Added default")
        await host.shutdown()
        try WorkspaceResourceTrust(paths: f.paths).set(f.root.path, trusted: true)
        let trusted = try await f.open()
        #expect(trusted.commandCatalog().contains { $0.name == "local" })
        #expect(trusted.resourceDiagnostics().contains { $0.type == .collision })
        try await trusted.session.prompt("/review x")
        #expect(f.requests.current.last == "Project x")
        await trusted.shutdown()
        try WorkspaceResourceTrust(paths: f.paths).set(f.root.path, trusted: false)
        let revoked = try await f.open()
        #expect(!revoked.commandCatalog().contains { $0.name == "local" })
        await revoked.shutdown()
    }
    @Test func disabledModelSkillRemainsUserInvocableAndSettingOnlyHidesCompletion() async throws {
        let f = CommandFixture(); defer { f.cleanup() }
        try f.write("agent/skills/private/SKILL.md", "---\nname: private\ndescription: User skill\ndisable-model-invocation: true\n---\nSkill body")
        let host = try await f.open()
        #expect(host.commandCatalog().contains { $0.name == "skill:private" })
        try await host.session.prompt("/skill:private extra")
        #expect(f.requests.current.last?.contains("Skill body\n</skill>\n\nextra") == true)
        try f.write("agent/settings.json", #"{"enableSkillCommands":false}"#)
        try await host.session.reloadResources()
        #expect(!host.commandCatalog().contains { $0.name == "skill:private" })
        try await host.session.prompt("/skill:private explicit")
        #expect(f.requests.current.last?.hasSuffix("explicit") == true)
        await host.shutdown()
    }
    @Test func extensionsWinOverTemplatesAndNeverCreateUserMessages() async throws {
        let f = CommandFixture(); defer { f.cleanup() }
        try f.write("agent/prompts/hello.md", "Template")
        try f.write("agent/prompts/NEW.md", "Must not hide a builtin")
        let calls = Locked<[String]>([])
        let ext = NativeExtension(id: "fixture", commands: [.init(name: "hello", description: "Local handler", execute: { text, _ in calls.withLock { $0.append(text) } })])
        let host = try await f.open(extensions: [ext])
        let catalog = host.commandCatalog()
        #expect(catalog.filter { $0.name == "hello" }.map(\.source) == [.extension])
        #expect(!catalog.contains { $0.name == "NEW" })
        #expect(try SlashCommand.parse("/hello literal", catalog: catalog) == nil)
        #expect(try SlashCommand.parse("/NEW", catalog: catalog)?.command == .new)
        let count = host.manager.getEntries().count
        try await host.session.prompt("/hello literal")
        #expect(calls.current == ["literal"])
        #expect(f.requests.current.isEmpty)
        #expect(host.manager.getEntries().count == count)
        try await host.session.prompt("/hello literal", .init(expandPromptTemplates: false))
        #expect(calls.current == ["literal"])
        #expect(f.requests.current.last == "/hello literal")
        let next = try await host.newConversation()
        #expect(next.commandCatalog().contains { $0.name == "hello" })
        await host.shutdown(); await next.shutdown()
    }
    @Test func duplicateExtensionsGetStableInvocationSuffixes() async throws {
        let f = CommandFixture(); defer { f.cleanup() }
        let calls = Locked<[String]>([])
        let extensions = ["first", "second"].map { id in NativeExtension(id: id, commands: [.init(name: "same", description: id, execute: { _, _ in calls.withLock { $0.append(id) } })]) }
        let host = try await f.open(extensions: extensions)
        #expect(host.commandCatalog().filter { $0.source == .extension }.map(\.name) == ["same:1", "same:2"])
        try await host.session.prompt("/same:2")
        #expect(calls.current == ["second"])
        #expect(throws: PiError.self) { try SlashCommand.parse("/same", catalog: host.commandCatalog()) }
        await host.shutdown()
        #expect(host.session.extensionRunner?.getRegisteredCommands().isEmpty == true)
    }
    @Test @MainActor func desktopHandledAndFailedCommandsPreservePresentationAndDraft() async throws {
        let f = CommandFixture(); defer { f.cleanup() }
        try f.write("agent/prompts/review.md", "Read $1")
        let store = ConnectionStore(paths: f.paths, credentials: MemoryCredentials())
        let profile = ConnectionProfile(id: "fixture", name: "Fixture", modelID: "fixture", api: "openai-completions", endpoint: "https://example.invalid")
        let ext = NativeExtension(id: "fixture", commands: [
            .init(name: "handled", description: "No provider", execute: { _, _ in }),
            .init(name: "fail", description: "Fail locally", execute: { _, _ in throw PiError("Extension failed") })])
        let chat = try await ChatSession.openCoding(cwd: f.root.path, profile: profile, store: store, streamFn: f.stream, extensions: [ext])
        chat.draft = "/handled"; await chat.send()
        #expect(chat.messages.isEmpty && chat.draft.isEmpty && f.requests.current.isEmpty)
        chat.draft = "/fail"; await chat.send()
        #expect(chat.messages.isEmpty && chat.draft == "/fail" && chat.error != nil)
        chat.draft = "unsent"; _ = try await chat.reloadResources()
        #expect(chat.draft == "unsent" && chat.commands.contains { $0.name == "review" })
        await chat.shutdown()
    }
}
