// Port: packages/coding-agent/src/core/mcp-servers.ts @ 42cb822f1c5d3153069dd0661bfd297424666cf1
import Foundation
import PiAI

public enum McpExposure: String, Sendable, CaseIterable { case codemode, deferred, direct, hidden }
public let LIST_MCP_RESOURCES_TOOL = "list_mcp_resources"
public let LIST_MCP_RESOURCE_TEMPLATES_TOOL = "list_mcp_resource_templates"
public let READ_MCP_RESOURCE_TOOL = "read_mcp_resource"
public func isMcpToolName(_ name: String) -> Bool {
    name.hasPrefix("mcp__") || [LIST_MCP_RESOURCES_TOOL, LIST_MCP_RESOURCE_TEMPLATES_TOOL, READ_MCP_RESOURCE_TOOL].contains(name)
}
public func mcpNamespace(_ server: String) -> String { "mcp__" + server.replacingOccurrences(of: "-", with: "_") }
public func createToolNameMatcher(_ entries: [String]) -> @Sendable (String) -> Bool {
    let patterns = entries.compactMap { pattern -> NSRegularExpression? in
        let source = pattern.components(separatedBy: "*").map(NSRegularExpression.escapedPattern).joined(separator: ".*")
        return try? NSRegularExpression(pattern: "^" + source + "$")
    }
    return { name in patterns.contains { $0.firstMatch(in: name, range: NSRange(name.startIndex..., in: name)) != nil } }
}
public struct McpServerConfig: Sendable, Hashable {
    /// Ordered raw config preserves first-match toolExposure behavior and future fields.
    public var value: JsonObject
    public var exposure: McpExposure { McpExposure(rawValue: value["exposure"]?.stringValue ?? "") ?? .codemode }
    public var enabled: Bool { value["enabled"]?.boolValue ?? true }
    public var timeout: Double { value["timeout"]?.doubleValue ?? 60 }
    public var command: String? { value["command"]?.stringValue }
    public var url: String? { value["url"]?.stringValue }
}
public func getMcpToolExposure(config: McpServerConfig, toolName: String) -> McpExposure {
    let overrides = config.value["toolExposure"]?.objectValue ?? JsonObject()
    if let exact = overrides[toolName]?.stringValue, let exposure = McpExposure(rawValue: exact) { return exposure }
    for (pattern, value) in overrides where pattern.contains("*") {
        if createToolNameMatcher([pattern])(toolName), let raw = value.stringValue, let exposure = McpExposure(rawValue: raw) { return exposure }
    }
    return config.exposure
}
private let loopbackHosts: Set<String> = ["localhost", "127.0.0.1", "[::1]", "::1"]
public func isLoopbackRedirectUri(_ value: String) -> Bool {
    guard let url = URLComponents(string: value), url.scheme == "http", let host = url.host else { return false }
    return loopbackHosts.contains(host) && (url.query ?? "").isEmpty && (url.fragment ?? "").isEmpty
}
private func secureMcpURL(_ value: String) -> Bool {
    guard let url = URLComponents(string: value), let host = url.host else { return false }
    return url.scheme == "https" || (url.scheme == "http" && loopbackHosts.contains(host))
}
private func validateOAuth(_ value: JsonValue?) -> String? {
    guard let value else { return nil }
    guard let object = value.objectValue else { return "oauth must be an object" }
    for field in ["clientId", "clientSecret"] where object[field] != nil && object[field]?.stringValue == nil { return "oauth.\(field) must be a string" }
    let port = object["callbackPort"]?.doubleValue
    if object["callbackPort"] != nil && (port == nil || port! < 1 || port! > 65535 || port!.rounded() != port!) { return "oauth.callbackPort must be a port number" }
    if let callback = object["callbackUrl"] {
        guard let raw = callback.stringValue, isLoopbackRedirectUri(raw) else { return "oauth.callbackUrl must be an http URI on localhost, 127.0.0.1, or [::1] without query or fragment" }
        if let urlPort = URLComponents(string: raw)?.port, let port, Double(urlPort) != port { return "oauth.callbackUrl and oauth.callbackPort name different ports" }
    }
    if object["scope"] != nil && object["scope"]?.stringValue == nil { return "oauth.scope must be a string" }
    if object["clientName"] != nil && (object["clientName"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true) { return "oauth.clientName must be a non-empty string" }
    if let registration = object["clientRegistration"], registration != .string("dcr") {
        if registration != .string("cimd") { return "oauth.clientRegistration must be \"dcr\" or \"cimd\"" }
        if object["clientId"] != nil || object["clientName"] != nil { return "oauth.clientRegistration \"cimd\" cannot be combined with oauth.clientId or oauth.clientName" }
        if let raw = object["callbackUrl"]?.stringValue, let callback = URLComponents(string: raw),
           callback.host == "[::1]" || callback.host == "::1" || callback.path != "/callback" {
            return "oauth.clientRegistration \"cimd\" requires oauth.callbackUrl on localhost or 127.0.0.1 with path /callback"
        }
    }
    if let metadata = object["authServerMetadataUrl"], !(metadata.stringValue.map(secureMcpURL) ?? false) {
        return "oauth.authServerMetadataUrl must be an https URL, or http on localhost, 127.0.0.1, or [::1]"
    }
    return nil
}
public func validateMcpServerConfig(name: String, raw: JsonValue) throws -> McpServerConfig {
    guard name.range(of: "^[A-Za-z0-9_-]+$", options: .regularExpression) != nil else { throw PiError("invalid server name \"\(name)\" (use letters, digits, \"_\" and \"-\")") }
    guard var value = raw.objectValue else { throw PiError("server \"\(name)\" must be an object") }
    func fail(_ message: String) -> PiError { PiError("server \"\(name)\": " + message) }
    func alias(_ value: JsonValue) -> JsonValue { value == .string("codemode-deferred") ? .string("codemode") : value }
    if let exposure = value["exposure"] { value["exposure"] = alias(exposure) }
    if let overrides = value["toolExposure"]?.objectValue {
        var mapped = JsonObject(); for (key, entry) in overrides { mapped[key] = alias(entry) }; value["toolExposure"] = .object(mapped)
    }
    func exposureValid(_ entry: JsonValue) -> Bool { entry.stringValue.flatMap(McpExposure.init(rawValue:)) != nil }
    let exposures = McpExposure.allCases.map { "\"\($0.rawValue)\"" }.joined(separator: ", ")
    if let exposure = value["exposure"], !exposureValid(exposure) { throw fail("exposure must be one of \(exposures)") }
    if let overrides = value["toolExposure"] {
        guard let object = overrides.objectValue else { throw fail("toolExposure must map tool names to exposures") }
        for (name, exposure) in object where !exposureValid(exposure) { throw fail("toolExposure \"\(name)\" must be one of \(exposures)") }
    }
    if value["enabled"] != nil && value["enabled"]?.boolValue == nil { throw fail("enabled must be a boolean") }
    if value["description"] != nil && value["description"]?.stringValue == nil { throw fail("description must be a string") }
    if let timeout = value["timeout"], !(timeout.doubleValue.map { $0 > 0 } ?? false) { throw fail("timeout must be a positive number of seconds") }
    let type = value["type"]
    if type == .string("sse") { throw fail("legacy SSE transport is not supported; use the streamable HTTP URL") }
    func strings(_ entry: JsonValue) -> Bool { entry.objectValue.map { $0.allSatisfy { $0.1.stringValue != nil } } ?? false }
    if let url = value["url"]?.stringValue, type == nil || type == .string("http") || type == .string("streamable-http") {
        guard let parsed = URLComponents(string: url), ["http", "https"].contains(parsed.scheme ?? ""), parsed.host != nil else { throw fail("url must be an http or https URL") }
        if let headers = value["headers"], !strings(headers) { throw fail("headers must map names to strings") }
        if let error = validateOAuth(value["oauth"]) { throw fail(error) }
        if let auth = value["auth"] {
            guard let provider = auth["provider"]?.stringValue, !provider.isEmpty else { throw fail("auth.provider must be a provider name") }
            if !secureMcpURL(url) { throw fail("auth requires an https URL, or http on localhost, 127.0.0.1, or [::1]") }
        }
        return .init(value: value)
    }
    if value["command"]?.stringValue != nil, type == nil || type == .string("stdio") {
        if let args = value["args"], !(args.arrayValue.map { $0.allSatisfy { $0.stringValue != nil } } ?? false) { throw fail("args must be an array of strings") }
        if let env = value["env"], !strings(env) { throw fail("env must map names to strings") }
        if value["cwd"] != nil && value["cwd"]?.stringValue == nil { throw fail("cwd must be a string") }
        return .init(value: value)
    }
    throw PiError("server \"\(name)\" needs either \"command\" (stdio) or \"url\" (streamable HTTP)")
}
public struct RegisteredMcpServer: Sendable {
    public var name: String
    public var config: McpServerConfig
    public var extensionPath: String
    public init(name: String, config: McpServerConfig, extensionPath: String) { self.name = name; self.config = config; self.extensionPath = extensionPath }
}
public final class McpServerRegistry: Sendable {
    private struct State { var servers: [RegisteredMcpServer] = []; var listener: (@Sendable () -> Void)? }
    private let state = Locked(State())
    public init() {}
    public func register(_ server: RegisteredMcpServer) {
        let callback = state.withLock { state in
            if let index = state.servers.firstIndex(where: { $0.name == server.name }) { state.servers[index] = server }
            else { state.servers.append(server) }
            return state.listener
        }; callback?()
    }
    public func unregister(name: String, extensionPath: String) {
        let callback = state.withLock { state -> (@Sendable () -> Void)? in
            guard let index = state.servers.firstIndex(where: { $0.name == name && $0.extensionPath == extensionPath }) else { return nil }
            state.servers.remove(at: index); return state.listener
        }; callback?()
    }
    public func get(_ name: String) -> RegisteredMcpServer? { state.withLock { $0.servers.first { $0.name == name } } }
    public func list() -> [RegisteredMcpServer] { state.withLock { $0.servers } }
    public func setChangeListener(_ listener: (@Sendable () -> Void)?) { state.withLock { $0.listener = listener } }
}
