import Foundation
import Testing
@testable import PiAI

// Port of packages/ai/test/anthropic-force-adaptive-thinking.test.ts

private func makeCustomModel(_ compat: JsonObject? = nil) -> Model {
    // Id intentionally does not match any built-in adaptive substring. This
    // mirrors corporate proxy schemes such as `anthropic--claude-opus-latest`.
    bModel(
        id: "vendor--claude-opus-latest",
        name: "Vendor Proxy Opus Latest",
        provider: "vendor-proxy",
        baseUrl: "http://127.0.0.1:9",
        reasoning: true,
        contextWindow: 200000,
        maxTokens: 32000,
        compat: compat
    )
}

/// Mirrors the generated catalog entry for `anthropic/<id>` (fields the payload depends on), with the
/// upstream test's payload-capture baseUrl.
private func catalogModel(_ id: String, thinkingLevelMap: ThinkingLevelMap, compat: JsonObject) -> Model {
    var model = bModel(id: id, provider: "anthropic", baseUrl: "http://127.0.0.1:9", reasoning: true, maxTokens: 128000, compat: compat)
    model.thinkingLevelMap = thinkingLevelMap
    return model
}

private let claudeFable5 = catalogModel(
    "claude-fable-5",
    thinkingLevelMap: [.off: String?.none, .xhigh: "xhigh", .max: "max"],
    compat: ["supportsMidConvoSystemMessages": true, "supportsMidConvoToolChanges": true, "forceAdaptiveThinking": true]
)
private let claudeOpus48 = catalogModel(
    "claude-opus-4-8",
    thinkingLevelMap: [.xhigh: "xhigh", .max: "max"],
    compat: ["supportsMidConvoSystemMessages": true, "supportsMidConvoToolChanges": true, "forceAdaptiveThinking": true, "supportsTemperature": false]
)

private func capture(_ model: Model, reasoning: ThinkingLevel? = nil) async throws -> JsonObject {
    var options = SimpleStreamOptions()
    options.reasoning = reasoning
    return try #require(await bCapturePayload(model, bUserContext("Hello"), options), "Expected payload to be captured before request failure")
}

@Suite("Anthropic forceAdaptiveThinking compat override")
struct AnthropicForceAdaptiveThinkingTests {
    @Test("sends legacy thinking payload for custom model ids by default")
    func legacyByDefault() async throws {
        let payload = try await capture(makeCustomModel(), reasoning: .medium)
        #expect(payload["thinking"]?["type"] == "enabled")
        #expect(payload["output_config"] == nil)
    }

    @Test("sends adaptive thinking payload when compat.forceAdaptiveThinking is true")
    func forcedAdaptive() async throws {
        let payload = try await capture(makeCustomModel(["forceAdaptiveThinking": true]), reasoning: .medium)
        #expect(payload["thinking"] == ["type": "adaptive", "display": "summarized"])
        #expect(payload["output_config"] == ["effort": "medium"])
    }

    @Test("uses adaptive thinking with native xhigh effort for Claude Fable 5")
    func fable5Xhigh() async throws {
        let payload = try await capture(claudeFable5, reasoning: .xhigh)
        #expect(payload["thinking"] == ["type": "adaptive", "display": "summarized"])
        #expect(payload["output_config"] == ["effort": "xhigh"])
    }

    @Test("allows built-in adaptive models to opt out with compat.forceAdaptiveThinking false")
    func optOut() async throws {
        var model = claudeOpus48
        model.compat = ["forceAdaptiveThinking": false]
        let payload = try await capture(model, reasoning: .medium)
        #expect(payload["thinking"]?["type"] == "enabled")
        #expect(payload["output_config"] == nil)
    }

    @Test("preserves thinking.type=disabled when reasoning is off regardless of override")
    func offStaysDisabled() async throws {
        let payload = try await capture(makeCustomModel(["forceAdaptiveThinking": true]))
        #expect(payload["thinking"] == ["type": "disabled"])
        #expect(payload["output_config"] == nil)
    }
}
