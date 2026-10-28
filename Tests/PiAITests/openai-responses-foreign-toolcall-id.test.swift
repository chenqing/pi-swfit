import Foundation
import Testing
@testable import PiAI

// Port of packages/ai/test/openai-responses-foreign-toolcall-id.test.ts

private let COPILOT_RAW_TOOL_CALL_ID =
    "call_4VnzVawQXPB9MgYib7CiQFEY|I9b95oN1wD/cHXKTw3PpRkL6KkCtzTJhUxMouMWYwHeTo2j3htzfSk7YPx2vifiIM4g3A8XXyOj8q4Bt6SLUG7gqY1E3ELkrkVQNHglRfUmWj84lqxJY+Puieb3VKyX0FB+83TUzn91cDMF/4gzt990IzqVrc+nIb9RRscRD070Du16q1glydVjWR0SBJsE6TbY/esOjFpqplogQqrajm1eI++f3eLi73R6q7hVusY0QbeFySVxABCjhN0lXB04caBe1rzHjYzul6MAXj7uq+0r17VLq+yrtyYhN12wkmFqHeqTyEei6EFPbMy24Nc+IbJlkP0OCg02W+gOnyBFcbi2ctvJFSOhSjt1CqBdqCnnhwUqXjbWiT0wh3DmLScRgTHmGkaI+oAcQQjfic65nxj+TnEkReA=="

@Suite struct OpenAIResponsesForeignToolCallIdNormalizationTests {
    @Test func hashesForeignCopilotToolItemIdsIntoABoundedCodexSafeShape() throws {
        let model = dModel("openai-codex", "gpt-6.1-sol")
        let assistant = AssistantMessage(
            content: [.toolCall(ToolCall(id: COPILOT_RAW_TOOL_CALL_ID, name: "edit", arguments: ["path": "src/styles/app.css"]))],
            api: "openai-responses", provider: "github-copilot", model: "gpt-5.5",
            stopReason: .toolUse, timestamp: dateNow() - 2000
        )
        let toolResult = ToolResultMessage(
            toolCallId: COPILOT_RAW_TOOL_CALL_ID, toolName: "edit", content: [.text(TextContent(text: "ok"))],
            isError: false, timestamp: dateNow() - 1000
        )
        let context = normalizeContext(Context(
            systemPrompt: "You are concise.",
            messages: [.user(UserMessage(content: "Use the tool.", timestamp: dateNow() - 3000)), .assistant(assistant), .toolResult(toolResult)]
        ))

        let input = try convertResponsesMessages(model, context, ["openai", "openai-codex", "opencode"])
        let functionCall = try #require(input.first { $0["type"] == "function_call" })
        #expect(functionCall["type"] == "function_call")

        let itemPart = String(COPILOT_RAW_TOOL_CALL_ID.split(separator: "|", omittingEmptySubsequences: false)[1])
        let expectedItemId = "fc_\(shortHash(itemPart))"
        let id = functionCall["id"]?.stringValue ?? ""
        #expect(id == expectedItemId)
        #expect(id.count <= 64)
        #expect(id.wholeMatch(of: /fc_[A-Za-z0-9]+/) != nil)
    }
}
