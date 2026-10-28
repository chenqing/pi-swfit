import Foundation

// Port of packages/ai/src/api/constrained-sampling.ts
//
// Swift: JSON schemas are `JsonValue`s (`JsonSchemaObject` = a JSON object); the in-place
// mutation of `structuredClone(schema)` is done on an `inout` value copy.

private struct UnsupportedStrictJsonSchemaError: Error, CustomStringConvertible, LocalizedError, Sendable {
    let message: String
    init(_ message: String) { self.message = message }
    var description: String { message }
    var errorDescription: String? { message }
}

/// Returns true when a provider's strict mode rejects this schema keyword with this value.
public typealias UnsupportedStrictSchemaKeywordCheck = @Sendable (_ key: String, _ value: JsonValue) -> Bool

private let UNSUPPORTED_STRICT_SCHEMA_KEYS = [
    "$ref",
    "$defs",
    "definitions",
    "allOf",
    "oneOf",
    "patternProperties",
    "dependentSchemas",
    "dependencies",
    "unevaluatedProperties",
    "propertyNames",
    "contains",
    "prefixItems",
    "not",
    "if",
    "then",
    "else",
]

private func isJsonSchemaObject(_ value: JsonValue?) -> Bool {
    if case .object = value { return true }
    return false
}

private func isStructuredSchema(_ schema: JsonValue) -> Bool {
    guard case .object(let schema) = schema else { return false }
    let types: [JsonValue]
    switch schema["type"] {
    case .string(let type)?: types = [.string(type)]
    case .array(let array)?: types = array
    default: types = []
    }
    return types.contains(.string("object"))
        || types.contains(.string("array"))
        || schema["properties"] != nil
        || schema["items"] != nil
}

private func schemaAllowsNull(_ schema: JsonValue) -> Bool {
    guard case .object(let schema) = schema else { return false }
    if schema["type"] == .string("null") { return true }
    if case .array(let types)? = schema["type"], types.contains(.string("null")) { return true }
    if schema["const"] == .null { return true }
    if case .array(let values)? = schema["enum"], values.contains(.null) { return true }
    if case .array(let variants)? = schema["anyOf"] { return variants.contains { schemaAllowsNull($0) } }
    return false
}

