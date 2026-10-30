import Foundation

// Port of packages/ai/src/api/google-shared.ts
//
// Shared utilities for Google Generative AI and Google Vertex providers.
//
// Swift notes:
// - `@google/genai` `Content` / `Part` / `ThinkingConfig` values are JSON (`JsonValue` / `JsonObject`), the shape the
//   SDK core (`platform/sdk/GoogleGenAI.swift`) takes. SDK string enums (`FinishReason`, `FunctionCallingConfigMode`,
//   `ThinkingLevel`) are their string values.
// - `Model<"google-generative-ai" | "google-vertex">` is `Model` (Swift models carry `api` as a string).
// - Exported names that clash with other api modules are suffixed with `Google`: `convertMessagesGoogle`
//   (openai-completions also exports `convertMessages`), `convertToolsGoogle`, `mapToolChoiceGoogle`,
//   `mapStopReasonGoogle`, `mapStopReasonStringGoogle` (other adapters declare module-level helpers with these names).
// - Nothing in this file exists solely for Vertex; it is ported in full. `google-vertex.ts` itself is not ported.

// type GoogleApiType = "google-generative-ai" | "google-vertex": Swift `Model.api` is a string.

/// Thinking level for Gemini 3 models.
/// Mirrors Google's ThinkingLevel enum values.
public enum GoogleApiThinkingLevel: String, Sendable, Hashable {
    case THINKING_LEVEL_UNSPECIFIED, MINIMAL, LOW, MEDIUM, HIGH
}

/// `Exclude<ThinkingLevel, "xhigh" | "max">`.
public enum ResolvedGoogleThinkingLevel: String, Sendable, Hashable {
    case minimal, low, medium, high
}

/// `@google/genai` `ThinkingLevel` enum (string values).
public typealias GoogleSdkThinkingLevel = String

private let GOOGLE_SDK_THINKING_LEVEL_MAP: [GoogleApiThinkingLevel: GoogleSdkThinkingLevel] = [
    .THINKING_LEVEL_UNSPECIFIED: "THINKING_LEVEL_UNSPECIFIED",
    .MINIMAL: "MINIMAL",
    .LOW: "LOW",
    .MEDIUM: "MEDIUM",
    .HIGH: "HIGH",
]

/// Resolve a supported pi level or model-specific Google mapping to a standard Google level.
public func resolveGoogleThinkingLevel(_ model: Model, _ level: ThinkingLevel) throws -> ResolvedGoogleThinkingLevel {
    let mapped = model.thinkingLevelMap?[ModelThinkingLevel(level)]
    let resolvedLevel: String
    if case .some(.some(let value)) = mapped {
        resolvedLevel = value.lowercased()
    } else {
        resolvedLevel = level.rawValue
    }
    switch resolvedLevel {
    case "minimal", "low", "medium", "high":
        return ResolvedGoogleThinkingLevel(rawValue: resolvedLevel)!
    default:
        // `String(mapped)`: a missing key is undefined, an explicit null is null.
        let mappedText: String
        switch mapped {
        case .none: mappedText = "undefined"
        case .some(.none): mappedText = "null"
        case .some(.some(let value)): mappedText = value
        }
        throw PiError(
            "Unsupported Google thinking level mapping for \(model.provider)/\(model.id): \(level.rawValue) -> \(mappedText)"
        )
    }
}

/// Whether this model uses Gemini's discrete `thinkingLevel` control instead of
/// the token-based `thinkingBudget` control. Supported levels come from the
/// model's `thinkingLevelMap`; this only selects the Google wire format.
public func usesGoogleThinkingLevel(_ model: Model) -> Bool {
    let id = model.id.lowercased()
    return (
        // Match Gemini 3 Pro/Flash IDs with or without a minor version, such as
        // gemini-3-flash-preview, gemini-3.1-pro-preview, and gemini-3.8-flash.
        id.contains(/gemini-3(?:\.[0-9]+)?-(?:pro|flash)/) ||
        // Match Gemini 4 and later, such as gemini-4-argon (#10890).
        id.contains(/gemini-(?:[4-9]|[1-9][0-9])/) ||
        id == "gemini-flash-latest" ||
        id == "gemini-flash-lite-latest" ||
        // Match both hosted Gemma 4 naming forms: gemma-4-* and gemma4-*.
        id.contains(/gemma-?4/)
    )
}

