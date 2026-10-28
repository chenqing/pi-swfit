import Foundation
import Testing
@testable import PiAI

// Shared helpers for the anthropic-messages test ports (group B).

/// A fetched request as seen by a fake `FetchFunction`.
final class BRequests: @unchecked Sendable {
    private let lock = NSLock()
    private var _requests: [FetchRequest] = []

    func add(_ request: FetchRequest) {
        lock.lock()
        _requests.append(request)
        lock.unlock()
    }

    var all: [FetchRequest] {
        lock.lock()
        defer { lock.unlock() }
        return _requests
    }

    var count: Int { all.count }
    var last: FetchRequest? { all.last }

    /// Parsed JSON body of each request.
    var bodies: [JsonObject] {
        all.map { request in
            (try? JsonValue.parse(String(decoding: request.body ?? Data(), as: UTF8.self)))?.objectValue ?? JsonObject()
        }
    }

    var lastBody: JsonObject? { bodies.last }
}

/// `createSseResponse(events)` from the upstream tests: `event: X\ndata: Y\n` joined by blank lines.
func bSseBody(_ events: [(event: String, data: String)]) -> String {
    events.map { "event: \($0.event)\ndata: \($0.data)\n" }.joined(separator: "\n")
}

/// Same, with JSON payloads serialized like `JSON.stringify`.
func bSseBody(json events: [(event: String, data: JsonValue)]) -> String {
    bSseBody(events.map { ($0.event, $0.data.serialized()) })
}

/// The `minimalAnthropicEvents` stream from the upstream SSE parsing tests ("Hello", end_turn).
let bMinimalAnthropicEvents: [(event: String, data: JsonValue)] = [
    ("message_start", [
        "type": "message_start",
        "message": [
            "id": "msg_test",
            "usage": ["input_tokens": 12, "output_tokens": 0, "cache_read_input_tokens": 0, "cache_creation_input_tokens": 0],
        ],
    ]),
    ("content_block_start", ["type": "content_block_start", "index": 0, "content_block": ["type": "text", "text": ""]]),
    ("content_block_delta", ["type": "content_block_delta", "index": 0, "delta": ["type": "text_delta", "text": "Hello"]]),
    ("content_block_stop", ["type": "content_block_stop", "index": 0]),
    ("message_delta", [
        "type": "message_delta",
        "delta": ["stop_reason": "end_turn"],
        "usage": ["input_tokens": 12, "output_tokens": 5, "cache_read_input_tokens": 0, "cache_creation_input_tokens": 0],
    ]),
    ("message_stop", ["type": "message_stop"]),
]

/// Fake fetch answering every request with `body` (an SSE stream by default). Records requests in `requests`.
func bFetch(
    _ body: String = bSseBody(json: bMinimalAnthropicEvents),
    status: Int = 200,
    headers: [(String, String)] = [("content-type", "text/event-stream")],
    requests: BRequests? = nil
) -> FetchFunction {
    { request in
        requests?.add(request)
        return FetchResponse(status: status, headers: Headers(headers), body: .data(Data(body.utf8)))
    }
}

/// Fake fetch answering with a sequence of responses (the last one repeats).
func bFetchSequence(_ responses: [(status: Int, body: String, headers: [(String, String)])], requests: BRequests? = nil) -> FetchFunction {
    let counter = Locked(0)
    return { request in
        requests?.add(request)
        let index = counter.withLock { value -> Int in
            defer { value += 1 }
            return value
        }
        let response = responses[min(index, responses.count - 1)]
        return FetchResponse(status: response.status, headers: Headers(response.headers), body: .data(Data(response.body.utf8)))
    }
}

/// A JSON error response like the Anthropic API returns.
func bAnthropicErrorBody(type: String = "invalid_request_error", message: String) -> String {
    JsonValue.object(["type": "error", "error": ["type": .string(type), "message": .string(message)]]).serialized()
}

