import Foundation
import Testing
@testable import PiAI

// Fixture replay for api/openai-responses.swift and api/azure-openai-responses.swift.
//
// Fixtures (`_fixtures_D_responses.swift`) were recorded from upstream pi (TS) against a local
// OpenAI-compatible endpoint serving GLM-5.3-Flash: /tmp/pi-live/fixtures/responses-*.{request.json,sse}.
// Expected final messages and update-event sequences are what upstream emitted for the same streams
// (/tmp/pi-live/out/fx-openai-responses-*.jsonl). The model and tools match the recording runner:
// provider "openai", reasoning model, input text+image, maxTokens 32000, `streamSimple` with the
// agent's thinking level. Azure reuses the same fixtures through `streamSimpleAzureOpenAIResponses`.

private let systemPrompt = "You are a helpful assistant with access to workspace tools."
private let thinkPrompt = "What is 17*23? Answer with only the number."
private let toolsPrompt = "Use the tools to list the files in the workspace, then read every file, and tell me their exact contents."
private let fixtureNames = ["think", "tools-1", "tools-2", "tools-3"]

private enum Flavor: String, CaseIterable, Sendable, CustomTestStringConvertible {
    case openai, azure
    var testDescription: String { rawValue }
}

private func replayModel(_ flavor: Flavor) -> Model {
    Model(
        id: "zcode/GLM-5.3-Flash", name: "zcode/GLM-5.3-Flash",
        api: flavor == .openai ? "openai-responses" : "azure-openai-responses",
        provider: flavor == .openai ? "openai" : "azure",
        baseUrl: "http://127.0.0.1:3426/v1", reasoning: true, input: ["text", "image"],
        contextWindow: 1_000_000, maxTokens: 32000
    )
}

private func fixtureJSON(_ text: String) -> JsonValue {
    guard let value = try? JsonValue.parse(text) else { fatalError("bad fixture JSON") }
    return value
}

/// Tools exactly as the recording sent them (TypeBox key order), read back from the recorded body.
private func replayTools() -> [Tool] {
    (fixtureJSON(responsesFixtures["think"]!.requestBody)["tools"]?.arrayValue ?? []).map { tool in
        Tool(name: tool["name"]!.stringValue!, description: tool["description"]!.stringValue!, parameters: tool["parameters"]!)
    }
}

/// Canonical form with sorted object keys, for comparing against upstream's insertion-ordered JSON.
private func canonical(_ value: JsonValue) -> JsonValue {
    switch value {
    case .object(let o):
        var sorted = JsonObject()
        for key in o.keys.sorted() { sorted[key] = canonical(o[key]!) }
        return .object(sorted)
    case .array(let a): return .array(a.map(canonical))
    default: return value
    }
}

private func expectedMessage(_ name: String, _ flavor: Flavor) -> JsonValue {
    var json = fixtureJSON(responsesFixtures[name]!.expectedMessage)
    if flavor == .azure {
        json["api"] = "azure-openai-responses"
        json["provider"] = "azure"
    }
    return json
}

private func messageJSON(_ message: AssistantMessage) -> JsonValue {
    var json = message.json
    json["timestamp"] = nil
    json["durationMs"] = nil
    json["thinkingLevel"] = nil
    return json
}

private func previousMessage(_ name: String, _ flavor: Flavor) throws -> AssistantMessage {
    var json = expectedMessage(name, flavor)
    json["timestamp"] = 0
    return try AssistantMessage(json: json)
}

private func toolResult(_ call: ToolCall, _ text: String) -> Message {
    .toolResult(ToolResultMessage(toolCallId: call.id, toolName: call.name, content: [.text(TextContent(text: text))], isError: false))
}

