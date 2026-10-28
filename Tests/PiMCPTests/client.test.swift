import Foundation
import Testing
import PiAI
@testable import PiMCP

private actor FakeTransport: McpTransport {
    var events: McpTransportEvents?
    var messages: [JsonObject] = []
    var closed = false
    var hold = false
    func start(events: McpTransportEvents) { self.events = events }
    func send(_ message: JsonObject, signal: AbortSignal?) async throws {
        try signal?.throwIfAborted(); messages.append(message)
        guard let id = message["id"] else { return }
        let method = message["method"]?.stringValue
        var result: JsonValue = .emptyObject
        if method == "initialize" { result = .object(["protocolVersion": .string(LATEST_PROTOCOL_VERSION), "capabilities": .emptyObject, "serverInfo": .object(["name": .string("fixture"), "version": .string("1")])]) }
        else if hold { return }
        else if method == "tools/list" {
            if message["params"]?["cursor"] == nil { result = .object(["tools": .array([.object(["name": .string("first"), "inputSchema": .emptyObject])]), "nextCursor": .string("next")]) }
            else { result = .object(["tools": .array([.object(["name": .string("second"), "inputSchema": .emptyObject])])]) }
        } else if method == "tools/call" { result = .object(["content": .array([]), "structuredContent": .object(["answer": .number(42)]), "isError": .bool(true)]) }
        await events?.onMessage(["jsonrpc": .string("2.0"), "id": id, "result": result])
    }
    func close() async { if closed { return }; closed = true; await events?.onClose() }
    func setHold() { hold = true }
    func snapshot() -> [JsonObject] { messages }
    func emit(_ message: JsonObject) async { await events?.onMessage(message) }
}
@Suite("Pi MCP client") struct PiMCPClientTests {
    @Test func initializePaginationAndContent() async throws {
        let transport = FakeTransport(), client = McpClient(transport: FakeTransport())
        await client.close()
        let active = McpClient(transport: transport)
        try await active.connect()
        #expect(await active.state == .connected)
        #expect(try await active.listTools().compactMap { $0["name"]?.stringValue } == ["first", "second"])
        let result = try await active.callTool("first", arguments: [:])
        #expect(result["structuredContent"]?["answer"] == .number(42))
        #expect(result["isError"] == .bool(true))
        await active.close()
        #expect(await active.state == .closed)
    }
    @Test func timeoutCancelsOnlyRequest() async throws {
        let transport = FakeTransport(), controller = AbortController()
        let client = McpClient(transport: transport)
        try await client.connect(); await transport.setHold()
        await #expect(throws: McpTimeoutError.self) { try await client.request("slow", options: .init(timeoutMs: 20)) }
        #expect(await client.state == .connected)
        controller.abort()
        await #expect(throws: AbortError.self) { try await client.request("aborted", options: .init(signal: controller.signal)) }
        #expect(await transport.snapshot().contains { $0["method"] == .string("notifications/cancelled") })
        await client.close()
    }
    @Test func closeSettlesPendingRequest() async throws {
        let transport = FakeTransport(), clientOptions = McpClientOptions(requestTimeoutMs: 10_000)
        let client = McpClient(transport: transport, options: clientOptions)
        try await client.connect(); await transport.setHold()
        let task = Task { try await client.request("wait") }
        while !(await transport.snapshot().contains { $0["method"] == .string("wait") }) { await Task.yield() }
        await client.close()
        await #expect(throws: McpConnectionClosedError.self) { try await task.value }
    }
    @Test func cancellationDoesNotAffectAnotherRequest() async throws {
        let transport = FakeTransport(), controller = AbortController()
        let client = McpClient(transport: transport)
        try await client.connect(); await transport.setHold()
        let first = Task { try await client.request("first", options: .init(signal: controller.signal)) }
        let second = Task { try await client.request("second") }
        while await transport.snapshot().filter({ $0["method"] == .string("first") || $0["method"] == .string("second") }).count < 2 { await Task.yield() }
        controller.abort()
        await #expect(throws: AbortError.self) { try await first.value }
        let secondId = try #require(await transport.snapshot().first { $0["method"] == .string("second") }?["id"])
        await transport.emit(["jsonrpc": .string("2.0"), "id": secondId, "result": .string("ok")])
        #expect(try await second.value == .string("ok"))
        #expect(await client.state == .connected)
        await client.close()
    }
    @Test func progressResetsRequestTimeout() async throws {
        let transport = FakeTransport(), progress = Locked(0)
        let client = McpClient(transport: transport)
        try await client.connect(); await transport.setHold()
        let request = Task { try await client.request("long", options: .init(timeoutMs: 1000, onProgress: { _ in progress.withLock { $0 += 1 } })) }
        while !(await transport.snapshot().contains { $0["method"] == .string("long") }) { await Task.yield() }
        let message = try #require(await transport.snapshot().first { $0["method"] == .string("long") })
        let progressToken = try #require(message["params"]?["_meta"]?["progressToken"])
        for index in 1...5 {
            try await Task.sleep(for: .milliseconds(250))
            await transport.emit(["jsonrpc": .string("2.0"), "method": .string("notifications/progress"),
                                  "params": .object(["progressToken": progressToken, "progress": .number(Double(index))])])
        }
        await transport.emit(["jsonrpc": .string("2.0"), "id": message["id"]!, "result": .emptyObject])
        #expect(try await request.value == .emptyObject)
        #expect(progress.withLock { $0 } == 5)
        await client.close()
    }
    @Test func outOfRangeProtocolNumbersCannotTrap() async throws {
        let transport = FakeTransport(), client = McpClient(transport: FakeTransport())
        await client.close()
        let active = McpClient(transport: transport)
        try await active.connect(); await transport.setHold()
        let request = Task { try await active.request("malformed") }
        while !(await transport.snapshot().contains { $0["method"] == .string("malformed") }) { await Task.yield() }
        let id = try #require(await transport.snapshot().first { $0["method"] == .string("malformed") }?["id"])
        await transport.emit(["jsonrpc": .string("2.0"), "id": .number(1e100), "result": .null])
        await transport.emit(["jsonrpc": .string("2.0"), "method": .string("notifications/progress"), "params": .object(["progressToken": .number(1e100)])])
        await transport.emit(["jsonrpc": .string("2.0"), "id": id, "error": .object(["code": .number(1e100), "message": .string("invalid")])])
        await #expect(throws: McpError.self) { try await request.value }
        await active.close()
    }
}