public func toGoogleThinkingLevel(_ level: ResolvedGoogleThinkingLevel) -> GoogleApiThinkingLevel {
    switch level {
    case .minimal:
        return .MINIMAL
    case .low:
        return .LOW
    case .medium:
        return .MEDIUM
    case .high:
        return .HIGH
    }
}

public func toGoogleSdkThinkingLevel(_ level: GoogleApiThinkingLevel) -> GoogleSdkThinkingLevel {
    GOOGLE_SDK_THINKING_LEVEL_MAP[level]!
}

/// Returns a `ThinkingConfig`.
public func getDisabledGoogleThinkingConfig(_ model: Model) throws -> JsonObject {
    if !usesGoogleThinkingLevel(model) { return ["thinkingBudget": 0] }

    let fallback = clampThinkingLevel(model, .off)
    guard let fallbackLevel = fallback.thinkingLevel else { return ["thinkingBudget": 0] }

    let resolvedLevel = try resolveGoogleThinkingLevel(model, fallbackLevel)
    let apiLevel = toGoogleThinkingLevel(resolvedLevel)
    return ["thinkingLevel": .string(toGoogleSdkThinkingLevel(apiLevel))]
}

/// Determines whether a streamed Gemini `Part` should be treated as "thinking".
///
/// Protocol note (Gemini / Vertex AI thought signatures):
/// - `thought: true` is the definitive marker for thinking content (thought summaries).
/// - `thoughtSignature` is an encrypted representation of the model's internal thought process
///   used to preserve reasoning context across multi-turn interactions.
/// - `thoughtSignature` can appear on ANY part type (text, functionCall, etc.) - it does NOT
///   indicate the part itself is thinking content.
/// - For non-functionCall responses, the signature appears on the last part for context replay.
/// - When persisting/replaying model outputs, signature-bearing parts must be preserved as-is;
///   do not merge/move signatures across parts.
///
/// See: https://ai.google.dev/gemini-api/docs/thought-signatures
///
/// Swift: `part` is the JSON `Part` (only `thought` / `thoughtSignature` are read).
public func isThinkingPart(_ part: JsonValue) -> Bool {
    part["thought"] == .bool(true)
}

/// Retain thought signatures during streaming.
///
/// Some backends only send `thoughtSignature` on the first delta for a given part/block; later deltas may omit it.
/// This helper preserves the last non-empty signature for the current block.
///
/// Note: this does NOT merge or move signatures across distinct response parts. It only prevents
/// a signature from being overwritten with `undefined` within the same streamed block.
public func retainThoughtSignature(_ existing: String?, _ incoming: String?) -> String? {
    if let incoming, !incoming.isEmpty { return incoming }
    return existing
}

// Thought signatures must be base64 for Google APIs (TYPE_BYTES).
// const base64SignaturePattern = /^[A-Za-z0-9+/]+={0,2}$/;
private func matchesBase64SignaturePattern(_ signature: String) -> Bool {
    let units = Array(signature.utf16)
    var end = units.count
    var padding = 0
    while end > 0 && units[end - 1] == 0x3D /* = */ && padding < 2 {
        end -= 1
        padding += 1
    }
    if end == 0 { return false }
    for unit in units[0..<end] {
        let isBase64 =
            (unit >= 0x41 && unit <= 0x5A) || (unit >= 0x61 && unit <= 0x7A) || (unit >= 0x30 && unit <= 0x39) ||
            unit == 0x2B /* + */ || unit == 0x2F /* / */
        if !isBase64 { return false }
    }
    return true
}

private func isValidThoughtSignature(_ signature: String?) -> Bool {
    guard let signature, !signature.isEmpty else { return false }
    if signature.utf16.count % 4 != 0 { return false }
    return matchesBase64SignaturePattern(signature)
}

/// Only keep signatures from the same provider/model and with valid base64.
private func resolveThoughtSignature(_ isSameProviderAndModel: Bool, _ signature: String?) -> String? {
    isSameProviderAndModel && isValidThoughtSignature(signature) ? signature : nil
}

/// Models via Google APIs that require explicit tool call IDs in function calls/responses.
public func requiresToolCallId(_ modelId: String) -> Bool {
    let geminiMajorVersion = getGeminiMajorVersion(modelId)
    return (
        modelId.hasPrefix("claude-") ||
        modelId.hasPrefix("gpt-oss-") ||
        (geminiMajorVersion != nil && geminiMajorVersion! >= 3)
    )
}

