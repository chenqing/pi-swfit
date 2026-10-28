import Foundation
import Testing
@testable import PiAI

// Port of packages/ai/test/anthropic-auth-token.test.ts
// Swift: upstream mocks `@anthropic-ai/sdk` and inspects the constructor options and `create()` params. Here the real
// SDK runs over a fake `FetchFunction`: `apiKey`/`authToken`/`defaultHeaders` show up as the request's `x-api-key` /
// `Authorization` / other headers, and `params.betas` as the `anthropic-beta` header (and in the `onPayload` params).

private let authSse = [
    "event: message_start\ndata: " + JsonValue.object([
        "type": "message_start",
        "message": ["id": "msg_test", "usage": ["input_tokens": 1, "output_tokens": 0]],
    ]).serialized() + "\n",
    "event: message_delta\ndata: " + JsonValue.object([
        "type": "message_delta",
        "delta": ["stop_reason": "end_turn"],
        "usage": ["output_tokens": 1],
    ]).serialized() + "\n",
    "event: message_stop\ndata: " + JsonValue.object(["type": "message_stop"]).serialized() + "\n",
].joined(separator: "\n")

private let neverAbortedSignal = AbortController().signal

private let authContext = Context(
    systemPrompt: "System prompt.",
    messages: [.user(UserMessage(content: "Hello"))]
)

private let anthropicModel = bModel(
    id: "claude-test",
    name: "Claude Test",
    baseUrl: "https://api.anthropic.com",
    reasoning: false,
    contextWindow: 100_000,
    maxTokens: 4096
)

private var kimiCodingModel: Model {
    var model = anthropicModel
    model.id = "kimi-for-coding"
    model.name = "Kimi For Coding"
    model.provider = "kimi-coding"
    model.baseUrl = "https://api.kimi.com/coding"
    return model
}

/// What upstream's `mockState` records: the request (constructor auth + default headers) and the `create()` params.
private struct Captured {
    var requests: BRequests
    var params: JsonObject?

    var headers: Headers? { requests.last?.headers }
    var betas: [String]? { params?["betas"]?.arrayValue?.compactMap(\.stringValue) }
    var system: [JsonValue]? { requests.lastBody?["system"]?.arrayValue }
}

private func recordingOnPayload(_ box: Locked<JsonObject?>) -> OnPayload {
    { payload, _ in
        box.withLock { $0 = payload.objectValue }
        return nil
    }
}

private func runStream(_ model: Model, _ configure: (inout AnthropicOptions) -> Void) async -> Captured {
    let requests = BRequests()
    let params = Locked<JsonObject?>(nil)
    var options = AnthropicOptions()
    options.fetch = bFetch(authSse, requests: requests)
    options.onPayload = recordingOnPayload(params)
    configure(&options)
    _ = await streamAnthropicMessages(model, normalizeContext(authContext), options).result()
    return Captured(requests: requests, params: params.withLock { $0 })
}

private func runModels(env: [String: String], _ configure: (inout SimpleStreamOptions) -> Void = { _ in }) async -> Captured {
    let models = createModels(CreateModelsOptions(authContext: AuthContext(
        env: { env[$0] },
        fileExists: { _ in false }
    )))
    models.setProvider(anthropicProvider(models: []))
    let requests = BRequests()
    let params = Locked<JsonObject?>(nil)
    var options = SimpleStreamOptions()
    options.fetch = bFetch(authSse, requests: requests)
    options.onPayload = recordingOnPayload(params)
    configure(&options)
    _ = await models.streamSimple(anthropicModel, authContext, options).result()
    return Captured(requests: requests, params: params.withLock { $0 })
}

