import Foundation

// Port of utils/error-body.ts
//
// Shared normalization for provider HTTP error objects.
//
// Endpoints behind a proxy / gateway may return a non-2xx response whose body
// the provider SDK cannot fold into `error.message`. The SDK error object still
// carries the HTTP status and the raw/parsed body, but under SDK-specific field
// names. Provider catch blocks that read only `error.message` therefore drop
// the body and surface opaque messages like `"403 status code (no body)"` or
// collapse to `"Unknown: UnknownError"`.
//
// `normalizeProviderError` probes the known SDK field shapes (Mistral,
// `openai`, `@google/genai`, AWS Bedrock) and returns a struct each provider
// composes into its display string. The `messageCarriesBody` flag captures the
// Anthropic / `@google/genai` happy path where the SDK already folded the body
// into the message, so providers can preserve it without double-printing.

public let MAX_PROVIDER_ERROR_BODY_CHARS = 4000

public struct NormalizedProviderError: Sendable, Hashable {
    /// HTTP status code, when one could be extracted from the SDK error object.
    public var status: Double?
    /// Raw HTTP body reason, already trimmed and truncated to the cap.
    public var body: String?
    /// `error.message`, or `safeJsonStringify(error)` for a non-`Error` throw.
    public var message: String
    /// True when `message` already contains the body (no separate body to add).
    public var messageCarriesBody: Bool
    public init(status: Double? = nil, body: String? = nil, message: String, messageCarriesBody: Bool) {
        self.status = status; self.body = body; self.message = message; self.messageCarriesBody = messageCarriesBody
    }
}

/// Swift: an untyped SDK error field (`unknown` upstream).
public enum SdkErrorField: Sendable, Hashable {
    /// Plain parsed data: a string, a number, or a plain JSON object/array.
    case value(JsonValue)
    /// An object with a `pipe()` method (a Node response stream).
    case stream
    /// A class instance (an SDK response wrapper), never a parsed body.
    case instance
}

/// `Error & { statusCode?, status?, body?, error?, $metadata?: { httpStatusCode? }, $response?: { statusCode?, body? } }`.
/// Every field defaults to absent.
public protocol SdkErrorShape: Error {
    var statusCode: JsonValue? { get }
    var status: JsonValue? { get }
    var body: SdkErrorField? { get }
    var error: SdkErrorField? { get }
    /// `$metadata.httpStatusCode`
    var metadataHttpStatusCode: JsonValue? { get }
    /// `$response.statusCode`
    var responseStatusCode: JsonValue? { get }
    /// `$response.body`
    var responseBody: SdkErrorField? { get }
}

extension SdkErrorShape {
    public var statusCode: JsonValue? { nil }
    public var status: JsonValue? { nil }
    public var body: SdkErrorField? { nil }
    public var error: SdkErrorField? { nil }
    public var metadataHttpStatusCode: JsonValue? { nil }
    public var responseStatusCode: JsonValue? { nil }
    public var responseBody: SdkErrorField? { nil }
}

/// A generic SDK error carrying any of the probed fields (`Object.assign(new Error(message), {...})`).
public struct ProviderSdkError: SdkErrorShape, CustomStringConvertible, LocalizedError, Sendable {
    public var name: String
    public var message: String
    public var statusCode: JsonValue?
    public var status: JsonValue?
    public var body: SdkErrorField?
    public var error: SdkErrorField?
    public var metadataHttpStatusCode: JsonValue?
    public var responseStatusCode: JsonValue?
    public var responseBody: SdkErrorField?
    public init(_ message: String, name: String = "Error", statusCode: JsonValue? = nil, status: JsonValue? = nil, body: SdkErrorField? = nil, error: SdkErrorField? = nil,
                metadataHttpStatusCode: JsonValue? = nil, responseStatusCode: JsonValue? = nil, responseBody: SdkErrorField? = nil) {
        self.message = message; self.name = name; self.statusCode = statusCode; self.status = status; self.body = body; self.error = error
        self.metadataHttpStatusCode = metadataHttpStatusCode; self.responseStatusCode = responseStatusCode; self.responseBody = responseBody
    }
    public var description: String { message }
    public var errorDescription: String? { message }
}

/// Swift: SDK error classes whose upstream fields (`status`, `error`) collide with differently typed
/// Swift properties expose their `SdkErrorShape` view through this protocol.
public protocol SdkErrorShapeConvertible: Error {
    var sdkErrorShape: any SdkErrorShape { get }
}

public func normalizeProviderError(_ error: any Error) -> NormalizedProviderError {
    let message = errorMessage(error)
    guard let sdkError = (error as? any SdkErrorShapeConvertible)?.sdkErrorShape ?? (error as? any SdkErrorShape) else {
        return NormalizedProviderError(status: nil, body: nil, message: message, messageCarriesBody: true)
    }
    let status = extractStatus(sdkError)
    let body = extractBody(sdkError)
    let messageCarriesBody = body == nil || message.contains(body!)

    return NormalizedProviderError(status: status, body: body, message: message, messageCarriesBody: messageCarriesBody)
}

/// Non-`Error` thrown value (`throw { ... }` upstream).
public func normalizeProviderError(nonError value: JsonValue?) -> NormalizedProviderError {
    NormalizedProviderError(message: safeJsonStringify(value), messageCarriesBody: false)
}

