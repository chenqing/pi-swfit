import Foundation
import Testing
@testable import PiAI

// Port of packages/ai/test/openai-responses-empty-tool-result.test.ts

private func buildEmptyToolResult(_ toolCallId: String, _ timestamp: Int, _ text: String = "") -> ToolResultMessage {
    ToolResultMessage(toolCallId: toolCallId, toolName: "bash", content: [.text(TextContent(text: text))], isError: false, timestamp: timestamp)
}

@Suite struct OpenAIResponsesEmptyToolResultTests {
    // Whitespace-only cases: https://github.com/earendil-works/pi/issues/8720
    @Test(arguments: ["", "\r\n", " \n\t"])
    func usesNoToolOutputPlaceholderForToolResultTextWithoutImages(_ text: String) throws {
        let model = dModel("openai", "gpt-4o-mini")
        let now = dateNow()
        let assistant = AssistantMessage(
            content: [.toolCall(ToolCall(id: "tool-1", name: "bash", arguments: ["command": "true"]))],
            api: model.api, provider: model.provider, model: model.id, stopReason: .toolUse, timestamp: now
        )
        let context = normalizeContext(Context(messages: [
            .user(UserMessage(content: "Run the command", timestamp: now - 1)),
            .assistant(assistant),
            .toolResult(buildEmptyToolResult("tool-1", now + 1, text)),
        ]))

        let input = try convertResponsesMessages(model, context, ["openai", "openai-codex", "opencode"])
        let functionCallOutput = input.first { $0["type"] == "function_call_output" }

        #expect(functionCallOutput != nil)
        #expect(functionCallOutput?["output"] == "(no tool output)")
        #expect(functionCallOutput?["output"]?.stringValue?.contains("see attached image") == false)
    }
}
