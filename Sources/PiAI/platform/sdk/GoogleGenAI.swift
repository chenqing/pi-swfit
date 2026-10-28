import Foundation

// Port of the `@google/genai` 2.21.0 surface used by `api/google-generative-ai.ts`:
// `new GoogleGenAI({ apiKey, httpOptions })` and `client.models.generateContentStream(params)` against the
// Gemini Developer API (mldev) backend, with the request/response converters and transformers it runs.
//
// Swift shape: request params, `config` and `HttpOptions` stay JSON (`JsonValue` / `JsonObject`). The
// non-JSON `config.abortSignal` is passed as the `abortSignal:` parameter of `generateContentStream`.
//
// Not ported: Vertex AI / Gemini Enterprise Agent Platform backend (`vertexai` / `enterprise`, project and
// location, `google-auth-library` credentials), automatic function calling with `CallableTool`s and MCP
// clients (JSON tools are never callable, so AFC is always disabled), `retryOptions` (p-retry), the
// Undici timeout patch, `console.warn` / `console.debug` diagnostics, live / batches / caches / chats /
// files / operations / tokens / tunings / file search stores / interactions, uploads and downloads.

// MARK: - _base_url.ts

private struct DefaultBaseUrls: Sendable {
    var geminiUrl: String?
    var vertexUrl: String?
}

private let _defaultBaseUrls = Locked(DefaultBaseUrls())

/// Overrides the base URLs for the Gemini API and Vertex AI API.
///
/// - Remark: This function should be called before initializing the SDK. If the base URLs are set after
///   initializing the SDK, the base URLs will not be updated. Base URLs provided in the HttpOptions will
///   also take precedence over URLs set here.
public func setDefaultBaseUrls(geminiUrl: String? = nil, vertexUrl: String? = nil) {
    _defaultBaseUrls.withLock {
        $0.geminiUrl = geminiUrl
        $0.vertexUrl = vertexUrl
    }
}

/// Returns the default base URLs for the Gemini API and Vertex AI API.
func getDefaultBaseUrls() -> (geminiUrl: String?, vertexUrl: String?) {
    let urls = _defaultBaseUrls.current
    return (urls.geminiUrl, urls.vertexUrl)
}

/// Returns the default base URL based on the following priority:
///   1. Base URLs set via HttpOptions.
///   2. Base URLs set via the latest call to setDefaultBaseUrls.
///   3. Base URLs set via environment variables.
func getBaseUrl(_ httpOptions: JsonObject?, _ vertexai: Bool, _ vertexBaseUrlFromEnv: String?, _ geminiBaseUrlFromEnv: String?) -> JsonValue? {
    if !jsTruthy(httpOptions?["baseUrl"]) {
        let defaultBaseUrls = getDefaultBaseUrls()
        if vertexai {
            return (defaultBaseUrls.vertexUrl ?? vertexBaseUrlFromEnv).map { .string($0) }
        } else {
            return (defaultBaseUrls.geminiUrl ?? geminiBaseUrlFromEnv).map { .string($0) }
        }
    }
    return httpOptions?["baseUrl"]
}

// MARK: - _common.ts

func formatMap(_ templateString: String, _ valueMap: JsonValue?) throws -> String {
    // Use a regular expression to find all placeholders in the template string
    let regex = try! NSRegularExpression(pattern: "\\{([^}]+)\\}")
    let ns = templateString as NSString
    var result = ""
    var last = 0
    // Replace each placeholder with its corresponding value from the valueMap
    for match in regex.matches(in: templateString, range: NSRange(location: 0, length: ns.length)) {
        result += ns.substring(with: NSRange(location: last, length: match.range.location - last))
        let key = ns.substring(with: match.range(at: 1))
        if let valueMap = valueMap?.objectValue, valueMap.contains(key) {
            let value = valueMap[key]!
            // Convert the value to a string if it's not a string already
            result += value.isNull ? "" : jsToString(value)
        } else {
            // Handle missing keys
            throw PiError("Key '\(key)' not found in valueMap.")
        }
        last = match.range.location + match.range.length
    }
    result += ns.substring(from: last)
    return result
}

/// Swift: `keys` holding `[]` / `[0]` array segments are not used by the ported converters and are not supported.
func setValueByPath(_ data: inout JsonObject, _ keys: [String], _ value: JsonValue) throws {
    if keys.count > 1 {
        let key = keys[0]
        var child: JsonObject
        if case .object(let existing)? = data[key] {
            child = existing
        } else {
            // `!data[key] || typeof data[key] !== 'object'` (an array is an object in JS; arrays are never
            // stored at these paths by the ported converters).
            child = JsonObject()
        }
        try setValueByPath(&child, Array(keys.dropFirst()), value)
        data[key] = .object(child)
        return
    }
    let keyToSet = keys[keys.count - 1]
    if let existingData = data[keyToSet] {
        if !jsTruthy(value) || isEmptyJsObject(value) {
            return
        }
        if value == existingData, !isJsObjectType(value) {
            return
        }
        if isJsObjectType(existingData), isJsObjectType(value), !existingData.isNull, !value.isNull {
            data[keyToSet] = objectAssign(existingData, value)
        } else {
            throw PiError("Cannot set value for an existing key. Key: \(keyToSet)")
        }
    } else {
        if keyToSet == "_self", case .object(let valueAsRecord) = value {
            for (k, v) in valueAsRecord { data[k] = v }
        } else {
            data[keyToSet] = value
        }
    }
}

/// `getValueByPath(data, keys)` for paths without `[]` segments (the ones the ported converters use).
func getValueByPath(_ data: JsonValue?, _ keys: [String]) -> JsonValue? {
    if keys.count == 1 && keys[0] == "_self" {
        return data
    }
    var current = data
    for key in keys {
        guard case .object(let object)? = current else {
            return nil
        }
        current = object[key]
    }
    return current
}

/// `typeof value === 'object'` (true for null, arrays and objects).
private func isJsObjectType(_ value: JsonValue) -> Bool {
    switch value {
    case .null, .array, .object: return true
    default: return false
    }
}

/// `typeof value === 'object' && Object.keys(value).length === 0`.
private func isEmptyJsObject(_ value: JsonValue) -> Bool {
    switch value {
    case .array(let items): return items.isEmpty
    case .object(let object): return object.isEmpty
    default: return false
    }
}

/// `Object.assign(target, source)` for JSON objects / arrays (arrays assign by index).
private func objectAssign(_ target: JsonValue, _ source: JsonValue) -> JsonValue {
    switch (target, source) {
    case (.object(var t), .object(let s)):
        for (k, v) in s { t[k] = v }
        return .object(t)
    case (.array(var t), .array(let s)):
        for (i, v) in s.enumerated() {
            if i < t.count { t[i] = v } else { t.append(v) }
        }
        return .array(t)
    case (.object(var t), .array(let s)):
        for (i, v) in s.enumerated() { t[String(i)] = v }
        return .object(t)
    default:
        return target
    }
}

/// `!= null`: present and not JSON null.
private func isPresent(_ value: JsonValue?) -> Bool {
    if let value, !value.isNull { return true }
    return false
}

/// `typeof value` for a JSON value.
private func jsTypeof(_ value: JsonValue?) -> String {
    switch value {
    case nil: return "undefined"
    case .null?, .array?, .object?: return "object"
    case .bool?: return "boolean"
    case .number?: return "number"
    case .string?: return "string"
    }
}

/// Not-Gemini-API parameter check: `getValueByPath(fromObject, [key]) !== undefined`.
private func rejectEnterpriseOnly(_ fromObject: JsonValue, _ key: String) throws {
    if getValueByPath(fromObject, [key]) != nil {
        throw PiError("\(key) parameter is only supported in Gemini Enterprise Agent Platform mode, not in Gemini Developer API mode.")
    }
}

/// Copies `fromObject[key]` to `toObject[key]` when it is `!= null` (the generated converters' common shape).
private func copyIfPresent(_ fromObject: JsonValue, _ toObject: inout JsonObject, _ key: String) throws {
    let fromValue = getValueByPath(fromObject, [key])
    if let fromValue, isPresent(fromValue) {
        try setValueByPath(&toObject, [key], fromValue)
    }
}

/// `if (Array.isArray(list)) list = list.map(transform)`.
private func mapIfArray(_ value: JsonValue, _ transform: (JsonValue) throws -> JsonValue) rethrows -> JsonValue {
    if case .array(let items) = value {
        return .array(try items.map(transform))
    }
    return value
}

// MARK: - _transformers.ts

/// Data type of the schema field (`Type` enum values).
private let typeValues: Set<String> = ["TYPE_UNSPECIFIED", "STRING", "NUMBER", "INTEGER", "BOOLEAN", "ARRAY", "OBJECT", "NULL"]

func tModel(_ apiClient: ApiClient, _ model: JsonValue?) throws -> String {
    guard let model = model?.stringValue, !model.isEmpty else {
        throw PiError("model is required and must be a string")
    }
    if model.contains("..") || model.contains("?") || model.contains("&") {
        throw PiError("invalid model parameter")
    }
    if apiClient.isVertexAI() {
        // Not ported: Vertex AI model names (the client is always Gemini API).
        return model
    } else {
        if model.hasPrefix("models/") || model.hasPrefix("tunedModels/") {
            return model
        } else {
            return "models/\(model)"
        }
    }
}

func tPart(_ origin: JsonValue?) throws -> JsonValue {
    guard let origin, !origin.isNull else {
        throw PiError("PartUnion is required")
    }
    if case .object = origin {
        return origin
    }
    if case .array = origin {
        return origin
    }
    if case .string(let text) = origin {
        return ["text": .string(text)]
    }
    throw PiError("Unsupported part type: \(jsTypeof(origin))")
}

func tParts(_ origin: JsonValue?) throws -> JsonValue {
    guard let origin, !origin.isNull else {
        throw PiError("PartListUnion is required")
    }
    if case .array(let items) = origin {
        if items.isEmpty {
            throw PiError("PartListUnion is required")
        }
        return .array(try items.map { try tPart($0) })
    }
    return .array([try tPart(origin)])
}

