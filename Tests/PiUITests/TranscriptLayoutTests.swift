import Testing
import PiChat
@testable import PiUI

struct TranscriptLayoutTests {
    @Test func toolRichReplyKeepsEventIdentityWithoutArtificialMessageGaps() {
        let messages: [ChatMessage] = [
            .init(role: .user, text: "看看当前目录"),
            .init(role: .assistant, text: "我先看一下。", tools: [tool("bash")]),
            .init(role: .assistant, tools: [tool("read")]),
            .init(role: .assistant, text: "只有 greeting.swift。"),
            .init(role: .user, text: "继续")
        ]
        let rows = TranscriptRow.make(messages)
        #expect(rows.map(\.id) == messages.map(\.id))
        #expect(rows[2].spacingBefore < rows[3].spacingBefore)
        #expect(rows[3].spacingBefore < rows[1].spacingBefore)
        #expect(rows[4].spacingBefore > rows[3].spacingBefore)
        #expect(rows.filter(\.showsActions).map(\.id) == [messages[3].id])
        #expect(rows.flatMap { $0.message.tools.map(\.id) } == ["bash", "read"])
    }

    @Test func emptyStreamingPlaceholdersDoNotAddRowsOrSplitReplies() {
        let user = ChatMessage(role: .user, text: "Question")
        let first = ChatMessage(role: .assistant, text: "Starting")
        var streaming = ChatMessage(role: .assistant)
        let before = TranscriptRow.make([user, first, streaming])
        #expect(before.count == 2)
        #expect(before.last?.showsActions == true)
        streaming.tools = [tool("read")]
        let after = TranscriptRow.make([user, first, streaming])
        #expect(after.map(\.id) == [user.id, first.id, streaming.id])
        #expect(after[1].showsActions == false)
        #expect(after[2].spacingBefore < after[1].spacingBefore)
    }

    @Test func textFragmentsAndSeparateTurnsKeepDistinctBoundaries() {
        let rows = TranscriptRow.make([
            .init(role: .assistant, text: "Recovered partial response"),
            .init(role: .assistant, text: "More text"),
            .init(role: .user, text: "Next"),
            .init(role: .assistant, text: "Answer")
        ])
        #expect(rows.map(\.showsActions) == [false, true, false, true])
        #expect(rows[1].spacingBefore < rows[2].spacingBefore)
        #expect(rows[1].spacingBefore < rows[3].spacingBefore)
        #expect(TranscriptRow.make([]).isEmpty)
    }

    @Test func runningReplyDoesNotInsertAnActionShelfBetweenStreamingSteps() {
        let messages: [ChatMessage] = [
            .init(role: .assistant, text: "Previous response"),
            .init(role: .user, text: "Continue"),
            .init(role: .assistant, text: "Checking files"),
            .init(role: .assistant)
        ]
        #expect(TranscriptRow.make(messages, isRunning: true).map(\.showsActions) == [true, false, false])
        #expect(TranscriptRow.make(messages, isRunning: false).map(\.showsActions) == [true, false, true])
    }

    private func tool(_ id: String) -> ChatToolCall {
        ChatToolCall(id: id, name: id, state: .succeeded)
    }
}
