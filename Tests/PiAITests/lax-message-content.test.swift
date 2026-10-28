import Testing
@testable import PiAI

// Port of packages/ai/test/lax-message-content.test.ts.
//
// The Message types require `content` to always be present, but untyped
// callers (custom tools, hand-built histories, old session files) can violate
// that contract. `transformMessages` is the choke point before every provider
// request and is intentionally lax: it normalizes null/missing content to an
// empty array (issues #6259, #6276).
//
// Swift: message `content` is non-optional, so null/missing content cannot be constructed.
// The expressible part is ported: messages whose content is already empty survive
// `transformMessages` (including the image downgrade path) with empty content.

/// Text-only model so the image downgrade path (replaceImagesWithPlaceholder) runs,
/// which was the primary crash site for null tool result content.
private func makeTextOnlyModel() -> Model {
	Model(
		id: "test-model",
		name: "Test Model",
		api: "openai-completions",
		provider: "openai",
		baseUrl: "https://example.invalid/v1",
		reasoning: false,
		input: ["text"],
		cost: ModelCost(input: 0, output: 0, cacheRead: 0, cacheWrite: 0),
		contextWindow: 128000,
		maxTokens: 16000
	)
}

@Suite("lax message content handling")
struct LaxMessageContentTests {
	// Not ported: `content: null` / missing `content` (Swift content fields are non-optional);
	// the empty-content equivalent below is what the upstream normalization produces.
	@Test("normalizes null/missing content to an empty array instead of crashing")
	func normalizesEmptyContent() {
		let messages: [Message] = [
			.user(UserMessage(content: .blocks([]), timestamp: dateNow())),
			.assistant(AssistantMessage(
				content: [],
				api: "openai-completions",
				provider: "openai",
				model: "test-model",
				usage: Usage(input: 0, output: 0, cacheRead: 0, cacheWrite: 0, totalTokens: 0, cost: UsageCost()),
				stopReason: .stop,
				timestamp: dateNow()
			)),
			.toolResult(ToolResultMessage(
				toolCallId: "call_1",
				toolName: "web_search",
				content: [],
				isError: false,
				timestamp: dateNow()
			)),
		]

		let result = transformMessages(messages, makeTextOnlyModel())

		#expect(result.count == 3)
		for msg in result {
			switch msg {
			case .user(let user): #expect(user.content == .blocks([]))
			case .assistant(let assistant): #expect(assistant.content.isEmpty)
			case .toolResult(let toolResult): #expect(toolResult.content.isEmpty)
			case .system: Issue.record("unexpected system message")
			}
		}
	}
}
