import Foundation
import Testing
@testable import PiAI

// Port of packages/ai/test/openai-responses-compat.test.ts

private struct CapturedAffinity {
    var sessionId: String?
    var clientRequestId: String?
    var xSessionId: String?
}

private func streamWithPayload(_ model: Model, _ context: TranscriptContext, _ configure: (inout StreamOptions) -> Void = { _ in }) async -> (payload: JsonValue?, recorder: DRecorder, result: AssistantMessage) {
    let recorder = DRecorder()
    let payload = Locked<JsonValue?>(nil)
    var options = StreamOptions()
    options.apiKey = "sk-test-key"
    options.fetch = dSSEFetch(recorder)
    options.onPayload = { p, _ in payload.withLock { $0 = p }; return nil }
    configure(&options)
    let stream = streamOpenAIResponses(model, context, options)
    let (_, result) = await dCollect(stream)
    return (payload.current, recorder, result)
}

private func captureOpenAIResponseHeaders(_ model: Model = dModel("openai", "gpt-5.4"), _ configure: (inout StreamOptions) -> Void) async -> (CapturedAffinity, JsonValue?) {
    let (payload, recorder, _) = await streamWithPayload(model, dUserContext(), configure)
    let request = recorder.last
    return (CapturedAffinity(
        sessionId: request?.header("session_id"),
        clientRequestId: request?.header("x-client-request-id"),
        xSessionId: request?.header("x-session-id")
    ), payload)
}

@Suite struct OpenAIResponsesProviderDefaultsTests {
    @Test func omitsReasoningWhenNoReasoningIsRequested() async {
        let (payload, _, _) = await streamWithPayload(dModel("github-copilot", "gpt-5-mini"), dUserContext())
        #expect(payload != nil)
        #expect(payload?["reasoning"] == nil)
    }

    @Test func forwardsRequiredToolChoice() async {
        let context = normalizeContext(Context(
            messages: [.user(UserMessage(content: "Do not call ping. Respond with text instead."))],
            tools: [Tool(name: "ping", description: "Ping", parameters: dStringObjectSchema(["value"]))]
        ))
        let (payload, _, _) = await streamWithPayload(dModel("openai", "gpt-5.4"), context) { $0.toolChoice = "required" }
        // gpt-5.4 declares its tools in additional_tools items; tool_choice applies to them.
        #expect(payload?["tool_choice"] == "required")
        let input = payload?["input"]?.arrayValue ?? []
        #expect(input.count == 2)
        #expect(input.first?["type"] == "additional_tools")
        #expect(input.first?["tools"]?.arrayValue?.contains { $0["name"] == "ping" } == true)
    }

    @Test func setsStrictModeExplicitlyForCloudflareOpenAIResponsesTools() async {
        let model = dModel("cloudflare-ai-gateway", "gpt-5.6-sol")
        let ordinarySchema: JsonValue = [
            "type": "object",
            "properties": ["path": ["type": "string"], "offset": ["type": "number"]],
            "required": ["path"],
        ]
        let context = normalizeContext(Context(
            messages: [.user(UserMessage(content: "Use a tool."))],
            tools: [
                Tool(name: "ordinary", description: "An ordinary tool", parameters: ordinarySchema),
                Tool(name: "constrained", description: "A constrained tool", parameters: dStringObjectSchema(["value"]),
                     constrainedSampling: .some(.jsonSchema(strict: "prefer"))),
            ]
        ))
        let (payload, _, _) = await streamWithPayload(model, context)
        #expect(model.compat?["supportsStrictMode"] == true)
        let tools = payload?["tools"]?.arrayValue ?? []
        #expect(tools.map { $0["name"] } == ["ordinary", "constrained"])
        #expect(tools.map { $0["strict"] } == [false, true])
    }

    @Test(arguments: [
        "gpt-5.1", "gpt-5.2", "gpt-5.3-codex", "gpt-5.4", "gpt-5.4-mini", "gpt-5.4-nano", "gpt-5.5",
        "gpt-5.6-sol", "gpt-5.6-terra", "gpt-5.6-luna", "gpt-6-sol", "gpt-6-luna",
    ])
    func sendsNoneReasoningEffortWhenNoReasoningIsRequested(_ modelId: String) async {
        let (payload, _, _) = await streamWithPayload(dModel("openai", modelId), dUserContext())
        #expect(payload?["reasoning"]?["effort"] == "none")
    }

