import Foundation
import PiAI
import PiAgent
import Testing
@testable import PiCodingAgent

// Port of test/suite/agent-session-retry-events.test.ts
//
// Not ported: "prompt waits for retry completion even when assistant message_end handling is delayed" and
// "emits extension events before public event subscribers" (both need extension factories).

private func normalizeEventOrder(_ events: [AgentSessionEvent]) -> [String] {
    var normalized: [String] = []
    for event in events {
        let label: String
        switch event {
        case .messageStart(let message), .messageEnd(let message):
            label = "\(event.type):\(message.role)"
        case .toolExecutionStart(_, let toolName, _), .toolExecutionEnd(_, let toolName, _, _, _):
            label = "\(event.type):\(toolName)"
        default:
            label = event.type
        }
        if label == "message_update" && normalized.last == "message_update" {
            continue
        }
        normalized.append(label)
    }
    return normalized
}

private func retrySettings(enabled: Bool = true, maxRetries: Int? = 3, baseDelayMs: Int? = 1) -> Settings {
    Settings(retry: Settings.RetrySettings(enabled: enabled, maxRetries: maxRetries, baseDelayMs: baseDelayMs))
}

private func overloaded() -> FauxResponseStep {
    .message(fauxAssistantMessage("", stopReason: .error, errorMessage: "overloaded_error"))
}

private func retryEvents(_ session: AgentSession) -> Collector<String> {
    let events = Collector<String>()
    _ = session.subscribe { event in
        switch event {
        case .autoRetryStart(let attempt, _, _, _): events.append("start:\(attempt)")
        case .autoRetryEnd(let success, _, _): events.append("end:\(success)")
        default: break
        }
    }
    return events
}

private func willRetryFlags(_ harness: Harness) -> [Bool] {
    harness.eventsOfType("agent_end").compactMap { if case .agentEnd(_, let willRetry) = $0 { return willRetry } else { return nil } }
}

private func makeEchoTool(_ toolRuns: Collector<String>) -> AgentTool {
    AgentTool(
        name: "echo",
        label: "Echo",
        description: "Echo text back",
        parameters: ["type": "object", "properties": ["text": ["type": "string"]], "required": ["text"]]
    ) { _, params, _, _ in
        let text = params["text"]?.stringValue ?? ""
        toolRuns.append(text)
        return AgentToolResult(content: [.text(TextContent(text: "echo:\(text)"))], details: ["text": .string(text)])
    }
}

@Suite("AgentSession retry and event characterization") struct AgentSessionRetryEventsTests {
    @Test("retries after a transient error and succeeds") func retriesAndSucceeds() async throws {
        let harness = try await createHarness(HarnessOptions(settings: retrySettings()))
        defer { harness.cleanup() }
        let events = retryEvents(harness.session)

        harness.setResponses([overloaded(), .message(fauxAssistantMessage("recovered"))])

        try await harness.session.prompt("test")

        #expect(events.values == ["start:1", "end:true"])
        #expect(willRetryFlags(harness) == [true, false])
        #expect(harness.faux.state.callCount == 2)
        #expect(harness.session.isRetrying == false)
    }

    @Test("retries multiple transient failures and succeeds on the final attempt") func retriesMultiple() async throws {
        let harness = try await createHarness(HarnessOptions(settings: retrySettings()))
        defer { harness.cleanup() }
        let events = retryEvents(harness.session)

        harness.setResponses([overloaded(), overloaded(), .message(fauxAssistantMessage("success"))])

        try await harness.session.prompt("test")

        #expect(events.values == ["start:1", "start:2", "end:true"])
        #expect(harness.faux.state.callCount == 3)
    }

