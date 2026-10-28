import Foundation
import Testing
@testable import PiAI

// Port of packages/ai/test/anthropic-strict-tool-schema.test.ts

private func createModel() -> Model {
    Model(
        id: "claude-opus-4-8",
        name: "Claude Opus 4.8",
        api: "anthropic-messages",
        provider: "test-anthropic",
        baseUrl: "http://127.0.0.1:9",
        reasoning: true,
        input: ["text"],
        cost: ModelCost(),
        contextWindow: 200_000,
        maxTokens: 32_000,
        compat: ["forceAdaptiveThinking": true, "supportsStrictTools": true]
    )
}

private func createTool(_ parameters: JsonValue, _ constrainedSampling: ConstrainedSamplingConfig? = nil) -> Tool {
    Tool(
        name: "lookup",
        description: "Look up a value",
        parameters: parameters,
        constrainedSampling: constrainedSampling.map { .some($0) }
    )
}

private func createStrictTool(_ parameters: JsonValue) -> Tool {
    createTool(parameters, .jsonSchema(strict: "prefer"))
}

private func captureFirstTool(_ tool: Tool) async throws -> JsonValue {
    let captured = Locked<JsonObject?>(nil)
    var options = AnthropicOptions()
    options.apiKey = "test-key"
    options.cacheRetention = CacheRetention.none
    options.onPayload = { value, _ in
        captured.withLock { $0 = value.objectValue }
        throw PiError("payload captured", name: "PayloadCaptured")
    }
    let context = Context(messages: [.user(UserMessage(content: "Use the tool"))], tools: [tool])
    _ = await streamAnthropicMessages(createModel(), normalizeContext(context), options).result()
    return try #require(captured.withLock { $0 }?["tools"]?[0], "Expected a tool in the captured Anthropic payload")
}

/// `Type.Object(properties)`: required lists every non-optional property.
private func object(_ properties: JsonObject, optional: Set<String> = [], extra: JsonObject = JsonObject()) -> JsonValue {
    var schema: JsonObject = ["type": "object"]
    for (key, value) in extra { schema[key] = value }
    schema["properties"] = .object(properties)
    let required = properties.keys.filter { !optional.contains($0) }
    if !required.isEmpty { schema["required"] = .array(required.map(JsonValue.string)) }
    return .object(schema)
}

/// vitest `toMatchObject`: objects match recursively by subset, arrays element-wise with equal length.
private func matchesObject(_ actual: JsonValue?, _ expected: JsonValue) -> Bool {
    switch expected {
    case .object(let expectedObject):
        guard case .object(let actualObject)? = actual else { return false }
        return expectedObject.allSatisfy { matchesObject(actualObject[$0.key], $0.value) }
    case .array(let expectedArray):
        guard case .array(let actualArray)? = actual, actualArray.count == expectedArray.count else { return false }
        return zip(actualArray, expectedArray).allSatisfy { matchesObject($0, $1) }
    default:
        return actual == expected
    }
}

@Suite("Anthropic strict tool schemas")
struct AnthropicStrictToolSchemaTests {
    @Test("only sends the full input schema for strict JSON-schema tools")
    func onlySendsFullSchemaForStrictTools() async throws {
        let legacyParameters = object(["value": ["type": "string"]], extra: ["additionalProperties": false, "title": "LookupInput"])
        let legacyTool = try await captureFirstTool(createTool(legacyParameters))
        #expect(legacyTool["strict"] == nil)
        #expect(legacyTool["input_schema"] == [
            "type": "object",
            "properties": legacyParameters["properties"]!,
            "required": legacyParameters["required"]!,
        ])

        let strictTool = try await captureFirstTool(
            createStrictTool(object(
                ["value": ["type": "string"], "optional": ["type": "number"]],
                optional: ["optional"],
                extra: ["title": "StrictLookupInput"]
            ))
        )
        #expect(strictTool["strict"] == true)
        #expect(matchesObject(strictTool["input_schema"], [
            "additionalProperties": false,
            "required": ["value", "optional"],
            "properties": ["optional": ["anyOf": [["type": "number"], ["type": "null"]]]],
            "title": "StrictLookupInput",
        ]))
    }

    // https://github.com/earendil-works/pi/issues/9953
    @Test("sends prefer tools non-strict when they use keywords Anthropic strict mode rejects")
    func sendsPreferToolsNonStrictForUnsupportedKeywords() async throws {
        let unsupportedParameters: [JsonValue] = [
            object(["timeoutMs": ["type": "integer", "minimum": 1, "maximum": 300_000]], optional: ["timeoutMs"]),
            object(["options": object(["tags": ["type": "array", "items": ["type": "string"], "minItems": 2]])]),
            object(["expression": ["type": "string", "format": "regex"]]),
        ]
        for parameters in unsupportedParameters {
            let tool = try await captureFirstTool(createStrictTool(parameters))
            #expect(tool["strict"] == nil, "\(parameters.serialized())")
        }

        let supportedTool = try await captureFirstTool(
            createStrictTool(object([
                "code": ["type": "string", "minLength": 1, "maxLength": 1000, "pattern": "^[a-z]+$"],
                "url": ["type": "string", "format": "uri"],
                "tags": ["type": "array", "items": ["type": "string"], "minItems": 1],
            ]))
        )
        #expect(supportedTool["strict"] == true)
    }
}
