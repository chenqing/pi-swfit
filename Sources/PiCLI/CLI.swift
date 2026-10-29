import Foundation
import PiLineEditor
import PiHost
import PiAI
import PiAgent
import PiCodingAgent
#if os(macOS)
import Darwin
import Security
#endif

public enum PFCLI {
    public static let version = "0.1.0"
    public static let help = """
    pf — Pi for Swift · native coding agent

    Usage: pf [options] [prompt ...]
      -p, --print              Print the final response and exit
      --mode text|json         Text output or JSONL session events (not RPC)
      --provider NAME          Model provider (default: openai)
      --model ID               Model ID (or PF_MODEL)
      --thinking LEVEL         off, minimal, low, medium, high, xhigh, max
      --tools LIST             Comma-separated read,bash,edit,write (default: all four)
      --no-tools               Disable local coding tools
      --system-prompt TEXT     Override the default coding prompt
      -c, --continue           Continue the latest session in this working directory
      --session PATH           Open an existing Pi JSONL session
      --session-dir PATH       Override the session storage directory
      --no-session             Keep the session in memory only
      --help, --version

    Swift-specific options:
      --base-url URL           Provider endpoint, including /v1 where required
      --api NAME               openai-completions, openai-responses, anthropic-messages
      --connection NAME       Saved connection name or ID from Pi Swift
      --list-connections      List saved connections (no secrets)
      --agent-dir PATH         Default: ~/.pf/agent (or PF_AGENT_DIR)
      --trust-project          Load the current project's .pi resources/settings
      --demo                   Offline fixture; no key, network or tool execution

    Set the provider's API key environment variable (e.g. OPENAI_API_KEY).
    Without -p, a terminal opens a line-oriented REPL. /help lists commands; /quit exits.
    Piped stdin is prepended to the first prompt. No full TUI, RPC or npm extensions yet.
    Tools can access local files and run commands with your user's permissions.
    Use --no-tools for chat-only use. See Docs/CLI.md for the compatibility matrix.
    """

    public static func run(_ arguments: [String], extensions: [NativeExtension] = []) async -> Int32 {
        do {
            let args = try CLIArguments(arguments)
            if args.help { output(help + "\n"); return 0 }
            if args.version { output("pf \(version)\n"); return 0 }
            #if os(macOS)
            return try await execute(args, extensions: extensions)
            #else
            throw PiError("pf currently requires macOS")
            #endif
        } catch {
            diagnostic("pf: \(error)\n"); return 1
        }
    }

