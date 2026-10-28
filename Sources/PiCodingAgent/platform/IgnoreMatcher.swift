import Foundation

/// Swift counterpart of the `ignore` package used by skills.ts. Rules remain ordered;
/// a negated child cannot re-include a directory excluded by a parent rule.
struct IgnoreMatcher {
    private struct Rule {
        var regex: NSRegularExpression
        var negated: Bool
        var directoryOnly: Bool
    }
    private var rules: [Rule] = []

    mutating func add(_ line: String, prefix: String) {
        var pattern = line
        while pattern.hasSuffix(" "), !pattern.hasSuffix("\\ ") { pattern.removeLast() }
        guard !pattern.isEmpty, !pattern.hasPrefix("#") else { return }
        let negated = pattern.hasPrefix("!")
        if negated { pattern.removeFirst() }
        if pattern.hasPrefix("\\!") || pattern.hasPrefix("\\#") { pattern.removeFirst() }
        let anchored = pattern.hasPrefix("/")
        if anchored { pattern.removeFirst() }
        let directoryOnly = pattern.hasSuffix("/")
        if directoryOnly { pattern.removeLast() }
        let slash = pattern.contains("/")
        let start = NSRegularExpression.escapedPattern(for: prefix) + (anchored || slash ? "" : "(?:.*/)?")
        if let regex = try? NSRegularExpression(pattern: "^" + start + Self.glob(pattern) + "$") {
            rules.append(.init(regex: regex, negated: negated, directoryOnly: directoryOnly))
        }
    }

    func ignores(_ path: String, isDirectory: Bool) -> Bool {
        let components = path.split(separator: "/")
        for count in 1...max(1, components.count) {
            let part = components.prefix(count).joined(separator: "/")
            let directory = count < components.count || isDirectory
            var ignored = false
            for rule in rules where !rule.directoryOnly || directory {
                if rule.regex.firstMatch(in: part, range: NSRange(part.startIndex..., in: part)) != nil { ignored = !rule.negated }
            }
            if ignored { return true }
        }
        return false
    }

    static func glob(_ pattern: String) -> String {
        let chars = Array(pattern); var index = 0; var result = ""
        while index < chars.count {
            let char = chars[index]
            if char == "*" {
                if index + 1 < chars.count, chars[index + 1] == "*" {
                    index += 1
                    if index + 1 < chars.count, chars[index + 1] == "/" { result += "(?:.*/)?"; index += 1 }
                    else { result += ".*" }
                } else { result += "[^/]*" }
            } else if char == "?" { result += "[^/]" }
            else if char == "[", let end = chars[(index + 1)...].firstIndex(of: "]") {
                var expression = String(chars[(index + 1)..<end])
                if expression.hasPrefix("!") { expression.replaceSubrange(expression.startIndex...expression.startIndex, with: "^") }
                result += "[" + expression + "]"; index = end
            } else if char == "\\", index + 1 < chars.count {
                index += 1; result += NSRegularExpression.escapedPattern(for: String(chars[index]))
            } else { result += NSRegularExpression.escapedPattern(for: String(char)) }
            index += 1
        }
        return result
    }
}
