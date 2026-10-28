import Foundation
@testable import PiAI

// Shared helpers for group D's OpenAI Responses tests (vitest `vi.spyOn(globalThis, "fetch")` and
// `vi.mock("openai")` become fake `FetchFunction`s that record requests and serve SSE bytes).

/// One request seen by a fake fetch.
struct DCapturedRequest: Sendable {
    var url: URL
    var headers: Headers
    var body: JsonValue?

    func header(_ name: String) -> String? { headers.get(name) }
}

/// Records every request a fake fetch receives.
final class DRecorder: Sendable {
    private let state = Locked<[DCapturedRequest]>([])
    init() {}
    func record(_ request: FetchRequest) {
        let body = request.body.flatMap { try? JsonValue.parse(String(decoding: $0, as: UTF8.self)) }
        state.withLock { $0.append(DCapturedRequest(url: request.url, headers: request.headers, body: body)) }
    }
    var requests: [DCapturedRequest] { state.withLock { $0 } }
    var last: DCapturedRequest? { requests.last }
}

/// Serialize Responses stream events as SSE (`event:` + `data:` frames).
func dSSE(_ events: [JsonValue]) -> String {
    events.map { event in
        var frame = ""
        if let type = event["type"]?.stringValue { frame += "event: \(type)\n" }
        frame += "data: \(event.serialized())\n\n"
        return frame
    }.joined()
}

/// SSE body that yields `bytes` in chunks of the given sizes (cycled), then finishes or hangs.
func dChunkedBody(_ bytes: Data, chunkSizes: [Int] = [], hangAtEnd: Bool = false, signal: AbortSignal? = nil) -> ResponseBody {
    let (stream, continuation) = AsyncThrowingStream<Data, any Error>.makeStream()
    if chunkSizes.isEmpty {
        continuation.yield(bytes)
    } else {
        var offset = 0
        var i = 0
        while offset < bytes.count {
            let size = max(1, chunkSizes[i % chunkSizes.count])
            let end = min(bytes.count, offset + size)
            continuation.yield(bytes.subdata(in: offset..<end))
            offset = end
            i += 1
        }
    }
    if hangAtEnd {
        if let signal {
            signal.addEventListener {
                continuation.finish(throwing: AbortError())
            }
        }
    } else {
        continuation.finish()
    }
    return ResponseBody(stream)
}

/// A fake fetch serving `sse` with status 200 and recording requests.
func dSSEFetch(_ recorder: DRecorder = DRecorder(), _ sse: String = "data: [DONE]\n\n", chunkSizes: [Int] = [], hangAtEnd: Bool = false) -> FetchFunction {
    { request in
        recorder.record(request)
        return FetchResponse(
            status: 200,
            headers: Headers([("content-type", "text/event-stream")]),
            body: dChunkedBody(Data(sse.utf8), chunkSizes: chunkSizes, hangAtEnd: hangAtEnd, signal: request.signal)
        )
    }
}

/// A fake fetch answering with a JSON error body.
func dErrorFetch(_ recorder: DRecorder = DRecorder(), status: Int, json: String) -> FetchFunction {
    { request in
        recorder.record(request)
        return FetchResponse(status: status, headers: Headers([("content-type", "application/json")]), body: .data(Data(json.utf8)))
    }
}

/// Drain a stream; returns the events and the final result.
func dCollect(_ stream: AssistantMessageEventStream) async -> (events: [AssistantMessageEvent], result: AssistantMessage) {
    var events: [AssistantMessageEvent] = []
    for await event in stream { events.append(event) }
    return (events, await stream.result())
}

/// `async function*` over fixed events, for `processResponsesStream`.
func dEvents(_ events: [JsonValue]) -> AsyncStream<JsonValue> {
    AsyncStream { continuation in
        for event in events { continuation.yield(event) }
        continuation.finish()
    }
}

func dUserContext(_ text: String = "hi", systemPrompt: String? = "sys", tools: [Tool]? = nil) -> TranscriptContext {
    normalizeContext(Context(
        systemPrompt: systemPrompt,
        messages: [.user(UserMessage(content: .string(text)))],
        tools: tools
    ))
}

func dEmptyOutput(_ model: Model) -> AssistantMessage {
    var output = AssistantMessage(api: model.api, provider: model.provider, model: model.id)
    output.stopReason = .pending
    return output
}

/// `Type.Object({ <name>: Type.String() })`
func dStringObjectSchema(_ names: [String], optional: [String] = []) -> JsonValue {
    var properties = JsonObject()
    for name in names { properties[name] = ["type": "string"] }
    return [
        "type": "object",
        "properties": .object(properties),
        "required": .array(names.filter { !optional.contains($0) }.map(JsonValue.string)),
    ]
}

func dModel(_ provider: String, _ id: String) -> Model {
    guard let model = getModel(provider, id) ?? dCatalogModel(provider, id) else { fatalError("missing model \(provider)/\(id)") }
    return model
}

func dTextOf(_ message: AssistantMessage) -> String {
    message.content.compactMap { if case .text(let t) = $0 { return t.text } else { return nil } }.joined()
}

func dToolCalls(_ message: AssistantMessage) -> [ToolCall] {
    message.content.compactMap { if case .toolCall(let c) = $0 { return c } else { return nil } }
}

/// Message of a caught error (`""` when nothing was thrown).
func dErr(_ error: (any Error)?) -> String { error.map(errorMessage) ?? "" }
