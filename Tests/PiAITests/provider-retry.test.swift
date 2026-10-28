import Foundation
import Testing
@testable import PiAI

private struct TestProviderError: ProviderError, LocalizedError, Equatable {
    let id = UUID()
    var status: Int?
    var headers: Headers?
    var errorDescription: String? { "Provider error: \(status.map(String.init) ?? "undefined")" }
    static func == (lhs: TestProviderError, rhs: TestProviderError) -> Bool { lhs.id == rhs.id }
}

private func providerError(_ status: Int?, _ headers: [String: String]? = nil) -> TestProviderError {
    TestProviderError(status: status, headers: Headers(headers ?? [:]))
}

/// `vi.fn()` replacement: rejects with the queued errors in order, then repeats the last outcome.
private final class MockRequest: Sendable {
    private let state: Locked<(calls: Int, outcomes: [Result<String, TestProviderError>])>
    init(_ outcomes: [Result<String, TestProviderError>]) { state = Locked((0, outcomes)) }
    var calls: Int { state.current.calls }
    @Sendable func callAsFunction() async throws -> String {
        let outcome = state.withLock { s -> Result<String, TestProviderError> in
            let outcome = s.outcomes.count > 1 ? s.outcomes.removeFirst() : s.outcomes[0]
            s.calls += 1
            return outcome
        }
        return try outcome.get()
    }
}

/// Swift: there is no fake-timer injection in `retryProviderRequest` (it uses the real platform `sleep`),
/// so timer-advancing tests use scaled-down real delays (100 ms instead of 1-2 s).
@Suite
struct ProviderRetryTests {
    @Test("retries retryable provider errors")
    func retriesRetryable() async throws {
        let request = MockRequest([.failure(providerError(429, ["retry-after-ms": "100"])), .success("ok")])

        let result = Task { try await retryProviderRequest({ try await request() }, ProviderRetryOptions(maxRetries: 1)) }
        try await Task.sleep(nanoseconds: 50_000_000)
        #expect(request.calls == 1)

        #expect(try await result.value == "ok")
        #expect(request.calls == 2)
    }

    @Test("does not retry errors the provider marks as non-retryable")
    func nonRetryableHeader() async {
        let error = providerError(429, ["x-should-retry": "false"])
        let request = MockRequest([.failure(error)])

        await #expect(throws: error) { try await retryProviderRequest({ try await request() }, ProviderRetryOptions(maxRetries: 2)) }
        #expect(request.calls == 1)
    }

    @Test("does not retry statuses listed in noRetryStatuses")
    func noRetryStatuses() async {
        let error = providerError(504, ["retry-after-ms": "0"])
        let request = MockRequest([.failure(error)])

        await #expect(throws: error) {
            try await retryProviderRequest({ try await request() }, ProviderRetryOptions(maxRetries: 2, noRetryStatuses: [504]))
        }
        #expect(request.calls == 1)
    }

    @Test("rejects a provider-requested retry delay above the limit")
    func rejectsDelayAboveLimit() async {
        let request = MockRequest([.failure(providerError(429, ["retry-after": "277403"]))])

        await #expect {
            try await retryProviderRequest({ try await request() }, ProviderRetryOptions(maxRetries: 1, maxRetryDelayMs: 1000))
        } throws: { error in
            errorMessage(error).contains("Server requested 277403s retry delay (max: 1s)")
        }
        #expect(request.calls == 1)
    }

    @Test("allows disabling the provider-requested retry delay cap")
    func disablesCap() async throws {
        let request = MockRequest([.failure(providerError(429, ["retry-after": "0.1"])), .success("ok")])

        let result = Task { try await retryProviderRequest({ try await request() }, ProviderRetryOptions(maxRetries: 1, maxRetryDelayMs: 0)) }
        try await Task.sleep(nanoseconds: 50_000_000)
        #expect(request.calls == 1)

        #expect(try await result.value == "ok")
        #expect(request.calls == 2)
    }

    // Not ported: `vi.getTimerCount()` assertions — there is no timer registry to inspect in Swift.
    @Test("aborts a provider-requested retry delay")
    func abortsDelay() async throws {
        let controller = AbortController()
        let request = MockRequest([.failure(providerError(429, ["retry-after": "277403"]))])

        let result = Task {
            try await retryProviderRequest(
                { try await request() },
                ProviderRetryOptions(maxRetries: 2, maxRetryDelayMs: 0, signal: controller.signal)
            )
        }
        try await Task.sleep(nanoseconds: 20_000_000)
        #expect(request.calls == 1)

        controller.abort()

        await #expect {
            _ = try await result.value
        } throws: { error in
            (error as? PiError)?.name == "AbortError"
        }
        #expect(request.calls == 1)
    }
}
