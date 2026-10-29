import Foundation
import PiAI
import PiAgent
import Testing
@testable import PiCodingAgent

// Port of test/session-manager/build-context.test.ts

private func msg(_ id: String, _ parentId: String?, _ role: String, _ text: String) -> SessionEntry {
    let message: AgentMessage
    if role == "user" {
        message = .user(UserMessage(content: .string(text), timestamp: 1))
    } else {
        message = .assistant(AssistantMessage(
            content: [.text(TextContent(text: text))],
            api: "anthropic-messages",
            provider: "anthropic",
            model: "claude-test",
            usage: Usage(input: 1, output: 1, cacheRead: 0, cacheWrite: 0, totalTokens: 2, cost: UsageCost()),
            stopReason: .stop,
            timestamp: 1
        ))
    }
    return .message(SessionMessageEntry(id: id, parentId: parentId, timestamp: "2025-01-01T00:00:00Z", message: message))
}

private func compaction(_ id: String, _ parentId: String?, _ summary: String, _ firstKeptEntryId: String) -> SessionEntry {
    .compaction(CompactionEntry(
        id: id, parentId: parentId, timestamp: "2025-01-01T00:00:00Z", summary: summary,
        firstKeptEntryId: firstKeptEntryId, tokensBefore: 1000
    ))
}

private func branchSummary(_ id: String, _ parentId: String?, _ summary: String, _ fromId: String) -> SessionEntry {
    .branchSummary(BranchSummaryEntry(id: id, parentId: parentId, timestamp: "2025-01-01T00:00:00Z", fromId: fromId, summary: summary))
}

private func custom(_ id: String, _ parentId: String?, _ customType: String, _ data: JsonValue? = nil) -> SessionEntry {
    .custom(CustomEntry(id: id, parentId: parentId, timestamp: "2025-01-01T00:00:00Z", customType: customType, data: data))
}

private func thinkingLevel(_ id: String, _ parentId: String?, _ level: String) -> SessionEntry {
    .thinkingLevelChange(ThinkingLevelChangeEntry(id: id, parentId: parentId, timestamp: "2025-01-01T00:00:00Z", thinkingLevel: level))
}

private func modelChange(_ id: String, _ parentId: String?, _ provider: String, _ modelId: String) -> SessionEntry {
    .modelChange(ModelChangeEntry(id: id, parentId: parentId, timestamp: "2025-01-01T00:00:00Z", provider: provider, modelId: modelId))
}

@Suite("buildSessionContext") struct BuildSessionContextTests {
    @Test("cyclic parent links terminate without repeating messages") func cyclicParents() {
        let selfCycle = buildSessionContext([msg("a", "a", "user", "hello")])
        #expect(selfCycle.messages.count == 1)
        let cycle = [msg("a", "b", "user", "hello"), msg("b", "a", "assistant", "reply")]
        #expect(buildSessionContext(cycle).messages.map(\.role) == ["user", "assistant"])
    }

    // MARK: trivial cases

    @Test("empty entries returns empty context") func emptyEntries() {
        let ctx = buildSessionContext([])
        #expect(ctx.messages.isEmpty)
        #expect(ctx.thinkingLevel == "off")
        #expect(ctx.model == nil)
    }

    @Test("single user message") func singleUserMessage() {
        let ctx = buildSessionContext([msg("1", nil, "user", "hello")])
        #expect(ctx.messages.count == 1)
        #expect(ctx.messages[0].role == "user")
    }

    @Test("simple conversation") func simpleConversation() {
        let entries = [
            msg("1", nil, "user", "hello"),
            msg("2", "1", "assistant", "hi there"),
            msg("3", "2", "user", "how are you"),
            msg("4", "3", "assistant", "great"),
        ]
        let ctx = buildSessionContext(entries)
        #expect(ctx.messages.count == 4)
        #expect(ctx.messages.map(\.role) == ["user", "assistant", "user", "assistant"])
    }

    @Test("tracks thinking level changes") func thinkingLevelChanges() {
        let entries = [
            msg("1", nil, "user", "hello"),
            thinkingLevel("2", "1", "high"),
            msg("3", "2", "assistant", "thinking hard"),
        ]
        let ctx = buildSessionContext(entries)
        #expect(ctx.thinkingLevel == "high")
        #expect(ctx.messages.count == 2)
    }

