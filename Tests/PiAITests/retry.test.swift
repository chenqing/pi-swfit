import Foundation
import Testing
@testable import PiAI

private let openAIExplicitRetryMessage =
    "An error occurred while processing your request. You can retry your request, or contact us through our help center at help.openai.com if the error persists. Please include the request ID req_******** in your message."
private let bedrockExplicitRetryMessage =
    "{\"message\":\"The system encountered an unexpected error during processing. Try your request again.\"}"
private let nvidiaNIMResourceExhaustedMessage = "ResourceExhausted: Worker local total request limit reached (288/48)"
private let bunFetchSocketClosedMessage =
    "The socket connection was closed unexpectedly. For more information, pass `verbose: true` in the second argument to fetch()"
private let openAIResponsesEarlyEofMessage = "OpenAI Responses stream ended before a terminal response event"
private let wrappedDnsLookupError =
    "The pending stream has been canceled (caused by: getaddrinfo ENOTFOUND bedrock-runtime.us-east-1.amazonaws.com)"
private let azurePeakLoadError =
    "The system is currently experiencing high demand and cannot process your request. Your request exceeds the maximum usage size allowed during peak load. For improved capacity reliability, consider switching to Provisioned Throughput."

private func errorMsg(_ errorMessage: String) -> AssistantMessage {
    fauxAssistantMessage("", stopReason: .error, errorMessage: errorMessage)
}

/// `vi.fn()` replacement recording every call's arguments.
private final class Recorder<Args: Sendable>: Sendable {
    private let state = Locked<[Args]>([])
    func record(_ args: Args) { state.withLock { $0.append(args) } }
    var calls: [Args] { state.current }
    var count: Int { state.current.count }
}

private final class Counter: Sendable {
    private let state = Locked(0)
    @discardableResult func next() -> Int { state.withLock { $0 += 1; return $0 } }
    var value: Int { state.current }
}

private struct FinishedCall: Sendable, Equatable {
    var success: Bool
    var attempt: Int
    var finalError: String?
}

@Suite
struct RetryTests {
    // MARK: provider retry classification

    @Test("matches explicit provider retry guidance")
    func explicitRetryGuidance() {
        #expect(isRetryableAssistantError(errorMsg(openAIExplicitRetryMessage)) == true)
        #expect(isRetryableAssistantError(errorMsg(bedrockExplicitRetryMessage)) == true)
        #expect(isRetryableAssistantError(errorMsg(nvidiaNIMResourceExhaustedMessage)) == true)
    }

    @Test("matches Bun fetch socket drop wording")
    func bunSocketDrop() {
        #expect(isRetryableAssistantError(errorMsg(bunFetchSocketClosedMessage)) == true)
    }

    @Test("matches upstream request buffer exhaustion wording")
    func requestBufferExhaustion() {
        #expect(isRetryableAssistantError(errorMsg("Error: exceeded request buffer limit while retrying upstream")) == true)
    }

    @Test("matches DNS transport failure wording: %s", arguments: [
        wrappedDnsLookupError,
        "connect ENOTFOUND api.example.com",
        "EAI_AGAIN api.example.com",
        "getaddrinfo failed for api.example.com",
    ])
    func dnsTransportFailure(_ errorMessage: String) {
        #expect(isRetryableAssistantError(errorMsg(errorMessage)) == true)
    }

    @Test("matches HTTP/2 pending stream cancellation: %s", arguments: [
        "The pending stream has been canceled",
        "The pending stream has been canceled (caused by: socket closed)",
    ])
    func pendingStreamCancellation(_ errorMessage: String) {
        // Regression for #10379.
        #expect(isRetryableAssistantError(errorMsg(errorMessage)) == true)
    }

    @Test("matches service unavailable wording: %s", arguments: [
        // Regression for #10965 (provider unknown, no status code in the message).
        "The service is temporarily unavailable. Please retry later.",
        // Bedrock ServiceUnavailableException as formatted by formatBedrockError.
        "Service unavailable: The service is temporarily unavailable.",
    ])
    func serviceUnavailable(_ errorMessage: String) {
        #expect(isRetryableAssistantError(errorMsg(errorMessage)) == true)
    }

