import Foundation
import Testing
@testable import PiAI

// Port of packages/ai/test/anthropic-cache-write-1h-cost.test.ts
// The upstream fake `client` (whose `beta.messages.create().asResponse()` returns the SSE response) is
// replaced by a fake `fetch` answering with the same SSE body.

private func eventsWithCacheCreation(_ cacheCreation: JsonObject?) -> [(event: String, data: JsonValue)] {
    var startUsage: JsonObject = [
        "input_tokens": 100,
        "output_tokens": 0,
        "cache_read_input_tokens": 0,
        "cache_creation_input_tokens": 1_000_000,
    ]
    if let cacheCreation { startUsage["cache_creation"] = .object(cacheCreation) }
    return [
        ("message_start", ["type": "message_start", "message": ["id": "msg_test", "usage": .object(startUsage)]]),
        ("content_block_start", ["type": "content_block_start", "index": 0, "content_block": ["type": "text", "text": ""]]),
        ("content_block_delta", ["type": "content_block_delta", "index": 0, "delta": ["type": "text_delta", "text": "Hi"]]),
        ("content_block_stop", ["type": "content_block_stop", "index": 0]),
        ("message_delta", [
            "type": "message_delta",
            "delta": ["stop_reason": "end_turn"],
            "usage": [
                "input_tokens": 100,
                "output_tokens": 5,
                "cache_read_input_tokens": 0,
                "cache_creation_input_tokens": 1_000_000,
            ],
        ]),
        ("message_stop", ["type": "message_stop"]),
    ]
}

// claude-opus-4-8: input 5, cacheWrite (5m) 6.25 per Mtok. 1h write = 2x input = 10.
// Mirrors the generated catalog entry for anthropic/claude-opus-4-8 (cost only).
private let claudeOpus48 = bModel(
    id: "claude-opus-4-8",
    provider: "anthropic",
    baseUrl: "https://api.anthropic.com",
    cost: ModelCost(input: 5, output: 25, cacheRead: 0.5, cacheWrite: 6.25),
    compat: ["forceAdaptiveThinking": true, "supportsTemperature": false]
)
// Mirrors the generated catalog entry for vercel-ai-gateway/anthropic/claude-haiku-4.5 (cost only).
private let vercelClaudeHaiku45 = bModel(
    id: "anthropic/claude-haiku-4.5",
    provider: "vercel-ai-gateway",
    baseUrl: "https://ai-gateway.vercel.sh",
    cost: ModelCost(input: 1, output: 5, cacheRead: 0.1, cacheWrite: 1.25),
    compat: ["allowEmptySignature": true]
)

private let context = bUserContext("hi")

private func isClose(_ actual: Double, _ expected: Double, digits: Int = 10) -> Bool {
    abs(actual - expected) < pow(10, Double(-digits)) / 2
}

@Suite("Anthropic 1h cache write cost")
struct AnthropicCacheWrite1hCostTests {
    @Test("prices the 1h portion at 2x input and the rest at the 5m rate")
    func splitPricing() async {
        let run = await bRun(
            claudeOpus48,
            context,
            response: bSseBody(json: eventsWithCacheCreation(["ephemeral_5m_input_tokens": 600_000, "ephemeral_1h_input_tokens": 400_000]))
        )
        let result = run.result
        #expect(result.usage.cacheWrite == 1_000_000)
        #expect(result.usage.cacheWrite1h == 400_000)
        // 600k * 6.25/Mtok + 400k * 10/Mtok = 3.75 + 4.0 = 7.75
        #expect(isClose(result.usage.cost.cacheWrite, 7.75), "\(result.usage.cost.cacheWrite)")
    }

    // Regression for #9210: Vercel AI Gateway sends cache usage in message_delta, not message_start.
    @Test("prices 1h cache writes reported only in message_delta")
    func messageDeltaOnly() async {
        let events: [(event: String, data: JsonValue)] = [
            ("message_start", ["type": "message_start", "message": ["id": "msg_test", "usage": ["input_tokens": 0, "output_tokens": 0]]]),
            ("message_delta", [
                "type": "message_delta",
                "delta": ["stop_reason": "end_turn"],
                "usage": [
                    "input_tokens": 3,
                    "output_tokens": 4,
                    "cache_creation_input_tokens": 6535,
                    "cache_creation": ["ephemeral_5m_input_tokens": 0, "ephemeral_1h_input_tokens": 6535],
                ],
            ]),
            ("message_stop", ["type": "message_stop"]),
        ]
        let model = vercelClaudeHaiku45
        let result = await bRun(model, context, response: bSseBody(json: events)).result
        #expect(result.usage.cacheWrite == 6535)
        #expect(result.usage.cacheWrite1h == 6535)
        #expect(isClose(result.usage.cost.cacheWrite, (6535 * model.cost.input * 2) / 1_000_000), "\(result.usage.cost.cacheWrite)")
    }

    @Test("falls back to the 5m rate when no breakdown is reported")
    func noBreakdown() async {
        let result = await bRun(claudeOpus48, context, response: bSseBody(json: eventsWithCacheCreation(nil))).result
        #expect(result.usage.cacheWrite == 1_000_000)
        #expect((result.usage.cacheWrite1h ?? 0) == 0)
        // 1M * 6.25/Mtok = 6.25
        #expect(isClose(result.usage.cost.cacheWrite, 6.25), "\(result.usage.cost.cacheWrite)")
    }
}
