import Foundation
import Testing
@testable import PiAI

// Port of packages/ai/test/model-cost-tiers.test.ts
// The upstream cases drive `scripts/openrouter-catalog.ts`, which prices chat models with
// `openRouterCost`; they are ported against `openRouterCost` directly. Not ported: the Vercel AI
// Gateway cases (`scripts/ai-gateway-pricing.ts` is a catalog generator script).

@Suite("OpenRouter pricing overrides")
struct ModelCostTiersTests {
    @Test("turns prompt-length overrides into tiers")
    func promptLengthOverrides() {
        #expect(openRouterCost(OpenRouterPricing(
            prompt: "0.0000001",
            completion: "0.0000005",
            input_cache_read: "0.00000001",
            input_cache_write: "0.000000125",
            overrides: [OpenRouterPricingOverride(
                min_prompt_tokens: 100000,
                prompt: "0.0000005",
                completion: "0.0000025",
                input_cache_read: "0.00000005",
                input_cache_write: "0.000000625"
            )]
        )) == ModelCost(
            input: 0.1,
            output: 0.5,
            cacheRead: 0.01,
            cacheWrite: 0.125,
            tiers: [ModelCostTier(inputTokensAbove: 100000, input: 0.5, output: 2.5, cacheRead: 0.05, cacheWrite: 0.625)]
        ))
    }

    @Test("keeps base rates missing from an override")
    func keepsBaseRates() {
        #expect(openRouterCost(OpenRouterPricing(
            prompt: "0.000002",
            completion: "0.000012",
            input_cache_read: "0.0000002",
            input_cache_write: "0.000000375",
            overrides: [OpenRouterPricingOverride(min_prompt_tokens: 200000, prompt: "0.000004", completion: "0.000018")]
        )).tiers == [ModelCostTier(inputTokensAbove: 200000, input: 4, output: 18, cacheRead: 0.2, cacheWrite: 0.375)])
    }

    @Test("skips time-of-day overrides")
    func skipsTimeOfDay() {
        #expect(openRouterCost(OpenRouterPricing(
            prompt: "0.000000132",
            completion: "0.000000528",
            overrides: [
                OpenRouterPricingOverride(utc_start: 0, utc_end: 1600, prompt: "0.000000132", completion: "0.000000528"),
                OpenRouterPricingOverride(min_prompt_tokens: 1000, utc_days: ["saturday"], prompt: "0.0000001"),
            ]
        )) == ModelCost(input: 0.132, output: 0.528, cacheRead: 0, cacheWrite: 0))
    }
}
