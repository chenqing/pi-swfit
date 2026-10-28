// Port of extensions/tool-search/tool.ts @ 42cb822f1c5d3153069dd0661bfd297424666cf1.
import Foundation
import PiAI
import PiAgent

public func tokenizeToolSearch(_ text: String) -> [String] {
    let stop: Set<String> = ["a", "an", "and", "are", "as", "at", "be", "by", "for", "from", "in", "is", "it", "of", "on", "or", "that", "the", "this", "to", "with"]
    let value = text.replacingOccurrences(of: "([a-z0-9])([A-Z])", with: "$1 $2", options: .regularExpression)
        .replacingOccurrences(of: "([A-Z]+)([A-Z][a-z])", with: "$1 $2", options: .regularExpression).lowercased()
    return value.components(separatedBy: CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyz0123456789").inverted)
        .filter { !$0.isEmpty && !stop.contains($0) }.map { term in
            if term.count > 4 && term.hasSuffix("ies") { return String(term.dropLast(3)) + "y" }
            if term.count > 4 && term.range(of: "(ches|shes|sses|xes|zes)$", options: .regularExpression) != nil { return String(term.dropLast(2)) }
            if term.count > 3 && term.hasSuffix("s") && !term.hasSuffix("ss") { return String(term.dropLast()) }
            return term
        }
}
public func rankTools(query: String, tools: [ExtensionToolInfo], limit: Int = 8, namespace: String? = nil) -> [ExtensionToolInfo] {
    let candidates = tools.filter { $0.exposure != .hidden && $0.exposure != .modelOnly && (namespace == nil || $0.namespace == namespace) }
    func schemaText(_ schema: JsonValue, depth: Int = 0) -> [String] {
        guard depth < 64, let value = schema.objectValue else { return [] }
        var parts = value["description"]?.stringValue.map { [$0] } ?? []
        for (name, property) in value["properties"]?.objectValue ?? JsonObject() { parts += [name] + schemaText(property, depth: depth + 1) }
        if let items = value["items"] { parts += schemaText(items, depth: depth + 1) }
        for key in ["anyOf", "oneOf", "allOf"] { for variant in value[key]?.arrayValue ?? [] { parts += schemaText(variant, depth: depth + 1) } }
        return parts
    }
    let queryTerms = Set(tokenizeToolSearch(query))
    guard !queryTerms.isEmpty, !candidates.isEmpty, limit > 0 else { return [] }
    let counts: [[String: Int]] = candidates.map { item in
        let text = ([item.tool.name, item.tool.name.replacingOccurrences(of: "_", with: " "), item.tool.description, item.namespace ?? ""] + schemaText(item.tool.parameters)).joined(separator: " ")
        return tokenizeToolSearch(text).reduce(into: [:]) { $0[$1, default: 0] += 1 }
    }
    let lengths = counts.map { $0.values.reduce(0, +) }, n = Double(candidates.count)
    let average = max(1, Double(lengths.reduce(0, +)) / n)
    let idf = Dictionary(uniqueKeysWithValues: queryTerms.map { term in
        let frequency = Double(counts.filter { $0[term] != nil }.count)
        return (term, log(1 + (n - frequency + 0.5) / (frequency + 0.5)))
    })
    let scores: [(Int, Double)] = candidates.indices.map { index in
        var score: Double = 0
        for term in queryTerms {
            let count = Double(counts[index][term] ?? 0)
            let norm = 1.2 * (1 - 0.75 + 0.75 * Double(lengths[index]) / average)
            let weight: Double = idf[term] ?? 0
            score += weight * (count * 2.2 / (count + norm))
        }
        return (index, score)
    }
    // Upstream ae823bc0b: exact full names or __ suffixes outrank BM25 length normalization.
    func normalizeName(_ name: String) -> String {
        name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            .replacingOccurrences(of: "[^a-z0-9_$]", with: "_", options: .regularExpression)
    }
    let nameQuery = normalizeName(query)
    func named(_ index: Int) -> Bool {
        let name = normalizeName(candidates[index].tool.name)
        return name == nameQuery || name.hasSuffix("__" + nameQuery)
    }
    return scores.filter { $0.1 > 0 }.sorted {
        if named($0.0) != named($1.0) { return named($0.0) }
        return $0.1 == $1.1 ? $0.0 < $1.0 : $0.1 > $1.1
    }.prefix(limit).map { candidates[$0.0] }
}
public func createToolSearchExtension() -> NativeExtension {
    .init(id: "builtin:tool-search", onEvent: { event, context in
        guard case .sessionStart = event else { return }
        let tool = AgentTool(name: "tool_search", label: "tool_search",
            description: "Search deferred tool metadata with BM25 and load matching tools for the next model call. Use this to find MCP tools.",
            parameters: .object(["type": .string("object"), "properties": .object([
                "query": .object(["type": .string("string")]), "limit": .object(["type": .string("number")])]), "required": .array([.string("query")])]),
            execute: { _, args, signal, _ in
                try signal?.throwIfAborted()
                let query = args["query"]?.stringValue ?? "", maximum = args["limit"]?.doubleValue ?? 8
                guard !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw PiError("query must not be empty") }
                guard maximum.isFinite, maximum > 0, maximum.rounded() == maximum, maximum < Double(Int.max) else { throw PiError("limit must be a positive integer") }
                let candidates = await context.getTools().filter { !$0.active && ($0.exposure == .codemode || $0.exposure == .deferred) }
                let matches = rankTools(query: query, tools: candidates, limit: Int(maximum))
                try await context.activateTools(matches.map { $0.tool.name })
                let text = matches.isEmpty ? "No matching tools found." : "Loaded \(matches.count) tools. They are available from your next call:\n" + matches.map { "- \($0.tool.name): \($0.tool.description.components(separatedBy: .newlines).first ?? "")" }.joined(separator: "\n")
                return .init(content: [.text(.init(text: text))], details: .object(["loaded": .array(matches.map { .string($0.tool.name) })]))
            })
        try await context.registerTools([ExtensionTool(tool, exposure: .modelOnly)])
    })
}
