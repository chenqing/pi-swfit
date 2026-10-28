import Foundation
import PiAI
import PiAgent
import Testing
@testable import PiCodingAgent

// Port of test/compaction-summary-reasoning.test.ts
// Swift: upstream mocks `completeSimple` with `vi.mock`; here the recorded mock is passed as the
// `streamFn` parameter every summarization entry point already accepts (it replaces `completeSimple`).

private func createModel(_ reasoning: Bool, _ maxTokens: Int = 8192, _ compat: JsonObject? = nil) -> Model {
    Model(
        id: reasoning ? "reasoning-model" : "non-reasoning-model",
        name: reasoning ? "Reasoning Model" : "Non-reasoning Model",
        api: "anthropic-messages",
        provider: "anthropic",
        baseUrl: "https://api.anthropic.com",
        reasoning: reasoning,
        input: ["text"],
        cost: ModelCost(),
        contextWindow: 200000,
        maxTokens: maxTokens,
        compat: compat
    )
}

private let mockSummaryResponse = AssistantMessage(
    content: [.text(TextContent(text: "## Goal\nTest summary"))],
    api: "anthropic-messages",
    provider: "anthropic",
    model: "claude-sonnet-4-5",
    usage: Usage(
        input: 10, output: 10, cacheRead: 0, cacheWrite: 0, totalTokens: 20,
        cost: UsageCost(input: 0, output: 0, cacheRead: 0, cacheWrite: 0, total: 0)
    ),
    stopReason: .stop,
    timestamp: dateNow()
)

private let mockToolCallResponse: AssistantMessage = {
    var message = mockSummaryResponse
    message.content = [.toolCall(ToolCall(id: "tool-call-1", name: "read", arguments: ["path": "README.md"]))]
    message.stopReason = .toolUse
    return message
}()

private let messages: [AgentMessage] = [.user(UserMessage(content: .string("Summarize this."), timestamp: dateNow()))]

/// `completeSimpleMock`: records `(model, context, options)` and resolves queued responses
/// (`mockResolvedValueOnce`) before the default (`mockResolvedValue`).
private final class CompleteSimpleMock: Sendable {
    struct Call: Sendable {
        var model: Model
        var context: TranscriptContext
        var options: SimpleStreamOptions?
    }

    private struct State {
        var calls: [Call] = []
        var once: [AssistantMessage] = []
    }

    private let state = Locked(State())
    let defaultResponse: AssistantMessage

    init(_ defaultResponse: AssistantMessage = mockSummaryResponse) {
        self.defaultResponse = defaultResponse
    }

    var calls: [Call] { state.withLock { $0.calls } }

    func mockResolvedValueOnce(_ message: AssistantMessage) {
        state.withLock { $0.once.append(message) }
    }

    var streamFn: StreamFn {
        { [self] model, context, options in
            let response = state.withLock { s -> AssistantMessage in
                s.calls.append(Call(model: model, context: context, options: options))
                return s.once.isEmpty ? defaultResponse : s.once.removeFirst()
            }
            let stream = createAssistantMessageEventStream()
            stream.push(.done(reason: response.stopReason, message: response))
            return stream
        }
    }
}

private func splitTurnPreparation(
    _ messagesToSummarize: [AgentMessage] = [],
    tokensBefore: Int = 100,
    previousSummary: String? = nil,
    settings: CompactionSettings = CompactionSettings(enabled: true, reserveTokens: 2000, keepRecentTokens: 20)
) -> CompactionPreparation {
    CompactionPreparation(
        firstKeptEntryId: "entry-keep",
        messagesToSummarize: messagesToSummarize,
        turnPrefixMessages: messages,
        isSplitTurn: true,
        tokensBefore: tokensBefore,
        previousSummary: previousSummary,
        fileOps: FileOperations(read: [], written: [], edited: []),
        settings: settings
    )
}

@Suite("generateSummary reasoning options") struct GenerateSummaryReasoningTests {
    @Test("uses the provided thinking level for reasoning-capable models") func providedThinkingLevel() async throws {
        let mock = CompleteSimpleMock()
        let result = try await generateSummaryWithUsage(
            messages, createModel(true), nil, "test-key", nil, nil, nil, nil, .medium, mock.streamFn
        )

        #expect(result.text == "## Goal\nTest summary")
        #expect(result.usage == mockSummaryResponse.usage)

        #expect(mock.calls.count == 1)
        #expect(mock.calls[0].options?.reasoning == .medium)
        #expect(mock.calls[0].options?.apiKey == "test-key")
    }

    @Test("preserves the string result from generateSummary") func stringResult() async throws {
        let mock = CompleteSimpleMock()
        let text = try await generateSummary(messages, createModel(false), nil, "test-key", nil, nil, nil, nil, nil, mock.streamFn)
        #expect(text == "## Goal\nTest summary")
    }

    @Test("uses fresh routing sessions without prompt caching") func freshRoutingSessions() async throws {
        let mock = CompleteSimpleMock()
        _ = try await generateSummary(messages, createModel(false), nil, "test-key", nil, nil, nil, nil, nil, mock.streamFn)
        _ = try await generateSummary(messages, createModel(false), nil, "test-key", nil, nil, nil, nil, nil, mock.streamFn)

        let requestOptions = mock.calls.map(\.options)
        #expect(requestOptions.count == 2)
        #expect(requestOptions.allSatisfy { $0?.cacheRetention == CacheRetention.none })

        let sessionIds = requestOptions.map { $0?.sessionId }
        #expect(sessionIds[0] != sessionIds[1])
    }