func _isContent(_ origin: JsonValue?) -> Bool {
    if case .object(let object)? = origin, case .array? = object["parts"] {
        return true
    }
    return false
}

func _isFunctionCallPart(_ origin: JsonValue?) -> Bool {
    if case .object(let object)? = origin {
        return object.contains("functionCall")
    }
    return false
}

func _isFunctionResponsePart(_ origin: JsonValue?) -> Bool {
    if case .object(let object)? = origin {
        return object.contains("functionResponse")
    }
    return false
}

func tContent(_ origin: JsonValue?) throws -> JsonValue {
    guard let origin, !origin.isNull else {
        throw PiError("ContentUnion is required")
    }
    if _isContent(origin) {
        // _isContent is a utility function that checks if the
        // origin is a Content.
        return origin
    }
    return [
        "role": "user",
        "parts": try tParts(origin),
    ]
}

func tContents(_ origin: JsonValue?) throws -> JsonValue {
    guard let origin, !origin.isNull else {
        throw PiError("contents are required")
    }
    guard case .array(let items) = origin else {
        // If it's not an array, it's a single content or a single PartUnion.
        if _isFunctionCallPart(origin) || _isFunctionResponsePart(origin) {
            throw PiError("To specify functionCall or functionResponse parts, please wrap them in a Content object, specifying the role for them")
        }
        return .array([try tContent(origin)])
    }
    if items.isEmpty {
        throw PiError("contents are required")
    }
    var result: [JsonValue] = []
    var accumulatedParts: [JsonValue] = []
    let isContentArray = _isContent(items[0])
    for item in items {
        let isContent = _isContent(item)
        if isContent != isContentArray {
            throw PiError("Mixing Content and Parts is not supported, please group the parts into a the appropriate Content objects and specify the roles for them")
        }
        if isContent {
            // `isContent` contains the result of _isContent, which is a utility
            // function that checks if the item is a Content.
            result.append(item)
        } else if _isFunctionCallPart(item) || _isFunctionResponsePart(item) {
            throw PiError("To specify functionCall or functionResponse parts, please wrap them, and any other parts, in Content objects as appropriate, specifying the role for them")
        } else {
            accumulatedParts.append(item)
        }
    }
    if !isContentArray {
        result.append(["role": "user", "parts": try tParts(.array(accumulatedParts))])
    }
    return .array(result)
}

/// `value.toUpperCase()`; throws the JS TypeError for non-strings.
private func jsToUpperCase(_ value: JsonValue, _ expression: String) throws -> String {
    guard case .string(let text) = value else {
        throw PiError("\(expression).toUpperCase is not a function", name: "TypeError")
    }
    return text.uppercased()
}

/*
Transform the type field from an array of types to an array of anyOf fields.
Example:
  {type: ['STRING', 'NUMBER']}
will be transformed to
  {anyOf: [{type: 'STRING'}, {type: 'NUMBER'}]}
*/
func flattenTypeArrayToAnyOf(_ typeList: [JsonValue], _ resultingSchema: inout JsonObject) throws {
    if typeList.contains(.string("null")) {
        resultingSchema["nullable"] = true
    }
    let listWithoutNull = typeList.filter { $0 != .string("null") }
    if listWithoutNull.count == 1 {
        let upper = try jsToUpperCase(listWithoutNull[0], "listWithoutNull[0]")
        resultingSchema["type"] = .string(typeValues.contains(upper) ? upper : "TYPE_UNSPECIFIED")
    } else {
        var anyOf: [JsonValue] = []
        for i in listWithoutNull {
            let upper = try jsToUpperCase(i, "i")
            anyOf.append([
                "type": .string(typeValues.contains(upper) ? upper : "TYPE_UNSPECIFIED"),
            ])
        }
        resultingSchema["anyOf"] = .array(anyOf)
    }
}

func processJsonSchema(_ jsonSchema: JsonValue) throws -> JsonValue {
    var _jsonSchema = jsonSchema
    var genAISchema = JsonObject()
    let schemaFieldNames = ["items"]
    let listSchemaFieldNames = ["anyOf"]
    let dictSchemaFieldNames = ["properties"]
    if jsTruthy(_jsonSchema["type"]), jsTruthy(_jsonSchema["anyOf"]) {
        throw PiError("type and anyOf cannot be both populated.")
    }
    /*
    This is to handle the nullable array or object. The _jsonSchema will
    be in the format of {anyOf: [{type: 'null'}, {type: 'object'}]}. The
    logic is to check if anyOf has 2 elements and one of the element is null,
    if so, the anyOf field is unnecessary, so we need to get rid of the anyOf
    field and make the schema nullable. Then use the other element as the new
    _jsonSchema for processing. This is because the backend doesn't have a null
    type.
    This has to be checked before we process any other fields.
    For example:
      const objectNullable = z.object({
        nullableArray: z.array(z.string()).nullable(),
      });
    Will have the raw _jsonSchema as:
    {
      type: 'OBJECT',
      properties: {
          nullableArray: {
             anyOf: [
                {type: 'null'},
                {
                  type: 'array',
                  items: {type: 'string'},
                },
              ],
          }
      },
      required: [ 'nullableArray' ],
    }
    Will result in following schema compatible with Gemini API:
      {
        type: 'OBJECT',
        properties: {
           nullableArray: {
              nullable: true,
              type: 'ARRAY',
              items: {type: 'string'},
           }
        },
        required: [ 'nullableArray' ],
      }
    */
    let incomingAnyOf = _jsonSchema["anyOf"]
    if case .array(let anyOf)? = incomingAnyOf, anyOf.count == 2 {
        if anyOf[0]["type"] == .string("null") {
            genAISchema["nullable"] = true
            _jsonSchema = anyOf[1]
        } else if anyOf[1]["type"] == .string("null") {
            genAISchema["nullable"] = true
            _jsonSchema = anyOf[0]
        }
    }
    if case .array(let typeList)? = _jsonSchema["type"] {
        try flattenTypeArrayToAnyOf(typeList, &genAISchema)
    }
    for (fieldName, fieldValue) in _jsonSchema.objectValue ?? JsonObject() {
        // Skip if the fieldvalue is undefined or null.
        if fieldValue.isNull {
            continue
        }
        if fieldName == "type" {
            if fieldValue == .string("null") {
                throw PiError("type: null can not be the only possible type for the field.")
            }
            if case .array = fieldValue {
                // we have already handled the type field with array of types in the
                // beginning of this function.
                continue
            }
            let upper = try jsToUpperCase(fieldValue, "fieldValue")
            genAISchema["type"] = .string(typeValues.contains(upper) ? upper : "TYPE_UNSPECIFIED")
        } else if schemaFieldNames.contains(fieldName) {
            genAISchema[fieldName] = try processJsonSchema(fieldValue)
        } else if listSchemaFieldNames.contains(fieldName) {
            var listSchemaFieldValue: [JsonValue] = []
            for item in fieldValue.arrayValue ?? [] {
                if item["type"] == .string("null") {
                    genAISchema["nullable"] = true
                    continue
                }
                listSchemaFieldValue.append(try processJsonSchema(item))
            }
            genAISchema[fieldName] = .array(listSchemaFieldValue)
        } else if dictSchemaFieldNames.contains(fieldName) {
            var dictSchemaFieldValue = JsonObject()
            for (key, value) in fieldValue.objectValue ?? JsonObject() {
                dictSchemaFieldValue[key] = try processJsonSchema(value)
            }
            genAISchema[fieldName] = .object(dictSchemaFieldValue)
        } else {
            // additionalProperties is not included in JSONSchema, skipping it.
            if fieldName == "additionalProperties" {
                continue
            }
            genAISchema[fieldName] = fieldValue
        }
    }
    return .object(genAISchema)
}

// we take the unknown in the schema field because we want enable user to pass
// the output of major schema declaration tools without casting. Tools such as
// zodToJsonSchema, typebox, zodToJsonSchema function can return JsonSchema7Type
// or object, see details in
// https://github.com/StefanTerdell/zod-to-json-schema/blob/70525efe555cd226691e093d171370a3b10921d1/src/zodToJsonSchema.ts#L7
// typebox can return unknown, see details in
// https://github.com/sinclairzx81/typebox/blob/5a5431439f7d5ca6b494d0d18fbfd7b1a356d67c/src/type/create/type.ts#L35
// Note: proper json schemas with the $schema field set never arrive to this
// transformer. Schemas with $schema are routed to the equivalent API json
// schema field.
func tSchema(_ schema: JsonValue) throws -> JsonValue {
    try processJsonSchema(schema)
}

func tJsonSchema(_ schema: JsonValue) -> JsonValue {
    schema
}

func tSpeechConfig(_ speechConfig: JsonValue) throws -> JsonValue {
    switch speechConfig {
    case .object, .array, .null:
        return speechConfig
    case .string(let voiceName):
        return [
            "voiceConfig": [
                "prebuiltVoiceConfig": [
                    "voiceName": .string(voiceName),
                ],
            ],
        ]
    default:
        throw PiError("Unsupported speechConfig type: \(jsTypeof(speechConfig))")
    }
}

/// `Object.keys(value).includes('$schema')`.
private func hasSchemaKey(_ value: JsonValue) -> Bool {
    value.objectValue?.contains("$schema") ?? false
}

