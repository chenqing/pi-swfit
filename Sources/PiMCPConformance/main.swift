// Adapter for the official MCP client conformance suite. Uses production HTTP/OAuth code.
import Foundation
import PiAI
import PiMCP

@main struct ConformanceClient {
    static func main() async {
        var report: JsonObject
        do { try await run(); report = ["success": .bool(true)] }
        catch { report = ["success": .bool(false), "error": .string(String(describing: error))] }
        if let path = ProcessInfo.processInfo.environment["PI_MCP_CONFORMANCE_REPORT"] {
            try? Data(JsonValue.object(report).serialized().utf8).write(to: URL(fileURLWithPath: path))
        }
        print(JsonValue.object(report).serialized())
        exit(report["success"] == .bool(true) ? 0 : 1)
    }

    static func run() async throws {
        let env = ProcessInfo.processInfo.environment
        guard let rawURL = CommandLine.arguments.last, let url = URL(string: rawURL),
              let scenario = env["MCP_CONFORMANCE_SCENARIO"] else { throw PiError("Missing scenario/server URL") }
        let context = try JsonValue.parse(env["MCP_CONFORMANCE_CONTEXT"] ?? "{}")
        var settings = JsonObject()
        settings["clientId"] = context["client_id"]
        settings["clientSecret"] = context["client_secret"]
        let auth = McpOAuthClient(name: "conformance", serverURL: url, settings: settings)
        var client: McpClient?
        var signIns = 0
        do {
            while true {
                do {
                    if client == nil {
                        let connection = McpClient(transport: StreamableHttpTransport(options: .init(url: url, authentication: auth.authentication)),
                                                   options: .init(requestTimeoutMs: 20_000))
                        client = connection
                        try await connection.connect()
                    }
                    guard let connection = client else { throw PiError("Missing connection") }
                    var result: JsonObject?
                    if scenario.hasPrefix("auth/") { result = try await connection.callTool("test-tool", arguments: [:]) }
                    else {
                        switch scenario {
                        case "initialize": break
                        case "tools_call": result = try await connection.callTool("add_numbers", arguments: ["a": .number(2), "b": .number(3)])
                        case "sse-retry": result = try await connection.callTool("test_reconnection", arguments: [:])
                        case "elicitation-sep1034-client-defaults": result = try await connection.callTool("test_client_elicitation_defaults", arguments: [:])
                        case "json-schema-2020-12-preservation":
                            let tools = try await connection.listTools()
                            guard let schema = tools.first(where: { $0["name"] == .string("json_schema_2020_12_tool") })?["inputSchema"] else { throw PiError("Schema tool missing") }
                            result = try await connection.callTool("json_schema_echo", arguments: ["schema": schema])
                        default: throw PiError("Unhandled conformance scenario: \(scenario)")
                        }
                    }
                    if result?["isError"] == .bool(true) { throw PiError("Tool returned isError: \(String(describing: result))") }
                    break
                } catch {
                    guard error is McpOAuthAuthorizationRequired || (error as? McpHTTPError)?.status == 401 else { throw error }
                    guard signIns < 3 else { throw PiError("MCP sign-in retry limit reached") }
                    signIns += 1
                    await client?.close(); client = nil
                    try await auth.login(openURL: simulatedBrowser)
                }
            }
            await client?.close()
        } catch { await client?.close(); throw error }
    }

    static func simulatedBrowser(_ url: URL) async throws {
        let response = try await defaultFetch(.init(url: url, timeoutMs: 10_000, followRedirects: false))
        guard let location = response.headers.get("Location"), let callback = URL(string: location),
              callback.scheme == "http", ["localhost", "127.0.0.1", "::1", "[::1]"].contains(callback.host ?? "") else {
            throw PiError("Conformance authorization did not redirect to loopback")
        }
        let delivered = try await defaultFetch(.init(url: callback, timeoutMs: 10_000, followRedirects: false))
        for try await _ in delivered.body {}
        guard delivered.ok else { throw PiError("OAuth callback rejected") }
    }
}
