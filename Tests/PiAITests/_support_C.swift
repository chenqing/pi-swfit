import Foundation
import Testing
@testable import PiAI

// Shared helpers for group C's openai-completions tests. The upstream tests mock the `openai` module;
// here the real SDK runs against a fake `FetchFunction` that records requests and answers with SSE.

/// Parse a JSON literal (test data only).
func cJSON(_ text: String) -> JsonValue {
    do { return try JsonValue.parse(text) } catch { fatalError("bad test JSON: \(error)\n\(text)") }
}

private let zeroUsageJSON: JsonValue = cJSON(#"{"input":0,"output":0,"cacheRead":0,"cacheWrite":0,"totalTokens":0,"cost":{"input":0,"output":0,"cacheRead":0,"cacheWrite":0,"total":0}}"#)

/// Messages from an upstream-shaped JSON array; missing `timestamp` / assistant `usage` get upstream test defaults.
func cMessages(_ text: String) -> [Message] {
    guard case .array(let items) = cJSON(text) else { fatalError("expected array") }
    return items.map { item in
        guard case .object(var o) = item else { fatalError("expected object") }
        if o["timestamp"] == nil { o["timestamp"] = .number(Double(dateNow())) }
        if o["role"]?.stringValue == "assistant", o["usage"] == nil { o["usage"] = zeroUsageJSON }
        if o["role"]?.stringValue == "toolResult", o["isError"] == nil { o["isError"] = false }
        do { return try Message(json: .object(o)) } catch { fatalError("bad message: \(error)") }
    }
}

func cTools(_ text: String) -> [Tool] {
    guard case .array(let items) = cJSON(text) else { fatalError("expected array") }
    return items.map { item in
        do { return try Tool(json: item) } catch { fatalError("bad tool: \(error)") }
    }
}

func cModel(_ text: String) -> Model {
    do { return try Model(json: cJSON(text)) } catch { fatalError("bad model: \(error)") }
}

func cBuiltin(_ provider: BuiltinProvider, _ id: String) -> Model {
    _ = cInstallCatalog
    guard let model = getModel(provider, id) else { fatalError("missing builtin model \(provider)/\(id)") }
    return model
}

/// `const { compat: _compat, ...baseModel } = getModel("openai", "gpt-4o-mini"); { ...baseModel, api: "openai-completions" }`
func cOpenAICompletionsModel(compat: JsonObject? = nil) -> Model {
    var model = cBuiltin("openai", "gpt-4o-mini")
    model.compat = compat
    model.api = "openai-completions"
    return model
}

/// `{ type: "object", properties: { ... }, required: [...] }` as TypeBox's `Type.Object` writes it.
func cObjectSchema(_ properties: [(String, String)], optional: Set<String> = []) -> JsonValue {
    var props = JsonObject()
    for (name, type) in properties { props[name] = ["type": .string(type)] }
    var schema: JsonObject = ["type": "object", "properties": .object(props)]
    let required = properties.map(\.0).filter { !optional.contains($0) }
    if !required.isEmpty { schema["required"] = .array(required.map(JsonValue.string)) }
    return .object(schema)
}

/// SSE body for the given chunk objects (`null` entries become `data: null`).
func cSSE(_ chunks: [JsonValue], done: Bool = true) -> String {
    var text = ""
    for chunk in chunks { text += "data: \(chunk.serialized())\n\n" }
    if done { text += "data: [DONE]\n\n" }
    return text
}

/// The upstream mock's default stream.
let cDefaultChunks: [JsonValue] = [
    cJSON(#"{"choices":[{"delta":{},"finish_reason":"stop"}],"usage":{"prompt_tokens":1,"completion_tokens":1,"prompt_tokens_details":{"cached_tokens":0},"completion_tokens_details":{"reasoning_tokens":0}}}"#),
]

func cSSEResponse(_ body: String, status: Int = 200, headers: [(String, String)] = [("content-type", "text/event-stream")], chunkSizes: [Int]? = nil) -> FetchResponse {
    let bytes = Array(body.utf8)
    let stream = AsyncThrowingStream<Data, any Error> { continuation in
        if let chunkSizes, !chunkSizes.isEmpty {
            var offset = 0
            var i = 0
            while offset < bytes.count {
                let size = chunkSizes[i % chunkSizes.count]
                let end = min(bytes.count, offset + size)
                continuation.yield(Data(bytes[offset..<end]))
                offset = end
                i += 1
            }
        } else {
            continuation.yield(Data(bytes))
        }
        continuation.finish()
    }
    return FetchResponse(status: status, headers: Headers(headers), body: ResponseBody(stream))
}

/// Fake server: records each request and answers via `responder` (request, index).
final class CFakeServer: @unchecked Sendable {
    typealias Responder = @Sendable (FetchRequest, Int) async throws -> FetchResponse
    private let state = Locked<[FetchRequest]>([])
    private let responder: Responder

    init(_ responder: @escaping Responder) { self.responder = responder }

    /// Answers every request with the given chunks as SSE.
    convenience init(chunks: [JsonValue] = cDefaultChunks) {
        let body = cSSE(chunks)
        self.init { _, _ in cSSEResponse(body) }
    }

    var requests: [FetchRequest] { state.current }

    var fetch: FetchFunction {
        { [self] request in
            let index = state.withLock { r -> Int in
                r.append(request)
                return r.count - 1
            }
            return try await responder(request, index)
        }
    }

    func body(_ index: Int = 0) -> JsonValue {
        let request = requests[index]
        return cJSON(String(decoding: request.body ?? Data(), as: UTF8.self))
    }
}

struct CRun {
    var payload: JsonValue
    var result: AssistantMessage
    var events: [AssistantMessageEvent]
    var server: CFakeServer
}

/// Runs `streamSimple` (compat dispatch, like the upstream tests) against the fake server and captures
/// the `onPayload` params, the event list and the final message.
func cRunSimple(
    _ model: Model,
    _ context: Context,
    _ configure: (inout SimpleStreamOptions) -> Void = { _ in },
    chunks: [JsonValue] = cDefaultChunks,
    server: CFakeServer? = nil
) async throws -> CRun {
    let server = server ?? CFakeServer(chunks: chunks)
    let captured = Locked<JsonValue?>(nil)
    var options = SimpleStreamOptions()
    options.apiKey = "test"
    options.fetch = server.fetch
    configure(&options)
    let userOnPayload = options.onPayload
    options.onPayload = { params, model in
        captured.withLock { $0 = params }
        return try await userOnPayload?(params, model)
    }
    let stream = try streamSimple(model, context, options)
    var events: [AssistantMessageEvent] = []
    for await event in stream { events.append(event) }
    let result = await stream.result()
    let payload = captured.current ?? (server.requests.isEmpty ? .null : server.body())
    return CRun(payload: payload, result: result, events: events, server: server)
}

/// Same as `cRunSimple` but through `stream` (provider options).
func cRunStream(
    _ model: Model,
    _ context: Context,
    _ configure: (inout StreamOptions) -> Void = { _ in },
    chunks: [JsonValue] = cDefaultChunks,
    server: CFakeServer? = nil
) async throws -> CRun {
    let server = server ?? CFakeServer(chunks: chunks)
    let captured = Locked<JsonValue?>(nil)
    var options = StreamOptions()
    options.apiKey = "test"
    options.fetch = server.fetch
    configure(&options)
    let userOnPayload = options.onPayload
    options.onPayload = { params, model in
        captured.withLock { $0 = params }
        return try await userOnPayload?(params, model)
    }
    let s = try stream(model, context, options)
    var events: [AssistantMessageEvent] = []
    for await event in s { events.append(event) }
    let result = await s.result()
    let payload = captured.current ?? (server.requests.isEmpty ? .null : server.body())
    return CRun(payload: payload, result: result, events: events, server: server)
}

func cUserContext(_ text: String = "Hi", systemPrompt: String? = nil, tools: [Tool]? = nil) -> Context {
    Context(systemPrompt: systemPrompt, messages: [.user(UserMessage(content: .string(text)))], tools: tools)
}

func cContentJSON(_ message: AssistantMessage) -> JsonValue { .array(message.content.map(\.json)) }

func cContentIndex(_ event: AssistantMessageEvent) -> Int? {
    switch event {
    case .textStart(let i, _), .textDelta(let i, _, _), .textEnd(let i, _, _),
         .thinkingStart(let i, _), .thinkingDelta(let i, _, _), .thinkingEnd(let i, _, _),
         .toolcallStart(let i, _), .toolcallDelta(let i, _, _), .toolcallEnd(let i, _, _):
        return i
    default:
        return nil
    }
}

/// Recursive structural subset match (`toMatchObject`).
func cMatches(_ actual: JsonValue?, _ expected: JsonValue) -> Bool {
    guard let actual else { return false }
    switch (actual, expected) {
    case (.object(let a), .object(let e)):
        for (key, value) in e where !cMatches(a[key], value) { return false }
        return true
    case (.array(let a), .array(let e)):
        return a.count == e.count && zip(a, e).allSatisfy { cMatches($0, $1) }
    default:
        return actual == expected
    }
}

func cKeys(_ value: JsonValue?) -> [String] { value?.objectValue?.map(\.0) ?? [] }

/// Runs the provider's own `streamOpenAICompletions` (upstream `stream` from api/openai-completions.ts)
/// on `normalizeContext(context)` against the fake server.
func cRunDirect(
    _ model: Model,
    _ context: Context,
    _ configure: (inout StreamOptions) -> Void = { _ in },
    chunks: [JsonValue] = cDefaultChunks,
    server: CFakeServer? = nil
) async -> CRun {
    let server = server ?? CFakeServer(chunks: chunks)
    let captured = Locked<JsonValue?>(nil)
    var options = StreamOptions()
    options.apiKey = "test"
    options.fetch = server.fetch
    configure(&options)
    let userOnPayload = options.onPayload
    options.onPayload = { params, model in
        captured.withLock { $0 = params }
        return try await userOnPayload?(params, model)
    }
    let s = streamOpenAICompletions(model, normalizeContext(context), options)
    var events: [AssistantMessageEvent] = []
    for await event in s { events.append(event) }
    let result = await s.result()
    let payload = captured.current ?? (server.requests.isEmpty ? .null : server.body())
    return CRun(payload: payload, result: result, events: events, server: server)
}

/// Chat completion chunk `{ id, model?, choices: [{ index: 0, delta, finish_reason }] }`.
func cChunk(_ delta: JsonValue, finishReason: String? = nil, id: String = "chatcmpl-test", model: String? = nil) -> JsonValue {
    var chunk: JsonObject = ["id": .string(id)]
    if let model { chunk["model"] = .string(model) }
    chunk["choices"] = [["index": 0, "delta": delta, "finish_reason": finishReason.map(JsonValue.string) ?? .null]]
    return .object(chunk)
}
