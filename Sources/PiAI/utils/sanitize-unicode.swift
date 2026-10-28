import Foundation

// Port of utils/sanitize-unicode.ts

/// Removes unpaired Unicode surrogate characters from a string.
///
/// Unpaired surrogates (high surrogates 0xD800-0xDBFF without matching low surrogates 0xDC00-0xDFFF,
/// or vice versa) cause JSON serialization errors in many API providers.
///
/// Valid emoji and other characters outside the Basic Multilingual Plane use properly paired
/// surrogates and will NOT be affected by this function.
///
/// Swift: a `String` is always valid Unicode, so it cannot hold an unpaired surrogate (decoding
/// replaces one with U+FFFD). The UTF-16 scan below mirrors the upstream regex and is a no-op
/// for every well-formed `String`.
public func sanitizeSurrogates(_ text: String) -> String {
    let units = Array(text.utf16)
    var output: [UInt16] = []
    output.reserveCapacity(units.count)
    var changed = false
    var i = 0
    while i < units.count {
        let unit = units[i]
        if (0xD800...0xDBFF).contains(unit) {
            if i + 1 < units.count, (0xDC00...0xDFFF).contains(units[i + 1]) {
                output.append(unit)
                output.append(units[i + 1])
                i += 2
                continue
            }
            changed = true
            i += 1
            continue
        }
        if (0xDC00...0xDFFF).contains(unit) {
            changed = true
            i += 1
            continue
        }
        output.append(unit)
        i += 1
    }
    return changed ? String(decoding: output, as: UTF16.self) : text
}
