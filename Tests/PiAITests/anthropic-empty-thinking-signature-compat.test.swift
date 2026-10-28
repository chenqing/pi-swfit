import Foundation
import Testing
@testable import PiAI

// Port of packages/ai/test/anthropic-empty-thinking-signature-compat.test.ts
// Not ported: "allows empty thinking signatures for every Vercel AI Gateway model" (reads the generated
// catalog via getModels("vercel-ai-gateway"); the Swift port has no generated catalog)
// The Fireworks cases build the models inline; the upstream `model.compat?.allowEmptySignature` catalog
// assertion is kept against the inline model.

private func makeModel(_ allowEmptySignature: Bool? = nil) -> Model {
    bModel(
        id: "mimo-v2.6-pro",
        name: "MiMo-V2.5-Pro",
        provider: "xiaomi-token-plan-ams",
        baseUrl: "http://127.0.0.1:9/anthropic",
        reasoning: true,
        contextWindow: 1048576,
        maxTokens: 1024,
        compat: allowEmptySignature.map { ["allowEmptySignature": .bool($0)] }
    )
}

/// Mirrors the generated catalog entry for `fireworks/<modelId>` (Fireworks anthropic-messages compat).
private func fireworksModel(_ modelId: String) -> Model {
    bModel(
        id: modelId,
        provider: "fireworks",
        baseUrl: "https://api.fireworks.ai/inference",
        reasoning: true,
        compat: [
            "allowEmptySignature": true,
            "sendSessionAffinityHeaders": true,
            "supportsEagerToolInputStreaming": false,
            "supportsCacheControlOnTools": false,
            "supportsLongCacheRetention": false,
        ]
    )
}

private func makeContext(
    _ thinkingSignature: String,
    _ thinking: String = "internal reasoning",
    provider: String = "xiaomi-token-plan-ams",
    model: String = "mimo-v2.6-pro",
    extraContent: [AssistantContent] = []
) -> Context {
    let assistant = AssistantMessage(
        content: [.thinking(ThinkingContent(thinking: thinking, thinkingSignature: thinkingSignature))] + extraContent,
        api: "anthropic-messages",
        provider: provider,
        model: model,
        stopReason: .stop
    )
    return Context(messages: [
        .user(UserMessage(content: "first")),
        .assistant(assistant),
        .user(UserMessage(content: "second")),
    ])
}

private func assistantContent(_ model: Model, _ context: Context) async throws -> JsonValue? {
    let payload = try #require(await bCapturePayload(model, context), "Expected payload capture before request")
    return payload["messages"]?.arrayValue?.first { $0["role"] == "assistant" }?["content"]
}

@Suite("Anthropic empty thinking signature compat")
struct AnthropicEmptyThinkingSignatureCompatTests {
    @Test("converts empty-signature thinking to text by default")
    func convertsToText() async throws {
        let content = try await assistantContent(makeModel(), makeContext(""))
        #expect(content == [["type": "text", "text": "internal reasoning"]])
    }

    @Test("preserves empty thinking text when the signature is present")
    func preservesEmptyThinking() async throws {
        let content = try await assistantContent(makeModel(), makeContext("signed-thinking", ""))
        #expect(content == [["type": "thinking", "thinking": "", "signature": "signed-thinking"]])
    }

    @Test("preserves empty-signature thinking when allowEmptySignature is enabled")
    func allowEmptySignature() async throws {
        let content = try await assistantContent(makeModel(true), makeContext(" "))
        #expect(content == [["type": "thinking", "thinking": "internal reasoning", "signature": ""]])
    }

    // Regression for #9323: Fireworks emits unsigned thinking that must survive replay.
    @Test(
        "preserves unsigned thinking for Fireworks",
        arguments: [
            "accounts/fireworks/models/deepseek-v4p1-flash",
            "accounts/fireworks/models/qwen3p8-max",
            "accounts/fireworks/models/qwen3p8-2p4t-a95b",
            "accounts/fireworks/models/nemotron-3-ultra-nvfp4",
        ]
    )
    func fireworks(modelId: String) async throws {
        let model = fireworksModel(modelId)
        #expect(model.compat?["allowEmptySignature"] == true)
        let context = makeContext("", "internal reasoning", provider: "fireworks", model: modelId, extraContent: [.text(TextContent(text: "answer"))])
        let content = try await assistantContent(model, context)
        #expect(content == [
            ["type": "thinking", "thinking": "internal reasoning", "signature": ""],
            ["type": "text", "text": "answer"],
        ])
    }
}
