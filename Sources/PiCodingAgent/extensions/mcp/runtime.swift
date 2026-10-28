// Native session integration corresponding to extensions/mcp/{index,runtime}.ts @ 42cb822f1c5d3153069dd0661bfd297424666cf1.
// Tools and resources share the session registry and its permission, cancellation and exposure rules.
import Foundation
import PiAI
import PiAgent
import PiMCP

public typealias McpTransportFactory = @Sendable (McpServerEntry, String, AbortSignal) async throws -> any McpTransport
public struct McpExtensionOptions: Sendable {
    public var transportFactory: McpTransportFactory?
    public var authentication: McpAuthentication
    public var valueResolver: McpConfigValueResolver
    public var connectTimeoutMs: Int
    /// Session startup/turn preparation waits this long; remaining connections continue in the background.
    public var startupWaitMs: Int
    public init(connectTimeoutMs: Int = 10_000, startupWaitMs: Int = 1_000, transportFactory: McpTransportFactory? = nil, authentication: McpAuthentication = .init(), valueResolver: McpConfigValueResolver = .init()) {
        self.startupWaitMs = max(0, startupWaitMs); self.connectTimeoutMs = max(1, connectTimeoutMs); self.transportFactory = transportFactory; self.authentication = authentication; self.valueResolver = valueResolver
    }
}
public enum McpServerState: String, Sendable { case disabled, connecting, connected, disconnected, needsAuth, failed, closed }
public struct McpServerStatus: Sendable {
    public let name: String
    public let state: McpServerState
    public let toolCount: Int
    public let directToolCount: Int
    public let diagnostic: String?
}

