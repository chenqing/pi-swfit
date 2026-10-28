import Foundation

// Port of utils/provider-retry.ts

private let DEFAULT_MAX_RETRY_DELAY_MS = 60_000

public struct ProviderRetryOptions: Sendable {
    public var maxRetries: Int?
    public var maxRetryDelayMs: Int?
    public var signal: AbortSignal?
    /// HTTP statuses that fail at once although the default policy would retry them.
    public var noRetryStatuses: [Int]?
    public init(maxRetries: Int? = nil, maxRetryDelayMs: Int? = nil, signal: AbortSignal? = nil, noRetryStatuses: [Int]? = nil) {
        self.maxRetries = maxRetries; self.maxRetryDelayMs = maxRetryDelayMs; self.signal = signal; self.noRetryStatuses = noRetryStatuses
    }
}

/// An SDK HTTP error carrying the response status and headers (`Error & { status, headers }`).
public protocol ProviderError: Error {
    var status: Int? { get }
    var headers: Headers? { get }
}

private func isProviderError(_ error: any Error) -> (any ProviderError)? {
    error as? any ProviderError
}

/// Mirrors the pinned OpenAI/Anthropic SDK retry policy; review when either SDK is upgraded.
private func isRetryableProviderError(_ error: any ProviderError) -> Bool {
    let shouldRetry = error.headers?.get("x-should-retry")
    if shouldRetry == "true" { return true }
    if shouldRetry == "false" { return false }

    guard let status = error.status else { return true }
    return status == 408 || status == 409 || status == 429 || status >= 500
}

private func validateServerRetryDelayMs(_ delayMs: Double, _ maxRetryDelayMs: Int?, _ providerErrorMessage: String) throws -> Double {
    let maxDelayMs = maxRetryDelayMs ?? DEFAULT_MAX_RETRY_DELAY_MS
    if maxDelayMs > 0 && delayMs > Double(maxDelayMs) {
        throw PiError(
            "Server requested \(JsonWriter.formatNumber((delayMs / 1000).rounded(.up)))s retry delay (max: \(JsonWriter.formatNumber((Double(maxDelayMs) / 1000).rounded(.up)))s). \(providerErrorMessage)"
        )
    }
    return delayMs
}

private func getRetryDelayMs(_ error: any ProviderError, _ retryIndex: Int, _ maxRetryDelayMs: Int?) throws -> Double {
    if let retryAfterMs = error.headers?.get("retry-after-ms"), !retryAfterMs.isEmpty {
        let value = jsParseFloat(retryAfterMs)
        if value.isFinite { return try validateServerRetryDelayMs(value, maxRetryDelayMs, errorMessage(error)) }
    }

    if let retryAfter = error.headers?.get("retry-after"), !retryAfter.isEmpty {
        let seconds = jsParseFloat(retryAfter)
        let delayMs = seconds.isNaN ? jsDateParse(retryAfter) - Double(dateNow()) : seconds * 1000
        if delayMs.isFinite { return try validateServerRetryDelayMs(delayMs, maxRetryDelayMs, errorMessage(error)) }
    }

    let exponentialDelay = min(0.5 * pow(2, Double(retryIndex)), 8) * 1000
    return exponentialDelay * (1 - Double.random(in: 0..<1) * 0.25)
}

private func createAbortError() -> PiError {
    PiError("Request aborted", name: "AbortError")
}

private func abortableSleep(_ ms: Double, _ signal: AbortSignal?) async throws {
    if signal?.aborted == true {
        throw createAbortError()
    }
    do {
        try await sleep(Int(max(0, ms).rounded(.up)), signal)
    } catch {
        if signal?.aborted == true { throw createAbortError() }
        throw error
    }
}

