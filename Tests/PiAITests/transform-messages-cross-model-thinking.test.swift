import Testing
@testable import PiAI

// Port of packages/ai/test/transform-messages-cross-model-thinking.test.ts.

private let kimi = Model(
	id: "moonshotai/Kimi-K3",
	name: "Kimi K3",
	api: "openai-completions",
	provider: "sference",
	baseUrl: "https://api.sference.com/v1",
	reasoning: true,
	input: ["text", "image"],
	cost: ModelCost(input: 0, output: 0, cacheRead: 0, cacheWrite: 0),
	contextWindow: 1048576,
	maxTokens: 32768
)

private func assistant(_ model: String, _ content: [AssistantContent], stopReason: StopReason = .toolUse) -> Message {
	.assistant(AssistantMessage(
		content: content,
		api: "openai-completions",
		provider: "sference",
		model: model,
		usage: Usage(input: 0, output: 0, cacheRead: 0, cacheWrite: 0, totalTokens: 0, cost: UsageCost()),
		stopReason: stopReason,
		timestamp: dateNow()
	))
}

private func user(_ content: String) -> Message {
	.user(UserMessage(content: .string(content), timestamp: dateNow()))
}

private func text(_ text: String) -> AssistantContent {
	.text(TextContent(text: text))
}

@Suite("thinking from other models")
struct TransformMessagesCrossModelThinkingTests {
	// https://github.com/earendil-works/pi/issues/10995
	@Test("does not send another model's readable thinking as text")
	func doesNotSendOtherModelsThinking() {
		let messages: [Message] = [
			user("Why does curl work but node fails?"),
			assistant("zai-org/GLM-5.3", [
				.thinking(ThinkingContent(
					thinking: "The user asks about ECONNRESET. Candidates: proxy, IPv6, TLS.",
					thinkingSignature: "reasoning_content"
				)),
				text("Let me check the TLS versions."),
				.toolCall(ToolCall(id: "call_1", name: "bash", arguments: ["command": "curl -v"])),
			]),
			.toolResult(ToolResultMessage(
				toolCallId: "call_1",
				toolName: "bash",
				content: [.text(TextContent(text: "TLSv1.2"))],
				isError: false,
				timestamp: dateNow()
			)),
		]

		let result = transformMessages(messages, kimi)
		let assistantMsg = result.compactMap(\.assistantMessage).first

		#expect(assistantMsg?.content == [
			text("Let me check the TLS versions."),
			.toolCall(ToolCall(id: "call_1", name: "bash", arguments: ["command": "curl -v"])),
		])
	}

	@Test("keeps thinking only from the target model when models alternate")
	func keepsThinkingOnlyFromTargetModel() {
		let thinking = { (text: String) -> AssistantContent in
			.thinking(ThinkingContent(thinking: text, thinkingSignature: "reasoning_content"))
		}
		let messages: [Message] = [
			user("1"),
			assistant("moonshotai/Kimi-K3", [thinking("kimi 1"), text("a")], stopReason: .stop),
			user("2"),
			assistant("zai-org/GLM-5.3", [thinking("glm 1"), text("b")], stopReason: .stop),
			user("3"),
			assistant("moonshotai/Kimi-K3", [thinking("kimi 2"), text("c")], stopReason: .stop),
			user("4"),
			assistant("zai-org/GLM-5.3", [thinking("glm 2"), text("d")], stopReason: .stop),
			user("hi"),
		]

		let result = transformMessages(messages, kimi)
		let contents = result.compactMap(\.assistantMessage).map(\.content)

		#expect(contents == [
			[thinking("kimi 1"), text("a")],
			[text("b")],
			[thinking("kimi 2"), text("c")],
			[text("d")],
		])
	}
}
