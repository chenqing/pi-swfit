import Foundation
import Testing
@testable import PiAI

// Port of packages/ai/test/openai-completions-thinking-as-text.test.ts
// Swift: the upstream local `http` server is replaced by the fake fetch (the request still goes through
// the real SDK and must target POST /chat/completions).

private let compat = ResolvedOpenAICompletionsCompat(
    supportsStore: true, supportsDeveloperRole: true, supportsReasoningEffort: true, supportsUsageInStreaming: true,
    supportsFinishReason: true, maxTokensField: .maxCompletionTokens, requiresToolResultName: false,
    requiresAssistantAfterToolResult: false, requiresThinkingAsText: true, requiresReasoningContentOnAssistantMessages: false,
    thinkingFormat: .openai, zaiToolStream: false, supportsStrictMode: true, supportsOpenAIGrammarTools: false,
    sendSessionAffinityHeaders: false, sessionAffinityFormat: .openai, supportsLongCacheRetention: true,
    supportsThinkingTokenBudget: false, supportsMidConvoSystemMessages: false, supportsMidConvoToolAdditions: false
)

/// The same compat as model JSON (what `getCompat` resolves to the struct above).
private let compatJSON = #"{"supportsStore":true,"supportsDeveloperRole":true,"supportsReasoningEffort":true,"supportsUsageInStreaming":true,"supportsFinishReason":true,"maxTokensField":"max_completion_tokens","requiresToolResultName":false,"requiresAssistantAfterToolResult":false,"requiresThinkingAsText":true,"requiresReasoningContentOnAssistantMessages":false,"thinkingFormat":"openai","openRouterRouting":{},"vercelGatewayRouting":{},"chatTemplateKwargs":{},"chatTemplateArgs":{},"zaiToolStream":false,"supportsThinkingTokenBudget":false,"supportsStrictMode":true,"supportsOpenAIGrammarTools":false,"supportsMidConvoSystemMessages":false,"supportsMidConvoToolAdditions":false,"sendSessionAffinityHeaders":false,"sessionAffinityFormat":"openai","supportsLongCacheRetention":true}"#

private func buildModel(_ baseUrl: String = "http://127.0.0.1:1") -> Model {
    cModel(#"{"id":"repro-model","name":"Repro Model","api":"openai-completions","provider":"repro-provider","baseUrl":"\#(baseUrl)","reasoning":true,"input":["text"],"cost":{"input":0,"output":0,"cacheRead":0,"cacheWrite":0},"contextWindow":128000,"maxTokens":4096,"compat":\#(compatJSON)}"#)
}

private func buildAssistant(_ content: [AssistantContent]) -> AssistantMessage {
    AssistantMessage(content: content, api: "openai-completions", provider: "repro-provider", model: "repro-model", usage: Usage(), stopReason: .stop, timestamp: 2)
}

private func buildContext(_ assistant: AssistantMessage) -> Context {
    Context(messages: [
        .user(UserMessage(content: .string("hello"), timestamp: 1)),
        .assistant(assistant),
        .user(UserMessage(content: .string("continue"), timestamp: 3)),
    ])
}

private let thinkingAndText: [AssistantContent] = [.thinking(ThinkingContent(thinking: "internal reasoning")), .text(TextContent(text: "visible answer"))]

@Suite("openai-completions thinking-as-text replay")
struct OpenAICompletionsThinkingAsTextTests {
    @Test("serializes same-model thinking-plus-text replay as assistant text parts")
    func thinkingPlusText() throws {
        let messages = try convertMessages(buildModel(), normalizeContext(buildContext(buildAssistant(thinkingAndText))), compat)
        #expect(JsonValue.object(messages[1]) == cJSON(#"{"role":"assistant","content":[{"type":"text","text":"internal reasoning"},{"type":"text","text":"visible answer"}]}"#))
    }

    @Test("serializes same-model thinking-only replay as assistant text parts")
    func thinkingOnly() throws {
        let messages = try convertMessages(buildModel(), normalizeContext(buildContext(buildAssistant([.thinking(ThinkingContent(thinking: "internal reasoning"))]))), compat)
        #expect(JsonValue.object(messages[1]) == cJSON(#"{"role":"assistant","content":[{"type":"text","text":"internal reasoning"}]}"#))
    }

    @Test("reaches the endpoint when replay contains both thinking and text")
    func reachesEndpoint() async throws {
        let chunks = [
            cJSON(#"{"id":"chatcmpl-repro","object":"chat.completion.chunk","created":0,"model":"repro-model","choices":[{"index":0,"delta":{"role":"assistant","content":"ok"},"finish_reason":null}]}"#),
            cJSON(#"{"id":"chatcmpl-repro","object":"chat.completion.chunk","created":0,"model":"repro-model","choices":[{"index":0,"delta":{},"finish_reason":"stop"}],"usage":{"prompt_tokens":1,"completion_tokens":1}}"#),
        ]
        let server = CFakeServer { request, _ in
            guard request.method == "POST", request.url.path == "/chat/completions" else {
                return cSSEResponse("", status: 404, headers: [])
            }
            return cSSEResponse(cSSE(chunks))
        }
        let run = await cRunDirect(buildModel("http://127.0.0.1:4100"), buildContext(buildAssistant(thinkingAndText)), { $0.apiKey = "test-key" }, server: server)

        #expect(server.requests.count == 1)
        #expect(server.body()["messages"]?[1] == cJSON(#"{"role":"assistant","content":[{"type":"text","text":"internal reasoning"},{"type":"text","text":"visible answer"}]}"#))
        #expect(run.events.last?.type == "done")
    }
}