/// `modelId.toLowerCase().match(/^gemini(?:-live)?-(\d+)/)` -> `Number.parseInt(match[1], 10)`.
private func getGeminiMajorVersion(_ modelId: String) -> Int? {
    let id = Array(modelId.lowercased().utf8)
    func digits(after prefix: String) -> Int? {
        let prefixBytes = Array(prefix.utf8)
        guard id.count > prefixBytes.count, Array(id[0..<prefixBytes.count]) == prefixBytes else { return nil }
        var value = 0
        var count = 0
        for byte in id[prefixBytes.count...] {
            guard byte >= 0x30 && byte <= 0x39 else { break }
            let (multiplied, overflow1) = value.multipliedReportingOverflow(by: 10)
            let (added, overflow2) = multiplied.addingReportingOverflow(Int(byte - 0x30))
            value = overflow1 || overflow2 ? Int.max : added
            count += 1
        }
        return count > 0 ? value : nil
    }
    return digits(after: "gemini-live-") ?? digits(after: "gemini-")
}

private func supportsMultimodalFunctionResponse(_ modelId: String) -> Bool {
    let geminiMajorVersion = getGeminiMajorVersion(modelId)
    if let geminiMajorVersion {
        return geminiMajorVersion >= 3
    }
    return true
}

/// `id.replace(/[^a-zA-Z0-9_-]/g, "_").slice(0, 64)` over UTF-16 code units.
private func sanitizeGoogleToolCallId(_ id: String) -> String {
    var result = ""
    for unit in id.utf16.prefix(64) {
        let keep =
            (unit >= 0x41 && unit <= 0x5A) || (unit >= 0x61 && unit <= 0x7A) || (unit >= 0x30 && unit <= 0x39) ||
            unit == 0x5F /* _ */ || unit == 0x2D /* - */
        result.unicodeScalars.append(keep ? Unicode.Scalar(UInt8(unit)) : "_")
    }
    return result
}