@Suite("Anthropic auth token env")
struct AnthropicAuthTokenEnvTests {
    @Test("resolves ANTHROPIC_AUTH_TOKEN as a bearer Authorization header")
    func resolvesAuthToken() async throws {
        let env = [
            "ANTHROPIC_AUTH_TOKEN": "auth-token",
            "ANTHROPIC_OAUTH_TOKEN": "oauth-token",
            "ANTHROPIC_API_KEY": "api-key",
        ]
        let auth = try #require(try await anthropicProvider(models: []).auth.apiKey?.resolve(ApiKeyAuthInput(
            ctx: AuthContext(env: { env[$0] }, fileExists: { _ in false }),
            signal: neverAbortedSignal
        )))

        #expect(auth.auth.apiKey == nil)
        #expect(auth.auth.baseUrl == nil)
        #expect(gHeaders(auth.auth.headers) == ["Authorization=Bearer auth-token"])
        #expect(auth.env == nil)
        #expect(auth.source == ANTHROPIC_AUTH_TOKEN_ENV)
    }

    @Test("preserves ANTHROPIC_OAUTH_TOKEN as OAuth-shaped API auth")
    func preservesOAuthToken() async throws {
        let env = [
            "ANTHROPIC_OAUTH_TOKEN": "oauth-token",
            "ANTHROPIC_API_KEY": "api-key",
        ]
        let auth = try #require(try await anthropicProvider(models: []).auth.apiKey?.resolve(ApiKeyAuthInput(
            ctx: AuthContext(env: { env[$0] }, fileExists: { _ in false }),
            signal: neverAbortedSignal
        )))

        #expect(auth.auth.apiKey == "oauth-token")
        #expect(auth.auth.headers == nil)
        #expect(auth.auth.baseUrl == nil)
        #expect(auth.env == nil)
        #expect(auth.source == ANTHROPIC_OAUTH_TOKEN_ENV)
    }

    @Test("uses Authorization headers without OAuth-mode request shaping")
    func authorizationHeaderWithoutOAuthShaping() async throws {
        let captured = await runStream(anthropicModel) { options in
            options.headers = [("Authorization", "Bearer gateway-token")]
        }

        // apiKey: null, authToken: null -> no SDK auth header of its own.
        #expect(captured.headers?.get("x-api-key") == nil)
        #expect(captured.headers?.get("Authorization") == "Bearer gateway-token")
        #expect((captured.betas ?? []).contains("oauth-2025-04-20") == false)
        #expect(captured.system?.count == 1)
        #expect(captured.system?.first?["text"] == "System prompt.")
    }

    @Test("threads authContext ANTHROPIC_AUTH_TOKEN through request headers")
    func threadsAuthContextToken() async throws {
        let captured = await runModels(env: ["ANTHROPIC_AUTH_TOKEN": "ctx-token"])

        #expect(captured.headers?.get("x-api-key") == nil)
        #expect(captured.headers?.get("Authorization") == "Bearer ctx-token")
        #expect((captured.betas ?? []).contains("oauth-2025-04-20") == false)
        #expect(captured.system?.count == 1)
        #expect(captured.system?.first?["text"] == "System prompt.")
    }

    @Test("preserves OAuth request shaping for ANTHROPIC_OAUTH_TOKEN")
    func oauthShapingForOAuthToken() async throws {
        let captured = await runModels(env: ["ANTHROPIC_OAUTH_TOKEN": "sk-ant-oat-test"])

        // apiKey: null, authToken: "sk-ant-oat-test".
        #expect(captured.headers?.get("x-api-key") == nil)
        #expect(captured.headers?.get("Authorization") == "Bearer sk-ant-oat-test")
        #expect((captured.betas ?? []).contains("oauth-2025-04-20"))
    }

    @Test("lets explicit request headers override ANTHROPIC_AUTH_TOKEN")
    func explicitHeadersOverrideAuthToken() async throws {
        let captured = await runModels(env: ["ANTHROPIC_AUTH_TOKEN": "ctx-token"]) { options in
            options.headers = [("Authorization", "Bearer explicit-token")]
        }

        #expect(captured.headers?.get("Authorization") == "Bearer explicit-token")
    }
}

@Suite("Anthropic-compatible user agents")
struct AnthropicCompatibleUserAgentTests {
    @Test("uses pi's User-Agent by default for Anthropic Messages requests")
    func defaultUserAgent() async throws {
        let captured = await runStream(anthropicModel) { $0.apiKey = "anthropic-key" }

        #expect(captured.headers?.get("User-Agent") == getPiUserAgent())
    }

    @Test("lets explicit headers override the default Anthropic Messages User-Agent")
    func explicitUserAgent() async throws {
        let captured = await runStream(kimiCodingModel) { options in
            options.apiKey = "kimi-key"
            options.headers = [("User-Agent", "custom-client")]
        }

        #expect(captured.headers?.get("User-Agent") == "custom-client")
    }

    @Test("preserves explicit Anthropic beta header replacement")
    func betaHeaderReplacement() async throws {
        let captured = await runStream(anthropicModel) { options in
            options.apiKey = "anthropic-key"
            options.headers = [("anthropic-beta", "custom-beta")]
        }

        #expect(captured.betas == ["custom-beta"])
        #expect(captured.headers?.get("anthropic-beta") == "custom-beta")
    }

    @Test("preserves explicit Anthropic beta header suppression")
    func betaHeaderSuppression() async throws {
        let captured = await runStream(anthropicModel) { options in
            options.apiKey = "anthropic-key"
            options.headers = [("anthropic-beta", nil)]
        }

        #expect(captured.params != nil)
        #expect(captured.params?["betas"] == nil)
        #expect(captured.headers?.get("anthropic-beta") == nil)
    }
}