    @Test("matches node-fetch request failure wording: %s", arguments: [
        // Regression for #10996: node-fetch errors from the google-vertex OAuth token refresh.
        "request to https://oauth2.googleapis.com/token failed, reason:",
        "request to https://oauth2.googleapis.com/token failed, reason: connect ECONNREFUSED 127.0.0.1:9",
    ])
    func nodeFetchFailure(_ errorMessage: String) {
        #expect(isRetryableAssistantError(errorMsg(errorMessage)) == true)
    }

    @Test("matches gateway upstream failure wording: %s", arguments: [
        // Regression for #10920: gateway upstream failures sent as `response.failed` error codes.
        "unknown: Unable to forward upstream stream",
        "upstream_error: Upstream request failed",
        "upstream_stream_read_error: Upstream response stream was interrupted",
        "Upstream HTTP/2 stream failed",
    ])
    func gatewayUpstreamFailure(_ errorMessage: String) {
        #expect(isRetryableAssistantError(errorMsg(errorMessage)) == true)
    }

    @Test("matches OpenAI Responses streams that end before terminal events")
    func responsesEarlyEof() {
        #expect(isRetryableAssistantError(errorMsg(openAIResponsesEarlyEofMessage)) == true)
    }

    @Test("matches Azure peak-load capacity errors")
    func azurePeakLoad() {
        // Regression for #9669.
        #expect(isRetryableAssistantError(errorMsg(azurePeakLoadError)) == true)
    }

    @Test("keeps provider limit errors non-retryable")
    func providerLimitNonRetryable() {
        #expect(isRetryableAssistantError(errorMsg("429 quota exceeded")) == false)
    }

    @Test("keeps the ChatGPT subscription usage limit non-retryable")
    func subscriptionUsageLimit() {
        let errorMessage =
            "OpenAI API error (429): {\"code\":\"subscription_sharing_usage_limit_exceeded\",\"message\":\"Usage limit reached.\"}"
        #expect(isRetryableAssistantError(errorMsg(errorMessage)) == false)
    }

    @Test("keeps the ChatGPT Business workspace usage limit non-retryable")
    func workspaceUsageLimit() {
        let errorMessage =
            "OpenAI API error (429): {\"code\":\"subscription_sharing_workplace_individual_usage_limit_exceeded\",\"message\":\"Usage limit reached.\"}"
        #expect(isRetryableAssistantError(errorMsg(errorMessage)) == false)
    }

    // Swift-only: checks the escaping of the Zhipu 1308 and Codex CLI patterns (upstream has no test).
    @Test("keeps the Zhipu usage limit (code 1308) non-retryable")
    func zhipuUsageLimit() {
        #expect(isRetryableAssistantError(errorMsg("429 {\"error\":{\"code\":\"1308\",\"message\":\"Usage limit reached\"}}")) == false)
        #expect(isRetryableAssistantError(errorMsg("429 {\"error\":{\"code\": 1308}}")) == false)
        #expect(isRetryableAssistantError(errorMsg("429 {\"error\":{\"code\":\"13080\"}}")) == true)
        #expect(isRetryableAssistantError(errorMsg("stream disconnected before completion: stream closed before response.completed")) == true)
    }

    @Test("retries temporary ChatGPT subscription errors: %s", arguments: [
        "subscription_sharing_usage_unavailable: Usage cannot be checked.",
        "subscription_sharing_user_unavailable: User cannot be loaded.",
    ])
    func temporarySubscriptionErrors(_ errorMessage: String) {
        #expect(isRetryableAssistantError(errorMsg(errorMessage)) == true)
    }

    @Test("classifies assistant error messages")
    func classifies() {
        #expect(isRetryableAssistantError(errorMsg("overloaded_error")) == true)
        // Regression for #9627.
        #expect(isRetryableAssistantError(errorMsg("520 status code (no body)")) == true)
        #expect(isRetryableAssistantError(errorMsg("524 status code (no body)")) == true)
        #expect(isRetryableAssistantError(fauxAssistantMessage("not an error")) == false)
    }

    @Test("does not match status codes inside ids or longer numbers: %s", arguments: [
        // Regression for #11057: status codes inside ids or other numbers are not status codes.
        "401 {\"type\":\"error\",\"error\":{\"type\":\"authentication_error\",\"message\":\"invalid x-api-key\"},\"request_id\":\"req_011CU503xyz\"}",
        "400 image exceeds 5 MB maximum: 5316784 bytes > 5242880 bytes",
    ])
    func statusCodesInsideNumbers(_ errorMessage: String) {
        #expect(isRetryableAssistantError(errorMsg(errorMessage)) == false)
    }

