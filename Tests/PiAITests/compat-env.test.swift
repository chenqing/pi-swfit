import Foundation
import Testing
@testable import PiAI

// Port of packages/ai/test/compat-env.test.ts

private let model = Model(
    id: "test-model",
    name: "Test Model",
    api: "openai-responses",
    provider: "custom-openai",
    baseUrl: "https://example.test/v1",
    reasoning: false,
    input: ["text"],
    cost: ModelCost(input: 0, output: 0, cacheRead: 0, cacheWrite: 0),
    contextWindow: 128000,
    maxTokens: 4096
)

@Suite("compat legacy API fallback", .serialized)
struct CompatEnvTests {
    @Test("dispatches unknown providers through the legacy API registry")
    func dispatchesUnknownProviders() async throws {
        defer { resetApiProviders() }
        let capturedApiKey = Locked<String?>(nil)
        let respond: StreamFunction = { model, _, options in
            capturedApiKey.withLock { $0 = options?.apiKey }
            return gRespond(model)
        }
        registerApiProvider(ApiProvider(api: "openai-responses", stream: respond, streamSimple: respond))

        var options = StreamOptions()
        options.apiKey = "request-key"
        _ = try await complete(model, gUserContext(), options)

        #expect(capturedApiKey.current == "request-key")
    }

    @Test("rejects a model whose api does not match the registered provider")
    func mismatchedApi() throws {
        defer { resetApiProviders() }
        let respond: StreamFunction = { model, _, _ in gRespond(model) }
        registerApiProvider(ApiProvider(api: "openai-responses", stream: respond, streamSimple: respond))
        let provider = try #require(getApiProvider("openai-responses"))
        var other = model
        other.api = "openai-completions"
        #expect(throws: PiError("Mismatched api: openai-completions expected openai-responses")) {
            _ = try provider.stream(other, normalizeContext(gUserContext()), nil)
        }
    }

    @Test("unregisters providers by source id and restores builtins on reset")
    func unregisterAndReset() throws {
        defer { resetApiProviders() }
        let respond: StreamFunction = { model, _, _ in gRespond(model) }
        let builtin = try #require(getApiProvider("anthropic-messages"))
        registerApiProvider(ApiProvider(api: "custom-api", stream: respond, streamSimple: respond), "source-1")
        #expect(getApiProvider("custom-api") != nil)
        unregisterApiProviders("source-1")
        #expect(getApiProvider("custom-api") == nil)
        #expect(getApiProvider("anthropic-messages") === builtin)

        var unknown = model
        unknown.api = "no-such-api"
        #expect(throws: PiError("No API provider registered for api: no-such-api")) {
            _ = try streamSimple(unknown, gUserContext())
        }
    }
}
