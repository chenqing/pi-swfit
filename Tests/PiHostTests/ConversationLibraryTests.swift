import Foundation
import Testing
import PiAI
import PiAgent
import PiCodingAgent
import PiChat
@testable import PiHost

@Suite @MainActor struct ConversationLibraryTests {
    @Test func organizationPreservesTranscriptAndRenameHonorsLease() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let paths = HostPaths(agentDir: root.appendingPathComponent("agent").path)
        let store = ConnectionStore(paths: paths, credentials: MemoryCredentials())
        let profile = ConnectionProfile(name: "Test", modelID: "one", api: "openai-completions", endpoint: "http://localhost:1234/v1")
        let stream: StreamFn = { model, _, _ in
            let stream = createAssistantMessageEventStream()
            let message = AssistantMessage(content: [.text(TextContent(text: "Hello"))], api: model.api, provider: model.provider, model: model.id)
            stream.push(.done(reason: .stop, message: message)); return stream
        }
        let chat = try await ChatSession.openCoding(cwd: root.path, profile: profile, store: store, streamFn: stream)
        await chat.send("Example")
        let file = try #require(chat.sessionFile), library = ConversationLibrary(paths: paths)
        let original = try Data(contentsOf: URL(fileURLWithPath: file))
        try library.update(file, pinned: true)
        try library.update(file, archived: true)
        #expect(try library.load()[file]?.pinned == true)
        #expect(try library.load()[file]?.archived == true)
        #expect(try Data(contentsOf: URL(fileURLWithPath: file)) == original)
        #expect(throws: (any Error).self) { try library.rename(file, title: "Locked") }
        try chat.rename("  Better\nname  ")
        #expect(chat.name == "Better name")
        await chat.shutdown()
        try library.rename(file, title: "Renamed again")
        #expect(try SessionManager.open(file).getSessionName() == "Renamed again")
        try library.update(file, archived: false)
        #expect(try library.load()[file]?.archived == false)
        #expect(try library.load()[file]?.pinned == true)
        #expect(throws: (any Error).self) { try library.rename(file, title: " \n ") }
        let manager = try SessionManager.open(file)
        #expect(manager.buildSessionContext().messages.contains { $0.role == "user" })
    }

    @Test func modelSwitchKeepsTranscriptDraftLeaseAndUsesNewCredential() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let paths = HostPaths(agentDir: root.appendingPathComponent("agent").path)
        let store = ConnectionStore(paths: paths, credentials: MemoryCredentials())
        let first = ConnectionProfile(id: "one", name: "One", modelID: "one", api: "openai-completions", endpoint: "http://localhost:1234/v1")
        let second = ConnectionProfile(id: "two", name: "Two", modelID: "two", api: "openai-completions", endpoint: "http://localhost:5678/v1")
        try store.save(first, apiKey: "first-test-key"); try store.save(second, apiKey: "second-test-key")
        let routes = Locked<[String]>([])
        let stream: StreamFn = { model, _, options in
            routes.withLock { $0.append(model.id + ":" + (options?.apiKey ?? "missing")) }
            let stream = createAssistantMessageEventStream()
            let message = AssistantMessage(content: [.text(TextContent(text: "Hello"))], api: model.api, provider: model.provider, model: model.id)
            stream.push(.done(reason: .stop, message: message)); return stream
        }
        let chat = try await ChatSession.openCoding(cwd: root.path, profile: first, store: store, streamFn: stream)
        await chat.send("First")
        let file = try #require(chat.sessionFile)
        chat.draft = "Keep this draft"
        var invalid = second; invalid.endpoint = "ftp://example.invalid"
        await #expect(throws: (any Error).self) { try await chat.selectConnection(invalid, store: store) }
        #expect(chat.connectionID == first.id && chat.draft == "Keep this draft" && !chat.isChangingConnection)
        try await chat.selectConnection(second, store: store)
        #expect(chat.draft == "Keep this draft" && chat.sessionFile == file)
        #expect(chat.messages.filter { $0.role == .user }.count == 1)
        #expect(chat.connectionID == second.id)
        #expect(throws: (any Error).self) { try ConversationLibrary(paths: paths).rename(file, title: "Locked") }
        await chat.send()
        #expect(routes.current == ["one:first-test-key", "two:second-test-key"])
        #expect(CodingSessionHost.savedConnectionID(try SessionManager.open(file)) == "two")
        try await chat.reset()
        await chat.send("New conversation")
        #expect(routes.current.last == "two:second-test-key")
        await chat.shutdown()
        let reopened = try await ChatSession.openCoding(cwd: root.path, profile: second, store: store, sessionFile: file, streamFn: stream)
        #expect(reopened.messages.filter { $0.role == .user }.count == 2)
        await reopened.shutdown()
        #expect(!(try String(contentsOfFile: file, encoding: .utf8)).contains("test-key"))
    }
}
