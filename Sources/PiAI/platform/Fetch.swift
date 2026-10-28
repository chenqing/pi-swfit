import Foundation

// Swift stand-in for the web `fetch` API that upstream (and the SDKs it wraps) use.
//
// Timeout semantics mirror what upstream runs with on Node:
// - undici `headersTimeout` / `bodyTimeout` (300 s each): the connection is idle-timed out when no
//   headers or no body bytes arrive for that long. URLSession's `timeoutInterval` is exactly an idle timeout.
// - SDK `timeout` (10 min default, `StreamOptions.timeoutMs`): covers the request until response headers
//   arrive; the body stream is then governed only by the idle timeout. See `Request.timeoutMs`.

/// Case-insensitive, order-preserving HTTP headers (web `Headers`).
public struct Headers: Sendable, Sequence {
    public private(set) var entries: [(name: String, value: String)] = []

    public init() {}
    public init(_ pairs: [(String, String)]) { for (k, v) in pairs { append(k, v) } }
    public init(_ dict: [String: String]) { for k in dict.keys.sorted() { append(k, dict[k]!) } }

    public func get(_ name: String) -> String? {
        let lower = name.lowercased()
        let values = entries.filter { $0.name.lowercased() == lower }.map(\.value)
        return values.isEmpty ? nil : values.joined(separator: ", ")
    }

    public func has(_ name: String) -> Bool { get(name) != nil }

    public mutating func set(_ name: String, _ value: String) {
        let lower = name.lowercased()
        guard let index = entries.firstIndex(where: { $0.name.lowercased() == lower }) else {
            entries.append((name, value))
            return
        }
        entries.removeAll { $0.name.lowercased() == lower }
        entries.insert((name, value), at: index)
    }

    public mutating func append(_ name: String, _ value: String) { entries.append((name, value)) }

    public mutating func delete(_ name: String) {
        let lower = name.lowercased()
        entries.removeAll { $0.name.lowercased() == lower }
    }

    public func makeIterator() -> IndexingIterator<[(name: String, value: String)]> { entries.makeIterator() }

    /// Lower-cased name -> value (`headersToRecord`).
    public var record: [String: String] {
        var result: [String: String] = [:]
        for (name, _) in entries { result[name.lowercased()] = get(name) }
        return result
    }
}

public struct FetchRequest: Sendable {
    public var url: URL
    public var method: String
    public var headers: Headers
    public var body: Data?
    public var signal: AbortSignal?
    /// Time allowed until response headers arrive (SDK `timeout`). nil = no overall limit.
    public var timeoutMs: Int?
    /// Idle timeout while waiting for headers or between body chunks (undici headers/body timeout).
    public var idleTimeoutMs: Int
    /// Disable for credential-bearing endpoints or requests whose side effects must not be replayed.
    public var followRedirects: Bool

    public init(url: URL, method: String = "GET", headers: Headers = Headers(), body: Data? = nil, signal: AbortSignal? = nil, timeoutMs: Int? = nil, idleTimeoutMs: Int = 300_000, followRedirects: Bool = true) {
        self.url = url; self.method = method; self.headers = headers; self.body = body; self.signal = signal; self.timeoutMs = timeoutMs; self.idleTimeoutMs = idleTimeoutMs; self.followRedirects = followRedirects
    }
}

/// Streaming response body: an async sequence of byte chunks. Iterate it once.
public struct ResponseBody: AsyncSequence, Sendable {
    public typealias Element = Data
    let stream: AsyncThrowingStream<Data, any Error>
    public init(_ stream: AsyncThrowingStream<Data, any Error>) { self.stream = stream }
    public static func data(_ data: Data) -> ResponseBody {
        ResponseBody(AsyncThrowingStream { c in
            if !data.isEmpty { c.yield(data) }
            c.finish()
        })
    }
    public func makeAsyncIterator() -> AsyncThrowingStream<Data, any Error>.AsyncIterator { stream.makeAsyncIterator() }
}

public struct FetchResponse: Sendable {
    public var status: Int
    public var statusText: String
    public var headers: Headers
    public var url: URL?
    public var body: ResponseBody

    public init(status: Int, statusText: String? = nil, headers: Headers, url: URL? = nil, body: ResponseBody) {
        self.status = status
        self.statusText = statusText ?? HTTPURLResponse.localizedString(forStatusCode: status).capitalized
        self.headers = headers; self.url = url; self.body = body
    }

