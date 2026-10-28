import Foundation

// Port of packages/ai/src/utils/validation.ts.
//
// Upstream validates with TypeBox 1.3.27 (`Compile(schema).Check/Errors`). TypeBox's interpreted JSON
// Schema engine is ported below (`TypeBoxValidator`), keyword by keyword in TypeBox's evaluation order,
// with TypeBox's en_US error messages and its default `maxErrors` of 8.
//
// `Value.Convert(tool.parameters, args)` is not ported: TypeBox only converts schemas carrying the
// non-enumerable `~kind` marker, which never survives JSON. Swift tool schemas are plain JSON, for
// which `Value.Convert` is a no-op upstream as well. Likewise the `TypeBox.Kind` symbol check is always
// false for TypeBox 1.x schemas, so `coerceWithJsonSchema` always runs, exactly as here.

private func getSchemaTypes(_ schema: JsonObject) -> [String] {
	if case .string(let type) = schema["type"] {
		return [type]
	}
	if case .array(let types) = schema["type"] {
		return types.compactMap { $0.stringValue }
	}
	return []
}

private func matchesJsonType(_ value: JsonValue, _ type: String) -> Bool {
	switch type {
	case "number":
		if case .number = value { return true }
		return false
	case "integer":
		if case .number(let n) = value { return n.isFinite && n.rounded(.towardZero) == n }
		return false
	case "boolean":
		if case .bool = value { return true }
		return false
	case "string":
		if case .string = value { return true }
		return false
	case "null":
		return value == .null
	case "array":
		if case .array = value { return true }
		return false
	case "object":
		if case .object = value { return true }
		return false
	default:
		return false
	}
}

private func getSubSchemaValidator(_ schema: JsonValue) -> TypeBoxValidator? {
	return getValidator(schema)
}

