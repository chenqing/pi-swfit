
import Foundation

// Port of utils/overflow.ts

/// Regex patterns to detect context overflow errors from different providers.
///
/// These patterns match error messages returned when the input exceeds
/// the model's context window or the provider's request byte-size limit.
///
/// Provider-specific patterns (with example error messages):
///
/// - Anthropic: "prompt is too long: 213462 tokens > 200000 maximum"
/// - Anthropic: "413 {\"error\":{\"type\":\"request_too_large\",\"message\":\"Request exceeds the maximum size\"}}"
/// - OpenAI: "Your input exceeds the context window of this model"
/// - OpenAI/LiteLLM: "Requested token count exceeds the model's maximum context length of 131072 tokens"
/// - LiteLLM pre-call check: "litellm.ContextWindowExceededError: ... Context Window exceeded for given call."
/// - OpenAI-compatible: "Input length (265330) exceeds model's maximum context length (262144)."
/// - Google: "The input token count (1196265) exceeds the maximum number of tokens allowed (1048575)"
/// - xAI: "This model's maximum prompt length is 131072 but the request contains 537812 tokens"
/// - Groq: "Please reduce the length of the messages or completion"
/// - OpenRouter: "This endpoint's maximum context length is X tokens. However, you requested about Y tokens"
/// - OpenRouter/Poolside: "Input length X exceeds the maximum allowed input length of Y tokens."
/// - Together AI: "The input (X tokens) is longer than the model's context length (Y tokens)."
/// - llama.cpp: "the request exceeds the available context size, try increasing it"
/// - LM Studio: "tokens to keep from the initial prompt is greater than the context length"
/// - GitHub Copilot: "prompt token count of X exceeds the limit of Y"
/// - GitHub Copilot: 'github-copilot API error (413): {"message":"failed to parse request","code":""}'
/// - MiniMax: "invalid params, context window exceeds limit"
/// - Kimi For Coding: "Your request exceeded model token limit: X (requested: Y)"
/// - DS4: "Prompt has X tokens, but the configured context size is Y tokens"
/// - Cerebras: "400/413 status code (no body)"
/// - Mistral: "Prompt contains X tokens ... too large for model with Y maximum context length"
/// - z.ai: `{"code":"1261","message":"Prompt too long"}`, `{"code":"1261","message":"Prompt exceeds max length"}` (CN endpoint), or silent overflow via usage.input > contextWindow
/// - Xiaomi MiMo: Truncates input to fill contextWindow exactly, then returns finish_reason "length"
///   with output=0 (no room left to generate). Detected via stopReason "length" + zero output +
///   input filling the context window.
/// - DashScope/Qwen: "Range of input length should be [1, X]" (HTTP 400 invalid_parameter_error)
/// - Ollama: Some deployments truncate silently, others return errors like "prompt too long; exceeded max context length by X tokens"
let OVERFLOW_PATTERNS: [NSRegularExpression] = [
    jsRegex("prompt (?:is )?too long", "i"), // Anthropic and z.ai token overflow
    jsRegex("prompt exceeds max length", "i"), // z.ai CN endpoint token overflow
    jsRegex("request_too_large", "i"), // Anthropic request byte-size overflow (HTTP 413)
    jsRegex("input is too long for requested model", "i"), // Amazon Bedrock
    jsRegex("exceeds the context window", "i"), // OpenAI (Completions & Responses API)
    jsRegex("exceeds (?:the )?(?:model'?s )?maximum context length(?: of [\\d,]+ tokens?|\\s*\\([\\d,]+\\))", "i"), // OpenAI-compatible proxies (LiteLLM)
    jsRegex("context window exceeded", "i"), // LiteLLM pre-call check (ContextWindowExceededError)
    jsRegex("input token count.*exceeds the maximum", "i"), // Google (Gemini)
    jsRegex("maximum prompt length is \\d+", "i"), // xAI (Grok)
    jsRegex("reduce the length of the messages", "i"), // Groq
    jsRegex("maximum context length is \\d+ tokens", "i"), // OpenRouter (most backends)
    jsRegex("exceeds (?:the )?maximum allowed input length of [\\d,]+ tokens?", "i"), // OpenRouter/Poolside
    jsRegex("input \\(\\d+ tokens\\) is longer than the model'?s context length \\(\\d+ tokens\\)", "i"), // Together AI
    jsRegex("exceeds the limit of \\d+", "i"), // GitHub Copilot
    jsRegex("exceeds the available context size", "i"), // llama.cpp server
    jsRegex("greater than the context length", "i"), // LM Studio
    jsRegex("context window exceeds limit", "i"), // MiniMax
    jsRegex("exceeded model token limit", "i"), // Kimi For Coding
    jsRegex("too large for model with \\d+ maximum context length", "i"), // Mistral
    jsRegex("prompt has [\\d,]+ tokens?, but the configured context size is [\\d,]+ tokens?", "i"), // DS4 server
    jsRegex("model_context_window_exceeded", "i"), // z.ai non-standard finish_reason surfaced as error text
    jsRegex("prompt too long; exceeded (?:max )?context length", "i"), // Ollama explicit overflow error
    jsRegex("range of input length should be", "i"), // DashScope / Qwen Token Plan
    jsRegex("context[_ ]length[_ ]exceeded", "i"), // Generic fallback
    jsRegex("too many tokens", "i"), // Generic fallback
    jsRegex("token limit exceeded", "i"), // Generic fallback
    // HTTP 413 means request-size overflow regardless of provider or body text.
    // Match raw SDK errors and formatProviderError's prefix, not a status mentioned in the body.
    jsRegex("^(?:[\\w -]+ API error \\(413\\):|413(?:\\s|:|$))", "i"),
]

