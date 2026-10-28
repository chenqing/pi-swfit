import Foundation

// Shared Stainless runtime used by the OpenAI (openai 7.19.0) and Anthropic (@anthropic-ai/sdk 0.129.0)
// SDK ports: `internal/headers.ts`, `internal/utils/env.ts`, `internal/utils/values.ts`,
// `internal/detect-platform.ts`, `internal/errors.ts`, `internal/decoders/line.ts` and the SSE
// decoding half of `core/streaming.ts`. Both SDKs ship near-identical copies; differences are noted
// where they occur. Swift-only infrastructure: no upstream pi file corresponds to this one.

// MARK: - internal/headers.ts

/// Headers built by `buildHeaders`: the parsed values plus the lowercase names explicitly set to null.
public struct NullableHeaders: Sendable {
    /// Parsed headers.
    public var values: Headers
    /// Set of lowercase header names explicitly set to null (insertion-ordered set).
    public var nulls: [String]

    public init(values: Headers = Headers(), nulls: [String] = []) {
        self.values = values
        self.nulls = nulls
    }
}

/// `HeadersLike`: a plain object (`Record<string, string | null | undefined>`), a `Headers` instance,
/// or `NullableHeaders`. Record entries whose value is `undefined` are simply not listed; a `nil`
/// value is an explicit `null` (removes the header). Array-valued record entries: Not ported (unused by pi).
public enum HeadersLike: Sendable {
    case record([(String, String?)])
    case headers(Headers)
    case nullable(NullableHeaders)

    /// Convenience for a record without null values.
    public static func values(_ pairs: [(String, String)]) -> HeadersLike {
        .record(pairs.map { ($0.0, Optional($0.1)) })
    }
}

/// One header row produced by `iterateHeaders`.
enum HeaderRowValue {
    case value(String)
    case null
    /// Anthropic: the synthetic clear-before-set yielded for object keys (`clearSentinel`).
    /// OpenAI yields a plain `null` there instead.
    case clear
}

private let httpTokenHeaderName = try! NSRegularExpression(pattern: "^[!#$%&'*+\\-.^_`|~0-9A-Za-z]+$")

private func isHttpToken(_ name: String) -> Bool {
    httpTokenHeaderName.firstMatch(in: name, range: NSRange(name.startIndex..., in: name)) != nil
}

/// `iterateHeaders(headers)`. `clearSentinel` selects the Anthropic behavior (yield `.clear` instead of `null`).
func iterateHeaders(_ headers: HeadersLike?, clearSentinel: Bool) -> [(String, HeaderRowValue)] {
    guard let headers else { return [] }
    var rows: [(String, HeaderRowValue)] = []
    switch headers {
    case .nullable(let nullable):
        for (name, value) in nullable.values.entries { rows.append((name, .value(value))) }
        for name in nullable.nulls { rows.append((name, .null)) }
        return rows
    case .headers(let values):
        // Web `Headers` iterate without the clear-before-set step.
        for (name, value) in values.entries { rows.append((name, .value(value))) }
        return rows
    case .record(let entries):
        // Objects keys always overwrite older headers, they never append.
        // Yield a null to clear the header before adding the new values.
        for (name, value) in entries {
            rows.append((name, clearSentinel ? .clear : .null))
            if let value { rows.append((name, .value(value))) } else { rows.append((name, .null)) }
        }
        return rows
    }
}

/// OpenAI `buildHeaders(newHeaders)`.
func buildHeaders(_ newHeaders: [HeadersLike?]) throws -> NullableHeaders {
    var targetHeaders = Headers()
    var nullHeaders: [String] = []
    for headers in newHeaders {
        var seenHeaders = Set<String>()
        for (name, value) in iterateHeaders(headers, clearSentinel: false) {
            if !isHttpToken(name) {
                throw PiError("Header name must be a valid HTTP token [\"\(name)\"]", name: "TypeError")
            }
            let lowerName = name.lowercased()
            if !seenHeaders.contains(lowerName) {
                targetHeaders.delete(lowerName)
                seenHeaders.insert(lowerName)
            }
            switch value {
            case .value(let value):
                targetHeaders.append(lowerName, value)
                nullHeaders.removeAll { $0 == lowerName }
            case .null, .clear:
                targetHeaders.delete(lowerName)
                if !nullHeaders.contains(lowerName) { nullHeaders.append(lowerName) }
            }
        }
    }
    return NullableHeaders(values: targetHeaders, nulls: nullHeaders)
}

