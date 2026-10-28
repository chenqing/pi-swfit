import Foundation
import PiAI
import PiAgent
import Testing
@testable import PiCodingAgent

// Port of test/suite/agent-session-compaction.test.ts (subset)
//
// Swift: `vi.spyOn(session, "_runAutoCompaction")` becomes `_setRunAutoCompactionOverride`. The harness agent always
// supplies "faux-key", so the "registry auth is absent" cases run with the custom streamFn only.
// The abort tests block in the summary request until the compaction signal aborts, instead of in an extension's
// `session_before_compact` handler.
// Not ported (extensions, model runtime, coding tools, or an optional model):
// "manually compacts using an extension-provided summary", "checkpoints the replayed system state and folds summarized
// and retained system patches into it", "allows a queued prompt to start when manual compaction ends", "throws when
// compacting without a model", "throws when compacting without configured auth", "manually compacts with
// provider-resolved bearer auth", "notifies extensions when auto-compaction fails", "compacts and resumes after a
// length stop below the desired output limit" (and its describe block), "includes steering queued during compaction in
// the resumed assistant request", "does not compact after a terminating tool result", "stops after one compact-and-retry
// when a second response is also truncated", "resumes after threshold compaction when only agent-level queued messages
// exist", "compacts successful overflow responses without retrying".

private func createUsage(_ totalTokens: Int) -> Usage {
    Usage(
        input: totalTokens, output: 0, cacheRead: 0, cacheWrite: 0, totalTokens: totalTokens,
        cost: UsageCost(input: 0, output: 0, cacheRead: 0, cacheWrite: 0, total: 0)
    )
}

private func createAssistant(
    _ harness: Harness,
    stopReason: StopReason? = nil,
    errorMessage: String? = nil,
    totalTokens: Int = 0,
    timestamp: Int? = nil
) -> AssistantMessage {
    let model = harness.getModel()
    var message = fauxAssistantMessage("", stopReason: stopReason, errorMessage: errorMessage, timestamp: timestamp)
    message.api = model.api
    message.provider = model.provider
    message.model = model.id
    message.usage = createUsage(totalTokens)
    return message
}

private struct SummaryRequest: Sendable {
    var context: TranscriptContext
    var options: SimpleStreamOptions?
}

/// Returns the summary request count.
private func useSummaryStreamFn(_ harness: Harness, _ summary: String, _ requests: Collector<SummaryRequest>? = nil) async -> @Sendable () -> Int {
    let callCount = Locked(0)
    await harness.session.agent.update { agent in
        agent.streamFunction = { model, context, options in
            callCount.withLock { $0 += 1 }
            requests?.append(SummaryRequest(context: context, options: options))
            let stream = createAssistantMessageEventStream()
            var message = fauxAssistantMessage(summary)
            message.api = model.api
            message.provider = model.provider
            message.model = model.id
            message.usage = createUsage(10)
            let final = message
            Task { stream.push(.done(reason: .stop, message: final)) }
            return stream
        }
    }
    return { callCount.withLock { $0 } }
}

private func seedCompactableSession(_ harness: Harness) async throws {
    harness.settingsManager.applyOverrides(Settings(compaction: Settings.CompactionSettings(keepRecentTokens: 1)))
    let now = dateNow()
    try harness.sessionManager.appendMessage(AgentMessage.user(UserMessage(
        content: .blocks([.text(TextContent(text: "message to compact"))]), timestamp: now - 1000
    )))
    var assistant = createAssistant(harness, stopReason: .stop, totalTokens: 100, timestamp: now - 500)
    assistant.content = [.text(TextContent(text: "assistant response to compact"))]
    try harness.sessionManager.appendMessage(AgentMessage.assistant(assistant))
    let messages = harness.sessionManager.buildSessionContext().messages
    await harness.session.agent.update { $0.state.messages = messages }
}

/// Swift: the summary request waits for the compaction signal to abort (upstream blocks in `session_before_compact`).
private func createAbortableCompactionHarness() async throws -> (harness: Harness, compactionStarted: Locked<Bool>) {
    let harness = try await createHarness(HarnessOptions(settings: Settings(compaction: Settings.CompactionSettings(keepRecentTokens: 1))))
    try await seedCompactableSession(harness)
    let compactionStarted = Locked(false)
    let promptStream = await harness.session.agent.streamFunction
    await harness.session.agent.update { agent in
        agent.streamFunction = { model, context, options in
            // Summary requests carry the summarization system prompt; prompts go to the faux provider.
            guard getCurrentSystemPrompt(context.messages) == SUMMARIZATION_SYSTEM_PROMPT, let signal = options?.signal else {
                return try await promptStream(model, context, options)
            }
            let stream = createAssistantMessageEventStream()
            signal.addEventListener {
                var message = fauxAssistantMessage("", stopReason: .aborted)
                message.api = model.api
                message.provider = model.provider
                message.model = model.id
                stream.push(.error(reason: .aborted, error: message))
            }
            compactionStarted.withLock { $0 = true }
            return stream
        }
    }
    return (harness, compactionStarted)
}

