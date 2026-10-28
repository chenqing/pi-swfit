import Foundation

// Port of packages/ai/src/utils/json-parse.ts.
//
// Upstream relies on V8's `JSON.parse` and on the `partial-json` package (0.1.7). Both are ported
// below over UTF-16 code units so indices, positions and error messages match JavaScript exactly:
// - `v8JsonParse` reproduces V8's `JSON.parse` grammar and its SyntaxError messages
//   (including the ` (line L column C)` suffix and the "is not valid JSON" context snippets).
// - `partialJsonParse` is a line-by-line port of partial-json's `parseJSON` with `Allow.ALL`.

private let VALID_JSON_ESCAPES: Set<UInt16> = Set(["\"", "\\", "/", "b", "f", "n", "r", "t"].map { $0.utf16.first! })

private func isControlCharacter(_ char: UInt16) -> Bool {
	return char >= 0x00 && char <= 0x1f
}

private func escapeControlCharacter(_ char: UInt16) -> String {
	switch char {
	case 0x08:
		return "\\b"
	case 0x0c:
		return "\\f"
	case 0x0a:
		return "\\n"
	case 0x0d:
		return "\\r"
	case 0x09:
		return "\\t"
	default:
		let hex = String(char, radix: 16)
		return "\\u" + String(repeating: "0", count: max(0, 4 - hex.count)) + hex
	}
}

private func isHexDigit(_ c: UInt16) -> Bool {
	return (c >= 0x30 && c <= 0x39) || (c >= 0x41 && c <= 0x46) || (c >= 0x61 && c <= 0x66)
}

/**
 * Repairs malformed JSON string literals by:
 * - escaping raw control characters inside strings
 * - doubling backslashes before invalid escape characters
 */
public func repairJson(_ json: String) -> String {
	let units = Array(json.utf16)
	var repaired: [UInt16] = []
	repaired.reserveCapacity(units.count)
	var inString = false
	let quote: UInt16 = 0x22
	let backslash: UInt16 = 0x5c

	var index = 0
	while index < units.count {
		defer { index += 1 }
		let char = units[index]

		if !inString {
			repaired.append(char)
			if char == quote {
				inString = true
			}
			continue
		}

		if char == quote {
			repaired.append(char)
			inString = false
			continue
		}

		if char == backslash {
			guard index + 1 < units.count else {
				repaired.append(contentsOf: [backslash, backslash])
				continue
			}
			let nextChar = units[index + 1]

			if nextChar == 0x75 /* u */ {
				let digitsEnd = min(index + 6, units.count)
				let digitsStart = min(index + 2, digitsEnd)
				let unicodeDigits = units[digitsStart..<digitsEnd]
				if unicodeDigits.count == 4 && unicodeDigits.allSatisfy(isHexDigit) {
					repaired.append(contentsOf: [backslash, 0x75])
					repaired.append(contentsOf: unicodeDigits)
					index += 5
					continue
				}
			}

			if VALID_JSON_ESCAPES.contains(nextChar) {
				repaired.append(contentsOf: [backslash, nextChar])
				index += 1
				continue
			}

			repaired.append(contentsOf: [backslash, backslash])
			continue
		}

		if isControlCharacter(char) {
			repaired.append(contentsOf: escapeControlCharacter(char).utf16)
		} else {
			repaired.append(char)
		}
	}

	return String(decoding: repaired, as: UTF16.self)
}

public func parseJsonWithRepair(_ json: String) throws -> JsonValue {
	do {
		return try v8JsonParse(json)
	} catch {
		let repairedJson = repairJson(json)
		if repairedJson != json {
			return try v8JsonParse(repairedJson)
		}
		throw error
	}
}

/// `Pick<ToolCall, "arguments" | "argumentsError">`.
public struct ParsedToolCallArguments: Sendable, Hashable {
	public var arguments: JsonObject
	public var argumentsError: String?
	public init(arguments: JsonObject, argumentsError: String? = nil) {
		self.arguments = arguments
		self.argumentsError = argumentsError
	}
}

