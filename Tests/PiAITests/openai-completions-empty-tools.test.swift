import Foundation
import Testing
@testable import PiAI

// Port of packages/ai/test/openai-completions-empty-tools.test.ts
// Empty tools arrays must NOT be serialized as `tools: []`: some OpenAI-compatible backends reject them.
// Swift: the upstream mock captures the OpenAI client options (baseURL, defaultHeaders); here the same
// values are read from the request the real SDK sent to the fake fetch.

private func baseModel() -> Model { cOpenAICompletionsModel() }

private func withCloudflareEnv<T>(_ body: () async throws -> T) async rethrows -> T {
    let names = ["CLOUDFLARE_API_KEY", "CLOUDFLARE_ACCOUNT_ID", "CLOUDFLARE_GATEWAY_ID"]
    let saved = names.map { ProcessInfo.processInfo.environment[$0] }
    setenv("CLOUDFLARE_API_KEY", "cf-token", 1)
    setenv("CLOUDFLARE_ACCOUNT_ID", "account-id", 1)
    setenv("CLOUDFLARE_GATEWAY_ID", "gateway-id", 1)
    defer {
        for (name, value) in zip(names, saved) {
            if let value { setenv(name, value, 1) } else { unsetenv(name) }
        }
    }
    return try await body()
}

/// `streamSimple` without an api key (Cloudflare resolves auth from the environment).
/// Swift: compat `streamSimple` dispatches through a builtin `Models` built once, on the first compat call
/// in the process, from the catalog installed at that moment; another suite may make that call before this
/// file's catalog is installed. The same builtin dispatch is therefore run on a fresh `builtinModels()`.
private func runCloudflare(_ model: Model, _ context: Context, _ configure: (inout SimpleStreamOptions) -> Void = { _ in }) async throws -> CRun {
    let server = CFakeServer(chunks: cDefaultChunks)
    let captured = Locked<JsonValue?>(nil)
    var options = SimpleStreamOptions()
    options.fetch = server.fetch
    configure(&options)
    options.onPayload = { params, _ in
        captured.withLock { $0 = params }
        return nil
    }
    let stream = builtinModels().streamSimple(model, context, options)
    var events: [AssistantMessageEvent] = []
    for await event in stream { events.append(event) }
    let result = await stream.result()
    return CRun(payload: captured.current ?? .null, result: result, events: events, server: server)
}

@Suite("openai-completions empty tools handling", .serialized)
struct OpenAICompletionsEmptyToolsTests {
    @Test("omits tools field when context.tools is an empty array")
    func emptyToolsArray() async throws {
        let run = try await cRunSimple(baseModel(), cUserContext("hi", tools: []))
        #expect(!cKeys(run.payload).contains("tools"))
    }

    @Test("omits tools field when context.tools is undefined")
    func undefinedTools() async throws {
        let run = try await cRunSimple(baseModel(), cUserContext("hi"))
        #expect(!cKeys(run.payload).contains("tools"))
    }

    @Test("sends default maxTokens")
    func defaultMaxTokens() async throws {
        let model = baseModel()
        let run = try await cRunSimple(model, cUserContext("hi"))
        #expect(run.payload["max_tokens"] == nil)
        #expect(run.payload["max_completion_tokens"] == .number(Double(model.maxTokens)))
    }

    @Test("sends explicit maxTokens")
    func explicitMaxTokens() async throws {
        let run = try await cRunSimple(baseModel(), cUserContext("hi")) { $0.maxTokens = 1234 }
        #expect(run.payload["max_tokens"] == nil)
        #expect(run.payload["max_completion_tokens"] == 1234)
    }

    @Test("clamps default maxTokens to remaining context")
    func clampsDefaultMaxTokens() async throws {
        var model = baseModel()
        model.contextWindow = 10000
        model.maxTokens = 8000
        let run = try await cRunSimple(model, cUserContext(String(repeating: "x", count: 8000)))
        #expect(run.payload["max_tokens"] == nil)
        #expect(run.payload["max_completion_tokens"] == 3618)
    }