    public var ok: Bool { (200..<300).contains(status) }

    public func data() async throws -> Data {
        var data = Data()
        for try await chunk in body { data.append(chunk) }
        return data
    }

    public func text() async throws -> String { String(decoding: try await data(), as: UTF8.self) }

    public func json() async throws -> JsonValue { try JsonValue.parse(try await text()) }
}

public typealias FetchFunction = @Sendable (FetchRequest) async throws -> FetchResponse

/// `globalThis.fetch`, backed by a shared URLSession.
public let defaultFetch: FetchFunction = { request in try await URLSessionFetch.shared.fetch(request) }

/// Swift: the ambient `globalThis.fetch` read at call time by code that cannot take an injected fetch (the Google
/// adapters). Defaults to `defaultFetch`; tests rebind it with `GlobalFetch.$current.withValue(...)`, the
/// equivalent of upstream's `vi.stubGlobal("fetch", ...)`.
public enum GlobalFetch {
    @TaskLocal public static var current: FetchFunction = defaultFetch
}

/// Network failure before a response (web fetch rejects with `TypeError: fetch failed`).
public struct FetchError: Error, CustomStringConvertible, LocalizedError, Sendable {
    public var message: String
    public var cause: String?
    public var code: String?
    public init(_ message: String = "fetch failed", cause: String? = nil, code: String? = nil) { self.message = message; self.cause = cause; self.code = code }
    public var description: String { message }
    public var errorDescription: String? { message }
}

/// Request timed out (SDK `APIConnectionTimeoutError` / undici timeout errors are built from this).
public struct FetchTimeoutError: Error, CustomStringConvertible, LocalizedError, Sendable {
    public var message: String
    public init(_ message: String = "Request timed out.") { self.message = message }
    public var description: String { message }
    public var errorDescription: String? { message }
}

