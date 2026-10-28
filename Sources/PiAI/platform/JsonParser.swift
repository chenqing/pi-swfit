import Foundation

public struct JsonParseError: Error, CustomStringConvertible, Sendable {
    public let message: String
    public let offset: Int
    public var description: String { "JSON parse error at byte \(offset): \(message)" }
}

/// 有序、零依赖的 JSON 解析器。
///
/// 支持三种模式：
/// - 严格解析（`parse`）：标准 JSON。
/// - 修复（`repair`）：转义字符串中的裸控制字符、修复非法反斜杠转义，对应上游 `repairJson`。
/// - 增量解析（`parsePartial`）：用于流式工具参数，输入可以在任意位置被截断，
///   返回已经能确定的部分（未闭合的字符串 / 数组 / 对象会被补全），对应上游 `parseStreamingJson`。
public enum JsonParser {
    public static func parse(_ text: String) throws -> JsonValue {
        var parser = Parser(bytes: Array(text.utf8), partial: false)
        parser.skipWhitespace()
        guard let value = try parser.parseValue() else {
            throw JsonParseError(message: "Unexpected end of input", offset: parser.index)
        }
        parser.skipWhitespace()
        if parser.index < parser.bytes.count {
            throw JsonParseError(message: "Unexpected trailing characters", offset: parser.index)
        }
        return value
    }

    /// 尽力解析可能被截断的 JSON。永远不抛错：完全无法解析时返回 `nil`。
    public static func parsePartial(_ text: String) -> JsonValue? {
        if text.allSatisfy({ $0.isWhitespace }) { return nil }
        if let value = try? JsonValue.parseWithRepair(text) { return value }
        for candidate in [text, repair(text)] {
            var parser = Parser(bytes: Array(candidate.utf8), partial: true)
            parser.skipWhitespace()
            if let value = try? parser.parseValue() { return value }
        }
        return nil
    }

    /// 修复字符串字面量中的常见错误：裸控制字符、非法转义、末尾孤立的反斜杠。
    public static func repair(_ json: String) -> String {
        let scalars = Array(json.unicodeScalars)
        var out = String.UnicodeScalarView()
        var inString = false
        var i = 0
        let validEscapes: Set<Unicode.Scalar> = ["\"", "\\", "/", "b", "f", "n", "r", "t"]
        while i < scalars.count {
            let c = scalars[i]
            if !inString {
                out.append(c)
                if c == "\"" { inString = true }
                i += 1
                continue
            }
            if c == "\"" {
                out.append(c)
                inString = false
                i += 1
                continue
            }
            if c == "\\" {
                guard i + 1 < scalars.count else {
                    out.append(contentsOf: "\\\\".unicodeScalars)
                    i += 1
                    continue
                }
                let next = scalars[i + 1]
                if next == "u", i + 5 < scalars.count,
                   scalars[(i + 2)...(i + 5)].allSatisfy({ $0.properties.isASCIIHexDigit })
                {
                    out.append(contentsOf: scalars[i...(i + 5)])
                    i += 6
                    continue
                }
                if validEscapes.contains(next) {
                    out.append(c)
                    out.append(next)
                    i += 2
                    continue
                }
                out.append(contentsOf: "\\\\".unicodeScalars)
                i += 1
                continue
            }
            if c.value < 0x20 {
                switch c {
                case "\u{08}": out.append(contentsOf: "\\b".unicodeScalars)
                case "\u{0C}": out.append(contentsOf: "\\f".unicodeScalars)
                case "\n": out.append(contentsOf: "\\n".unicodeScalars)
                case "\r": out.append(contentsOf: "\\r".unicodeScalars)
                case "\t": out.append(contentsOf: "\\t".unicodeScalars)
                default:
                    let hex = String(c.value, radix: 16)
                    out.append(contentsOf: ("\\u" + String(repeating: "0", count: 4 - hex.count) + hex).unicodeScalars)
                }
                i += 1
                continue
            }
            out.append(c)
            i += 1
        }
        return String(out)
    }
}

private struct Parser {
    let bytes: [UInt8]
    let partial: Bool
    var index = 0
    /// 增量模式下遇到输入结尾时置位，外层容器据此立即收尾返回。
    var truncated = false

    init(bytes: [UInt8], partial: Bool) {
        self.bytes = bytes
        self.partial = partial
    }

    var atEnd: Bool { index >= bytes.count }

    mutating func skipWhitespace() {
        while index < bytes.count {
            switch bytes[index] {
            case 0x20, 0x09, 0x0A, 0x0D: index += 1
            default: return
            }
        }
    }

