import Foundation
import Testing
@testable import PiAI

private func createErrorMessage(_ errorMessage: String, _ provider: String = "ollama") -> AssistantMessage {
    AssistantMessage(
        content: [],
        api: "openai-completions",
        provider: provider,
        model: "qwen3.5:35b",
        usage: Usage(
            input: 0,
            output: 0,
            cacheRead: 0,
            cacheWrite: 0,
            totalTokens: 0,
            cost: UsageCost(input: 0, output: 0, cacheRead: 0, cacheWrite: 0, total: 0)
        ),
        stopReason: .error,
        errorMessage: errorMessage,
        timestamp: dateNow()
    )
}

private func createLengthStopMessage(
    input: Int,
    cacheRead: Int,
    output: Int,
    cacheWrite: Int? = nil,
    api: Api? = nil,
    provider: String? = nil,
    model: String? = nil
) -> AssistantMessage {
    let cacheWrite = cacheWrite ?? 0
    return AssistantMessage(
        content: [],
        api: api ?? "openai-completions",
        provider: provider ?? "test-provider",
        model: model ?? "test-model",
        usage: Usage(
            input: input,
            output: output,
            cacheRead: cacheRead,
            cacheWrite: cacheWrite,
            totalTokens: input + cacheRead + cacheWrite + output,
            cost: UsageCost(input: 0, output: 0, cacheRead: 0, cacheWrite: 0, total: 0)
        ),
        stopReason: .length,
        timestamp: dateNow()
    )
}

@Suite
struct OverflowTests {
    // The 413 pattern is provider-agnostic, so a single Copilot-prefixed string and a single
    // non-Copilot string cover both branches of the regex; the bare forms cover the raw SDK output.
    @Test("detects provider-independent request-size overflow: %s", arguments: [
        "github-copilot API error (413): {\"message\":\"failed to parse request\",\"code\":\"\"}", // formatProviderError prefix
        "custom-provider API error (413): Payload Too Large", // any provider, not just Copilot
        "413 {\"error\":{\"message\":\"failed to parse request\",\"code\":\"\"}}", // raw SDK error
        "413", // bare status at end of string
    ])
    func requestSizeOverflow(_ errorMessage: String) {
        // The request can exceed the byte limit even with zero usage and a large token window.
        #expect(isContextOverflow(createErrorMessage(errorMessage), 1_000_000) == true)
        #expect(isContextOverflow(createErrorMessage(errorMessage)) == true)
    }

    @Test("does not mistake unrelated errors for request-size overflow: %s", arguments: [
        "github-copilot API error (400): {\"message\":\"failed to parse request\",\"code\":\"\"}", // other status, same body
        "custom-provider API error (429): Too many requests",
        "github-copilot API error (400): {\"message\":\"failed to parse request: invalid value 413\"}", // 413 in the body only
        "custom-provider API error (400): upstream mentioned OpenAI API error (413): invalid input", // 413 not at start
        "custom-provider API error (4130): invalid input", // 413 is a prefix, not the status
        "4130 failed to parse request", // bare 4130 is not 413
    ])
    func notRequestSizeOverflow(_ errorMessage: String) {
        #expect(isContextOverflow(createErrorMessage(errorMessage)) == false)
    }

    @Test("limits HTTP-status matching to failed responses")
    func limitsToFailedResponses() {
        let message = createErrorMessage("OpenAI API error (413): {\"message\":\"failed to parse request\"}")
        var aborted = message
        aborted.stopReason = .aborted
        var stopped = message
        stopped.stopReason = .stop
        #expect(isContextOverflow(aborted) == false)
        #expect(isContextOverflow(stopped) == false)
    }

    @Test("detects explicit Ollama prompt-too-long errors")
    func ollamaPromptTooLong() {
        let message = createErrorMessage("400 `prompt too long; exceeded max context length by 100918 tokens`")
        #expect(isContextOverflow(message, 32768) == true)
    }

    @Test("detects z.ai prompt-too-long errors")
    func zaiPromptTooLong() {
        // Regression for #9805.
        let message = createErrorMessage("400 {\"code\":\"1261\",\"message\":\"Prompt too long\"}", "zai")
        #expect(isContextOverflow(message, 1048576) == true)
    }

    @Test("detects z.ai CN endpoint prompt-exceeds-max-length errors")
    func zaiCnPromptExceeds() {
        // Regression for #10208.
        let message = createErrorMessage("400 {\"code\":\"1261\",\"message\":\"Prompt exceeds max length\"}", "zai")
        #expect(isContextOverflow(message, 1048576) == true)
    }

    @Test("detects Together AI context length errors")
    func togetherContextLength() {
        let message = createErrorMessage(
            "400 The input (516368 tokens) is longer than the model's context length (262144 tokens)."
        )
        #expect(isContextOverflow(message, 262144) == true)
    }

