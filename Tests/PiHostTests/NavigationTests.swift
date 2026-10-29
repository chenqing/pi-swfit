import Foundation
import Testing
import PiAI
import PiAgent
import PiCodingAgent
import PiChat
@testable import PiHost

private struct NavigationFixture {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("pi-navigation-" + UUID().uuidString)
    var paths: HostPaths { HostPaths(agentDir: root.appendingPathComponent("agent").path) }
    let levels = Locked<[ThinkingLevel?]>([])
    let fail = Locked(false)
    var model: Model { Model(id: "fixture", name: "Fixture", api: "openai-completions", provider: "fixture", baseUrl: "https://example.invalid", reasoning: true) }
    var stream: StreamFn { { model, _, options in
        if fail.current { throw PiError("fixture failure") }
        levels.withLock { $0.append(options?.reasoning) }
        let stream = createAssistantMessageEventStream()
        stream.push(.done(reason: .stop, message: AssistantMessage(content: [.text(TextContent(text: "Fixture reply"))], api: model.api, provider: model.provider, model: model.id)))
        return stream
    } }
    func open(memory: Bool = false) async throws -> CodingSessionHost {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return try await CodingSessionHost.open(cwd: root.path, paths: paths,
            manager: memory ? SessionManager.inMemory(root.path) : nil,
            options: AgentOptions(initialState: AgentInitialState(model: model), streamFn: stream))
    }
    func cleanup() { try? FileManager.default.removeItem(at: root) }
}

