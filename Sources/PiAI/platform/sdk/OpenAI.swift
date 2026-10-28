import Foundation

// Port of the `openai` 7.19.0 SDK surface pi uses: `client.ts` (`OpenAI`), `core/error.ts`,
// `core/api-promise.ts`, `internal/parse.ts`, `core/streaming.ts` (`Stream.fromSSEResponse`) and the
// `chat.completions.create` / `responses.create` resources.
//
// Not ported (no pi caller): workload identity (legacy and X.509), `provider`, data residency,
// admin-key auth scheme, logging, `fetchOptions`, pagination, `Stream.tee` / `toReadableStream` /
// `fromReadableStream`, websockets, `_request_id` (non-enumerable property),
// `responses.create`'s `_thenUnwrap(addOutputText)` for non-streaming responses.

open class OpenAI: @unchecked Sendable {
    public static let VERSION = "7.19.0"
    public static let DEFAULT_TIMEOUT = 600_000 // 10 minutes

    public struct ClientOptions: Sendable {
        /// Defaults to `process.env['OPENAI_API_KEY']`.
        public var apiKey: String?
        /// Defaults to `process.env['OPENAI_ADMIN_KEY']` (only checked for credentials; scheme Not ported).
        public var adminAPIKey: String?
        /// Defaults to `process.env['OPENAI_ORG_ID']`.
        public var organization: String?
        /// Defaults to `process.env['OPENAI_PROJECT_ID']`.
        public var project: String?
        /// Defaults to `process.env['OPENAI_BASE_URL']`, then `https://api.openai.com/v1`.
        public var baseURL: String?
        public var timeout: Int?
        public var fetch: FetchFunction?
        public var maxRetries: Int?
        public var defaultHeaders: HeadersLike?
        public var defaultQuery: [(String, String)]?
        public var dangerouslyAllowBrowser: Bool?
        /// Swift: the environment `readEnv` consults (default: the process environment).
        public var env: ProviderEnv?

        public init(apiKey: String? = nil, adminAPIKey: String? = nil, organization: String? = nil, project: String? = nil, baseURL: String? = nil, timeout: Int? = nil, fetch: FetchFunction? = nil, maxRetries: Int? = nil, defaultHeaders: HeadersLike? = nil, defaultQuery: [(String, String)]? = nil, dangerouslyAllowBrowser: Bool? = nil, env: ProviderEnv? = nil) {
            self.apiKey = apiKey
            self.adminAPIKey = adminAPIKey
            self.organization = organization
            self.project = project
            self.baseURL = baseURL
            self.timeout = timeout
            self.fetch = fetch
            self.maxRetries = maxRetries
            self.defaultHeaders = defaultHeaders
            self.defaultQuery = defaultQuery
            self.dangerouslyAllowBrowser = dangerouslyAllowBrowser
            self.env = env
        }
    }

    public let apiKey: String?
    public let adminAPIKey: String?
    public let organization: String?
    public let project: String?

    public let baseURL: String
    public let maxRetries: Int
    public let timeout: Int
    let fetch: FetchFunction
    let _options: ClientOptions

    /// API Client for interfacing with the OpenAI API.
    public init(_ clientOptions: ClientOptions = ClientOptions()) throws {
        let env = clientOptions.env ?? ProcessInfo.processInfo.environment
        let baseURL = clientOptions.baseURL ?? readEnv(env, "OPENAI_BASE_URL")
        let apiKey = clientOptions.apiKey ?? readEnv(env, "OPENAI_API_KEY")
        let adminAPIKey = clientOptions.adminAPIKey ?? readEnv(env, "OPENAI_ADMIN_KEY")
        let organization = clientOptions.organization ?? readEnv(env, "OPENAI_ORG_ID")
        let project = clientOptions.project ?? readEnv(env, "OPENAI_PROJECT_ID")
        var options = clientOptions
        options.apiKey = apiKey
        options.adminAPIKey = adminAPIKey
        options.organization = organization
        options.project = project
        options.baseURL = (baseURL?.isEmpty == false ? baseURL : nil) ?? "https://api.openai.com/v1"

        if (apiKey ?? "").isEmpty && (adminAPIKey ?? "").isEmpty {
            throw OpenAIError(
                "Missing credentials. Please pass an `apiKey`, `workloadIdentity`, `adminAPIKey`, or set the `OPENAI_API_KEY` or `OPENAI_ADMIN_KEY` environment variable."
            )
        }

        // Not ported: browser detection (`dangerouslyAllowBrowser`); Swift never runs in a browser.

        self.baseURL = options.baseURL!
        self.timeout = options.timeout ?? OpenAI.DEFAULT_TIMEOUT /* 10 minutes */
        self.maxRetries = options.maxRetries ?? 2
        self.fetch = options.fetch ?? defaultFetch

        if let customHeadersEnv = readEnv(env, "OPENAI_CUSTOM_HEADERS") {
            let parsed = parseCustomHeadersEnv(customHeadersEnv)
            options.defaultHeaders = .nullable(try PiAI.buildHeaders([.record(parsed), options.defaultHeaders]))
        }

        self._options = options
        self.apiKey = apiKey
        self.adminAPIKey = adminAPIKey
        self.organization = organization
        self.project = project
    }

