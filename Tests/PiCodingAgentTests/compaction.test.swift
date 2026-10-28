import Foundation
import PiAI
import PiAgent
import Testing
@testable import PiCodingAgent

// Port of test/compaction.test.ts

// ============================================================================
// Test fixtures
// ============================================================================

/// Upstream checkout holding `test/fixtures/large-session.jsonl` (read-only). Swift: SwiftPM test targets warn
/// about undeclared resource files, so the fixture is read from the upstream tree instead of being copied.
let upstreamCodingAgentTestDir: String = {
    let root = ProcessInfo.processInfo.environment["PI_UPSTREAM_DIR"] ?? (NSHomeDirectory() as NSString).appendingPathComponent("work/pi")
    return (root as NSString).appendingPathComponent("packages/coding-agent/test")
}()

private let largeSessionPath = (upstreamCodingAgentTestDir as NSString).appendingPathComponent("fixtures/large-session.jsonl")
private let hasLargeSessionFixture = FileManager.default.fileExists(atPath: largeSessionPath)

private func loadLargeSessionEntries() throws -> [SessionEntry] {
    let content = try String(contentsOfFile: largeSessionPath, encoding: .utf8)
    var entries = parseSessionEntries(content)
    migrateSessionEntries(&entries) // Add id/parentId for v1 fixtures
    return entries.compactMap(\.sessionEntry)
}

func createMockUsage(_ input: Int, _ output: Int, _ cacheRead: Int = 0, _ cacheWrite: Int = 0) -> Usage {
    Usage(
        input: input,
        output: output,
        cacheRead: cacheRead,
        cacheWrite: cacheWrite,
        totalTokens: input + output + cacheRead + cacheWrite,
        cost: UsageCost(input: 0, output: 0, cacheRead: 0, cacheWrite: 0, total: 0)
    )
}

private func createUserMessage(_ text: String) -> AgentMessage {
    .user(UserMessage(content: .string(text), timestamp: dateNow()))
}

private func createAssistantMessage(_ text: String, _ usage: Usage? = nil) -> AssistantMessage {
    AssistantMessage(
        content: [.text(TextContent(text: text))],
        api: "anthropic-messages",
        provider: "anthropic",
        model: "claude-sonnet-4-5",
        usage: usage ?? createMockUsage(100, 50),
        stopReason: .stop,
        timestamp: dateNow()
    )
}

/// Swift: the upstream module-level `entryCounter` / `lastId` (reset in `beforeEach`), one per test.
private final class EntryBuilder {
    var entryCounter = 0
    var lastId: String?

    private func nextId() -> String {
        defer { entryCounter += 1 }
        return "test-id-\(entryCounter)"
    }

    func createMessageEntry(_ message: AgentMessage) -> SessionMessageEntry {
        let id = nextId()
        let entry = SessionMessageEntry(id: id, parentId: lastId, timestamp: toISOString(dateNow()), message: message)
        lastId = id
        return entry
    }

    func createMessageEntry(_ message: AssistantMessage) -> SessionMessageEntry {
        createMessageEntry(.assistant(message))
    }

    func createCompactionEntry(_ summary: String, _ firstKeptEntryId: String) -> SessionEntry {
        let id = nextId()
        let entry = CompactionEntry(
            id: id, parentId: lastId, timestamp: toISOString(dateNow()), summary: summary,
            firstKeptEntryId: firstKeptEntryId, tokensBefore: 10000
        )
        lastId = id
        return .compaction(entry)
    }

    func createModelChangeEntry(_ provider: String, _ modelId: String) -> SessionEntry {
        let id = nextId()
        let entry = ModelChangeEntry(id: id, parentId: lastId, timestamp: toISOString(dateNow()), provider: provider, modelId: modelId)
        lastId = id
        return .modelChange(entry)
    }

    func createThinkingLevelEntry(_ thinkingLevel: String) -> SessionEntry {
        let id = nextId()
        let entry = ThinkingLevelChangeEntry(id: id, parentId: lastId, timestamp: toISOString(dateNow()), thinkingLevel: thinkingLevel)
        lastId = id
        return .thinkingLevelChange(entry)
    }

    func createCustomMessageEntry(_ content: String) -> SessionEntry {
        let id = nextId()
        let entry = CustomMessageEntry(
            id: id, parentId: lastId, timestamp: toISOString(dateNow()), customType: "test", content: .string(content), display: true
        )
        lastId = id
        return .customMessage(entry)
    }
}