/// Reproduce the retry behavior used by the OpenAI and Anthropic SDKs while making
/// their backoff sleep interruptible. Their built-in retry timers ignore the
/// request AbortSignal, so callers must invoke the SDK with `maxRetries: 0` and
/// wrap the request with this helper. Provider-requested delays above
/// `maxRetryDelayMs` fail immediately (60 seconds by default); set it to zero to
/// disable the limit.
public func retryProviderRequest<T: Sendable>(
    _ request: @Sendable () async throws -> T,
    _ options: ProviderRetryOptions = ProviderRetryOptions()
) async throws -> T {
    let maxRetries = options.maxRetries ?? 0
    var retriesRemaining = maxRetries

    while true {
        do {
            // Each retry is a fresh SDK request, so X-Stainless-Retry-Count remains zero.
            return try await request()
        } catch {
            if options.signal?.aborted == true { throw createAbortError() }
            guard retriesRemaining > 0, let providerError = isProviderError(error), isRetryableProviderError(providerError) else { throw error }
            if let status = providerError.status, options.noRetryStatuses?.contains(status) == true { throw error }

            let retryIndex = maxRetries - retriesRemaining
            retriesRemaining -= 1
            try await abortableSleep(try getRetryDelayMs(providerError, retryIndex, options.maxRetryDelayMs), options.signal)
        }
    }
}

// MARK: - JS number/date parsing helpers

/// `Number.parseFloat(text)`: parses the longest leading decimal literal (after whitespace); NaN if none.
func jsParseFloat(_ text: String) -> Double {
    let scalars = Array(text.unicodeScalars.drop { isJsWhitespace($0) })
    var i = 0
    var literal = ""
    if i < scalars.count, scalars[i] == "+" || scalars[i] == "-" { literal.unicodeScalars.append(scalars[i]); i += 1 }
    let rest = String(String.UnicodeScalarView(scalars[i...]))
    if rest.hasPrefix("Infinity") { return literal == "-" ? -.infinity : .infinity }
    var digits = 0
    while i < scalars.count, ("0"..."9").contains(scalars[i]) { literal.unicodeScalars.append(scalars[i]); i += 1; digits += 1 }
    if i < scalars.count, scalars[i] == "." {
        var fraction = "."
        var j = i + 1
        var fractionDigits = 0
        while j < scalars.count, ("0"..."9").contains(scalars[j]) { fraction.unicodeScalars.append(scalars[j]); j += 1; fractionDigits += 1 }
        if digits > 0 || fractionDigits > 0 { literal += fraction; i = j; digits += fractionDigits }
    }
    if digits == 0 { return .nan }
    if i < scalars.count, scalars[i] == "e" || scalars[i] == "E" {
        var exponent = "e"
        var j = i + 1
        if j < scalars.count, scalars[j] == "+" || scalars[j] == "-" { exponent.unicodeScalars.append(scalars[j]); j += 1 }
        var exponentDigits = 0
        while j < scalars.count, ("0"..."9").contains(scalars[j]) { exponent.unicodeScalars.append(scalars[j]); j += 1; exponentDigits += 1 }
        if exponentDigits > 0 { literal += exponent }
    }
    if literal.hasSuffix(".") { literal.removeLast() }
    if literal.hasPrefix(".") || literal.hasPrefix("-.") || literal.hasPrefix("+.") { literal = literal.replacingOccurrences(of: ".", with: "0.", options: [], range: literal.range(of: ".")) }
    return Double(literal) ?? .nan
}

/// `Date.parse(text)` for the HTTP-date formats a `retry-after` header can carry (and ISO 8601). NaN otherwise.
func jsDateParse(_ text: String) -> Double {
    if let date = ISO8601DateFormatter().date(from: text) { return (date.timeIntervalSince1970 * 1000).rounded(.down) }
    let formats = ["EEE, dd MMM yyyy HH:mm:ss zzz", "EEEE, dd-MMM-yy HH:mm:ss zzz", "EEE MMM d HH:mm:ss yyyy"]
    for format in formats {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "GMT")
        formatter.dateFormat = format
        if let date = formatter.date(from: text) { return (date.timeIntervalSince1970 * 1000).rounded(.down) }
    }
    return .nan
}
