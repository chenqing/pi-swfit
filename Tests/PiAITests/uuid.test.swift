import Foundation
import Testing
@testable import PiAI

private let UUID_V7_RE = try! NSRegularExpression(pattern: "^[0-9a-f]{8}-[0-9a-f]{4}-7[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$")
private let TIMESTAMP = 0x0123456789ab

private func parseTimestamp(_ uuid: String) -> Int {
    Int(String(uuid.replacingOccurrences(of: "-", with: "").prefix(12)), radix: 16)!
}

private func matchesUuidV7(_ id: String) -> Bool {
    UUID_V7_RE.firstMatch(in: id, range: NSRange(id.startIndex..., in: id)) != nil
}

/// Swift: `vi.useFakeTimers()` / `vi.stubGlobal("crypto", ...)` -> `uuidTestHooks`; afterEach restores them.
@Suite(.serialized)
struct UuidTests {
    init() {
        uuidTestHooks.withLock { $0 = UuidTestHooks() }
        resetUuidv7StateForTesting()
    }

    private func restore() {
        uuidTestHooks.withLock { $0 = UuidTestHooks() }
    }

    @Test("generates ordered UUIDv7s while preserving follower timestamps")
    func generatesOrdered() throws {
        defer { restore() }
        let now = Locked(TIMESTAMP)
        uuidTestHooks.withLock { $0.now = { now.current } }

        let first = try uuidv7()
        let second = try uuidv7()
        now.withLock { $0 = TIMESTAMP - 1 }
        let afterRollback = try uuidv7()
        now.withLock { $0 = TIMESTAMP + 1 }
        let afterAdvance = try uuidv7()
        let ordinaryIds = [first, second, afterRollback, afterAdvance]
        let followerTimestamp = TIMESTAMP - 1_000
        let followers = [try uuidv7(followerTimestamp), try uuidv7(followerTimestamp)]

        for id in ordinaryIds + followers { #expect(matchesUuidV7(id), "\(id)") }
        #expect(ordinaryIds == ordinaryIds.sorted())
        #expect(Set(ordinaryIds).count == ordinaryIds.count)
        #expect(ordinaryIds.map(parseTimestamp) == [TIMESTAMP, TIMESTAMP, TIMESTAMP, TIMESTAMP + 1])
        #expect(followers.map(parseTimestamp) == [followerTimestamp, followerTimestamp])
        #expect(Set(followers).count == followers.count)
    }

    @Test("uses fresh randomness for every UUID tail")
    func freshRandomness() throws {
        defer { restore() }
        let randomByte = Locked<UInt8>(0)
        uuidTestHooks.withLock {
            $0.getRandomValues = { bytes in
                let value = randomByte.withLock { b -> UInt8 in b += 1; return b }
                for index in bytes.indices { bytes[index] = value }
            }
        }

        #expect([String(try uuidv7(TIMESTAMP).suffix(8)), String(try uuidv7(TIMESTAMP).suffix(8))] == ["01010101", "02020202"])
    }

    @Test("accepts timestamp boundary %s", arguments: [0, 281_474_976_710_655 /* 2 ** 48 - 1 */])
    func acceptsBoundary(_ timestamp: Int) throws {
        #expect(parseTimestamp(try uuidv7(timestamp)) == timestamp)
    }

    // Not ported: 1.5, NaN and Infinity cases — the Swift `uuidv7` takes an `Int` timestamp, so they are unrepresentable.
    @Test("rejects invalid timestamp %s", arguments: [-1, 281_474_976_710_656 /* 2 ** 48 */])
    func rejectsInvalid(_ timestamp: Int) {
        #expect {
            _ = try uuidv7(timestamp)
        } throws: { error in
            (error as? PiError)?.name == "RangeError"
        }
    }
}