private extension SessionMessageEntry {
    var entry: SessionEntry { .message(self) }
}

private func textBlocks(_ blocks: [UserContent]) -> String {
    blocks.compactMap { if case .text(let t) = $0 { return t.text } else { return nil } }.joined(separator: " ")
}

private func extractText(_ messages: [AgentMessage]) -> String {
    messages
        .map { message -> String in
            switch message {
            case .user(let user):
                switch user.content {
                case .string(let text): return text
                case .blocks(let blocks): return textBlocks(blocks)
                }
            case .assistant(let assistant):
                return assistant.content.compactMap { if case .text(let t) = $0 { return t.text } else { return nil } }.joined(separator: " ")
            case .toolResult(let result):
                return textBlocks(result.content)
            case .custom:
                if let summary = summaryOf(message) { return summary }
                if let custom = CustomMessage(message) {
                    switch custom.content {
                    case .string(let text): return text
                    case .blocks(let blocks): return textBlocks(blocks)
                    }
                }
                if let bash = BashExecutionMessage(message) { return "\(bash.command)\n\(bash.output)" }
                return ""
            case .system:
                return ""
            }
        }
        .joined(separator: "\n")
}

// ============================================================================
// Unit tests
// ============================================================================

@Suite("Token calculation") struct TokenCalculationTests {
    @Test("should calculate total context tokens from usage") func total() {
        #expect(calculateContextTokens(createMockUsage(1000, 500, 200, 100)) == 1800)
    }

    @Test("should handle zero values") func zero() {
        #expect(calculateContextTokens(createMockUsage(0, 0, 0, 0)) == 0)
    }
}

@Suite("getLastAssistantUsage") struct GetLastAssistantUsageTests {
    @Test("should find the last non-aborted assistant message usage") func findsLast() throws {
        let b = EntryBuilder()
        let entries: [SessionEntry] = [
            b.createMessageEntry(createUserMessage("Hello")).entry,
            b.createMessageEntry(createAssistantMessage("Hi", createMockUsage(100, 50))).entry,
            b.createMessageEntry(createUserMessage("How are you?")).entry,
            b.createMessageEntry(createAssistantMessage("Good", createMockUsage(200, 100))).entry,
        ]

        let usage = try #require(getLastAssistantUsage(entries))
        #expect(usage.input == 200)
    }

    @Test("should skip aborted messages") func skipsAborted() throws {
        let b = EntryBuilder()
        var abortedMsg = createAssistantMessage("Aborted", createMockUsage(300, 150))
        abortedMsg.stopReason = .aborted

        let entries: [SessionEntry] = [
            b.createMessageEntry(createUserMessage("Hello")).entry,
            b.createMessageEntry(createAssistantMessage("Hi", createMockUsage(100, 50))).entry,
            b.createMessageEntry(createUserMessage("How are you?")).entry,
            b.createMessageEntry(abortedMsg).entry,
        ]

        let usage = try #require(getLastAssistantUsage(entries))
        #expect(usage.input == 100)
    }

    @Test("should skip all-zero assistant usage") func skipsZero() throws {
        let b = EntryBuilder()
        let entries: [SessionEntry] = [
            b.createMessageEntry(createUserMessage("Hello")).entry,
            b.createMessageEntry(createAssistantMessage("Hi", createMockUsage(100, 50))).entry,
            b.createMessageEntry(createUserMessage("continue")).entry,
            b.createMessageEntry(createAssistantMessage("Partial", createMockUsage(0, 0))).entry,
        ]

        let usage = try #require(getLastAssistantUsage(entries))
        #expect(usage.input == 100)
    }

    @Test("should return undefined if no assistant messages") func noAssistant() {
        let b = EntryBuilder()
        #expect(getLastAssistantUsage([b.createMessageEntry(createUserMessage("Hello")).entry]) == nil)
    }
}

@Suite("estimateContextTokens") struct EstimateContextTokensTests {
    @Test("uses the last non-zero assistant usage as the context anchor") func anchor() {
        let messages: [AgentMessage] = [
            createUserMessage("Hello"),
            .assistant(createAssistantMessage("Hi", createMockUsage(100, 50))),
            createUserMessage("continue"),
            .assistant(createAssistantMessage("Partial thinking", createMockUsage(0, 0))),
        ]

        let estimate = estimateContextTokens(messages)

        #expect(estimate.usageTokens == 150)
        #expect(estimate.lastUsageIndex == 1)
        #expect(estimate.trailingTokens > 0)
        #expect(estimate.tokens == 150 + estimate.trailingTokens)
    }
}

