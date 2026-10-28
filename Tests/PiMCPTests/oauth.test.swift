import Foundation
import CryptoKit
import Testing
import PiAI
@testable import PiMCP

private func oauthResponse(_ object: JsonObject, status: Int = 200, headers: Headers = Headers()) -> FetchResponse {
    var headers = headers; headers.set("Content-Type", "application/json")
    return .init(status: status, headers: headers, body: ResponseBody(AsyncThrowingStream { continuation in
        continuation.yield(Data(JsonValue.object(object).serialized().utf8)); continuation.finish()
    }))
}
private let oauthMetadata: JsonObject = ["issuer": .string("https://auth.example"),
    "authorization_endpoint": .string("https://auth.example/authorize"), "token_endpoint": .string("https://auth.example/token"),
    "registration_endpoint": .string("https://auth.example/register"), "response_types_supported": .array([.string("code")]),
    "code_challenge_methods_supported": .array([.string("S256")]), "token_endpoint_auth_methods_supported": .array([.string("none")]),
    "authorization_response_iss_parameter_supported": .bool(true)]
@Suite("Pi MCP OAuth") struct PiMCPOAuthTests {
    #if os(macOS)
    @Test func realHTTPOAuthRefreshLogoutAndCancellation() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("pi-oauth-lifecycle-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let ready = root.appendingPathComponent("ready")
        let script = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Conformance/oauth-lifecycle.py")
        let process = Process(); process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        process.arguments = ["-u", script.path, ready.path]; process.currentDirectoryURL = root
        try process.run()
        defer { if process.isRunning { process.terminate() }; process.waitUntilExit() }
        var base: URL?
        for _ in 0..<300 {
            if let text = try? String(contentsOf: ready, encoding: .utf8), let url = URL(string: text), url.port != nil { base = url; break }
            try await Task.sleep(for: .milliseconds(10))
        }
        let origin = try #require(base), server = origin.appendingPathComponent("mcp")
        let auth = McpOAuthClient(name: "lifecycle", serverURL: server)
        let connection = McpClient(transport: StreamableHttpTransport(options: .init(url: server, authentication: auth.authentication)))
        await #expect(throws: McpOAuthAuthorizationRequired.self) { try await connection.connect() }
        let browser: @Sendable (URL) async throws -> Void = { url in
            let response = try await defaultFetch(.init(url: url, timeoutMs: 2_000, followRedirects: false))
            let callback = try #require(response.headers.get("Location").flatMap(URL.init(string:)))
            #expect(callback.host == "127.0.0.1")
            let accepted = try await defaultFetch(.init(url: callback, timeoutMs: 2_000)); _ = try await accepted.data()
            #expect(accepted.status == 200)
        }
        try await auth.login(openURL: browser)
        let authenticated = McpClient(transport: StreamableHttpTransport(options: .init(url: server, authentication: auth.authentication)))
        try await authenticated.connect()
        _ = try await defaultFetch(.init(url: origin.appendingPathComponent("reject-next"), method: "POST"))
        let result = try await authenticated.callTool("echo", arguments: [:])
        #expect(result["content"]?[0]?["text"] == .string("authenticated"))
        let stats = try await defaultFetch(.init(url: origin.appendingPathComponent("stats"))).json()
        #expect(stats["refreshes"] == .number(1)); #expect(stats["calls"] == .number(1))
        await authenticated.close()
        try await auth.logout()
        #expect(try await auth.authorizationHeader() == nil)

        // Logout cancels an outstanding loopback login and cannot resurrect credentials.
        let pendingURL = Locked<URL?>(nil)
        let pending = Task { try await auth.login { url in pendingURL.withLock { $0 = url } } }
        for _ in 0..<300 where pendingURL.withLock({ $0 == nil }) { try await Task.sleep(for: .milliseconds(10)) }
        #expect(pendingURL.withLock { $0 != nil })
        try await auth.logout()
        await #expect(throws: PiError("Login cancelled")) { try await pending.value }
        #expect(try await auth.authorizationHeader() == nil)

        // Explicit cancellation also closes the listener, and a later login remains usable.
        let cancel = AbortController()
        await #expect(throws: PiError("Login cancelled")) {
            try await auth.login(signal: cancel.signal) { _ in cancel.abort() }
        }
        try await auth.login(openURL: browser)
        #expect(try await auth.authorizationHeader() != nil)
        try await auth.logout()
    }
    #endif
    @Test func challengeAndDiscoveryPaths() throws {
        let challenge = parseWwwAuthenticate(#"Bearer resource_metadata="https://api.example/metadata", scope="files read", error="insufficient_scope""#)
        #expect(challenge.scope == "files read")
        #expect(challenge.resourceMetadataURL?.absoluteString == "https://api.example/metadata")
        #expect(parseWwwAuthenticate("Basic scope=bad").scope == nil)
        let paths = buildAuthorizationServerDiscoveryURLs(URL(string: "https://auth.example/tenant/")!).map(\.path)
        #expect(paths == ["/.well-known/oauth-authorization-server/tenant", "/.well-known/openid-configuration/tenant", "/tenant/.well-known/openid-configuration"])
        #expect(throws: PiError.self) { try secureMcpOAuthEndpoint("http://remote.example/token") }
        #expect(try secureMcpOAuthEndpoint("http://127.0.0.1/token").host == "127.0.0.1")
    }
    @Test func discoveryRejectsWrongIssuerAndWrongResource() async throws {
        let server = URL(string: "https://api.example/mcp")!
        await #expect(throws: PiError.self) {
            try await discoverMcpOAuth(serverURL: server, fetch: { request in
                if request.url.host == "api.example" { return oauthResponse(["resource": .string(server.absoluteString), "authorization_servers": .array([.string("https://different.example")])]) }
                return oauthResponse(oauthMetadata)
            })
        }
        await #expect(throws: PiError.self) {
            try await discoverMcpOAuth(serverURL: server, fetch: { _ in oauthResponse(["resource": .string("https://other.example/mcp")]) })
        }
    }
    @Test func pkceLoopbackLoginRefreshAndCredentialIsolation() async throws {
        let server = URL(string: "https://api.example/mcp")!, store = MemoryMcpOAuthStateStore()
        let challenge = Locked(""), tokenCalls = Locked(0)
        let fetch: FetchFunction = { request in
            if request.url.host == "api.example" { return oauthResponse(["resource": .string(server.absoluteString), "authorization_servers": .array([.string("https://auth.example")])]) }
            if request.url.path.hasPrefix("/.well-known") { return oauthResponse(oauthMetadata) }
            if request.url.path == "/register" { return oauthResponse(["client_id": .string("native-test")]) }
            if request.url.path == "/token" {
                #expect(!request.followRedirects)
                let body = String(decoding: request.body ?? Data(), as: UTF8.self)
                var url = URLComponents(); url.percentEncodedQuery = body
                let params = Dictionary(uniqueKeysWithValues: (url.queryItems ?? []).map { ($0.name, $0.value ?? "") })
                let count = tokenCalls.withLock { $0 += 1; return $0 }
                if count == 1 {
                    #expect(params["code"] == "test-code")
                    let verifier = try #require(params["code_verifier"])
                    let digest = Data(SHA256.hash(data: Data(verifier.utf8))).base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
                    #expect(digest == challenge.withLock { $0 })
                } else { #expect(params["grant_type"] == "refresh_token"); #expect(params["refresh_token"] == "refresh") }
                return oauthResponse(["access_token": .string(count == 1 ? "first" : "refreshed"), "refresh_token": .string("refresh"), "token_type": .string("Bearer"), "expires_in": .number(3600)])
            }
            throw PiError("Unexpected fixture endpoint")
        }
        let client = McpOAuthClient(name: "one", serverURL: server, store: store, fetch: fetch)
        try await client.login { url in
            let fields = Dictionary(uniqueKeysWithValues: (URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []).map { ($0.name, $0.value ?? "") })
            challenge.withLock { $0 = fields["code_challenge"] ?? "" }
            var redirect = try #require(URLComponents(string: fields["redirect_uri"] ?? ""))
            // Invalid state must leave the legitimate callback listener usable.
            redirect.queryItems = [.init(name: "state", value: "wrong"), .init(name: "code", value: "bad")]
            let rejected = try await defaultFetch(.init(url: redirect.url!)); #expect(rejected.status == 400)
            redirect.queryItems = [.init(name: "state", value: fields["state"]), .init(name: "code", value: "test-code"), .init(name: "iss", value: "https://auth.example")]
            let accepted = try await defaultFetch(.init(url: redirect.url!)); #expect(accepted.status == 200)
        }
        #expect(try await client.authorizationHeader() == "Bearer first")
        #expect(try await client.handleUnauthorized("Bearer", rejectedAuthorization: "Bearer first", signal: nil))
        #expect(try await client.authorizationHeader() == "Bearer refreshed")
        let other = McpOAuthClient(name: "two", serverURL: server, store: store, fetch: fetch)
        #expect(try await other.authorizationHeader() == nil)
        let changed = McpOAuthClient(name: "one", serverURL: server, settings: ["clientId": .string("another")], store: store, fetch: fetch)
        #expect(try await changed.authorizationHeader() == nil)
        try await client.logout()
        #expect(try await client.authorizationHeader() == nil)
    }
    @Test func httpRetriesOnlyDefiniteAuthenticationFailure() async throws {
        let sends = Locked(0), refreshes = Locked(0)
        let authentication = McpHTTPAuthentication(authorization: { _ in "Bearer token" }, unauthorized: { _, _, _ in refreshes.withLock { $0 += 1 }; return true })
        let transport = StreamableHttpTransport(options: .init(url: URL(string: "https://api.example/mcp")!, fetch: { request in
            #expect(request.headers.get("Authorization") == "Bearer token")
            #expect(!request.followRedirects)
            let count = sends.withLock { $0 += 1; return $0 }
            return oauthResponse([:], status: count == 1 ? 401 : 204)
        }, authentication: authentication))
        try await transport.start(events: .init(onMessage: { _ in }, onError: { _ in }, onClose: {}))
        try await transport.send(["jsonrpc": .string("2.0"), "method": .string("fixture")], signal: nil)
        #expect(sends.withLock { $0 } == 2); #expect(refreshes.withLock { $0 } == 1)
        await transport.close()
        let attempts = Locked(0)
        let failed = StreamableHttpTransport(options: .init(url: URL(string: "https://api.example/mcp")!, fetch: { _ in
            attempts.withLock { $0 += 1 }; throw PiError("uncertain network outcome")
        }, authentication: authentication))
        try await failed.start(events: .init(onMessage: { _ in }, onError: { _ in }, onClose: {}))
        await #expect(throws: PiError.self) { try await failed.send(["method": .string("tools/call")], signal: nil) }
        #expect(attempts.withLock { $0 } == 1)
        await failed.close()
    }
}
