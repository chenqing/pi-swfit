import Foundation
import Testing
import PiAI
@testable import PiMCP
#if os(macOS)
import Darwin
#endif

@Suite("Pi MCP transports") struct PiMCPTransportTests {
    @Test func sseFraming() throws {
        let text = "event: message\r\ndata: {\"jsonrpc\":\"2.0\",\"result\":\"你好\"}\r\n\r\n"
        var decoder = McpSSEDecoder(maxMessageBytes: 1024), messages: [String] = []
        for byte in text.utf8 { messages += try decoder.feed(Data([byte])) }
        #expect(messages.count == 1)
        #expect(try JsonValue.parse(messages[0])["result"] == .string("你好"))
        var bounded = McpSSEDecoder(maxMessageBytes: 8)
        #expect(throws: PiError.self) { try bounded.feed(Data("data: too long a line".utf8)) }
    }
    @Test func httpSessionHeadersAndStructuredOnlyResult() async throws {
        let requests = Locked<[FetchRequest]>([])
        let url = try #require(URL(string: "https://fixture.invalid/mcp"))
        let transport = StreamableHttpTransport(options: .init(url: url, fetch: { request in
            requests.withLock { $0.append(request) }
            if request.method == "GET" { return .init(status: 405, headers: Headers(), body: .data(Data())) }
            if request.method == "DELETE" { return .init(status: 204, headers: Headers(), body: .data(Data())) }
            let message = try JsonValue.parse(String(decoding: request.body ?? Data(), as: UTF8.self))
            if message["id"] == nil { return .init(status: 202, headers: Headers(), body: .data(Data())) }
            let result: JsonValue
            var headers = Headers(["Content-Type": "application/json"])
            if message["method"] == .string("initialize") {
                headers.set("Mcp-Session-Id", "fixture-session")
                result = .object(["protocolVersion": .string("2025-03-26"), "capabilities": .emptyObject,
                                  "serverInfo": .object(["name": .string("fixture"), "version": .string("1")])])
            } else { result = .object(["structuredContent": .array([.number(42)])]) }
            let payload = JsonValue.object(["jsonrpc": .string("2.0"), "id": message["id"]!, "result": result]).serialized()
            return .init(status: 200, headers: headers, body: .data(Data(payload.utf8)))
        }))
        let client = McpClient(transport: transport)
        try await client.connect()
        let result = try await client.callTool("read", arguments: [:])
        #expect(result["content"] == .array([]))
        #expect(result["structuredContent"] == .array([.number(42)]))
        let call = requests.withLock { $0.last { $0.method == "POST" } }
        #expect(call?.headers.get("Mcp-Session-Id") == "fixture-session")
        #expect(call?.headers.get("MCP-Protocol-Version") == "2025-03-26")
        await client.close()
        #expect(requests.withLock { $0.contains { $0.method == "DELETE" } })
    }
    @Test func httpNeverReplaysToolPost() async throws {
        let calls = Locked(0)
        let transport = StreamableHttpTransport(options: .init(url: URL(string: "https://fixture.invalid/mcp")!, fetch: { _ in
            calls.withLock { $0 += 1 }; return .init(status: 503, headers: Headers(), body: .data(Data()))
        }))
        try await transport.start(events: .init(onMessage: { _ in }, onError: { _ in }, onClose: {}))
        await #expect(throws: McpHTTPError.self) { try await transport.send(["jsonrpc": .string("2.0"), "id": .number(1), "method": .string("tools/call")], signal: nil) }
        #expect(calls.withLock { $0 } == 1)
        await transport.close()
    }
    @Test func ssePrimingRetryAndCursorFields() throws {
        var decoder = McpSSEDecoder(maxMessageBytes: 1024)
        #expect(try decoder.feed(Data("id: first\r\nretry: 500\r\ndata: \r\n\r\n".utf8)).isEmpty)
        #expect(decoder.lastEventId == "first"); #expect(decoder.retryMs == 500)
        _ = try decoder.feed(Data("id: bad\0id\nretry: -1\ndata:   \n\n".utf8))
        #expect(decoder.lastEventId == "first"); #expect(decoder.retryMs == 500)
        _ = try decoder.feed(Data("id:\nretry: 60000\n\n".utf8))
        #expect(decoder.lastEventId == ""); #expect(decoder.retryMs == 60_000)
    }
    @Test func sseCursorCommitsOnlyAtEventBoundary() throws {
        var decoder = McpSSEDecoder(maxMessageBytes: 1024)
        _ = try decoder.feed(Data("id: committed\n\n".utf8))
        _ = try decoder.feed(Data("id: pending\nretry: 25\ndata: {}\n".utf8))
        #expect(decoder.lastEventId == "committed")
        #expect(decoder.retryMs == 25)
        #expect(try decoder.feed(Data("\n".utf8)) == ["{}"])
        #expect(decoder.lastEventId == "pending")
        _ = try decoder.feed(Data("id:\n".utf8))
        #expect(decoder.lastEventId == "pending")
        _ = try decoder.feed(Data("\n".utf8))
        #expect(decoder.lastEventId == "")
    }
    @Test func truncatedSSEEventResumesFromLastCompleteCursor() async throws {
        let posts = Locked(0), gets = Locked(0), replies = Locked(0)
        let transport = StreamableHttpTransport(options: .init(url: URL(string: "https://fixture.invalid/mcp")!, fetch: { request in
            if request.method == "POST" {
                posts.withLock { $0 += 1 }
                return .init(status: 200, headers: Headers(["Content-Type": "text/event-stream"]), body: ResponseBody(AsyncThrowingStream { stream in
                    // The cursor-only priming event is complete, but the next response is lost
                    // before its blank line. Resuming after "incomplete" would omit that result.
                    stream.yield(Data("id: committed\nretry: 1\n\nid: incomplete\ndata: {\"jsonrpc\":\"2.0\",\"id\":1,".utf8))
                    stream.finish(throwing: FetchError("connection lost"))
                }))
            }
            gets.withLock { $0 += 1 }
            #expect(request.headers.get("Last-Event-ID") == "committed")
            return .init(status: 200, headers: Headers(["Content-Type": "text/event-stream"]), body: .data(Data("id: incomplete\ndata: {\"jsonrpc\":\"2.0\",\"id\":1,\"result\":{}}\n\n".utf8)))
        }))
        try await transport.start(events: .init(onMessage: { _ in replies.withLock { $0 += 1 } }, onError: { _ in }, onClose: {}))
        try await transport.send(["jsonrpc": .string("2.0"), "id": .number(1), "method": .string("tools/call")], signal: nil)
        #expect(posts.withLock { $0 } == 1); #expect(gets.withLock { $0 } == 1); #expect(replies.withLock { $0 } == 1)
        await transport.close()
    }
    @Test func concurrentPostStreamsResumeWithIndependentCursors() async throws {
        let requests = Locked<[FetchRequest]>([]), replies = Locked<[JsonValue]>([])
        let transport = StreamableHttpTransport(options: .init(url: URL(string: "https://fixture.invalid/mcp")!, fetch: { request in
            requests.withLock { $0.append(request) }
            let body: String
            if request.method == "POST" {
                let message = try JsonValue.parse(String(decoding: request.body!, as: UTF8.self))
                body = "id: \(message["id"]!.serialized())\nretry: 1\ndata: \n\n"
            } else {
                let id = try #require(request.headers.get("Last-Event-ID"))
                body = "data: {\"jsonrpc\":\"2.0\",\"id\":\(id),\"result\":{}}\n\n"
            }
            return .init(status: 200, headers: Headers(["Content-Type": "text/event-stream"]), body: .data(Data(body.utf8)))
        }))
        try await transport.start(events: .init(onMessage: { message in replies.withLock { $0.append(message["id"]!) } }, onError: { _ in }, onClose: {}))
        async let first: Void = transport.send(["jsonrpc": .string("2.0"), "id": .number(1), "method": .string("tools/call")], signal: nil)
        async let second: Void = transport.send(["jsonrpc": .string("2.0"), "id": .number(2), "method": .string("tools/call")], signal: nil)
        _ = try await (first, second)
        #expect(Set(replies.withLock { $0 }) == Set([.number(1), .number(2)]))
        #expect(requests.withLock { $0.filter { $0.method == "POST" }.count } == 2)
        #expect(Set(requests.withLock { $0.filter { $0.method == "GET" }.compactMap { $0.headers.get("Last-Event-ID") } }) == Set(["1", "2"]))
        await transport.close()
    }
    @Test func cancelDuringSSERetryDoesNotReconnect() async throws {
        let sends = Locked(0), abort = AbortController()
        let transport = StreamableHttpTransport(options: .init(url: URL(string: "https://fixture.invalid/mcp")!, fetch: { _ in
            sends.withLock { $0 += 1 }
            return .init(status: 200, headers: Headers(["Content-Type": "text/event-stream"]), body: .data(Data("id: pending\nretry: 30000\ndata: \n\n".utf8)))
        }))
        try await transport.start(events: .init(onMessage: { _ in }, onError: { _ in }, onClose: {}))
        let request = Task { try await transport.send(["jsonrpc": .string("2.0"), "id": .number(1), "method": .string("tools/call")], signal: abort.signal) }
        for _ in 0..<100 where sends.withLock({ $0 == 0 }) { try await Task.sleep(for: .milliseconds(5)) }
        abort.abort()
        await #expect(throws: AbortError.self) { try await request.value }
        #expect(sends.withLock { $0 } == 1)
        await transport.close()
    }
    @Test func brokenSSEBodyAndTransientGETResumeWithoutRepeatingPOST() async throws {
        let posts = Locked(0), gets = Locked(0), replies = Locked(0)
        let transport = StreamableHttpTransport(options: .init(url: URL(string: "https://fixture.invalid/mcp")!, fetch: { request in
            if request.method == "POST" {
                posts.withLock { $0 += 1 }
                return .init(status: 200, headers: Headers(["Content-Type": "text/event-stream"]), body: ResponseBody(AsyncThrowingStream { stream in
                    stream.yield(Data("id: resumable\nretry: 1\ndata: \n\n".utf8))
                    stream.finish(throwing: FetchError("connection lost"))
                }))
            }
            #expect(request.headers.get("Last-Event-ID") == "resumable")
            if gets.withLock({ $0 += 1; return $0 }) == 1 { return .init(status: 503, headers: Headers(), body: .data(Data())) }
            return .init(status: 200, headers: Headers(["Content-Type": "text/event-stream"]), body: .data(Data("data: {\"jsonrpc\":\"2.0\",\"id\":1,\"result\":{}}\n\n".utf8)))
        }))
        try await transport.start(events: .init(onMessage: { _ in replies.withLock { $0 += 1 } }, onError: { _ in }, onClose: {}))
        try await transport.send(["jsonrpc": .string("2.0"), "id": .number(1), "method": .string("tools/call")], signal: nil)
        #expect(posts.withLock { $0 } == 1); #expect(gets.withLock { $0 } == 2); #expect(replies.withLock { $0 } == 1)
        await transport.close()
    }
    @Test(arguments: ["", "id: incomplete\ndata: "])
    func endedStreamWithoutCursorNeverReplaysRequest(_ body: String) async throws {
        let sends = Locked(0)
        let transport = StreamableHttpTransport(options: .init(url: URL(string: "https://fixture.invalid/mcp")!, fetch: { _ in
            sends.withLock { $0 += 1 }
            return .init(status: 200, headers: Headers(["Content-Type": "text/event-stream"]), body: .data(Data(body.utf8)))
        }))
        try await transport.start(events: .init(onMessage: { _ in }, onError: { _ in }, onClose: {}))
        await #expect(throws: PiError.self) { try await transport.send(["id": .number(1), "method": .string("tools/call")], signal: nil) }
        #expect(sends.withLock { $0 } == 1)
        await transport.close()
    }
    #if os(macOS)
    @Test func realStdioRoundTripAndShutdown() async throws {
        let program = #"""
        import json, sys
        for line in sys.stdin:
            message=json.loads(line)
            if 'id' not in message: continue
            method=message.get('method')
            result={}
            if method=='initialize': result={'protocolVersion':'2025-11-25','capabilities':{'tools':{}},'serverInfo':{'name':'fixture','version':'1'}}
            if method=='tools/list': result={'tools':[{'name':'echo','inputSchema':{'type':'object'}}]}
            if method=='tools/call': result={'content':[{'type':'text','text':'hello'}]}
            print(json.dumps({'jsonrpc':'2.0','id':message['id'],'result':result}), flush=True)
        """#
        let transport = StdioTransport(options: .init(command: "/usr/bin/python3", args: ["-u", "-c", program], cwd: FileManager.default.temporaryDirectory.path, closeTimeoutMs: 100))
        let client = McpClient(transport: transport)
        try await client.connect()
        let pid = try #require(await transport.pid)
        #expect(try await client.listTools().first?["name"] == .string("echo"))
        #expect(try await client.callTool("echo", arguments: [:])["content"]?[0]?["text"] == .string("hello"))
        await client.close()
        for _ in 0..<100 where kill(pid, 0) == 0 { try await Task.sleep(for: .milliseconds(10)) }
        #expect(kill(pid, 0) == -1 && errno == ESRCH)
    }
    @Test func stdioClosesDescendantProcessGroup() async throws {
        let program = #"""
        import os, signal, time, sys
        child=os.fork()
        if child==0:
            signal.signal(signal.SIGTERM, signal.SIG_IGN)
            while True: time.sleep(1)
        print(child, file=sys.stderr, flush=True)
        for line in sys.stdin: pass
        """#
        let transport = StdioTransport(options: .init(command: "/usr/bin/python3", args: ["-u", "-c", program], cwd: FileManager.default.temporaryDirectory.path, closeTimeoutMs: 100))
        try await transport.start(events: .init(onMessage: { _ in }, onError: { _ in }, onClose: {}))
        var child: Int32?
        for _ in 0..<100 {
            child = Int32(await transport.stderr.trimmingCharacters(in: .whitespacesAndNewlines))
            if child != nil { break }; try await Task.sleep(for: .milliseconds(10))
        }
        let descendant = try #require(child)
        await transport.close()
        for _ in 0..<100 where kill(descendant, 0) == 0 { try await Task.sleep(for: .milliseconds(10)) }
        #expect(kill(descendant, 0) == -1 && errno == ESRCH)
    }
    #endif
}
