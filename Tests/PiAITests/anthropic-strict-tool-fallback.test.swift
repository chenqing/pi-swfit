import Foundation
import Testing
@testable import PiAI

// Port of packages/ai/test/anthropic-strict-tool-fallback.test.ts
//
// Not ported: "preserves prefer through pi-messages so the gateway's Anthropic adapter can fall back"
// (api/pi-messages.ts is not ported).

private let grammarError =
    "The compiled grammar is too large, which would cause performance issues. Simplify your tool schemas or reduce the number of strict tools."

private let model = Model(
    id: "claude-haiku-4-5",
    name: "Test Claude",
    api: "anthropic-messages",
    provider: "anthropic",
    baseUrl: "https://anthropic.example",
    reasoning: false,
    input: ["text"],
    cost: ModelCost(),
    contextWindow: 200_000,
    maxTokens: 100,
    compat: ["supportsStrictTools": true]
)

/// `Type.Object({ value: Type.String(), optional: Type.Optional(Type.Number()) })`
private let lookupParameters: JsonValue = [
    "type": "object",
    "properties": ["value": ["type": "string"], "optional": ["type": "number"]],
    "required": ["value"],
]

private func tool(_ name: String, _ strict: String? = nil) -> Tool {
    Tool(
        name: name,
        description: "Look up a value",
        parameters: lookupParameters,
        constrainedSampling: strict.map { .some(.jsonSchema(strict: $0)) }
    )
}

private func context(_ tools: [Tool]) -> TranscriptContext {
    normalizeContext(Context(messages: [.user(UserMessage(content: "Hello", timestamp: 1))], tools: tools))
}

private typealias Response = (status: Int, body: String, headers: [(String, String)])

private func errorResponse(_ message: String = grammarError, _ status: Int = 400, _ type: String = "invalid_request_error") -> Response {
    (status, bAnthropicErrorBody(type: type, message: message), [("content-type", "application/json")])
}

private func successResponse() -> Response {
    let events: [(event: String, data: JsonValue)] = [
        ("message_start", [
            "type": "message_start",
            "message": ["id": "msg_test", "model": .string(model.id), "usage": ["input_tokens": 10, "output_tokens": 0]],
        ]),
        ("message_delta", ["type": "message_delta", "delta": ["stop_reason": "end_turn"], "usage": ["output_tokens": 1]]),
        ("message_stop", ["type": "message_stop"]),
    ]
    return (200, bSseBody(json: events) + "\n", [("content-type", "text/event-stream")])
}

private struct Harness {
    var requests = BRequests()
    var options = AnthropicOptions()
    var payloads: [JsonObject] { requests.bodies }
}

private func harness(_ respond: @escaping @Sendable (_ attempt: Int) -> Response) -> Harness {
    var harness = Harness()
    let requests = harness.requests
    harness.options.apiKey = "test-key"
    harness.options.maxRetries = 0
    harness.options.fetch = { request in
        requests.add(request)
        let response = respond(requests.count)
        return FetchResponse(status: response.status, headers: Headers(response.headers), body: .data(Data(response.body.utf8)))
    }
    return harness
}

private func tools(_ payload: JsonObject) -> [JsonValue] { payload["tools"]?.arrayValue ?? [] }

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

