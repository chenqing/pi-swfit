import Foundation
import Testing
@testable import PiAI

// Port of packages/ai/test/azure-openai-tool-choice.test.ts

private let model = Model(id: "test-deployment", name: "Test Deployment", api: "azure-openai-responses", provider: "azure",
                          baseUrl: "http://127.0.0.1:9/openai/v1", reasoning: false, input: ["text"],
                          contextWindow: 10_000, maxTokens: 1_000)

private func context() -> TranscriptContext {
    normalizeContext(Context(
        messages: [.user(UserMessage(content: "Summarize this", timestamp: 1))],
        tools: [Tool(name: "read", description: "Read a file", parameters: dStringObjectSchema(["path"]))]
    ))
}

private func capturingOptions(_ payload: Locked<JsonValue?>) -> StreamOptions {
    var options = StreamOptions()
    options.apiKey = "test-key"
    options.onPayload = { requestPayload, _ in
        payload.withLock { $0 = requestPayload }
        throw PiError("payload captured")
    }
    return options
}

@Suite struct AzureOpenAIToolChoiceTests {
    @Test func forwardsProviderSpecificToolChoiceWhilePreservingToolDefinitions() async {
        let payload = Locked<JsonValue?>(nil)
        var options = capturingOptions(payload)
        options.extra["toolChoice"] = "required"
        _ = await streamAzureOpenAIResponses(model, context(), options).result()

        #expect(payload.current?["tool_choice"] == "required")
        #expect(payload.current?["tools"]?.arrayValue?.count == 1)
    }

    @Test func forwardsProviderNeutralToolChoiceFromSimpleOptions() async {
        let payload = Locked<JsonValue?>(nil)
        var options = capturingOptions(payload)
        options.toolChoice = "none"
        _ = await streamSimpleAzureOpenAIResponses(model, context(), options).result()

        #expect(payload.current?["tool_choice"] == "none")
        #expect(payload.current?["tools"]?.arrayValue?.count == 1)
    }
}