/// Probe the HTTP status, first numeric hit wins, in SDK-field order:
/// `statusCode` (Mistral) → `status` (`openai`, `@google/genai`) →
/// `$metadata.httpStatusCode` (Bedrock) → `$response.statusCode` (Bedrock).
private func extractStatus(_ error: any SdkErrorShape) -> Double? {
    if case .number(let v) = error.statusCode { return v }
    if case .number(let v) = error.status { return v }
    if case .number(let v) = error.metadataHttpStatusCode { return v }
    if case .number(let v) = error.responseStatusCode { return v }
    return nil
}

/// Probe the raw body reason, first usable hit wins, in SDK-field order:
/// `body` string (Mistral) → `error` parsed JSON body object (`openai` SDK's
/// `this.error`) → `$response.body` (Bedrock). Empty objects and unread response
/// streams are treated as no body so they do not surface as `"{}"` or serialized
/// stream internals. The chosen body is truncated to the cap.
private func extractBody(_ error: any SdkErrorShape) -> String? {
    guard let bodyText = pickBodyText(error) else { return nil }
    let trimmed = jsTrim(bodyText)
    if trimmed.isEmpty { return nil }
    return truncateErrorText(trimmed, MAX_PROVIDER_ERROR_BODY_CHARS)
}

private func pickBodyText(_ error: any SdkErrorShape) -> String? {
    if case .value(.string(let s)) = error.body { return s }
    if isPlainNonEmptyObject(error.error), case .value(let v) = error.error { return safeJsonStringify(v) }
    let responseBody = error.responseBody
    if case .value(.string(let s)) = responseBody { return s }
    if isReadableStreamLike(responseBody) { return nil }
    if isPlainNonEmptyObject(responseBody), case .value(let v) = responseBody { return safeJsonStringify(v) }
    return nil
}

private func isReadableStreamLike(_ value: SdkErrorField?) -> Bool {
    if case .stream = value { return true }
    return false
}

/// Only a PLAIN object counts as an HTTP body. SDK error fields can hold class
/// instances instead of parsed bodies — AWS SDK v3's `$response.body` is an
/// HTTP stream/response wrapper object, and stringifying one produced garbage
/// like `{"_events":...}` as the "body", which then REPLACED `error.message`
/// in the composed display string. `error.message` is where the SDK puts the
/// real deserialized exception text ("Input is too long...", schema validation
/// details, ...), so the one useful string was discarded for noise. A class
/// instance yields no body, `messageCarriesBody` stays true, and the real
/// message survives. Complements the `pipe` sniffing above: web
/// ReadableStreams (pipeTo/pipeThrough, no `pipe`) and non-stream SDK wrapper
/// classes fail the prototype check, while parsed JSON bodies (plain objects
/// by construction) still pass.
private func isPlainNonEmptyObject(_ value: SdkErrorField?) -> Bool {
    guard case .value(.object(let object)) = value else { return false }
    return object.count > 0
}

/// Compose a display string from a normalized error. When the message already
/// carries the body (Anthropic / `@google/genai` happy path) or no body/status
/// was extracted, the message is returned unchanged. Otherwise the status and
/// body are surfaced, with an optional provider prefix.
///
/// - no prefix: `"<status>: <body>"`
/// - prefix:    `"<prefix> (<status>): <body>"`
public func formatProviderError(_ norm: NormalizedProviderError, _ prefix: String? = nil) -> String {
    if norm.messageCarriesBody || norm.status == nil || norm.body == nil {
        if let prefix, let status = norm.status {
            return "\(prefix) (\(JsonWriter.formatNumber(status))): \(norm.message)"
        }
        return norm.message
    }
    let status = JsonWriter.formatNumber(norm.status!)
    return prefix != nil ? "\(prefix!) (\(status)): \(norm.body!)" : "\(status): \(norm.body!)"
}

public func truncateErrorText(_ text: String, _ maxChars: Int) -> String {
    let length = text.utf16.count
    if length <= maxChars { return text }
    return "\(jsSlice(text, 0, maxChars))... [truncated \(length - maxChars) chars]"
}

/// `JSON.stringify(value)`, or `String(value)` when it yields undefined (nil -> "undefined").
public func safeJsonStringify(_ value: JsonValue?) -> String {
    guard let value else { return "undefined" }
    return value.serialized()
}

// MARK: - JS string helpers (UTF-16 semantics)

/// `text.slice(start, end)` over UTF-16 code units.
func jsSlice(_ text: String, _ start: Int, _ end: Int? = nil) -> String {
    let units = text.utf16
    let length = units.count
    func clamp(_ value: Int) -> Int { value < 0 ? max(0, length + value) : min(value, length) }
    let from = clamp(start)
    let to = clamp(end ?? length)
    if from >= to { return "" }
    let a = units.index(units.startIndex, offsetBy: from)
    let b = units.index(units.startIndex, offsetBy: to)
    return String(decoding: Array(units[a..<b]), as: UTF16.self)
}

/// `String.prototype.trim()` (ECMAScript whitespace and line terminators).
func jsTrim(_ text: String) -> String {
    let scalars = text.unicodeScalars
    guard let first = scalars.firstIndex(where: { !isJsWhitespace($0) }) else { return "" }
    let last = scalars.lastIndex(where: { !isJsWhitespace($0) })!
    return String(scalars[first...last])
}

func isJsWhitespace(_ scalar: Unicode.Scalar) -> Bool {
    switch scalar.value {
    case 0x09, 0x0A, 0x0B, 0x0C, 0x0D, 0x20, 0xA0, 0x1680, 0x2000...0x200A, 0x2028, 0x2029, 0x202F, 0x205F, 0x3000, 0xFEFF:
        return true
    default:
        return false
    }
}