    func error(_ message: String) -> JsonParseError { JsonParseError(message: message, offset: index) }

    /// 遇到输入结尾：严格模式抛错；增量模式标记截断。
    mutating func hitEnd() throws {
        if partial { truncated = true } else { throw error("Unexpected end of input") }
    }

    mutating func parseValue() throws -> JsonValue? {
        skipWhitespace()
        guard !atEnd else { try hitEnd(); return nil }
        switch bytes[index] {
        case UInt8(ascii: "{"): return try parseObject()
        case UInt8(ascii: "["): return try parseArray()
        case UInt8(ascii: "\""):
            let s = try parseString()
            return s.map(JsonValue.string)
        case UInt8(ascii: "t"): return try parseLiteral("true", .bool(true))
        case UInt8(ascii: "f"): return try parseLiteral("false", .bool(false))
        case UInt8(ascii: "n"): return try parseLiteral("null", .null)
        case UInt8(ascii: "-"), UInt8(ascii: "0")...UInt8(ascii: "9"): return try parseNumber()
        default: throw error("Unexpected character '\(Character(Unicode.Scalar(bytes[index])))'")
        }
    }

    mutating func parseLiteral(_ word: String, _ value: JsonValue) throws -> JsonValue? {
        let w = Array(word.utf8)
        for (offset, expected) in w.enumerated() {
            if index + offset >= bytes.count {
                try hitEnd()
                index = bytes.count
                return value // 增量模式：前缀匹配即补全（"tr" → true）
            }
            if bytes[index + offset] != expected { throw error("Invalid literal") }
        }
        index += w.count
        return value
    }

    mutating func parseNumber() throws -> JsonValue? {
        let start = index
        if bytes[index] == UInt8(ascii: "-") { index += 1 }
        while index < bytes.count {
            let b = bytes[index]
            if (UInt8(ascii: "0")...UInt8(ascii: "9")).contains(b) || b == UInt8(ascii: ".") || b == UInt8(ascii: "e")
                || b == UInt8(ascii: "E") || b == UInt8(ascii: "+") || b == UInt8(ascii: "-")
            {
                index += 1
            } else {
                break
            }
        }
        let text = String(decoding: bytes[start..<index], as: UTF8.self)
        if let value = Double(text), isValidJSONNumber(text) { return .number(value) }
        if partial && atEnd {
            truncated = true
            // 截断的数字（如 "12." 或 "-"）：取最长的合法前缀
            var candidate = text
            while !candidate.isEmpty {
                candidate.removeLast()
                if let value = Double(candidate), isValidJSONNumber(candidate) { return .number(value) }
            }
            return nil
        }
        throw JsonParseError(message: "Invalid number '\(text)'", offset: start)
    }

    func isValidJSONNumber(_ text: String) -> Bool {
        // 排除 Swift 接受但 JSON 不接受的写法（"inf"、"nan"、"0x10"、前导 "+"、前导零等）
        let bytes = Array(text.utf8)
        var i = 0
        if i < bytes.count, bytes[i] == UInt8(ascii: "-") { i += 1 }
        guard i < bytes.count else { return false }
        if bytes[i] == UInt8(ascii: "0") {
            i += 1
        } else if (UInt8(ascii: "1")...UInt8(ascii: "9")).contains(bytes[i]) {
            while i < bytes.count, (UInt8(ascii: "0")...UInt8(ascii: "9")).contains(bytes[i]) { i += 1 }
        } else {
            return false
        }
        if i < bytes.count, bytes[i] == UInt8(ascii: ".") {
            i += 1
            let s = i
            while i < bytes.count, (UInt8(ascii: "0")...UInt8(ascii: "9")).contains(bytes[i]) { i += 1 }
            if i == s { return false }
        }
        if i < bytes.count, bytes[i] == UInt8(ascii: "e") || bytes[i] == UInt8(ascii: "E") {
            i += 1
            if i < bytes.count, bytes[i] == UInt8(ascii: "+") || bytes[i] == UInt8(ascii: "-") { i += 1 }
            let s = i
            while i < bytes.count, (UInt8(ascii: "0")...UInt8(ascii: "9")).contains(bytes[i]) { i += 1 }
            if i == s { return false }
        }
        return i == bytes.count
    }

