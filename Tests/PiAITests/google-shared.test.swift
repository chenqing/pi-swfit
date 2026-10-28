import Foundation
import Testing
@testable import PiAI

// Ports of packages/ai/test/google-shared-convert-tools.test.ts, google-shared-retry.test.ts,
// google-thinking-signature.test.ts, google-shared-image-tool-result-routing.test.ts,
// google-shared-signed-empty-blocks.test.ts and google-shared-gemini3-unsigned-tool-call.test.ts.
//
// Swift: `convertTools` / `convertMessages` are `convertToolsGoogle` / `convertMessagesGoogle`. Contents are JSON,
// so `part.x` is `part["x"]`. `vi.useFakeTimers` is not available: the retry test waits the real 500ms backoff.

private func makeTool(_ parameters: JsonValue) -> Tool {
    Tool(name: "test_tool", description: "A test tool", parameters: parameters)
}

private func makeGoogleModel(_ id: String, api: String = "google-generative-ai", provider: String = "google", input: [ModelInputModality] = ["text"]) -> Model {
    Model(id: id, name: id, api: api, provider: provider, baseUrl: "https://example.com", reasoning: true, input: input, contextWindow: 128000, maxTokens: 8192)
}

private func assistant(_ model: Model, _ content: [AssistantContent], modelId: String? = nil) -> Message {
    var message = AssistantMessage(content: content, api: model.api, provider: model.provider, model: modelId ?? model.id, stopReason: .toolUse)
    message.usage = Usage()
    return .assistant(message)
}

private func toolResult(_ id: String, _ name: String, _ content: [UserContent]) -> Message {
    .toolResult(ToolResultMessage(toolCallId: id, toolName: name, content: content, isError: false))
}

private func parts(_ content: JsonValue?) -> [JsonValue] { content?["parts"]?.arrayValue ?? [] }

private func modelTurn(_ contents: [JsonValue]) -> JsonValue? { contents.first { $0["role"] == "model" } }

// MARK: - google-shared convertTools

@Suite("google-shared convertTools")
struct GoogleSharedConvertToolsTests {
    @Test("strips JSON Schema meta keys from parameters when useParameters=true")
    func stripsMetaKeys() throws {
        let tools = [makeTool([
            "$schema": "http://json-schema.org/draft-07/schema#",
            "$id": "urn:bash-tool",
            "$comment": "A bash tool for demonstration",
            "$defs": ["commandDef": ["type": "string"]],
            "definitions": ["legacyDef": ["type": "number"]],
            "type": "object",
            "properties": ["command": ["type": "string"]],
            "required": ["command"],
        ])]
        let result = try convertToolsGoogle(tools, true)
        let decl = try #require(result?[0]["functionDeclarations"]?[0])
        #expect(decl["parameters"] == [
            "type": "object",
            "properties": ["command": ["type": "string"]],
            "required": ["command"],
        ])
        for key in ["$schema", "$id", "$comment", "$defs", "definitions"] {
            #expect(decl["parameters"]?[key] == nil)
        }
    }

    @Test("recursively strips nested JSON Schema meta keys")
    func recursivelyStrips() throws {
        let tools = [makeTool([
            "$schema": "http://json-schema.org/draft-07/schema#",
            "type": "object",
            "properties": ["deep": ["$schema": "http://json-schema.org/draft-07/schema#", "$id": "urn:nested", "type": "string"]],
        ])]
        let decl = try #require(try convertToolsGoogle(tools, true)?[0]["functionDeclarations"]?[0])
        #expect(decl["parameters"] == ["type": "object", "properties": ["deep": ["type": "string"]]])
    }

    @Test("preserves $ref while stripping meta keys")
    func preservesRef() throws {
        let tools = [makeTool([
            "$schema": "http://json-schema.org/draft-07/schema#",
            "type": "object",
            "properties": ["refProp": ["$ref": "#/$defs/someDef", "type": "string"]],
        ])]
        let decl = try #require(try convertToolsGoogle(tools, true)?[0]["functionDeclarations"]?[0])
        #expect(decl["parameters"] == ["type": "object", "properties": ["refProp": ["$ref": "#/$defs/someDef", "type": "string"]]])
    }

    @Test("does not mutate the original Tool.parameters object")
    func doesNotMutate() throws {
        let originalParameters: JsonValue = [
            "$schema": "http://json-schema.org/draft-07/schema#",
            "type": "object",
            "properties": ["command": ["type": "string"]],
            "required": ["command"],
        ]
        let tools = [makeTool(originalParameters)]
        _ = try convertToolsGoogle(tools, true)
        #expect(tools[0].parameters == originalParameters)
    }

    @Test("preserves $schema in parametersJsonSchema when useParameters=false")
    func preservesSchemaInJsonSchema() throws {
        let parameters: JsonValue = [
            "$schema": "http://json-schema.org/draft-07/schema#",
            "type": "object",
            "properties": ["command": ["type": "string"]],
            "required": ["command"],
        ]
        let decl = try #require(try convertToolsGoogle([makeTool(parameters)], false)?[0]["functionDeclarations"]?[0])
        #expect(decl["parametersJsonSchema"] == parameters)
    }

    @Test("handles tools without $schema gracefully")
    func withoutSchema() throws {
        let parameters: JsonValue = ["type": "object", "properties": ["path": ["type": "string"]], "required": ["path"]]
        let decl = try #require(try convertToolsGoogle([makeTool(parameters)], true)?[0]["functionDeclarations"]?[0])
        #expect(decl["parameters"] == parameters)
    }

    @Test("uses validated function calling for strict tools on Gemini 3")
    func validatedForStrict() throws {
        var tool = makeTool(["type": "object", "properties": [:]])
        tool.constrainedSampling = .some(.jsonSchema(strict: "require"))

        #expect(supportsGoogleStrictToolSampling("gemini-3.1-pro-preview") == true)
        #expect(supportsGoogleStrictToolSampling("gemini-2.5-pro") == false)
        #expect(try resolveGoogleFunctionCallingMode([tool], nil, true) == "VALIDATED")
        let error = #expect(throws: (any Error).self) { try resolveGoogleFunctionCallingMode([tool], nil, false) }
        #expect(errorMessage(error!).contains("Tool \"test_tool\" requires JSON-schema constrained sampling"))
    }

    @Test("returns undefined for empty tool list")
    func emptyToolList() throws {
        #expect(try convertToolsGoogle([]) == nil)
        #expect(try convertToolsGoogle([], true) == nil)
    }
}

