// Port of extensions/mcp/resources.ts @ 42cb822f1c5d3153069dd0661bfd297424666cf1.
import Foundation
import PiAI
import PiAgent
import PiMCP

struct McpResourceServer: Sendable {
    let name: String
    let client: McpClient
    let signal: AbortSignal
    let timeoutMs: Int
    let failed: @Sendable (any Error) async -> Void
}
private func visibleResource(_ item: JsonObject) -> Bool {
    let uri = item["uri"]?.stringValue ?? item["uriTemplate"]?.stringValue ?? ""
    return !uri.hasPrefix("ui://") && (item["mimeType"]?.stringValue ?? "").range(of: #";\s*profile\s*=\s*"?mcp-app"?"#, options: .regularExpression) == nil
}
private func cleanResource(_ item: JsonObject, server: String? = nil) -> JsonValue {
    var item = item; item["_meta"] = nil; item["icons"] = nil
    if let server { item["server"] = .string(server) }
    return .object(item)
}
func createMcpResourceTools(exposure: ToolExposure, version: UUID,
                            servers: @escaping @Sendable () async -> [McpResourceServer]) -> [ExtensionTool] {
    [LIST_MCP_RESOURCES_TOOL, LIST_MCP_RESOURCE_TEMPLATES_TOOL, READ_MCP_RESOURCE_TOOL].map { name in
        let read = name == READ_MCP_RESOURCE_TOOL, templates = name == LIST_MCP_RESOURCE_TEMPLATES_TOOL
        let key = templates ? "resourceTemplates" : "resources"
        let method = templates ? "resources/templates/list" : "resources/list"
        var parameters: JsonObject = ["type": .string("object"), "additionalProperties": .bool(false), "properties": .object([
            "server": .object(["type": .string("string"), "description": .string("MCP server name; omit to list all servers.")]),
            read ? "uri" : "cursor": .object(["type": .string("string")])])]
        if read { parameters["required"] = .array([.string("server"), .string("uri")]) }
        let tool = AgentTool(name: name, label: name,
            description: read ? "Read a resource URI from a named MCP server." : "List MCP \(templates ? "resource templates" : "resources"). Prefer resources over web search. With server, returns one page; without server, returns all pages from every server.",
            parameters: .object(parameters), outputSchema: .object(["type": .string("object")]), execute: { _, args, signal, _ in
                func string(_ key: String) throws -> String? {
                    guard let value = args[key], value != .null else { return nil }
                    guard let text = value.stringValue else { throw PiError("\(key) must be a string") }
                    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                    return trimmed.isEmpty ? nil : trimmed
                }
                try signal?.throwIfAborted()
                let serverName = try string("server"), cursor = try string("cursor")
                let available = await servers().sorted { $0.name < $1.name }
                let selected = available.filter { serverName == nil || $0.name == serverName }
                if let serverName, selected.isEmpty { throw PiError("MCP server \(serverName) has no available resources") }
                var payload: JsonObject
                var content: [JsonValue]
                if read {
                    guard let serverName, let server = selected.first, let uri = try string("uri") else { throw PiError("server and uri are required") }
                    let combined = combineAbortSignals([signal, server.signal]); defer { combined.cleanup() }
                    let response: JsonObject
                    do { response = try await server.client.readResource(uri, options: .init(signal: combined.signal, timeoutMs: server.timeoutMs)) }
                    catch { await server.failed(error); throw error }
                    try combined.signal?.throwIfAborted()
                    let contents = (response["contents"]?.arrayValue ?? []).compactMap(\.objectValue).map { cleanResource($0) }
                    payload = ["server": .string(serverName), "uri": .string(uri), "contents": .array(contents)]
                    content = contents.flatMap { item -> [JsonValue] in
                        let label: [JsonValue] = contents.count > 1 ? [.object(["type": .string("text"), "text": .string((item["uri"]?.stringValue ?? uri) + ":")])] : []
                        return label + [.object(["type": .string("resource"), "resource": item])]
                    }
                } else {
                    if cursor != nil && serverName == nil { throw PiError("cursor requires a server") }
                    var items: [JsonValue] = [], errors: [JsonValue] = [], nextCursor: JsonValue?
                    for server in selected {
                        let combined = combineAbortSignals([signal, server.signal]); defer { combined.cleanup() }
                        do {
                            let options = McpRequestOptions(signal: combined.signal, timeoutMs: server.timeoutMs)
                            let entries: [JsonObject]
                            if serverName != nil {
                                let response = try await server.client.request(method, params: cursor.map { ["cursor": .string($0)] } ?? [:], options: options)
                                entries = (response[key]?.arrayValue ?? []).compactMap(\.objectValue)
                                nextCursor = response["nextCursor"]
                            } else {
                                entries = try await (templates ? server.client.listResourceTemplates(options: options) : server.client.listResources(options: options))
                            }
                            try combined.signal?.throwIfAborted()
                            items += entries.filter(visibleResource).map { cleanResource($0, server: server.name) }
                        } catch {
                            await server.failed(error)
                            try signal?.throwIfAborted()
                            if serverName != nil { throw error }
                            errors.append(.object(["server": .string(server.name), "error": .string("MCP resource listing failed")]))
                        }
                    }
                    payload = [key: .array(items)]
                    if let serverName { payload["server"] = .string(serverName) }
                    if let nextCursor { payload["nextCursor"] = nextCursor }
                    if !errors.isEmpty { payload["errors"] = .array(errors) }
                    content = [.object(["type": .string("text"), "text": .string(JsonValue.object(payload).serialized())])]
                }
                var result = convertMcpResult(server: serverName ?? "", tool: name, result: ["content": .array(content)])
                result.structuredContent = .object(payload)
                return result
            })
        return ExtensionTool(tool, exposure: exposure, version: version)
    }
}