func tTool(_ tool: JsonValue) throws -> JsonValue {
    guard case .object(var toolObject) = tool else {
        if tool.isNull {
            throw PiError("Cannot read properties of null (reading 'functionDeclarations')", name: "TypeError")
        }
        return tool
    }
    if jsTruthy(toolObject["functionDeclarations"]), case .array(var functionDeclarations)? = toolObject["functionDeclarations"] {
        for index in functionDeclarations.indices {
            guard case .object(var functionDeclaration) = functionDeclarations[index] else { continue }
            if let parameters = functionDeclaration["parameters"], jsTruthy(parameters) {
                if !hasSchemaKey(parameters) {
                    functionDeclaration["parameters"] = try processJsonSchema(parameters)
                } else {
                    if !jsTruthy(functionDeclaration["parametersJsonSchema"]) {
                        functionDeclaration["parametersJsonSchema"] = parameters
                        functionDeclaration["parameters"] = nil
                    }
                }
            }
            if let response = functionDeclaration["response"], jsTruthy(response) {
                if !hasSchemaKey(response) {
                    functionDeclaration["response"] = try processJsonSchema(response)
                } else {
                    if !jsTruthy(functionDeclaration["responseJsonSchema"]) {
                        functionDeclaration["responseJsonSchema"] = response
                        functionDeclaration["response"] = nil
                    }
                }
            }
            functionDeclarations[index] = .object(functionDeclaration)
        }
        toolObject["functionDeclarations"] = .array(functionDeclarations)
    }
    return .object(toolObject)
}

func tTools(_ tools: JsonValue?) throws -> JsonValue {
    // Check if the incoming type is defined.
    guard let tools, !tools.isNull else {
        throw PiError("tools is required")
    }
    guard case .array(let items) = tools else {
        throw PiError("tools is required and must be an array of Tools")
    }
    var result: [JsonValue] = []
    for tool in items {
        result.append(tool)
    }
    return .array(result)
}

/// Prepends resource name with project, location, resource_prefix if needed.
///
/// Not ported: the Vertex AI branch (the client is always Gemini API).
func resourceName(_ client: ApiClient, _ resourceName: String, _ resourcePrefix: String, _ splitsAfterPrefix: Int = 1) -> String {
    let shouldAppendPrefix = !resourceName.hasPrefix("\(resourcePrefix)/") &&
        resourceName.split(separator: "/", omittingEmptySubsequences: false).count == splitsAfterPrefix
    if shouldAppendPrefix {
        return "\(resourcePrefix)/\(resourceName)"
    }
    return resourceName
}

func tCachedContentName(_ apiClient: ApiClient, _ name: JsonValue) throws -> String {
    guard case .string(let name) = name else {
        throw PiError("name must be a string")
    }
    return resourceName(apiClient, name, "cachedContents")
}

// MARK: - converters/_models_converters.ts (Gemini API)

func authConfigToMldev(_ fromObject: JsonValue) throws -> JsonValue {
    var toObject = JsonObject()
    try copyIfPresent(fromObject, &toObject, "apiKey")
    try rejectEnterpriseOnly(fromObject, "apiKeyConfig")
    try rejectEnterpriseOnly(fromObject, "authType")
    try rejectEnterpriseOnly(fromObject, "googleServiceAccountConfig")
    try rejectEnterpriseOnly(fromObject, "httpBasicAuthConfig")
    try rejectEnterpriseOnly(fromObject, "oauthConfig")
    try rejectEnterpriseOnly(fromObject, "oidcConfig")
    return .object(toObject)
}

func blobToMldev(_ fromObject: JsonValue) throws -> JsonValue {
    var toObject = JsonObject()
    try copyIfPresent(fromObject, &toObject, "data")
    try rejectEnterpriseOnly(fromObject, "displayName")
    try copyIfPresent(fromObject, &toObject, "mimeType")
    return .object(toObject)
}

func candidateFromMldev(_ fromObject: JsonValue) throws -> JsonValue {
    var toObject = JsonObject()
    try copyIfPresent(fromObject, &toObject, "content")
    let fromCitationMetadata = getValueByPath(fromObject, ["citationMetadata"])
    if let fromCitationMetadata, isPresent(fromCitationMetadata) {
        try setValueByPath(&toObject, ["citationMetadata"], try citationMetadataFromMldev(fromCitationMetadata))
    }
    try copyIfPresent(fromObject, &toObject, "tokenCount")
    try copyIfPresent(fromObject, &toObject, "finishReason")
    try copyIfPresent(fromObject, &toObject, "groundingMetadata")
    try copyIfPresent(fromObject, &toObject, "avgLogprobs")
    try copyIfPresent(fromObject, &toObject, "index")
    try copyIfPresent(fromObject, &toObject, "logprobsResult")
    let fromSafetyRatings = getValueByPath(fromObject, ["safetyRatings"])
    if let fromSafetyRatings, isPresent(fromSafetyRatings) {
        let transformedList = mapIfArray(fromSafetyRatings) { item in item }
        try setValueByPath(&toObject, ["safetyRatings"], transformedList)
    }
    try copyIfPresent(fromObject, &toObject, "urlContextMetadata")
    return .object(toObject)
}

func citationMetadataFromMldev(_ fromObject: JsonValue) throws -> JsonValue {
    var toObject = JsonObject()
    let fromCitations = getValueByPath(fromObject, ["citationSources"])
    if let fromCitations, isPresent(fromCitations) {
        let transformedList = mapIfArray(fromCitations) { item in item }
        try setValueByPath(&toObject, ["citations"], transformedList)
    }
    return .object(toObject)
}

func contentToMldev(_ fromObject: JsonValue) throws -> JsonValue {
    var toObject = JsonObject()
    let fromParts = getValueByPath(fromObject, ["parts"])
    if let fromParts, isPresent(fromParts) {
        let transformedList = try mapIfArray(fromParts) { item in try partToMldev(item) }
        try setValueByPath(&toObject, ["parts"], transformedList)
    }
    try copyIfPresent(fromObject, &toObject, "role")
    return .object(toObject)
}

func fileDataToMldev(_ fromObject: JsonValue) throws -> JsonValue {
    var toObject = JsonObject()
    try rejectEnterpriseOnly(fromObject, "displayName")
    try copyIfPresent(fromObject, &toObject, "fileUri")
    try copyIfPresent(fromObject, &toObject, "mimeType")
    return .object(toObject)
}

func functionCallToMldev(_ fromObject: JsonValue) throws -> JsonValue {
    var toObject = JsonObject()
    try copyIfPresent(fromObject, &toObject, "args")
    try copyIfPresent(fromObject, &toObject, "id")
    try copyIfPresent(fromObject, &toObject, "name")
    try rejectEnterpriseOnly(fromObject, "partialArgs")
    try rejectEnterpriseOnly(fromObject, "willContinue")
    return .object(toObject)
}

func functionCallingConfigToMldev(_ fromObject: JsonValue) throws -> JsonValue {
    var toObject = JsonObject()
    try copyIfPresent(fromObject, &toObject, "allowedFunctionNames")
    try copyIfPresent(fromObject, &toObject, "mode")
    try rejectEnterpriseOnly(fromObject, "streamFunctionCallArguments")
    return .object(toObject)
}

func generateContentConfigToMldev(_ apiClient: ApiClient, _ fromObject: JsonValue, _ parentObject: inout JsonObject) throws -> JsonValue {
    var toObject = JsonObject()
    let fromServiceTier = getValueByPath(fromObject, ["serviceTier"])
    if let fromServiceTier, isPresent(fromServiceTier) {
        try setValueByPath(&parentObject, ["serviceTier"], fromServiceTier)
    }
    let fromSystemInstruction = getValueByPath(fromObject, ["systemInstruction"])
    if let fromSystemInstruction, isPresent(fromSystemInstruction) {
        try setValueByPath(&parentObject, ["systemInstruction"], try contentToMldev(try tContent(fromSystemInstruction)))
    }
    try copyIfPresent(fromObject, &toObject, "temperature")
    try copyIfPresent(fromObject, &toObject, "topP")
    try copyIfPresent(fromObject, &toObject, "topK")
    try copyIfPresent(fromObject, &toObject, "candidateCount")
    try copyIfPresent(fromObject, &toObject, "maxOutputTokens")
    try copyIfPresent(fromObject, &toObject, "stopSequences")
    try copyIfPresent(fromObject, &toObject, "responseLogprobs")
    try copyIfPresent(fromObject, &toObject, "logprobs")
    try copyIfPresent(fromObject, &toObject, "presencePenalty")
    try copyIfPresent(fromObject, &toObject, "frequencyPenalty")
    try copyIfPresent(fromObject, &toObject, "seed")
    try copyIfPresent(fromObject, &toObject, "responseMimeType")
    let fromResponseSchema = getValueByPath(fromObject, ["responseSchema"])
    if let fromResponseSchema, isPresent(fromResponseSchema) {
        try setValueByPath(&toObject, ["responseSchema"], try tSchema(fromResponseSchema))
    }
    let fromResponseJsonSchema = getValueByPath(fromObject, ["responseJsonSchema"])
    if let fromResponseJsonSchema, isPresent(fromResponseJsonSchema) {
        try setValueByPath(&toObject, ["responseJsonSchema"], tJsonSchema(fromResponseJsonSchema))
    }
    try rejectEnterpriseOnly(fromObject, "routingConfig")
    try rejectEnterpriseOnly(fromObject, "modelSelectionConfig")
    let fromSafetySettings = getValueByPath(fromObject, ["safetySettings"])
    if let fromSafetySettings, isPresent(fromSafetySettings) {
        let transformedList = try mapIfArray(fromSafetySettings) { item in try safetySettingToMldev(item) }
        try setValueByPath(&parentObject, ["safetySettings"], transformedList)
    }
    let fromTools = getValueByPath(fromObject, ["tools"])
    if let fromTools, isPresent(fromTools) {
        let transformedList = try mapIfArray(try tTools(fromTools)) { item in try toolToMldev(try tTool(item)) }
        try setValueByPath(&parentObject, ["tools"], transformedList)
    }
    let fromToolConfig = getValueByPath(fromObject, ["toolConfig"])
    if let fromToolConfig, isPresent(fromToolConfig) {
        try setValueByPath(&parentObject, ["toolConfig"], try toolConfigToMldev(fromToolConfig))
    }
    try rejectEnterpriseOnly(fromObject, "labels")
    let fromCachedContent = getValueByPath(fromObject, ["cachedContent"])
    if let fromCachedContent, isPresent(fromCachedContent) {
        try setValueByPath(&parentObject, ["cachedContent"], .string(try tCachedContentName(apiClient, fromCachedContent)))
    }
    try copyIfPresent(fromObject, &toObject, "responseModalities")
    try copyIfPresent(fromObject, &toObject, "mediaResolution")
    let fromSpeechConfig = getValueByPath(fromObject, ["speechConfig"])
    if let fromSpeechConfig, isPresent(fromSpeechConfig) {
        try setValueByPath(&toObject, ["speechConfig"], try tSpeechConfig(fromSpeechConfig))
    }
    try rejectEnterpriseOnly(fromObject, "audioTimestamp")
    try copyIfPresent(fromObject, &toObject, "thinkingConfig")
    try copyIfPresent(fromObject, &toObject, "audioTranscriptionConfig")
    let fromImageConfig = getValueByPath(fromObject, ["imageConfig"])
    if let fromImageConfig, isPresent(fromImageConfig) {
        try setValueByPath(&toObject, ["imageConfig"], try imageConfigToMldev(fromImageConfig))
    }
    try copyIfPresent(fromObject, &toObject, "enableEnhancedCivicAnswers")
    try rejectEnterpriseOnly(fromObject, "modelArmorConfig")
    return .object(toObject)
}

