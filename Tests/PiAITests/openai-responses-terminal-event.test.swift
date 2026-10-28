import Foundation
import Testing
@testable import PiAI

// Port of packages/ai/test/openai-responses-terminal-event.test.ts
// `vi.mock("openai")` becomes a fake fetch serving the mocked events as SSE.

private func createModel() -> Model {
    Model(id: "gpt-5-mini", name: "GPT-5 Mini", api: "openai-responses", provider: "openai",
          baseUrl: "https://api.openai.com/v1", reasoning: true, input: ["text"],
          contextWindow: 400000, maxTokens: 128000)
}

private let earlyEofEvents: [JsonValue] = [
    ["type": "response.created", "sequence_number": 0, "response": ["id": "resp_early_eof"]],
    ["type": "response.output_item.added", "sequence_number": 1, "output_index": 0,
     "item": ["type": "reasoning", "id": "rs_early_eof", "summary": []]],
    ["type": "response.reasoning_text.delta", "sequence_number": 2, "output_index": 0, "content_index": 0,
     "item_id": "rs_early_eof", "delta": "partial reasoning before the stream ends"],
]

private let wrapperEvents: [JsonValue] = [
    ["type": "response.created", "sequence_number": 0, "response": ["id": "resp_wrapper_early_eof"]],
    ["type": "response.output_item.added", "sequence_number": 1, "output_index": 0,
     "item": ["type": "reasoning", "id": "rs_wrapper_early_eof", "summary": []]],
    ["type": "response.reasoning_text.delta", "sequence_number": 2, "output_index": 0, "content_index": 0,
     "item_id": "rs_wrapper_early_eof", "delta": "partial reasoning before the wrapper stream ends"],
]

private let completedEvents: [JsonValue] = [
    ["type": "response.completed", "sequence_number": 0, "response": [
        "id": "resp_completed", "status": "completed",
        "usage": ["input_tokens": 20, "output_tokens": 7, "total_tokens": 27,
                  "input_tokens_details": ["cached_tokens": 2, "cache_write_tokens": 3]],
    ]],
]

private func incompleteEvents(_ reason: String = "max_output_tokens") -> [JsonValue] {
    [["type": "response.incomplete", "sequence_number": 0, "response": [
        "id": "resp_incomplete", "status": "incomplete",
        "incomplete_details": ["reason": .string(reason)],
        "usage": ["input_tokens": 30, "output_tokens": 12, "total_tokens": 42,
                  "input_tokens_details": ["cached_tokens": 5]],
    ]]]
}

private let failedEvents: [JsonValue] = [
    ["type": "response.failed", "sequence_number": 0, "response": [
        "id": "resp_failed", "status": "failed", "error": ["code": "server_error", "message": "boom"],
    ]],
]

private func phasedMessageEvents(_ phases: (String, String), _ terminalStatus: String = "completed") -> [JsonValue] {
    var events: [JsonValue] = [
        ["type": "response.output_item.added", "sequence_number": 0, "output_index": 0, "item": [
            "type": "message", "id": "msg_phase", "role": "assistant", "status": "in_progress",
            "content": [], "phase": .string(phases.0),
        ]],
        ["type": "response.output_item.done", "sequence_number": 1, "output_index": 0, "item": [
            "type": "message", "id": "msg_phase", "role": "assistant", "status": "completed",
            "content": [["type": "output_text", "text": "answer", "annotations": []]], "phase": .string(phases.1),
        ]],
    ]
    if terminalStatus == "incomplete" {
        events.append(["type": "response.incomplete", "sequence_number": 2, "response": [
            "id": "resp_phase", "status": "incomplete", "incomplete_details": ["reason": "max_output_tokens"],
        ]])
        return events
    }
    events.append(["type": "response.completed", "sequence_number": 2, "response": ["id": "resp_phase", "status": "completed"]])
    return events
}

