import Foundation
import Testing
@testable import PiAI

// Tests for the SDK cores in `Sources/PiAI/platform/sdk/` (no network: every client uses a fake fetch).

// MARK: - Fake fetch

private final class FakeServer: @unchecked Sendable {
    typealias Responder = @Sendable (FetchRequest, Int) async throws -> FetchResponse

    private let lock = NSLock()
    private var _requests: [FetchRequest] = []
    private let responder: Responder

    init(_ responder: @escaping Responder) {
        self.responder = responder
    }

    var requests: [FetchRequest] {
        lock.lock()
        defer { lock.unlock() }
        return _requests
    }

    var fetch: FetchFunction {
        { [self] request in
            let index: Int = {
                lock.lock()
                defer { lock.unlock() }
                _requests.append(request)
                return _requests.count - 1
            }()
            return try await responder(request, index)
        }
    }
}

private func jsonResponse(_ status: Int, _ body: String, headers: [(String, String)] = []) -> FetchResponse {
    FetchResponse(
        status: status,
        headers: Headers([("content-type", "application/json")] + headers),
        body: .data(Data(body.utf8))
    )
}

private func textResponse(_ status: Int, _ body: String, statusText: String? = nil, headers: [(String, String)] = []) -> FetchResponse {
    FetchResponse(status: status, statusText: statusText, headers: Headers(headers), body: .data(Data(body.utf8)))
}

/// A response whose body is delivered as the given byte chunks.
private func chunkedResponse(_ status: Int, _ chunks: [String], headers: [(String, String)] = [("content-type", "text/event-stream")]) -> FetchResponse {
    let stream = AsyncThrowingStream<Data, any Error> { continuation in
        for chunk in chunks { continuation.yield(Data(chunk.utf8)) }
        continuation.finish()
    }
    return FetchResponse(status: status, headers: Headers(headers), body: ResponseBody(stream))
}

/// Waits until the request's signal aborts, then throws its reason (like `fetch` does).
private func hangUntilAborted(_ request: FetchRequest) async throws -> FetchResponse {
    while !(request.signal?.aborted ?? false) {
        try await Task.sleep(nanoseconds: 5_000_000)
    }
    throw request.signal?.reason ?? AbortError()
}

private func bodyJSON(_ request: FetchRequest) throws -> JsonValue {
    try JsonValue.parse(String(decoding: request.body ?? Data(), as: UTF8.self))
}

private func bodyText(_ request: FetchRequest) -> String {
    String(decoding: request.body ?? Data(), as: UTF8.self)
}

// MARK: - OpenAI