private func makeJsonSchemaNodeStrict(_ schemaValue: inout JsonValue, _ isUnsupportedKeyword: UnsupportedStrictSchemaKeywordCheck?) throws {
    guard case .object(var schema) = schemaValue else {
        throw UnsupportedStrictJsonSchemaError("boolean schemas are unsupported")
    }
    for key in UNSUPPORTED_STRICT_SCHEMA_KEYS {
        if schema[key] != nil {
            throw UnsupportedStrictJsonSchemaError("\(key) schemas are unsupported")
        }
    }
    if let isUnsupportedKeyword {
        for (key, value) in schema {
            if isUnsupportedKeyword(key, value) {
                throw UnsupportedStrictJsonSchemaError("\(key): \(value.serialized()) is unsupported")
            }
        }
    }

    if let anyOf = schema["anyOf"] {
        guard case .array(var variants) = anyOf, variants.count > 0 else {
            throw UnsupportedStrictJsonSchemaError("anyOf must contain at least one schema")
        }
        for index in variants.indices {
            if isStructuredSchema(variants[index]) {
                throw UnsupportedStrictJsonSchemaError("object and array unions are unsupported")
            }
            try makeJsonSchemaNodeStrict(&variants[index], isUnsupportedKeyword)
        }
        schema["anyOf"] = .array(variants)
    }

    if var items = schema["items"] {
        if case .array = items {
            throw UnsupportedStrictJsonSchemaError("tuple schemas are unsupported")
        }
        try makeJsonSchemaNodeStrict(&items, isUnsupportedKeyword)
        schema["items"] = items
    }

    let isObjectSchema = schema["type"] == .string("object")
    if schema["properties"] != nil && !isObjectSchema {
        throw UnsupportedStrictJsonSchemaError("properties require type object")
    }
    if !isObjectSchema {
        schemaValue = .object(schema)
        return
    }
    if let additionalProperties = schema["additionalProperties"], additionalProperties != .bool(false) {
        throw UnsupportedStrictJsonSchemaError("schema-valued or true additionalProperties is unsupported")
    }
    if let properties = schema["properties"], !isJsonSchemaObject(properties) {
        throw UnsupportedStrictJsonSchemaError("object properties must be a schema map")
    }
    if let required = schema["required"] {
        guard case .array(let keys) = required, keys.allSatisfy({ $0.stringValue != nil }) else {
            throw UnsupportedStrictJsonSchemaError("object required must be a string array")
        }
    }

    var properties = schema["properties"]?.objectValue ?? JsonObject()
    let propertyNames = properties.keys
    let required = Set((schema["required"]?.arrayValue ?? []).compactMap(\.stringValue))
    if required.contains(where: { !propertyNames.contains($0) }) {
        throw UnsupportedStrictJsonSchemaError("required contains an unknown property")
    }
    for key in propertyNames {
        var property = properties[key]!
        try makeJsonSchemaNodeStrict(&property, isUnsupportedKeyword)
        if !required.contains(key) && !schemaAllowsNull(property) {
            properties[key] = .object(["anyOf": .array([property, .object(["type": "null"])])])
        } else {
            properties[key] = property
        }
    }
    if schema["properties"] != nil {
        schema["properties"] = .object(properties)
    }
    schema["required"] = .array(propertyNames.map(JsonValue.string))
    schema["additionalProperties"] = .bool(false)
    schemaValue = .object(schema)
}

/// Convert a tool schema to the strict subset expected by provider constrained sampling.
public func makeStrictJsonSchema(
    _ schema: JsonValue,
    _ isUnsupportedKeyword: UnsupportedStrictSchemaKeywordCheck? = nil
) throws -> JsonValue {
    var cloned = schema
    if !isJsonSchemaObject(cloned) {
        throw UnsupportedStrictJsonSchemaError("root schema must have type object")
    }
    try makeJsonSchemaNodeStrict(&cloned, isUnsupportedKeyword)
    if cloned["type"] != .string("object") {
        throw UnsupportedStrictJsonSchemaError("root schema must have type object")
    }
    return cloned
}

public func getJsonSchemaToolParameters(_ tool: Tool, _ strict: Bool?) throws -> JsonValue {
    strict == true ? try makeStrictJsonSchema(tool.parameters) : tool.parameters
}

public struct GrammarConstrainedSampling: Sendable, Hashable {
    /// "lark" | "regex"
    public var format: String
    public var definition: String
    public var inputProperty: String
    public init(format: String, definition: String, inputProperty: String) {
        self.format = format; self.definition = definition; self.inputProperty = inputProperty
    }
}

public struct GrammarToolInputJsonBuffer: Sendable, Hashable {
    public var input: String
    public var started: Bool
    public var closed: Bool
    public init(input: String = "", started: Bool = false, closed: Bool = false) {
        self.input = input; self.started = started; self.closed = closed
    }
}

public func getGrammarToolInput(
    _ toolName: String,
    _ arguments_: JsonObject,
    _ inputProperty: String
) throws -> String {
    guard case .string(let input)? = arguments_[inputProperty] else {
        throw PiError("Grammar tool call \"\(toolName)\" requires argument \"\(inputProperty)\" to be a string.")
    }
    return input
}

/// `a === b` for strings (UTF-16 code unit equality, no canonical equivalence).
private func jsStringEquals(_ a: String, _ b: String) -> Bool {
    a.utf16.elementsEqual(b.utf16)
}