    mutating func parseString() throws -> String? {
        index += 1 // 开头的引号
        var buffer: [UInt8] = []
        while true {
            guard !atEnd else {
                try hitEnd()
                return String(decoding: buffer, as: UTF8.self)
            }
            let b = bytes[index]
            if b == UInt8(ascii: "\"") {
                index += 1
                return String(decoding: buffer, as: UTF8.self)
            }
            if b == UInt8(ascii: "\\") {
                guard index + 1 < bytes.count else {
                    try hitEnd()
                    index = bytes.count
                    return String(decoding: buffer, as: UTF8.self)
                }
                let e = bytes[index + 1]
                index += 2
                switch e {
                case UInt8(ascii: "\""): buffer.append(UInt8(ascii: "\""))
                case UInt8(ascii: "\\"): buffer.append(UInt8(ascii: "\\"))
                case UInt8(ascii: "/"): buffer.append(UInt8(ascii: "/"))
                case UInt8(ascii: "b"): buffer.append(0x08)
                case UInt8(ascii: "f"): buffer.append(0x0C)
                case UInt8(ascii: "n"): buffer.append(0x0A)
                case UInt8(ascii: "r"): buffer.append(0x0D)
                case UInt8(ascii: "t"): buffer.append(0x09)
                case UInt8(ascii: "u"):
                    guard let unit = readHex4() else {
                        if partial && index + 4 > bytes.count {
                            truncated = true
                            index = bytes.count
                            return String(decoding: buffer, as: UTF8.self)
                        }
                        throw error("Invalid unicode escape")
                    }
                    var scalarValue = UInt32(unit)
                    if (0xD800...0xDBFF).contains(unit) {
                        // 代理对：期望紧跟 \uDC00-\uDFFF
                        if index + 1 < bytes.count, bytes[index] == UInt8(ascii: "\\"), bytes[index + 1] == UInt8(ascii: "u") {
                            index += 2
                            if let low = readHex4(), (0xDC00...0xDFFF).contains(low) {
                                scalarValue = 0x10000 + ((UInt32(unit) - 0xD800) << 10) + (UInt32(low) - 0xDC00)
                            } else {
                                scalarValue = 0xFFFD
                            }
                        } else {
                            scalarValue = 0xFFFD
                        }
                    } else if (0xDC00...0xDFFF).contains(unit) {
                        scalarValue = 0xFFFD
                    }
                    let scalar = Unicode.Scalar(scalarValue) ?? "\u{FFFD}"
                    buffer.append(contentsOf: Array(String(Character(scalar)).utf8))
                default:
                    throw error("Invalid escape '\\\(Character(Unicode.Scalar(e)))'")
                }
                continue
            }
            if b < 0x20 { throw error("Unescaped control character in string") }
            buffer.append(b)
            index += 1
        }
    }

    mutating func readHex4() -> UInt16? {
        guard index + 4 <= bytes.count else { return nil }
        var value: UInt16 = 0
        for i in 0..<4 {
            let b = bytes[index + i]
            let digit: UInt16
            switch b {
            case UInt8(ascii: "0")...UInt8(ascii: "9"): digit = UInt16(b - UInt8(ascii: "0"))
            case UInt8(ascii: "a")...UInt8(ascii: "f"): digit = UInt16(b - UInt8(ascii: "a") + 10)
            case UInt8(ascii: "A")...UInt8(ascii: "F"): digit = UInt16(b - UInt8(ascii: "A") + 10)
            default: return nil
            }
            value = value * 16 + digit
        }
        index += 4
        return value
    }

    mutating func parseArray() throws -> JsonValue? {
        index += 1
        var items: [JsonValue] = []
        skipWhitespace()
        if atEnd { try hitEnd(); return .array(items) }
        if bytes[index] == UInt8(ascii: "]") { index += 1; return .array(items) }
        while true {
            let value = try parseValue()
            if let value { items.append(value) }
            if truncated { return .array(items) }
            skipWhitespace()
            if atEnd { try hitEnd(); return .array(items) }
            if bytes[index] == UInt8(ascii: ",") {
                index += 1
                skipWhitespace()
                if atEnd { try hitEnd(); return .array(items) }
                continue
            }
            if bytes[index] == UInt8(ascii: "]") { index += 1; return .array(items) }
            throw error("Expected ',' or ']'")
        }
    }

    mutating func parseObject() throws -> JsonValue? {
        index += 1
        var object = JsonObject()
        skipWhitespace()
        if atEnd { try hitEnd(); return .object(object) }
        if bytes[index] == UInt8(ascii: "}") { index += 1; return .object(object) }
        while true {
            skipWhitespace()
            if atEnd { try hitEnd(); return .object(object) }
            guard bytes[index] == UInt8(ascii: "\"") else { throw error("Expected object key") }
            let key = try parseString()
            if truncated { return .object(object) } // 键本身被截断：丢弃
            skipWhitespace()
            if atEnd { try hitEnd(); return .object(object) }
            guard bytes[index] == UInt8(ascii: ":") else { throw error("Expected ':'") }
            index += 1
            skipWhitespace()
            if atEnd { try hitEnd(); return .object(object) }
            let value = try parseValue()
            if let key, let value { object[key] = value }
            if truncated { return .object(object) }
            skipWhitespace()
            if atEnd { try hitEnd(); return .object(object) }
            if bytes[index] == UInt8(ascii: ",") { index += 1; continue }
            if bytes[index] == UInt8(ascii: "}") { index += 1; return .object(object) }
            throw error("Expected ',' or '}'")
        }
    }
}

