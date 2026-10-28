import Foundation
import Testing
import PiAI
import PiAgent
import PiCodingAgent
import PiChat
@testable import PiHost

final class MemoryCredentials: PiHost.CredentialStore, Sendable {
    let values = Locked<[String: String]>([:])
    func read(account: String) throws -> String? { values.current[account] }
    func write(_ secret: String, account: String) throws { values.withLock { $0[account] = secret } }
    func remove(account: String) throws { values.withLock { _ = $0.removeValue(forKey: account) } }
}

private struct Fixture {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("pi-host-tests-" + UUID().uuidString)
    let keys = MemoryCredentials()
    var cwd: String { root.appendingPathComponent("workspace").path }
    var paths: HostPaths { HostPaths(agentDir: root.appendingPathComponent("agent").path) }
    var store: ConnectionStore { ConnectionStore(paths: paths, credentials: keys) }
    var profile: ConnectionProfile { ConnectionProfile(id: "fixture", name: "Fixture", modelID: "test-model", api: "openai-completions", endpoint: "http://127.0.0.1:19876/v1") }
    func prepare() throws { try FileManager.default.createDirectory(atPath: cwd, withIntermediateDirectories: true) }
    func cleanup() { try? FileManager.default.removeItem(at: root) }
}

private let codingStream: StreamFn = { model, context, _ in
    let stream = createAssistantMessageEventStream()
    var message = AssistantMessage(api: model.api, provider: model.provider, model: model.id)
    if context.messages.filter({ $0.role == "user" }).count > 1 {
        message.content = [.text(TextContent(text: "Restored conversation acknowledged."))]
    } else if !context.messages.contains(where: { if case .toolResult(let r) = $0 { return r.toolName == "read" }; return false }) {
        message.content = [.toolCall(ToolCall(id: "read-1", name: "read", arguments: ["path": "sample.txt"]))]
        message.stopReason = .toolUse
    } else if !context.messages.contains(where: { if case .toolResult(let r) = $0 { return r.toolName == "edit" }; return false }) {
        message.content = [.toolCall(ToolCall(id: "edit-1", name: "edit", arguments: ["path": "sample.txt", "edits": [["oldText": "before", "newText": "after"]]]))]
        message.stopReason = .toolUse
    } else { message.content = [.text(TextContent(text: "The change is complete."))] }
    stream.push(.start(partial: message)); stream.push(.done(reason: message.stopReason, message: message))
    return stream
}

@Suite("Shared native host") @MainActor
struct HostTests {
    private func waitForApproval(_ chat: ChatSession) async -> ChatApproval? {
        let until = Date().addingTimeInterval(3)
        while Date() < until {
            if let request = chat.approvals.pending.first { return request }
            if !chat.isRunning { await Task.yield() }
            try? await Task.sleep(for: .milliseconds(5))
        }
        return nil
    }
    @Test func profilesNeverStoreSecretsAndKeysAreBoundToDestination() throws {
        let f = Fixture(); try f.prepare(); defer { f.cleanup() }
        try f.store.save(f.profile, apiKey: "test-only-secret")
        let saved = try String(contentsOfFile: f.paths.agentDir + "/connections.json", encoding: .utf8)
        #expect(!saved.contains("test-only-secret"))
        #expect(try f.store.key(for: f.profile) == "test-only-secret")
        try f.store.save(f.profile, apiKey: nil)
        #expect(try f.store.key(for: f.profile) == "test-only-secret")
        var changed = f.profile; changed.endpoint = "https://example.invalid/v1"
        #expect(try f.store.key(for: changed) == nil)
        #expect(throws: (any Error).self) { try f.store.save(changed, apiKey: nil) }
        changed.endpoint = "https://user:secret@example.invalid/v1"
        #expect(throws: (any Error).self) { try changed.validate() }
        try f.store.forgetKey(for: f.profile)
        #expect(try f.store.key(for: f.profile) == nil)
    }