let CEREBRAS_BODYLESS_OVERFLOW_PATTERN = jsRegex("^4(?:00|13)\\s*(?:status code)?\\s*\\(no body\\)", "i")

/// Patterns that indicate non-overflow errors (e.g. rate limiting, server errors).
/// Error messages matching any of these are excluded from overflow detection
/// even if they also match an OVERFLOW_PATTERN.
///
/// Example: Bedrock formats throttling errors as "ThrottlingException: Too many tokens,
/// please wait before trying again." which would match the /too many tokens/i overflow
/// pattern without this exclusion.
let NON_OVERFLOW_PATTERNS: [NSRegularExpression] = [
    jsRegex("^(Throttling error|Service unavailable):", "i"), // AWS Bedrock non-overflow errors (human-readable prefixes from formatBedrockError)
    jsRegex("rate limit", "i"), // Generic rate limiting
    jsRegex("too many requests", "i"), // Generic HTTP 429 style
]

/// Check if an assistant message represents a context overflow error.
///
/// This handles three cases:
/// 1. Error-based overflow: Most providers return stopReason "error" with a
///    specific error message pattern.
/// 2. Silent overflow: Some providers accept overflow requests and return
///    successfully. For these, we check if usage.input exceeds the context window.
/// 3. Length-stop overflow: Xiaomi MiMo can return "length" with zero output when
///    the input fills the context window.
///
/// ## Reliability by Provider
///
/// **Reliable detection (returns error with detectable message):**
/// - Anthropic: "prompt is too long: X tokens > Y maximum" or "request_too_large"
/// - OpenAI (Completions & Responses): "exceeds the context window", "exceeds the model's maximum context length of X tokens", or "exceeds model's maximum context length (X)"
/// - Google Gemini: "input token count exceeds the maximum"
/// - xAI (Grok): "maximum prompt length is X but request contains Y"
/// - Groq: "reduce the length of the messages"
/// - GitHub Copilot: HTTP 413 "failed to parse request" (request byte-size overflow)
/// - Cerebras: 400/413 status code (no body)
/// - Mistral: "Prompt contains X tokens ... too large for model with Y maximum context length"
/// - OpenRouter (most backends): "maximum context length is X tokens"
/// - OpenRouter/Poolside: "Input length X exceeds the maximum allowed input length of Y tokens."
/// - Together AI: "The input (X tokens) is longer than the model's context length (Y tokens)."
/// - llama.cpp: "exceeds the available context size"
/// - LM Studio: "greater than the context length"
/// - Kimi For Coding: "exceeded model token limit: X (requested: Y)"
/// - DS4: "Prompt has X tokens, but the configured context size is Y tokens"
/// - DashScope/Qwen: "Range of input length should be [1, X]"
/// - z.ai: "Prompt too long"
///
/// **Unreliable detection:**
/// - z.ai: Sometimes accepts overflow silently (detectable via usage.input > contextWindow),
///   sometimes returns rate limit errors. Pass contextWindow param to detect silent overflow.
/// - Xiaomi MiMo: Truncates input to fit contextWindow then returns stopReason "length" with
///   output=0. Pass contextWindow param to detect via the "filled context + zero output" signal.
/// - Ollama: May truncate input silently for some setups, but may also return explicit
///   overflow errors that match the patterns above. Silent truncation still cannot be
///   detected here because we do not know the expected token count.
///
/// ## Custom Providers
///
/// If you've added custom models via settings.json, this function may not detect
/// overflow errors from those providers. To add support:
///
/// 1. Send a request that exceeds the model's context window
/// 2. Check the errorMessage in the response
/// 3. Create a regex pattern that matches the error
/// 4. The pattern should be added to OVERFLOW_PATTERNS in this file, or
///    check the errorMessage yourself before calling this function
///
/// @param message - The assistant message to check
/// @param contextWindow - Optional context window size for detecting silent overflow (z.ai)
/// @returns true if the message indicates a context overflow
public func isContextOverflow(_ message: AssistantMessage, _ contextWindow: Int? = nil) -> Bool {
    // Case 1: Check error message patterns
    if message.stopReason == .error, let errorMessage = message.errorMessage, !errorMessage.isEmpty {
        // Skip messages matching known non-overflow patterns (e.g. throttling / rate-limit)
        let isNonOverflow = NON_OVERFLOW_PATTERNS.contains { jsRegexTest($0, errorMessage) }
        if !isNonOverflow {
            if OVERFLOW_PATTERNS.contains(where: { jsRegexTest($0, errorMessage) }) {
                return true
            }
            if message.provider == "cerebras" && jsRegexTest(CEREBRAS_BODYLESS_OVERFLOW_PATTERN, errorMessage) {
                return true
            }
        }
    }

    // Case 2: Silent overflow (z.ai style) - successful but usage exceeds context
    if let contextWindow, contextWindow != 0, message.stopReason == .stop {
        let inputTokens = message.usage.input + message.usage.cacheRead
        if inputTokens > contextWindow {
            return true
        }
    }

    // Case 3: Length-stop overflow (Xiaomi MiMo style) - server truncates oversized input
    // to fit the context window, leaving no room for output. Returns stopReason "length"
    // with output=0 and input+cacheRead filling the context window.
    if let contextWindow, contextWindow != 0, message.stopReason == .length, message.usage.output == 0 {
        let inputTokens = message.usage.input + message.usage.cacheRead
        if Double(inputTokens) >= Double(contextWindow) * 0.99 {
            return true
        }
    }

    return false
}