    @Test("honors caller-supplied routing session and tool choice without prompt caching") func callerRouting() async throws {
        let mock = CompleteSimpleMock()
        var options = SimpleStreamOptions()
        options.sessionId = "current-routing-session"
        options.cacheRetention = .long
        options.toolChoice = "auto"
        _ = try await completeSummarization(
            createModel(false), normalizeContext(Context(systemPrompt: "Summarize", messages: [])), options, mock.streamFn
        )

        let recorded = mock.calls[0].options
        #expect(recorded?.sessionId == "current-routing-session")
        #expect(recorded?.cacheRetention == CacheRetention.none)
        #expect(recorded?.toolChoice == "auto")
    }

    @Test("preserves the previous summary without an empty history request for a split turn") func previousSummarySplitTurn() async throws {
        let mock = CompleteSimpleMock()
        let preparation = splitTurnPreparation(previousSummary: "previous checkpoint")

        let result = try await compact(preparation, createModel(false), "test-key", nil, nil, nil, nil, mock.streamFn)

        #expect(mock.calls.count == 1)
        #expect(result.summary.contains("previous checkpoint"))
        let requestContext = mock.calls[0].context
        let prompt = JsonValue.array(requestContext.messages.map(\.json)).serialized()
        // Regression test for #9652: clear boundaries and continuation wording avoid the reasoning-extraction false positive.
        #expect(prompt.contains("# Conversation\\n[User]: Summarize this."))
        #expect(prompt.contains("# Instructions\\nThe messages above are earlier context from an ongoing conversation."))
    }

    @Test("rejects tool calls from conversation summaries") func rejectsToolCalls() async {
        let mock = CompleteSimpleMock()
        mock.mockResolvedValueOnce(mockToolCallResponse)

        let message = await thrownMessage {
            _ = try await generateSummaryWithUsage(messages, createModel(false), nil, "test-key", nil, nil, nil, nil, nil, mock.streamFn)
        }
        #expect(message?.contains("Summarization attempted to call a tool") == true)
    }

    @Test("rejects tool calls from split-turn summaries") func rejectsSplitTurnToolCalls() async {
        let mock = CompleteSimpleMock()
        mock.mockResolvedValueOnce(mockToolCallResponse)
        let preparation = splitTurnPreparation()

        let message = await thrownMessage {
            _ = try await compact(preparation, createModel(false), "test-key", nil, nil, nil, nil, mock.streamFn)
        }
        #expect(message?.contains("Turn prefix summarization attempted to call a tool") == true)
    }

    @Test("rejects a length-limited history summary") func rejectsLengthLimitedHistory() async {
        let mock = CompleteSimpleMock()
        var partial = mockSummaryResponse
        partial.stopReason = .length
        partial.content = [.text(TextContent(text: "partial"))]
        mock.mockResolvedValueOnce(partial)

        let message = await thrownMessage {
            _ = try await generateSummaryWithUsage(messages, createModel(false), nil, "test-key", nil, nil, nil, nil, nil, mock.streamFn)
        }
        #expect(message?.contains("generation hit the token cap") == true)
    }

    @Test("rejects a length-limited split-turn summary") func rejectsLengthLimitedSplitTurn() async {
        let mock = CompleteSimpleMock()
        var partial = mockSummaryResponse
        partial.stopReason = .length
        partial.content = [.text(TextContent(text: "partial"))]
        mock.mockResolvedValueOnce(partial)
        let preparation = splitTurnPreparation()

        let message = await thrownMessage {
            _ = try await compact(preparation, createModel(false), "test-key", nil, nil, nil, nil, mock.streamFn)
        }
        #expect(message?.contains("generation hit the token cap") == true)
    }

    @Test("does not set reasoning when thinking is off") func noReasoningWhenOff() async throws {
        let mock = CompleteSimpleMock()
        _ = try await generateSummary(messages, createModel(true), nil, "test-key", nil, nil, nil, nil, .off, mock.streamFn)

        #expect(mock.calls.count == 1)
        #expect(mock.calls[0].options?.apiKey == "test-key")
        #expect(mock.calls[0].options?.reasoning == nil)
    }

    @Test("does not set reasoning for non-reasoning models") func noReasoningForNonReasoningModels() async throws {
        let mock = CompleteSimpleMock()
        _ = try await generateSummary(messages, createModel(false), nil, "test-key", nil, nil, nil, nil, .medium, mock.streamFn)

        #expect(mock.calls.count == 1)
        #expect(mock.calls[0].options?.apiKey == "test-key")
        #expect(mock.calls[0].options?.reasoning == nil)
    }

    // Not ported: "leaves Anthropic refusal fallback handling to pi-ai model metadata" and "does not set Anthropic
    // refusal fallback for models without allowed fallback targets" (StreamOptions has no `refusalFallbacks`).

    @Test("combines usage from split-turn summaries") func combinesUsage() async throws {
        let mock = CompleteSimpleMock()
        let preparation = splitTurnPreparation(
            messages, tokensBefore: 600000, settings: CompactionSettings(enabled: true, reserveTokens: 16384, keepRecentTokens: 20000)
        )

        let result = try await compact(preparation, createModel(false), "test-key", nil, nil, nil, nil, mock.streamFn)

        var expected = mockSummaryResponse.usage
        expected.input = 20
        expected.output = 20
        expected.totalTokens = 40
        expected.cost = UsageCost(input: 0, output: 0, cacheRead: 0, cacheWrite: 0, total: 0)
        #expect(result.usage == expected)
    }
}