/// Connections live for one AgentSession. Reconfiguration cancels old work before publishing a new
/// catalog. Every published tool still goes through AgentSession's ordinary permission/result hooks.
public actor McpExtensionRuntime {
    private struct Server {
        var entry: McpServerEntry
        var state: McpServerState
        var client: McpClient?
        var tools: [JsonObject] = []
        var hasResources = false
        var catalog = UUID()
        var lease = AbortController()
        var diagnostic: String?
    }
    private let options: McpExtensionOptions
    private let cwd: String
    private let agentDir: String
    private let projectTrusted: Bool
    private var context: ExtensionContext?
    private var servers: [String: Server] = [:]
    private var order: [String] = []
    private var generation = UUID()
    private var connections = AbortController()
    private var openings: [String: (id: UUID, task: Task<Void, Never>)] = [:]
    private var publication: Task<Void, Never>?
    private var closing: Task<Void, Never>?
    private var closed = false
    private var configErrors: [String] = []
    public init(options: McpExtensionOptions = .init(), cwd: String, agentDir: String, projectTrusted: Bool = false) {
        self.options = options; self.cwd = cwd; self.agentDir = agentDir; self.projectTrusted = projectTrusted
    }
    public nonisolated func makeExtension() -> NativeExtension {
        NativeExtension(id: "builtin:mcp", onEvent: { [self] event, context in
            switch event {
            case .sessionStart: await start(context)
            case .sessionShutdown: await close()
            case .resourcesReloaded: await reload()
            case .beforeAgentStart: await prepareForTurn()
            default: break
            }
        })
    }
    private func start(_ context: ExtensionContext) async {
        guard !closed, self.context == nil else { return }
        self.context = context
        await reload()
    }
    public func statuses() -> [McpServerStatus] {
        order.compactMap { name in
            guard let server = servers[name] else { return nil }
            return .init(name: name, state: server.state, toolCount: server.tools.count,
                directToolCount: server.tools.filter { getMcpToolExposure(config: server.entry.config, toolName: $0["name"]?.stringValue ?? "") == .direct }.count,
                diagnostic: server.diagnostic)
        }
    }
    public func diagnostics() -> [String] { configErrors }
    /// Reloads global config and, only for trusted sessions, project config. Secrets resolve later,
    /// inside transport creation; parsing/status inspection never runs commands or reads credentials.
    public func reload() async {
        guard !closed, let context, !context.signal.aborted else { return }
        generation = UUID(); let current = generation
        connections.abort(); connections = AbortController()
        openings.values.forEach { $0.task.cancel() }; openings.removeAll()
        let old = Array(servers.values)
        old.forEach { $0.lease.abort() }
        let loaded = loadMcpConfig(agentDir: agentDir, cwd: cwd, projectTrusted: projectTrusted)
        configErrors = loaded.errors
        servers = [:]; order = loaded.servers.map(\.name)
        for entry in loaded.servers { servers[entry.name] = .init(entry: entry, state: entry.config.enabled ? .connecting : .disabled) }
        await publish()
        for server in old { await server.client?.close() }
        guard current == generation, !closed else { return }
        let tasks = loaded.servers.filter { $0.config.enabled }.map { startConnection($0.name, generation: current) }
        await waitForStartup(tasks)
    }
    /// Retry dropped connections at the next user turn. No tool request is replayed, and disabled,
    /// failed or authorization-required servers remain under explicit user control.
    public func prepareForTurn() async {
        guard !closed, context?.signal.aborted == false else { return }
        var tasks: [Task<Void, Never>] = []
        for name in order {
            if servers[name]?.state == .disconnected {
                openings.removeValue(forKey: name)?.task.cancel()
                servers[name]?.lease.abort(); servers[name]?.lease = AbortController()
                servers[name]?.client = nil; servers[name]?.state = .connecting
                tasks.append(startConnection(name, generation: generation))
            } else if let opening = openings[name] { tasks.append(opening.task) }
        }
        await waitForStartup(tasks)
    }
    private func startConnection(_ name: String, generation current: UUID) -> Task<Void, Never> {
        if let opening = openings[name] { return opening.task }
        let id = UUID()
        let task = Task { [weak self] in
            await self?.connect(name, generation: current)
            await self?.finishedOpening(name, id: id)
        }
        openings[name] = (id, task)
        return task
    }
    private func finishedOpening(_ name: String, id: UUID) {
        if openings[name]?.id == id { openings[name] = nil }
    }
    private func waitForStartup(_ tasks: [Task<Void, Never>]) async {
        guard !tasks.isEmpty, options.startupWaitMs > 0 else { return }
        let completed = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
        let observer = Task {
            for task in tasks { await task.value }
            completed.continuation.yield(())
        }
        let timeout = Task {
            do { try await Task.sleep(for: .milliseconds(options.startupWaitMs)) }
            catch { return }
            completed.continuation.yield(())
        }
        for await _ in completed.stream { break }
        completed.continuation.finish(); timeout.cancel(); observer.cancel()
    }
    /// Session-local toggle. Persist the config separately with updateMcpServerConfig when desired.
    public func setEnabled(_ name: String, _ enabled: Bool) async throws {
        guard !closed, let context, !context.signal.aborted, var server = servers[name] else { throw PiError("MCP server is unavailable") }
        if server.entry.config.enabled == enabled { return }
        server.entry.config.value["enabled"] = .bool(enabled)
        let old = server.client
        openings.removeValue(forKey: name)?.task.cancel()
        server.lease.abort(); server.lease = AbortController(); server.catalog = UUID()
        server.client = nil; server.tools = []; server.state = enabled ? .connecting : .disabled
        server.diagnostic = nil; servers[name] = server
        await publish(); await old?.close()
        if enabled { await startConnection(name, generation: generation).value }
    }
    private func connect(_ name: String, generation current: UUID) async {
        guard current == generation, !closed, let server = servers[name], server.entry.config.enabled, let context else { return }
        let lease = server.lease
        let deadline = AbortSignal.timeout(options.connectTimeoutMs)
        let combined = combineAbortSignals([context.signal, connections.signal, lease.signal, deadline])
        defer { combined.cleanup() }
        var opened: McpClient?
        do {
            let transport: any McpTransport
            if let factory = options.transportFactory { transport = try await factory(server.entry, cwd, combined.signal ?? lease.signal) }
            else { transport = try await createDefaultMcpTransport(server.entry, cwd, combined.signal ?? lease.signal, authentication: options.authentication, valueResolver: options.valueResolver) }
            guard valid(name, current, lease) else { await transport.close(); return }
            let client = McpClient(transport: transport, options: .init(requestTimeoutMs: options.connectTimeoutMs))
            opened = client; servers[name]?.client = client
            await client.onError { [weak self] error in
                Task { await self?.authenticationFailed(name, generation: current, lease: lease, error: error) }
            }
            await client.onClose { [weak self] in Task { await self?.disconnected(name, generation: current, lease: lease) } }
            await client.onNotification("notifications/tools/list_changed") { [weak self] _ in
                await self?.refresh(name, generation: current, lease: lease)
            }
            try await client.connect(signal: combined.signal)
            guard valid(name, current, lease) else { await client.close(); return }
            servers[name]?.hasResources = await client.serverCapabilities["resources"] != nil
            servers[name]?.state = .connected
            await refresh(name, generation: current, lease: lease)
        } catch {
            if valid(name, current, lease) {
                servers[name]?.state = ((error as? McpHTTPError)?.status == 401 || error is McpOAuthAuthorizationRequired) ? .needsAuth : .failed
                // Transport/config errors may contain credentials. Keep diagnostics actionable without
                // storing raw headers, URLs, shell output or server-provided error payloads.
                servers[name]?.diagnostic = error is McpTimeoutError || deadline.aborted ? "MCP connection timed out" : "MCP connection failed; check transport, configuration and authentication"
                servers[name]?.tools = []
                await publish()
            }
            await opened?.close()
        }
    }
    private func valid(_ name: String, _ current: UUID, _ lease: AbortController) -> Bool {
        !closed && context?.signal.aborted == false && generation == current && !lease.signal.aborted && servers[name]?.lease === lease
    }
    private func disconnected(_ name: String, generation current: UUID, lease: AbortController) async {
        guard valid(name, current, lease) else { return }
        if servers[name]?.state == .connected || servers[name]?.state == .connecting { servers[name]?.state = .disconnected }
        servers[name]?.tools = []; servers[name]?.catalog = UUID()
        await publish()
    }
    private func refresh(_ name: String, generation current: UUID, lease: AbortController) async {
        guard valid(name, current, lease), let client = servers[name]?.client else { return }
        let catalog = UUID()
        let combined = combineAbortSignals([lease.signal, context?.signal, connections.signal])
        defer { combined.cleanup() }
        servers[name]?.catalog = catalog; servers[name]?.tools = []
        // Withdraw immediately, even if tools/list later fails or a second notification overtakes it.
        await publish()
        do {
            let capabilities = await client.serverCapabilities
            let tools = capabilities["tools"] == nil ? [] : try await client.listTools(options: .init(signal: combined.signal, timeoutMs: options.connectTimeoutMs))
            guard valid(name, current, lease), servers[name]?.catalog == catalog, await client.state == .connected else { return }
            var seen = Set<String>()
            for tool in tools {
                guard let toolName = tool["name"]?.stringValue, !toolName.isEmpty, seen.insert(toolName).inserted,
                      tool["inputSchema"]?.objectValue != nil else { throw PiError("Invalid MCP tool catalog") }
            }
            servers[name]?.tools = tools
            servers[name]?.diagnostic = nil
            await publish()
        } catch {
            guard valid(name, current, lease), servers[name]?.catalog == catalog else { return }
            await authenticationFailed(name, generation: current, lease: lease, error: error)
            guard valid(name, current, lease), servers[name]?.catalog == catalog, servers[name]?.state == .connected else { return }
            servers[name]?.diagnostic = "MCP tool catalog refresh failed; stale tools were withdrawn"
        }
    }
    private func publish() async {
        guard let context else { return }
        var definitions: [ExtensionTool] = []
        var names = Set<String>()
        for name in order {
            guard let server = servers[name], server.state == .connected, server.entry.config.enabled else { continue }
            for tool in server.tools {
                guard let rawName = tool["name"]?.stringValue else { continue }
                let exposure = ToolExposure(rawValue: getMcpToolExposure(config: server.entry.config, toolName: rawName).rawValue) ?? .codemode
                let toolName = createMcpToolName(server: name, tool: rawName, isTaken: { names.contains($0) })
                guard names.insert(toolName).inserted else { continue }
                var parameters = tool["inputSchema"]?.objectValue ?? JsonObject()
                if parameters["type"] == nil { parameters["type"] = .string("object") }
                if parameters["properties"] == nil { parameters["properties"] = .emptyObject }
                let current = generation, catalog = server.catalog
                definitions.append(ExtensionTool(AgentTool(name: toolName, label: "\(name)/\(rawName)",
                    description: tool["description"]?.stringValue ?? "MCP tool \(rawName) from server \(name)",
                    parameters: .object(parameters), outputSchema: createMcpResultSchema(tool["outputSchema"]),
                    execute: { [weak self] _, args, signal, update in
                        guard let self else { throw PiError("MCP session is closed") }
                        return try await self.call(name, tool: rawName, args: args, generation: current, catalog: catalog, signal: signal, update: update)
                    }), exposure: exposure, namespace: mcpNamespace(name), version: catalog))
            }
        }
        let resourceExposures = order.compactMap { name -> McpExposure? in
            guard let server = servers[name], server.state == .connected, server.hasResources,
                  server.entry.config.enabled, server.entry.config.exposure != .hidden else { return nil }
            return server.entry.config.exposure
        }
        if !resourceExposures.isEmpty {
            let exposure: ToolExposure = resourceExposures.contains(.direct) ? .direct : resourceExposures.contains(.deferred) ? .deferred : .codemode
            definitions += createMcpResourceTools(exposure: exposure, version: generation) { [weak self] in await self?.resourceServers() ?? [] }
        }
        let previous = publication, snapshot = definitions
        let task = Task { [weak self] in
            await previous?.value
            guard !context.signal.aborted else { return }
            do { try await context.registerTools(snapshot) }
            catch { await self?.publicationFailed() }
        }
        publication = task
        await task.value
    }
    private func resourceServers() -> [McpResourceServer] {
        guard !closed, context?.signal.aborted == false else { return [] }
        return order.compactMap { name in
            guard let server = servers[name], server.state == .connected, server.hasResources,
                  server.entry.config.enabled, server.entry.config.exposure != .hidden, let client = server.client else { return nil }
            let current = generation, lease = server.lease
            return .init(name: name, client: client, signal: lease.signal,
                         timeoutMs: Int(min(Double(Int.max / 2), server.entry.config.timeout * 1000)),
                         failed: { [weak self] error in await self?.authenticationFailed(name, generation: current, lease: lease, error: error) })
        }
    }
    private func authenticationFailed(_ name: String, generation current: UUID, lease: AbortController, error: any Error) async {
        guard valid(name, current, lease), error is McpOAuthAuthorizationRequired || (error as? McpHTTPError)?.status == 401 else { return }
        servers[name]?.state = .needsAuth; servers[name]?.tools = []
        servers[name]?.diagnostic = "MCP authentication is required; sign in and reconnect"
        await publish()
    }
    public func login(_ name: String, signal: AbortSignal? = nil, openURL: @escaping @Sendable (URL) async throws -> Void) async throws {
        guard let server = servers[name], !closed else { throw PiError("MCP server is unavailable") }
        let combined = combineAbortSignals([signal, connections.signal, context?.signal]); defer { combined.cleanup() }
        try await options.authentication.login(server.entry, signal: combined.signal, openURL: openURL)
        try combined.signal?.throwIfAborted()
        try await reconnect(name)
    }
    public func logout(_ name: String) async throws {
        guard let server = servers[name], !closed else { throw PiError("MCP server is unavailable") }
        let current = generation
        try await options.authentication.logout(server.entry)
        guard valid(name, current, server.lease) else { return }
        openings.removeValue(forKey: name)?.task.cancel()
        server.lease.abort(); servers[name]?.client = nil; servers[name]?.tools = []; servers[name]?.state = .needsAuth
        await publish(); await server.client?.close()
    }
    public func reconnect(_ name: String) async throws {
        guard !closed, var server = servers[name], server.entry.config.enabled else { throw PiError("MCP server is unavailable") }
        let old = server.client
        openings.removeValue(forKey: name)?.task.cancel()
        server.lease.abort(); server.lease = AbortController(); server.catalog = UUID()
        server.client = nil; server.tools = []; server.state = .connecting; server.diagnostic = nil
        servers[name] = server
        await publish(); await old?.close()
        await startConnection(name, generation: generation).value
    }
    private func publicationFailed() { configErrors.append("MCP tool publication failed; check tool name conflicts and session storage") }
    private func call(_ name: String, tool: String, args: JsonValue, generation current: UUID, catalog: UUID,
                      signal: AbortSignal?, update: AgentToolUpdateCallback?) async throws -> AgentToolResult {
        guard !closed, current == generation, let server = servers[name], server.catalog == catalog,
              server.entry.config.enabled, server.state == .connected, let client = server.client,
              let context, !context.signal.aborted else { throw PiError("MCP tool is no longer available") }
        guard let arguments = args.objectValue else { throw PiError("MCP tool arguments must be an object") }
        let combined = combineAbortSignals([signal, server.lease.signal, context.signal])
        defer { combined.cleanup() }
        try combined.signal?.throwIfAborted()
        let milliseconds = server.entry.config.timeout * 1000
        guard milliseconds.isFinite, milliseconds > 0, milliseconds < Double(Int.max) else { throw PiError("Invalid MCP timeout") }
        let result: JsonObject
        do { result = try await client.callTool(tool, arguments: arguments, options: .init(signal: combined.signal, timeoutMs: Int(milliseconds), onProgress: { progress in
            let text = progress["message"]?.stringValue ?? "Progress \(progress["progress"]?.serialized() ?? "")"
            var details: JsonObject = ["server": .string(name), "tool": .string(tool)]
            if let value = progress["progress"]?.doubleValue, value.isFinite, value >= 0 { details["progress"] = .number(value) }
            if let value = progress["total"]?.doubleValue, value.isFinite, value > 0 { details["total"] = .number(value) }
            update?(.init(content: [.text(.init(text: text))], details: .object(details)))
        }))
        } catch {
            if current == generation, servers[name]?.catalog == catalog,
               error is McpOAuthAuthorizationRequired || (error as? McpHTTPError)?.status == 401 {
                servers[name]?.state = .needsAuth; servers[name]?.tools = []
                servers[name]?.diagnostic = "MCP authentication is required; sign in and reconnect"
                await publish()
            }
            throw error
        }
        try combined.signal?.throwIfAborted()
        return convertMcpResult(server: name, tool: tool, result: result)
    }
    public func close() async {
        if let closing { await closing.value; return }
        closed = true; generation = UUID(); connections.abort()
        openings.values.forEach { $0.task.cancel() }; openings.removeAll()
        let old = Array(servers.values)
        for name in order { servers[name]?.lease.abort(); servers[name]?.state = .closed; servers[name]?.tools = [] }
        let task = Task { [self] in
            await publish()
            for server in old { await server.client?.close() }
        }
        closing = task
        await task.value
    }
}

