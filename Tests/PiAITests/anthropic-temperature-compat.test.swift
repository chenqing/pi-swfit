import Foundation
import Testing
@testable import PiAI

// Port of packages/ai/test/anthropic-temperature-compat.test.ts

private func makeCustomModel(_ compat: JsonObject? = nil) -> Model {
    bModel(
        id: "vendor--claude-opus-4-7",
        name: "Vendor Proxy Opus 4.7",
        provider: "vendor-proxy",
        baseUrl: "http://127.0.0.1:9",
        reasoning: true,
        contextWindow: 200000,
        maxTokens: 32000,
        compat: compat
    )
}

/// Mirrors the generated catalog entry for `anthropic/<id>` (compat flags only), with the upstream
/// test's payload-capture baseUrl.
private func catalogModel(_ id: String, _ compat: JsonObject) -> Model {
    bModel(id: id, provider: "anthropic", baseUrl: "http://127.0.0.1:9", reasoning: true, compat: compat)
}

private let claudeOpus47 = catalogModel("claude-opus-4-7", ["forceAdaptiveThinking": true, "supportsTemperature": false])
private let claudeOpus48 = catalogModel(
    "claude-opus-4-8",
    ["supportsMidConvoSystemMessages": true, "supportsMidConvoToolChanges": true, "forceAdaptiveThinking": true, "supportsTemperature": false]
)
private let claudeOpus46 = catalogModel("claude-opus-4-6", ["forceAdaptiveThinking": true])
private let claudeSonnet46 = catalogModel("claude-sonnet-4-6", ["forceAdaptiveThinking": true])

private func capture(_ model: Model, temperature: Double) async throws -> JsonObject {
    var options = SimpleStreamOptions()
    options.temperature = temperature
    return try #require(await bCapturePayload(model, bUserContext("Hello"), options), "Expected payload to be captured before request failure")
}

@Suite("Anthropic temperature compatibility")
struct AnthropicTemperatureCompatTests {
    @Test("omits temperature for Claude Opus 4.7")
    func opus47() async throws {
        #expect(try await capture(claudeOpus47, temperature: 0)["temperature"] == nil)
    }

    @Test("omits temperature for Claude Opus 4.8")
    func opus48() async throws {
        #expect(try await capture(claudeOpus48, temperature: 0)["temperature"] == nil)
    }

    @Test("omits default temperature for Claude Opus 4.7")
    func opus47Default() async throws {
        #expect(try await capture(claudeOpus47, temperature: 1)["temperature"] == nil)
    }

    @Test("keeps temperature for Claude Opus 4.6")
    func opus46() async throws {
        #expect(try await capture(claudeOpus46, temperature: 0)["temperature"] == 0)
    }

    @Test("keeps temperature for Claude Sonnet 4.6")
    func sonnet46() async throws {
        #expect(try await capture(claudeSonnet46, temperature: 0)["temperature"] == 0)
    }

    @Test("omits temperature for custom models with supportsTemperature disabled")
    func customDisabled() async throws {
        #expect(try await capture(makeCustomModel(["supportsTemperature": false]), temperature: 0)["temperature"] == nil)
    }
}