@Suite("shouldCompact") struct ShouldCompactTests {
    @Test("should return true when context exceeds threshold") func exceeds() {
        let settings = CompactionSettings(enabled: true, reserveTokens: 10000, keepRecentTokens: 20000)

        #expect(shouldCompact(95000, 100000, settings) == true)
        #expect(shouldCompact(89000, 100000, settings) == false)
    }

    @Test("should return false when disabled") func disabled() {
        let settings = CompactionSettings(enabled: false, reserveTokens: 10000, keepRecentTokens: 20000)

        #expect(shouldCompact(95000, 100000, settings) == false)
    }
}

@Suite("findCutPoint") struct FindCutPointTests {
    @Test("should find cut point based on actual token differences") func tokenDifferences() throws {
        let b = EntryBuilder()
        // Create entries with cumulative token counts
        var entries: [SessionEntry] = []
        for i in 0..<10 {
            entries.append(b.createMessageEntry(createUserMessage("User \(i)")).entry)
            entries.append(b.createMessageEntry(createAssistantMessage("Assistant \(i)", createMockUsage(0, 100, (i + 1) * 1000, 0))).entry)
        }

        // 20 entries, last assistant has 10000 tokens
        // keepRecentTokens = 2500: keep entries where diff < 2500
        let result = findCutPoint(entries, 0, entries.count, 2500)

        // Should cut at a valid cut point (user or assistant message)
        #expect(entries[result.firstKeptEntryIndex].type == "message")
        let role = entries[result.firstKeptEntryIndex].message?.role
        #expect(role == "user" || role == "assistant")
    }

    @Test("should return startIndex if no valid cut points in range") func noValidCutPoints() {
        let b = EntryBuilder()
        let entries = [b.createMessageEntry(createAssistantMessage("a")).entry]
        #expect(findCutPoint(entries, 0, entries.count, 1000).firstKeptEntryIndex == 0)
    }

    @Test("should keep everything if all messages fit within budget") func allFit() {
        let b = EntryBuilder()
        let entries: [SessionEntry] = [
            b.createMessageEntry(createUserMessage("1")).entry,
            b.createMessageEntry(createAssistantMessage("a", createMockUsage(0, 50, 500, 0))).entry,
            b.createMessageEntry(createUserMessage("2")).entry,
            b.createMessageEntry(createAssistantMessage("b", createMockUsage(0, 50, 1000, 0))).entry,
        ]

        #expect(findCutPoint(entries, 0, entries.count, 50000).firstKeptEntryIndex == 0)
    }

    @Test("should indicate split turn when cutting at assistant message") func splitTurn() {
        let b = EntryBuilder()
        // Create a scenario where we cut at an assistant message mid-turn
        let entries: [SessionEntry] = [
            b.createMessageEntry(createUserMessage("Turn 1")).entry,
            b.createMessageEntry(createAssistantMessage("A1", createMockUsage(0, 100, 1000, 0))).entry,
            b.createMessageEntry(createUserMessage("Turn 2")).entry, // index 2
            b.createMessageEntry(createAssistantMessage("A2-1", createMockUsage(0, 100, 5000, 0))).entry, // index 3
            b.createMessageEntry(createAssistantMessage("A2-2", createMockUsage(0, 100, 8000, 0))).entry, // index 4
            b.createMessageEntry(createAssistantMessage("A2-3", createMockUsage(0, 100, 10000, 0))).entry, // index 5
        ]

        // With keepRecentTokens = 3000, should cut somewhere in Turn 2
        let result = findCutPoint(entries, 0, entries.count, 3000)

        // If cut at assistant message (not user), should indicate split turn
        if entries[result.firstKeptEntryIndex].message?.role == "assistant" {
            #expect(result.isSplitTurn == true)
            #expect(result.turnStartIndex == 2) // Turn 2 starts at index 2
        }
    }

