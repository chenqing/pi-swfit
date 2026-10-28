import Foundation

// Port of `openai` 7.19.0 `azure.ts` (`AzureOpenAI`).
//
// Not ported: `azureADTokenProvider` (function credentials), `workloadIdentity`, `withOptions`,
// `redirect: 'manual'` for `api-key` requests (URLSession follows redirects).

open class AzureOpenAI: OpenAI, @unchecked Sendable {
    public struct AzureClientOptions: Sendable {
        /// Defaults to `process.env['OPENAI_API_VERSION']`.
        public var apiVersion: String?
        /// Your Azure endpoint, including the resource, e.g. `https://example-resource.azure.openai.com/`.
        public var endpoint: String?
        /// A model deployment, if given, sets the base client URL to include `/deployments/{deployment}`.
        public var deployment: String?
        /// Defaults to `process.env['AZURE_OPENAI_API_KEY']`.
        public var apiKey: String?
        /// Defaults to `process.env['OPENAI_BASE_URL']`.
        public var baseURL: String?
        public var organization: String?
        public var project: String?
        public var timeout: Int?
        public var fetch: FetchFunction?
        public var maxRetries: Int?
        public var defaultHeaders: HeadersLike?
        public var defaultQuery: [(String, String)]?
        public var dangerouslyAllowBrowser: Bool?
        /// Swift: the environment `readEnv` consults (default: the process environment).
        public var env: ProviderEnv?

        public init(apiVersion: String? = nil, endpoint: String? = nil, deployment: String? = nil, apiKey: String? = nil, baseURL: String? = nil, organization: String? = nil, project: String? = nil, timeout: Int? = nil, fetch: FetchFunction? = nil, maxRetries: Int? = nil, defaultHeaders: HeadersLike? = nil, defaultQuery: [(String, String)]? = nil, dangerouslyAllowBrowser: Bool? = nil, env: ProviderEnv? = nil) {
            self.apiVersion = apiVersion
            self.endpoint = endpoint
            self.deployment = deployment
            self.apiKey = apiKey
            self.baseURL = baseURL
            self.organization = organization
            self.project = project
            self.timeout = timeout
            self.fetch = fetch
            self.maxRetries = maxRetries
            self.defaultHeaders = defaultHeaders
            self.defaultQuery = defaultQuery
            self.dangerouslyAllowBrowser = dangerouslyAllowBrowser
            self.env = env
        }
    }

    public let deploymentName: String?
    public let apiVersion: String

    /// API Client for interfacing with the Azure OpenAI API.
    public init(_ azureOptions: AzureClientOptions = AzureClientOptions()) throws {
        let env = azureOptions.env ?? ProcessInfo.processInfo.environment
        var baseURL = azureOptions.baseURL ?? readEnv(env, "OPENAI_BASE_URL")
        let apiKey = azureOptions.apiKey ?? readEnv(env, "AZURE_OPENAI_API_KEY")
        let apiVersion = azureOptions.apiVersion ?? readEnv(env, "OPENAI_API_VERSION")
        var endpoint = azureOptions.endpoint

        guard let apiVersion, !apiVersion.isEmpty else {
            throw OpenAIError(
                "The OPENAI_API_VERSION environment variable is missing or empty; either provide it, or instantiate the AzureOpenAI client with an apiVersion option, like new AzureOpenAI({ apiVersion: 'My API Version' })."
            )
        }

        if (apiKey ?? "").isEmpty {
            throw OpenAIError(
                "Missing credentials. Please pass one of `apiKey` and `azureADTokenProvider`, or set the `AZURE_OPENAI_API_KEY` environment variable."
            )
        }

        let defaultQuery = spreadQuery([azureOptions.defaultQuery, [("api-version", apiVersion)]])

        if (baseURL ?? "").isEmpty {
            if (endpoint ?? "").isEmpty {
                endpoint = env["AZURE_OPENAI_ENDPOINT"]
            }

            guard let resolvedEndpoint = endpoint, !resolvedEndpoint.isEmpty else {
                throw OpenAIError(
                    "Must provide one of the `baseURL` or `endpoint` arguments, or the `AZURE_OPENAI_ENDPOINT` environment variable"
                )
            }

            var endpointEnd = resolvedEndpoint.endIndex
            while endpointEnd > resolvedEndpoint.startIndex && resolvedEndpoint[resolvedEndpoint.index(before: endpointEnd)] == "/" {
                endpointEnd = resolvedEndpoint.index(before: endpointEnd)
            }
            baseURL = "\(resolvedEndpoint[..<endpointEnd])/openai"
        } else if !(endpoint ?? "").isEmpty {
            throw OpenAIError("baseURL and endpoint are mutually exclusive")
        }

        self.apiVersion = apiVersion
        self.deploymentName = azureOptions.deployment
        try super.init(OpenAI.ClientOptions(
            apiKey: apiKey,
            organization: azureOptions.organization,
            project: azureOptions.project,
            baseURL: baseURL,
            timeout: azureOptions.timeout,
            fetch: azureOptions.fetch,
            maxRetries: azureOptions.maxRetries,
            defaultHeaders: azureOptions.defaultHeaders,
            defaultQuery: defaultQuery,
            dangerouslyAllowBrowser: azureOptions.dangerouslyAllowBrowser,
            env: env
        ))
    }

    open override var userAgentClassName: String { "AzureOpenAI" }

    open override func buildRequest(_ inputOptions: FinalRequestOptions, retryCount: Int = 0) async throws -> (req: FinalizedRequest, url: String, timeout: Int) {
        var options = inputOptions
        if _deployments_endpoints.contains(options.path) && options.method == "post" && options.body != nil {
            guard case .object(let body)? = options.body else {
                throw PiError("Expected request body to be an object")
            }
            let model: String? = (deploymentName?.isEmpty == false ? deploymentName : nil) ?? body["model"]?.stringValue
            if let model, !hasDeploymentPathSegment(baseURL) {
                options.path = "/deployments/\(encodeURIPathSegment(model))" + options.path
            }
        }
        return try await super.buildRequest(options, retryCount: retryCount)
    }

    open override func authHeaders(_ opts: FinalRequestOptions) throws -> NullableHeaders? {
        if let apiKey = _options.apiKey {
            return try PiAI.buildHeaders([.record([("api-key", apiKey)])])
        }
        return try super.authHeaders(opts)
    }
}

private func hasDeploymentPathSegment(_ baseURL: String) -> Bool {
    guard let url = URLComponents(string: baseURL) else { return false }
    return url.path.split(separator: "/", omittingEmptySubsequences: false).contains("deployments")
}

/// The `path` template tag's `encodeURIPath` for one interpolated value.
private func encodeURIPathSegment(_ value: String) -> String {
    var allowed = CharacterSet()
    allowed.insert(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~!$&'()*+,;=:@")
    return value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
}

private let _deployments_endpoints: Set<String> = [
    "/completions",
    "/chat/completions",
    "/embeddings",
    "/audio/transcriptions",
    "/audio/translations",
    "/audio/speech",
    "/images/generations",
    "/batches",
    "/images/edits",
]
