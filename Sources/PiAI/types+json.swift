import Foundation

// Swift-only: JSON conversion for the types in types.swift and utils/diagnostics.swift.
//
// Every type converts to and from the exact upstream JSON shape (what `JSON.stringify` writes for
// the TS object): key order follows the upstream interface field order, `undefined` (nil) fields
// are omitted, and `null` is written only where upstream stores null (ThinkingLevelMap values,
// SystemMessage section removals). Used for session files and byte-stable request bodies.

/// A value with an upstream JSON representation.
public protocol JsonConvertible {
    var json: JsonValue { get }
    init(json: JsonValue) throws
}

/// Thrown when JSON does not have the upstream shape of the requested type.
public struct JsonShapeError: Error, CustomStringConvertible, LocalizedError, Sendable {
    public var message: String
    public init(_ message: String) { self.message = message }
    public var description: String { message }
    public var errorDescription: String? { message }
}

// MARK: - Decoding helpers

private func object(_ json: JsonValue, _ type: String) throws -> JsonObject {
    guard case .object(let object) = json else { throw JsonShapeError("Expected \(type) object, got \(json.typeName)") }
    return object
}

private func present(_ object: JsonObject, _ key: String) -> JsonValue? {
    // JSON written by JS never holds `undefined`; treat an explicit null like a missing optional field.
    guard let value = object[key], !value.isNull else { return nil }
    return value
}

private func requireValue(_ object: JsonObject, _ key: String, _ type: String) throws -> JsonValue {
    guard let value = object[key] else { throw JsonShapeError("\(type).\(key) is required") }
    return value
}

private func string(_ object: JsonObject, _ key: String, _ type: String) throws -> String {
    guard case .string(let value) = try requireValue(object, key, type) else { throw JsonShapeError("\(type).\(key) must be a string") }
    return value
}

private func optionalString(_ object: JsonObject, _ key: String, _ type: String) throws -> String? {
    guard let value = present(object, key) else { return nil }
    guard case .string(let string) = value else { throw JsonShapeError("\(type).\(key) must be a string") }
    return string
}

private func number(_ object: JsonObject, _ key: String, _ type: String) throws -> Double {
    guard case .number(let value) = try requireValue(object, key, type) else { throw JsonShapeError("\(type).\(key) must be a number") }
    return value
}

private func optionalNumber(_ object: JsonObject, _ key: String, _ type: String) throws -> Double? {
    guard let value = present(object, key) else { return nil }
    guard case .number(let number) = value else { throw JsonShapeError("\(type).\(key) must be a number") }
    return number
}

private func toInt(_ value: Double, _ key: String, _ type: String) throws -> Int {
    guard value.isFinite, abs(value) < 9.007_199_254_740_992e15 else { throw JsonShapeError("\(type).\(key) must be a finite number") }
    return Int(value.rounded(.towardZero))
}

private func int(_ object: JsonObject, _ key: String, _ type: String) throws -> Int {
    try toInt(try number(object, key, type), key, type)
}

private func optionalInt(_ object: JsonObject, _ key: String, _ type: String) throws -> Int? {
    guard let value = try optionalNumber(object, key, type) else { return nil }
    return try toInt(value, key, type)
}

private func bool(_ object: JsonObject, _ key: String, _ type: String) throws -> Bool {
    guard case .bool(let value) = try requireValue(object, key, type) else { throw JsonShapeError("\(type).\(key) must be a boolean") }
    return value
}

private func optionalBool(_ object: JsonObject, _ key: String, _ type: String) throws -> Bool? {
    guard let value = present(object, key) else { return nil }
    guard case .bool(let bool) = value else { throw JsonShapeError("\(type).\(key) must be a boolean") }
    return bool
}

private func array(_ object: JsonObject, _ key: String, _ type: String) throws -> [JsonValue] {
    guard case .array(let value) = try requireValue(object, key, type) else { throw JsonShapeError("\(type).\(key) must be an array") }
    return value
}

private func optionalArray(_ object: JsonObject, _ key: String, _ type: String) throws -> [JsonValue]? {
    guard let value = present(object, key) else { return nil }
    guard case .array(let array) = value else { throw JsonShapeError("\(type).\(key) must be an array") }
    return array
}

private func optionalObject(_ object: JsonObject, _ key: String, _ type: String) throws -> JsonObject? {
    guard let value = present(object, key) else { return nil }
    guard case .object(let nested) = value else { throw JsonShapeError("\(type).\(key) must be an object") }
    return nested
}

private func enumValue<T: RawRepresentable>(_ raw: String, _ key: String, _ type: String) throws -> T where T.RawValue == String {
    guard let value = T(rawValue: raw) else { throw JsonShapeError("\(type).\(key) has unknown value \"\(raw)\"") }
    return value
}

private func num(_ value: Int) -> JsonValue { .number(Double(value)) }

// MARK: - model-schema.ts

extension ThinkingLevel: JsonConvertible {
    public var json: JsonValue { .string(rawValue) }
    public init(json: JsonValue) throws {
        guard case .string(let raw) = json, let value = ThinkingLevel(rawValue: raw) else { throw JsonShapeError("Invalid ThinkingLevel") }
        self = value
    }
}

