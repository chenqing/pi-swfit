import Foundation
import Testing
@testable import PiAI

// Fixture replay for api/openai-completions.swift.
//
// Fixtures (inline at the bottom of this file) were recorded from upstream pi (TS) against a local
// OpenAI-compatible endpoint serving GLM-5.3-Flash: /tmp/pi-live/fixtures/completions-*.{request.json,sse}.
// The expected final messages and event-type sequences are what upstream itself emitted for the same
// streams (/tmp/pi-live/out/fx-openai-completions-*.jsonl, with the agent-only fields timestamp,
// durationMs and thinkingLevel removed). The model and tools match the recording runner
// (/tmp/pi-ref/live/ref.mjs): provider "openai", reasoning model, input text+image, maxTokens 32000.

private let systemPrompt = "You are a helpful assistant with access to workspace tools."
private let toolsPrompt = "Use the tools to list the files in the workspace, then read every file, and tell me their exact contents."

private func replayModel() -> Model {
    Model(
        id: "zcode/GLM-5.3-Flash", name: "zcode/GLM-5.3-Flash", api: "openai-completions", provider: "openai",
        baseUrl: "http://127.0.0.1:3426/v1", reasoning: true, input: ["text", "image"],
        cost: ModelCost(input: 0, output: 0, cacheRead: 0, cacheWrite: 0), contextWindow: 1_000_000, maxTokens: 32000
    )
}

/// Tools exactly as the recording sent them (TypeBox key order), read back from the recorded body.
private func replayTools() -> [Tool] {
    let body = cJSON(completionsFixtures["think"]!.requestBody)
    return (body["tools"]?.arrayValue ?? []).map { tool in
        let function = tool["function"]!
        return Tool(name: function["name"]!.stringValue!, description: function["description"]!.stringValue!, parameters: function["parameters"]!)
    }
}

private func userBlocks(_ text: String) -> Message {
    .user(UserMessage(content: .blocks([.text(TextContent(text: text))])))
}

