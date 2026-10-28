import Foundation
import Testing
import PiAI
import PiAgent
@testable import PiCodingAgent

@Suite("Upstream alignment 2026-10-28")
struct UpstreamAlignmentTests {
    @Test func namesOutrankDescriptionLength() {
        func tool(_ name: String, _ description: String) -> ExtensionToolInfo {
            ExtensionToolInfo(tool: AgentTool(name: name, label: name, description: description, parameters: .object([:])) { _, _, _, _ in .init(content: []) }, exposure: .deferred, namespace: nil, active: false)
        }
        let tools = [tool("mcp__app__queue_read", "Read a queued message of this thread."),
                     tool("mcp__dev-app__thread_read", "Read durable state and a paginated timeline from any thread. The default view returns user messages, assistant messages and plans. Continue with afterPosition until hasMore is false.")]
        for query in ["thread_read", "dev_app__thread_read", "mcp__dev-app__thread_read", "Thread_Read", "thread read"] {
            #expect(rankTools(query: query, tools: tools, limit: 1).first?.tool.name == "mcp__dev-app__thread_read")
        }
        #expect(rankTools(query: "read", tools: tools, limit: 1).first?.tool.name == "mcp__app__queue_read")
    }

    @Test func failedAppendDoesNotAdvanceMemory() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let session = try SessionManager.create(dir.path, dir.path)
        let first = try session.appendMessage(AgentMessage.user(UserMessage(content: .string("first"), timestamp: 1)))
        let file = try #require(session.getSessionFile())
        let original = try Data(contentsOf: URL(fileURLWithPath: file))
        // A directory at the file path reliably fails appends even under privileged CI users.
        try FileManager.default.removeItem(atPath: file)
        try FileManager.default.createDirectory(atPath: file, withIntermediateDirectories: false)
        #expect(throws: (any Error).self) { try session.appendMessage(AgentMessage.user(UserMessage(content: .string("lost"), timestamp: 2))) }
        #expect(session.getLeafId() == first)
        #expect(session.getEntries().map(\.id) == [first])
        try FileManager.default.removeItem(atPath: file)
        try original.write(to: URL(fileURLWithPath: file))
        let second = try session.appendMessage(AgentMessage.user(UserMessage(content: .string("second"), timestamp: 3)))
        #expect(session.getEntry(second)?.parentId == first)
        #expect(try SessionManager.open(file, dir.path).getBranch().map(\.id) == [first, second])
    }

    @Test func failedFirstFlushKeepsOnlySetupEntries() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let session = try SessionManager.create(dir.path, dir.path)
        let first = try session.appendModelChange("test", "fixture")
        let file = try #require(session.getSessionFile())
        try FileManager.default.createDirectory(atPath: file, withIntermediateDirectories: false)
        #expect(throws: (any Error).self) { try session.appendMessage(AgentMessage.user(UserMessage(content: .string("lost"), timestamp: 2))) }
        #expect(session.getLeafId() == first)
        #expect(session.getEntries().map(\.id) == [first])
        try FileManager.default.removeItem(atPath: file)
        let second = try session.appendMessage(AgentMessage.user(UserMessage(content: .string("second"), timestamp: 3)))
        #expect(try SessionManager.open(file, dir.path).getBranch().map(\.id) == [first, second])
    }
}
