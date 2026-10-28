import Foundation
import PiAI
import PiAgent
import Testing
@testable import PiCodingAgent

// Port of test/agent-session-retry.test.ts
//
// Swift: no AuthStorage / ModelRegistry / resource loader (not ported); the agent's `getApiKey` supplies the key and
// settings come from `SettingsManager.inMemory` with the same `applyOverrides`. Tools are given to the agent directly
// instead of `baseToolsOverride`.
// Not ported: "prompt waits for retry completion even when assistant message_end handling is delayed" (it patches
// `_emitExtensionEvent`; extensions are not ported).

private func createAssistantMessage(_ text: String, stopReason: StopReason = .stop, errorMessage: String? = nil) -> AssistantMessage {
    var message = AssistantMessage(
        content: [.text(TextContent(text: text))],
        api: "anthropic-messages",
        provider: "anthropic",
        model: "mock",
        usage: Usage(
            input: 0, output: 0, cacheRead: 0, cacheWrite: 0, totalTokens: 0,
            cost: UsageCost(input: 0, output: 0, cacheRead: 0, cacheWrite: 0, total: 0)
        ),
        stopReason: stopReason,
        timestamp: dateNow()
    )
    message.errorMessage = errorMessage
    return message
}

/// `queueMicrotask(() => { stream.push(start); stream.push(done | error) })`.
private func respond(_ message: AssistantMessage) -> AssistantMessageEventStream {
    let stream = createAssistantMessageEventStream()
    Task {
        stream.push(.start(partial: message))
        if message.stopReason == .error || message.stopReason == .aborted {
            stream.push(.error(reason: message.stopReason, error: message))
        } else {
            stream.push(.done(reason: message.stopReason, message: message))
        }
    }
    return stream
}

private func makeAgentSession(
    _ streamFn: @escaping StreamFn,
    tools: [AgentTool] = [],
    retry: Settings.RetrySettings
) async throws -> AgentSession {
    // Swift: `getModel("anthropic", "claude-sonnet-4-5")` stand-in (the generated model catalog is not ported).
    let model = Model(
        id: "claude-sonnet-4-5", name: "Claude Sonnet 4.5", api: "anthropic-messages", provider: "anthropic",
        baseUrl: "https://api.anthropic.com", reasoning: true, input: ["text", "image"], contextWindow: 200000, maxTokens: 64000
    )
    let agent = try Agent(AgentOptions(
        initialState: AgentInitialState(systemPrompt: "Test", model: model, tools: tools),
        convertToLlm: { convertToLlm($0) },
        streamFn: streamFn,
        getApiKey: { _ in "test-key" }
    ))
    let sessionManager = try SessionManager.inMemory()
    let settingsManager = SettingsManager.inMemory()
    settingsManager.applyOverrides(Settings(retry: retry))
    return await AgentSession(AgentSessionConfig(agent: agent, sessionManager: sessionManager, settingsManager: settingsManager, cwd: NSTemporaryDirectory()))
}

private struct CreatedSession {
    var session: AgentSession
    var callCount: Locked<Int>
    func getCallCount() -> Int { callCount.withLock { $0 } }
}

private func createSession(failCount: Int = 1, maxRetries: Int = 3, maxAgentDelayMs: Int = 60000) async throws -> CreatedSession {
    let callCount = Locked(0)
    let session = try await makeAgentSession({ _, _, _ in
        let count = callCount.withLock { $0 += 1; return $0 }
        if count <= failCount {
            return respond(createAssistantMessage("", stopReason: .error, errorMessage: "overloaded_error"))
        }
        return respond(createAssistantMessage("Success"))
    }, retry: Settings.RetrySettings(enabled: true, maxRetries: maxRetries, baseDelayMs: 1, maxAgentDelayMs: maxAgentDelayMs))
    return CreatedSession(session: session, callCount: callCount)
}

private func retryEvents(_ session: AgentSession) -> Collector<String> {
    let events = Collector<String>()
    _ = session.subscribe { event in
        switch event {
        case .autoRetryStart(let attempt, _, _, _): events.append("start:\(attempt)")
        case .autoRetryEnd(let success, _, _): events.append("end:success=\(success)")
        default: break
        }
    }
    return events
}