// MARK: - google request retries

private final class CallCounter: Sendable {
    let count = Locked(0)
    func next() -> Int { count.withLock { $0 += 1; return $0 } }
    var value: Int { count.withLock { $0 } }
}

/// Shaped like @google/genai's ApiError: has `status`, but no `headers`.
private func googleApiError(_ status: Int) -> GoogleGenAI.ApiError {
    GoogleGenAI.ApiError(message: "got status: \(status)", status: status)
}

@Suite("google request retries")
struct GoogleSharedRetryTests {
    @Test("retries a headers-less SDK error with a retryable status")
    func retriesHeaderlessError() async throws {
        let calls = CallCounter()
        var options = StreamOptions()
        options.maxRetries = 1
        let result = try await retryGoogleRequest({ () async throws -> String in
            if calls.next() == 1 { throw googleApiError(429) }
            return "ok"
        }, options)
        #expect(result == "ok")
        #expect(calls.value == 2)
    }

    @Test("does not retry when maxRetries is unset")
    func noRetryByDefault() async {
        let calls = CallCounter()
        let error = await #expect(throws: GoogleGenAI.ApiError.self) {
            try await retryGoogleRequest({ () async throws -> String in
                _ = calls.next()
                throw googleApiError(429)
            })
        }
        #expect(error?.status == 429)
        #expect(calls.value == 1)
    }

    @Test("does not retry a non-retryable status")
    func noRetryNonRetryable() async {
        let calls = CallCounter()
        var options = StreamOptions()
        options.maxRetries = 2
        let error = await #expect(throws: GoogleGenAI.ApiError.self) {
            try await retryGoogleRequest({ () async throws -> String in
                _ = calls.next()
                throw googleApiError(400)
            }, options)
        }
        #expect(error?.status == 400)
        #expect(calls.value == 1)
    }
}

// MARK: - Google thinking detection (thoughtSignature)

@Suite("Google thinking detection (thoughtSignature)")
struct GoogleThinkingSignatureTests {
    @Test("treats part.thought === true as thinking")
    func thoughtTrue() {
        #expect(isThinkingPart(["thought": true]) == true)
        #expect(isThinkingPart(["thought": true, "thoughtSignature": "opaque-signature"]) == true)
    }