/**
 * Parses the model's complete arguments text of a finished tool call.
 *
 * Unlike {@link parseStreamingJson}, this never keeps a partially parsed prefix: once the call is
 * finished, text that is not a valid JSON object means the model sent malformed arguments. In that
 * case `arguments` is `{}` and `argumentsError` describes the problem, including the text the
 * model sent, so tool validation can report it back to the model.
 */
public func parseToolCallArguments(_ json: String?) -> ParsedToolCallArguments {
	guard let json, !jsTrim(json).isEmpty else { return ParsedToolCallArguments(arguments: JsonObject()) }
	do {
		let parsed = try parseJsonWithRepair(json)
		guard case .object(let object) = parsed else {
			throw PiError("Tool arguments must be a JSON object")
		}
		return ParsedToolCallArguments(arguments: object)
	} catch {
		return ParsedToolCallArguments(
			arguments: JsonObject(),
			argumentsError: "\(errorMessage(error))\n\nReceived arguments:\n\(json)"
		)
	}
}

/**
 * Attempts to parse potentially incomplete JSON during streaming.
 * Always returns a valid object, even if the JSON is incomplete.
 *
 * @param partialJson The partial JSON string from streaming
 * @returns Parsed object or empty object if parsing fails
 */
public func parseStreamingJson(_ partialJson: String?) -> JsonObject {
	// Upstream is generic (`T = Record<string, unknown>`) and returns non-object results unchanged;
	// typed callers only ever use the object form, so non-object results become `{}` here.
	// Use `parseStreamingJsonValue` for the raw result.
	if case .object(let object) = parseStreamingJsonValue(partialJson) { return object }
	return JsonObject()
}

/// Untyped variant of `parseStreamingJson` that returns whatever value was parsed (`{}` on failure).
public func parseStreamingJsonValue(_ partialJson: String?) -> JsonValue {
	guard let partialJson, jsTrim(partialJson) != "" else {
		return .object(JsonObject())
	}

	do {
		return try parseJsonWithRepair(partialJson)
	} catch {
		do {
			let result = try partialJsonParse(partialJson)
			return result == .null ? .object(JsonObject()) : result
		} catch {
			do {
				let result = try partialJsonParse(repairJson(partialJson))
				return result == .null ? .object(JsonObject()) : result
			} catch {
				return .object(JsonObject())
			}
		}
	}
}

// MARK: - JS string helpers (UTF-16)

/// `String.prototype.substring` over UTF-16 code units (clamps and swaps arguments).
private func jsSubstring(_ s: [UInt16], _ start: Int, _ end: Int? = nil) -> [UInt16] {
	var a = min(max(start, 0), s.count)
	var b = min(max(end ?? s.count, 0), s.count)
	if a > b { swap(&a, &b) }
	return Array(s[a..<b])
}

/// `String.prototype.lastIndexOf` for a single code unit.
private func jsLastIndexOf(_ s: [UInt16], _ unit: UInt16) -> Int {
	return s.lastIndex(of: unit) ?? -1
}

private func utf16String(_ units: some Collection<UInt16>) -> String {
	return String(decoding: units, as: UTF16.self)
}

private func unit(_ c: Character) -> UInt16 { c.utf16.first! }

// MARK: - V8 JSON.parse

private enum V8JsonToken {
	case eos, string, number, lbrace, lbrack, trueLiteral, falseLiteral, nullLiteral, whitespace, colon, comma, rbrack, rbrace, illegal
}

private func v8OneCharToken(_ c: UInt16?) -> V8JsonToken {
	guard let c else { return .eos }
	switch c {
	case 0x22: return .string
	case 0x2d, 0x30...0x39: return .number
	case 0x7b: return .lbrace
	case 0x5b: return .lbrack
	case 0x74: return .trueLiteral
	case 0x66: return .falseLiteral
	case 0x6e: return .nullLiteral
	case 0x20, 0x09, 0x0a, 0x0d: return .whitespace
	case 0x3a: return .colon
	case 0x2c: return .comma
	case 0x5d: return .rbrack
	case 0x7d: return .rbrace
	default: return .illegal
	}
}

