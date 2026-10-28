import Foundation
import Testing
@testable import PiAI

// Port of packages/ai/test/openai-completions-response-model.test.ts

private func openRouterAuto() -> Model {
    cModel(#"{"id":"openrouter/auto","name":"OpenRouter Auto","api":"openai-completions","provider":"openrouter","baseUrl":"https://openrouter.ai/api/v1","reasoning":false,"input":["text"],"cost":{"input":0,"output":0,"cacheRead":0,"cacheWrite":0},"contextWindow":200000,"maxTokens":8192}"#)
}

private func usage(_ prompt: Int, _ completion: Int) -> JsonValue {
    cJSON(#"{"prompt_tokens":\#(prompt),"completion_tokens":\#(completion),"prompt_tokens_details":{"cached_tokens":0},"completion_tokens_details":{"reasoning_tokens":0}}"#)
}

private func finalChunk(_ id: String, model: String?, _ prompt: Int, _ completion: Int) -> JsonValue {
    var chunk = cChunk([:], finishReason: "stop", id: id, model: model)
    chunk["usage"] = usage(prompt, completion)
    return chunk
}

private func run(_ chunks: [JsonValue]) async throws -> AssistantMessage {
    let server = CFakeServer(chunks: chunks)
    var options = StreamOptions()
    options.apiKey = "test"
    options.fetch = server.fetch
    return try await complete(openRouterAuto(), cUserContext("hi"), options)
}

@Suite("openai-completions responseModel")
struct OpenAICompletionsResponseModelTests {
    @Test("surfaces routed chunk.model on responseModel without changing model")
    func surfacesRoutedModel() async throws {
        let message = try await run([
            cChunk(["content": "hi"], id: "chatcmpl-1", model: "anthropic/claude-opus-4.8"),
            finalChunk("chatcmpl-1", model: "anthropic/claude-opus-4.8", 10, 5),
        ])
        #expect(message.model == "openrouter/auto")
        #expect(message.responseModel == "anthropic/claude-opus-4.8")
        #expect(message.provider == "openrouter")
        #expect(message.stopReason == .stop)
    }

    @Test("leaves responseModel undefined when chunks echo the requested id")
    func echoedId() async throws {
        let message = try await run([
            cChunk(["content": "hi"], id: "chatcmpl-2", model: "openrouter/auto"),
            finalChunk("chatcmpl-2", model: "openrouter/auto", 1, 1),
        ])
        #expect(message.model == "openrouter/auto")
        #expect(message.responseModel == nil)
    }

    @Test("ignores empty or missing chunk.model")
    func emptyOrMissingModel() async throws {
        let message = try await run([
            cChunk(["content": "hi"], id: "chatcmpl-3"),
            cChunk(["content": "!"], id: "chatcmpl-3", model: ""),
            finalChunk("chatcmpl-3", model: nil, 1, 2),
        ])
        #expect(message.model == "openrouter/auto")
        #expect(message.responseModel == nil)
    }
}