    @Test("should budget context-visible custom message entries") func customMessageBudget() {
        let b = EntryBuilder()
        let entries: [SessionEntry] = [
            b.createMessageEntry(createUserMessage("hi")).entry,
            b.createMessageEntry(createAssistantMessage("hello")).entry,
            b.createCustomMessageEntry(String(repeating: "x", count: 4000)),
            b.createMessageEntry(createAssistantMessage("ok")).entry,
        ]

        let tinyBudget = findCutPoint(entries, 0, entries.count, 1)
        #expect(tinyBudget.firstKeptEntryIndex == 3)
        #expect(tinyBudget.isSplitTurn == true)
        #expect(tinyBudget.turnStartIndex == 2)

        let customFitsBudget = findCutPoint(entries, 0, entries.count, 2)
        #expect(customFitsBudget.firstKeptEntryIndex == 2)
        #expect(customFitsBudget.isSplitTurn == false)
        #expect(customFitsBudget.turnStartIndex == -1)
    }

    // Regression test for #9740.
    @Test("should fall back to the latest valid cut point before oversized trailing tool results") func oversizedToolResults() throws {
        let b = EntryBuilder()
        let oldUser = b.createMessageEntry(createUserMessage("old history"))
        let oldAssistant = b.createMessageEntry(createAssistantMessage("old answer"))
        let currentUser = b.createMessageEntry(createUserMessage("read the large file"))
        var toolCallMessage = createAssistantMessage("")
        toolCallMessage.content = [.toolCall(ToolCall(id: "call-1", name: "read", arguments: ["path": "big.txt"]))]
        toolCallMessage.stopReason = .toolUse
        let toolCall = b.createMessageEntry(toolCallMessage)
        let toolResult = b.createMessageEntry(.toolResult(ToolResultMessage(
            toolCallId: "call-1",
            toolName: "read",
            content: [.text(TextContent(text: String(repeating: "x", count: 8000)))],
            isError: false,
            timestamp: dateNow()
        )))
        let entries = [oldUser, oldAssistant, currentUser, toolCall, toolResult].map(\.entry)

        let result = findCutPoint(entries, 0, entries.count, 1000)
        #expect(result == CutPointResult(firstKeptEntryIndex: 3, turnStartIndex: 2, isSplitTurn: true))

        var settings = DEFAULT_COMPACTION_SETTINGS
        settings.keepRecentTokens = 1000
        let preparation = try #require(prepareCompaction(entries, settings))
        #expect(preparation.firstKeptEntryId == toolCall.id)
        #expect(preparation.messagesToSummarize.map(agentMessageToJson) == [oldUser.message, oldAssistant.message].map(agentMessageToJson))
        #expect(preparation.turnPrefixMessages.map(agentMessageToJson) == [currentUser.message].map(agentMessageToJson))
    }
}

