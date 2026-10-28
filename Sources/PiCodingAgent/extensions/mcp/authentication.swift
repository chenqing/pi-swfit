// Native host boundary for extensions/mcp/oauth.ts. Credentials belong to one name + URL.
import Foundation
import CryptoKit
import PiAI
import PiMCP

public actor McpAuthentication {
    public typealias Provider = @Sendable (String, URL) async throws -> McpHTTPAuthentication
    private let store: any McpOAuthStateStore
    private let fetch: FetchFunction
    private let provider: Provider?
    private let resolver = McpConfigValueResolver()
    private var clients: [String: McpOAuthClient] = [:]
    public init(store: any McpOAuthStateStore = MemoryMcpOAuthStateStore(), fetch: @escaping FetchFunction = defaultFetch,
                provider: Provider? = nil) {
        self.store = store; self.fetch = fetch; self.provider = provider
    }
    public func client(for entry: McpServerEntry, signal: AbortSignal? = nil) async throws -> McpOAuthClient {
        guard let raw = entry.config.url else { throw PiError("OAuth requires HTTP MCP") }
        let url = try secureMcpOAuthEndpoint(raw)
        var settings = entry.config.value["oauth"]?.objectValue ?? [:]
        for field in ["clientId", "clientSecret"] {
            if let raw = settings[field]?.stringValue { settings[field] = .string(try await resolver.resolve(raw, cwd: URL(fileURLWithPath: entry.source).deletingLastPathComponent().path, signal: signal)) }
        }
        // Changing client/issuer configuration creates a fresh provider; durable credentials remain URL-bound.
        let identity = mcpOAuthStorageKey(name: entry.name, url: url) + SHA256.hash(data: Data(JsonValue.object(settings).serialized().utf8)).map { String(format: "%02x", $0) }.joined()
        if let existing = clients[identity] { return existing }
        let client = McpOAuthClient(name: entry.name, serverURL: url, settings: settings, store: store, fetch: fetch)
        clients[identity] = client
        return client
    }
    public func httpAuthentication(for entry: McpServerEntry) async throws -> McpHTTPAuthentication? {
        if let name = entry.config.value["auth"]?["provider"]?.stringValue {
            guard let provider, let raw = entry.config.url else { throw PiError("MCP auth.provider requires an explicit host provider binding") }
            return try await provider(name, secureMcpOAuthEndpoint(raw))
        }
        // Plain remote HTTP may work without auth. Never send credentials to it.
        guard let raw = entry.config.url, (try? secureMcpOAuthEndpoint(raw)) != nil else { return nil }
        return try await client(for: entry).authentication
    }
    public func login(_ entry: McpServerEntry, signal: AbortSignal? = nil,
                      openURL: @escaping @Sendable (URL) async throws -> Void) async throws {
        try await client(for: entry, signal: signal).login(signal: signal, openURL: openURL)
    }
    public func logout(_ entry: McpServerEntry) async throws { try await client(for: entry).logout() }
}