extension ModelThinkingLevel: JsonConvertible {
    public var json: JsonValue { .string(rawValue) }
    public init(json: JsonValue) throws {
        guard case .string(let raw) = json, let value = ModelThinkingLevel(rawValue: raw) else { throw JsonShapeError("Invalid ModelThinkingLevel") }
        self = value
    }
}

extension CacheRetention: JsonConvertible {
    public var json: JsonValue { .string(rawValue) }
    public init(json: JsonValue) throws {
        guard case .string(let raw) = json, let value = CacheRetention(rawValue: raw) else { throw JsonShapeError("Invalid CacheRetention") }
        self = value
    }
}

/// `ThinkingLevelMap` JSON: `{ [level]: string | null }`, levels in `MODEL_THINKING_LEVELS` order.
public func thinkingLevelMapToJson(_ map: ThinkingLevelMap) -> JsonValue {
    var result = JsonObject()
    for level in MODEL_THINKING_LEVELS {
        guard let entry = map[level] else { continue }
        result[level.rawValue] = entry.map(JsonValue.string) ?? .null
    }
    return .object(result)
}

public func thinkingLevelMapFromJson(_ json: JsonValue) throws -> ThinkingLevelMap {
    let source = try object(json, "ThinkingLevelMap")
    var map: ThinkingLevelMap = [:]
    for (key, value) in source {
        guard let level = ModelThinkingLevel(rawValue: key) else { continue }
        switch value {
        case .null: map[level] = .some(nil)
        case .string(let string): map[level] = .some(string)
        default: throw JsonShapeError("ThinkingLevelMap.\(key) must be a string or null")
        }
    }
    return map
}

/// `SamplingParamsByThinkingLevel` JSON, levels in `MODEL_THINKING_LEVELS` order.
public func samplingParamsByThinkingLevelToJson(_ params: SamplingParamsByThinkingLevel) -> JsonValue {
    var result = JsonObject()
    for level in MODEL_THINKING_LEVELS {
        guard let entry = params[level] else { continue }
        result[level.rawValue] = .object(entry)
    }
    return .object(result)
}

public func samplingParamsByThinkingLevelFromJson(_ json: JsonValue) throws -> SamplingParamsByThinkingLevel {
    let source = try object(json, "SamplingParamsByThinkingLevel")
    var result: SamplingParamsByThinkingLevel = [:]
    for (key, value) in source {
        guard let level = ModelThinkingLevel(rawValue: key) else { continue }
        guard case .object(let params) = value else { throw JsonShapeError("SamplingParamsByThinkingLevel.\(key) must be an object") }
        result[level] = params
    }
    return result
}

extension ModelPromptCache: JsonConvertible {
    public var json: JsonValue {
        var o = JsonObject()
        if let short { o["short"] = .number(short) }
        if let long { o["long"] = .number(long) }
        return .object(o)
    }
    public init(json: JsonValue) throws {
        let o = try object(json, "ModelPromptCache")
        self.init(short: try optionalNumber(o, "short", "ModelPromptCache"), long: try optionalNumber(o, "long", "ModelPromptCache"))
    }
}

extension ModelCostTier: JsonConvertible {
    public var json: JsonValue {
        [
            "inputTokensAbove": .number(inputTokensAbove),
            "input": .number(input),
            "output": .number(output),
            "cacheRead": .number(cacheRead),
            "cacheWrite": .number(cacheWrite),
        ]
    }
    public init(json: JsonValue) throws {
        let t = "ModelCostTier"
        let o = try object(json, t)
        self.init(
            inputTokensAbove: try number(o, "inputTokensAbove", t), input: try number(o, "input", t), output: try number(o, "output", t),
            cacheRead: try number(o, "cacheRead", t), cacheWrite: try number(o, "cacheWrite", t)
        )
    }
}

extension ModelCost: JsonConvertible {
    public var json: JsonValue {
        var o: JsonObject = [
            "input": .number(input),
            "output": .number(output),
            "cacheRead": .number(cacheRead),
            "cacheWrite": .number(cacheWrite),
        ]
        if let tiers { o["tiers"] = .array(tiers.map(\.json)) }
        return .object(o)
    }
    public init(json: JsonValue) throws {
        let t = "ModelCost"
        let o = try object(json, t)
        self.init(
            input: try number(o, "input", t), output: try number(o, "output", t), cacheRead: try number(o, "cacheRead", t),
            cacheWrite: try number(o, "cacheWrite", t), tiers: try optionalArray(o, "tiers", t)?.map(ModelCostTier.init(json:))
        )
    }
}

extension ModelImageResizeOptions: JsonConvertible {
    public var json: JsonValue {
        var o = JsonObject()
        if let maxWidth { o["maxWidth"] = num(maxWidth) }
        if let maxHeight { o["maxHeight"] = num(maxHeight) }
        if let maxBytes { o["maxBytes"] = num(maxBytes) }
        if let jpegQuality { o["jpegQuality"] = num(jpegQuality) }
        return .object(o)
    }
    public init(json: JsonValue) throws {
        let t = "ModelImageResizeOptions"
        let o = try object(json, t)
        self.init(
            maxWidth: try optionalInt(o, "maxWidth", t), maxHeight: try optionalInt(o, "maxHeight", t),
            maxBytes: try optionalInt(o, "maxBytes", t), jpegQuality: try optionalInt(o, "jpegQuality", t)
        )
    }
}

