import Foundation
import PiAI
import PiAgent
import Testing
@testable import PiCodingAgent

// Port of test/session-manager/labels.test.ts

private func hiMessage() -> AgentMessage {
    .assistant(AssistantMessage(
        content: [.text(TextContent(text: "hi"))],
        api: "anthropic-messages",
        provider: "anthropic",
        model: "test",
        usage: Usage(input: 1, output: 1, cacheRead: 0, cacheWrite: 0, totalTokens: 2, cost: UsageCost()),
        stopReason: .stop,
        timestamp: 2
    ))
}

private func user(_ text: String, _ timestamp: Int) -> AgentMessage {
    .user(UserMessage(content: .string(text), timestamp: timestamp))
}

@Suite("SessionManager labels") struct LabelsTests {
    @Test("sets and gets labels") func setsAndGets() throws {
        let session = try SessionManager.inMemory()

        let msgId = try session.appendMessage(user("hello", 1))

        // No label initially
        #expect(session.getLabel(msgId) == nil)

        // Set a label
        let labelId = try session.appendLabelChange(msgId, "checkpoint")
        #expect(session.getLabel(msgId) == "checkpoint")

        // Label entry should be in entries
        let labelEntry = try #require(session.getEntries().compactMap(\.labelEntry).first)
        #expect(labelEntry.id == labelId)
        #expect(labelEntry.targetId == msgId)
        #expect(labelEntry.label == "checkpoint")
    }

    @Test("clears labels with undefined") func clearsLabels() throws {
        let session = try SessionManager.inMemory()

        let msgId = try session.appendMessage(user("hello", 1))

        _ = try session.appendLabelChange(msgId, "checkpoint")
        #expect(session.getLabel(msgId) == "checkpoint")

        // Clear the label
        _ = try session.appendLabelChange(msgId, nil)
        #expect(session.getLabel(msgId) == nil)
    }

    @Test("last label wins") func lastLabelWins() throws {
        let session = try SessionManager.inMemory()

        let msgId = try session.appendMessage(user("hello", 1))

        _ = try session.appendLabelChange(msgId, "first")
        _ = try session.appendLabelChange(msgId, "second")
        let lastLabelId = try session.appendLabelChange(msgId, "third")

        #expect(session.getLabel(msgId) == "third")

        let lastLabelEntry = try #require(session.getEntries().first { $0.id == lastLabelId })
        let msgNode = session.getTree().first { $0.entry.id == msgId }
        #expect(msgNode?.labelTimestamp == lastLabelEntry.timestamp)
    }

    @Test("labels are included in tree nodes") func labelsInTree() throws {
        let session = try SessionManager.inMemory()

        let msg1Id = try session.appendMessage(user("hello", 1))
        let msg2Id = try session.appendMessage(hiMessage())

        let msg1LabelId = try session.appendLabelChange(msg1Id, "start")
        let msg2LabelId = try session.appendLabelChange(msg2Id, "response")

        let entries = session.getEntries()
        let msg1LabelEntry = try #require(entries.first { $0.id == msg1LabelId })
        let msg2LabelEntry = try #require(entries.first { $0.id == msg2LabelId })
        let tree = session.getTree()

        // Find the message nodes (skip label entries)
        let msg1Node = tree.first { $0.entry.id == msg1Id }
        #expect(msg1Node?.label == "start")
        #expect(msg1Node?.labelTimestamp == msg1LabelEntry.timestamp)

        // msg2 is a child of msg1
        let msg2Node = msg1Node?.children.first { $0.entry.id == msg2Id }
        #expect(msg2Node?.label == "response")
        #expect(msg2Node?.labelTimestamp == msg2LabelEntry.timestamp)
    }

    @Test("labels are preserved in createBranchedSession") func labelsPreservedInBranch() throws {
        let session = try SessionManager.inMemory()

        let msg1Id = try session.appendMessage(user("hello", 1))
        let msg2Id = try session.appendMessage(hiMessage())

        let msg1LabelId = try session.appendLabelChange(msg1Id, "important")
        let msg2LabelId = try session.appendLabelChange(msg2Id, "also-important")
        let originalEntries = session.getEntries()
        let msg1LabelEntry = try #require(originalEntries.first { $0.id == msg1LabelId })
        let msg2LabelEntry = try #require(originalEntries.first { $0.id == msg2LabelId })

        // Branch from msg2 (in-memory mode returns null, but updates internal state)
        try session.createBranchedSession(msg2Id)

        // Labels should be preserved
        #expect(session.getLabel(msg1Id) == "important")
        #expect(session.getLabel(msg2Id) == "also-important")

        // New label entries should exist
        #expect(session.getEntries().filter { $0.type == "label" }.count == 2)

        let tree = session.getTree()
        let msg1Node = tree.first { $0.entry.id == msg1Id }
        let msg2Node = msg1Node?.children.first { $0.entry.id == msg2Id }
        #expect(msg1Node?.labelTimestamp == msg1LabelEntry.timestamp)
        #expect(msg2Node?.labelTimestamp == msg2LabelEntry.timestamp)
    }

    @Test("rewires children of removed labels when forking") func rewiresChildren() throws {
        let session = try SessionManager.inMemory()

        let msg1Id = try session.appendMessage(user("hello", 1))
        _ = try session.appendLabelChange(msg1Id, "checkpoint")
        let modelChangeId = try session.appendModelChange("anthropic", "claude-test")
        let msg2Id = try session.appendMessage(user("followup", 2))

        try session.createBranchedSession(msg2Id)

        #expect(session.getEntry(modelChangeId)?.parentId == msg1Id)
    }

    @Test("labels not on path are not preserved in createBranchedSession") func labelsOffPath() throws {
        let session = try SessionManager.inMemory()

        let msg1Id = try session.appendMessage(user("hello", 1))
        let msg2Id = try session.appendMessage(hiMessage())
        let msg3Id = try session.appendMessage(user("followup", 3))

        // Label all messages
        _ = try session.appendLabelChange(msg1Id, "first")
        _ = try session.appendLabelChange(msg2Id, "second")
        _ = try session.appendLabelChange(msg3Id, "third")

        // Branch from msg2 (excludes msg3)
        try session.createBranchedSession(msg2Id)

        // Only labels for msg1 and msg2 should be preserved
        #expect(session.getLabel(msg1Id) == "first")
        #expect(session.getLabel(msg2Id) == "second")
        #expect(session.getLabel(msg3Id) == nil)
    }

    @Test("labels are not included in buildSessionContext") func labelsNotInContext() throws {
        let session = try SessionManager.inMemory()

        let msgId = try session.appendMessage(user("hello", 1))
        _ = try session.appendLabelChange(msgId, "checkpoint")

        let ctx = session.buildSessionContext()
        #expect(ctx.messages.count == 1)
        #expect(ctx.messages[0].role == "user")
    }

    @Test("throws when labeling non-existent entry") func throwsForMissing() throws {
        let session = try SessionManager.inMemory()

        #expect(thrownMessage { try session.appendLabelChange("non-existent", "label") }?.contains("Entry non-existent not found") == true)
    }
}
