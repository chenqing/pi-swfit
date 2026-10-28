import Foundation
import Testing
@testable import PiAI

// Port of packages/ai/test/anthropic-mid-conversation-effort.test.ts
//
// Not ported: "generates exact model and transport gates" and "supports off only on managed models that
// accept disabled thinking" (they assert the generated built-in catalog from scripts/generate-models.ts;
// Swift has no generated model catalog, so inlined models would only restate the expectations).

private func managedModel(_ provider: String = "anthropic") -> Model {
    var model = Model(
        id: "claude-fable-5-1",
        name: "Claude Fable 5.1",
        api: "anthropic-messages",
        provider: provider,
        baseUrl: "http://127.0.0.1:9",
        reasoning: true,
        input: ["text"],
        cost: ModelCost(),
        contextWindow: 200_000,
        maxTokens: 32_000,
        compat: ["forceAdaptiveThinking": true, "supportsMidConvoEffort": true]
    )
    model.thinkingLevelMap = [.off: nil, .minimal: "low", .low: "low", .medium: "medium", .high: "high", .max: "max"]
    return model
}

private func assistant(_ model: Model, _ level: String? = nil) -> Message {
    var message = AssistantMessage(
        content: [
            .thinking(ThinkingContent(thinking: "reasoning", thinkingSignature: "signature")),
            .text(TextContent(text: "answer")),
        ],
        api: "anthropic-messages",
        provider: model.provider,
        model: model.id,
        usage: Usage(),
        stopReason: .stop,
        timestamp: 1
    )
    message.providerThinkingLevel = level
    return .assistant(message)
}

private func user(_ text: String, _ timestamp: Int) -> Message {
    .user(UserMessage(content: .string(text), timestamp: timestamp))
}

private struct Captured {
    var payload: JsonObject
    var message: AssistantMessage
    var messages: [JsonValue] { payload["messages"]?.arrayValue ?? [] }
}

private func capture(
    _ model: Model,
    _ messages: [Message],
    effort: AnthropicEffort? = nil,
    thinkingEnabled: Bool = true
) async throws -> Captured {
    let captured = Locked<JsonObject?>(nil)
    var options = AnthropicOptions(thinkingEnabled: thinkingEnabled, effort: effort)
    options.apiKey = "test-key"
    options.cacheRetention = CacheRetention.none
    options.onPayload = { value, _ in
        captured.withLock { $0 = value.objectValue }
        throw PiError("payload captured")
    }
    let message = await streamAnthropicMessages(model, normalizeContext(Context(messages: messages)), options).result()
    let payload = try #require(captured.withLock { $0 }, "Expected payload capture")
    return Captured(payload: payload, message: message)
}

private func effortMessages(_ captured: Captured) -> [JsonValue] {
    captured.messages.filter { $0["role"] == "system" }
}

private func marker(_ effort: String) -> JsonValue {
    ["role": "system", "content": [], "output_config": ["effort": .string(effort)]]
}