    @Test("clamps explicit maxTokens to remaining context")
    func clampsExplicitMaxTokens() async throws {
        var model = baseModel()
        model.contextWindow = 10000
        model.maxTokens = 8000
        let run = try await cRunSimple(model, cUserContext(String(repeating: "x", count: 8000))) { $0.maxTokens = 7000 }
        #expect(run.payload["max_tokens"] == nil)
        #expect(run.payload["max_completion_tokens"] == 3618)
    }

    @Test("uses conservative OpenAI-compatible fields for Cloudflare AI Gateway /compat models")
    func cloudflareCompatFields() async throws {
        try await withCloudflareEnv {
            let model = cBuiltin("cloudflare-ai-gateway", "workers-ai/@cf/moonshotai/kimi-k2.6")
            let run = try await runCloudflare(model, cUserContext("hi", systemPrompt: "You are helpful.")) {
                $0.maxTokens = 1234
                $0.reasoning = .high
            }
            #expect(run.payload["messages"]?[0]?["role"] == "system")
            #expect(run.payload["max_tokens"] == 1234)
            #expect(run.payload["max_completion_tokens"] == nil)
            #expect(run.payload["reasoning_effort"] == nil)
            #expect(run.payload["store"] == nil)

            let request = try #require(run.server.requests.first)
            #expect(request.url.absoluteString == "https://gateway.ai.cloudflare.com/v1/account-id/gateway-id/compat/chat/completions")
            #expect(request.headers.get("authorization") == nil)
            #expect(request.headers.get("cf-aig-authorization") == "Bearer cf-token")
        }
    }

    @Test("resolves Cloudflare AI Gateway base URL through provider auth")
    func cloudflareBaseUrl() async throws {
        try await withCloudflareEnv {
            let model = cBuiltin("cloudflare-ai-gateway", "workers-ai/@cf/moonshotai/kimi-k2.6")
            let run = try await runCloudflare(model, cUserContext("hi"))
            #expect(run.server.requests.first?.url.absoluteString == "https://gateway.ai.cloudflare.com/v1/account-id/gateway-id/compat/chat/completions")
        }
    }

    @Test("preserves inline upstream Authorization for Cloudflare AI Gateway BYOK requests")
    func cloudflareByok() async throws {
        try await withCloudflareEnv {
            // Swift: the catalog's gpt-5.1 is an openai-responses model; this group's workspace has only the
            // Chat Completions client, so the same Cloudflare BYOK auth is checked over Chat Completions.
            var model = cBuiltin("cloudflare-ai-gateway", "gpt-5.1")
            model.api = "openai-completions"
            let run = try await runCloudflare(model, cUserContext("hi")) { $0.headers = [("Authorization", "Bearer upstream-token")] }
            let request = try #require(run.server.requests.first)
            #expect(request.headers.get("authorization") == "Bearer upstream-token")
            #expect(request.headers.get("cf-aig-authorization") == "Bearer cf-token")
        }
    }

    @Test("sends session affinity headers for Workers AI through Cloudflare AI Gateway")
    func cloudflareSessionAffinity() async throws {
        try await withCloudflareEnv {
            let model = cBuiltin("cloudflare-ai-gateway", "workers-ai/@cf/moonshotai/kimi-k2.6")
            let run = try await runCloudflare(model, cUserContext("hi")) { $0.sessionId = "session-1" }
            let request = try #require(run.server.requests.first)
            #expect(request.headers.get("session_id") == "session-1")
            #expect(request.headers.get("x-client-request-id") == "session-1")
            #expect(request.headers.get("x-session-affinity") == "session-1")
        }
    }

    @Test("still emits tools: [] for Anthropic/LiteLLM proxy when conversation has tool history")
    func toolHistoryKeepsEmptyTools() async throws {
        let messages = cMessages(#"""
        [{"role":"user","content":"use the tool"},
         {"role":"assistant","content":[{"type":"toolCall","id":"t1","name":"noop","arguments":{}}],"stopReason":"toolUse","api":"openai-completions","provider":"openai","model":"gpt-4o-mini"},
         {"role":"toolResult","toolCallId":"t1","toolName":"noop","content":[{"type":"text","text":"done"}],"isError":false}]
        """#)
        let run = try await cRunSimple(baseModel(), Context(messages: messages, tools: []))
        #expect(run.payload["tools"] == [])
    }
}