/// The conversation for each fixture, chained through upstream's assistant messages like the agent loop did.
private func turnMessages(_ name: String, _ flavor: Flavor) throws -> [Message] {
    var messages: [Message] = [.user(UserMessage(content: .blocks([.text(TextContent(text: name == "think" ? thinkPrompt : toolsPrompt))])))]
    if name == "tools-2" || name == "tools-3" {
        let first = try previousMessage("tools-1", flavor)
        messages.append(.assistant(first))
        messages.append(toolResult(dToolCalls(first)[0], "a.txt\nb.txt"))
    }
    if name == "tools-3" {
        let second = try previousMessage("tools-2", flavor)
        messages.append(.assistant(second))
        let calls = dToolCalls(second)
        messages.append(toolResult(calls[0], "alpha\n"))
        messages.append(toolResult(calls[1], "beta\n"))
    }
    return messages
}

private func reasoningFor(_ name: String) -> ThinkingLevel { name == "think" ? .high : .low }

private struct Replay: Sendable {
    var events: [AssistantMessageEvent]
    var result: AssistantMessage
    var request: DCapturedRequest?
}

private func replay(
    _ name: String,
    _ flavor: Flavor,
    fetch: @escaping FetchFunction,
    recorder: DRecorder,
    signal: AbortSignal? = nil,
    onEvent: (@Sendable (AssistantMessageEvent) -> Void)? = nil
) async throws -> Replay {
    var options = SimpleStreamOptions()
    options.apiKey = "magpie"
    options.fetch = fetch
    options.reasoning = reasoningFor(name)
    options.signal = signal
    options.env = [:]
    if flavor == .azure { options.extra["azureBaseUrl"] = "http://127.0.0.1:3426/v1" }
    let context = normalizeContext(Context(systemPrompt: systemPrompt, messages: try turnMessages(name, flavor), tools: replayTools()))
    let model = replayModel(flavor)
    let stream = flavor == .openai
        ? streamSimpleOpenAIResponses(model, context, options)
        : streamSimpleAzureOpenAIResponses(model, context, options)
    var events: [AssistantMessageEvent] = []
    for await event in stream {
        events.append(event)
        onEvent?(event)
    }
    return Replay(events: events, result: await stream.result(), request: recorder.last)
}

private func replaySSE(_ name: String, _ flavor: Flavor, sse: String? = nil, chunkSizes: [Int] = []) async throws -> Replay {
    let recorder = DRecorder()
    return try await replay(name, flavor, fetch: dSSEFetch(recorder, sse ?? responsesFixtures[name]!.sse, chunkSizes: chunkSizes), recorder: recorder)
}

/// Fails (instead of hanging the suite) when `body` does not finish within `seconds`.
private func within<T: Sendable>(_ seconds: Double, _ body: @escaping @Sendable () async throws -> T) async throws -> T {
    try await withThrowingTaskGroup(of: T?.self) { group in
        group.addTask { try await body() }
        group.addTask {
            try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            return nil
        }
        let first = try await group.next()!
        group.cancelAll()
        guard let value = first else { throw PiError("timed out after \(seconds)s") }
        return value
    }
}

/// Deterministic 1–7 byte chunk sizes.
private func randomChunkSizes(seed: UInt64, count: Int = 512) -> [Int] {
    var state = seed &* 6364136223846793005 &+ 1442695040888963407
    return (0..<count).map { _ in
        state = state &* 6364136223846793005 &+ 1442695040888963407
        return Int((state >> 33) % 7) + 1
    }
}

private func updateTypes(_ events: [AssistantMessageEvent]) -> [String] {
    events.map(\.type).filter { $0 != "start" && $0 != "done" && $0 != "error" }
}

/// The recorded body as the given adapter would send it: Azure omits nothing the OpenAI recording has,
/// and sends no extra fields for these requests.
/// The recording came from the openai adapter. Upstream Azure passes `model.compat?.supportsStrictMode ?? true`
/// (raw compat) to `convertResponsesTools`, while openai passes the resolved compat (false for this endpoint),
/// so Azure function tools additionally carry `strict: false`.
private func expectedBody(_ name: String, _ flavor: Flavor = .openai) -> JsonValue {
    let body = fixtureJSON(responsesFixtures[name]!.requestBody)
    guard flavor == .azure, var object = body.objectValue, let tools = object["tools"]?.arrayValue else { return body }
    object["tools"] = .array(tools.map { tool in
        guard var t = tool.objectValue, t["type"]?.stringValue == "function" else { return tool }
        t["strict"] = false
        return .object(t)
    })
    return .object(object)
}

