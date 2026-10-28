import Foundation
import Testing
@testable import PiAI

// Port of packages/ai/test/openai-completions-reasoning-details.test.ts
// The upstream mock answers the n-th request with `chunkSets[n]` and records each payload.

private let reasoningDetail = cJSON(#"{"type":"reasoning.encrypted","id":"call_1","data":"encrypted-signature"}"#)
private let signedReasoningTextDetail = cJSON(#"{"type":"reasoning.text","text":"I should call the read tool.","signature":"sha256:signed-text","id":"reasoning-text-1","format":"anthropic-claude-v1","index":0}"#)
private let reasoningSummaryDetail = cJSON(#"{"type":"reasoning.summary","summary":"Decided to inspect the requested file.","id":"reasoning-summary-1","format":"anthropic-claude-v1","index":1}"#)
private let readTool = Tool(name: "read", description: "Read a file", parameters: cObjectSchema([("path", "string")]))

private func model() -> Model {
    cModel(#"{"id":"google/gemini-test","name":"Gemini Test","api":"openai-completions","provider":"openrouter","baseUrl":"https://openrouter.ai/api/v1","reasoning":true,"input":["text"],"cost":{"input":0,"output":0,"cacheRead":0,"cacheWrite":0},"contextWindow":100000,"maxTokens":4096}"#)
}

private func chunk(_ delta: JsonValue, _ finishReason: String? = nil) -> JsonValue {
    cChunk(delta, finishReason: finishReason, model: "google/gemini-test")
}

private func toolCallChunk() -> JsonValue {
    chunk(cJSON(#"{"tool_calls":[{"index":0,"id":"call_1","type":"function","function":{"name":"read","arguments":"{\"path\":\"README.md\"}"}}]}"#))
}

/// Serves `chunkSets[i]` to the i-th request.
private func makeServer(_ chunkSets: [[JsonValue]]) -> CFakeServer {
    CFakeServer { _, index in cSSEResponse(cSSE(index < chunkSets.count ? chunkSets[index] : [])) }
}

private func runStream(_ server: CFakeServer, _ messages: [AssistantMessage] = []) async -> AssistantMessage {
    await cRunDirect(model(), Context(messages: messages.map(Message.assistant), tools: [readTool]), server: server).result
}

private func assistantPayload(_ server: CFakeServer, _ index: Int) -> JsonValue? {
    server.body(index)["messages"]?.arrayValue?.first { $0["role"] == "assistant" }
}

private func thinkingJSON(_ message: AssistantMessage) -> JsonValue? {
    message.content.first { if case .thinking = $0 { return true } else { return false } }?.json
}

@Suite("openai-completions reasoning_details streaming")
struct OpenAICompletionsReasoningDetailsTests {
    @Test("preserves reasoning_details in the thinking signature")
    func preservesInSignature() async throws {
        let server = makeServer([
            [chunk(["reasoning_details": [reasoningDetail]]), toolCallChunk(), chunk([:], "tool_calls")],
            [chunk(["content": "ok"]), chunk([:], "stop")],
        ])

        let assistant = await runStream(server)
        #expect(thinkingJSON(assistant) == ["type": "thinking", "thinking": "", "thinkingSignature": .string(JsonValue.array([reasoningDetail]).serialized())])
        let toolCall = assistant.content.first { if case .toolCall = $0 { return true } else { return false } }
        #expect(toolCall?.json == cJSON(#"{"type":"toolCall","id":"call_1","name":"read","arguments":{"path":"README.md"}}"#))

        _ = await runStream(server, [assistant])
        #expect(assistantPayload(server, 1)?["reasoning_details"] == [reasoningDetail])
    }

    @Test("falls back to encrypted tool-call signatures for older stored assistant messages")
    func fallsBackToToolCallSignatures() async throws {
        let server = makeServer([
            [chunk(["reasoning_details": [reasoningDetail]]), toolCallChunk(), chunk([:], "tool_calls")],
            [chunk(["content": "ok"]), chunk([:], "stop")],
        ])

        var assistant = await runStream(server)
        assistant.content = assistant.content.compactMap { block in
            switch block {
            case .thinking: return nil
            case .toolCall(var call):
                call.thoughtSignature = reasoningDetail.serialized()
                return .toolCall(call)
            default: return block
            }
        }
        #expect(assistant.content.contains { if case .toolCall = $0 { return true } else { return false } })

        _ = await runStream(server, [assistant])
        #expect(assistantPayload(server, 1)?["reasoning_details"] == [reasoningDetail])
    }

    @Test("preserves signed text and summary reasoning_details in their original sequence")
    func preservesSequence() async throws {
        let server = makeServer([
            [
                chunk(["reasoning": signedReasoningTextDetail["text"]!, "reasoning_details": [signedReasoningTextDetail]]),
                chunk(["reasoning_details": [reasoningDetail, reasoningSummaryDetail]]),
                toolCallChunk(),
                chunk([:], "tool_calls"),
            ],
            [chunk(["content": "ok"]), chunk([:], "stop")],
        ])

        let assistant = await runStream(server)
        let expected: JsonValue = [signedReasoningTextDetail, reasoningDetail, reasoningSummaryDetail]
        #expect(thinkingJSON(assistant) == ["type": "thinking", "thinking": signedReasoningTextDetail["text"]!, "thinkingSignature": .string(expected.serialized())])

        _ = await runStream(server, [assistant])
        let payload = assistantPayload(server, 1)
        #expect(payload?["reasoning_details"] == expected)
        #expect(payload?["reasoning"] == nil)
    }

    @Test("merges consecutive text and summary reasoning_details deltas before replay")
    func mergesDeltas() async throws {
        let textDelta = cJSON(#"{"type":"reasoning.text","text":"The","index":0}"#)
        let textDeltaWithSignature = cJSON(#"{"type":"reasoning.text","text":" user wants the time.","signature":"sha256:text-signature","format":"openai-responses-v1","index":0}"#)
        let summaryDelta = cJSON(#"{"type":"reasoning.summary","summary":"Looked","index":0}"#)
        let summaryDeltaWithFormat = cJSON(#"{"type":"reasoning.summary","summary":" up time.","format":"openai-responses-v1","index":0}"#)
        let laterSummaryDelta = cJSON(#"{"type":"reasoning.summary","summary":"After encrypted block.","format":"openai-responses-v1","index":0}"#)
        let expected: JsonValue = [
            cJSON(#"{"type":"reasoning.text","text":"The user wants the time.","index":0,"signature":"sha256:text-signature","format":"openai-responses-v1"}"#),
            cJSON(#"{"type":"reasoning.summary","summary":"Looked up time.","index":0,"format":"openai-responses-v1"}"#),
            reasoningDetail,
            laterSummaryDelta,
        ]
        let server = makeServer([
            [
                chunk(["reasoning_details": [textDelta]]),
                chunk(["reasoning_details": [textDeltaWithSignature]]),
                chunk(["reasoning_details": [summaryDelta]]),
                chunk(["reasoning_details": [summaryDeltaWithFormat]]),
                chunk(["reasoning_details": [reasoningDetail]]),
                chunk(["reasoning_details": [laterSummaryDelta]]),
                toolCallChunk(),
                chunk([:], "tool_calls"),
            ],
            [chunk(["content": "ok"]), chunk([:], "stop")],
        ])

        let assistant = await runStream(server)
        #expect(thinkingJSON(assistant) == ["type": "thinking", "thinking": "", "thinkingSignature": .string(expected.serialized())])

        _ = await runStream(server, [assistant])
        #expect(assistantPayload(server, 1)?["reasoning_details"] == expected)
    }
}

@Suite("openai-completions reasoning and content in one delta")
struct OpenAICompletionsReasoningAndContentTests {
    // https://github.com/earendil-works/pi/issues/10926
    @Test("places thinking before text when one delta carries reasoning_content and content")
    func reasoningContentBeforeText() async {
        let server = makeServer([[chunk(["role": "assistant", "reasoning_content": "thinking", "content": "answer"], "stop")]])
        let assistant = await runStream(server)
        #expect(cContentJSON(assistant) == cJSON(#"[{"type":"thinking","thinking":"thinking","thinkingSignature":"reasoning_content"},{"type":"text","text":"answer"}]"#))
    }

    @Test("places thinking before text when one delta carries reasoning_details and content")
    func reasoningDetailsBeforeText() async {
        let server = makeServer([[chunk(["reasoning_details": [reasoningDetail], "content": "answer"], "stop")]])
        let assistant = await runStream(server)
        #expect(assistant.content.map(\.type) == ["thinking", "text"])
    }
}