private let unfinishedToolCallEvents: [JsonValue] = [
    ["type": "response.output_item.added", "sequence_number": 0, "output_index": 0,
     "item": ["type": "function_call", "id": "fc_1", "call_id": "call_1", "name": "bash", "arguments": ""]],
    ["type": "response.function_call_arguments.delta", "sequence_number": 1, "output_index": 0,
     "item_id": "fc_1", "delta": "{\"command\":\"rm -rf /tmp/build"],
    ["type": "response.completed", "sequence_number": 2, "response": ["id": "resp_unfinished", "status": "completed"]],
]

// llama.cpp omits output_index from every event and sends both done events after all deltas.
private let toolCallsWithoutOutputIndexEvents: [JsonValue] = {
    func call(_ n: String, _ arguments: String) -> JsonValue {
        ["type": "function_call", "id": .string("fc_\(n)"), "call_id": .string("call_\(n)"), "name": "bash", "arguments": .string(arguments)]
    }
    return [
        ["type": "response.output_item.added", "item": call("a", "")],
        ["type": "response.function_call_arguments.delta", "item_id": "fc_a", "delta": "{\"command\":\"echo a\"}"],
        ["type": "response.output_item.added", "item": call("b", "")],
        ["type": "response.function_call_arguments.delta", "item_id": "fc_b", "delta": "{\"command\":\"echo b\"}"],
        ["type": "response.output_item.done", "item": call("a", "{\"command\":\"echo a\"}")],
        ["type": "response.output_item.done", "item": call("b", "{\"command\":\"echo b\"}")],
        ["type": "response.completed", "response": ["id": "resp_no_output_index", "status": "completed"]],
    ]
}()

private func process(_ events: [JsonValue], _ model: Model = createModel()) async -> (output: AssistantMessage, error: (any Error)?, partialStopReasons: [StopReason]) {
    var output = dEmptyOutput(model)
    let stream = AssistantMessageEventStream()
    var caught: (any Error)?
    do { try await processResponsesStream(dEvents(events), &output, stream, model) } catch { caught = error }
    stream.end(output)
    var stopReasons: [StopReason] = []
    for await event in stream {
        switch event {
        case .done, .error: break
        default: stopReasons.append(event.message.stopReason)
        }
    }
    return (output, caught, stopReasons)
}

private func wrapperContext() -> TranscriptContext {
    normalizeContext(Context(systemPrompt: "", messages: [.user(UserMessage(content: .blocks([.text(TextContent(text: "hi"))]), timestamp: 0))], tools: []))
}

@Suite struct OpenAIResponsesTerminalEventHandlingTests {
    @Test func rejectsStreamsThatEndBeforeATerminalResponseEvent() async {
        let (_, error, _) = await process(earlyEofEvents)
        #expect(dErr(error) == "OpenAI Responses stream ended before a terminal response event")
    }

    @Test func rejectsCompletedStreamsWhoseToolCallNeverReceivedOutputItemDone() async {
        let (_, error, _) = await process(unfinishedToolCallEvents)
        #expect(dErr(error).contains("OpenAI Responses stream completed with an unfinished tool call: bash (call_1|fc_1)"))
    }

    // https://github.com/earendil-works/pi/issues/9974
    @Test func rejectsParallelToolCallsWithoutOutputIndexInsteadOfRunningMixedUpCalls() async {
        let (_, error, _) = await process(toolCallsWithoutOutputIndexEvents)
        #expect(dErr(error).contains("OpenAI Responses stream completed with an unfinished tool call: bash (call_a|fc_a)"))
    }