/// What upstream (openai 7.19.0 `_iterSSEMessages` + `Stream`, then `processResponsesStream`) reports for a body
/// that ends after `sse`: the in-progress event left after the last blank line is flushed once, so a
/// partial `data:` line fails JSON parsing; otherwise the stream simply ends without a terminal event.
private func upstreamTruncationMessage(_ sse: String) -> String {
    let tail = sse.components(separatedBy: "\n\n").last ?? ""
    var event: String?
    var data: [String] = []
    for line in tail.components(separatedBy: "\n") where !line.isEmpty {
        if line.hasPrefix("event:") { event = String(line.dropFirst(6)).trimmingCharacters(in: .whitespaces) }
        if line.hasPrefix("data:") { data.append(String(line.dropFirst(line.hasPrefix("data: ") ? 6 : 5))) }
    }
    if event != nil || !data.isEmpty {
        let joined = data.joined(separator: "\n")
        if joined != "[DONE]" && (try? JsonValue.parse(joined)) == nil {
            return "Error reading response: malformed server-sent event JSON."
        }
    }
    return "OpenAI Responses stream ended before a terminal response event"
}

@Suite struct OpenAIResponsesReplayTests {
    // (a) request body
    @Test(arguments: Flavor.allCases, fixtureNames)
    fileprivate func requestBodyMatchesTheRecording(_ flavor: Flavor, _ name: String) async throws {
        let replay = try await replaySSE(name, flavor)
        let request = try #require(replay.request)
        let body = try #require(request.body)
        #expect(canonical(body) == canonical(expectedBody(name, flavor)), "\(canonical(body).serialized())")
        switch flavor {
        case .openai:
            #expect(request.url.absoluteString == "http://127.0.0.1:3426/v1/responses")
            #expect(request.header("authorization") == "Bearer magpie")
        case .azure:
            #expect(request.url.absoluteString == "http://127.0.0.1:3426/v1/responses?api-version=v1")
            #expect(request.header("api-key") == "magpie")
        }
        #expect(request.header("user-agent") == getPiUserAgent())
        #expect(request.header("content-type") == "application/json")
        #expect(request.header("accept") == "application/json")
    }

    // (b) whole and chunked SSE replay
    @Test(arguments: Flavor.allCases, fixtureNames)
    fileprivate func replaysTheRecordedStream(_ flavor: Flavor, _ name: String) async throws {
        let fixture = responsesFixtures[name]!
        let expected = canonical(expectedMessage(name, flavor))
        for chunkSizes in [[], randomChunkSizes(seed: 1), randomChunkSizes(seed: 7), randomChunkSizes(seed: 42)] {
            let replay = try await within(10) { try await replaySSE(name, flavor, chunkSizes: chunkSizes) }
            #expect(replay.events.first?.type == "start")
            #expect(replay.events.last?.type == "done", "\(replay.result.errorMessage ?? "")")
            #expect(updateTypes(replay.events) == fixture.expectedUpdateTypes)
            #expect(canonical(messageJSON(replay.result)) == expected)
            if case .done(_, let message)? = replay.events.last {
                #expect(canonical(messageJSON(message)) == expected)
            }
        }
    }

    @Test(arguments: Flavor.allCases)
    fileprivate func finalMessagesCarryTheRecordedContent(_ flavor: Flavor) async throws {
        let think = try await replaySSE("think", flavor).result
        #expect(dTextOf(think) == "391")
        #expect(think.content.first?.thinkingContent?.thinking.isEmpty == false)

        let tools1 = try await replaySSE("tools-1", flavor).result
        #expect(tools1.stopReason == .toolUse)
        #expect(dToolCalls(tools1).map(\.name) == ["ls"])
        #expect(dToolCalls(tools1).first?.arguments == ["path": "."])
        #expect(tools1.usage.input == 230)
        #expect(tools1.usage.output == 11)
        #expect(tools1.usage.totalTokens == 241)

        let tools2 = try await replaySSE("tools-2", flavor).result
        #expect(dToolCalls(tools2).map(\.arguments) == [["path": "a.txt"], ["path": "b.txt"]])
    }

