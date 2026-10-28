import Foundation
import Testing
@testable import PiAI

// Replays real upstream recordings (`_fixtures_google_replay.swift`, generated from /tmp/pi-live/fixtures/google-*)
// through `streamSimpleGoogleGenerativeAI` with a fake `globalThis.fetch` (`GlobalFetch.current`).

private let replayModel: Model = {
    var model = Model(
        id: "zcode/GLM-5.3-Flash",
        name: "GLM-5.3-Flash",
        api: "google-generative-ai",
        provider: "google",
        baseUrl: "http://127.0.0.1:3426/pass/v1beta",
        reasoning: true,
        input: ["text", "image"],
        contextWindow: 1_000_000,
        maxTokens: 32000
    )
    model.cost = ModelCost()
    return model
}()

private let replayTools: [Tool] = [
    Tool(name: "ls", description: "List files in the workspace directory.", parameters: [
        "type": "object", "properties": ["path": ["type": "string"]],
    ]),
    Tool(name: "read", description: "Read a file in the workspace by relative path.", parameters: [
        "type": "object", "required": ["path"], "properties": ["path": ["type": "string"]],
    ]),
]

private struct RecordedRequest {
    let path: String
    let headers: JsonValue
    let body: String
}

private func recordedRequest(_ fixture: GoogleReplayFixture) throws -> RecordedRequest {
    let text = String(decoding: Data(base64Encoded: fixture.requestBase64)!, as: UTF8.self)
    let newline = text.firstIndex(of: "\n")!
    let meta = try JsonValue.parse(String(text[..<newline]))
    return RecordedRequest(path: meta["path"]!.stringValue!, headers: meta["headers"]!, body: String(text[text.index(after: newline)...]))
}

private func sseBytes(_ fixture: GoogleReplayFixture) -> Data { Data(base64Encoded: fixture.sseBase64)! }

private func context(_ fixture: GoogleReplayFixture) throws -> TranscriptContext {
    guard case .array(let history) = try JsonValue.parse(fixture.historyJson) else { fatalError() }
    return normalizeContext(Context(
        systemPrompt: "You are a helpful assistant with access to workspace tools.",
        messages: try history.map(Message.init(json:)),
        tools: replayTools
    ))
}

private func options(_ fixture: GoogleReplayFixture, signal: AbortSignal? = nil) -> SimpleStreamOptions {
    var options = SimpleStreamOptions()
    options.apiKey = "magpie"
    options.reasoning = ThinkingLevel(rawValue: fixture.reasoning)
    options.signal = signal
    return options
}

/// Key-order-insensitive form for `toEqual`-style comparison.
private func canonical(_ value: JsonValue) -> JsonValue {
    switch value {
    case .object(let object):
        return .object(JsonObject(object.keys.sorted().map { ($0, canonical(object[$0]!)) }))
    case .array(let items):
        return .array(items.map(canonical))
    default:
        return value
    }
}

private final class RequestLog: Sendable {
    let requests = Locked<[FetchRequest]>([])
    func append(_ request: FetchRequest) { requests.withLock { $0.append(request) } }
    var all: [FetchRequest] { requests.withLock { $0 } }
}

private func sseResponse(_ chunks: [Data]) -> FetchResponse {
    let stream = AsyncThrowingStream<Data, any Error> { continuation in
        for chunk in chunks { continuation.yield(chunk) }
        continuation.finish()
    }
    return FetchResponse(status: 200, headers: Headers([("content-type", "text/event-stream")]), body: ResponseBody(stream))
}

/// Deterministic 1–7 byte chunking.
private func randomChunks(_ data: Data, seed: UInt64) -> [Data] {
    var state = seed &* 6364136223846793005 &+ 1442695040888963407
    var chunks: [Data] = []
    var index = data.startIndex
    while index < data.endIndex {
        state = state &* 6364136223846793005 &+ 1442695040888963407
        let size = Int((state >> 33) % 7) + 1
        let end = min(index + size, data.endIndex)
        chunks.append(data[index..<end])
        index = end
    }
    return chunks
}

private func run(
    _ fixture: GoogleReplayFixture,
    signal: AbortSignal? = nil,
    log: RequestLog = RequestLog(),
    _ respond: @escaping @Sendable (FetchRequest) async throws -> FetchResponse
) async throws -> [AssistantMessageEvent] {
    let fetch: FetchFunction = { request in
        log.append(request)
        return try await respond(request)
    }
    let ctx = try context(fixture)
    let opts = options(fixture, signal: signal)
    let stream = try GlobalFetch.$current.withValue(fetch) {
        try streamSimpleGoogleGenerativeAI(replayModel, ctx, opts)
    }
    var events: [AssistantMessageEvent] = []
    for await event in stream { events.append(event) }
    return events
}

private func expectFinal(_ message: AssistantMessage, _ fixture: GoogleReplayFixture) throws {
    var expected = try JsonValue.parse(fixture.finalJson)
    var actual = message.json
    for key in ["timestamp", "durationMs", "thinkingLevel"] {
        expected[key] = nil
        actual[key] = nil
    }
    #expect(canonical(actual) == canonical(expected), "\(fixture.name): \(actual.serialized())")
}