    @Test("does not treat thoughtSignature alone as thinking")
    func signatureAlone() {
        // Per Google docs, thoughtSignature is for context replay and can appear on any part type.
        // Only thought === true indicates thinking content.
        // See: https://ai.google.dev/gemini-api/docs/thought-signatures
        #expect(isThinkingPart(["thoughtSignature": "opaque-signature"]) == false)
        #expect(isThinkingPart(["thought": false, "thoughtSignature": "opaque-signature"]) == false)
    }

    @Test("does not treat empty/missing signatures as thinking if thought is not set")
    func emptySignatures() {
        #expect(isThinkingPart([:]) == false)
        #expect(isThinkingPart(["thought": false, "thoughtSignature": ""]) == false)
    }

    @Test("preserves the existing signature when subsequent deltas omit thoughtSignature")
    func preservesExisting() {
        let first = retainThoughtSignature(nil, "sig-1")
        #expect(first == "sig-1")
        let second = retainThoughtSignature(first, nil)
        #expect(second == "sig-1")
        let third = retainThoughtSignature(second, "")
        #expect(third == "sig-1")
    }

    @Test("updates the signature when a new non-empty signature arrives")
    func updates() {
        #expect(retainThoughtSignature("sig-1", "sig-2") == "sig-2")
    }
}

// MARK: - google-shared image tool result routing

private func imageRoutingContext(_ model: Model) -> Context {
    Context(messages: [
        .user(UserMessage(content: "read the files")),
        assistant(model, [
            .toolCall(ToolCall(id: "call_a", name: "read", arguments: ["path": "a.txt"])),
            .toolCall(ToolCall(id: "call_img", name: "read", arguments: ["path": "image.png"])),
            .toolCall(ToolCall(id: "call_b", name: "read", arguments: ["path": "b.txt"])),
        ]),
        toolResult("call_a", "read", [.text(TextContent(text: "alpha text"))]),
        toolResult("call_img", "read", [.image(ImageContent(data: "abc", mimeType: "image/png"))]),
        toolResult("call_b", "read", [.text(TextContent(text: "beta text"))]),
    ])
}

@Suite("google-shared image tool result routing")
struct GoogleSharedImageToolResultRoutingTests {
    @Test("keeps separate synthetic image turn for Gemini 2.x Google API models")
    func separateImageTurn() {
        let model = makeGoogleModel("gemini-2.5-flash", input: ["text", "image"])
        let contents = convertMessagesGoogle(model, normalizeContext(imageRoutingContext(model)))

        #expect(contents.count == 5)
        #expect(parts(contents[2]).allSatisfy { jsTruthy($0["functionResponse"]) })
        #expect(parts(contents[3])[0]["text"] == "Tool result image:")
        #expect(jsTruthy(parts(contents[3])[1]["inlineData"]))
        #expect(jsTruthy(parts(contents[4])[0]["functionResponse"]))
    }

    @Test("nests image tool results for Gemini 3 Google API models")
    func nestsForGemini3() {
        let model = makeGoogleModel("gemini-3-pro-preview", input: ["text", "image"])
        let contents = convertMessagesGoogle(model, normalizeContext(imageRoutingContext(model)))

        #expect(contents.count == 3)
        let toolResultTurn = contents[2]
        #expect(parts(toolResultTurn).count == 3)
        let imageResponse = parts(toolResultTurn)[1]["functionResponse"]
        #expect(jsTruthy(imageResponse))
        #expect(parts(imageResponse).count == 1)
        #expect(jsTruthy(parts(imageResponse).first?["inlineData"]))
    }

    // https://github.com/earendil-works/pi/issues/8720
    @Test("treats whitespace-only tool result text as no text")
    func whitespaceOnlyText() {
        let model = makeGoogleModel("gemini-3-pro-preview", input: ["text", "image"])
        var context = imageRoutingContext(model)
        context.messages = context.messages.map { message in
            guard case .toolResult(var result) = message else { return message }
            if result.toolCallId == "call_a" { result.content = [.text(TextContent(text: "\r\n"))] }
            if result.toolCallId == "call_img" { result.content.insert(.text(TextContent(text: " \n")), at: 0) }
            return .toolResult(result)
        }
        let contents = convertMessagesGoogle(model, normalizeContext(context))

        let responses = parts(contents[2]).map { $0["functionResponse"]?["response"] }
        #expect(responses[0] == ["output": ""])
        #expect(responses[1] == ["output": "(see attached image)"])
        #expect(responses[2] == ["output": "beta text"])
    }
}

// MARK: - google-shared convertMessages — signed empty blocks