@Suite struct SDKCoreTests {
    @Test func openAIRequestHeadersAndURL() async throws {
        let server = FakeServer { _, _ in jsonResponse(200, #"{"id":"x"}"#) }
        let client = try OpenAI(.init(apiKey: "sk-test", baseURL: "https://example.test/v1/", fetch: server.fetch, env: [:]))
        let body: JsonValue = ["model": "gpt-x", "messages": []]
        let result = try await client.chat.completions.create(body).withResponse()
        #expect(result.data.json == ["id": "x"])

        let request = try #require(server.requests.first)
        #expect(request.url.absoluteString == "https://example.test/v1/chat/completions")
        #expect(request.method == "POST")
        #expect(request.headers.get("authorization") == "Bearer sk-test")
        #expect(request.headers.get("content-type") == "application/json")
        #expect(request.headers.get("user-agent") == "OpenAI/JS 7.19.0")
        #expect(request.headers.get("x-stainless-retry-count") == "0")
        #expect(bodyText(request) == body.serialized())
    }

    @Test func openAIMissingAPIKey() throws {
        #expect(throws: (any Error).self) { try OpenAI(.init(env: [:])) }
        do {
            _ = try OpenAI(.init(env: [:]))
        } catch {
            #expect(errorMessage(error) == "Missing credentials. Please pass an `apiKey`, `workloadIdentity`, `adminAPIKey`, or set the `OPENAI_API_KEY` or `OPENAI_ADMIN_KEY` environment variable.")
        }
    }

    @Test func openAIStatusErrorSubclassAndMessage() async throws {
        let server = FakeServer { _, _ in jsonResponse(400, #"{"error":{"message":"bad input","type":"invalid_request_error"}}"#, headers: [("x-request-id", "req_1")]) }
        let client = try OpenAI(.init(apiKey: "k", fetch: server.fetch, maxRetries: 0, env: [:]))
        do {
            _ = try await client.chat.completions.create(["model": "m"]).value()
            Issue.record("expected an error")
        } catch let error as OpenAI.BadRequestError {
            #expect(error.status == 400)
            #expect(error.message == "400 bad input")
            #expect(error.type == "invalid_request_error")
            #expect(error.requestID == "req_1")
        }
    }

    @Test func openAIRetriesRetryableStatus() async throws {
        let server = FakeServer { _, index in
            index == 0
                ? jsonResponse(500, #"{"error":{"message":"boom"}}"#, headers: [("retry-after-ms", "1")])
                : jsonResponse(200, #"{"ok":true}"#)
        }
        let client = try OpenAI(.init(apiKey: "k", fetch: server.fetch, maxRetries: 2, env: [:]))
        let result = try await client.chat.completions.create(["model": "m"]).value()
        #expect(result.json == ["ok": true])
        #expect(server.requests.count == 2)
        #expect(server.requests[1].headers.get("x-stainless-retry-count") == "1")
    }

    @Test func openAIShouldRetryHeaderFalseStopsRetries() async throws {
        let server = FakeServer { _, _ in jsonResponse(503, #"{"error":{"message":"nope"}}"#, headers: [("x-should-retry", "false")]) }
        let client = try OpenAI(.init(apiKey: "k", fetch: server.fetch, maxRetries: 3, env: [:]))
        await #expect(throws: OpenAI.InternalServerError.self) {
            _ = try await client.chat.completions.create(["model": "m"]).value()
        }
        #expect(server.requests.count == 1)
    }

    @Test func openAIConnectionError() async throws {
        let server = FakeServer { _, _ in throw FetchError("fetch failed", cause: "ECONNREFUSED") }
        let client = try OpenAI(.init(apiKey: "k", fetch: server.fetch, maxRetries: 0, env: [:]))
        do {
            _ = try await client.chat.completions.create(["model": "m"]).value()
            Issue.record("expected an error")
        } catch let error as OpenAI.APIConnectionError {
            #expect(!(error is OpenAI.APIConnectionTimeoutError))
            #expect(error.message == "Connection error.")
        }
    }

    @Test func openAITimeout() async throws {
        let server = FakeServer { request, _ in try await hangUntilAborted(request) }
        let client = try OpenAI(.init(apiKey: "k", timeout: 50, fetch: server.fetch, maxRetries: 0, env: [:]))
        do {
            _ = try await client.chat.completions.create(["model": "m"]).value()
            Issue.record("expected an error")
        } catch let error as OpenAI.APIConnectionTimeoutError {
            #expect(error.message == "Request timed out.")
        }
    }

    @Test func openAIUserAbort() async throws {
        let server = FakeServer { request, _ in try await hangUntilAborted(request) }
        let client = try OpenAI(.init(apiKey: "k", fetch: server.fetch, maxRetries: 2, env: [:]))
        let controller = AbortController()
        let promise = client.chat.completions.create(["model": "m"], RequestOptions(signal: controller.signal))
        _ = Task {
            try await Task.sleep(nanoseconds: 30_000_000)
            controller.abort()
        }
        do {
            _ = try await promise.value()
            Issue.record("expected an error")
        } catch let error as OpenAI.APIUserAbortError {
            #expect(error.message == "Request was aborted.")
        }
        #expect(server.requests.count == 1)
    }

    // MARK: SSE

    @Test func openAISSEParsing() async throws {
        let chunks = [
            ": keep-alive comment\r\n\r",
            "\ndata: {\"a\":",
            "1}\r\n\r\nevent: message\ndata: {\"b\":\ndata: 2}\n\n",
            "data: [DONE]\n\ndata: {\"after\":true}\n\n",
        ]
        let server = FakeServer { _, _ in chunkedResponse(200, chunks) }
        let client = try OpenAI(.init(apiKey: "k", fetch: server.fetch, env: [:]))
        let result = try await client.chat.completions.create(["model": "m", "stream": true]).value()
        let stream = try #require(result.stream)
        var events: [JsonValue] = []
        for try await event in stream { events.append(event) }
        #expect(events == [["a": 1], ["b": 2]])
    }

    @Test func openAISSEFlushesEventWithoutTrailingBlankLine() async throws {
        let server = FakeServer { _, _ in chunkedResponse(200, ["data: {\"a\":1}\n\ndata: {\"b\":2}"]) }
        let client = try OpenAI(.init(apiKey: "k", fetch: server.fetch, env: [:]))
        let stream = try #require(try await client.chat.completions.create(["model": "m", "stream": true]).value().stream)
        var events: [JsonValue] = []
        for try await event in stream { events.append(event) }
        #expect(events == [["a": 1], ["b": 2]])
    }

    @Test func openAISSEErrorEventThrowsAPIError() async throws {
        let server = FakeServer { _, _ in chunkedResponse(200, ["data: {\"error\":{\"message\":\"overloaded\"}}\n\n"]) }
        let client = try OpenAI(.init(apiKey: "k", fetch: server.fetch, env: [:]))
        let stream = try #require(try await client.chat.completions.create(["model": "m", "stream": true]).value().stream)
        do {
            for try await _ in stream {}
            Issue.record("expected an error")
        } catch let error as OpenAI.APIError {
            #expect(error.status == nil)
            #expect(error.message == "overloaded")
        }
    }

    @Test func openAIBreakingOutOfStreamAbortsController() async throws {
        let server = FakeServer { _, _ in chunkedResponse(200, ["data: {\"a\":1}\n\ndata: {\"a\":2}\n\n"]) }
        let client = try OpenAI(.init(apiKey: "k", fetch: server.fetch, env: [:]))
        let stream = try #require(try await client.chat.completions.create(["model": "m", "stream": true]).value().stream)
        for try await _ in stream { break }
        for _ in 0..<100 where !stream.controller.signal.aborted { try await Task.sleep(nanoseconds: 10_000_000) }
        #expect(stream.controller.signal.aborted)
    }

    // MARK: - Azure

    @Test func azureDeploymentURLAndApiKeyHeader() async throws {
        let server = FakeServer { _, _ in jsonResponse(200, "{}") }
        let client = try AzureOpenAI(.init(apiVersion: "2025-01-01", endpoint: "https://res.openai.azure.com/", apiKey: "az-key", fetch: server.fetch, env: [:]))
        _ = try await client.chat.completions.create(["model": "gpt deploy", "messages": []]).value()
        let request = try #require(server.requests.first)
        #expect(request.url.absoluteString == "https://res.openai.azure.com/openai/deployments/gpt%20deploy/chat/completions?api-version=2025-01-01")
        #expect(request.headers.get("api-key") == "az-key")
        #expect(request.headers.get("authorization") == nil)
        #expect(request.headers.get("user-agent") == "AzureOpenAI/JS 7.19.0")
    }

    @Test func azureMissingApiVersion() {
        do {
            _ = try AzureOpenAI(.init(endpoint: "https://res", apiKey: "k", env: [:]))
            Issue.record("expected an error")
        } catch {
            #expect(errorMessage(error).hasPrefix("The OPENAI_API_VERSION environment variable is missing or empty"))
        }
    }

    // MARK: - Anthropic

    @Test func anthropicBetaMessagesRequest() async throws {
        let server = FakeServer { _, _ in jsonResponse(200, "{}") }
        let client = try Anthropic(.init(apiKey: "sk-ant", fetch: server.fetch, env: [:]))
        let params: JsonValue = [
            "model": "claude-x",
            "max_tokens": 100,
            "messages": [],
            "betas": ["b1", "b2"],
            "stream": true,
        ]
        _ = try await client.beta.messages.create(params).asResponse()
        let request = try #require(server.requests.first)
        #expect(request.url.absoluteString == "https://api.anthropic.com/v1/messages?beta=true")
        #expect(request.headers.get("x-api-key") == "sk-ant")
        #expect(request.headers.get("anthropic-version") == "2023-06-01")
        #expect(request.headers.get("anthropic-beta") == "b1,b2")
        #expect(request.headers.get("user-agent") == "Anthropic/JS 0.129.0")
        #expect(request.headers.get("authorization") == nil)
        #expect(try bodyJSON(request) == ["model": "claude-x", "max_tokens": 100, "messages": [], "stream": true])
        #expect(!bodyText(request).contains("betas"))
    }

    @Test func anthropicMissingAuthValidation() async throws {
        let server = FakeServer { _, _ in jsonResponse(200, "{}") }
        let client = try Anthropic(.init(fetch: server.fetch, env: [:]))
        do {
            _ = try await client.beta.messages.create(["model": "m", "max_tokens": 1, "messages": [], "stream": true]).asResponse()
            Issue.record("expected an error")
        } catch {
            #expect(errorMessage(error) == "Could not resolve authentication method. Expected one of apiKey, authToken, credentials, config, or profile to be set. Or for one of the \"X-Api-Key\" or \"Authorization\" headers to be explicitly omitted")
        }
        #expect(server.requests.isEmpty)
    }

    @Test func anthropicStatusErrorTypeAndMessage() async throws {
        let body = #"{"type":"error","error":{"type":"rate_limit_error","message":"slow down"}}"#
        let server = FakeServer { _, _ in jsonResponse(429, body, headers: [("request-id", "req_9")]) }
        let client = try Anthropic(.init(apiKey: "k", fetch: server.fetch, maxRetries: 0, env: [:]))
        do {
            _ = try await client.beta.messages.create(["model": "m", "max_tokens": 1, "messages": [], "stream": true]).asResponse()
            Issue.record("expected an error")
        } catch let error as Anthropic.RateLimitError {
            #expect(error.status == 429)
            #expect(error.type == "rate_limit_error")
            #expect(error.requestID == "req_9")
            #expect(error.message == "429 \(body)")
        }
    }

    @Test func anthropicCredentialsProviderAddsOAuthBetaAndRefreshesOn401() async throws {
        let calls = Locked<[Bool]>([])
        let provider: AccessTokenProvider = { options in
            let count = calls.withLock { c -> Int in
                c.append(options?.forceRefresh ?? false)
                return c.count
            }
            return AccessToken(token: "tok\(count)", expiresAt: nil)
        }
        let server = FakeServer { _, index in
            index == 0 ? jsonResponse(401, #"{"type":"error","error":{"type":"authentication_error","message":"expired"}}"#, headers: [("retry-after-ms", "1")]) : jsonResponse(200, "{}")
        }
        let client = try Anthropic(.init(fetch: server.fetch, maxRetries: 2, credentials: provider, env: [:]))
        _ = try await client.beta.messages.create(["model": "m", "max_tokens": 1, "messages": [], "betas": ["b1"], "stream": true]).asResponse()
        #expect(server.requests.count == 2)
        let first = server.requests[0]
        #expect(first.headers.get("authorization") == "Bearer tok1")
        #expect(first.headers.get("x-api-key") == nil)
        #expect(first.headers.get("anthropic-beta") == "b1,oauth-2025-04-20")
        #expect(server.requests[1].headers.get("authorization") == "Bearer tok2")
    }

    @Test func anthropicWithOptionsKeepsAuthAndOverrides() async throws {
        let server = FakeServer { _, _ in jsonResponse(200, "{}") }
        let client = try Anthropic(.init(apiKey: "k1", fetch: server.fetch, env: [:]))
        let clone = try client.withOptions(.init(baseURL: "https://proxy.test"))
        _ = try await clone.beta.messages.create(["model": "m", "max_tokens": 1, "messages": [], "stream": true]).asResponse()
        let request = try #require(server.requests.first)
        #expect(request.url.absoluteString == "https://proxy.test/v1/messages?beta=true")
        #expect(request.headers.get("x-api-key") == "k1")
    }

    @Test func anthropicNonStreamingTimeout() throws {
        let client = try Anthropic(.init(apiKey: "k", env: [:]))
        #expect(try client.calculateNonstreamingTimeout(1000, nil) == 600_000)
        do {
            _ = try client.calculateNonstreamingTimeout(100_000, nil)
            Issue.record("expected an error")
        } catch {
            #expect(errorMessage(error).hasPrefix("Streaming is required for operations that may take longer than 10 minutes."))
        }
    }

    @Test func anthropicRedactSensitive() {
        let body: JsonValue = ["error": "invalid_grant", "error_description": "bad", "assertion": "secret", "access_token": "x"]
        #expect(redactSensitive(body) == ["error": "invalid_grant", "error_description": "bad"])
        #expect(redactSensitive(nil) == nil)
    }

    // MARK: - Google GenAI

    private func googleClient(_ server: FakeServer, httpOptions: JsonObject? = nil, env: ProviderEnv = [:]) throws -> GoogleGenAI {
        try GoogleGenAI(.init(apiKey: "g-key", httpOptions: httpOptions, fetch: server.fetch, env: env))
    }

    @Test func googleRequestURLHeadersAndBody() async throws {
        let sse = "data: {\"candidates\":[{\"content\":{\"parts\":[{\"text\":\"hi\"}],\"role\":\"model\"},\"index\":0,\"citationMetadata\":{\"citationSources\":[{\"uri\":\"u\"}]}}],\"responseId\":\"r1\"}\r\n\r\n"
        let server = FakeServer { _, _ in chunkedResponse(200, [sse], headers: [("Content-Type", "text/event-stream"), ("X-Trace", "t")]) }
        let client = try googleClient(server, httpOptions: [
            "baseUrl": "https://proxy.test/v1beta/",
            "apiVersion": "",
            "headers": ["User-Agent": "pi/1", "X-Custom": "c"],
        ])
        let params: JsonValue = [
            "model": "gemini-x",
            "contents": [["role": "model", "parts": [["thought": true, "thoughtSignature": "sig", "text": "t"]]]],
            "config": [
                "temperature": 0.5,
                "systemInstruction": "be nice",
                "tools": [["functionDeclarations": [["name": "f", "parameters": ["type": "object", "properties": ["a": ["type": ["string", "null"]]], "additionalProperties": false]]]]],
                "toolConfig": ["functionCallingConfig": ["mode": "AUTO"]],
                "thinkingConfig": ["includeThoughts": true],
            ],
        ]
        let stream = try await client.models.generateContentStream(params)
        var chunks: [JsonValue] = []
        for try await chunk in stream { chunks.append(chunk) }

        let request = try #require(server.requests.first)
        #expect(request.url.absoluteString == "https://proxy.test/v1beta/models/gemini-x:streamGenerateContent?alt=sse")
        #expect(request.method == "POST")
        #expect(request.headers.get("user-agent") == "pi/1")
        #expect(request.headers.get("x-goog-api-client") == "google-genai-sdk/2.21.0 gl-node/unknown")
        #expect(request.headers.get("content-type") == "application/json")
        #expect(request.headers.get("x-custom") == "c")
        #expect(request.headers.get("x-goog-api-key") == "g-key")
        #expect(bodyText(request) == #"{"contents":[{"parts":[{"text":"t","thought":true,"thoughtSignature":"sig"}],"role":"model"}],"systemInstruction":{"parts":[{"text":"be nice"}],"role":"user"},"tools":[{"functionDeclarations":[{"name":"f","parameters":{"type":"OBJECT","properties":{"a":{"nullable":true,"type":"STRING"}}}}]}],"toolConfig":{"functionCallingConfig":{"mode":"AUTO"}},"generationConfig":{"temperature":0.5,"thinkingConfig":{"includeThoughts":true}}}"#)

        #expect(chunks.count == 1)
        let chunk = try #require(chunks.first)
        #expect(chunk["responseId"] == "r1")
        #expect(chunk["candidates"]?[0]?["citationMetadata"] == ["citations": [["uri": "u"]]])
        #expect(chunk["sdkHttpResponse"] == ["headers": ["content-type": "text/event-stream", "x-trace": "t"]])
    }

    @Test func googleDefaultBaseURLFromEnvAndTimeoutHeader() async throws {
        let server = FakeServer { _, _ in chunkedResponse(200, []) }
        let client = try googleClient(server, httpOptions: ["timeout": 1500], env: ["GOOGLE_GEMINI_BASE_URL": " https://env.test "])
        for try await _ in try await client.models.generateContentStream(["model": "models/g", "contents": "hello"]) {}
        let request = try #require(server.requests.first)
        #expect(request.url.absoluteString == "https://env.test/v1beta/models/g:streamGenerateContent?alt=sse")
        #expect(request.headers.get("x-server-timeout") == "2")
        #expect(bodyText(request) == #"{"contents":[{"parts":[{"text":"hello"}],"role":"user"}]}"#)
    }

    @Test func googleApiKeyFromEnv() throws {
        let client = try GoogleGenAI(.init(env: ["GOOGLE_API_KEY": "", "GEMINI_API_KEY": "gem"]))
        #expect(client.apiClient.getApiKey() == "gem")
        do {
            _ = try GoogleGenAI(.init(project: "p", env: [:]))
            Issue.record("expected an error")
        } catch {
            #expect(errorMessage(error) == "Project and location are not supported for Gemini API backend.")
        }
    }

    @Test func googleHTTPErrorThrowsApiError() async throws {
        let server = FakeServer { _, _ in jsonResponse(429, #"{"error":{"code":429,"message":"quota","status":"RESOURCE_EXHAUSTED"}}"#) }
        let client = try googleClient(server)
        do {
            _ = try await client.models.generateContentStream(["model": "g", "contents": "x"])
            Issue.record("expected an error")
        } catch let error as GoogleGenAI.ApiError {
            #expect(error.status == 429)
            #expect(error.message == #"{"error":{"code":429,"message":"quota","status":"RESOURCE_EXHAUSTED"}}"#)
            #expect(error.headers == nil)
        }
    }

    @Test func googleNonJSONHTTPError() async throws {
        let server = FakeServer { _, _ in textResponse(503, "unavailable", statusText: "Service Unavailable") }
        let client = try googleClient(server)
        do {
            _ = try await client.models.generateContentStream(["model": "g", "contents": "x"])
            Issue.record("expected an error")
        } catch let error as GoogleGenAI.ApiError {
            #expect(error.status == 503)
            #expect(error.message == #"{"error":{"message":"unavailable","code":503,"status":"Service Unavailable"}}"#)
        }
    }

    @Test func googleErrorChunkThrowsApiError() async throws {
        let server = FakeServer { _, _ in
            chunkedResponse(200, ["data: {\"responseId\":\"a\"}\n\n", #"{"error":{"code":500,"status":"INTERNAL","message":"m"}}"#])
        }
        let client = try googleClient(server)
        let stream = try await client.models.generateContentStream(["model": "g", "contents": "x"])
        var received: [JsonValue] = []
        do {
            for try await chunk in stream { received.append(chunk) }
            Issue.record("expected an error")
        } catch let error as GoogleGenAI.ApiError {
            #expect(error.status == 500)
            #expect(error.message == #"got status: INTERNAL. {"error":{"code":500,"status":"INTERNAL","message":"m"}}"#)
        }
        #expect(received.count == 1)
    }

    @Test func googleIncompleteSegment() async throws {
        let server = FakeServer { _, _ in chunkedResponse(200, ["data: {\"responseId\":\"a\"}\n\ndata: {\"respon"]) }
        let client = try googleClient(server)
        let stream = try await client.models.generateContentStream(["model": "g", "contents": "x"])
        var received: [JsonValue] = []
        do {
            for try await chunk in stream { received.append(chunk) }
            Issue.record("expected an error")
        } catch {
            #expect(errorMessage(error) == "Incomplete JSON segment at the end")
        }
        #expect(received.count == 1)
    }

    @Test func googleUTF8SplitAcrossChunks() async throws {
        let bytes = Array("data: {\"responseId\":\"é😀\"}\n\n".utf8)
        let split = bytes.firstIndex(of: 0xF0)! + 2
        let stream = AsyncThrowingStream<Data, any Error> { continuation in
            continuation.yield(Data(bytes[..<split]))
            continuation.yield(Data(bytes[split...]))
            continuation.finish()
        }
        let server = FakeServer { _, _ in FetchResponse(status: 200, headers: Headers(), body: ResponseBody(stream)) }
        let client = try googleClient(server)
        var received: [JsonValue] = []
        for try await chunk in try await client.models.generateContentStream(["model": "g", "contents": "x"]) { received.append(chunk) }
        #expect(received.first?["responseId"] == "é😀")
    }

    @Test func googleAbortSignalAbortsRequest() async throws {
        let server = FakeServer { request, _ in try await hangUntilAborted(request) }
        let client = try googleClient(server)
        let controller = AbortController()
        _ = Task {
            try await Task.sleep(nanoseconds: 30_000_000)
            controller.abort()
        }
        do {
            _ = try await client.models.generateContentStream(["model": "g", "contents": "x"], abortSignal: controller.signal)
            Issue.record("expected an error")
        } catch {
            #expect(errorMessage(error) == "This operation was aborted")
        }
    }

    @Test func googleConverterErrors() async throws {
        let server = FakeServer { _, _ in chunkedResponse(200, []) }
        let client = try googleClient(server)
        await #expect(throws: PiError("labels parameter is only supported in Gemini Enterprise Agent Platform mode, not in Gemini Developer API mode.")) {
            _ = try await client.models.generateContentStream(["model": "g", "contents": "x", "config": ["labels": nil]])
        }
        await #expect(throws: PiError("invalid model parameter")) {
            _ = try await client.models.generateContentStream(["model": "a?b", "contents": "x"])
        }
        await #expect(throws: PiError("contents are required")) {
            _ = try await client.models.generateContentStream(["model": "g", "contents": []])
        }
        await #expect(throws: PiError("To specify functionCall or functionResponse parts, please wrap them in a Content object, specifying the role for them")) {
            _ = try await client.models.generateContentStream(["model": "g", "contents": ["functionCall": ["name": "f"]]])
        }
        await #expect(throws: PiError("Mixing Content and Parts is not supported, please group the parts into a the appropriate Content objects and specify the roles for them")) {
            _ = try await client.models.generateContentStream(["model": "g", "contents": [["role": "user", "parts": []], "text"]])
        }
        #expect(server.requests.isEmpty)
    }

    @Test func googleProcessJsonSchema() throws {
        let schema: JsonValue = [
            "type": "object",
            "description": "d",
            "properties": [
                "list": ["anyOf": [["type": "null"], ["type": "array", "items": ["type": "integer"]]]],
                "multi": ["type": ["string", "number"]],
                "weird": ["type": "custom"],
            ],
            "required": ["list"],
            "additionalProperties": false,
        ]
        let result = try processJsonSchema(schema)
        #expect(result.serialized() == #"{"type":"OBJECT","description":"d","properties":{"list":{"nullable":true,"type":"ARRAY","items":{"type":"INTEGER"}},"multi":{"anyOf":[{"type":"STRING"},{"type":"NUMBER"}]},"weird":{"type":"TYPE_UNSPECIFIED"}},"required":["list"]}"#)
        #expect(throws: PiError("type and anyOf cannot be both populated.")) { try processJsonSchema(["type": "string", "anyOf": []]) }
        #expect(throws: PiError("type: null can not be the only possible type for the field.")) { try processJsonSchema(["type": "null"]) }
    }

    @Test func googleSchemaWithDollarSchemaMovesToJsonSchemaFields() async throws {
        let server = FakeServer { _, _ in chunkedResponse(200, []) }
        let client = try googleClient(server)
        let params: JsonValue = [
            "model": "g",
            "contents": "x",
            "config": [
                "responseSchema": ["$schema": "s", "type": "object"],
                "tools": [["functionDeclarations": [["name": "f", "parameters": ["$schema": "s", "type": "object"]]]]],
            ],
        ]
        for try await _ in try await client.models.generateContentStream(params) {}
        let body = try bodyJSON(try #require(server.requests.first))
        #expect(body["generationConfig"] == ["responseJsonSchema": ["$schema": "s", "type": "object"]])
        #expect(body["tools"] == [["functionDeclarations": [["name": "f", "parametersJsonSchema": ["$schema": "s", "type": "object"]]]]])
    }
}