struct NavigationTests {
    @Test func initialThinkingDoesNotDiscardSeedMessages() async throws {
        let f = NavigationFixture(); defer { f.cleanup() }
        try FileManager.default.createDirectory(at: f.root, withIntermediateDirectories: true)
        var initial = AgentInitialState(model: f.model, thinkingLevel: .high)
        initial.messages = [.user(UserMessage(content: "seed context"))]
        let host = try await CodingSessionHost.open(cwd: f.root.path, paths: f.paths,
            options: AgentOptions(initialState: initial, streamFn: f.stream))
        #expect(await host.session.messages.contains { $0.role == "user" })
        #expect(host.manager.buildSessionContext().thinkingLevel == "high")
        await host.shutdown()
    }
    @Test func thinkingPersistsRestoresAndReachesProviderWithoutCommandMessages() async throws {
        let f = NavigationFixture(); defer { f.cleanup() }
        let host = try await f.open()
        let events = Locked<[String]>([])
        let unsubscribe = host.session.subscribe { event in events.withLock { $0.append(event.type) } }
        _ = try await host.selectThinking("HIGH")
        _ = try await host.selectThinking("high")
        #expect(events.current.filter { $0 == "thinking_level_changed" }.count == 1)
        await #expect(throws: (any Error).self) { _ = try await host.selectThinking("max") }
        #expect(await host.session.thinkingLevel == .high)
        try await host.session.prompt("hello")
        #expect(f.levels.current == [.high])
        let file = try #require(host.manager.getSessionFile())
        unsubscribe(); await host.shutdown()
        let restored = try await CodingSessionHost.open(cwd: f.root.path, paths: f.paths,
            manager: SessionManager.open(file), options: AgentOptions(initialState: AgentInitialState(model: f.model), streamFn: f.stream))
        #expect(await restored.session.thinkingLevel == .high)
        #expect(restored.manager.getEntries().filter { $0.type == "thinking_level_change" }.count == 1)
        #expect(restored.manager.getEntries().filter { $0.messageEntry?.message.role == "user" }.count == 1)
        await restored.shutdown()
    }
    @Test func treeKeepsBothBranchesAndReturnsUserTextWithoutSending() async throws {
        let f = NavigationFixture(); defer { f.cleanup() }
        let host = try await f.open()
        try await host.session.prompt("first")
        try await host.session.prompt("original second")
        let target = try #require(host.navigationItems(forkOnly: true).last)
        let originalLeaf = try #require(host.manager.getLeafId())
        let file = try #require(host.manager.getSessionFile())
        let originalBytes = try Data(contentsOf: URL(fileURLWithPath: file))
        #expect(try await host.session.navigateTree(target.id) == "original second")
        #expect(try Data(contentsOf: URL(fileURLWithPath: file)) == originalBytes)
        #expect(f.levels.current.count == 2)
        #expect(await host.session.messages.filter { $0.role == "user" }.count == 1)
        try await host.session.prompt("alternate second")
        #expect(host.manager.getEntry(originalLeaf) != nil)
        #expect(host.navigationItems(forkOnly: true).count == 3)
        #expect(try await host.session.navigateTree(originalLeaf) == nil)
        #expect(await host.session.messages.filter { $0.role == "user" }.count == 2)
        #expect(host.manager.getSessionFile() == file)
        await host.shutdown()
    }
    @Test func forkCopiesOnlyAncestorsAndKeepsSourceBytesAndLease() async throws {
        let f = NavigationFixture(); defer { f.cleanup() }
        let host = try await f.open()
        _ = try await host.selectThinking("medium")
        try await host.session.prompt("first")
        try await host.session.prompt("fork me")
        let target = try #require(host.navigationItems(forkOnly: true).last)
        let source = try #require(host.manager.getSessionFile())
        let bytes = try Data(contentsOf: URL(fileURLWithPath: source))
        let fork = try await host.fork(before: target.id)
        #expect(fork.text == "fork me")
        #expect(fork.host.manager.getSessionFile() != source)
        #expect(fork.host.manager.getHeader()?.parentSession == source)
        #expect(await fork.host.session.messages.filter { $0.role == "user" }.count == 1)
        #expect(await fork.host.session.thinkingLevel == .medium)
        #expect(try Data(contentsOf: URL(fileURLWithPath: source)) == bytes)
        #expect(host.manager.getEntry(target.id) != nil)
        #expect(throws: (any Error).self) { try HostFileLock(source + ".lock") }
        await fork.host.shutdown(); await host.shutdown()
    }
    @Test func firstMessageForkAndTreeWorkInMemory() async throws {
        let manager = try SessionManager.inMemory()
        let user = try manager.appendMessage(AgentMessage.user(UserMessage(content: "root message")))
        _ = try manager.appendMessage(AgentMessage.assistant(AssistantMessage(api: "openai-completions", provider: "fixture", model: "fixture")))
        let copy = try manager.forkBefore(user)
        #expect(copy.getSessionFile() == nil)
        #expect(copy.getEntries().isEmpty)
        #expect(manager.getEntries().count == 2)
        let f = NavigationFixture(); defer { f.cleanup() }
        let host = try await f.open(memory: true)
        try await host.session.prompt("in memory")
        let result = try await host.fork(before: #require(host.navigationItems(forkOnly: true).first).id)
        #expect(result.host.manager.getSessionFile() == nil)
        #expect(result.text == "in memory")
        await result.host.shutdown(); await host.shutdown()
    }
    @Test func summaryFailureDoesNotMoveLeafAndSuccessPersistsSummary() async throws {
        let f = NavigationFixture(); defer { f.cleanup() }
        let host = try await f.open()
        try await host.session.prompt("first")
        try await host.session.prompt("second")
        let target = try #require(host.navigationItems(forkOnly: true).first)
        let old = host.manager.getLeafId()
        f.fail.withLock { $0 = true }
        await #expect(throws: (any Error).self) { _ = try await host.session.navigateTree(target.id, summarize: true) }
        #expect(host.manager.getLeafId() == old)
        #expect(host.session.isIdle)
        f.fail.withLock { $0 = false }
        #expect(try await host.session.navigateTree(target.id, summarize: true, customInstructions: "Keep decisions") == "first")
        #expect(host.manager.getEntry(try #require(host.manager.getLeafId()))?.type == "branch_summary")
        #expect(host.manager.getEntry(try #require(old)) != nil)
        await host.shutdown()
    }
    @Test @MainActor func desktopForkRestoresDraftAndRejectsOverwrite() async throws {
        let f = NavigationFixture(); defer { f.cleanup() }
        try FileManager.default.createDirectory(at: f.root, withIntermediateDirectories: true)
        let store = ConnectionStore(paths: f.paths, credentials: MemoryCredentials())
        let profile = ConnectionProfile(name: "Fixture", modelID: "fixture", api: "openai-completions", endpoint: "https://example.invalid", thinkingLevels: [.off, .high])
        let chat = try await ChatSession.openCoding(cwd: f.root.path, profile: profile, store: store, streamFn: f.stream)
        try await chat.selectThinking("high")
        await chat.send("original draft")
        let entry = try #require(chat.navigationItems(forkOnly: true).first)
        chat.draft = "keep this"
        await #expect(throws: (any Error).self) { try await chat.navigate(to: entry.id, fork: true) }
        #expect(chat.draft == "keep this")
        let original = chat.sessionFile
        chat.draft = "/fork"
        try await chat.consumeCommand("/fork") { try await chat.navigate(to: entry.id, fork: true) }
        #expect(chat.draft == "original draft")
        #expect(chat.messages.isEmpty)
        #expect(chat.sessionFile != original)
        #expect(chat.permissionMode == .manual)
        #expect(f.levels.current.count == 1)
        await chat.shutdown()
    }
    @Test func failedWritesLeaveThinkingAndNavigationUntouched() async throws {
        let f = NavigationFixture(); defer { f.cleanup() }
        let host = try await f.open()
        try await host.session.prompt("first"); try await host.session.prompt("second")
        let old = host.manager.getLeafId()
        let count = host.manager.getEntries().count
        let file = try #require(host.manager.getSessionFile())
        try FileManager.default.moveItem(atPath: file, toPath: file + ".backup")
        try FileManager.default.createDirectory(atPath: file, withIntermediateDirectories: false)
        await #expect(throws: (any Error).self) { _ = try await host.selectThinking("high") }
        #expect(await host.session.thinkingLevel == .off)
        let target = try #require(host.navigationItems(forkOnly: true).first)
        await #expect(throws: (any Error).self) { _ = try await host.session.navigateTree(target.id, summarize: true) }
        #expect(host.manager.getLeafId() == old)
        #expect(host.manager.getEntries().count == count)
        #expect(host.session.isIdle)
        await host.shutdown()
    }
    @Test @MainActor func restoredDraftKeepsSelectedTreePositionAcrossRestart() async throws {
        let f = NavigationFixture(); defer { f.cleanup() }
        try FileManager.default.createDirectory(at: f.root, withIntermediateDirectories: true)
        let store = ConnectionStore(paths: f.paths, credentials: MemoryCredentials())
        let profile = ConnectionProfile(name: "Fixture", modelID: "fixture", api: "openai-completions", endpoint: "https://example.invalid")
        let chat = try await ChatSession.openCoding(cwd: f.root.path, profile: profile, store: store, streamFn: f.stream)
        await chat.send("first"); await chat.send("second")
        let entry = try #require(chat.navigationItems(forkOnly: true).last)
        try await chat.navigate(to: entry.id, fork: false)
        let file = try #require(chat.sessionFile)
        let drafts = ConversationDraftStore(paths: f.paths)
        try drafts.save(chat.draft, for: file, position: chat.draftPosition)
        await chat.shutdown()
        let restored = try await ChatSession.openCoding(cwd: f.root.path, profile: profile, store: store, sessionFile: file, streamFn: f.stream)
        restored.draft = try drafts.load(for: file)
        #expect(restored.draft == "second")
        #expect(restored.messages.filter { $0.role == .user }.map(\.text) == ["first"])
        #expect(try restored.navigationItems(forkOnly: true).count == 2)
        await restored.shutdown()
    }
    @Test func customCapabilitiesAreExplicitAndOldProfilesRemainDecodable() throws {
        let original = ConnectionProfile(name: "Unknown", modelID: "unknown", api: "openai-completions", endpoint: "https://example.invalid")
        #expect(try getSupportedThinkingLevels(original.model()) == [.off])
        var custom = original; custom.thinkingLevels = [.off, .low, .high, .xhigh]
        #expect(try getSupportedThinkingLevels(custom.model()) == [.off, .low, .high, .xhigh])
        let data = try JSONEncoder().encode(original)
        #expect(try JSONDecoder().decode(ConnectionProfile.self, from: data).thinkingLevels == nil)
        #expect(custom.credentialAccount == original.credentialAccount)
    }
}
