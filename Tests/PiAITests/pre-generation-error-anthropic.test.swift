import Foundation
import Testing
@testable import PiAI

// Port of the anthropic-messages case of packages/ai/test/pre-generation-error.test.ts
// Upstream `streamSimple` throws synchronously; the Swift `streamSimpleAnthropicMessages` cannot throw and
// instead returns a stream that ends with that error (see the note in api/anthropic-messages.swift). The port
// asserts the same message on the error result and that no request is sent.
// Not ported: the azure, google, mistral, codex, openai-completions and openai-responses cases (other adapters).

@Suite("direct API authentication - anthropic-messages")
struct PreGenerationErrorAnthropicTests {
    @Test("throws synchronously when auth is missing")
    func missingAuth() async {
        let model = bModel(
            id: "test-model",
            name: "Test",
            provider: "test-provider",
            baseUrl: "https://example.invalid",
            reasoning: false,
            contextWindow: 1_000,
            maxTokens: 100
        )
        let requests = BRequests()
        var options = SimpleStreamOptions()
        options.fetch = bFetch(requests: requests)
        let result = await streamSimpleAnthropicMessages(model, normalizeContext(Context(messages: [])), options).result()
        #expect(result.stopReason == .error)
        #expect(result.errorMessage?.contains("No API key for provider: test-provider") == true)
        #expect(requests.count == 0)
    }
}
