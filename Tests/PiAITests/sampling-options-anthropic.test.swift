import Foundation
import Testing
@testable import PiAI

// Port of the anthropic-messages case of packages/ai/test/sampling-options.test.ts
// Upstream dispatches through the registry `stream()`; this calls `streamAnthropicMessages` directly.
// Not ported: the openai-completions / openai-responses / azure-openai-responses cases (other adapters).

@Suite("sampling params - anthropic-messages")
struct SamplingOptionsAnthropicTests {
    @Test("is ignored by non-OpenAI-compatible APIs")
    func ignoredByAnthropic() async throws {
        let model = bModel(
            id: "custom-model",
            name: "Custom Model",
            provider: "custom-provider",
            baseUrl: "http://127.0.0.1:9/v1",
            reasoning: false,
            contextWindow: 128000,
            maxTokens: 16384
        )
        var options = AnthropicOptions()
        options.samplingParams = ["top_p": 0.9, "top_k": 40]
        let payload = try #require(await bCaptureAnthropicPayload(model, bUserContext("Hello"), options), "Expected payload to be captured before request failure")
        #expect(payload["top_p"] == nil)
        #expect(payload["top_k"] == nil)
    }
}
