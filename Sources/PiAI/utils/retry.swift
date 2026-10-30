import Foundation

// Port of utils/retry.ts

private func buildProviderErrorPattern(_ patterns: [String]) -> NSRegularExpression {
    jsRegex(patterns.joined(separator: "|"), "i")
}

let NON_RETRYABLE_PROVIDER_LIMIT_ERROR_PATTERN = buildProviderErrorPattern([
    // OpenCode Go/free-tier limits returned as 429 JSON error types by OpenCode's
    // Zen API. These are subscription/account limits, not transient throttles.
    "GoUsageLimitError",
    "FreeUsageLimitError",

    // OpenCode Go subscription-limit text asks users to enable available-balance
    // usage after rolling/weekly/monthly limits are reached.
    "Monthly usage limit reached",
    "available balance",

    // Generic quota/budget/billing exhaustion. `insufficient_quota` is OpenAI's
    // quota/billing error code; the other strings cover common gateway wording.
    "insufficient_quota",
    "out of budget",
    "quota exceeded",
    "billing",

    // Sign in with ChatGPT: the subscription's shared usage limit, which resets
    // after hours rather than seconds.
    "subscription_sharing_usage_limit_exceeded",
    // Sign in with ChatGPT on a ChatGPT Business plan: a usage limit set by the
    // workspace admin. Only the admin can raise it.
    "subscription_sharing_workplace_individual_usage_limit_exceeded",

    // Zhipu/Z.ai (open.bigmodel.cn) error code 1308: the plan's usage limit is
    // reached, sent as HTTP 429. It resets after hours, not seconds (#11537).
    "\"code\"\\s*:\\s*\"?1308(?![0-9])",
])

let RETRYABLE_PROVIDER_ERROR_PATTERN = buildProviderErrorPattern([
    // Generic provider load, HTTP status, and server-side transient failures.
    "overloaded",
    "server_busy",
    "servers are currently busy",
    "currently experiencing high demand",
    "model is at capacity",
    "rate.?limit",
    "too many requests",
    // Status codes must not be part of a longer word or number, e.g. a request id or byte count (#11057).
    "(?<![a-z0-9])(?:429|500|502|503|504|520|524)(?![a-z0-9])",
    // Also matches "The service is temporarily unavailable" (#10965).
    "service.?(?:is.?)?(?:temporarily.?)?unavailable",
    "server.?error",
    "internal.?error",

    // Wrapper/provider text for transient upstream failures, including OpenRouter
    // "Provider returned error" responses (#2264) and gateway wording such as
    // "The upstream provider returned an error" (#10842).
    "provider.?returned.?(?:an.?)?error",
    "exceeded request buffer limit while retrying upstream",
    // Gateway failure relaying the upstream response stream, sent as an OpenAI
    // Responses `response.failed` event without an error code (#10920).
    "unable to forward upstream",
    // Other gateway upstream failures relayed as `response.failed` error codes (#10920).
    "upstream.?request.?failed",
    "upstream_stream_read_error",
    "stream was interrupted",
    "http/?2 stream failed",

    // Network, proxy, and fetch transport failures. This includes OpenAI Codex
    // raw-fetch failures such as "upstream connect", "connection refused", and
    // "reset before headers" (#733), plus OpenRouter connection drops (#3317).
    "network.?error",
    "connection.?error",
    "connection.?refused",
    "connection.?lost",
    "other side closed",
    "fetch failed",
    // node-fetch system errors, e.g. the Google ADC OAuth token refresh used by
    // google-vertex. The reason is often empty (#10996).
    "request to \\S+ failed, reason:",
    "getaddrinfo",
    "ENOTFOUND",
    "EAI_AGAIN",
    "upstream.?connect",
    "reset before headers",
    "socket hang up",
    "socket connection was closed",
    "timed? out",
    "timeout",
    "terminated",

    // WebSocket transports can report close/error text instead of HTTP/fetch text.
    "websocket.?closed",
    "websocket.?error",

    // Premature stream endings from SDKs and transports. Anthropic can throw
    // "stream ended without ..." and "Anthropic stream ended before message_stop"
    // (#4433); Bedrock/Smithy can throw an HTTP/2 no-response error (#3594).
    "ended without",
    "stream ended before message_stop",
    "stream ended before a terminal response event",
    "http2 request did not get a response",
    // Codex CLI mid-stream disconnect, relayed by proxies that wrap the Codex CLI,
    // e.g. "stream disconnected before completion: stream closed before response.completed" (#11057).
    "stream disconnected before completion",
    // Node ERR_HTTP2_STREAM_CANCEL: the HTTP/2 session died before the request was
    // sent, e.g. after the Bedrock SDK's 5-minute session timeout (#10379).
    "pending stream has been canceled",

    // Provider-requested retry delay cap failures should flow through the outer
    // retry policy so callers can surface/abort the backoff (#1123).
    "retry delay",

    // Explicit retry guidance emitted mid-stream by OpenAI Responses and Bedrock
    // stream exceptions (#6019).
    "you can retry your request",
    "try your request again",
    "please retry your request",

    // gRPC based providers (e.g. NVIDIA NIM)
    "ResourceExhausted",

    // Sign in with ChatGPT: usage or user data temporarily unavailable. Usage
    // failures can arrive mid-stream without an HTTP 503 in the message.
    "subscription_sharing_usage_unavailable",
    "subscription_sharing_user_unavailable",
])

