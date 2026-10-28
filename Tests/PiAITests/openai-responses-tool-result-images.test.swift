import Foundation
import Testing
@testable import PiAI

// Offline port of packages/ai/test/openai-responses-tool-result-images.test.ts.
// Upstream only has live-network cases; this checks the same payload invariants (images stay inside
// function_call_output, no follow-up user message) on the converted second-turn request.

private let toolText = "A red circle with a diameter of 100 pixels."
// 1x1 PNG
private let base64Image = "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8DwHwAFBQIAX8jx0gAAAABJRU5ErkJggg=="

@Suite struct ResponsesAPIToolResultImagesTests {
    @Test(arguments: [("openai", "gpt-5-mini"), ("azure", "gpt-4o-mini"), ("github-copilot", "gpt-5-mini"), ("openai-codex", "gpt-6.1-sol")])
    func sendsToolResultImagesInFunctionCallOutput(_ provider: String, _ id: String) throws {
        let model = dModel(provider, id)
        guard model.input.contains("image") else { return }

        let firstResponse = AssistantMessage(
            content: [.toolCall(ToolCall(id: "call_img|fc_img", name: "get_circle_with_description"))],
            api: model.api, provider: model.provider, model: model.id, stopReason: .toolUse
        )
        let context = normalizeContext(Context(
            systemPrompt: "You are a helpful assistant that always uses the provided tool when asked.",
            messages: [
                .user(UserMessage(content: "Call get_circle_with_description, then describe both the tool text and the image. Mention the color and shape.")),
                .assistant(firstResponse),
                .toolResult(ToolResultMessage(
                    toolCallId: "call_img|fc_img",
                    toolName: "get_circle_with_description",
                    content: [.text(TextContent(text: toolText)), .image(ImageContent(data: base64Image, mimeType: "image/png"))],
                    isError: false
                )),
            ],
            tools: [Tool(name: "get_circle_with_description", description: "Returns a red circle image with a short text description.", parameters: ["type": "object", "properties": [:], "required": []])]
        ))

        let responseInput = try convertResponsesMessages(model, context, [model.provider, "openai", "openai-codex", "opencode", "azure", "github-copilot"])
        let functionCallOutputIndex = try #require(responseInput.firstIndex { $0["type"] == "function_call_output" })
        let outputItems = try #require(responseInput[functionCallOutputIndex]["output"]?.arrayValue, "Expected function_call_output output to be a content array")

        let textItem = try #require(outputItems.first { $0["type"] == "input_text" })
        let imageItem = try #require(outputItems.first { $0["type"] == "input_image" })
        #expect(textItem["text"]?.stringValue?.contains(toolText) == true)
        #expect(imageItem["image_url"]?.stringValue?.hasPrefix("data:image/png;base64,") == true)

        let laterUserMessages = responseInput[(functionCallOutputIndex + 1)...].filter { $0["role"] == "user" }
        #expect(laterUserMessages.isEmpty)
    }
}