/// Convert internal messages to Gemini Content[] format.
///
/// Swift: upstream `convertMessages` (renamed; see the file header). Returns `Content` JSON values.
public func convertMessagesGoogle(_ model: Model, _ context: TranscriptContext) -> [JsonValue] {
    // Gemini has no mid-conversation system messages; the leading prompt is sent as systemInstruction.
    let conversation = withoutInitialSystemMessage(collapseSystemMessages(context).messages)
    var contents: [JsonObject] = []
    let normalizeToolCallId: (String, Model, AssistantMessage) -> String = { id, _, _ in
        if !requiresToolCallId(model.id) { return id }
        return sanitizeGoogleToolCallId(id)
    }

    let transformedMessages = transformMessages(conversation, model, normalizeToolCallId)

    for msg in transformedMessages {
        switch msg {
        case .user(let user):
            switch user.content {
            case .string(let text):
                contents.append([
                    "role": "user",
                    "parts": [["text": .string(sanitizeSurrogates(text))]],
                ])
            case .blocks(let blocks):
                let parts: [JsonValue] = blocks.map { item in
                    switch item {
                    case .text(let text):
                        return ["text": .string(sanitizeSurrogates(text.text))]
                    case .image(let image):
                        return [
                            "inlineData": [
                                "mimeType": .string(image.mimeType),
                                "data": .string(image.data),
                            ],
                        ]
                    }
                }
                if parts.isEmpty { continue }
                contents.append([
                    "role": "user",
                    "parts": .array(parts),
                ])
            }
        case .assistant(let assistant):
            var parts: [JsonValue] = []
            // Check if message is from same provider and model - only then keep thinking blocks
            let isSameProviderAndModel = assistant.provider == model.provider && assistant.model == model.id

            for block in assistant.content {
                switch block {
                case .text(let text):
                    let thoughtSignature = resolveThoughtSignature(isSameProviderAndModel, text.textSignature)
                    // Skip empty text blocks — unless they carry a thought signature. Gemini can attach
                    // the signature to a part whose visible text is empty and requires it echoed back;
                    // dropping it breaks the reasoning chain and the model intermittently ends mid-task
                    // turns with a thought-only STOP (empty completion, no tool call).
                    if (text.text.isEmpty || jsTrim(text.text).isEmpty) && thoughtSignature == nil { continue }
                    var part: JsonObject = ["text": .string(sanitizeSurrogates(text.text))]
                    if let thoughtSignature { part["thoughtSignature"] = .string(thoughtSignature) }
                    parts.append(.object(part))
                case .thinking(let thinking):
                    // Only keep as thinking block if same provider AND same model
                    // Otherwise convert to plain text (no tags to avoid model mimicking them)
                    if isSameProviderAndModel {
                        let thoughtSignature = resolveThoughtSignature(isSameProviderAndModel, thinking.thinkingSignature)
                        // Same rule as text blocks: an empty thinking block is dropped only when it
                        // carries no signature (mirrors the anthropic converter's handling).
                        if (thinking.thinking.isEmpty || jsTrim(thinking.thinking).isEmpty) && thoughtSignature == nil { continue }
                        var part: JsonObject = [
                            "thought": true,
                            "text": .string(sanitizeSurrogates(thinking.thinking)),
                        ]
                        if let thoughtSignature { part["thoughtSignature"] = .string(thoughtSignature) }
                        parts.append(.object(part))
                    } else {
                        // Cross-provider/model: the signature is unusable, empty blocks stay dropped.
                        if thinking.thinking.isEmpty || jsTrim(thinking.thinking).isEmpty { continue }
                        parts.append([
                            "text": .string(sanitizeSurrogates(thinking.thinking)),
                        ])
                    }
                case .toolCall(let toolCall):
                    let thoughtSignature = resolveThoughtSignature(isSameProviderAndModel, toolCall.thoughtSignature)
                    var functionCall: JsonObject = [
                        "name": .string(toolCall.name),
                        "args": .object(toolCall.arguments),
                    ]
                    if requiresToolCallId(model.id) { functionCall["id"] = .string(toolCall.id) }
                    var part: JsonObject = ["functionCall": .object(functionCall)]
                    if let thoughtSignature { part["thoughtSignature"] = .string(thoughtSignature) }
                    parts.append(.object(part))
                }
            }

            if parts.isEmpty { continue }
            contents.append([
                "role": "model",
                "parts": .array(parts),
            ])
        case .toolResult(let toolResult):
            // Extract text and image content
            let textContent = toolResult.content.compactMap(\.textContent)
            let textResult = textContent.map(\.text).joined(separator: "\n")
            let imageContent = model.input.contains("image")
                ? toolResult.content.compactMap(\.imageContent)
                : []

            let hasText = !jsTrim(textResult).isEmpty
            let hasImages = !imageContent.isEmpty

            // Gemini 3+ models support multimodal function responses with images nested inside
            // functionResponse.parts. Claude and other non-Gemini models behind Cloud Code Assist /
            // Gemini < 3 still needs a separate user image turn.
            let modelSupportsMultimodalFunctionResponse = supportsMultimodalFunctionResponse(model.id)

            // Use "output" key for success, "error" key for errors as per SDK documentation
            let responseValue = hasText ? sanitizeSurrogates(textResult) : hasImages ? "(see attached image)" : ""

            let imageParts: [JsonValue] = imageContent.map { imageBlock in
                [
                    "inlineData": [
                        "mimeType": .string(imageBlock.mimeType),
                        "data": .string(imageBlock.data),
                    ],
                ]
            }

            let includeId = requiresToolCallId(model.id)
            var functionResponse: JsonObject = [
                "name": .string(toolResult.toolName),
                "response": toolResult.isError ? ["error": .string(responseValue)] : ["output": .string(responseValue)],
            ]
            if hasImages && modelSupportsMultimodalFunctionResponse { functionResponse["parts"] = .array(imageParts) }
            if includeId { functionResponse["id"] = .string(toolResult.toolCallId) }
            let functionResponsePart: JsonValue = ["functionResponse": .object(functionResponse)]

            // Cloud Code Assist API requires all function responses to be in a single user turn.
            // Check if the last content is already a user turn with function responses and merge.
            if var lastContent = contents.last,
               lastContent["role"] == "user",
               case .array(var lastParts)? = lastContent["parts"],
               lastParts.contains(where: { $0["functionResponse"].map(jsTruthy) ?? false }) {
                lastParts.append(functionResponsePart)
                lastContent["parts"] = .array(lastParts)
                contents[contents.count - 1] = lastContent
            } else {
                contents.append([
                    "role": "user",
                    "parts": [functionResponsePart],
                ])
            }

            // For Gemini < 3, add images in a separate user message
            if hasImages && !modelSupportsMultimodalFunctionResponse {
                contents.append([
                    "role": "user",
                    "parts": .array([["text": "Tool result image:"]] + imageParts),
                ])
            }
        case .system:
            // Mid-conversation system messages were collapsed above; nothing to send.
            continue
        }
    }

    return contents.map { .object($0) }
}