// Gemini can attach `thoughtSignature` to a response part whose visible text is empty (e.g. a
// thought burst preceding a function call) and requires the signature echoed back on the next
// request. Dropping such blocks while rebuilding history silently breaks the reasoning chain:
// the model then intermittently ends a mid-task turn with a thought-only STOP and no tool call.
// These tests pin the rule: an empty text/thinking block is skipped only when it is UNSIGNED.

private let VALID_SIG = "AAAAAAAAAAAAAAAAAAAAAA=="

private func signedContext(_ model: Model, _ content: [AssistantContent], modelId: String? = nil) -> Context {
    Context(messages: [.user(UserMessage(content: "Hi")), assistant(model, content, modelId: modelId)])
}

private let bashCall = AssistantContent.toolCall(ToolCall(id: "call_1", name: "bash", arguments: ["command": "ls"]))

@Suite("google-shared convertMessages — signed empty blocks")
struct GoogleSharedSignedEmptyBlocksTests {
    @Test("keeps a signed empty thinking block so its signature is echoed back")
    func signedEmptyThinking() {
        let model = makeGoogleModel("gemini-3-pro-preview")
        let contents = convertMessagesGoogle(model, normalizeContext(signedContext(model, [
            .thinking(ThinkingContent(thinking: "", thinkingSignature: VALID_SIG)),
            bashCall,
        ])))
        let signed = parts(modelTurn(contents)).filter { $0["thoughtSignature"]?.stringValue == VALID_SIG }
        #expect(signed.count == 1)
        #expect(signed.first?["thought"] == true)
    }

    @Test("keeps a signed empty text block the same way")
    func signedEmptyText() {
        let model = makeGoogleModel("gemini-3-pro-preview")
        let contents = convertMessagesGoogle(model, normalizeContext(signedContext(model, [
            .text(TextContent(text: "", textSignature: VALID_SIG)),
            bashCall,
        ])))
        let signed = parts(modelTurn(contents)).filter { $0["thoughtSignature"]?.stringValue == VALID_SIG }
        #expect(signed.count == 1)
    }

    @Test("still drops unsigned empty blocks")
    func dropsUnsigned() {
        let model = makeGoogleModel("gemini-3-pro-preview")
        let contents = convertMessagesGoogle(model, normalizeContext(signedContext(model, [
            .thinking(ThinkingContent(thinking: "")),
            .text(TextContent(text: "   ")),
            bashCall,
        ])))
        let modelParts = parts(modelTurn(contents))
        #expect(modelParts.count == 1)
        #expect(jsTruthy(modelParts.first?["functionCall"]))
    }

    @Test("still drops signed empty blocks from a different provider/model (signature unusable)")
    func dropsOtherModel() {
        let model = makeGoogleModel("gemini-3-pro-preview")
        let contents = convertMessagesGoogle(model, normalizeContext(signedContext(model, [
            .thinking(ThinkingContent(thinking: "", thinkingSignature: VALID_SIG)),
            .text(TextContent(text: "", textSignature: VALID_SIG)),
            bashCall,
        ], modelId: "other-model")))
        let turn = modelTurn(contents)
        #expect(parts(turn).count == 1)
        #expect(jsTruthy(parts(turn).first?["functionCall"]))
        let serialized = turn?.serialized() ?? ""
        #expect(!serialized.contains(VALID_SIG))
    }
}

// MARK: - google-shared convertMessages — Gemini 3 unsigned tool calls

private func unsignedContext(_ model: Model, modelId: String? = nil, thoughtSignature: String? = nil) -> Context {
    Context(messages: [
        .user(UserMessage(content: "Hi")),
        assistant(model, [
            .toolCall(ToolCall(id: "call_1", name: "bash", arguments: ["command": "echo hi"], thoughtSignature: thoughtSignature)),
            .toolCall(ToolCall(id: "call_2", name: "bash", arguments: ["command": "ls -la"])),
        ], modelId: modelId),
        toolResult("call_1", "bash", [.text(TextContent(text: "hi"))]),
        toolResult("call_2", "bash", [.text(TextContent(text: "files"))]),
    ])
}

private func gemini3Model(_ api: String, _ provider: String, _ id: String = "gemini-3-pro-preview") -> Model {
    var model = makeGoogleModel(id, api: api, provider: provider)
    model.name = "Gemini 3 Pro Preview"
    return model
}

