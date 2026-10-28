import Foundation
import PiAI
import PiAgent
import Testing
@testable import PiCodingAgent

// Port of test/agent-session-auto-compaction-queue.test.ts
//
// Swift: `vi.spyOn(session, "_runAutoCompaction")` becomes `_setRunAutoCompactionOverride` (a recording stub), and
// `vi.spyOn(session.agent, "continue")` is replaced by checking the agent stays idle: `_runAutoCompaction` here
// returns whether the post-run loop should continue instead of calling `agent.continue()` itself.
// No AuthStorage / ModelRegistry (not ported): the agent's `getApiKey` supplies the key.

private let zeroCost = UsageCost(input: 0, output: 0, cacheRead: 0, cacheWrite: 0, total: 0)

private func usage(input: Int, output: Int = 0, totalTokens: Int) -> Usage {
    Usage(input: input, output: output, cacheRead: 0, cacheWrite: 0, totalTokens: totalTokens, cost: zeroCost)
}

private final class Fixture: Sendable {
    let session: AgentSession
    let sessionManager: SessionManager
    let settingsManager: SettingsManager

    init() async throws {
        // Swift: `getModel("anthropic", "claude-sonnet-4-5")` stand-in (the generated model catalog is not ported).
        let model = Model(
            id: "claude-sonnet-4-5", name: "Claude Sonnet 4.5", api: "anthropic-messages", provider: "anthropic",
            baseUrl: "https://api.anthropic.com", reasoning: true, input: ["text", "image"], contextWindow: 200000, maxTokens: 64000
        )
        let agent = try Agent(AgentOptions(
            initialState: AgentInitialState(systemPrompt: "Test", model: model, tools: []),
            convertToLlm: { convertToLlm($0) },
            streamFn: { model, context, options in try streamSimple(model, Context(messages: context.messages), options) },
            getApiKey: { _ in "test-key" }
        ))
        sessionManager = try SessionManager.inMemory()
        settingsManager = SettingsManager.inMemory()
        session = await AgentSession(AgentSessionConfig(
            agent: agent, sessionManager: sessionManager, settingsManager: settingsManager, cwd: NSTemporaryDirectory()
        ))
    }

    /// `vi.spyOn(session, "_runAutoCompaction").mockResolvedValue()`: records calls.
    func spyRunAutoCompaction() -> Collector<String> {
        let calls = Collector<String>()
        session._setRunAutoCompactionOverride { reason, willRetry in
            calls.append("\(reason.rawValue):\(willRetry)")
            return false
        }
        return calls
    }

    func assistant(_ text: String, _ usage: Usage, stopReason: StopReason = .stop, errorMessage: String? = nil, timestamp: Int) async -> AssistantMessage {
        let model = await session.model
        var message = AssistantMessage(
            content: [.text(TextContent(text: text))],
            api: model.api,
            provider: model.provider,
            model: model.id,
            usage: usage,
            stopReason: stopReason,
            timestamp: timestamp
        )
        message.errorMessage = errorMessage
        return message
    }
}

private func userBlocks(_ text: String, _ timestamp: Int) -> AgentMessage {
    .user(UserMessage(content: .blocks([.text(TextContent(text: text))]), timestamp: timestamp))
}

@Suite("AgentSession auto-compaction queue resume") struct AgentSessionAutoCompactionQueueTests {
    @Test("should resume after threshold compaction when only agent-level queued messages exist") func resumesForQueuedMessages() async throws {
        let f = try await Fixture()
        defer { f.session.dispose() }
        f.settingsManager.applyOverrides(Settings(compaction: Settings.CompactionSettings(keepRecentTokens: 1)))
        let now = dateNow()
        try f.sessionManager.appendMessage(userBlocks("message to compact", now - 1000))
        try f.sessionManager.appendMessage(AgentMessage.assistant(
            await f.assistant("assistant response to compact", usage(input: 100, totalTokens: 100), timestamp: now - 500)
        ))
        let contextMessages = f.sessionManager.buildSessionContext().messages
        let summaryCalls = Locked(0)
        await f.session.agent.update { agent in
            agent.state.messages = contextMessages
            agent.streamFunction = { summaryModel, _, _ in
                summaryCalls.withLock { $0 += 1 }
                let stream = createAssistantMessageEventStream()
                var message = fauxAssistantMessage("compacted")
                message.api = summaryModel.api
                message.provider = summaryModel.provider
                message.model = summaryModel.id
                message.usage = usage(input: 10, totalTokens: 10)
                let final = message
                Task { stream.push(.done(reason: .stop, message: final)) }
                return stream
            }
        }

        f.session.agent.followUp(CustomMessage(
            customType: "test", content: .blocks([.text(TextContent(text: "Queued custom"))]), display: false, timestamp: dateNow()
        ).agentMessage)

        #expect(f.session.pendingMessageCount == 0)
        #expect(f.session.agent.hasQueuedMessages() == true)

        #expect(try await f.session._runAutoCompaction(.threshold, false) == true)

        // `continueSpy` not called: only the summary request ran and the agent did not start a run.
        #expect(summaryCalls.withLock { $0 } == 1)
        #expect(f.session.isStreaming == false)
        #expect(f.session.agent.hasQueuedMessages() == true)
    }