public func appendGrammarToolInputJsonDelta(
    _ buffer: inout GrammarToolInputJsonBuffer,
    _ inputProperty: String,
    _ inputDelta: String
) throws -> String? {
    guard !buffer.closed else { throw PiError("grammar tool input for property \"\(inputProperty)\" changed after it was closed") }
    guard !inputDelta.isEmpty else { return nil }
    buffer.input.append(contentsOf: inputDelta)
    return grammarToolInputJsonStart(&buffer, inputProperty) + String(JsonValue.string(inputDelta).serialized().dropFirst().dropLast())
}

public func closeGrammarToolInputJson(
    _ buffer: inout GrammarToolInputJsonBuffer,
    _ inputProperty: String,
    _ finalInput: String? = nil
) throws -> String? {
    if buffer.closed {
        if finalInput == nil || jsStringEquals(finalInput!, buffer.input) { return nil }
        throw PiError("grammar tool input for property \"\(inputProperty)\" changed after it was closed")
    }
    if let finalInput, !finalInput.utf16.starts(with: buffer.input.utf16) {
        throw PiError("grammar tool input for property \"\(inputProperty)\" changed non-monotonically")
    }
    let rest = finalInput.map { jsSlice($0, buffer.input.utf16.count) } ?? ""
    if let finalInput { buffer.input = finalInput }
    buffer.closed = true
    return grammarToolInputJsonStart(&buffer, inputProperty) + String(JsonValue.string(rest).serialized().dropFirst().dropLast()) + "\"}"
}

private func grammarToolInputJsonStart(_ buffer: inout GrammarToolInputJsonBuffer, _ inputProperty: String) -> String {
    guard !buffer.started else { return "" }
    buffer.started = true
    return "{\(JsonValue.string(inputProperty).serialized()):\""
}

/// Compatibility overload for existing Swift clients; provider hot paths use deltas and close separately.
public func appendGrammarToolInputJsonDelta(
    _ buffer: inout GrammarToolInputJsonBuffer,
    _ inputProperty: String,
    _ nextInput: String,
    _ close: Bool
) throws -> String? {
    if buffer.closed {
        if close && jsStringEquals(nextInput, buffer.input) { return nil }
        throw PiError("grammar tool input for property \"\(inputProperty)\" changed after it was closed")
    }
    if !nextInput.utf16.starts(with: buffer.input.utf16) {
        throw PiError("grammar tool input for property \"\(inputProperty)\" changed non-monotonically")
    }

    let inputDelta = jsSlice(nextInput, buffer.input.utf16.count)
    if !close && inputDelta.utf16.isEmpty { return nil }

    var delta = ""
    if !buffer.started {
        delta += "{\(JsonValue.string(inputProperty).serialized()):\""
        buffer.started = true
    }
    let quoted = JsonValue.string(inputDelta).serialized()
    delta += jsSlice(quoted, 1, -1)
    buffer.input = nextInput

    if close {
        delta += "\"}"
        buffer.closed = true
    }
    return delta
}

/// Provider-owned reference state prevents copying the growing input when dictionary entries are read.
/// Preview arguments use the same bounded snapshots as JSON tools.
final class StreamingGrammarToolInput {
    let property: String
    private var buffer: GrammarToolInputJsonBuffer
    private let arguments = ToolCallArgumentsStream()
    private var unsent: String
    init(property: String, initialInput: String = "") {
        self.property = property
        buffer = GrammarToolInputJsonBuffer(input: initialInput, started: !initialInput.isEmpty)
        unsent = initialInput.isEmpty ? "" : "{\(JsonValue.string(property).serialized()):" + String(JsonValue.string(initialInput).serialized().dropLast())
        if !unsent.isEmpty { arguments.append(unsent) }
    }
    func update(_ input: String?, close: Bool) throws -> (delta: String?, arguments: JsonObject) {
        let delta = close ? try closeGrammarToolInputJson(&buffer, property, input)
            : try appendGrammarToolInputJsonDelta(&buffer, property, input ?? "")
        let value = arguments.append(delta ?? "")
        guard !unsent.isEmpty else { return (delta, value) }
        let sent = unsent + (delta ?? ""); unsent = ""
        return (sent, value)
    }
}