    @Test func forwardsParsedProviderStreamEventsInOrder() async {
        let model = createModel()
        let seen = Locked<[(JsonValue, String)]>([])
        var options = StreamOptions()
        options.apiKey = "test"
        options.fetch = dSSEFetch(DRecorder(), dSSE(wrapperEvents))
        options.onProviderStreamEvent = { event, eventModel in
            await Task.yield()
            seen.withLock { $0.append((event, eventModel.id)) }
        }
        let stream = streamOpenAIResponses(model, wrapperContext(), options)
        _ = await stream.result()

        let providerEvents = seen.current
        #expect(providerEvents.count == 3)
        #expect(providerEvents.map { $0.0["type"]?.stringValue } == [
            "response.created", "response.output_item.added", "response.reasoning_text.delta",
        ])
        #expect(providerEvents.map(\.1) == [model.id, model.id, model.id])
    }

    @Test func emitsAnErrorFinalResultWhenTheWrapperStreamEndsBeforeATerminalResponseEvent() async {
        var options = StreamOptions()
        options.apiKey = "test"
        options.fetch = dSSEFetch(DRecorder(), dSSE(wrapperEvents))
        let stream = streamOpenAIResponses(createModel(), wrapperContext(), options)
        var initialStopReason: StopReason?
        var events: [AssistantMessageEvent] = []
        for await event in stream {
            if case .start(let partial) = event { initialStopReason = partial.stopReason }
            events.append(event)
        }
        let result = await stream.result()
        #expect(initialStopReason == .pending)
        #expect(events.last?.type == "error")
        #expect(result.stopReason == .error)
        #expect(result.errorMessage == "OpenAI Responses stream ended before a terminal response event")
    }

    @Test(arguments: [
        (("commentary", "commentary"), [StopReason.pending, .pending]),
        (("final_answer", "final_answer"), [StopReason.stop, .stop]),
        (("commentary", "final_answer"), [StopReason.pending, .stop]),
    ] as [((String, String), [StopReason])])
    func tracksMessagePhases(_ phases: (String, String), _ expected: [StopReason]) async {
        let (output, error, observed) = await process(phasedMessageEvents(phases))
        #expect(error == nil)
        #expect(observed == expected)
        #expect(output.stopReason == .stop)
    }

    @Test func replacesAProvisionalFinalAnswerStopWithAnIncompleteTerminalReason() async {
        let (output, error, observed) = await process(phasedMessageEvents(("final_answer", "final_answer"), "incomplete"))
        #expect(error == nil)
        #expect(observed == [.stop, .stop])
        #expect(output.stopReason == .length)
    }

    @Test func finalizesCompletedTerminalEventsAsStop() async {
        let (output, _, _) = await process(completedEvents)
        #expect(output.responseId == "resp_completed")
        #expect(output.stopReason == .stop)
        #expect(output.rawStopReason == "completed")
        #expect(output.usage.input == 15)
        #expect(output.usage.output == 7)
        #expect(output.usage.cacheRead == 2)
        #expect(output.usage.cacheWrite == 3)
        #expect(output.usage.totalTokens == 27)
    }

    @Test func finalizesIncompleteTerminalEventsAsLengthStops() async {
        let (output, _, _) = await process(incompleteEvents())
        #expect(output.responseId == "resp_incomplete")
        #expect(output.stopReason == .length)
        #expect(output.rawStopReason == "incomplete.max_output_tokens")
        #expect(output.usage.input == 25)
        #expect(output.usage.output == 12)
        #expect(output.usage.cacheRead == 5)
        #expect(output.usage.cacheWrite == 0)
        #expect(output.usage.totalTokens == 42)
    }

    @Test func finalizesContentFilteredIncompleteResponsesAsNonRetryableErrors() async {
        let (output, _, _) = await process(incompleteEvents("content_filter"))
        #expect(output.stopReason == .error)
        #expect(output.rawStopReason == "incomplete.content_filter")
        #expect(output.errorMessage == "Response incomplete: content_filter")
    }

    @Test func preservesUnknownProviderIncompleteReasonsAsNonRetryableErrors() async {
        let (output, _, _) = await process(incompleteEvents("max_time_limit"))
        #expect(output.stopReason == .error)
        #expect(output.rawStopReason == "incomplete.max_time_limit")
        #expect(output.errorMessage == "Response incomplete: max_time_limit")
    }

    @Test func rejectsFailedTerminalEventsWithTheProviderError() async {
        let (output, error, _) = await process(failedEvents)
        #expect(dErr(error).contains("server_error: boom"))
        #expect(output.rawStopReason == "failed")
    }
}