extension ModelImageInputLimits: JsonConvertible {
    public var json: JsonValue {
        var o = JsonObject()
        if let resize { o["resize"] = resize.json }
        if let maxPerMessage { o["maxPerMessage"] = num(maxPerMessage) }
        if let maxPerRequest { o["maxPerRequest"] = num(maxPerRequest) }
        return .object(o)
    }
    public init(json: JsonValue) throws {
        let t = "ModelImageInputLimits"
        let o = try object(json, t)
        self.init(
            resize: try present(o, "resize").map(ModelImageResizeOptions.init(json:)),
            maxPerMessage: try optionalInt(o, "maxPerMessage", t), maxPerRequest: try optionalInt(o, "maxPerRequest", t)
        )
    }
}

extension ModelInputLimits: JsonConvertible {
    public var json: JsonValue {
        var o = JsonObject()
        if let maxRequestBytes { o["maxRequestBytes"] = num(maxRequestBytes) }
        if let images { o["images"] = images.json }
        return .object(o)
    }
    public init(json: JsonValue) throws {
        let t = "ModelInputLimits"
        let o = try object(json, t)
        self.init(maxRequestBytes: try optionalInt(o, "maxRequestBytes", t), images: try present(o, "images").map(ModelImageInputLimits.init(json:)))
    }
}

// MARK: - Options

extension ThinkingBudgets: JsonConvertible {
    public var json: JsonValue {
        var o = JsonObject()
        if let minimal { o["minimal"] = num(minimal) }
        if let low { o["low"] = num(low) }
        if let medium { o["medium"] = num(medium) }
        if let high { o["high"] = num(high) }
        return .object(o)
    }
    public init(json: JsonValue) throws {
        let t = "ThinkingBudgets"
        let o = try object(json, t)
        self.init(
            minimal: try optionalInt(o, "minimal", t), low: try optionalInt(o, "low", t),
            medium: try optionalInt(o, "medium", t), high: try optionalInt(o, "high", t)
        )
    }
}

/// `ProviderHeaders` JSON: `Record<string, string | null>`.
public func providerHeadersToJson(_ headers: ProviderHeaders) -> JsonValue {
    var o = JsonObject()
    for (name, value) in headers { o[name] = value.map(JsonValue.string) ?? .null }
    return .object(o)
}

public func providerHeadersFromJson(_ json: JsonValue) throws -> ProviderHeaders {
    let o = try object(json, "ProviderHeaders")
    return try o.map { key, value in
        switch value {
        case .null: return (key, nil)
        case .string(let string): return (key, string)
        default: throw JsonShapeError("ProviderHeaders.\(key) must be a string or null")
        }
    }
}

extension ProviderResponse: JsonConvertible {
    public var json: JsonValue {
        var headersObject = JsonObject()
        for key in headers.keys.sorted() { headersObject[key] = .string(headers[key]!) }
        return ["status": num(status), "headers": .object(headersObject)]
    }
    public init(json: JsonValue) throws {
        let t = "ProviderResponse"
        let o = try object(json, t)
        var headers: [String: String] = [:]
        for (key, value) in try optionalObject(o, "headers", t) ?? JsonObject() {
            if case .string(let string) = value { headers[key] = string }
        }
        self.init(status: try int(o, "status", t), headers: headers)
    }
}

// MARK: - Content

extension TextSignatureV1: JsonConvertible {
    public var json: JsonValue {
        var o: JsonObject = ["v": num(v), "id": .string(id)]
        if let phase { o["phase"] = .string(phase) }
        return .object(o)
    }
    public init(json: JsonValue) throws {
        let t = "TextSignatureV1"
        let o = try object(json, t)
        guard try int(o, "v", t) == 1 else { throw JsonShapeError("TextSignatureV1.v must be 1") }
        self.init(id: try string(o, "id", t), phase: try optionalString(o, "phase", t))
    }
}

extension TextContent: JsonConvertible {
    public var json: JsonValue {
        var o: JsonObject = ["type": "text", "text": .string(text)]
        if let textSignature { o["textSignature"] = .string(textSignature) }
        return .object(o)
    }
    public init(json: JsonValue) throws {
        let t = "TextContent"
        let o = try object(json, t)
        self.init(text: try string(o, "text", t), textSignature: try optionalString(o, "textSignature", t))
    }
}

extension ThinkingContent: JsonConvertible {
    public var json: JsonValue {
        var o: JsonObject = ["type": "thinking", "thinking": .string(thinking)]
        if let thinkingSignature { o["thinkingSignature"] = .string(thinkingSignature) }
        if let redacted { o["redacted"] = .bool(redacted) }
        return .object(o)
    }
    public init(json: JsonValue) throws {
        let t = "ThinkingContent"
        let o = try object(json, t)
        self.init(thinking: try string(o, "thinking", t), thinkingSignature: try optionalString(o, "thinkingSignature", t), redacted: try optionalBool(o, "redacted", t))
    }
}

