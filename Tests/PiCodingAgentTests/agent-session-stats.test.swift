import Foundation
import PiAI
import PiAgent
import Testing
@testable import PiCodingAgent

// Port of test/agent-session-stats.test.ts
// Swift: no AuthStorage / ModelRegistry (not ported); the agent's `getApiKey` supplies the key.

// Swift: `getModel("anthropic", "claude-sonnet-4-5")` stand-in (the generated model catalog is not ported).
private let model = Model(
    id: "claude-sonnet-4-5", name: "Claude Sonnet 4.5", api: "anthropic-messages", provider: "anthropic",
    baseUrl: "https://api.anthropic.com", reasoning: true, input: ["text", "image"], contextWindow: 200000, maxTokens: 64000
)

private func createUsage(_ totalTokens: Int, costTotal: Double = 0) -> Usage {
    Usage(
        input: totalTokens, output: 0, cacheRead: 0, cacheWrite: 0, totalTokens: totalTokens,
        cost: UsageCost(input: 0, output: 0, cacheRead: 0, cacheWrite: 0, total: costTotal)
    )
}

private func createAssistantMessage(_ text: String, _ totalTokens: Int, _ timestamp: Int) -> AgentMessage {
    .assistant(AssistantMessage(
        content: [.text(TextContent(text: text))],
        api: model.api,
        provider: model.provider,
        model: model.id,
        usage: createUsage(totalTokens),
        stopReason: .stop,
        timestamp: timestamp
    ))
}

private func createUserMessage(_ text: String, _ timestamp: Int) -> AgentMessage {
    .user(UserMessage(content: .string(text), timestamp: timestamp))
}

private func createToolResultMessage(_ usage: Usage) -> AgentMessage {
    .toolResult(ToolResultMessage(
        toolCallId: "tool-call-1",
        toolName: "test_tool",
        content: [.text(TextContent(text: "tool result"))],
        usage: usage,
        isError: false,
        timestamp: 1
    ))
}

private func createSession() async throws -> (session: AgentSession, sessionManager: SessionManager) {
    let settingsManager = SettingsManager.inMemory()
    let sessionManager = try SessionManager.inMemory()
    let session = await AgentSession(AgentSessionConfig(
        agent: try Agent(AgentOptions(
            initialState: AgentInitialState(systemPrompt: "You are a helpful assistant.", model: model, thinkingLevel: .high, tools: []),
            convertToLlm: { convertToLlm($0) },
            streamFn: { model, context, options in try streamSimple(model, Context(messages: context.messages), options) },
            getApiKey: { _ in "test-key" }
        )),
        sessionManager: sessionManager,
        settingsManager: settingsManager,
        cwd: FileManager.default.currentDirectoryPath
    ))
    return (session, sessionManager)
}

private func syncAgentMessages(_ session: AgentSession, _ sessionManager: SessionManager) async {
    let messages = sessionManager.buildSessionContext().messages
    await session.agent.update { $0.state.messages = messages }
}

@Suite("AgentSession.getSessionStats") struct AgentSessionStatsTests {
    @Test("exposes the current context usage alongside token totals") func contextUsage() async throws {
        let (session, sessionManager) = try await createSession()
        defer { session.dispose() }

        try sessionManager.appendMessage(createUserMessage("hello", 1))
        try sessionManager.appendMessage(createAssistantMessage("hi", 200, 2))
        await syncAgentMessages(session, sessionManager)

        let stats = await session.getSessionStats()
        #expect(stats.contextUsage == (await session.getContextUsage()))
        #expect(stats.contextUsage?.tokens == 200)
        #expect(stats.contextUsage?.contextWindow == model.contextWindow)
        #expect(stats.contextUsage?.percent == (200 / Double(model.contextWindow)) * 100)
    }

    @Test("reports unknown current context usage immediately after compaction") func unknownAfterCompaction() async throws {
        let (session, sessionManager) = try await createSession()
        defer { session.dispose() }

        try sessionManager.appendMessage(createUserMessage("first", 1))
        try sessionManager.appendMessage(createAssistantMessage("response1", 180_000, 2))
        let keptUserId = try sessionManager.appendMessage(createUserMessage("second", 3))
        try sessionManager.appendMessage(createAssistantMessage("response2", 195_000, 4))
        _ = try sessionManager.appendCompaction("summary", keptUserId, 195_000)
        try sessionManager.appendMessage(createUserMessage("third", 5))
        await syncAgentMessages(session, sessionManager)

        let stats = await session.getSessionStats()
        // Totals cover ALL entries, including history compacted away (180k + 195k).
        #expect(stats.tokens.input == 375_000)
        #expect(stats.contextUsage != nil)
        #expect(stats.contextUsage?.tokens == nil)
        #expect(stats.contextUsage?.percent == nil)
    }

    @Test("uses post-compaction usage for current context instead of stale kept usage") func postCompactionUsage() async throws {
        let (session, sessionManager) = try await createSession()
        defer { session.dispose() }

        try sessionManager.appendMessage(createUserMessage("first", 1))
        try sessionManager.appendMessage(createAssistantMessage("response1", 180_000, 2))
        let keptUserId = try sessionManager.appendMessage(createUserMessage("second", 3))
        try sessionManager.appendMessage(createAssistantMessage("response2", 195_000, 4))
        _ = try sessionManager.appendCompaction("summary", keptUserId, 195_000)
        try sessionManager.appendMessage(createUserMessage("third", 5))
        try sessionManager.appendMessage(createAssistantMessage("response3", 25_000, 6))
        await syncAgentMessages(session, sessionManager)

        let stats = await session.getSessionStats()
        // Totals cover ALL entries, including history compacted away (180k + 195k + 25k).
        #expect(stats.tokens.input == 400_000)
        #expect(stats.contextUsage != nil)
        #expect(stats.contextUsage?.tokens == 25_000)
        #expect(stats.contextUsage?.percent == (25_000 / Double(model.contextWindow)) * 100)
    }

