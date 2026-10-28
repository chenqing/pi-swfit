import Foundation

// Port of the `@anthropic-ai/sdk` 0.129.0 surface pi uses: `client.ts` (`BaseAnthropic` / `Anthropic`),
// `core/error.ts`, `core/api-promise.ts` (`asResponse`), `resources/beta/messages/messages.ts`
// (`beta.messages.create`) and the workload identity credentials in `lib/credentials/`
// (`token-cache.ts`, `identity-token.ts`, `oidc-federation.ts`, `types.ts`, `credential-chain.ts`).
//
// Not ported (no pi caller): the default credential chain (`profile`, `ANTHROPIC_PROFILE` config files,
// `defaultCredentials` / `loadConfigWithSource`), `user_oauth` profiles (`userOAuthProvider`), the on-disk
// federation token cache (`cachedExchangeProvider`, `checkCredentialsFileSafety`,
// `writeCredentialsFileAtomic`), middleware (`middleware`, `backendMiddleware`, `RetryableError`),
// logging, `fetchOptions`, `webhookKey`, pagination, `defaultBaseURL`, browser detection,
// `armAbandonmentBackstop`, stream request bodies (`isStreamBody`), form-urlencoded bodies,
// `APIPromise` parsing (`withResponse`, `then`; pi reads `asResponse()` and decodes the SSE itself),
// every other resource.

open class Anthropic: @unchecked Sendable {
    public static let VERSION = "0.129.0"
    public static let DEFAULT_TIMEOUT = 600_000 // 10 minutes

    public struct ClientOptions: Sendable {
        /// Defaults to `process.env['ANTHROPIC_API_KEY'] ?? null`. `.some(nil)` is an explicit `null`;
        /// `nil` (`.none`) is `undefined`.
        public var apiKey: String??
        /// Defaults to `process.env['ANTHROPIC_AUTH_TOKEN'] ?? null`. `.some(nil)` is an explicit `null`.
        public var authToken: String??
        /// Defaults to `process.env['ANTHROPIC_BASE_URL'] ?? https://api.anthropic.com`.
        public var baseURL: String?
        public var timeout: Int?
        public var fetch: FetchFunction?
        public var maxRetries: Int?
        public var defaultHeaders: HeadersLike?
        public var defaultQuery: [(String, String)]?
        public var dangerouslyAllowBrowser: Bool?
        /// A custom access token provider, wrapped in a `TokenCache`.
        public var credentials: AccessTokenProvider?
        /// An explicit workload identity configuration, resolved with `resolveCredentialsFromConfig`.
        public var config: AnthropicConfig?
        /// Swift: the environment `readEnv` consults (default: the process environment).
        public var env: ProviderEnv?

        /// `InternalClientOptions.__auth`: the auth state a `withOptions()` clone shares.
        var __auth: AuthState?
        /// `InternalClientOptions.__baseURLIsExplicit`.
        var __baseURLIsExplicit: Bool?

        public init(apiKey: String?? = nil, authToken: String?? = nil, baseURL: String? = nil, timeout: Int? = nil, fetch: FetchFunction? = nil, maxRetries: Int? = nil, defaultHeaders: HeadersLike? = nil, defaultQuery: [(String, String)]? = nil, dangerouslyAllowBrowser: Bool? = nil, credentials: AccessTokenProvider? = nil, config: AnthropicConfig? = nil, env: ProviderEnv? = nil) {
            self.apiKey = apiKey
            self.authToken = authToken
            self.baseURL = baseURL
            self.timeout = timeout
            self.fetch = fetch
            self.maxRetries = maxRetries
            self.defaultHeaders = defaultHeaders
            self.defaultQuery = defaultQuery
            self.dangerouslyAllowBrowser = dangerouslyAllowBrowser
            self.credentials = credentials
            self.config = config
            self.env = env
        }
    }

    public let apiKey: String?
    public let authToken: String?

    /// The active credential provider.
    ///
    /// Clones returned by `withOptions` share the parent's auth state (provider, token cache and any
    /// resolution error) unless the caller passes an explicit `apiKey`, `authToken`, `credentials` or `config` override.
    public var credentials: AccessTokenProvider? {
        _authState.provider
    }
    let _authState: AuthState
    /// Whether `baseURL` was chosen by the caller (constructor arg or env var) rather than derived.
    /// Non-explicit base URLs may be replaced by a config-supplied host.
    let _baseURLIsExplicit: Bool

    private let _baseURL: Locked<String>
    public var baseURL: String { _baseURL.current }
    public let maxRetries: Int
    public let timeout: Int

    let fetch: FetchFunction
    let _options: ClientOptions
    let env: ProviderEnv

    /// API Client for interfacing with the Anthropic API.
    public required init(_ clientOptions: ClientOptions = ClientOptions()) throws {
        let env = clientOptions.env ?? ProcessInfo.processInfo.environment
        let baseURL = clientOptions.baseURL ?? readEnv(env, "ANTHROPIC_BASE_URL")
        var apiKey = clientOptions.apiKey
        var authToken = clientOptions.authToken
        // Not ported: `profile` (the default credential chain).
        if apiKey == nil {
            apiKey = .some(readEnv(env, "ANTHROPIC_API_KEY"))
        }
        if authToken == nil {
            authToken = .some(readEnv(env, "ANTHROPIC_AUTH_TOKEN"))
        }
        var options = clientOptions
        options.apiKey = apiKey
        options.authToken = authToken
        options.baseURL = (baseURL?.isEmpty == false ? baseURL : nil) ?? "https://api.anthropic.com"

        // Not ported: browser detection (`dangerouslyAllowBrowser`); Swift never runs in a browser.

        self._baseURL = Locked(options.baseURL!)
        // After destructuring, `baseURL` is the constructor arg or ANTHROPIC_BASE_URL — both count as an
        // explicit choice that a config base_url must not override. withOptions() propagates the parent's
        // flag via __baseURLIsExplicit so a non-overriding clone doesn't mistake the inherited baseURL for
        // a caller-supplied one.
        self._baseURLIsExplicit = clientOptions.__baseURLIsExplicit ?? (baseURL?.isEmpty == false)
        self.timeout = options.timeout ?? Anthropic.DEFAULT_TIMEOUT /* 10 minutes */
        self.maxRetries = try validatePositiveInteger("maxRetries", options.maxRetries ?? 2) { AnthropicError($0) }
        self.fetch = options.fetch ?? defaultFetch
        self.env = env

        if let customHeadersEnv = readEnv(env, "ANTHROPIC_CUSTOM_HEADERS") {
            var parsed: [(String, String?)] = []
            for line in customHeadersEnv.split(separator: "\n", omittingEmptySubsequences: false) {
                guard let colon = line.firstIndex(of: ":") else { continue }
                let name = jsTrim(String(line[..<colon]))
                let value = jsTrim(String(line[line.index(after: colon)...]))
                if let index = parsed.firstIndex(where: { $0.0 == name }) {
                    parsed[index].1 = value
                } else {
                    parsed.append((name, value))
                }
            }
            options.defaultHeaders = .nullable(buildAnthropicHeaders([.record(parsed), options.defaultHeaders]))
        }

        let inherited = clientOptions.__auth
        // Never persist the internal __auth handle on _options — it's a one-shot constructor signal.
        options.__auth = nil
        options.__baseURLIsExplicit = nil
        self._options = options

        self.apiKey = apiKey ?? nil
        self.authToken = authToken ?? nil

        if let inherited {
            self._authState = inherited
            if !_baseURLIsExplicit, let inheritedBaseURL = inherited.baseURL {
                _baseURL.withLock { $0 = inheritedBaseURL }
            }
        } else {
            self._authState = AuthState()

            // apiKey/authToken win over credentials/config; don't build a token cache or resolve a
            // config that the request path will then ignore.
            if self.apiKey == nil && self.authToken == nil {
                if let credentials = options.credentials {
                    _authState.provider = credentials
                    _authState.tokenCache = _makeTokenCache(credentials)
                } else if let config = options.config {
                    let result = try resolveCredentialsFromConfig(config, _credentialResolverOptions())
                    _authState.provider = result.provider
                    _authState.tokenCache = _makeTokenCache(result.provider)
                    _authState.extraHeaders = result.extraHeaders
                    _applyCredentialBaseURL(result.baseURL)
                } else if _shouldResolveDefaultCredentials() {
                    // Not ported: lazy resolution from the default credential chain (config files,
                    // ANTHROPIC_PROFILE); with no explicit auth, validateHeaders reports the missing method.
                }
            }
        }
    }