extension ImageContent: JsonConvertible {
    public var json: JsonValue { ["type": "image", "data": .string(data), "mimeType": .string(mimeType)] }
    public init(json: JsonValue) throws {
        let t = "ImageContent"
        let o = try object(json, t)
        self.init(data: try string(o, "data", t), mimeType: try string(o, "mimeType", t))
    }
}

extension ToolCall: JsonConvertible {
    public var json: JsonValue {
        var o: JsonObject = ["type": "toolCall", "id": .string(id), "name": .string(name), "arguments": .object(arguments)]
        if let thoughtSignature { o["thoughtSignature"] = .string(thoughtSignature) }
        if let namespace { o["namespace"] = .string(namespace) }
        if let argumentsError { o["argumentsError"] = .string(argumentsError) }
        return .object(o)
    }
    public init(json: JsonValue) throws {
        let t = "ToolCall"
        let o = try object(json, t)
        self.init(
            id: try string(o, "id", t), name: try string(o, "name", t), arguments: try optionalObject(o, "arguments", t) ?? JsonObject(),
            thoughtSignature: try optionalString(o, "thoughtSignature", t), namespace: try optionalString(o, "namespace", t),
            argumentsError: try optionalString(o, "argumentsError", t)
        )
    }
}

extension AssistantContent: JsonConvertible {
    public var json: JsonValue {
        switch self {
        case .text(let content): return content.json
        case .thinking(let content): return content.json
        case .toolCall(let content): return content.json
        }
    }
    public init(json: JsonValue) throws {
        let o = try object(json, "AssistantContent")
        switch o["type"]?.stringValue {
        case "text": self = .text(try TextContent(json: json))
        case "thinking": self = .thinking(try ThinkingContent(json: json))
        case "toolCall": self = .toolCall(try ToolCall(json: json))
        default: throw JsonShapeError("Unknown assistant content type: \(o["type"]?.serialized() ?? "undefined")")
        }
    }
}

extension UserContent: JsonConvertible {
    public var json: JsonValue {
        switch self {
        case .text(let content): return content.json
        case .image(let content): return content.json
        }
    }
    public init(json: JsonValue) throws {
        let o = try object(json, "UserContent")
        switch o["type"]?.stringValue {
        case "text": self = .text(try TextContent(json: json))
        case "image": self = .image(try ImageContent(json: json))
        default: throw JsonShapeError("Unknown user content type: \(o["type"]?.serialized() ?? "undefined")")
        }
    }
}

extension UserMessageContent: JsonConvertible {
    public var json: JsonValue {
        switch self {
        case .string(let string): return .string(string)
        case .blocks(let blocks): return .array(blocks.map(\.json))
        }
    }
    public init(json: JsonValue) throws {
        switch json {
        case .string(let string): self = .string(string)
        case .array(let blocks): self = .blocks(try blocks.map(UserContent.init(json:)))
        default: throw JsonShapeError("User message content must be a string or an array")
        }
    }
}

extension SystemMessageContent: JsonConvertible {
    public var json: JsonValue {
        switch self {
        case .string(let string): return .string(string)
        case .blocks(let blocks): return .array(blocks.map(\.json))
        }
    }
    public init(json: JsonValue) throws {
        switch json {
        case .string(let string): self = .string(string)
        case .array(let blocks): self = .blocks(try blocks.map(TextContent.init(json:)))
        default: throw JsonShapeError("System message content must be a string or an array")
        }
    }
}

// MARK: - Usage

extension UsageCost: JsonConvertible {
    public var json: JsonValue {
        [
            "input": .number(input),
            "output": .number(output),
            "cacheRead": .number(cacheRead),
            "cacheWrite": .number(cacheWrite),
            "total": .number(total),
        ]
    }
    public init(json: JsonValue) throws {
        let t = "Usage.cost"
        let o = try object(json, t)
        self.init(
            input: try number(o, "input", t), output: try number(o, "output", t), cacheRead: try number(o, "cacheRead", t),
            cacheWrite: try number(o, "cacheWrite", t), total: try number(o, "total", t)
        )
    }
}

extension Usage: JsonConvertible {
    public var json: JsonValue {
        var o: JsonObject = ["input": num(input), "output": num(output), "cacheRead": num(cacheRead), "cacheWrite": num(cacheWrite)]
        if let cacheWrite1h { o["cacheWrite1h"] = num(cacheWrite1h) }
        if let reasoning { o["reasoning"] = num(reasoning) }
        o["totalTokens"] = num(totalTokens)
        o["cost"] = cost.json
        return .object(o)
    }
    public init(json: JsonValue) throws {
        let t = "Usage"
        let o = try object(json, t)
        self.init(
            input: try int(o, "input", t), output: try int(o, "output", t), cacheRead: try int(o, "cacheRead", t),
            cacheWrite: try int(o, "cacheWrite", t), cacheWrite1h: try optionalInt(o, "cacheWrite1h", t),
            reasoning: try optionalInt(o, "reasoning", t), totalTokens: try int(o, "totalTokens", t),
            cost: try UsageCost(json: try requireValue(o, "cost", t))
        )
    }
}