    @Test("includes branch summary usage in session totals") func branchSummaryUsage() async throws {
        let (session, sessionManager) = try await createSession()
        defer { session.dispose() }

        _ = try sessionManager.branchWithSummary(nil, "summary", nil, false, sampleUsage)
        await syncAgentMessages(session, sessionManager)

        let stats = await session.getSessionStats()
        #expect(stats.tokens == SessionStats.Tokens(input: 10, output: 20, cacheRead: 30, cacheWrite: 40, total: 100))
        #expect(stats.cost == 1)
    }

    @Test("includes compaction usage in session totals") func compactionUsage() async throws {
        let (session, sessionManager) = try await createSession()
        defer { session.dispose() }

        let firstKeptEntryId = try sessionManager.appendMessage(createUserMessage("hello", 1))
        _ = try sessionManager.appendCompaction("summary", firstKeptEntryId, 100, nil, false, sampleUsage)
        await syncAgentMessages(session, sessionManager)

        let stats = await session.getSessionStats()
        #expect(stats.tokens == SessionStats.Tokens(input: 10, output: 20, cacheRead: 30, cacheWrite: 40, total: 100))
        #expect(stats.cost == 1)
    }

    @Test("includes cache-warming usage exactly once without adding messages") func cacheWarmingUsage() async throws {
        let (session, sessionManager) = try await createSession()
        defer { session.dispose() }

        _ = try sessionManager.appendUsage(
            "cache_warm",
            "anthropic",
            model.id,
            Usage(
                input: 2, output: 1, cacheRead: 97, cacheWrite: 0, totalTokens: 100,
                cost: UsageCost(input: 0.001, output: 0.002, cacheRead: 0.007, cacheWrite: 0, total: 0.01)
            ),
            "extension override"
        )

        let entry = try #require(sessionManager.getEntries().first)
        #expect(entry.type == "usage")
        guard case .usage(let usageEntry) = entry else { Issue.record("expected usage entry"); return }
        #expect(usageEntry.kind == "cache_warm")
        #expect(usageEntry.note == "extension override")
        let stats = await session.getSessionStats()
        #expect(stats.tokens == SessionStats.Tokens(input: 2, output: 1, cacheRead: 97, cacheWrite: 0, total: 100))
        #expect(stats.totalMessages == 0)
        #expect(sessionManager.buildSessionContext().messages.isEmpty)
        #expect(getUsageCostBreakdown(sessionManager.getEntries()) == [
            UsageCostBreakdownEntry(key: "anthropic/\(model.id)", cost: 0.01, tokens: 100),
        ])
    }

    @Test("includes tool result usage in session totals") func toolResultUsage() async throws {
        let (session, sessionManager) = try await createSession()
        defer { session.dispose() }

        try sessionManager.appendMessage(createToolResultMessage(sampleUsage))
        await syncAgentMessages(session, sessionManager)

        let stats = await session.getSessionStats()
        #expect(stats.tokens == SessionStats.Tokens(input: 10, output: 20, cacheRead: 30, cacheWrite: 40, total: 100))
        #expect(stats.cost == 1)
    }

    @Test("groups tool and summary usage separately from model-attributed usage") func groupsUsage() throws {
        let sessionManager = try SessionManager.inMemory()
        let rootId = try sessionManager.appendMessage(createUserMessage("hello", 1))
        var assistant = createAssistantMessage("response", 100, 2)
        if case .assistant(var message) = assistant {
            message.usage = createUsage(100, costTotal: 0.5)
            assistant = .assistant(message)
        }
        try sessionManager.appendMessage(assistant)
        try sessionManager.appendMessage(createToolResultMessage(createUsage(100, costTotal: 1)))
        _ = try sessionManager.appendCompaction("summary", rootId, 100, nil, false, createUsage(100, costTotal: 2))
        _ = try sessionManager.branchWithSummary(nil, "branch summary", nil, false, createUsage(100, costTotal: 3))

        #expect(getUsageCostBreakdown(sessionManager.getEntries()) == [
            UsageCostBreakdownEntry(key: "Tools/summaries", cost: 6, tokens: 300),
            UsageCostBreakdownEntry(key: "\(model.provider)/\(model.id)", cost: 0.5, tokens: 100),
        ])
    }

    @Test("ignores zero-usage messages when checking for post-compaction context usage") func ignoresZeroUsage() async throws {
        let (session, sessionManager) = try await createSession()
        defer { session.dispose() }

        try sessionManager.appendMessage(createUserMessage("first", 1))
        try sessionManager.appendMessage(createAssistantMessage("response1", 180_000, 2))
        let keptUserId = try sessionManager.appendMessage(createUserMessage("second", 3))
        try sessionManager.appendMessage(createAssistantMessage("response2", 195_000, 4))
        _ = try sessionManager.appendCompaction("summary", keptUserId, 195_000)
        try sessionManager.appendMessage(createUserMessage("third", 5))
        try sessionManager.appendMessage(createAssistantMessage("response3", 25_000, 6))
        try sessionManager.appendMessage(createUserMessage("continue", 7))
        try sessionManager.appendMessage(createAssistantMessage("partial", 0, 8))
        await syncAgentMessages(session, sessionManager)

        let stats = await session.getSessionStats()
        #expect(stats.contextUsage != nil)
        #expect(stats.contextUsage?.tokens != nil)
        #expect((stats.contextUsage?.tokens ?? 0) > 25_000)
    }
}
