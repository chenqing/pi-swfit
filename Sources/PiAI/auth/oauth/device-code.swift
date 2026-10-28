import Foundation

// Port of packages/ai/src/auth/oauth/device-code.ts
// Timers come from `OAuthRuntime` (upstream uses `Date.now()` / `setTimeout`, which its tests fake).

private let CANCEL_MESSAGE = "Login cancelled"
private let TIMEOUT_MESSAGE = "Device flow timed out"
private let SLOW_DOWN_TIMEOUT_MESSAGE =
    "Device flow timed out after one or more slow_down responses. This is often caused by clock drift in WSL or VM environments. Please sync or restart the VM clock and try again."
private let MINIMUM_INTERVAL_MS = 1000.0
// RFC 8628 section 3.2: if the authorization server omits `interval`, the client must use 5 seconds.
private let DEFAULT_POLL_INTERVAL_SECONDS = 5.0
// RFC 8628 section 3.5: `slow_down` means the polling interval must increase by 5 seconds.
private let SLOW_DOWN_INTERVAL_INCREMENT_MS = 5000.0

public enum OAuthDeviceCodePollResult<T: Sendable>: Sendable {
    case pending
    case slow_down(intervalSeconds: Double? = nil)
    case failed(message: String)
    case complete(value: T)

    /// "pending" | "slow_down" | "failed" | "complete"
    public var status: String {
        switch self {
        case .pending: return "pending"
        case .slow_down: return "slow_down"
        case .failed: return "failed"
        case .complete: return "complete"
        }
    }
}

public struct OAuthDeviceCodePollOptions<T: Sendable>: Sendable {
    public var intervalSeconds: Double?
    public var expiresInSeconds: Double?
    public var waitBeforeFirstPoll: Bool?
    public var poll: @Sendable () async throws -> OAuthDeviceCodePollResult<T>
    public var signal: AbortSignal

    public init(
        intervalSeconds: Double? = nil,
        expiresInSeconds: Double? = nil,
        waitBeforeFirstPoll: Bool? = nil,
        poll: @escaping @Sendable () async throws -> OAuthDeviceCodePollResult<T>,
        signal: AbortSignal
    ) {
        self.intervalSeconds = intervalSeconds; self.expiresInSeconds = expiresInSeconds
        self.waitBeforeFirstPoll = waitBeforeFirstPoll; self.poll = poll; self.signal = signal
    }
}

public func abortableSleep(_ ms: Int, _ signal: AbortSignal, _ cancelMessage: String) async throws {
    try await abortableSleep(ms, signal, cancelMessage, runtime: .live)
}

func abortableSleep(_ ms: Int, _ signal: AbortSignal, _ cancelMessage: String, runtime: OAuthRuntime) async throws {
    if signal.aborted {
        throw PiError(cancelMessage)
    }
    do {
        try await runtime.sleep(ms, signal)
    } catch {
        if signal.aborted { throw PiError(cancelMessage) }
        throw error
    }
}

public func pollOAuthDeviceCodeFlow<T: Sendable>(_ options: OAuthDeviceCodePollOptions<T>) async throws -> T {
    try await pollOAuthDeviceCodeFlow(options, runtime: .live)
}

func pollOAuthDeviceCodeFlow<T: Sendable>(_ options: OAuthDeviceCodePollOptions<T>, runtime: OAuthRuntime) async throws -> T {
    let deadline: Double =
        options.expiresInSeconds != nil
            ? Double(runtime.now()) + options.expiresInSeconds! * 1000
            : Double.infinity
    var intervalMs = max(
        MINIMUM_INTERVAL_MS,
        ((options.intervalSeconds ?? DEFAULT_POLL_INTERVAL_SECONDS) * 1000).rounded(.down)
    )

    var slowDownResponses = 0
    if options.waitBeforeFirstPoll == true {
        let remainingMs = deadline - Double(runtime.now())
        if remainingMs > 0 {
            try await abortableSleep(jsMillis(min(intervalMs, remainingMs)), options.signal, CANCEL_MESSAGE, runtime: runtime)
        }
    }

    while Double(runtime.now()) < deadline {
        if options.signal.aborted {
            throw PiError(CANCEL_MESSAGE)
        }

        let result = try await options.poll()
        if case .complete(let value) = result {
            return value
        }
        if case .failed(let message) = result {
            throw PiError(message)
        }
        if case .slow_down(let intervalSeconds) = result {
            slowDownResponses += 1
            // Use the server-provided interval when given (GitHub reports the new required minimum
            // in `interval`); trusting only a client-tracked value risks polling early forever under
            // WSL/VM clock drift. Otherwise apply RFC 8628 section 3.5: increase by 5 seconds.
            if let intervalSeconds, intervalSeconds.isFinite, intervalSeconds > 0 {
                intervalMs = max(MINIMUM_INTERVAL_MS, (intervalSeconds * 1000).rounded(.down))
            } else {
                intervalMs = max(MINIMUM_INTERVAL_MS, intervalMs + SLOW_DOWN_INTERVAL_INCREMENT_MS)
            }
        }

        let remainingMs = deadline - Double(runtime.now())
        if remainingMs <= 0 {
            break
        }

        try await abortableSleep(jsMillis(min(intervalMs, remainingMs)), options.signal, CANCEL_MESSAGE, runtime: runtime)
    }

    throw PiError(slowDownResponses > 0 ? SLOW_DOWN_TIMEOUT_MESSAGE : TIMEOUT_MESSAGE)
}
