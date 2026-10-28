import Foundation

// Swift-only: the ambient globals the OAuth flows (`auth/oauth/*`) use.
//
// Upstream calls `globalThis.fetch`, `Date.now()`, `setTimeout` (via `sleep` / `abortableSleep`) and
// `process.env` directly, and its tests replace them with `vi.stubGlobal("fetch", ...)`,
// `vi.useFakeTimers()` and `vi.stubEnv(...)`. Swift cannot stub globals safely under parallel tests, so each
// flow is built from an `OAuthRuntime`; the exported flows (`anthropicOAuth`, ...) use `.live`.

struct OAuthRuntime: Sendable {
    /// `globalThis.fetch`.
    var fetch: FetchFunction
    /// `Date.now()`.
    var now: @Sendable () -> Int
    /// `sleep(ms, signal)` from utils/sleep.ts (rejects with the signal's reason on abort).
    var sleep: @Sendable (_ ms: Int, _ signal: AbortSignal?) async throws -> Void
    /// `getProviderEnvValue(name)`.
    var env: @Sendable (_ name: String) -> String?

    init(
        fetch: @escaping FetchFunction = defaultFetch,
        now: @escaping @Sendable () -> Int = { dateNow() },
        sleep: @escaping @Sendable (_ ms: Int, _ signal: AbortSignal?) async throws -> Void = { ms, signal in try await PiAI.sleep(ms, signal) },
        env: @escaping @Sendable (_ name: String) -> String? = { getProviderEnvValue($0) }
    ) {
        self.fetch = fetch; self.now = now; self.sleep = sleep; self.env = env
    }

    static let live = OAuthRuntime()

    /// `fetch(url, { method, headers, body, signal })` with a string URL.
    func fetch(
        _ url: String,
        method: String = "GET",
        headers: [(String, String)] = [],
        body: String? = nil,
        signal: AbortSignal? = nil
    ) async throws -> FetchResponse {
        guard let parsed = URL(string: url) else { throw PiError("Failed to parse URL from \(url)", name: "TypeError") }
        return try await fetch(FetchRequest(url: parsed, method: method, headers: Headers(headers), body: body.map { Data($0.utf8) }, signal: signal))
    }
}

/// Swift-only: a settle-once promise (`new Promise((resolve, reject) => ...)` with the resolvers kept outside).
final class PendingResult<T: Sendable>: Sendable {
    private struct State {
        var result: Result<T, any Error>?
        var waiters: [CheckedContinuation<T, any Error>] = []
    }

    private let state = Locked(State())

    init() {}

    /// Settle with `result`. Later calls are ignored (like calling `resolve` twice).
    func settle(_ result: Result<T, any Error>) {
        let waiters: [CheckedContinuation<T, any Error>]? = state.withLock { s in
            guard s.result == nil else { return nil }
            s.result = result
            defer { s.waiters = [] }
            return s.waiters
        }
        waiters?.forEach { $0.resume(with: result) }
    }

    func resolve(_ value: T) { settle(.success(value)) }
    func reject(_ error: any Error) { settle(.failure(error)) }

    var isSettled: Bool { state.withLock { $0.result != nil } }

    /// `await promise`.
    func value() async throws -> T {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<T, any Error>) in
            let settled: Result<T, any Error>? = state.withLock { s in
                if let result = s.result { return result }
                s.waiters.append(continuation)
                return nil
            }
            if let settled { continuation.resume(with: settled) }
        }
    }
}

/// Convert a JS millisecond number to `Int`, the way the credential stores it. Non-finite values
/// (upstream would store NaN/Infinity) clamp to 0 / ±`Number.MAX_SAFE_INTEGER`.
func jsMillis(_ value: Double) -> Int {
    if value.isNaN { return 0 }
    if value >= 9_007_199_254_740_991 { return 9_007_199_254_740_991 }
    if value <= -9_007_199_254_740_991 { return -9_007_199_254_740_991 }
    return Int(value.rounded(.towardZero))
}