/// Anthropic: headers whose values accumulate across `buildHeaders` sources instead of the later
/// source's value replacing the earlier one. Values are comma-appended (deduplicated, order-preserving)
/// into a single header line.
let APPEND_HEADERS: Set<String> = ["x-stainless-helper"]

/// Anthropic `appendHeaderValue(existing, addition)`.
func appendHeaderValue(_ existing: String?, _ addition: String) -> String {
    var tokens = existing.map { $0.split(separator: ",", omittingEmptySubsequences: false).map { jsTrim(String($0)) }.filter { !$0.isEmpty } } ?? []
    for tok in addition.split(separator: ",", omittingEmptySubsequences: false).map({ jsTrim(String($0)) }) {
        if !tok.isEmpty && !tokens.contains(tok) { tokens.append(tok) }
    }
    return tokens.joined(separator: ", ")
}

/// Anthropic `buildHeaders(newHeaders)`: no HTTP-token check, clear sentinel, `APPEND_HEADERS`.
/// Swift: web `Headers` lower-case names on iteration, so names are stored lower-cased here too.
func buildAnthropicHeaders(_ newHeaders: [HeadersLike?]) -> NullableHeaders {
    var targetHeaders = Headers()
    var nullHeaders: [String] = []
    for headers in newHeaders {
        var seenHeaders = Set<String>()
        for (name, value) in iterateHeaders(headers, clearSentinel: true) {
            let lowerName = name.lowercased()
            if APPEND_HEADERS.contains(lowerName) {
                // Accumulating headers ignore the synthetic clear-before-set; an
                // explicit `null` (any source shape) is honored as removal.
                switch value {
                case .clear:
                    continue
                case .null:
                    targetHeaders.delete(lowerName)
                    if !nullHeaders.contains(lowerName) { nullHeaders.append(lowerName) }
                case .value(let value):
                    targetHeaders.set(lowerName, appendHeaderValue(targetHeaders.get(lowerName), value))
                    nullHeaders.removeAll { $0 == lowerName }
                }
                continue
            }
            if case .clear = value {
                targetHeaders.delete(lowerName)
                seenHeaders.insert(lowerName)
                continue
            }
            if !seenHeaders.contains(lowerName) {
                targetHeaders.delete(lowerName)
                seenHeaders.insert(lowerName)
            }
            switch value {
            case .value(let value):
                targetHeaders.append(lowerName, value)
                nullHeaders.removeAll { $0 == lowerName }
            case .null, .clear:
                targetHeaders.delete(lowerName)
                if !nullHeaders.contains(lowerName) { nullHeaders.append(lowerName) }
            }
        }
    }
    return NullableHeaders(values: targetHeaders, nulls: nullHeaders)
}

// MARK: - internal/utils/env.ts

/// Read an environment variable. Trims beginning and trailing whitespace; empty -> undefined.
/// Swift: reads the given environment (`ProcessInfo.processInfo.environment` by default).
func readEnv(_ env: ProviderEnv, _ name: String) -> String? {
    guard let value = env[name] else { return nil }
    let trimmed = jsTrim(value)
    return trimmed.isEmpty ? nil : trimmed
}

/// `<SDK>_CUSTOM_HEADERS`: one `Name: value` per line, split at the first colon, both parts trimmed.
func parseCustomHeadersEnv(_ value: String) -> [(String, String?)] {
    var parsed: [(String, String?)] = []
    for line in value.split(separator: "\n", omittingEmptySubsequences: false) {
        guard let colon = line.firstIndex(of: ":") else { continue }
        let name = jsTrim(String(line[..<colon]))
        let headerValue = jsTrim(String(line[line.index(after: colon)...]))
        if let index = parsed.firstIndex(where: { $0.0 == name }) { parsed[index].1 = headerValue } else { parsed.append((name, headerValue)) }
    }
    return parsed
}