@Suite("Anthropic mid-conversation effort")
struct AnthropicMidConversationEffortTests {
    @Test("reconstructs an exact historical marker prefix and appends the current marker")
    func reconstructsHistoricalMarkerPrefix() async throws {
        let model = managedModel()
        let first = try await capture(model, [user("one", 1)], effort: "low")
        let second = try await capture(model, [user("one", 1), assistant(model, "low"), user("two", 2)], effort: "high")

        #expect(first.messages == [
            ["role": "user", "content": "one"],
            marker("low"),
        ])
        #expect(Array(second.messages.prefix(first.messages.count)) == first.messages)
        #expect(second.messages.last == marker("high"))
        #expect(first.payload["output_config"] == ["effort": "high"])
        #expect(second.payload["output_config"] == ["effort": "high"])
        #expect(second.payload["thinking"] == [
            "type": "adaptive",
            "display": "summarized",
            "block_binding": ["prefix_mismatch_behavior": "drop_block"],
        ])
        #expect(first.message.providerThinkingLevel == "low")
    }

    @Test("preserves native effort", arguments: ["low", "medium", "high", "xhigh", "max"])
    func preservesNativeEffort(_ effort: String) async throws {
        let model = managedModel()
        let captured = try await capture(model, [user("one", 1)], effort: AnthropicEffort(rawValue: effort))
        #expect(effortMessages(captured) == [marker(effort)])
        #expect(captured.message.providerThinkingLevel == effort)
    }

    @Test("defaults omitted effort to high and still enables drop_block")
    func defaultsOmittedEffortToHigh() async throws {
        let captured = try await capture(managedModel(), [user("one", 1)])
        #expect(captured.messages.last == marker("high"))
        #expect(captured.payload["thinking"]?["block_binding"]?["prefix_mismatch_behavior"] == "drop_block")
        #expect(captured.message.providerThinkingLevel == "high")
    }

    @Test("does not invent markers for legacy or other-provider assistants")
    func doesNotInventMarkers() async throws {
        let model = managedModel()
        let legacy = assistant(model)
        guard case .assistant(var otherProvider) = assistant(model, "low") else { return }
        otherProvider.provider = "other-provider"
        let captured = try await capture(
            model,
            [user("one", 1), legacy, user("two", 2), .assistant(otherProvider), user("three", 3)],
            effort: "medium"
        )
        #expect(effortMessages(captured) == [marker("medium")])
    }

    @Test("sends plain disabled thinking without effort when off is supported")
    func sendsPlainDisabledThinking() async throws {
        var model = managedModel()
        model.thinkingLevelMap = [.minimal: nil, .low: "low", .medium: "medium", .high: "high", .max: "max"]
        // Anthropic rejects block_binding with disabled thinking, and rejects effort markers
        // that change level (here low, then medium) while thinking is disabled.
        let captured = try await capture(
            model,
            [
                user("one", 1),
                assistant(model, "low"),
                user("two", 2),
                assistant(model, "medium"),
                user("three", 3),
            ],
            thinkingEnabled: false
        )
        #expect(captured.payload["thinking"] == ["type": "disabled"])
        #expect(captured.payload["output_config"] == nil)
        #expect(effortMessages(captured) == [])
        #expect(captured.message.providerThinkingLevel == nil)
    }

    @Test("keeps adaptive thinking when off is unsupported")
    func keepsAdaptiveThinkingWhenOffUnsupported() async throws {
        let captured = try await capture(managedModel(), [user("one", 1)], thinkingEnabled: false)
        #expect(captured.payload["thinking"]?["type"] == "adaptive")
        #expect(effortMessages(captured) == [marker("high")])
        #expect(captured.message.providerThinkingLevel == "high")
    }

    @Test("leaves unsupported models on top-level effort")
    func leavesUnsupportedModelsOnTopLevelEffort() async throws {
        var model = managedModel()
        model.compat = ["forceAdaptiveThinking": true]
        let captured = try await capture(model, [user("one", 1)], effort: "low")
        #expect(captured.messages == [["role": "user", "content": "one"]])
        #expect(captured.payload["output_config"] == ["effort": "low"])
        #expect(captured.payload["thinking"] == ["type": "adaptive", "display": "summarized"])
        #expect(captured.message.providerThinkingLevel == nil)
    }

    @Test("sends the effort and binding beta headers")
    func sendsEffortAndBindingBetaHeaders() async throws {
        let events: [(event: String, data: JsonValue)] = [
            ("message_start", [
                "type": "message_start",
                "message": [
                    "id": "msg_test",
                    "model": "claude-fable-5-1",
                    "usage": ["input_tokens": 1, "output_tokens": 0],
                ],
            ]),
            ("message_delta", [
                "type": "message_delta",
                "delta": ["stop_reason": "end_turn"],
                "usage": ["input_tokens": 1, "output_tokens": 1],
            ]),
            ("message_stop", ["type": "message_stop"]),
        ]
        let requests = BRequests()
        var options = AnthropicOptions()
        options.apiKey = "test-key"
        options.cacheRetention = CacheRetention.none
        options.fetch = bFetch(bSseBody(json: events) + "\n", requests: requests)
        let result = await streamAnthropicMessages(managedModel(), normalizeContext(Context(messages: [user("one", 1)])), options).result()

        #expect(result.stopReason == .stop)
        let betaHeader = try #require(requests.last?.headers.get("anthropic-beta"))
        #expect(betaHeader.contains("mid-conversation-output-config-2026-07-01"))
        #expect(betaHeader.contains("thinking-binding-controls-2026-08-01"))
    }
}