extension StopReason: JsonConvertible {
    public var json: JsonValue { .string(rawValue) }
    public init(json: JsonValue) throws {
        guard case .string(let raw) = json, let value = StopReason(rawValue: raw) else { throw JsonShapeError("Invalid StopReason") }
        self = value
    }
}

extension DeferredHandle: JsonConvertible {
    public var json: JsonValue {
        var o: JsonObject = ["provider": .string(provider), "modelId": .string(modelId), "api": .string(api), "id": .string(id)]
        if let expiresAt { o["expiresAt"] = num(expiresAt) }
        if let pollAfterMs { o["pollAfterMs"] = num(pollAfterMs) }
        if let data { o["data"] = data }
        return .object(o)
    }
    public init(json: JsonValue) throws {
        let t = "DeferredHandle"
        let o = try object(json, t)
        self.init(
            provider: try string(o, "provider", t), modelId: try string(o, "modelId", t), api: try string(o, "api", t), id: try string(o, "id", t),
            expiresAt: try optionalInt(o, "expiresAt", t), pollAfterMs: try optionalInt(o, "pollAfterMs", t), data: o["data"]
        )
    }
}

// MARK: - diagnostics.ts

extension DiagnosticErrorInfo: JsonConvertible {
    public var json: JsonValue {
        var o = JsonObject()
        if let name { o["name"] = .string(name) }
        o["message"] = .string(message)
        if let stack { o["stack"] = .string(stack) }
        if let code { o["code"] = code }
        return .object(o)
    }
    public init(json: JsonValue) throws {
        let t = "DiagnosticErrorInfo"
        let o = try object(json, t)
        var code: JsonValue?
        if let value = present(o, "code") {
            switch value {
            case .string, .number: code = value
            default: throw JsonShapeError("DiagnosticErrorInfo.code must be a string or number")
            }
        }
        self.init(name: try optionalString(o, "name", t), message: try string(o, "message", t), stack: try optionalString(o, "stack", t), code: code)
    }
}

extension AssistantMessageDiagnostic: JsonConvertible {
    public var json: JsonValue {
        var o: JsonObject = ["type": .string(type), "timestamp": num(timestamp)]
        if let error { o["error"] = error.json }
        if let details { o["details"] = .object(details) }
        return .object(o)
    }
    public init(json: JsonValue) throws {
        let t = "AssistantMessageDiagnostic"
        let o = try object(json, t)
        self.init(
            type: try string(o, "type", t), timestamp: try int(o, "timestamp", t),
            error: try present(o, "error").map(DiagnosticErrorInfo.init(json:)), details: try optionalObject(o, "details", t)
        )
    }
}

// MARK: - Messages

/// `SystemSections` JSON: `Record<string, string | null>` in section order.
public func systemSectionsToJson(_ sections: SystemSections) -> JsonValue {
    var o = JsonObject()
    for section in sections { o[section.name] = section.text.map(JsonValue.string) ?? .null }
    return .object(o)
}

public func systemSectionsFromJson(_ json: JsonValue) throws -> SystemSections {
    let o = try object(json, "SystemMessage.sections")
    return try o.map { key, value in
        switch value {
        case .null: return (name: key, text: nil)
        case .string(let string): return (name: key, text: string)
        default: throw JsonShapeError("SystemMessage.sections.\(key) must be a string or null")
        }
    }
}

extension SystemMessage: JsonConvertible {
    public var json: JsonValue {
        var o: JsonObject = ["role": "system", "content": content.json]
        if let sections { o["sections"] = systemSectionsToJson(sections) }
        if let toolsAdded { o["toolsAdded"] = .array(toolsAdded.map(\.json)) }
        if let toolsRemoved { o["toolsRemoved"] = .array(toolsRemoved.map(\.json)) }
        o["timestamp"] = num(timestamp)
        return .object(o)
    }
    public init(json: JsonValue) throws {
        let t = "SystemMessage"
        let o = try object(json, t)
        self.init(
            content: try SystemMessageContent(json: try requireValue(o, "content", t)),
            sections: try present(o, "sections").map(systemSectionsFromJson),
            toolsAdded: try optionalArray(o, "toolsAdded", t)?.map(Tool.init(json:)),
            toolsRemoved: try optionalArray(o, "toolsRemoved", t)?.map(ToolReference.init(json:)),
            timestamp: try int(o, "timestamp", t)
        )
    }
}

extension UserMessage: JsonConvertible {
    public var json: JsonValue { ["role": "user", "content": content.json, "timestamp": num(timestamp)] }
    public init(json: JsonValue) throws {
        let t = "UserMessage"
        let o = try object(json, t)
        self.init(content: try UserMessageContent(json: try requireValue(o, "content", t)), timestamp: try int(o, "timestamp", t))
    }
}

