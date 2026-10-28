import Testing
@testable import PiAI

// Port of packages/ai/test/context-estimate.test.ts.

private func createUsage(_ totalTokens: Int) -> Usage {
	Usage(
		input: totalTokens,
		output: 0,
		cacheRead: 0,
		cacheWrite: 0,
		totalTokens: totalTokens,
		cost: UsageCost(input: 0, output: 0, cacheRead: 0, cacheWrite: 0, total: 0)
	)
}

private func createAssistant(_ timestamp: Int, _ totalTokens: Int) -> Message {
	.assistant(AssistantMessage(
		content: [.text(TextContent(text: "kept"))],
		api: "openai-responses",
		provider: "openai",
		model: "test-model",
		usage: createUsage(totalTokens),
		stopReason: .stop,
		timestamp: timestamp
	))
}

private func user(_ content: String, _ timestamp: Int) -> Message {
	.user(UserMessage(content: .string(content), timestamp: timestamp))
}

private let model = Model(
	id: "test-model",
	name: "Test Model",
	api: "openai-responses",
	provider: "openai",
	baseUrl: "https://api.openai.com/v1",
	reasoning: false,
	input: ["text"],
	cost: ModelCost(input: 0, output: 0, cacheRead: 0, cacheWrite: 0),
	contextWindow: 10_000,
	maxTokens: 8_000
)

@Suite("context token estimation")
struct ContextEstimateTests {
	// Regression for #10497: large new inputs need more room than chars/4 allows.
	@Test("reserves 3.5 characters per token for new text when limiting output")
	func reservesCharactersPerToken() {
		let context = normalizeContext(Context(
			messages: [createAssistant(100, 2_000), user(String(repeating: "x", count: 3_500), 200)]
		))

		#expect(estimateContextTokens(context) == ContextUsageEstimate(
			tokens: 3_000,
			usageTokens: 2_000,
			trailingTokens: 1_000,
			lastUsageIndex: 0
		))
		#expect(buildBaseOptions(model, context).maxTokens == 2_904)
	}

	@Test("ignores stale assistant usage after a newer message is inserted before it")
	func ignoresStaleAssistantUsage() {
		let context = normalizeContext(Context(
			systemPrompt: "system",
			messages: [
				user("summary", 200),
				createAssistant(100, 9_500),
				user(String(repeating: "x", count: 4_000), 300),
			]
		))

		#expect(estimateContextTokens(context) == ContextUsageEstimate(
			tokens: 1_149,
			usageTokens: 0,
			trailingTokens: 1_149,
			lastUsageIndex: nil
		))
		#expect(buildBaseOptions(model, context).maxTokens == 4_755)
	}

	@Test("uses assistant usage again after a response to the inserted context")
	func usesAssistantUsageAgain() {
		let context = normalizeContext(Context(
			messages: [
				user("summary", 200),
				createAssistant(100, 9_500),
				user("new prompt", 300),
				createAssistant(400, 2_000),
				user("tail", 500),
			]
		))

		#expect(estimateContextTokens(context) == ContextUsageEstimate(
			tokens: 2_002,
			usageTokens: 2_000,
			trailingTokens: 2,
			lastUsageIndex: 3
		))
	}
}
