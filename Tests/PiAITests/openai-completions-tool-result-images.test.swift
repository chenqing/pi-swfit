import Foundation
import Testing
@testable import PiAI

// Port of packages/ai/test/openai-completions-tool-result-images.test.ts

private let compat = ResolvedOpenAICompletionsCompat(
    supportsStore: true, supportsDeveloperRole: true, supportsReasoningEffort: true, supportsUsageInStreaming: true,
    supportsFinishReason: true, maxTokensField: .maxCompletionTokens, requiresToolResultName: false,
    requiresAssistantAfterToolResult: false, requiresThinkingAsText: false, requiresReasoningContentOnAssistantMessages: false,
    thinkingFormat: .openai, zaiToolStream: false, supportsStrictMode: true, supportsOpenAIGrammarTools: false,
    sendSessionAffinityHeaders: false, sessionAffinityFormat: .openai, supportsLongCacheRetention: true,
    cacheControlFormat: .anthropic, supportsThinkingTokenBudget: false, supportsMidConvoSystemMessages: false,
    supportsMidConvoToolAdditions: false
)

private func imageModel() -> Model {
    var model = cOpenAICompletionsModel()
    model.input = ["text", "image"]
    return model
}

private func toolCallAssistant(_ model: Model, _ calls: [(String, String, JsonObject)], timestamp: Int) -> Message {
    .assistant(AssistantMessage(
        content: calls.map { .toolCall(ToolCall(id: $0.0, name: $0.1, arguments: $0.2)) },
        api: model.api, provider: model.provider, model: model.id,
        usage: Usage(), stopReason: .toolUse, timestamp: timestamp
    ))
}

private func buildToolResult(_ toolCallId: String, _ timestamp: Int) -> Message {
    .toolResult(ToolResultMessage(
        toolCallId: toolCallId, toolName: "read",
        content: [.text(TextContent(text: "Read image file [image/png]")), .image(ImageContent(data: "ZmFrZQ==", mimeType: "image/png"))],
        isError: false, timestamp: timestamp
    ))
}

private func buildEmptyToolResult(_ toolCallId: String, _ timestamp: Int, _ text: String = "") -> Message {
    .toolResult(ToolResultMessage(toolCallId: toolCallId, toolName: "bash", content: [.text(TextContent(text: text))], isError: false, timestamp: timestamp))
}

@Suite("openai-completions convertMessages")
struct OpenAICompletionsToolResultImagesTests {
    // Regression test for https://github.com/earendil-works/pi/issues/9797
    @Test("omits empty text parts from user messages with images")
    func omitsEmptyTextParts() throws {
        let context = normalizeContext(Context(messages: [
            .user(UserMessage(content: .blocks([.text(TextContent(text: "")), .image(ImageContent(data: "ZmFrZQ==", mimeType: "image/png"))]))),
        ]))
        let messages = try convertMessages(imageModel(), context, compat)
        #expect(JsonValue.array(messages.map(JsonValue.object)) == cJSON(#"[{"role":"user","content":[{"type":"image_url","image_url":{"url":"data:image/png;base64,ZmFrZQ=="}}]}]"#))
    }

    @Test("batches tool-result images after consecutive tool results")
    func batchesToolResultImages() throws {
        let model = imageModel()
        let now = dateNow()
        let context = normalizeContext(Context(messages: [
            .user(UserMessage(content: .string("Read the images"), timestamp: now - 2)),
            toolCallAssistant(model, [("tool-1", "read", ["path": "img-1.png"]), ("tool-2", "read", ["path": "img-2.png"])], timestamp: now),
            buildToolResult("tool-1", now + 1),
            buildToolResult("tool-2", now + 2),
        ]))

        let messages = try convertMessages(model, context, compat)
        #expect(messages.map { $0["role"]?.stringValue ?? "" } == ["user", "assistant", "tool", "tool", "user"])

        let imageMessage = try #require(messages.last)
        #expect(imageMessage["role"] == "user")
        let parts = try #require(imageMessage["content"]?.arrayValue)
        #expect(parts.filter { $0["type"] == "image_url" }.count == 2)
    }

    // Whitespace-only cases: https://github.com/earendil-works/pi/issues/8720
    @Test("uses '(no tool output)' placeholder for tool result text without images", arguments: ["", "\r\n", " \n\t"])
    func noToolOutputPlaceholder(_ text: String) throws {
        let model = imageModel()
        let now = dateNow()
        let context = normalizeContext(Context(messages: [
            .user(UserMessage(content: .string("Run the command"), timestamp: now - 1)),
            toolCallAssistant(model, [("tool-1", "bash", ["command": "true"])], timestamp: now),
            buildEmptyToolResult("tool-1", now + 1, text),
        ]))

        let messages = try convertMessages(model, context, compat)
        let toolMessage = try #require(messages.first { $0["role"] == "tool" })
        #expect(toolMessage["content"] == "(no tool output)")
        #expect(toolMessage["content"]?.stringValue?.contains("see attached image") == false)
    }
}