extension AssistantMessage: JsonConvertible {
    public var json: JsonValue {
        var o: JsonObject = [
            "role": "assistant",
            "content": .array(content.map(\.json)),
            "api": .string(api),
            "provider": .string(provider),
            "model": .string(model),
        ]
        if let responseModel { o["responseModel"] = .string(responseModel) }
        if let responseId { o["responseId"] = .string(responseId) }
        if let providerThinkingLevel { o["providerThinkingLevel"] = .string(providerThinkingLevel) }
        if let thinkingLevel { o["thinkingLevel"] = thinkingLevel.json }
        if let diagnostics { o["diagnostics"] = .array(diagnostics.map(\.json)) }
        o["usage"] = usage.json
        o["stopReason"] = stopReason.json
        if let deferred { o["deferred"] = deferred.json }
        if let errorMessage { o["errorMessage"] = .string(errorMessage) }
        if let rawStopReason { o["rawStopReason"] = .string(rawStopReason) }
        if let endTurn { o["endTurn"] = .bool(endTurn) }
        o["timestamp"] = num(timestamp)
        if let durationMs { o["durationMs"] = num(durationMs) }
        return .object(o)
    }
    public init(json: JsonValue) throws {
        let t = "AssistantMessage"
        let o = try object(json, t)
        self.init(
            content: try array(o, "content", t).map(AssistantContent.init(json:)),
            api: try string(o, "api", t), provider: try string(o, "provider", t), model: try string(o, "model", t),
            usage: try Usage(json: try requireValue(o, "usage", t)),
            stopReason: try StopReason(json: try requireValue(o, "stopReason", t)),
            errorMessage: try optionalString(o, "errorMessage", t),
            timestamp: try int(o, "timestamp", t)
        )
        responseModel = try optionalString(o, "responseModel", t)
        responseId = try optionalString(o, "responseId", t)
        providerThinkingLevel = try optionalString(o, "providerThinkingLevel", t)
        thinkingLevel = try present(o, "thinkingLevel").map(ModelThinkingLevel.init(json:))
        diagnostics = try optionalArray(o, "diagnostics", t)?.map(AssistantMessageDiagnostic.init(json:))
        deferred = try present(o, "deferred").map(DeferredHandle.init(json:))
        rawStopReason = try optionalString(o, "rawStopReason", t)
        endTurn = try optionalBool(o, "endTurn", t)
        durationMs = try optionalInt(o, "durationMs", t)
    }
}

extension NestedToolCallRecord: JsonConvertible {
    public var json: JsonValue {
        var o: JsonObject = ["id": .string(id), "name": .string(name)]
        if let arguments { o["arguments"] = .object(arguments) }
        if let argumentsBytes { o["argumentsBytes"] = num(argumentsBytes) }
        o["status"] = .string(status)
        if let durationMs { o["durationMs"] = num(durationMs) }
        if let error { o["error"] = .string(error) }
        return .object(o)
    }
    public init(json: JsonValue) throws {
        let t = "NestedToolCallRecord"
        let o = try object(json, t)
        self.init(
            id: try string(o, "id", t), name: try string(o, "name", t), arguments: try optionalObject(o, "arguments", t),
            argumentsBytes: try optionalInt(o, "argumentsBytes", t), status: try string(o, "status", t),
            durationMs: try optionalInt(o, "durationMs", t), error: try optionalString(o, "error", t)
        )
    }
}

extension NestedToolCalls: JsonConvertible {
    public var json: JsonValue { ["calls": .array(calls.map(\.json)), "complete": .bool(complete)] }
    public init(json: JsonValue) throws {
        let t = "NestedToolCalls"
        let o = try object(json, t)
        self.init(calls: try array(o, "calls", t).map(NestedToolCallRecord.init(json:)), complete: try bool(o, "complete", t))
    }
}

extension ToolResultMessage: JsonConvertible {
    public var json: JsonValue {
        var o: JsonObject = [
            "role": "toolResult",
            "toolCallId": .string(toolCallId),
            "toolName": .string(toolName),
            "content": .array(content.map(\.json)),
        ]
        if let details { o["details"] = details }
        if let usage { o["usage"] = usage.json }
        if let nestedCalls { o["nestedCalls"] = nestedCalls.json }
        o["isError"] = .bool(isError)
        o["timestamp"] = num(timestamp)
        if let durationMs { o["durationMs"] = num(durationMs) }
        return .object(o)
    }
    public init(json: JsonValue) throws {
        let t = "ToolResultMessage"
        let o = try object(json, t)
        self.init(
            toolCallId: try string(o, "toolCallId", t), toolName: try string(o, "toolName", t),
            content: try array(o, "content", t).map(UserContent.init(json:)),
            details: o["details"],
            usage: try present(o, "usage").map(Usage.init(json:)),
            nestedCalls: try present(o, "nestedCalls").map(NestedToolCalls.init(json:)),
            isError: try bool(o, "isError", t), timestamp: try int(o, "timestamp", t),
            durationMs: try optionalInt(o, "durationMs", t)
        )
    }
}

