// Native process adapter for packages/codemode and extensions/codemode at 42cb822f1c5d3153069dd0661bfd297424666cf1.
// JavaScriptCore runs in a separately signed App Sandbox helper. Only JSON tool calls cross back
// into the session; the helper has no filesystem/network entitlements or general native bridge.
import Foundation
import PiAI
import PiAgent
import PiMCP

public struct CodemodeOptions: Sendable {
    public var helperPath: String
    public var timeoutMs: Int
    public init(helperPath: String = Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/PiCodeModeRunner.app/Contents/MacOS/PiCodeModeRunner").path,
                timeoutMs: Int = 60_000) {
        self.helperPath = helperPath; self.timeoutMs = min(120_000, max(100, timeoutMs))
    }
}
private actor CodemodeRuntime {
    let options: CodemodeOptions
    var storage = JsonObject()
    var client: McpClient?
    var closed = false
    init(_ options: CodemodeOptions) { self.options = options }
    func close() async { closed = true; storage = [:]; await client?.close(); client = nil }
    func execute(_ code: String, parent: String, signal: AbortSignal?, context: ExtensionContext) async throws -> AgentToolResult {
        guard !closed, client == nil else { throw PiError("Codemode is closed or already executing") }
        guard code.utf8.count <= 1024 * 1024 else { throw PiError("Codemode source exceeds 1 MiB") }
        #if os(macOS)
        guard FileManager.default.isExecutableFile(atPath: options.helperPath) else { throw PiError("Codemode sandbox helper is unavailable") }
        var timeout = options.timeoutMs, outputTokens = 10_000
        if let line = code.components(separatedBy: .newlines).first, line.hasPrefix("// @options:") {
            let json = try JsonValue.parse(String(line.dropFirst("// @options:".count)))
            if let value = json["timeout_ms"]?.doubleValue {
                guard value.isFinite, value >= 100, value <= 120_000, value.rounded() == value else { throw PiError("timeout_ms must be an integer between 100 and 120000") }
                timeout = Int(value)
            }
            if let value = json["max_output_tokens"]?.doubleValue {
                guard value.isFinite, value >= 1, value <= 100_000, value.rounded() == value else { throw PiError("max_output_tokens must be an integer between 1 and 100000") }
                outputTokens = Int(value)
            }
        }
        let infos = await context.getTools().filter { $0.exposure != .hidden && $0.exposure != .modelOnly }
        let known = Dictionary(uniqueKeysWithValues: infos.map { ($0.tool.name, $0) })
        let declarations = infos.map { item -> JsonValue in
            var value: JsonObject = ["name": .string(item.tool.name), "description": .string(item.tool.description),
                "inputSchema": item.tool.parameters, "outputSchema": item.tool.outputSchema ?? .object(["type": .string("string")])]
            if let namespace = item.namespace { value["namespace"] = .string(namespace) }
            return .object(value)
        }
        let transport = StdioTransport(options: .init(command: options.helperPath, cwd: FileManager.default.temporaryDirectory.path, inheritEnv: false))
        let connection = McpClient(transport: transport, options: .init(name: "pi-codemode-host", requestTimeoutMs: timeout))
        client = connection
        await connection.setRequestHandler("tools/call", handler: { params, childSignal in
            guard let name = params["name"]?.stringValue, let arguments = params["arguments"]?.objectValue else { throw PiError("Invalid nested call") }
            let combined = combineAbortSignals([signal, childSignal, context.signal]); defer { combined.cleanup() }
            try combined.signal?.throwIfAborted()
            if name == "__pi_search" {
                let query = arguments["query"]?.stringValue ?? "", limit = arguments["limit"]?.doubleValue ?? 8
                guard limit.isFinite, limit > 0, limit <= 1000, limit.rounded() == limit else { throw PiError("Invalid search limit") }
                let current = await context.getTools()
                let matches = rankTools(query: query, tools: current, limit: Int(limit), namespace: arguments["namespace"]?.stringValue)
                return .object(["value": .array(matches.map { .object(["name": .string($0.tool.name), "description": .string($0.tool.description)]) })])
            }
            guard let info = known[name] else { throw PiError("Tool is unavailable to codemode: \(name)") }
            let outcome = try await context.executeTool(parent, name, arguments, combined.signal)
            // A structured tool resolves to its full result even when that object reports an error.
            if info.tool.outputSchema != nil, let structured = outcome.result.structuredContent { return .object(["value": structured]) }
            let text = outcome.result.content.compactMap { if case .text(let value) = $0 { value.text } else { nil } }.joined(separator: "\n")
            if outcome.isError { throw PiError(text.isEmpty ? "Nested tool failed" : text) }
            return .object(["value": .string(text)])
        })
        do {
            try await connection.connect(signal: signal)
            let result = try await connection.request("codemode/run", params: ["code": .string(code), "tools": .array(declarations), "store": .object(storage)], options: .init(signal: signal, timeoutMs: timeout))
            try signal?.throwIfAborted(); try context.signal.throwIfAborted()
            guard !closed, let value = result.objectValue, let saved = value["store"]?.objectValue,
                  JsonValue.object(saved).serialized().utf8.count <= 2 * 1024 * 1024 else { throw PiError("Invalid codemode result") }
            storage = saved
            var converted = convertMcpResult(server: "codemode", tool: "codemode", result: ["content": value["content"] ?? .array([])])
            converted.structuredContent = nil
            let texts = converted.content.compactMap { if case .text(let text) = $0 { text.text } else { nil } }.joined(separator: "\n")
            if texts.utf8.count > outputTokens * 4 {
                let path = try saveMcpOutput(Data(texts.utf8), ".txt")
                converted.content = [.text(.init(text: String(texts.prefix(outputTokens * 2)) + "\n[Output truncated; full output: \(path)]"))]
                    + converted.content.filter { if case .image = $0 { true } else { false } }
            }
            await connection.close(); client = nil
            return converted
        } catch { await connection.close(); client = nil; throw error }
        #else
        throw PiError("Codemode process execution is unavailable on this platform")
        #endif
    }
}

public func createCodemodeExtension(_ options: CodemodeOptions = .init()) -> NativeExtension {
    let runtime = CodemodeRuntime(options)
    return .init(id: "builtin:codemode", onEvent: { event, context in
        switch event {
        case .sessionStart:
            let tool = AgentTool(name: "codemode", label: "codemode", description: """
            Run JavaScript in an isolated sandbox as an async function body. Top-level await and return work.
            No Node, filesystem, network or timers. Call tools with await tools.NAME({...}); all calls pass permission checks.
            text(value), image(dataURL), console.log(...), return and exit() produce output. store(key,value)/load(key) retain JSON across calls.
            ALL_TOOLS, await searchTools(query,{limit,namespace}), await describeTool(name), await describeNamespace(name) discover tools.
            Optional first line: // @options: {"max_output_tokens":10000,"timeout_ms":60000}
            Batch independent calls with Promise.allSettled. Unawaited calls are cancelled when the script ends.
            """, parameters: .object(["type": .string("object"), "properties": .object(["code": .object(["type": .string("string")])]), "required": .array([.string("code")])]),
                executionMode: .sequential, execute: { id, args, signal, _ in
                    guard let code = args["code"]?.stringValue else { throw PiError("code must be a string") }
                    return try await runtime.execute(code, parent: id, signal: signal, context: context)
                })
            try await context.registerTools([ExtensionTool(tool, exposure: .modelOnly)])
        case .sessionShutdown: await runtime.close()
        default: break
        }
    })
}
