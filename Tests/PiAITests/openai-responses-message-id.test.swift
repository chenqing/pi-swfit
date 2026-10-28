import Foundation
import Testing
@testable import PiAI

// Port of packages/ai/test/openai-responses-message-id.test.ts

@Suite struct OpenAIResponsesMessageIdConversionTests {
    @Test func generatesUniqueFallbackMessageIdsForMultipleTextBlocksInOneAssistantTurn() throws {
        let model = dModel("openai-codex", "gpt-6.1-sol")
        let assistant = AssistantMessage(
            content: [.text(TextContent(text: "first answer")), .text(TextContent(text: "visible answer"))],
            api: "anthropic-messages", provider: "anthropic", model: "claude-opus-4-8",
            stopReason: .stop, timestamp: dateNow() - 1000
        )
        let context = normalizeContext(Context(
            systemPrompt: "You are concise.",
            messages: [.user(UserMessage(content: "hello", timestamp: dateNow() - 2000)), .assistant(assistant)]
        ))

        let input = try convertResponsesMessages(model, context, ["openai", "openai-codex", "opencode"])
        let messageIds = input
            .filter { $0["type"] == "message" }
            .compactMap { $0["id"]?.stringValue }

        #expect(messageIds == ["msg_pi_1", "msg_pi_1_1"])
        #expect(Set(messageIds).count == messageIds.count)
    }
}
