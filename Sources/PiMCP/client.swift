// Port: packages/mcp/src/client.ts @ 42cb822f1c5d3153069dd0661bfd297424666cf1
// JSON result objects retain all MCP content fields rather than flattening them into text.
import Foundation
import PiAI

public struct McpClientOptions: Sendable {
    public var name: String
    public var version: String
    public var requestTimeoutMs: Int
    public var roots: [JsonObject]
    public var capabilities: JsonObject
    public init(name: String = "pi", version: String = "1.0", requestTimeoutMs: Int = 30_000, roots: [JsonObject] = [], capabilities: JsonObject = JsonObject()) {
        self.name = name; self.version = version; self.requestTimeoutMs = requestTimeoutMs; self.roots = roots
        self.capabilities = capabilities
    }
}
public struct McpRequestOptions: Sendable {
    public var signal: AbortSignal?
    public var timeoutMs: Int?
    public var onProgress: (@Sendable (JsonObject) -> Void)?
    public init(signal: AbortSignal? = nil, timeoutMs: Int? = nil, onProgress: (@Sendable (JsonObject) -> Void)? = nil) {
        self.signal = signal; self.timeoutMs = timeoutMs; self.onProgress = onProgress
    }
}
public actor McpClient {
    public enum State: Sendable { case idle, connecting, connected, closed }
    public private(set) var state: State = .idle
    public private(set) var serverCapabilities = JsonObject()
    public private(set) var serverInfo = JsonObject()
    public private(set) var instructions: String?
    private let transport: any McpTransport
    private let options: McpClientOptions
    private struct Pending {
        var continuation: CheckedContinuation<JsonValue, any Error>
        var controller: AbortController
        var timeoutMs: Int
        var timer: Task<Void, Never>?
        var generation = 0
        var signal: AbortSignal?
        var abortToken: Int?
        var onProgress: (@Sendable (JsonObject) -> Void)?
        var cancellable: Bool
    }
    private var nextId = 0
    private var pending: [Int: Pending] = [:]
    private var listeners: [String: [UUID: @Sendable (JsonObject) async -> Void]] = [:]
    private var errorListeners: [UUID: @Sendable (any Error) -> Void] = [:]
    private var closeListeners: [UUID: @Sendable () -> Void] = [:]
    public typealias RequestHandler = @Sendable (JsonObject, AbortSignal) async throws -> JsonValue
    private var handlers: [String: RequestHandler] = [:]
    private var incoming: [JsonValue: AbortController] = [:]
    public var connectionState: State { state }
    public init(transport: any McpTransport, options: McpClientOptions = .init()) { self.transport = transport; self.options = options }

    @discardableResult
    public func connect(signal: AbortSignal? = nil) async throws -> JsonObject {
        guard state == .idle else { throw PiError("MCP client has already been started") }
        state = .connecting
        do {
            try signal?.throwIfAborted()
            try await transport.start(events: .init(onMessage: { [weak self] in await self?.receive($0) },
                onError: { [weak self] in await self?.emitError($0) }, onClose: { [weak self] in await self?.failConnection(McpConnectionClosedError()) }))
            var offeredCapabilities = options.capabilities
            if !options.roots.isEmpty && offeredCapabilities["roots"] == nil { offeredCapabilities["roots"] = .emptyObject }
            let result = try await request("initialize", params: [
                "protocolVersion": .string(LATEST_PROTOCOL_VERSION),
                "capabilities": .object(offeredCapabilities),
                "clientInfo": .object(["name": .string(options.name), "version": .string(options.version)])
            ], options: .init(signal: signal))
            guard let version = result["protocolVersion"]?.stringValue,
                  let capabilities = result["capabilities"]?.objectValue,
                  let info = result["serverInfo"]?.objectValue, info["name"]?.stringValue != nil,
                  info["version"]?.stringValue != nil,
                  result["instructions"] == nil || result["instructions"]?.stringValue != nil else {
                throw McpError(-32600, "Invalid MCP initialize result")
            }
            guard SUPPORTED_PROTOCOL_VERSIONS.contains(version) else { throw McpError(-32600, "Unsupported MCP protocol version: \(version)") }
            try signal?.throwIfAborted()
            guard state == .connecting else { throw McpConnectionClosedError() }
            serverCapabilities = capabilities; serverInfo = info; instructions = result["instructions"]?.stringValue
            await transport.setProtocolVersion(version)
            try await notify("notifications/initialized")
            state = .connected
            return result.objectValue!
        } catch { await close(); throw error }
    }

    public func request(_ method: String, params: JsonObject = JsonObject(), options requestOptions: McpRequestOptions = .init()) async throws -> JsonValue {
        guard state == .connected || (state == .connecting && method == "initialize") else { throw McpConnectionClosedError() }
        try requestOptions.signal?.throwIfAborted(); try Task.checkCancellation()
        nextId += 1; let id = nextId
        let timeout = requestOptions.timeoutMs ?? options.requestTimeoutMs
        guard timeout > 0 else { throw PiError("MCP request timeout must be positive") }
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let controller = AbortController()
                let token = requestOptions.signal?.addEventListener { [weak self] in Task { await self?.cancel(id, error: AbortError()) } }
                pending[id] = .init(continuation: continuation, controller: controller, timeoutMs: timeout,
                                   signal: requestOptions.signal, abortToken: token,
                                   onProgress: requestOptions.onProgress, cancellable: method != "initialize")
                resetTimer(id)
                var parameters = params
                if requestOptions.onProgress != nil {
                    var meta = parameters["_meta"]?.objectValue ?? JsonObject(); meta["progressToken"] = .number(Double(id)); parameters["_meta"] = .object(meta)
                }
                let message: JsonObject = ["jsonrpc": .string("2.0"), "id": .number(Double(id)), "method": .string(method), "params": .object(parameters)]
                if requestOptions.signal?.aborted == true || Task.isCancelled {
                    Task { await self.cancel(id, error: AbortError()) }; return
                }
                Task {
                    do { try await transport.send(message, signal: controller.signal) }
                    catch { finish(id, .failure(error)) }
                }
            }
        } onCancel: { Task { await self.cancel(id, error: AbortError()) } }
    }
    public func notify(_ method: String, params: JsonObject? = nil) async throws {
        guard state != .closed else { throw McpConnectionClosedError() }
        var message: JsonObject = ["jsonrpc": .string("2.0"), "method": .string(method)]
        if let params { message["params"] = .object(params) }
        try await transport.send(message, signal: nil)
    }
    private func resetTimer(_ id: Int) {
        guard var item = pending[id] else { return }
        item.timer?.cancel(); item.generation += 1
        let generation = item.generation, timeout = item.timeoutMs
        item.timer = Task { [weak self] in
            do { try await Task.sleep(for: .milliseconds(timeout)) } catch { return }
            await self?.expire(id, generation: generation)
        }
        pending[id] = item
    }
    private func expire(_ id: Int, generation: Int) async {
        guard pending[id]?.generation == generation else { return }
        await cancel(id, error: McpTimeoutError(pending[id]!.timeoutMs))
    }
    private func finish(_ id: Int, _ result: Result<JsonValue, any Error>) {
        guard let item = pending.removeValue(forKey: id) else { return }
        item.timer?.cancel(); item.controller.abort()
        if let token = item.abortToken { item.signal?.removeEventListener(token) }
        item.continuation.resume(with: result)
    }
    private func cancel(_ id: Int, error: any Error) async {
        guard let item = pending[id] else { return }
        finish(id, .failure(error))
        if item.cancellable { try? await notify("notifications/cancelled", params: ["requestId": .number(Double(id)), "reason": .string(String(describing: error))]) }
    }
    private func failConnection(_ error: any Error) async {
        guard state != .closed else { return }
        state = .closed
        for id in Array(pending.keys) { finish(id, .failure(error)) }
        for controller in incoming.values { controller.abort() }; incoming.removeAll()
        let callbacks = Array(closeListeners.values); closeListeners.removeAll()
        callbacks.forEach { $0() }
        await transport.close()
    }
    public func close() async { await failConnection(McpConnectionClosedError()) }
    public func setRequestHandler(_ method: String, handler: RequestHandler?) { handlers[method] = handler }
    @discardableResult public func onError(_ listener: @escaping @Sendable (any Error) -> Void) -> UUID {
        let id = UUID(); errorListeners[id] = listener; return id
    }
    public func removeErrorListener(_ id: UUID) { errorListeners[id] = nil }
    @discardableResult public func onClose(_ listener: @escaping @Sendable () -> Void) -> UUID {
        let id = UUID()
        if state == .closed { listener() } else { closeListeners[id] = listener }
        return id
    }
    public func removeCloseListener(_ id: UUID) { closeListeners[id] = nil }
    private func emitError(_ error: any Error) { for callback in errorListeners.values { callback(error) } }
    @discardableResult
    public func onNotification(_ method: String, listener: @escaping @Sendable (JsonObject) async -> Void) -> UUID {
        let id = UUID(); listeners[method, default: [:]][id] = listener; return id
    }
    public func removeNotificationListener(_ id: UUID) {
        for key in Array(listeners.keys) { listeners[key]?[id] = nil }
    }
    private func receive(_ message: JsonObject) async {
        guard state != .closed, message["jsonrpc"] == .string("2.0") else { return }
        if let method = message["method"]?.stringValue {
            let params = message["params"]?.objectValue ?? JsonObject()
            if let id = message["id"] {
                if let handler = handlers[method] {
                    let controller = AbortController(); incoming[id] = controller
                    Task {
                        var reply: JsonObject = ["jsonrpc": .string("2.0"), "id": id]
                        do { reply["result"] = try await handler(params, controller.signal) }
                        catch { reply["error"] = .object(["code": .number(Double((error as? McpError)?.code ?? -32603)), "message": .string(errorMessage(error))]) }
                        incoming[id] = nil
                        if !controller.signal.aborted && state != .closed { try? await transport.send(reply, signal: nil) }
                    }
                    return
                }
                var reply: JsonObject = ["jsonrpc": .string("2.0"), "id": id]
                if method == "ping" { reply["result"] = .emptyObject }
                else if method == "roots/list" && (!options.roots.isEmpty || options.capabilities["roots"] != nil) { reply["result"] = .object(["roots": .array(options.roots.map(JsonValue.object))]) }
                else { reply["error"] = .object(["code": .number(-32601), "message": .string("Method not found: \(method)")]) }
                try? await transport.send(reply, signal: nil)
            } else {
                if method == "notifications/cancelled", let id = params["requestId"] { incoming[id]?.abort() }
                if method == "notifications/progress", let token = params["progressToken"]?.doubleValue,
                   let id = Int(exactly: token), let item = pending[id] {
                    resetTimer(id); item.onProgress?(params)
                }
                for callback in Array(listeners[method]?.values ?? [:].values) { await callback(params) }
            }
            return
        }
        guard let number = message["id"]?.doubleValue, let id = Int(exactly: number), id >= 0 else { return }
        if let error = message["error"]?.objectValue, let number = error["code"]?.doubleValue,
           let code = Int(exactly: number), let description = error["message"]?.stringValue {
            finish(id, .failure(McpError(code, description, data: error["data"])))
        } else if let result = message["result"] { finish(id, .success(result)) }
        else { finish(id, .failure(McpError(-32600, "Invalid JSON-RPC response"))) }
    }
    private func listAll(_ method: String, key: String, options: McpRequestOptions) async throws -> [JsonObject] {
        var cursor: String?, seen: Set<String> = [], items: [JsonObject] = []
        for _ in 0..<1_000 {
            var params = JsonObject(); if let cursor { params["cursor"] = .string(cursor) }
            let result = try await request(method, params: params, options: options)
            guard let page = result[key]?.arrayValue else { throw McpError(-32600, "Invalid MCP \(method) result") }
            for value in page {
                guard var item = value.objectValue else { throw McpError(-32600, "Invalid entry in MCP \(method) result") }
                if key == "tools" {
                    guard item["name"]?.stringValue != nil, item["inputSchema"]?.objectValue != nil else { throw McpError(-32600, "Invalid entry in MCP \(method) result") }
                } else {
                    let uriKey = key == "resources" ? "uri" : "uriTemplate"
                    guard let uri = item[uriKey]?.stringValue, item["name"] == nil || item["name"]?.stringValue != nil else { throw McpError(-32600, "Invalid entry in MCP \(method) result") }
                    if item["name"] == nil { item["name"] = .string(uri) }
                }
                items.append(item)
            }
            let next = result["nextCursor"]
            if next == nil || next == .null || next == .string("") { return items }
            guard let next = next?.stringValue else { throw McpError(-32600, "Invalid MCP \(method) cursor") }
            guard seen.insert(next).inserted else { throw McpError(-32600, "Repeated MCP pagination cursor") }
            cursor = next
        }
        throw McpError(-32600, "MCP pagination exceeded 1000 pages")
    }
    public func listTools(options: McpRequestOptions = .init()) async throws -> [JsonObject] { try await listAll("tools/list", key: "tools", options: options) }
    public func listResources(options: McpRequestOptions = .init()) async throws -> [JsonObject] { try await listAll("resources/list", key: "resources", options: options) }
    public func listResourceTemplates(options: McpRequestOptions = .init()) async throws -> [JsonObject] { try await listAll("resources/templates/list", key: "resourceTemplates", options: options) }
    public func callTool(_ name: String, arguments: JsonObject, options: McpRequestOptions = .init()) async throws -> JsonObject {
        let result = try await request("tools/call", params: ["name": .string(name), "arguments": .object(arguments)], options: options)
        guard var object = result.objectValue, object["content"] == nil || object["content"]?.arrayValue != nil else { throw McpError(-32600, "Invalid MCP tools/call result") }
        if object["content"] == nil { object["content"] = .array([]) }
        return object
    }
    public func readResource(_ uri: String, options: McpRequestOptions = .init()) async throws -> JsonObject {
        let result = try await request("resources/read", params: ["uri": .string(uri)], options: options)
        guard let object = result.objectValue, let contents = object["contents"]?.arrayValue,
              contents.allSatisfy({ $0["uri"]?.stringValue != nil && ($0["text"]?.stringValue != nil || $0["blob"]?.stringValue != nil) }) else { throw McpError(-32600, "Invalid MCP resources/read result") }
        return object
    }
}