final class URLSessionFetch: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    static let shared = URLSessionFetch()

    private struct Pending {
        var response: CheckedContinuation<FetchResponse, any Error>?
        var body: AsyncThrowingStream<Data, any Error>.Continuation
        var stream: AsyncThrowingStream<Data, any Error>
        var request: FetchRequest
    }

    private let pending = Locked([Int: Pending]())
    private var session: URLSession!

    override init() {
        super.init()
        let configuration = URLSessionConfiguration.default
        configuration.timeoutIntervalForResource = 7 * 24 * 3600
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.urlCache = nil
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        let queue = OperationQueue()
        queue.maxConcurrentOperationCount = 1
        queue.name = "pi.fetch"
        session = URLSession(configuration: configuration, delegate: self, delegateQueue: queue)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        let follow = pending.withLock { $0[task.taskIdentifier]?.request.followRedirects ?? false }
        completionHandler(follow ? request : nil)
    }

    func fetch(_ request: FetchRequest) async throws -> FetchResponse {
        try request.signal?.throwIfAborted()
        var urlRequest = URLRequest(url: request.url)
        urlRequest.httpMethod = request.method
        urlRequest.timeoutInterval = Double(request.idleTimeoutMs) / 1000
        for (name, value) in request.headers.entries { urlRequest.addValue(value, forHTTPHeaderField: name) }
        urlRequest.httpBody = request.body

        let task = session.dataTask(with: urlRequest)
        let taskID = task.taskIdentifier
        let (stream, bodyContinuation) = AsyncThrowingStream<Data, any Error>.makeStream(bufferingPolicy: .unbounded)
        // Consumer stopped reading (break / deinit): cancel the transfer.
        bodyContinuation.onTermination = { termination in
            if case .cancelled = termination { task.cancel() }
        }

        // Abort signal: cancel the task; the waiters receive the signal's reason.
        let abortID = request.signal?.addEventListener { [weak self] in
            self?.fail(taskID, request.signal?.reason ?? AbortError())
            task.cancel()
        }
        // Overall timeout until headers (SDK `timeout`).
        var timeoutItem: DispatchWorkItem?
        if let timeoutMs = request.timeoutMs, timeoutMs > 0 {
            let item = DispatchWorkItem { [weak self] in
                guard let self else { return }
                if self.pending.withLock({ $0[taskID]?.response != nil }) {
                    self.fail(taskID, FetchTimeoutError())
                    task.cancel()
                }
            }
            timeoutItem = item
            DispatchQueue.global().asyncAfter(deadline: .now() + .milliseconds(timeoutMs), execute: item)
        }

        do {
            let response: FetchResponse = try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<FetchResponse, any Error>) in
                    pending.withLock { $0[taskID] = Pending(response: continuation, body: bodyContinuation, stream: stream, request: request) }
                    if request.signal?.aborted == true || Task.isCancelled {
                        fail(taskID, request.signal?.reason ?? AbortError())
                        task.cancel()
                        return
                    }
                    task.resume()
                }
            } onCancel: { [weak self] in
                self?.fail(taskID, AbortError())
                task.cancel()
            }
            timeoutItem?.cancel()
            // The abort listener stays registered: aborting while the body streams fails the body.
            return response
        } catch {
            timeoutItem?.cancel()
            if let abortID { request.signal?.removeEventListener(abortID) }
            throw error
        }
    }

    /// Fail whatever is still pending for a task: the response continuation or the body stream.
    private func fail(_ taskID: Int, _ error: any Error) {
        let entry = pending.withLock { $0.removeValue(forKey: taskID) }
        guard let entry else { return }
        if let response = entry.response { response.resume(throwing: error) }
        entry.body.finish(throwing: error)
    }

    // MARK: URLSessionDataDelegate

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse, completionHandler: @escaping @Sendable (URLSession.ResponseDisposition) -> Void) {
        let taskID = dataTask.taskIdentifier
        let resumed: (CheckedContinuation<FetchResponse, any Error>, FetchResponse)? = pending.withLock { map in
            guard var entry = map[taskID], let continuation = entry.response else { return nil }
            entry.response = nil
            map[taskID] = entry
            let http = response as? HTTPURLResponse
            var headers = Headers()
            for (key, value) in http?.allHeaderFields ?? [:] {
                if let key = key as? String { headers.append(key, "\(value)") }
            }
            let fetchResponse = FetchResponse(status: http?.statusCode ?? 0, headers: headers, url: response.url, body: ResponseBody(entry.stream))
            return (continuation, fetchResponse)
        }
        completionHandler(.allow)
        if let (continuation, value) = resumed { continuation.resume(returning: value) }
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        let body = pending.withLock { $0[dataTask.taskIdentifier]?.body }
        body?.yield(data)
    }

    // Swift: undici fails a body whose connection drops before the terminating chunk with `TypeError: terminated`.
    // URLSession reports such an HTTP/1.1 chunked body as complete (error nil) and exposes no way to tell, so the
    // body just ends; the adapters' own "stream ended without ..." checks (retryable, like "terminated") catch it.
    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: (any Error)?) {
        let entry = pending.withLock { $0.removeValue(forKey: task.taskIdentifier) }
        guard let entry else { return }
        let mapped = error.map { Self.mapError($0, request: entry.request) }
        if let response = entry.response {
            if let mapped {
                response.resume(throwing: mapped)
            } else {
                // No response object at all (should not happen for HTTP).
                response.resume(throwing: FetchError("fetch failed", cause: "no response"))
            }
        }
        if let mapped { entry.body.finish(throwing: mapped) } else { entry.body.finish() }
    }

    private static func mapError(_ error: any Error, request: FetchRequest) -> any Error {
        if let reason = request.signal?.reason { return reason }
        let ns = error as NSError
        if ns.domain == NSURLErrorDomain {
            switch ns.code {
            case NSURLErrorCancelled: return AbortError()
            case NSURLErrorTimedOut: return FetchTimeoutError()
            case NSURLErrorNetworkConnectionLost: return FetchError("fetch failed", cause: "other side closed", code: "UND_ERR_SOCKET")
            case NSURLErrorCannotFindHost, NSURLErrorDNSLookupFailed: return FetchError("fetch failed", cause: "getaddrinfo ENOTFOUND \(request.url.host ?? "")", code: "ENOTFOUND")
            case NSURLErrorCannotConnectToHost: return FetchError("fetch failed", cause: "connect ECONNREFUSED \(request.url.host ?? "")", code: "ECONNREFUSED")
            case NSURLErrorNotConnectedToInternet: return FetchError("fetch failed", cause: "network error: not connected to the internet", code: "ENETUNREACH")
            default: return FetchError("fetch failed", cause: ns.localizedDescription, code: String(ns.code))
            }
        }
        return FetchError("fetch failed", cause: ns.localizedDescription)
    }
}