/// Custom anthropic-messages model; defaults mirror the upstream tests' local models.
func bModel(
    id: String = "claude-test",
    name: String? = nil,
    provider: String = "anthropic",
    baseUrl: String = "http://127.0.0.1:9",
    reasoning: Bool = true,
    input: [ModelInputModality] = ["text"],
    cost: ModelCost = ModelCost(),
    contextWindow: Int = 200_000,
    maxTokens: Int = 32_000,
    headers: [(String, String)]? = nil,
    compat: JsonObject? = nil
) -> Model {
    Model(
        id: id,
        name: name ?? id,
        api: "anthropic-messages",
        provider: provider,
        baseUrl: baseUrl,
        reasoning: reasoning,
        input: input,
        cost: cost,
        contextWindow: contextWindow,
        maxTokens: maxTokens,
        headers: headers,
        compat: compat
    )
}

func bUserContext(_ text: String = "Hello", systemPrompt: String? = nil, tools: [Tool]? = nil) -> Context {
    Context(systemPrompt: systemPrompt, messages: [.user(UserMessage(content: .string(text)))], tools: tools)
}

/// Result of driving one request through a fake fetch.
struct BRun {
    var events: [AssistantMessageEvent]
    var result: AssistantMessage
    var requests: BRequests

    var body: JsonObject? { requests.lastBody }
    var request: FetchRequest? { requests.last }
}

/// Runs `streamSimpleAnthropicMessages` with a fake fetch and collects everything.
func bRunSimple(
    _ model: Model,
    _ context: Context,
    _ options: SimpleStreamOptions = SimpleStreamOptions(),
    response: String = bSseBody(json: bMinimalAnthropicEvents),
    status: Int = 200,
    apiKey: String? = "fake-key"
) async -> BRun {
    let requests = BRequests()
    var options = options
    if options.apiKey == nil { options.apiKey = apiKey }
    if options.fetch == nil { options.fetch = bFetch(response, status: status, requests: requests) }
    let stream = streamSimpleAnthropicMessages(model, normalizeContext(context), options)
    var events: [AssistantMessageEvent] = []
    for await event in stream { events.append(event) }
    return BRun(events: events, result: await stream.result(), requests: requests)
}

/// Runs `streamAnthropicMessages` with a fake fetch and collects everything.
func bRun(
    _ model: Model,
    _ context: Context,
    _ options: AnthropicOptions = AnthropicOptions(),
    response: String = bSseBody(json: bMinimalAnthropicEvents),
    status: Int = 200,
    apiKey: String? = "fake-key"
) async -> BRun {
    let requests = BRequests()
    var options = options
    if options.apiKey == nil { options.apiKey = apiKey }
    if options.fetch == nil && options.client == nil { options.fetch = bFetch(response, status: status, requests: requests) }
    let stream = streamAnthropicMessages(model, normalizeContext(context), options)
    var events: [AssistantMessageEvent] = []
    for await event in stream { events.append(event) }
    return BRun(events: events, result: await stream.result(), requests: requests)
}

/// `capturePayload`: the params object handed to `onPayload` (the request is then aborted by throwing).
func bCapturePayload(_ model: Model, _ context: Context = bUserContext(), _ options: SimpleStreamOptions = SimpleStreamOptions()) async -> JsonObject? {
    let captured = Locked<JsonObject?>(nil)
    var options = options
    if options.apiKey == nil { options.apiKey = "fake-key" }
    options.onPayload = { payload, _ in
        captured.withLock { $0 = payload.objectValue }
        throw PiError("payload captured", name: "PayloadCaptured")
    }
    _ = await streamSimpleAnthropicMessages(model, normalizeContext(context), options).result()
    return captured.withLock { $0 }
}

/// Same as `bCapturePayload` for the non-simple entry point.
func bCaptureAnthropicPayload(_ model: Model, _ context: Context = bUserContext(), _ options: AnthropicOptions = AnthropicOptions()) async -> JsonObject? {
    let captured = Locked<JsonObject?>(nil)
    var options = options
    if options.apiKey == nil { options.apiKey = "fake-key" }
    options.onPayload = { payload, _ in
        captured.withLock { $0 = payload.objectValue }
        throw PiError("payload captured", name: "PayloadCaptured")
    }
    _ = await streamAnthropicMessages(model, normalizeContext(context), options).result()
    return captured.withLock { $0 }
}