    /// Whether to lazily resolve auth from the default credential chain when no explicit auth is
    /// configured. Called once from the constructor, so overrides must not depend on subclass instance
    /// state. Subclasses that bring their own auth scheme return false.
    open func _shouldResolveDefaultCredentials() -> Bool {
        true
    }

    /// Stores a config-supplied base URL on the shared auth state and, if the caller did not pin
    /// `baseURL` via constructor option or env, adopts it as this client's outbound API host.
    private func _applyCredentialBaseURL(_ baseURL: String?) {
        guard let baseURL, !baseURL.isEmpty else { return }
        let normalized = stripTrailingSlashes(baseURL)
        _authState.baseURL = normalized
        if !_baseURLIsExplicit {
            _baseURL.withLock { $0 = normalized }
        }
    }

    /// Options bag passed into the credential chain. `baseURL` here is only the fallback host for the
    /// token-exchange POST when the config itself omits `base_url`.
    private func _credentialResolverOptions() -> ResolverOptions {
        ResolverOptions(baseURL: baseURL, fetch: _credentialsFetch(), userAgent: getUserAgent(), env: env)
    }

    /// A `Fetch` for first-party credential token-exchange requests.
    /// Not ported: routing through the client's middleware chain.
    private func _credentialsFetch() -> FetchFunction {
        fetch
    }

    private func _makeTokenCache(_ provider: @escaping AccessTokenProvider) -> TokenCache {
        // Not ported: logging advisory refresh failures (`loggerFor(this).debug`).
        TokenCache(provider)
    }

    /// Create a new client instance re-using the same options given to the current client with optional
    /// overriding. A non-nil field of `options` counts as present (`'key' in options`).
    public func withOptions(_ options: ClientOptions) throws -> Self {
        // Share the auth state object unless the caller passes any auth-related key.
        let overridesStructuredAuth = options.credentials != nil || options.config != nil
        let overridesAuth = options.apiKey != nil || options.authToken != nil || overridesStructuredAuth
        var merged = _options
        // Only forward baseURL when the caller (or env) explicitly chose it.
        if _baseURLIsExplicit { merged.baseURL = baseURL }
        merged.maxRetries = maxRetries
        merged.timeout = timeout
        merged.fetch = fetch
        merged.apiKey = .some(apiKey)
        merged.authToken = .some(authToken)
        merged.credentials = credentials
        // When the caller passes a structured-credential override, drop inherited structured-credential
        // options so only `...options` supplies them.
        if overridesStructuredAuth {
            merged.credentials = nil
            merged.config = nil
        }
        if let value = options.apiKey { merged.apiKey = value }
        if let value = options.authToken { merged.authToken = value }
        if let value = options.baseURL { merged.baseURL = value }
        if let value = options.timeout { merged.timeout = value }
        if let value = options.fetch { merged.fetch = value }
        if let value = options.maxRetries { merged.maxRetries = value }
        if let value = options.defaultHeaders { merged.defaultHeaders = value }
        if let value = options.defaultQuery { merged.defaultQuery = value }
        if let value = options.dangerouslyAllowBrowser { merged.dangerouslyAllowBrowser = value }
        if let value = options.credentials { merged.credentials = value }
        if let value = options.config { merged.config = value }
        if let value = options.env { merged.env = value }
        // Always set __auth so any stale value is overwritten. nil means "build fresh auth from these options".
        merged.__auth = overridesAuth ? nil : _authState
        merged.__baseURLIsExplicit = options.baseURL != nil ? true : _baseURLIsExplicit
        return try Self(merged)
    }

    // MARK: resources

    public var beta: Beta { Beta(client: self) }

    public struct Beta: Sendable {
        let client: Anthropic
        public var messages: BetaMessages { BetaMessages(client: client) }
    }

    public struct BetaMessages: Sendable {
        let client: Anthropic

        /// Send a structured list of input messages with text and/or image content, and the model will
        /// generate the next message in the conversation.
        public func create(_ params: JsonValue, _ options: RequestOptions = RequestOptions()) throws -> APIPromise {
            // Transform deprecated output_format to output_config.format
            let modifiedParams = try transformOutputFormat(params)

            var body = modifiedParams.objectValue ?? JsonObject()
            let betas = body["betas"]
            let user_profile_id = body["user_profile_id"]
            let workspace_id = body["workspace_id"]
            body["betas"] = nil
            body["user_profile_id"] = nil
            body["workspace_id"] = nil

            // Not ported: `console.warn` for DEPRECATED_MODELS (empty) and MODELS_TO_WARN_WITH_THINKING_ENABLED.

            var timeout = options.timeout ?? client._options.timeout
            if !jsTruthy(body["stream"]) && timeout == nil {
                let model = body["model"]?.stringValue ?? ""
                let maxNonstreamingTokens = MODEL_NONSTREAMING_TOKENS[model]
                timeout = try client.calculateNonstreamingTimeout(jsNumber(body["max_tokens"]), maxNonstreamingTokens)
            }

            // Not ported: `stainlessHelperHeader(body.tools, body.messages)`; helper tags are JS symbols
            // on SDK-built objects and never appear on JSON payloads.

            var betaHeaders: [(String, String?)] = []
            if let betas, !betas.isNull { betaHeaders.append(("anthropic-beta", jsToString(betas))) }
            if let user_profile_id, !user_profile_id.isNull { betaHeaders.append(("anthropic-user-profile-id", jsToString(user_profile_id))) }
            if let workspace_id, !workspace_id.isNull { betaHeaders.append(("anthropic-workspace-id", jsToString(workspace_id))) }

            var requestOptions = options
            requestOptions.timeout = options.timeout ?? timeout ?? 600000
            requestOptions.headers = .nullable(buildAnthropicHeaders([.record(betaHeaders), options.headers]))
            return client.post("/v1/messages?beta=true", body: .object(body), stream: modifiedParams["stream"]?.boolValue ?? false, requestOptions)
        }
    }

    // MARK: client internals

    func defaultQuery() -> [(String, String)]? {
        _options.defaultQuery
    }

    open func validateHeaders(_ headers: NullableHeaders) throws {
        if !(headers.values.get("x-api-key") ?? "").isEmpty || !(headers.values.get("authorization") ?? "").isEmpty {
            return
        }
        if let error = _authState.error {
            throw error
        }
        if _authState.tokenCache != nil {
            return // auth will be injected per-request via authHeaders
        }

        if let apiKey, !apiKey.isEmpty, !(headers.values.get("x-api-key") ?? "").isEmpty {
            return
        }
        if headers.nulls.contains("x-api-key") {
            return
        }

        if let authToken, !authToken.isEmpty, !(headers.values.get("authorization") ?? "").isEmpty {
            return
        }
        if headers.nulls.contains("authorization") {
            return
        }

        throw PiError(
            "Could not resolve authentication method. Expected one of apiKey, authToken, credentials, config, or profile to be set. Or for one of the \"X-Api-Key\" or \"Authorization\" headers to be explicitly omitted"
        )
    }

