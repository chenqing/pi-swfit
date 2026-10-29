import Foundation
import Observation
import PiAI
import PiAgent
import PiCodingAgent
import PiHost

/// Main-actor presentation adapter. The Agent owns the model transcript; the UI owns no provider state.
@MainActor @Observable
public final class ChatSession {
    public private(set) var messages: [ChatMessage] = []
    public private(set) var state: ChatRunState = .idle
    public private(set) var error: String?
    public private(set) var isCommandError = false
    public private(set) var cancellationMessage = "Stopped · Your partial response is preserved"
    public var displayedMessages: [ChatMessage] {
        let pendingIDs = Set(approvals.pending.map(\.id))
        return messages.map { message in
            var message = message
            for i in message.tools.indices where pendingIDs.contains(message.tools[i].id) {
                message.tools[i].state = .awaitingApproval
            }
            return message
        }
    }
    public var usage: ChatUsageSummary { ChatUsageSummary(messages: messages) }
    public let availableToolNames: [String]
    public private(set) var modelName: String
    public private(set) var name: String?
    public private(set) var isChangingConnection = false
    public var draft = ""
    public private(set) var commands = CommandDescriptor.builtins()
    public let approvals: ApprovalCenter
    public var permissionMode: ChatPermissionMode { approvals.permissionMode }
    public var canSelectPermissionMode: Bool { managesApprovals && !isRunning && !isChangingConnection && approvals.pending.isEmpty }
    public var isRunning: Bool { active }
    public var draftPosition: ConversationDraftStore.Position? {
        codingHost.map { .init(leafID: $0.manager.getLeafId()) }
    }
    public var sessionFile: String? { codingHost?.manager.getSessionFile() }
    public var workspace: String? { codingHost?.cwd }
    public var connectionID: String? { codingHost?.connectionID }
    private var active = false
    private var managesApprovals = true
    @ObservationIgnored private var codingHost: CodingSessionHost?
    @ObservationIgnored private var agent: Agent
    @ObservationIgnored private var assistantID: UUID?

    public init(options: AgentOptions, approvalPolicy: ChatApprovalPolicy = .always) throws {
        let center = ApprovalCenter()
        approvals = center
        managesApprovals = approvalPolicy == .always
        var options = options
        if options.streamFn == nil {
            options.streamFn = { model, context, options in
                try PiAI.streamSimple(model, Context(messages: context.messages), options)
            }
        }
        let hostAuthorization = options.beforeToolCall
        options.beforeToolCall = { context, signal in
            if let decision = try await hostAuthorization?(context, signal), decision.block == true { return decision }
            guard approvalPolicy == .always else { return nil }
            try signal?.throwIfAborted()
            guard await center.permissionMode.requiresApproval(tool: context.toolCall.name, arguments: context.args.value, workspace: nil) else { return nil }
            let allowed = await center.request(ChatApproval(id: context.toolCall.id, toolName: context.toolCall.name,
                                                          arguments: context.args.value.serialized()), signal: signal)
            return allowed ? nil : BeforeToolCallResult(block: true, reason: "Tool execution was declined.", terminate: true)
        }
        availableToolNames = (options.initialState?.tools ?? []).map(\.name).sorted()
        modelName = options.initialState?.model?.name ?? "Unknown model"
        agent = try Agent(options)
    }

    /// Affects only this open conversation. Never resolves an already-pending call.
    public func selectPermissionMode(_ mode: ChatPermissionMode) throws {
        guard canSelectPermissionMode else { throw PiError("Wait for the conversation to be idle before changing permissions") }
        approvals.permissionMode = mode
    }

    public func clearCommandError() {
        guard isCommandError else { return }
        error = nil; isCommandError = false
        if state == .failed { state = .idle }
    }