/// `JSON.parse` with V8's exact SyntaxError messages. Positions are UTF-16 offsets.
func v8JsonParse(_ text: String) throws -> JsonValue {
	var parser = V8JsonParser(Array(text.utf16))
	return try parser.parse()
}

private struct V8JsonParser {
	let source: [UInt16]
	var cursor = 0

	static let kMaxContextCharacters = 10
	static let kMinOriginalSourceLengthForContext = kMaxContextCharacters * 2 + 1

	init(_ source: [UInt16]) {
		self.source = source
	}

	var isAtEnd: Bool { cursor >= source.count }
	var current: UInt16? { cursor < source.count ? source[cursor] : nil }

	mutating func next() -> UInt16? {
		cursor += 1
		return current
	}

	func peek() -> V8JsonToken { v8OneCharToken(current) }

	mutating func skipWhitespace() {
		while let c = current, c == 0x20 || c == 0x09 || c == 0x0a || c == 0x0d { cursor += 1 }
	}

	mutating func parse() throws -> JsonValue {
		let value = try parseValue()
		skipWhitespace()
		if !isAtEnd {
			throw report(peek(), "Unexpected non-whitespace character after JSON")
		}
		return value
	}

	// MARK: Errors

	func fileLocation() -> (line: Int, column: Int) {
		// JSON allows only \r and \n as line terminators.
		var line = 1
		var lastLineBreak = 0
		var index = 0
		let end = cursor
		while index < end {
			if source[index] == 0x0d && index < end - 1 && source[index + 1] == 0x0a {
				// \r\n counts as a single newline.
				index += 1
			}
			if source[index] == 0x0d || source[index] == 0x0a {
				line += 1
				lastLineBreak = index + 1
			}
			index += 1
		}
		return (line, 1 + index - lastLineBreak)
	}

	func syntaxError(_ message: String) -> PiError { PiError(message, name: "SyntaxError") }

	func positioned(_ message: String) -> PiError {
		let location = fileLocation()
		return syntaxError("\(message) in JSON at position \(cursor) (line \(location.line) column \(location.column))")
	}

	func isSpecialString() -> Bool {
		let text = utf16String(source)
		return text == "[object Object]" || text == "undefined" || text == "Infinity" || text == "NaN"
	}

	/// `JsonParser::ReportUnexpectedToken`.
	func report(_ token: V8JsonToken, _ errorMessage: String? = nil) -> PiError {
		if let errorMessage { return positioned(errorMessage) }
		switch token {
		case .eos:
			return syntaxError("Unexpected end of JSON input")
		case .number:
			return positioned("Unexpected number")
		case .string:
			return positioned("Unexpected string")
		default:
			if isSpecialString() {
				return syntaxError("\"\(utf16String(source))\" is not valid JSON")
			}
			let token = current.map { utf16String([$0]) } ?? ""
			let length = source.count
			let pos = cursor
			if length < Self.kMinOriginalSourceLengthForContext {
				return syntaxError("Unexpected token '\(token)', \"\(utf16String(source))\" is not valid JSON")
			}
			let k = Self.kMaxContextCharacters
			if pos < k {
				let context = utf16String(source[0..<min(pos + k, length)])
				return syntaxError("Unexpected token '\(token)', \"\(context)\"... is not valid JSON")
			} else if pos < length - k {
				let context = utf16String(source[(pos - k)..<(pos + k)])
				return syntaxError("Unexpected token '\(token)', ...\"\(context)\"... is not valid JSON")
			} else {
				let context = utf16String(source[(pos - k)..<length])
				return syntaxError("Unexpected token '\(token)', ...\"\(context)\" is not valid JSON")
			}
		}
	}

	/// `JsonParser::ReportUnexpectedCharacter`.
	func reportCharacter(_ c: UInt16?) -> PiError {
		guard let c else { return report(.eos) }
		return report(c < 0x80 ? v8OneCharToken(c) : .illegal)
	}

	// MARK: Grammar

	mutating func check(_ token: V8JsonToken) -> Bool {
		skipWhitespace()
		if peek() == token {
			cursor += 1
			return true
		}
		return false
	}

