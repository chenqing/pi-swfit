// Native OAuth flow corresponding to packages/mcp/src/oauth/{flow,provider}.ts @ 42cb822f.
import Foundation
import CryptoKit
import Security
import PiAI

public struct McpOAuthAuthorizationRequired: Error, Sendable { public init() {} }
public protocol McpOAuthStateStore: Sendable {
    func load(key: String) async throws -> JsonObject?
    func save(key: String, value: JsonObject?) async throws
}
public actor MemoryMcpOAuthStateStore: McpOAuthStateStore {
    private var values: [String: JsonObject] = [:]
    public init() {}
    public func load(key: String) -> JsonObject? { values[key] }
    public func save(key: String, value: JsonObject?) { values[key] = value }
}
public func mcpOAuthStorageKey(name: String, url: URL) -> String {
    SHA256.hash(data: Data((name + "\0" + url.absoluteString).utf8)).map { String(format: "%02x", $0) }.joined()
}
private func randomOAuthValue() throws -> String {
    var bytes = [UInt8](repeating: 0, count: 32)
    guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else { throw PiError("Secure random generator failed") }
    return base64url(Data(bytes))
}
private func base64url(_ data: Data) -> String { data.base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "") }
private func formData(_ values: [String: String]) -> Data {
    let allowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
    func encode(_ text: String) -> String { text.addingPercentEncoding(withAllowedCharacters: allowed)! }
    return Data(values.keys.sorted().map { encode($0) + "=" + encode(values[$0]!) }.joined(separator: "&").utf8)
}