/// 与 `JSON.stringify` 输出一致的序列化器（键顺序、转义规则、整数格式）。
struct JsonWriter {
    let pretty: Bool
    var output = ""

    init(pretty: Bool) { self.pretty = pretty }

    mutating func write(_ value: JsonValue, indent: Int) {
        switch value {
        case .null: output += "null"
        case .bool(let b): output += b ? "true" : "false"
        case .number(let n): output += JsonWriter.formatNumber(n)
        case .string(let s): JsonWriter.writeString(s, into: &output)
        case .array(let items):
            if items.isEmpty { output += "[]"; return }
            output += "["
            for (i, item) in items.enumerated() {
                if i > 0 { output += "," }
                newline(indent + 1)
                write(item, indent: indent + 1)
            }
            newline(indent)
            output += "]"
        case .object(let object):
            if object.isEmpty { output += "{}"; return }
            output += "{"
            var first = true
            for (key, item) in object {
                if !first { output += "," }
                first = false
                newline(indent + 1)
                JsonWriter.writeString(key, into: &output)
                output += pretty ? ": " : ":"
                write(item, indent: indent + 1)
            }
            newline(indent)
            output += "}"
        }
    }

    mutating func newline(_ indent: Int) {
        guard pretty else { return }
        output += "\n" + String(repeating: "  ", count: indent)
    }

    static func formatNumber(_ n: Double) -> String {
        guard n.isFinite else { return "null" }
        return jsNumberToString(n)
    }

    static func writeString(_ s: String, into output: inout String) {
        output += "\""
        for scalar in s.unicodeScalars {
            switch scalar {
            case "\"": output += "\\\""
            case "\\": output += "\\\\"
            case "\n": output += "\\n"
            case "\r": output += "\\r"
            case "\t": output += "\\t"
            case "\u{08}": output += "\\b"
            case "\u{0C}": output += "\\f"
            default:
                if scalar.value < 0x20 {
                    let hex = String(scalar.value, radix: 16)
                    output += "\\u" + String(repeating: "0", count: 4 - hex.count) + hex
                } else {
                    output.unicodeScalars.append(scalar)
                }
            }
        }
        output += "\""
    }
}

/// JS `Number.prototype.toString()` (radix 10).
func jsNumberToString(_ n: Double) -> String {
    if n.isNaN { return "NaN" }
    if n == 0 { return "0" }
    if n.isInfinite { return n > 0 ? "Infinity" : "-Infinity" }
    if n < 0 { return "-" + jsNumberToString(-n) }
    // Shortest round-trip digits from Swift, then ECMAScript Number::toString layout.
    let description = "\(n)"
    let parts = description.split(separator: "e", maxSplits: 1)
    let mantissa = String(parts[0])
    var exponent = parts.count > 1 ? Int(parts[1]) ?? 0 : 0
    var digits = mantissa.replacingOccurrences(of: ".", with: "")
    var point = (mantissa.firstIndex(of: ".").map { mantissa.distance(from: mantissa.startIndex, to: $0) } ?? mantissa.count)
    while digits.hasPrefix("0") && digits.count > 1 {
        digits.removeFirst()
        point -= 1
    }
    while digits.hasSuffix("0") && digits.count > 1 {
        digits.removeLast()
    }
    exponent += point
    let k = digits.count
    let nPos = exponent
    if k <= nPos && nPos <= 21 {
        return digits + String(repeating: "0", count: nPos - k)
    }
    if 0 < nPos && nPos <= 21 {
        let index = digits.index(digits.startIndex, offsetBy: nPos)
        return String(digits[..<index]) + "." + String(digits[index...])
    }
    if -6 < nPos && nPos <= 0 {
        return "0." + String(repeating: "0", count: -nPos) + digits
    }
    let e = nPos - 1
    let sign = e < 0 ? "-" : "+"
    if k == 1 {
        return digits + "e" + sign + String(abs(e))
    }
    return String(digits.prefix(1)) + "." + String(digits.dropFirst()) + "e" + sign + String(abs(e))
}
