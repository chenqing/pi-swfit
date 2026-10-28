import Testing
@testable import PiAI

// Port of packages/ai/test/validation.test.ts.
// TypeBox `Type.*` schemas are written as the plain JSON Schema TypeBox 1.3.27 emits for them.

private func createToolCallWithPlainSchema(_ schema: JsonValue, _ value: JsonValue) -> (tool: Tool, toolCall: ToolCall) {
	let tool = Tool(
		name: "echo",
		description: "Echo tool",
		parameters: [
			"type": "object",
			"properties": [
				"value": schema,
			],
			"required": ["value"],
		]
	)

	let toolCall = ToolCall(
		id: "tool-1",
		name: "echo",
		arguments: ["value": value]
	)

	return (tool, toolCall)
}

/// `expect(() => fn()).toThrow(substring)`.
private func expectThrows(_ substring: String, sourceLocation: SourceLocation = #_sourceLocation, _ body: () throws -> Void) {
	do {
		try body()
		Issue.record("Expected an error containing \(substring.debugDescription)", sourceLocation: sourceLocation)
	} catch let error as PiError {
		#expect(error.message.contains(substring), "\(error.message)", sourceLocation: sourceLocation)
	} catch {
		Issue.record("Unexpected error type: \(error)", sourceLocation: sourceLocation)
	}
}

@Suite
struct ValidationTests {
	// MARK: validateToolArguments

	// Upstream replaces `globalThis.Function` to force TypeBox's interpreted (non-JIT) validator.
	// The Swift `TypeBoxValidator` is always interpreted, so the same assertion runs directly.
	@Test("still validates when Function constructor is unavailable")
	func stillValidatesWhenFunctionConstructorIsUnavailable() throws {
		let tool = Tool(
			name: "echo",
			description: "Echo tool",
			// Type.Object({ count: Type.Number() })
			parameters: [
				"type": "object",
				"required": ["count"],
				"properties": ["count": ["type": "number"]],
			]
		)
		let toolCall = ToolCall(
			id: "tool-1",
			name: "echo",
			arguments: ["count": "42"]
		)

		#expect(try validateToolArguments(tool, toolCall) == ["count": 42])
	}

	@Test("coerces serialized plain JSON schemas with AJV-compatible primitive rules")
	func coercesSerializedPlainJsonSchemas() throws {
		let passingCases: [(schema: JsonValue, input: JsonValue, expected: JsonValue)] = [
			(schema: ["type": "number"], input: "42", expected: 42),
			(schema: ["type": "number"], input: true, expected: 1),
			(schema: ["type": "number"], input: nil, expected: 0),
			(schema: ["type": "integer"], input: "42", expected: 42),
			(schema: ["type": "boolean"], input: "true", expected: true),
			(schema: ["type": "boolean"], input: "false", expected: false),
			(schema: ["type": "boolean"], input: 1, expected: true),
			(schema: ["type": "boolean"], input: 0, expected: false),
			(schema: ["type": "string"], input: nil, expected: ""),
			(schema: ["type": "string"], input: true, expected: "true"),
			(schema: ["type": "null"], input: "", expected: nil),
			(schema: ["type": "null"], input: 0, expected: nil),
			(schema: ["type": "null"], input: false, expected: nil),
			(
				schema: ["type": ["number", "string"]],
				input: "1",
				expected: "1"
			),
			(
				schema: ["type": ["boolean", "number"]],
				input: "1",
				expected: 1
			),
		]

		for testCase in passingCases {
			let (tool, toolCall) = createToolCallWithPlainSchema(testCase.schema, testCase.input)
			#expect(try validateToolArguments(tool, toolCall) == ["value": testCase.expected], "schema \(testCase.schema.serialized()) input \(testCase.input.serialized())")
		}
	}