private func toolResult(_ id: String, _ name: String, _ text: String) -> Message {
    .toolResult(ToolResultMessage(toolCallId: id, toolName: name, content: [.text(TextContent(text: text))], isError: false))
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

private func messageJSON(_ message: AssistantMessage) -> JsonValue {
    var json = message.json
    json["timestamp"] = nil
    json["durationMs"] = nil
    json["thinkingLevel"] = nil
    return json
}

private struct Replay {
    var events: [AssistantMessageEvent]
    var result: AssistantMessage
    var request: FetchRequest?
}

private func replay(
    _ messages: [Message],
    reasoning: ThinkingLevel,
    response: @escaping @Sendable (FetchRequest) async throws -> FetchResponse,
    signal: AbortSignal? = nil,
    onEvent: (@Sendable (AssistantMessageEvent) -> Void)? = nil
) async -> Replay {
    let server = CFakeServer { request, _ in try await response(request) }
    var options = SimpleStreamOptions()
    options.apiKey = "magpie"
    options.fetch = server.fetch
    options.reasoning = reasoning
    options.signal = signal
    let context = normalizeContext(Context(systemPrompt: systemPrompt, messages: messages, tools: replayTools()))
    let stream = streamSimpleOpenAICompletions(replayModel(), context, options)
    var events: [AssistantMessageEvent] = []
    for await event in stream {
        events.append(event)
        onEvent?(event)
    }
    return Replay(events: events, result: await stream.result(), request: server.requests.first)
}

/// Fails (instead of hanging the suite) when `body` does not finish within `seconds`.
private func within<T: Sendable>(_ seconds: Double, _ body: @escaping @Sendable () async -> T) async throws -> T {
    try await withThrowingTaskGroup(of: T?.self) { group in
        group.addTask { await body() }
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

/// The conversation for each fixture, chained through the replayed assistant messages like the agent loop did.
private func turnMessages(_ previous: [String: AssistantMessage], _ name: String) -> [Message] {
    var messages = [userBlocks(name == "think" ? "What is 17*23? Answer with only the number." : toolsPrompt)]
    if name == "tools-2" || name == "tools-3" {
        messages.append(.assistant(previous["tools-1"]!))
        messages.append(toolResult("call_fd4d5436964845e3a3378554", "ls", "a.txt\nb.txt"))
    }
    if name == "tools-3" {
        messages.append(.assistant(previous["tools-2"]!))
        messages.append(toolResult("call_5166d8b8caec4c39b392116e", "read", "alpha\n"))
        messages.append(toolResult("call_2270a14e9de740268fe78ab3", "read", "beta\n"))
    }
    return messages
}

private func reasoningFor(_ name: String) -> ThinkingLevel { name == "think" ? .high : .low }

private func expectedMessage(_ name: String) throws -> AssistantMessage {
    var json = cJSON(completionsFixtures[name]!.expectedMessage)
    json["timestamp"] = 0
    return try AssistantMessage(json: json)
}

private func previousMessages() throws -> [String: AssistantMessage] {
    ["tools-1": try expectedMessage("tools-1"), "tools-2": try expectedMessage("tools-2")]
}

/// Byte offset of the first `finish_reason` that is not null (cuts before it must not finish the stream).
private func finishOffset(_ sse: String) -> Int {
    let bytes = Array(sse.utf8)
    let needle = Array(#""finish_reason":""#.utf8)
    for i in 0...(bytes.count - needle.count) where Array(bytes[i..<(i + needle.count)]) == needle {
        // Back up to the start of this `data:` line.
        var j = i
        while j > 0 && bytes[j - 1] != UInt8(ascii: "\n") { j -= 1 }
        return j
    }
    fatalError("no finish_reason in fixture")
}

/// What upstream reports for a stream that ends at EOF without `finish_reason`. openai@7.19.0 flushes an
/// unterminated last event at EOF, so a cut inside a `data:` line surfaces as the SDK's JSON SyntaxError;
/// a cut on an event boundary (or after a complete `data:` line) reaches pi's own check.
private func expectedTruncationMessage(_ truncated: String) -> String {
    let tail = truncated.components(separatedBy: "\n\n").last ?? ""
    let data = tail.split(separator: "\n", omittingEmptySubsequences: false)
        .filter { $0.hasPrefix("data:") }
        .map { line -> String in
            var value = String(line.dropFirst(5))
            if value.hasPrefix(" ") { value.removeFirst() }
            return value
        }
    if data.isEmpty { return "Stream ended without finish_reason" }
    return (try? JsonValue.parse(data.joined(separator: "\n"))) == nil
        ? "Error reading response: malformed server-sent event JSON."
        : "Stream ended without finish_reason"
}

private func slowResponse(_ sse: String, upTo: Int, hangAfter: Bool) -> @Sendable (FetchRequest) async throws -> FetchResponse {
    { request in
        let bytes = Array(sse.utf8)
        let signal = request.signal
        let stream = AsyncThrowingStream<Data, any Error> { continuation in
            let task = Task {
                var offset = 0
                while offset < upTo {
                    let end = min(upTo, offset + 64)
                    continuation.yield(Data(bytes[offset..<end]))
                    offset = end
                    try? await Task.sleep(nanoseconds: 1_000_000)
                }
                if hangAfter {
                    while !(signal?.aborted ?? false) && !Task.isCancelled {
                        try? await Task.sleep(nanoseconds: 2_000_000)
                    }
                    continuation.finish(throwing: signal?.reason ?? AbortError())
                } else {
                    continuation.finish()
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
        return FetchResponse(status: 200, headers: Headers([("content-type", "text/event-stream")]), body: ResponseBody(stream))
    }
}

@Suite("openai-completions fixture replay")
struct OpenAICompletionsReplayTests {
    static let names = ["think", "tools-1", "tools-2", "tools-3"]

    // (a) The request body matches the recorded body field for field (and byte for byte).
    @Test("request body and headers match the recording", arguments: names)
    func requestMatchesRecording(_ name: String) async throws {
        let fixture = completionsFixtures[name]!
        let previous = try previousMessages()
        let sse = fixture.sse
        let run = await replay(turnMessages(previous, name), reasoning: reasoningFor(name), response: { _ in cSSEResponse(sse) })
        let request = try #require(run.request)
        let body = String(decoding: request.body ?? Data(), as: UTF8.self)
        let recorded = cJSON(fixture.requestBody)
        let sent = cJSON(body)
        #expect(cKeys(sent) == cKeys(recorded))
        for key in cKeys(recorded) {
            #expect(sent[key] == recorded[key], "body.\(key) differs")
        }
        #expect(body == fixture.requestBody)

        let meta = cJSON(fixture.requestMeta)
        #expect(request.method == "POST")
        #expect(request.url.absoluteString == "http://127.0.0.1:3426" + meta["path"]!.stringValue!)
        for header in ["authorization", "user-agent", "content-type", "accept"] {
            let recordedValue = meta["headers"]?[header]?.stringValue
            let expected = header == "user-agent" ? getPiUserAgent() : recordedValue
            #expect(request.headers.get(header) == expected, "header \(header)")
        }
        #expect(meta["headers"]?["user-agent"]?.stringValue?.hasPrefix("pi (") == true)
    }

    // (b) The SSE replays to upstream's events and final message, whole and in random 1-7 byte chunks.
    @Test("SSE replays to upstream's events and final message", arguments: names)
    func sseReplays(_ name: String) async throws {
        let fixture = completionsFixtures[name]!
        let previous = try previousMessages()
        var generator = SystemRandomNumberGenerator()
        let chunkings: [[Int]?] = [nil, [1], [7]] + (0..<5).map { _ in (0..<64).map { _ in Int.random(in: 1...7, using: &generator) } }
        for chunkSizes in chunkings {
            let sse = fixture.sse
            let run = try await within(10) {
                await replay(turnMessages(previous, name), reasoning: reasoningFor(name), response: { _ in cSSEResponse(sse, chunkSizes: chunkSizes) })
            }
            #expect(run.events.map(\.type) == fixture.expectedEvents, "chunking \(String(describing: chunkSizes))")
            #expect(canonical(messageJSON(run.result)) == canonical(cJSON(fixture.expectedMessage)), "chunking \(String(describing: chunkSizes))")
            guard case .done(let reason, let message) = run.events.last else {
                Issue.record("last event is not done")
                continue
            }
            #expect(reason == run.result.stopReason)
            #expect(canonical(messageJSON(message)) == canonical(messageJSON(run.result)))
        }
    }

    @Test("replayed content details: thinking, text, tool call deltas and parsed arguments")
    func replayDetails() async throws {
        let previous = try previousMessages()

        let think = await replay(turnMessages(previous, "think"), reasoning: .high, response: { _ in cSSEResponse(completionsFixtures["think"]!.sse) })
        let thinkingDeltas = think.events.compactMap { event -> String? in
            if case .thinkingDelta(_, let delta, _) = event { return delta }
            return nil
        }
        #expect(thinkingDeltas.joined() == "Simple arithmetic: 17 * 23 = 391. The user wants only the number.")
        let ends = think.events.compactMap { event -> String? in
            switch event {
            case .thinkingEnd(let index, let content, _): return "thinking:\(index):\(content)"
            case .textEnd(let index, let content, _): return "text:\(index):\(content)"
            default: return nil
            }
        }
        #expect(ends == ["thinking:0:Simple arithmetic: 17 * 23 = 391. The user wants only the number.", "text:1:391"])
        #expect(think.result.usage.input == 220)
        #expect(think.result.usage.output == 24)
        #expect(think.result.usage.totalTokens == 244)
        #expect(think.result.usage.reasoning == 0)

        let tools = await replay(turnMessages(previous, "tools-2"), reasoning: .low, response: { _ in cSSEResponse(completionsFixtures["tools-2"]!.sse) })
        #expect(tools.result.stopReason == .toolUse)
        #expect(tools.result.rawStopReason == "tool_calls")
        let toolEnds = tools.events.compactMap { event -> String? in
            if case .toolcallEnd(let index, let call, _) = event { return "\(index):\(call.id):\(call.name):\(JsonValue.object(call.arguments).serialized())" }
            return nil
        }
        #expect(toolEnds == [
            #"0:call_5166d8b8caec4c39b392116e:read:{"path":"a.txt"}"#,
            #"1:call_2270a14e9de740268fe78ab3:read:{"path":"b.txt"}"#,
        ])
        // Partial JSON is parsed as it streams.
        let partials = tools.events.compactMap { event -> JsonValue? in
            guard case .toolcallDelta(0, _, let partial) = event, case .toolCall(let call) = partial.content[0] else { return nil }
            return .object(call.arguments)
        }
        #expect(partials.contains(cJSON(#"{"path":"a"}"#)))
        #expect(partials.last == cJSON(#"{"path":"a.txt"}"#))
    }

    // (c) Truncated streams end with upstream's error (pi's finish_reason check, or the SDK's JSON error for a
    // cut inside an event), never hang and never finish silently.
    @Test("truncated SSE ends with an error event", arguments: names)
    func truncatedStreams(_ name: String) async throws {
        let fixture = completionsFixtures[name]!
        let previous = try previousMessages()
        let sse = fixture.sse
        let finish = finishOffset(sse)
        let cuts = [0, 1, 37, finish / 3, finish / 2, finish - 5, finish - 2, finish - 1, finish]
        for cut in cuts {
            let truncated = String(decoding: Array(sse.utf8)[0..<cut], as: UTF8.self)
            let run = try await within(10) {
                await replay(turnMessages(previous, name), reasoning: reasoningFor(name), response: { _ in cSSEResponse(truncated, chunkSizes: [3, 5, 2]) })
            }
            guard case .error(let reason, let error) = run.events.last else {
                Issue.record("cut \(cut): last event is \(run.events.last?.type ?? "none")")
                continue
            }
            #expect(reason == .error, "cut \(cut)")
            #expect(error.stopReason == .error, "cut \(cut)")
            #expect(error.errorMessage == expectedTruncationMessage(truncated), "cut \(cut)")
            #expect(!run.events.contains { $0.type == "done" }, "cut \(cut)")
        }
    }

    @Test("a connection dropped mid-body ends with the transport error")
    func droppedConnection() async throws {
        let previous = try previousMessages()
        let sse = completionsFixtures["think"]!.sse
        let cut = finishOffset(sse) / 2
        let run = try await within(10) {
            await replay(turnMessages(previous, "think"), reasoning: .high, response: { _ in
                let bytes = Array(sse.utf8)[0..<cut]
                let stream = AsyncThrowingStream<Data, any Error> { continuation in
                    continuation.yield(Data(bytes))
                    continuation.finish(throwing: PiError("terminated", name: "TypeError"))
                }
                return FetchResponse(status: 200, headers: Headers([("content-type", "text/event-stream")]), body: ResponseBody(stream))
            })
        }
        guard case .error(let reason, let error) = run.events.last else {
            Issue.record("last event is \(run.events.last?.type ?? "none")")
            return
        }
        #expect(reason == .error)
        #expect(error.errorMessage == "terminated")
        // Upstream keeps the partial thinking block and the response id (ref-openai-completions-cut.jsonl).
        #expect(error.responseId == "chatcmpl-msg_20261021140119ab0abbb5373248c7")
        if case .thinking(let thinking) = error.content.first {
            #expect(thinking.thinkingSignature == "reasoning_content")
            #expect(!thinking.thinking.isEmpty)
        } else {
            Issue.record("expected partial thinking block")
        }
    }

    // Upstream parity: a stream cut after finish_reason (before usage / [DONE]) still completes.
    @Test("SSE cut after finish_reason completes like upstream")
    func cutAfterFinish() async throws {
        let previous = try previousMessages()
        let sse = completionsFixtures["tools-1"]!.sse
        let bytes = Array(sse.utf8)
        let finish = finishOffset(sse)
        let lineEnd = (finish..<bytes.count).first { bytes[$0] == UInt8(ascii: "\n") }! + 2
        let truncated = String(decoding: bytes[0..<lineEnd], as: UTF8.self)
        let run = await replay(turnMessages(previous, "tools-1"), reasoning: .low, response: { _ in cSSEResponse(truncated) })
        #expect(run.events.last?.type == "done")
        #expect(run.result.stopReason == .toolUse)
        #expect(run.result.usage.totalTokens == 0)
    }

    // (d) Aborting mid-stream ends promptly with stopReason "aborted".
    @Test("abort mid-stream ends promptly with stopReason aborted", arguments: names)
    func abortMidStream(_ name: String) async throws {
        let fixture = completionsFixtures[name]!
        let previous = try previousMessages()
        let sse = fixture.sse
        let controller = AbortController()
        let abortedAt = Locked<Int?>(nil)
        let firstDeltaSeen = Locked(false)
        let run = try await within(5) {
            await replay(
                turnMessages(previous, name), reasoning: reasoningFor(name),
                response: slowResponse(sse, upTo: finishOffset(sse), hangAfter: true),
                signal: controller.signal,
                onEvent: { event in
                    guard event.type.hasSuffix("_delta"), !firstDeltaSeen.current else { return }
                    firstDeltaSeen.withLock { $0 = true }
                    abortedAt.withLock { $0 = dateNow() }
                    controller.abort()
                }
            )
        }
        guard case .error(let reason, let error) = run.events.last else {
            Issue.record("last event is \(run.events.last?.type ?? "none")")
            return
        }
        #expect(reason == .aborted)
        #expect(error.stopReason == .aborted)
        #expect(error.errorMessage == "Request was aborted")
        #expect(!run.events.contains { $0.type == "done" })
        let elapsed = dateNow() - (abortedAt.current ?? dateNow())
        #expect(elapsed < 1000, "abort took \(elapsed)ms")
    }

    @Test("abort before response headers ends with stopReason aborted")
    func abortBeforeHeaders() async throws {
        let previous = try previousMessages()
        let controller = AbortController()
        Task {
            try? await Task.sleep(nanoseconds: 50_000_000)
            controller.abort()
        }
        let run = try await within(5) {
            await replay(turnMessages(previous, "think"), reasoning: .high, response: { request in
                while !(request.signal?.aborted ?? false) { try await Task.sleep(nanoseconds: 2_000_000) }
                throw request.signal?.reason ?? AbortError()
            }, signal: controller.signal)
        }
        #expect(run.events.map(\.type) == ["error"] || run.events.map(\.type) == ["start", "error"])
        #expect(run.result.stopReason == .aborted)
        // Upstream: ref-openai-completions-hang-abort.jsonl.
        #expect(run.result.errorMessage == "Request aborted")
        #expect(run.result.content.isEmpty)
    }
}

// MARK: - Fixtures (verbatim bytes)

private struct CompletionsFixture {
    let name: String
    let requestMeta: String
    let requestBody: String
    let sse: String
    let expectedMessage: String
    let expectedEvents: [String]
}

private let completionsFixtures: [String: CompletionsFixture] = [
    "think": CompletionsFixture(
        name: "think",
        requestMeta: #"""
{"path": "/v1/chat/completions", "headers": {"host": "127.0.0.1:3426", "connection": "keep-alive", "accept": "application/json", "x-stainless-retry-count": "0", "x-stainless-lang": "js", "x-stainless-package-version": "7.19.0", "x-stainless-os": "MacOS", "x-stainless-arch": "arm64", "x-stainless-runtime": "node", "x-stainless-runtime-version": "v25.9.0", "authorization": "Bearer magpie", "user-agent": "pi (darwin 27.2.0; arm64)", "content-type": "application/json", "accept-language": "*", "sec-fetch-mode": "cors", "accept-encoding": "gzip, deflate", "content-length": "740"}}
"""#,
        requestBody: #"""
{"model":"zcode/GLM-5.3-Flash","messages":[{"role":"developer","content":"You are a helpful assistant with access to workspace tools."},{"role":"user","content":[{"type":"text","text":"What is 17*23? Answer with only the number."}]}],"stream":true,"stream_options":{"include_usage":true},"store":false,"max_completion_tokens":32000,"tools":[{"type":"function","function":{"name":"ls","description":"List files in the workspace directory.","parameters":{"type":"object","properties":{"path":{"type":"string"}}}}},{"type":"function","function":{"name":"read","description":"Read a file in the workspace by relative path.","parameters":{"type":"object","required":["path"],"properties":{"path":{"type":"string"}}}}}],"reasoning_effort":"high"}
"""#,
        sse: #"""
data: {"choices":[{"delta":{"content":"","role":"assistant"},"finish_reason":null,"index":0}],"created":1792562484,"id":"chatcmpl-msg_20261021140119ab0abbb5373248c7","model":"GLM-5.3-Flash","object":"chat.completion.chunk","usage":null}

data: {"choices":[{"delta":{"reasoning_content":"Simple"},"finish_reason":null,"index":0}],"created":1792562484,"id":"chatcmpl-msg_20261021140119ab0abbb5373248c7","model":"GLM-5.3-Flash","object":"chat.completion.chunk","usage":null}

data: {"choices":[{"delta":{"reasoning_content":" arithmetic"},"finish_reason":null,"index":0}],"created":1792562484,"id":"chatcmpl-msg_20261021140119ab0abbb5373248c7","model":"GLM-5.3-Flash","object":"chat.completion.chunk","usage":null}

data: {"choices":[{"delta":{"reasoning_content":":"},"finish_reason":null,"index":0}],"created":1792562484,"id":"chatcmpl-msg_20261021140119ab0abbb5373248c7","model":"GLM-5.3-Flash","object":"chat.completion.chunk","usage":null}

data: {"choices":[{"delta":{"reasoning_content":" "},"finish_reason":null,"index":0}],"created":1792562484,"id":"chatcmpl-msg_20261021140119ab0abbb5373248c7","model":"GLM-5.3-Flash","object":"chat.completion.chunk","usage":null}

data: {"choices":[{"delta":{"reasoning_content":"17"},"finish_reason":null,"index":0}],"created":1792562484,"id":"chatcmpl-msg_20261021140119ab0abbb5373248c7","model":"GLM-5.3-Flash","object":"chat.completion.chunk","usage":null}

data: {"choices":[{"delta":{"reasoning_content":" *"},"finish_reason":null,"index":0}],"created":1792562484,"id":"chatcmpl-msg_20261021140119ab0abbb5373248c7","model":"GLM-5.3-Flash","object":"chat.completion.chunk","usage":null}

data: {"choices":[{"delta":{"reasoning_content":" "},"finish_reason":null,"index":0}],"created":1792562484,"id":"chatcmpl-msg_20261021140119ab0abbb5373248c7","model":"GLM-5.3-Flash","object":"chat.completion.chunk","usage":null}

data: {"choices":[{"delta":{"reasoning_content":"23"},"finish_reason":null,"index":0}],"created":1792562484,"id":"chatcmpl-msg_20261021140119ab0abbb5373248c7","model":"GLM-5.3-Flash","object":"chat.completion.chunk","usage":null}

data: {"choices":[{"delta":{"reasoning_content":" ="},"finish_reason":null,"index":0}],"created":1792562484,"id":"chatcmpl-msg_20261021140119ab0abbb5373248c7","model":"GLM-5.3-Flash","object":"chat.completion.chunk","usage":null}

data: {"choices":[{"delta":{"reasoning_content":" "},"finish_reason":null,"index":0}],"created":1792562484,"id":"chatcmpl-msg_20261021140119ab0abbb5373248c7","model":"GLM-5.3-Flash","object":"chat.completion.chunk","usage":null}

data: {"choices":[{"delta":{"reasoning_content":"39"},"finish_reason":null,"index":0}],"created":1792562484,"id":"chatcmpl-msg_20261021140119ab0abbb5373248c7","model":"GLM-5.3-Flash","object":"chat.completion.chunk","usage":null}

data: {"choices":[{"delta":{"reasoning_content":"1"},"finish_reason":null,"index":0}],"created":1792562484,"id":"chatcmpl-msg_20261021140119ab0abbb5373248c7","model":"GLM-5.3-Flash","object":"chat.completion.chunk","usage":null}

data: {"choices":[{"delta":{"reasoning_content":"."},"finish_reason":null,"index":0}],"created":1792562484,"id":"chatcmpl-msg_20261021140119ab0abbb5373248c7","model":"GLM-5.3-Flash","object":"chat.completion.chunk","usage":null}

data: {"choices":[{"delta":{"reasoning_content":" The"},"finish_reason":null,"index":0}],"created":1792562484,"id":"chatcmpl-msg_20261021140119ab0abbb5373248c7","model":"GLM-5.3-Flash","object":"chat.completion.chunk","usage":null}

data: {"choices":[{"delta":{"reasoning_content":" user"},"finish_reason":null,"index":0}],"created":1792562484,"id":"chatcmpl-msg_20261021140119ab0abbb5373248c7","model":"GLM-5.3-Flash","object":"chat.completion.chunk","usage":null}

data: {"choices":[{"delta":{"reasoning_content":" wants"},"finish_reason":null,"index":0}],"created":1792562484,"id":"chatcmpl-msg_20261021140119ab0abbb5373248c7","model":"GLM-5.3-Flash","object":"chat.completion.chunk","usage":null}

data: {"choices":[{"delta":{"reasoning_content":" only"},"finish_reason":null,"index":0}],"created":1792562484,"id":"chatcmpl-msg_20261021140119ab0abbb5373248c7","model":"GLM-5.3-Flash","object":"chat.completion.chunk","usage":null}

data: {"choices":[{"delta":{"reasoning_content":" the"},"finish_reason":null,"index":0}],"created":1792562484,"id":"chatcmpl-msg_20261021140119ab0abbb5373248c7","model":"GLM-5.3-Flash","object":"chat.completion.chunk","usage":null}

data: {"choices":[{"delta":{"reasoning_content":" number"},"finish_reason":null,"index":0}],"created":1792562484,"id":"chatcmpl-msg_20261021140119ab0abbb5373248c7","model":"GLM-5.3-Flash","object":"chat.completion.chunk","usage":null}

data: {"choices":[{"delta":{"reasoning_content":"."},"finish_reason":null,"index":0}],"created":1792562484,"id":"chatcmpl-msg_20261021140119ab0abbb5373248c7","model":"GLM-5.3-Flash","object":"chat.completion.chunk","usage":null}

data: {"choices":[{"delta":{"content":"39"},"finish_reason":null,"index":0}],"created":1792562484,"id":"chatcmpl-msg_20261021140119ab0abbb5373248c7","model":"GLM-5.3-Flash","object":"chat.completion.chunk","usage":null}

data: {"choices":[{"delta":{"content":"1"},"finish_reason":null,"index":0}],"created":1792562484,"id":"chatcmpl-msg_20261021140119ab0abbb5373248c7","model":"GLM-5.3-Flash","object":"chat.completion.chunk","usage":null}

data: {"choices":[{"delta":{},"finish_reason":"stop","index":0}],"created":1792562484,"id":"chatcmpl-msg_20261021140119ab0abbb5373248c7","model":"GLM-5.3-Flash","object":"chat.completion.chunk","usage":null}

data: {"choices":[],"created":1792562484,"id":"chatcmpl-msg_20261021140119ab0abbb5373248c7","model":"GLM-5.3-Flash","object":"chat.completion.chunk","usage":{"completion_tokens":24,"completion_tokens_details":{"reasoning_tokens":0},"prompt_tokens":220,"prompt_tokens_details":{"cache_write_tokens":0,"cached_tokens":0},"total_tokens":244}}

data: [DONE]
"""# + "\n\n",
        expectedMessage: #"""
{"role":"assistant","content":[{"type":"thinking","thinking":"Simple arithmetic: 17 * 23 = 391. The user wants only the number.","thinkingSignature":"reasoning_content"},{"type":"text","text":"391"}],"api":"openai-completions","provider":"openai","model":"zcode/GLM-5.3-Flash","usage":{"input":220,"output":24,"cacheRead":0,"cacheWrite":0,"reasoning":0,"totalTokens":244,"cost":{"input":0,"output":0,"cacheRead":0,"cacheWrite":0,"total":0,"totalFromProvider":false}},"stopReason":"stop","responseId":"chatcmpl-msg_20261021140119ab0abbb5373248c7","responseModel":"GLM-5.3-Flash","rawStopReason":"stop"}
"""#,
        expectedEvents: ["start", "thinking_start", "thinking_delta", "thinking_delta", "thinking_delta", "thinking_delta", "thinking_delta", "thinking_delta", "thinking_delta", "thinking_delta", "thinking_delta", "thinking_delta", "thinking_delta", "thinking_delta", "thinking_delta", "thinking_delta", "thinking_delta", "thinking_delta", "thinking_delta", "thinking_delta", "thinking_delta", "thinking_delta", "text_start", "text_delta", "text_delta", "thinking_end", "text_end", "done"]
    ),
    "tools-1": CompletionsFixture(
        name: "tools-1",
        requestMeta: #"""
{"path": "/v1/chat/completions", "headers": {"host": "127.0.0.1:3426", "connection": "keep-alive", "accept": "application/json", "x-stainless-retry-count": "0", "x-stainless-lang": "js", "x-stainless-package-version": "7.19.0", "x-stainless-os": "MacOS", "x-stainless-arch": "arm64", "x-stainless-runtime": "node", "x-stainless-runtime-version": "v25.9.0", "authorization": "Bearer magpie", "user-agent": "pi (darwin 27.2.0; arm64)", "content-type": "application/json", "accept-language": "*", "sec-fetch-mode": "cors", "accept-encoding": "gzip, deflate", "content-length": "801"}}
"""#,
        requestBody: #"""
{"model":"zcode/GLM-5.3-Flash","messages":[{"role":"developer","content":"You are a helpful assistant with access to workspace tools."},{"role":"user","content":[{"type":"text","text":"Use the tools to list the files in the workspace, then read every file, and tell me their exact contents."}]}],"stream":true,"stream_options":{"include_usage":true},"store":false,"max_completion_tokens":32000,"tools":[{"type":"function","function":{"name":"ls","description":"List files in the workspace directory.","parameters":{"type":"object","properties":{"path":{"type":"string"}}}}},{"type":"function","function":{"name":"read","description":"Read a file in the workspace by relative path.","parameters":{"type":"object","required":["path"],"properties":{"path":{"type":"string"}}}}}],"reasoning_effort":"low"}
"""#,
        sse: #"""
data: {"choices":[{"delta":{"content":"","role":"assistant"},"finish_reason":null,"index":0}],"created":1792562489,"id":"chatcmpl-msg_202610211401243e8bbf7c7b1a416d","model":"GLM-5.3-Flash","object":"chat.completion.chunk","usage":null}

data: {"choices":[{"delta":{"tool_calls":[{"function":{"arguments":"","name":"ls"},"id":"call_fd4d5436964845e3a3378554","index":0,"type":"function"}]},"finish_reason":null,"index":0}],"created":1792562489,"id":"chatcmpl-msg_202610211401243e8bbf7c7b1a416d","model":"GLM-5.3-Flash","object":"chat.completion.chunk","usage":null}

data: {"choices":[{"delta":{"tool_calls":[{"function":{"arguments":"{\""},"index":0}]},"finish_reason":null,"index":0}],"created":1792562489,"id":"chatcmpl-msg_202610211401243e8bbf7c7b1a416d","model":"GLM-5.3-Flash","object":"chat.completion.chunk","usage":null}

data: {"choices":[{"delta":{"tool_calls":[{"function":{"arguments":"path"},"index":0}]},"finish_reason":null,"index":0}],"created":1792562489,"id":"chatcmpl-msg_202610211401243e8bbf7c7b1a416d","model":"GLM-5.3-Flash","object":"chat.completion.chunk","usage":null}

data: {"choices":[{"delta":{"tool_calls":[{"function":{"arguments":"\":\""},"index":0}]},"finish_reason":null,"index":0}],"created":1792562489,"id":"chatcmpl-msg_202610211401243e8bbf7c7b1a416d","model":"GLM-5.3-Flash","object":"chat.completion.chunk","usage":null}

data: {"choices":[{"delta":{"tool_calls":[{"function":{"arguments":".\""},"index":0}]},"finish_reason":null,"index":0}],"created":1792562489,"id":"chatcmpl-msg_202610211401243e8bbf7c7b1a416d","model":"GLM-5.3-Flash","object":"chat.completion.chunk","usage":null}

data: {"choices":[{"delta":{"tool_calls":[{"function":{"arguments":"}"},"index":0}]},"finish_reason":null,"index":0}],"created":1792562489,"id":"chatcmpl-msg_202610211401243e8bbf7c7b1a416d","model":"GLM-5.3-Flash","object":"chat.completion.chunk","usage":null}

data: {"choices":[{"delta":{},"finish_reason":"tool_calls","index":0}],"created":1792562489,"id":"chatcmpl-msg_202610211401243e8bbf7c7b1a416d","model":"GLM-5.3-Flash","object":"chat.completion.chunk","usage":null}

data: {"choices":[],"created":1792562489,"id":"chatcmpl-msg_202610211401243e8bbf7c7b1a416d","model":"GLM-5.3-Flash","object":"chat.completion.chunk","usage":{"completion_tokens":11,"completion_tokens_details":{"reasoning_tokens":0},"prompt_tokens":230,"prompt_tokens_details":{"cache_write_tokens":0,"cached_tokens":0},"total_tokens":241}}

data: [DONE]
"""# + "\n\n",
        expectedMessage: #"""
{"role":"assistant","content":[{"type":"toolCall","id":"call_fd4d5436964845e3a3378554","name":"ls","arguments":{"path":"."}}],"api":"openai-completions","provider":"openai","model":"zcode/GLM-5.3-Flash","usage":{"input":230,"output":11,"cacheRead":0,"cacheWrite":0,"reasoning":0,"totalTokens":241,"cost":{"input":0,"output":0,"cacheRead":0,"cacheWrite":0,"total":0,"totalFromProvider":false}},"stopReason":"toolUse","responseId":"chatcmpl-msg_202610211401243e8bbf7c7b1a416d","responseModel":"GLM-5.3-Flash","rawStopReason":"tool_calls"}
"""#,
        expectedEvents: ["start", "toolcall_start", "toolcall_delta", "toolcall_delta", "toolcall_delta", "toolcall_delta", "toolcall_delta", "toolcall_delta", "toolcall_end", "done"]
    ),
    "tools-2": CompletionsFixture(
        name: "tools-2",
        requestMeta: #"""
{"path": "/v1/chat/completions", "headers": {"host": "127.0.0.1:3426", "connection": "keep-alive", "accept": "application/json", "x-stainless-retry-count": "0", "x-stainless-lang": "js", "x-stainless-package-version": "7.19.0", "x-stainless-os": "MacOS", "x-stainless-arch": "arm64", "x-stainless-runtime": "node", "x-stainless-runtime-version": "v25.9.0", "authorization": "Bearer magpie", "user-agent": "pi (darwin 27.2.0; arm64)", "content-type": "application/json", "accept-language": "*", "sec-fetch-mode": "cors", "accept-encoding": "gzip, deflate", "content-length": "1053"}}
"""#,
        requestBody: #"""
{"model":"zcode/GLM-5.3-Flash","messages":[{"role":"developer","content":"You are a helpful assistant with access to workspace tools."},{"role":"user","content":[{"type":"text","text":"Use the tools to list the files in the workspace, then read every file, and tell me their exact contents."}]},{"role":"assistant","content":null,"tool_calls":[{"id":"call_fd4d5436964845e3a3378554","type":"function","function":{"name":"ls","arguments":"{\"path\":\".\"}"}}]},{"role":"tool","content":"a.txt\nb.txt","tool_call_id":"call_fd4d5436964845e3a3378554"}],"stream":true,"stream_options":{"include_usage":true},"store":false,"max_completion_tokens":32000,"tools":[{"type":"function","function":{"name":"ls","description":"List files in the workspace directory.","parameters":{"type":"object","properties":{"path":{"type":"string"}}}}},{"type":"function","function":{"name":"read","description":"Read a file in the workspace by relative path.","parameters":{"type":"object","required":["path"],"properties":{"path":{"type":"string"}}}}}],"reasoning_effort":"low"}
"""#,
        sse: #"""
data: {"choices":[{"delta":{"content":"","role":"assistant"},"finish_reason":null,"index":0}],"created":1792562493,"id":"chatcmpl-msg_2026102114012973d95b36e8814af4","model":"GLM-5.3-Flash","object":"chat.completion.chunk","usage":null}

data: {"choices":[{"delta":{"tool_calls":[{"function":{"arguments":"","name":"read"},"id":"call_5166d8b8caec4c39b392116e","index":0,"type":"function"}]},"finish_reason":null,"index":0}],"created":1792562493,"id":"chatcmpl-msg_2026102114012973d95b36e8814af4","model":"GLM-5.3-Flash","object":"chat.completion.chunk","usage":null}

data: {"choices":[{"delta":{"tool_calls":[{"function":{"arguments":"{\""},"index":0}]},"finish_reason":null,"index":0}],"created":1792562493,"id":"chatcmpl-msg_2026102114012973d95b36e8814af4","model":"GLM-5.3-Flash","object":"chat.completion.chunk","usage":null}

data: {"choices":[{"delta":{"tool_calls":[{"function":{"arguments":"path"},"index":0}]},"finish_reason":null,"index":0}],"created":1792562493,"id":"chatcmpl-msg_2026102114012973d95b36e8814af4","model":"GLM-5.3-Flash","object":"chat.completion.chunk","usage":null}

data: {"choices":[{"delta":{"tool_calls":[{"function":{"arguments":"\":\""},"index":0}]},"finish_reason":null,"index":0}],"created":1792562493,"id":"chatcmpl-msg_2026102114012973d95b36e8814af4","model":"GLM-5.3-Flash","object":"chat.completion.chunk","usage":null}

data: {"choices":[{"delta":{"tool_calls":[{"function":{"arguments":"a"},"index":0}]},"finish_reason":null,"index":0}],"created":1792562493,"id":"chatcmpl-msg_2026102114012973d95b36e8814af4","model":"GLM-5.3-Flash","object":"chat.completion.chunk","usage":null}

data: {"choices":[{"delta":{"tool_calls":[{"function":{"arguments":".txt"},"index":0}]},"finish_reason":null,"index":0}],"created":1792562493,"id":"chatcmpl-msg_2026102114012973d95b36e8814af4","model":"GLM-5.3-Flash","object":"chat.completion.chunk","usage":null}

data: {"choices":[{"delta":{"tool_calls":[{"function":{"arguments":"\""},"index":0}]},"finish_reason":null,"index":0}],"created":1792562493,"id":"chatcmpl-msg_2026102114012973d95b36e8814af4","model":"GLM-5.3-Flash","object":"chat.completion.chunk","usage":null}

data: {"choices":[{"delta":{"tool_calls":[{"function":{"arguments":"}"},"index":0}]},"finish_reason":null,"index":0}],"created":1792562493,"id":"chatcmpl-msg_2026102114012973d95b36e8814af4","model":"GLM-5.3-Flash","object":"chat.completion.chunk","usage":null}

data: {"choices":[{"delta":{"tool_calls":[{"function":{"arguments":"","name":"read"},"id":"call_2270a14e9de740268fe78ab3","index":1,"type":"function"}]},"finish_reason":null,"index":0}],"created":1792562493,"id":"chatcmpl-msg_2026102114012973d95b36e8814af4","model":"GLM-5.3-Flash","object":"chat.completion.chunk","usage":null}

data: {"choices":[{"delta":{"tool_calls":[{"function":{"arguments":"{\""},"index":1}]},"finish_reason":null,"index":0}],"created":1792562493,"id":"chatcmpl-msg_2026102114012973d95b36e8814af4","model":"GLM-5.3-Flash","object":"chat.completion.chunk","usage":null}

data: {"choices":[{"delta":{"tool_calls":[{"function":{"arguments":"path"},"index":1}]},"finish_reason":null,"index":0}],"created":1792562493,"id":"chatcmpl-msg_2026102114012973d95b36e8814af4","model":"GLM-5.3-Flash","object":"chat.completion.chunk","usage":null}

data: {"choices":[{"delta":{"tool_calls":[{"function":{"arguments":"\":\""},"index":1}]},"finish_reason":null,"index":0}],"created":1792562493,"id":"chatcmpl-msg_2026102114012973d95b36e8814af4","model":"GLM-5.3-Flash","object":"chat.completion.chunk","usage":null}

data: {"choices":[{"delta":{"tool_calls":[{"function":{"arguments":"b"},"index":1}]},"finish_reason":null,"index":0}],"created":1792562493,"id":"chatcmpl-msg_2026102114012973d95b36e8814af4","model":"GLM-5.3-Flash","object":"chat.completion.chunk","usage":null}

data: {"choices":[{"delta":{"tool_calls":[{"function":{"arguments":".txt"},"index":1}]},"finish_reason":null,"index":0}],"created":1792562493,"id":"chatcmpl-msg_2026102114012973d95b36e8814af4","model":"GLM-5.3-Flash","object":"chat.completion.chunk","usage":null}

data: {"choices":[{"delta":{"tool_calls":[{"function":{"arguments":"\""},"index":1}]},"finish_reason":null,"index":0}],"created":1792562493,"id":"chatcmpl-msg_2026102114012973d95b36e8814af4","model":"GLM-5.3-Flash","object":"chat.completion.chunk","usage":null}

data: {"choices":[{"delta":{"tool_calls":[{"function":{"arguments":"}"},"index":1}]},"finish_reason":null,"index":0}],"created":1792562493,"id":"chatcmpl-msg_2026102114012973d95b36e8814af4","model":"GLM-5.3-Flash","object":"chat.completion.chunk","usage":null}

data: {"choices":[{"delta":{},"finish_reason":"tool_calls","index":0}],"created":1792562493,"id":"chatcmpl-msg_2026102114012973d95b36e8814af4","model":"GLM-5.3-Flash","object":"chat.completion.chunk","usage":null}

data: {"choices":[],"created":1792562493,"id":"chatcmpl-msg_2026102114012973d95b36e8814af4","model":"GLM-5.3-Flash","object":"chat.completion.chunk","usage":{"completion_tokens":22,"completion_tokens_details":{"reasoning_tokens":0},"prompt_tokens":250,"prompt_tokens_details":{"cache_write_tokens":0,"cached_tokens":0},"total_tokens":272}}

data: [DONE]
"""# + "\n\n",
        expectedMessage: #"""
{"role":"assistant","content":[{"type":"toolCall","id":"call_5166d8b8caec4c39b392116e","name":"read","arguments":{"path":"a.txt"}},{"type":"toolCall","id":"call_2270a14e9de740268fe78ab3","name":"read","arguments":{"path":"b.txt"}}],"api":"openai-completions","provider":"openai","model":"zcode/GLM-5.3-Flash","usage":{"input":250,"output":22,"cacheRead":0,"cacheWrite":0,"reasoning":0,"totalTokens":272,"cost":{"input":0,"output":0,"cacheRead":0,"cacheWrite":0,"total":0,"totalFromProvider":false}},"stopReason":"toolUse","responseId":"chatcmpl-msg_2026102114012973d95b36e8814af4","responseModel":"GLM-5.3-Flash","rawStopReason":"tool_calls"}
"""#,
        expectedEvents: ["start", "toolcall_start", "toolcall_delta", "toolcall_delta", "toolcall_delta", "toolcall_delta", "toolcall_delta", "toolcall_delta", "toolcall_delta", "toolcall_delta", "toolcall_start", "toolcall_delta", "toolcall_delta", "toolcall_delta", "toolcall_delta", "toolcall_delta", "toolcall_delta", "toolcall_delta", "toolcall_delta", "toolcall_end", "toolcall_end", "done"]
    ),
    "tools-3": CompletionsFixture(
        name: "tools-3",
        requestMeta: #"""
{"path": "/v1/chat/completions", "headers": {"host": "127.0.0.1:3426", "connection": "keep-alive", "accept": "application/json", "x-stainless-retry-count": "0", "x-stainless-lang": "js", "x-stainless-package-version": "7.19.0", "x-stainless-os": "MacOS", "x-stainless-arch": "arm64", "x-stainless-runtime": "node", "x-stainless-runtime-version": "v25.9.0", "authorization": "Bearer magpie", "user-agent": "pi (darwin 27.2.0; arm64)", "content-type": "application/json", "accept-language": "*", "sec-fetch-mode": "cors", "accept-encoding": "gzip, deflate", "content-length": "1507"}}
"""#,
        requestBody: #"""
{"model":"zcode/GLM-5.3-Flash","messages":[{"role":"developer","content":"You are a helpful assistant with access to workspace tools."},{"role":"user","content":[{"type":"text","text":"Use the tools to list the files in the workspace, then read every file, and tell me their exact contents."}]},{"role":"assistant","content":null,"tool_calls":[{"id":"call_fd4d5436964845e3a3378554","type":"function","function":{"name":"ls","arguments":"{\"path\":\".\"}"}}]},{"role":"tool","content":"a.txt\nb.txt","tool_call_id":"call_fd4d5436964845e3a3378554"},{"role":"assistant","content":null,"tool_calls":[{"id":"call_5166d8b8caec4c39b392116e","type":"function","function":{"name":"read","arguments":"{\"path\":\"a.txt\"}"}},{"id":"call_2270a14e9de740268fe78ab3","type":"function","function":{"name":"read","arguments":"{\"path\":\"b.txt\"}"}}]},{"role":"tool","content":"alpha\n","tool_call_id":"call_5166d8b8caec4c39b392116e"},{"role":"tool","content":"beta\n","tool_call_id":"call_2270a14e9de740268fe78ab3"}],"stream":true,"stream_options":{"include_usage":true},"store":false,"max_completion_tokens":32000,"tools":[{"type":"function","function":{"name":"ls","description":"List files in the workspace directory.","parameters":{"type":"object","properties":{"path":{"type":"string"}}}}},{"type":"function","function":{"name":"read","description":"Read a file in the workspace by relative path.","parameters":{"type":"object","required":["path"],"properties":{"path":{"type":"string"}}}}}],"reasoning_effort":"low"}
"""#,
        sse: #"""
data: {"choices":[{"delta":{"content":"","role":"assistant"},"finish_reason":null,"index":0}],"created":1792562498,"id":"chatcmpl-msg_2026102114013375565e752a5d4631","model":"GLM-5.3-Flash","object":"chat.completion.chunk","usage":null}

data: {"choices":[{"delta":{"content":"The"},"finish_reason":null,"index":0}],"created":1792562498,"id":"chatcmpl-msg_2026102114013375565e752a5d4631","model":"GLM-5.3-Flash","object":"chat.completion.chunk","usage":null}

data: {"choices":[{"delta":{"content":" workspace"},"finish_reason":null,"index":0}],"created":1792562498,"id":"chatcmpl-msg_2026102114013375565e752a5d4631","model":"GLM-5.3-Flash","object":"chat.completion.chunk","usage":null}

data: {"choices":[{"delta":{"content":" contains"},"finish_reason":null,"index":0}],"created":1792562498,"id":"chatcmpl-msg_2026102114013375565e752a5d4631","model":"GLM-5.3-Flash","object":"chat.completion.chunk","usage":null}

data: {"choices":[{"delta":{"content":" two"},"finish_reason":null,"index":0}],"created":1792562498,"id":"chatcmpl-msg_2026102114013375565e752a5d4631","model":"GLM-5.3-Flash","object":"chat.completion.chunk","usage":null}

data: {"choices":[{"delta":{"content":" files"},"finish_reason":null,"index":0}],"created":1792562498,"id":"chatcmpl-msg_2026102114013375565e752a5d4631","model":"GLM-5.3-Flash","object":"chat.completion.chunk","usage":null}

data: {"choices":[{"delta":{"content":":\n\n"},"finish_reason":null,"index":0}],"created":1792562498,"id":"chatcmpl-msg_2026102114013375565e752a5d4631","model":"GLM-5.3-Flash","object":"chat.completion.chunk","usage":null}

data: {"choices":[{"delta":{"content":"-"},"finish_reason":null,"index":0}],"created":1792562498,"id":"chatcmpl-msg_2026102114013375565e752a5d4631","model":"GLM-5.3-Flash","object":"chat.completion.chunk","usage":null}

data: {"choices":[{"delta":{"content":" **"},"finish_reason":null,"index":0}],"created":1792562498,"id":"chatcmpl-msg_2026102114013375565e752a5d4631","model":"GLM-5.3-Flash","object":"chat.completion.chunk","usage":null}

data: {"choices":[{"delta":{"content":"a"},"finish_reason":null,"index":0}],"created":1792562498,"id":"chatcmpl-msg_2026102114013375565e752a5d4631","model":"GLM-5.3-Flash","object":"chat.completion.chunk","usage":null}

data: {"choices":[{"delta":{"content":".txt"},"finish_reason":null,"index":0}],"created":1792562498,"id":"chatcmpl-msg_2026102114013375565e752a5d4631","model":"GLM-5.3-Flash","object":"chat.completion.chunk","usage":null}

data: {"choices":[{"delta":{"content":"**:"},"finish_reason":null,"index":0}],"created":1792562498,"id":"chatcmpl-msg_2026102114013375565e752a5d4631","model":"GLM-5.3-Flash","object":"chat.completion.chunk","usage":null}

data: {"choices":[{"delta":{"content":" `"},"finish_reason":null,"index":0}],"created":1792562498,"id":"chatcmpl-msg_2026102114013375565e752a5d4631","model":"GLM-5.3-Flash","object":"chat.completion.chunk","usage":null}

data: {"choices":[{"delta":{"content":"alpha"},"finish_reason":null,"index":0}],"created":1792562498,"id":"chatcmpl-msg_2026102114013375565e752a5d4631","model":"GLM-5.3-Flash","object":"chat.completion.chunk","usage":null}

data: {"choices":[{"delta":{"content":"`\n"},"finish_reason":null,"index":0}],"created":1792562498,"id":"chatcmpl-msg_2026102114013375565e752a5d4631","model":"GLM-5.3-Flash","object":"chat.completion.chunk","usage":null}

data: {"choices":[{"delta":{"content":"-"},"finish_reason":null,"index":0}],"created":1792562498,"id":"chatcmpl-msg_2026102114013375565e752a5d4631","model":"GLM-5.3-Flash","object":"chat.completion.chunk","usage":null}

data: {"choices":[{"delta":{"content":" **"},"finish_reason":null,"index":0}],"created":1792562498,"id":"chatcmpl-msg_2026102114013375565e752a5d4631","model":"GLM-5.3-Flash","object":"chat.completion.chunk","usage":null}

data: {"choices":[{"delta":{"content":"b"},"finish_reason":null,"index":0}],"created":1792562498,"id":"chatcmpl-msg_2026102114013375565e752a5d4631","model":"GLM-5.3-Flash","object":"chat.completion.chunk","usage":null}

data: {"choices":[{"delta":{"content":".txt"},"finish_reason":null,"index":0}],"created":1792562498,"id":"chatcmpl-msg_2026102114013375565e752a5d4631","model":"GLM-5.3-Flash","object":"chat.completion.chunk","usage":null}

data: {"choices":[{"delta":{"content":"**:"},"finish_reason":null,"index":0}],"created":1792562498,"id":"chatcmpl-msg_2026102114013375565e752a5d4631","model":"GLM-5.3-Flash","object":"chat.completion.chunk","usage":null}

data: {"choices":[{"delta":{"content":" `"},"finish_reason":null,"index":0}],"created":1792562498,"id":"chatcmpl-msg_2026102114013375565e752a5d4631","model":"GLM-5.3-Flash","object":"chat.completion.chunk","usage":null}

data: {"choices":[{"delta":{"content":"beta"},"finish_reason":null,"index":0}],"created":1792562498,"id":"chatcmpl-msg_2026102114013375565e752a5d4631","model":"GLM-5.3-Flash","object":"chat.completion.chunk","usage":null}

data: {"choices":[{"delta":{"content":"`"},"finish_reason":null,"index":0}],"created":1792562498,"id":"chatcmpl-msg_2026102114013375565e752a5d4631","model":"GLM-5.3-Flash","object":"chat.completion.chunk","usage":null}

data: {"choices":[{"delta":{},"finish_reason":"stop","index":0}],"created":1792562498,"id":"chatcmpl-msg_2026102114013375565e752a5d4631","model":"GLM-5.3-Flash","object":"chat.completion.chunk","usage":null}

data: {"choices":[],"created":1792562498,"id":"chatcmpl-msg_2026102114013375565e752a5d4631","model":"GLM-5.3-Flash","object":"chat.completion.chunk","usage":{"completion_tokens":24,"completion_tokens_details":{"reasoning_tokens":0},"prompt_tokens":282,"prompt_tokens_details":{"cache_write_tokens":0,"cached_tokens":0},"total_tokens":306}}

data: [DONE]
"""# + "\n\n",
        expectedMessage: #"""
{"role":"assistant","content":[{"type":"text","text":"The workspace contains two files:\n\n- **a.txt**: `alpha`\n- **b.txt**: `beta`"}],"api":"openai-completions","provider":"openai","model":"zcode/GLM-5.3-Flash","usage":{"input":282,"output":24,"cacheRead":0,"cacheWrite":0,"reasoning":0,"totalTokens":306,"cost":{"input":0,"output":0,"cacheRead":0,"cacheWrite":0,"total":0,"totalFromProvider":false}},"stopReason":"stop","responseId":"chatcmpl-msg_2026102114013375565e752a5d4631","responseModel":"GLM-5.3-Flash","rawStopReason":"stop"}
"""#,
        expectedEvents: ["start", "text_start", "text_delta", "text_delta", "text_delta", "text_delta", "text_delta", "text_delta", "text_delta", "text_delta", "text_delta", "text_delta", "text_delta", "text_delta", "text_delta", "text_delta", "text_delta", "text_delta", "text_delta", "text_delta", "text_delta", "text_delta", "text_delta", "text_delta", "text_end", "done"]
    ),
]
