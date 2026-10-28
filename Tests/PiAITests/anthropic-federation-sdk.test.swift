import Foundation
import Testing
@testable import PiAI

// Port of packages/ai/test/anthropic-federation-sdk.test.ts, plus the SDK-level cases of
// packages/ai/test/anthropic-federation.test.ts that anthropic-federation.test.swift leaves out.
// Runs the real Anthropic SDK against a fake fetch to check how often the
// workload identity federation token exchange happens.
// https://github.com/earendil-works/pi/issues/10177
//
// Swift: every test passes its own `fetch`, so the adapter's process-wide federation client cache never serves
// a client across tests (a cached client only matches requests without a custom fetch).

private struct RecordedRequest: Equatable {
    var path: String
    var authorization: String?
}

private final class FederationRequests: @unchecked Sendable {
    private let lock = NSLock()
    private var _requests: [FetchRequest] = []

    func add(_ request: FetchRequest) {
        lock.lock()
        _requests.append(request)
        lock.unlock()
    }

    var all: [FetchRequest] {
        lock.lock()
        defer { lock.unlock() }
        return _requests
    }

    var recorded: [RecordedRequest] {
        all.map { RecordedRequest(path: $0.url.path, authorization: $0.headers.get("authorization")) }
    }

    func requests(to path: String) -> [FetchRequest] { all.filter { $0.url.path == path } }

    func body(_ request: FetchRequest) -> JsonObject? {
        (try? JsonValue.parse(String(decoding: request.body ?? Data(), as: UTF8.self)))?.objectValue
    }
}

