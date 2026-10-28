import Foundation

/// 保持插入顺序的 JSON 对象。
///
/// 使用自己的有序对象，而不是 `[String: JsonValue]`，原因有二：
/// 1. Swift 的 `Dictionary` 迭代顺序每个进程都会随机化。工具 schema、请求体如果因此每次序列化结果不同，
///    就会破坏 Anthropic / OpenAI 的 prompt caching（缓存按字节前缀命中）。
/// 2. pi 上游的 system message `sections` 依赖对象键的顺序来渲染提示词，会话文件也需要按原顺序写回。
public struct JsonObject: Sendable, Hashable, Sequence, ExpressibleByDictionaryLiteral {
    public private(set) var keys: [String] = []
    private var storage: [String: JsonValue] = [:]

    public init() {}

    public init(_ pairs: [(String, JsonValue)]) {
        for (key, value) in pairs { self[key] = value }
    }

    public init(dictionaryLiteral elements: (String, JsonValue)...) {
        for (key, value) in elements { self[key] = value }
    }

    public var count: Int { keys.count }
    public var isEmpty: Bool { keys.isEmpty }

    /// 读取或写入键。写入 `nil` 表示删除该键（注意：写入 `.null` 会保留键并赋值为 JSON null）。
    public subscript(key: String) -> JsonValue? {
        get { storage[key] }
        set {
            if let newValue {
                if storage.updateValue(newValue, forKey: key) == nil { keys.append(key) }
            } else if storage.removeValue(forKey: key) != nil {
                keys.removeAll { $0 == key }
            }
        }
    }

    public func contains(_ key: String) -> Bool { storage[key] != nil }

    public func makeIterator() -> AnyIterator<(key: String, value: JsonValue)> {
        var index = 0
        let keys = self.keys
        let storage = self.storage
        return AnyIterator {
            guard index < keys.count else { return nil }
            let key = keys[index]
            index += 1
            return (key, storage[key]!)
        }
    }

    /// 等值比较忽略键顺序，与 JSON 语义一致。
    public static func == (lhs: JsonObject, rhs: JsonObject) -> Bool { lhs.storage == rhs.storage }
    public func hash(into hasher: inout Hasher) { hasher.combine(storage) }

    /// 以 `[String: JsonValue]` 形式访问（会丢失顺序）。
    public var dictionary: [String: JsonValue] { storage }
}

/// 任意 JSON 值。`[String: Any]` 不满足 `Sendable`，所以工具参数、schema、厂商私有字段都用它承载。
///
/// 数字统一存成 `Double`，与 JavaScript 一致：超过 2^53 的整数无法精确表示，大整数 ID 请用字符串传递。
public enum JsonValue: Sendable, Hashable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([JsonValue])
    case object(JsonObject)
}

// MARK: - 便捷访问

extension JsonValue {
    public var stringValue: String? { if case .string(let v) = self { return v } else { return nil } }
    public var boolValue: Bool? { if case .bool(let v) = self { return v } else { return nil } }
    public var doubleValue: Double? { if case .number(let v) = self { return v } else { return nil } }
    public var intValue: Int? {
        guard case .number(let v) = self, v.isFinite, v.rounded() == v, abs(v) < 9.007_199_254_740_992e15 else { return nil }
        return Int(v)
    }
    public var arrayValue: [JsonValue]? { if case .array(let v) = self { return v } else { return nil } }
    public var objectValue: JsonObject? { if case .object(let v) = self { return v } else { return nil } }
    public var isNull: Bool { if case .null = self { return true } else { return false } }

    public subscript(key: String) -> JsonValue? {
        get { objectValue?[key] }
        set {
            guard case .object(var object) = self else { return }
            object[key] = newValue
            self = .object(object)
        }
    }

    public subscript(index: Int) -> JsonValue? {
        guard case .array(let array) = self, array.indices.contains(index) else { return nil }
        return array[index]
    }

    /// JSON 类型名，用于校验错误信息。
    public var typeName: String {
        switch self {
        case .null: return "null"
        case .bool: return "boolean"
        case .number(let v): return v.rounded() == v ? "integer" : "number"
        case .string: return "string"
        case .array: return "array"
        case .object: return "object"
        }
    }

    public static let emptyObject: JsonValue = .object(JsonObject())
}

// MARK: - 字面量

extension JsonValue: ExpressibleByNilLiteral, ExpressibleByBooleanLiteral, ExpressibleByIntegerLiteral,
    ExpressibleByFloatLiteral, ExpressibleByStringLiteral, ExpressibleByArrayLiteral, ExpressibleByDictionaryLiteral
{
    public init(nilLiteral: ()) { self = .null }
    public init(booleanLiteral value: Bool) { self = .bool(value) }
    public init(integerLiteral value: Int) { self = .number(Double(value)) }
    public init(floatLiteral value: Double) { self = .number(value) }
    public init(stringLiteral value: String) { self = .string(value) }
    public init(arrayLiteral elements: JsonValue...) { self = .array(elements) }
    public init(dictionaryLiteral elements: (String, JsonValue)...) {
        var object = JsonObject()
        for (key, value) in elements { object[key] = value }
        self = .object(object)
    }
}

// MARK: - 文本 <-> JsonValue

extension JsonValue {
    /// 严格解析 JSON 文本。
    public static func parse(_ text: String) throws -> JsonValue {
        try JsonParser.parse(text)
    }

    /// 解析 JSON 文本，失败时先修复字符串中的非法转义 / 裸控制字符再重试（对应上游 `parseJsonWithRepair`）。
    public static func parseWithRepair(_ text: String) throws -> JsonValue {
        do {
            return try JsonParser.parse(text)
        } catch {
            let repaired = JsonParser.repair(text)
            if repaired != text { return try JsonParser.parse(repaired) }
            throw error
        }
    }

    /// 序列化为紧凑 JSON 文本，键按插入顺序输出（与 `JSON.stringify` 一致）。
    public func serialized(pretty: Bool = false) -> String {
        var writer = JsonWriter(pretty: pretty)
        writer.write(self, indent: 0)
        return writer.output
    }
}

extension JsonValue: CustomStringConvertible {
    public var description: String { serialized() }
}

// MARK: - Codable（便于与 Swift 类型互转；注意 JSONEncoder 不保证键顺序）

extension JsonValue: Codable {
    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Double.self) {
            self = .number(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode([JsonValue].self) {
            self = .array(value)
        } else if let value = try? container.decode([String: JsonValue].self) {
            var object = JsonObject()
            for key in value.keys.sorted() { object[key] = value[key] }
            self = .object(object)
        } else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Unsupported JSON value")
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .null: try container.encodeNil()
        case .bool(let v): try container.encode(v)
        case .number(let v): try container.encode(v)
        case .string(let v): try container.encode(v)
        case .array(let v): try container.encode(v)
        case .object(let v): try container.encode(v.dictionary)
        }
    }
}

extension JsonValue {
    /// 把 `Encodable` 值转成 JsonValue（经由 JSONEncoder，再用有序解析器读回）。
    public init<T: Encodable>(encoding value: T) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(value)
        self = try JsonParser.parse(String(decoding: data, as: UTF8.self))
    }

    /// 把 JsonValue 解码成 `Decodable` 类型。
    public func decode<T: Decodable>(_ type: T.Type = T.self) throws -> T {
        let data = Data(serialized().utf8)
        return try JSONDecoder().decode(T.self, from: data)
    }
}