func generateContentParametersToMldev(_ apiClient: ApiClient, _ fromObject: JsonValue) throws -> JsonObject {
    var toObject = JsonObject()
    let fromModel = getValueByPath(fromObject, ["model"])
    if let fromModel, isPresent(fromModel) {
        try setValueByPath(&toObject, ["_url", "model"], .string(try tModel(apiClient, fromModel)))
    }
    let fromContents = getValueByPath(fromObject, ["contents"])
    if let fromContents, isPresent(fromContents) {
        let transformedList = try mapIfArray(try tContents(fromContents)) { item in try contentToMldev(item) }
        try setValueByPath(&toObject, ["contents"], transformedList)
    }
    let fromConfig = getValueByPath(fromObject, ["config"])
    if let fromConfig, isPresent(fromConfig) {
        let generationConfig = try generateContentConfigToMldev(apiClient, fromConfig, &toObject)
        try setValueByPath(&toObject, ["generationConfig"], generationConfig)
    }
    return toObject
}

func generateContentResponseFromMldev(_ fromObject: JsonValue) throws -> JsonObject {
    var toObject = JsonObject()
    try copyIfPresent(fromObject, &toObject, "sdkHttpResponse")
    let fromCandidates = getValueByPath(fromObject, ["candidates"])
    if let fromCandidates, isPresent(fromCandidates) {
        let transformedList = try mapIfArray(fromCandidates) { item in try candidateFromMldev(item) }
        try setValueByPath(&toObject, ["candidates"], transformedList)
    }
    try copyIfPresent(fromObject, &toObject, "modelVersion")
    try copyIfPresent(fromObject, &toObject, "promptFeedback")
    try copyIfPresent(fromObject, &toObject, "responseId")
    try copyIfPresent(fromObject, &toObject, "usageMetadata")
    try copyIfPresent(fromObject, &toObject, "modelStatus")
    return toObject
}

func googleMapsToMldev(_ fromObject: JsonValue) throws -> JsonValue {
    var toObject = JsonObject()
    let fromAuthConfig = getValueByPath(fromObject, ["authConfig"])
    if let fromAuthConfig, isPresent(fromAuthConfig) {
        try setValueByPath(&toObject, ["authConfig"], try authConfigToMldev(fromAuthConfig))
    }
    try copyIfPresent(fromObject, &toObject, "enableWidget")
    try rejectEnterpriseOnly(fromObject, "groundingTypes")
    return .object(toObject)
}

func googleSearchToMldev(_ fromObject: JsonValue) throws -> JsonValue {
    var toObject = JsonObject()
    try rejectEnterpriseOnly(fromObject, "blockingConfidence")
    try rejectEnterpriseOnly(fromObject, "excludeDomains")
    try copyIfPresent(fromObject, &toObject, "searchTypes")
    try copyIfPresent(fromObject, &toObject, "timeRangeFilter")
    return .object(toObject)
}

func imageConfigToMldev(_ fromObject: JsonValue) throws -> JsonValue {
    var toObject = JsonObject()
    try copyIfPresent(fromObject, &toObject, "aspectRatio")
    try copyIfPresent(fromObject, &toObject, "imageSize")
    try rejectEnterpriseOnly(fromObject, "personGeneration")
    try rejectEnterpriseOnly(fromObject, "outputMimeType")
    try rejectEnterpriseOnly(fromObject, "outputCompressionQuality")
    try rejectEnterpriseOnly(fromObject, "imageOutputOptions")
    try rejectEnterpriseOnly(fromObject, "prominentPeople")
    return .object(toObject)
}

func partToMldev(_ fromObject: JsonValue) throws -> JsonValue {
    var toObject = JsonObject()
    try copyIfPresent(fromObject, &toObject, "mediaResolution")
    try copyIfPresent(fromObject, &toObject, "toolCall")
    try copyIfPresent(fromObject, &toObject, "toolResponse")
    try copyIfPresent(fromObject, &toObject, "audioTranscription")
    try copyIfPresent(fromObject, &toObject, "codeExecutionResult")
    try copyIfPresent(fromObject, &toObject, "executableCode")
    let fromFileData = getValueByPath(fromObject, ["fileData"])
    if let fromFileData, isPresent(fromFileData) {
        try setValueByPath(&toObject, ["fileData"], try fileDataToMldev(fromFileData))
    }
    let fromFunctionCall = getValueByPath(fromObject, ["functionCall"])
    if let fromFunctionCall, isPresent(fromFunctionCall) {
        try setValueByPath(&toObject, ["functionCall"], try functionCallToMldev(fromFunctionCall))
    }
    try copyIfPresent(fromObject, &toObject, "functionResponse")
    let fromInlineData = getValueByPath(fromObject, ["inlineData"])
    if let fromInlineData, isPresent(fromInlineData) {
        try setValueByPath(&toObject, ["inlineData"], try blobToMldev(fromInlineData))
    }
    try copyIfPresent(fromObject, &toObject, "text")
    try copyIfPresent(fromObject, &toObject, "thought")
    try copyIfPresent(fromObject, &toObject, "thoughtSignature")
    try copyIfPresent(fromObject, &toObject, "videoMetadata")
    try copyIfPresent(fromObject, &toObject, "partMetadata")
    try copyIfPresent(fromObject, &toObject, "mediaProcessing")
    return .object(toObject)
}

func safetySettingToMldev(_ fromObject: JsonValue) throws -> JsonValue {
    var toObject = JsonObject()
    try copyIfPresent(fromObject, &toObject, "category")
    try rejectEnterpriseOnly(fromObject, "method")
    try copyIfPresent(fromObject, &toObject, "threshold")
    return .object(toObject)
}

func toolConfigToMldev(_ fromObject: JsonValue) throws -> JsonValue {
    var toObject = JsonObject()
    let fromFunctionCallingConfig = getValueByPath(fromObject, ["functionCallingConfig"])
    if let fromFunctionCallingConfig, isPresent(fromFunctionCallingConfig) {
        try setValueByPath(&toObject, ["functionCallingConfig"], try functionCallingConfigToMldev(fromFunctionCallingConfig))
    }
    try copyIfPresent(fromObject, &toObject, "retrievalConfig")
    try copyIfPresent(fromObject, &toObject, "includeServerSideToolInvocations")
    return .object(toObject)
}

func toolToMldev(_ fromObject: JsonValue) throws -> JsonValue {
    var toObject = JsonObject()
    try rejectEnterpriseOnly(fromObject, "retrieval")
    let fromGoogleMaps = getValueByPath(fromObject, ["googleMaps"])
    if let fromGoogleMaps, isPresent(fromGoogleMaps) {
        try setValueByPath(&toObject, ["googleMaps"], try googleMapsToMldev(fromGoogleMaps))
    }
    let fromMcpServers = getValueByPath(fromObject, ["mcpServers"])
    if let fromMcpServers, isPresent(fromMcpServers) {
        let transformedList = mapIfArray(fromMcpServers) { item in item }
        try setValueByPath(&toObject, ["mcpServers"], transformedList)
    }
    try copyIfPresent(fromObject, &toObject, "codeExecution")
    try copyIfPresent(fromObject, &toObject, "computerUse")
    try rejectEnterpriseOnly(fromObject, "enterpriseWebSearch")
    try rejectEnterpriseOnly(fromObject, "exaAiSearch")
    let fromFunctionDeclarations = getValueByPath(fromObject, ["functionDeclarations"])
    if let fromFunctionDeclarations, isPresent(fromFunctionDeclarations) {
        let transformedList = mapIfArray(fromFunctionDeclarations) { item in item }
        try setValueByPath(&toObject, ["functionDeclarations"], transformedList)
    }
    let fromGoogleSearch = getValueByPath(fromObject, ["googleSearch"])
    if let fromGoogleSearch, isPresent(fromGoogleSearch) {
        try setValueByPath(&toObject, ["googleSearch"], try googleSearchToMldev(fromGoogleSearch))
    }
    try copyIfPresent(fromObject, &toObject, "googleSearchRetrieval")
    try rejectEnterpriseOnly(fromObject, "parallelAiSearch")
    try copyIfPresent(fromObject, &toObject, "urlContext")
    try copyIfPresent(fromObject, &toObject, "fileSearch")
    return .object(toObject)
}

// MARK: - _api_client.ts

let CONTENT_TYPE_HEADER = "Content-Type"
let SERVER_TIMEOUT_HEADER = "X-Server-Timeout"
let USER_AGENT_HEADER = "User-Agent"
let GOOGLE_API_CLIENT_HEADER = "x-goog-api-client"
public let SDK_VERSION = "2.21.0" // x-release-please-version
let LIBRARY_LABEL = "google-genai-sdk/\(SDK_VERSION)"
let VERTEX_AI_API_DEFAULT_VERSION = "v1beta1"
let GOOGLE_AI_API_DEFAULT_VERSION = "v1beta"