    public func send(_ text: String? = nil) async {
        let input = (text ?? draft).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !input.isEmpty, !isRunning, !isChangingConnection else { return }
        cancellationMessage = "Stopped · Your partial response is preserved"
        isCommandError = false
        draft = ""; error = nil; state = .running; active = true; assistantID = nil
        approvals.reset()
        let pendingUser = ChatMessage(role: .user, text: input)
        messages.append(pendingUser)
        let disposition = Locked<PromptDisposition?>(nil)
        let unsubscribe = agent.subscribe { [weak self] event, _ in await self?.receive(event) }
        defer {
            unsubscribe(); approvals.cancelAll()
            if state == .running { state = .completed }
            if state == .stopping { state = .cancelled }
            finishPendingTools()
            active = false
        }
        await withTaskCancellationHandler {
            do {
                if let codingHost {
                    try await codingHost.session.prompt(input, .init(preflightResult: { result in disposition.withLock { $0 = result } }, strictSkillCommands: true))
                }
                else { try await agent.prompt(input) }
            } catch {
                if state == .stopping || Task.isCancelled { state = .cancelled }
                else { self.error = String(describing: error); state = .failed }
            }
        } onCancel: { [agent, codingHost] in
            agent.abort()
            if let codingHost { Task { await codingHost.session.abort() } }
        }
        if codingHost != nil, disposition.current == nil || disposition.current == .handled {
            messages.removeAll { $0.id == pendingUser.id }
            if error != nil {
                isCommandError = true
                if draft.isEmpty { draft = input }
            }
        }
        if Task.isCancelled { state = .cancelled }
    }

    /// Cancels the current request. Completed tool effects are never rolled back or automatically replayed.
    public func stop() {
        guard active, state != .stopping else { return }
        state = .stopping
        agent.abort()
        if let codingHost { Task { await codingHost.session.abort() } }
        approvals.cancelAll()
    }

    public func reset() async throws {
        guard !isRunning, !isChangingConnection else { return }
        if let old = codingHost {
            let next = try await old.newConversation()
            codingHost = next; agent = next.session.agent; commands = next.commandCatalog()
            await old.shutdown()
        } else { try await agent.reset() }
        messages = []; draft = ""; error = nil; state = .idle; assistantID = nil; name = nil
        approvals.reset()
        approvals.permissionMode = .manual
    }

    /// Opens a persistent coding session in Manual mode, with workspace reads approved.
    public static func openCoding(cwd inputCwd: String, profile: ConnectionProfile, store: ConnectionStore,
                                  sessionFile: String? = nil, streamFn: StreamFn? = nil, projectTrusted: Bool? = nil,
                                  extensions: [NativeExtension] = []) async throws -> ChatSession {
        let cwd = HostPaths.canonicalWorkspace(inputCwd)
        let center = ApprovalCenter()
        let manager: SessionManager
        if let sessionFile {
            guard FileManager.default.fileExists(atPath: sessionFile) else { throw PiError("Session file does not exist") }
            manager = try SessionManager.open(sessionFile, store.paths.sessionDirectory(cwd: cwd), cwd)
            guard manager.getHeader().map({ HostPaths.canonicalWorkspace($0.cwd) }) == cwd else { throw PiError("This session belongs to a different workspace") }
        } else { manager = try SessionManager.create(cwd, store.paths.sessionDirectory(cwd: cwd)) }
        if let sessionFile, let position = try ConversationDraftStore(paths: store.paths).position(for: sessionFile) {
            if let leaf = position.leafID { try manager.branch(leaf) }
            else { manager.resetLeaf() }
        }
        let key = try await Task.detached { try store.key(for: profile) }.value
        var options = AgentOptions(initialState: AgentInitialState(systemPrompt: codingSystemPrompt(cwd: cwd),
            model: try profile.model(), tools: PiHost.createCodingTools(cwd: cwd)), streamFn: streamFn,
            getApiKey: { _ in key })
        options.beforeToolCall = { context, signal in
            try signal?.throwIfAborted()
            let preview = try previewCodingChange(name: context.toolCall.name, arguments: context.args.value, cwd: cwd)
            if await center.permissionMode.requiresApproval(tool: context.toolCall.name, arguments: context.args.value, workspace: cwd) {
                let allowed = await center.request(ChatApproval(id: context.toolCall.id, toolName: context.toolCall.name,
                    arguments: context.args.value.serialized(), preview: preview?.diff), signal: signal)
                guard allowed else { return BeforeToolCallResult(block: true, reason: "Tool execution was declined.", terminate: true) }
            }
            try signal?.throwIfAborted()
            try preview?.verifyUnchanged()
            return nil
        }
        let host = try await CodingSessionHost.open(cwd: cwd, paths: store.paths, manager: manager,
                                                    options: options, projectTrusted: projectTrusted, connectionID: profile.id, extensions: extensions)
        let result = ChatSession(host: host, approvals: center, state: await host.session.agent.state)
        result.commands = host.commandCatalog()
        result.restore(host.manager.buildSessionContext().messages)
        return result
    }

    private init(host: CodingSessionHost, approvals: ApprovalCenter, state: AgentState) {
        availableToolNames = state.tools.map(\.name).sorted(); modelName = state.model.name
        name = host.manager.getSessionName()
        codingHost = host; agent = host.session.agent; self.approvals = approvals
    }