    @Test(arguments: ["gpt-5", "gpt-5-mini", "gpt-5-nano", "gpt-5-pro", "gpt-5.2-pro", "gpt-5.4-pro", "gpt-5.5-pro"])
    func omitsReasoningEffortWhenOffIsUnsupported(_ modelId: String) async {
        let (payload, _, _) = await streamWithPayload(dModel("openai", modelId), dUserContext())
        #expect(payload != nil)
        #expect(payload?["reasoning"] == nil)
    }

    @Test func setsCacheAffinityHeadersForOfficialRequestsWithASessionId() async {
        let (captured, _) = await captureOpenAIResponseHeaders { $0.sessionId = "session-123" }
        #expect(captured.sessionId == "session-123")
        #expect(captured.clientRequestId == "session-123")
    }

    @Test func clampsPromptCacheKeyTo64Characters() async {
        let sessionId = String(repeating: "x", count: 67)
        let (payload, _, _) = await streamWithPayload(dModel("openai", "gpt-5.4"), dUserContext()) { $0.sessionId = sessionId }
        #expect(payload?["prompt_cache_key"] == .string(String(repeating: "x", count: 64)))
    }

    @Test func setsCacheAffinityHeadersForProxyRequestsWithASessionId() async {
        var proxyModel = dModel("openai", "gpt-5.4")
        proxyModel.provider = "opencode"
        proxyModel.baseUrl = "https://proxy.example.com/v1"
        let (captured, _) = await captureOpenAIResponseHeaders(proxyModel) { $0.sessionId = "session-123" }
        #expect(captured.sessionId == "session-123")
        #expect(captured.clientRequestId == "session-123")
    }

    @Test func usesOpenRouterSessionAffinityHeaderWhenConfigured() async {
        var proxyModel = dModel("openai", "gpt-5.4")
        proxyModel.provider = "proxy"
        proxyModel.baseUrl = "https://proxy.example.com/v1"
        proxyModel.compat = ["sessionAffinityFormat": "openrouter"]
        let (captured, payload) = await captureOpenAIResponseHeaders(proxyModel) { $0.sessionId = "session-proxy" }
        #expect(captured.sessionId == nil)
        #expect(captured.clientRequestId == nil)
        #expect(captured.xSessionId == "session-proxy")
        #expect(payload?["session_id"] == nil)
        #expect(payload?["prompt_cache_key"] == "session-proxy")
    }

    @Test func autoDetectsOpenRouterSessionAffinityHeader() async {
        var model = dModel("openai", "gpt-5.4")
        model.provider = "openrouter"
        model.baseUrl = "https://openrouter.ai/api/v1"
        let (captured, payload) = await captureOpenAIResponseHeaders(model) { $0.sessionId = "session-openrouter" }
        #expect(captured.sessionId == nil)
        #expect(captured.clientRequestId == nil)
        #expect(captured.xSessionId == "session-openrouter")
        #expect(payload?["session_id"] == nil)
        #expect(payload?["prompt_cache_key"] == "session-openrouter")
    }

    @Test func usesOpenAINoSessionFormatWhenConfigured() async {
        var proxyModel = dModel("openai", "gpt-5.4")
        proxyModel.provider = "proxy"
        proxyModel.baseUrl = "https://proxy.example.com/v1"
        proxyModel.compat = ["sessionAffinityFormat": "openai-nosession"]
        let (captured, payload) = await captureOpenAIResponseHeaders(proxyModel) { $0.sessionId = "session-proxy" }
        #expect(captured.sessionId == nil)
        #expect(captured.clientRequestId == "session-proxy")
        #expect(captured.xSessionId == nil)
        #expect(payload?["session_id"] == nil)
        #expect(payload?["prompt_cache_key"] == "session-proxy")
    }

    @Test func usesOpenAINoSessionFormatForOpenCodeResponsesModels() async {
        let model = dModel("opencode", "gpt-5.4")
        let (captured, payload) = await captureOpenAIResponseHeaders(model) { $0.sessionId = "session-opencode" }
        #expect(model.compat?["sessionAffinityFormat"] == "openai-nosession")
        #expect(captured.sessionId == nil)
        #expect(captured.clientRequestId == "session-opencode")
        #expect(captured.xSessionId == nil)
        #expect(payload?["prompt_cache_key"] == "session-opencode")
    }