// Not ported: raiseUndiciTimeouts (Node's Undici dispatcher has no URLSession equivalent).

/// Abort plumbing for one attempt (`createAttemptSignal`).
struct AttemptSignal: Sendable {
    var signal: AbortSignal?
    var dispose: @Sendable () -> Void
}

/// Creates the abort plumbing for one attempt.
///
/// A fresh signal per attempt is what makes `HttpOptions.timeout` a per-attempt
/// deadline rather than a budget shared across every retry and backoff.
func createAttemptSignal(_ timeout: Double?, _ callerSignal: AbortSignal?) -> AttemptSignal {
    let noop: @Sendable () -> Void = {}
    let hasTimeout = (timeout ?? 0) > 0
    if !hasTimeout && callerSignal == nil {
        return AttemptSignal(signal: nil, dispose: noop)
    }
    let controller = AbortController()
    var timeoutHandle: TimeoutHandle?
    if let timeout, timeout > 0 {
        timeoutHandle = setTimeout(timeout) { controller.abort() }
    }
    var listenerID: Int?
    if let callerSignal {
        if callerSignal.aborted {
            controller.abort()
        } else {
            listenerID = callerSignal.addEventListener { controller.abort() }
        }
    }
    let handle = timeoutHandle
    let id = listenerID
    return AttemptSignal(signal: controller.signal, dispose: {
        handle?.cancel()
        if let id { callerSignal?.removeEventListener(id) }
    })
}

/// A wrapper class for the http response.
public struct HttpResponse: Sendable {
    /// Lower-cased response header names -> values, sorted by name (`Headers.entries()`).
    public let headers: JsonObject
    let responseText: String

    init(headers: JsonObject, responseText: String) {
        self.headers = headers
        self.responseText = responseText
    }

    public func json() throws -> JsonValue {
        do {
            return try JsonValue.parse(responseText)
        } catch {
            throw PiError(errorMessage(error), name: "SyntaxError")
        }
    }
}

/// `Object.fromEntries(response.headers.entries())`.
private func headersEntriesRecord(_ headers: Headers) -> JsonObject {
    let record = headers.record
    var result = JsonObject()
    for key in record.keys.sorted() {
        result[key] = .string(record[key]!)
    }
    return result
}

/// The request shape `ApiClient.requestStream` takes.
struct HttpRequest: Sendable {
    var path: String
    var queryParams: JsonValue?
    var body: String?
    var httpMethod: String
    var httpOptions: JsonObject?
    var abortSignal: AbortSignal?
}

/// The `ApiClient` constructor options (`ApiClientInitOptions`).
struct ApiClientInitOptions: Sendable {
    var auth: NodeAuth
    var project: String?
    var location: String?
    var apiVersion: String?
    var apiKey: String?
    var vertexai: Bool?
    var httpOptions: JsonObject?
    var userAgentExtra: String?
    /// Swift: the `fetch` implementation (upstream uses the global `fetch`).
    var fetch: FetchFunction?
}

/// The ApiClient class is used to send requests to the Gemini API or Vertex AI
/// endpoints.
///
/// WARNING: This is an internal API and may change without notice. Direct usage
/// is not supported and may break your application.
public final class ApiClient: Sendable {
    let clientOptions: ApiClientInitOptions
    let customBaseUrl: JsonValue?

    init(_ opts: ApiClientInitOptions) {
        var clientOptions = opts
        self.customBaseUrl = opts.httpOptions?["baseUrl"]
        var initHttpOptions = JsonObject()
        if clientOptions.vertexai ?? false {
            // Not ported: Vertex AI base URL / location resolution (GoogleGenAI rejects Vertex AI first).
            initHttpOptions["apiVersion"] = .string(clientOptions.apiVersion ?? VERTEX_AI_API_DEFAULT_VERSION)
        } else {
            // Gemini API
            if !jsTruthy(clientOptions.apiKey.map { .string($0) }) {
                // Not ported: console.warn('API key should be set when using the Gemini API.');
            }
            initHttpOptions["apiVersion"] = .string(clientOptions.apiVersion ?? GOOGLE_AI_API_DEFAULT_VERSION)
            initHttpOptions["baseUrl"] = "https://generativelanguage.googleapis.com/"
        }
        initHttpOptions["headers"] = .object(ApiClient.defaultHeaders(clientOptions.userAgentExtra))
        clientOptions.httpOptions = initHttpOptions
        if let httpOptions = opts.httpOptions {
            clientOptions.httpOptions = ApiClient.patchHttpOptions(initHttpOptions, httpOptions)
        }
        self.clientOptions = clientOptions
    }

    public func isVertexAI() -> Bool {
        clientOptions.vertexai ?? false
    }

    public func getProject() -> String? {
        clientOptions.project
    }

    public func getLocation() -> String? {
        clientOptions.location
    }

    public func getCustomBaseUrl() -> JsonValue? {
        customBaseUrl
    }

    public func getApiVersion() throws -> JsonValue {
        if let httpOptions = clientOptions.httpOptions, let apiVersion = httpOptions["apiVersion"] {
            return apiVersion
        }
        throw PiError("API version is not set.")
    }

    public func getBaseUrl() throws -> JsonValue {
        if let httpOptions = clientOptions.httpOptions, let baseUrl = httpOptions["baseUrl"] {
            return baseUrl
        }
        throw PiError("Base URL is not set.")
    }

    public func getRequestUrl() throws -> String {
        try getRequestUrlInternal(clientOptions.httpOptions)
    }

    public func getHeaders() throws -> JsonValue {
        if let httpOptions = clientOptions.httpOptions, let headers = httpOptions["headers"] {
            return headers
        } else {
            throw PiError("Headers are not set.")
        }
    }

    func getRequestUrlInternal(_ httpOptions: JsonObject?) throws -> String {
        guard let httpOptions,
              let baseUrlValue = httpOptions["baseUrl"],
              let apiVersion = httpOptions["apiVersion"]
        else {
            throw PiError("HTTP options are not correctly set.")
        }
        let rawBaseUrl = jsToString(baseUrlValue)
        let baseUrl = rawBaseUrl.hasSuffix("/") ? String(rawBaseUrl.dropLast()) : rawBaseUrl
        var urlElement = [baseUrl]
        if jsTruthy(apiVersion) && apiVersion != .string("") {
            urlElement.append(jsToString(apiVersion))
        }
        return urlElement.joined(separator: "/")
    }

    public func getBaseResourcePath() -> String {
        "projects/\(clientOptions.project ?? "undefined")/locations/\(clientOptions.location ?? "undefined")"
    }

    public func getApiKey() -> String? {
        clientOptions.apiKey
    }

