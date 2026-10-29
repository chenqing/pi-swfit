import Foundation
import Testing
@testable import PiHost

struct ConversationDraftStoreTests {
    private func root() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }
    @Test func restoresExactTextAcrossInstancesWithoutTouchingTranscript() throws {
        let root = try root(); defer { try? FileManager.default.removeItem(at: root) }
        let paths = HostPaths(agentDir: root.appendingPathComponent("agent").path)
        let session = root.appendingPathComponent("session.jsonl")
        let transcript = Data("original transcript\n".utf8)
        try transcript.write(to: session)
        let draft = "  中文草稿 👋\n\n```swift\nlet value = 1\n```\n"
        try ConversationDraftStore(paths: paths).save(draft, for: session.path)
        #expect(try ConversationDraftStore(paths: paths).load(for: session.path) == draft)
        #expect(try Data(contentsOf: session) == transcript)
        let directory = root.appendingPathComponent("agent/drafts")
        let file = try #require(FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil).first { $0.pathExtension == "json" })
        #expect(try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? Int == 0o600)
        #expect(try FileManager.default.attributesOfItem(atPath: directory.path)[.posixPermissions] as? Int == 0o700)
    }
    @Test func separateSessionsAndClearingDoNotResurrectOldDrafts() throws {
        let root = try root(); defer { try? FileManager.default.removeItem(at: root) }
        let paths = HostPaths(agentDir: root.path)
        let first = root.appendingPathComponent("one/session.jsonl").path
        let second = root.appendingPathComponent("two/session.jsonl").path
        let store = ConversationDraftStore(paths: paths)
        try store.save("First", for: first); try store.save("Second", for: second)
        try store.save("Changed", for: first)
        #expect(try store.load(for: second) == "Second")
        try store.save("", for: first)
        #expect(try ConversationDraftStore(paths: paths).load(for: first) == "")
        #expect(try ConversationDraftStore(paths: paths).load(for: second) == "Second")
        // An unsent session need not have a transcript file to preserve its draft.
        #expect(!FileManager.default.fileExists(atPath: second))
        try store.save(" \n", for: first)
        #expect(try store.load(for: first) == " \n")
    }
    @Test func corruptDraftIsReportedAndLeftIntact() throws {
        let root = try root(); defer { try? FileManager.default.removeItem(at: root) }
        let store = ConversationDraftStore(paths: HostPaths(agentDir: root.path))
        let session = root.appendingPathComponent("session.jsonl").path
        try store.save("Draft", for: session)
        let file = try #require(FileManager.default.contentsOfDirectory(at: root.appendingPathComponent("drafts"), includingPropertiesForKeys: nil).first { $0.pathExtension == "json" })
        let invalid = Data("not JSON".utf8); try invalid.write(to: file)
        #expect(throws: (any Error).self) { try store.load(for: session) }
        #expect(try Data(contentsOf: file) == invalid)
    }
    @Test func listsLegacyAndNewUnsentDraftsOnlyInTheirWorkspace() throws {
        let root = try root(); defer { try? FileManager.default.removeItem(at: root) }
        let paths = HostPaths(agentDir: root.appendingPathComponent("agent").path)
        let store = ConversationDraftStore(paths: paths)
        let cwd = root.appendingPathComponent("project").path
        let first = paths.sessionDirectory(cwd: cwd) + "/first.jsonl"
        let second = paths.sessionDirectory(cwd: cwd) + "/second.jsonl"
        let saved = paths.sessionDirectory(cwd: cwd) + "/saved.jsonl"
        try store.save("旧草稿", for: first)
        try store.save("New draft", for: second, connectionID: "connection-two")
        try store.save("Saved transcript draft", for: saved)
        try paths.prepareSessionDirectory(cwd: cwd)
        try Data("transcript".utf8).write(to: URL(fileURLWithPath: saved))
        try store.save("Other workspace", for: paths.sessionDirectory(cwd: cwd + "-other") + "/other.jsonl")
        let result = try store.unsent(cwd: cwd + "/.")
        #expect(result.count == 2)
        #expect(result.first { $0.text == "旧草稿" }?.connectionID == nil)
        #expect(result.first { $0.text == "New draft" }?.connectionID == "connection-two")
        #expect(!FileManager.default.fileExists(atPath: first))
        try store.save("", for: first)
        #expect(try store.unsent(cwd: cwd).count == 1)
    }
    @Test func occupiedDraftLockFailsWithoutOverwritingSavedText() throws {
        let root = try root(); defer { try? FileManager.default.removeItem(at: root) }
        let store = ConversationDraftStore(paths: HostPaths(agentDir: root.path))
        let session = root.appendingPathComponent("session.jsonl").path
        try store.save("Saved", for: session)
        let file = try #require(FileManager.default.contentsOfDirectory(at: root.appendingPathComponent("drafts"), includingPropertiesForKeys: nil).first { $0.pathExtension == "json" })
        let lock = try HostFileLock(file.path + ".lock"); defer { lock.release() }
        #expect(throws: (any Error).self) { try store.save("Unsaved", for: session) }
        #expect(try store.load(for: session) == "Saved")
    }
}