	mutating func expectNext(_ token: V8JsonToken, _ errorMessage: String) throws {
		skipWhitespace()
		if peek() == token {
			cursor += 1
			return
		}
		throw report(peek(), errorMessage)
	}

	mutating func parseValue() throws -> JsonValue {
		skipWhitespace()
		switch peek() {
		case .string:
			cursor += 1
			return .string(try scanString())
		case .number:
			return .number(try parseNumber())
		case .lbrace:
			cursor += 1
			var object = JsonObject()
			if check(.rbrace) { return .object(object) }
			try expectNext(.string, "Expected property name or '}'")
			while true {
				let key = try scanString()
				try expectNext(.colon, "Expected ':' after property name")
				object[key] = try parseValue()
				if check(.comma) {
					try expectNext(.string, "Expected double-quoted property name")
					continue
				}
				if peek() == .rbrace {
					cursor += 1
					return .object(object)
				}
				throw report(peek(), "Expected ',' or '}' after property value")
			}
		case .lbrack:
			cursor += 1
			var array: [JsonValue] = []
			if check(.rbrack) { return .array(array) }
			while true {
				array.append(try parseValue())
				if check(.comma) { continue }
				if peek() == .rbrack {
					cursor += 1
					return .array(array)
				}
				throw report(peek(), "Expected ',' or ']' after array element")
			}
		case .trueLiteral:
			try scanLiteral("true")
			return .bool(true)
		case .falseLiteral:
			try scanLiteral("false")
			return .bool(false)
		case .nullLiteral:
			try scanLiteral("null")
			return .null
		default:
			throw report(peek())
		}
	}

	mutating func scanLiteral(_ literal: String) throws {
		let s = Array(literal.utf16)
		let remaining = source.count - cursor
		if remaining >= s.count && Array(source[(cursor + 1)..<(cursor + s.count)]) == Array(s[1...]) {
			cursor += s.count
			return
		}
		cursor += 1
		for i in 0..<min(s.count - 1, remaining - 1) {
			if s[1 + i] != source[cursor] {
				throw reportCharacter(source[cursor])
			}
			cursor += 1
		}
		throw report(.eos)
	}

	/// Scans a string body; the cursor is just past the opening quote.
	mutating func scanString() throws -> String {
		var units: [UInt16] = []
		while true {
			guard let c = current else {
				throw report(.eos, "Unterminated string")
			}
			if c == 0x22 {
				cursor += 1
				return utf16String(units)
			}
			if c == 0x5c {
				let escaped = next()
				guard let escaped, escaped <= 0xff else {
					throw reportCharacter(escaped)
				}
				switch escaped {
				case 0x22, 0x5c, 0x2f: units.append(escaped)
				case 0x62: units.append(0x08)
				case 0x66: units.append(0x0c)
				case 0x6e: units.append(0x0a)
				case 0x72: units.append(0x0d)
				case 0x74: units.append(0x09)
				case 0x75:
					var value: UInt16 = 0
					for _ in 0..<4 {
						guard let digit = next(), let hex = hexValue(digit) else {
							throw report(.illegal, "Bad Unicode escape")
						}
						value = value * 16 + hex
					}
					units.append(value)
				default:
					throw report(.illegal, "Bad escaped character")
				}
				cursor += 1
				continue
			}
			if c < 0x20 {
				throw report(.illegal, "Bad control character in string literal")
			}
			units.append(c)
			cursor += 1
		}
	}

	func hexValue(_ c: UInt16) -> UInt16? {
		switch c {
		case 0x30...0x39: return c - 0x30
		case 0x41...0x46: return c - 0x41 + 10
		case 0x61...0x66: return c - 0x61 + 10
		default: return nil
		}
	}

	func isDecimalDigit(_ c: UInt16?) -> Bool {
		guard let c else { return false }
		return c >= 0x30 && c <= 0x39
	}

	mutating func advanceToNonDecimal() {
		while isDecimalDigit(current) { cursor += 1 }
	}

