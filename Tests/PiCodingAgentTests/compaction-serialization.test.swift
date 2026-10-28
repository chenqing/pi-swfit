import Foundation
import PiAI
import Testing
@testable import PiCodingAgent

// Port of test/compaction-serialization.test.ts

private let zeroUsage = Usage(
    input: 0, output: 0, cacheRead: 0, cacheWrite: 0, totalTokens: 0,
    cost: UsageCost(input: 0, output: 0, cacheRead: 0, cacheWrite: 0, total: 0)
)

@Suite("serializeConversation") struct SerializeConversationTests {
    @Test("should truncate long tool results") func truncatesLongToolResults() {
        let longContent = String(repeating: "x", count: 5000)
        let messages: [Message] = [
            .toolResult(ToolResultMessage(
                toolCallId: "tc1", toolName: "read", content: [.text(TextContent(text: longContent))], isError: false, timestamp: dateNow()
            )),
        ]

        let result = serializeConversation(messages)

        #expect(result.contains("[Tool result]:"))
        #expect(result.contains("[... 3000 more characters truncated]"))
        #expect(!result.contains(String(repeating: "x", count: 3000)))
        // First 2000 chars should be present
        #expect(result.contains(String(repeating: "x", count: 2000)))
    }

    @Test("should not truncate short tool results") func keepsShortToolResults() {
        let shortContent = String(repeating: "x", count: 1500)
        let messages: [Message] = [
            .toolResult(ToolResultMessage(
                toolCallId: "tc1", toolName: "read", content: [.text(TextContent(text: shortContent))], isError: false, timestamp: dateNow()
            )),
        ]

        let result = serializeConversation(messages)

        #expect(result == "[Tool result]: \(shortContent)")
        #expect(!result.contains("truncated"))
    }

    @Test("should not truncate assistant or user messages") func keepsUserAndAssistant() {
        let longText = String(repeating: "y", count: 5000)
        let messages: [Message] = [
            .user(UserMessage(content: .blocks([.text(TextContent(text: longText))]), timestamp: dateNow())),
            .assistant(AssistantMessage(
                content: [.text(TextContent(text: longText))], api: "anthropic", provider: "anthropic", model: "test",
                usage: zeroUsage, stopReason: .stop, timestamp: dateNow()
            )),
        ]

        let result = serializeConversation(messages)

        #expect(!result.contains("truncated"))
        #expect(result.contains(longText))
    }

    @Test("should omit thinking") func omitsThinking() {
        let messages: [Message] = [
            .assistant(AssistantMessage(
                content: [
                    .thinking(ThinkingContent(thinking: "private reasoning", thinkingSignature: "sig")),
                    .text(TextContent(text: "visible reply")),
                    .toolCall(ToolCall(id: "tc1", name: "read", arguments: ["path": "a.ts"])),
                ],
                api: "anthropic", provider: "anthropic", model: "test",
                usage: zeroUsage, stopReason: .toolUse, timestamp: dateNow()
            )),
        ]

        let result = serializeConversation(messages)

        #expect(result == "[Assistant]: visible reply\n\n[Assistant tool calls]: read(path=\"a.ts\")")
    }
}