    open func authHeaders(_ opts: FinalRequestOptions, _ flags: RequestAuthFlags) async throws -> NullableHeaders? {
        // Not ported: waiting for lazy credential resolution (the default credential chain).
        if _authState.error != nil {
            return nil
        }
        // If we have a token cache and no API key is set, use token auth
        if let tokenCache = _authState.tokenCache, apiKey == nil {
            let token = try await tokenCache.getToken()
            flags.usedTokenCache = true
            return buildAnthropicHeaders([.record([("Authorization", "Bearer \(token)")])])
        }
        return buildAnthropicHeaders([apiKeyAuth(opts).map { .nullable($0) }, bearerAuth(opts).map { .nullable($0) }])
    }

    open func apiKeyAuth(_ opts: FinalRequestOptions) -> NullableHeaders? {
        guard let apiKey else { return nil }
        return buildAnthropicHeaders([.record([("X-Api-Key", apiKey)])])
    }

    open func bearerAuth(_ opts: FinalRequestOptions) -> NullableHeaders? {
        guard let authToken else { return nil }
        return buildAnthropicHeaders([.record([("Authorization", "Bearer \(authToken)")])])
    }

    func getUserAgent() -> String {
        "Anthropic/JS \(Anthropic.VERSION)"
    }

    func makeStatusError(_ status: Int, _ error: JsonValue?, _ message: String?, _ headers: Headers) -> APIError {
        APIError.generate(status, error, message, headers)
    }

