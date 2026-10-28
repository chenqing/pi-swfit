import Foundation
import Testing
@testable import PiAI

// Port of packages/ai/test/oauth-device-code.test.ts
// `vi.useFakeTimers()` -> `OAuthTestHarness` virtual clock: each sleep advances time at once, so the
// "nothing polled after 1999 ms" checks become checks on the recorded sleep durations and poll times.

@Suite struct OAuthDeviceCodePollingTests {
    private let start = 1_773_014_400_000 // 2026-03-09T00:00:00Z

    @Test func pollsImmediatelyAndReturnsTheCompletedValue() async throws {
        let h = OAuthTestHarness(now: start)
        let pollTimes = Locked<[Int]>([])
        let result = try await pollOAuthDeviceCodeFlow(OAuthDeviceCodePollOptions<String>(
            intervalSeconds: 2,
            expiresInSeconds: 30,
            poll: {
                let count = pollTimes.withLock { $0.append(h.now); return $0.count }
                return count == 1 ? .pending : .complete(value: "token")
            },
            signal: AbortController().signal
        ), runtime: h.runtime)
        #expect(result == "token")
        #expect(pollTimes.current == [start, start + 2000])
        #expect(h.sleeps.current == [2000])
    }

    @Test func canWaitBeforeTheFirstPoll() async throws {
        let h = OAuthTestHarness(now: start)
        let pollTimes = Locked<[Int]>([])
        let result = try await pollOAuthDeviceCodeFlow(OAuthDeviceCodePollOptions<String>(
            intervalSeconds: 2,
            expiresInSeconds: 30,
            waitBeforeFirstPoll: true,
            poll: {
                pollTimes.withLock { $0.append(h.now) }
                return .complete(value: "token")
            },
            signal: AbortController().signal
        ), runtime: h.runtime)
        #expect(result == "token")
        #expect(pollTimes.current == [start + 2000])
    }

    @Test func increasesTheIntervalBy5SecondsAfterSlowDownWithoutAServerInterval() async throws {
        let h = OAuthTestHarness(now: start)
        let pollTimes = Locked<[Int]>([])
        let results = Locked<[OAuthDeviceCodePollResult<String>]>([.slow_down(), .complete(value: "token")])
        let result = try await pollOAuthDeviceCodeFlow(OAuthDeviceCodePollOptions<String>(
            intervalSeconds: 2,
            expiresInSeconds: 900,
            poll: {
                pollTimes.withLock { $0.append(h.now) }
                guard let next = results.withLock({ $0.isEmpty ? nil : $0.removeFirst() }) else { throw PiError("Unexpected extra poll") }
                return next
            },
            signal: AbortController().signal
        ), runtime: h.runtime)
        #expect(result == "token")
        #expect(pollTimes.current == [start, start + 7000])
    }

    @Test func honorsAServerProvidedSlowDownInterval() async throws {
        let h = OAuthTestHarness(now: start)
        let pollTimes = Locked<[Int]>([])
        let results = Locked<[OAuthDeviceCodePollResult<String>]>([.slow_down(intervalSeconds: 30), .complete(value: "token")])
        let result = try await pollOAuthDeviceCodeFlow(OAuthDeviceCodePollOptions<String>(
            intervalSeconds: 2,
            expiresInSeconds: 900,
            poll: {
                pollTimes.withLock { $0.append(h.now) }
                guard let next = results.withLock({ $0.isEmpty ? nil : $0.removeFirst() }) else { throw PiError("Unexpected extra poll") }
                return next
            },
            signal: AbortController().signal
        ), runtime: h.runtime)
        #expect(result == "token")
        #expect(pollTimes.current == [start, start + 30000])
    }

    @Test func cancelsAnInFlightWait() async throws {
        let controller = AbortController()
        let task = Task {
            try await pollOAuthDeviceCodeFlow(OAuthDeviceCodePollOptions<String>(
                intervalSeconds: 5,
                expiresInSeconds: 30,
                poll: { .pending },
                signal: controller.signal
            ))
        }
        try await Task.sleep(nanoseconds: 20_000_000)
        controller.abort()
        let error = await gCaught { _ = try await task.value }
        #expect(errorMessage(error!) == "Login cancelled")
    }
}