/// Check whether a length stop ended below the caller or model's intended output limit.
/// Such responses may be caused by context pressure or provider-side truncation, so callers
/// can make one bounded compact-and-retry attempt. `desiredMaxOutput` must be the original
/// limit before any context-based clamping.
public func isRecoverableLength(_ message: AssistantMessage, _ desiredMaxOutput: Int) -> Bool {
    message.stopReason == .length && desiredMaxOutput > 0 && message.usage.output < desiredMaxOutput
}

/// Get the overflow patterns for testing purposes.
public func getOverflowPatterns() -> [NSRegularExpression] {
    OVERFLOW_PATTERNS
}

// MARK: - JS RegExp helpers

/// Compile a JS regex literal body with flags ("i", "m", "s") as an `NSRegularExpression`.
func jsRegex(_ pattern: String, _ flags: String = "") -> NSRegularExpression {
    var options: NSRegularExpression.Options = []
    if flags.contains("i") { options.insert(.caseInsensitive) }
    if flags.contains("m") { options.insert(.anchorsMatchLines) }
    if flags.contains("s") { options.insert(.dotMatchesLineSeparators) }
    // swiftlint:disable:next force_try
    return try! NSRegularExpression(pattern: pattern, options: options)
}

/// `regex.test(text)`.
func jsRegexTest(_ regex: NSRegularExpression, _ text: String) -> Bool {
    regex.firstMatch(in: text, options: [], range: NSRange(text.startIndex..., in: text)) != nil
}
