import Foundation
import Testing
@testable import PiAI

// Port of packages/ai/test/openai-responses-namespace.test.ts

private let model = Model(id: "gpt-5.4", name: "GPT-5.4", api: "openai-responses", provider: "openai",
                          baseUrl: "https://api.openai.com/v1", reasoning: true, input: ["text"],
                          contextWindow: 400000, maxTokens: 128000)

private let functionCallEvents: [JsonValue] = [
    ["type": "response.output_item.added", "sequence_number": 0, "output_index": 0, "item": [
        "type": "function_call", "id": "fc_test", "call_id": "call_test", "name": "lookup", "arguments": "",
    ]],
    ["type": "response.output_item.done", "sequence_number": 1, "output_index": 0, "item": [
        "type": "function_call", "id": "fc_test", "call_id": "call_test", "name": "lookup",
        "arguments": "{\"value\":\"hello\"}", "namespace": "dynamic_tools",
    ]],
    ["type": "response.completed", "sequence_number": 2, "response": ["id": "resp_test", "status": "completed"]],
]

private let customToolCallEvents: [JsonValue] = [
    ["type": "response.output_item.added", "sequence_number": 0, "output_index": 0, "item": [
        "type": "custom_tool_call", "id": "ctc_test", "call_id": "call_test", "name": "query", "input": "",
    ]],
    ["type": "response.output_item.done", "sequence_number": 1, "output_index": 0, "item": [
        "type": "custom_tool_call", "id": "ctc_test", "call_id": "call_test", "name": "query",
        "input": "hello", "namespace": "dynamic_tools",
    ]],
    ["type": "response.completed", "sequence_number": 2, "response": ["id": "resp_test", "status": "completed"]],
]

private func getToolCall(_ output: AssistantMessage) throws -> ToolCall {
    guard let call = output.content.first?.toolCallContent else { throw PiError("Expected toolCall block") }
    return call
}

private func replay(_ target: Model, _ output: AssistantMessage, _ grammar: [String: String]? = nil) throws -> [JsonValue] {
    try convertResponsesMessages(
        target,
        normalizeContext(Context(messages: [.assistant(output)])),
        ["openai"],
        grammar.map { ConvertResponsesMessagesOptions(grammarToolInputProperties: $0) }
    )
}

@Suite struct OpenAIResponsesTerminalMessagesTests {
    @Test func omitsAnAbsentErrorMessage() async throws {
        var output = dEmptyOutput(model)
        try await processResponsesStream(dEvents(functionCallEvents), &output, AssistantMessageEventStream(), model)
        #expect(output.errorMessage == nil)
    }
}

@Suite struct OpenAIResponsesToolCallNamespacesTests {
    @Test func roundTripsAFunctionNamespaceReceivedOnlyOnOutputItemDone() async throws {
        var output = dEmptyOutput(model)
        try await processResponsesStream(dEvents(functionCallEvents), &output, AssistantMessageEventStream(), model)

        let toolCall = try getToolCall(output)
        #expect(toolCall.id == "call_test|fc_test")
        #expect(toolCall.name == "lookup")
        #expect(toolCall.arguments == ["value": "hello"])
        #expect(toolCall.namespace == "dynamic_tools")

        let replayed = try replay(model, output).first { $0["type"] == "function_call" }
        #expect(replayed?["type"] == "function_call")
        #expect(replayed?["id"] == "fc_test")
        #expect(replayed?["call_id"] == "call_test")
        #expect(replayed?["name"] == "lookup")
        #expect(replayed?["arguments"] == "{\"value\":\"hello\"}")
        #expect(replayed?["namespace"] == "dynamic_tools")
    }

    @Test func roundTripsACustomToolNamespaceReceivedOnlyOnOutputItemDone() async throws {
        var output = dEmptyOutput(model)
        let grammarToolInputProperties = ["query": "input"]
        try await processResponsesStream(dEvents(customToolCallEvents), &output, AssistantMessageEventStream(), model,
                                         OpenAIResponsesStreamOptions(grammarToolInputProperties: grammarToolInputProperties))

        let toolCall = try getToolCall(output)
        #expect(toolCall.id == "call_test|ctc_test")
        #expect(toolCall.name == "query")
        #expect(toolCall.arguments == ["input": "hello"])
        #expect(toolCall.namespace == "dynamic_tools")

        let replayed = try replay(model, output, grammarToolInputProperties).first { $0["type"] == "custom_tool_call" }
        #expect(replayed?["type"] == "custom_tool_call")
        #expect(replayed?["id"] == "ctc_test")
        #expect(replayed?["call_id"] == "call_test")
        #expect(replayed?["name"] == "query")
        #expect(replayed?["input"] == "hello")
        #expect(replayed?["namespace"] == "dynamic_tools")
    }

    @Test func dropsNamespacesWhenTheTargetCannotReplayTheirLoadItems() throws {
        var output = dEmptyOutput(model)
        output.content.append(.toolCall(ToolCall(id: "call_function|fc_test", name: "lookup", arguments: ["value": "hello"], namespace: "dynamic_tools")))
        output.content.append(.toolCall(ToolCall(id: "call_custom|ctc_test", name: "query", arguments: ["input": "hello"], namespace: "dynamic_tools")))

        var gpt52 = model
        gpt52.id = "gpt-5.2"; gpt52.name = "GPT-5.2"
        var azure = model
        azure.provider = "azure"
        var spark = model
        spark.api = "openai-codex-responses"; spark.provider = "openai-codex"
        spark.id = "gpt-5.3-codex-spark"; spark.name = "GPT-5.3 Codex Spark"

        for targetModel in [gpt52, azure, spark] {
            let replayed = try replay(targetModel, output, ["query": "input"])
            let functionCall = replayed.first { $0["type"] == "function_call" }
            let customToolCall = replayed.first { $0["type"] == "custom_tool_call" }
            #expect(functionCall != nil)
            #expect(functionCall?["namespace"] == nil)
            #expect(customToolCall != nil)
            #expect(customToolCall?["namespace"] == nil)
        }
    }

    @Test func doesNotAddANamespaceToOrdinaryFunctionCalls() throws {
        var output = dEmptyOutput(model)
        output.content.append(.toolCall(ToolCall(id: "call_test|fc_test", name: "lookup", arguments: ["value": "hello"])))

        let replayed = try replay(model, output).first { $0["type"] == "function_call" }
        #expect(replayed != nil)
        #expect(replayed?["namespace"] == nil)
    }
}
