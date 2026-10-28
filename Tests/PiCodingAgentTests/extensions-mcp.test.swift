import Foundation
import Testing
import PiAI
import PiAgent
import PiMCP
@testable import PiCodingAgent

private struct ExtensionFixture {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("pi-extensions-\(UUID())")
    var cwd: String { root.appendingPathComponent("project").path }
    var agentDir: String { root.appendingPathComponent("agent").path }
    init() throws {
        try FileManager.default.createDirectory(atPath: cwd, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(atPath: agentDir, withIntermediateDirectories: true)
    }
    func config(_ content: String, project: Bool = false) throws {
        let directory = project ? cwd + "/.pi" : agentDir
        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        try content.write(toFile: directory + "/mcp.json", atomically: true, encoding: .utf8)
    }
    func cleanup() { try? FileManager.default.removeItem(at: root) }
    func session(extensions: [NativeExtension] = [], mcp: McpExtensionOptions? = nil, trusted: Bool = false,
                 manager: SessionManager? = nil, options: AgentOptions? = nil) async throws -> CreateAgentSessionResult {
        let settings = SettingsManager.inMemory(.init(compaction: .init(enabled: false), retry: .init(enabled: false)))
        let resources = DefaultResourceLoader(.init(cwd: cwd, agentDir: agentDir, settingsManager: settings, homeDir: root.appendingPathComponent("home").path))
        return try await createAgentSession(.init(cwd: cwd, agentDir: agentDir, projectTrusted: trusted,
            agentOptions: options ?? testAgentOptions(), settingsManager: settings, sessionManager: manager,
            resourceLoader: resources, extensions: extensions, mcp: mcp))
    }
}
private func testAgentOptions(call: String? = nil, tools: [AgentTool] = [],
                              observe: (@Sendable ([Tool]) -> Void)? = nil) -> AgentOptions {
    let count = Locked(0)
    let model = Model(id: "test", name: "Test", api: "openai-completions", provider: "test", baseUrl: "https://fixture.invalid",
                      reasoning: false, input: ["text"], contextWindow: 100_000, maxTokens: 1000)
    return .init(initialState: .init(systemPrompt: "Test", model: model, tools: tools), streamFn: { model, context, _ in
        observe?(getCurrentTools(context.messages))
        let first = count.withLock { $0 += 1; return $0 == 1 }
        let content: [AssistantContent] = first && call != nil ? [.toolCall(.init(id: "call-1", name: call!))] : [.text(.init(text: "done"))]
        let reason: StopReason = first && call != nil ? .toolUse : .stop
        let message = AssistantMessage(content: content, api: model.api, provider: model.provider, model: model.id, stopReason: reason)
        let stream = AssistantMessageEventStream(); stream.push(.done(reason: reason, message: message)); return stream
    })
}
private func testTool(_ name: String, execute: @escaping @Sendable () -> AgentToolResult = { .init(content: [.text(.init(text: "original"))], structuredContent: .string("original")) }) -> AgentTool {
    .init(name: name, label: name, description: name, parameters: .object(["type": .string("object"), "properties": .emptyObject]), execute: { _, _, _, _ in execute() })
}
private actor ExtensionMcpTransport: McpTransport {
    var events: McpTransportEvents?
    var calls = 0
    var closes = 0
    var toolNames = ["echo"]
    var failList = false
    var holdCalls = false
    var cancelled = false
    var hasResources = false
    var reportsProgress = false
    func start(events: McpTransportEvents) { self.events = events }
    func send(_ message: JsonObject, signal: AbortSignal?) async throws {
        try signal?.throwIfAborted()
        let method = message["method"]?.stringValue
        if method == "notifications/cancelled" { cancelled = true }
        guard let id = message["id"] else { return }
        let result: JsonValue
        switch method {
        case "initialize": result = .object(["protocolVersion": .string(LATEST_PROTOCOL_VERSION), "capabilities": .object(hasResources ? ["tools": .object(["listChanged": .bool(true)]), "resources": .emptyObject] : ["tools": .object(["listChanged": .bool(true)])]), "serverInfo": .object(["name": .string("fixture"), "version": .string("1")])])
        case "tools/list":
            if failList {
                await events?.onMessage(["jsonrpc": .string("2.0"), "id": id, "error": .object(["code": .number(-32603), "message": .string("fixture failure")])]); return
            }
            result = .object(["tools": .array(toolNames.map { .object(["name": .string($0), "inputSchema": .object(["type": .string("object")])]) })])
        case "resources/list":
            result = .object(["resources": .array([
                .object(["uri": .string("fixture://note"), "name": .string("Note"), "_meta": .string("private"), "icons": .array([])]),
                .object(["uri": .string("ui://app"), "name": .string("UI")])])])
        case "resources/templates/list": result = .object(["resourceTemplates": .array([.object(["uriTemplate": .string("fixture://{id}"), "name": .string("Item")])])])
        case "resources/read": result = .object(["contents": .array([.object(["uri": .string("fixture://note"), "text": .string("resource text"), "_meta": .string("private")])])])
        case "tools/call":
            calls += 1
            if holdCalls { return }
            if reportsProgress, let token = message["params"]?["_meta"]?["progressToken"] {
                await events?.onMessage(["jsonrpc": "2.0", "method": "notifications/progress", "params": .object([
                    "progressToken": token, "progress": 2, "total": 5, "message": "Processed 2 rows", "private": "not public"
                ])])
            }
            result = .object(["content": .array([.object(["type": .string("text"), "text": .string("mcp answer")])]), "structuredContent": .number(42), "_meta": .object(["private": .bool(true)])])
        default: result = .emptyObject
        }
        await events?.onMessage(["jsonrpc": .string("2.0"), "id": id, "result": result])
    }
    func close() async { guard closes == 0 else { return }; closes += 1; await events?.onClose() }
    func changeTools(_ names: [String], fail: Bool = false) async {
        toolNames = names; failList = fail
        await events?.onMessage(["jsonrpc": .string("2.0"), "method": .string("notifications/tools/list_changed")])
    }
    func hold() { holdCalls = true }
    func enableResources() { hasResources = true }
    func enableProgress() { reportsProgress = true }
}
private func eventually(_ predicate: () async -> Bool) async throws {
    let end = ContinuousClock.now.advanced(by: .seconds(3))
    while !(await predicate()) {
        if ContinuousClock.now > end { throw PiError("Timed out waiting for fixture") }
        try await Task.sleep(for: .milliseconds(5))
    }
}

@Suite("Pi native extensions and MCP sessions") struct PiExtensionMcpTests {
    @Test func numericProgressReachesToolUpdatesWithoutPrivateMetadata() async throws {
        let fixture = try ExtensionFixture(); defer { fixture.cleanup() }
        try fixture.config(#"{"mcpServers":{"sample":{"command":"unused","exposure":"direct"}}}"#)
        let transport = ExtensionMcpTransport(); await transport.enableProgress()
        let created = try await fixture.session(mcp: .init(transportFactory: { _, _, _ in transport }), options: testAgentOptions(call: "mcp__sample__echo"))
        let updates = Locked<[AgentToolResult]>([])
        let unsubscribe = created.session.subscribe { event in
            if case .toolExecutionUpdate(_, _, _, let value) = event { updates.withLock { $0.append(value) } }
        }
        try await created.session.prompt("test progress")
        unsubscribe(); await created.session.shutdown()
        let value = try #require(updates.withLock { $0.first })
        #expect(value.details?["progress"] == 2)
        #expect(value.details?["total"] == 5)
        #expect(value.details?["private"] == nil)
        #expect(value.details?["progressToken"] == nil)
    }
    @Test func slowStartupContinuesInBackgroundAndPublishesTools() async throws {
        let fixture = try ExtensionFixture(); defer { fixture.cleanup() }
        try fixture.config(#"{"mcpServers":{"slow":{"command":"unused","exposure":"direct"},"fast":{"command":"unused","exposure":"direct"}}}"#)
        let gate = AsyncStream<Void>.makeStream(), slow = ExtensionMcpTransport(), fast = ExtensionMcpTransport()
        let created = try await fixture.session(mcp: .init(startupWaitMs: 20, transportFactory: { entry, _, _ in
            if entry.name == "slow" { for await _ in gate.stream { break }; return slow }
            return fast
        }))
        let runtime = try #require(created.mcp)
        #expect(await runtime.statuses().first { $0.name == "slow" }?.state == .connecting)
        try await eventually { await created.session.state.tools.contains { $0.name == "mcp__fast__echo" } }
        gate.continuation.yield(())
        try await eventually { await created.session.state.tools.contains { $0.name == "mcp__slow__echo" } }
        await created.session.shutdown()
        #expect(await slow.closes == 1); #expect(await fast.closes == 1)
    }
    @Test func disabledBackgroundConnectionCannotPublishLateTools() async throws {
        let fixture = try ExtensionFixture(); defer { fixture.cleanup() }
        try fixture.config(#"{"mcpServers":{"slow":{"command":"unused","exposure":"direct"}}}"#)
        let gate = Locked<CheckedContinuation<Void, Never>?>(nil), transport = ExtensionMcpTransport()
        let created = try await fixture.session(mcp: .init(startupWaitMs: 20, transportFactory: { _, _, _ in
            await withCheckedContinuation { continuation in gate.withLock { $0 = continuation } }
            return transport
        }))
        let runtime = try #require(created.mcp)
        try await eventually { gate.withLock { $0 != nil } }
        try await runtime.setEnabled("slow", false)
        gate.withLock { $0?.resume(); $0 = nil }
        try await eventually { await transport.closes == 1 }
        #expect(await runtime.statuses().first?.state == .disabled)
        #expect(await created.session.state.tools.filter { isMcpToolName($0.name) }.isEmpty)
        await created.session.shutdown()
    }
    @Test func droppedConnectionReconnectsOnceOnNextPrompt() async throws {
        let fixture = try ExtensionFixture(); defer { fixture.cleanup() }
        try fixture.config(#"{"mcpServers":{"sample":{"command":"unused","exposure":"direct"}}}"#)
        let first = ExtensionMcpTransport(), second = ExtensionMcpTransport(), attempts = Locked(0)
        let created = try await fixture.session(mcp: .init(transportFactory: { _, _, _ in
            attempts.withLock { $0 += 1; return $0 } == 1 ? first : second
        }), options: testAgentOptions(call: "mcp__sample__echo"))
        let runtime = try #require(created.mcp)
        await first.close()
        try await eventually { await runtime.statuses().first?.state == .disconnected }
        #expect(attempts.withLock { $0 } == 1)
        try await created.session.prompt("use the reconnected tool")
        #expect(attempts.withLock { $0 } == 2)
        #expect(await first.calls == 0); #expect(await second.calls == 1)
        await created.session.shutdown()
    }
    @Test func backgroundConnectionDeadlineIncludesTransportCreation() async throws {
        let fixture = try ExtensionFixture(); defer { fixture.cleanup() }
        try fixture.config(#"{"mcpServers":{"slow":{"command":"unused"}}}"#)
        let cancelled = Locked(false)
        let created = try await fixture.session(mcp: .init(connectTimeoutMs: 50, startupWaitMs: 10, transportFactory: { _, _, signal in
            do { try await sleep(5_000, signal) }
            catch { cancelled.withLock { $0 = true }; throw error }
            return ExtensionMcpTransport()
        }))
        let runtime = try #require(created.mcp)
        try await eventually { await runtime.statuses().first?.state == .failed }
        #expect(cancelled.withLock { $0 })
        #expect(await runtime.statuses().first?.diagnostic == "MCP connection timed out")
        await created.session.shutdown()
    }
    @Test func lifecycleHooksAreOrderedAndShutdownOnce() async throws {
        let fixture = try ExtensionFixture(); defer { fixture.cleanup() }
        let events = Locked<[String]>([]), executions = Locked(0)
        let ext = NativeExtension(id: "test", tools: [testTool("echo") { executions.withLock { $0 += 1 }; return .init(content: [.text(.init(text: "original"))], structuredContent: .string("private")) }],
            onEvent: { event, _ in events.withLock { $0.append(event.type) } },
            onToolCall: { _, _ in events.withLock { $0.append("tool_call") }; return nil },
            onToolResult: { _, _ in events.withLock { $0.append("tool_result") }; return .init(content: [.text(.init(text: "redacted"))]) })
        var options = testAgentOptions(call: "echo")
        options.beforeToolCall = { _, _ in events.withLock { $0.append("host_before") }; return nil }
        options.afterToolCall = { _, _ in events.withLock { $0.append("host_after") }; return nil }
        let created = try await fixture.session(extensions: [ext], options: options)
        let finalResult = Locked<AgentToolResult?>(nil)
        let unsubscribe = created.session.subscribe { event in
            if event.type == "agent_start" { events.withLock { $0.append("public_start") } }
            if case .toolExecutionEnd(_, _, let result, _, _) = event { finalResult.withLock { $0 = result } }
        }
        try await created.session.prompt("test")
        unsubscribe()
        await created.session.shutdown(); await created.session.shutdown()
        let log = events.withLock { $0 }
        #expect(log.first == "session_start")
        #expect(log.filter { $0 == "session_shutdown" }.count == 1)
        #expect(log.firstIndex(of: "host_before")! < log.firstIndex(of: "tool_call")!)
        #expect(log.firstIndex(of: "host_after")! < log.firstIndex(of: "tool_result")!)
        #expect(log.firstIndex(of: "agent_start")! < log.firstIndex(of: "public_start")!)
        #expect(executions.withLock { $0 } == 1)
        let result = try #require(created.session.sessionManager.buildSessionContext().messages.compactMap { if case .toolResult(let value) = $0 { value } else { nil } }.first)
        #expect(result.content == [.text(.init(text: "redacted"))])
        #expect(finalResult.withLock { $0?.structuredContent } == nil)
        await #expect(throws: PiError.self) { try await created.session.prompt("closed") }
    }
    @Test func permissionFailureBlocksToolAndHostVetoWins() async throws {
        let fixture = try ExtensionFixture(); defer { fixture.cleanup() }
        for hostVeto in [false, true] {
            let count = Locked(0), extensionCalls = Locked(0)
            var options = testAgentOptions(call: "echo", tools: [testTool("echo") { count.withLock { $0 += 1 }; return .init(content: []) }])
            if hostVeto { options.beforeToolCall = { _, _ in .init(block: true, reason: "host denied") } }
            let ext = NativeExtension(id: "guard", onToolCall: { _, _ in extensionCalls.withLock { $0 += 1 }; throw PiError("permission service unavailable") })
            let created = try await fixture.session(extensions: [ext], options: options)
            try await created.session.prompt("test")
            #expect(count.withLock { $0 } == 0)
            #expect(extensionCalls.withLock { $0 } == (hostVeto ? 0 : 1))
            #expect(created.session.extensionRunner?.drainErrors().count == (hostVeto ? 0 : 1))
            await created.session.shutdown()
        }
    }
    @Test func replacedToolsAndContextsAreRevoked() async throws {
        let fixture = try ExtensionFixture(); defer { fixture.cleanup() }
        let captured = Locked<ExtensionContext?>(nil)
        let ext = NativeExtension(id: "dynamic", tools: [testTool("old")], onEvent: { event, context in
            if case .sessionStart = event { captured.withLock { $0 = context } }
        })
        let created = try await fixture.session(extensions: [ext])
        let old = try #require(await created.session.state.tools.first)
        let context = try #require(captured.withLock { $0 })
        try await context.replaceTools([testTool("new")])
        await #expect(throws: AbortError.self) { try await old.execute("stale", .emptyObject, nil, nil) }
        #expect(await created.session.state.tools.map(\.name) == ["new"])
        #expect(getCurrentTools(convertToLlm(created.session.sessionManager.buildSessionContext().messages)).map(\.name) == ["new"])
        await created.session.shutdown()
        await #expect(throws: PiError.self) { try await context.replaceTools([testTool("resurrect")]) }
    }
    @Test func duplicateToolsCannotOverrideHostAndBadResultHandlerDoesNotStopOthers() async throws {
        let fixture = try ExtensionFixture(); defer { fixture.cleanup() }
        let observed = Locked(false)
        let first = NativeExtension(id: "collision", tools: [testTool("echo")], onToolResult: { _, _ in throw PiError("bad result handler") })
        let second = NativeExtension(id: "second", onToolResult: { _, _ in observed.withLock { $0 = true }; return nil })
        let created = try await fixture.session(extensions: [first, second], options: testAgentOptions(call: "echo", tools: [testTool("echo")]))
        try await created.session.prompt("test")
        #expect(observed.withLock { $0 })
        #expect(created.session.extensionRunner?.drainErrors().map(\.event) == ["session_start", "tool_result"])
        await created.session.shutdown()
    }
    @Test func revokedToolCannotReturnLateSuccess() async throws {
        let fixture = try ExtensionFixture(); defer { fixture.cleanup() }
        let captured = Locked<ExtensionContext?>(nil), gate = Locked<CheckedContinuation<Void, Never>?>(nil)
        var tool = testTool("slow")
        tool.execute = { _, _, _, _ in
            await withCheckedContinuation { continuation in gate.withLock { $0 = continuation } }
            return .init(content: [.text(.init(text: "late success"))])
        }
        let created = try await fixture.session(extensions: [.init(id: "slow", tools: [tool], onEvent: { event, context in
            if case .sessionStart = event { captured.withLock { $0 = context } }
        })])
        let handle = try #require(await created.session.state.tools.first)
        let call = Task { try await handle.execute("slow", .emptyObject, nil, nil) }
        try await eventually { gate.withLock { $0 != nil } }
        let context = try #require(captured.withLock { $0 })
        try await context.replaceTools([])
        gate.withLock { $0?.resume(); $0 = nil }
        await #expect(throws: AbortError.self) { try await call.value }
        await created.session.shutdown()
    }
    @Test func mcpDirectToolReachesModelAndPermissionPipeline() async throws {
        let fixture = try ExtensionFixture(); defer { fixture.cleanup() }
        try fixture.config(#"{"mcpServers":{"sample":{"command":"unused","exposure":"direct"}}}"#)
        let transport = ExtensionMcpTransport(), declarations = Locked<[String]>([]), hooks = Locked(0)
        let ext = NativeExtension(id: "audit", onToolCall: { event, _ in
            #expect(event.toolCall.name == "mcp__sample__echo"); hooks.withLock { $0 += 1 }; return nil
        })
        let created = try await fixture.session(extensions: [ext], mcp: .init(transportFactory: { _, _, _ in transport }),
            options: testAgentOptions(call: "mcp__sample__echo", observe: { tools in declarations.withLock { $0 = tools.map(\.name) } }))
        let finalResult = Locked<AgentToolResult?>(nil)
        let unsubscribe = created.session.subscribe { event in
            if case .toolExecutionEnd(_, _, let result, _, _) = event { finalResult.withLock { $0 = result } }
        }
        try await created.session.prompt("test")
        unsubscribe()
        #expect(await transport.calls == 1); #expect(hooks.withLock { $0 } == 1)
        #expect(declarations.withLock { $0.filter(isMcpToolName) } == ["mcp__sample__echo"])
        let result = try #require(finalResult.withLock { $0 })
        #expect(result.structuredContent?["structuredContent"] == .number(42))
        #expect(result.structuredContent?["_meta"] == nil)
        await created.session.shutdown()
        #expect(await transport.closes == 1)
    }
    @Test func mcpVetoNeverReachesServer() async throws {
        let fixture = try ExtensionFixture(); defer { fixture.cleanup() }
        try fixture.config(#"{"mcpServers":{"sample":{"command":"unused","exposure":"direct"}}}"#)
        let transport = ExtensionMcpTransport()
        let created = try await fixture.session(extensions: [.init(id: "deny", onToolCall: { _, _ in .init(block: true, reason: "denied") })],
            mcp: .init(transportFactory: { _, _, _ in transport }), options: testAgentOptions(call: "mcp__sample__echo"))
        try await created.session.prompt("test")
        #expect(await transport.calls == 0)
        await created.session.shutdown()
    }
    @Test func defaultExposureTrustAndDisabledServersDoNotBecomeDirect() async throws {
        let fixture = try ExtensionFixture(); defer { fixture.cleanup() }
        try fixture.config(#"{"mcpServers":{"default":{"command":"unused"},"off":{"command":"unused","enabled":false,"exposure":"direct"}}}"#)
        try fixture.config(#"{"mcpServers":{"project":{"command":"unused","exposure":"direct"}}}"#, project: true)
        let names = Locked<[String]>([])
        let created = try await fixture.session(mcp: .init(transportFactory: { entry, _, _ in names.withLock { $0.append(entry.name) }; return ExtensionMcpTransport() }))
        #expect(names.withLock { $0 } == ["default"])
        #expect(await created.session.state.tools.filter { isMcpToolName($0.name) }.isEmpty)
        let runtime = try #require(created.mcp)
        #expect(await runtime.statuses().first?.diagnostic == nil)
        await created.session.shutdown()
    }
    @Test func catalogNotificationReplacesToolsAndFailureWithdrawsStaleHandles() async throws {
        let fixture = try ExtensionFixture(); defer { fixture.cleanup() }
        try fixture.config(#"{"mcpServers":{"sample":{"command":"unused","exposure":"direct"}}}"#)
        let transport = ExtensionMcpTransport()
        let created = try await fixture.session(mcp: .init(transportFactory: { _, _, _ in transport }))
        let old = try #require(await created.session.state.tools.first { isMcpToolName($0.name) })
        await transport.changeTools(["next"])
        #expect(await created.session.state.tools.map(\.name).filter(isMcpToolName) == ["mcp__sample__next"])
        await #expect(throws: AbortError.self) { try await old.execute("stale", .emptyObject, nil, nil) }
        await transport.changeTools([], fail: true)
        #expect(await created.session.state.tools.filter { isMcpToolName($0.name) }.isEmpty)
        #expect(getCurrentTools(convertToLlm(created.session.sessionManager.buildSessionContext().messages)).filter { isMcpToolName($0.name) }.isEmpty)
        await created.session.shutdown()
    }
    @Test func disableCancelsInFlightCallAndWithdrawsDeclarations() async throws {
        let fixture = try ExtensionFixture(); defer { fixture.cleanup() }
        try fixture.config(#"{"mcpServers":{"sample":{"command":"unused","exposure":"direct"}}}"#)
        let transport = ExtensionMcpTransport()
        let created = try await fixture.session(mcp: .init(transportFactory: { _, _, _ in transport }), options: testAgentOptions(call: "mcp__sample__echo"))
        let runtime = try #require(created.mcp)
        await transport.hold()
        let run = Task { try await created.session.prompt("test") }
        try await eventually { await transport.calls == 1 }
        try await runtime.setEnabled("sample", false)
        try await run.value
        #expect(await transport.closes == 1)
        #expect(await created.session.state.tools.filter { isMcpToolName($0.name) }.isEmpty)
        #expect(await runtime.statuses().first?.state == .disabled)
        await created.session.shutdown()
    }
    @Test func resumeRemovesPreviouslyDeclaredExtensionTools() async throws {
        let fixture = try ExtensionFixture(); defer { fixture.cleanup() }
        let created = try await fixture.session(extensions: [.init(id: "old", tools: [testTool("old")])])
        let manager = created.session.sessionManager
        await created.session.shutdown()
        let resumed = try await fixture.session(manager: manager)
        #expect(await resumed.session.state.tools.isEmpty)
        #expect(getCurrentTools(convertToLlm(manager.buildSessionContext().messages)).isEmpty)
        await resumed.session.shutdown()
    }
    @Test func oneServerRefreshDoesNotRevokeOtherServerTools() async throws {
        let fixture = try ExtensionFixture(); defer { fixture.cleanup() }
        try fixture.config(#"{"mcpServers":{"one":{"command":"unused","exposure":"direct"},"two":{"command":"unused","exposure":"direct"}}}"#)
        let one = ExtensionMcpTransport(), two = ExtensionMcpTransport()
        let created = try await fixture.session(mcp: .init(transportFactory: { entry, _, _ in entry.name == "one" ? one : two }))
        let stable = try #require(await created.session.state.tools.first { $0.name == "mcp__one__echo" })
        await two.changeTools(["changed"])
        let result = try await stable.execute("stable", .emptyObject, nil, nil)
        #expect(result.structuredContent?["structuredContent"] == .number(42))
        await two.close()
        let runtime = try #require(created.mcp)
        try await eventually { await runtime.statuses().last?.state == .disconnected }
        #expect(await created.session.state.tools.map(\.name).filter(isMcpToolName) == ["mcp__one__echo"])
        await created.session.shutdown()
    }
    @Test func mcpRuntimeIsReleasedAfterShutdown() async throws {
        let fixture = try ExtensionFixture(); defer { fixture.cleanup() }
        weak var reference: McpExtensionRuntime?
        do {
            let created = try await fixture.session(mcp: .init())
            reference = created.mcp
            await created.session.shutdown()
        }
        #expect(reference == nil)
    }
    #if os(macOS)
    @Test func realStdioConfigRunsThroughSessionAndStops() async throws {
        let fixture = try ExtensionFixture(); defer { fixture.cleanup() }
        let program = #"""
        import json, os, sys
        for line in sys.stdin:
            m=json.loads(line)
            if 'id' not in m: continue
            result={}
            if m.get('method')=='initialize': result={'protocolVersion':'2025-11-25','capabilities':{'tools':{}},'serverInfo':{'name':'fixture','version':'1'}}
            if m.get('method')=='tools/list': result={'tools':[{'name':'echo','inputSchema':{'type':'object'}}]}
            if m.get('method')=='tools/call': result={'content':[{'type':'text','text':os.getcwd()}]}
            print(json.dumps({'jsonrpc':'2.0','id':m['id'],'result':result}), flush=True)
        """#
        let config = JsonValue.object(["mcpServers": .object(["real": .object([
            "command": .string("/usr/bin/python3"), "args": .array([.string("-u"), .string("-c"), .string(program)]), "exposure": .string("direct")])])])
        try fixture.config(config.serialized())
        let created = try await fixture.session(mcp: .init(), options: testAgentOptions(call: "mcp__real__echo"))
        try await created.session.prompt("test")
        let result = try #require(created.session.sessionManager.buildSessionContext().messages.compactMap { if case .toolResult(let value) = $0 { value } else { nil } }.first)
        #expect(!result.isError)
        if case .text(let text) = result.content.first {
            #expect(URL(fileURLWithPath: text.text).resolvingSymlinksInPath().path == URL(fileURLWithPath: fixture.cwd).resolvingSymlinksInPath().path)
        } else { Issue.record("Expected real MCP text response") }
        await created.session.shutdown()
        #expect(await created.mcp?.statuses().first?.state == .closed)
    }
    #endif
    @Test func resourceToolsFilterAppsAndPreserveStructuredPayload() async throws {
        let fixture = try ExtensionFixture(); defer { fixture.cleanup() }
        try fixture.config(#"{"mcpServers":{"sample":{"command":"unused","exposure":"direct"}}}"#)
        let transport = ExtensionMcpTransport(); await transport.enableResources()
        let created = try await fixture.session(mcp: .init(transportFactory: { _, _, _ in transport }))
        let tools = await created.session.state.tools
        let list = try #require(tools.first { $0.name == LIST_MCP_RESOURCES_TOOL })
        let result = try await list.execute("list", .emptyObject, nil, nil)
        let resources = try #require(result.structuredContent?["resources"]?.arrayValue)
        #expect(resources.count == 1); #expect(resources[0]["server"] == .string("sample"))
        #expect(resources[0]["_meta"] == nil); #expect(resources[0]["icons"] == nil)
        let read = try #require(tools.first { $0.name == READ_MCP_RESOURCE_TOOL })
        let contents = try await read.execute("read", .object(["server": .string("sample"), "uri": .string("fixture://note")]), nil, nil)
        #expect(contents.content == [.text(.init(text: "resource text"))])
        #expect(contents.structuredContent?["contents"]?.arrayValue?.first?["_meta"] == nil)
        await created.session.shutdown()
        await #expect(throws: AbortError.self) { try await read.execute("stale", .emptyObject, nil, nil) }
    }
    @Test func commandsInputContextAndSessionBoundaries() async throws {
        let fixture = try ExtensionFixture(); defer { fixture.cleanup() }
        let commands = Locked<[String]>([]), changes = Locked(false), events = Locked<[String]>([])
        let ext = NativeExtension(id: "lifecycle", onEvent: { event, _ in events.withLock { $0.append(event.type) } },
            commands: [.init(name: "hello", description: "Hello", execute: { args, _ in commands.withLock { $0.append(args) } })],
            onInput: { text, images, _ in .transform("changed " + text, images: images) },
            onContext: { messages, _ in messages + [.system(.init(content: "projection only"))] },
            onBeforeSessionChange: { _, _ in changes.withLock { $0 } })
        let created = try await fixture.session(extensions: [ext])
        try await created.session.prompt("/hello there")
        #expect(commands.withLock { $0 } == ["there"])
        try await created.session.prompt("question")
        let messages = created.session.sessionManager.buildSessionContext().messages
        #expect(messages.contains { $0.role == "user" && agentMessageToJson($0).serialized().contains("changed question") })
        #expect(!messages.contains { agentMessageToJson($0)["content"] == .string("projection only") })
        #expect(try await created.session.newSession() == false)
        changes.withLock { $0 = true }
        #expect(try await created.session.newSession())
        #expect(events.withLock { $0 }.contains("session_switch"))
        #expect(events.withLock { $0 }.contains("resources_reload"))
        await created.session.shutdown()
    }
    @Test func staleConfigurationEditorCannotOverwriteExternalChanges() throws {
        let fixture = try ExtensionFixture(); defer { fixture.cleanup() }
        try fixture.config(#"{"extra":42,"mcpServers":{"sample":{"command":"original"}}}"#)
        let original: JsonValue = .object(["command": .string("original")])
        let changed: JsonValue = .object(["command": .string("changed")])
        let path = fixture.agentDir + "/mcp.json"
        try saveMcpServerConfig(path: path, name: "sample", config: changed, expected: original)
        #expect(throws: PiError.self) { try saveMcpServerConfig(path: path, name: "sample", config: original, expected: original) }
        #expect(throws: PiError.self) { try saveMcpServerConfig(path: path, name: "sample", config: original, expected: .null) }
        let persisted = try JsonValue.parse(String(contentsOfFile: path, encoding: .utf8))
        #expect(persisted["mcpServers"]?["sample"] == changed)
        #expect(persisted["extra"] == .number(42))
    }
    @Test func queuedInputsPassThroughExtensionHooks() async throws {
        let fixture = try ExtensionFixture(); defer { fixture.cleanup() }
        let commands = Locked(0)
        let ext = NativeExtension(id: "queue-hooks", commands: [.init(name: "local", description: "Local", execute: { _, _ in commands.withLock { $0 += 1 } })],
            onInput: { text, images, _ in text == "handled" ? .handled : .transform("changed " + text, images: images) })
        let created = try await fixture.session(extensions: [ext])
        #expect(try await created.session.steer("/local") == .handled)
        #expect(try await created.session.followUp("handled") == .handled)
        #expect(try await created.session.steer("first") == .queued)
        #expect(try await created.session.followUp("second") == .queued)
        let queued = created.session.clearQueue()
        #expect(queued.steering == ["changed first"])
        #expect(queued.followUp == ["changed second"])
        #expect(commands.withLock { $0 } == 1)
        await created.session.shutdown()
        await #expect(throws: PiError.self) { try await created.session.steer("closed") }
    }
    @Test func sessionTransitionReservesIdleBoundaryWhileHooksAwait() async throws {
        let fixture = try ExtensionFixture(); defer { fixture.cleanup() }
        let entered = AsyncStream<Void>.makeStream(), resume = AsyncStream<Void>.makeStream()
        let ext = NativeExtension(id: "transition", onBeforeSessionChange: { _, _ in
            entered.continuation.yield(())
            for await _ in resume.stream { break }
            return true
        })
        let created = try await fixture.session(extensions: [ext])
        let transition = Task { try await created.session.newSession() }
        for await _ in entered.stream { break }
        #expect(!created.session.isIdle)
        await #expect(throws: PiError.self) { try await created.session.prompt("racing prompt") }
        await #expect(throws: PiError.self) { try await created.session.reloadResources() }
        resume.continuation.yield(())
        #expect(try await transition.value)
        #expect(created.session.isIdle)
        try await created.session.prompt("after transition")
        await created.session.shutdown()
    }
    #if os(macOS)
    @Test func commandValuesAreBoundedCachedAndCancellable() async throws {
        let fixture = try ExtensionFixture(); defer { fixture.cleanup() }
        let resolver = McpConfigValueResolver()
        #expect(try await resolver.resolve("!printf secret", cwd: fixture.cwd, signal: nil) == "secret")
        #expect(try await resolver.resolve("!printf secret", cwd: fixture.cwd, signal: nil) == "secret")
        await #expect(throws: PiError.self) { try await resolver.resolve("!exit 4", cwd: fixture.cwd, signal: nil) }
        await #expect(throws: PiError.self) { try await resolver.resolve("!/usr/bin/yes x", cwd: fixture.cwd, signal: nil) }
        let cancel = AbortController(); cancel.abort()
        await #expect(throws: AbortError.self) { try await resolver.resolve("!sleep 20", cwd: fixture.cwd, signal: cancel.signal) }
    }
    #endif
    @Test func deferredSearchLoadsToolsAndSurvivesResume() async throws {
        let fixture = try ExtensionFixture(); defer { fixture.cleanup() }
        let ext = NativeExtension(id: "deferred", onEvent: { event, context in
            if case .sessionStart = event { try await context.registerTools([ExtensionTool(testTool("find_book"), exposure: .deferred)]) }
        })
        let created = try await fixture.session(extensions: [ext, createToolSearchExtension()])
        #expect(await created.session.state.tools.map(\.name) == ["tool_search"])
        let search = try #require(await created.session.state.tools.first)
        _ = try await search.execute("search", .object(["query": .string("find books")]), nil, nil)
        #expect(await created.session.state.tools.map(\.name).contains("find_book"))
        let manager = created.session.sessionManager
        await created.session.shutdown()
        let resumed = try await fixture.session(extensions: [ext], manager: manager)
        #expect(await resumed.session.state.tools.map(\.name) == ["find_book"])
        await resumed.session.shutdown()
    }
    @Test func nestedCallsUsePermissionsAndPersistParentRecords() async throws {
        let fixture = try ExtensionFixture(); defer { fixture.cleanup() }
        let observed = Locked<[String]>([]), calls = Locked(0)
        let ext = NativeExtension(id: "nested", onEvent: { event, context in
            guard case .sessionStart = event else { return }
            var parent = testTool("parent")
            parent.execute = { id, _, signal, _ in
                let denied = try await context.executeTool(id, "child", [:], signal)
                #expect(denied.isError)
                return .init(content: [.text(.init(text: "finished"))])
            }
            try await context.registerTools([ExtensionTool(parent), ExtensionTool(testTool("child") {
                calls.withLock { $0 += 1 }; return .init(content: [])
            }, exposure: .codemode)])
        })
        var options = testAgentOptions(call: "parent")
        options.beforeToolCall = { event, _ in
            observed.withLock { $0.append(event.parentToolCallId ?? "root") }
            return event.parentToolCallId == nil ? nil : .init(block: true, reason: "permission denied")
        }
        let created = try await fixture.session(extensions: [ext], options: options)
        try await created.session.prompt("run")
        #expect(observed.withLock { $0 } == ["root", "call-1"])
        #expect(calls.withLock { $0 } == 0)
        let result = try #require(created.session.sessionManager.buildSessionContext().messages.compactMap { if case .toolResult(let result) = $0 { result } else { nil } }.first)
        #expect(result.nestedCalls?.calls.first?.id == "call-1/1")
        #expect(result.nestedCalls?.calls.first?.status == "error")
        await created.session.shutdown()
    }
    #if os(macOS)
    @Test(.enabled(if: ProcessInfo.processInfo.environment["PI_CODEMODE_HELPER"] != nil))
    func realCodemodeSandboxRunsNestedToolsAndTimesOut() async throws {
        let fixture = try ExtensionFixture(); defer { fixture.cleanup() }
        let path = try #require(ProcessInfo.processInfo.environment["PI_CODEMODE_HELPER"])
        let parentIDs = Locked<[String]>([])
        var options = testAgentOptions()
        options.initialState?.messages = [.assistant(.init(content: [.toolCall(.init(id: "code", name: "codemode"))], api: "test", provider: "test", model: "test", stopReason: .toolUse))]
        options.beforeToolCall = { event, _ in parentIDs.withLock { $0.append(event.parentToolCallId ?? "root") }; return nil }
        let created = try await fixture.session(extensions: [.init(id: "tools", tools: [testTool("echo")]),
            createCodemodeExtension(.init(helperPath: path, timeoutMs: 3000))], options: options)
        let code = try #require(await created.session.state.tools.first { $0.name == "codemode" })
        let result = try await code.execute("code", .object(["code": .string("const value = await tools.echo({}); store('value',value); text(value); text(typeof fetch); text(typeof tools.codemode);")]), nil, nil)
        #expect(result.content.contains(.text(.init(text: "original"))))
        #expect(result.content.filter { $0 == .text(.init(text: "undefined")) }.count == 2)
        #expect(parentIDs.withLock { $0 } == ["code"])
        let stored = try await code.execute("next", .object(["code": .string("text(load('value'))")]), nil, nil)
        #expect(stored.content == [.text(.init(text: "original"))])
        await #expect(throws: (any Error).self) {
            _ = try await code.execute("timeout", .object(["code": .string("// @options: {\"timeout_ms\":100}\nwhile(true) {}")]), nil, nil)
        }
        let recovery = try await code.execute("recovery", .object(["code": .string("text('recovered')")]), nil, nil)
        #expect(recovery.content == [.text(.init(text: "recovered"))])
        await created.session.shutdown()
    }
    #endif
    @Test func mcpNamesSchemasTruncationAndInterpolation() throws {
        let first = createMcpToolName(server: "server", tool: "a-b")
        #expect(first == "mcp__server__a_b")
        #expect(createMcpToolName(server: "server", tool: "a_b", isTaken: { $0 == first }) != first)
        #expect(createMcpToolName(server: "server", tool: String(repeating: "x", count: 90)).count == 64)
        let schema = createMcpResultSchema(.object(["$ref": .string("#/$defs/Item"), "default": .object(["$ref": .string("#")])]))
        #expect(schema["properties"]?["structuredContent"]?["$ref"] == .string("#/properties/structuredContent/$defs/Item"))
        #expect(schema["properties"]?["structuredContent"]?["default"]?["$ref"] == .string("#"))
        let saved = Locked(Data())
        let text = String(repeating: "中", count: 20_000)
        let result = convertMcpResult(server: "s", tool: "t", result: ["content": .array([.object(["type": .string("text"), "text": .string(text)])]), "_meta": .string("secret")], saveOutput: { data, _ in saved.withLock { $0 = data }; return "/tmp/fixture.txt" })
        #expect(saved.withLock { $0 } == Data(text.utf8))
        #expect(result.structuredContent?["content"]?.arrayValue?.first?["text"] == .string(text))
        #expect(result.structuredContent?["_meta"] == nil)
        if case .text(let block) = result.content.first { #expect(block.text.utf8.count <= MCP_OUTPUT_MAX_BYTES) }
        #expect(try resolveMcpConfigValue("Bearer ${TOKEN} $$ $! $TOKEN", environment: ["TOKEN": "abc"]) == "Bearer abc $ ! abc")
        #expect(throws: PiError.self) { try resolveMcpConfigValue("$MISSING", environment: [:]) }
        #expect(throws: PiError.self) { try resolveMcpConfigValue("!echo should-not-run", environment: [:]) }
    }
}