    // (c) truncated SSE ends with an error event carrying upstream's message
    @Test(arguments: Flavor.allCases, fixtureNames)
    fileprivate func truncatedStreamsEndWithAnError(_ flavor: Flavor, _ name: String) async throws {
        let bytes = Array(responsesFixtures[name]!.sse.utf8)
        let marker = Array("event: response.completed".utf8)
        let completedAt = (0...(bytes.count - marker.count)).last { Array(bytes[$0..<($0 + marker.count)]) == marker }!
        for cut in [1, 37, bytes.count / 3, bytes.count / 2, completedAt - 1, completedAt, completedAt + 10, completedAt + 40, bytes.count - 3] {
            let sse = String(decoding: bytes[..<cut], as: UTF8.self)
            let replay = try await within(10) { try await replaySSE(name, flavor, sse: sse) }
            #expect(replay.events.last?.type == "error", "cut \(cut)")
            #expect(!replay.events.contains { $0.type == "done" }, "cut \(cut)")
            #expect(replay.result.stopReason == .error, "cut \(cut)")
            #expect(replay.result.errorMessage == upstreamTruncationMessage(sse), "cut \(cut): \(replay.result.errorMessage ?? "nil")")
        }
    }

    // (c') the connection drops mid-stream: the transport error message reaches the final message
    @Test(arguments: Flavor.allCases)
    fileprivate func droppedConnectionsEndWithTheTransportError(_ flavor: Flavor) async throws {
        let bytes = Data(responsesFixtures["tools-1"]!.sse.utf8)
        let recorder = DRecorder()
        let fetch: FetchFunction = { request in
            recorder.record(request)
            let (stream, continuation) = AsyncThrowingStream<Data, any Error>.makeStream()
            continuation.yield(bytes.prefix(bytes.count / 2))
            continuation.finish(throwing: PiError("terminated", name: "TypeError"))
            return FetchResponse(status: 200, headers: Headers([("content-type", "text/event-stream")]), body: ResponseBody(stream))
        }
        let replay = try await within(10) { try await replay("tools-1", flavor, fetch: fetch, recorder: recorder) }
        #expect(replay.events.last?.type == "error")
        #expect(replay.result.stopReason == .error)
        #expect(replay.result.errorMessage == "terminated", "\(replay.result.errorMessage ?? "nil")")
    }

    // (d) abort mid-stream
    @Test(arguments: Flavor.allCases)
    fileprivate func abortMidStreamEndsPromptlyAsAborted(_ flavor: Flavor) async throws {
        let sse = responsesFixtures["think"]!.sse
        let bytes = Array(sse.utf8)
        let half = String(decoding: bytes[..<(bytes.count / 2)], as: UTF8.self)
        let controller = AbortController()
        let recorder = DRecorder()
        let started = Date()
        let replay = try await within(5) {
            try await replay(
                "think", flavor,
                fetch: dSSEFetch(recorder, half, hangAtEnd: true),
                recorder: recorder,
                signal: controller.signal,
                onEvent: { event in
                    if event.type == "thinking_delta" { controller.abort() }
                }
            )
        }
        #expect(Date().timeIntervalSince(started) < 2)
        #expect(replay.events.last?.type == "error")
        #expect(replay.result.stopReason == .aborted)
        #expect(!replay.events.contains { $0.type == "done" })
    }

    @Test(arguments: Flavor.allCases)
    fileprivate func abortWhileTheServerHangsEndsPromptlyAsAborted(_ flavor: Flavor) async throws {
        let controller = AbortController()
        let recorder = DRecorder()
        let task = Task {
            try await replay("think", flavor, fetch: dSSEFetch(recorder, "", hangAtEnd: true), recorder: recorder, signal: controller.signal)
        }
        try await Task.sleep(nanoseconds: 100_000_000)
        controller.abort()
        let replay = try await within(5) { try await task.value }
        #expect(replay.events.last?.type == "error")
        #expect(replay.result.stopReason == .aborted)
    }
}