    func constructUrl(_ path: String, _ httpOptions: JsonObject?, _ prependProjectLocation: Bool) throws -> URLComponents {
        var urlElement = [try getRequestUrlInternal(httpOptions)]
        if prependProjectLocation {
            urlElement.append(getBaseResourcePath())
        }
        if path != "" {
            urlElement.append(path)
        }
        let joined = urlElement.joined(separator: "/")
        guard let url = URL(string: joined), url.scheme != nil, let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            throw PiError("Invalid URL", name: "TypeError")
        }
        return components
    }

    func shouldPrependVertexProjectPath(_ request: HttpRequest, _ httpOptions: JsonObject?) -> Bool {
        if jsTruthy(httpOptions?["baseUrl"]) && httpOptions?["baseUrlResourceScope"] == .string("COLLECTION") {
            return false
        }
        if !(clientOptions.vertexai ?? false) {
            return false
        }
        // Not ported: Vertex AI project/location prefixing.
        return false
    }

    // Not ported: request() / unaryApiCall() (only streaming generateContent is used).

    static func patchHttpOptions(_ baseHttpOptions: JsonObject?, _ requestHttpOptions: JsonObject) -> JsonObject {
        var patchedHttpOptions = baseHttpOptions ?? JsonObject()
        for (key, value) in requestHttpOptions {
            // Records compile to objects.
            switch value {
            case .object, .array, .null:
                // `{...patchedHttpOptions[key], ...value}`
                var merged = JsonObject()
                if case .object(let previous)? = patchedHttpOptions[key] {
                    merged = previous
                } else if case .array(let previous)? = patchedHttpOptions[key] {
                    for (i, v) in previous.enumerated() { merged[String(i)] = v }
                } else if case .string(let previous)? = patchedHttpOptions[key] {
                    for (i, c) in previous.enumerated() { merged[String(i)] = .string(String(c)) }
                }
                if case .object(let source) = value {
                    for (k, v) in source { merged[k] = v }
                } else if case .array(let source) = value {
                    for (i, v) in source.enumerated() { merged[String(i)] = v }
                }
                patchedHttpOptions[key] = .object(merged)
            default:
                patchedHttpOptions[key] = value
            }
        }
        return patchedHttpOptions
    }

    func requestStream(_ request: HttpRequest) async throws -> AsyncThrowingStream<HttpResponse, any Error> {
        var patchedHttpOptions = clientOptions.httpOptions
        if let requestHttpOptions = request.httpOptions {
            patchedHttpOptions = ApiClient.patchHttpOptions(clientOptions.httpOptions, requestHttpOptions)
        }
        let prependProjectLocation = shouldPrependVertexProjectPath(request, patchedHttpOptions)
        var url = try constructUrl(request.path, patchedHttpOptions, prependProjectLocation)
        let alt = url.queryItems?.first { $0.name == "alt" }
        if alt == nil || alt?.value != "sse" {
            // `url.searchParams.set('alt', 'sse')`
            var items = url.queryItems ?? []
            if let index = items.firstIndex(where: { $0.name == "alt" }) {
                var result: [URLQueryItem] = []
                for (offset, item) in items.enumerated() {
                    if item.name != "alt" {
                        result.append(item)
                    } else if offset == index {
                        result.append(URLQueryItem(name: "alt", value: "sse"))
                    }
                }
                items = result
            } else {
                items.append(URLQueryItem(name: "alt", value: "sse"))
            }
            url.queryItems = items
        }
        var requestInit = RequestInit()
        requestInit.body = request.body
        guard let urlString = url.string else {
            throw PiError("Invalid URL", name: "TypeError")
        }
        requestInit = try await includeExtraHttpOptionsToRequestInit(requestInit, patchedHttpOptions, urlString)
        return try await streamApiCall(urlString, requestInit, request.httpMethod, patchedHttpOptions?["retryOptions"], patchedHttpOptions?["timeout"], request.abortSignal)
    }

    func includeExtraHttpOptionsToRequestInit(_ requestInit: RequestInit, _ httpOptions: JsonObject?, _ url: String) async throws -> RequestInit {
        var requestInit = requestInit
        // Not ported: raiseUndiciTimeouts(httpOptions.timeout).
        if let httpOptions, httpOptions["extraBody"] != .null {
            includeExtraBodyToRequestInit(&requestInit, httpOptions["extraBody"])
        }
        requestInit.headers = try await getHeadersInternal(httpOptions, url)
        return requestInit
    }

    func streamApiCall(_ url: String, _ requestInit: RequestInit, _ httpMethod: String, _ retryOptions: JsonValue?, _ timeout: JsonValue?, _ abortSignal: AbortSignal?) async throws -> AsyncThrowingStream<HttpResponse, any Error> {
        let response = try await apiCall(url, requestInit, httpMethod, retryOptions, timeout, abortSignal)
        try await throwErrorIfNotOK(response)
        return processStreamResponse(response)
        // Swift: every thrown value is already an `Error`, so the upstream
        // `exception ${e} sending request` wrapping never applies.
    }

    func processStreamResponse(_ response: FetchResponse) -> AsyncThrowingStream<HttpResponse, any Error> {
        let (stream, continuation) = AsyncThrowingStream<HttpResponse, any Error>.makeStream(bufferingPolicy: .unbounded)
        let task = Task {
            do {
                // Swift: a FetchResponse always has a body; `Response body is empty` cannot occur.
                var decoder = TextDecoderUTF8()
                let responseHeaders = headersEntriesRecord(response.headers)
                var buffer: [Unicode.Scalar] = []
                let dataPrefix = "data:"
                let delimiters: [[Unicode.Scalar]] = ["\n\n", "\r\r", "\r\n\r\n"].map { Array($0.unicodeScalars) }
                var iterator = response.body.makeAsyncIterator()
                while true {
                    guard let value = try await iterator.next() else {
                        if !jsTrim(String(String.UnicodeScalarView(buffer))).isEmpty {
                            throw PiError("Incomplete JSON segment at the end")
                        }
                        break
                    }
                    if Task.isCancelled { break }
                    let chunkString = decoder.decode(value)
                    // Parse and throw an error if the chunk contains an error.
                    if let apiError = streamChunkApiError(chunkString) {
                        throw apiError
                    }
                    buffer.append(contentsOf: chunkString.unicodeScalars)
                    var delimiterIndex = -1
                    var delimiterLength = 0
                    while true {
                        delimiterIndex = -1
                        delimiterLength = 0
                        for delimiter in delimiters {
                            let index = indexOf(buffer, delimiter)
                            if index != -1 && (delimiterIndex == -1 || index < delimiterIndex) {
                                delimiterIndex = index
                                delimiterLength = delimiter.count
                            }
                        }
                        if delimiterIndex == -1 {
                            break // No complete event in buffer
                        }
                        let eventString = String(String.UnicodeScalarView(buffer[0..<delimiterIndex]))
                        buffer = Array(buffer[(delimiterIndex + delimiterLength)...])
                        let trimmedEvent = jsTrim(eventString)
                        if trimmedEvent.hasPrefix(dataPrefix) {
                            let processedChunkString = jsTrim(String(trimmedEvent.dropFirst(dataPrefix.count)))
                            continuation.yield(HttpResponse(headers: responseHeaders, responseText: processedChunkString))
                        }
                    }
                }
                continuation.finish()
            } catch {
                continuation.finish(throwing: error)
            }
        }
        continuation.onTermination = { _ in task.cancel() }
        return stream
    }

    func apiCall(_ url: String, _ requestInit: RequestInit, _ httpMethod: String, _ retryOptions: JsonValue?, _ timeout: JsonValue?, _ abortSignal: AbortSignal?) async throws -> FetchResponse {
        // Not ported: retryOptions (p-retry with exponential backoff). Requests are attempted once, as
        // upstream does when `retryOptions` is unset (pi never sets it).
        let fetch = clientOptions.fetch ?? defaultFetch
        let timeoutMs: Double? = timeout.flatMap { $0.isNull ? nil : jsNumber($0) }
        let runFetch: @Sendable () async throws -> FetchResponse = {
            // A fresh signal per attempt, so that `timeout` bounds this attempt
            // rather than the whole retry sequence.
            let attempt = createAttemptSignal(timeoutMs, abortSignal)
            let response: FetchResponse
            do {
                guard let requestURL = URL(string: url) else {
                    throw PiError("Invalid URL", name: "TypeError")
                }
                response = try await fetch(FetchRequest(
                    url: requestURL,
                    method: httpMethod,
                    headers: requestInit.headers,
                    body: requestInit.body.map { Data($0.utf8) },
                    signal: attempt.signal
                ))
            } catch {
                attempt.dispose()
                throw error
            }
            // Either a success, or a failure that must not be retried.
            //
            // The attempt is deliberately not disposed: ownership of the response
            // passes to the caller, and the timeout must stay armed while the body
            // is consumed.
            return response
        }
        return try await runFetch()
    }

    static func defaultHeaders(_ userAgentExtra: String?) -> JsonObject {
        var headers = JsonObject()
        let versionHeaderValue = LIBRARY_LABEL + " " + (userAgentExtra ?? "undefined")
        headers[USER_AGENT_HEADER] = .string(versionHeaderValue)
        headers[GOOGLE_API_CLIENT_HEADER] = .string(versionHeaderValue)
        headers[CONTENT_TYPE_HEADER] = "application/json"
        return headers
    }

    func getDefaultHeaders() -> JsonObject {
        ApiClient.defaultHeaders(clientOptions.userAgentExtra)
    }

    func getHeadersInternal(_ httpOptions: JsonObject?, _ url: String) async throws -> Headers {
        var headers = Headers()
        if let httpOptions, case .object(let optionHeaders)? = httpOptions["headers"] {
            for (key, value) in optionHeaders {
                headers.append(key, jsToString(value))
            }
        }
        // Append a timeout header if it is set, note that the timeout option is
        // in milliseconds but the header is in seconds.
        // NOTE: This is intentionally outside the httpOptions.headers guard above
        // so that the X-Server-Timeout header is always sent whenever a timeout
        // is configured, even if the caller did not supply any custom headers.
        if let timeout = httpOptions?["timeout"], jsTruthy(timeout), jsNumber(timeout) > 0 {
            headers.append(SERVER_TIMEOUT_HEADER, JsonWriter.formatNumber((jsNumber(timeout) / 1000).rounded(.up)))
        }
        try await clientOptions.auth.addAuthHeaders(&headers, url)
        return headers
    }

    // Not ported: getFileName / uploadFile / uploadFileToFileSearchStore / downloadFile / fetchUploadUrl.
}

/// The `RequestInit` fields `ApiClient` sets.
struct RequestInit: Sendable {
    var body: String?
    var headers = Headers()
}

/// Index of `pattern` in `buffer` (`String.prototype.indexOf`), or -1.
private func indexOf(_ buffer: [Unicode.Scalar], _ pattern: [Unicode.Scalar]) -> Int {
    guard buffer.count >= pattern.count else { return -1 }
    var i = 0
    while i <= buffer.count - pattern.count {
        if buffer[i] == pattern[0] && Array(buffer[i..<(i + pattern.count)]) == pattern {
            return i
        }
        i += 1
    }
    return -1
}

/// The error-chunk check in `processStreamResponse`: a raw chunk that parses as a JSON object with an
/// `error` whose `code` is 4xx/5xx becomes an `ApiError`; every other parse outcome is ignored.
private func streamChunkApiError(_ chunkString: String) -> GoogleGenAI.ApiError? {
    guard let chunkJson = try? JsonValue.parse(chunkString),
          case .object(let object) = chunkJson,
          let errorJson = object["error"]
    else {
        return nil
    }
    if errorJson.isNull {
        // `null['status']` throws a TypeError, which the upstream catch ignores.
        return nil
    }
    let status = errorJson["status"]
    let code = errorJson["code"]
    let errorMessage = "got status: \(status.map(jsToString) ?? "undefined"). \(chunkJson.serialized())"
    let codeNumber = jsNumber(code)
    if codeNumber >= 400 && codeNumber < 600 {
        return GoogleGenAI.ApiError(message: errorMessage, status: Int(codeNumber))
    }
    return nil
}

/// `new TextDecoder('utf-8').decode(value, { stream: true })`: holds back an incomplete trailing
/// sequence, strips a leading BOM, and replaces invalid bytes with U+FFFD.
struct TextDecoderUTF8 {
    private var pending: [UInt8] = []
    private var bomSeen = false

    mutating func decode(_ data: Data) -> String {
        var bytes = pending
        bytes.append(contentsOf: data)
        var cut = bytes.count
        var i = bytes.count - 1
        var back = 0
        while i >= 0 && back < 4 {
            let b = bytes[i]
            if b & 0xC0 == 0x80 {
                i -= 1
                back += 1
                continue
            }
            let need = b >= 0xF8 ? 1 : b >= 0xF0 ? 4 : b >= 0xE0 ? 3 : b >= 0xC0 ? 2 : 1
            if need > bytes.count - i {
                cut = i
            }
            break
        }
        pending = Array(bytes[cut...])
        var text = String(decoding: bytes[..<cut], as: UTF8.self)
        if !bomSeen && !text.isEmpty {
            bomSeen = true
            if text.unicodeScalars.first == "\u{FEFF}" {
                text = String(text.unicodeScalars.dropFirst())
            }
        }
        return text
    }
}