	@Test("treats null as omission for optional non-nullable properties")
	func treatsNullAsOmissionForOptionalNonNullableProperties() throws {
		let tool = Tool(
			name: "echo",
			description: "Echo tool",
			// Type.Object({
			//   path: Type.String(),
			//   offset: Type.Optional(Type.Number()),
			//   nullable: Type.Optional(Type.Union([Type.String(), Type.Null()])),
			//   metadata: Type.Object({ enabled: Type.Optional(Type.Boolean()) }),
			// })
			parameters: [
				"type": "object",
				"required": ["path", "metadata"],
				"properties": [
					"path": ["type": "string"],
					"offset": ["type": "number"],
					"nullable": ["anyOf": [["type": "string"], ["type": "null"]]],
					"metadata": [
						"type": "object",
						"properties": ["enabled": ["type": "boolean"]],
					],
				],
			]
		)
		let toolCall = ToolCall(
			id: "tool-1",
			name: "echo",
			arguments: ["path": "file.txt", "offset": nil, "nullable": nil, "metadata": ["enabled": nil]]
		)

		#expect(try validateToolArguments(tool, toolCall) == [
			"path": "file.txt",
			"nullable": nil,
			"metadata": [:],
		])
	}

	@Test("preserves optional nulls whose referenced schema is nullable")
	func preservesOptionalNullsWhoseReferencedSchemaIsNullable() throws {
		let tool = Tool(
			name: "echo",
			description: "Echo tool",
			parameters: [
				"type": "object",
				"properties": ["value": ["$ref": "#/$defs/value"]],
				"$defs": ["value": ["anyOf": [["type": "number"], ["type": "null"]]]],
			]
		)
		let toolCall = ToolCall(
			id: "tool-1",
			name: "echo",
			arguments: ["value": nil]
		)

		#expect(try validateToolArguments(tool, toolCall) == ["value": nil])
	}

	@Test("preserves a value that already matches a nullable union arm")
	func preservesValueMatchingNullableUnionArm() throws {
		let tool = Tool(
			name: "echo",
			description: "Echo tool",
			// Type.Object({ value: Type.Union([Type.Number(), Type.Null()]) })
			parameters: [
				"type": "object",
				"required": ["value"],
				"properties": ["value": ["anyOf": [["type": "number"], ["type": "null"]]]],
			]
		)
		let toolCall = ToolCall(
			id: "tool-1",
			name: "echo",
			arguments: ["value": nil]
		)

		#expect(try validateToolArguments(tool, toolCall) == ["value": nil])
	}

	@Test("preserves a value that already matches a oneOf nullable union arm")
	func preservesValueMatchingOneOfNullableUnionArm() throws {
		let (tool, toolCall) = createToolCallWithPlainSchema(
			["oneOf": [["type": "number"], ["type": "null"]]],
			nil
		)

		#expect(try validateToolArguments(tool, toolCall) == ["value": nil])
	}

	@Test("still coerces nullable unions when the original value does not match any arm")
	func stillCoercesNullableUnionsWhenNoArmMatches() throws {
		let (tool, toolCall) = createToolCallWithPlainSchema(
			["anyOf": [["type": "number"], ["type": "null"]]],
			"42"
		)

		#expect(try validateToolArguments(tool, toolCall) == ["value": 42])
	}

	@Test("accepts null for nullable array schemas with items")
	func acceptsNullForNullableArraySchemasWithItems() throws {
		let (tool, toolCall) = createToolCallWithPlainSchema(
			["type": ["array", "null"], "items": ["type": "string"]],
			nil
		)
		// Upstream exercises TypeBox's generated (JIT) validator explicitly here; the Swift port has a
		// single interpreted validator, which stands in for `Compile(tool.parameters)`.
		let generatedCheck = TypeBoxValidator(tool.parameters)

		#expect(generatedCheck.check(.object(toolCall.arguments)) == true)
		#expect(try validateToolArguments(tool, toolCall) == ["value": nil])
	}

	@Test("rejects invalid coercions for serialized plain JSON schemas")
	func rejectsInvalidCoercionsForSerializedPlainJsonSchemas() {
		let failingCases: [(schema: JsonValue, input: JsonValue)] = [
			(schema: ["type": "boolean"], input: "1"),
			(schema: ["type": "boolean"], input: "0"),
			(schema: ["type": "null"], input: "null"),
			(schema: ["type": "integer"], input: "42.1"),
		]

		for testCase in failingCases {
			let (tool, toolCall) = createToolCallWithPlainSchema(testCase.schema, testCase.input)
			expectThrows("Validation failed") { _ = try validateToolArguments(tool, toolCall) }
		}
	}

	// #10897
	@Test("reports malformed arguments JSON instead of validating empty arguments")
	func reportsMalformedArgumentsJson() {
		let tool = Tool(
			name: "echo",
			description: "Echo tool",
			// Type.Object({ value: Type.Optional(Type.String()) })
			parameters: [
				"type": "object",
				"properties": ["value": ["type": "string"]],
			]
		)
		let toolCall = ToolCall(
			id: "tool-1",
			name: "echo",
			arguments: [:],
			argumentsError: "Unexpected token"
		)

		expectThrows("Invalid arguments for tool \"echo\": Unexpected token") {
			_ = try validateToolArguments(tool, toolCall)
		}
	}

	// MARK: Swift-only: TypeBox `format` keywords (expected results verified against typebox 1.3.27 `Compile(...).Check`)

	@Test(
		"format keywords match TypeBox",
		arguments: [
			("date", "2024-02-29", true),
			("date", "2023-02-29", false),
			("date", "2024-13-01", false),
			("date", "2024-1-01", false),
			("date", "2024-04-31", false),
			("time", "12:34:56Z", true),
			("time", "12:34:56+01:00", true),
			("time", "12:34:56", false),
			("time", "25:00:00Z", false),
			("time", "23:59:60Z", true),
			("time", "12:34:56.789-05:30", true),
			("date-time", "2024-01-01T12:00:00Z", true),
			("date-time", "2024-01-01 12:00:00Z", false),
			("date-time", "2024-01-01t12:00:00z", true),
			("date-time", "2024-01-01T12:00:00", false),
			("date-time", "2024-02-30T00:00:00Z", false),
			("email", "user@example.com", true),
			("email", "a.b+c@sub.example.org", true),
			("email", "not-an-email", false),
			("email", "user@", false),
			("email", "@example.com", false),
			("uuid", "123e4567-e89b-12d3-a456-426614174000", true),
			("uuid", "urn:uuid:123e4567-e89b-12d3-a456-426614174000", false),
			("uuid", "123e4567e89b12d3a456426614174000", false),
			("uuid", "123e4567-e89b-12d3-a456-42661417400g", false),
			("ipv4", "192.168.0.1", true),
			("ipv4", "255.255.255.255", true),
			("ipv4", "256.0.0.1", false),
			("ipv4", "1.2.3", false),
			("ipv4", "01.2.3.4", false),
			("ipv6", "::1", true),
			("ipv6", "2001:db8::8a2e:370:7334", true),
			("ipv6", "fe80::1%eth0", false),
			("ipv6", "2001:db8::g", false),
			("ipv6", "1:2:3:4:5:6:7:8", true),
			("ipv6", "::ffff:192.168.0.1", true),
			("uri", "https://example.com/path?q=1#frag", true),
			("uri", "mailto:user@example.com", true),
			("uri", "urn:isbn:0451450523", true),
			("uri", "/relative/path", false),
			("uri", "example.com", false),
			("uri", "http://exa mple.com", false),
		] as [(String, String, Bool)]
	)
	func formatKeywordsMatchTypeBox(format: String, value: String, expected: Bool) {
		let validator = TypeBoxValidator(["type": "string", "format": .string(format)])
		#expect(validator.check(.string(value)) == expected)
	}

	@Test("format keyword ignores non-strings and unknown formats")
	func formatKeywordIgnoresNonStringsAndUnknownFormats() {
		#expect(TypeBoxValidator(["format": "email"]).check(5) == true)
		#expect(TypeBoxValidator(["format": "email"]).check("x") == false)
		#expect(TypeBoxValidator(["type": "string", "format": "unknown-format"]).check("anything") == true)
	}

	@Test("format failures are reported by validateToolArguments")
	func formatFailuresAreReported() {
		let tool = Tool(
			name: "echo",
			description: "Echo tool",
			parameters: [
				"type": "object",
				"properties": [
					"when": ["type": "string", "format": "date-time"],
					"id": ["type": "string", "format": "uuid"],
				],
				"required": ["when", "id"],
			]
		)
		let toolCall = ToolCall(
			id: "tool-1",
			name: "echo",
			arguments: JsonObject([("when", "nope"), ("id", "123e4567-e89b-12d3-a456-426614174000")])
		)

		expectThrows(
			"Validation failed for tool \"echo\":\n  - when: must match format \"date-time\"\n\nReceived arguments:\n{\n  \"when\": \"nope\",\n  \"id\": \"123e4567-e89b-12d3-a456-426614174000\"\n}"
		) {
			_ = try validateToolArguments(tool, toolCall)
		}
	}
}