    @Test("tracks model from assistant message") func modelFromAssistant() {
        let ctx = buildSessionContext([msg("1", nil, "user", "hello"), msg("2", "1", "assistant", "hi")])
        #expect(ctx.model == SessionModelRef(provider: "anthropic", modelId: "claude-test"))
    }

    @Test("tracks model from model change entry") func modelFromModelChange() {
        let entries = [
            msg("1", nil, "user", "hello"),
            modelChange("2", "1", "openai", "gpt-4"),
            msg("3", "2", "assistant", "hi"),
        ]
        let ctx = buildSessionContext(entries)
        // Assistant message overwrites model change
        #expect(ctx.model == SessionModelRef(provider: "anthropic", modelId: "claude-test"))
    }

    // MARK: with compaction

    @Test("includes summary before kept messages") func summaryBeforeKept() {
        let entries = [
            msg("1", nil, "user", "first"),
            msg("2", "1", "assistant", "response1"),
            msg("3", "2", "user", "second"),
            msg("4", "3", "assistant", "response2"),
            compaction("5", "4", "Summary of first two turns", "3"),
            msg("6", "5", "user", "third"),
            msg("7", "6", "assistant", "response3"),
        ]
        let ctx = buildSessionContext(entries)

        // Should have: summary + kept (3,4) + after (6,7) = 5 messages
        #expect(ctx.messages.count == 5)
        #expect(summaryOf(ctx.messages[0])?.contains("Summary of first two turns") == true)
        #expect(contentString(ctx.messages[1]) == "second")
        #expect(firstText(ctx.messages[2]) == "response2")
        #expect(contentString(ctx.messages[3]) == "third")
        #expect(firstText(ctx.messages[4]) == "response3")
    }

    @Test("handles compaction keeping from first message") func compactionKeepingFirst() {
        let entries = [
            msg("1", nil, "user", "first"),
            msg("2", "1", "assistant", "response"),
            compaction("3", "2", "Empty summary", "1"),
            msg("4", "3", "user", "second"),
        ]
        let ctx = buildSessionContext(entries)

        // Summary + all messages (1,2,4)
        #expect(ctx.messages.count == 4)
        #expect(summaryOf(ctx.messages[0])?.contains("Empty summary") == true)
    }

    @Test("multiple compactions uses latest") func multipleCompactions() {
        let entries = [
            msg("1", nil, "user", "a"),
            msg("2", "1", "assistant", "b"),
            compaction("3", "2", "First summary", "1"),
            msg("4", "3", "user", "c"),
            msg("5", "4", "assistant", "d"),
            compaction("6", "5", "Second summary", "4"),
            msg("7", "6", "user", "e"),
        ]
        let ctx = buildSessionContext(entries)

        // Should use second summary, keep from 4
        #expect(ctx.messages.count == 4)
        #expect(summaryOf(ctx.messages[0])?.contains("Second summary") == true)
    }

    @Test("buildContextEntries returns compaction-aware entries including custom entries") func contextEntriesWithCustom() {
        let entries = [
            msg("1", nil, "user", "first"),
            custom("2", "1", "old-state", ["hidden": true]),
            msg("3", "2", "assistant", "response1"),
            custom("4", "3", "kept-card", ["title": "Kept"]),
            msg("5", "4", "user", "second"),
            compaction("6", "5", "Summary", "4"),
            custom("7", "6", "after-card", ["title": "After"]),
            msg("8", "7", "assistant", "response2"),
        ]

        #expect(buildContextEntries(entries).map(\.id) == ["6", "4", "5", "7", "8"])
        let ctx = buildSessionContext(entries)
        #expect(ctx.messages.map(\.role) == ["compactionSummary", "user", "assistant"])
    }

    @Test("keeps settings from the full path after compaction") func settingsAfterCompaction() {
        let entries = [
            msg("1", nil, "user", "first"),
            thinkingLevel("2", "1", "high"),
            msg("3", "2", "assistant", "response1"),
            msg("4", "3", "user", "second"),
            compaction("5", "4", "Summary", "4"),
        ]

        let ctx = buildSessionContext(entries)
        #expect(ctx.thinkingLevel == "high")
        #expect(ctx.messages.map(\.role) == ["compactionSummary", "user"])
    }