private let federationSse = [
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

private func createFetch(_ requests: FederationRequests) -> FetchFunction {
    { request in
        requests.add(request)
        if request.url.path == "/v1/oauth/token" {
            return FetchResponse(
                status: 200,
                headers: Headers([("content-type", "application/json")]),
                body: .data(Data(JsonValue.object(["access_token": "federated-token", "expires_in": 3600]).serialized().utf8))
            )
        }
        return FetchResponse(
            status: 200,
            headers: Headers([("content-type", "text/event-stream")]),
            body: .data(Data(federationSse.utf8))
        )
    }
}

private let federationContext = normalizeContext(Context(
    systemPrompt: "System prompt.",
    messages: [.user(UserMessage(content: "Hello"))]
))

private let anthropicModel = bModel(
    id: "claude-test",
    name: "Claude Test",
    baseUrl: "https://api.anthropic.com",
    reasoning: false,
    contextWindow: 100_000,
    maxTokens: 4096
)

/// `beforeAll`: a temp dir holding `identity.jwt` (one per test, so tests stay independent).
private final class IdentityTokenFile {
    let directory: URL
    let path: String

    init() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("pi-anthropic-federation-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let file = directory.appendingPathComponent("identity.jwt")
        try "header.payload.signature".write(to: file, atomically: true, encoding: .utf8)
        path = file.path
    }

    deinit { try? FileManager.default.removeItem(at: directory) }
}

private func streamOptions(env: ProviderEnv? = nil, fetch: @escaping FetchFunction) -> AnthropicOptions {
    var options = AnthropicOptions()
    options.env = env
    options.fetch = fetch
    return options
}

// Both suites share the adapter's process-wide federation client cache (upstream: module state, isolated per
// test file by vitest), so they run serially with respect to each other.
@Suite(.serialized)
struct AnthropicFederationSdkSerial {}

extension AnthropicFederationSdkSerial {
@Suite("Anthropic workload identity federation with the SDK")
struct AnthropicFederationSdkTests {
    @Test("exchanges the identity token once across requests")
    func exchangesOnce() async throws {
        let identity = try IdentityTokenFile()
        let federationEnv = [
            "ANTHROPIC_FEDERATION_RULE_ID": "fdrl_test",
            "ANTHROPIC_ORGANIZATION_ID": "org-test",
            "ANTHROPIC_IDENTITY_TOKEN_FILE": identity.path,
        ]
        let requests = FederationRequests()
        let fetch = createFetch(requests)

        for _ in 0..<3 {
            let message = await streamAnthropicMessages(anthropicModel, federationContext, streamOptions(env: federationEnv, fetch: fetch)).result()
            #expect(message.stopReason == .stop)
        }

        #expect(requests.requests(to: "/v1/oauth/token").count == 1)
        let messageRequests = requests.recorded.filter { $0.path == "/v1/messages" }
        #expect(messageRequests.count == 3)
        for request in messageRequests {
            #expect(request.authorization == "Bearer federated-token")
        }
    }

    @Test("does not run the SDK credential chain for header-owned auth")
    func headerOwnedAuthSkipsCredentialChain() async throws {
        let identity = try IdentityTokenFile()
        // Swift: upstream stubs the federation variables into the process env (`vi.stubEnv`); mutating the process
        // env would leak into parallel tests, so they travel as provider env instead.
        let federationEnv = [
            "ANTHROPIC_FEDERATION_RULE_ID": "fdrl_test",
            "ANTHROPIC_ORGANIZATION_ID": "org-test",
            "ANTHROPIC_IDENTITY_TOKEN_FILE": identity.path,
        ]
        let requests = FederationRequests()
        var options = streamOptions(env: federationEnv, fetch: createFetch(requests))
        options.headers = [("Authorization", "Bearer auth-token")]

        let message = await streamAnthropicMessages(anthropicModel, federationContext, options).result()

        #expect(message.stopReason == .stop)
        #expect(requests.recorded == [RecordedRequest(path: "/v1/messages", authorization: "Bearer auth-token")])
    }
}

// The SDK-level cases of anthropic-federation.test.ts. Upstream mocks the SDK and checks the constructor's
// `config` option; here the SDK performs the exchange and the config shows up in the jwt-bearer request body.
}

extension AnthropicFederationSdkSerial {
@Suite("Anthropic workload identity federation (SDK config)")
struct AnthropicFederationSdkConfigTests {
    private static func federationEnv(_ identity: IdentityTokenFile) -> [String: String] {
        [
            "ANTHROPIC_FEDERATION_RULE_ID": "fdrl_test",
            "ANTHROPIC_ORGANIZATION_ID": "org-test",
            "ANTHROPIC_SERVICE_ACCOUNT_ID": "svac_test",
            "ANTHROPIC_IDENTITY_TOKEN_FILE": identity.path,
        ]
    }

    /// `expectedConfig` as the SDK sends it in the token exchange (`workspace_id: undefined` is omitted).
    private static let expectedExchangeBody: JsonObject = [
        "grant_type": "urn:ietf:params:oauth:grant-type:jwt-bearer",
        "assertion": "header.payload.signature",
        "federation_rule_id": "fdrl_test",
        "organization_id": "org-test",
        "service_account_id": "svac_test",
    ]

    @Test("treats ANTHROPIC_SERVICE_ACCOUNT_ID as optional, like the SDK")
    func serviceAccountOptional() async throws {
        let identity = try IdentityTokenFile()
        var partial = Self.federationEnv(identity)
        partial["ANTHROPIC_SERVICE_ACCOUNT_ID"] = nil
        let requests = FederationRequests()

        _ = await streamAnthropicMessages(anthropicModel, federationContext, streamOptions(env: partial, fetch: createFetch(requests))).result()

        let exchange = try #require(requests.requests(to: "/v1/oauth/token").first)
        var expected = Self.expectedExchangeBody
        expected["service_account_id"] = nil
        #expect(requests.body(exchange) == expected)
    }

    @Test("hands the SDK a federation config instead of a key")
    func handsFederationConfig() async throws {
        let identity = try IdentityTokenFile()
        let requests = FederationRequests()
        let params = Locked<JsonObject?>(nil)
        var options = streamOptions(env: Self.federationEnv(identity), fetch: createFetch(requests))
        options.onPayload = { payload, _ in
            params.withLock { $0 = payload.objectValue }
            return nil
        }

        _ = await streamAnthropicMessages(anthropicModel, federationContext, options).result()

        let exchange = try #require(requests.requests(to: "/v1/oauth/token").first)
        #expect(requests.body(exchange) == Self.expectedExchangeBody)
        let message = try #require(requests.requests(to: "/v1/messages").first)
        // apiKey: null, authToken: null, and no Authorization default header: the only auth is the SDK's federated token.
        #expect(message.headers.get("x-api-key") == nil)
        #expect(message.headers.get("authorization") == "Bearer federated-token")
        // `params.betas`: pi does not request OAuth shaping (the SDK itself adds its oauth beta for federated tokens).
        let betas = params.withLock { $0 }?["betas"]?.arrayValue?.compactMap(\.stringValue) ?? []
        #expect(betas.contains("oauth-2025-04-20") == false)
    }

    @Test("threads authContext federation variables through Models")
    func threadsAuthContext() async throws {
        let identity = try IdentityTokenFile()
        let env = Self.federationEnv(identity)
        let models = createModels(CreateModelsOptions(authContext: AuthContext(
            env: { env[$0] },
            fileExists: { _ in false }
        )))
        models.setProvider(anthropicProvider(models: []))
        let requests = FederationRequests()
        var options = SimpleStreamOptions()
        options.fetch = createFetch(requests)

        _ = await models.streamSimple(anthropicModel, Context(
            systemPrompt: "System prompt.",
            messages: [.user(UserMessage(content: "Hello"))]
        ), options).result()

        let exchange = try #require(requests.requests(to: "/v1/oauth/token").first)
        #expect(requests.body(exchange) == Self.expectedExchangeBody)
        let message = try #require(requests.requests(to: "/v1/messages").first)
        #expect(message.headers.get("x-api-key") == nil)
    }

    @Test("lets an explicit API key win over federation env")
    func explicitKeyWins() async throws {
        let identity = try IdentityTokenFile()
        let requests = FederationRequests()
        var options = streamOptions(env: Self.federationEnv(identity), fetch: createFetch(requests))
        options.apiKey = "explicit-key"

        _ = await streamAnthropicMessages(anthropicModel, federationContext, options).result()

        #expect(requests.requests(to: "/v1/oauth/token").isEmpty)
        let message = try #require(requests.requests(to: "/v1/messages").first)
        #expect(message.headers.get("x-api-key") == "explicit-key")
    }

    @Test("does not federate other anthropic-messages providers")
    func otherProvidersNotFederated() async throws {
        let identity = try IdentityTokenFile()
        var kimi = anthropicModel
        kimi.provider = "kimi-coding"
        kimi.baseUrl = "https://api.kimi.com/coding"
        let requests = FederationRequests()

        let message = await streamAnthropicMessages(
            kimi,
            federationContext,
            streamOptions(env: Self.federationEnv(identity), fetch: createFetch(requests))
        ).result()

        #expect(message.stopReason == .error)
        // No client was constructed, so nothing was fetched.
        #expect(requests.all.isEmpty)
    }
}
}
