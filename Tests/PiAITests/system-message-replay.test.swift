import Testing
@testable import PiAI

// Port of packages/ai/test/system-message-replay.test.ts.
//
// Swift: `SystemMessage`, `Tool` and `Message` are not Equatable (tools carry JSON Schema and
// optional configs); upstream `toEqual` is ported as equality of the upstream JSON shapes
// (`.json`), which, like `toEqual`, ignores object key order.

/// `Type.Object({})`
private let emptyObjectSchema: JsonValue = ["type": "object", "properties": [:]]

private func tool(_ name: String, _ description: String? = nil) -> Tool {
	Tool(name: name, description: description ?? "\(name) tool", parameters: emptyObjectSchema)
}

private func json(_ messages: [Message]) -> JsonValue { .array(messages.map(\.json)) }
private func json(_ tools: [Tool]) -> JsonValue { .array(tools.map(\.json)) }

private let transcript = normalizeContext(Context(
	messages: [
		.system(SystemMessage(
			content: "base",
			sections: [(name: "a", text: "<a>1</a>"), (name: "b", text: "<b>1</b>")],
			toolsAdded: [tool("first")],
			timestamp: 10
		)),
		.user(UserMessage(content: "hello", timestamp: 11)),
		.system(SystemMessage(content: "also do this", timestamp: 12)),
		// Upstream: `{ role: "assistant", content: [...], timestamp: 13 } as never` (no api/provider/model).
		.assistant(AssistantMessage(content: [.text(TextContent(text: "ok"))], api: "", provider: "", model: "", timestamp: 13)),
		.system(SystemMessage(
			content: "",
			sections: [(name: "a", text: "<a>2</a>"), (name: "b", text: nil), (name: "c", text: "<c>1</c>")],
			toolsAdded: [tool("second")],
			toolsRemoved: [ToolReference(name: "first")],
			timestamp: 14
		)),
	]
))

@Suite("system message replay")
struct SystemMessageReplayTests {
	@Test("replays content, sections, and tools into one leading message")
	func replaysIntoOneLeadingMessage() {
		let current = getCurrentSystemMessage(transcript.messages)
		#expect(current?.json == SystemMessage(
			content: "base\n\nalso do this",
			sections: [(name: "a", text: "<a>2</a>"), (name: "c", text: "<c>1</c>")],
			toolsAdded: [tool("second")],
			timestamp: 10
		).json)
		#expect(getCurrentSystemPrompt(transcript.messages) == "base\n\nalso do this\n\n<a>2</a>\n\n<c>1</c>")
	}

	@Test("collapse keeps only non-system messages after the replayed head")
	func collapseKeepsOnlyNonSystemMessages() {
		let collapsed = collapseSystemMessages(transcript)
		#expect(collapsed.messages.map(\.role) == ["system", "user", "assistant"])
		#expect(json(collapseSystemMessages(collapsed).messages) == json(collapsed.messages))
	}

	@Test("replay of a transcript without system messages is empty")
	func replayWithoutSystemMessagesIsEmpty() {
		let context = normalizeContext(Context(messages: [.user(UserMessage(content: "hi", timestamp: 1))]))
		#expect(getCurrentSystemMessage(context.messages) == nil)
		#expect(getCurrentSystemPrompt(context.messages) == "")
		#expect(json(collapseSystemMessages(context).messages) == json(context.messages))
	}

	@Test("a late full patch on a transcript without a leading message replays as the prompt")
	func lateFullPatchReplaysAsPrompt() {
		let context: TranscriptContext = normalizeContext(Context(
			messages: [
				.user(UserMessage(content: "old session", timestamp: 1)),
				.system(SystemMessage(
					content: "",
					sections: [(name: "preamble", text: "You are pi.")],
					toolsAdded: [tool("x")],
					timestamp: 2
				)),
			]
		))
		#expect(getCurrentSystemPrompt(context.messages) == "You are pi.")
		let head = collapseSystemMessages(context).messages.first
		#expect(head?.role == "system")
		#expect(head?.systemMessage?.toolsAdded.map(json) == json([tool("x")]))
	}

	@Test("renders complete prompts and framed updates")
	func rendersPromptsAndUpdates() throws {
		guard let leading = transcript.messages[0].systemMessage, let update = transcript.messages[4].systemMessage else {
			Issue.record("expected system messages")
			return
		}
		#expect(getSystemMessageText(leading) == "base\n\n<a>1</a>\n\n<b>1</b>")
		#expect(renderSystemMessageUpdate(update) == [
			"Updated system prompt section \"a\":\n\n<a>2</a>",
			"Removed system prompt section \"b\".",
			"Updated system prompt section \"c\":\n\n<c>1</c>",
		].joined(separator: "\n\n"))
	}

	@Test("normalizes the legacy prompt and tool fields into a leading system message")
	func normalizesLegacyFields() {
		let messages: [Message] = [.user(UserMessage(content: "hi", timestamp: 1))]
		#expect(json(normalizeContext(Context(messages: messages)).messages) == json(messages))
		#expect(json(normalizeContext(Context(systemPrompt: "", messages: messages, tools: [])).messages) == json(messages))
		#expect(json(normalizeContext(Context(systemPrompt: "be brief", messages: messages, tools: [tool("a")])).messages) == json(
			[.system(SystemMessage(content: "be brief", toolsAdded: [tool("a")], timestamp: 0))] + messages
		))
	}

	@Test("compares tool declarations without executable or undefined fields")
	func comparesToolDeclarations() {
		// Swift `Tool` has no `execute`; an unset `constrainedSampling` is the `undefined` field.
		let executable = Tool(name: "a", description: "a tool", parameters: emptyObjectSchema, constrainedSampling: nil)
		#expect(declarationsEqual(executable, tool("a")))
		#expect(!declarationsEqual(tool("a"), tool("a", "changed")))
		var constrainedFalse = tool("a")
		constrainedFalse.constrainedSampling = .some(.none)
		#expect(!declarationsEqual(tool("a"), constrainedFalse))
	}

	@Test("tool state changes treat changed definitions as removal plus addition")
	func toolStateChanges() {
		let changes = getToolStateChanges([tool("a"), tool("b")], [tool("b", "changed"), tool("c")])
		#expect(json(changes.toolsAdded) == json([tool("b", "changed"), tool("c")]))
		#expect(changes.toolsRemoved == [ToolReference(name: "a"), ToolReference(name: "b")])
		let unchanged = getToolStateChanges([tool("a")], [tool("a")])
		#expect(unchanged.toolsAdded.isEmpty)
		#expect(unchanged.toolsRemoved.isEmpty)
	}

	@Test("detects non-additive tool history and redefinitions")
	func detectsNonAdditiveHistory() {
		#expect(hasNonAdditiveToolChanges(transcript.messages) == true)
		#expect(hasToolRedefinitions(transcript.messages) == false)
		let additive = normalizeContext(Context(
			messages: [
				.system(SystemMessage(content: "", toolsAdded: [tool("a")], timestamp: 1)),
				.system(SystemMessage(content: "", toolsAdded: [tool("b")], timestamp: 2)),
			]
		))
		#expect(hasNonAdditiveToolChanges(additive.messages) == false)
		let redeclared = normalizeContext(Context(
			messages: [
				.system(SystemMessage(content: "", toolsAdded: [tool("a")], timestamp: 1)),
				.system(SystemMessage(content: "", toolsAdded: [tool("a", "changed")], timestamp: 2)),
			]
		))
		#expect(hasNonAdditiveToolChanges(redeclared.messages) == true)
		#expect(hasToolRedefinitions(redeclared.messages) == true)
	}
}
