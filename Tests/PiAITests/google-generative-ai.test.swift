import Foundation
import Testing
@testable import PiAI

// Google Generative AI parts of packages/ai/test/google-thinking-level-map.test.ts,
// google-raw-stop-reason.test.ts, fetch-option.test.ts and pre-generation-error.test.ts.
//
// Swift: Vertex cases are not ported (no google-vertex adapter in this group). Upstream mocks `@google/genai`;
// here the real SDK port runs against a fake `globalThis.fetch` (`GlobalFetch.current`) serving SSE chunks.
// Not ported: "allows Google adapters to receive globalThis.fetch explicitly" — Swift closures have no identity,
// so every explicit `options.fetch` is rejected.

private let helloContext = normalizeContext(Context(messages: [.user(UserMessage(content: "Hello", timestamp: 0))]))

private func googleModel(_ id: String, _ thinkingLevelMap: ThinkingLevelMap) -> Model {
    var model = Model(id: id, name: id, api: "google-generative-ai", provider: "test-google", baseUrl: "https://example.invalid/v1beta",
                      reasoning: true, input: ["text"], contextWindow: 128000, maxTokens: 4096)
    model.thinkingLevelMap = thinkingLevelMap
    return model
}

private final class PayloadBox: Sendable {
    let value = Locked<JsonValue?>(nil)
}

private func captureGooglePayload(_ model: Model, _ reasoning: ThinkingLevel? = nil, _ thinkingBudgets: ThinkingBudgets? = nil) async throws -> JsonValue {
    let box = PayloadBox()
    var options = SimpleStreamOptions()
    options.apiKey = "test"
    options.reasoning = reasoning
    options.thinkingBudgets = thinkingBudgets
    options.onPayload = { request, _ in
        box.value.withLock { $0 = request }
        throw PiError("payload captured")
    }
    let result = await (try streamSimpleGoogleGenerativeAI(model, helloContext, options)).result()
    #expect(result.errorMessage?.contains("payload captured") == true)
    return try #require(box.value.withLock { $0 }, "Google payload was not captured")
}

private func level(_ value: String) -> ThinkingLevel { ThinkingLevel(rawValue: value)! }

@Suite("Google thinking level maps")
struct GoogleThinkingLevelMapTests {
    @Test("exhaustively resolves supported logical levels and mapping values")
    func exhaustive() throws {
        for (lvl, expected) in [("minimal", "minimal"), ("low", "low"), ("medium", "medium"), ("high", "high")] {
            #expect(try resolveGoogleThinkingLevel(googleModel("gemini-3.7-flash", [:]), level(lvl)).rawValue == expected)
        }
        let mappedExpectations = [
            ("minimal", "minimal"), ("low", "low"), ("medium", "medium"), ("high", "high"),
            ("MINIMAL", "minimal"), ("LOW", "low"), ("MEDIUM", "medium"), ("HIGH", "high"),
        ]
        for (mapped, expected) in mappedExpectations {
            let model = googleModel("gemini-3.7-flash", [.high: mapped, .xhigh: mapped, .max: mapped])
            #expect(try resolveGoogleThinkingLevel(model, .high).rawValue == expected)
            #expect(try resolveGoogleThinkingLevel(model, level("xhigh")).rawValue == expected)
            #expect(try resolveGoogleThinkingLevel(model, level("max")).rawValue == expected)
        }

        let invalidModel = googleModel("gemini-3.7-flash", [.xhigh: "extreme"])
        let error1 = #expect(throws: (any Error).self) { try resolveGoogleThinkingLevel(invalidModel, level("xhigh")) }
        #expect(errorMessage(error1!).contains("Unsupported Google thinking level mapping for test-google/gemini-3.7-flash: xhigh -> extreme"))
        let error2 = #expect(throws: (any Error).self) { try resolveGoogleThinkingLevel(googleModel("gemini-3.7-flash", [:]), level("max")) }
        #expect(errorMessage(error2!).contains("Unsupported Google thinking level mapping for test-google/gemini-3.7-flash: max -> undefined"))
    }