    public func selectConnection(_ profile: ConnectionProfile, store: ConnectionStore) async throws {
        guard !isRunning, !isChangingConnection, let host = codingHost else { throw PiError("Open an idle workspace before switching models") }
        isChangingConnection = true; defer { isChangingConnection = false }
        let key = try await Task.detached { try store.key(for: profile) }.value
        try await host.selectConnection(profile, key: key)
        modelName = profile.modelID
    }

    /// Consume a host command without inserting a model message. Restore failed input
    /// without replacing text the user prepared while an async command was running.
    public func consumeCommand(_ input: String, action: () async throws -> Void) async throws {
        guard !isRunning, !isChangingConnection, draft == input else { throw PiError("The draft changed or the conversation is busy") }
        clearCommandError()
        draft = ""
        do { try await action() }
        catch {
            if draft.isEmpty { draft = input }
            else if draft != input { draft += "\n\n" + input }
            throw error
        }
    }

    public func reloadResources() async throws -> [String] {
        guard !isRunning, !isChangingConnection, let host = codingHost else { throw PiError("Open an idle workspace to reload resources") }
        isChangingConnection = true; defer { isChangingConnection = false; commands = host.commandCatalog() }
        try await host.session.reloadResources()
        return host.resourceDiagnostics().map { $0.message }
    }

    public func thinkingOptions() async throws -> (levels: [ModelThinkingLevel], current: ModelThinkingLevel) {
        guard let host = codingHost else { throw PiError("Open a workspace to choose thinking") }
        return (await host.session.getAvailableThinkingLevels(), await host.session.thinkingLevel)
    }
    public func selectThinking(_ input: String) async throws {
        guard !isRunning, !isChangingConnection, let host = codingHost else { throw PiError("Wait for the conversation to be idle") }
        _ = try await host.selectThinking(input)
    }
    public func navigationItems(forkOnly: Bool = false) throws -> [SessionNavigationItem] {
        guard let host = codingHost else { throw PiError("Open a workspace to navigate history") }
        return host.navigationItems(forkOnly: forkOnly)
    }
    @discardableResult
    public func navigate(to id: String, fork: Bool, summarize: Bool = false, instructions: String = "") async throws -> String {
        guard !isRunning, !isChangingConnection, let host = codingHost else { throw PiError("Wait for the conversation to be idle") }
        guard draft.isEmpty else { throw PiError("Save or clear the draft before navigating history") }
        if !fork, host.manager.getLeafId() == id { return "Already at this point. No changes were made." }
        cancellationMessage = "Navigation cancelled. Your conversation is unchanged."
        active = true; error = nil; state = .running
        defer {
            active = false
            if state == .stopping { state = .cancelled }
            else if state == .running { state = .idle }
        }
        do {
            let text: String?
            if fork {
                let result = try await host.fork(before: id)
                codingHost = result.host; agent = result.host.session.agent; commands = result.host.commandCatalog(); text = result.text
                await host.shutdown()
                approvals.reset(); approvals.permissionMode = .manual
            } else {
                text = try await host.session.navigateTree(id, summarize: summarize,
                    customInstructions: instructions.isEmpty ? nil : instructions)
            }
            if let current = codingHost {
                restore(current.manager.buildSessionContext().messages)
                name = current.manager.getSessionName()
            }
            // A new draft typed while summarizing is never overwritten.
            if let text, !text.isEmpty { draft += (draft.isEmpty ? "" : "\n\n") + text }
            state = .idle
            return fork ? "Fork created. Edit the restored message to continue." : "Moved to selected point."
        } catch {
            state = state == .stopping || CommandFeedback.isCancellation(error) ? .cancelled : .failed
            throw error
        }
    }

    public func sessionInformation() async throws -> String {
        guard let host = codingHost else { throw PiError("Open a workspace to inspect a saved session") }
        return SlashCommand.describe(await host.session.getSessionStats())
    }

    @discardableResult
    public func compact(_ instructions: String = "") async throws -> String {
        guard !isRunning, !isChangingConnection, let host = codingHost else { throw PiError("Open an idle workspace before compacting") }
        cancellationMessage = "Compaction cancelled. Your conversation is unchanged."
        active = true; state = .running; error = nil
        defer { active = false }
        do {
            let notice = try await CommandFeedback.compact(host.session, instructions: instructions)
            state = notice.hasPrefix("Context compacted.") ? .completed : .idle
            return notice
        } catch {
            state = state == .stopping || CommandFeedback.isCancellation(error) ? .cancelled : .failed
            throw error
        }
    }

