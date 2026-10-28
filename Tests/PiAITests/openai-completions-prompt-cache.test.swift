import Foundation
import Testing
@testable import PiAI

// Port of packages/ai/test/openai-completions-prompt-cache.test.ts
// Swift: the client `defaultHeaders` the upstream mock captures are read from the request the SDK sent.
// `process.env.PI_CACHE_RETENTION` is passed as the scoped provider env (`options.env`), which
// `getProviderEnvValue` consults before the process environment, so the suite does not mutate global state.

private func createModel(_ configure: (inout Model) -> Void = { _ in }) -> Model {
    var model = cOpenAICompletionsModel()
    configure(&model)
    return model
}

private struct Captured {
    var payload: JsonValue
    var request: FetchRequest
    func header(_ name: String) -> String? { request.headers.get(name) }
}

private func captureRequest(
    cacheRetention: CacheRetention? = nil,
    sessionId: String? = nil,
    headers: ProviderHeaders? = nil,
    env: ProviderEnv? = nil,
    _ model: Model = createModel()
) async throws -> Captured {
    let run = await cRunDirect(model, cUserContext("hi", systemPrompt: "sys")) { options in
        options.apiKey = "test-key"
        options.cacheRetention = cacheRetention
        options.sessionId = sessionId
        options.headers = headers
        options.env = env
    }
    return Captured(payload: run.payload, request: try #require(run.server.requests.first))
}

private func proxyModel(_ compat: JsonObject) -> Model {
    createModel { $0.baseUrl = "https://proxy.example.com/v1"; $0.compat = compat }
}

@Suite("openai-completions prompt caching")
struct OpenAICompletionsPromptCacheTests {
    @Test("sets prompt_cache_key for direct OpenAI requests when caching is enabled")
    func setsPromptCacheKey() async throws {
        let captured = try await captureRequest(sessionId: "session-123")
        #expect(captured.payload["prompt_cache_key"] == "session-123")
        #expect(captured.payload["prompt_cache_retention"] == nil)
    }

    @Test("sets prompt_cache_retention to 24h for direct OpenAI requests when cacheRetention is long")
    func longRetention() async throws {
        let captured = try await captureRequest(cacheRetention: .long, sessionId: "session-456")
        #expect(captured.payload["prompt_cache_key"] == "session-456")
        #expect(captured.payload["prompt_cache_retention"] == "24h")
    }

    @Test("clamps prompt_cache_key to OpenAI's 64-character limit")
    func clampsKey() async throws {
        let captured = try await captureRequest(sessionId: String(repeating: "x", count: 67))
        #expect(captured.payload["prompt_cache_key"] == .string(String(repeating: "x", count: 64)))
    }

    @Test("omits prompt cache fields when cacheRetention is none")
    func omitsWhenNone() async throws {
        let captured = try await captureRequest(cacheRetention: CacheRetention.none, sessionId: "session-789")
        #expect(captured.payload["prompt_cache_key"] == nil)
        #expect(captured.payload["prompt_cache_retention"] == nil)
    }

    @Test("omits prompt cache fields for non-OpenAI base URLs without compatible long retention")
    func omitsForProxies() async throws {
        let captured = try await captureRequest(cacheRetention: .long, sessionId: "session-proxy", proxyModel(["supportsLongCacheRetention": false]))
        #expect(captured.payload["prompt_cache_key"] == nil)
        #expect(captured.payload["prompt_cache_retention"] == nil)
    }

    @Test("uses PI_CACHE_RETENTION for direct OpenAI requests")
    func usesEnvRetention() async throws {
        let captured = try await captureRequest(sessionId: "session-env", env: ["PI_CACHE_RETENTION": "long"])
        #expect(captured.payload["prompt_cache_key"] == "session-env")
        #expect(captured.payload["prompt_cache_retention"] == "24h")
    }

    @Test("sends known session-affinity headers when compat.sendSessionAffinityHeaders is enabled")
    func sessionAffinityHeaders() async throws {
        let captured = try await captureRequest(sessionId: "session-affinity", proxyModel(["sendSessionAffinityHeaders": true]))
        #expect(captured.header("session_id") == "session-affinity")
        #expect(captured.header("x-client-request-id") == "session-affinity")
        #expect(captured.header("x-session-affinity") == "session-affinity")
    }

    @Test("sends Fireworks session affinity", arguments: ["accounts/fireworks/models/glm-5p3", "accounts/fireworks/routers/glm-5p3-fast"])
    func fireworksAffinity(_ modelId: String) async throws {
        let captured = try await captureRequest(sessionId: "fireworks-session", cBuiltin("fireworks", modelId))
        #expect(captured.header("x-session-affinity") == "fireworks-session")
    }

    @Test("sends Baseten session affinity for built-in catalog models")
    func basetenAffinity() async throws {
        let captured = try await captureRequest(sessionId: "baseten-catalog-session", cBuiltin("baseten", "zai-org/GLM-5.2"))
        #expect(captured.header("x-session-affinity") == "baseten-catalog-session")
        #expect(captured.header("x-client-request-id") == "baseten-catalog-session")
    }

    @Test("uses OpenAI no-session format when configured")
    func openAINoSession() async throws {
        let model = createModel { $0.compat = ["sendSessionAffinityHeaders": true, "sessionAffinityFormat": "openai-nosession"] }
        let captured = try await captureRequest(sessionId: "session-nosession", model)
        #expect(captured.payload["session_id"] == nil)
        #expect(captured.payload["prompt_cache_key"] == "session-nosession")
        #expect(captured.header("session_id") == nil)
        #expect(captured.header("x-client-request-id") == "session-nosession")
        #expect(captured.header("x-session-affinity") == "session-nosession")
        #expect(captured.header("x-session-id") == nil)
    }

    @Test("uses OpenRouter session-affinity header when configured")
    func openRouterFormat() async throws {
        let captured = try await captureRequest(sessionId: "session-proxy", proxyModel(["sendSessionAffinityHeaders": true, "sessionAffinityFormat": "openrouter"]))
        #expect(captured.payload["session_id"] == nil)
        #expect(captured.payload["prompt_cache_key"] == nil)
        #expect(captured.header("x-session-id") == "session-proxy")
        #expect(captured.header("session_id") == nil)
        #expect(captured.header("x-client-request-id") == nil)
        #expect(captured.header("x-session-affinity") == nil)
    }

    @Test("sends OpenRouter session-affinity header by default for built-in OpenRouter models")
    func openRouterDefault() async throws {
        let captured = try await captureRequest(sessionId: "session-openrouter", cBuiltin("openrouter", "auto"))
        #expect(captured.payload["session_id"] == nil)
        #expect(captured.payload["prompt_cache_key"] == nil)
        #expect(captured.header("x-session-id") == "session-openrouter")
        #expect(captured.header("session_id") == nil)
        #expect(captured.header("x-client-request-id") == nil)
        #expect(captured.header("x-session-affinity") == nil)
    }

    @Test("omits OpenRouter session-affinity data when disabled")
    func openRouterDisabled() async throws {
        let model = createModel {
            $0.provider = "openrouter"
            $0.baseUrl = "https://openrouter.ai/api/v1"
            $0.compat = ["sendSessionAffinityHeaders": false]
        }
        let captured = try await captureRequest(sessionId: "session-openrouter", model)
        #expect(captured.payload["session_id"] == nil)
        #expect(captured.payload["prompt_cache_key"] == nil)
        #expect(captured.header("x-session-id") == nil)
    }

    @Test("omits session-affinity headers when cacheRetention is none")
    func omitsAffinityWhenNone() async throws {
        let captured = try await captureRequest(cacheRetention: CacheRetention.none, sessionId: "session-affinity", proxyModel(["sendSessionAffinityHeaders": true]))
        #expect(captured.header("session_id") == nil)
        #expect(captured.header("x-client-request-id") == nil)
        #expect(captured.header("x-session-affinity") == nil)
    }

    @Test("lets explicit headers override generated session-affinity headers")
    func explicitHeadersOverride() async throws {
        let captured = try await captureRequest(
            sessionId: "session-affinity",
            headers: [("session_id", "override-session"), ("x-client-request-id", "override-request"), ("x-session-affinity", "override-affinity")],
            proxyModel(["sendSessionAffinityHeaders": true])
        )
        #expect(captured.header("session_id") == "override-session")
        #expect(captured.header("x-client-request-id") == "override-request")
        #expect(captured.header("x-session-affinity") == "override-affinity")
    }
}
