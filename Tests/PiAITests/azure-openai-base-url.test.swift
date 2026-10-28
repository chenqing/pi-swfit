import Foundation
import Testing
@testable import PiAI

// Port of packages/ai/test/azure-openai-base-url.test.ts
//
// Swift: `vi.mock("openai")` captured the `AzureOpenAI` constructor options. Here the `baseURL` given to
// the client is `resolveAzureConfig(model, options).baseUrl` (what `createClient` passes) and the request
// itself is checked through a recording fake fetch. `process.env.AZURE_OPENAI_*` become `options.env`.

private func context() -> Context { Context(messages: [.user(UserMessage(content: "hello"))]) }

private let completedSSE = dSSE([
    ["type": "response.created", "sequence_number": 0, "response": ["id": "resp_azure"]],
    ["type": "response.completed", "sequence_number": 1, "response": ["id": "resp_azure", "status": "completed"]],
])

private func azureOptions(_ recorder: DRecorder, _ configure: (inout StreamOptions) -> Void = { _ in }) -> StreamOptions {
    var options = StreamOptions()
    options.apiKey = "test-api-key"
    options.env = [:]
    options.fetch = dSSEFetch(recorder, completedSSE)
    configure(&options)
    return options
}

private func captureClientBaseUrl(_ baseUrl: String) async throws -> (baseURL: String, requestURL: String?) {
    let model = dModel("azure", "gpt-4o-mini")
    let recorder = DRecorder()
    let options = azureOptions(recorder) { $0.env = ["AZURE_OPENAI_BASE_URL": baseUrl] }
    let result = await streamAzureOpenAIResponses(model, normalizeContext(context()), options).result()
    #expect(recorder.requests.count == 1, "\(result.errorMessage ?? "")")
    return (try resolveAzureConfig(model, options).baseUrl, recorder.last?.url.absoluteString)
}

private func captureClientHeaders(_ headers: ProviderHeaders? = nil) async -> DCapturedRequest? {
    let recorder = DRecorder()
    let options = azureOptions(recorder) {
        $0.extra["azureBaseUrl"] = "https://my-resource.openai.azure.com"
        $0.headers = headers
    }
    _ = await streamAzureOpenAIResponses(dModel("azure", "gpt-4o-mini"), normalizeContext(context()), options).result()
    #expect(recorder.requests.count == 1)
    return recorder.last
}

@Suite struct AzureBaseURLNormalizationTests {
    @Test(arguments: [
        ("https://marc-quicktests-resource.cognitiveservices.azure.com", "https://marc-quicktests-resource.cognitiveservices.azure.com/openai/v1"),
        ("https://marc-quicktests-resource.ai.azure.com", "https://marc-quicktests-resource.ai.azure.com/openai/v1"),
        ("https://my-resource.openai.azure.com", "https://my-resource.openai.azure.com/openai/v1"),
        ("https://my-resource.cognitiveservices.azure.com/openai", "https://my-resource.cognitiveservices.azure.com/openai/v1"),
        ("https://my-resource.cognitiveservices.azure.com/openai/v1", "https://my-resource.cognitiveservices.azure.com/openai/v1"),
        ("https://my-resource.services.ai.azure.com/openai/v1/responses", "https://my-resource.services.ai.azure.com/openai/v1"),
        ("https://my-proxy.example.com/v1", "https://my-proxy.example.com/v1"),
        ("https://my-resource.openai.azure.com/openai?api-version=2024-12-01", "https://my-resource.openai.azure.com/openai/v1"),
    ])
    func normalizesBaseUrl(_ input: String, _ expected: String) async throws {
        let (baseURL, requestURL) = try await captureClientBaseUrl(input)
        #expect(baseURL == expected)
        #expect(requestURL == "\(expected)/responses?api-version=v1")
    }

    @Test func preservesQueryParamsOnNonAzureProxyUrls() async throws {
        let (baseURL, _) = try await captureClientBaseUrl("https://my-proxy.example.com/v1?custom=true")
        #expect(baseURL == "https://my-proxy.example.com/v1?custom=true")
    }

    @Test func throwsOnInvalidUrls() async {
        let recorder = DRecorder()
        let options = azureOptions(recorder) { $0.env = ["AZURE_OPENAI_BASE_URL": "not-a-url"] }
        let result = await streamAzureOpenAIResponses(dModel("azure", "gpt-4o-mini"), normalizeContext(context()), options).result()
        #expect(result.stopReason == .error)
        #expect(result.errorMessage?.contains("Invalid Azure OpenAI base URL") == true)
    }

