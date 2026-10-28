import Foundation
import Testing
@testable import PiAI

// Port of packages/ai/test/openai-completions-cache-control-format.test.ts

private let readTool = Tool(name: "read", description: "Read a file", parameters: cObjectSchema([("path", "string")]))

private func capturePayload(_ model: Model, cacheRetention: CacheRetention? = nil, messages: [Message]? = nil) async -> JsonValue {
    let context = Context(
        systemPrompt: "System prompt",
        messages: messages ?? [.user(UserMessage(content: .string("Hello")))],
        tools: [readTool]
    )
    return await cRunDirect(model, context) { options in
        options.apiKey = "test-key"
        options.cacheRetention = cacheRetention
    }.payload
}

private func instructionMessage(_ params: JsonValue) -> JsonValue? {
    params["messages"]?.arrayValue?.first { $0["role"] == "system" || $0["role"] == "developer" }
}

private func expectAnthropicCacheMarkers(_ params: JsonValue) {
    let instruction = instructionMessage(params)
    #expect(instruction != nil)
    #expect(instruction?["content"]?.arrayValue != nil)
    #expect(instruction?["content"]?[0]?["cache_control"] == ["type": "ephemeral"])

    #expect(params["tools"]?.arrayValue?.count == 1)
    #expect(params["tools"]?[0]?["cache_control"] == ["type": "ephemeral"])

    let last = params["messages"]?.arrayValue?.last
    #expect(last?["role"] == "user")
    #expect(last?["content"]?.arrayValue != nil)
    #expect(last?["content"]?[0]?["cache_control"] == ["type": "ephemeral"])
}

private func customQwen() -> Model {
    cModel(#"{"id":"custom-qwen","name":"Custom Qwen","api":"openai-completions","provider":"openrouter","baseUrl":"https://example.com/v1","reasoning":true,"input":["text"],"cost":{"input":0,"output":0,"cacheRead":0,"cacheWrite":0},"contextWindow":128000,"maxTokens":32000,"compat":{"cacheControlFormat":"anthropic"}}"#)
}

@Suite("openai-completions cacheControlFormat")
struct OpenAICompletionsCacheControlFormatTests {
    @Test("applies Anthropic-style cache markers when model compat enables them")
    func appliesMarkers() async {
        expectAnthropicCacheMarkers(await capturePayload(customQwen()))
    }

    @Test("preserves Anthropic-style cache markers for OpenRouter Anthropic batch aliases")
    func openRouterBatchAliases() async {
        expectAnthropicCacheMarkers(await capturePayload(cBuiltin("openrouter", "anthropic/claude-fable-5.1:batch")))
    }

    @Test("moves the conversation cache marker to a tool result")
    func markerOnToolResult() async {
        let model = cBuiltin("openrouter", "anthropic/claude-fable-5.1:batch")
        let messages = cMessages(#"""
        [{"role":"user","content":"Read the file"},
         {"role":"assistant","content":[{"type":"toolCall","id":"call_1","name":"read","arguments":{"path":"README.md"}}],"api":"openai-completions","provider":"openrouter","model":"\#(model.id)","stopReason":"toolUse"},
         {"role":"toolResult","toolCallId":"call_1","toolName":"read","content":[{"type":"text","text":"file contents"}],"isError":false}]
        """#)
        let params = await capturePayload(model, messages: messages)

        let user = params["messages"]?.arrayValue?.first { $0["role"] == "user" }
        #expect(user?["content"] == "Read the file")

        let tool = params["messages"]?.arrayValue?.last
        #expect(tool?["role"] == "tool")
        #expect(tool?["content"]?.arrayValue != nil)
        #expect(tool?["content"]?[0]?["cache_control"] == ["type": "ephemeral"])
    }

    @Test("omits Anthropic-style cache markers when cacheRetention is none")
    func omitsMarkersWhenNone() async {
        let params = await capturePayload(customQwen(), cacheRetention: CacheRetention.none)
        #expect(instructionMessage(params)?["content"]?.arrayValue == nil)
        #expect(params["tools"]?[0]?["cache_control"] == nil)
        #expect(params["messages"]?.arrayValue?.last?["content"]?.stringValue != nil)
    }
}
