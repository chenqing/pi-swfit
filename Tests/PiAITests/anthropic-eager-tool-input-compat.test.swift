import Foundation
import Testing
@testable import PiAI

// Port of packages/ai/test/anthropic-eager-tool-input-compat.test.ts
// The upstream local HTTP server (capturing headers and body, answering with an empty SSE stream) is
// replaced by a fake `fetch` doing the same.

private func createModel(_ compat: JsonObject? = nil) -> Model {
    var merged: JsonObject = ["forceAdaptiveThinking": true]
    for (key, value) in compat ?? [:] { merged[key] = value }
    return bModel(
        id: "claude-opus-4-8",
        name: "Claude Opus 4.8",
        provider: "test-anthropic",
        baseUrl: "http://127.0.0.1:9",
        reasoning: true,
        contextWindow: 200000,
        maxTokens: 32000,
        compat: merged
    )
}

private let tool = Tool(
    name: "lookup",
    description: "Look up a value",
    parameters: ["type": "object", "properties": ["value": ["type": "string"]], "required": ["value"]]
)

private func createContext(_ tools: [Tool] = [tool]) -> Context {
    bUserContext("Use the tool", tools: tools.isEmpty ? nil : tools)
}

private func captureAnthropicRequest(_ compat: JsonObject?, _ context: Context) async throws -> (headers: Headers, body: JsonObject) {
    var options = AnthropicOptions()
    options.apiKey = "test-key"
    options.cacheRetention = CacheRetention.none
    let run = await bRun(createModel(compat), context, options, response: "")
    let request = try #require(run.request, "Anthropic request was not captured")
    return (request.headers, try #require(run.body))
}

private func getFirstTool(_ body: JsonObject) throws -> JsonObject {
    try #require(body["tools"]?.arrayValue?.first?.objectValue, "Expected first tool in request body")
}

@Suite("Anthropic eager tool input streaming compatibility")
struct AnthropicEagerToolInputCompatTests {
    @Test("sends per-tool eager_input_streaming by default")
    func defaultEager() async throws {
        let request = try await captureAnthropicRequest(nil, createContext())
        #expect(try getFirstTool(request.body)["eager_input_streaming"] == true)
        #expect(request.headers.get("anthropic-beta") == nil)
    }

    @Test("uses the legacy fine-grained tool streaming beta when eager tool input streaming is disabled")
    func legacyBeta() async throws {
        let request = try await captureAnthropicRequest(["supportsEagerToolInputStreaming": false], createContext())
        #expect(try getFirstTool(request.body)["eager_input_streaming"] == nil)
        #expect(request.headers.get("anthropic-beta") == "fine-grained-tool-streaming-2025-05-14")
    }

    @Test("does not send the legacy fine-grained tool streaming beta when there are no tools")
    func noTools() async throws {
        let request = try await captureAnthropicRequest(["supportsEagerToolInputStreaming": false], createContext([]))
        #expect(request.body["tools"] == nil)
        #expect(request.headers.get("anthropic-beta") == nil)
    }
}
