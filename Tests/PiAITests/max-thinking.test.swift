import Foundation
import Testing
@testable import PiAI

// Port of packages/ai/test/max-thinking.test.ts
// Not ported: the openai-codex catalog and Codex Responses payload cases (catalog and API not in group G).

@Suite("max thinking level")
struct MaxThinkingTests {
    @Test("is opt-in for ordinary reasoning models")
    func optIn() {
        let model = Model(
            id: "ordinary-reasoning",
            name: "Ordinary Reasoning",
            api: "openai-completions",
            provider: "test",
            baseUrl: "https://example.com/v1",
            reasoning: true,
            input: ["text"],
            cost: ModelCost(),
            contextWindow: 128000,
            maxTokens: 4096
        )

        #expect(getSupportedThinkingLevels(model) == [.off, .minimal, .low, .medium, .high])
        #expect(clampThinkingLevel(model, .max) == .high)
    }

    @Test("supports a hole between high and max")
    func holeBetweenHighAndMax() {
        var model = Model(
            id: "high-and-max",
            name: "High and Max",
            api: "openai-completions",
            provider: "test",
            baseUrl: "https://example.com/v1",
            reasoning: true,
            input: ["text"],
            cost: ModelCost(),
            contextWindow: 128000,
            maxTokens: 4096
        )
        model.thinkingLevelMap = [.xhigh: String?.none, .max: String?.some("max")]

        #expect(getSupportedThinkingLevels(model) == [.off, .minimal, .low, .medium, .high, .max])
        #expect(clampThinkingLevel(model, .xhigh) == .max)
    }
}
