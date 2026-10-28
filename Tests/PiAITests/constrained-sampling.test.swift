import Foundation
import Testing
@testable import PiAI

// Port of packages/ai/test/constrained-sampling.test.ts (the api/constrained-sampling.ts parts).
// The Responses-specific cases (convertResponsesTools / convertResponsesMessages / processResponsesStream)
// belong to the openai-responses port; their Chat Completions counterparts are covered through
// `streamOpenAICompletions` below.

private func thrownMessage(_ body: () throws -> Any?) -> String? {
    do {
        _ = try body()
        return nil
    } catch {
        return errorMessage(error)
    }
}

private func makeTool(parameters: JsonValue? = nil, constrainedSampling: ConstrainedSamplingConfig?? = nil) -> Tool {
    Tool(
        name: "sample_tool", description: "Sample tool",
        // Type.Object({ payload: Type.String() }, { additionalProperties: false })
        parameters: parameters ?? cJSON(#"{"additionalProperties":false,"type":"object","properties":{"payload":{"type":"string"}},"required":["payload"]}"#),
        constrainedSampling: constrainedSampling
    )
}

@Suite("constrained tool sampling")
struct ConstrainedSamplingTests {
    @Test func incrementalGrammarInputAndFinalReconciliation() throws {
        var buffer = GrammarToolInputJsonBuffer()
        #expect(try appendGrammarToolInputJsonDelta(&buffer, "payload", "") == nil)
        var text = try #require(try appendGrammarToolInputJsonDelta(&buffer, "payload", "a\n"))
        text += try #require(try appendGrammarToolInputJsonDelta(&buffer, "payload", "\"中😀"))
        text += try #require(try closeGrammarToolInputJson(&buffer, "payload", "a\n\"中😀 tail"))
        #expect(try JsonValue.parse(text) == ["payload": "a\n\"中😀 tail"])
        #expect(try closeGrammarToolInputJson(&buffer, "payload") == nil)
        #expect(try closeGrammarToolInputJson(&buffer, "payload", buffer.input) == nil)
        #expect(thrownMessage { try closeGrammarToolInputJson(&buffer, "payload", "other") }?.contains("changed after it was closed") == true)
        #expect(thrownMessage { try appendGrammarToolInputJsonDelta(&buffer, "payload", "") }?.contains("changed after it was closed") == true)
        var partial = GrammarToolInputJsonBuffer()
        _ = try appendGrammarToolInputJsonDelta(&partial, "payload", "ab")
        #expect(thrownMessage { try closeGrammarToolInputJson(&partial, "payload", "a") }?.contains("changed non-monotonically") == true)
    }

    @Test func largeGrammarInputAndInitialPayload() throws {
        let stream = StreamingGrammarToolInput(property: "code", initialInput: "// start\n")
        let chunk = String(repeating: "let x = \"😀\";\n", count: 8)
        var deltas = ""
        let start = ContinuousClock.now
        for _ in 0..<4_000 { deltas += try stream.update(chunk, close: false).delta ?? "" }
        let final = try stream.update(nil, close: true)
        deltas += final.delta ?? ""
        let expected = "// start\n" + String(repeating: chunk, count: 4_000)
        #expect(final.arguments == ["code": .string(expected)])
        #expect(try JsonValue.parse(deltas) == .object(final.arguments))
        #expect(try stream.update(expected, close: true).delta == nil)
        #expect(start.duration(to: .now) < .seconds(10))
    }

    @Test("derives strict provider schemas without changing tool definitions")
    func derivesStrictSchemas() throws {
        // Type.Object({ path, offset?, metadata: { enabled? }, nullable?: string | null })
        let parameters = cJSON(#"""
        {"type":"object","properties":{"path":{"type":"string"},"offset":{"type":"number"},"metadata":{"type":"object","properties":{"enabled":{"type":"boolean"}}},"nullable":{"anyOf":[{"type":"string"},{"type":"null"}]}},"required":["path","metadata"]}
        """#)
        let original = parameters

        let strict = try makeStrictJsonSchema(parameters)

        #expect(parameters == original)
        #expect(parameters["additionalProperties"] == nil)
        #expect(parameters["required"] == cJSON(#"["path","metadata"]"#))
        #expect(cMatches(strict, cJSON(#"""
        {"additionalProperties":false,"required":["path","offset","metadata","nullable"],"properties":{
          "offset":{"anyOf":[{"type":"number"},{"type":"null"}]},
          "metadata":{"additionalProperties":false,"required":["enabled"],"properties":{"enabled":{"anyOf":[{"type":"boolean"},{"type":"null"}]}}},
          "nullable":{"anyOf":[{"type":"string"},{"type":"null"}]}}}
        """#)))
    }

    @Test("falls back or rejects schemas that cannot be safely converted")
    func fallsBackOrRejects() throws {
        let cases: [(parameters: JsonValue, error: String)] = [
            (cJSON(#"{"type":"object","properties":{"metadata":{"additionalProperties":{"type":"string"},"type":"object","properties":{}}},"required":["metadata"]}"#), "additionalProperties is unsupported"),
            (cJSON(#"{"allOf":[{"type":"object","properties":{"a":{"type":"string"}},"required":["a"]},{"type":"object","properties":{"b":{"type":"number"}},"required":["b"]}]}"#), "allOf schemas are unsupported"),
            (cJSON(#"{"type":"object","properties":{"value":{"anyOf":[{"type":"object","properties":{"nested":{"type":"string"}},"required":["nested"]},{"type":"null"}]}},"required":["value"]}"#), "object and array unions are unsupported"),
            (cJSON(#"{"type":"object","properties":{"child":{"$ref":"https://example.com/child.json"}},"required":["child"]}"#), "$ref schemas are unsupported"),
        ]

        for (parameters, error) in cases {
            var tool = makeTool(parameters: parameters, constrainedSampling: .some(.jsonSchema(strict: "prefer")))

            #expect(thrownMessage { try makeStrictJsonSchema(parameters) }?.contains(error) == true, "\(error)")
            #expect(try resolveJsonSchemaStrictSampling(tool, true) == nil)
            #expect(try getJsonSchemaToolParameters(tool, try resolveJsonSchemaStrictSampling(tool, true)) == parameters)

            tool.constrainedSampling = .some(.jsonSchema(strict: "require"))
            #expect(thrownMessage { try resolveJsonSchemaStrictSampling(tool, true) }?.contains(error) == true, "\(error)")
        }
    }

    @Test("resolves json_schema and grammar constraints like convertResponsesTools")
    func resolvesConstraints() throws {
        #expect(try resolveJsonSchemaStrictSampling(makeTool(constrainedSampling: .some(.jsonSchema(strict: "prefer"))), true) == true)
        #expect(thrownMessage {
            try resolveJsonSchemaStrictSampling(makeTool(constrainedSampling: .some(.jsonSchema(strict: "require"))), false)
        }?.contains(#"Tool "sample_tool" requires JSON-schema constrained sampling"#) == true)

        let grammarTool = makeTool(constrainedSampling: .some(.grammar(variants: [(format: "openai_lark", grammar: "start: /[a-z]+/")])))
        let grammar = try #require(try resolveGrammarConstrainedSampling(grammarTool, true))
        #expect(grammar.format == "lark")
        #expect(grammar.definition == "start: /[a-z]+/")
        #expect(grammar.inputProperty == "payload")
        #expect(thrownMessage {
            try resolveGrammarConstrainedSampling(makeTool(constrainedSampling: .some(.grammar(variants: []))), true)
        } == #"Tool "sample_tool" cannot use grammar constrained sampling: no supported grammar variant was provided."#)
        #expect(try resolveGrammarConstrainedSampling(grammarTool, false) == nil)
        #expect(try createGrammarToolInputProperties([grammarTool], true) == ["sample_tool": "payload"])
        #expect(try createGrammarToolInputProperties([grammarTool], false).isEmpty)

        // constrainedSampling: false behaves like no constraint.
        #expect(try resolveJsonSchemaStrictSampling(makeTool(constrainedSampling: .some(nil)), true) == resolveJsonSchemaStrictSampling(makeTool(), true))
    }

    @Test("rejects grammar replays whose input argument is not a string")
    func grammarReplayInput() throws {
        for invalid in [JsonObject(), ["payload": 42] as JsonObject] {
            #expect(thrownMessage { try getGrammarToolInput("sample_tool", invalid, "payload") }?
                .hasPrefix(#"Grammar tool call "sample_tool" requires argument "payload" to be a string"#) == true)
        }
        #expect(try getGrammarToolInput("sample_tool", ["payload": "abc"], "payload") == "abc")
    }

    @Test("keeps grammar input JSON deltas append-only")
    func grammarDeltasAppendOnly() throws {
        var buffer = GrammarToolInputJsonBuffer(input: "", started: false, closed: false)
        let first = try appendGrammarToolInputJsonDelta(&buffer, "payload", "a\"", false)
        let second = try appendGrammarToolInputJsonDelta(&buffer, "payload", "a\"\nb", true)

        #expect(cJSON((first ?? "") + (second ?? "")) == ["payload": "a\"\nb"])
        #expect(try appendGrammarToolInputJsonDelta(&buffer, "payload", "a\"\nb", true) == nil)
        #expect(thrownMessage { try appendGrammarToolInputJsonDelta(&buffer, "payload", "changed", true) }
            == #"grammar tool input for property "payload" changed after it was closed"#)
    }

    @Test("Chat Completions sends strict tools, falls back, and streams grammar tool calls")
    func completionsIntegration() async throws {
        let model = cModel(#"{"id":"gpt-test","name":"GPT Test","api":"openai-completions","provider":"openai","baseUrl":"https://api.openai.com/v1","reasoning":false,"input":["text"],"cost":{"input":0,"output":0,"cacheRead":0,"cacheWrite":0},"contextWindow":128000,"maxTokens":4096,"compat":{"supportsStrictMode":true}}"#)

        let strictRun = try await cRunStream(model, cUserContext("hi", tools: [makeTool(constrainedSampling: .some(.jsonSchema(strict: "prefer")))]))
        #expect(cMatches(strictRun.payload["tools"]?[0], cJSON(#"{"type":"function","function":{"name":"sample_tool","strict":true}}"#)))

        var nonStrict = model
        nonStrict.compat = ["supportsStrictMode": false]
        let fallbackRun = try await cRunStream(nonStrict, cUserContext("hi", tools: [makeTool(constrainedSampling: .some(.jsonSchema(strict: "prefer")))]))
        #expect(fallbackRun.payload["tools"]?[0]?["function"]?["strict"] == nil)

        let requireRun = try await cRunStream(nonStrict, cUserContext("hi", tools: [makeTool(constrainedSampling: .some(.jsonSchema(strict: "require")))]))
        #expect(requireRun.result.stopReason == .error)
        #expect(requireRun.result.errorMessage?.contains(#"Tool "sample_tool" requires JSON-schema constrained sampling"#) == true)
    }
}