    @Test func canOmitOpenAISessionIdHeaderWhilePreservingOtherAffinityData() async {
        var proxyModel = dModel("openai", "gpt-5.4")
        proxyModel.provider = "opencode"
        proxyModel.baseUrl = "https://proxy.example.com/v1"
        proxyModel.compat = ["sessionAffinityFormat": "openai-nosession"]
        let (captured, payload) = await captureOpenAIResponseHeaders(proxyModel) { $0.sessionId = "session-123" }
        #expect(captured.sessionId == nil)
        #expect(captured.clientRequestId == "session-123")
        #expect(payload?["prompt_cache_key"] == "session-123")
    }

    @Test func letsExplicitHeadersOverrideTheDefaultCacheAffinityHeaders() async {
        let (captured, _) = await captureOpenAIResponseHeaders {
            $0.sessionId = "session-123"
            $0.headers = [("session_id", "override-session"), ("x-client-request-id", "override-request")]
        }
        #expect(captured.sessionId == "override-session")
        #expect(captured.clientRequestId == "override-request")
    }

    @Test func omitsCacheAffinityHeadersWhenCacheRetentionIsNone() async {
        let (captured, _) = await captureOpenAIResponseHeaders {
            $0.cacheRetention = CacheRetention.none
            $0.sessionId = "session-123"
        }
        #expect(captured.sessionId == nil)
        #expect(captured.clientRequestId == nil)
    }

    @Test(arguments: [
        ("gpt-5.4", "priority", "priority", 2.0),
        ("gpt-5.5", "priority", "priority", 2.5),
        ("gpt-5.5", "flex", "flex", 0.5),
        // GPT-6 models report Fast mode as "fast" even when "priority" is requested (#10034)
        ("gpt-6-luna", "priority", "fast", 2.0),
        ("gpt-6-luna", "fast", "fast", 2.0),
    ])
    func appliesServiceTierCostMultiplier(_ modelId: String, _ serviceTier: String, _ responseServiceTier: String, _ multiplier: Double) async {
        let model = dModel("openai", modelId)
        let tokenCount = 100_000.0
        let tokenScale = tokenCount / 1_000_000
        let event: JsonValue = [
            "type": "response.completed",
            "response": [
                "status": "completed",
                "service_tier": .string(responseServiceTier),
                "usage": [
                    "input_tokens": .number(tokenCount),
                    "output_tokens": .number(tokenCount),
                    "total_tokens": .number(tokenCount * 2),
                    "input_tokens_details": ["cached_tokens": 0],
                ],
            ],
        ]
        let sse = "data: \(event.serialized())\n\n"
        var options = StreamOptions()
        options.apiKey = "sk-test-key"
        options.fetch = dSSEFetch(DRecorder(), sse)
        options.extra["serviceTier"] = .string(serviceTier)
        let result = await streamOpenAIResponses(model, dUserContext(), options).result()

        #expect(abs(result.usage.cost.input - model.cost.input * multiplier * tokenScale) < 1e-12)
        #expect(abs(result.usage.cost.output - model.cost.output * multiplier * tokenScale) < 1e-12)
        #expect(abs(result.usage.cost.total - (model.cost.input + model.cost.output) * multiplier * tokenScale) < 1e-12)
    }
}

@Suite struct OpenAIResponsesMaxOutputTokensCompatTests {
    @Test func sendsMaxOutputTokensByDefault() async {
        let (payload, _, _) = await streamWithPayload(dModel("openai", "gpt-5.4"), dUserContext()) { $0.maxTokens = 1024 }
        #expect(payload?["max_output_tokens"] == 1024)
    }

    @Test func omitsMaxOutputTokensWhenSupportsMaxOutputTokensIsFalse() async {
        var model = dModel("openai", "gpt-5.4")
        var compat = model.compat ?? JsonObject()
        compat["supportsMaxOutputTokens"] = false
        model.compat = compat
        let (payload, _, _) = await streamWithPayload(model, dUserContext()) { $0.maxTokens = 1024 }
        #expect(payload != nil)
        #expect(payload?["max_output_tokens"] == nil)
    }
}
