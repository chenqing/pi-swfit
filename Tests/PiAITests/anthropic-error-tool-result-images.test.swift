import Foundation
import Testing
@testable import PiAI

// Port of packages/ai/test/anthropic-error-tool-result-images.test.ts

private let model = Model(
    id: "claude-test",
    name: "Claude Test",
    api: "anthropic-messages",
    provider: "anthropic",
    baseUrl: "http://127.0.0.1:9",
    reasoning: false,
    input: ["text", "image"],
    cost: ModelCost(),
    contextWindow: 200_000,
    maxTokens: 1024
)

private func assistant(_ calls: [ToolCall]) -> Message {
    .assistant(AssistantMessage(
        content: calls.map(AssistantContent.toolCall),
        api: "anthropic-messages",
        provider: "anthropic",
        model: "claude-test",
        usage: Usage(),
        stopReason: .toolUse
    ))
}

private let call1 = ToolCall(id: "call-1", name: "codemode")
private let call2 = ToolCall(id: "call-2", name: "read")

private func capturePayload(_ messages: [Message]) async throws -> JsonObject {
    var options = SimpleStreamOptions()
    options.cacheRetention = CacheRetention.none
    return try #require(await bCapturePayload(model, Context(messages: messages), options), "Expected payload capture before request")
}

private func image(_ data: String) -> JsonValue {
    ["type": "image", "source": ["type": "base64", "media_type": "image/png", "data": .string(data)]]
}

private func pngImage(_ data: String) -> UserContent {
    .image(ImageContent(data: data, mimeType: "image/png"))
}

@Suite("Anthropic error tool results with images")
struct AnthropicErrorToolResultImagesTests {
    // Regression for #10794: Anthropic rejects error tool results that contain images.
    @Test("moves the images after the tool results of the turn")
    func movesImagesAfterToolResults() async throws {
        let payload = try await capturePayload([
            .user(UserMessage(content: "Show the screenshots")),
            assistant([call1, call2]),
            .toolResult(ToolResultMessage(
                toolCallId: "call-1",
                toolName: "codemode",
                content: [
                    .text(TextContent(text: "Script failed")),
                    pngImage("AAAA"),
                    pngImage("CCCC"),
                    .text(TextContent(text: "Script error")),
                ],
                isError: true
            )),
            .toolResult(ToolResultMessage(
                toolCallId: "call-2",
                toolName: "read",
                content: [pngImage("BBBB")],
                isError: false
            )),
        ])

        #expect(payload["messages"]?[2] == [
            "role": "user",
            "content": [
                [
                    "type": "tool_result",
                    "tool_use_id": "call-1",
                    "content": "Script failed\n(image attached after the tool results)\nScript error",
                    "is_error": true,
                ],
                [
                    "type": "tool_result",
                    "tool_use_id": "call-2",
                    "content": [["type": "text", "text": "(see attached image)"], image("BBBB")],
                    "is_error": false,
                ],
                ["type": "text", "text": "Images from the error result of tool call call-1 (codemode):"],
                image("AAAA"),
                image("CCCC"),
            ],
        ])
    }

    @Test("keeps error tool results without images unchanged")
    func keepsErrorToolResultsWithoutImages() async throws {
        let payload = try await capturePayload([
            .user(UserMessage(content: "Run it")),
            assistant([call1]),
            .toolResult(ToolResultMessage(
                toolCallId: "call-1",
                toolName: "codemode",
                content: [.text(TextContent(text: "Script failed"))],
                isError: true
            )),
        ])

        #expect(payload["messages"]?[2] == [
            "role": "user",
            "content": [["type": "tool_result", "tool_use_id": "call-1", "content": "Script failed", "is_error": true]],
        ])
    }
}