@Suite("AgentSession retry") struct AgentSessionRetryTests {
    @Test("retries after a transient error and succeeds") func retriesAndSucceeds() async throws {
        let created = try await createSession(failCount: 1)
        defer { created.session.dispose() }
        let events = retryEvents(created.session)

        try await created.session.prompt("Test")

        #expect(created.getCallCount() == 2)
        #expect(events.values == ["start:1", "end:success=true"])
        #expect(created.session.isRetrying == false)
    }

    @Test("exhausts max retries and emits failure") func exhaustsRetries() async throws {
        let created = try await createSession(failCount: 99, maxRetries: 2)
        defer { created.session.dispose() }
        let events = retryEvents(created.session)

        try await created.session.prompt("Test")

        #expect(created.getCallCount() == 3)
        #expect(events.values.contains("start:1"))
        #expect(events.values.contains("start:2"))
        #expect(events.values.contains("end:success=false"))
        #expect(created.session.isRetrying == false)
    }

    @Test("caps agent retry delay") func capsDelay() async throws {
        // Regression for #8826.
        let created = try await createSession(failCount: 4, maxRetries: 5, maxAgentDelayMs: 5)
        defer { created.session.dispose() }
        let delays = Collector<Int>()
        _ = created.session.subscribe { event in
            if case .autoRetryStart(_, _, let delayMs, _) = event { delays.append(delayMs) }
        }

        try await created.session.prompt("Test")

        #expect(delays.values == [1, 2, 4, 5])
    }

    @Test("retries provider network_error failures") func retriesNetworkError() async throws {
        let callCount = Locked(0)
        let session = try await makeAgentSession({ _, _, _ in
            let count = callCount.withLock { $0 += 1; return $0 }
            if count == 1 {
                return respond(createAssistantMessage("", stopReason: .error, errorMessage: "Provider finish_reason: network_error"))
            }
            return respond(createAssistantMessage("Recovered after retry"))
        }, retry: Settings.RetrySettings(enabled: true, maxRetries: 3, baseDelayMs: 1))
        defer { session.dispose() }
        let events = retryEvents(session)

        try await session.prompt("Test")

        #expect(callCount.withLock { $0 } == 2)
        #expect(events.values == ["start:1", "end:success=true"])
    }

    @Test("prompt waits for full agent loop when retry produces tool calls") func waitsForToolLoop() async throws {
        // Regression: when auto-retry fires and the retry response includes tool_use,
        // session.prompt() must wait for the entire tool loop to finish before returning.
        // Previously, _resolveRetry() on the first successful message_end would unblock
        // waitForRetry() while the agent was still executing tools.
        let callCount = Locked(0)
        let toolExecuted = Locked(false)

        let echoTool = AgentTool(
            name: "echo",
            label: "Echo",
            description: "Echo text back",
            parameters: [
                "type": "object",
                "properties": ["text": ["type": "string"]],
                "required": ["text"],
            ]
        ) { _, _, _, _ in
            toolExecuted.withLock { $0 = true }
            return AgentToolResult(content: [.text(TextContent(text: "echoed"))], details: nil)
        }

        let session = try await makeAgentSession({ _, _, _ in
            let count = callCount.withLock { $0 += 1; return $0 }
            if count == 1 {
                // First call: overloaded error
                return respond(createAssistantMessage("", stopReason: .error, errorMessage: "overloaded_error"))
            } else if count == 2 {
                // Second call (retry): text + tool_use
                var msg = createAssistantMessage("Looking that up now.", stopReason: .toolUse)
                msg.content = [
                    .text(TextContent(text: "Looking that up now.")),
                    .toolCall(ToolCall(id: "call_1", name: "echo", arguments: ["text": "hello"])),
                ]
                return respond(msg)
            }
            // Third call (after tool result): final response
            return respond(createAssistantMessage("Final answer."))
        }, tools: [echoTool], retry: Settings.RetrySettings(enabled: true, maxRetries: 3, baseDelayMs: 1))
        defer { session.dispose() }

        try await session.prompt("Test")

        // All three LLM calls must have completed
        #expect(callCount.withLock { $0 } == 3)
        // Tool must have been executed
        #expect(toolExecuted.withLock { $0 } == true)
        // Agent must not be streaming after prompt returns
        #expect(session.isStreaming == false)
        // A follow-up prompt must work (no "Agent is already processing" error)
        try await session.prompt("Follow-up")
        #expect(callCount.withLock { $0 } == 4)
    }
}