    // MARK: resources

    public var chat: Chat { Chat(client: self) }
    public var responses: Responses { Responses(client: self) }

    public struct Chat: Sendable {
        let client: OpenAI
        public var completions: Completions { Completions(client: client) }
    }

    public struct Completions: Sendable {
        let client: OpenAI
        /// `client.chat.completions.create(body, options)`: `POST /chat/completions`.
        public func create(_ body: JsonValue, _ options: RequestOptions = RequestOptions()) -> APIPromise {
            client.post("/chat/completions", body: body, stream: body["stream"]?.boolValue ?? false, options)
        }
    }

    public struct Responses: Sendable {
        let client: OpenAI
        /// `client.responses.create(body, options)`: `POST /responses`.
        /// Not ported: `_thenUnwrap(addOutputText)` for non-streaming responses.
        public func create(_ body: JsonValue, _ options: RequestOptions = RequestOptions()) -> APIPromise {
            client.post("/responses", body: body, stream: body["stream"]?.boolValue ?? false, options)
        }
    }

    // MARK: client internals

    func defaultQuery() -> [(String, String)]? {
        _options.defaultQuery
    }

    open func validateHeaders(_ headers: NullableHeaders) throws {
        if !(headers.values.get("authorization") ?? "").isEmpty || !(headers.values.get("api-key") ?? "").isEmpty {
            return
        }
        if headers.nulls.contains("authorization") || headers.nulls.contains("api-key") {
            return
        }

        throw PiError(
            "Could not resolve authentication method. Expected either apiKey or adminAPIKey to be set. Or for one of the \"Authorization\" or \"api-key\" headers to be explicitly omitted"
        )
    }

    /// `authHeaders(opts, { bearerAuth: true })` (chat completions and responses use bearer auth only).
    open func authHeaders(_ opts: FinalRequestOptions) throws -> NullableHeaders? {
        try PiAI.buildHeaders([bearerAuth(opts)])
    }

    func bearerAuth(_ opts: FinalRequestOptions) throws -> HeadersLike? {
        guard let apiKey else { return nil }
        return .nullable(try PiAI.buildHeaders([.record([("Authorization", "Bearer \(apiKey)")])]))
    }

    /// `${this.constructor.name}/JS ${VERSION}`.
    open var userAgentClassName: String { "OpenAI" }

    func getUserAgent() -> String {
        "\(userAgentClassName)/JS \(OpenAI.VERSION)"
    }

    func makeStatusError(_ status: Int, _ error: JsonValue?, _ message: String?, _ headers: Headers) -> APIError {
        var normalizedError = error
        if case .object(let object)? = error, object["error"] == nil || object["error"] == .null {
            normalizedError = .object(["error": .object(object)])
        }
        return APIError.generate(status, normalizedError, message, headers)
    }

    func buildURL(_ path: String, _ query: [(String, String)]?) throws -> String {
        let baseURL = self.baseURL
        let urlString = isAbsoluteURL(path)
            ? path
            : baseURL + (baseURL.hasSuffix("/") && path.hasPrefix("/") ? String(path.dropFirst()) : path)

        let defaultQuery = self.defaultQuery()
        return try buildRequestURL(urlString) { pathQuery in
            var merged = query
            if !(defaultQuery ?? []).isEmpty || !pathQuery.isEmpty {
                merged = spreadQuery([pathQuery, defaultQuery, query])
            }
            return merged
        }
    }

    func post(_ path: String, body: JsonValue, stream: Bool, _ options: RequestOptions) -> APIPromise {
        request(FinalRequestOptions(method: "post", path: path, body: body, stream: stream, options))
    }

