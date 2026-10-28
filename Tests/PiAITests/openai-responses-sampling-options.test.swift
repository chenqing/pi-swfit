import Foundation
import Testing
@testable import PiAI

// Port of the openai-responses / azure-openai-responses cases of packages/ai/test/sampling-options.test.ts.
// Upstream dispatches through `compat.stream()`; here the adapters are called directly by api.

private func makeModel(_ api: String, _ samplingParams: SamplingParams? = nil, _ overrides: (inout Model) -> Void = { _ in }) -> Model {
    var model = Model(id: "custom-model", name: "Custom Model", api: api, provider: "custom-provider",
                      baseUrl: "http://127.0.0.1:9/v1", reasoning: false, input: ["text"],
                      contextWindow: 128000, maxTokens: 16384)
    model.samplingParams = samplingParams
    overrides(&model)
    return model
}

private func capturePayload(_ model: Model, _ configure: (inout StreamOptions) -> Void = { _ in }) async throws -> JsonValue {
    let payload = Locked<JsonValue?>(nil)
    var options = StreamOptions()
    configure(&options)
    options.apiKey = "fake-key"
    options.onPayload = { p, _ in
        payload.withLock { $0 = p }
        throw PiError("payload captured", name: "PayloadCaptured")
    }
    let context = normalizeContext(Context(messages: [.user(UserMessage(content: "Hello"))]))
    let stream = model.api == "azure-openai-responses"
        ? streamAzureOpenAIResponses(model, context, options)
        : streamOpenAIResponses(model, context, options)
    _ = await stream.result()
    return try #require(payload.current, "Expected payload to be captured before request failure")
}

@Suite struct OpenAIResponsesSamplingParamsTests {
    // Model defaults must apply to direct stream()/complete() calls, not only streamSimple() (#9506)
    @Test(arguments: ["openai-responses", "azure-openai-responses"])
    func appliesModelLevelSamplingParamsWithRequestKeysTakingPrecedence(_ api: String) async throws {
        let payload = try await capturePayload(makeModel(api, ["top_p": 0.95, "min_p": 0.05])) {
            $0.samplingParams = ["top_p": 0.5]
        }
        #expect(payload["top_p"] == 0.5)
        #expect(payload["min_p"] == 0.05)
    }

    @Test(arguments: ["openai-responses", "azure-openai-responses"])
    func appliesThinkingLevelParamsBetweenModelAndRequestParams(_ api: String) async throws {
        let model = makeModel(api, ["temperature": 1, "top_p": 0.95]) {
            $0.reasoning = true
            $0.samplingParamsByThinkingLevel = [.low: ["temperature": 0.6, "top_k": 64]]
        }
        let payload = try await capturePayload(model) {
            $0.extra["reasoningEffort"] = "low"
            $0.samplingParams = ["top_p": 0.5]
        }
        #expect(payload["temperature"] == 0.6)
        #expect(payload["top_p"] == 0.5)
        #expect(payload["top_k"] == 64)
    }

    @Test(arguments: ["openai-responses", "azure-openai-responses"])
    func usesMediumSamplingParamsForSummaryOnlyRequests(_ api: String) async throws {
        let model = makeModel(api) {
            $0.reasoning = true
            $0.samplingParamsByThinkingLevel = [.off: ["temperature": 0.7], .medium: ["temperature": 0.8]]
        }
        let payload = try await capturePayload(model) { $0.extra["reasoningSummary"] = "auto" }
        #expect(payload["reasoning"]?["effort"] == "medium")
        #expect(payload["temperature"] == 0.8)
    }
}
