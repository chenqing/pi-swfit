import Testing
@testable import PiAI

// Port of packages/ai/test/transform-messages-copilot-openai-to-anthropic.test.ts.

/// Normalize function matching what anthropic.ts uses: `id.replace(/[^a-zA-Z0-9_-]/g, "_").slice(0, 64)`
/// (JS operates on UTF-16 code units).
private func anthropicNormalizeToolCallId(_ id: String, _ model: Model, _ source: AssistantMessage) -> String {
	let units: [UInt16] = id.utf16.map { unit in
		switch unit {
		case 0x30...0x39, 0x41...0x5A, 0x61...0x7A, 0x5F, 0x2D: return unit
		default: return 0x5F
		}
	}
	return String(decoding: units.prefix(64), as: UTF16.self)
}

private func makeCopilotClaudeModel() -> Model {
	Model(
		id: "claude-sonnet-4.6",
		name: "Claude Sonnet 4.6",
		api: "anthropic-messages",
		provider: "github-copilot",
		baseUrl: "https://api.individual.githubcopilot.com",
		reasoning: true,
		input: ["text", "image"],
		cost: ModelCost(input: 0, output: 0, cacheRead: 0, cacheWrite: 0),
		contextWindow: 128000,
		maxTokens: 16000
	)
}

private func makeAssistantMessage(_ content: [AssistantContent]) -> AssistantMessage {
	AssistantMessage(
		content: content,
		api: "openai-responses",
		provider: "github-copilot",
		model: "gpt-5",
		usage: Usage(input: 0, output: 0, cacheRead: 0, cacheWrite: 0, totalTokens: 0, cost: UsageCost()),
		stopReason: .toolUse,
		timestamp: dateNow()
	)
}

@Suite("OpenAI to Anthropic session migration for Copilot Claude")
struct TransformMessagesCopilotTests {
	@Test("removes thoughtSignature from tool calls when migrating between models")
	func removesThoughtSignature() {
		let model = makeCopilotClaudeModel()
		let signature: JsonValue = ["type": "reasoning.encrypted", "id": "call_123", "data": "encrypted"]
		let messages: [Message] = [
			.user(UserMessage(content: "run a command", timestamp: dateNow())),
			.assistant(AssistantMessage(
				content: [
					.toolCall(ToolCall(
						id: "call_123",
						name: "bash",
						arguments: ["command": "ls"],
						thoughtSignature: signature.serialized()
					)),
				],
				api: "openai-responses",
				provider: "github-copilot",
				model: "gpt-5",
				usage: Usage(input: 0, output: 0, cacheRead: 0, cacheWrite: 0, totalTokens: 0, cost: UsageCost()),
				stopReason: .toolUse,
				timestamp: dateNow()
			)),
			.toolResult(ToolResultMessage(
				toolCallId: "call_123",
				toolName: "bash",
				content: [.text(TextContent(text: "output"))],
				isError: false,
				timestamp: dateNow()
			)),
		]

		let result = transformMessages(messages, model, anthropicNormalizeToolCallId)
		let assistantMsg = result.compactMap(\.assistantMessage).first
		let toolCall = assistantMsg?.content.compactMap(\.toolCallContent).first

		#expect(toolCall != nil)
		#expect(toolCall?.thoughtSignature == nil)
	}

	@Test("adds synthetic tool results for trailing orphaned tool calls")
	func addsSyntheticToolResults() {
		let model = makeCopilotClaudeModel()
		let messages: [Message] = [
			.user(UserMessage(content: "read the file", timestamp: dateNow())),
			.assistant(makeAssistantMessage([
				.toolCall(ToolCall(id: "call_123|fc_123", name: "read", arguments: ["path": "README.md"])),
			])),
		]

		let result = transformMessages(messages, model, anthropicNormalizeToolCallId)
		let lastMessage = result.last?.toolResultMessage

		#expect(result.last?.role == "toolResult")
		#expect(lastMessage?.toolCallId == "call_123_fc_123")
		#expect(lastMessage?.toolName == "read")
		#expect(lastMessage?.isError == true)
		#expect(lastMessage?.content == [.text(TextContent(text: "No result provided"))])
	}

	@Test("adds synthetic results only for trailing tool calls that are still missing results")
	func addsSyntheticResultsOnlyForMissing() {
		let model = makeCopilotClaudeModel()
		let messages: [Message] = [
			.user(UserMessage(content: "run commands", timestamp: dateNow())),
			.assistant(makeAssistantMessage([
				.toolCall(ToolCall(id: "call_1|fc_1", name: "read", arguments: ["path": "README.md"])),
				.toolCall(ToolCall(id: "call_2|fc_2", name: "bash", arguments: ["command": "pwd"])),
			])),
			.toolResult(ToolResultMessage(
				toolCallId: "call_1|fc_1",
				toolName: "read",
				content: [.text(TextContent(text: "done"))],
				isError: false,
				timestamp: dateNow()
			)),
		]

		let result = transformMessages(messages, model, anthropicNormalizeToolCallId)
		let syntheticResults = result.compactMap(\.toolResultMessage).filter(\.isError)

		#expect(syntheticResults.count == 1)
		#expect(syntheticResults.first?.role == "toolResult")
		#expect(syntheticResults.first?.toolCallId == "call_2_fc_2")
		#expect(syntheticResults.first?.toolName == "bash")
		#expect(syntheticResults.first?.content == [.text(TextContent(text: "No result provided"))])
	}
}