@Suite("buildSessionContext (compaction)") struct CompactionBuildSessionContextTests {
    @Test("should load all messages when no compaction") func noCompaction() {
        let b = EntryBuilder()
        let entries: [SessionEntry] = [
            b.createMessageEntry(createUserMessage("1")).entry,
            b.createMessageEntry(createAssistantMessage("a")).entry,
            b.createMessageEntry(createUserMessage("2")).entry,
            b.createMessageEntry(createAssistantMessage("b")).entry,
        ]

        let loaded = buildSessionContext(entries)
        #expect(loaded.messages.count == 4)
        #expect(loaded.thinkingLevel == "off")
        #expect(loaded.model == SessionModelRef(provider: "anthropic", modelId: "claude-sonnet-4-5"))
    }

    @Test("should handle single compaction") func singleCompaction() {
        let b = EntryBuilder()
        // IDs: u1=test-id-0, a1=test-id-1, u2=test-id-2, a2=test-id-3, compaction=test-id-4, u3=test-id-5, a3=test-id-6
        let u1 = b.createMessageEntry(createUserMessage("1"))
        let a1 = b.createMessageEntry(createAssistantMessage("a"))
        let u2 = b.createMessageEntry(createUserMessage("2"))
        let a2 = b.createMessageEntry(createAssistantMessage("b"))
        let compaction = b.createCompactionEntry("Summary of 1,a,2,b", u2.id) // keep from u2 onwards
        let u3 = b.createMessageEntry(createUserMessage("3"))
        let a3 = b.createMessageEntry(createAssistantMessage("c"))

        let entries: [SessionEntry] = [u1.entry, a1.entry, u2.entry, a2.entry, compaction, u3.entry, a3.entry]

        let loaded = buildSessionContext(entries)
        // summary + kept (u2, a2) + after (u3, a3) = 5
        #expect(loaded.messages.count == 5)
        #expect(loaded.messages[0].role == "compactionSummary")
        #expect(summaryOf(loaded.messages[0])?.contains("Summary of 1,a,2,b") == true)
    }

    @Test("should handle multiple compactions (only latest matters)") func multipleCompactions() {
        let b = EntryBuilder()
        // First batch
        let u1 = b.createMessageEntry(createUserMessage("1"))
        let a1 = b.createMessageEntry(createAssistantMessage("a"))
        let compact1 = b.createCompactionEntry("First summary", u1.id)
        // Second batch
        let u2 = b.createMessageEntry(createUserMessage("2"))
        let bMsg = b.createMessageEntry(createAssistantMessage("b"))
        let u3 = b.createMessageEntry(createUserMessage("3"))
        let c = b.createMessageEntry(createAssistantMessage("c"))
        let compact2 = b.createCompactionEntry("Second summary", u3.id) // keep from u3 onwards
        // After second compaction
        let u4 = b.createMessageEntry(createUserMessage("4"))
        let d = b.createMessageEntry(createAssistantMessage("d"))

        let entries: [SessionEntry] = [u1.entry, a1.entry, compact1, u2.entry, bMsg.entry, u3.entry, c.entry, compact2, u4.entry, d.entry]

        let loaded = buildSessionContext(entries)
        // summary + kept from u3 (u3, c) + after (u4, d) = 5
        #expect(loaded.messages.count == 5)
        #expect(summaryOf(loaded.messages[0])?.contains("Second summary") == true)
    }

    @Test("should keep all messages when firstKeptEntryId is first entry") func keepAll() {
        let b = EntryBuilder()
        let u1 = b.createMessageEntry(createUserMessage("1"))
        let a1 = b.createMessageEntry(createAssistantMessage("a"))
        let compact1 = b.createCompactionEntry("First summary", u1.id) // keep from first entry
        let u2 = b.createMessageEntry(createUserMessage("2"))
        let bMsg = b.createMessageEntry(createAssistantMessage("b"))

        let loaded = buildSessionContext([u1.entry, a1.entry, compact1, u2.entry, bMsg.entry])
        // summary + all messages (u1, a1, u2, b) = 5
        #expect(loaded.messages.count == 5)
    }

    @Test("should track model and thinking level changes") func modelAndThinking() {
        let b = EntryBuilder()
        let entries: [SessionEntry] = [
            b.createMessageEntry(createUserMessage("1")).entry,
            b.createModelChangeEntry("openai", "gpt-4"),
            b.createMessageEntry(createAssistantMessage("a")).entry,
            b.createThinkingLevelEntry("high"),
        ]

        let loaded = buildSessionContext(entries)
        // model_change is later overwritten by assistant message's model info
        #expect(loaded.model == SessionModelRef(provider: "anthropic", modelId: "claude-sonnet-4-5"))
        #expect(loaded.thinkingLevel == "high")
    }
}

@Suite("prepareCompaction") struct PrepareCompactionTests {
    @Test("does not treat system messages as conversation history") func systemMessages() throws {
        let b = EntryBuilder()
        let system = b.createMessageEntry(.system(SystemMessage(content: "", sections: [(name: "preamble", text: "current prompt")], timestamp: dateNow())))
        let user = b.createMessageEntry(createUserMessage("one long turn"))
        let assistant = b.createMessageEntry(createAssistantMessage("assistant suffix"))
        var settings = DEFAULT_COMPACTION_SETTINGS
        settings.keepRecentTokens = 1
        let preparation = try #require(prepareCompaction([system.entry, user.entry, assistant.entry], settings))

        #expect(preparation.firstKeptEntryId == assistant.id)
        #expect(preparation.isSplitTurn == true)
        #expect(preparation.messagesToSummarize.isEmpty)
        #expect(preparation.turnPrefixMessages.map(agentMessageToJson) == [agentMessageToJson(user.message)])
    }
}