    func request(_ options: FinalRequestOptions, _ remainingRetries: Int? = nil) -> APIPromise {
        APIPromise(client: self, request: Task { try await self.makeRequest(options, remainingRetries) })
    }

    func parseResponseWithTimeout(_ input: APIResponseProps) async throws -> (APIResult, APIResponseProps) {
        var props = input
        if props.options.stream || props.response.status == 204 || props.response.headers.get("content-length") == "0" {
            return (try await defaultParseResponse(props), props)
        }

        while true {
            let timeout = props.timeout
            let callerSignal = props.options.signal
            let remaining = max(0, props.startTime + timeout - dateNow())
            let timedOut = Locked(false)

            do {
                if callerSignal?.aborted == true {
                    throw APIUserAbortError()
                }
                let parsed = try await raceParse(props, remaining: remaining, callerSignal: callerSignal, timedOut: timedOut)
                return (parsed, props)
            } catch {
                if callerSignal?.aborted == true && !timedOut.current {
                    throw APIUserAbortError()
                }
                if !timedOut.current {
                    throw error
                }

                let retriesRemaining = props.retriesRemaining
                if retriesRemaining == 0 {
                    throw APIConnectionTimeoutError()
                }

                props = try await retryRequest(props.options, retriesRemaining, nil, props.requestSignal)
            }
        }
    }

