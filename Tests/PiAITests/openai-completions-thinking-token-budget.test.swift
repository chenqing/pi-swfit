import Foundation
import Testing
@testable import PiAI

// Port of packages/ai/test/openai-completions-thinking-token-budget.test.ts

private func vllmModel(_ compat: String = #"{"thinkingFormat":"zai","supportsThinkingTokenBudget":true}"#) -> Model {
    cModel(#"{"id":"zai-org/glm-5.2","name":"GLM 5.2 (local vLLM)","api":"openai-completions","provider":"local-vllm","baseUrl":"http://localhost:8000/v1","reasoning":true,"input":["text"],"cost":{"input":0,"output":0,"cacheRead":0,"cacheWrite":0},"contextWindow":262144,"maxTokens":16384,"compat":\#(compat)}"#)
}

private func capture(_ model: Model, reasoning: ThinkingLevel? = nil, thinkingBudgets: ThinkingBudgets? = nil, maxTokens: Int? = nil) async throws -> JsonValue {
    try await cRunSimple(model, cUserContext("Hi")) { options in
        options.reasoning = reasoning
        options.thinkingBudgets = thinkingBudgets
        options.maxTokens = maxTokens
    }.payload
}

private let chatTemplateCompat = #"{"thinkingFormat":"chat-template","chatTemplateKwargs":{"enable_thinking":{"$var":"thinking.enabled"},"thinking_budget":{"$var":"thinking.budget"}}}"#

@Suite("openai-completions thinking token budget")
struct OpenAICompletionsThinkingTokenBudgetTests {
    @Test("sends the configured budget for the requested level")
    func configuredBudget() async throws {
        let params = try await capture(vllmModel(), reasoning: .medium, thinkingBudgets: ThinkingBudgets(medium: 4096))
        #expect(params["thinking_token_budget"] == 4096)
    }

    @Test("omits the budget when neither the field nor the alias is set")
    func omitsWithoutField() async throws {
        let params = try await capture(vllmModel(#"{"thinkingFormat":"zai"}"#), reasoning: .medium, thinkingBudgets: ThinkingBudgets(medium: 4096))
        #expect(params["thinking_token_budget"] == nil)
        #expect(params["thinking_budget"] == nil)
        #expect(params["thinking_budget_tokens"] == nil)
    }

    @Test("omits the budget when thinking is off")
    func omitsWhenOff() async throws {
        let params = try await capture(vllmModel(), reasoning: nil, thinkingBudgets: ThinkingBudgets(high: 8192))
        #expect(params["thinking_token_budget"] == nil)
    }

    @Test("clamps xhigh and max to the high budget")
    func clampsXhighAndMax() async throws {
        let xhigh = try await capture(vllmModel(), reasoning: .xhigh, thinkingBudgets: ThinkingBudgets(high: 8192))
        let max = try await capture(vllmModel(), reasoning: .max, thinkingBudgets: ThinkingBudgets(high: 8192))
        #expect(xhigh["thinking_token_budget"] == 8192)
        #expect(max["thinking_token_budget"] == 8192)
    }

    @Test("leaves room for the answer when the budget meets the response ceiling")
    func leavesRoomForAnswer() async throws {
        let params = try await capture(vllmModel(), reasoning: .high)
        #expect(params["thinking_token_budget"] == .number(Double(16384 - 1024)))
    }

    @Test("uses the caller max_tokens as the ceiling when it is lower than the model cap")
    func callerMaxTokensCeiling() async throws {
        let params = try await capture(vllmModel(), reasoning: .high, thinkingBudgets: ThinkingBudgets(high: 8192), maxTokens: 4096)
        #expect(params["thinking_token_budget"] == .number(Double(4096 - 1024)))
    }

    @Test("sends the field named by thinkingTokenBudgetField", arguments: ["thinking_budget", "thinking_budget_tokens"])
    func budgetField(_ field: String) async throws {
        let params = try await capture(vllmModel(#"{"thinkingFormat":"qwen","thinkingTokenBudgetField":"\#(field)"}"#), reasoning: .medium, thinkingBudgets: ThinkingBudgets(medium: 4096))
        #expect(params[field] == 4096)
        #expect(params["thinking_token_budget"] == nil)
    }

    @Test("lets thinkingTokenBudgetField win over the boolean alias")
    func fieldWinsOverAlias() async throws {
        let params = try await capture(
            vllmModel(#"{"thinkingFormat":"zai","supportsThinkingTokenBudget":true,"thinkingTokenBudgetField":"thinking_budget"}"#),
            reasoning: .medium, thinkingBudgets: ThinkingBudgets(medium: 4096)
        )
        #expect(params["thinking_budget"] == 4096)
        #expect(params["thinking_token_budget"] == nil)
    }

    @Test("puts the clamped budget in chat_template_kwargs when $var is thinking.budget")
    func chatTemplateBudget() async throws {
        let params = try await capture(vllmModel(chatTemplateCompat), reasoning: .high)
        #expect(params["chat_template_kwargs"] == ["enable_thinking": true, "thinking_budget": .number(Double(16384 - 1024))])
        #expect(params["thinking_token_budget"] == nil)
    }

    @Test("omits thinking.budget from chat_template_kwargs when thinking is off")
    func chatTemplateOff() async throws {
        let params = try await capture(vllmModel(chatTemplateCompat), reasoning: nil)
        #expect(params["chat_template_kwargs"] == ["enable_thinking": false])
    }
}