/// JS `Number(string)`.
func jsNumber(_ text: String) -> Double {
	let trimmed = jsTrim(text)
	if trimmed.isEmpty { return 0 }
	let lower = trimmed.lowercased()
	for (prefix, radix) in [("0x", 16), ("0o", 8), ("0b", 2)] where lower.hasPrefix(prefix) {
		let digits = trimmed.dropFirst(2)
		guard !digits.isEmpty else { return .nan }
		var value = 0.0
		for c in digits {
			guard let digit = c.hexDigitValue, digit < radix else { return .nan }
			value = value * Double(radix) + Double(digit)
		}
		return value
	}
	switch trimmed {
	case "Infinity", "+Infinity": return .infinity
	case "-Infinity": return -.infinity
	default: break
	}
	let decimal = jsRegex(#"^[+-]?(?:\d+\.?\d*(?:[eE][+-]?\d+)?|\.\d+(?:[eE][+-]?\d+)?)$"#)
	guard jsRegexTest(decimal, trimmed) else { return .nan }
	return Double(trimmed) ?? .nan
}

private func coercePrimitiveByType(_ value: JsonValue, _ type: String) -> JsonValue {
	switch type {
	case "number":
		if value == .null {
			return .number(0)
		}
		if case .string(let text) = value, jsTrim(text) != "" {
			let parsed = jsNumber(text)
			if parsed.isFinite {
				return .number(parsed)
			}
		}
		if case .bool(let flag) = value {
			return .number(flag ? 1 : 0)
		}
		return value
	case "integer":
		if value == .null {
			return .number(0)
		}
		if case .string(let text) = value, jsTrim(text) != "" {
			let parsed = jsNumber(text)
			if parsed.isFinite && parsed.rounded(.towardZero) == parsed {
				return .number(parsed)
			}
		}
		if case .bool(let flag) = value {
			return .number(flag ? 1 : 0)
		}
		return value
	case "boolean":
		if value == .null {
			return .bool(false)
		}
		if case .string(let text) = value {
			if text == "true" {
				return .bool(true)
			}
			if text == "false" {
				return .bool(false)
			}
		}
		if case .number(let n) = value {
			if n == 1 {
				return .bool(true)
			}
			if n == 0 {
				return .bool(false)
			}
		}
		return value
	case "string":
		if value == .null {
			return .string("")
		}
		if case .number(let n) = value {
			return .string(jsNumberToString(n))
		}
		if case .bool(let flag) = value {
			return .string(flag ? "true" : "false")
		}
		return value
	case "null":
		if value == .string("") || value == .number(0) || value == .bool(false) {
			return .null
		}
		return value
	default:
		return value
	}
}

private func applySchemaObjectCoercion(_ value: inout JsonObject, _ schema: JsonObject) {
	let properties = schema["properties"]?.objectValue
	let definedKeys = Set(properties?.keys ?? [])

	if let properties {
		for (key, propertySchema) in properties {
			guard let current = value[key] else {
				continue
			}
			value[key] = coerceWithJsonSchema(current, propertySchema)
		}
	}

	if case .object = schema["additionalProperties"], let additionalProperties = schema["additionalProperties"] {
		for (key, propertyValue) in value {
			if definedKeys.contains(key) {
				continue
			}
			value[key] = coerceWithJsonSchema(propertyValue, additionalProperties)
		}
	}
}

private func applySchemaArrayCoercion(_ value: inout [JsonValue], _ schema: JsonObject) {
	if case .array(let items) = schema["items"] {
		for index in value.indices {
			guard index < items.count, isTruthy(items[index]) else {
				continue
			}
			value[index] = coerceWithJsonSchema(value[index], items[index])
		}
		return
	}

	if case .object = schema["items"], let items = schema["items"] {
		for index in value.indices {
			value[index] = coerceWithJsonSchema(value[index], items)
		}
	}
}

/// JS truthiness of a JSON value.
private func isTruthy(_ value: JsonValue) -> Bool {
	switch value {
	case .null: return false
	case .bool(let flag): return flag
	case .number(let n): return n != 0 && !n.isNaN
	case .string(let s): return !s.isEmpty
	case .array, .object: return true
	}
}

private func coerceWithUnionSchema(_ value: JsonValue, _ schemas: [JsonValue]) -> JsonValue {
	for schema in schemas {
		let validator = getSubSchemaValidator(schema)
		if validator?.check(value) == true {
			return value
		}
	}

	for schema in schemas {
		let candidate = value
		let coerced = coerceWithJsonSchema(candidate, schema)
		let validator = getSubSchemaValidator(schema)
		if validator?.check(coerced) == true {
			return coerced
		}
	}
	return value
}

private func coerceWithJsonSchema(_ value: JsonValue, _ schemaValue: JsonValue) -> JsonValue {
	guard case .object(let schema) = schemaValue else { return value }
	var nextValue = value

	if case .array(let allOf) = schema["allOf"] {
		for nested in allOf {
			nextValue = coerceWithJsonSchema(nextValue, nested)
		}
	}

	if case .array(let anyOf) = schema["anyOf"] {
		nextValue = coerceWithUnionSchema(nextValue, anyOf)
	}

	if case .array(let oneOf) = schema["oneOf"] {
		nextValue = coerceWithUnionSchema(nextValue, oneOf)
	}

	let schemaTypes = getSchemaTypes(schema)
	let matchesUnionMember = schemaTypes.count > 1 && schemaTypes.contains { matchesJsonType(nextValue, $0) }
	if !schemaTypes.isEmpty && !matchesUnionMember {
		for schemaType in schemaTypes {
			let candidate = coercePrimitiveByType(nextValue, schemaType)
			if candidate != nextValue {
				nextValue = candidate
				break
			}
		}
	}

	if schemaTypes.contains("object"), case .object(var object) = nextValue {
		applySchemaObjectCoercion(&object, schema)
		nextValue = .object(object)
	}

	if schemaTypes.contains("array"), case .array(var array) = nextValue {
		applySchemaArrayCoercion(&array, schema)
		nextValue = .array(array)
	}

	return nextValue
}

private func normalizeOptionalNulls(_ value: inout JsonValue, _ schemaValue: JsonValue) {
	guard case .object(let schema) = schemaValue else { return }
	if case .array(var array) = value {
		if case .array(let items) = schema["items"] {
			for index in array.indices where index < items.count {
				normalizeOptionalNulls(&array[index], items[index])
			}
		} else if let items = schema["items"], isTruthy(items) {
			for index in array.indices { normalizeOptionalNulls(&array[index], items) }
		}
		value = .array(array)
		return
	}
	guard case .object(var object) = value, case .object(let properties) = schema["properties"] else { return }

	let required = Set((schema["required"]?.arrayValue ?? []).compactMap { $0.stringValue })
	for (key, propertySchema) in properties {
		guard var property = object[key] else { continue }
		var isRef = false
		if case .object(let propertyObject) = propertySchema, case .string = propertyObject["$ref"] { isRef = true }
		if property == .null &&
			!required.contains(key) &&
			!isRef &&
			getSubSchemaValidator(propertySchema)?.check(.null) == false {
			object[key] = nil
		} else {
			normalizeOptionalNulls(&property, propertySchema)
			object[key] = property
		}
	}
	value = .object(object)
}

private func getValidator(_ schema: JsonValue) -> TypeBoxValidator {
	// Upstream caches compiled validators per schema object; the interpreter needs no compilation.
	return TypeBoxValidator(schema)
}

private func formatValidationPath(_ error: TypeBoxValidationError) -> String {
	if error.keyword == "required" {
		if let requiredProperty = error.requiredProperties.first, !requiredProperty.isEmpty {
			let basePath = validationPath(error.instancePath)
			return basePath.isEmpty ? requiredProperty : "\(basePath).\(requiredProperty)"
		}
	}
	let path = validationPath(error.instancePath)
	return path.isEmpty ? "root" : path
}

/// `instancePath.replace(/^\//, "").replace(/\//g, ".")`
private func validationPath(_ instancePath: String) -> String {
	var path = instancePath
	if path.hasPrefix("/") { path.removeFirst() }
	return path.replacingOccurrences(of: "/", with: ".")
}

/**
 * Finds a tool by name and validates the tool call arguments against its TypeBox schema
 * @param tools Array of tool definitions
 * @param toolCall The tool call from the LLM
 * @returns The validated arguments
 * @throws Error if tool is not found or validation fails
 */
public func validateToolCall(_ tools: [Tool], _ toolCall: ToolCall) throws -> JsonValue {
	guard let tool = tools.first(where: { $0.name == toolCall.name }) else {
		throw PiError("Tool \"\(toolCall.name)\" not found")
	}
	return try validateToolArguments(tool, toolCall)
}

/**
 * Validates tool call arguments against the tool's TypeBox schema
 * @param tool The tool definition with TypeBox schema
 * @param toolCall The tool call from the LLM
 * @returns The validated (and potentially coerced) arguments
 * @throws Error with formatted message if validation fails
 */
public func validateToolArguments(_ tool: Tool, _ toolCall: ToolCall) throws -> JsonValue {
	if let argumentsError = toolCall.argumentsError {
		throw PiError("Invalid arguments for tool \"\(toolCall.name)\": \(argumentsError)")
	}
	var args = JsonValue.object(toolCall.arguments)
	normalizeOptionalNulls(&args, tool.parameters)
	// Not ported: Value.Convert(tool.parameters, args) — a no-op for plain JSON schemas (see file header).

	let validator = getValidator(tool.parameters)
	let coerced = coerceWithJsonSchema(args, tool.parameters)
	if coerced != args {
		if case .object = coerced {
			args = coerced
		} else {
			return validator.check(coerced) ? coerced : args
		}
	}

	if validator.check(args) {
		return args
	}

	let formatted = validator
		.errors(args)
		.map { "  - \(formatValidationPath($0)): \($0.message)" }
		.joined(separator: "\n")
	let errors = formatted.isEmpty ? "Unknown validation error" : formatted

	let errorMessage = "Validation failed for tool \"\(toolCall.name)\":\n\(errors)\n\nReceived arguments:\n\(JsonValue.object(toolCall.arguments).serialized(pretty: true))"

	throw PiError(errorMessage)
}

// MARK: - TypeBox 1.3.27 schema engine (interpreted Check / Errors)

/// `TLocalizedValidationError` (only the fields pi reads, plus the paths).
struct TypeBoxValidationError: Sendable, Hashable {
	var keyword: String
	var schemaPath: String
	var instancePath: String
	/// `params.requiredProperties` for `required` errors.
	var requiredProperties: [String] = []
	/// en_US localized message.
	var message: String
}

/// TypeBox `Settings.Get().maxErrors` default.
private let TYPEBOX_MAX_ERRORS = 8

private final class TypeBoxErrorContext {
	var errors: [TypeBoxValidationError] = []
	var atCapacity: Bool { errors.count >= TYPEBOX_MAX_ERRORS }
	@discardableResult
	func addError(_ error: TypeBoxValidationError) -> Bool {
		if !atCapacity { errors.append(error) }
		return false
	}
}

/// `Compile(schema)` equivalent: `check(value)` and `errors(value)`.
struct TypeBoxValidator: Sendable {
	let root: JsonValue

	init(_ root: JsonValue) {
		self.root = root
	}

	func check(_ value: JsonValue) -> Bool {
		return checkSchema(root, value)
	}

	func errors(_ value: JsonValue) -> [TypeBoxValidationError] {
		let context = TypeBoxErrorContext()
		_ = errorSchema(context, "#", "", root, value)
		return context.errors
	}

	// MARK: Schema predicates

	private static func isSchema(_ value: JsonValue?) -> Bool {
		switch value {
		case .object?, .bool?: return true
		default: return false
		}
	}

	private static func isSchemaArray(_ value: JsonValue?) -> [JsonValue]? {
		guard case .array(let items)? = value, items.allSatisfy({ isSchema($0) }) else { return nil }
		return items
	}

	private static func isSchemaRecord(_ value: JsonValue?) -> JsonObject? {
		guard case .object(let record)? = value, record.allSatisfy({ isSchema($0.value) }) else { return nil }
		return record
	}

	private static func finiteNumber(_ value: JsonValue?) -> Double? {
		guard case .number(let n)? = value, n.isFinite else { return nil }
		return n
	}

	private static func typeNames(_ schema: JsonObject) -> JsonValue? {
		switch schema["type"] {
		case .string?: return schema["type"]
		case .array(let items)? where items.allSatisfy({ $0.stringValue != nil }): return schema["type"]
		default: return nil
		}
	}

	private static func requiredKeys(_ schema: JsonObject) -> [String]? {
		guard case .array(let items)? = schema["required"] else { return nil }
		let keys = items.compactMap { $0.stringValue }
		return keys.count == items.count ? keys : nil
	}

	private static func isNumber(_ value: JsonValue) -> Bool {
		if case .number(let n) = value { return n.isFinite }
		return false
	}

	private static func isInteger(_ value: JsonValue) -> Bool {
		if case .number(let n) = value { return n.isFinite && n.rounded(.towardZero) == n }
		return false
	}

	private static func checkTypeName(_ type: String, _ value: JsonValue) -> Bool {
		switch type {
		case "object":
			if case .object = value { return true }
			return false
		case "array":
			if case .array = value { return true }
			return false
		case "boolean":
			if case .bool = value { return true }
			return false
		case "integer":
			return isInteger(value)
		case "number":
			return isNumber(value)
		case "null":
			return value == .null
		case "string":
			if case .string = value { return true }
			return false
		// xschema: bigint, constructor, function, symbol never match JSON values; undefined/void neither.
		case "bigint", "constructor", "function", "symbol", "undefined", "void":
			return false
		default:
			return true
		}
	}

	private static func checkType(_ schema: JsonObject, _ value: JsonValue) -> Bool {
		switch schema["type"] {
		case .array(let types)?: return types.contains { checkTypeName($0.stringValue ?? "", value) }
		case .string(let type)?: return checkTypeName(type, value)
		default: return true
		}
	}

	// MARK: Helpers

	/// `GetPropertiesPattern` + `UnicodeRegExp`.
	private static func propertiesPattern(_ schema: JsonObject) -> NSRegularExpression? {
		var patterns: [String] = []
		if let patternProperties = isSchemaRecord(schema["patternProperties"]) {
			patterns.append(contentsOf: patternProperties.keys)
		}
		if let properties = isSchemaRecord(schema["properties"]) {
			patterns.append(contentsOf: properties.keys.map { "^" + NSRegularExpression.escapedPattern(for: $0) + "$" })
		}
		return unicodeRegExp(patterns.isEmpty ? "(?!)" : "(\(patterns.joined(separator: "|")))")
	}

	private static func unicodeRegExp(_ pattern: String) -> NSRegularExpression? {
		return try? NSRegularExpression(pattern: pattern)
	}

	private static func regexTest(_ regex: NSRegularExpression?, _ text: String) -> Bool {
		// Not ported: an invalid pattern throws a SyntaxError in JS; here it never matches.
		guard let regex else { return false }
		return jsRegexTest(regex, text)
	}

	private static func isMultipleOf(_ dividend: Double, _ divisor: Double) -> Bool {
		let tolerance = 1e-10
		if !dividend.isFinite { return true }
		if dividend.rounded(.towardZero) == dividend && (1 / divisor).truncatingRemainder(dividingBy: 1) == 0 { return true }
		let mod = dividend.truncatingRemainder(dividingBy: divisor)
		return min(abs(mod), abs(mod - divisor), abs(mod + divisor)) < tolerance
	}

	/// `stack.Ref(schema)`: local `#`, `#/json/pointer` and `#anchor` references against the root schema.
	/// Not ported: `$id` base URIs and remote references (no external context is passed upstream either).
	private func resolveRef(_ ref: String) -> JsonValue? {
		guard ref.hasPrefix("#") else { return nil }
		let fragment = String(ref.dropFirst()).removingPercentEncoding ?? String(ref.dropFirst())
		if fragment.isEmpty { return root }
		if fragment.hasPrefix("/") {
			var current: JsonValue? = root
			for rawToken in fragment.dropFirst().split(separator: "/", omittingEmptySubsequences: false) {
				let token = rawToken.replacingOccurrences(of: "~1", with: "/").replacingOccurrences(of: "~0", with: "~")
				switch current {
				case .object(let object)?: current = object[token]
				case .array(let items)?:
					guard let index = Int(token), index >= 0, index < items.count else { return nil }
					current = items[index]
				default: return nil
				}
			}
			return current
		}
		return findAnchor(fragment, in: root)
	}

	private func findAnchor(_ anchor: String, in value: JsonValue) -> JsonValue? {
		switch value {
		case .object(let object):
			if object["$anchor"]?.stringValue == anchor || object["$dynamicAnchor"]?.stringValue == anchor { return value }
			for (_, child) in object {
				if let found = findAnchor(anchor, in: child) { return found }
			}
			return nil
		case .array(let items):
			for child in items {
				if let found = findAnchor(anchor, in: child) { return found }
			}
			return nil
		default:
			return nil
		}
	}

	// MARK: Check

	private func checkSchema(_ schemaValue: JsonValue, _ value: JsonValue) -> Bool {
		if case .bool(let flag) = schemaValue { return flag }
		guard case .object(let schema) = schemaValue else { return true }
		let s = Self.self

		if s.typeNames(schema) != nil && !s.checkType(schema, value) { return false }

		if case .object(let object) = value {
			if let required = s.requiredKeys(schema), !required.allSatisfy({ object.contains($0) }) { return false }
			if s.isSchema(schema["additionalProperties"]), let additional = schema["additionalProperties"] {
				let regex = s.propertiesPattern(schema)
				for (key, property) in object where !s.regexTest(regex, key) {
					if !checkSchema(additional, property) { return false }
				}
			}
			if !checkDependencies(schema, object) { return false }
			if let dependentRequired = dependentRequiredRecord(schema), !object.isEmpty {
				for (key, keys) in dependentRequired where object.contains(key) {
					if !keys.allSatisfy({ object.contains($0) }) { return false }
				}
			}
			if let dependentSchemas = s.isSchemaRecord(schema["dependentSchemas"]), !object.isEmpty {
				for (key, dependent) in dependentSchemas where object.contains(key) {
					if !checkSchema(dependent, value) { return false }
				}
			}
			if let patternProperties = s.isSchemaRecord(schema["patternProperties"]) {
				for (pattern, patternSchema) in patternProperties {
					let regex = s.unicodeRegExp(pattern)
					for (key, property) in object where s.regexTest(regex, key) {
						if !checkSchema(patternSchema, property) { return false }
					}
				}
			}
			if let properties = s.isSchemaRecord(schema["properties"]) {
				for (key, propertySchema) in properties {
					guard let property = object[key] else { continue }
					if !checkSchema(propertySchema, property) { return false }
				}
			}
			if s.isSchema(schema["propertyNames"]), let propertyNames = schema["propertyNames"] {
				for key in object.keys where !checkSchema(propertyNames, .string(key)) { return false }
			}
			if let minProperties = s.finiteNumber(schema["minProperties"]), !(Double(object.count) >= minProperties) { return false }
			if let maxProperties = s.finiteNumber(schema["maxProperties"]), !(Double(object.count) <= maxProperties) { return false }
		}

		if case .array(let items) = value {
			if !checkArray(schema, items) { return false }
		}

		if case .string(let text) = value {
			if let maxLength = s.finiteNumber(schema["maxLength"]), !(Double(text.count) <= maxLength) { return false }
			if let minLength = s.finiteNumber(schema["minLength"]), !(Double(text.count) >= minLength) { return false }
			if case .string(let format)? = schema["format"], !testFormat(format, text) { return false }
			if case .string(let pattern)? = schema["pattern"], !s.regexTest(s.unicodeRegExp(pattern), text) { return false }
		}

		if case .number(let n) = value, n.isFinite {
			if let limit = s.finiteNumber(schema["exclusiveMaximum"]), !(n < limit) { return false }
			if let limit = s.finiteNumber(schema["exclusiveMinimum"]), !(n > limit) { return false }
			if let limit = s.finiteNumber(schema["maximum"]), !(n <= limit) { return false }
			if let limit = s.finiteNumber(schema["minimum"]), !(n >= limit) { return false }
			if let divisor = s.finiteNumber(schema["multipleOf"]), !s.isMultipleOf(n, divisor) { return false }
		}

		if case .string(let ref)? = schema["$ref"] {
			guard let target = resolveRef(ref), s.isSchema(target), checkSchema(target, value) else { return false }
		}
		// Not ported: $recursiveRef / $dynamicRef (dynamic scopes); they fail to resolve here.
		if case .string? = schema["$recursiveRef"] { return false }
		if case .string? = schema["$dynamicRef"] { return false }

		if let constValue = schema["const"], constValue != value { return false }
		if case .array(let options)? = schema["enum"], !options.contains(value) { return false }

		if s.isSchema(schema["if"]), let ifSchema = schema["if"] {
			let thenSchema = s.isSchema(schema["then"]) ? schema["then"]! : .bool(true)
			let elseSchema = s.isSchema(schema["else"]) ? schema["else"]! : .bool(true)
			if !(checkSchema(ifSchema, value) ? checkSchema(thenSchema, value) : checkSchema(elseSchema, value)) { return false }
		}
		if s.isSchema(schema["not"]), let notSchema = schema["not"], checkSchema(notSchema, value) { return false }
		if let allOf = s.isSchemaArray(schema["allOf"]), !allOf.allSatisfy({ checkSchema($0, value) }) { return false }
		if let anyOf = s.isSchemaArray(schema["anyOf"]), !anyOf.contains(where: { checkSchema($0, value) }) { return false }
		if let oneOf = s.isSchemaArray(schema["oneOf"]), oneOf.filter({ checkSchema($0, value) }).count != 1 { return false }
		// Not ported: unevaluatedItems / unevaluatedProperties (evaluation tracking); treated as satisfied.
		return true
	}

	private func dependentRequiredRecord(_ schema: JsonObject) -> [(String, [String])]? {
		guard case .object(let record)? = schema["dependentRequired"] else { return nil }
		var result: [(String, [String])] = []
		for (key, value) in record {
			guard case .array(let items) = value else { return nil }
			let keys = items.compactMap { $0.stringValue }
			guard keys.count == items.count else { return nil }
			result.append((key, keys))
		}
		return result
	}

	/// `dependencies`: each entry is a schema or an array of property names.
	private func dependenciesRecord(_ schema: JsonObject) -> JsonObject? {
		guard case .object(let record)? = schema["dependencies"] else { return nil }
		for (_, value) in record {
			switch value {
			case .object, .bool: continue
			case .array(let items) where items.allSatisfy({ $0.stringValue != nil }): continue
			default: return nil
			}
		}
		return record
	}

	private func checkDependencies(_ schema: JsonObject, _ object: JsonObject) -> Bool {
		guard let dependencies = dependenciesRecord(schema) else { return true }
		if object.isEmpty { return true }
		for (key, dependency) in dependencies where object.contains(key) {
			if case .array(let keys) = dependency {
				if !keys.allSatisfy({ object.contains($0.stringValue ?? "") }) { return false }
			} else if !checkSchema(dependency, .object(object)) {
				return false
			}
		}
		return true
	}

	private func checkArray(_ schema: JsonObject, _ items: [JsonValue]) -> Bool {
		let s = Self.self
		let itemsValue = schema["items"]
		let sizedItems = s.isSchemaArray(itemsValue)
		let isItems = s.isSchema(itemsValue) || sizedItems != nil
		if let additionalItems = schema["additionalItems"], s.isSchema(additionalItems), let sized = sizedItems {
			for (index, item) in items.enumerated() where index >= sized.count {
				if !checkSchema(additionalItems, item) { return false }
			}
		}
		let minContains = s.finiteNumber(schema["minContains"])
		if let contains = schema["contains"], s.isSchema(contains) {
			if minContains != 0 {
				if items.isEmpty || !items.contains(where: { checkSchema(contains, $0) }) { return false }
			}
		}
		if isItems {
			if let sized = sizedItems {
				for (index, itemSchema) in sized.enumerated() where index < items.count {
					if !checkSchema(itemSchema, items[index]) { return false }
				}
			} else if let itemSchema = itemsValue {
				let offset = s.isSchemaArray(schema["prefixItems"])?.count ?? 0
				for item in items.dropFirst(offset) where !checkSchema(itemSchema, item) { return false }
			}
		}
		if let contains = schema["contains"], s.isSchema(contains) {
			let count = Double(items.filter { checkSchema(contains, $0) }.count)
			if let maxContains = s.finiteNumber(schema["maxContains"]), !(count <= maxContains) { return false }
			if let minContains, !(count >= minContains) { return false }
		}
		if let maxItems = s.finiteNumber(schema["maxItems"]), !(Double(items.count) <= maxItems) { return false }
		if let minItems = s.finiteNumber(schema["minItems"]), !(Double(items.count) >= minItems) { return false }
		if let prefixItems = s.isSchemaArray(schema["prefixItems"]), !items.isEmpty {
			for (index, itemSchema) in prefixItems.enumerated() where index < items.count {
				if !checkSchema(itemSchema, items[index]) { return false }
			}
		}
		if case .bool(true)? = schema["uniqueItems"], Set(items).count != items.count { return false }
		return true
	}

	// MARK: Errors

	private func add(_ context: TypeBoxErrorContext, _ keyword: String, _ schemaPath: String, _ instancePath: String, _ message: String, requiredProperties: [String] = []) -> Bool {
		return context.addError(TypeBoxValidationError(keyword: keyword, schemaPath: schemaPath, instancePath: instancePath, requiredProperties: requiredProperties, message: message))
	}

	private func errorSchema(_ context: TypeBoxErrorContext, _ schemaPath: String, _ instancePath: String, _ schemaValue: JsonValue, _ value: JsonValue) -> Bool {
		if context.atCapacity { return false }
		if case .bool(let flag) = schemaValue {
			return flag || add(context, "boolean", schemaPath, instancePath, "schema is false")
		}
		guard case .object(let schema) = schemaValue else { return true }
		let s = Self.self
		var ok = true

		if let type = s.typeNames(schema), !s.checkType(schema, value) {
			let message: String
			if case .string(let name) = type {
				message = "must be \(name)"
			} else {
				message = "must be either \((type.arrayValue ?? []).compactMap { $0.stringValue }.joined(separator: " or "))"
			}
			ok = add(context, "type", schemaPath, instancePath, message) && ok
		}

		if case .object(let object) = value {
			if let required = s.requiredKeys(schema) {
				let missing = required.filter { !object.contains($0) }
				if !missing.isEmpty {
					ok = add(context, "required", schemaPath, instancePath, "must have required properties \(missing.joined(separator: ", "))", requiredProperties: missing) && ok
				}
			}
			if s.isSchema(schema["additionalProperties"]), let additional = schema["additionalProperties"] {
				let regex = s.propertiesPattern(schema)
				var failed = false
				for (key, property) in object where !s.regexTest(regex, key) {
					if !errorSchema(context, "\(schemaPath)/additionalProperties", "\(instancePath)/\(key)", additional, property) { failed = true }
				}
				if failed { ok = add(context, "additionalProperties", schemaPath, instancePath, "must not have additional properties") && ok }
			}
			if let dependencies = dependenciesRecord(schema), !object.isEmpty {
				for (key, dependency) in dependencies where object.contains(key) {
					if case .array(let keys) = dependency {
						let names = keys.compactMap { $0.stringValue }
						for dependencyKey in names where !object.contains(dependencyKey) {
							ok = add(context, "dependencies", schemaPath, instancePath, "must have properties \(names.joined(separator: ", ")) when property \(key) is present") && ok
							break
						}
					} else if !errorSchema(context, "\(schemaPath)/dependencies/\(key)", instancePath, dependency, value) {
						ok = false
					}
				}
			}
			if let dependentRequired = dependentRequiredRecord(schema), !object.isEmpty {
				for (key, keys) in dependentRequired where object.contains(key) {
					for dependency in keys where !object.contains(dependency) {
						ok = add(context, "dependentRequired", schemaPath, instancePath, "must have properties \(keys.joined(separator: ", ")) when property \(key) is present") && ok
					}
				}
			}
			if let dependentSchemas = s.isSchemaRecord(schema["dependentSchemas"]), !object.isEmpty {
				for (key, dependent) in dependentSchemas where object.contains(key) {
					if !errorSchema(context, "\(schemaPath)/dependentSchemas/\(key)", instancePath, dependent, value) { ok = false }
				}
			}
			if let patternProperties = s.isSchemaRecord(schema["patternProperties"]) {
				for (pattern, patternSchema) in patternProperties {
					let regex = s.unicodeRegExp(pattern)
					for (key, property) in object where s.regexTest(regex, key) {
						if !errorSchema(context, "\(schemaPath)/patternProperties/\(pattern)", "\(instancePath)/\(key)", patternSchema, property) { ok = false }
					}
				}
			}
			if let properties = s.isSchemaRecord(schema["properties"]) {
				for (key, propertySchema) in properties {
					guard let property = object[key] else { continue }
					if !errorSchema(context, "\(schemaPath)/properties/\(key)", "\(instancePath)/\(key)", propertySchema, property) { ok = false }
				}
			}
			if s.isSchema(schema["propertyNames"]), let propertyNames = schema["propertyNames"] {
				var invalid: [String] = []
				for key in object.keys where !errorSchema(context, "\(schemaPath)/propertyNames", "\(instancePath)/\(key)", propertyNames, .string(key)) {
					invalid.append(key)
				}
				if !invalid.isEmpty { ok = add(context, "propertyNames", schemaPath, instancePath, "property names \(invalid.joined(separator: ", ")) are invalid") && ok }
			}
			if let limit = s.finiteNumber(schema["minProperties"]), !(Double(object.count) >= limit) {
				ok = add(context, "minProperties", schemaPath, instancePath, "must not have fewer than \(jsNumberToString(limit)) properties") && ok
			}
			if let limit = s.finiteNumber(schema["maxProperties"]), !(Double(object.count) <= limit) {
				ok = add(context, "maxProperties", schemaPath, instancePath, "must not have more than \(jsNumberToString(limit)) properties") && ok
			}
		}

		if case .array(let items) = value {
			if !errorArray(context, schemaPath, instancePath, schema, items) { ok = false }
		}

		if case .string(let text) = value {
			if let limit = s.finiteNumber(schema["maxLength"]), !(Double(text.count) <= limit) {
				ok = add(context, "maxLength", schemaPath, instancePath, "must not have more than \(jsNumberToString(limit)) characters") && ok
			}
			if let limit = s.finiteNumber(schema["minLength"]), !(Double(text.count) >= limit) {
				ok = add(context, "minLength", schemaPath, instancePath, "must not have fewer than \(jsNumberToString(limit)) characters") && ok
			}
			if case .string(let format)? = schema["format"], !testFormat(format, text) {
				ok = add(context, "format", schemaPath, instancePath, "must match format \"\(format)\"") && ok
			}
			if case .string(let pattern)? = schema["pattern"], !s.regexTest(s.unicodeRegExp(pattern), text) {
				ok = add(context, "pattern", schemaPath, instancePath, "must match pattern \"\(pattern)\"") && ok
			}
		}

		if case .number(let n) = value, n.isFinite {
			if let limit = s.finiteNumber(schema["exclusiveMaximum"]), !(n < limit) {
				ok = add(context, "exclusiveMaximum", schemaPath, instancePath, "must be < \(jsNumberToString(limit))") && ok
			}
			if let limit = s.finiteNumber(schema["exclusiveMinimum"]), !(n > limit) {
				ok = add(context, "exclusiveMinimum", schemaPath, instancePath, "must be > \(jsNumberToString(limit))") && ok
			}
			if let limit = s.finiteNumber(schema["maximum"]), !(n <= limit) {
				ok = add(context, "maximum", schemaPath, instancePath, "must be <= \(jsNumberToString(limit))") && ok
			}
			if let limit = s.finiteNumber(schema["minimum"]), !(n >= limit) {
				ok = add(context, "minimum", schemaPath, instancePath, "must be >= \(jsNumberToString(limit))") && ok
			}
			if let divisor = s.finiteNumber(schema["multipleOf"]), !s.isMultipleOf(n, divisor) {
				ok = add(context, "multipleOf", schemaPath, instancePath, "must be multiple of \(jsNumberToString(divisor))") && ok
			}
		}

		if case .string(let ref)? = schema["$ref"] {
			let nextContext = TypeBoxErrorContext()
			let target = resolveRef(ref)
			let result = target.map { s.isSchema($0) && errorSchema(nextContext, "#", instancePath, $0, value) } ?? false
			if !result {
				nextContext.errors.forEach { context.addError($0) }
				ok = false
			}
		}
		if case .string? = schema["$recursiveRef"] { ok = false }
		if case .string? = schema["$dynamicRef"] { ok = false }

		if let constValue = schema["const"], constValue != value {
			ok = add(context, "const", schemaPath, instancePath, "must be equal to constant") && ok
		}
		if case .array(let options)? = schema["enum"], !options.contains(value) {
			ok = add(context, "enum", schemaPath, instancePath, "must be equal to one of the allowed values") && ok
		}

		if s.isSchema(schema["if"]), let ifSchema = schema["if"] {
			let thenSchema = s.isSchema(schema["then"]) ? schema["then"]! : .bool(true)
			let elseSchema = s.isSchema(schema["else"]) ? schema["else"]! : .bool(true)
			let trueContext = TypeBoxErrorContext()
			let isIf: Bool
			if errorSchema(trueContext, "\(schemaPath)/if", instancePath, ifSchema, value) {
				isIf = errorSchema(trueContext, "\(schemaPath)/then", instancePath, thenSchema, value)
					|| add(context, "if", schemaPath, instancePath, "must match \"then\" schema")
			} else {
				isIf = errorSchema(context, "\(schemaPath)/else", instancePath, elseSchema, value)
					|| add(context, "if", schemaPath, instancePath, "must match \"else\" schema")
			}
			if !isIf { ok = false }
		}
		if s.isSchema(schema["not"]), let notSchema = schema["not"], checkSchema(notSchema, value) {
			ok = add(context, "not", schemaPath, instancePath, "must not be valid") && ok
		}
		if let allOf = s.isSchemaArray(schema["allOf"]) {
			var failedContexts: [TypeBoxErrorContext] = []
			for (index, member) in allOf.enumerated() {
				let nextContext = TypeBoxErrorContext()
				if !errorSchema(nextContext, "\(schemaPath)/allOf/\(index)", instancePath, member, value) { failedContexts.append(nextContext) }
			}
			if !failedContexts.isEmpty {
				failedContexts.forEach { $0.errors.forEach { context.addError($0) } }
				ok = false
			}
		}
		if let anyOf = s.isSchemaArray(schema["anyOf"]) {
			var failedContexts: [TypeBoxErrorContext] = []
			var passed = 0
			for (index, member) in anyOf.enumerated() {
				let nextContext = TypeBoxErrorContext()
				if errorSchema(nextContext, "\(schemaPath)/anyOf/\(index)", instancePath, member, value) {
					passed += 1
				} else {
					failedContexts.append(nextContext)
				}
			}
			if passed == 0 {
				failedContexts.forEach { $0.errors.forEach { context.addError($0) } }
				ok = add(context, "anyOf", schemaPath, instancePath, "must match a schema in anyOf") && ok
			}
		}
		if let oneOf = s.isSchemaArray(schema["oneOf"]) {
			var failedContexts: [TypeBoxErrorContext] = []
			var passed = 0
			for (index, member) in oneOf.enumerated() {
				let nextContext = TypeBoxErrorContext()
				if errorSchema(nextContext, "\(schemaPath)/oneOf/\(index)", instancePath, member, value) {
					passed += 1
				} else {
					failedContexts.append(nextContext)
				}
			}
			if passed != 1 {
				if passed == 0 { failedContexts.forEach { $0.errors.forEach { context.addError($0) } } }
				ok = add(context, "oneOf", schemaPath, instancePath, "must match exactly one schema in oneOf") && ok
			}
		}
		return ok
	}

	private func errorArray(_ context: TypeBoxErrorContext, _ schemaPath: String, _ instancePath: String, _ schema: JsonObject, _ items: [JsonValue]) -> Bool {
		let s = Self.self
		var ok = true
		let itemsValue = schema["items"]
		let sizedItems = s.isSchemaArray(itemsValue)
		let isItems = s.isSchema(itemsValue) || sizedItems != nil
		if let additionalItems = schema["additionalItems"], s.isSchema(additionalItems), let sized = sizedItems {
			// Upstream uses short-circuiting `Every` here.
			for (index, item) in items.enumerated() where index >= sized.count {
				if !errorSchema(context, "\(schemaPath)/additionalItems", "\(instancePath)/\(index)", additionalItems, item) {
					ok = false
					break
				}
			}
		}
		let minContains = s.finiteNumber(schema["minContains"])
		if let contains = schema["contains"], s.isSchema(contains), minContains != 0 {
			if items.isEmpty || !items.contains(where: { checkSchema(contains, $0) }) {
				ok = add(context, "contains", schemaPath, instancePath, "must contain at least 1 valid item") && ok
			}
		}
		if isItems {
			if let sized = sizedItems {
				for (index, itemSchema) in sized.enumerated() where index < items.count {
					if !errorSchema(context, "\(schemaPath)/items/\(index)", "\(instancePath)/\(index)", itemSchema, items[index]) { ok = false }
				}
			} else if let itemSchema = itemsValue {
				let offset = s.isSchemaArray(schema["prefixItems"])?.count ?? 0
				for (index, item) in items.enumerated() where index >= offset {
					if !errorSchema(context, "\(schemaPath)/items", "\(instancePath)/\(index)", itemSchema, item) { ok = false }
				}
			}
		}
		let containsSchema = s.isSchema(schema["contains"]) ? schema["contains"] : nil
		let containsCount = containsSchema.map { contains in Double(items.filter { checkSchema(contains, $0) }.count) }
		if let containsCount, let maxContains = s.finiteNumber(schema["maxContains"]), !(containsCount <= maxContains) {
			ok = add(context, "contains", schemaPath, instancePath, "must contain at least 1 valid item") && ok
		}
		if let limit = s.finiteNumber(schema["maxItems"]), !(Double(items.count) <= limit) {
			ok = add(context, "maxItems", schemaPath, instancePath, "must not have more than \(jsNumberToString(limit)) items") && ok
		}
		if let containsCount, let minContains, !(containsCount >= minContains) {
			ok = add(context, "contains", schemaPath, instancePath, "must contain at least 1 valid item") && ok
		}
		if let limit = s.finiteNumber(schema["minItems"]), !(Double(items.count) >= limit) {
			ok = add(context, "minItems", schemaPath, instancePath, "must not have fewer than \(jsNumberToString(limit)) items") && ok
		}
		if let prefixItems = s.isSchemaArray(schema["prefixItems"]), !items.isEmpty {
			for (index, itemSchema) in prefixItems.enumerated() where index < items.count {
				if !errorSchema(context, "\(schemaPath)/prefixItems/\(index)", "\(instancePath)/\(index)", itemSchema, items[index]) { ok = false }
			}
		}
		if case .bool(true)? = schema["uniqueItems"], Set(items).count != items.count {
			ok = add(context, "uniqueItems", schemaPath, instancePath, "must not have duplicate items") && ok
		}
		return ok
	}
}

// MARK: - TypeBox formats (`Format.Test`)

private let FORMAT_DATE = jsRegex(#"^(\d\d\d\d)-(\d\d)-(\d\d)$"#, "")
private let FORMAT_TIME = jsRegex(#"^(\d\d):(\d\d):(\d\d)(?:\.\d+)?(?:([Zz])|([+-])(\d\d):(\d\d))?$"#, "")
private let FORMAT_DURATION = jsRegex(#"^P((\d+Y(\d+M(\d+D)?)?|\d+M(\d+D)?|\d+D)(T(\d+H(\d+M(\d+S)?)?|\d+M(\d+S)?|\d+S))?|T(\d+H(\d+M(\d+S)?)?|\d+M(\d+S)?|\d+S)|\d+W)$"#, "")
private let FORMAT_EMAIL = jsRegex(#"^(?:[a-z0-9!#$%&'*+/=?^_`{|}~-]+(?:\.[a-z0-9!#$%&'*+/=?^_`{|}~-]+)*|"(?:[^"\\]|\\[\x20-\x7e])*")@(?:[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?(?:\.[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?)*|\[(?:IPv6:[a-f0-9:]+|(?:25[0-5]|2[0-4][0-9]|1[0-9]{2}|[1-9]?[0-9])(?:\.(?:25[0-5]|2[0-4][0-9]|1[0-9]{2}|[1-9]?[0-9])){3})\])$"#, "i")
private let FORMAT_IPV4 = jsRegex(#"^(?:(?:25[0-5]|2[0-4]\d|1\d\d|[1-9]?\d)\.){3}(?:25[0-5]|2[0-4]\d|1\d\d|[1-9]?\d)$"#, "")
private let FORMAT_IPV6 = jsRegex(#"^(?:(?:(?:[0-9a-f]{1,4}:){6}|::(?:[0-9a-f]{1,4}:){5}|(?:[0-9a-f]{1,4})?::(?:[0-9a-f]{1,4}:){4}|(?:(?:[0-9a-f]{1,4}:)?[0-9a-f]{1,4})?::(?:[0-9a-f]{1,4}:){3}|(?:(?:[0-9a-f]{1,4}:){0,2}[0-9a-f]{1,4})?::(?:[0-9a-f]{1,4}:){2}|(?:(?:[0-9a-f]{1,4}:){0,3}[0-9a-f]{1,4})?::[0-9a-f]{1,4}:|(?:(?:[0-9a-f]{1,4}:){0,4}[0-9a-f]{1,4})?::)(?:[0-9a-f]{1,4}:[0-9a-f]{1,4}|(?:(?:25[0-5]|2[0-4]\d|1\d\d|[1-9]?\d)\.){3}(?:25[0-5]|2[0-4]\d|1\d\d|[1-9]?\d))|(?:(?:[0-9a-f]{1,4}:){0,5}[0-9a-f]{1,4})?::[0-9a-f]{1,4}|(?:(?:[0-9a-f]{1,4}:){0,6}[0-9a-f]{1,4})?::)$"#, "i")
private let FORMAT_JSON_POINTER = jsRegex(#"^(?:\/(?:[^~/]|~0|~1)*)*$"#, "")
private let FORMAT_JSON_POINTER_URI_FRAGMENT = jsRegex(#"^#(?:\/(?:[a-z0-9_\-.!$&'()*+,;:=@]|%[0-9a-f]{2}|~0|~1)*)*$"#, "i")
private let FORMAT_RELATIVE_JSON_POINTER = jsRegex(#"^(?:0|[1-9][0-9]*)(?:#|(?:\/(?:[^~/]|~0|~1)*)*)$"#, "")
private let FORMAT_URI = jsRegex(#"^[a-z][a-z0-9+\-.]*:(?:\/\/(?:(?:[-a-z0-9._~!$&'()*+,;=:]|%[0-9a-f]{2})*@)?(?:\[(?:(?:(?:[\da-f]{1,4}:){6}(?:[\da-f]{1,4}:[\da-f]{1,4}|(?:(?:25[0-5]|2[0-4]\d|1\d\d|[1-9]?\d)\.){3}(?:25[0-5]|2[0-4]\d|1\d\d|[1-9]?\d))|::(?:[\da-f]{1,4}:){5}(?:[\da-f]{1,4}:[\da-f]{1,4}|(?:(?:25[0-5]|2[0-4]\d|1\d\d|[1-9]?\d)\.){3}(?:25[0-5]|2[0-4]\d|1\d\d|[1-9]?\d))|(?:[\da-f]{1,4})?::(?:[\da-f]{1,4}:){4}(?:[\da-f]{1,4}:[\da-f]{1,4}|(?:(?:25[0-5]|2[0-4]\d|1\d\d|[1-9]?\d)\.){3}(?:25[0-5]|2[0-4]\d|1\d\d|[1-9]?\d))|(?:(?:[\da-f]{1,4}:){0,1}[\da-f]{1,4})?::(?:[\da-f]{1,4}:){3}(?:[\da-f]{1,4}:[\da-f]{1,4}|(?:(?:25[0-5]|2[0-4]\d|1\d\d|[1-9]?\d)\.){3}(?:25[0-5]|2[0-4]\d|1\d\d|[1-9]?\d))|(?:(?:[\da-f]{1,4}:){0,2}[\da-f]{1,4})?::(?:[\da-f]{1,4}:){2}(?:[\da-f]{1,4}:[\da-f]{1,4}|(?:(?:25[0-5]|2[0-4]\d|1\d\d|[1-9]?\d)\.){3}(?:25[0-5]|2[0-4]\d|1\d\d|[1-9]?\d))|(?:(?:[\da-f]{1,4}:){0,3}[\da-f]{1,4})?::[\da-f]{1,4}:(?:[\da-f]{1,4}:[\da-f]{1,4}|(?:(?:25[0-5]|2[0-4]\d|1\d\d|[1-9]?\d)\.){3}(?:25[0-5]|2[0-4]\d|1\d\d|[1-9]?\d))|(?:(?:[\da-f]{1,4}:){0,4}[\da-f]{1,4})?::(?:[\da-f]{1,4}:[\da-f]{1,4}|(?:(?:25[0-5]|2[0-4]\d|1\d\d|[1-9]?\d)\.){3}(?:25[0-5]|2[0-4]\d|1\d\d|[1-9]?\d))|(?:(?:[\da-f]{1,4}:){0,5}[\da-f]{1,4})?::[\da-f]{1,4}|(?:(?:[\da-f]{1,4}:){0,6}[\da-f]{1,4})?::)|v[0-9a-f]+\.[-a-z0-9._~!$&'()*+,;=:]+)\]|(?:(?:25[0-5]|2[0-4]\d|1\d\d|[1-9]?\d)\.){3}(?:25[0-5]|2[0-4]\d|1\d\d|[1-9]?\d)|(?:[-a-z0-9._~!$&'()*+,;=]|%[0-9a-f]{2})*)(?::\d*)?(?:\/(?:[-a-z0-9._~!$&'()*+,;=:@]|%[0-9a-f]{2})*)*|\/(?:(?:[-a-z0-9._~!$&'()*+,;=:@]|%[0-9a-f]{2})+(?:\/(?:[-a-z0-9._~!$&'()*+,;=:@]|%[0-9a-f]{2})*)*)?|(?:[-a-z0-9._~!$&'()*+,;=:@]|%[0-9a-f]{2})+(?:\/(?:[-a-z0-9._~!$&'()*+,;=:@]|%[0-9a-f]{2})*)*)?(?:\?(?:[-a-z0-9._~!$&'()*+,;=:@/?]|%[0-9a-f]{2})*)?(?:#(?:[-a-z0-9._~!$&'()*+,;=:@/?]|%[0-9a-f]{2})*)?$"#, "i")
private let FORMAT_URI_REFERENCE = jsRegex(#"^(?:[a-z][a-z0-9+\-.]*:(?:\/\/(?:(?:[-a-z0-9._~!$&'()*+,;=:]|%[0-9a-f]{2})*@)?(?:\[(?:(?:(?:[\da-f]{1,4}:){6}(?:[\da-f]{1,4}:[\da-f]{1,4}|(?:(?:25[0-5]|2[0-4]\d|1\d\d|[1-9]?\d)\.){3}(?:25[0-5]|2[0-4]\d|1\d\d|[1-9]?\d))|::(?:[\da-f]{1,4}:){5}(?:[\da-f]{1,4}:[\da-f]{1,4}|(?:(?:25[0-5]|2[0-4]\d|1\d\d|[1-9]?\d)\.){3}(?:25[0-5]|2[0-4]\d|1\d\d|[1-9]?\d))|(?:[\da-f]{1,4})?::(?:[\da-f]{1,4}:){4}(?:[\da-f]{1,4}:[\da-f]{1,4}|(?:(?:25[0-5]|2[0-4]\d|1\d\d|[1-9]?\d)\.){3}(?:25[0-5]|2[0-4]\d|1\d\d|[1-9]?\d))|(?:(?:[\da-f]{1,4}:){0,1}[\da-f]{1,4})?::(?:[\da-f]{1,4}:){3}(?:[\da-f]{1,4}:[\da-f]{1,4}|(?:(?:25[0-5]|2[0-4]\d|1\d\d|[1-9]?\d)\.){3}(?:25[0-5]|2[0-4]\d|1\d\d|[1-9]?\d))|(?:(?:[\da-f]{1,4}:){0,2}[\da-f]{1,4})?::(?:[\da-f]{1,4}:){2}(?:[\da-f]{1,4}:[\da-f]{1,4}|(?:(?:25[0-5]|2[0-4]\d|1\d\d|[1-9]?\d)\.){3}(?:25[0-5]|2[0-4]\d|1\d\d|[1-9]?\d))|(?:(?:[\da-f]{1,4}:){0,3}[\da-f]{1,4})?::[\da-f]{1,4}:(?:[\da-f]{1,4}:[\da-f]{1,4}|(?:(?:25[0-5]|2[0-4]\d|1\d\d|[1-9]?\d)\.){3}(?:25[0-5]|2[0-4]\d|1\d\d|[1-9]?\d))|(?:(?:[\da-f]{1,4}:){0,4}[\da-f]{1,4})?::(?:[\da-f]{1,4}:[\da-f]{1,4}|(?:(?:25[0-5]|2[0-4]\d|1\d\d|[1-9]?\d)\.){3}(?:25[0-5]|2[0-4]\d|1\d\d|[1-9]?\d))|(?:(?:[\da-f]{1,4}:){0,5}[\da-f]{1,4})?::[\da-f]{1,4}|(?:(?:[\da-f]{1,4}:){0,6}[\da-f]{1,4})?::)|v[0-9a-f]+\.[-a-z0-9._~!$&'()*+,;=:]+)\]|(?:(?:25[0-5]|2[0-4]\d|1\d\d|[1-9]?\d)\.){3}(?:25[0-5]|2[0-4]\d|1\d\d|[1-9]?\d)|(?:[-a-z0-9._~!$&'()*+,;=]|%[0-9a-f]{2})*)(?::\d*)?(?:\/(?:[-a-z0-9._~!$&'()*+,;=:@]|%[0-9a-f]{2})*)*|\/(?:(?:[-a-z0-9._~!$&'()*+,;=:@]|%[0-9a-f]{2})+(?:\/(?:[-a-z0-9._~!$&'()*+,;=:@]|%[0-9a-f]{2})*)*)?|(?:[-a-z0-9._~!$&'()*+,;=:@]|%[0-9a-f]{2})+(?:\/(?:[-a-z0-9._~!$&'()*+,;=:@]|%[0-9a-f]{2})*)*)?|(?:\/\/(?:(?:[-a-z0-9._~!$&'()*+,;=:]|%[0-9a-f]{2})*@)?(?:\[(?:(?:(?:[\da-f]{1,4}:){6}(?:[\da-f]{1,4}:[\da-f]{1,4}|(?:(?:25[0-5]|2[0-4]\d|1\d\d|[1-9]?\d)\.){3}(?:25[0-5]|2[0-4]\d|1\d\d|[1-9]?\d))|::(?:[\da-f]{1,4}:){5}(?:[\da-f]{1,4}:[\da-f]{1,4}|(?:(?:25[0-5]|2[0-4]\d|1\d\d|[1-9]?\d)\.){3}(?:25[0-5]|2[0-4]\d|1\d\d|[1-9]?\d))|(?:[\da-f]{1,4})?::(?:[\da-f]{1,4}:){4}(?:[\da-f]{1,4}:[\da-f]{1,4}|(?:(?:25[0-5]|2[0-4]\d|1\d\d|[1-9]?\d)\.){3}(?:25[0-5]|2[0-4]\d|1\d\d|[1-9]?\d))|(?:(?:[\da-f]{1,4}:){0,1}[\da-f]{1,4})?::(?:[\da-f]{1,4}:){3}(?:[\da-f]{1,4}:[\da-f]{1,4}|(?:(?:25[0-5]|2[0-4]\d|1\d\d|[1-9]?\d)\.){3}(?:25[0-5]|2[0-4]\d|1\d\d|[1-9]?\d))|(?:(?:[\da-f]{1,4}:){0,2}[\da-f]{1,4})?::(?:[\da-f]{1,4}:){2}(?:[\da-f]{1,4}:[\da-f]{1,4}|(?:(?:25[0-5]|2[0-4]\d|1\d\d|[1-9]?\d)\.){3}(?:25[0-5]|2[0-4]\d|1\d\d|[1-9]?\d))|(?:(?:[\da-f]{1,4}:){0,3}[\da-f]{1,4})?::[\da-f]{1,4}:(?:[\da-f]{1,4}:[\da-f]{1,4}|(?:(?:25[0-5]|2[0-4]\d|1\d\d|[1-9]?\d)\.){3}(?:25[0-5]|2[0-4]\d|1\d\d|[1-9]?\d))|(?:(?:[\da-f]{1,4}:){0,4}[\da-f]{1,4})?::(?:[\da-f]{1,4}:[\da-f]{1,4}|(?:(?:25[0-5]|2[0-4]\d|1\d\d|[1-9]?\d)\.){3}(?:25[0-5]|2[0-4]\d|1\d\d|[1-9]?\d))|(?:(?:[\da-f]{1,4}:){0,5}[\da-f]{1,4})?::[\da-f]{1,4}|(?:(?:[\da-f]{1,4}:){0,6}[\da-f]{1,4})?::)|v[0-9a-f]+\.[-a-z0-9._~!$&'()*+,;=:]+)\]|(?:(?:25[0-5]|2[0-4]\d|1\d\d|[1-9]?\d)\.){3}(?:25[0-5]|2[0-4]\d|1\d\d|[1-9]?\d)|(?:[-a-z0-9._~!$&'()*+,;=]|%[0-9a-f]{2})*)(?::\d*)?(?:\/(?:[-a-z0-9._~!$&'()*+,;=:@]|%[0-9a-f]{2})*)*|\/(?:(?:[-a-z0-9._~!$&'()*+,;=:@]|%[0-9a-f]{2})+(?:\/(?:[-a-z0-9._~!$&'()*+,;=:@]|%[0-9a-f]{2})*)*)?|(?:[-a-z0-9._~!$&'()*+,;=@]|%[0-9a-f]{2})+(?:\/(?:[-a-z0-9._~!$&'()*+,;=:@]|%[0-9a-f]{2})*)*)?)(?:\?(?:[-a-z0-9._~!$&'()*+,;=:@/?]|%[0-9a-f]{2})*)?(?:#(?:[-a-z0-9._~!$&'()*+,;=:@/?]|%[0-9a-f]{2})*)?$"#, "i")
private let FORMAT_URI_TEMPLATE = jsRegex(#"^(?:(?:[^\x00-\x20"<>%\\^`{|}\x7f]|%[0-9a-f]{2})|\{[+#./;?&=,!@|]?(?:[a-z0-9_]|%[0-9a-f]{2})+(?:\.(?:[a-z0-9_]|%[0-9a-f]{2})+)*(?::[1-9]\d{0,3}|\*)?(?:,(?:[a-z0-9_]|%[0-9a-f]{2})+(?:\.(?:[a-z0-9_]|%[0-9a-f]{2})+)*(?::[1-9]\d{0,3}|\*)?)*\})*$"#, "i")
private let FORMAT_UUID = jsRegex(#"^[0-9a-f]{8}-(?:[0-9a-f]{4}-){3}[0-9a-f]{12}$"#, "i")

private let DAYS = [0, 31, 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31]

private func regexGroups(_ regex: NSRegularExpression, _ text: String) -> [String?]? {
	let ns = text as NSString
	guard let match = regex.firstMatch(in: text, range: NSRange(location: 0, length: ns.length)) else { return nil }
	return (0..<match.numberOfRanges).map { index in
		let range = match.range(at: index)
		return range.location == NSNotFound ? nil : ns.substring(with: range)
	}
}

private func isLeapYear(_ year: Int) -> Bool {
	return year % 4 == 0 && (year % 100 != 0 || year % 400 == 0)
}

private func formatIsDate(_ value: String) -> Bool {
	guard let matches = regexGroups(FORMAT_DATE, value) else { return false }
	let year = Int(matches[1] ?? "") ?? 0
	let month = Int(matches[2] ?? "") ?? 0
	let day = Int(matches[3] ?? "") ?? 0
	return month >= 1 && month <= 12 && day >= 1 && day <= (month == 2 && isLeapYear(year) ? 29 : DAYS[month])
}

private func formatIsTime(_ value: String, _ strictTimeZone: Bool = true) -> Bool {
	guard let matches = regexGroups(FORMAT_TIME, value) else { return false }
	// Require timezone offset or 'Z'/'z' when strictTimeZone is true
	if strictTimeZone && matches[4] == nil && matches[5] == nil { return false }
	let hr = Int(matches[1] ?? "") ?? 0
	let min = Int(matches[2] ?? "") ?? 0
	let sec = Int(matches[3] ?? "") ?? 0
	if hr > 23 || min > 59 || sec > 60 { return false }
	if matches[5] != nil {
		let tzH = Int(matches[6] ?? "") ?? 0
		let tzM = Int(matches[7] ?? "") ?? 0
		if tzH > 23 || tzM > 59 { return false }
	}
	if sec < 60 { return true }
	// Leap second handling: must normalize to 23:59:60 UTC (1439 total UTC minutes)
	let tzSign = matches[5] == "-" ? -1 : 1
	let tzH = Int(matches[6] ?? "0") ?? 0
	let tzM = Int(matches[7] ?? "0") ?? 0
	let totalUtcMin = (hr * 60 + min) - tzSign * (tzH * 60 + tzM)
	return (totalUtcMin % 1440 + 1440) % 1440 == 1439
}

private func formatIsDateTime(_ value: String) -> Bool {
	let dateTime = value.split(omittingEmptySubsequences: false, whereSeparator: { $0 == "T" || $0 == "t" })
	return dateTime.count == 2 && formatIsDate(String(dateTime[0])) && formatIsTime(String(dateTime[1]))
}

/// `Format.Test(format, value)`: unregistered formats pass.
/// Not ported (treated as unregistered): `hostname`, `idn-hostname`, `idn-email` (IDNA tables) and
/// `iri`, `iri-reference`, `url` (WHATWG `URL.canParse`).
private func testFormat(_ format: String, _ value: String) -> Bool {
	switch format {
	case "date-time": return formatIsDateTime(value)
	case "date": return formatIsDate(value)
	case "duration": return jsRegexTest(FORMAT_DURATION, value)
	case "email": return jsRegexTest(FORMAT_EMAIL, value)
	case "ipv4": return jsRegexTest(FORMAT_IPV4, value)
	case "ipv6": return jsRegexTest(FORMAT_IPV6, value)
	case "json-pointer-uri-fragment": return jsRegexTest(FORMAT_JSON_POINTER_URI_FRAGMENT, value)
	case "json-pointer": return jsRegexTest(FORMAT_JSON_POINTER, value)
	case "regex": return (try? NSRegularExpression(pattern: value)) != nil
	case "relative-json-pointer": return jsRegexTest(FORMAT_RELATIVE_JSON_POINTER, value)
	case "time": return formatIsTime(value)
	case "uri-reference": return jsRegexTest(FORMAT_URI_REFERENCE, value)
	case "uri-template": return jsRegexTest(FORMAT_URI_TEMPLATE, value)
	case "uri": return jsRegexTest(FORMAT_URI, value)
	case "uuid": return jsRegexTest(FORMAT_UUID, value)
	default: return true
	}
}