    /// `Promise.race([defaultParseResponse(...), timeoutPromise])` with the caller abort listener.
    private func raceParse(_ props: APIResponseProps, remaining: Int, callerSignal: AbortSignal?, timedOut: Locked<Bool>) async throws -> APIResult {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<APIResult, any Error>) in
            let settled = Locked(false)
            let cleanup = Locked<(@Sendable () -> Void)?>(nil)
            let settle: @Sendable (Result<APIResult, any Error>) -> Void = { result in
                let first = settled.withLock { s -> Bool in
                    if s { return false }
                    s = true
                    return true
                }
                guard first else { return }
                cleanup.withLock { $0 }?()
                continuation.resume(with: result)
            }
            let timer = setTimeout(Double(remaining)) {
                timedOut.withLock { $0 = true }
                props.controller.abort()
                settle(.failure(APIConnectionTimeoutError()))
            }
            var listenerID: Int?
            if let callerSignal {
                listenerID = callerSignal.addEventListener {
                    if !timedOut.current { settle(.failure(APIUserAbortError())) }
                }
            }
            let registeredID = listenerID
            cleanup.withLock {
                $0 = {
                    timer.cancel()
                    if let registeredID { callerSignal?.removeEventListener(registeredID) }
                }
            }
            if settled.current { cleanup.withLock { $0 }?() }
            Task {
                do {
                    settle(.success(try await self.defaultParseResponse(props)))
                } catch {
                    settle(.failure(error))
                }
            }
        }
    }

    private func makeRequest(_ options: FinalRequestOptions, _ retriesRemainingInput: Int?) async throws -> APIResponseProps {
        let maxRetries = options.maxRetries ?? self.maxRetries
        let retriesRemaining = retriesRemainingInput ?? maxRetries

        // Not ported: prepareOptions / prepareRequest hooks (no-ops).
        let (req, url, timeout) = try await buildRequest(options, retryCount: maxRetries - retriesRemaining)

        let startTime = dateNow()

        let callerSignal = options.signal
        if callerSignal?.aborted == true || req.signal?.aborted == true {
            throw _makeUserAbortError(callerSignal?.aborted == true ? callerSignal! : req.signal!)
        }
        // Request hooks may replace the caller signal before it reaches fetch.
        let controller = createRequestController(req.signal)
        let response: FetchResponse
        do {
            response = try await fetchWithTimeout(url, req, timeout, controller)
        } catch {
            if callerSignal?.aborted == true || req.signal?.aborted == true {
                throw _makeUserAbortError(callerSignal?.aborted == true ? callerSignal! : req.signal!)
            }
            // detect native connection timeout errors
            let isTimeout = isAbortError(error) || looksLikeTimeout(error)
            if retriesRemaining > 0 {
                return try await retryRequest(options, retriesRemaining, nil, req.signal)
            }
            if isTimeout {
                let isHeadersTimeout = (error as? FetchError)?.code == "UND_ERR_HEADERS_TIMEOUT"
                throw APIConnectionTimeoutError(
                    message: isHeadersTimeout
                        ? "Request timed out. Node.js fetch timed out waiting for response headers; " +
                            "configure a matching undici fetch and fetchOptions.dispatcher with an Agent whose headersTimeout is at least the SDK timeout."
                        : nil,
                    cause: error
                )
            }
            // Not ported: getConnectionErrorMessage's undici dispatcher mismatch hint.
            throw APIConnectionError(message: nil, cause: error)
        }

        if !response.ok {
            let shouldRetry = self.shouldRetry(response)
            if retriesRemaining > 0 && shouldRetry {
                // We don't need the body of this response.
                cancelResponseBody(response)
                return try await retryRequest(options, retriesRemaining, response.headers, req.signal)
            }

            let errText: String
            do { errText = try await response.text() } catch { errText = errorMessage(error) }
            let errJSON = safeJSON(errText)
            let errMessage = jsTruthy(errJSON) ? nil : errText

            throw makeStatusError(response.status, errJSON, errMessage, response.headers)
        }

        return APIResponseProps(
            response: response,
            options: options,
            controller: controller,
            requestSignal: req.signal,
            startTime: startTime,
            timeout: timeout,
            retriesRemaining: retriesRemaining
        )
    }

    func fetchWithTimeout(_ url: String, _ initial: FinalizedRequest, _ ms: Int, _ controller: RequestController) async throws -> FetchResponse {
        // The caller signal is composed into `controller.signal` (createRequestController), so no extra listener.
        let timer = setTimeout(Double(ms)) { controller.abort() }
        defer { timer.cancel() }
        guard let requestURL = URL(string: url) else { throw PiError("Invalid URL", name: "TypeError") }
        let request = FetchRequest(
            url: requestURL,
            // Custom methods like 'patch' need to be uppercased
            method: initial.method.uppercased(),
            headers: initial.headers,
            body: initial.body,
            signal: controller.signal
        )
        return try await fetch(request)
    }

    private func shouldRetry(_ response: FetchResponse) -> Bool {
        // Note this is not a standard header.
        let shouldRetryHeader = response.headers.get("x-should-retry")

        // If the server explicitly says whether or not to retry, obey.
        if shouldRetryHeader == "true" { return true }
        if shouldRetryHeader == "false" { return false }

        // Retry on request timeouts.
        if response.status == 408 { return true }

        // Retry on lock timeouts.
        if response.status == 409 { return true }

        // Retry on rate limits.
        if response.status == 429 { return true }

        // Retry internal errors.
        if response.status >= 500 { return true }

        return false
    }

    private func retryRequest(_ options: FinalRequestOptions, _ retriesRemaining: Int, _ responseHeaders: Headers?, _ requestSignal: AbortSignal?) async throws -> APIResponseProps {
        var timeoutMillis: Double?

        // Note the `retry-after-ms` header may not be standard, but is a good idea and we'd like proactive support for it.
        if let retryAfterMillisHeader = responseHeaders?.get("retry-after-ms"), !retryAfterMillisHeader.isEmpty {
            let timeoutMs = jsParseFloat(retryAfterMillisHeader)
            if !timeoutMs.isNaN {
                timeoutMillis = timeoutMs
            }
        }

        // About the Retry-After header: https://developer.mozilla.org/en-US/docs/Web/HTTP/Headers/Retry-After
        if let retryAfterHeader = responseHeaders?.get("retry-after"), !retryAfterHeader.isEmpty, timeoutMillis == nil {
            let timeoutSeconds = jsParseFloat(retryAfterHeader)
            if !timeoutSeconds.isNaN {
                timeoutMillis = timeoutSeconds * 1000
            } else {
                timeoutMillis = jsDateParse(retryAfterHeader) - Double(dateNow())
            }
        }

        // If the API asks us to wait a certain amount of time, just do what it
        // says, but otherwise calculate a default
        if timeoutMillis == nil || !timeoutMillis!.isFinite || timeoutMillis! < 0 || timeoutMillis! > 60 * 1000 {
            let maxRetries = options.maxRetries ?? self.maxRetries
            timeoutMillis = calculateDefaultRetryTimeoutMillis(retriesRemaining, maxRetries)
        }
        let retrySignals: [AbortSignal?] = requestSignal === options.signal ? [requestSignal] : [requestSignal, options.signal]
        let combined = combineAbortSignals(retrySignals)
        defer { combined.cleanup() }
        do {
            try await sleep(Int(timeoutMillis!.rounded(.up)), combined.signal)
        } catch {
            if let abortedSignal = retrySignals.compactMap({ $0 }).first(where: { $0.aborted }) {
                throw _makeUserAbortError(abortedSignal)
            }
            throw error
        }

        return try await makeRequest(options, retriesRemaining - 1)
    }

    private func calculateDefaultRetryTimeoutMillis(_ retriesRemaining: Int, _ maxRetries: Int) -> Double {
        let initialRetryDelay = 0.5
        let maxRetryDelay = 8.0

        let numRetries = maxRetries - retriesRemaining

        // Apply exponential backoff, but not more than the max.
        let sleepSeconds = min(initialRetryDelay * pow(2, Double(numRetries)), maxRetryDelay)

        // Apply some jitter, take up to at most 25 percent of the retry time.
        let jitter = 1 - Double.random(in: 0..<1) * 0.25

        return sleepSeconds * jitter * 1000
    }

    /// Builds a request: URL, timeout, body and headers (validated).
    open func buildRequest(_ inputOptions: FinalRequestOptions, retryCount: Int = 0) async throws -> (req: FinalizedRequest, url: String, timeout: Int) {
        var options = inputOptions

        let url = try buildURL(options.path, options.query)
        if options.timeout != nil {
            _ = try validatePositiveInteger("timeout", options.timeout) { OpenAIError($0) }
        }
        let timeout = options.timeout ?? self.timeout
        options.timeout = timeout
        let authenticationHeaders = try authHeaders(inputOptions)
        let (bodyHeaders, body) = buildJSONBody(options.body)

        let reqHeaders = try buildHeaders(
            options: inputOptions,
            timeout: timeout,
            bodyHeaders: bodyHeaders,
            authenticationHeaders: authenticationHeaders,
            retryCount: retryCount
        )

        let req = FinalizedRequest(method: options.method, headers: reqHeaders, signal: options.signal, body: body)
        return (req, url, timeout)
    }

    private func buildHeaders(options: FinalRequestOptions, timeout: Int, bodyHeaders: HeadersLike?, authenticationHeaders: NullableHeaders?, retryCount: Int) throws -> Headers {
        // Not ported: idempotency header (`idempotencyHeader` is unset on OpenAI).
        var base: [(String, String?)] = [
            ("Accept", "application/json"),
            ("User-Agent", getUserAgent()),
            ("X-Stainless-Retry-Count", String(retryCount)),
        ]
        if timeout != 0 {
            base.append(("X-Stainless-Timeout", String(timeout / 1000)))
        }
        base.append(contentsOf: getPlatformHeaders(OpenAI.VERSION))
        base.append(("OpenAI-Organization", organization))
        base.append(("OpenAI-Project", project))

        let headers = try PiAI.buildHeaders([
            .record([]),
            .record(base),
            authenticationHeaders.map { .nullable($0) },
            _options.defaultHeaders,
            bodyHeaders,
            options.headers,
        ])

        try validateHeaders(headers)

        return headers.values
    }

    private func _makeUserAbortError(_ signal: AbortSignal) -> APIUserAbortError {
        APIUserAbortError(cause: signal.reason)
    }

    // MARK: internal/parse.ts

    func defaultParseResponse(_ props: APIResponseProps) async throws -> APIResult {
        let response = props.response
        do {
            if props.options.stream {
                // Note: there is an invariant here that isn't represented in the type system
                // that if you set `stream: true` the response type must also be `Stream<T>`
                return .stream(Stream.fromSSEResponse(response, props.controller))
            }

            // fetch refuses to read the body when the status code is 204.
            if response.status == 204 {
                return .null
            }

            let contentType = response.headers.get("content-type")
            let mediaType = contentType.map { jsTrim(String($0.split(separator: ";", omittingEmptySubsequences: false).first ?? "")).lowercased() }
            let isJSON = mediaType?.contains("application/json") == true || mediaType?.hasSuffix("+json") == true
            if isJSON {
                let contentLength = response.headers.get("content-length")
                if contentLength == "0" {
                    // if there is no content we can't do anything
                    return .undefined
                }

                let bodyText = try await response.text()
                if bodyText.isEmpty {
                    // Some servers respond with an empty body and a JSON content-type but
                    // without a `content-length: 0` header. Treat this the same as an explicit
                    // `content-length: 0` instead of letting `JSON.parse` throw an opaque `SyntaxError`.
                    return .undefined
                }

                do {
                    return .json(try JsonValue.parse(bodyText))
                } catch {
                    throw PiError(String(describing: error), name: "SyntaxError")
                }
            }

            let text = try await response.text()
            return .text(text)
        } catch {
            throw asAbortError(error, props.controller.signal)
        }
    }
}