    // MARK: with branches

    @Test("follows path to specified leaf") func followsPathToLeaf() {
        // Tree:
        //   1 -> 2 -> 3 (branch A)
        //         \-> 4 (branch B)
        let entries = [
            msg("1", nil, "user", "start"),
            msg("2", "1", "assistant", "response"),
            msg("3", "2", "user", "branch A"),
            msg("4", "2", "user", "branch B"),
        ]

        let ctxA = buildSessionContext(entries, "3")
        #expect(ctxA.messages.count == 3)
        #expect(contentString(ctxA.messages[2]) == "branch A")

        let ctxB = buildSessionContext(entries, "4")
        #expect(ctxB.messages.count == 3)
        #expect(contentString(ctxB.messages[2]) == "branch B")
    }

    @Test("includes branch summary in path") func branchSummaryInPath() {
        let entries = [
            msg("1", nil, "user", "start"),
            msg("2", "1", "assistant", "response"),
            msg("3", "2", "user", "abandoned path"),
            branchSummary("4", "2", "Summary of abandoned work", "3"),
            msg("5", "4", "user", "new direction"),
        ]
        let ctx = buildSessionContext(entries, "5")

        #expect(ctx.messages.count == 4)
        #expect(summaryOf(ctx.messages[2])?.contains("Summary of abandoned work") == true)
        #expect(contentString(ctx.messages[3]) == "new direction")
    }

    @Test("complex tree with multiple branches and compaction") func complexTree() {
        // Tree:
        //   1 -> 2 -> 3 -> 4 -> compaction(5) -> 6 -> 7 (main path)
        //              \-> 8 -> 9 (abandoned branch)
        //                    \-> branchSummary(10) -> 11 (resumed from 3)
        let entries = [
            msg("1", nil, "user", "start"),
            msg("2", "1", "assistant", "r1"),
            msg("3", "2", "user", "q2"),
            msg("4", "3", "assistant", "r2"),
            compaction("5", "4", "Compacted history", "3"),
            msg("6", "5", "user", "q3"),
            msg("7", "6", "assistant", "r3"),
            // Abandoned branch from 3
            msg("8", "3", "user", "wrong path"),
            msg("9", "8", "assistant", "wrong response"),
            // Branch summary resuming from 3
            branchSummary("10", "3", "Tried wrong approach", "9"),
            msg("11", "10", "user", "better approach"),
        ]

        // Main path to 7: summary + kept(3,4) + after(6,7)
        let ctxMain = buildSessionContext(entries, "7")
        #expect(ctxMain.messages.count == 5)
        #expect(summaryOf(ctxMain.messages[0])?.contains("Compacted history") == true)
        #expect(contentString(ctxMain.messages[1]) == "q2")
        #expect(firstText(ctxMain.messages[2]) == "r2")
        #expect(contentString(ctxMain.messages[3]) == "q3")
        #expect(firstText(ctxMain.messages[4]) == "r3")

        // Branch path to 11: 1,2,3 + branch_summary + 11
        let ctxBranch = buildSessionContext(entries, "11")
        #expect(ctxBranch.messages.count == 5)
        #expect(contentString(ctxBranch.messages[0]) == "start")
        #expect(firstText(ctxBranch.messages[1]) == "r1")
        #expect(contentString(ctxBranch.messages[2]) == "q2")
        #expect(summaryOf(ctxBranch.messages[3])?.contains("Tried wrong approach") == true)
        #expect(contentString(ctxBranch.messages[4]) == "better approach")
    }

    // MARK: edge cases

    @Test("uses last entry when leafId not found") func leafNotFound() {
        let ctx = buildSessionContext([msg("1", nil, "user", "hello"), msg("2", "1", "assistant", "hi")], "nonexistent")
        #expect(ctx.messages.count == 2)
    }

    @Test("handles orphaned entries gracefully") func orphanedEntries() {
        let entries = [
            msg("1", nil, "user", "hello"),
            msg("2", "missing", "assistant", "orphan"), // parent doesn't exist
        ]
        let ctx = buildSessionContext(entries, "2")
        // Should only get the orphan since parent chain is broken
        #expect(ctx.messages.count == 1)
    }
}
