import Foundation

// Port of utils/uuid.ts

private let MAX_UUID_V7_TIMESTAMP = 0xffffffffffff
private let MAX_SEQUENCE: UInt64 = (1 << 41) - 1

private struct UuidState {
    var lastOrdinaryTimestamp = -1
    var sequence: UInt64?
}

private let uuidState = Locked(UuidState())

/// Generate a time-ordered UUIDv7. A supplied timestamp is preserved for follower ids.
public func uuidv7(_ timestampMs: Int? = nil) throws -> String {
    let hooks = uuidTestHooks.current
    let requestedTimestamp = timestampMs ?? (hooks.now?() ?? dateNow())
    if requestedTimestamp < 0 || requestedTimestamp > MAX_UUID_V7_TIMESTAMP {
        throw PiError("UUIDv7 timestamp must be an integer between 0 and \(MAX_UUID_V7_TIMESTAMP)", name: "RangeError")
    }

    var bytes = [UInt8](repeating: 0, count: 16)
    if let getRandomValues = hooks.getRandomValues {
        getRandomValues(&bytes)
    } else {
        var generator = SystemRandomNumberGenerator()
        for index in bytes.indices { bytes[index] = UInt8.random(in: 0...255, using: &generator) }
    }

    let (effectiveTimestamp, sequence): (Int, UInt64) = try uuidState.withLock { state in
        let effectiveTimestamp = timestampMs == nil ? max(requestedTimestamp, state.lastOrdinaryTimestamp) : timestampMs!
        if timestampMs == nil { state.lastOrdinaryTimestamp = effectiveTimestamp }
        if let current = state.sequence {
            if current == MAX_SEQUENCE { throw PiError("UUIDv7 generator sequence exhausted", name: "RangeError") }
            state.sequence = current + 1
        } else {
            state.sequence =
                (UInt64(bytes[1]) << 32) |
                (UInt64(bytes[2]) << 24) |
                (UInt64(bytes[3]) << 16) |
                (UInt64(bytes[4]) << 8) |
                UInt64(bytes[5])
        }
        return (effectiveTimestamp, state.sequence!)
    }

    let timestamp = UInt64(effectiveTimestamp)
    for index in stride(from: 5, through: 0, by: -1) {
        bytes[index] = UInt8((timestamp >> UInt64((5 - index) * 8)) & 0xff)
    }
    bytes[6] = 0x70 | UInt8((sequence >> 37) & 0x0f)
    bytes[7] = UInt8((sequence >> 29) & 0xff)
    bytes[8] = 0x80 | UInt8((sequence >> 23) & 0x3f)
    bytes[9] = UInt8((sequence >> 15) & 0xff)
    bytes[10] = UInt8((sequence >> 7) & 0xff)
    bytes[11] = UInt8((sequence & 0x7f) << 1) | (bytes[11] & 0x01)

    let hex = bytes.map { String(format: "%02x", $0) }
    return "\(hex[0..<4].joined())-\(hex[4..<6].joined())-\(hex[6..<8].joined())-\(hex[8..<10].joined())-\(hex[10...].joined())"
}

/// Test hooks standing in for fake timers and a stubbed `crypto.getRandomValues`.
struct UuidTestHooks: Sendable {
    var now: (@Sendable () -> Int)?
    var getRandomValues: (@Sendable (inout [UInt8]) -> Void)?
}

let uuidTestHooks = Locked(UuidTestHooks())

/// Test hook: reset the module-level generator state (fresh module import upstream).
func resetUuidv7StateForTesting(lastOrdinaryTimestamp: Int = -1, sequence: UInt64? = nil) {
    uuidState.withLock { $0 = UuidState(lastOrdinaryTimestamp: lastOrdinaryTimestamp, sequence: sequence) }
}
