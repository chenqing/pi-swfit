import Foundation
import Testing
@testable import PiAI

// Port of packages/ai/test/openai-completions-retry.test.ts
// Swift: the upstream mock records the SDK request options (`maxRetries: 0`) and uses fake timers. Here
// the real SDK runs against a fake fetch, so "SDK retries disabled" shows as exactly one fetch per
// provider attempt, and the retry delays are measured on the real clock.

private let model = cModel(#"{"id":"test-model","name":"Test Model","api":"openai-completions","provider":"opencode-go","baseUrl":"https://opencode.ai/zen/go/v1","reasoning":false,"input":["text"],"cost":{"input":0,"output":0,"cacheRead":0,"cacheWrite":0},"contextWindow":1000,"maxTokens":100}"#)

private let okChunks = [cChunk(["content": "ok"]), cChunk([:], finishReason: "stop")]

private func errorResponse(_ status: Int, _ message: String, _ headers: [(String, String)]) -> FetchResponse {
    cSSEResponse(#"{"error":{"message":"\#(message)"}}"#, status: status, headers: [("content-type", "application/json")] + headers)
}

/// Answers the queued errors first, then the ok stream; records when each request arrived.
private final class RetryServer: @unchecked Sendable {
    let arrivals = Locked<[Int]>([])
    let server: CFakeServer

    init(_ errors: [FetchResponse]) {
        let queue = Locked(errors)
        let arrivals = self.arrivals
        server = CFakeServer { _, _ in
            arrivals.withLock { $0.append(dateNow()) }
            if let error = queue.withLock({ $0.isEmpty ? nil : $0.removeFirst() }) { return error }
            return cSSEResponse(cSSE(okChunks))
        }
    }
}

private func consume(_ retry: RetryServer, maxRetries: Int? = nil, maxRetryDelayMs: Int? = nil) async -> AssistantMessage {
    let context = Context(systemPrompt: "", messages: [.user(UserMessage(content: .blocks([.text(TextContent(text: "hi"))]), timestamp: 0))], tools: [])
    return await cRunDirect(model, context, { options in
        options.maxRetries = maxRetries
        options.maxRetryDelayMs = maxRetryDelayMs
    }, server: retry.server).result
}

@Suite("openai-completions provider retries")
struct OpenAICompletionsRetryTests {
    @Test("disables SDK retries by default")
    func disablesSdkRetries() async {
        let retry = RetryServer([errorResponse(500, "server error", [])])
        let result = await consume(retry)
        // One attempt: neither pi nor the SDK retried the 500.
        #expect(retry.arrivals.current.count == 1)
        #expect(result.stopReason == .error)
    }

    @Test("honors provider retries while keeping SDK retries disabled")
    func honorsProviderRetries() async {
        let retry = RetryServer([
            errorResponse(429, "rate limited", [("retry-after-ms", "100")]),
            errorResponse(500, "server error", [("retry-after-ms", "100")]),
        ])
        let result = await consume(retry, maxRetries: 2, maxRetryDelayMs: 100)

        #expect(result.stopReason == .stop)
        let arrivals = retry.arrivals.current
        #expect(arrivals.count == 3)
        if arrivals.count == 3 {
            #expect(arrivals[1] - arrivals[0] >= 95)
            #expect(arrivals[2] - arrivals[1] >= 95)
        }
    }

    @Test("fails immediately when a provider-requested retry delay exceeds the limit")
    func retryDelayExceedsLimit() async {
        let retry = RetryServer([errorResponse(429, "rate limited", [("retry-after", "277403")])])
        let result = await consume(retry, maxRetries: 2, maxRetryDelayMs: 1000)

        #expect(result.stopReason == .error)
        #expect(result.errorMessage?.contains("Server requested 277403s retry delay (max: 1s)") == true)
        #expect(result.errorMessage?.contains("rate limited") == true)
        #expect(retry.arrivals.current.count == 1)
    }
}