@Suite("prepareCompaction with previous compaction") struct PrepareCompactionPreviousTests {
    @Test("should skip repeated compactions when kept messages still fit") func skipsRepeated() {
        let b = EntryBuilder()
        let u1 = b.createMessageEntry(createUserMessage("user msg 1 (summarized by compaction1)"))
        let a1 = b.createMessageEntry(createAssistantMessage("assistant msg 1"))
        let u2 = b.createMessageEntry(createUserMessage("user msg 2 - kept by compaction1"))
        let a2 = b.createMessageEntry(createAssistantMessage("assistant msg 2"))
        let u3 = b.createMessageEntry(createUserMessage("user msg 3 - kept by compaction1"))
        let a3 = b.createMessageEntry(createAssistantMessage("assistant msg 3", createMockUsage(5000, 1000)))
        let compaction1 = b.createCompactionEntry("First summary", u2.id)
        let u4 = b.createMessageEntry(createUserMessage("user msg 4 (new after compaction1)"))
        let a4 = b.createMessageEntry(createAssistantMessage("assistant msg 4", createMockUsage(8000, 2000)))

        let pathEntries = [u1.entry, a1.entry, u2.entry, a2.entry, u3.entry, a3.entry, compaction1, u4.entry, a4.entry]
        #expect(prepareCompaction(pathEntries, DEFAULT_COMPACTION_SETTINGS) == nil)
    }

    @Test("should re-summarize previously kept messages when the recent window moves past them") func resummarizes() throws {
        let b = EntryBuilder()
        func rep(_ s: String, _ n: Int) -> String { String(repeating: s, count: n) }
        let u1 = b.createMessageEntry(createUserMessage(rep("user msg 1 (summarized by compaction1)", 4)))
        let a1 = b.createMessageEntry(createAssistantMessage(rep("assistant msg 1", 4)))
        let u2 = b.createMessageEntry(createUserMessage(rep("user msg 2 - kept by compaction1 ", 12)))
        let a2 = b.createMessageEntry(createAssistantMessage(rep("assistant msg 2 ", 12)))
        let u3 = b.createMessageEntry(createUserMessage(rep("user msg 3 - kept by compaction1 ", 12)))
        let a3 = b.createMessageEntry(createAssistantMessage(rep("assistant msg 3 ", 12), createMockUsage(5000, 1000)))
        let compaction1 = b.createCompactionEntry("First summary", u2.id)
        let u4 = b.createMessageEntry(createUserMessage(rep("user msg 4 (new after compaction1) ", 12)))
        let a4 = b.createMessageEntry(createAssistantMessage(rep("assistant msg 4 ", 12), createMockUsage(8000, 2000)))

        var settings = DEFAULT_COMPACTION_SETTINGS
        settings.keepRecentTokens = 100
        let preparation = try #require(prepareCompaction(
            [u1.entry, a1.entry, u2.entry, a2.entry, u3.entry, a3.entry, compaction1, u4.entry, a4.entry], settings
        ))

        let summarizedText = extractText(preparation.messagesToSummarize)
        #expect(summarizedText.contains("user msg 2 - kept by compaction1"))
        #expect(summarizedText.contains("user msg 3 - kept by compaction1"))
        #expect(!summarizedText.contains("First summary"))
        #expect(preparation.previousSummary == "First summary")
    }
}

// ============================================================================
// Integration tests with real session data
// ============================================================================

@Suite("Large session fixture", .enabled(if: hasLargeSessionFixture)) struct LargeSessionFixtureTests {
    @Test("should parse the large session") func parses() throws {
        let entries = try loadLargeSessionEntries()
        #expect(entries.count > 100)
        #expect(entries.filter { $0.type == "message" }.count > 100)
    }

    @Test("should find cut point in large session") func cutPoint() throws {
        let entries = try loadLargeSessionEntries()
        let result = findCutPoint(entries, 0, entries.count, DEFAULT_COMPACTION_SETTINGS.keepRecentTokens)

        // Cut point should be at a message entry (user or assistant)
        #expect(entries[result.firstKeptEntryIndex].type == "message")
        let role = entries[result.firstKeptEntryIndex].message?.role
        #expect(role == "user" || role == "assistant")
    }

    @Test("should load session correctly") func loads() throws {
        let entries = try loadLargeSessionEntries()
        let loaded = buildSessionContext(entries)

        #expect(loaded.messages.count > 100)
        #expect(loaded.model != nil)
    }
}

// Not ported: "LLM summarization" (requires ANTHROPIC_OAUTH_TOKEN and network access).