@Suite("google-generative-ai replay")
struct GoogleGenerativeAIReplayTests {
    @Test("request path, headers and body match the upstream recording", arguments: googleReplayFixtures.map(\.name))
    func requestMatches(_ name: String) async throws {
        let fixture = googleReplayFixtures.first { $0.name == name }!
        let recorded = try recordedRequest(fixture)
        let log = RequestLog()
        let bytes = sseBytes(fixture)
        _ = try await run(fixture, log: log) { _ in sseResponse([bytes]) }

        let requests = log.all
        #expect(requests.count == 1)
        let request = try #require(requests.first)
        #expect(request.method == "POST")
        #expect(request.url.absoluteString == "http://127.0.0.1:3426/pass" + recorded.path)
        #expect(request.headers.get("x-goog-api-key") == recorded.headers["x-goog-api-key"]?.stringValue)
        #expect(request.headers.get("Content-Type") == recorded.headers["Content-Type"]?.stringValue)
        #expect(request.headers.get("User-Agent") == getPiUserAgent())
        // Swift has no node version: `gl-node/unknown` instead of `gl-node/v25.9.0`.
        #expect(request.headers.get("x-goog-api-client")?.hasPrefix("google-genai-sdk/2.21.0 gl-node/") == true)

        let body = String(decoding: request.body ?? Data(), as: UTF8.self)
        // Field-for-field, in upstream key order.
        #expect(try JsonValue.parse(body).serialized() == JsonValue.parse(recorded.body).serialized())
    }

    @Test("replay yields the upstream events and final message", arguments: googleReplayFixtures.map(\.name))
    func replay(_ name: String) async throws {
        let fixture = googleReplayFixtures.first { $0.name == name }!
        let bytes = sseBytes(fixture)
        var splits: [[Data]] = [[bytes]]
        for seed in 1...5 { splits.append(randomChunks(bytes, seed: UInt64(seed))) }

        for chunks in splits {
            let events = try await run(fixture) { _ in sseResponse(chunks) }
            #expect(events.map(\.type) == fixture.eventTypes, "\(fixture.name)")
            guard case .done(_, let message)? = events.last else {
                Issue.record("\(fixture.name): no done event: \(events.last?.message.errorMessage ?? "")")
                continue
            }
            try expectFinal(message, fixture)
            // Tool-call deltas carry the serialized, parsed arguments.
            for event in events {
                if case .toolcallDelta(let index, let delta, let partial) = event,
                   case .toolCall(let call) = partial.content[index] {
                    #expect(try JsonValue.parse(delta) == .object(call.arguments))
                }
            }
        }
    }

    @Test("truncated streams end with an error carrying upstream's message", arguments: googleReplayFixtures.map(\.name))
    func truncation(_ name: String) async throws {
        let fixture = googleReplayFixtures.first { $0.name == name }!
        let bytes = sseBytes(fixture)
        let full = String(decoding: bytes, as: UTF8.self)
        let cuts = [0, 1, 7, bytes.count / 3, bytes.count / 2, bytes.count - 40, bytes.count - 2, bytes.count - 1]
        // Also cut exactly at every event boundary before the final (finish-reason) event.
        var boundaries: [Int] = []
        var offset = 0
        for event in full.components(separatedBy: "\n\n").dropLast(2) {
            offset += event.utf8.count + 2
            boundaries.append(offset)
        }
        for cut in cuts + boundaries.prefix(3) + boundaries.suffix(1) {
            let prefix = bytes.prefix(cut)
            let events = try await run(fixture) { _ in sseResponse(randomChunks(prefix, seed: UInt64(cut))) }
            guard case .error(let reason, let message)? = events.last else {
                Issue.record("\(fixture.name) cut \(cut): last event \(events.last?.type ?? "none")")
                continue
            }
            #expect(reason == .error)
            #expect(message.stopReason == .error)
            let tail = String(decoding: prefix, as: UTF8.self).components(separatedBy: "\n\n").last ?? ""
            let expected = jsTrim(tail).isEmpty
                ? "Google stream ended without a finish reason"
                : "Incomplete JSON segment at the end"
            #expect(message.errorMessage == expected, "\(fixture.name) cut \(cut)")
            #expect(!events.contains { $0.type == "done" })
        }
    }

    @Test("aborting mid-stream ends promptly with stopReason aborted", arguments: googleReplayFixtures.map(\.name))
    func abortMidStream(_ name: String) async throws {
        let fixture = googleReplayFixtures.first { $0.name == name }!
        let bytes = sseBytes(fixture)
        let controller = AbortController()
        let firstHalf = bytes.prefix(bytes.count / 2)
        let started = Locked(false)
        let respond: @Sendable (FetchRequest) async throws -> FetchResponse = { request in
            let (stream, continuation) = AsyncThrowingStream<Data, any Error>.makeStream()
            for chunk in randomChunks(firstHalf, seed: 9) { continuation.yield(chunk) }
            let signal = request.signal
            signal?.addEventListener { continuation.finish(throwing: signal?.reason ?? AbortError()) }
            if signal?.aborted == true { continuation.finish(throwing: signal?.reason ?? AbortError()) }
            started.withLock { $0 = true }
            return FetchResponse(status: 200, headers: Headers([("content-type", "text/event-stream")]), body: ResponseBody(stream))
        }
        Task {
            while !started.withLock({ $0 }) { try? await Task.sleep(nanoseconds: 2_000_000) }
            try? await Task.sleep(nanoseconds: 20_000_000)
            controller.abort()
        }
        let startedAt = dateNow()
        let events = try await run(fixture, signal: controller.signal, respond)
        #expect(dateNow() - startedAt < 2000)
        guard case .error(let reason, let message)? = events.last else {
            Issue.record("\(fixture.name): last event \(events.last?.type ?? "none")")
            return
        }
        #expect(reason == .aborted)
        #expect(message.stopReason == .aborted)
        #expect(events.first?.type == "start")
    }
}