/// `asAbortError(error, signal)`: the signal's own reason becomes a `DOMException('AbortError')`.
private func asAbortError(_ error: any Error, _ signal: AbortSignal) -> any Error {
    if !signal.aborted || !isSameError(error, signal.reason) || isAbortError(error) {
        return error
    }
    return AbortError("This operation was aborted")
}

/// `createRequestController(callerSignal)`: a fresh controller whose signal also follows the caller's.
func createRequestController(_ callerSignal: AbortSignal?) -> RequestController {
    let controller = AbortController()
    guard let callerSignal else { return RequestController(controller) }
    // Native composition keeps cancellation active after response headers without
    // retaining an abort listener on the caller's signal or changing its reason.
    let composed = AbortSignal.any([controller.signal, callerSignal])
    return RequestController(controller, signal: composed)
}

// MARK: - APIResponseProps / APIPromise

public struct APIResponseProps: Sendable {
    public var response: FetchResponse
    public var options: FinalRequestOptions
    public var controller: RequestController
    public var requestSignal: AbortSignal?
    public var startTime: Int
    /// `#responseAttempts.get(controller)`: the attempt's timeout and remaining retries.
    var timeout: Int
    var retriesRemaining: Int
}

extension OpenAI {
    /// Parsed response data (`T` of `APIPromise<T>`).
    public enum APIResult: Sendable {
        case stream(Stream)
        case json(JsonValue)
        case text(String)
        case null
        case undefined