/// One exact server identity. The host owns durable credential storage and browser opening.
/// HTTP requests can refresh credentials but can never open a browser without an explicit login.
public actor McpOAuthClient {
    public let serverURL: URL
    public let name: String
    private let settings: JsonObject
    private let store: any McpOAuthStateStore
    private let fetch: FetchFunction
    private let key: String
    private let configurationDigest: String
    private var challenge = McpOAuthChallenge()
    private var refreshTask: Task<String?, Error>?
    private var loginActive = false
    private var loginController: AbortController?
    private var epoch = UUID()
    public init(name: String, serverURL: URL, settings: JsonObject = [:],
                store: any McpOAuthStateStore = MemoryMcpOAuthStateStore(), fetch: @escaping FetchFunction = defaultFetch) {
        self.name = name; self.serverURL = serverURL; self.settings = settings; self.store = store; self.fetch = fetch
        key = mcpOAuthStorageKey(name: name, url: serverURL)
        configurationDigest = SHA256.hash(data: Data(JsonValue.object(settings).serialized().utf8)).map { String(format: "%02x", $0) }.joined()
    }
    private func state() async throws -> JsonObject {
        let value = try await store.load(key: key)
        return value?["serverUrl"] == .string(serverURL.absoluteString) && value?["configurationDigest"] == .string(configurationDigest)
            ? value! : ["serverUrl": .string(serverURL.absoluteString), "configurationDigest": .string(configurationDigest)]
    }
    private func discovery(signal: AbortSignal?) async throws -> McpOAuthDiscovery {
        try await discoverMcpOAuth(serverURL: serverURL, challenge: challenge,
            metadataURL: settings["authServerMetadataUrl"]?.stringValue.flatMap(URL.init(string:)), fetch: fetch, signal: signal)
    }
    public func authorizationHeader(signal: AbortSignal? = nil) async throws -> String? {
        let value = try await state()
        guard let token = value["tokens"]?["access_token"]?.stringValue else { return nil }
        if let expiry = value["expiresAt"]?.doubleValue, expiry < Date().timeIntervalSince1970 + 30 {
            guard let refreshed = try await refresh(signal: signal) else { throw McpOAuthAuthorizationRequired() }
            return "Bearer " + refreshed
        }
        return "Bearer " + token
    }
    public func handleUnauthorized(_ header: String?, rejectedAuthorization: String?, signal: AbortSignal?) async throws -> Bool {
        challenge = parseWwwAuthenticate(header)
        if challenge.error == "insufficient_scope" { throw McpOAuthAuthorizationRequired() }
        if let current = try await authorizationHeader(signal: signal), current != rejectedAuthorization { return true }
        guard try await refresh(signal: signal) != nil else { throw McpOAuthAuthorizationRequired() }
        return true
    }
    private func refresh(signal: AbortSignal?) async throws -> String? {
        if let task = refreshTask { return try await task.value }
        let generation = epoch
        let task = Task { [self] () throws -> String? in
            var value = try await state()
            guard let refresh = value["tokens"]?["refresh_token"]?.stringValue,
                  let client = value["client"]?.objectValue else { return nil }
            let info = try await discovery(signal: signal)
            var tokens = try await tokenRequest(info: info, client: client, params: ["grant_type": "refresh_token", "refresh_token": refresh], signal: signal)
            if tokens["refresh_token"] == nil { tokens["refresh_token"] = .string(refresh) }
            guard generation == epoch else { throw McpOAuthAuthorizationRequired() }
            value = savingTokens(tokens, in: value)
            try await store.save(key: key, value: value)
            return tokens["access_token"]?.stringValue
        }
        refreshTask = task
        defer { refreshTask = nil }
        return try await task.value
    }
    private func savingTokens(_ tokens: JsonObject, in original: JsonObject) -> JsonObject {
        var value = original; value["tokens"] = .object(tokens)
        value["expiresAt"] = tokens["expires_in"]?.doubleValue.map { .number(Date().timeIntervalSince1970 + $0) }
        return value
    }
    private func endpoint(_ info: McpOAuthDiscovery, field: String, fallback: String) throws -> URL {
        try secureMcpOAuthEndpoint(info.metadata[field]?.stringValue ?? URL(string: fallback, relativeTo: URL(string: info.issuer))!.absoluteURL.absoluteString)
    }
    private func tokenRequest(info: McpOAuthDiscovery, client: JsonObject, params original: [String: String], signal: AbortSignal?) async throws -> JsonObject {
        var params = original
        var headers = Headers(["Accept": "application/json", "Content-Type": "application/x-www-form-urlencoded"])
        guard let clientID = client["client_id"]?.stringValue else { throw PiError("OAuth client has no ID") }
        let secret = client["client_secret"]?.stringValue
        let supported = info.metadata["token_endpoint_auth_methods_supported"]?.arrayValue?.compactMap(\.stringValue) ?? []
        let hint = client["token_endpoint_auth_method"]?.stringValue
        let method: String
        if let hint, ["none", "client_secret_post", "client_secret_basic"].contains(hint), supported.isEmpty || supported.contains(hint) { method = hint }
        else if secret != nil && (supported.isEmpty || supported.contains("client_secret_basic")) { method = "client_secret_basic" }
        else if secret != nil && supported.contains("client_secret_post") { method = "client_secret_post" }
        else { method = "none" }
        if method == "client_secret_basic" {
            guard let secret else { throw PiError("OAuth client secret is required") }
            headers.set("Authorization", "Basic " + Data((clientID + ":" + secret).utf8).base64EncodedString())
        } else {
            params["client_id"] = clientID
            if method == "client_secret_post" { params["client_secret"] = secret }
        }
        if let resource = info.resource { params["resource"] = resource }
        let response = try await fetch(.init(url: endpoint(info, field: "token_endpoint", fallback: "/token"), method: "POST", headers: headers, body: formData(params), signal: signal, timeoutMs: 30_000, followRedirects: false))
        let tokens = try await oauthJSON(response)
        guard response.ok, tokens["error"] == nil,
              let access = tokens["access_token"]?.stringValue, !access.isEmpty,
              tokens["token_type"]?.stringValue?.lowercased() == "bearer" else { throw McpOAuthAuthorizationRequired() }
        if let expiry = tokens["expires_in"], !(expiry.doubleValue.map { $0.isFinite && $0 >= 0 } ?? false) { throw PiError("Invalid OAuth token expiry") }
        return tokens
    }
    public func login(signal: AbortSignal? = nil, openURL: @escaping @Sendable (URL) async throws -> Void) async throws {
        guard !loginActive else { throw PiError("MCP login is already in progress") }
        let controller = AbortController()
        loginActive = true; loginController = controller
        let combined = combineAbortSignals([signal, controller.signal])
        let signal = combined.signal
        defer { combined.cleanup(); loginActive = false; loginController = nil }
        epoch = UUID(); let generation = epoch
        let info = try await discovery(signal: signal), state = try randomOAuthValue(), verifier = try randomOAuthValue()
        if let methods = info.metadata["code_challenge_methods_supported"]?.arrayValue, !methods.contains(.string("S256")) { throw PiError("OAuth server does not support PKCE S256") }
        if let responses = info.metadata["response_types_supported"]?.arrayValue, !responses.contains(.string("code")) { throw PiError("OAuth server does not support authorization codes") }
        guard let callback = URLComponents(string: settings["callbackUrl"]?.stringValue ?? "http://127.0.0.1/callback") else { throw PiError("Invalid OAuth callback URL") }
        let callbackHost = callback.host ?? "127.0.0.1"
        guard callback.scheme == "http", ["localhost", "127.0.0.1", "::1", "[::1]"].contains(callbackHost), callback.query == nil, callback.fragment == nil else { throw PiError("OAuth callback must use HTTP loopback") }
        let cimd = settings["clientRegistration"] == .string("cimd")
        let requireIssuer = info.metadata["authorization_response_iss_parameter_supported"] == .bool(true)
        var callbackSource = URLComponents(url: serverURL, resolvingAgainstBaseURL: false)!
        callbackSource.fragment = nil
        let callbackID = base64url(Data(SHA256.hash(data: Data(callbackSource.url!.absoluteString.utf8)).prefix(9)))
        let callbackPath = (callback.path.isEmpty ? "/callback" : callback.path) + (cimd && !requireIssuer ? "/" + callbackID : "")
        let rawPort = settings["callbackPort"]?.doubleValue ?? Double(callback.port ?? 0)
        guard rawPort.isFinite, rawPort >= 0, rawPort <= 65535, rawPort.rounded() == rawPort else { throw PiError("Invalid OAuth callback port") }
        let port = Int(rawPort)
        let listener = try await startOAuthCallbackServer(OAuthCallbackServerOptions<String>(providerName: name,
            host: callbackHost == "localhost" ? "127.0.0.1" : callbackHost.replacingOccurrences(of: "[", with: "").replacingOccurrences(of: "]", with: ""),
            port: port, path: callbackPath, redirectHost: callbackHost, state: state, expectedIssuer: info.issuer, requireIssuer: requireIssuer,
            complete: { $0 }, signal: signal, timeoutMs: 180_000))
        defer { listener.close() }
        var value = try await self.state(), client: JsonObject
        if let id = settings["clientId"]?.stringValue {
            client = ["client_id": .string(id)]; client["client_secret"] = settings["clientSecret"]
        } else if cimd {
            guard info.metadata["client_id_metadata_document_supported"] == .bool(true),
                  info.metadata["token_endpoint_auth_methods_supported"]?.arrayValue?.contains(.string("none")) == true else { throw PiError("OAuth server does not support client metadata documents") }
            client = ["client_id": .string("https://pi.dev/oauth/" + (requireIssuer ? "" : callbackID + "/") + "client.json"), "token_endpoint_auth_method": .string("none")]
        } else if let stored = value["client"]?.objectValue, stored["redirect_uris"]?.arrayValue?.contains(.string(listener.redirectUri)) == true {
            client = stored
        } else {
            if !info.metadata.isEmpty && info.metadata["registration_endpoint"] == nil { throw PiError("OAuth server requires a configured client ID") }
            let metadata: JsonObject = ["client_name": settings["clientName"] ?? .string("Pi Swift"), "redirect_uris": .array([.string(listener.redirectUri)]),
                "grant_types": .array([.string("authorization_code"), .string("refresh_token")]), "response_types": .array([.string("code")]),
                "token_endpoint_auth_method": .string("none"), "application_type": .string("native")]
            let response = try await fetch(.init(url: endpoint(info, field: "registration_endpoint", fallback: "/register"), method: "POST",
                headers: Headers(["Content-Type": "application/json", "Accept": "application/json"]), body: Data(JsonValue.object(metadata).serialized().utf8), signal: signal, timeoutMs: 30_000, followRedirects: false))
            guard response.ok else { throw PiError("OAuth client registration failed (HTTP \(response.status))") }
            client = try await oauthJSON(response)
            client["redirect_uris"] = metadata["redirect_uris"]
        }
        guard let clientID = client["client_id"]?.stringValue else { throw PiError("OAuth registration returned no client ID") }
        var authorization = URLComponents(url: try endpoint(info, field: "authorization_endpoint", fallback: "/authorize"), resolvingAgainstBaseURL: false)!
        var scope = settings["scope"]?.stringValue ?? info.scopes.joined(separator: " ")
        let requested = [value["tokens"]?["scope"]?.stringValue, challenge.scope].compactMap { $0 }.joined(separator: " ")
        if !requested.isEmpty {
            var parts = scope.split(separator: " ").map(String.init)
            for entry in requested.split(separator: " ").map(String.init) where !parts.contains(entry) { parts.append(entry) }
            scope = parts.joined(separator: " ")
        }
        var query = ["response_type": "code", "client_id": clientID, "redirect_uri": listener.redirectUri, "state": state,
                     "code_challenge_method": "S256", "code_challenge": base64url(Data(SHA256.hash(data: Data(verifier.utf8))))]
        if !scope.isEmpty { query["scope"] = scope }
        if scope.split(separator: " ").contains("offline_access") { query["prompt"] = "consent" }
        query["resource"] = info.resource
        authorization.queryItems = (authorization.queryItems ?? []).filter { query[$0.name] == nil } + query.keys.sorted().map { URLQueryItem(name: $0, value: query[$0]) }
        try await openURL(authorization.url!)
        guard let code = try await listener.wait() else { throw AbortError() }
        let tokens = try await tokenRequest(info: info, client: client, params: ["grant_type": "authorization_code", "code": code,
            "code_verifier": verifier, "redirect_uri": listener.redirectUri], signal: signal)
        try signal?.throwIfAborted()
        guard generation == epoch else { throw AbortError() }
        value["client"] = .object(client)
        try await store.save(key: key, value: savingTokens(tokens, in: value))
    }
    public func logout() async throws {
        epoch = UUID(); loginController?.abort(); refreshTask?.cancel()
        try await store.save(key: key, value: nil)
    }
}

extension McpOAuthClient {
    public nonisolated var authentication: McpHTTPAuthentication {
        .init(authorization: { signal in try await self.authorizationHeader(signal: signal) },
              unauthorized: { header, previous, signal in try await self.handleUnauthorized(header, rejectedAuthorization: previous, signal: signal) })
    }
}