private let JSON_SCHEMA_META_DECLARATIONS: Set<String> = [
    "$schema",
    "$id",
    "$anchor",
    "$dynamicAnchor",
    "$vocabulary",
    "$comment",
    "$defs",
    "definitions", // pre-draft-2019-09 equivalent of $defs
]

/// Strip meta-declarations from a schema obj
private func sanitizeForOpenApi(_ schema: JsonValue) -> JsonValue {
    guard case .object(let object) = schema else {
        return schema
    }

    var result = JsonObject()
    for (key, value) in object {
        if JSON_SCHEMA_META_DECLARATIONS.contains(key) { continue }
        result[key] = sanitizeForOpenApi(value)
    }
    return .object(result)
}

/// Schema keywords whose values map names to subschemas, so their keys are not schema keywords.
private let JSON_SCHEMA_NAME_MAPS: Set<String> = [
    "properties",
    "patternProperties",
    "$defs",
    "definitions",
    "dependentSchemas",
    "dependencies",
]

/// Keywords containing a subschema or an array of subschemas, not literal data.
private let JSON_SCHEMA_SUBSCHEMAS: Set<String> = [
    "additionalProperties",
    "unevaluatedProperties",
    "propertyNames",
    "items",
    "prefixItems",
    "additionalItems",
    "unevaluatedItems",
    "contains",
    "allOf",
    "anyOf",
    "oneOf",
    "not",
    "if",
    "then",
    "else",
    "contentSchema",
]

/// Rewrite string and number `const` values to single-value `enum`s.
/// Gemini ignores `const` in `parametersJsonSchema` but honors `enum`.
func rewriteConstAsEnum(_ schema: JsonValue, _ isNameMap: Bool = false) -> JsonValue {
    if case .array(let items) = schema { return .array(items.map { rewriteConstAsEnum($0) }) }
    guard case .object(let object) = schema else { return schema }

    var result = JsonObject()
    for (key, value) in object {
        if isNameMap || JSON_SCHEMA_SUBSCHEMAS.contains(key) {
            result[key] = rewriteConstAsEnum(value)
        } else if JSON_SCHEMA_NAME_MAPS.contains(key) {
            result[key] = rewriteConstAsEnum(value, true)
        } else {
            result[key] = value
        }
    }
    if !isNameMap, let value = result["const"], result["enum"] == nil {
        switch value {
        case .string, .number:
            result["const"] = nil
            result["enum"] = .array([value])
        default:
            break
        }
    }
    return .object(result)
}

/// Convert tools to Gemini function declarations format.
///
/// By default uses `parametersJsonSchema` which supports full JSON Schema (including
/// anyOf, oneOf, etc.). Gemini ignores `const` there, so string and number `const`
/// values are sent as single-value `enum`s. Set `useParameters` to true to use the legacy `parameters`
/// field instead (OpenAPI 3.03 Schema). This is needed for Cloud Code Assist with Claude
/// models, where the API translates `parameters` into Anthropic's `input_schema`.
///
/// Swift: upstream `convertTools` (renamed; see the file header).
public func convertToolsGoogle(
    _ tools: [Tool],
    _ useParameters: Bool = false,
    _ supportsStrictMode: Bool = true
) throws -> [JsonValue]? {
    if tools.isEmpty { return nil }
    return [
        [
            "functionDeclarations": .array(try tools.map { tool -> JsonValue in
                let strict = try resolveJsonSchemaStrictSampling(tool, supportsStrictMode)
                let parameters = try getJsonSchemaToolParameters(tool, strict)
                var declaration: JsonObject = [
                    "name": .string(tool.name),
                    "description": .string(tool.description),
                ]
                if useParameters {
                    declaration["parameters"] = sanitizeForOpenApi(parameters)
                } else {
                    declaration["parametersJsonSchema"] = rewriteConstAsEnum(parameters)
                }
                return .object(declaration)
            }),
        ],
    ]
}