        public var stream: Stream? { if case .stream(let s) = self { return s } else { return nil } }
        public var json: JsonValue? { if case .json(let j) = self { return j } else { return nil } }
    }

    /// A subclass of `Promise` providing additional helper methods for interacting with the SDK.
    /// The request starts when the promise is created, like the JS promise.
    public final class APIPromise: Sendable {
        private let client: OpenAI
        private let responsePromise: Task<APIResponseProps, any Error>
        private let parsedPromise = Locked<Task<(APIResult, APIResponseProps), any Error>?>(nil)

        init(client: OpenAI, request: Task<APIResponseProps, any Error>) {
            self.client = client
            self.responsePromise = request
        }

        /// Gets the raw `Response` instance instead of parsing the response data.
        public func asResponse() async throws -> FetchResponse {
            try await awaitTask(responsePromise).response
        }

        /// Gets the parsed response data, the raw `Response` instance and the ID of the request.
        /// A body timeout can retry after the original raw response has arrived; the response
        /// reported is the one the data was parsed from.
        public func withResponse() async throws -> (data: APIResult, response: FetchResponse, request_id: String?) {
            let (data, props) = try await parse()
            return (data, props.response, props.response.headers.get("x-request-id"))
        }

        /// `await promise`.
        public func value() async throws -> APIResult {
            try await parse().0
        }

        private func parse() async throws -> (APIResult, APIResponseProps) {
            let task = parsedPromise.withLock { existing -> Task<(APIResult, APIResponseProps), any Error> in
                if let existing { return existing }
                let responsePromise = self.responsePromise
                let client = self.client
                let task = Task { try await client.parseResponseWithTimeout(try await responsePromise.value) }
                existing = task
                return task
            }
            return try await awaitTask(task)
        }
    }
}

// MARK: - core/streaming.ts

extension OpenAI {
    /// A single-consumption asynchronous API response stream of parsed JSON events.
    ///
    /// Breaking out of a response-backed stream early aborts its request.
    /// Swift: events are decoded by a reader task ahead of the consumer; once the controller is
    /// aborted no further events are delivered (the upstream generator checks the signal before each yield).
    public struct Stream: AsyncSequence, Sendable {
        public typealias Element = JsonValue

        /// Abort controller for the underlying request.
        public let controller: RequestController
        public let response: FetchResponse
        private let consumed = Locked(false)

        /// Decodes an SSE response into parsed JSON events.
        ///
        /// The resulting stream can be consumed only once, ignores events after `[DONE]`, and
        /// surfaces API error payloads as `APIError` instances. Named `thread.*` events are
        /// yielded as `{ event, data }`.
        public static func fromSSEResponse(_ response: FetchResponse, _ controller: RequestController) -> Stream {
            Stream(controller: controller, response: response)
        }

        private init(controller: RequestController, response: FetchResponse) {
            self.controller = controller
            self.response = response
        }

