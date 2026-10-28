import Foundation
import Testing
@testable import PiAI

// Port of packages/ai/test/openai-completions-vllm-priority.test.ts

private func captureRequest(_ model: Model) async -> JsonValue {
    await cRunDirect(model, cUserContext("hi", systemPrompt: "sys")) { $0.apiKey = "test-key" }.payload
}

@Suite("openai-completions vllm priority")
struct OpenAICompletionsVllmPriorityTests {
    @Test("sends compat.vllmPriority as the top-level priority request field")
    func sendsPriority() async {
        let payload = await captureRequest(cOpenAICompletionsModel(compat: ["vllmPriority": 10]))
        #expect(payload["priority"] == 10)
    }

    @Test("omits priority when vllmPriority is not set")
    func omitsPriority() async {
        let payload = await captureRequest(cOpenAICompletionsModel())
        #expect(payload["priority"] == nil)
    }
}