    @Test func approvedEditPersistsDiffAndResumesThroughSharedRuntime() async throws {
        let f = Fixture(); try f.prepare(); defer { f.cleanup() }
        try "before\n".write(toFile: f.cwd + "/sample.txt", atomically: true, encoding: .utf8)
        try f.store.save(f.profile, apiKey: "test-only-secret")
        let chat = try await ChatSession.openCoding(cwd: f.cwd, profile: f.profile, store: f.store, streamFn: codingStream)
        let task = Task { await chat.send("Read and update sample.txt") }; defer { task.cancel() }
        let read = try #require(await waitForApproval(chat)); #expect(read.toolName == "read")
        chat.approvals.resolve(read.id, allow: true)
        let edit = try #require(await waitForApproval(chat)); #expect(edit.toolName == "edit")
        #expect(edit.preview?.contains("-before") == true && edit.preview?.contains("+after") == true)
        #expect(try String(contentsOfFile: f.cwd + "/sample.txt", encoding: .utf8) == "before\n")
        chat.approvals.resolve(edit.id, allow: true); await task.value
        #expect(chat.state == .completed)
        #expect(try String(contentsOfFile: f.cwd + "/sample.txt", encoding: .utf8) == "after\n")
        let file = try #require(chat.sessionFile)
        #expect(chat.messages.flatMap(\.tools).contains { $0.diff?.contains("+after") == true })
        await #expect(throws: (any Error).self) {
            try await ChatSession.openCoding(cwd: f.cwd, profile: f.profile, store: f.store, sessionFile: file, streamFn: codingStream)
        }
        await chat.shutdown()
        let saved = try String(contentsOfFile: file, encoding: .utf8)
        #expect(!saved.contains("test-only-secret"))
        let reopened = try await ChatSession.openCoding(cwd: f.cwd, profile: f.profile, store: f.store, sessionFile: file, streamFn: codingStream)
        #expect(reopened.messages.filter { $0.role == .user }.count == 1)
        #expect(reopened.messages.flatMap(\.tools).contains { $0.diff?.contains("+after") == true && $0.state == .succeeded })
        await reopened.send("Continue")
        #expect(reopened.messages.filter { $0.role == .user }.count == 2)
        await reopened.shutdown()
        let manager = try SessionManager.open(file)
        #expect(CodingSessionHost.savedConnectionID(manager) == f.profile.id)
        let host = try await CodingSessionHost.open(cwd: f.cwd, paths: f.paths, manager: manager,
            options: AgentOptions(initialState: AgentInitialState(model: try f.profile.model()), streamFn: codingStream))
        try await host.session.prompt("Continue in pf")
        #expect(await host.session.messages.filter { $0.role == "user" }.count == 3)
        await host.shutdown()
    }

    @Test func changedFileDuringApprovalIsNotOverwritten() async throws {
        let f = Fixture(); try f.prepare(); defer { f.cleanup() }
        try "before\n".write(toFile: f.cwd + "/sample.txt", atomically: true, encoding: .utf8)
        let chat = try await ChatSession.openCoding(cwd: f.cwd, profile: f.profile, store: f.store, streamFn: codingStream)
        let task = Task { await chat.send("Update") }; defer { task.cancel() }
        let read = try #require(await waitForApproval(chat)); chat.approvals.resolve(read.id, allow: true)
        let edit = try #require(await waitForApproval(chat))
        try "external edit\n".write(toFile: f.cwd + "/sample.txt", atomically: true, encoding: .utf8)
        chat.approvals.resolve(edit.id, allow: true); await task.value
        #expect(try String(contentsOfFile: f.cwd + "/sample.txt", encoding: .utf8) == "external edit\n")
        #expect(chat.messages.flatMap(\.tools).contains { $0.name == "edit" && $0.state == .failed })
        await chat.shutdown()
    }

    @Test func declinedEditDoesNotWriteAndNewConversationPreservesOldSession() async throws {
        let f = Fixture(); try f.prepare(); defer { f.cleanup() }
        try "before\n".write(toFile: f.cwd + "/sample.txt", atomically: true, encoding: .utf8)
        let chat = try await ChatSession.openCoding(cwd: f.cwd, profile: f.profile, store: f.store, streamFn: codingStream)
        let task = Task { await chat.send("Update") }; defer { task.cancel() }
        let read = try #require(await waitForApproval(chat)); chat.approvals.resolve(read.id, allow: true)
        let edit = try #require(await waitForApproval(chat)); chat.approvals.resolve(edit.id, allow: false)
        await task.value
        #expect(try String(contentsOfFile: f.cwd + "/sample.txt", encoding: .utf8) == "before\n")
        let old = try #require(chat.sessionFile)
        try await chat.reset()
        #expect(chat.messages.isEmpty && chat.sessionFile != old)
        #expect(FileManager.default.fileExists(atPath: old))
        await chat.shutdown()
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["PI_HOST_KEYCHAIN_TEST"] == "1"))
    func realKeychainRoundTripWithDisposableCredential() throws {
        let store = KeychainCredentialStore(service: "dev.chenqing.pi-swift.tests." + UUID().uuidString)
        let account = UUID().uuidString
        defer { try? store.remove(account: account) }
        try store.write("fixture-one", account: account)
        #expect(try store.read(account: account) == "fixture-one")
        try store.write("fixture-two", account: account)
        #expect(try store.read(account: account) == "fixture-two")
        try store.remove(account: account)
        #expect(try store.read(account: account) == nil)
    }

    @Test func cancellingApprovalReleasesSessionAndFolderAliasesShareHistory() async throws {
        let f = Fixture(); try f.prepare(); defer { f.cleanup() }
        let alias = f.root.appendingPathComponent("alias").path
        try FileManager.default.createSymbolicLink(atPath: alias, withDestinationPath: f.cwd)
        #expect(f.paths.sessionDirectory(cwd: alias) == f.paths.sessionDirectory(cwd: f.cwd))
        let chat = try await ChatSession.openCoding(cwd: alias, profile: f.profile, store: f.store, streamFn: codingStream)
        let task = Task { await chat.send("Read the file") }; defer { task.cancel() }
        _ = try #require(await waitForApproval(chat))
        chat.stop(); await task.value
        #expect(chat.state == .cancelled && chat.approvals.pending.isEmpty)
        let file = try #require(chat.sessionFile)
        await chat.shutdown()
        let recent = try SessionManager.continueRecent(HostPaths.canonicalWorkspace(f.cwd), f.paths.sessionDirectory(cwd: f.cwd))
        #expect(recent.getSessionFile() == file)
        let reopened = try await ChatSession.openCoding(cwd: f.cwd, profile: f.profile, store: f.store, sessionFile: file, streamFn: codingStream)
        await reopened.shutdown()
    }
}
