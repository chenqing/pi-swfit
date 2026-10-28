import Foundation
import Testing
@testable import PiAI

// Port of packages/ai/test/anthropic-thinking-disable.test.ts
// Not ported: "Anthropic thinking disable E2E" / "disables thinking for Claude reasoning models" (live Anthropic API, needs ANTHROPIC_API_KEY)

/// Mirrors the generated catalog entry for `anthropic/<id>` (fields the payload depends on), with the
/// upstream test's payload-capture baseUrl.
private func catalogModel(_ id: String, thinkingLevelMap: ThinkingLevelMap? = nil, compat: JsonObject? = nil) -> Model {
    var model = bModel(id: id, provider: "anthropic", baseUrl: "http://127.0.0.1:9", reasoning: true, maxTokens: 64000, compat: compat)
    model.thinkingLevelMap = thinkingLevelMap
    return model
}

// claude-sonnet-4-5: budget-based thinking, no compat overrides.
private let claudeSonnet45 = catalogModel("claude-sonnet-4-5")
// claude-opus-4-6: adaptive thinking, `max` effort.
private let claudeOpus46 = catalogModel("claude-opus-4-6", thinkingLevelMap: [.max: "max"], compat: ["forceAdaptiveThinking": true])
// claude-opus-4-8: adaptive thinking, xhigh/max efforts, no temperature, mid-conversation system messages.
private let claudeOpus48 = catalogModel(
    "claude-opus-4-8",
    thinkingLevelMap: [.xhigh: "xhigh", .max: "max"],
    compat: ["supportsMidConvoSystemMessages": true, "supportsMidConvoToolChanges": true, "forceAdaptiveThinking": true, "supportsTemperature": false]
)
// claude-fable-5: adaptive thinking that cannot be turned off.
private let claudeFable5 = catalogModel(
    "claude-fable-5",
    thinkingLevelMap: [.off: String?.none, .xhigh: "xhigh", .max: "max"],
    compat: ["supportsMidConvoSystemMessages": true, "supportsMidConvoToolChanges": true, "forceAdaptiveThinking": true]
)
// claude-sonnet-5: adaptive thinking, xhigh/max efforts.
private let claudeSonnet5 = catalogModel("claude-sonnet-5", thinkingLevelMap: [.xhigh: "xhigh", .max: "max"], compat: ["forceAdaptiveThinking": true])

private func capture(_ model: Model, reasoning: ThinkingLevel? = nil) async throws -> JsonObject {
    var options = SimpleStreamOptions()
    options.reasoning = reasoning
    return try #require(await bCapturePayload(model, bUserContext("Hello"), options), "Expected payload to be captured before request failure")
}

@Suite("Anthropic thinking disable payload")
struct AnthropicThinkingDisablePayloadTests {
    @Test("sends thinking.type=disabled for budget-based reasoning models when thinking is off")
    func budgetModelOff() async throws {
        let payload = try await capture(claudeSonnet45)
        #expect(payload["thinking"] == ["type": "disabled"])
        #expect(payload["output_config"] == nil)
    }

    @Test("sends thinking.type=disabled for adaptive reasoning models when thinking is off")
    func adaptiveModelOff() async throws {
        let payload = try await capture(claudeOpus46)
        #expect(payload["thinking"] == ["type": "disabled"])
        #expect(payload["output_config"] == nil)
    }

    @Test("sends thinking.type=disabled for Claude Opus 4.8 when thinking is off")
    func opus48Off() async throws {
        let payload = try await capture(claudeOpus48)
        #expect(payload["thinking"] == ["type": "disabled"])
        #expect(payload["output_config"] == nil)
    }

    @Test("omits thinking.type=disabled for Claude Fable 5 when thinking is off")
    func fable5Off() async throws {
        let payload = try await capture(claudeFable5)
        #expect(payload["thinking"] == nil)
        #expect(payload["output_config"] == nil)
    }

    @Test("uses adaptive thinking for Claude Opus 4.8 when reasoning is enabled")
    func opus48High() async throws {
        let payload = try await capture(claudeOpus48, reasoning: .high)
        #expect(payload["thinking"] == ["type": "adaptive", "display": "summarized"])
        #expect(payload["output_config"] == ["effort": "high"])
    }

    @Test("uses adaptive thinking for Claude Sonnet 5 when reasoning is enabled")
    func sonnet5High() async throws {
        let payload = try await capture(claudeSonnet5, reasoning: .high)
        #expect(payload["thinking"] == ["type": "adaptive", "display": "summarized"])
        #expect(payload["output_config"] == ["effort": "high"])
    }

    @Test("maps xhigh reasoning to effort=xhigh for Claude Opus 4.8")
    func opus48Xhigh() async throws {
        let payload = try await capture(claudeOpus48, reasoning: .xhigh)
        #expect(payload["thinking"] == ["type": "adaptive", "display": "summarized"])
        #expect(payload["output_config"] == ["effort": "xhigh"])
    }
}