    func buildURL(_ path: String, _ query: [(String, String)]?) throws -> String {
        // Not ported: `defaultBaseURL` (no resource sets it).
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

    /// Used as a callback for mutating the given request before each underlying fetch call.
    ///
    /// Runs immediately before each underlying fetch call, so it sees exactly what goes over the wire.
    /// Overrides must be idempotent and overwrite headers from a previous invocation rather than append to them.
    open func prepareRequest(_ request: inout FinalizedRequest, url: String, options: FinalRequestOptions) async throws {
        // Append auth-derived headers when using token auth. Done here (after all header merging) rather
        // than in authHeaders() so we append to any existing anthropic-beta values instead of being
        // overwritten by later header sources.
        if _authState.tokenCache != nil && apiKey == nil {
            var headers = request.headers
            for (k, v) in _authState.extraHeaders {
                if !headers.has(k) { headers.set(k, v) }
            }
            let existing = headers.get("anthropic-beta")?
                .split(separator: ",", omittingEmptySubsequences: false)
                .map { jsTrim(String($0)) }
            if !(existing?.contains(OAUTH_API_BETA_HEADER) ?? false) {
                headers.set("anthropic-beta", ((existing ?? []) + [OAUTH_API_BETA_HEADER]).joined(separator: ","))
            }
            request.headers = headers
        }
    }

    func post(_ path: String, body: JsonValue, stream: Bool, _ options: RequestOptions) -> APIPromise {
        request(FinalRequestOptions(method: "post", path: path, body: body, stream: stream, options))
    }

    func request(_ options: FinalRequestOptions, _ remainingRetries: Int? = nil) -> APIPromise {
        APIPromise(request: Task { try await self.makeRequest(options, remainingRetries, RequestAuthFlags()) })
    }

    private func makeRequest(_ options: FinalRequestOptions, _ retriesRemainingInput: Int?, _ flags: RequestAuthFlags) async throws -> AnthropicResponseProps {
        let maxRetries = try validatePositiveInteger("maxRetries", options.maxRetries ?? self.maxRetries) { AnthropicError($0) }
        // Top-level call: per-request auth flags start fresh (`_requestAuthFlags.delete(options)`).
        let retriesRemaining = retriesRemainingInput ?? maxRetries

        // Not ported: prepareOptions hook (a no-op).
        let (req, url, timeout) = try await buildRequest(options, retryCount: maxRetries - retriesRemaining, flags)

        let startTime = dateNow()

        if options.signal?.aborted == true {
            throw APIUserAbortError()
        }

        let controller = AbortController()
        let response: FetchResponse
        do {
            response = try await fetchWithTimeout(url, req, timeout, controller, options)
        } catch {
            if options.signal?.aborted == true {
                throw APIUserAbortError()
            }
            // detect native connection timeout errors
            let isTimeout = isAbortError(error) || looksLikeTimeout(error)

            // Not ported: middleware error propagation.
            if retriesRemaining > 0 {
                return try await retryRequest(options, retriesRemaining, nil, flags)
            }
            if isTimeout {
                throw APIConnectionTimeoutError()
            }
            throw APIConnectionError(cause: error)
        }

        if !response.ok {
            let shouldRetry = await self.shouldRetry(response, flags)
            if retriesRemaining > 0 && shouldRetry {
                // We don't need the body of this response.
                cancelResponseBody(response)
                return try await retryRequest(options, retriesRemaining, response.headers, flags)
            }

            let errText: String
            do { errText = try await response.text() } catch { errText = errorMessage(error) }
            let errJSON = safeJSON(errText)
            let errMessage = jsTruthy(errJSON) ? nil : errText

            throw makeStatusError(response.status, errJSON, errMessage, response.headers)
        }

        // Not ported: armAbandonmentBackstop (releases the caller-signal listener when the body is dropped).
        return AnthropicResponseProps(response: response, options: options, controller: controller, startTime: startTime)
    }

    func fetchWithTimeout(_ url: String, _ initial: FinalizedRequest, _ ms: Int, _ controller: AbortController, _ requestOptions: FinalRequestOptions) async throws -> FetchResponse {
        let abort: @Sendable () -> Void = { controller.abort() }
        var listenerID: Int?
        if let signal = initial.signal {
            listenerID = signal.addEventListener(abort)
        }
        let registeredID = listenerID

        var innerInit = initial
        innerInit.method = initial.method.uppercased()

        do {
            // Prepare the request (auth signing and other `prepareRequest` hooks) as the innermost step.
            // Preparation is outside the timeout timer.
            try await prepareRequest(&innerInit, url: url, options: requestOptions)

            guard let requestURL = URL(string: url) else { throw PiError("Invalid URL", name: "TypeError") }
            // Arm the timeout around the underlying fetch only.
            let timer = setTimeout(Double(ms), abort)
            defer { timer.cancel() }
            return try await fetch(FetchRequest(
                url: requestURL,
                method: innerInit.method,
                headers: innerInit.headers,
                body: innerInit.body,
                signal: controller.signal
            ))
        } catch {
            // releaseRequestSignal(controller)
            if let registeredID { initial.signal?.removeEventListener(registeredID) }
            throw error
        }
    }

    private func shouldRetry(_ response: FetchResponse, _ flags: RequestAuthFlags) async -> Bool {
        // Reactive refresh: on a 401 from a request that used the token cache, invalidate and retry once.
        // Only fires when this specific request was bearer-authenticated (not when an apiKey was used) and
        // only once per request — a second 401 after refresh falls through to the normal retry policy below
        // (which treats 4xx as non-retryable).
        if response.status == 401,
           let tokenCache = _authState.tokenCache,
           flags.usedTokenCache,
           !flags.didRefreshFor401
        {
            flags.didRefreshFor401 = true
            await tokenCache.invalidate()
            return true
        }

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

    private func retryRequest(_ options: FinalRequestOptions, _ retriesRemaining: Int, _ responseHeaders: Headers?, _ flags: RequestAuthFlags) async throws -> AnthropicResponseProps {
        var timeoutMillis: Double?

        // Note the `retry-after-ms` header may not be standard, but is a good idea and we'd like proactive support for it.
        if let retryAfterMillisHeader = responseHeaders?.get("retry-after-ms"), !retryAfterMillisHeader.isEmpty {
            let timeoutMs = jsParseFloat(retryAfterMillisHeader)
            if !timeoutMs.isNaN {
                timeoutMillis = timeoutMs
            }
        }

        // About the Retry-After header: https://developer.mozilla.org/en-US/docs/Web/HTTP/Headers/Retry-After
        if let retryAfterHeader = responseHeaders?.get("retry-after"), !retryAfterHeader.isEmpty, timeoutMillis == nil || timeoutMillis == 0 {
            let timeoutSeconds = jsParseFloat(retryAfterHeader)
            if !timeoutSeconds.isNaN {
                timeoutMillis = timeoutSeconds * 1000
            } else {
                timeoutMillis = jsDateParse(retryAfterHeader) - Double(dateNow())
            }
        }

        // If the API asks us to wait a certain amount of time, do what it says, as long as it's a positive delay that
        // one timer can represent (setTimeout fires after 1ms for anything above 2^31 - 1). Otherwise (no header, an
        // unparseable value, zero/negative, a date in the past) calculate a default.
        if timeoutMillis == nil || !(timeoutMillis! > 0 && timeoutMillis! <= 2_147_483_647) {
            let maxRetries = options.maxRetries ?? self.maxRetries
            timeoutMillis = calculateDefaultRetryTimeoutMillis(retriesRemaining, maxRetries)
        }
        // `sleep` resolves (rather than rejects) on abort; the next attempt surfaces the abort.
        do {
            try await sleep(Int(timeoutMillis!.rounded(.up)), options.signal)
        } catch {
            if options.signal?.aborted != true { throw error }
        }

        return try await makeRequest(options, retriesRemaining - 1, flags)
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

    public func calculateNonstreamingTimeout(_ maxTokens: Double, _ maxNonstreamingTokens: Double? = nil) throws -> Int {
        let maxTime = 60.0 * 60 * 1000 // 60 minutes
        let defaultTime = 60 * 10 * 1000 // 10 minutes

        let expectedTime = (maxTime * maxTokens) / 128000
        if expectedTime > Double(defaultTime) || (maxNonstreamingTokens != nil && maxTokens > maxNonstreamingTokens!) {
            throw AnthropicError(
                "Streaming is required for operations that may take longer than 10 minutes. See https://github.com/anthropics/anthropic-sdk-typescript#long-requests for more details"
            )
        }

        return defaultTime
    }

    func buildRequest(_ inputOptions: FinalRequestOptions, retryCount: Int = 0, _ flags: RequestAuthFlags) async throws -> (req: FinalizedRequest, url: String, timeout: Int) {
        var options = inputOptions

        // Not ported: awaiting lazy credential resolution.
        if !_baseURLIsExplicit, let authBaseURL = _authState.baseURL, baseURL != authBaseURL {
            _baseURL.withLock { $0 = authBaseURL }
        }

        let url = try buildURL(options.path, options.query)
        if options.timeout != nil {
            _ = try validatePositiveInteger("timeout", options.timeout) { AnthropicError($0) }
        }
        let timeout = options.timeout ?? self.timeout
        options.timeout = timeout
        let (bodyHeaders, body) = buildJSONBody(options.body)
        let reqHeaders = try await buildHeaders(
            options: inputOptions,
            bodyHeaders: bodyHeaders,
            retryCount: retryCount,
            timeout: timeout,
            flags
        )

        let req = FinalizedRequest(method: options.method, headers: reqHeaders, signal: options.signal, body: body)
        return (req, url, timeout)
    }

    private func buildHeaders(options: FinalRequestOptions, bodyHeaders: HeadersLike?, retryCount: Int, timeout: Int, _ flags: RequestAuthFlags) async throws -> Headers {
        var base: [(String, String?)] = [
            ("Accept", "application/json"),
            ("User-Agent", getUserAgent()),
            ("X-Stainless-Retry-Count", String(retryCount)),
            ("X-Stainless-Timeout", String(timeout / 1000)),
        ]
        base.append(contentsOf: getPlatformHeaders(Anthropic.VERSION))
        if _options.dangerouslyAllowBrowser == true {
            base.append(("anthropic-dangerous-direct-browser-access", "true"))
        }
        base.append(("anthropic-version", "2023-06-01"))

        let headers = buildAnthropicHeaders([
            .record(base),
            try await authHeaders(options, flags).map { .nullable($0) },
            _options.defaultHeaders,
            bodyHeaders,
            options.headers,
        ])

        try validateHeaders(headers)

        return headers.values
    }
}

/// Per-request auth bookkeeping (`RequestAuthFlags`), shared across the retries of one request.
public final class RequestAuthFlags: @unchecked Sendable {
    private let state = Locked((usedTokenCache: false, didRefreshFor401: false))
    public var usedTokenCache: Bool {
        get { state.current.usedTokenCache }
        set { state.withLock { $0.usedTokenCache = newValue } }
    }
    public var didRefreshFor401: Bool {
        get { state.current.didRefreshFor401 }
        set { state.withLock { $0.didRefreshFor401 = newValue } }
    }
}

/// The auth state a client shares with its `withOptions()` clones (`AuthState`).
/// Not ported: `resolution` (lazy default credential chain).
final class AuthState: @unchecked Sendable {
    private let lock = NSLock()
    private var _provider: AccessTokenProvider?
    private var _tokenCache: TokenCache?
    private var _error: (any Error)?
    private var _extraHeaders: [(String, String)] = []
    private var _baseURL: String?

    var provider: AccessTokenProvider? {
        get { lock.withLock { _provider } }
        set { lock.withLock { _provider = newValue } }
    }
    var tokenCache: TokenCache? {
        get { lock.withLock { _tokenCache } }
        set { lock.withLock { _tokenCache = newValue } }
    }
    var error: (any Error)? {
        get { lock.withLock { _error } }
        set { lock.withLock { _error = newValue } }
    }
    var extraHeaders: [(String, String)] {
        get { lock.withLock { _extraHeaders } }
        set { lock.withLock { _extraHeaders = newValue } }
    }
    var baseURL: String? {
        get { lock.withLock { _baseURL } }
        set { lock.withLock { _baseURL = newValue } }
    }
}

/// Model-specific timeout constraints for non-streaming requests
let MODEL_NONSTREAMING_TOKENS: [String: Double] = [
    "claude-opus-4@20250514": 8192,
    "anthropic.claude-opus-4-1-20250805-v1:0": 8192,
    "claude-opus-4-1@20250805": 8192,
]

/// Transform deprecated output_format to output_config.format
/// Returns a modified copy of the params without mutating the original
private func transformOutputFormat(_ params: JsonValue) throws -> JsonValue {
    guard var rest = params.objectValue, let output_format = rest["output_format"], jsTruthy(output_format) else {
        return params
    }

    if jsTruthy(rest["output_config"]?["format"]) {
        throw Anthropic.AnthropicError(
            "Both output_format and output_config.format were provided. " +
                "Please use only output_config.format (output_format is deprecated)."
        )
    }

    rest["output_format"] = nil
    var outputConfig = rest["output_config"]?.objectValue ?? JsonObject()
    outputConfig["format"] = output_format
    rest["output_config"] = .object(outputConfig)
    return .object(rest)
}

// MARK: - APIPromise

public struct AnthropicResponseProps: Sendable {
    public var response: FetchResponse
    public var options: FinalRequestOptions
    public var controller: AbortController
    public var startTime: Int
}

extension Anthropic {
    /// A subclass of `Promise` providing additional helper methods for interacting with the SDK.
    /// The request starts when the promise is created, like the JS promise.
    /// Not ported: response parsing (`withResponse`, `then`, `_thenUnwrap`).
    public final class APIPromise: Sendable {
        private let responsePromise: Task<AnthropicResponseProps, any Error>

        init(request: Task<AnthropicResponseProps, any Error>) {
            self.responsePromise = request
        }

        /// Gets the raw `Response` instance instead of parsing the response data.
        public func asResponse() async throws -> FetchResponse {
            try await awaitTask(responsePromise).response
        }
    }
}

// MARK: - core/error.ts

extension Anthropic {
    open class AnthropicError: Error, CustomStringConvertible, LocalizedError, @unchecked Sendable {
        public let message: String
        public let cause: (any Error)?
        public init(_ message: String, cause: (any Error)? = nil) {
            self.message = message
            self.cause = cause
        }
        public var description: String { message }
        public var errorDescription: String? { message }
    }

    open class APIError: AnthropicError, ProviderError, @unchecked Sendable {
        /// HTTP status for the response that caused the error
        public let status: Int?
        /// HTTP headers for the response that caused the error
        public let headers: Headers?
        /// JSON body of the response that caused the error
        public let error: JsonValue?

        public let requestID: String?
        public let workspaceID: String?

        /// The `error.type` from the API response body, e.g. `"rate_limit_error"`
        public let type: String?

        public init(_ status: Int?, _ error: JsonValue?, _ message: String?, _ headers: Headers?, _ type: String? = nil, cause: (any Error)? = nil) {
            self.status = status
            self.headers = headers
            self.requestID = headers?.get("request-id")
            self.workspaceID = headers?.get("anthropic-workspace-id")
            self.error = error
            self.type = type
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

            let error = errorResponse
            let type = error?["error"]?["type"]?.stringValue

            if status == 400 { return BadRequestError(status, error, message, headers, type) }
            if status == 401 { return AuthenticationError(status, error, message, headers, type) }
            if status == 403 { return PermissionDeniedError(status, error, message, headers, type) }
            if status == 404 { return NotFoundError(status, error, message, headers, type) }
            if status == 409 { return ConflictError(status, error, message, headers, type) }
            if status == 422 { return UnprocessableEntityError(status, error, message, headers, type) }
            if status == 429 { return RateLimitError(status, error, message, headers, type) }
            if status >= 500 { return InternalServerError(status, error, message, headers, type) }
            return APIError(status, error, message, headers, type)
        }
    }

    public final class APIUserAbortError: APIError, @unchecked Sendable {
        public init(message: String? = nil) {
            super.init(nil, nil, (message ?? "").isEmpty ? "Request was aborted." : message, nil)
        }
    }

    open class APIConnectionError: APIError, @unchecked Sendable {
        public init(message: String? = nil, cause: (any Error)? = nil) {
            super.init(nil, nil, (message ?? "").isEmpty ? "Connection error." : message, nil, cause: cause)
        }
    }

    public final class APIConnectionTimeoutError: APIConnectionError, @unchecked Sendable {
        public init(message: String? = nil) {
            super.init(message: message ?? "Request timed out.")
        }
    }

    // Not ported: RetryableError (middleware only).

    public final class BadRequestError: APIError, @unchecked Sendable {}
    public final class AuthenticationError: APIError, @unchecked Sendable {}
    public final class PermissionDeniedError: APIError, @unchecked Sendable {}
    public final class NotFoundError: APIError, @unchecked Sendable {}
    public final class ConflictError: APIError, @unchecked Sendable {}
    public final class UnprocessableEntityError: APIError, @unchecked Sendable {}
    public final class RateLimitError: APIError, @unchecked Sendable {}
    public final class InternalServerError: APIError, @unchecked Sendable {}
}

// MARK: - lib/credentials/types.ts

public struct AccessToken: Sendable, Equatable {
    public var token: String
    /// Unix epoch seconds. `nil` means no expiry (cache forever).
    public var expiresAt: Double?
    public init(token: String, expiresAt: Double?) {
        self.token = token
        self.expiresAt = expiresAt
    }
}

public struct AccessTokenProviderOptions: Sendable {
    public var forceRefresh: Bool?
    public init(forceRefresh: Bool? = nil) { self.forceRefresh = forceRefresh }
}

/// Mints or returns a cached access token.
///
/// The optional `opts.forceRefresh` flag, set by `TokenCache.invalidate` after a 401, tells providers
/// with on-disk caches to bypass their freshness short-circuit and always fetch fresh. Providers
/// without a cache can ignore it.
public typealias AccessTokenProvider = @Sendable (AccessTokenProviderOptions?) async throws -> AccessToken

public typealias IdentityTokenProvider = @Sendable () async throws -> String

public struct CredentialResult: Sendable {
    public var provider: AccessTokenProvider
    public var extraHeaders: [(String, String)]
    /// The `base_url` from the resolved config, if any.
    public var baseURL: String?
}

/// `AnthropicConfig` (`core/credentials.ts`).
public struct AnthropicConfig: Sendable {
    public struct IdentityToken: Sendable {
        public var source: String
        public var path: String
        public init(source: String = "file", path: String) {
            self.source = source
            self.path = path
        }
    }

    public struct AuthenticationInfo: Sendable {
        /// `'oidc_federation'` or `'user_oauth'`.
        public var type: String
        /// Filesystem path to the credentials JSON that stores access/refresh tokens.
        public var credentials_path: String?
        /// Tagged ID (`fdrl_...`) of the federation rule. Required for `oidc_federation`.
        public var federation_rule_id: String?
        /// Optional `svac_...` expected-target check.
        public var service_account_id: String?
        public var identity_token: IdentityToken?
        /// OAuth client ID for refresh (`user_oauth`).
        public var client_id: String?
        public init(type: String, credentials_path: String? = nil, federation_rule_id: String? = nil, service_account_id: String? = nil, identity_token: IdentityToken? = nil, client_id: String? = nil) {
            self.type = type
            self.credentials_path = credentials_path
            self.federation_rule_id = federation_rule_id
            self.service_account_id = service_account_id
            self.identity_token = identity_token
            self.client_id = client_id
        }
    }

    public var version: String?
    public var authentication: AuthenticationInfo
    public var base_url: String?
    public var organization_id: String?
    public var workspace_id: String?

    public init(version: String? = nil, authentication: AuthenticationInfo, base_url: String? = nil, organization_id: String? = nil, workspace_id: String? = nil) {
        self.version = version
        self.authentication = authentication
        self.base_url = base_url
        self.organization_id = organization_id
        self.workspace_id = workspace_id
    }
}

let GRANT_TYPE_JWT_BEARER = "urn:ietf:params:oauth:grant-type:jwt-bearer"
let TOKEN_ENDPOINT = "/v1/oauth/token"

/// `anthropic-beta` value required on authenticated API requests using an OAuth bearer token.
let OAUTH_API_BETA_HEADER = "oauth-2025-04-20"

/// `anthropic-beta` value required on jwt-bearer exchanges against the token endpoint.
let FEDERATION_BETA_HEADER = "oidc-federation-2026-04-01"

let ADVISORY_REFRESH_THRESHOLD_IN_SECONDS = 120.0
let MANDATORY_REFRESH_THRESHOLD_IN_SECONDS = 30.0
let ADVISORY_REFRESH_BACKOFF_IN_SECONDS = 5.0

private let MAX_TOKEN_RESPONSE_BYTES = 1 << 20

/// `class WorkloadIdentityError extends AnthropicError`.
public final class WorkloadIdentityError: Anthropic.AnthropicError, @unchecked Sendable {
    public let statusCode: Int?
    public let body: JsonValue?
    public let requestId: String?

    public init(_ message: String, _ statusCode: Int? = nil, _ body: JsonValue? = nil, _ requestId: String? = nil) {
        self.statusCode = statusCode
        self.body = body
        self.requestId = requestId
        super.init(message)
    }
}

/// Rejects base URLs that would cause a JWT assertion or refresh token to be sent over cleartext HTTP.
/// Loopback hosts are allowed for local development.
func requireSecureTokenEndpoint(_ baseURL: String) throws {
    if baseURL.isEmpty { return }
    guard let u = URLComponents(string: baseURL), let scheme = u.scheme, !scheme.isEmpty else {
        throw WorkloadIdentityError("Invalid token endpoint base URL \"\(baseURL)\": TypeError: Invalid URL")
    }
    let proto = scheme.lowercased() + ":"
    if proto == "https:" { return }
    // WHATWG URL.hostname returns bracketed IPv6 ("[::1]"); Go's net/url strips them.
    var host = (u.host ?? "").lowercased()
    if host.hasPrefix("[") { host.removeFirst() }
    if host.hasSuffix("]") { host.removeLast() }
    if proto == "http:" && (host == "localhost" || host == "127.0.0.1" || host == "::1") {
        return
    }
    throw WorkloadIdentityError("Refusing to send credential over non-https token endpoint \"\(baseURL)\"")
}

/// Reads the response body as text, parses it as a token-endpoint JSON response, validates
/// `access_token` is present, and rejects a non-Bearer `token_type` when one is provided.
/// Reads at most `MAX_TOKEN_RESPONSE_BYTES` from the body stream.
func parseTokenResponse(_ resp: FetchResponse, _ requestId: String?) async throws -> JsonValue {
    let text = try await readLimitedText(resp)
    let data: JsonValue
    do {
        data = try JsonValue.parse(text)
    } catch {
        throw WorkloadIdentityError(
            "Token endpoint returned non-JSON response (status \(resp.status))",
            resp.status,
            redactSensitive(.string(text)),
            requestId
        )
    }
    if data.isNull {
        throw PiError("Cannot read properties of null (reading 'access_token')", name: "TypeError")
    }
    if !jsTruthy(data["access_token"]) {
        throw WorkloadIdentityError(
            "Token endpoint response missing access_token: \(jsonStringify(redactSensitive(data)))",
            resp.status,
            redactSensitive(data),
            requestId
        )
    }
    if let tokenType = data["token_type"], jsTruthy(tokenType) {
        guard let tokenTypeString = tokenType.stringValue else {
            throw PiError("data.token_type.toLowerCase is not a function", name: "TypeError")
        }
        if tokenTypeString.lowercased() != "bearer" {
            throw WorkloadIdentityError(
                "Token endpoint response: unsupported token_type \"\(tokenTypeString)\" (want Bearer)",
                resp.status,
                redactSensitive(data),
                requestId
            )
        }
    }
    return data
}

private let MAX_ERROR_BODY_CHARS = 2000
// RFC 6749 §5.2 standard error-response fields. Anything else in a token endpoint error body is
// potentially echoed input (assertion, refresh_token, access_token, …) and is dropped rather than
// allowlisted-with-exceptions.
private let SAFE_ERROR_KEYS: Set<String> = ["error", "error_description", "error_uri"]

/// Returns a redacted copy of a token-endpoint error body for safe inclusion in an exception.
/// Strings are truncated; objects keep only the RFC 6749 §5.2 error fields.
func redactSensitive(_ body: JsonValue?) -> JsonValue? {
    guard let body, !body.isNull else { return body }
    if case .string(let text) = body {
        let parsed: JsonValue
        do {
            parsed = try JsonValue.parse(text)
        } catch {
            let length = text.utf16.count
            if length <= MAX_ERROR_BODY_CHARS { return body }
            let prefix = String(decoding: Array(text.utf16.prefix(MAX_ERROR_BODY_CHARS)), as: UTF16.self)
            return .string(prefix + "... <\(length - MAX_ERROR_BODY_CHARS) more chars>")
        }
        return .string(jsonStringify(redactSensitive(parsed)))
    }
    if case .object(let object) = body {
        var out = JsonObject()
        for (k, v) in object where SAFE_ERROR_KEYS.contains(k) {
            out[k] = v
        }
        return .object(out)
    }
    return .null
}

private func readLimitedText(_ resp: FetchResponse) async throws -> String {
    var received = Data()
    for try await chunk in resp.body {
        if received.count + chunk.count > MAX_TOKEN_RESPONSE_BYTES {
            let remaining = MAX_TOKEN_RESPONSE_BYTES - received.count
            if remaining > 0 { received.append(chunk.prefix(remaining)) }
            break
        }
        received.append(chunk)
    }
    return String(decoding: received, as: UTF8.self)
}

// MARK: - lib/credentials/token-cache.ts

/// Wraps an `AccessTokenProvider` with two-tier proactive refresh and concurrent deduplication.
///
/// Refresh policy on each `getToken` call:
///
/// - No cached token → call provider (blocking), cache, return.
/// - Cached with `expiresAt == nil` → return cached forever.
/// - More than 120s remaining → return cached.
/// - 30–120s remaining (advisory window) → return stale token immediately, kick off background
///   refresh. On failure, log and keep stale.
/// - Less than 30s remaining or expired (mandatory) → block and refresh. On failure, throw.
///
/// Concurrent mandatory callers coalesce into a single provider call.
public actor TokenCache {
    private let provider: AccessTokenProvider
    private var cached: AccessToken?
    private var pendingRefresh: Task<AccessToken, any Error>?
    private var nextForce = false
    private var lastAdvisoryError: Double = 0
    private let onAdvisoryRefreshError: (@Sendable (any Error) -> Void)?

    public init(_ provider: @escaping AccessTokenProvider, _ onAdvisoryRefreshError: (@Sendable (any Error) -> Void)? = nil) {
        self.provider = provider
        self.onAdvisoryRefreshError = onAdvisoryRefreshError
    }

    public func getToken() async throws -> String {
        let force = nextForce
        nextForce = false
        let cached = self.cached

        guard !force, let cached else {
            let token = try await refresh(force)
            return token.token
        }

        guard let expiresAt = cached.expiresAt else {
            return cached.token
        }

        let remaining = expiresAt - nowAsSeconds()

        if remaining > ADVISORY_REFRESH_THRESHOLD_IN_SECONDS {
            return cached.token
        }

        if remaining > MANDATORY_REFRESH_THRESHOLD_IN_SECONDS {
            backgroundRefresh()
            return cached.token
        }

        let token = try await refresh()
        return token.token
    }

    /// Clears the cached token and marks the next `getToken` as a forced refresh, so the underlying
    /// provider bypasses any on-disk freshness check. Called after a 401 — the server has just told us
    /// the token is bad even if its `expires_at` still looks fresh.
    public func invalidate() {
        cached = nil
        nextForce = true
    }

    /// Mandatory refresh. Joins any in-flight refresh unless forced — a forced refresh must not coalesce
    /// into a non-forced one that may re-serve the same stale disk token.
    private func refresh(_ force: Bool = false) async throws -> AccessToken {
        if let pendingRefresh, !force {
            return try await pendingRefresh.value
        }
        return try await doRefresh(force).value
    }

    /// Advisory background refresh. Shares the same in-flight promise as mandatory refreshes for
    /// deduplication, but swallows errors so the stale cached token keeps being served. Backs off for
    /// `ADVISORY_REFRESH_BACKOFF_IN_SECONDS` after a failure so an outage during the advisory window
    /// doesn't hammer the token endpoint.
    private func backgroundRefresh() {
        if pendingRefresh != nil {
            return
        }
        if nowAsSeconds() - lastAdvisoryError < ADVISORY_REFRESH_BACKOFF_IN_SECONDS {
            return
        }
        let task = doRefresh()
        Task {
            do {
                _ = try await task.value
            } catch {
                self.recordAdvisoryError(error)
            }
        }
    }

    private func recordAdvisoryError(_ error: any Error) {
        lastAdvisoryError = nowAsSeconds()
        // Advisory failure: keep serving the stale cached token, but surface the error to the
        // caller-provided hook so it can be logged.
        onAdvisoryRefreshError?(error)
    }

    /// Core refresh. Sets `pendingRefresh` so concurrent callers (both advisory and mandatory) coalesce
    /// into a single provider call.
    private func doRefresh(_ force: Bool = false) -> Task<AccessToken, any Error> {
        let provider = self.provider
        let task = Task<AccessToken, any Error> {
            do {
                let token = try await provider(force ? AccessTokenProviderOptions(forceRefresh: true) : nil)
                self.settle(token)
                return token
            } catch {
                self.settle(nil)
                throw error
            }
        }
        pendingRefresh = task
        return task
    }

    private func settle(_ token: AccessToken?) {
        if let token { cached = token }
        pendingRefresh = nil
    }
}

/// Current time as unix epoch seconds.
func nowAsSeconds() -> Double {
    (Double(dateNow()) / 1000).rounded(.down)
}

// MARK: - lib/credentials/identity-token.ts

/// Reads a JWT from a file on every call. Supports automatic rotation
/// (e.g. Kubernetes projected service-account tokens).
public func identityTokenFromFile(_ path: String) throws -> IdentityTokenProvider {
    if path.isEmpty {
        throw Anthropic.AnthropicError("Identity token file path is empty")
    }

    return {
        let content: String
        do {
            content = try String(contentsOfFile: path, encoding: .utf8)
        } catch {
            throw Anthropic.AnthropicError("Failed to read identity token file at \(path): \(jsErrorString(error))")
        }
        let token = jsTrim(content)
        if token.isEmpty {
            throw Anthropic.AnthropicError("Identity token file at \(path) is empty")
        }
        return token
    }
}

/// Wraps a static JWT string as an `IdentityTokenProvider`.
public func identityTokenFromValue(_ token: String) throws -> IdentityTokenProvider {
    if token.isEmpty {
        throw Anthropic.AnthropicError("Identity token value is empty")
    }
    return { token }
}

// MARK: - lib/credentials/oidc-federation.ts

public struct OIDCFederationConfig: Sendable {
    public var identityTokenProvider: IdentityTokenProvider
    public var federationRuleId: String
    public var organizationId: String
    public var serviceAccountId: String?
    /// Optional `wrkspc_*` tagged ID, or the literal `"default"` to scope the token to the
    /// organization's default workspace. The minted token is workspace-scoped.
    public var workspaceId: String?
    public var baseURL: String
    public var fetch: FetchFunction
    /// Overrides the outgoing User-Agent header on the token exchange. When empty, sends an
    /// SDK-identified UA so the token endpoint's access logs identify the caller.
    public var userAgent: String?

    public init(identityTokenProvider: @escaping IdentityTokenProvider, federationRuleId: String, organizationId: String, serviceAccountId: String? = nil, workspaceId: String? = nil, baseURL: String, fetch: @escaping FetchFunction, userAgent: String? = nil) {
        self.identityTokenProvider = identityTokenProvider
        self.federationRuleId = federationRuleId
        self.organizationId = organizationId
        self.serviceAccountId = serviceAccountId
        self.workspaceId = workspaceId
        self.baseURL = baseURL
        self.fetch = fetch
        self.userAgent = userAgent
    }
}

/// Exchanges an external OIDC JWT for an Anthropic access token via the RFC 7523 jwt-bearer grant.
///
/// Each invocation performs a fresh token exchange. Wrap in a `TokenCache` to avoid exchanging on
/// every request.
///
/// Federation grants do not return a refresh token — callers re-exchange their assertion on expiry.
public func oidcFederationProvider(_ config: OIDCFederationConfig) -> AccessTokenProvider {
    return { _ in
        try requireSecureTokenEndpoint(config.baseURL)

        let jwt = try await config.identityTokenProvider()
        // The token endpoint enforces a 16 KiB assertion limit; surface a clear client-side error so
        // misconfigured projected-token sources are diagnosable without a server round-trip.
        let jwtLength = jwt.utf16.count
        if jwtLength > 16 * 1024 {
            throw WorkloadIdentityError(
                "Identity token is \(Int((Double(jwtLength) / 1024).rounded(.up))) KiB, exceeds the 16 KiB assertion limit"
            )
        }

        var body: JsonObject = [
            "grant_type": .string(GRANT_TYPE_JWT_BEARER),
            "assertion": .string(jwt),
            "federation_rule_id": .string(config.federationRuleId),
            "organization_id": .string(config.organizationId),
        ]
        if let serviceAccountId = config.serviceAccountId, !serviceAccountId.isEmpty {
            body["service_account_id"] = .string(serviceAccountId)
        }
        if let workspaceId = config.workspaceId, !workspaceId.isEmpty {
            body["workspace_id"] = .string(workspaceId)
        }

        let url = "\(config.baseURL)\(TOKEN_ENDPOINT)"
        let resp: FetchResponse
        do {
            guard let requestURL = URL(string: url) else { throw PiError("Invalid URL", name: "TypeError") }
            resp = try await config.fetch(FetchRequest(
                url: requestURL,
                method: "POST",
                headers: Headers([
                    ("Content-Type", "application/json"),
                    ("anthropic-beta", "\(OAUTH_API_BETA_HEADER),\(FEDERATION_BETA_HEADER)"),
                    ("User-Agent", (config.userAgent?.isEmpty == false ? config.userAgent : nil) ?? "anthropic-sdk-typescript/\(Anthropic.VERSION) oidcFederationProvider"),
                ]),
                body: Data(JsonValue.object(body).serialized().utf8)
            ))
        } catch {
            throw WorkloadIdentityError("Failed to reach token endpoint \(url): \(jsErrorString(error))")
        }

        let requestId = resp.headers.get("Request-Id")

        if !resp.ok {
            let text = (try? await resp.text()) ?? ""
            let redacted = redactSensitive(.string(text))?.stringValue ?? ""
            // A 401 is hard to debug from the status code alone, so surface guidance: check the
            // federation rule, optionally set a workspace ID (the most common fix when no workspaceId is
            // configured), and point at the Workload identity page in Claude Console for the server-side
            // authentication event log. Other statuses (5xx, 400, ...) get no hint.
            var hint = ""
            if resp.status == 401 {
                let hintMiddle = config.workspaceId?.isEmpty == false
                    ? ""
                    : "If your federation rule is scoped to multiple workspaces, set the ANTHROPIC_WORKSPACE_ID environment variable, the 'workspace_id' config key, or the `workspaceId` option. "
                hint = " Ensure your federation rule matches your identity token. \(hintMiddle)View your authentication events in the Workload identity page of Claude Console for more details."
            }
            throw WorkloadIdentityError(
                "Token exchange failed with status \(resp.status)\(requestId?.isEmpty == false ? " (request-id \(requestId!))" : ""): \(redacted)\(hint)",
                resp.status,
                .string(redacted),
                requestId
            )
        }

        let data = try await parseTokenResponse(resp, requestId)
        let expiresIn = jsNumber(data["expires_in"])
        if !expiresIn.isFinite {
            throw WorkloadIdentityError(
                "Token endpoint response missing required fields: \(jsonStringify(redactSensitive(data)))",
                resp.status,
                redactSensitive(data),
                requestId
            )
        }

        return AccessToken(
            token: jsToString(data["access_token"]!),
            expiresAt: nowAsSeconds() + expiresIn
        )
    }
}

// MARK: - lib/credentials/credential-chain.ts

public struct ResolverOptions: Sendable {
    public var baseURL: String
    public var fetch: FetchFunction
    public var userAgent: String?
    /// Swift: the environment `readEnv` consults.
    public var env: ProviderEnv
    // Not ported: onCacheWriteError / onSafetyWarning (the on-disk credential cache).
}

/// Builds the access token provider for an explicit config (`config` client option).
public func resolveCredentialsFromConfig(_ config: AnthropicConfig, _ options: ResolverOptions) throws -> CredentialResult {
    let credentialsPath = config.authentication.credentials_path
    let effectiveBaseURL = stripTrailingSlashes((config.base_url?.isEmpty == false ? config.base_url : nil) ?? options.baseURL)

    let provider = try buildProvider(config, credentialsPath, effectiveBaseURL, options)

    var extraHeaders: [(String, String)] = []
    // For federation profiles workspace_id is sent in the jwt-bearer exchange body, not as a request
    // header (the minted token is already workspace-scoped, so the header would be ignored).
    if let workspaceId = config.workspace_id, !workspaceId.isEmpty, config.authentication.type == "user_oauth" {
        extraHeaders.append(("anthropic-workspace-id", workspaceId))
    }

    // Surface the profile's own base_url (not the options.baseURL fallback) so the client can adopt it
    // for outbound API requests when the caller didn't pin one explicitly.
    return CredentialResult(provider: provider, extraHeaders: extraHeaders, baseURL: config.base_url?.isEmpty == false ? config.base_url : nil)
}

// Not ported: defaultCredentials (config files / ANTHROPIC_PROFILE).

private func buildProvider(_ config: AnthropicConfig, _ credentialsPath: String?, _ baseURL: String, _ options: ResolverOptions) throws -> AccessTokenProvider {
    switch config.authentication.type {
    case "oidc_federation":
        let auth = config.authentication
        guard let identityProvider = try resolveIdentityTokenProvider(auth, options.env) else {
            throw WorkloadIdentityError(
                "oidc_federation config requires an identity token (set authentication.identity_token, " +
                    "ANTHROPIC_IDENTITY_TOKEN_FILE, or ANTHROPIC_IDENTITY_TOKEN)"
            )
        }
        guard let federationRuleId = auth.federation_rule_id, !federationRuleId.isEmpty else {
            throw WorkloadIdentityError(
                "oidc_federation config requires 'federation_rule_id'. Set it in authentication.federation_rule_id in your profile, or via ANTHROPIC_FEDERATION_RULE_ID (profile takes precedence)."
            )
        }
        guard let organizationId = config.organization_id, !organizationId.isEmpty else {
            throw WorkloadIdentityError(
                "oidc_federation config requires organization_id (set ANTHROPIC_ORGANIZATION_ID or config.organization_id)"
            )
        }

        let exchange = oidcFederationProvider(OIDCFederationConfig(
            identityTokenProvider: identityProvider,
            federationRuleId: federationRuleId,
            organizationId: organizationId,
            serviceAccountId: auth.service_account_id,
            workspaceId: config.workspace_id,
            baseURL: baseURL,
            fetch: options.fetch,
            userAgent: options.userAgent
        ))

        // Not ported: cachedExchangeProvider (on-disk caching when credentials_path is set).
        return exchange

    case "user_oauth":
        if (credentialsPath ?? "").isEmpty {
            throw WorkloadIdentityError(
                "user_oauth config requires authentication.credentials_path " +
                    "(or load via a profile so it defaults to <config_dir>/credentials/<profile>.json)"
            )
        }
        // Not ported: userOAuthProvider.
        throw WorkloadIdentityError("authentication.type \"user_oauth\" is not supported by this port")

    default:
        let t = config.authentication.type
        throw WorkloadIdentityError("authentication.type \"\(t)\" is not a known authentication type")
    }
}

private func resolveIdentityTokenProvider(_ auth: AnthropicConfig.AuthenticationInfo, _ env: ProviderEnv) throws -> IdentityTokenProvider? {
    if let identityToken = auth.identity_token {
        let source = identityToken.source
        if source != "file" {
            throw WorkloadIdentityError(
                "identity_token.source \"\(source)\" is not supported by this SDK version (only \"file\")"
            )
        }
        if identityToken.path.isEmpty {
            throw WorkloadIdentityError("identity_token.source \"file\" requires a non-empty path")
        }
        return try identityTokenFromFile(identityToken.path)
    }

    if let tokenFile = readEnv(env, "ANTHROPIC_IDENTITY_TOKEN_FILE") {
        return try identityTokenFromFile(tokenFile)
    }

    if let tokenValue = readEnv(env, "ANTHROPIC_IDENTITY_TOKEN") {
        return try identityTokenFromValue(tokenValue)
    }

    return nil
}

// MARK: - JS value helpers

/// `.replace(/\/+$/, '')`.
private func stripTrailingSlashes(_ text: String) -> String {
    var result = text
    while result.hasSuffix("/") { result.removeLast() }
    return result
}

/// `JSON.stringify(value)` for a possibly-undefined value (`undefined` → `"undefined"` in a template).
private func jsonStringify(_ value: JsonValue?) -> String {
    value?.serialized() ?? "undefined"
}

/// `String(value)` for a JSON value.
func jsToString(_ value: JsonValue) -> String {
    switch value {
    case .null: return "null"
    case .bool(let b): return b ? "true" : "false"
    case .number(let n): return JsonWriter.formatNumber(n)
    case .string(let s): return s
    case .array(let items): return items.map { $0.isNull ? "" : jsToString($0) }.joined(separator: ",")
    case .object: return "[object Object]"
    }
}

/// `Number(value)` for a possibly-undefined JSON value.
func jsNumber(_ value: JsonValue?) -> Double {
    guard let value else { return .nan }
    switch value {
    case .null: return 0
    case .bool(let b): return b ? 1 : 0
    case .number(let n): return n
    case .string(let s):
        let trimmed = jsTrim(s)
        if trimmed.isEmpty { return 0 }
        if trimmed == "Infinity" || trimmed == "+Infinity" { return .infinity }
        if trimmed == "-Infinity" { return -.infinity }
        if trimmed.lowercased().contains("inf") || trimmed.lowercased().contains("nan") { return .nan }
        return Double(trimmed) ?? .nan
    case .array(let items):
        if items.isEmpty { return 0 }
        if items.count == 1 { return jsNumber(.string(jsToString(items[0]))) }
        return .nan
    case .object: return .nan
    }
}

/// `String(err)` / `${err}` for a thrown error: `"<name>: <message>"`.
private func jsErrorString(_ error: any Error) -> String {
    if let error = error as? PiError { return "\(error.name): \(error.message)" }
    return "Error: \(errorMessage(error))"
}
