import Testing
@testable import PiAI

// Port of packages/ai/test/json-parse.test.ts.
@Suite
struct JsonParseTests {
	// MARK: parseStreamingJson

	// #10868
	@Test("keeps invalid \\u escapes as literal text without dropping fields")
	func keepsInvalidUnicodeEscapesAsLiteralText() {
		#expect(parseStreamingJson(#"{"text":"\url{x}"}"#) == ["text": "\\url{x}"])
		#expect(parseStreamingJson(#"{"path":"a.tex","content":"\usepackage{x}","mode":"w"}"#) == [
			"path": "a.tex",
			"content": "\\usepackage{x}",
			"mode": "w",
		])
	}

	@Test("decodes valid \\u escapes")
	func decodesValidUnicodeEscapes() {
		#expect(parseStreamingJson(#"{"text":"caf\u00e9 \url"}"#) == ["text": "café \\url"])
	}

	@Test("omits a \\u escape that is cut off mid-stream")
	func omitsCutOffUnicodeEscape() {
		#expect(parseStreamingJson(#"{"text":"ab\u00"#) == ["text": "ab"])
	}

	// MARK: parseToolCallArguments (#10897)

	@Test("parses complete JSON and repairs invalid escapes")
	func parsesCompleteJsonAndRepairsInvalidEscapes() {
		#expect(parseToolCallArguments(#"{"kind":"seek","note":"\url"}"#) == ParsedToolCallArguments(
			arguments: ["kind": "seek", "note": "\\url"]
		))
	}

	@Test("uses empty arguments for empty text")
	func usesEmptyArgumentsForEmptyText() {
		#expect(parseToolCallArguments("") == ParsedToolCallArguments(arguments: [:]))
	}

	@Test("does not keep the valid prefix of malformed JSON")
	func doesNotKeepValidPrefixOfMalformedJson() {
		let raw = #"{"action":"apply","actions":[{"kind":"seek","time":.5}]}"#
		let result = parseToolCallArguments(raw)
		#expect(result.arguments == [:])
		#expect(result.argumentsError?.contains("\n\nReceived arguments:\n") == true)
		#expect(result.argumentsError?.hasSuffix(raw) == true)
	}

	@Test("does not complete cut-off JSON")
	func doesNotCompleteCutOffJson() {
		let raw = #"{"kind":"seek","clipId":"clip-fl"#
		let result = parseToolCallArguments(raw)
		#expect(result.arguments == [:])
		#expect(result.argumentsError?.hasSuffix(raw) == true)
	}

	@Test("rejects JSON that is not an object")
	func rejectsJsonThatIsNotAnObject() {
		#expect(parseToolCallArguments("[1,2]") == ParsedToolCallArguments(
			arguments: [:],
			argumentsError: "Tool arguments must be a JSON object\n\nReceived arguments:\n[1,2]"
		))
	}
}