/// Retry policy: bounded attempts with exponential backoff (`baseDelayMs * 2^(attempt-1)`).
/// `maxAgentDelayMs` caps each computed delay and defaults to 60 seconds.
/// Matches `settings.retry` (`enabled`, `maxRetries`, `baseDelayMs`, `maxAgentDelayMs`) in coding-agent; kept
/// here so the classifier and the policy-driven retry loop live together and stay reusable
/// by the SDK and other callers.
public struct RetryPolicy: Sendable, Hashable {
    public var enabled: Bool
    /// Max retry attempts (0 = no retries). The initial call never counts as a retry.
    public var maxRetries: Int
    /// Base delay in ms. Per-attempt delay is `baseDelayMs * 2^(attempt-1)` before jitter.
    public var baseDelayMs: Int
    /// Optional cap for agent-level retry delays in ms. Defaults to 60 seconds.
    public var maxAgentDelayMs: Int?
    public init(enabled: Bool, maxRetries: Int, baseDelayMs: Int, maxAgentDelayMs: Int? = nil) {
        self.enabled = enabled; self.maxRetries = maxRetries; self.baseDelayMs = baseDelayMs; self.maxAgentDelayMs = maxAgentDelayMs
    }
}

public let DEFAULT_MAX_AGENT_RETRY_DELAY_MS = 60_000

/// `Pick<RetryPolicy, "baseDelayMs" | "maxAgentDelayMs">`
public func retryDelayMs(baseDelayMs: Int, maxAgentDelayMs: Int? = nil, _ attempt: Int) -> Int {
    let delay = Double(baseDelayMs) * pow(2, Double(max(0, attempt - 1)))
    let maxSafeInteger = 9_007_199_254_740_991.0
    let safeDelay = (delay.rounded() == delay && abs(delay) <= maxSafeInteger) ? delay : maxSafeInteger
    return Int(min(safeDelay, Double(maxAgentDelayMs ?? DEFAULT_MAX_AGENT_RETRY_DELAY_MS)))
}

public func retryDelayMs(_ policy: RetryPolicy, _ attempt: Int) -> Int {
    retryDelayMs(baseDelayMs: policy.baseDelayMs, maxAgentDelayMs: policy.maxAgentDelayMs, attempt)
}

/// Optional callbacks emitted by ``retryAssistantCall`` around each retry.
public struct RetryCallbacks: Sendable {
    /// Emitted before the backoff sleep of each retry attempt (1-indexed).
    public var onRetryScheduled: (@Sendable (_ attempt: Int, _ maxAttempts: Int, _ delayMs: Int, _ errorMessage: String) async throws -> Void)?
    /// Emitted after the backoff sleep, immediately before the retried call starts.
    public var onRetryAttemptStart: (@Sendable () async throws -> Void)?
    /// Emitted once when the loop ends: success if a later call completed normally.
    public var onRetryFinished: (@Sendable (_ success: Bool, _ attempt: Int, _ finalError: String?) async throws -> Void)?
    public init(
        onRetryScheduled: (@Sendable (Int, Int, Int, String) async throws -> Void)? = nil,
        onRetryAttemptStart: (@Sendable () async throws -> Void)? = nil,
        onRetryFinished: (@Sendable (Bool, Int, String?) async throws -> Void)? = nil
    ) {
        self.onRetryScheduled = onRetryScheduled; self.onRetryAttemptStart = onRetryAttemptStart; self.onRetryFinished = onRetryFinished
    }
}