private func inferGrammarInputProperty(_ tool: Tool) throws -> String {
    let schema = tool.parameters
    if schema["type"] != .string("object") {
        throw PiError("grammar constrained sampling requires an object parameter schema")
    }
    guard case .array(let required)? = schema["required"], required.count == 1, case .string(let inputProperty) = required[0] else {
        throw PiError("grammar constrained sampling requires exactly one required string property")
    }

    guard let property = schema["properties"]?[inputProperty], jsTruthy(property) else {
        throw PiError("grammar constrained sampling requires a properties entry for \(inputProperty)")
    }
    if property["type"] != .string("string") {
        throw PiError("grammar constrained sampling property \(inputProperty) must have type string")
    }
    return inputProperty
}

/**
 * Decide whether a JSON-schema tool is sent in strict mode. `isUnsupportedKeyword` lets a provider
 * reject extra keywords its strict mode does not accept, so "prefer" tools fall back to non-strict.
 */
public func resolveJsonSchemaStrictSampling(
    _ tool: Tool,
    _ supportsStrictMode: Bool,
    _ isUnsupportedKeyword: UnsupportedStrictSchemaKeywordCheck? = nil
) throws -> Bool? {
    guard case .some(.some(.jsonSchema(let strict))) = tool.constrainedSampling else { return nil }

    if supportsStrictMode {
        do {
            _ = try makeStrictJsonSchema(tool.parameters, isUnsupportedKeyword)
            return true
        } catch let error as UnsupportedStrictJsonSchemaError {
            if strict != "require" { return nil }
            throw PiError("Tool \"\(tool.name)\" requires JSON-schema constrained sampling, but \(error.message).")
        }
    }
    if strict == "require" {
        throw PiError(
            "Tool \"\(tool.name)\" requires JSON-schema constrained sampling, but strict tools are unsupported."
        )
    }
    return nil
}

public func resolveGrammarConstrainedSampling(
    _ tool: Tool,
    _ supportsOpenAIGrammarTools: Bool
) throws -> GrammarConstrainedSampling? {
    guard case .some(.some(.grammar(let variants))) = tool.constrainedSampling else {
        return nil
    }

    if !supportsOpenAIGrammarTools {
        return nil
    }

    let larkDefinition = variants.last { $0.format == "openai_lark" }?.grammar
    let regexDefinition = variants.last { $0.format == "openai_regex" }?.grammar
    let hasLarkDefinition = larkDefinition.map { !jsTrim($0).isEmpty } ?? false
    let hasRegexDefinition = regexDefinition.map { !jsTrim($0).isEmpty } ?? false
    if !hasLarkDefinition && !hasRegexDefinition {
        throw PiError(
            "Tool \"\(tool.name)\" cannot use grammar constrained sampling: no supported grammar variant was provided."
        )
    }

    do {
        return GrammarConstrainedSampling(
            format: hasLarkDefinition ? "lark" : "regex",
            definition: hasLarkDefinition ? larkDefinition! : regexDefinition!,
            inputProperty: try inferGrammarInputProperty(tool)
        )
    } catch {
        let message = errorMessage(error)
        throw PiError("Tool \"\(tool.name)\" cannot use grammar constrained sampling: \(message).")
    }
}

/// `ReadonlyMap<string, string>` (tool name -> grammar input property).
public func createGrammarToolInputProperties(
    _ tools: [Tool]?,
    _ supportsOpenAIGrammarTools: Bool
) throws -> [String: String] {
    var properties: [String: String] = [:]
    for tool in tools ?? [] {
        if let grammar = try resolveGrammarConstrainedSampling(tool, supportsOpenAIGrammarTools) {
            properties[tool.name] = grammar.inputProperty
        }
    }
    return properties
}
