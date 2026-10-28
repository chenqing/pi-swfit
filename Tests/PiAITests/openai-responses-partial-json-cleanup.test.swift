import Foundation
import Testing
@testable import PiAI

// Port of packages/ai/test/openai-responses-partial-json-cleanup.test.ts
// Swift keeps `partialJson` in a side table, never on the block, so "not persisted" is checked by the
// emitted `toolcall_end` call equalling the persisted block.

private let model = Model(id: "gpt-5-mini", name: "GPT-5 Mini", api: "openai-responses", provider: "openai",
                          baseUrl: "https://api.openai.com/v1", reasoning: true, input: ["text"],
                          contextWindow: 400000, maxTokens: 128000)

private func functionCallEvents(_ argumentsJson: String) -> [JsonValue] {
    [
        ["type": "response.output_item.added", "item": [
            "type": "function_call", "id": "fc_test", "call_id": "call_test", "name": "edit", "arguments": "",
        ]],
        ["type": "response.function_call_arguments.delta", "delta": "{\"path\":\"README.md\""],
        ["type": "response.function_call_arguments.delta", "delta": ",\"content\":\"updated\"}"],
        ["type": "response.function_call_arguments.done", "arguments": .string(argumentsJson)],
        ["type": "response.output_item.done", "item": [
            "type": "function_call", "id": "fc_test", "call_id": "call_test", "name": "edit", "arguments": .string(argumentsJson),
        ]],
        ["type": "response.completed", "sequence_number": 5, "response": ["id": "resp_test", "status": "completed"]],
    ]
}

@Suite struct OpenAIResponsesPartialJsonCleanupTests {
    @Test func removesPartialJsonFromPersistedToolCallBlocksAtOutputItemDone() async throws {
        var output = dEmptyOutput(model)
        let stream = AssistantMessageEventStream()
        let argumentsJson = "{\"path\":\"README.md\",\"content\":\"updated\"}"

        try await processResponsesStream(dEvents(functionCallEvents(argumentsJson)), &output, stream, model)
        stream.end(output)

        #expect(output.content.count == 1)
        let persistedToolCall = try #require(output.content.first?.toolCallContent)
        #expect(persistedToolCall.arguments == ["path": "README.md", "content": "updated"])

        var toolCallEnd: ToolCall?
        for await event in stream {
            if case .toolcallEnd(_, let toolCall, _) = event { toolCallEnd = toolCall }
        }
        #expect(toolCallEnd != nil)
        #expect(toolCallEnd == persistedToolCall)
    }

    // #10897
    @Test func marksMalformedFinalArgumentsInsteadOfKeepingTheParsedPrefix() async throws {
        var output = dEmptyOutput(model)
        let argumentsJson = "{\"path\":\"README.md\",\"content\":\"updated\",\"mode\":.5}"

        try await processResponsesStream(dEvents(functionCallEvents(argumentsJson)), &output, AssistantMessageEventStream(), model)

        let toolCall = try #require(output.content.first?.toolCallContent)
        #expect(toolCall.arguments == [:])
        #expect(toolCall.argumentsError?.hasSuffix("Received arguments:\n\(argumentsJson)") == true)
    }
}