    #if os(macOS)
    private static func execute(_ args: CLIArguments, extensions: [NativeExtension]) async throws -> Int32 {
        let cwd = HostPaths.canonicalWorkspace(FileManager.default.currentDirectoryPath)
        let env = ProcessInfo.processInfo.environment
        // SecItem authentication contexts do not suppress all legacy login-Keychain ACL dialogs.
        // A batch CLI must fail instead of waiting for an invisible system prompt.
        if isatty(STDIN_FILENO) != 1, SecKeychainSetUserInteractionAllowed(false) != errSecSuccess {
            throw PiError("Could not disable interactive Keychain prompts for this batch run")
        }
        let paths = HostPaths(agentDir: args.agentDir)
        let sessionDir = ((args.sessionDir ?? paths.sessionDirectory(cwd: cwd)) as NSString).expandingTildeInPath
        let connections = ConnectionStore(paths: paths, credentials: KeychainCredentialStore(allowInteraction: isatty(STDIN_FILENO) == 1))
        if args.listConnections {
            for profile in try connections.load().profiles { output("\(profile.id)  \(profile.name)  \(profile.modelID)  \(profile.endpoint)\n") }
            return 0
        }
        let stdinIsTerminal = isatty(STDIN_FILENO) == 1
        let interactive = stdinIsTerminal && !args.printMode && args.mode != "json"
        var prompts = args.messages
        if !stdinIsTerminal {
            let data = try FileHandle.standardInput.read(upToCount: 8 * 1024 * 1024 + 1) ?? Data()
            guard data.count <= 8 * 1024 * 1024, let input = String(data: data, encoding: .utf8) else { throw PiError("stdin must be UTF-8 and at most 8 MiB") }
            if !input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                if prompts.isEmpty { prompts = [input] } else { prompts[0] = input + "\n\n" + prompts[0] }
            }
        }
        guard interactive || !prompts.isEmpty else { throw PiError("Provide a prompt or pipe text to stdin. Run pf --help.") }
        let manager: SessionManager
        if args.noSession { manager = try SessionManager.inMemory(cwd) }
        else if let file = args.session {
            let path = (file as NSString).expandingTildeInPath
            guard FileManager.default.fileExists(atPath: path) else { throw PiError("Session file does not exist: \(path)") }
            manager = try SessionManager.open(path, sessionDir, cwd)
        } else if args.continueSession { manager = try SessionManager.continueRecent(cwd, sessionDir) }
        else { manager = try SessionManager.create(cwd, sessionDir) }
        if let file = args.session, manager.getHeader().map({ HostPaths.canonicalWorkspace($0.cwd) }) != cwd { throw PiError("Session belongs to another workspace. Change directory before opening \(file)") }
        let explicitRouting = args.model != nil || env["PF_MODEL"] != nil || args.api != nil || args.baseURL != nil || args.providerExplicit
        let savedID = CodingSessionHost.savedConnectionID(manager)
        let profile = try args.demo || (explicitRouting && args.connection == nil) ? nil : connections.load().profile(args.connection ?? savedID)
        let savedKey = try env["PF_API_KEY"] ?? profile.flatMap { try connections.key(for: $0) }
        let model: Model
        if args.demo {
            model = Model(id: "offline-demo", name: "Offline demo", api: "openai-completions", provider: "demo", baseUrl: "https://example.invalid")
        } else if let profile { model = try profile.model() } else {
            guard let id = args.model ?? env["PF_MODEL"], !id.isEmpty else { throw PiError("Specify --model ID, PF_MODEL, or save a connection in Pi Swift") }
            let registry = createModels()
            if let known = registry.getModel(args.provider, id), args.baseURL == nil, args.api == nil { model = known }
            else {
                let api = args.api ?? (args.provider == "anthropic" ? "anthropic-messages" : "openai-completions")
                guard ["openai-completions", "openai-responses", "anthropic-messages"].contains(api) else { throw PiError("Unsupported custom API format") }
                let endpoint = args.baseURL ?? (args.provider == "anthropic" ? "https://api.anthropic.com" : "https://api.openai.com/v1")
                guard let url = URL(string: endpoint), let host = url.host,
                      url.scheme == "https" || (url.scheme == "http" && ["localhost", "127.0.0.1", "::1"].contains(host)) else { throw PiError("Use HTTPS, or HTTP on localhost") }
                if args.baseURL == nil && !["openai", "anthropic"].contains(args.provider) { throw PiError("Unknown model/provider; supply --base-url and --api explicitly") }
                model = Model(id: id, name: id, api: api, provider: args.provider, baseUrl: endpoint, input: ["text"], contextWindow: 128_000, maxTokens: 4096)
            }
        }
        let stream: StreamFn
        if args.demo { stream = demoStream }
        else { stream = { model, context, options in
            try PiAI.streamSimple(model, Context(messages: context.messages), options)
        } }
        let tools = args.demo ? [] : createCodingTools(cwd: cwd).filter { args.tools.contains($0.name) }
        let options = AgentOptions(initialState: AgentInitialState(
            systemPrompt: args.systemPrompt ?? codingSystemPrompt(cwd: cwd),
            model: model, thinkingLevel: args.thinking, tools: tools), streamFn: stream, getApiKey: { _ in savedKey })
        let host = try await CodingSessionHost.open(cwd: cwd, paths: paths, manager: manager, options: options, projectTrusted: args.trustProject ? true : nil, connectionID: profile?.id, extensions: extensions)
        let commands = CLICommands(host: host, connections: connections, demo: args.demo, printLine: { diagnostic($0 + "\n") })
        let activeHost = commands.activeHost
        for warning in host.diagnostics { diagnostic("pf: \(warning.message)\n") }
        let runFailed = Locked(false)
        let observe: @Sendable (AgentSessionEvent) -> Void = { event in
            if case .messageEnd(.assistant(let message)) = event, message.stopReason == .error { runFailed.withLock { $0 = true } }
            if args.mode == "json", let value = jsonEvent(event) { output(value.serialized() + "\n") }
            else if interactive, case .messageUpdate(_, .textDelta(_, let delta, _)) = event { output(delta) }
            else if interactive, case .toolExecutionStart(_, let name, _) = event { diagnostic("\n[\(name)]\n") }
        }
        var subscription = host.session.subscribe(observe)
        defer { subscription() }
        signal(SIGINT, SIG_IGN); signal(SIGTERM, SIG_IGN)
        let signals = [SIGINT, SIGTERM].map { number -> DispatchSourceSignal in
            let source = DispatchSource.makeSignalSource(signal: number, queue: .global())
            source.setEventHandler { Task { let current = activeHost.current; await current.session.abort(); await current.shutdown(); exit(128 + number) } }
            source.resume(); return source
        }
        defer { signals.forEach { $0.cancel() }; signal(SIGINT, SIG_DFL); signal(SIGTERM, SIG_DFL) }
        if args.mode == "json", let header = manager.getHeader() { output(header.json.serialized() + "\n") }
        if interactive { diagnostic("pf \(version) · \(model.id) · /help for commands\n") }
        func prompt(_ text: String) async throws {
            runFailed.withLock { $0 = false }
            let session = activeHost.current.session
            let disposition = Locked<PromptDisposition?>(nil)
            do {
                try await session.prompt(text, .init(preflightResult: { result in disposition.withLock { $0 = result } }, strictSkillCommands: interactive))
            } catch {
                if interactive, disposition.current == nil {
                    commands.pendingDraft.withLock { $0 = text }
                }
                throw error
            }
            if disposition.current == .handled { return }
            let last = await session.messages.reversed().compactMap { if case .assistant(let m) = $0 { return m }; return nil }.first
            runFailed.withLock { $0 = last?.stopReason == .error }
            if args.mode != "json" {
                if !interactive, let last { output(last.content.compactMap { if case .text(let t) = $0 { return t.text }; return nil }.joined() + "\n") }
                else if interactive { output("\n") }
                if let last, last.stopReason == .error { diagnostic("pf: \(last.errorMessage ?? "Model request failed")\n") }
            }
        }
        do {
            for text in prompts { try await prompt(text); if runFailed.current { break } }
            if interactive {
                while true {
                    let draft = commands.pendingDraft.withLock { value -> String in
                        let draft = value; value = ""; return draft
                    }
                    let completionNames = activeHost.current.commandCatalog(includeQuit: true).map { "/" + $0.name }.joined(separator: "\n")
                    guard let buffer = pf_readline("\npf › ", draft, completionNames) else { break }
                    let line = String(cString: buffer).replacingOccurrences(of: "\r\n", with: "\n")
                        .replacingOccurrences(of: "\r", with: "\n")
                    free(buffer)
                    if line.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { continue }
                    var builtin = true
                    do {
                        if let invocation = try SlashCommand.parse(line, catalog: activeHost.current.commandCatalog(includeQuit: true)) {
                            let previous = activeHost.current
                            guard try await commands.execute(invocation, input: line) else { break }
                            if activeHost.current !== previous {
                                subscription(); subscription = activeHost.current.session.subscribe(observe)
                            }
                        } else { builtin = false; try await prompt(line) }
                    } catch {
                        if builtin { commands.pendingDraft.withLock { $0 = line } }
                        diagnostic("pf: \(error)\n")
                    }
                }
            }
        } catch { await activeHost.current.shutdown(); throw error }
        await activeHost.current.shutdown()
        return runFailed.current ? 1 : 0
    }
    #endif

    private static let demoStream: StreamFn = { model, context, _ in
        let stream = createAssistantMessageEventStream()
        let userCount = context.messages.filter { $0.role == "user" }.count
        let message = AssistantMessage(content: [.text(TextContent(text: "pf is running through PiCodingAgent.AgentSession. User turns in this session: \(userCount). No network or tools were used."))], api: model.api, provider: model.provider, model: model.id)
        stream.push(.start(partial: message))
        stream.push(.textDelta(contentIndex: 0, delta: message.content.compactMap { if case .text(let t) = $0 { return t.text }; return nil }.joined(), partial: message))
        stream.push(.done(reason: .stop, message: message))
        return stream
    }
    private static func output(_ text: String) { FileHandle.standardOutput.write(Data(text.utf8)) }
    private static func diagnostic(_ text: String) { FileHandle.standardError.write(Data(text.utf8)) }
}
