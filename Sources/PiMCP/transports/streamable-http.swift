// Streamable HTTP transport, packages/mcp @ 42cb822f1c5d3153069dd0661bfd297424666cf1.
// SSE responses resume through GET with a per-stream cursor.
// A tools/call POST is never replayed after an uncertain network outcome.
import Foundation
import PiAI

public struct McpHTTPError: Error, Sendable { public var status: Int; public var authenticate: String? }
public struct McpHTTPAuthentication: Sendable {
    public var authorization: @Sendable (AbortSignal?) async throws -> String?
    public var unauthorized: @Sendable (String?, String?, AbortSignal?) async throws -> Bool
    public init(authorization: @escaping @Sendable (AbortSignal?) async throws -> String?,
                unauthorized: @escaping @Sendable (String?, String?, AbortSignal?) async throws -> Bool) {
        self.authorization = authorization; self.unauthorized = unauthorized
    }
}
public struct StreamableHttpTransportOptions: Sendable {
    public var url: URL
    public var headers: Headers
    public var fetch: FetchFunction
    public var maxMessageBytes: Int
    public var authentication: McpHTTPAuthentication?
    public init(url: URL, headers: Headers = Headers(), maxMessageBytes: Int = DEFAULT_MAX_MESSAGE_BYTES,
                fetch: @escaping FetchFunction = defaultFetch, authentication: McpHTTPAuthentication? = nil) {
        self.url = url; self.headers = headers; self.fetch = fetch; self.maxMessageBytes = maxMessageBytes; self.authentication = authentication
    }
}
public actor StreamableHttpTransport: McpTransport {
    public let options: StreamableHttpTransportOptions
    public private(set) var sessionId: String?
    private var protocolVersion: String?
    private var events: McpTransportEvents?
    private var closed = false
    private var getTask: Task<Void, Never>?
    private let lifetime = AbortController()
    private var lastAuthorization: String?
    public init(options: StreamableHttpTransportOptions) { self.options = options }
    public func start(events: McpTransportEvents) throws {
        guard !closed else { throw McpConnectionClosedError() }
        guard self.events == nil else { throw PiError("MCP HTTP transport already started") }
        self.events = events
    }
    private func headers() -> Headers {
        var headers = options.headers
        headers.set("Accept", "application/json, text/event-stream")
        if let sessionId { headers.set("Mcp-Session-Id", sessionId) }
        if let protocolVersion { headers.set("MCP-Protocol-Version", protocolVersion) }
        return headers
    }
    public func setProtocolVersion(_ version: String) { protocolVersion = version }
    private func fetchAuthenticated(_ original: FetchRequest) async throws -> FetchResponse {
        var request = original
        request.followRedirects = false
        let authorization = try await options.authentication?.authorization(request.signal)
        if let authorization { request.headers.set("Authorization", authorization); lastAuthorization = authorization }
        let response = try await options.fetch(request)
        let challenge = response.headers.get("WWW-Authenticate")
        if response.status == 403 && parseWwwAuthenticate(challenge).error == "insufficient_scope" {
            _ = try await options.authentication?.unauthorized(challenge, authorization, request.signal)
            throw McpOAuthAuthorizationRequired()
        }
        if response.status == 401, let auth = options.authentication,
           try await auth.unauthorized(challenge, authorization, request.signal) {
            try request.signal?.throwIfAborted()
            if let next = try await auth.authorization(request.signal) { request.headers.set("Authorization", next); lastAuthorization = next }
            // Exactly one retry after a definite authentication rejection; never replay network failures.
            return try await options.fetch(request)
        }
        return response
    }
    public func send(_ message: JsonObject, signal: AbortSignal?) async throws {
        guard !closed, events != nil else { throw McpConnectionClosedError() }
        let combined = combineAbortSignals([signal, lifetime.signal]); defer { combined.cleanup() }
        try combined.signal?.throwIfAborted()
        let payload = Data(JsonValue.object(message).serialized().utf8)
        guard payload.count <= options.maxMessageBytes else { throw PiError("MCP message exceeds size limit") }
        var headers = headers(); headers.set("Content-Type", "application/json")
        let response = try await fetchAuthenticated(.init(url: options.url, method: "POST", headers: headers, body: payload, signal: combined.signal))
        guard !closed else { throw McpConnectionClosedError() }
        try await requireSuccess(response)
        if message["method"] == .string("initialize"), let id = response.headers.get("Mcp-Session-Id") { sessionId = id }
        // Notifications and client responses have no JSON-RPC response to consume. Some servers
        // return an empty JSON envelope with HTTP 200 instead of the recommended HTTP 202.
        if message["id"] != nil && message["method"] != nil && response.status != 202 && response.status != 204 {
            try await consume(response, signal: combined.signal, requestID: message["id"])
        }
        if message["method"] == .string("notifications/initialized"), getTask == nil {
            getTask = Task { [weak self] in await self?.listen() }
        }
    }
    private func listen() async {
        do {
            var headers = headers(); headers.set("Accept", "text/event-stream")
            var response: FetchResponse
            var attempt = 0
            while true {
                do {
                    response = try await fetchAuthenticated(.init(url: options.url, headers: headers, signal: lifetime.signal))
                    if response.status != 405 && !(response.status == 404 && sessionId == nil) { try await requireSuccess(response) }
                    break
                } catch {
                    guard !closed, attempt < 5, retryable(error) else { throw error }
                    try await sleep(min(30_000, 1_000 << attempt), lifetime.signal)
                    attempt += 1
                }
            }
            // GET SSE is optional. A 404 with an established session means it has expired.
            if response.status == 405 || (response.status == 404 && sessionId == nil) { return }
            try await requireSuccess(response)
            try await consume(response, signal: lifetime.signal, requestID: nil)
        } catch {
            if !closed {
                await events?.onError(error)
                // Authentication and expired sessions need a fresh connection. Network errors
                // after the bounded resume budget also retire this connection.
                await close()
            }
        }
    }
    private func requireSuccess(_ response: FetchResponse) async throws {
        guard response.ok else {
            let error = McpHTTPError(status: response.status, authenticate: response.headers.get("WWW-Authenticate"))
            if response.status == 404 && sessionId != nil { await close() }
            throw error
        }
    }
    private func retryable(_ error: any Error) -> Bool {
        if error is URLError || error is FetchError || error is FetchTimeoutError { return true }
        guard let status = (error as? McpHTTPError)?.status else { return false }
        return status == 408 || status == 429 || (status >= 500 && status != 501)
    }
    private func consume(_ initial: FetchResponse, signal: AbortSignal?, requestID: JsonValue?) async throws {
        let contentType = initial.headers.get("Content-Type")?.lowercased() ?? ""
        if contentType.contains("application/json") {
            var data = Data()
            for try await chunk in initial.body {
                try signal?.throwIfAborted(); data.append(chunk)
                guard data.count <= options.maxMessageBytes else { throw PiError("MCP message exceeds size limit") }
            }
            _ = try await deliver(String(decoding: data, as: UTF8.self))
            return
        }
        guard contentType.contains("text/event-stream") else { throw PiError("Unsupported MCP response content type: \(contentType)") }
        var response = initial
        var cursor: String?, retryMs: Int?, attempts = 0
        while !closed {
            var decoder = McpSSEDecoder(maxMessageBytes: options.maxMessageBytes)
            let openedAt = ContinuousClock.now
            do {
                for try await chunk in response.body {
                    try signal?.throwIfAborted(); try Task.checkCancellation()
                    let payloads = try decoder.feed(chunk)
                    if let id = decoder.lastEventId { cursor = id.isEmpty ? nil : id }
                    // A hostile or misconfigured server must not park the reconnect loop for hours.
                    if let retry = decoder.retryMs { retryMs = min(retry, 30_000) }
                    if !payloads.isEmpty { attempts = 0 }
                    for payload in payloads {
                        let message = try await deliver(payload)
                        if let requestID, message["id"] == requestID, message["method"] == nil { return }
                    }
                }
            } catch {
                try signal?.throwIfAborted(); try Task.checkCancellation()
                // Invalid payloads and size violations are protocol errors, not reconnect signals.
                guard retryable(error) else { throw error }
            }
            try signal?.throwIfAborted(); try Task.checkCancellation()
            // A POST can only be resumed with the server's cursor. Never replay the POST itself.
            guard requestID == nil || cursor != nil else { throw PiError("MCP response stream ended without a resumable cursor") }
            if ContinuousClock.now - openedAt > .seconds(30) { attempts = 0 }
            guard attempts < 5 else { throw PiError("MCP SSE reconnect limit reached") }
            try await sleep(retryMs ?? min(30_000, 1_000 << attempts), signal)
            attempts += 1
            var headers = headers(); headers.set("Accept", "text/event-stream")
            if let cursor { headers.set("Last-Event-ID", cursor) }
            // A failed GET is safe to retry; the same cursor preserves the original request.
            while true {
                do {
                    response = try await fetchAuthenticated(.init(url: options.url, headers: headers, signal: signal))
                    try await requireSuccess(response)
                    guard response.headers.get("Content-Type")?.lowercased().contains("text/event-stream") == true else {
                        throw PiError("MCP resumed stream must use text/event-stream")
                    }
                    break
                } catch {
                    try signal?.throwIfAborted(); try Task.checkCancellation()
                    guard attempts < 5, retryable(error) else { throw error }
                    try await sleep(retryMs ?? min(30_000, 1_000 << attempts), signal)
                    attempts += 1
                }
            }
        }
        throw McpConnectionClosedError()
    }
    private func deliver(_ payload: String) async throws -> JsonObject {
        let message = try parseJsonRpcMessage(JsonValue.parse(payload))
        if !closed { await events?.onMessage(message) }
        return message
    }
    public func close() async {
        guard !closed else { return }; closed = true
        lifetime.abort(); getTask?.cancel(); getTask = nil
        if sessionId != nil {
            // Cleanup has its own short deadline: the lifetime signal has already been aborted.
            var cleanupHeaders = headers()
            if let lastAuthorization { cleanupHeaders.set("Authorization", lastAuthorization) }
            _ = try? await options.fetch(.init(url: options.url, method: "DELETE", headers: cleanupHeaders, signal: AbortSignal.timeout(2_000), followRedirects: false))
        }
        await events?.onClose()
    }
}