func throwErrorIfNotOK(_ response: FetchResponse?) async throws {
    guard let response else {
        throw PiError("response is undefined")
    }
    if !response.ok {
        let status = response.status
        let errorBody: JsonValue
        if response.headers.get("content-type")?.contains("application/json") == true {
            do {
                errorBody = try await response.json()
            } catch {
                throw PiError(errorMessage(error), name: "SyntaxError")
            }
        } else {
            errorBody = [
                "error": [
                    "message": .string(try await response.text()),
                    "code": .number(Double(response.status)),
                    "status": .string(response.statusText),
                ],
            ]
        }
        let errorMessage = errorBody.serialized()
        if status >= 400 && status < 600 {
            let apiError = GoogleGenAI.ApiError(message: errorMessage, status: status)
            throw apiError
        }
        throw PiError(errorMessage)
    }
}

/// Recursively updates the `requestInit.body` with values from an `extraBody` object.
///
/// If `requestInit.body` is a string, it's assumed to be JSON and will be parsed.
/// The `extraBody` is then deeply merged into this parsed object.
///
/// The function does not enforce that updated values from `extraBody` have the
/// same type as existing values in `requestInit.body`. Type mismatches during
/// the merge will result in a warning, but the value from `extraBody` will overwrite
/// the original. `extraBody` users are responsible for ensuring `extraBody` has the correct structure.
func includeExtraBodyToRequestInit(_ requestInit: inout RequestInit, _ extraBody: JsonValue?) {
    guard case .object(let extraBodyObject)? = extraBody, !extraBodyObject.isEmpty else {
        return
    }
    // Not ported: Blob bodies (request bodies are always strings here).
    var currentBodyObject = JsonObject()
    // If adding new type to HttpRequest.body, please check the code below to
    // see if we need to update the logic.
    if let body = requestInit.body, !body.isEmpty {
        guard let parsedBody = try? JsonValue.parse(body) else {
            // Not ported: console.warn('includeExtraBodyToRequestInit: Original request body is not valid JSON. Skip applying extraBody to the request body.');
            return
        }
        if case .object(let object) = parsedBody {
            currentBodyObject = object
        } else {
            // Not ported: console.warn('includeExtraBodyToRequestInit: Original request body is valid JSON but not a non-array object. Skip applying extraBody to the request body.');
            return
        }
    }
    func deepMerge(_ target: JsonObject, _ source: JsonObject) -> JsonObject {
        var output = target
        for (key, sourceValue) in source {
            let targetValue = output[key]
            if case .object(let sourceObject) = sourceValue, case .object(let targetObject)? = targetValue {
                output[key] = .object(deepMerge(targetObject, sourceObject))
            } else {
                // Not ported: console.warn on a type mismatch for the key.
                output[key] = sourceValue
            }
        }
        return output
    }
    let mergedBody = deepMerge(currentBodyObject, extraBodyObject)
    requestInit.body = JsonValue.object(mergedBody).serialized()
}

// MARK: - node/_node_auth.ts

let GOOGLE_API_KEY_HEADER = "x-goog-api-key"

final class NodeAuth: Sendable {
    let apiKey: String?

    init(apiKey: String?) {
        // Not ported: `new GoogleAuth(buildGoogleAuthOptions(googleAuthOptions))` when apiKey is undefined.
        self.apiKey = apiKey
    }

    func addAuthHeaders(_ headers: inout Headers, _ url: String?) async throws {
        if let apiKey {
            if apiKey.hasPrefix("auth_tokens/") {
                throw PiError("Ephemeral tokens are only supported by the live API.")
            }
            try addKeyHeader(&headers)
            return
        }
        try await addGoogleAuthHeaders(&headers, url)
    }

    func addKeyHeader(_ headers: inout Headers) throws {
        if headers.get(GOOGLE_API_KEY_HEADER) != nil {
            return
        }
        guard let apiKey else {
            // This should never happen, this method is only called
            // when apiKey is set.
            throw PiError("Trying to set API key header but apiKey is not set")
        }
        headers.append(GOOGLE_API_KEY_HEADER, apiKey)
    }

    func addGoogleAuthHeaders(_ headers: inout Headers, _ url: String?) async throws {
        // Not ported: google-auth-library application default credentials.
        throw PiError("google-auth-library credentials are not supported by this port; provide an apiKey")
    }
}

// MARK: - models.ts

/// Swift: the `generateContentStream` result — `GenerateContentResponse` chunks as JSON objects, each
/// carrying `sdkHttpResponse: { headers }`.
public typealias GenerateContentResponseStream = AsyncThrowingStream<JsonValue, any Error>

// Swift: upstream `Models` (genai models module); renamed because PiAI already has `Models` (models.ts).
public final class GoogleGenAIModels: Sendable {
    let apiClient: ApiClient

    init(_ apiClient: ApiClient) {
        self.apiClient = apiClient
    }

    /// Makes an API request to generate content with a given model and yields the
    /// response in chunks.
    ///
    /// For the `model` parameter, supported formats for Gemini API include:
    /// - The Gemini model ID, for example: 'gemini-2.0-flash'
    /// - The model name starts with 'models/', for example:
    ///   'models/gemini-2.0-flash'
    /// - For tuned models, the model name starts with 'tunedModels/',
    ///   for example:
    ///   'tunedModels/1234567890123456789'
    ///
    /// - Parameters:
    ///   - params: `GenerateContentParameters` (`model`, `contents`, `config`) as JSON. `config.httpOptions`
    ///     is honored as JSON `HttpOptions`.
    ///   - abortSignal: Swift: upstream `config.abortSignal`.
    /// - Returns: The response from generating content.
    public func generateContentStream(_ params: JsonValue, abortSignal: AbortSignal? = nil) async throws -> GenerateContentResponseStream {
        var params = params
        maybeMoveToResponseJsonSchema(&params)
        if shouldDisableAfc(params["config"]) {
            let transformedParams = try await processParamsMaybeAddMcpUsage(params)
            return try await generateContentStreamInternal(transformedParams, abortSignal: abortSignal)
        }
        // Not ported: automatic function calling with CallableTools / MCP (unreachable for JSON tools).
        let transformedParams = try await processParamsMaybeAddMcpUsage(params)
        return try await generateContentStreamInternal(transformedParams, abortSignal: abortSignal)
    }

    /// Previously we made GenerateContentConfig.responseSchema field to accept
    /// unknown. Since v1.9.0, we switch to use backend JSON schema support.
    /// To maintain backward compatibility, we move the data that was treated as
    /// JSON schema from the responseSchema field to the responseJsonSchema field.
    func maybeMoveToResponseJsonSchema(_ params: inout JsonValue) {
        guard case .object(var config)? = params["config"], jsTruthy(config["responseSchema"]) else {
            return
        }
        if !jsTruthy(config["responseJsonSchema"]) {
            if let responseSchema = config["responseSchema"], hasSchemaKey(responseSchema) {
                config["responseJsonSchema"] = responseSchema
                config["responseSchema"] = nil
                params["config"] = .object(config)
            }
        }
    }

    /// Transforms the CallableTools in the parameters to be simply Tools, it
    /// copies the params into a new object and replaces the tools, it does not
    /// modify the original params. Also sets the MCP usage header if there are
    /// MCP tools in the parameters.
    func processParamsMaybeAddMcpUsage(_ params: JsonValue) async throws -> JsonValue {
        let tools = params["config"]?["tools"]
        guard let tools, jsTruthy(tools) else {
            return params
        }
        guard case .array(let toolList) = tools else {
            throw PiError("tools.map is not a function", name: "TypeError")
        }
        // Swift: JSON tools are never CallableTools, so the transformed list is the input list.
        let transformedTools = toolList
        var newParams = JsonObject()
        if let model = params["model"] { newParams["model"] = model }
        if let contents = params["contents"] { newParams["contents"] = contents }
        var newConfig = params["config"]?.objectValue ?? JsonObject()
        newConfig["tools"] = .array(transformedTools)
        if try hasMcpToolUsage(toolList) {
            let headers = newConfig["httpOptions"]?["headers"].flatMap { $0.isNull ? nil : $0 }?.objectValue ?? JsonObject()
            var newHeaders = headers
            if newHeaders.isEmpty {
                newHeaders = apiClient.getDefaultHeaders()
            }
            setMcpUsageHeader(&newHeaders)
            var httpOptions = newConfig["httpOptions"]?.objectValue ?? JsonObject()
            httpOptions["headers"] = .object(newHeaders)
            newConfig["httpOptions"] = .object(httpOptions)
        }
        newParams["config"] = .object(newConfig)
        return .object(newParams)
    }

    func generateContentStreamInternal(_ params: JsonValue, abortSignal: AbortSignal?) async throws -> GenerateContentResponseStream {
        // Not ported: the Vertex AI branch (generateContentParametersToVertex / generateContentResponseFromVertex).
        var body = try generateContentParametersToMldev(apiClient, params)
        let path = try formatMap("{model}:streamGenerateContent?alt=sse", body["_url"])
        let queryParams = body["_query"]
        body["_url"] = nil
        body["_query"] = nil
        let apiClient = self.apiClient
        let apiResponse = try await apiClient.requestStream(HttpRequest(
            path: path,
            queryParams: queryParams,
            body: JsonValue.object(body).serialized(),
            httpMethod: "POST",
            httpOptions: params["config"]?["httpOptions"]?.objectValue,
            abortSignal: abortSignal
        ))
        let (stream, continuation) = AsyncThrowingStream<JsonValue, any Error>.makeStream(bufferingPolicy: .unbounded)
        let task = Task {
            do {
                for try await chunk in apiResponse {
                    var resp = try generateContentResponseFromMldev(try chunk.json())
                    resp["sdkHttpResponse"] = [
                        "headers": .object(chunk.headers),
                    ]
                    continuation.yield(.object(resp))
                }
                continuation.finish()
            } catch {
                continuation.finish(throwing: error)
            }
        }
        continuation.onTermination = { _ in task.cancel() }
        return stream
    }
}

