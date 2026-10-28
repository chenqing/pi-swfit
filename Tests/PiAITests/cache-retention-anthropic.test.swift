import Foundation
import Testing
@testable import PiAI

// Port of the "Anthropic Provider" cases of packages/ai/test/cache-retention.test.ts
// PI_CACHE_RETENTION is passed through `options.env` instead of `process.env` (tests run in parallel).
// The two upstream cases gated on ANTHROPIC_API_KEY only need a key for the registry `stream()` call: the
// payload is captured and the request aborted before any network I/O, so they are ported with a fake key
// against `streamAnthropicMessages` directly.
// Not ported: the "OpenAI Responses Provider" and "OpenAI Completions Provider" cases (other adapters).

// Mirrors the generated catalog entry for anthropic/claude-haiku-4-5 (fields the payload depends on).
private let claudeHaiku45: Model = {
    var model = bModel(
        id: "claude-haiku-4-5",
        provider: "anthropic",
        baseUrl: "https://api.anthropic.com",
        reasoning: true,
        cost: ModelCost(input: 1, output: 5, cacheRead: 0.1, cacheWrite: 1.25),
        maxTokens: 64000
    )
    model.promptCache = ModelPromptCache(short: 300, long: 3600)
    return model
}()

private let context = bUserContext("Hello", systemPrompt: "You are a helpful assistant.")

private func capture(_ model: Model, cacheRetention: CacheRetention? = nil, env: ProviderEnv? = nil) async throws -> JsonObject {
    var options = AnthropicOptions()
    options.apiKey = "fake-key"
    options.cacheRetention = cacheRetention
    options.env = env
    return try #require(await bCaptureAnthropicPayload(model, context, options))
}

@Suite("Cache Retention (PI_CACHE_RETENTION) - Anthropic Provider")
struct CacheRetentionAnthropicTests {
    @Test("should use default cache TTL (no ttl field) when PI_CACHE_RETENTION is not set")
    func defaultTtl() async throws {
        let payload = try await capture(claudeHaiku45)
        // System prompt should have cache_control without ttl
        let system = try #require(payload["system"])
        #expect(system[0]?["cache_control"] == ["type": "ephemeral"])
    }

    @Test("should use 1h cache TTL when PI_CACHE_RETENTION=long")
    func envLong() async throws {
        let payload = try await capture(claudeHaiku45, env: ["PI_CACHE_RETENTION": "long"])
        // System prompt should have cache_control with ttl: "1h"
        let system = try #require(payload["system"])
        #expect(system[0]?["cache_control"] == ["type": "ephemeral", "ttl": "1h"])
    }

    @Test("should add ttl for non-api.anthropic.com baseUrl by default")
    func proxyTtl() async throws {
        var proxyModel = claudeHaiku45
        proxyModel.baseUrl = "https://my-proxy.example.com/v1"
        let payload = try await capture(proxyModel, env: ["PI_CACHE_RETENTION": "long"])
        #expect(payload["system"]?[0]?["cache_control"] == ["type": "ephemeral", "ttl": "1h"])
    }

    @Test("should omit ttl when supportsLongCacheRetention is false")
    func compatNoLong() async throws {
        var proxyModel = claudeHaiku45
        proxyModel.baseUrl = "https://my-proxy.example.com/v1"
        proxyModel.compat = ["supportsLongCacheRetention": false]
        let payload = try await capture(proxyModel, cacheRetention: .long)
        #expect(payload["system"]?[0]?["cache_control"] == ["type": "ephemeral"])
    }

    @Test("should omit cache_control when cacheRetention is none")
    func none() async throws {
        let payload = try await capture(claudeHaiku45, cacheRetention: CacheRetention.none)
        let system = try #require(payload["system"]?[0])
        #expect(system["cache_control"] == nil)
    }

    @Test("should add cache_control to string user messages")
    func stringUserMessage() async throws {
        let payload = try await capture(claudeHaiku45)
        let lastMessage = try #require(payload["messages"]?.arrayValue?.last)
        let content = try #require(lastMessage["content"]?.arrayValue)
        let lastBlock = try #require(content.last)
        #expect(lastBlock["cache_control"] == ["type": "ephemeral"])
    }

    @Test("should set 1h cache TTL when cacheRetention is long")
    func optionLong() async throws {
        let payload = try await capture(claudeHaiku45, cacheRetention: .long)
        #expect(payload["system"]?[0]?["cache_control"] == ["type": "ephemeral", "ttl": "1h"])
    }
}