@Suite("Anthropic preferred strict tool fallback")
struct AnthropicStrictToolFallbackTests {
    // Regression tests for https://github.com/earendil-works/pi/issues/10409.
    @Test("retries with original non-strict schemas and preserves required tools", arguments: [
        grammarError,
        // Observed from the live API: 32 strict tools, then 20 tools with 24 optional fields each.
        "Too many strict tools (32). The maximum number of strict tools supported is 20. Try reducing the number of tools marked as strict.",
        "Schemas contains too many parameters with union types (480 parameters with type arrays or anyOf). This causes exponential compilation cost. Reduce the number of nullable or union-typed parameters (limit: 16 parameters with unions).",
    ])
    func retriesWithNonStrictSchemas(_ message: String) async throws {
        let preferred = tool("preferred", "prefer")
        let required = tool("required", "require")
        let ordinary = tool("ordinary")
        let transcript = context([preferred, required, ordinary])
        let original = transcript.messages.compactMap(\.systemMessage).flatMap { $0.toolsAdded ?? [] }.map(\.json)
        // Use the real SDK's HTTP error parsing, not a synthetic thrown Error.
        var h = harness { attempt in attempt == 1 ? errorResponse(message) : successResponse() }
        let onPayloadCalls = Locked(0)
        let onResponseCalls = Locked(0)
        h.options.onPayload = { payload, _ in
            onPayloadCalls.withLock { $0 += 1 }
            var next = payload.objectValue ?? JsonObject()
            next["inference_geo"] = "us"
            next["stream"] = false
            return .object(next)
        }
        h.options.onResponse = { _, _ in onResponseCalls.withLock { $0 += 1 } }
        h.options.cacheRetention = .long
        let stream = streamAnthropicMessages(model, transcript, h.options)
        var events: [String] = []
        for await event in stream { events.append(event.type) }
        let result = await stream.result()

        #expect(result.stopReason == .stop)
        #expect(events == ["start", "done"])
        let payloads = h.payloads
        try #require(payloads.count == 2)
        #expect(onPayloadCalls.withLock { $0 } == 2)
        #expect(onResponseCalls.withLock { $0 } == 1)
        let first = tools(payloads[0])
        let second = tools(payloads[1])
        try #require(first.count == 3 && second.count == 3)
        #expect(matchesObject(first[0], [
            "strict": true,
            "input_schema": [
                "required": ["value", "optional"],
                "properties": ["optional": ["anyOf": [["type": "number"], ["type": "null"]]]],
            ],
        ]))
        #expect(second[0]["strict"] == nil)
        #expect(second[0]["input_schema"] == [
            "type": "object",
            "properties": ["value": ["type": "string"], "optional": ["type": "number"]],
            "required": ["value"],
        ])
        #expect(second[1] == first[1])
        #expect(second[1]["strict"] == true)
        #expect(second[2] == first[2])
        #expect(second[2]["cache_control"] == ["type": "ephemeral", "ttl": "1h"])
        #expect(payloads.map { $0["stream"] } == [true, true])
        #expect(payloads[1]["inference_geo"] == "us")
        let after = transcript.messages.compactMap(\.systemMessage).flatMap { $0.toolsAdded ?? [] }.map(\.json)
        #expect(after == original)
        let diagnostic = try #require(result.diagnostics?.first)
        #expect(diagnostic.type == "anthropic_strict_tools_fallback")
        #expect(diagnostic.details?["reason"] == "strict_tool_limits_exceeded")
    }

    @Test("downgrades inline additions and same-name redefinitions without downgrading require")
    func downgradesInlineAdditions() async throws {
        var transcript = context([tool("lookup", "require")])
        transcript.messages.append(.system(SystemMessage(content: "", toolsAdded: [tool("lookup", "prefer")], timestamp: 2)))
        transcript.messages.append(.system(SystemMessage(content: "", toolsAdded: [tool("lookup", "require")], timestamp: 3)))
        var h = harness { attempt in attempt == 1 ? errorResponse() : successResponse() }
        h.options.apiKey = "sk-ant-oat-test"
        var nativeModel = model
        nativeModel.compat?["supportsMidConvoSystemMessages"] = true
        nativeModel.compat?["supportsMidConvoToolChanges"] = true
        let result = await streamAnthropicMessages(nativeModel, transcript, h.options).result()
        #expect(result.stopReason == .stop)
        let payloads = h.payloads
        try #require(payloads.count == 2)
        #expect(payloads[1]["tools"] == payloads[0]["tools"])
        let additions: [[JsonValue]] = payloads.map { payload in
            (payload["messages"]?.arrayValue ?? []).flatMap { message -> [JsonValue] in
                guard let content = message["content"]?.arrayValue else { return [] }
                return content.compactMap { block in
                    block["type"] == "tool_addition" && block["tool"]?["type"] == "tool_definition"
                        ? block["tool"]?["definition"] : nil
                }
            }
        }
        try #require(additions[0].count == 2 && additions[1].count == 2)
        #expect(additions[0].map { $0["strict"] } == [true, true])
        #expect(additions[1].map { $0["strict"] } == [nil, true])
        #expect(additions[1][0]["input_schema"]?["required"] == ["value"])
        #expect(additions[1][1] == additions[0][1])
    }

    @Test("does not retry a tool set", arguments: [
        ("required", [tool("lookup", "require")]),
        ("ordinary", [tool("lookup")]),
        ("locally unsupported prefer", [
            Tool(
                name: "lookup",
                description: "Look up a value",
                parameters: ["type": "object", "properties": ["value": ["type": "number", "minimum": 1]], "required": ["value"]],
                constrainedSampling: .some(.jsonSchema(strict: "prefer"))
            ),
        ]),
    ])
    func doesNotRetry(_ name: String, _ toolSet: [Tool]) async throws {
        let h = harness { _ in errorResponse() }
        let result = await streamAnthropicMessages(model, context(toolSet), h.options).result()
        #expect(result.stopReason == .error, "\(name)")
        #expect(result.errorMessage?.contains(grammarError) == true, "\(name)")
        #expect(h.payloads.count == 1, "\(name)")
    }

    @Test("does not downgrade on", arguments: [
        ("unrelated 400", "Invalid tool schema", 400, "invalid_request_error"),
        ("wrong error type", grammarError, 400, "authentication_error"),
        ("wrong HTTP status", grammarError, 500, "invalid_request_error"),
    ])
    func doesNotDowngrade(_ name: String, _ message: String, _ status: Int, _ type: String) async throws {
        let h = harness { _ in errorResponse(message, status, type) }
        let result = await streamAnthropicMessages(model, context([tool("lookup", "prefer")]), h.options).result()
        #expect(result.stopReason == .error, "\(name)")
        #expect(h.payloads.count == 1, "\(name)")
    }

    @Test("surfaces a second rejection rather than retrying again")
    func surfacesSecondRejection() async throws {
        let h = harness { attempt in errorResponse(attempt == 1 ? grammarError : "Required grammar is still too large") }
        let result = await streamAnthropicMessages(
            model,
            context([tool("lookup", "prefer"), tool("required", "require")]),
            h.options
        ).result()
        #expect(result.stopReason == .error)
        #expect(result.errorMessage?.contains("Required grammar is still too large") == true)
        let payloads = h.payloads
        try #require(payloads.count == 2)
        #expect(tools(payloads[1])[1]["strict"] == true)
    }

    @Test("does not downgrade a hook exception, even if it looks like the provider rejection")
    func doesNotDowngradeHookException() async throws {
        var h = harness { _ in successResponse() }
        h.options.onPayload = { _, _ in
            throw Anthropic.APIError.generate(
                400,
                ["error": ["type": "invalid_request_error", "message": .string(grammarError)]],
                grammarError,
                Headers()
            )
        }
        let result = await streamAnthropicMessages(model, context([tool("lookup", "prefer")]), h.options).result()
        #expect(result.stopReason == .error)
        #expect(h.payloads.count == 0)
        #expect(result.diagnostics == nil)
    }

    @Test("honors cancellation before the fallback attempt")
    func honorsCancellation() async throws {
        let controller = AbortController()
        var h = harness { _ in
            controller.abort()
            return errorResponse()
        }
        h.options.signal = controller.signal
        let result = await streamAnthropicMessages(model, context([tool("lookup", "prefer")]), h.options).result()
        #expect(result.stopReason == .aborted)
        #expect(h.payloads.count == 1)
    }

    @Test("does not retry an SSE error after response headers")
    func doesNotRetrySseError() async throws {
        let errorEvent: JsonValue = ["type": "error", "error": ["type": "invalid_request_error", "message": .string(grammarError)]]
        let h = harness { _ in (200, "event: error\ndata: \(errorEvent.serialized())\n\n", [("content-type", "text/event-stream")]) }
        let result = await streamAnthropicMessages(model, context([tool("lookup", "prefer")]), h.options).result()
        #expect(result.stopReason == .error)
        #expect(h.payloads.count == 1)
    }

    @Test("does not disable strict sampling on later requests")
    func doesNotDisableStrictSamplingLater() async throws {
        let h = harness { attempt in attempt == 1 ? errorResponse() : successResponse() }
        let transcript = context([tool("lookup", "prefer")])
        _ = await streamAnthropicMessages(model, transcript, h.options).result()
        _ = await streamAnthropicMessages(model, transcript, h.options).result()
        #expect(h.payloads.map { tools($0).first?["strict"] } == [true, nil, true])
    }
}