// `jsTrim` (`String.prototype.trim()`) lives in utils/error-body.swift.

// MARK: - internal/utils/values.ts

private let startsWithSchemeRegexp = try! NSRegularExpression(pattern: "^[a-z][a-z0-9+.-]*:", options: [.caseInsensitive])

func isAbsoluteURL(_ url: String) -> Bool {
    startsWithSchemeRegexp.firstMatch(in: url, range: NSRange(url.startIndex..., in: url)) != nil
}

/// `validatePositiveInteger(name, n)`. `makeError` builds the SDK's `<SDK>Error`.
func validatePositiveInteger(_ name: String, _ n: Int?, _ makeError: (String) -> any Error) throws -> Int {
    guard let n else { throw makeError("\(name) must be an integer") }
    if n < 0 { throw makeError("\(name) must be a positive integer") }
    return n
}

/// `safeJSON(text)`: `JSON.parse`, or undefined on failure.
func safeJSON(_ text: String) -> JsonValue? {
    try? JsonValue.parse(text)
}

/// JavaScript truthiness of a JSON value (`undefined` = nil).
func jsTruthy(_ value: JsonValue?) -> Bool {
    switch value {
    case nil, .null: return false
    case .bool(let b): return b
    case .number(let n): return n != 0 && !n.isNaN
    case .string(let s): return !s.isEmpty
    case .array, .object: return true
    }
}

// MARK: - internal/utils/query.ts

/// `qs.stringify(query, { arrayFormat: 'brackets' })` for flat string values (RFC 3986 encoding).
/// Nested objects / arrays: Not ported (pi never passes a query).
func stringifyQuery(_ query: [(String, String)]) -> String {
    query.map { "\(qsEncode($0.0))=\(qsEncode($0.1))" }.joined(separator: "&")
}