    // Regression test for https://github.com/earendil-works/pi/issues/9455
    @Test("uses the lowest supported Google Generative AI level when reasoning is omitted")
    func lowestLevelWhenOmitted() async throws {
        let payload = try await captureGooglePayload(googleModel("gemini-3.8-flash", [
            .off: nil, .minimal: nil, .low: "low", .medium: "medium", .high: "high", .xhigh: nil, .max: nil,
        ]))
        #expect(payload["config"]?["thinkingConfig"] == ["thinkingLevel": "LOW"])
    }

    @Test("preserves native medium effort for Gemini 3.1 Pro on Google Generative AI")
    func nativeMedium() async throws {
        let payload = try await captureGooglePayload(
            googleModel("gemini-3.1-pro-preview", [.off: nil, .minimal: nil, .low: "low", .medium: "medium", .high: "high", .xhigh: nil, .max: nil]),
            .medium
        )
        #expect(payload["config"]?["thinkingConfig"] == ["includeThoughts": true, "thinkingLevel": "MEDIUM"])
    }

    @Test("disables Gemini 2.5 thinking when reasoning is omitted on Google Generative AI")
    func disables25() async throws {
        let payload = try await captureGooglePayload(googleModel("gemini-2.5-flash", [:]))
        #expect(payload["config"]?["thinkingConfig"] == ["thinkingBudget": 0])
    }

    // Regression test for https://github.com/earendil-works/pi/issues/10890
    @Test("uses thinking levels for Gemini 4 models on Google Generative AI")
    func gemini4() async throws {
        let payload = try await captureGooglePayload(googleModel("gemini-4-argon", [:]), .medium)
        #expect(payload["config"]?["thinkingConfig"] == ["includeThoughts": true, "thinkingLevel": "MEDIUM"])
    }

    @Test("maps Google Generative AI extended levels to a supported level", arguments: ["xhigh", "max"])
    func extendedLevels(_ reasoning: String) async throws {
        let payload = try await captureGooglePayload(googleModel("gemini-3.7-flash", [.xhigh: "high", .max: "high"]), level(reasoning))
        #expect(payload["config"]?["thinkingConfig"]?["includeThoughts"] == true)
        #expect(payload["config"]?["thinkingConfig"]?["thinkingLevel"] == "HIGH")
    }

    @Test("honors uppercase provider values for standard Google Generative AI levels")
    func uppercaseValues() async throws {
        let payload = try await captureGooglePayload(googleModel("gemini-3.7-flash", [.high: "LOW"]), .high)
        #expect(payload["config"]?["thinkingConfig"]?["thinkingLevel"] == "LOW")
    }

    @Test("uses mapped Google Generative AI levels for token budgets")
    func mappedBudgets() async throws {
        let payload = try await captureGooglePayload(googleModel("gemini-2.5-flash", [.xhigh: "high"]), level("xhigh"), ThinkingBudgets(high: 1234))
        #expect(payload["config"]?["thinkingConfig"]?["thinkingBudget"] == 1234)
    }
}

// MARK: - google-raw-stop-reason

private final class FetchLog: Sendable {
    let requests = Locked<[FetchRequest]>([])
    var all: [FetchRequest] { requests.withLock { $0 } }
}

/// `globalThis.fetch` answering with SSE `data:` events for `chunks`.
private func sseFetch(_ chunks: [JsonValue], log: FetchLog = FetchLog()) -> FetchFunction {
    { request in
        log.requests.withLock { $0.append(request) }
        let body = chunks.map { "data: \($0.serialized())\r\n\r\n" }.joined()
        return FetchResponse(status: 200, headers: Headers([("content-type", "text/event-stream")]), body: .data(Data(body.utf8)))
    }
}