        public struct AsyncIterator: AsyncIteratorProtocol {
            var base: AsyncThrowingStream<JsonValue, any Error>.AsyncIterator
            let signal: AbortSignal
            let consumer: ConsumerState?
            /// Set when the reader task itself aborted the controller after its generator ended (the
            /// upstream `finally`). Events and the error it buffered before that are still delivered,
            /// as the upstream consumer receives the generator's rejection.
            var selfAborted: Locked<Bool>? = nil

            private var externallyAborted: Bool { signal.aborted && selfAborted?.current != true }

            public mutating func next() async throws -> JsonValue? {
                if externallyAborted { return nil }
                let value: JsonValue?
                do {
                    value = try await base.next()
                } catch {
                    consumer?.finished()
                    throw error
                }
                guard let value else {
                    consumer?.finished()
                    return nil
                }
                if externallyAborted { return nil }
                return value
            }
        }

        /// Swift: the upstream generator's `done` flag as seen by the consumer. Events are decoded ahead
        /// of the consumer, so "the user `break`s" is detected when the iterator is released before it
        /// reached the end of the stream.
        public final class ConsumerState: @unchecked Sendable {
            private let done = Locked(false)
            private let controller: RequestController

            init(_ controller: RequestController) { self.controller = controller }

            func finished() { done.withLock { $0 = true } }

            deinit {
                // If the user `break`s, abort the ongoing request.
                if !done.current { controller.abort() }
            }
        }

        public func makeAsyncIterator() -> AsyncIterator {
            let (stream, continuation) = AsyncThrowingStream<JsonValue, any Error>.makeStream(bufferingPolicy: .unbounded)
            let wasConsumed = consumed.withLock { c -> Bool in
                defer { c = true }
                return c
            }
            if wasConsumed {
                continuation.finish(throwing: OpenAIError("Cannot iterate over a consumed stream, use `.tee()` to split the stream."))
                return AsyncIterator(base: stream.makeAsyncIterator(), signal: AbortController().signal, consumer: nil)
            }
            let controller = self.controller
            let response = self.response
            let done = Locked(false)
            let selfAborted = Locked(false)
            let task = Task {
                var receivedCompletionSentinel = false
                do {
                    try await _iterSSEMessages(response, controller) { sse in
                        if sse.data == "[DONE]" {
                            receivedCompletionSentinel = true
                            return false
                        }

                        if sse.event == nil || !sse.event!.hasPrefix("thread.") {
                            let data: JsonValue
                            do {
                                data = try JsonValue.parse(sse.data)
                            } catch {
                                throw PiError("Error reading response: malformed server-sent event JSON.", name: "SyntaxError")
                            }

                            if sse.event == "error" {
                                let error = data["error"].flatMap { $0.isNull ? nil : $0 } ?? data
                                throw APIError(nil, error, nil, response.headers)
                            }

                            if jsTruthy(data), jsTruthy(data["error"]) {
                                throw APIError(nil, data["error"], nil, response.headers)
                            }

                            continuation.yield(data)
                        } else {
                            let data: JsonValue
                            do {
                                data = try JsonValue.parse(sse.data)
                            } catch {
                                throw PiError("Error reading response: malformed server-sent event JSON.", name: "SyntaxError")
                            }
                            continuation.yield(.object(["event": .string(sse.event!), "data": data]))
                        }
                        return true
                    }
                    done.withLock { $0 = true }
                    continuation.finish()
                } catch {
                    // Abort errors and cleanup failures after the completion sentinel are non-fatal.
                    if receivedCompletionSentinel || isTransportAbortError(error) || (controller.signal.aborted && isSameError(error, controller.signal.reason)) {
                        continuation.finish()
                    } else {
                        continuation.finish(throwing: error)
                    }
                }
                // If the user `break`s, abort the ongoing request.
                if !done.current {
                    selfAborted.withLock { flag in
                        if !controller.signal.aborted { flag = true }
                    }
                    controller.abort()
                }
            }
            continuation.onTermination = { termination in
                if case .cancelled = termination {
                    // Abort before nested iterator cleanup can wait on the response body's cancellation.
                    if !done.current { controller.abort() }
                    task.cancel()
                }
            }
            return AsyncIterator(base: stream.makeAsyncIterator(), signal: controller.signal, consumer: ConsumerState(controller), selfAborted: selfAborted)
        }
    }
}

private func isTransportAbortError(_ error: any Error) -> Bool {
    !(error is OpenAI.APIError) && isAbortError(error)
}

// MARK: - core/error.ts

