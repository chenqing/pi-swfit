import Foundation
import Testing
@testable import PiAI

// Port of packages/ai/test/openai-responses-mid-convo-effort.test.ts

private let thinkingLevelMap: ThinkingLevelMap = [
    .off: "none", .minimal: String?.none, .low: "low", .medium: "medium", .high: "high", .xhigh: "xhigh", .max: "max",
]

private func openAIModel(_ compat: JsonObject = ["supportsMidConvoEffort": true]) -> Model {
    var model = Model(id: "gpt-6-luna", name: "GPT-6 Luna", api: "openai-responses", provider: "openai",
                      baseUrl: "https://api.openai.com/v1", reasoning: true, input: ["text"],
                      contextWindow: 272000, maxTokens: 128000, compat: compat)
    model.thinkingLevelMap = thinkingLevelMap
    return model
}

private func user(_ text: String) -> Message { .user(UserMessage(content: .string(text), timestamp: 0)) }

private func toolResult(_ callId: String) -> Message {
    .toolResult(ToolResultMessage(toolCallId: callId, toolName: "lookup", content: [.text(TextContent(text: "result"))], isError: false, timestamp: 0))
}

private func update(_ effort: String) -> JsonValue { ["type": "configuration_update", "reasoning": ["effort": .string(effort)]] }

private func responseEvents(_ responseId: String, _ withToolCall: Bool) -> [JsonValue] {
    let item: JsonValue = withToolCall
        ? ["type": "function_call", "id": "fc_1", "call_id": "call_1", "name": "lookup", "arguments": "{}", "status": "completed"]
        : ["type": "message", "id": .string("msg_\(responseId)"), "role": "assistant", "status": "completed",
           "content": [["type": "output_text", "text": "answer", "annotations": []]]]
    return [
        ["type": "response.created", "response": ["id": .string(responseId)]],
        ["type": "response.output_item.added", "output_index": 0, "item": item],
        ["type": "response.output_item.done", "output_index": 0, "item": item],
        ["type": "response.completed", "response": ["id": .string(responseId), "status": "completed"]],
    ]
}

private func runOpenAI(
    _ messages: [Message],
    _ reasoningEffort: String?,
    apiKey: String = "sk-test",
    model: Model = openAIModel(),
    withToolCall: Bool = false
) async throws -> (payload: JsonValue, message: AssistantMessage) {
    let recorder = DRecorder()
    let sse = responseEvents("resp_1", withToolCall).map { "data: \($0.serialized())\n\n" }.joined()
    var options = StreamOptions()
    options.apiKey = apiKey
    options.extra["reasoningEffort"] = reasoningEffort.map(JsonValue.string)
    options.fetch = dSSEFetch(recorder, sse)
    let message = await streamOpenAIResponses(model, normalizeContext(Context(messages: messages)), options).result()
    let payload = try #require(recorder.last?.body, "Request payload was not captured")
    #expect(message.stopReason != .error)
    return (payload, message)
}

private func inputOf(_ payload: JsonValue) -> [JsonValue] { payload["input"]?.arrayValue ?? [] }

@Suite struct OpenAIResponsesConfigurationUpdateTests {
    @Test func keepsReasoningEffortConstantAndOnlyAppendsInputWhenTheLevelChanges() async throws {
        var history: [Message] = [user("one")]
        let first = try await runOpenAI(history, "high")
        history.append(contentsOf: [.assistant(first.message), user("two")])
        let second = try await runOpenAI(history, "high")
        history.append(contentsOf: [.assistant(second.message), user("three")])
        let third = try await runOpenAI(history, "low")

        #expect(inputOf(first.payload) == [
            ["role": "user", "content": [["type": "input_text", "text": "one"]]],
            update("high"),
        ])
        for run in [first, second, third] {
            #expect(run.payload["reasoning"]?["effort"] == "medium")
        }
        #expect(Array(inputOf(second.payload).prefix(inputOf(first.payload).count)) == inputOf(first.payload))
        #expect(Array(inputOf(third.payload).prefix(inputOf(second.payload).count)) == inputOf(second.payload))
        #expect(inputOf(third.payload).filter { $0["type"] == "configuration_update" } == [update("high"), update("high"), update("low")])
        #expect(inputOf(third.payload).last == update("low"))
        #expect([first, second, third].map(\.message.providerThinkingLevel) == ["high", "high", "low"])
    }

    @Test func appliesALevelChangeMadeDuringAToolLoopToTheNextReply() async throws {
        var history: [Message] = [user("one")]
        let toolCall = try await runOpenAI(history, "high", withToolCall: true)
        history.append(contentsOf: [.assistant(toolCall.message), toolResult("call_1|fc_1")])
        let afterTool = try await runOpenAI(history, "low")

        let input = inputOf(afterTool.payload)
        #expect(Array(input.prefix(inputOf(toolCall.payload).count)) == inputOf(toolCall.payload))
        let lastTwo = Array(input.suffix(2))
        #expect(lastTwo.count == 2)
        #expect(lastTwo.first?["type"] == "function_call_output")
        #expect(lastTwo.first?["call_id"] == "call_1")
        #expect(lastTwo.last == update("low"))
        #expect(afterTool.message.providerThinkingLevel == "low")
    }

    @Test func addsItemsOnlyBeforeRepliesRecordedByThisModel() async throws {
        let unstamped = try await runOpenAI([user("one")], "high", model: openAIModel([:])).message
        var otherProvider = unstamped
        otherProvider.provider = "opencode"; otherProvider.providerThinkingLevel = "high"
        var otherModel = unstamped
        otherModel.model = "gpt-6-sol"; otherModel.providerThinkingLevel = "high"
        var recorded = unstamped
        recorded.providerThinkingLevel = "high"

        let (payload, _) = try await runOpenAI([
            user("one"), .assistant(unstamped),
            user("two"), .assistant(otherProvider),
            user("three"), .assistant(otherModel),
            user("four"), .assistant(recorded),
            user("five"),
        ], "low")

        #expect(inputOf(payload).map { ($0["type"] ?? $0["role"])?.stringValue } == [
            "user", "message", "user", "message", "user", "message", "user",
            "configuration_update", "message", "user", "configuration_update",
        ])
        #expect(inputOf(payload).filter { $0["type"] == "configuration_update" } == [update("high"), update("low")])
    }

    @Test(arguments: [
        ("Sign in with ChatGPT", "chatgpt-access-token", openAIModel(), "low", "low"),
        ("the compat flag turned off", "sk-test", openAIModel(["supportsMidConvoEffort": false]), "low", "low"),
        ("thinking off", "sk-test", openAIModel(), nil, "none"),
    ] as [(String, String, Model, String?, String)])
    func sendsTheLevelAsReasoningEffort(_ name: String, _ apiKey: String, _ model: Model, _ level: String?, _ effort: String) async throws {
        let first = try await runOpenAI([user("one")], "high", apiKey: apiKey, model: model)
        let (payload, message) = try await runOpenAI([user("one"), .assistant(first.message), user("two")], level, apiKey: apiKey, model: model)

        #expect(payload["reasoning"]?["effort"]?.stringValue == effort, "\(name)")
        #expect(!inputOf(payload).contains { $0["type"] == "configuration_update" }, "\(name)")
        #expect(message.providerThinkingLevel == nil, "\(name)")
    }
}
