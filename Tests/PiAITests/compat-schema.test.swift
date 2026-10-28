// Port of packages/ai/test/compat-schema.test.ts
//
// Upstream checks TypeBox `Compile(Schema).Default({})`; the Swift port exposes schema defaults as each compat
// struct's static `defaults`.

import Testing
@testable import PiAI

@Suite("compatibility schemas")
struct CompatSchemaTests {
    // Not ported: "preserves property types in the provider superset" — a TypeScript type-level assertion on
    // ProviderCompatSchema, which is not ported (models.json schema generation belongs to models.ts).

    @Test("preserves API-specific defaults")
    func apiSpecificDefaults() {
        let completionsDefaults = OpenAICompletionsCompat.defaults.json
        #expect(!completionsDefaults.contains("thinkingFormat"))
        #expect(!completionsDefaults.contains("supportsLongCacheRetention"))
        #expect(OpenAIResponsesCompat.defaults.json["supportsDeveloperRole"] == true)
        let anthropicDefaults = AnthropicMessagesCompat.defaults.json
        #expect(!anthropicDefaults.contains("sendSessionAffinityHeaders"))
        #expect(anthropicDefaults["supportsLongCacheRetention"] == true)
        // Not ported: BedrockCompatSchema defaults (Bedrock compat is not ported).
    }

    // Not ported: "does not assign API-specific defaults to the provider superset" — ProviderCompatSchema is not ported.

    @Test("parses compat JSON leniently and round-trips unknown keys")
    func parsesCompatJson() {
        let json: JsonObject = [
            "supportsStore": false,
            "maxTokensField": "max_tokens",
            "thinkingFormat": "qwen-chat-template",
            "sessionAffinityFormat": "bogus",
            "chatTemplateKwargs": ["enable_thinking": ["$var": "thinking.enabled"], "temperature": 0.5],
            "openRouterRouting": ["only": ["anthropic"], "sort": ["by": "price", "partition": nil], "preferred_min_throughput": 10],
            "customField": "kept",
        ]
        let compat = OpenAICompletionsCompat(json: json)
        #expect(compat.supportsStore == false)
        #expect(compat.maxTokensField == .maxTokens)
        #expect(compat.thinkingFormat == .qwenChatTemplate)
        #expect(compat.sessionAffinityFormat == nil)
        #expect(compat.chatTemplateKwargs?.first?.1 == .variable(.thinkingEnabled, omitWhenOff: nil))
        #expect(compat.openRouterRouting?.only == ["anthropic"])
        #expect(compat.openRouterRouting?.sort == .object(by: "price", partition: .some(nil)))
        #expect(compat.openRouterRouting?.preferred_min_throughput == .number(10))
        #expect(compat.extra["customField"] == "kept")

        var expected = json
        expected["sessionAffinityFormat"] = nil
        #expect(JsonValue.object(compat.json) == .object(expected))
    }

    @Test("drops invalid Anthropic fallback models")
    func anthropicFallbackModels() {
        let cost: JsonValue = ["input": 1, "output": 2, "cacheRead": 0.1, "cacheWrite": 1.25]
        let valid = AnthropicMessagesCompat(json: [
            "allowedFallbackModels": [["provider": "anthropic", "model": "claude", "cost": cost]],
        ])
        #expect(valid.allowedFallbackModels?.first?.model == "claude")
        let empty = AnthropicMessagesCompat(json: [
            "allowedFallbackModels": [["provider": "", "model": "claude", "cost": cost]],
        ])
        #expect(empty.allowedFallbackModels == nil)
        let tooMany = AnthropicMessagesCompat(json: [
            "allowedFallbackModels": .array(Array(repeating: ["provider": "a", "model": "b", "cost": cost], count: 4)),
        ])
        #expect(tooMany.allowedFallbackModels == nil)
    }
}