private let qsUnreserved: CharacterSet = {
    var set = CharacterSet()
    set.insert(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_.~")
    return set
}()

private func qsEncode(_ text: String) -> String {
    text.addingPercentEncoding(withAllowedCharacters: qsUnreserved) ?? text
}

/// `new URL(urlString)`, `Object.fromEntries(url.searchParams)` and `url.search = stringifyQuery(query)`.
/// `mergeQuery(pathQuery)` returns the query to set, or nil to leave the URL unchanged.
func buildRequestURL(_ urlString: String, _ mergeQuery: ([(String, String)]) -> [(String, String)]?) throws -> String {
    guard var components = URLComponents(string: urlString), components.scheme != nil else {
        throw PiError("Invalid URL", name: "TypeError")
    }
    var pathQuery: [(String, String)] = []
    for item in components.queryItems ?? [] {
        let value = (item.value ?? "").replacingOccurrences(of: "+", with: " ")
        let name = item.name.replacingOccurrences(of: "+", with: " ")
        if let index = pathQuery.firstIndex(where: { $0.0 == name }) { pathQuery[index].1 = value } else { pathQuery.append((name, value)) }
    }
    if let query = mergeQuery(pathQuery) {
        let search = stringifyQuery(query)
        components.percentEncodedQuery = search.isEmpty ? nil : search
    }
    if components.path.isEmpty, components.host != nil { components.path = "/" }
    guard let string = components.string else { throw PiError("Invalid URL", name: "TypeError") }
    return string
}

/// `{ ...a, ...b }` for ordered string records (later keys win, first position kept).
func spreadQuery(_ sources: [[(String, String)]?]) -> [(String, String)] {
    var result: [(String, String)] = []
    for source in sources {
        for (key, value) in source ?? [] {
            if let index = result.firstIndex(where: { $0.0 == key }) { result[index].1 = value } else { result.append((key, value)) }
        }
    }
    return result
}

// MARK: - internal/detect-platform.ts

/// Node branch of `getPlatformProperties()`.
/// Swift: `X-Stainless-Runtime-Version` is `'unknown'` (no Node `process.version`).
func getPlatformHeaders(_ version: String) -> [(String, String?)] {
    [
        ("X-Stainless-Lang", "js"),
        ("X-Stainless-Package-Version", version),
        ("X-Stainless-OS", normalizePlatform(nodeProcessPlatform())),
        ("X-Stainless-Arch", normalizeArch(nodeProcessArch())),
        ("X-Stainless-Runtime", "node"),
        ("X-Stainless-Runtime-Version", "unknown"),
    ]
}

private func nodeProcessPlatform() -> String {
    #if os(macOS) || os(iOS) || os(tvOS) || os(watchOS) || os(visionOS)
    return "darwin"
    #elseif os(Linux)
    return "linux"
    #elseif os(Windows)
    return "win32"
    #else
    return "unknown"
    #endif
}

private func nodeProcessArch() -> String {
    #if arch(arm64)
    return "arm64"
    #elseif arch(x86_64)
    return "x64"
    #elseif arch(arm)
    return "arm"
    #else
    return "unknown"
    #endif
}

private func normalizeArch(_ arch: String) -> String {
    if arch == "x32" { return "x32" }
    if arch == "x86_64" || arch == "x64" { return "x64" }
    if arch == "arm" { return "arm" }
    if arch == "aarch64" || arch == "arm64" { return "arm64" }
    if !arch.isEmpty { return "other:\(arch)" }
    return "unknown"
}

private func normalizePlatform(_ input: String) -> String {
    let platform = input.lowercased()
    if platform.contains("ios") { return "iOS" }
    if platform == "android" { return "Android" }
    if platform == "darwin" { return "MacOS" }
    if platform == "win32" { return "Windows" }
    if platform == "freebsd" { return "FreeBSD" }
    if platform == "openbsd" { return "OpenBSD" }
    if platform == "linux" { return "Linux" }
    if !platform.isEmpty { return "Other:\(platform)" }
    return "Unknown"
}

// MARK: - internal/errors.ts

/// `isAbortError(err)`: `name === 'AbortError'` or a message mentioning `FetchRequestCanceledException`.
/// Swift: `CancellationError` (task cancellation) also counts as an abort.
func isAbortError(_ err: (any Error)?) -> Bool {
    guard let err else { return false }
    if err is AbortError || err is CancellationError { return true }
    if let err = err as? PiError, err.name == "AbortError" { return true }
    return errorMessage(err).contains("FetchRequestCanceledException")
}

/// `a === b` for errors: identity for class instances, otherwise same type and message.
func isSameError(_ a: any Error, _ b: (any Error)?) -> Bool {
    guard let b else { return false }
    if (type(of: a) as Any.Type) is AnyClass || (type(of: b) as Any.Type) is AnyClass {
        return (a as AnyObject) === (b as AnyObject)
    }
    return type(of: a) == type(of: b) && errorMessage(a) == errorMessage(b)
}

/// `/timed? ?out/i.test(String(error) + String(error.cause))`, used to classify connection failures.
func looksLikeTimeout(_ error: any Error) -> Bool {
    var text = errorMessage(error)
    if let error = error as? FetchError, let cause = error.cause { text += cause }
    return text.range(of: "timed? ?out", options: [.regularExpression, .caseInsensitive]) != nil
}

// MARK: - Request controller

/// The `AbortController` a request runs under. OpenAI's `createRequestController` replaces the
/// controller's `signal` with `AbortSignal.any([controller.signal, callerSignal])`; Swift's
/// `AbortController.signal` is immutable, so the composed signal lives here instead.
public final class RequestController: Sendable {
    private let controller: AbortController
    public let signal: AbortSignal

    init(_ controller: AbortController = AbortController(), signal: AbortSignal? = nil) {
        self.controller = controller
        self.signal = signal ?? controller.signal
    }

    public func abort(_ reason: (any Error)? = nil) { controller.abort(reason) }
}

// MARK: - internal/decoders/line.ts

/// A re-implementation of httpx's `LineDecoder` in Swift that handles incrementally
/// reading lines from text.
///
/// https://github.com/encode/httpx/blob/920333ea98118e9cf617f246905d7b202510941c/httpx/_decoders.py#L258
/// Not ported: `MAX_RETAINED_BUFFER_BYTES` buffer-capacity management (memory tuning only).
struct LineDecoder {
    private var buffer: [UInt8] = []
    private var start = 0
    private var searchIndex = 0
    private var skipLeadingLF = false

    mutating func decode(_ input: [UInt8]) -> [String] {
        var chunk = input[...]
        if chunk.isEmpty { return [] }

        if skipLeadingLF {
            skipLeadingLF = false
            if chunk.first == 0x0a { chunk = chunk.dropFirst() }
            if chunk.isEmpty { return [] }
        }

        append(chunk)

        var lines: [String] = []
        while let patternIndex = findNewlineIndex(buffer, searchIndex, buffer.count) {
            lines.append(String(decoding: buffer[start..<patternIndex.preceding], as: UTF8.self))

            start = patternIndex.index
            if patternIndex.carriage {
                if start < buffer.count && buffer[start] == 0x0a {
                    start += 1
                } else if start == buffer.count {
                    skipLeadingLF = true
                }
            }
            searchIndex = start
        }

        searchIndex = buffer.count
        if start == buffer.count {
            buffer = []
            start = 0
            searchIndex = 0
        }
        return lines
    }

    private mutating func append(_ chunk: ArraySlice<UInt8>) {
        if start > 0 {
            buffer.removeFirst(start)
            searchIndex -= start
            start = 0
        }
        buffer.append(contentsOf: chunk)
    }

    mutating func flush() -> [String] {
        skipLeadingLF = false
        if start == buffer.count { return [] }
        return decode(Array("\n".utf8))
    }
}

private func findNewlineIndex(_ buffer: [UInt8], _ start: Int, _ end: Int) -> (preceding: Int, index: Int, carriage: Bool)? {
    let newline: UInt8 = 0x0a // \n
    let carriage: UInt8 = 0x0d // \r
    var i = start
    while i < end {
        if buffer[i] == newline { return (i, i + 1, false) }
        if buffer[i] == carriage { return (i, i + 1, true) }
        i += 1
    }
    return nil
}

/// `findDoubleNewlineIndex(buffer)`: index just past the first `\n\n`, `\r\r`, `\r\n\r\n` (or mixed) pair; -1 if none.
func findDoubleNewlineIndex(_ buffer: ArraySlice<UInt8>) -> Int {
    let base = buffer.startIndex
    let count = buffer.count
    func lineEndingLength(_ i: Int) -> Int {
        if i >= count { return 0 }
        let byte = buffer[base + i]
        if byte == 0x0a { return 1 }
        if byte == 0x0d { return i + 1 < count && buffer[base + i + 1] == 0x0a ? 2 : 1 }
        return 0
    }
    var i = 0
    while i < count - 1 {
        let firstEndingLength = lineEndingLength(i)
        if firstEndingLength > 0 {
            let secondEndingIndex = i + firstEndingLength
            let secondEndingLength = lineEndingLength(secondEndingIndex)
            if secondEndingLength > 0 { return secondEndingIndex + secondEndingLength }
        }
        i += 1
    }
    return -1
}

// MARK: - core/streaming.ts (SSE decoding)

/// A decoded server-sent event before its JSON payload has been parsed.
public struct ServerSentEvent: Sendable, Equatable {
    /// Explicit SSE event name, or `nil` when the event has no `event:` field.
    public var event: String?
    /// Joined contents of the event's `data:` fields.
    public var data: String
    /// Original event lines retained for diagnostics when parsing fails.
    public var raw: [String]
}

struct SSEDecoder {
    private var data: [String] = []
    private var event: String?
    private var chunks: [String] = []

    mutating func decode(_ input: String) -> ServerSentEvent? {
        var line = input
        if line.hasSuffix("\r") { line.removeLast() }
        // Swift: "\r\n" is one Character; strip a trailing CR at the scalar level too.
        if line.unicodeScalars.last == "\r" { line = String(line.unicodeScalars.dropLast()) }

        if line.isEmpty {
            if (event ?? "").isEmpty && data.isEmpty { return nil }

            let sse = ServerSentEvent(event: event, data: data.joined(separator: "\n"), raw: chunks)

            event = nil
            data = []
            chunks = []

            return sse
        }

        chunks.append(line)

        if line.hasPrefix(":") { return nil }

        var (fieldname, _, value) = partition(line, ":")

        if value.hasPrefix(" ") { value.removeFirst() }

        if fieldname == "event" {
            event = value
        } else if fieldname == "data" {
            data.append(value)
        }

        return nil
    }

    /// Emits a pending event at EOF when the stream omitted the trailing blank
    /// line. Returns `nil` when no event is in progress so a record that already
    /// ended with a blank line is not delivered twice.
    mutating func flush() -> ServerSentEvent? { decode("") }
}

private func partition(_ str: String, _ delimiter: Character) -> (String, String, String) {
    if let index = str.firstIndex(of: delimiter) {
        return (String(str[..<index]), String(delimiter), String(str[str.index(after: index)...]))
    }
    return (str, "", "")
}

/// Error thrown by the `_iterSSEMessages` consumer callback; passed through untouched.
private struct SSEConsumerError: Error {
    let inner: any Error
}

/// `createAbortableSSESource(body, signal)`: reads the body in a child task; aborting the signal ends
/// the source (a pending read returns "ended"), and read errors caused by the abort end it silently.
/// Swift: the reader task buffers ahead of the consumer.
private func createAbortableSSESource(_ body: ResponseBody, _ signal: AbortSignal) -> (stream: AsyncThrowingStream<Data, any Error>, cleanup: @Sendable () -> Void) {
    let (stream, continuation) = AsyncThrowingStream<Data, any Error>.makeStream(bufferingPolicy: .unbounded)
    let reader = Task {
        do {
            for try await chunk in body {
                if signal.aborted { break }
                continuation.yield(chunk)
            }
            continuation.finish()
        } catch {
            if signal.aborted && (isAbortError(error) || isSameError(error, signal.reason)) {
                continuation.finish()
            } else {
                continuation.finish(throwing: error)
            }
        }
    }
    let abort: @Sendable () -> Void = {
        continuation.finish()
        reader.cancel()
    }
    let abortID = signal.addEventListener(abort)
    if signal.aborted { abort() }
    continuation.onTermination = { _ in reader.cancel() }
    return (stream, {
        signal.removeEventListener(abortID)
        reader.cancel()
    })
}

/// Decodes complete SSE records from a response. Complete events are decoded on demand without
/// imposing a line or event size limit. `onEvent` returns false to stop (the generator's `break`).
/// Not ported: the no-body / React Native branch (a Swift `FetchResponse` always has a body).
func _iterSSEMessages(
    _ response: FetchResponse,
    _ controller: RequestController,
    _ onEvent: (ServerSentEvent) throws -> Bool
) async throws {
    var sseDecoder = SSEDecoder()
    var lineDecoder = LineDecoder()
    let signal = controller.signal
    let source = createAbortableSSESource(response.body, signal)
    defer { source.cleanup() }

    /// Feeds one SSE chunk; returns false when iteration must stop.
    func handle(_ lines: [String]) throws -> Bool {
        for line in lines {
            if signal.aborted { return false }
            if let sse = sseDecoder.decode(line) {
                do {
                    if try !onEvent(sse) { return false }
                } catch {
                    throw SSEConsumerError(inner: error)
                }
            }
        }
        return true
    }

    do {
        // iterSSEChunks: yields when a double new-line is encountered.
        var data: [UInt8] = []
        var dataStart = 0
        var searchStartIndex = 0
        let DOUBLE_NEWLINE_DELIMITER_MAX_OVERLAP_BYTES = 3

        for try await chunk in source.stream {
            if dataStart > 0 {
                data.removeFirst(dataStart)
                searchStartIndex -= dataStart
                dataStart = 0
            }
            data.append(contentsOf: chunk)

            while true {
                var patternIndex = findDoubleNewlineIndex(data[searchStartIndex..<data.count])
                if patternIndex == -1 { break }
                patternIndex += searchStartIndex
                let sseChunk = Array(data[dataStart..<patternIndex])
                dataStart = patternIndex
                searchStartIndex = dataStart
                if signal.aborted { return }
                if try !handle(lineDecoder.decode(sseChunk)) { return }
            }

            searchStartIndex = max(dataStart, data.count - DOUBLE_NEWLINE_DELIMITER_MAX_OVERLAP_BYTES)
        }
        if data.count > dataStart {
            if signal.aborted { return }
            if try !handle(lineDecoder.decode(Array(data[dataStart...]))) { return }
        }

        if signal.aborted { return }
        if try !handle(lineDecoder.flush()) { return }
        if signal.aborted { return }
        if let pending = sseDecoder.flush() {
            do { _ = try onEvent(pending) } catch { throw SSEConsumerError(inner: error) }
        }
    } catch let error as SSEConsumerError {
        throw error.inner
    } catch {
        if !signal.aborted || (!isAbortError(error) && !isSameError(error, signal.reason)) {
            throw error
        }
    }
}

// MARK: - Timers and request plumbing

/// A pending `setTimeout`; `cancel()` is `clearTimeout`.
final class TimeoutHandle: @unchecked Sendable {
    private let item: DispatchWorkItem
    init(_ item: DispatchWorkItem) { self.item = item }
    func cancel() { item.cancel() }
}

/// `setTimeout(fn, ms)`.
@discardableResult
func setTimeout(_ ms: Double, _ fn: @escaping @Sendable () -> Void) -> TimeoutHandle {
    let item = DispatchWorkItem(block: fn)
    let delay = ms.isFinite ? max(0, Int(min(ms, Double(Int32.max)).rounded(.up))) : Int(Int32.max)
    DispatchQueue.global().asyncAfter(deadline: .now() + .milliseconds(delay), execute: item)
    return TimeoutHandle(item)
}

/// `Shims.CancelReadableStream(response.body)`: stop reading the body so the transfer is cancelled.
func cancelResponseBody(_ response: FetchResponse) {
    let body = response.body
    let task = Task {
        for try await _ in body {}
    }
    task.cancel()
}

/// The request a Stainless client hands to `fetch` (`FinalizedRequestInit`).
public struct FinalizedRequest: Sendable {
    public var method: String
    public var headers: Headers
    public var signal: AbortSignal?
    public var body: Data?
}

/// Per-request options (`RequestOptions`). `timeout == nil` means the key is absent.
public struct RequestOptions: Sendable {
    public var signal: AbortSignal?
    public var timeout: Int?
    public var maxRetries: Int?
    public var headers: HeadersLike?
    public var query: [(String, String)]?
    public var idempotencyKey: String?

    public init(signal: AbortSignal? = nil, timeout: Int? = nil, maxRetries: Int? = nil, headers: HeadersLike? = nil, query: [(String, String)]? = nil, idempotencyKey: String? = nil) {
        self.signal = signal
        self.timeout = timeout
        self.maxRetries = maxRetries
        self.headers = headers
        self.query = query
        self.idempotencyKey = idempotencyKey
    }
}

/// `FinalRequestOptions`: `{ method, path, body, ...RequestOptions, stream }`.
public struct FinalRequestOptions: Sendable {
    public var method: String
    public var path: String
    public var body: JsonValue?
    public var stream: Bool
    public var query: [(String, String)]?
    public var headers: HeadersLike?
    public var signal: AbortSignal?
    public var timeout: Int?
    public var maxRetries: Int?
    public var idempotencyKey: String?

    init(method: String, path: String, body: JsonValue?, stream: Bool, _ options: RequestOptions) {
        self.method = method
        self.path = path
        self.body = body
        self.stream = stream
        self.query = options.query
        self.headers = options.headers
        self.signal = options.signal
        self.timeout = options.timeout
        self.maxRetries = options.maxRetries
        self.idempotencyKey = options.idempotencyKey
    }
}

/// Builds `JSON.stringify(body)` with the `content-type: application/json` body header (`FallbackEncoder`).
func buildJSONBody(_ body: JsonValue?) -> (bodyHeaders: HeadersLike?, body: Data?) {
    guard let body, jsTruthy(body) else { return (nil, nil) }
    return (.record([("content-type", "application/json")]), Data(body.serialized().utf8))
}

/// Await `task` but cancel it when the awaiting task is cancelled.
func awaitTask<T: Sendable>(_ task: Task<T, any Error>) async throws -> T {
    try await withTaskCancellationHandler {
        try await task.value
    } onCancel: {
        task.cancel()
    }
}