extension OpenAI {
    open class OpenAIError: Error, CustomStringConvertible, LocalizedError, @unchecked Sendable {
        public let message: String
        public let cause: (any Error)?
        public init(_ message: String, cause: (any Error)? = nil) {
            self.message = message
            self.cause = cause
        }
        public var description: String { message }
        public var errorDescription: String? { message }
    }

    open class APIError: OpenAIError, ProviderError, @unchecked Sendable {
        /// HTTP status for the response that caused the error
        public let status: Int?
        /// HTTP headers for the response that caused the error
        public let headers: Headers?
        /// JSON body of the response that caused the error
        public let error: JsonValue?

        public let code: JsonValue?
        public let param: JsonValue?
        public let type: JsonValue?

        public let requestID: String?

        public init(_ status: Int?, _ error: JsonValue?, _ message: String?, _ headers: Headers?, cause: (any Error)? = nil) {
            self.status = status
            self.headers = headers
            self.requestID = headers?.get("x-request-id")
            self.error = error

            self.code = error?.objectValue?["code"]
            self.param = error?.objectValue?["param"]
            self.type = error?.objectValue?["type"]
            super.init(APIError.makeMessage(status, error, message), cause: cause)
        }

        static func makeMessage(_ status: Int?, _ error: JsonValue?, _ message: String?) -> String {
            let msg: String?
            if let errorMessage = error?.objectValue?["message"], jsTruthy(errorMessage) {
                msg = errorMessage.stringValue ?? errorMessage.serialized()
            } else if jsTruthy(error) {
                msg = error!.serialized()
            } else {
                msg = message
            }

            if let status, status != 0, let msg, !msg.isEmpty {
                return "\(status) \(msg)"
            }
            if let status, status != 0 {
                return "\(status) status code (no body)"
            }
            if let msg, !msg.isEmpty {
                return msg
            }
            return "(no status code or body)"
        }

        public static func generate(_ status: Int?, _ errorResponse: JsonValue?, _ message: String?, _ headers: Headers?) -> APIError {
            guard let status, status != 0, let headers else {
                // castToError(errorResponse): Swift keeps the JSON in the message only.
                return APIConnectionError(message: message, cause: errorResponse.map { PiError($0.serialized()) })
            }

            let error = errorResponse?.objectValue?["error"]

            if status == 400 { return BadRequestError(status, error, message, headers) }
            if status == 401 { return AuthenticationError(status, error, message, headers) }
            if status == 403 { return PermissionDeniedError(status, error, message, headers) }
            if status == 404 { return NotFoundError(status, error, message, headers) }
            if status == 409 { return ConflictError(status, error, message, headers) }
            if status == 422 { return UnprocessableEntityError(status, error, message, headers) }
            if status == 429 { return RateLimitError(status, error, message, headers) }
            if status >= 500 { return InternalServerError(status, error, message, headers) }
            return APIError(status, error, message, headers)
        }
    }

    public final class APIUserAbortError: APIError, @unchecked Sendable {
        public init(message: String? = nil, cause: (any Error)? = nil) {
            super.init(nil, nil, (message ?? "").isEmpty ? "Request was aborted." : message, nil, cause: cause)
        }
    }

    open class APIConnectionError: APIError, @unchecked Sendable {
        public init(message: String? = nil, cause: (any Error)? = nil) {
            super.init(nil, nil, (message ?? "").isEmpty ? "Connection error." : message, nil, cause: cause)
        }
    }

    public final class APIConnectionTimeoutError: APIConnectionError, @unchecked Sendable {
        public override init(message: String? = nil, cause: (any Error)? = nil) {
            super.init(message: message ?? "Request timed out.", cause: cause)
        }
    }

    public final class BadRequestError: APIError, @unchecked Sendable {}
    public final class AuthenticationError: APIError, @unchecked Sendable {}
    public final class PermissionDeniedError: APIError, @unchecked Sendable {}
    public final class NotFoundError: APIError, @unchecked Sendable {}
    public final class ConflictError: APIError, @unchecked Sendable {}
    public final class UnprocessableEntityError: APIError, @unchecked Sendable {}
    public final class RateLimitError: APIError, @unchecked Sendable {}
    public final class InternalServerError: APIError, @unchecked Sendable {}
}

// MARK: - utils/error-body.ts probing (`error.status`, `error.error`)

extension OpenAI.APIError: SdkErrorShapeConvertible {
    public var sdkErrorShape: any SdkErrorShape {
        ProviderSdkError(message, status: status.map { .number(Double($0)) }, error: error.map { .value($0) })
    }
}