private func defaultChunk(finishReason: String, includeFunctionCall: Bool) -> JsonValue {
    var candidate: JsonObject = ["finishReason": .string(finishReason)]
    if includeFunctionCall {
        candidate["content"] = ["parts": [["functionCall": ["id": "call-1", "name": "echo", "args": ["value": "truncated"]]]]]
    }
    return [
        "responseId": "google-response-id",
        "candidates": [.object(candidate)],
        "usageMetadata": ["promptTokenCount": 1, "candidatesTokenCount": 0, "totalTokenCount": 1],
    ]
}

private let rawStopContext = normalizeContext(Context(messages: [.user(UserMessage(content: "hello"))]))

/// Upstream `getModel("google", "gemini-2.5-flash")`. Swift: the built-in catalog is empty in tests, so the model is spelled out.
private func gemini25Flash() throws -> Model {
    Model(id: "gemini-2.5-flash", name: "Gemini 2.5 Flash", api: "google-generative-ai", provider: "google",
          baseUrl: "https://generativelanguage.googleapis.com/v1beta", reasoning: true, input: ["text", "image"],
          contextWindow: 1_048_576, maxTokens: 65_536)
}

private func runGoogle(_ chunks: [JsonValue], log: FetchLog = FetchLog(), _ configure: (inout StreamOptions) -> Void = { _ in }) async throws -> AssistantMessage {
    var options = StreamOptions()
    options.apiKey = "test-api-key"
    configure(&options)
    let model = try gemini25Flash()
    let stream = GlobalFetch.$current.withValue(sseFetch(chunks, log: log)) {
        streamGoogleGenerativeAI(model, rawStopContext, options)
    }
    return await stream.result()
}

@Suite("Google raw stop reasons")
struct GoogleRawStopReasonTests {
    @Test("preserves raw Gemini finish reasons for Google Generative AI errors")
    func rawErrors() async throws {
        let message = try await runGoogle([defaultChunk(finishReason: "MALFORMED_FUNCTION_CALL", includeFunctionCall: false)])
        #expect(message.stopReason == .error)
        #expect(message.rawStopReason == "MALFORMED_FUNCTION_CALL")
        #expect(message.errorMessage == "Provider stopped with: MALFORMED_FUNCTION_CALL")
    }

    @Test("preserves MAX_TOKENS with a tool call as length for Google Generative AI")
    func maxTokensWithToolCall() async throws {
        let message = try await runGoogle([defaultChunk(finishReason: "MAX_TOKENS", includeFunctionCall: true)])
        #expect(message.stopReason == .length)
        #expect(message.rawStopReason == "MAX_TOKENS")
        #expect(message.content.contains { $0.type == "toolCall" })
    }

    @Test("maps STOP with a tool call to toolUse for Google Generative AI")
    func stopWithToolCall() async throws {
        let message = try await runGoogle([defaultChunk(finishReason: "STOP", includeFunctionCall: true)])
        #expect(message.stopReason == .toolUse)
        #expect(message.rawStopReason == "STOP")
        #expect(message.content.contains { $0.type == "toolCall" })
    }
}

private final class ProviderEventLog: Sendable {
    let events = Locked<[(JsonValue, String)]>([])
}

@Suite("Google provider stream events")
struct GoogleProviderStreamEventTests {
    @Test("forwards each SDK chunk in order before normalizing it for Google Generative AI")
    func forwardsChunks() async throws {
        let chunks: [JsonValue] = [
            ["responseId": "resp_google", "candidates": [["content": ["parts": [["text": "hello"]]]]]],
            [
                "candidates": [["finishReason": "STOP"]],
                "usageMetadata": ["promptTokenCount": 2, "candidatesTokenCount": 1, "totalTokenCount": 3],
            ],
        ]
        let log = ProviderEventLog()
        let model = try gemini25Flash()
        let result = try await runGoogle(chunks) { options in
            options.onProviderStreamEvent = { chunk, eventModel in
                await Task.yield()
                log.events.withLock { $0.append((chunk, eventModel.id)) }
            }
        }
        let received = log.events.withLock { $0 }
        // Swift: the real SDK adds `sdkHttpResponse` to every chunk (the upstream test mocks the SDK).
        #expect(received.map { chunk -> JsonValue in
            var chunk = chunk.0
            chunk["sdkHttpResponse"] = nil
            return chunk
        } == chunks)
        #expect(received.map(\.1) == [model.id, model.id])
        #expect(result.stopReason == .stop)
        #expect(result.responseId == "resp_google")
        #expect(result.content == [.text(TextContent(text: "hello"))])
    }
}

