// Port: packages/coding-agent/src/extensions/mcp/config.ts @ 42cb822f1c5d3153069dd0661bfd297424666cf1
import Foundation
import PiAI

public struct McpServerEntry: Sendable {
    public var name: String
    public var config: McpServerConfig
    public var source: String
    public var scope: String?
    public var override: String?
}
public struct LoadedMcpConfig: Sendable {
    public var servers: [McpServerEntry] = []
    public var autoEnableCodemode: Bool?
    public var errors: [String] = []
    public var projectConfig: String?
}
public func loadMcpConfig(agentDir: String, cwd: String, projectTrusted: Bool) -> LoadedMcpConfig {
    var state = LoadedMcpConfig()
    func read(_ path: String, scope: String) {
        guard FileManager.default.fileExists(atPath: path) else { return }
        do {
            let parsed = try parseSettingsObject(String(contentsOfFile: path, encoding: .utf8))
            if parsed["mcpServers"] != nil && parsed["mcpServers"]?.objectValue == nil { throw PiError("expected an object with an \"mcpServers\" object") }
            if let enabled = parsed["autoEnableCodemode"] {
                if let value = enabled.boolValue { state.autoEnableCodemode = value }
                else { state.errors.append("\(path): autoEnableCodemode must be a boolean") }
            }
            for (name, raw) in parsed["mcpServers"]?.objectValue ?? JsonObject() {
                do {
                    if scope == "project", let value = raw.objectValue,
                       value["command"] == nil && value["url"] == nil && value["type"] == nil {
                        guard let index = state.servers.firstIndex(where: { $0.name == name }) else { throw PiError("server \"\(name)\" needs \"command\" or \"url\", or a global server to override") }
                        guard value.keys.allSatisfy({ ["enabled", "exposure", "toolExposure"].contains($0) }) else { throw PiError("server \"\(name)\": an override can only set enabled, exposure, toolExposure") }
                        var merged = state.servers[index].config.value
                        for (key, value) in value { merged[key] = value }
                        state.servers[index].config = try validateMcpServerConfig(name: name, raw: .object(merged))
                        state.servers[index].override = path
                        continue
                    }
                    let config = try validateMcpServerConfig(name: name, raw: raw)
                    if let clash = state.servers.first(where: { $0.name != name && mcpNamespace($0.name) == mcpNamespace(name) }) { throw PiError("server \"\(name)\" conflicts with \"\(clash.name)\"") }
                    if scope == "project", config.url != nil, config.value["auth"] != nil { throw PiError("server \"\(name)\": auth is only allowed in the global mcp.json") }
                    let entry = McpServerEntry(name: name, config: config, source: path, scope: scope)
                    if let index = state.servers.firstIndex(where: { $0.name == name }) { state.servers[index] = entry }
                    else { state.servers.append(entry) }
                } catch { state.errors.append("\(path): \(errorMessage(error))") }
            }
        } catch { state.errors.append("\(path): \(errorMessage(error))") }
    }
    read(agentDir + "/mcp.json", scope: "global")
    if projectTrusted {
        state.projectConfig = cwd + "/.pi/mcp.json"
        read(state.projectConfig!, scope: "project")
    }
    return state
}

/// Saves only the requested entry, preserving unrelated fields and ordered toolExposure entries.
public func saveMcpServerConfig(path: String, name: String, config: JsonValue?, expected: JsonValue? = nil) throws {
    if let config { _ = try validateMcpServerConfig(name: name, raw: config) }
    try editMcpServers(path: path) { servers in
        if let expected, (servers[name] ?? .null) != expected { throw PiError("MCP configuration changed on disk; reopen the editor before saving") }
        servers[name] = config; return true
    }
}

public struct McpServerConfigPatch: Sendable {
    public var enabled: Bool?
    public var exposure: McpExposure?
    public init(enabled: Bool? = nil, exposure: McpExposure? = nil) { self.enabled = enabled; self.exposure = exposure }
}
public func updateMcpServerConfig(path: String, name: String, patch: McpServerConfigPatch, override: Bool = false) throws {
    try editMcpServers(path: path) { servers in
        if servers[name] == nil && override { servers[name] = .emptyObject }
        guard var server = servers[name]?.objectValue else { throw PiError("\(path) does not define MCP server \"\(name)\"") }
        let keepDefaults = server["command"] == nil && server["url"] == nil && server["type"] == nil
        if let enabled = patch.enabled { server["enabled"] = enabled && !keepDefaults ? nil : .bool(enabled) }
        if let exposure = patch.exposure { server["exposure"] = exposure == .codemode && !keepDefaults ? nil : .string(exposure.rawValue) }
        servers[name] = .object(server); return true
    }
}
@discardableResult
public func addMcpServerConfig(path: String, name: String, config: McpServerConfig) throws -> Bool {
    _ = try validateMcpServerConfig(name: name, raw: .object(config.value))
    var replaced = false
    try editMcpServers(path: path) { servers in replaced = servers[name] != nil; servers[name] = .object(config.value); return true }
    return replaced
}
@discardableResult
public func removeMcpServerConfig(path: String, name: String) throws -> Bool {
    guard FileManager.default.fileExists(atPath: path) else { return false }
    var removed = false
    try editMcpServers(path: path) { servers in
        guard servers[name] != nil else { return false }
        servers[name] = nil; removed = true; return true
    }
    return removed
}
private func editMcpServers(path: String, edit: (inout JsonObject) throws -> Bool) throws {
    try withLockedJSONFile(path) { current in
        var object = try parseSettingsObject(current)
        if object["mcpServers"] != nil && object["mcpServers"]?.objectValue == nil { throw PiError("mcpServers must be an object") }
        var servers = object["mcpServers"]?.objectValue ?? JsonObject()
        guard try edit(&servers) else { return nil }
        object["mcpServers"] = .object(servers)
        let text = current ?? ""
        let regex = try NSRegularExpression(pattern: "^([ \\t]+)\\S", options: .anchorsMatchLines)
        let range = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)).flatMap { Range($0.range(at: 1), in: text) }
        let indent = range.map { String(text[$0].prefix(10)) } ?? "  "
        return prettyConfigJSON(.object(object), indent: indent) + "\n"
    }
}