    // MARK: retryDelayMs

    @Test("caps agent retry delay")
    func capsAgentRetryDelay() {
        // Regression for #8826.
        #expect(retryDelayMs(baseDelayMs: 2000, 6) == 60000)
        #expect(retryDelayMs(baseDelayMs: 2000, maxAgentDelayMs: 5000, 5) == 5000)
        #expect(retryDelayMs(baseDelayMs: 2000, maxAgentDelayMs: 0, 5) == 0)
    }

    // MARK: retryAssistantCall

    private let disabled = RetryPolicy(enabled: false, maxRetries: 3, baseDelayMs: 0)
    private let enabled = RetryPolicy(enabled: true, maxRetries: 3, baseDelayMs: 0)

    @Test("returns a successful response immediately without retrying")
    func successImmediately() async throws {
        let produce = Counter()
        let res = try await retryAssistantCall({ produce.next(); return fauxAssistantMessage("ok") }, enabled, nil)
        #expect(res.content == [.text(TextContent(text: "ok"))])
        #expect(produce.value == 1)
    }

    @Test("does not retry an aborted message")
    func noRetryAborted() async throws {
        let produce = Counter()
        let onRetryScheduled = Recorder<Int>()
        let res = try await retryAssistantCall(
            { produce.next(); return fauxAssistantMessage("", stopReason: .aborted) },
            enabled,
            nil,
            RetryCallbacks(onRetryScheduled: { attempt, _, _, _ in onRetryScheduled.record(attempt) })
        )
        #expect(res.stopReason == .aborted)
        #expect(produce.value == 1)
        #expect(onRetryScheduled.count == 0)
    }

    @Test("does not retry a non-retryable error (quota/billing)")
    func noRetryQuota() async throws {
        let produce = Counter()
        let onRetryScheduled = Recorder<Int>()
        let onRetryFinished = Recorder<FinishedCall>()
        let res = try await retryAssistantCall(
            { produce.next(); return errorMsg("insufficient_quota") },
            enabled,
            nil,
            RetryCallbacks(
                onRetryScheduled: { attempt, _, _, _ in onRetryScheduled.record(attempt) },
                onRetryFinished: { onRetryFinished.record(FinishedCall(success: $0, attempt: $1, finalError: $2)) }
            )
        )
        #expect(res.stopReason == .error)
        #expect(produce.value == 1)
        #expect(onRetryScheduled.count == 0)
        #expect(onRetryFinished.count == 0)
    }

    @Test("retries a transient error up to maxRetries then returns the final error")
    func retriesUpToMax() async throws {
        let produce = Counter()
        let onRetryScheduled = Recorder<Int>()
        let onRetryFinished = Recorder<FinishedCall>()
        let res = try await retryAssistantCall(
            { produce.next(); return errorMsg("terminated") },
            enabled,
            nil,
            RetryCallbacks(
                onRetryScheduled: { attempt, _, _, _ in onRetryScheduled.record(attempt) },
                onRetryFinished: { onRetryFinished.record(FinishedCall(success: $0, attempt: $1, finalError: $2)) }
            )
        )
        #expect(res.stopReason == .error)
        #expect(produce.value == 4) // 1 initial + 3 retries
        #expect(onRetryScheduled.count == 3)
        #expect(onRetryFinished.calls.contains(FinishedCall(success: false, attempt: 3, finalError: "terminated")))
    }

    @Test("reports capped retry delays")
    func reportsCappedDelays() async throws {
        // Regression for #8826.
        let n = Counter()
        let policy = RetryPolicy(enabled: true, maxRetries: 4, baseDelayMs: 10, maxAgentDelayMs: 15)
        let onRetryScheduled = Recorder<Int>()

        _ = try await retryAssistantCall(
            { n.next() < 5 ? errorMsg("terminated") : fauxAssistantMessage("recovered") },
            policy,
            nil,
            RetryCallbacks(onRetryScheduled: { _, _, delayMs, _ in onRetryScheduled.record(delayMs) })
        )

        #expect(onRetryScheduled.calls == [10, 15, 15, 15])
    }

