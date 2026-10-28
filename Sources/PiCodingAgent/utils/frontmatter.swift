// Port: packages/coding-agent/src/utils/frontmatter.ts @ 42cb822f1c5d3153069dd0661bfd297424666cf1
import Foundation
import PiAI
import Yams

public struct ParsedFrontmatter: Sendable {
    public var frontmatter: JsonValue
    public var body: String
}

public func parseFrontmatter(_ content: String) throws -> ParsedFrontmatter {
    let stripped = content.hasPrefix("\u{feff}") ? String(content.dropFirst()) : content
    let normalized = stripped.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
    guard normalized.hasPrefix("---"),
          let end = normalized.range(of: "\n---", range: normalized.index(normalized.startIndex, offsetBy: 3)..<normalized.endIndex)
    else { return .init(frontmatter: .emptyObject, body: normalized) }
    let start = normalized.index(normalized.startIndex, offsetBy: min(4, normalized.count))
    let yaml = start <= end.lowerBound ? String(normalized[start..<end.lowerBound]) : ""
    let body = String(normalized[end.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
    // yaml npm uses YAML 1.2 core schema. Yams' default resolver is YAML 1.1:
    // use explicit rules so yes/no/on/off and dates stay strings.
    let resolver = try Resolver.basic
        .appending(.bool, "^(?:true|True|TRUE|false|False|FALSE)$")
        .appending(.null, "^(?:~|null|Null|NULL|)$")
        .appending(.int, "^[-+]?(?:[0-9]+|0o[0-7]+|0x[0-9a-fA-F]+)$")
        .appending(.float, "^[-+]?(?:[0-9]*\\.[0-9]+(?:[eE][-+]?[0-9]+)?|[0-9]+[eE][-+]?[0-9]+)$")
    // libyaml needs the terminating line break for clipped block scalars at EOF;
    // npm yaml retains it even when extractFrontmatter sliced it off.
    guard let node = try compose(yaml: yaml + "\n", resolver) else { return .init(frontmatter: .emptyObject, body: body) }
    var budget = 100_000
    return try .init(frontmatter: frontmatterJSON(node, depth: 0, budget: &budget), body: body)
}

private func frontmatterJSON(_ node: Node, depth: Int, budget: inout Int) throws -> JsonValue {
    guard depth < 64 else { throw PiError("YAML nesting exceeds 64 levels") }
    budget -= 1
    guard budget >= 0 else { throw PiError("YAML alias expansion exceeds node limit") }
    switch node {
    case .scalar(let scalar):
        switch Tag.Name(rawValue: node.tag.rawValue) {
        case .null: return .null
        case .bool: return .bool(scalar.string.lowercased() == "true")
        case .int, .float:
            if let number = Double(scalar.string) { return .number(number) }
            if scalar.string.hasPrefix("0x"), let n = UInt64(scalar.string.dropFirst(2), radix: 16) { return .number(Double(n)) }
            if scalar.string.hasPrefix("0o"), let n = UInt64(scalar.string.dropFirst(2), radix: 8) { return .number(Double(n)) }
            return .string(scalar.string)
        default: return .string(scalar.string)
        }
    case .sequence(let sequence): return try .array(sequence.map { try frontmatterJSON($0, depth: depth + 1, budget: &budget) })
    case .mapping(let mapping):
        var object = JsonObject()
        for (key, value) in mapping {
            guard let key = key.string else { throw PiError("YAML mapping keys must be strings") }
            guard !object.contains(key) else { throw PiError("Map keys must be unique: \(key)") }
            object[key] = try frontmatterJSON(value, depth: depth + 1, budget: &budget)
        }
        return .object(object)
    case .alias: throw PiError("Unresolved YAML alias")
    }
}
public func stripFrontmatter(_ content: String) throws -> String { try parseFrontmatter(content).body }
