import Foundation
import PiAI
import PiAgent
import Testing
@testable import PiCodingAgent

// Port of test/branch-summarization.test.ts

private let model = Model(
    id: "test-model",
    name: "Test Model",
    api: "anthropic-messages",
    provider: "anthropic",
    baseUrl: "https://api.anthropic.com",
    reasoning: false,
    input: ["text"],
    cost: ModelCost(),
    contextWindow: 200000,
    maxTokens: 8192
)

private let entries: [SessionEntry] = [
    .message(SessionMessageEntry(
        id: "branch-user",
        parentId: nil,
        timestamp: toISOString(1),
        message: .user(UserMessage(content: .string("Abandoned request"), timestamp: 1))
    )),
]

private func response(_ content: [AssistantContent]) -> AssistantMessage {
    var message = fauxAssistantMessage("")
    message.content = content
    message.api = model.api
    message.provider = model.provider
    message.model = model.id
    return message
}

/// Swift: `queueMicrotask(() => stream.push(...))` becomes a detached task pushing the final event.
private func respondingStreamFn(_ reason: StopReason, _ message: AssistantMessage, record: Locked<SimpleStreamOptions?>? = nil) -> StreamFn {
    { _, _, options in
        record?.withLock { $0 = options }
        let stream = createAssistantMessageEventStream()
        Task { stream.push(.done(reason: reason, message: message)) }
        return stream
    }
}

@Suite("branch summarization") struct BranchSummarizationTests {
    @Test("does not override tool choice for branch summaries") func toolChoice() async throws {
        let requestOptions = Locked<SimpleStreamOptions?>(nil)
        let streamFn = respondingStreamFn(.stop, response([.text(TextContent(text: "summary"))]), record: requestOptions)

        _ = try await generateBranchSummary(entries, GenerateBranchSummaryOptions(
            model: model, signal: AbortController().signal, streamFn: streamFn
        ))

        let recorded = try #require(requestOptions.withLock { $0 })
        #expect(recorded.toolChoice == nil)
    }

    @Test("rejects tool calls from branch summaries") func rejectsToolCalls() async throws {
        let streamFn = respondingStreamFn(
            .toolUse, response([.toolCall(ToolCall(id: "tool-call-1", name: "read", arguments: ["path": "README.md"]))])
        )

        let result = try await generateBranchSummary(entries, GenerateBranchSummaryOptions(
            model: model, signal: AbortController().signal, streamFn: streamFn
        ))

        #expect(result.error == "Branch summarization attempted to call a tool")
    }

    @Test("rejects length-limited branch summaries") func rejectsLengthLimited() async throws {
        var message = response([.text(TextContent(text: "partial"))])
        message.stopReason = .length
        let streamFn = respondingStreamFn(.length, message)

        let result = try await generateBranchSummary(entries, GenerateBranchSummaryOptions(
            model: model, signal: AbortController().signal, streamFn: streamFn
        ))

        #expect(result.error == "Branch summarization failed: generation hit the token cap and the summary is incomplete")
    }
}
