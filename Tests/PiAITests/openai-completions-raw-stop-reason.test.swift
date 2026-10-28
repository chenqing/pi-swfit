import Foundation
import Testing
@testable import PiAI

// Port of packages/ai/test/openai-completions-raw-stop-reason.test.ts

private let model = cModel(#"{"id":"test-model","name":"Test Model","api":"openai-completions","provider":"openai","baseUrl":"https://api.openai.com/v1","reasoning":false,"input":["text"],"cost":{"input":0,"output":0,"cacheRead":0,"cacheWrite":0},"contextWindow":128000,"maxTokens":4096}"#)

@Suite("OpenAI completions raw stop reasons")
struct OpenAICompletionsRawStopReasonTests {
    @Test("preserves raw finish reasons for successful stops")
    func successfulStops() async {
        let run = await cRunDirect(model, cUserContext("hello"), chunks: [cChunk([:], finishReason: "stop", id: "chatcmpl-1")])
        #expect(run.result.stopReason == .stop)
        #expect(run.result.rawStopReason == "stop")
        #expect(run.result.errorMessage == nil)
    }

    @Test("preserves raw finish reasons for provider error stops")
    func providerErrorStops() async {
        let run = await cRunDirect(model, cUserContext("hello"), chunks: [cChunk([:], finishReason: "content_filter", id: "chatcmpl-2")])
        #expect(run.result.stopReason == .error)
        #expect(run.result.rawStopReason == "content_filter")
        #expect(run.result.errorMessage == "Provider finish_reason: content_filter")
    }
}