private func spyRunAutoCompaction(_ harness: Harness) -> Collector<String> {
    let calls = Collector<String>()
    harness.session._setRunAutoCompactionOverride { reason, willRetry in
        calls.append("\(reason.rawValue):\(willRetry)")
        return false
    }
    return calls
}

private func compactionErrors(_ harness: Harness) -> [String] {
    harness.eventsOfType("compaction_end").compactMap { event -> String? in
        if case .compactionEnd(_, _, _, _, let errorMessage) = event { return errorMessage }
        return nil
    }
}

private func userBlocks(_ text: String, _ timestamp: Int) -> AgentMessage {
    .user(UserMessage(content: .blocks([.text(TextContent(text: text))]), timestamp: timestamp))
}

@Suite("AgentSession compaction characterization") struct AgentSessionCompactionCharacterizationTests {
    @Test("manually compacts with a custom streamFn when registry auth is absent") func manualCustomStreamFn() async throws {
        let harness = try await createHarness()
        defer { harness.cleanup() }
        try await seedCompactableSession(harness)
        let getStreamCallCount = await useSummaryStreamFn(harness, "summary from custom stream")

        let result = try await harness.session.compact()

        #expect(result.summary.contains("summary from custom stream"))
        #expect(getStreamCallCount() == 1)
    }

    @Test("uses the standalone compaction request context") func standaloneRequestContext() async throws {
        let harness = try await createHarness(HarnessOptions(settings: Settings(compaction: Settings.CompactionSettings(keepRecentTokens: 1))))
        defer { harness.cleanup() }
        try await seedCompactableSession(harness)

        let transformContextCalls = Locked(0)
        await harness.session.agent.update { agent in
            agent.transformContext = { messages, _ in
                transformContextCalls.withLock { $0 += 1 }
                return messages
            }
            agent.sessionId = "active-routing-session"
            agent.transport = "websocket"
        }

        let requests = Collector<SummaryRequest>()
        _ = await useSummaryStreamFn(harness, "standalone summary", requests)

        try await harness.session.compact()

        let request = try #require(requests.values.first)
        #expect(transformContextCalls.withLock { $0 } == 0)
        #expect(getCurrentSystemPrompt(request.context.messages) != (await harness.session.agent.state.systemPrompt))
        #expect(getCurrentTools(request.context.messages).isEmpty)
        // Regression test for #9652: split-turn summaries use a clear Markdown conversation boundary.
        #expect(JsonValue.array(request.context.messages.map(\.json)).serialized().contains("# Conversation\\n[User]: message to compact"))
        #expect(request.options?.cacheRetention == CacheRetention.none)
        #expect(request.options?.sessionId != "active-routing-session")
        #expect(request.options?.transport == nil)
    }

    @Test("persists usage from pi-generated manual compaction") func persistsUsage() async throws {
        let harness = try await createHarness()
        defer { harness.cleanup() }
        try await seedCompactableSession(harness)
        _ = await useSummaryStreamFn(harness, "summary from custom stream")

        let result = try await harness.session.compact()

        let compactionEntries = harness.sessionManager.getEntries().compactMap(\.compactionEntry)
        #expect(result.usage == createUsage(10))
        #expect(compactionEntries.count == 1)
        #expect(compactionEntries.first?.usage == createUsage(10))
    }

    @Test("auto-compacts with a custom streamFn when registry auth is absent") func autoCustomStreamFn() async throws {
        let harness = try await createHarness()
        defer { harness.cleanup() }
        try await seedCompactableSession(harness)
        let getStreamCallCount = await useSummaryStreamFn(harness, "auto summary from custom stream")

        _ = try await harness.session._runAutoCompaction(.threshold, false)

        let compactionEntries = harness.sessionManager.getEntries().filter { $0.type == "compaction" }
        guard case .compactionEnd(_, let result, _, _, _)? = harness.eventsOfType("compaction_end").last else {
            Issue.record("missing compaction_end")
            return
        }
        #expect(compactionEntries.count == 1)
        #expect((result?.estimatedTokensAfter ?? 0) > 0)
        #expect(getStreamCallCount() == 1)
    }