extension Message: JsonConvertible {
    public var json: JsonValue {
        switch self {
        case .system(let message): return message.json
        case .user(let message): return message.json
        case .assistant(let message): return message.json
        case .toolResult(let message): return message.json
        }
    }
    public init(json: JsonValue) throws {
        let o = try object(json, "Message")
        switch o["role"]?.stringValue {
        case "system": self = .system(try SystemMessage(json: json))
        case "user": self = .user(try UserMessage(json: json))
        case "assistant": self = .assistant(try AssistantMessage(json: json))
        case "toolResult": self = .toolResult(try ToolResultMessage(json: json))
        default: throw JsonShapeError("Unknown message role: \(o["role"]?.serialized() ?? "undefined")")
        }
    }
}

// MARK: - Tools

extension ConstrainedSamplingConfig: JsonConvertible {
    public var json: JsonValue {
        switch self {
        case .jsonSchema(let strict):
            return ["type": "json_schema", "strict": .string(strict)]
        case .grammar(let variants):
            var o = JsonObject()
            for variant in variants { o[variant.format] = .string(variant.grammar) }
            return ["type": "grammar", "variants": .object(o)]
        }
    }
    public init(json: JsonValue) throws {
        let t = "ConstrainedSamplingConfig"
        let o = try object(json, t)
        switch o["type"]?.stringValue {
        case "json_schema":
            self = .jsonSchema(strict: try string(o, "strict", t))
        case "grammar":
            let variants = try optionalObject(o, "variants", t) ?? JsonObject()
            self = .grammar(variants: try variants.map { key, value in
                guard case .string(let grammar) = value else { throw JsonShapeError("ConstrainedSamplingConfig.variants.\(key) must be a string") }
                return (format: key, grammar: grammar)
            })
        default:
            throw JsonShapeError("Unknown constrained sampling type: \(o["type"]?.serialized() ?? "undefined")")
        }
    }
}

extension Tool: JsonConvertible {
    public var json: JsonValue {
        var o: JsonObject = ["name": .string(name), "description": .string(description), "parameters": parameters]
        switch constrainedSampling {
        case .none: break
        case .some(.none): o["constrainedSampling"] = false
        case .some(.some(let config)): o["constrainedSampling"] = config.json
        }
        return .object(o)
    }
    public init(json: JsonValue) throws {
        let t = "Tool"
        let o = try object(json, t)
        var constrainedSampling: ConstrainedSamplingConfig??
        switch o["constrainedSampling"] {
        case .none, .some(.null): constrainedSampling = nil
        case .some(.bool(false)): constrainedSampling = .some(nil)
        case .some(let value): constrainedSampling = .some(try ConstrainedSamplingConfig(json: value))
        }
        self.init(
            name: try string(o, "name", t), description: try optionalString(o, "description", t) ?? "",
            parameters: o["parameters"] ?? .emptyObject, constrainedSampling: constrainedSampling
        )
    }
}

extension ToolReference: JsonConvertible {
    public var json: JsonValue { ["name": .string(name)] }
    public init(json: JsonValue) throws {
        let o = try object(json, "ToolReference")
        self.init(name: try string(o, "name", "ToolReference"))
    }
}

// MARK: - Context

extension Context: JsonConvertible {
    public var json: JsonValue {
        var o = JsonObject()
        if let systemPrompt { o["systemPrompt"] = .string(systemPrompt) }
        o["messages"] = .array(messages.map(\.json))
        if let tools { o["tools"] = .array(tools.map(\.json)) }
        return .object(o)
    }
    public init(json: JsonValue) throws {
        let t = "Context"
        let o = try object(json, t)
        self.init(
            systemPrompt: try optionalString(o, "systemPrompt", t),
            messages: try array(o, "messages", t).map(Message.init(json:)),
            tools: try optionalArray(o, "tools", t)?.map(Tool.init(json:))
        )
    }
}

extension TranscriptContext: JsonConvertible {
    public var json: JsonValue { ["messages": .array(messages.map(\.json))] }
    public init(json: JsonValue) throws {
        let o = try object(json, "TranscriptContext")
        self.init(normalizedMessages: try array(o, "messages", "TranscriptContext").map(Message.init(json:)))
    }
}

// MARK: - Events

