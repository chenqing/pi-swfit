import Foundation
import Testing
@testable import PiAI

// Port of packages/ai/test/openai-responses-usage-limit.test.ts

private let usageLimitError: JsonObject = [
    "code": "subscription_sharing_usage_limit_exceeded",
    "message": "Usage limit reached.",
]

private let model = Model(id: "gpt-5-mini", name: "GPT-5 Mini", api: "openai-responses", provider: "openai",
                          baseUrl: "https://api.openai.com/v1", reasoning: true, input: ["text"],
                          contextWindow: 400000, maxTokens: 128000)

private func getErrorMessage(_ response: @escaping @Sendable () -> FetchResponse) async -> String? {
    var options = StreamOptions()
    options.apiKey = "test"
    options.fetch = { _ in response() }
    let context = normalizeContext(Context(systemPrompt: "", messages: [.user(UserMessage(content: .blocks([.text(TextContent(text: "hi"))]), timestamp: 0))], tools: []))
    let result = await streamOpenAIResponses(model, context, options).result()
    #expect(result.stopReason == .error)
    return result.errorMessage
}

@Suite struct OpenAIResponsesChatGPTUsageLimitTests {
    @Test func linksToChatGPTUsageWhenTheRequestIsRejected() async {
        var error = usageLimitError
        error["type"] = "rate_limit_error"
        let body = JsonValue.object(["error": .object(error)]).serialized()
        let errorMessage = await getErrorMessage {
            FetchResponse(status: 429, headers: Headers([("content-type", "application/json")]), body: .data(Data(body.utf8)))
        } ?? ""

        #expect(errorMessage.contains("subscription_sharing_usage_limit_exceeded"))
        #expect(errorMessage.contains("Check your ChatGPT usage: https://chatgpt.com/settings/usage"))
    }

    @Test func linksToChatGPTUsageWhenTheStreamFails() async {
        let event: JsonValue = [
            "type": "response.failed", "sequence_number": 0,
            "response": ["id": "resp_failed", "status": "failed", "error": .object(usageLimitError)],
        ]
        let sse = "event: response.failed\ndata: \(event.serialized())\n\n"
        let errorMessage = await getErrorMessage {
            FetchResponse(status: 200, headers: Headers([("content-type", "text/event-stream")]), body: .data(Data(sse.utf8)))
        } ?? ""

        #expect(errorMessage.contains("subscription_sharing_usage_limit_exceeded: Usage limit reached."))
        #expect(errorMessage.contains("Check your ChatGPT usage: https://chatgpt.com/settings/usage"))
    }
}
