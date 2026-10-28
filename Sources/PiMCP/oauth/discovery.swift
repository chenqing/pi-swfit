// Port of packages/mcp/src/oauth/discovery.ts @ 42cb822f1c5d3153069dd0661bfd297424666cf1.
import Foundation
import PiAI

public struct McpOAuthChallenge: Sendable {
    public var resourceMetadataURL: URL?
    public var scope: String?
    public var error: String?
    public init(resourceMetadataURL: URL? = nil, scope: String? = nil, error: String? = nil) {
        self.resourceMetadataURL = resourceMetadataURL; self.scope = scope; self.error = error
    }
}
public func parseWwwAuthenticate(_ header: String?) -> McpOAuthChallenge {
    guard let header, let scheme = header.split(whereSeparator: \.isWhitespace).first,
          ["bearer", "dpop"].contains(scheme.lowercased()) else { return .init() }
    func field(_ name: String) -> String? {
        guard let pattern = try? NSRegularExpression(pattern: #"(?:^|[,\s])"# + name + #"=(?:"([^"]*)"|([^\s,]+))"#, options: .caseInsensitive),
              let match = pattern.firstMatch(in: header, range: NSRange(header.startIndex..., in: header)) else { return nil }
        for index in [1, 2] { if let range = Range(match.range(at: index), in: header), !header[range].isEmpty { return String(header[range]) } }
        return nil
    }
    return .init(resourceMetadataURL: field("resource_metadata").flatMap(URL.init(string:)), scope: field("scope"), error: field("error"))
}
public func secureMcpOAuthEndpoint(_ value: String) throws -> URL {
    guard let url = URL(string: value), let host = url.host?.lowercased(), url.user == nil, url.password == nil,
          url.scheme == "https" || (url.scheme == "http" && ["localhost", "127.0.0.1", "::1", "[::1]"].contains(host)) else {
        throw PiError("OAuth endpoints require HTTPS or HTTP on loopback")
    }
    return url
}
func oauthJSON(_ response: FetchResponse) async throws -> JsonObject {
    var bytes = Data()
    for try await chunk in response.body {
        bytes.append(chunk)
        guard bytes.count <= 1024 * 1024 else { throw PiError("OAuth response exceeds size limit") }
    }
    guard let object = try JsonValue.parse(String(decoding: bytes, as: UTF8.self)).objectValue else { throw PiError("Invalid OAuth response") }
    return object
}
public struct McpOAuthDiscovery: Sendable {
    public var issuer: String
    public var metadata: JsonObject
    public var resource: String?
    public var scopes: [String]
}
public func buildAuthorizationServerDiscoveryURLs(_ issuer: URL) -> [URL] {
    var origin = URLComponents(url: issuer, resolvingAgainstBaseURL: false)!
    var path = origin.path; if path.hasSuffix("/") { path.removeLast() }
    origin.path = ""; origin.query = nil; origin.fragment = nil
    let base = origin.url!
    return (["/.well-known/oauth-authorization-server" + path, "/.well-known/openid-configuration" + path]
            + (path.isEmpty ? [] : [path + "/.well-known/openid-configuration"]))
        .compactMap { URL(string: $0, relativeTo: base)?.absoluteURL }
}
public func discoverMcpOAuth(serverURL: URL, challenge: McpOAuthChallenge = .init(), metadataURL: URL? = nil,
                            fetch: @escaping FetchFunction = defaultFetch, signal: AbortSignal? = nil) async throws -> McpOAuthDiscovery {
    _ = try secureMcpOAuthEndpoint(serverURL.absoluteString)
    var origin = URLComponents(url: serverURL, resolvingAgainstBaseURL: false)!
    var path = origin.path; if path.hasSuffix("/") { path.removeLast() }
    origin.path = ""; origin.query = nil; origin.fragment = nil
    let base = origin.url!
    func get(_ url: URL) async throws -> FetchResponse {
        _ = try secureMcpOAuthEndpoint(url.absoluteString)
        let response = try await fetch(.init(url: url, headers: Headers(["Accept": "application/json", "MCP-Protocol-Version": LATEST_PROTOCOL_VERSION]), signal: signal, timeoutMs: 15_000))
        if let finalURL = response.url { _ = try secureMcpOAuthEndpoint(finalURL.absoluteString) }
        return response
    }
    func miss(_ status: Int) -> Bool { (400..<500).contains(status) || status == 502 }
    var resourceMetadata = JsonObject()
    let resourceURLs = challenge.resourceMetadataURL.map { [$0] } ?? (["/.well-known/oauth-protected-resource" + path]
        + (path.isEmpty ? [] : ["/.well-known/oauth-protected-resource"])).compactMap { URL(string: $0, relativeTo: base)?.absoluteURL }
    for url in resourceURLs {
        let response = try await get(url)
        if response.ok { resourceMetadata = try await oauthJSON(response); break }
        if !miss(response.status) { break }
    }
    var resource: String?
    if let raw = resourceMetadata["resource"]?.stringValue {
        let configured = try secureMcpOAuthEndpoint(raw)
        let requestedPath = serverURL.path.hasSuffix("/") ? serverURL.path : serverURL.path + "/"
        let configuredPath = configured.path.hasSuffix("/") ? configured.path : configured.path + "/"
        guard configured.scheme == serverURL.scheme, configured.host == serverURL.host,
              configured.port == serverURL.port, requestedPath.hasPrefix(configuredPath) else { throw PiError("OAuth protected resource does not match MCP server") }
        resource = raw
    }
    let issuer = resourceMetadata["authorization_servers"]?.arrayValue?.first?.stringValue ?? base.absoluteString
    var metadata = JsonObject(), resolvedIssuer = issuer
    let urls = try metadataURL.map { [$0] } ?? buildAuthorizationServerDiscoveryURLs(secureMcpOAuthEndpoint(issuer))
    for url in urls {
        let response = try await get(url)
        if !response.ok {
            if metadataURL == nil && miss(response.status) { continue }
            throw PiError("OAuth metadata request failed (HTTP \(response.status))")
        }
        metadata = try await oauthJSON(response)
        guard let actual = metadata["issuer"]?.stringValue else { throw PiError("OAuth metadata has no issuer") }
        _ = try secureMcpOAuthEndpoint(actual)
        func trim(_ value: String) -> String { value.hasSuffix("/") ? String(value.dropLast()) : value }
        guard metadataURL != nil || trim(actual) == trim(issuer) else { throw PiError("OAuth authorization server issuer mismatch") }
        resolvedIssuer = actual; break
    }
    return .init(issuer: resolvedIssuer, metadata: metadata, resource: resource,
                 scopes: resourceMetadata["scopes_supported"]?.arrayValue?.compactMap(\.stringValue) ?? [])
}