extension AssistantMessageEvent: JsonConvertible {
    public var json: JsonValue {
        var o: JsonObject = ["type": .string(type)]
        switch self {
        case .start(let partial):
            o["partial"] = partial.json
        case .textStart(let index, let partial), .thinkingStart(let index, let partial), .toolcallStart(let index, let partial):
            o["contentIndex"] = num(index)
            o["partial"] = partial.json
        case .textDelta(let index, let delta, let partial), .thinkingDelta(let index, let delta, let partial), .toolcallDelta(let index, let delta, let partial):
            o["contentIndex"] = num(index)
            o["delta"] = .string(delta)
            o["partial"] = partial.json
        case .textEnd(let index, let content, let partial), .thinkingEnd(let index, let content, let partial):
            o["contentIndex"] = num(index)
            o["content"] = .string(content)
            o["partial"] = partial.json
        case .toolcallEnd(let index, let toolCall, let partial):
            o["contentIndex"] = num(index)
            o["toolCall"] = toolCall.json
            o["partial"] = partial.json
        case .done(let reason, let message):
            o["reason"] = reason.json
            o["message"] = message.json
        case .error(let reason, let error):
            o["reason"] = reason.json
            o["error"] = error.json
        }
        return .object(o)
    }
    public init(json: JsonValue) throws {
        let t = "AssistantMessageEvent"
        let o = try object(json, t)
        func partial() throws -> AssistantMessage { try AssistantMessage(json: try requireValue(o, "partial", t)) }
        func index() throws -> Int { try int(o, "contentIndex", t) }
        switch try string(o, "type", t) {
        case "start": self = .start(partial: try partial())
        case "text_start": self = .textStart(contentIndex: try index(), partial: try partial())
        case "text_delta": self = .textDelta(contentIndex: try index(), delta: try string(o, "delta", t), partial: try partial())
        case "text_end": self = .textEnd(contentIndex: try index(), content: try string(o, "content", t), partial: try partial())
        case "thinking_start": self = .thinkingStart(contentIndex: try index(), partial: try partial())
        case "thinking_delta": self = .thinkingDelta(contentIndex: try index(), delta: try string(o, "delta", t), partial: try partial())
        case "thinking_end": self = .thinkingEnd(contentIndex: try index(), content: try string(o, "content", t), partial: try partial())
        case "toolcall_start": self = .toolcallStart(contentIndex: try index(), partial: try partial())
        case "toolcall_delta": self = .toolcallDelta(contentIndex: try index(), delta: try string(o, "delta", t), partial: try partial())
        case "toolcall_end": self = .toolcallEnd(contentIndex: try index(), toolCall: try ToolCall(json: try requireValue(o, "toolCall", t)), partial: try partial())
        case "done": self = .done(reason: try StopReason(json: try requireValue(o, "reason", t)), message: try AssistantMessage(json: try requireValue(o, "message", t)))
        case "error": self = .error(reason: try StopReason(json: try requireValue(o, "reason", t)), error: try AssistantMessage(json: try requireValue(o, "error", t)))
        case let other: throw JsonShapeError("Unknown assistant message event type: \(other)")
        }
    }
}

// MARK: - Models

extension Model: JsonConvertible {
    public var json: JsonValue {
        var o: JsonObject = [
            "id": .string(id),
            "name": .string(name),
            "api": .string(api),
            "provider": .string(provider),
            "baseUrl": .string(baseUrl),
            "input": .array(input.map(JsonValue.string)),
        ]
        if let inputLimits { o["inputLimits"] = inputLimits.json }
        o["cost"] = cost.json
        if let headers {
            var headersObject = JsonObject()
            for (name, value) in headers { headersObject[name] = .string(value) }
            o["headers"] = .object(headersObject)
        }
        if let type { o["type"] = .string(type) }
        o["reasoning"] = .bool(reasoning)
        if let thinkingLevelMap { o["thinkingLevelMap"] = thinkingLevelMapToJson(thinkingLevelMap) }
        if let promptCache { o["promptCache"] = promptCache.json }
        o["contextWindow"] = num(contextWindow)
        o["maxTokens"] = num(maxTokens)
        if let samplingParams { o["samplingParams"] = .object(samplingParams) }
        if let samplingParamsByThinkingLevel { o["samplingParamsByThinkingLevel"] = samplingParamsByThinkingLevelToJson(samplingParamsByThinkingLevel) }
        if let compat { o["compat"] = .object(compat) }
        return .object(o)
    }
    public init(json: JsonValue) throws {
        let t = "Model"
        let o = try object(json, t)
        var headers: [(String, String)]?
        if let headersObject = try optionalObject(o, "headers", t) {
            headers = try headersObject.map { key, value in
                guard case .string(let string) = value else { throw JsonShapeError("Model.headers.\(key) must be a string") }
                return (key, string)
            }
        }
        self.init(
            id: try string(o, "id", t), name: try string(o, "name", t), api: try string(o, "api", t), provider: try string(o, "provider", t),
            baseUrl: try string(o, "baseUrl", t), reasoning: try bool(o, "reasoning", t),
            input: try array(o, "input", t).map {
                guard case .string(let modality) = $0 else { throw JsonShapeError("Model.input entries must be strings") }
                return modality
            },
            cost: try ModelCost(json: try requireValue(o, "cost", t)),
            contextWindow: try int(o, "contextWindow", t), maxTokens: try int(o, "maxTokens", t),
            headers: headers, compat: try optionalObject(o, "compat", t)
        )
        inputLimits = try present(o, "inputLimits").map(ModelInputLimits.init(json:))
        type = try optionalString(o, "type", t)
        thinkingLevelMap = try present(o, "thinkingLevelMap").map(thinkingLevelMapFromJson)
        promptCache = try present(o, "promptCache").map(ModelPromptCache.init(json:))
        samplingParams = try optionalObject(o, "samplingParams", t)
        samplingParamsByThinkingLevel = try present(o, "samplingParamsByThinkingLevel").map(samplingParamsByThinkingLevelFromJson)
    }
}

// Not converted: StreamOptions / ProviderStreams carry closures, signals and fetch functions, which have no JSON form.