private struct RetrySleepAbortError: Error, CustomStringConvertible, LocalizedError {
    let message = "Aborted"
    var description: String { message }
    var errorDescription: String? { message }
}

private func sleep(_ ms: Int, signal: AbortSignal?) async throws {
    if signal?.aborted == true {
        throw RetrySleepAbortError()
    }
    do {
        // Swift: platform `sleep` resolves at once for ms <= 0 (setTimeout(0) upstream) and rejects on abort.
        try await PiAI.sleep(ms, signal)
    } catch {
        if signal?.aborted == true { throw RetrySleepAbortError() }
        throw error
    }
}

/// Run a single assistant-producing call with bounded retry on transient errors.
///
/// Behavior:
/// - A successful response is returned immediately. Aborts are terminal and never
///   retried, but reported as unsuccessful if they happen after a retry was scheduled.
///   Aborts during the backoff sleep are normalized to an aborted `AssistantMessage`
///   too, so callers do not need to care when cancellation happened.
/// - A non-retryable error (per ``isRetryableAssistantError``, including quota/
///   billing exhaustion) is returned immediately so deterministic errors fail fast.
/// - Otherwise retries up to `maxRetries` times with exponential backoff, emitting
///   `onRetryScheduled` before each sleep, `onRetryAttemptStart` after each sleep before
///   the retried call starts, and `onRetryFinished` once at the end (whether the loop
///   ends in success, exhausted retries, or an aborted backoff).
///
/// When `policy` is undefined or disabled, the first response is returned unchanged
/// (equivalent to calling `produce()` directly).
public func retryAssistantCall(
    _ produce: @Sendable () async throws -> AssistantMessage,
    _ policy: RetryPolicy?,
    _ signal: AbortSignal?,
    _ callbacks: RetryCallbacks? = nil
) async throws -> AssistantMessage {
    let maxAttempts = policy?.enabled == true ? policy!.maxRetries : 0

    var attempt = 0
    var lastRetry: (attempt: Int, errorMessage: String)?
    while true {
        let response = try await produce()

        // Abort: terminal but not successful. Never retry an aborted message.
        if response.stopReason == .aborted {
            if let lastRetry { try await callbacks?.onRetryFinished?(false, lastRetry.attempt, nil) }
            return response
        }

        // Success: non-error, non-abort responses return as-is.
        if response.stopReason != .error {
            if let lastRetry { try await callbacks?.onRetryFinished?(true, lastRetry.attempt, nil) }
            return response
        }

        // Non-retryable, or budget exhausted: return the final error message.
        if attempt >= maxAttempts || !isRetryableAssistantError(response) {
            if let lastRetry { try await callbacks?.onRetryFinished?(false, lastRetry.attempt, response.errorMessage) }
            return response
        }

        attempt += 1
        let retry = (attempt: attempt, errorMessage: (response.errorMessage?.isEmpty == false ? response.errorMessage! : "Unknown error"))
        lastRetry = retry
        let delayMs = retryDelayMs(policy!, attempt)
        try await callbacks?.onRetryScheduled?(attempt, maxAttempts, delayMs, retry.errorMessage)

        // Normalize aborts during retry backoff to the same AssistantMessage shape as
        // provider stream aborts, so callers do not need to care when cancellation happened.
        do {
            try await sleep(delayMs, signal: signal)
        } catch {
            try await callbacks?.onRetryFinished?(false, attempt, retry.errorMessage)
            if error is RetrySleepAbortError {
                var rest = response
                rest.errorMessage = nil
                rest.stopReason = .aborted
                return rest
            }
            throw error
        }
        try await callbacks?.onRetryAttemptStart?()
    }
}

/// Classifies whether a failed assistant message looks like a transient provider
/// or transport error, so callers can decide if the last assistant turn should be
/// restarted.
///
/// This does not implement retry policy. Callers should first handle context
/// overflow separately, then apply their own retry budget, backoff, and reporting
/// before restarting the assistant turn.
public func isRetryableAssistantError(_ message: AssistantMessage) -> Bool {
    guard message.stopReason == .error, let errorMessage = message.errorMessage, !errorMessage.isEmpty else { return false }
    if jsRegexTest(NON_RETRYABLE_PROVIDER_LIMIT_ERROR_PATTERN, errorMessage) { return false }
    return jsRegexTest(RETRYABLE_PROVIDER_ERROR_PATTERN, errorMessage)
}