    @Test("does not compact when a length stop reaches the desired output limit") func lengthStopAtLimit() async throws {
        let harness = try await createHarness(HarnessOptions(models: [FauxModelDefinition(id: "faux-1", contextWindow: 1_000_000, maxTokens: 100)]))
        defer { harness.cleanup() }
        harness.setResponses([.message(fauxAssistantMessage(String(repeating: "x", count: 400), stopReason: .length))])

        try await harness.session.prompt("hello")

        #expect(harness.faux.state.callCount == 1)
        #expect(harness.eventsOfType("compaction_start").isEmpty)
    }

    @Test("keeps overflow wording when a repeated length stop fills the context window") func repeatedLengthOverflowWording() async throws {
        let harness = try await createHarness(HarnessOptions(models: [FauxModelDefinition(id: "faux-1", contextWindow: 100, maxTokens: 100)]))
        defer { harness.cleanup() }
        let lengthOverflowMessage = createAssistant(harness, stopReason: .length, totalTokens: 100, timestamp: dateNow())
        let calls = spyRunAutoCompaction(harness)

        _ = try await harness.session._checkCompaction(lengthOverflowMessage)
        var second = lengthOverflowMessage
        second.timestamp = dateNow() + 1
        _ = try await harness.session._checkCompaction(second)

        #expect(calls.values.count == 1)
        #expect(compactionErrors(harness).contains(
            "Context overflow recovery failed after one compact-and-retry attempt. Try reducing context or switching to a larger-context model."
        ))
    }

    @Test("cancels in-progress manual compaction when abortCompaction is called") func abortCompaction() async throws {
        let (harness, compactionStarted) = try await createAbortableCompactionHarness()
        defer { harness.cleanup() }

        let session = harness.session
        let compactTask = Task { try await session.compact() }
        #expect(await waitUntil { compactionStarted.withLock { $0 } })
        session.abortCompaction()

        let message = await thrownMessage { _ = try await compactTask.value }
        #expect(message == "Compaction cancelled")
    }

    // Regression test for #8920.
    @Test("aborts an in-progress manual compaction and waits until the session is idle") func abortWaitsForIdle() async throws {
        let (harness, compactionStarted) = try await createAbortableCompactionHarness()
        defer { harness.cleanup() }
        harness.setResponses([.message(fauxAssistantMessage("continued"))])

        let session = harness.session
        let compactTask = Task { try await session.compact() }
        #expect(await waitUntil { compactionStarted.withLock { $0 } })
        await session.abort()
        let message = await thrownMessage { _ = try await compactTask.value }
        #expect(message == "Compaction cancelled")

        guard case .compactionEnd(let reason, _, let aborted, _, _)? = harness.eventsOfType("compaction_end").last else {
            Issue.record("missing compaction_end")
            return
        }
        #expect(reason == .manual)
        #expect(aborted == true)
        #expect(session.isCompacting == false)
        #expect(session.isIdle == true)

        try await session.prompt("next prompt")
        #expect(await session.getLastAssistantText() == "continued")
    }

    @Test("does not retry overflow recovery more than once") func overflowRecoveryOnce() async throws {
        let harness = try await createHarness()
        defer { harness.cleanup() }
        let overflowMessage = createAssistant(harness, stopReason: .error, errorMessage: "prompt is too long", timestamp: dateNow())
        let calls = spyRunAutoCompaction(harness)

        _ = try await harness.session._checkCompaction(overflowMessage)
        var second = overflowMessage
        second.timestamp = dateNow() + 1
        _ = try await harness.session._checkCompaction(second)

        #expect(calls.values.count == 1)
        #expect(compactionErrors(harness).contains(
            "Context overflow recovery failed after one compact-and-retry attempt. Try reducing context or switching to a larger-context model."
        ))
    }

    @Test("ignores stale pre-compaction assistant usage on pre-prompt checks") func staleUsage() async throws {
        let harness = try await createHarness()
        defer { harness.cleanup() }
        let staleTimestamp = dateNow() - 10_000
        let staleAssistant = createAssistant(harness, stopReason: .stop, totalTokens: 610_000, timestamp: staleTimestamp)
        try harness.sessionManager.appendMessage(userBlocks("before compaction", staleTimestamp - 1000))
        try harness.sessionManager.appendMessage(AgentMessage.assistant(staleAssistant))
        let firstKeptEntryId = try #require(harness.sessionManager.getEntries().first).id
        _ = try harness.sessionManager.appendCompaction("summary", firstKeptEntryId, staleAssistant.usage.totalTokens, nil, false)
        try harness.sessionManager.appendMessage(userBlocks("after compaction", dateNow()))
        let calls = spyRunAutoCompaction(harness)

        _ = try await harness.session._checkCompaction(staleAssistant, false)

        #expect(calls.values.isEmpty)
    }

    @Test("triggers threshold compaction for error messages using the last successful usage") func thresholdFromLastUsage() async throws {
        let harness = try await createHarness()
        defer { harness.cleanup() }
        let successfulAssistant = createAssistant(harness, stopReason: .stop, totalTokens: 190_000, timestamp: dateNow())
        let errorAssistant = createAssistant(harness, stopReason: .error, errorMessage: "529 overloaded", timestamp: dateNow() + 1000)
        let messages: [AgentMessage] = [
            userBlocks("hello", dateNow() - 1000),
            .assistant(successfulAssistant),
            userBlocks("retry", dateNow() + 500),
            .assistant(errorAssistant),
        ]
        await harness.session.agent.update { $0.state.messages = messages }
        let calls = spyRunAutoCompaction(harness)

        _ = try await harness.session._checkCompaction(errorAssistant)

        #expect(calls.values == ["threshold:false"])
    }

    @Test("does not trigger threshold compaction for error messages when no prior usage exists") func noPriorUsage() async throws {
        let harness = try await createHarness()
        defer { harness.cleanup() }
        let errorAssistant = createAssistant(harness, stopReason: .error, errorMessage: "529 overloaded", timestamp: dateNow())
        let messages: [AgentMessage] = [userBlocks("hello", dateNow() - 1000), .assistant(errorAssistant)]
        await harness.session.agent.update { $0.state.messages = messages }
        let calls = spyRunAutoCompaction(harness)

        _ = try await harness.session._checkCompaction(errorAssistant)

        #expect(calls.values.isEmpty)
    }

    @Test("does not trigger threshold compaction when only kept pre-compaction usage exists") func onlyKeptUsage() async throws {
        let harness = try await createHarness()
        defer { harness.cleanup() }
        let preCompactionTimestamp = dateNow() - 10_000
        let keptAssistant = createAssistant(harness, stopReason: .stop, totalTokens: 190_000, timestamp: preCompactionTimestamp)
        try harness.sessionManager.appendMessage(userBlocks("before compaction", preCompactionTimestamp - 1000))
        try harness.sessionManager.appendMessage(AgentMessage.assistant(keptAssistant))
        let firstKeptEntryId = try #require(harness.sessionManager.getEntries().first).id
        _ = try harness.sessionManager.appendCompaction("summary", firstKeptEntryId, keptAssistant.usage.totalTokens, nil, false)
        let errorAssistant = createAssistant(harness, stopReason: .error, errorMessage: "529 overloaded", timestamp: dateNow())
        let messages: [AgentMessage] = [
            userBlocks("kept user", preCompactionTimestamp - 1000),
            .assistant(keptAssistant),
            userBlocks("new prompt", dateNow() - 500),
            .assistant(errorAssistant),
        ]
        await harness.session.agent.update { $0.state.messages = messages }
        let calls = spyRunAutoCompaction(harness)

        _ = try await harness.session._checkCompaction(errorAssistant)

        #expect(calls.values.isEmpty)
    }

    @Test("does not trigger threshold compaction below the threshold or when disabled") func belowThresholdOrDisabled() async throws {
        let belowThresholdHarness = try await createHarness(HarnessOptions(
            models: [FauxModelDefinition(id: "faux-1", contextWindow: 200_000)],
            settings: Settings(compaction: Settings.CompactionSettings(enabled: true, reserveTokens: 1000))
        ))
        defer { belowThresholdHarness.cleanup() }
        let disabledHarness = try await createHarness(HarnessOptions(settings: Settings(compaction: Settings.CompactionSettings(enabled: false))))
        defer { disabledHarness.cleanup() }
        let belowThresholdSpy = spyRunAutoCompaction(belowThresholdHarness)
        let disabledSpy = spyRunAutoCompaction(disabledHarness)

        _ = try await belowThresholdHarness.session._checkCompaction(
            createAssistant(belowThresholdHarness, stopReason: .stop, totalTokens: 1_000, timestamp: dateNow())
        )
        _ = try await disabledHarness.session._checkCompaction(
            createAssistant(disabledHarness, stopReason: .stop, totalTokens: 1_000_000, timestamp: dateNow())
        )

        #expect(belowThresholdSpy.values.isEmpty)
        #expect(disabledSpy.values.isEmpty)
    }
}