    @Test func clampsPromptCacheKeyToOpenAIs64CharacterLimit() async {
        let recorder = DRecorder()
        let options = azureOptions(recorder) {
            $0.extra["azureBaseUrl"] = "https://my-resource.openai.azure.com"
            $0.sessionId = String(repeating: "x", count: 67)
        }
        _ = await streamAzureOpenAIResponses(dModel("azure", "gpt-4o-mini"), normalizeContext(context()), options).result()
        #expect(recorder.last?.body?["prompt_cache_key"]?.stringValue == String(repeating: "x", count: 64))
    }

    @Test func disablesServerSideResponseStorage() async {
        let recorder = DRecorder()
        let options = azureOptions(recorder) { $0.extra["azureBaseUrl"] = "https://my-resource.openai.azure.com" }
        _ = await streamAzureOpenAIResponses(dModel("azure", "gpt-4o-mini"), normalizeContext(context()), options).result()
        #expect(recorder.last?.body?["store"] == false)
    }

    @Test func honorsSupportsStrictModeFalse() async {
        var model = dModel("azure", "gpt-4o-mini")
        var compat = model.compat ?? JsonObject()
        compat["supportsStrictMode"] = false
        model.compat = compat
        var ctx = context()
        ctx.tools = [Tool(
            name: "preferred",
            description: "Preferred constrained tool",
            parameters: dStringObjectSchema(["value"]),
            constrainedSampling: .jsonSchema(strict: "prefer")
        )]
        let recorder = DRecorder()
        let options = azureOptions(recorder) { $0.extra["azureBaseUrl"] = "https://my-resource.openai.azure.com" }
        _ = await streamAzureOpenAIResponses(model, normalizeContext(ctx), options).result()
        let tool = recorder.last?.body?["tools"]?.arrayValue?.first
        #expect(tool != nil)
        #expect(tool?["strict"] == nil)
    }

    @Test func buildsCorrectDefaultUrlFromAzureOpenAIResourceName() async throws {
        let model = dModel("azure", "gpt-4o-mini")
        let recorder = DRecorder()
        let options = azureOptions(recorder) { $0.env = ["AZURE_OPENAI_RESOURCE_NAME": "my-resource"] }
        _ = await streamAzureOpenAIResponses(model, normalizeContext(context()), options).result()
        #expect(recorder.requests.count == 1)
        #expect(try resolveAzureConfig(model, options).baseUrl == "https://my-resource.openai.azure.com/openai/v1")
        #expect(recorder.last?.url.absoluteString == "https://my-resource.openai.azure.com/openai/v1/responses?api-version=v1")
    }
}

@Suite struct AzureProviderStreamEventsTests {
    @Test func forwardsParsedEventsInOrderBeforeNormalizingTheResponse() async {
        let streamEvents: [JsonValue] = [
            ["type": "response.created", "sequence_number": 0, "response": ["id": "resp_azure"]],
            ["type": "response.completed", "sequence_number": 1, "response": ["id": "resp_azure", "status": "completed"]],
        ]
        let model = dModel("azure", "gpt-4o-mini")
        let received = Locked<[(JsonValue, String)]>([])
        let options = azureOptions(DRecorder()) {
            $0.extra["azureBaseUrl"] = "https://my-resource.openai.azure.com"
            $0.onProviderStreamEvent = { event, eventModel in
                await Task.yield()
                received.withLock { $0.append((event, eventModel.id)) }
            }
        }
        let result = await streamAzureOpenAIResponses(model, normalizeContext(context()), options).result()

        #expect(received.current.map(\.0) == streamEvents)
        #expect(received.current.map(\.1) == [model.id, model.id])
        #expect(result.stopReason == .stop)
        #expect(result.responseId == "resp_azure")
    }
}

@Suite struct AzureUserAgentTests {
    @Test func usesPisUserAgentByDefault() async {
        #expect(await captureClientHeaders()?.header("User-Agent") == getPiUserAgent())
    }

    @Test func letsExplicitHeadersOverrideTheDefaultUserAgent() async {
        #expect(await captureClientHeaders([("User-Agent", "custom-agent")])?.header("User-Agent") == "custom-agent")
    }
}
