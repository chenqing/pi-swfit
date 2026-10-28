import Foundation

// Port of utils/hash.ts

/// Fast deterministic hash to shorten long strings
public func shortHash(_ str: String) -> String {
    var h1: UInt32 = 0xdeadbeef
    var h2: UInt32 = 0x41c6ce57
    for ch in str.utf16 {
        let c = UInt32(ch)
        h1 = (h1 ^ c) &* 2654435761
        h2 = (h2 ^ c) &* 1597334677
    }
    h1 = ((h1 ^ (h1 >> 16)) &* 2246822507) ^ ((h2 ^ (h2 >> 13)) &* 3266489909)
    h2 = ((h2 ^ (h2 >> 16)) &* 2246822507) ^ ((h1 ^ (h1 >> 13)) &* 3266489909)
    return String(h2, radix: 36) + String(h1, radix: 36)
}