/// Config interpolation matches upstream's $NAME/${NAME}, $$ and $! forms. Command-backed secrets
/// are handled separately by McpConfigValueResolver after configuration is authorized.
public func resolveMcpConfigValue(_ value: String, environment: [String: String] = ProcessInfo.processInfo.environment) throws -> String {
    guard !value.hasPrefix("!") else { throw PiError("Command-backed MCP values require a host resolver") }
    let pattern = #"\$\$|\$!|\$\{[A-Za-z_][A-Za-z0-9_]*\}|\$[A-Za-z_][A-Za-z0-9_]*"#
    let regex = try NSRegularExpression(pattern: pattern)
    var resolved = value
    for match in regex.matches(in: value, range: NSRange(value.startIndex..., in: value)).reversed() {
        guard let range = Range(match.range, in: resolved), let original = Range(match.range, in: value) else { continue }
        let token = String(value[original]), replacement: String
        if token == "$$" { replacement = "$" } else if token == "$!" { replacement = "!" }
        else {
            let key = token.hasPrefix("${") ? String(token.dropFirst(2).dropLast()) : String(token.dropFirst())
            guard let secret = environment[key], !secret.isEmpty else { throw PiError("Missing MCP environment variable: \(key)") }
            replacement = secret
        }
        resolved.replaceSubrange(range, with: replacement)
    }
    return resolved
}
public func createDefaultMcpTransport(_ entry: McpServerEntry, _ cwd: String, _ signal: AbortSignal, authentication: McpAuthentication? = nil, valueResolver: McpConfigValueResolver = .init()) async throws -> any McpTransport {
    try signal.throwIfAborted()
    let config = entry.config
    if let raw = config.url {
        guard let url = URL(string: raw) else { throw PiError("Invalid MCP URL") }
        var headers = Headers()
        for (key, value) in config.value["headers"]?.objectValue ?? JsonObject() {
            headers.set(key, try await valueResolver.resolve(value.stringValue ?? "", cwd: cwd, signal: signal))
        }
        let auth = headers.has("Authorization") ? nil : try await authentication?.httpAuthentication(for: entry)
        return StreamableHttpTransport(options: .init(url: url, headers: headers, authentication: auth))
    }
    #if os(macOS)
    func expand(_ value: String) -> String { (value as NSString).expandingTildeInPath }
    guard let command = config.command else { throw PiError("Missing MCP command") }
    var env: [String: String] = [:]
    for (key, value) in config.value["env"]?.objectValue ?? JsonObject() { env[key] = try await valueResolver.resolve(value.stringValue ?? "", cwd: cwd, signal: signal) }
    let path = expand(config.value["cwd"]?.stringValue ?? ".")
    let directory = path.hasPrefix("/") ? path : URL(fileURLWithPath: cwd).appendingPathComponent(path).standardized.path
    return StdioTransport(options: .init(command: expand(command), args: (config.value["args"]?.arrayValue ?? []).compactMap(\.stringValue).map(expand), cwd: directory, env: env))
    #else
    throw PiError("MCP stdio is only available on macOS")
    #endif
}