/// Incremental SSE framing across arbitrary UTF-8 chunks and CR/LF/CRLF boundaries.
struct McpSSEDecoder {
    let maxMessageBytes: Int
    private var line = Data()
    private var data: [String] = []
    private var event = ""
    private var eventBytes = 0
    private var afterCR = false
    private var pendingEventId: String?
    private(set) var lastEventId: String?
    private(set) var retryMs: Int?
    init(maxMessageBytes: Int) { self.maxMessageBytes = maxMessageBytes }
    mutating func feed(_ chunk: Data) throws -> [String] {
        var messages: [String] = []
        for byte in chunk {
            if afterCR { afterCR = false; if byte == 10 { continue } }
            if byte == 10 || byte == 13 {
                let text = String(decoding: line, as: UTF8.self); line.removeAll(keepingCapacity: true)
                if text.isEmpty {
                    // An id belongs to its entire SSE event. Advancing before the blank line
                    // would skip an incomplete response when reconnecting after a broken body.
                    // Empty/id-only events still commit a cursor at this boundary.
                    if let pendingEventId { lastEventId = pendingEventId }
                    if !data.isEmpty && (event.isEmpty || event == "message") {
                        let payload = data.joined(separator: "\n")
                        if !payload.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { messages.append(payload) }
                    }
                    data.removeAll(); event = ""; eventBytes = 0
                } else if !text.hasPrefix(":") {
                    let pieces = text.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
                    var value = pieces.count > 1 ? String(pieces[1]) : ""
                    if value.hasPrefix(" ") { value.removeFirst() }
                    if pieces[0] == "data" { data.append(value); eventBytes += value.utf8.count + 1 }
                    else if pieces[0] == "event" { event = value }
                    else if pieces[0] == "id", !value.contains("\0") { pendingEventId = value }
                    else if pieces[0] == "retry", !value.isEmpty, value.utf8.allSatisfy({ (48...57).contains($0) }), let milliseconds = Int(value), milliseconds <= Int.max / 1_000_000 {
                        retryMs = milliseconds
                    }
                }
                afterCR = byte == 13
            } else { line.append(byte) }
            guard line.count + eventBytes <= maxMessageBytes else { throw PiError("MCP message exceeds size limit") }
        }
        return messages
    }
}
