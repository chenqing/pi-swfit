import Foundation
import Testing
@testable import PiAI

// Port of packages/ai/test/openai-responses-chatgpt-sign-in.test.ts

private let model = Model(id: "gpt-5-mini", name: "GPT-5 Mini", api: "openai-responses", provider: "openai",
                          baseUrl: "https://api.openai.com/v1", reasoning: true, input: ["text"],
                          contextWindow: 400000, maxTokens: 128000)

private func context() -> TranscriptContext {
    normalizeContext(Context(systemPrompt: "", messages: [.user(UserMessage(content: .blocks([.text(TextContent(text: "hi"))]), timestamp: 0))], tools: []))
}

private func capturePayload(_ apiKey: String, _ requestModel: Model = model) async throws -> JsonValue {
    let payload = Locked<JsonValue?>(nil)
    var options = StreamOptions()
    options.apiKey = apiKey
    options.maxTokens = 1000
    options.temperature = 0.5
    options.cacheRetention = .long
    options.onPayload = { params, _ in payload.withLock { $0 = params }; return nil }
    options.fetch = { _ in FetchResponse(status: 500, headers: Headers([]), body: .data(Data())) }
    _ = await streamOpenAIResponses(requestModel, context(), options).result()
    return try #require(payload.current, "Request payload was not captured")
}

@Suite struct OpenAIResponsesSignInWithChatGPTTests {
    @Test func omitsRequestFieldsThatTokenSharingRejects() async throws {
        let payload = try await capturePayload("chatgpt-access-token")
        #expect(payload["max_output_tokens"] == nil)
        #expect(payload["temperature"] == nil)
        #expect(payload["prompt_cache_retention"] == nil)
    }

    @Test func omitsPromptCacheOptionsOnModelsWithExplicitPromptCacheMode() async throws {
        var explicitCacheModel = model
        explicitCacheModel.compat = ["supportsExplicitPromptCacheMode": true]

        let signInPayload = try await capturePayload("chatgpt-access-token", explicitCacheModel)
        let apiKeyPayload = try await capturePayload("sk-proj-test", explicitCacheModel)

        #expect(signInPayload["prompt_cache_options"] == nil)
        #expect(apiKeyPayload["prompt_cache_options"] == ["ttl": "30m"])
    }

    @Test(arguments: [
        ("OpenAI API keys", "sk-proj-test", model),
        ("other OpenAI-compatible endpoints", "gateway-key", { var m = model; m.baseUrl = "https://gateway.example.com/v1"; return m }()),
    ] as [(String, String, Model)])
    func keepsThoseFields(_ name: String, _ apiKey: String, _ requestModel: Model) async throws {
        let payload = try await capturePayload(apiKey, requestModel)
        #expect(payload["max_output_tokens"] == 1000, "\(name)")
        #expect(payload["temperature"] == 0.5, "\(name)")
        #expect(payload["prompt_cache_retention"] == "24h", "\(name)")
    }
}