// MARK: - _afc.ts

let DEFAULT_MAX_REMOTE_CALLS = 10

/// Returns whether automatic function calling is disabled.
///
/// Swift: tools are JSON and never `CallableTool`s, so this is always true.
func shouldDisableAfc(_ config: JsonValue?) -> Bool {
    if jsTruthy(config?["automaticFunctionCalling"]?["disable"]) {
        return true
    }
    // `callableToolsPresent` is always false for JSON tools, so AFC is disabled.
    // Not ported: maximumRemoteCalls validation (unreachable without CallableTools).
    return true
}

// MARK: - mcp/_mcp.ts

// TODO: b/416041229 - Determine how to retrieve the MCP package version.
let MCP_LABEL = "mcp_used/unknown"

/// Checks whether the list of tools contains any MCP tools.
///
/// Not ported: `McpCallableTool` instances and the `mcpToTool` usage flag (always false here).
func hasMcpToolUsage(_ tools: [JsonValue]) throws -> Bool {
    for tool in tools {
        switch tool {
        case .null:
            throw PiError("Cannot use 'in' operator to search for 'inputSchema' in null", name: "TypeError")
        case .object(let object):
            if object.contains("inputSchema") {
                return true
            }
        default:
            break
        }
    }
    return false
}

/// Sets the MCP version label in the Google API client header.
func setMcpUsageHeader(_ headers: inout JsonObject) {
    let existingHeader = headers[GOOGLE_API_CLIENT_HEADER].map { $0.isNull ? "" : jsToString($0) } ?? ""
    let value = existingHeader + " \(MCP_LABEL)"
    headers[GOOGLE_API_CLIENT_HEADER] = .string(String(value.unicodeScalars.drop { isJsWhitespace($0) }))
}

// MARK: - node/node_client.ts

let LANGUAGE_LABEL_PREFIX = "gl-node/"

/// Swift: environment lookup (`process.env`), trimmed.
private func getEnv(_ env: ProviderEnv, _ name: String) -> String? {
    env[name].map(jsTrim)
}

func resolveCloudFlag(_ options: GoogleGenAI.Options, _ env: ProviderEnv) throws -> Bool {
    if options.enterprise != nil || options.vertexai != nil {
        if let enterprise = options.enterprise, let vertexai = options.vertexai, enterprise != vertexai {
            throw PiError("enterprise and vertexAI flags have conflicting values, please set enterprise value only.")
        }
        return options.enterprise ?? options.vertexai ?? false
    }
    let envEnterpriseStr = getEnv(env, "GOOGLE_GENAI_USE_ENTERPRISE")
    let envVertexaiStr = getEnv(env, "GOOGLE_GENAI_USE_VERTEXAI")
    let useEnterpriseEnv = stringToBoolean(envEnterpriseStr)
    let useVertexaiEnv = stringToBoolean(envVertexaiStr)
    if envEnterpriseStr != nil && envVertexaiStr != nil && useEnterpriseEnv != useVertexaiEnv {
        // Not ported: console.warn('Warning: Both GOOGLE_GENAI_USE_ENTERPRISE and GOOGLE_GENAI_USE_VERTEXAI are set with conflicting values. The value of GOOGLE_GENAI_USE_ENTERPRISE will be used.');
    }
    if envEnterpriseStr != nil {
        return useEnterpriseEnv
    }
    if envVertexaiStr != nil {
        return useVertexaiEnv
    }
    return false
}

private func stringToBoolean(_ str: String?) -> Bool {
    guard let str else {
        return false
    }
    return str.lowercased() == "true"
}

private func getApiKeyFromEnv(_ env: ProviderEnv) -> String? {
    let envGoogleApiKey = getEnv(env, "GOOGLE_API_KEY")
    let envGeminiApiKey = getEnv(env, "GEMINI_API_KEY")
    if let envGoogleApiKey, !envGoogleApiKey.isEmpty, let envGeminiApiKey, !envGeminiApiKey.isEmpty {
        // Not ported: console.warn('Both GOOGLE_API_KEY and GEMINI_API_KEY are set. Using GOOGLE_API_KEY.');
    }
    if let envGoogleApiKey, !envGoogleApiKey.isEmpty { return envGoogleApiKey }
    if let envGeminiApiKey, !envGeminiApiKey.isEmpty { return envGeminiApiKey }
    return nil
}

/// The Google GenAI SDK.
///
/// Provides access to the GenAI features through the Gemini API.
///
/// When using the Gemini API, a `Options.apiKey` must also be set.
///
/// Explicitly passed in values in `Options` will always take precedence over environment variables.
///
/// Not ported: the Vertex AI backend (`vertexai` / `enterprise` resolving to true throws).
public final class GoogleGenAI: Sendable {
    /// `GoogleGenAIOptions`.
    public struct Options: Sendable {
        /// Optional. Determines whether to use the Gemini Enterprise Agent Platform (Vertex AI). Not ported.
        public var vertexai: Bool?
        /// Optional. Same as `vertexai`. Not ported.
        public var enterprise: Bool?
        /// Optional. The Google Cloud project ID. Vertex AI only.
        public var project: String?
        /// Optional. The Google Cloud location. Vertex AI only.
        public var location: String?
        /// The API Key, required for Gemini API clients.
        public var apiKey: String?
        /// Optional. The API version to use.
        public var apiVersion: String?
        /// Optional. A set of customizable configuration for HTTP requests (`HttpOptions`: `baseUrl`,
        /// `apiVersion`, `headers`, `timeout`, `extraBody`, ...).
        public var httpOptions: JsonObject?
        /// Swift: the `fetch` implementation (upstream always uses the global `fetch`).
        public var fetch: FetchFunction?
        /// Swift: the environment consulted for `GOOGLE_API_KEY` etc. (default: the process environment).
        public var env: ProviderEnv?

        public init(vertexai: Bool? = nil, enterprise: Bool? = nil, project: String? = nil, location: String? = nil, apiKey: String? = nil, apiVersion: String? = nil, httpOptions: JsonObject? = nil, fetch: FetchFunction? = nil, env: ProviderEnv? = nil) {
            self.vertexai = vertexai
            self.enterprise = enterprise
            self.project = project
            self.location = location
            self.apiKey = apiKey
            self.apiVersion = apiVersion
            self.httpOptions = httpOptions
            self.fetch = fetch
            self.env = env
        }
    }

    /// API errors raised by the GenAI API.
    public struct ApiError: ProviderError, CustomStringConvertible, LocalizedError, Sendable {
        public let name = "ApiError"
        public let message: String
        public let status: Int?
        /// `retryGoogleRequest` normalizes the missing `headers` to undefined.
        public var headers: Headers? { nil }

        public init(message: String, status: Int?) {
            self.message = message
            self.status = status
        }

        public var description: String { message }
        public var errorDescription: String? { message }
    }

    let vertexai: Bool
    let apiKey: String?
    let project: String?
    let location: String?
    let apiVersion: String?
    let httpOptions: JsonObject?
    public let apiClient: ApiClient
    public let models: GoogleGenAIModels

    public init(_ inputOptions: Options = Options()) throws {
        var options = inputOptions
        let env = options.env ?? ProcessInfo.processInfo.environment
        self.vertexai = try resolveCloudFlag(options, env)
        // Validate explicitly set initializer values.
        if (!(options.project ?? "").isEmpty || !(options.location ?? "").isEmpty) && !vertexai {
            throw PiError("Project and location are not supported for Gemini API backend.")
        }
        let envApiKey = getApiKeyFromEnv(env)
        let envProject = getEnv(env, "GOOGLE_CLOUD_PROJECT")
        let envLocation = getEnv(env, "GOOGLE_CLOUD_LOCATION")
        let apiKey = options.apiKey ?? envApiKey
        self.apiKey = apiKey
        self.project = options.project ?? envProject
        self.location = options.location ?? envLocation
        if !vertexai && (apiKey ?? "").isEmpty {
            // Not ported: console.warn('API key should be set when using the Gemini API.');
        }
        // Handle when to use Vertex AI in express mode (api key)
        if vertexai {
            // Not ported: Vertex AI credential precedence and the Vertex AI backend.
            throw PiError("Vertex AI (Gemini Enterprise Agent Platform) is not supported by this port")
        }
        let baseUrl = getBaseUrl(options.httpOptions, vertexai, getEnv(env, "GOOGLE_VERTEX_BASE_URL"), getEnv(env, "GOOGLE_GEMINI_BASE_URL"))
        if let baseUrl, jsTruthy(baseUrl) {
            if options.httpOptions != nil {
                options.httpOptions!["baseUrl"] = baseUrl
            } else {
                options.httpOptions = ["baseUrl": baseUrl]
            }
        }
        self.apiVersion = options.apiVersion
        self.httpOptions = options.httpOptions
        let auth = NodeAuth(apiKey: apiKey)
        self.apiClient = ApiClient(ApiClientInitOptions(
            auth: auth,
            project: project,
            location: location,
            apiVersion: apiVersion,
            apiKey: apiKey,
            vertexai: vertexai,
            httpOptions: httpOptions,
            // Swift: there is no Node `process.version`.
            userAgentExtra: LANGUAGE_LABEL_PREFIX + "unknown",
            fetch: options.fetch
        ))
        self.models = GoogleGenAIModels(apiClient)
        // Not ported: live, batches, chats, caches, files, operations, authTokens, tunings,
        // fileSearchStores, interactions, webhooks, agents, triggers, environments.
    }
}
