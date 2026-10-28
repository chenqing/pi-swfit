import Foundation
import Testing
@testable import PiAI

// Port of packages/ai/test/openai-completions-provider-stream-event.test.ts

private func openRouterModel() -> Model {
    cModel(#"{"id":"openrouter/auto","name":"OpenRouter Auto","api":"openai-completions","provider":"openrouter","baseUrl":"https://openrouter.ai/api/v1","reasoning":false,"input":["text"],"cost":{"input":0,"output":0,"cacheRead":0,"cacheWrite":0},"contextWindow":200000,"maxTokens":8192}"#)
}

@Suite("openai-completions provider stream events")
struct OpenAICompletionsProviderStreamEventTests {
    // Regression test for #9784.
    @Test("exposes provider chunks including OpenRouter metadata")
    func exposesProviderChunks() async throws {
        let firstChunk = cJSON(#"{"id":"chatcmpl-1","model":"anthropic/claude-sonnet-4.6","choices":[{"index":0,"delta":{"content":"hello"}}]}"#)
        let finalChunk = cJSON(#"{"id":"chatcmpl-1","model":"anthropic/claude-sonnet-4.6","choices":[{"index":0,"delta":{},"finish_reason":"stop"}],"usage":{"prompt_tokens":10,"completion_tokens":2,"total_tokens":12,"cost":0.0012,"is_byok":false},"openrouter_metadata":{"strategy":"direct","region":"iad"}}"#)
        let server = CFakeServer { _, _ in cSSEResponse(cSSE([firstChunk, finalChunk]), headers: [("content-type", "text/event-stream"), ("x-request-id", "req-1")]) }
        let events = Locked<[JsonValue]>([])
        var options = SimpleStreamOptions()
        options.apiKey = "test"
        options.fetch = server.fetch
        options.onProviderStreamEvent = { data, _ in events.withLock { $0.append(data) } }

        let message = try await completeSimple(openRouterModel(), cUserContext("hi"), options)

        #expect(cContentJSON(message) == cJSON(#"[{"type":"text","text":"hello"}]"#))
        #expect(events.current == [firstChunk, finalChunk])
    }
}
