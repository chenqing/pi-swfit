import Foundation
import PiAI
import PiAgent
import Testing
@testable import PiCodingAgent

// Port of test/session-manager/save-entry.test.ts

@Suite("SessionManager.saveCustomEntry") struct SaveCustomEntryTests {
    @Test("saves custom entries and includes them in tree traversal") func savesCustomEntries() throws {
        let session = try SessionManager.inMemory()

        // Save a message
        let msgId = try session.appendMessage(AgentMessage.user(UserMessage(content: "hello", timestamp: 1)))

        // Save a custom entry
        let customId = try session.appendCustomEntry("my_data", ["foo": "bar"])

        // Save another message
        let msg2Id = try session.appendMessage(AgentMessage.assistant(AssistantMessage(
            content: [.text(TextContent(text: "hi"))],
            api: "anthropic-messages",
            provider: "anthropic",
            model: "test",
            usage: Usage(input: 1, output: 1, cacheRead: 0, cacheWrite: 0, totalTokens: 2, cost: UsageCost()),
            stopReason: .stop,
            timestamp: 2
        )))

        // Custom entry should be in entries
        let entries = session.getEntries()
        #expect(entries.count == 3)

        let customEntry = try #require(entries.compactMap { entry -> CustomEntry? in
            if case .custom(let custom) = entry { return custom }
            return nil
        }.first)
        #expect(customEntry.customType == "my_data")
        #expect(customEntry.data == ["foo": "bar"])
        #expect(customEntry.id == customId)
        #expect(customEntry.parentId == msgId)

        // Tree structure should be correct
        let path = session.getBranch()
        #expect(path.count == 3)
        #expect(path[0].id == msgId)
        #expect(path[1].id == customId)
        #expect(path[2].id == msg2Id)

        // buildSessionContext should work (custom entries skipped in messages)
        let ctx = session.buildSessionContext()
        #expect(ctx.messages.count == 2) // only message entries
    }
}