    @Test("detects LiteLLM-wrapped OpenAI maximum context length errors")
    func liteLLMWrapped() {
        let message = createErrorMessage(
            "Error: 503 litellm.ServiceUnavailableError: litellm.MidStreamFallbackError: litellm.APIConnectionError: APIConnectionError: OpenAIException - Requested token count exceeds the model's maximum context length of 131072 tokens."
        )
        #expect(isContextOverflow(message, 131072) == true)
    }

    @Test("detects OpenAI-compatible parenthesized maximum context length errors")
    func parenthesizedMaxContext() {
        let message = createErrorMessage(
            "Error: 400 Input length (265330) exceeds model's maximum context length (262144)."
        )
        #expect(isContextOverflow(message, 262144) == true)
    }

    @Test("detects OpenRouter Poolside maximum allowed input length errors")
    func poolsideMaxInput() {
        let message = createErrorMessage(
            "Provider returned error: Input length 131393 exceeds the maximum allowed input length of 131040 tokens."
        )
        #expect(isContextOverflow(message, 131072) == true)
    }

    @Test("detects DS4 configured context size errors")
    func ds4ContextSize() {
        let message = createErrorMessage(
            "400 Prompt has 256468 tokens, but the configured context size is 256000 tokens"
        )
        #expect(isContextOverflow(message, 256000) == true)

        let commaMessage = createErrorMessage(
            "Prompt has 5,958,968 tokens, but the configured context size is 256,000 tokens"
        )
        #expect(isContextOverflow(commaMessage, 256000) == true)
    }

    @Test("does not treat generic non-overflow Ollama errors as overflow")
    func genericOllamaError() {
        let message = createErrorMessage("500 `model runner crashed unexpectedly`")
        #expect(isContextOverflow(message, 32768) == false)
    }

    @Test("only treats bodyless 400 errors as overflow for Cerebras")
    func bodyless400Cerebras() {
        // Regression for #9482. HTTP 413 is a request-size error for every provider,
        // but a bodyless HTTP 400 is only known to indicate overflow for Cerebras.
        let errorMessage = "400 status code (no body)"
        #expect(isContextOverflow(createErrorMessage(errorMessage, "cerebras"), 131072) == true)
        #expect(isContextOverflow(createErrorMessage(errorMessage, "opencode-go"), 1000000) == false)
    }

    @Test("does not treat Bedrock throttling 'Too many tokens' as overflow")
    func bedrockThrottling() {
        // Bedrock returns this for HTTP 429 rate limiting, NOT context overflow.
        // formatBedrockError uses a human-readable prefix for ThrottlingException.
        let message = createErrorMessage("Throttling error: Too many tokens, please wait before trying again.")
        #expect(isContextOverflow(message, 200000) == false)
    }

    @Test("does not treat Bedrock service unavailable as overflow")
    func bedrockServiceUnavailable() {
        let message = createErrorMessage("Service unavailable: The service is temporarily unavailable.")
        #expect(isContextOverflow(message, 200000) == false)
    }

    @Test("does not treat generic rate limit errors as overflow")
    func genericRateLimit() {
        let message = createErrorMessage("Rate limit exceeded, please retry after 30 seconds.")
        #expect(isContextOverflow(message, 200000) == false)
    }

    @Test("does not treat HTTP 429 style errors as overflow")
    func http429Style() {
        let message = createErrorMessage("Too many requests. Please slow down.")
        #expect(isContextOverflow(message, 200000) == false)
    }

    @Test("detects Xiaomi-style overflow (length stop with zero output and filled context)")
    func xiaomiOverflow() {
        let message = createLengthStopMessage(
            input: 58,
            cacheRead: 1048512,
            output: 0,
            provider: "xiaomi",
            model: "mimo-v2.6-pro"
        )
        #expect(isContextOverflow(message, 1048576) == true)
    }

    @Test("treats a length stop below the desired output limit as recoverable")
    func recoverableLengthBelowLimit() {
        let message = createLengthStopMessage(
            input: 3,
            cacheRead: 253584,
            output: 16,
            cacheWrite: 25554,
            api: "openai-responses",
            provider: "openai",
            model: "gpt-5.6-sol"
        )
        #expect(isRecoverableLength(message, 128000) == true)
    }

    @Test("does not recover a length stop that reached the desired output limit")
    func notRecoverableAtLimit() {
        let message = createLengthStopMessage(input: 4062, cacheRead: 0, output: 1024)
        #expect(isRecoverableLength(message, 1024) == false)
    }

    @Test("treats zero-output length stops as recoverable without context metadata")
    func zeroOutputRecoverable() {
        let message = createLengthStopMessage(input: 100, cacheRead: 0, output: 0)
        #expect(isRecoverableLength(message, 128000) == true)
    }

    @Test("does not treat normal length stops with output as context overflow")
    func normalLengthStop() {
        let message = createLengthStopMessage(input: 1000, cacheRead: 0, output: 4096)
        #expect(isContextOverflow(message, 200000) == false)
    }

    @Test("does not treat zero-output length stops far below context as context overflow")
    func zeroOutputFarBelow() {
        let message = createLengthStopMessage(input: 100, cacheRead: 0, output: 0)
        #expect(isContextOverflow(message, 200000) == false)
    }
}