	mutating func parseNumber() throws -> Double {
		let start = cursor
		var c = current
		if c == 0x2d {
			c = next()
		}
		if c == 0x30 {
			// Prefix zero is only allowed if it's the only digit before
			// a decimal point or exponent.
			c = next()
			if isDecimalDigit(c) {
				throw report(.number)
			}
		} else {
			let digitsStart = cursor
			advanceToNonDecimal()
			if digitsStart == cursor {
				throw report(.illegal, "No number after minus sign")
			}
			c = current
		}

		if c == 0x2e {
			c = next()
			if !isDecimalDigit(c) {
				throw report(.illegal, "Unterminated fractional number")
			}
			advanceToNonDecimal()
		}

		if current == 0x65 || current == 0x45 {
			c = next()
			if c == 0x2d || c == 0x2b { c = next() }
			if !isDecimalDigit(c) {
				throw report(.illegal, "Exponent part is missing a number")
			}
			advanceToNonDecimal()
		}

		return Double(utf16String(source[start..<cursor])) ?? .nan
	}
}

// MARK: - partial-json 0.1.7 (`parse` with `Allow.ALL`)

private enum PartialJsonError: Error {
	/// `PartialJSON`
	case partial(String)
	/// `MalformedJSON`
	case malformed(String)
}

/// JS `String(e)` for the errors thrown inside partial-json.
private func jsErrorString(_ error: any Error) -> String {
	switch error {
	case PartialJsonError.partial(let message), PartialJsonError.malformed(let message):
		return "Error: \(message)"
	case let error as PiError:
		return "\(error.name): \(error.message)"
	default:
		return "Error: \(errorMessage(error))"
	}
}

/// JS property-key conversion (`obj[key] = value` with a non-string key).
private func jsPropertyKey(_ value: JsonValue) -> String {
	switch value {
	case .string(let s): return s
	case .null: return "null"
	case .bool(let b): return b ? "true" : "false"
	case .number(let n):
		if n.isNaN { return "NaN" }
		if n.isInfinite { return n > 0 ? "Infinity" : "-Infinity" }
		return JsonWriter.formatNumber(n)
	case .array(let items): return items.map { $0 == .null ? "" : jsPropertyKey($0) }.joined(separator: ",")
	case .object: return "[object Object]"
	}
}

/**
 * Parse incomplete JSON
 * @param {string} jsonString Partial JSON to be parsed
 * @returns The parsed JSON
 * @throws {PartialJSON} If the JSON is incomplete
 * @throws {MalformedJSON} If the JSON is malformed
 */
func partialJsonParse(_ jsonString: String) throws -> JsonValue {
	let trimmed = jsTrim(jsonString)
	if trimmed.isEmpty {
		throw PiError("\(jsonString) is empty")
	}
	var parser = PartialJsonParser(Array(trimmed.utf16))
	return try parser.parseAny()
}

private struct PartialJsonParser {
	let jsonString: [UInt16]
	let length: Int
	var index = 0

	init(_ jsonString: [UInt16]) {
		self.jsonString = jsonString
		self.length = jsonString.count
	}

	func char(_ i: Int) -> UInt16? { i >= 0 && i < length ? jsonString[i] : nil }

	func markPartialJSON(_ msg: String) -> PartialJsonError { .partial("\(msg) at position \(index)") }
	func throwMalformedError(_ msg: String) -> PartialJsonError { .malformed("\(msg) at position \(index)") }

	func jsonParse(_ units: [UInt16]) throws -> JsonValue { try v8JsonParse(utf16String(units)) }

	func matchesLiteral(_ literal: String, minRemaining: Int = 0) -> Bool {
		let lit = Array(literal.utf16)
		if jsSubstring(jsonString, index, index + lit.count) == lit { return true }
		let rest = jsSubstring(jsonString, index)
		return minRemaining < length - index && length - index < lit.count && lit.starts(with: rest)
	}