@Suite("Google Generative AI user agent")
struct GoogleUserAgentTests {
    private func captureHeaders(_ headers: ProviderHeaders? = nil) async throws -> Headers {
        let log = FetchLog()
        _ = try await runGoogle([defaultChunk(finishReason: "STOP", includeFunctionCall: false)], log: log) { options in
            options.headers = headers
        }
        #expect(log.all.count == 1)
        return try #require(log.all.first).headers
    }

    @Test("uses pi's User-Agent by default")
    func defaultUserAgent() async throws {
        #expect(try await captureHeaders().get("User-Agent") == getPiUserAgent())
        #expect(getPiUserAgent().hasPrefix("pi/\(PI_AI_VERSION) ("))
    }

    @Test("lets explicit headers override the default User-Agent")
    func overrideUserAgent() async throws {
        #expect(try await captureHeaders([("User-Agent", "custom-agent")]).get("User-Agent") == "custom-agent")
    }
}

// MARK: - fetch-option / pre-generation-error

@Suite("Google Generative AI fetch option and auth")
struct GoogleFetchOptionTests {
    private func createModel() -> Model {
        Model(id: "test-model", name: "Test Model", api: "google-generative-ai", provider: "test-provider", baseUrl: "https://upstream.test/v1",
              reasoning: false, input: ["text"], contextWindow: 10_000, maxTokens: 1_000)
    }

    @Test("rejects custom fetch for Google adapters instead of silently bypassing it")
    func rejectsCustomFetch() async throws {
        let calls = Locked<[String]>([])
        let fallback: FetchFunction = { _ in
            calls.withLock { $0.append("fallback") }
            throw PiError("ambient fetch must not be called")
        }
        let custom: FetchFunction = { _ in
            calls.withLock { $0.append("custom") }
            return FetchResponse(status: 401, headers: Headers([("content-type", "application/json")]),
                                 body: .data(Data(#"{"error":{"message":"upstream rejected request"}}"#.utf8)))
        }
        var options = SimpleStreamOptions()
        options.apiKey = "test-key"
        options.fetch = custom
        let context = normalizeContext(Context(messages: [.user(UserMessage(content: "hello", timestamp: 1))]))
        let model = createModel()
        let stream = try GlobalFetch.$current.withValue(fallback) {
            try streamSimpleGoogleGenerativeAI(model, context, options)
        }
        let google = await stream.result()
        #expect(google.errorMessage?.contains("Custom fetch is not supported by the Google Generative AI adapter") == true)
        #expect(calls.withLock { $0 }.isEmpty)
    }

    @Test("throws synchronously when auth is missing")
    func missingAuthThrows() {
        let model = Model(id: "test-model", name: "Test", api: "google-generative-ai", provider: "test-provider", baseUrl: "https://example.invalid",
                          reasoning: false, input: ["text"], contextWindow: 1_000, maxTokens: 100)
        let error = #expect(throws: (any Error).self) {
            _ = try streamSimpleGoogleGenerativeAI(model, normalizeContext(Context(messages: [])), SimpleStreamOptions())
        }
        #expect(errorMessage(error!).contains("No API key for provider: test-provider"))
    }

    @Test("the lazy API turns the missing-auth throw into an error event")
    func lazyApiMissingAuth() async {
        let model = Model(id: "test-model", name: "Test", api: "google-generative-ai", provider: "test-provider", baseUrl: "https://example.invalid")
        let result = await googleGenerativeAIApi().streamSimple(model, normalizeContext(Context(messages: [])), SimpleStreamOptions()).result()
        #expect(result.stopReason == .error)
        #expect(result.errorMessage == "No API key for provider: test-provider")
    }
}