@Suite("google-shared convertMessages — Gemini 3 unsigned tool calls")
struct GoogleSharedGemini3UnsignedToolCallTests {
    // Swift: the `google-vertex` case only exercises `convertMessages` with a Vertex-shaped model (no Vertex code).
    @Test("preserves tool call IDs via history", arguments: [
        ("google-generative-ai", "google", "gemini-3-pro-preview"),
        ("google-generative-ai", "google", "gemini-3.6-flash"),
        ("google-vertex", "google-vertex", "gemini-3-pro-preview"),
    ])
    func preservesIds(_ api: String, _ provider: String, _ id: String) {
        let model = gemini3Model(api, provider, id)
        let contents = convertMessagesGoogle(model, normalizeContext(unsignedContext(model)))
        let allParts = contents.flatMap { parts($0) }
        let functionCallIds = allParts.compactMap { $0["functionCall"]?["id"]?.stringValue }
        let functionResponseIds = allParts.compactMap { $0["functionResponse"]?["id"]?.stringValue }
        #expect(functionCallIds == ["call_1", "call_2"])
        #expect(functionResponseIds == ["call_1", "call_2"])
    }

    @Test("does not add skip_thought_signature_validator for unsigned Google Gen AI tool calls")
    func noSkipValidatorGenAI() throws {
        let model = gemini3Model("google-generative-ai", "google")
        let contents = convertMessagesGoogle(model, normalizeContext(unsignedContext(model, modelId: "other-model")))
        let turn = try #require(modelTurn(contents))
        let functionCallParts = parts(turn).filter { $0["functionCall"] != nil }
        #expect(functionCallParts.count == 2)
        #expect(functionCallParts[0]["thoughtSignature"] == nil)
        #expect(functionCallParts[1]["thoughtSignature"] == nil)
        #expect(!turn.serialized().contains("skip_thought_signature_validator"))
        let historicalText = parts(turn).filter { $0["text"]?.stringValue?.contains("Historical context") == true }
        #expect(historicalText.isEmpty)
    }

    @Test("does not add skip_thought_signature_validator for unsigned Vertex tool calls")
    func noSkipValidatorVertex() {
        let model = gemini3Model("google-vertex", "google-vertex")
        let contents = convertMessagesGoogle(model, normalizeContext(unsignedContext(model)))
        let turn = modelTurn(contents)
        let functionCallParts = parts(turn).filter { $0["functionCall"] != nil }
        #expect(functionCallParts.count == 2)
        #expect(functionCallParts.allSatisfy { $0["thoughtSignature"] == nil })
        let serialized = turn?.serialized() ?? ""
        #expect(!serialized.contains("skip_thought_signature_validator"))
    }

    @Test("preserves valid thoughtSignature when present for the same provider and model")
    func preservesValidSignature() {
        let model = gemini3Model("google-generative-ai", "google")
        let validSig = "AAAAAAAAAAAAAAAAAAAAAA=="
        let contents = convertMessagesGoogle(model, normalizeContext(unsignedContext(model, thoughtSignature: validSig)))
        let functionCallParts = parts(modelTurn(contents)).filter { $0["functionCall"] != nil }
        #expect(functionCallParts.count == 2)
        #expect(functionCallParts[0]["thoughtSignature"]?.stringValue == validSig)
        #expect(functionCallParts[1]["thoughtSignature"] == nil)
    }

    @Test("does not add a thoughtSignature for non-Gemini-3 models")
    func nonGemini3() {
        let model = gemini3Model("google-generative-ai", "google", "gemini-2.5-flash")
        let contents = convertMessagesGoogle(model, normalizeContext(unsignedContext(model, modelId: "other-model")))
        let functionCallParts = parts(modelTurn(contents)).filter { $0["functionCall"] != nil }
        let functionResponseParts = contents.flatMap { parts($0) }.filter { $0["functionResponse"] != nil }
        #expect(functionCallParts.count == 2)
        #expect(functionCallParts.allSatisfy { $0["functionCall"]?["id"] == nil })
        #expect(functionCallParts.allSatisfy { $0["thoughtSignature"] == nil })
        #expect(functionResponseParts.count == 2)
        #expect(functionResponseParts.allSatisfy { $0["functionResponse"]?["id"] == nil })
    }
}

@Suite("requiresToolCallId")
struct GoogleRequiresToolCallIdTests {
    @Test("returns expected for model id", arguments: [
        (false, "gemini-2.5-flash"),
        (true, "gemini-3.6-flash"),
        (true, "claude-sonnet-4-5"),
        (true, "gpt-oss-120b"),
    ])
    func requiresId(_ expected: Bool, _ modelId: String) {
        #expect(requiresToolCallId(modelId) == expected)
    }
}
