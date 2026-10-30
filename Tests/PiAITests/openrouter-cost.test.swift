import Foundation
import Testing
@testable import PiAI

// Port of packages/ai/test/openrouter-cost.test.ts

private func usage(_ total: Double = 1) -> Usage {
    Usage(
        input: 1,
        output: 1,
        cacheRead: 0,
        cacheWrite: 0,
        totalTokens: 2,
        cost: UsageCost(input: 0.25, output: 0.75, cacheRead: 0, cacheWrite: 0, total: total)
    )
}

private func model(_ provider: String, _ baseUrl: String) -> Model {
    Model(id: "m", name: "m", api: "openai-completions", provider: provider, baseUrl: baseUrl, reasoning: false,
          input: ["text"], cost: ModelCost(), contextWindow: 1000, maxTokens: 100)
}

private func json(_ text: String) -> JsonValue {
    do { return try JsonValue.parse(text) } catch { fatalError("bad test JSON: \(error)") }
}

@Suite("isOpenRouterModel")
struct IsOpenRouterModelTests {
    @Test("recognizes both the built-in provider and custom providers using OpenRouter's endpoint")
    func recognizes() {
        #expect(isOpenRouterModel(model("openrouter", "https://example.com")) == true)
        #expect(isOpenRouterModel(model("openrouter-work", "https://openrouter.ai/api/v1")) == true)
        #expect(isOpenRouterModel(model("custom", "https://example.com/v1")) == false)
    }
}

@Suite("applyOpenRouterReportedCost")
struct ApplyOpenRouterReportedCostTests {
    @Test("uses OpenRouter's reported cost for non-BYOK requests")
    func nonByok() {
        var value = usage()
        applyOpenRouterReportedCost(&value, json(#"{"cost":0,"is_byok":false,"cost_details":{"upstream_inference_cost":0,"upstream_inference_prompt_cost":0,"upstream_inference_completions_cost":0}}"#))
        #expect(value.cost.total == 0)
        #expect(value.cost.totalFromProvider == true)
    }

    @Test("adds the upstream inference cost for BYOK requests")
    func byok() {
        var value = usage()
        applyOpenRouterReportedCost(&value, json(#"{"cost":0.1,"is_byok":true,"cost_details":{"upstream_inference_cost":0.9,"upstream_inference_prompt_cost":0.6,"upstream_inference_completions_cost":0.3}}"#))
        #expect(value.cost.total == 1)
        #expect(value.cost.totalFromProvider == true)
    }

    @Test("uses upstream cost components when OpenRouter omits their total")
    func byokComponents() {
        var value = usage()
        applyOpenRouterReportedCost(&value, json(#"{"cost":0.1,"is_byok":true,"cost_details":{"upstream_inference_cost":null,"upstream_inference_prompt_cost":0.6,"upstream_inference_completions_cost":0.3}}"#))
        #expect(abs(value.cost.total - 1) < 0.005)
        #expect(value.cost.totalFromProvider == true)
    }

    @Test("keeps the catalog total when OpenRouter's accounting is incomplete")
    func incomplete() {
        var value = usage()
        value.cost.totalFromProvider = false
        applyOpenRouterReportedCost(&value, json(#"{"cost":null,"is_byok":false,"cost_details":null}"#))
        applyOpenRouterReportedCost(&value, json(#"{"cost":0.1,"is_byok":true,"cost_details":null}"#))
        #expect(value.cost.total == 1)
        #expect(value.cost.totalFromProvider == false)
    }
}