    // Regression test for #9340.
    @Test("finalizes retry state when abort is requested after a retry attempt fails") func abortAfterRetryFailure() async throws {
        let harness = try await createHarness(HarnessOptions(settings: retrySettings(baseDelayMs: 0)))
        defer { harness.cleanup() }
        harness.setResponses([overloaded(), overloaded()])

        let errorCount = Locked(0)
        let session = harness.session
        _ = session.subscribe { event in
            guard case .messageEnd(.assistant(let message)) = event else { return }
            if message.stopReason == .error && errorCount.withLock({ $0 += 1; return $0 }) == 2 {
                // Swift: `void session.abort()` runs abort's synchronous prefix before the listener returns; a Task
                // alone would race the retry decision, so request the abort synchronously first.
                session._requestAbort()
                Task { await session.abort() }
            }
        }

        try await harness.session.prompt("test")
        await harness.session.waitForIdle()

        #expect(harness.session.retryAttempt == 0)
        #expect(willRetryFlags(harness).last == false)
        let lastRetryEnd = harness.eventsOfType("auto_retry_end").last
        guard case .autoRetryEnd(let success, let attempt, let finalError)? = lastRetryEnd else {
            Issue.record("missing auto_retry_end")
            return
        }
        #expect(success == false)
        #expect(attempt == 1)
        #expect(finalError == "Retry cancelled")
    }

    @Test("exhausts max retries and emits a failure event") func exhaustsRetries() async throws {
        let harness = try await createHarness(HarnessOptions(settings: retrySettings(maxRetries: 2)))
        defer { harness.cleanup() }
        let events = retryEvents(harness.session)

        harness.setResponses([overloaded(), overloaded(), overloaded()])

        try await harness.session.prompt("test")

        #expect(events.values == ["start:1", "start:2", "end:false"])
        #expect(willRetryFlags(harness) == [true, true, false])
        #expect(harness.faux.state.callCount == 3)
        #expect(harness.session.isRetrying == false)
    }

    @Test("does not retry when retry is disabled") func disabled() async throws {
        let harness = try await createHarness(HarnessOptions(settings: retrySettings(enabled: false, maxRetries: nil, baseDelayMs: nil)))
        defer { harness.cleanup() }
        harness.setResponses([overloaded()])

        try await harness.session.prompt("test")

        #expect(harness.faux.state.callCount == 1)
        #expect(harness.eventsOfType("auto_retry_start").isEmpty)
    }

    @Test("does not retry non-retryable errors") func nonRetryable() async throws {
        let harness = try await createHarness(HarnessOptions(settings: retrySettings()))
        defer { harness.cleanup() }
        harness.setResponses([.message(fauxAssistantMessage("", stopReason: .error, errorMessage: "invalid_api_key"))])

        try await harness.session.prompt("test")

        #expect(harness.faux.state.callCount == 1)
        #expect(harness.eventsOfType("auto_retry_start").isEmpty)
    }

    @Test("cancels retry sleep when abortRetry is called") func abortRetrySleep() async throws {
        // Swift: a 10s delay instead of 100ms (the sleep is cancelled) so a busy test pool cannot finish the sleep
        // before the polling waiter calls abortRetry.
        let harness = try await createHarness(HarnessOptions(settings: retrySettings(baseDelayMs: 10_000)))
        defer { harness.cleanup() }
        harness.setResponses([overloaded()])

        let session = harness.session
        let sawRetryStart = Locked(false)
        _ = session.subscribe { event in
            if case .autoRetryStart = event { sawRetryStart.withLock { $0 = true } }
        }

        let promptTask = Task { try await session.prompt("test") }
        // Swift: also wait for the retry sleep to own its abort controller (upstream reaches it within one microtask).
        #expect(await waitUntil { sawRetryStart.withLock { $0 } && session.isRetrying })
        session.abortRetry()
        try await promptTask.value

        #expect(harness.session.isRetrying == false)
        let finalErrors = harness.eventsOfType("auto_retry_end").compactMap { event -> String? in
            if case .autoRetryEnd(_, _, let finalError) = event { return finalError }
            return nil
        }
        #expect(finalErrors.contains("Retry cancelled"))
        #expect(harness.faux.state.callCount == 1)
    }

    @Test("waits for the full loop when retry recovery produces tool calls") func waitsForToolLoop() async throws {
        let toolRuns = Collector<String>()
        let harness = try await createHarness(HarnessOptions(settings: retrySettings(), tools: [makeEchoTool(toolRuns)]))
        defer { harness.cleanup() }
        harness.setResponses([
            overloaded(),
            .message(fauxAssistantMessage([fauxToolCall("echo", ["text": "hello"])], stopReason: .toolUse)),
            .message(fauxAssistantMessage("final answer")),
        ])

        try await harness.session.prompt("test")

        #expect(harness.faux.state.callCount == 3)
        #expect(toolRuns.values == ["hello"])
        #expect(harness.session.isStreaming == false)
        try await harness.session.prompt("follow-up")
        #expect(harness.faux.state.callCount == 4)
    }