    @Test("should not compact repeatedly after overflow recovery already attempted") func noRepeatedOverflowCompaction() async throws {
        let f = try await Fixture()
        defer { f.session.dispose() }
        let overflowMessage = await f.assistant(
            "", usage(input: 0, totalTokens: 0), stopReason: .error, errorMessage: "prompt is too long", timestamp: dateNow()
        )

        let calls = f.spyRunAutoCompaction()

        let events = Collector<String>()
        _ = f.session.subscribe { event in
            if case .compactionEnd(let reason, _, _, _, let errorMessage) = event {
                events.append("compaction_end|\(reason.rawValue)|\(errorMessage ?? "")")
            }
        }

        _ = try await f.session._checkCompaction(overflowMessage)
        var second = overflowMessage
        second.timestamp = dateNow() + 1
        _ = try await f.session._checkCompaction(second)

        #expect(calls.values.count == 1)
        #expect(events.values.contains(
            "compaction_end|overflow|Context overflow recovery failed after one compact-and-retry attempt. Try reducing context or switching to a larger-context model."
        ))
    }

    @Test("should ignore stale pre-compaction assistant usage on pre-prompt compaction checks") func ignoresStaleUsage() async throws {
        let f = try await Fixture()
        defer { f.session.dispose() }
        let staleAssistantTimestamp = dateNow() - 10_000
        let staleAssistant = await f.assistant(
            "large response before compaction", usage(input: 600_000, output: 10_000, totalTokens: 610_000), timestamp: staleAssistantTimestamp
        )

        try f.sessionManager.appendMessage(userBlocks("before compaction", staleAssistantTimestamp - 1000))
        try f.sessionManager.appendMessage(AgentMessage.assistant(staleAssistant))

        let firstKeptEntryId = try #require(f.sessionManager.getEntries().first).id
        _ = try f.sessionManager.appendCompaction("summary", firstKeptEntryId, staleAssistant.usage.totalTokens, nil, false)

        try f.sessionManager.appendMessage(userBlocks("session recovery payload", dateNow()))

        let calls = f.spyRunAutoCompaction()

        _ = try await f.session._checkCompaction(staleAssistant, false)

        #expect(calls.values.isEmpty)
    }

    @Test("should trigger threshold compaction for error messages using last successful usage") func thresholdFromLastSuccessfulUsage() async throws {
        let f = try await Fixture()
        defer { f.session.dispose() }
        let model = await f.session.model

        // A successful assistant message with token usage just over the compaction threshold.
        // Compute this from the selected model so generated catalog context-window changes do not break the test.
        let compactionSettings = try f.settingsManager.getCompactionSettings()
        let thresholdTokens = model.contextWindow - compactionSettings.reserveTokens + 1
        let successfulAssistant = await f.assistant(
            "large successful response", usage(input: thresholdTokens - 10_000, output: 10_000, totalTokens: thresholdTokens), timestamp: dateNow()
        )

        // An error message (e.g. 529 overloaded) with no useful usage data
        let errorAssistant = await f.assistant(
            "", usage(input: 0, totalTokens: 0), stopReason: .error, errorMessage: "529 overloaded", timestamp: dateNow() + 1000
        )

        // Put both messages into agent state so estimateContextTokens can find the successful one
        let messages: [AgentMessage] = [
            userBlocks("hello", dateNow() - 1000),
            .assistant(successfulAssistant),
            userBlocks("another prompt", dateNow() + 500),
            .assistant(errorAssistant),
        ]
        await f.session.agent.update { $0.state.messages = messages }

        let calls = f.spyRunAutoCompaction()

        _ = try await f.session._checkCompaction(errorAssistant)

        #expect(calls.values == ["threshold:false"])
    }

    @Test("should not trigger threshold compaction for error messages when no prior usage exists") func noPriorUsage() async throws {
        let f = try await Fixture()
        defer { f.session.dispose() }

        // An error message with no prior successful assistant in context
        let errorAssistant = await f.assistant(
            "", usage(input: 0, totalTokens: 0), stopReason: .error, errorMessage: "529 overloaded", timestamp: dateNow()
        )

        let messages: [AgentMessage] = [userBlocks("hello", dateNow() - 1000), .assistant(errorAssistant)]
        await f.session.agent.update { $0.state.messages = messages }

        let calls = f.spyRunAutoCompaction()

        _ = try await f.session._checkCompaction(errorAssistant)

        #expect(calls.values.isEmpty)
    }

    @Test("should not trigger threshold compaction for error messages when only kept pre-compaction usage exists") func onlyKeptPreCompactionUsage() async throws {
        let f = try await Fixture()
        defer { f.session.dispose() }
        let preCompactionTimestamp = dateNow() - 10_000

        // A "kept" assistant message from before compaction with high usage
        let keptAssistant = await f.assistant(
            "kept response from before compaction", usage(input: 180_000, output: 10_000, totalTokens: 190_000), timestamp: preCompactionTimestamp
        )

        // Record the kept assistant in the session and create a compaction after it
        try f.sessionManager.appendMessage(userBlocks("before compaction", preCompactionTimestamp - 1000))
        try f.sessionManager.appendMessage(AgentMessage.assistant(keptAssistant))
        let firstKeptEntryId = try #require(f.sessionManager.getEntries().first).id
        _ = try f.sessionManager.appendCompaction("summary", firstKeptEntryId, keptAssistant.usage.totalTokens, nil, false)

        // Post-compaction error message
        let errorAssistant = await f.assistant(
            "", usage(input: 0, totalTokens: 0), stopReason: .error, errorMessage: "529 overloaded", timestamp: dateNow()
        )

        // Agent state has the kept assistant (pre-compaction) and the error (post-compaction)
        let messages: [AgentMessage] = [
            userBlocks("kept user msg", preCompactionTimestamp - 1000),
            .assistant(keptAssistant),
            userBlocks("new prompt", dateNow() - 500),
            .assistant(errorAssistant),
        ]
        await f.session.agent.update { $0.state.messages = messages }

        let calls = f.spyRunAutoCompaction()

        _ = try await f.session._checkCompaction(errorAssistant)

        // Should NOT compact because the only usage data is from a kept pre-compaction message
        #expect(calls.values.isEmpty)
    }
}