    @Test("stops retrying once a call succeeds")
    func stopsOnSuccess() async throws {
        let n = Counter()
        let onRetryFinished = Recorder<FinishedCall>()
        let res = try await retryAssistantCall(
            { n.next() < 3 ? errorMsg("terminated") : fauxAssistantMessage("recovered") },
            enabled,
            nil,
            RetryCallbacks(onRetryFinished: { onRetryFinished.record(FinishedCall(success: $0, attempt: $1, finalError: $2)) })
        )
        #expect(res.content == [.text(TextContent(text: "recovered"))])
        #expect(n.value == 3)
        #expect(onRetryFinished.calls.contains(FinishedCall(success: true, attempt: 2, finalError: nil)))
    }

    @Test("reports an aborted retried call as unsuccessful")
    func abortedRetriedCall() async throws {
        let n = Counter()
        let onRetryFinished = Recorder<FinishedCall>()
        let res = try await retryAssistantCall(
            { n.next() == 1 ? errorMsg("terminated") : fauxAssistantMessage("", stopReason: .aborted) },
            enabled,
            nil,
            RetryCallbacks(onRetryFinished: { onRetryFinished.record(FinishedCall(success: $0, attempt: $1, finalError: $2)) })
        )
        #expect(res.stopReason == .aborted)
        #expect(n.value == 2)
        #expect(onRetryFinished.calls.contains(FinishedCall(success: false, attempt: 1, finalError: nil)))
    }

    @Test("does not retry when policy is disabled")
    func disabledPolicy() async throws {
        let produce = Counter()
        let onRetryScheduled = Recorder<Int>()
        let onRetryFinished = Recorder<FinishedCall>()
        let res = try await retryAssistantCall(
            { produce.next(); return errorMsg("terminated") },
            disabled,
            nil,
            RetryCallbacks(
                onRetryScheduled: { attempt, _, _, _ in onRetryScheduled.record(attempt) },
                onRetryFinished: { onRetryFinished.record(FinishedCall(success: $0, attempt: $1, finalError: $2)) }
            )
        )
        #expect(res.stopReason == .error)
        #expect(produce.value == 1)
        #expect(onRetryScheduled.count == 0)
        #expect(onRetryFinished.count == 0)
    }

    @Test("emits onRetryAttemptStart after backoff before each retried call")
    func emitsAttemptStart() async throws {
        let events = Recorder<String>()
        let n = Locked(0)
        let onRetryScheduled = Recorder<Int>()
        let onRetryAttemptStart = Counter()
        let res = try await retryAssistantCall(
            {
                let current = n.withLock { value -> Int in
                    events.record("produce:\(value)")
                    value += 1
                    return value
                }
                return current < 3 ? errorMsg("terminated") : fauxAssistantMessage("recovered")
            },
            enabled,
            nil,
            RetryCallbacks(
                onRetryScheduled: { attempt, _, _, _ in
                    onRetryScheduled.record(attempt)
                    events.record("retry:\(attempt)")
                },
                onRetryAttemptStart: {
                    onRetryAttemptStart.next()
                    events.record("attempt-start")
                }
            )
        )
        #expect(res.content == [.text(TextContent(text: "recovered"))])
        #expect(onRetryScheduled.count == 2)
        #expect(onRetryAttemptStart.value == 2)
        #expect(events.calls == [
            "produce:0",
            "retry:1",
            "attempt-start",
            "produce:1",
            "retry:2",
            "attempt-start",
            "produce:2",
        ])
    }

    @Test("aborts backoff sleep via signal, returns an aborted message, and emits onRetryFinished(false)")
    func abortsBackoffSleep() async throws {
        let controller = AbortController()
        let produce = Counter()
        let policy = RetryPolicy(enabled: true, maxRetries: 5, baseDelayMs: 10_000)
        let onRetryFinished = Recorder<FinishedCall>()
        let p = Task {
            try await retryAssistantCall(
                { produce.next(); return errorMsg("terminated") },
                policy,
                controller.signal,
                RetryCallbacks(onRetryFinished: { onRetryFinished.record(FinishedCall(success: $0, attempt: $1, finalError: $2)) })
            )
        }
        // Let one error call resolve and the first backoff sleep start, then abort.
        while produce.value == 0 { try await Task.sleep(nanoseconds: 1_000_000) }
        controller.abort()
        let res = try await p.value
        #expect(res.stopReason == .aborted)
        #expect(res.errorMessage == nil)
        #expect(produce.value == 1)
        #expect(onRetryFinished.calls.contains(FinishedCall(success: false, attempt: 1, finalError: "terminated")))
    }
}