    public func rename(_ title: String) throws {
        guard !isRunning, !isChangingConnection, let host = codingHost else { throw PiError("Wait for the conversation to be idle") }
        let title = try ConversationLibrary.validTitle(title)
        try host.manager.appendSessionInfo(title)
        name = title
    }

    public func shutdown() async {
        approvals.cancelAll()
        if let codingHost { await codingHost.shutdown() }
        else { agent.abort(); await agent.waitForIdle() }
    }

    private func restore(_ transcript: [AgentMessage]) {
        messages = []; assistantID = nil
        for message in transcript {
            switch message {
            case .user(let user):
                let text: String
                switch user.content {
                case .string(let value): text = value
                case .blocks(let values): text = values.compactMap { if case .text(let t) = $0 { return t.text }; return nil }.joined(separator: "\n")
                }
                messages.append(ChatMessage(role: .user, text: text))
            case .assistant(let assistant):
                let item = ChatMessage(role: .assistant)
                messages.append(item); assistantID = item.id; update(assistant)
            case .toolResult(let result):
                upsertTool(result.toolCallId, name: result.toolName) { tool in
                    tool.output = result.content.compactMap { if case .text(let t) = $0 { return t.text }; return nil }.joined(separator: "\n")
                    tool.diff = result.details?["diff"]?.stringValue
                    tool.state = result.isError ? .failed : .succeeded
                }
            default: break
            }
        }
        finishPendingTools()
    }

    private func receive(_ event: AgentEvent) {
        switch event {
        case .messageStart(.assistant(let message)):
            if state == .failed { state = .running; error = nil }
            let item = ChatMessage(role: .assistant)
            assistantID = item.id; messages.append(item); update(message)
        case .messageUpdate(.assistant(let message), _): update(message)
        case .messageEnd(.assistant(let message)):
            update(message)
            if message.stopReason == .error { error = message.errorMessage ?? "The model request failed."; state = .failed }
            if message.stopReason == .aborted { state = .cancelled }
        case .toolExecutionStart(let id, let name, let args):
            upsertTool(id, name: name, arguments: JsonValue.object(args).serialized()) { $0.state = .running }
        case .toolExecutionUpdate(let id, let name, _, let result):
            upsertTool(id, name: name) { $0.output = Self.text(result) }
        case .toolExecutionEnd(let id, let name, let result, let isError, _):
            upsertTool(id, name: name) { tool in
                tool.output = Self.text(result)
                tool.diff = result.details?["diff"]?.stringValue
                if state == .stopping || state == .cancelled { tool.state = isError ? .interrupted : .succeeded }
                else if approvals.wasRejected(id) { tool.state = .denied }
                else { tool.state = isError ? .failed : .succeeded }
            }
        default: break
        }
    }

    private func update(_ message: AssistantMessage) {
        guard let index = messages.firstIndex(where: { $0.id == assistantID }) else { return }
        messages[index].text = message.content.compactMap { if case .text(let t) = $0 { return t.text }; return nil }.joined()
        if message.usage.input + message.usage.output + message.usage.cacheRead + message.usage.cacheWrite > 0 {
            messages[index].usage = message.usage
        }
        for case .toolCall(let call) in message.content {
            upsertTool(call.id, name: call.name, arguments: JsonValue.object(call.arguments).serialized()) { _ in }
        }
    }

    private func upsertTool(_ id: String, name: String, arguments: String? = nil, mutate: (inout ChatToolCall) -> Void) {
        for i in messages.indices {
            if let j = messages[i].tools.firstIndex(where: { $0.id == id }) {
                var tool = messages[i].tools[j]
                if let arguments { tool.arguments = arguments }
                mutate(&tool); messages[i].tools[j] = tool; return
            }
        }
        guard let i = messages.firstIndex(where: { $0.id == assistantID }) else { return }
        var tool = ChatToolCall(id: id, name: name, arguments: arguments ?? "{}")
        mutate(&tool); messages[i].tools.append(tool)
    }

    private func finishPendingTools() {
        for i in messages.indices {
            for j in messages[i].tools.indices where [.pending, .running].contains(messages[i].tools[j].state) {
                messages[i].tools[j].state = .interrupted
            }
        }
    }
    private static func text(_ result: AgentToolResult) -> String {
        result.content.compactMap { if case .text(let t) = $0 { return t.text }; return nil }.joined(separator: "\n")
    }
}