/// Gemini 3+ enforces required function parameters in validated tool-calling modes.
public func supportsGoogleStrictToolSampling(_ modelId: String) -> Bool {
    let majorVersion = getGeminiMajorVersion(modelId)
    return majorVersion != nil && majorVersion! >= 3
}

/// `@google/genai` `FunctionCallingConfigMode` enum (string values).
public typealias FunctionCallingConfigMode = String

/// Map tool choice string to Gemini FunctionCallingConfigMode.
///
/// Swift: upstream `mapToolChoice` (renamed; see the file header).
public func mapToolChoiceGoogle(_ choice: String) -> FunctionCallingConfigMode {
    switch choice {
    case "auto":
        return "AUTO"
    case "none":
        return "NONE"
    case "any":
        return "ANY"
    default:
        return "AUTO"
    }
}

public func resolveGoogleFunctionCallingMode(
    _ tools: [Tool],
    _ toolChoice: String?,
    _ supportsStrictMode: Bool
) throws -> FunctionCallingConfigMode? {
    var useStrictMode = false
    for tool in tools where try resolveJsonSchemaStrictSampling(tool, supportsStrictMode) == true {
        useStrictMode = true
        break
    }
    if toolChoice == "none" || toolChoice == "any" {
        return mapToolChoiceGoogle(toolChoice!)
    }
    if useStrictMode {
        return "VALIDATED"
    }
    if let toolChoice, !toolChoice.isEmpty { return mapToolChoiceGoogle(toolChoice) }
    return nil
}

/// `@google/genai` `FinishReason` enum (string values).
public typealias FinishReason = String

/// Map Gemini FinishReason to our StopReason.
///
/// Swift: upstream `mapStopReason` (renamed; see the file header). A value outside the SDK enum reaches
/// upstream's exhaustive `default` and throws, as it does at runtime upstream.
public func mapStopReasonGoogle(_ reason: FinishReason) throws -> StopReason {
    switch reason {
    case "STOP":
        return .stop
    case "MAX_TOKENS":
        return .length
    case "BLOCKLIST",
         "PROHIBITED_CONTENT",
         "SPII",
         "SAFETY",
         "IMAGE_SAFETY",
         "IMAGE_PROHIBITED_CONTENT",
         "IMAGE_RECITATION",
         "IMAGE_OTHER",
         "RECITATION",
         "FINISH_REASON_UNSPECIFIED",
         "OTHER",
         "LANGUAGE",
         "MALFORMED_FUNCTION_CALL",
         "UNEXPECTED_TOOL_CALL",
         "TOO_MANY_TOOL_CALLS",
         "NO_IMAGE":
        return .error
    default:
        throw PiError("Unhandled stop reason: \(reason)")
    }
}

/// Map string finish reason to our StopReason (for raw API responses).
///
/// Swift: upstream `mapStopReasonString` (renamed; see the file header).
public func mapStopReasonStringGoogle(_ reason: String) -> StopReason {
    switch reason {
    case "STOP":
        return .stop
    case "MAX_TOKENS":
        return .length
    default:
        return .error
    }
}

/// Run a Google GenAI SDK request with the shared provider retry policy
/// (408/409/429/5xx with backoff, honoring retry-after), mirroring how the
/// Anthropic and OpenAI adapters wrap their initial request in
/// retryProviderRequest. The SDK's ApiError has a `status` property but no
/// `headers` property, and retryProviderRequest only retries errors that carry
/// both, so normalize the error by adding the missing `headers` before
/// rethrowing.
///
/// Swift: `GoogleGenAI.ApiError` conforms to `ProviderError` with `headers == nil`, which is the normalized
/// shape, so errors pass through unchanged.
public func retryGoogleRequest<T: Sendable>(
    _ request: @escaping @Sendable () async throws -> T,
    _ options: StreamOptions? = nil
) async throws -> T {
    try await retryProviderRequest(
        {
            do {
                return try await request()
            } catch {
                // `(error as { headers?: Headers }).headers = undefined` — already the Swift shape.
                throw error
            }
        },
        ProviderRetryOptions(
            maxRetries: options?.maxRetries,
            maxRetryDelayMs: options?.maxRetryDelayMs,
            signal: options?.signal
        )
    )
}
