import Testing
@testable import PiAI

// Port of packages/ai/test/transcript-tool-changes.test.ts.
//
// Every test except "resolves the top-level tool boundary per transport" captures the provider
// request payload through `streamSimple(...)` + `onPayload` against real provider implementations
// (anthropic-messages, openai-responses, openai-completions) and the built-in model registry
// (`getModel("kimi-coding", ...)`). Those are not ported here: they test api/<provider>.ts payload
// building, not transcript.ts.

/// `Type.Object({})`
private let emptyObjectSchema: JsonValue = ["type": "object", "properties": [:]]

private func tool(_ name: String) -> Tool {
	Tool(name: name, description: "\(name) tool", parameters: emptyObjectSchema)
}

private func json(_ tools: [Tool]) -> JsonValue { .array(tools.map(\.json)) }

private let baseTool = tool("base_tool")
private let lateTool = tool("late_tool")
private let dropTool = tool("drop_tool")

private func withDescription(_ tool: Tool, _ description: String) -> Tool {
	var copy = tool
	copy.description = description
	return copy
}

private func expectTools(_ actual: TranscriptTools, _ requestTools: [Tool], _ foldedSystemMessages: Int, sourceLocation: SourceLocation = #_sourceLocation) {
	#expect(json(actual.requestTools) == json(requestTools), sourceLocation: sourceLocation)
	#expect(actual.foldedSystemMessages == foldedSystemMessages, sourceLocation: sourceLocation)
}

@Suite("transcript system messages")
struct TranscriptToolChangesTests {
	// Not ported: "sends Anthropic updates and tool changes in native system messages" (anthropic-messages payload capture via streamSimple)
	// Not ported: "redefines an Anthropic tool by value under the same name" (anthropic-messages payload capture)
	// Not ported: "sends the current Anthropic tool list without an initial tool" (anthropic-messages payload capture)
	// Not ported: "folds Anthropic updates into the system prompt without native support" (anthropic-messages payload capture)
	// Not ported: "requires both Anthropic capabilities for native tool changes" (anthropic-messages payload capture)
	// Not ported: "declares every OpenAI tool in additional_tools at its developer message" (openai-responses payload capture)
	// Not ported: "maps system-message additions into synthetic tool search" (openai-responses payload capture)
	// Not ported: "folds OpenAI updates into the leading developer message without native support" (openai-responses payload capture)
	// Not ported: "announces OpenAI removals as text" (openai-responses payload capture)
	// Not ported: "redefines an OpenAI tool with additional_tools instead of announcing a removal" (openai-responses payload capture)
	// Not ported: "keeps the OpenAI request prefix across a removal and later loads" (openai-responses payload capture)
	// Not ported: "stops listing a tool as unavailable once it is declared again" (openai-responses payload capture)
	// Not ported: "does not list a tool as still unavailable before its removal is announced" (openai-responses payload capture)
	// Not ported: "keeps the OpenAI tool search prefix across loads after a removal" (openai-responses payload capture)

	// #10940: removals and redeclarations move the top-level boundary once; plain additions stay anchored.
	@Test("resolves the top-level tool boundary per transport")
	func resolvesTopLevelToolBoundary() {
		let messages: [Message] = [
			.system(SystemMessage(content: "base prompt", toolsAdded: [baseTool, dropTool], timestamp: 0)),
			.system(SystemMessage(content: "", toolsRemoved: [ToolReference(name: "drop_tool")], timestamp: 1)),
			.system(SystemMessage(content: "", toolsAdded: [dropTool], timestamp: 2)),
			.system(SystemMessage(content: "", toolsAdded: [withDescription(lateTool, "x")], timestamp: 3)),
			.system(SystemMessage(content: "", toolsAdded: [withDescription(lateTool, "y")], timestamp: 4)),
		]

		expectTools(resolveTranscriptTools(Array(messages[0..<2]), .additions), [baseTool], 2)
		// Kimi K3 ignores a removed tool that a later tool message declares again, so the re-added
		// drop_tool moves the boundary; the new late_tool after it stays anchored.
		expectTools(resolveTranscriptTools(Array(messages[0..<4]), .additions), [baseTool, dropTool], 3)
		// The redefinition of late_tool moves the boundary to its message.
		expectTools(resolveTranscriptTools(messages, .additions), [baseTool, dropTool, withDescription(lateTool, "y")], 5)
		expectTools(resolveTranscriptTools(messages, .changes), [], 0)
		expectTools(resolveTranscriptTools(messages, .none), [baseTool, dropTool, withDescription(lateTool, "y")], 5)
	}

	// Not ported: "anchors Kimi additions in tool-bearing system messages" (openai-completions payload capture)
	// Not ported: "keeps the Kimi prefix across loads after a removal" (openai-completions payload capture + models.ts getModel("kimi-coding", "k3"))
	// Not ported: "anchors additions for Kimi Coding %s" for k3, k3-256k, kimi-for-coding (openai-completions payload capture + models.ts getModel)
	// Not ported: "keeps Kimi Coding Highspeed additions in top-level tools" (openai-completions payload capture + models.ts getModel)
	// Not ported: "keeps Kimi K2 system text inline without dynamic tool messages" (openai-completions payload capture)
	// Not ported: "folds OpenAI-compatible updates into the system prompt without native support" (openai-completions payload capture)
}