    @Test("emits the expected event order for a single prompt") func singlePromptOrder() async throws {
        let harness = try await createHarness()
        defer { harness.cleanup() }
        harness.setResponses([.message(fauxAssistantMessage("hello"))])

        try await harness.session.prompt("hi")

        #expect(normalizeEventOrder(harness.events) == [
            "agent_start",
            "turn_start",
            "message_start:system",
            "message_end:system",
            "message_start:user",
            "message_end:user",
            "message_start:assistant",
            "message_update",
            "message_end:assistant",
            "turn_end",
            "agent_end",
            "agent_settled",
        ])
    }

    @Test("emits the expected event order for a tool call turn") func toolCallTurnOrder() async throws {
        let toolRuns = Collector<String>()
        let harness = try await createHarness(HarnessOptions(tools: [makeEchoTool(toolRuns)]))
        defer { harness.cleanup() }
        harness.setResponses([
            .message(fauxAssistantMessage([fauxToolCall("echo", ["text": "hello"])], stopReason: .toolUse)),
            .message(fauxAssistantMessage("done")),
        ])

        try await harness.session.prompt("hi")

        #expect(toolRuns.values == ["hello"])
        #expect(normalizeEventOrder(harness.events) == [
            "agent_start",
            "turn_start",
            "message_start:system",
            "message_end:system",
            "message_start:user",
            "message_end:user",
            "message_start:assistant",
            "message_update",
            "message_end:assistant",
            "tool_execution_start:echo",
            "tool_execution_end:echo",
            "message_start:toolResult",
            "message_end:toolResult",
            "turn_end",
            "turn_start",
            "message_start:assistant",
            "message_update",
            "message_end:assistant",
            "turn_end",
            "agent_end",
            "agent_settled",
        ])
    }

    @Test("emits streaming deltas for text, thinking, and tool calls in message_update events") func streamingDeltas() async throws {
        let harness = try await createHarness()
        defer { harness.cleanup() }
        harness.setResponses([
            .message(fauxAssistantMessage(
                [fauxThinking("plan"), fauxText("answer"), fauxToolCall("echo", ["text": "hello"])],
                stopReason: .toolUse
            )),
        ])

        try? await harness.session.prompt("hi")

        let updateTypes = harness.eventsOfType("message_update").compactMap { event -> String? in
            if case .messageUpdate(_, let assistantMessageEvent) = event { return assistantMessageEvent.type }
            return nil
        }
        #expect(updateTypes.contains("thinking_delta"))
        #expect(updateTypes.contains("text_delta"))
        #expect(updateTypes.contains("toolcall_delta"))
    }

    @Test("emits agent_end for error responses") func agentEndForErrors() async throws {
        let harness = try await createHarness()
        defer { harness.cleanup() }
        harness.setResponses([.message(fauxAssistantMessage("", stopReason: .error, errorMessage: "broken"))])

        try await harness.session.prompt("hi")

        #expect(harness.eventsOfType("agent_end").count == 1)
        #expect(harness.events.last?.type == "agent_settled")
    }

    @Test("emits agent_end for aborted runs and persists the aborted assistant message") func agentEndForAborted() async throws {
        let harness = try await createHarness()
        defer { harness.cleanup() }
        harness.setResponses([.message(fauxAssistantMessage(String(repeating: "x", count: 20_000)))])

        let session = harness.session
        let sawMessageUpdate = Locked(false)
        _ = session.subscribe { event in
            if case .messageUpdate = event { sawMessageUpdate.withLock { $0 = true } }
        }

        let promptTask = Task { try await session.prompt("hi") }
        #expect(await waitUntil { sawMessageUpdate.withLock { $0 } })
        await session.abort()
        try await promptTask.value

        #expect(harness.eventsOfType("agent_end").count == 1)
        #expect(harness.events.last?.type == "agent_settled")
        let lastMessage = await session.messages.last
        #expect(lastMessage?.role == "assistant")
        if case .assistant(let assistant)? = lastMessage {
            #expect(assistant.stopReason == .aborted)
        }
    }
}
