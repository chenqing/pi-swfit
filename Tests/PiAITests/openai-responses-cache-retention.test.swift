import Foundation
import Testing
@testable import PiAI

// Port of the "OpenAI Responses Provider" section of packages/ai/test/cache-retention.test.ts.
// `process.env.PI_CACHE_RETENTION` becomes `options.env`; the two network cases (OPENAI_API_KEY) are skipped.

private func context() -> TranscriptContext {
    normalizeContext(Context(systemPrompt: "You are a helpful assistant.", messages: [.user(UserMessage(content: "Hello"))]))
}

private func capturePayload(_ model: Model, _ configure: (inout StreamOptions) -> Void) async -> JsonValue? {
    let payload = Locked<JsonValue?>(nil)
    var options = StreamOptions()
    options.apiKey = "sk-fake-key"
    options.env = [:]
    configure(&options)
    options.onPayload = { p, _ in
        payload.withLock { $0 = p }
        throw PiError("payload captured", name: "PayloadCaptured")
    }
    for await event in streamOpenAIResponses(model, context(), options) {
        if event.type == "error" { break }
    }
    return payload.current
}

@Suite struct OpenAIResponsesCacheRetentionTests {
    @Test(arguments: ["gpt-5.6-luna", "gpt-5.6-sol", "gpt-5.6-terra", "gpt-6-astra", "gpt-6-luna", "gpt-6-sol"])
    func doesNotEnableCacheWarmingFromTheDocumentedTTLAlone(_ modelId: String) {
        #expect(dModel("openai", modelId).promptCache == nil)
    }

    @Test func setsPromptCacheRetentionForNonOpenAIBaseUrlByDefault() async {
        var proxyModel = dModel("openai", "gpt-4o-mini")
        proxyModel.baseUrl = "https://my-proxy.example.com/v1"
        let payload = await capturePayload(proxyModel) { $0.env = ["PI_CACHE_RETENTION": "long"] }
        #expect(payload != nil)
        #expect(payload?["prompt_cache_retention"] == "24h")
    }

    @Test func omitsPromptCacheRetentionWhenSupportsLongCacheRetentionIsFalse() async {
        var model = dModel("openai", "gpt-4o-mini")
        model.compat = ["supportsLongCacheRetention": false]
        let payload = await capturePayload(model) {
            $0.cacheRetention = .long
            $0.sessionId = "session-compat-false"
        }
        #expect(payload != nil)
        #expect(payload?["prompt_cache_retention"] == nil)
    }

    @Test func omitsPromptCacheKeyAndDisablesImplicitWritesWhenCacheRetentionIsNone() async {
        let payload = await capturePayload(dModel("openai", "gpt-5.6-sol")) {
            $0.cacheRetention = CacheRetention.none
            $0.sessionId = "session-1"
        }
        #expect(payload != nil)
        #expect(payload?["prompt_cache_key"] == nil)
        #expect(payload?["prompt_cache_retention"] == nil)
        #expect(payload?["prompt_cache_options"] == ["mode": "explicit"])
    }

    @Test func omitsPromptCacheOptionsForModelsThatRejectIt() async {
        let payload = await capturePayload(dModel("openai", "gpt-4o-mini")) {
            $0.cacheRetention = CacheRetention.none
            $0.sessionId = "session-1"
        }
        #expect(payload != nil)
        #expect(payload?["prompt_cache_key"] == nil)
        #expect(payload?["prompt_cache_options"] == nil)
    }

    @Test(arguments: [
        ("gpt-4o-mini", "24h", nil),
        ("gpt-6-astra", nil, ["ttl": "30m"]),
        ("gpt-6-sol", nil, ["ttl": "30m"]),
        ("gpt-6-luna", nil, ["ttl": "30m"]),
    ] as [(String, String?, JsonValue?)])
    func usesTheSupportedLongCacheField(_ modelId: String, _ retention: String?, _ cacheOptions: JsonValue?) async {
        let payload = await capturePayload(dModel("openai", modelId)) {
            $0.cacheRetention = .long
            $0.sessionId = "session-2"
        }
        #expect(payload?["prompt_cache_key"] == "session-2")
        #expect(payload?["prompt_cache_retention"]?.stringValue == retention)
        #expect(payload?["prompt_cache_options"] == cacheOptions)
    }
}
