import Foundation
import Testing
@testable import PiAI

// Port of packages/ai/test/azure-openai-responses-reasoning-replay.test.ts

private let model = Model(id: "gpt-5-mini", name: "GPT-5 Mini", api: "azure-openai-responses", provider: "azure",
                          baseUrl: "https://example.invalid", reasoning: true, input: ["text"],
                          contextWindow: 400000, maxTokens: 128000)

private func createEvents(_ doneItem: JsonValue, _ completedItem: JsonValue) -> [JsonValue] {
    [
        ["type": "response.output_item.added", "output_index": 0, "sequence_number": 0,
         "item": ["type": "reasoning", "id": doneItem["id"]!, "summary": []]],
        ["type": "response.output_item.done", "output_index": 0, "sequence_number": 1, "item": doneItem],
        ["type": "response.completed", "sequence_number": 2,
         "response": ["id": "resp_test", "status": "completed", "output": [completedItem]]],
    ]
}

private func getReplayedReasoning(_ assistant: AssistantMessage) throws -> JsonValue? {
    let context = normalizeContext(Context(messages: [
        .user(UserMessage(content: "first", timestamp: dateNow() - 1)),
        .assistant(assistant),
        .user(UserMessage(content: "follow-up", timestamp: dateNow())),
    ]))
    return try convertResponsesMessages(model, context, ["azure"]).first { $0["type"] == "reasoning" }
}

@Suite struct AzureOpenAIResponsesReasoningReplayTests {
    @Test func preservesExistingEncryptedContentFromOutputItemDone() async throws {
        var output = dEmptyOutput(model)
        let doneItem: JsonValue = ["type": "reasoning", "id": "rs_done", "summary": [], "encrypted_content": "from-output-item-done"]
        var completedItem = doneItem
        completedItem["encrypted_content"] = "from-response-completed"

        try await processResponsesStream(dEvents(createEvents(doneItem, completedItem)), &output, AssistantMessageEventStream(), model)

        let replayed = try getReplayedReasoning(output)
        #expect(replayed?["type"] == "reasoning")
        #expect(replayed?["id"] == "rs_done")
        #expect(replayed?["encrypted_content"] == "from-output-item-done")
    }

    @Test func fillsEncryptedContentWhenOutputItemDoneOmittedIt() async throws {
        var output = dEmptyOutput(model)
        let doneItem: JsonValue = ["type": "reasoning", "id": "rs_missing", "summary": []]
        var completedItem = doneItem
        completedItem["encrypted_content"] = "from-response-completed"

        try await processResponsesStream(dEvents(createEvents(doneItem, completedItem)), &output, AssistantMessageEventStream(), model)

        let replayed = try getReplayedReasoning(output)
        #expect(replayed?["type"] == "reasoning")
        #expect(replayed?["id"] == "rs_missing")
        #expect(replayed?["encrypted_content"] == "from-response-completed")
    }
}