	mutating func parseAny() throws -> JsonValue {
		skipBlank()
		if index >= length { throw markPartialJSON("Unexpected end of input") }
		if char(index) == unit("\"") { return try parseStr() }
		if char(index) == unit("{") { return try parseObj() }
		if char(index) == unit("[") { return try parseArr() }
		if matchesLiteral("null") {
			index += 4
			return .null
		}
		if matchesLiteral("true") {
			index += 4
			return .bool(true)
		}
		if matchesLiteral("false") {
			index += 5
			return .bool(false)
		}
		if matchesLiteral("Infinity") {
			index += 8
			return .number(.infinity)
		}
		if matchesLiteral("-Infinity", minRemaining: 1) {
			index += 9
			return .number(-.infinity)
		}
		if matchesLiteral("NaN") {
			index += 3
			return .number(.nan)
		}
		return try parseNum()
	}

	mutating func parseStr() throws -> JsonValue {
		let start = index
		var escape = false
		index += 1 // skip initial quote
		while index < length && (jsonString[index] != unit("\"") || (escape && char(index - 1) == unit("\\"))) {
			escape = jsonString[index] == unit("\\") ? !escape : false
			index += 1
		}
		if char(index) == unit("\"") {
			do {
				index += 1
				return try jsonParse(jsSubstring(jsonString, start, index - (escape ? 1 : 0)))
			} catch {
				throw throwMalformedError(jsErrorString(error))
			}
		}
		// Allow.STR
		do {
			return try jsonParse(jsSubstring(jsonString, start, index - (escape ? 1 : 0)) + [unit("\"")])
		} catch {
			// SyntaxError: Invalid escape sequence
			return try jsonParse(jsSubstring(jsonString, start, jsLastIndexOf(jsonString, unit("\\"))) + [unit("\"")])
		}
	}

	mutating func parseObj() throws -> JsonValue {
		index += 1 // skip initial brace
		skipBlank()
		var obj = JsonObject()
		do {
			while char(index) != unit("}") {
				skipBlank()
				if index >= length { return .object(obj) } // Allow.OBJ
				let key = try parseStr()
				skipBlank()
				index += 1 // skip colon
				do {
					let value = try parseAny()
					obj[jsPropertyKey(key)] = value
				} catch {
					return .object(obj) // Allow.OBJ
				}
				skipBlank()
				if char(index) == unit(",") {
					index += 1 // skip comma
				}
			}
		} catch {
			return .object(obj) // Allow.OBJ
		}
		index += 1 // skip final brace
		return .object(obj)
	}

	mutating func parseArr() throws -> JsonValue {
		index += 1 // skip initial bracket
		var arr: [JsonValue] = []
		do {
			while char(index) != unit("]") {
				arr.append(try parseAny())
				skipBlank()
				if char(index) == unit(",") {
					index += 1 // skip comma
				}
			}
		} catch {
			return .array(arr) // Allow.ARR
		}
		index += 1 // skip final bracket
		return .array(arr)
	}

	mutating func parseNum() throws -> JsonValue {
		if index == 0 {
			if jsonString == Array("-".utf16) { throw throwMalformedError("Not sure what '-' is") }
			do {
				return try jsonParse(jsonString)
			} catch {
				// Allow.NUM
				if let value = try? jsonParse(jsSubstring(jsonString, 0, jsLastIndexOf(jsonString, unit("e")))) {
					return value
				}
				throw throwMalformedError(jsErrorString(error))
			}
		}
		let start = index
		if char(index) == unit("-") { index += 1 }
		let stops: [UInt16] = [unit(","), unit("]"), unit("}")]
		while let c = char(index), !stops.contains(c) { index += 1 }
		do {
			return try jsonParse(jsSubstring(jsonString, start, index))
		} catch {
			if jsSubstring(jsonString, start, index) == [unit("-")] { throw markPartialJSON("Not sure what '-' is") }
			do {
				return try jsonParse(jsSubstring(jsonString, start, jsLastIndexOf(jsonString, unit("e"))))
			} catch {
				throw throwMalformedError(jsErrorString(error))
			}
		}
	}

	mutating func skipBlank() {
		while index < length, [unit(" "), unit("\n"), unit("\r"), unit("\t")].contains(jsonString[index]) {
			index += 1
		}
	}
}
