/**
 * AgentSession - Core abstraction for agent lifecycle and session management.
 *
 * This class is shared between all run modes (interactive, print, rpc).
 * It encapsulates:
 * - Agent state access
 * - Event subscription with automatic session persistence
 * - Model and thinking level management
 * - Compaction (manual and auto)
 * - Bash execution
 * - Session switching and branching
 *
 * Modes use this class and add their own I/O layer on top.
 */

import Foundation
import PiAI
import PiAgent

// Port of packages/coding-agent/src/core/agent-session.ts (subset).
//
// Ported: prompt + persistence via agent event subscription, steering/follow-up queues, abort,
// manual compaction, automatic threshold/overflow compaction with one compact-and-retry recovery,
// automatic retry with backoff, request projection from the session, and the related events/getters.
//
// Additional native resource/extension/MCP integration is described in Docs/UPSTREAM.md.
// Still not a complete upstream SDK: JS/npm loading, complete UI/CLI extension contracts,
// model selection/auth UX, bash command UI, session export and all navigation helpers are not ported.

// ============================================================================
// Skill Block Parsing
// ============================================================================

public struct ParsedSkillBlock: Sendable {
    public var name: String
    public var location: String
    public var content: String
    public var userMessage: String?
}
public func parseSkillBlock(_ text: String) -> ParsedSkillBlock? {
    let pattern = #"^<skill name="([^"]+)" location="([^"]+)">\n([\s\S]*?)\n</skill>(?:\n\n([\s\S]+))?$"#
    guard let regex = try? NSRegularExpression(pattern: pattern), let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) else { return nil }
    func group(_ index: Int) -> String? { Range(match.range(at: index), in: text).map { String(text[$0]) } }
    let message = group(4)?.trimmingCharacters(in: .whitespacesAndNewlines)
    return .init(name: group(1)!, location: group(2)!, content: group(3)!, userMessage: message?.isEmpty == false ? message : nil)
}

/// `"manual" | "threshold" | "overflow"`
public enum CompactionReason: String, Sendable, Hashable {
    case manual
    case threshold
    case overflow
}

/// `{ source: "branchSummary" } | { source: "compaction"; reason }`
public enum SummarizationRetrySource: Sendable, Hashable {
    case branchSummary
    case compaction(reason: CompactionReason)

    public var source: String {
        switch self {
        case .branchSummary: return "branchSummary"
        case .compaction: return "compaction"
        }
    }
}

/** Session-specific events that extend the core AgentEvent */
public enum AgentSessionEvent: Sendable {
    // `Exclude<AgentEvent, { type: "agent_end" }>`
    // Swift: nested execution carries parentToolCallId in a separate associated event.
    case nestedToolExecution(event: AgentEvent, parentToolCallId: String)
    case agentStart
    case turnStart
    case turnEnd(message: AgentMessage, toolResults: [ToolResultMessage])
    case messageStart(message: AgentMessage)
    case messageUpdate(message: AgentMessage, assistantMessageEvent: AssistantMessageEvent)
    case messageEnd(message: AgentMessage)
    case toolExecutionStart(toolCallId: String, toolName: String, args: JsonObject)
    case toolExecutionUpdate(toolCallId: String, toolName: String, args: JsonObject, partialResult: AgentToolResult)
    case toolExecutionEnd(toolCallId: String, toolName: String, result: AgentToolResult, isError: Bool, durationMs: Int?)
    case agentEnd(messages: [AgentMessage], willRetry: Bool)
    case agentSettled(aborted: Bool)
    case queueUpdate(steering: [String], followUp: [String])
    case compactionStart(reason: CompactionReason)
    case entryAppended(entry: SessionEntry)
    case thinkingLevelChanged(level: ModelThinkingLevel)
    // Not ported: session_info_changed.
    case compactionEnd(reason: CompactionReason, result: CompactionResult?, aborted: Bool, willRetry: Bool, errorMessage: String?)
    case autoRetryStart(attempt: Int, maxAttempts: Int, delayMs: Int, errorMessage: String)
    case autoRetryEnd(success: Bool, attempt: Int, finalError: String?)
    case summarizationRetryScheduled(attempt: Int, maxAttempts: Int, delayMs: Int, errorMessage: String)
    case summarizationRetryAttemptStart(source: SummarizationRetrySource)
    case summarizationRetryFinished
    // Not ported: bash_execution_update.

    /// Swift: wraps every core event except `agent_end`, which carries `willRetry`.
    init?(_ event: AgentEvent) {
        switch event {
        case .agentStart: self = .agentStart
        case .agentEnd: return nil
        case .turnStart: self = .turnStart
        case .turnEnd(let message, let toolResults): self = .turnEnd(message: message, toolResults: toolResults)
        case .messageStart(let message): self = .messageStart(message: message)
        case .messageUpdate(let message, let event): self = .messageUpdate(message: message, assistantMessageEvent: event)
        case .messageEnd(let message): self = .messageEnd(message: message)
        case .toolExecutionStart(let id, let name, let args): self = .toolExecutionStart(toolCallId: id, toolName: name, args: args)
        case .toolExecutionUpdate(let id, let name, let args, let partial):
            self = .toolExecutionUpdate(toolCallId: id, toolName: name, args: args, partialResult: partial)
        case .toolExecutionEnd(let id, let name, let result, let isError, let durationMs):
            self = .toolExecutionEnd(toolCallId: id, toolName: name, result: result, isError: isError, durationMs: durationMs)
        }
    }

    public var type: String {
        switch self {
        case .nestedToolExecution(let event, _): return event.type
        case .agentStart: return "agent_start"
        case .turnStart: return "turn_start"
        case .turnEnd: return "turn_end"
        case .messageStart: return "message_start"
        case .messageUpdate: return "message_update"
        case .messageEnd: return "message_end"
        case .toolExecutionStart: return "tool_execution_start"
        case .toolExecutionUpdate: return "tool_execution_update"
        case .toolExecutionEnd: return "tool_execution_end"
        case .agentEnd: return "agent_end"
        case .agentSettled: return "agent_settled"
        case .thinkingLevelChanged: return "thinking_level_changed"
        case .queueUpdate: return "queue_update"
        case .compactionStart: return "compaction_start"
        case .entryAppended: return "entry_appended"
        case .compactionEnd: return "compaction_end"
        case .autoRetryStart: return "auto_retry_start"
        case .autoRetryEnd: return "auto_retry_end"
        case .summarizationRetryScheduled: return "summarization_retry_scheduled"
        case .summarizationRetryAttemptStart: return "summarization_retry_attempt_start"
        case .summarizationRetryFinished: return "summarization_retry_finished"
        }
    }
}

/** Listener function for agent session events */
public typealias AgentSessionEventListener = @Sendable (AgentSessionEvent) -> Void

// ============================================================================
// Types
// ============================================================================

public struct AgentSessionConfig: Sendable {
    public var agent: Agent
    public var sessionManager: SessionManager
    public var settingsManager: SettingsManager
    public var cwd: String
    public var resourceLoader: (any ResourceLoader)?
    public var extensionRunner: ExtensionRunner?
    public var projectTrusted: Bool
    public var initialActiveToolNames: Set<String>
    // Not ported: scopedModels, customTools, modelRuntime, cacheWarmer, extensionRunnerRef,
    // initialActiveToolNames, usesDefaultTools, defaultToolModifiers, allowedToolNames, excludedToolNames,
    // baseToolsOverride, sessionStartEvent.
    public init(agent: Agent, sessionManager: SessionManager, settingsManager: SettingsManager, cwd: String,
                resourceLoader: (any ResourceLoader)? = nil, extensionRunner: ExtensionRunner? = nil, projectTrusted: Bool = false, initialActiveToolNames: Set<String> = []) {
        self.agent = agent; self.sessionManager = sessionManager; self.settingsManager = settingsManager; self.cwd = cwd
        self.resourceLoader = resourceLoader; self.extensionRunner = extensionRunner; self.projectTrusted = projectTrusted
        self.initialActiveToolNames = initialActiveToolNames
    }
}

// Not ported: ExtensionBindings.

public enum QueuedInputDisposition: String, Sendable, Hashable {
    case handled
    case queued
}

/// `QueuedInputDisposition | "started"`
public enum PromptDisposition: String, Sendable, Hashable {
    case handled
    case queued
    case started
}

/// `"steer" | "followUp"`
public enum StreamingBehavior: String, Sendable, Hashable {
    case steer
    case followUp
}

/** Options for AgentSession.prompt() */
public struct PromptOptions: Sendable {
    /** Image attachments */
    public var images: [ImageContent]?
    /** When streaming, how to queue the message: "steer" (interrupt) or "followUp" (wait). Required if streaming. */
    public var streamingBehavior: StreamingBehavior?
    /** Called once the prompt is handled, queued, or its run has started. */
    public var preflightResult: (@Sendable (PromptDisposition) -> Void)?
    public var expandPromptTemplates: Bool
    // Not ported: input source metadata.
    public init(images: [ImageContent]? = nil, streamingBehavior: StreamingBehavior? = nil, preflightResult: (@Sendable (PromptDisposition) -> Void)? = nil, expandPromptTemplates: Bool = true) {
        self.images = images; self.streamingBehavior = streamingBehavior; self.preflightResult = preflightResult
        self.expandPromptTemplates = expandPromptTemplates
    }
}

// Not ported: ModelMutationOptions, ModelCycleResult.

/** Session statistics for /session command */
public struct SessionStats: Sendable {
    public struct Tokens: Sendable, Hashable {
        public var input: Int
        public var output: Int
        public var cacheRead: Int
        public var cacheWrite: Int
        public var total: Int
    }
    public var sessionFile: String?
    public var sessionId: String
    public var userMessages: Int
    public var assistantMessages: Int
    public var toolCalls: Int
    public var toolResults: Int
    public var totalMessages: Int
    public var tokens: Tokens
    public var cost: Double
    public var contextUsage: ContextUsage?
}

/// `ContextUsage` (extensions/types.ts): `tokens` and `percent` are null right after compaction,
/// until the next response reports usage.
public struct ContextUsage: Sendable, Hashable {
    public var tokens: Int?
    public var contextWindow: Int
    public var percent: Double?
    public init(tokens: Int?, contextWindow: Int, percent: Double?) {
        self.tokens = tokens; self.contextWindow = contextWindow; self.percent = percent
    }
}

private func estimateMessagesTokens(_ messages: [AgentMessage]) -> Int {
    var tokens = 0
    for message in messages {
        tokens += estimateTokens(message)
    }
    return tokens
}

// ============================================================================
// AgentSession Class
// ============================================================================

/// Swift: a class whose mutable fields live behind one lock. Upstream relies on JavaScript's single thread;
/// here agent listeners and hooks run on the agent's executor while callers use the public API.
public final class AgentSession: @unchecked Sendable {
    public let agent: Agent
    public let sessionManager: SessionManager
    public let settingsManager: SettingsManager

    private struct State {
        var unsubscribeAgent: (@Sendable () -> Void)?
        var eventListeners: [(id: Int, listener: AgentSessionEventListener)] = []
        var nextListenerId = 0
        var isAgentRunActive = false
        var preparation: UUID?
        var agentRunAbortRequested = false
        var idleWaiters: [CheckedContinuation<Void, Never>] = []

        // Message queueing (for UI display; actual queue is in agent)
        var steeringMessages: [String] = []
        var followUpMessages: [String] = []

        // Compaction state
        var compactionAbortController: AbortController?
        var autoCompactionAbortController: AbortController?
        var overflowRecoveryAttempted = false

        // Branch summarization state
        var branchSummaryAbortController: AbortController?

        // Retry state
        var retryAbortController: AbortController?
        var retryAttempt = 0
        /** The failed response a retry or recovery replaces, read and cleared by the next request. */
        var failedResponse: AssistantMessage?

        /// Swift: keyed by the message JSON (upstream: `WeakMap` keyed by object identity).
        var entryIdsByMessage: [JsonValue: String] = [:]
        var lastAssistantMessage: AssistantMessage?
        var lastAssistantToolResults: [AgentMessage] = []
        var isEmittingAgentSettled = false
        var deferredSettledActions: [@Sendable () async throws -> Void] = []

        /// Swift-only test seam replacing `vi.spyOn(session, "_runAutoCompaction")`.
        var runAutoCompactionOverride: (@Sendable (CompactionReason, Bool) async throws -> Bool)?
    }

    private let _state = Locked(State())
    private let _cwd: String
    public let resourceLoader: (any ResourceLoader)?
    public let extensionRunner: ExtensionRunner?
    private let extensionTools = ExtensionToolCatalog()
    private let nestedTools = NestedToolCallRunner()
    public typealias CompactionHandler = @Sendable (Model, CompactionSettings, CompactionPreparation?, AbortSignal) async throws -> CompactionResult?
    private let compactionHandler = Locked<CompactionHandler?>(nil)
    public func setCompactionHandler(_ handler: CompactionHandler?) { compactionHandler.withLock { $0 = handler } }
    private let disposed = Locked(false)
    private let skillErrors = Locked<[ResourceDiagnostic]>([])

    public func drainSkillErrors() -> [ResourceDiagnostic] {
        skillErrors.withLock { let result = $0; $0.removeAll(); return result }
    }
    private func _expandSkillCommand(_ text: String) -> String {
        do { return try expandSkillCommand(text, skills: resourceLoader?.getSkills().skills ?? []) }
        catch {
            skillErrors.withLock { $0.append(.init(type: .error, message: errorMessage(error))) }
            return text
        }
    }

    public init(_ config: AgentSessionConfig) async {
        self.agent = config.agent
        self.sessionManager = config.sessionManager
        self.settingsManager = config.settingsManager
        self._cwd = config.cwd
        self.resourceLoader = config.resourceLoader
        self.extensionRunner = config.extensionRunner
        extensionTools.state.withLock { $0.activated = config.initialActiveToolNames }

        // Always subscribe to agent events for internal handling
        // (session persistence, extensions, auto-compaction, retry logic)
        let unsubscribe = agent.subscribe { [weak self] event, _ in
            try await self?._handleAgentEvent(event)
        }
        _state.withLock { $0.unsubscribeAgent = unsubscribe }
        await _installAgentToolHooks()
        await _installAgentNextTurnRefresh()
        await _installAgentRequestProjection()
        // Not ported: _installAgentBoundaryHooks, _installHiddenDeclarationsProjection,
        // _installAgentForcedPromptProjection, _buildRuntime, _restoreToolsFromTranscript.
        await extensionRunner?.start(cwd: config.cwd, projectTrusted: config.projectTrusted, publish: { [weak self] owner, tools in
            guard let self else { throw PiError("Session is closed") }
            try await self._replaceExtensionTools(owner, tools)
        }, getTools: { [weak self] in await self?.getAllTools() ?? [] }, activateTools: { [weak self] names in
            guard let self else { throw PiError("Session is closed") }
            try await self.activateTools(names)
        }, executeTool: { [weak self] parent, name, args, signal in
            guard let self else { throw PiError("Session is closed") }
            return try await self.executeTool(parentToolCallId: parent, name: name, arguments: args, signal: signal)
        })
    }

    private func _installAgentToolHooks() async {
        guard let runner = extensionRunner else { return }
        let previousBefore = await agent.beforeToolCall
        let previousAfter = await agent.afterToolCall
        await agent.update { agent in
            agent.beforeToolCall = { event, signal in
                guard runner.isActive else { throw PiError("Extension runtime is closed") }
                let previous = try await previousBefore?(event, signal)
                if previous?.block == true { return previous }
                return try await runner.before(event) ?? previous
            }
            agent.afterToolCall = { event, signal in
                var next = event
                let previous = try await previousAfter?(event, signal)
                if let previous {
                    next.result = applyingToolResult(previous, to: event.result, isError: event.isError)
                    next.isError = next.result.isError ?? event.isError
                }
                if let patch = await runner.after(next) { return patch }
                return previous
            }
        }
    }

    public func getAllTools() async -> [ExtensionToolInfo] {
        let registered = extensionTools.infos(), names = Set(registered.map { $0.tool.name })
        let base = await agent.state.tools.filter { !names.contains($0.name) }
        return base.map { ExtensionToolInfo(tool: $0, exposure: .direct, namespace: nil, active: true) } + registered
    }

    public func activateTools(_ names: [String]) async throws {
        try await agent.update { [self] agent in
            try disposed.withLock { closed in
                guard !closed else { throw PiError("Session is closed") }
                let infos = extensionTools.infos(), known = Dictionary(uniqueKeysWithValues: infos.map { ($0.tool.name, $0) })
                for name in names {
                    guard let info = known[name], info.exposure != .hidden else { throw PiError("Tool is not available: \(name)") }
                }
                let previous = extensionTools.state.withLock { state in
                    let previous = state.activated; state.activated.formUnion(names); return previous
                }
                do { try _publishToolLoadout(agent) }
                catch { extensionTools.state.withLock { $0.activated = previous }; throw error }
            }
        }
    }

    private func _publishToolLoadout(_ agent: isolated Agent) throws {
        let infos = extensionTools.infos(), names = Set(infos.map { $0.tool.name })
        let next = agent.state.tools.filter { !names.contains($0.name) } + infos.filter(\.active).map(\.tool)
        let old = getCurrentTools(convertToLlm(sessionManager.buildSessionContext().messages))
        let nextNames = Set(next.map(\.name))
        let removed = old.filter { !nextNames.contains($0.name) }.map { ToolReference(name: $0.name) }
        let added = next.filter { tool in !old.contains { $0.name == tool.name && $0.description == tool.description && $0.parameters == tool.parameters } }.map(\.asTool)
        if !removed.isEmpty || !added.isEmpty {
            _ = try sessionManager.appendMessage(AgentMessage.system(SystemMessage(content: "", toolsAdded: added, toolsRemoved: removed)))
            agent.state.messages = sessionManager.buildSessionContext().messages
        }
        agent.state.tools = next
    }

    private func _replaceExtensionTools(_ owner: String, _ tools: [ExtensionTool]) async throws {
        try await agent.update { [self] agent in
            let revoked = try disposed.withLock { closed -> [AbortController] in
                guard !closed, extensionRunner?.isActive == true else { throw PiError("Session is closed") }
                let previous = extensionTools.state.withLock { $0 }, owned = previous.entries
                let oldNames = Set(owned.filter { $0.value.owner == owner }.map(\.key))
                let otherNames = Set(owned.keys).union(agent.state.tools.map(\.name)).subtracting(oldNames)
                var names = Set<String>(), entries = owned, kept = Set<String>()
                for registration in tools {
                    let name = registration.tool.name
                    guard !name.isEmpty, names.insert(name).inserted, !otherNames.contains(name) else { throw PiError("Duplicate or empty extension tool name: \(name)") }
                }
                for name in oldNames { entries[name] = nil }
                for var registration in tools {
                    let name = registration.tool.name
                    if let existing = owned[name], let version = registration.version,
                       existing.registration.version == version, existing.registration.exposure == registration.exposure {
                        entries[name] = existing; kept.insert(name); continue
                    }
                    let execute = registration.tool.execute, lease = AbortController(), nested = nestedTools
                    registration.tool.execute = { id, args, signal, update in
                        let combined = combineAbortSignals([signal, lease.signal]); defer { combined.cleanup() }
                        try combined.signal?.throwIfAborted()
                        let result = try await nested.withScope(id, signal: combined.signal) {
                            try await execute(id, args, combined.signal, update)
                        }
                        try combined.signal?.throwIfAborted()
                        return result
                    }
                    entries[name] = .init(owner: owner, lease: lease, registration: registration)
                }
                extensionTools.state.withLock { state in
                    state.entries = entries
                    state.order.removeAll { oldNames.contains($0) }
                    state.order += tools.map { $0.tool.name }
                }
                let oldTools = agent.state.tools
                agent.state.tools.removeAll { oldNames.contains($0.name) }
                do { try _publishToolLoadout(agent) }
                catch { extensionTools.state.withLock { $0 = previous }; agent.state.tools = oldTools; throw error }
                return oldNames.subtracting(kept).compactMap { owned[$0]?.lease }
            }
            revoked.forEach { $0.abort() }
        }
    }

    public func executeTool(parentToolCallId parent: String, name: String, arguments: JsonObject,
                            signal: AbortSignal? = nil) async throws -> AgentToolCallOutcome {
        guard !disposed.withLock({ $0 }) else { throw PiError("Session is closed") }
        let infos = await getAllTools()
        let tools = infos.filter { $0.exposure != .hidden && $0.exposure != .modelOnly }.map(\.tool)
        let sequential = await agent.toolExecution == .sequential || tools.first { $0.name == name }?.executionMode == .sequential
        return try await nestedTools.execute(parent: parent, name: name, args: arguments, signal: signal, sequential: sequential,
            run: { [self] call, signal, update in
                let state = await agent.state
                guard let assistant = state.messages.compactMap(\.assistantMessage).last else { throw PiError("No assistant message issued this call") }
                let before = await agent.beforeToolCall, after = await agent.afterToolCall
                return try await runToolCall(call, .init(tools: tools, assistantMessage: assistant,
                    context: .init(messages: state.messages, tools: state.tools), signal: signal, onUpdate: update,
                    beforeToolCall: { event, signal in var event = event; event.parentToolCallId = parent; return try await before?(event, signal) },
                    afterToolCall: { event, signal in var event = event; event.parentToolCallId = parent; return try await after?(event, signal) }))
            }, emit: { [self] event, parent in
                await extensionRunner?.emitEvent(.nestedToolExecution(event, parentToolCallId: parent))
                _emit(.nestedToolExecution(event: event, parentToolCallId: parent))
            })
    }

    /// Reload only while idle, so configuration never changes under a running permission decision.
    public func reloadResources() async throws {
        let boundary = try reserveIdleBoundary()
        defer { releaseIdleBoundary(boundary) }
        try await reloadResourcesAtBoundary()
    }
    private func reloadResourcesAtBoundary() async throws {
        settingsManager.reload()
        try resourceLoader?.reload()
        let skills = resourceLoader?.getSkills().skills ?? []
        let tools = await agent.state.tools.map(\.name)
        let prompt = formatSkillsForPrompt(skills, fileReadTool: tools.contains("read") ? "read" : tools.contains("bash") ? "bash" : "indirect")
        try await agent.update { agent in
            _ = try self.sessionManager.appendMessage(AgentMessage.system(.init(content: "", sections: [("skills", prompt.isEmpty ? nil : prompt)])))
            agent.state.messages = self.sessionManager.buildSessionContext().messages
        }
        await extensionRunner?.emitEvent(.resourcesReloaded)
    }
    /// Branching preserves the previous tree; resume loads an existing JSONL session.
    @discardableResult public func switchSession(file: String) async throws -> Bool {
        try await changeSession(reason: "resume") { try self.sessionManager.setSessionFile(file) }
    }
    @discardableResult public func branch(from entryID: String) async throws -> Bool {
        try await changeSession(reason: "branch") { try self.sessionManager.branch(entryID) }
    }
    @discardableResult public func newSession() async throws -> Bool {
        try await changeSession(reason: "new") { _ = try self.sessionManager.newSession() }
    }
    private func changeSession(reason: String, mutate: @Sendable () throws -> Void) async throws -> Bool {
        let boundary = try reserveIdleBoundary()
        defer { releaseIdleBoundary(boundary) }
        if try await extensionRunner?.beforeSessionChange(reason) == false { return false }
        guard !disposed.withLock({ $0 }) else { throw PiError("Session is closed") }
        try await agent.update { agent in
            try mutate()
            let names = getCurrentTools(convertToLlm(self.sessionManager.buildSessionContext().messages)).map(\.name)
            self.extensionTools.state.withLock { $0.activated = Set(names) }
            agent.state.messages = self.sessionManager.buildSessionContext().messages
            try self._publishToolLoadout(agent)
        }
        nestedTools.clear()
        _ = clearQueue()
        await extensionRunner?.emitEvent(.sessionChanged(reason: reason))
        try await reloadResourcesAtBoundary()
        return true
    }

    /// Preferred over dispose() when the caller must wait for MCP process/socket cleanup.
    public func shutdown() async {
        dispose()
        await extensionRunner?.shutdown()
        await agent.waitForIdle()
    }

    // Not ported: modelRuntime, _getRequiredRequestAuth, _recordSelection.

    /**
     * The model whose limits apply to `message`, or undefined when the message came from another
     * model. Under a virtual selection, that is the physical model that produced it.
     */
    private func _modelForMessage(_ message: AssistantMessage) async -> Model? {
        let model = await self.model
        // Not ported: virtual model resolution.
        return model.provider == message.provider && model.id == message.model ? model : nil
    }

    /** The model whose limits apply to the conversation. */
    private func _limitsModel() async -> Model {
        // Not ported: routed (virtual) models.
        await self.model
    }

    /** Whether `projection`, the current session projection, exceeds the compaction threshold of `model`. */
    private func _exceedsCompactionThreshold(_ model: Model, _ projection: SessionProjection) async throws -> Bool {
        if model.contextWindow <= 0 { return false }
        return shouldCompact(
            estimateProjectedContextTokens(projection, sessionManager.getBranch()).tokens,
            model.contextWindow,
            try settingsManager.getCompactionSettings(await self.model)
        )
    }

    private func _compactBeforeNextAssistantResponse(_ context: AgentContext) async throws -> AgentContext {
        let projection = sessionManager.buildSessionProjection()
        let model = await self.model
        // Not ported: virtual selections (checked in prepareRequest upstream).
        if !(try await _exceedsCompactionThreshold(model, projection)) {
            var next = context
            next.messages = projection.messages
            return next
        }
        _ = try await _runAutoCompaction(.threshold, false)
        var next = context
        next.messages = sessionManager.buildSessionProjection().messages
        return next
    }

    private func _installAgentRequestProjection() async {
        let previousPrepareRequest = await agent.prepareRequest
        await agent.update { [weak self] agent in
            agent.prepareRequest = { [weak self] request, signal in
                guard let self else { return try await previousPrepareRequest?(request, signal) }
                // Not ported: the failed response feeds virtual model routing.
                self._state.withLock { $0.failedResponse = nil }
                let projection = self.sessionManager.buildSessionProjection()
                let state = await self.agent.state
                var canonicalContext = request.context
                canonicalContext.messages = projection.messages
                // Messages declare the provider-visible loadout; context.tools keeps executable implementations.
                canonicalContext.tools = state.tools
                let previous = try await previousPrepareRequest?(
                    PrepareRequestContext(context: canonicalContext, model: state.model, thinkingLevel: state.thinkingLevel),
                    signal
                )
                var context = previous?.context ?? canonicalContext
                if let runner = self.extensionRunner { context.messages = try await runner.context(context.messages) }
                let model = previous?.model ?? state.model
                let thinkingLevel = previous?.thinkingLevel ?? state.thinkingLevel
                // Not ported: virtual model routing and the routed-model threshold check.
                return AgentRequestUpdate(context: context, model: model, thinkingLevel: thinkingLevel)
            }
        }
    }

    // Not ported: _dispatchTurnEndBoundary, _installAgentBoundaryHooks (extensions).

    private func _installAgentNextTurnRefresh() async {
        let previousWithContext = await agent.prepareNextTurnWithContext
        let previousPrepareNextTurn = await agent.prepareNextTurn
        let previousPrepareNextTurnWithContext: (@Sendable (PrepareNextTurnContext, AbortSignal?) async throws -> AgentLoopTurnUpdate?)? =
            previousWithContext ?? previousPrepareNextTurn.map { prepareNextTurn in
                { @Sendable (_: PrepareNextTurnContext, signal: AbortSignal?) in try await prepareNextTurn(signal) }
            }
        await agent.update { [weak self] agent in
            agent.prepareNextTurnWithContext = { [weak self] turn, signal in
                guard let self else { return try await previousPrepareNextTurnWithContext?(turn, signal) }
                let context = try await self._compactBeforeNextAssistantResponse(turn.context)
                var turnWithContext = turn
                turnWithContext.context = context
                let previousSnapshot = try await previousPrepareNextTurnWithContext?(turnWithContext, signal)
                var nextContext = previousSnapshot?.context ?? context
                // Not ported: system prompt rebuild and tool loadout update message.
                let state = await self.agent.state
                nextContext.tools = state.tools
                return AgentLoopTurnUpdate(
                    context: nextContext,
                    messages: previousSnapshot?.messages,
                    model: state.model,
                    thinkingLevel: state.thinkingLevel
                )
            }
        }
    }

    // =========================================================================
    // Event Subscription
    // =========================================================================

    private func _refreshFinalizedContext() async {
        let projection = sessionManager.buildSessionProjection()
        _state.withLock { state in
            for entry in projection.entries {
                for message in entry.messages {
                    state.entryIdsByMessage[agentMessageToJson(message)] = entry.sourceEntry.id
                }
            }
        }
        let messages = projection.messages
        await agent.update { $0.state.messages = messages }
    }

    // Not ported: boundary drafts and previews (_applyBoundaryDrafts, _createBoundaryPreviewManager,
    // _getPendingBoundaryMessages, _buildBoundaryContext, _commitBoundaryDrafts, _reportInvalidBoundaryContinuation).

    /** Emit an event to all listeners */
    private func _emit(_ event: AgentSessionEvent) {
        let listeners = _state.withLock { $0.eventListeners.map(\.listener) }
        for l in listeners {
            l(event)
        }
    }

    private func _emitQueueUpdate() {
        let (steering, followUp) = _state.withLock { ($0.steeringMessages, $0.followUpMessages) }
        _emit(.queueUpdate(steering: steering, followUp: followUp))
    }

    // Not ported: _emitSessionCompactFailed (extensions).

    private func _resolveIdleWaitIfIdle() {
        let waiters = _state.withLock { state -> [CheckedContinuation<Void, Never>] in
            if !Self.isIdle(state) || state.idleWaiters.isEmpty {
                return []
            }
            defer { state.idleWaiters = [] }
            return state.idleWaiters
        }
        for waiter in waiters {
            waiter.resume()
        }
    }

    private func _emitAgentSettled() async throws {
        let aborted = _state.withLock { state -> Bool in
            state.isAgentRunActive = false
            state.isEmittingAgentSettled = true
            return state.agentRunAbortRequested
        }
        // Not ported: cache warmer and extension agent_settled.
        _emit(.agentSettled(aborted: aborted))
        _state.withLock { $0.isEmittingAgentSettled = false }

        let deferred = _state.withLock { state -> [@Sendable () async throws -> Void] in
            defer { state.deferredSettledActions = [] }
            return state.deferredSettledActions
        }
        if !deferred.isEmpty {
            defer { _resolveIdleWaitIfIdle() }
            for action in deferred { try await action() }
            return
        }
        _resolveIdleWaitIfIdle()
    }

    /** Internal handler for agent events - shared by subscribe and reconnect */
    private func _handleAgentEvent(_ original: AgentEvent) async throws {
        var event = original
        if case .messageEnd(.toolResult(var message)) = original {
            let (calls, usage) = nestedTools.takeRecord(message.toolCallId)
            message.nestedCalls = calls
            if let usage { message.usage = message.usage.map { combineUsage($0, usage) } ?? usage }
            event = .messageEnd(message: .toolResult(message))
        }
        // An abort requested while the run was starting, e.g. during before_agent_start, stops it
        // here. agent_start is awaited before the first request.
        if case .agentStart = event, _state.withLock({ $0.agentRunAbortRequested }) { agent.abort() }
        // Not ported: nested tool call records.

        // When a user message starts, check if it's from either queue and remove it BEFORE emitting
        // This ensures the UI sees the updated queue state
        if case .messageStart(let message) = event, case .user(let user) = message {
            _state.withLock { $0.overflowRecoveryAttempted = false }
            let messageText = contentText(user.content, separator: "")
            if !messageText.isEmpty {
                let removed = _state.withLock { state -> Bool in
                    // Check steering queue first
                    if let steeringIndex = state.steeringMessages.firstIndex(of: messageText) {
                        state.steeringMessages.remove(at: steeringIndex)
                        return true
                    }
                    // Check follow-up queue
                    if let followUpIndex = state.followUpMessages.firstIndex(of: messageText) {
                        state.followUpMessages.remove(at: followUpIndex)
                        return true
                    }
                    return false
                }
                if removed { _emitQueueUpdate() }
            }
        }

        await extensionRunner?.emit(event)
        if case .agentEnd(let messages) = event {
            _emit(.agentEnd(messages: messages, willRetry: await _willRetryAfterAgentEnd(messages)))
        } else if let sessionEvent = AgentSessionEvent(event) {
            _emit(sessionEvent)
        }

        // Handle session persistence
        if case .messageEnd(let message) = event {
            var entryId: String?
            // Check if this is a custom message from extensions
            if message.role == "custom", let custom = CustomMessage(message) {
                // Persist as CustomMessageEntry
                entryId = try sessionManager.appendCustomMessageEntry(
                    custom.customType,
                    custom.content,
                    custom.display,
                    custom.details
                )
            } else if ["system", "user", "assistant", "toolResult"].contains(message.role) {
                // Regular LLM message - persist as SessionMessageEntry
                entryId = try sessionManager.appendMessage(message)
            }
            if let entryId {
                _state.withLock { $0.entryIdsByMessage[agentMessageToJson(message)] = entryId }
            }
            // Other message types (bashExecution, compactionSummary, branchSummary) are persisted elsewhere

            if case .assistant(let assistantMsg) = message {
                let retryEndAttempt = _state.withLock { state -> Int? in
                    state.lastAssistantMessage = assistantMsg
                    if assistantMsg.stopReason != .error && assistantMsg.stopReason != .length {
                        state.overflowRecoveryAttempted = false
                    }
                    // Reset retry counter immediately on successful assistant response
                    // This prevents accumulation across multiple LLM calls within a turn
                    if assistantMsg.stopReason != .error && state.retryAttempt > 0 {
                        defer { state.retryAttempt = 0 }
                        return state.retryAttempt
                    }
                    return nil
                }
                if let attempt = retryEndAttempt {
                    _emit(.autoRetryEnd(success: true, attempt: attempt, finalError: nil))
                }
            }
        }

        // A turn ends after its assistant message and every tool result has been appended.
        if case .turnEnd(_, let toolResults) = event {
            _state.withLock { $0.lastAssistantToolResults = toolResults.map { .toolResult($0) } }
            // Not ported: _flushPendingCustomMessages (sendCustomMessage).
        }
    }

    private func _willRetryAfterAgentEnd(_ messages: [AgentMessage]) async -> Bool {
        let (abortRequested, retryAttempt) = _state.withLock { ($0.agentRunAbortRequested, $0.retryAttempt) }
        if abortRequested { return false }
        let settings = settingsManager.getRetrySettings()
        if !settings.enabled || retryAttempt >= settings.maxRetries {
            return false
        }

        for message in messages.reversed() {
            if case .assistant(let assistant) = message {
                return await _isRetryableError(assistant)
            }
        }
        return false
    }

    private func _findPersistedMessageEntryId(_ message: AgentMessage) async -> String? {
        let key = agentMessageToJson(message)
        if let mapped = _state.withLock({ $0.entryIdsByMessage[key] }) { return mapped }
        for entry in sessionManager.getBranch().reversed() {
            if entry.type == "message", let entryMessage = entry.message, agentMessageToJson(entryMessage) == key { return entry.id }
        }

        let messages = await agent.state.messages
        guard let messageIndex = messages.firstIndex(where: { agentMessageToJson($0) == key }) else { return nil }
        let projection = sessionManager.buildSessionProjection()
        var projectedIndex = 0
        for entry in projection.entries {
            for _ in entry.messages {
                if projectedIndex == messageIndex {
                    _state.withLock { $0.entryIdsByMessage[key] = entry.sourceEntry.id }
                    return entry.sourceEntry.id
                }
                projectedIndex += 1
            }
        }
        return nil
    }

    private func _omitRecoveryAttempt(_ message: AssistantMessage, _ toolResults: [AgentMessage] = []) async throws {
        let targets: [AgentMessage] = [.assistant(message)] + toolResults
        var targetIds: [String?] = []
        for target in targets {
            targetIds.append(await _findPersistedMessageEntryId(target))
        }
        let stateMessages = await agent.state.messages.map(agentMessageToJson)
        let unresolvedProjectedTarget = targets.enumerated().contains { index, target in
            targetIds[index] == nil && stateMessages.contains(agentMessageToJson(target))
        }
        if unresolvedProjectedTarget {
            throw PiError("Cannot persist recovery omission because a projected message has no source entry")
        }
        for targetId in targetIds {
            guard let targetId else { continue }
            let editId = try sessionManager.appendContextEdit(targetId, nil)
            if let entry = sessionManager.getEntry(editId) { _emit(.entryAppended(entry: entry)) }
        }
        await _refreshFinalizedContext()
    }

    /** Find the last assistant message in agent state (including aborted ones) */
    private func _findLastAssistantMessage() async -> AssistantMessage? {
        let messages = await agent.state.messages
        for msg in messages.reversed() {
            if case .assistant(let assistant) = msg {
                return assistant
            }
        }
        return nil
    }

    // Not ported: _replaceMessageInPlace, _emitExtensionEvent.

    /**
     * Subscribe to agent events.
     * Session persistence is handled internally (saves messages on message_end).
     * Multiple listeners can be added. Returns unsubscribe function for this listener.
     */
    @discardableResult
    public func subscribe(_ listener: @escaping AgentSessionEventListener) -> @Sendable () -> Void {
        let id = _state.withLock { state -> Int in
            let id = state.nextListenerId
            state.nextListenerId += 1
            state.eventListeners.append((id: id, listener: listener))
            return id
        }

        // Return unsubscribe function for this specific listener
        return { [weak self] in
            self?._state.withLock { $0.eventListeners.removeAll { $0.id == id } }
        }
    }

    /** Disconnect from agent events during disposal. */
    private func _disconnectFromAgent() {
        let unsubscribe = _state.withLock { state -> (@Sendable () -> Void)? in
            defer { state.unsubscribeAgent = nil }
            return state.unsubscribeAgent
        }
        unsubscribe?()
    }

    /**
     * Remove all listeners and disconnect from agent.
     * Call this when completely done with the session.
     */
    public func dispose() {
        let first = disposed.withLock { value in let first = !value; value = true; return first }
        guard first else { return }
        extensionRunner?.invalidate()
        extensionTools.invalidate()
        nestedTools.clear()
        if let runner = extensionRunner { Task { await runner.shutdown() } }
        abortRetry()
        abortCompaction()
        abortBranchSummary()
        agent.abort()

        // Not ported: cache warmer.
        _disconnectFromAgent()
        _state.withLock { $0.eventListeners = [] }
    }

    // =========================================================================
    // Read-only State Access
    // =========================================================================

    /** Refresh the public finalized transcript from the canonical session projection. */
    public func refreshContext() async {
        await _refreshFinalizedContext()
    }

    /** Full agent state */
    public var state: AgentState {
        get async { await agent.state }
    }

    /// Current model. Swift: the agent always has one (upstream: may be undefined if not yet selected).
    public var model: Model {
        get async { await agent.state.model }
    }

    /** Current thinking level */
    public var thinkingLevel: AgentThinkingLevel {
        get async { await agent.state.thinkingLevel }
    }

    /** Whether the session is currently processing an agent run or post-run continuation. */
    public var isStreaming: Bool {
        _state.withLock { $0.isAgentRunActive }
    }

    private static func isIdle(_ state: State) -> Bool {
        !state.isAgentRunActive && state.preparation == nil && !isCompacting(state)
    }

    private static func isCompacting(_ state: State) -> Bool {
        state.autoCompactionAbortController != nil
            || state.compactionAbortController != nil
            || state.branchSummaryAbortController != nil
    }

    private func reserveIdleBoundary() throws -> UUID {
        guard !disposed.withLock({ $0 }) else { throw PiError("Session is closed") }
        return try _state.withLock { state in
            guard Self.isIdle(state) else { throw PiError("Wait for the session to become idle") }
            let token = UUID(); state.preparation = token; return token
        }
    }
    private func releaseIdleBoundary(_ token: UUID) {
        _state.withLock { if $0.preparation == token { $0.preparation = nil } }
        _resolveIdleWaitIfIdle()
    }

    /** Whether the session has no active agent run, compaction, branch summary, retry, or queued continuation. */
    public var isIdle: Bool {
        _state.withLock { Self.isIdle($0) }
    }

    /// Current effective system prompt. Swift: the agent's replayed system prompt (system prompt builder not ported).
    public var systemPrompt: String {
        get async { await agent.state.systemPrompt }
    }

    /** Current retry attempt (0 if not retrying) */
    public var retryAttempt: Int {
        _state.withLock { $0.retryAttempt }
    }

    // Not ported: tool registry accessors (getActiveToolNames, getAllTools, setActiveToolsByName, ...).

    /** Whether compaction or branch summarization is currently running */
    public var isCompacting: Bool {
        _state.withLock { Self.isCompacting($0) }
    }

    /** All messages including custom types like BashExecutionMessage */
    public var messages: [AgentMessage] {
        get async { await agent.state.messages }
    }

    /** Current steering mode */
    public var steeringMode: QueueMode {
        agent.steeringMode
    }

    /** Current follow-up mode */
    public var followUpMode: QueueMode {
        agent.followUpMode
    }

    /** Current session file path, or undefined if sessions are disabled */
    public var sessionFile: String? {
        sessionManager.getSessionFile()
    }

    /** Current session ID */
    public var sessionId: String {
        sessionManager.getSessionId()
    }

    /** Current session display name, if set */
    public var sessionName: String? {
        sessionManager.getSessionName()
    }

    // Not ported: scoped models, prompt templates, system prompt rebuild, tool loadout.

    private func _startRun(_ text: String, _ images: [ImageContent]?, _ onStarted: (() -> Void)? = nil) async throws {
        _state.withLock { state in
            state.isAgentRunActive = true
            state.preparation = nil
            state.agentRunAbortRequested = false
        }
        let messages: [AgentMessage]
        do {
            messages = try await _prepareRun(text, images)
        } catch {
            _state.withLock { $0.isAgentRunActive = false }
            // Not ported: pending bash/custom message flushes.
            _resolveIdleWaitIfIdle()
            throw error
        }
        onStarted?()

        // Compaction before the prompt may have scheduled a retry; the new prompt replaces it.
        _state.withLock { $0.failedResponse = nil }
        // Not ported: _recordSelection, pending tool names.
        var runError: (any Error)?
        do {
            try await agent.prompt(messages)
            while !abortRequested {
                if try await _handlePostAgentRun() {
                    if abortRequested { break }
                    try await agent.continue()
                    continue
                }
                if abortRequested { break }
                if !(await _runBeforeSettleBoundary()) { break }
                if abortRequested { break }
                try await agent.continue()
            }
        } catch {
            runError = error
        }
        // finally
        if abortRequested { _finishCancelledRetry() }
        _state.withLock { $0.failedResponse = nil }
        try await _emitAgentSettled()
        if let runError { throw runError }
    }

    private var abortRequested: Bool {
        _state.withLock { $0.agentRunAbortRequested }
    }

    /**
     * Prepare a run and return its starting messages: compact first when needed and build the starting
     * message, with a system message first when the agent's prompt is not yet in the session.
     */
    private func _prepareRun(_ text: String, _ images: [ImageContent]?) async throws -> [AgentMessage] {
        // Check if we need to compact before sending (catches aborted responses).
        // The starting message is sent below, so do not call agent.continue() here.
        if let lastAssistant = await _findLastAssistantMessage() {
            _ = try await _checkCompaction(lastAssistant, false)
        }

        // Not ported: before_agent_start, prompt image normalization, nextTurn and handler messages.
        var content: [UserContent] = [.text(TextContent(text: text))]
        if let images {
            content.append(contentsOf: images.map { .image($0) })
        }
        var messages: [AgentMessage] = [.user(UserMessage(content: .blocks(content), timestamp: dateNow()))]

        // Swift-only (replaces _preparePromptAndToolLoadout): requests are projected from the session, so the
        // agent's current system message is sent first when the session does not already carry it.
        let stateMessages = await agent.state.messages
        let agentSystem = getCurrentSystemMessage(stateMessages.compactMap(\.llmMessage))
        let sessionSystem = getCurrentSystemMessage(sessionManager.buildSessionProjection().messages.compactMap(\.llmMessage))
        if var agentSystem, agentSystem.withTimestamp(0).json != sessionSystem?.withTimestamp(0).json {
            agentSystem.timestamp = dateNow()
            messages.insert(.system(agentSystem), at: 0)
        }
        // Swift-only: start the run from the session projection so the agent loop declares tool changes against
        // the persisted transcript (the agent's own initial system message is not in the session).
        if stateMessages.map(agentMessageToJson) != sessionManager.buildSessionProjection().messages.map(agentMessageToJson) {
            await _refreshFinalizedContext()
        }
        return messages
    }

    private func _handlePostAgentRun() async throws -> Bool {
        let (message, toolResults) = _state.withLock { state -> (AssistantMessage?, [AgentMessage]) in
            defer {
                state.lastAssistantMessage = nil
                state.lastAssistantToolResults = []
            }
            return (state.lastAssistantMessage, state.lastAssistantToolResults)
        }
        if abortRequested {
            _finishCancelledRetry()
            return false
        }
        guard let message else { return agent.hasQueuedMessages() }

        if await _isRetryableError(message), try await _prepareRetry(message) {
            if abortRequested { _finishCancelledRetry() }
            _state.withLock { $0.failedResponse = message }
            return !abortRequested
        }
        if abortRequested {
            _finishCancelledRetry()
            return false
        }

        let failedAttempt = _state.withLock { state -> Int? in
            if message.stopReason == .error && state.retryAttempt > 0 {
                defer { state.retryAttempt = 0 }
                return state.retryAttempt
            }
            return nil
        }
        if let attempt = failedAttempt {
            _emit(.autoRetryEnd(success: false, attempt: attempt, finalError: message.errorMessage))
        }

        if try await _checkCompaction(message, true, toolResults) {
            return !abortRequested
        }

        // The low-level loop drains both queues before agent_end. Messages queued by
        // agent_end handlers require a fresh run before pre-settlement handlers fire.
        return !abortRequested && agent.hasQueuedMessages()
    }

    private func _runBeforeSettleBoundary() async -> Bool {
        // Not ported: agent_before_settle extension boundary. Without handlers upstream returns this.
        agent.hasQueuedMessages()
    }

    // Not ported: _normalizePromptImages.

    /**
     * Send a prompt to the agent.
     * - During streaming, queues via steer() or followUp() based on streamingBehavior option
     * @throws Error if streaming and no streamingBehavior specified
     */
    public func prompt(_ text: String, _ options: PromptOptions? = nil) async throws {
        guard !disposed.withLock({ $0 }) else { throw PiError("Session is closed") }
        let deferred = _state.withLock { state -> Bool in
            guard state.isEmittingAgentSettled else { return false }
            state.deferredSettledActions.append { [weak self] in try await self?.prompt(text, options) }
            return true
        }
        if deferred { return }
        let boundary = isStreaming ? nil : try reserveIdleBoundary()
        defer { if let boundary { releaseIdleBoundary(boundary) } }
        let preflightResult = options?.preflightResult
        if options?.expandPromptTemplates != false, try await extensionRunner?.command(text) == true { preflightResult?(.handled); return }

        if _state.withLock({ $0.compactionAbortController != nil }) {
            throw PiError(
                "Cannot submit a prompt while compaction is in progress. Wait for compaction to finish and retry."
            )
        }

        var inputText = text, currentImages = options?.images
        if let result = try await extensionRunner?.input(text, images: currentImages) {
            switch result {
            case .handled: preflightResult?(.handled); return
            case .transform(let next, let images): inputText = next; currentImages = images
            case .continueInput: break
            }
        }
        let expandedText = options?.expandPromptTemplates == false ? inputText : expandPromptTemplate(_expandSkillCommand(inputText), templates: resourceLoader?.getPrompts().templates ?? [])

        // If streaming, queue via steer() or followUp() based on option
        if isStreaming {
            guard let streamingBehavior = options?.streamingBehavior else {
                throw PiError(
                    "Agent is already processing. Specify streamingBehavior ('steer' or 'followUp') to queue the message."
                )
            }
            if streamingBehavior == .followUp {
                await _queueFollowUp(expandedText, currentImages)
            } else {
                await _queueSteer(expandedText, currentImages)
            }
            preflightResult?(.queued)
            return
        }

        // Not ported: model and auth validation (the agent always has a model; auth is resolved by its stream function).

        await extensionRunner?.emitEvent(.beforeAgentStart(prompt: expandedText))
        guard !disposed.withLock({ $0 }) else { throw PiError("Session is closed") }
        try await _startRun(expandedText, currentImages) {
            preflightResult?(.started)
        }
    }

    /**
     * Queue a steering message while the agent is running.
     * Delivered after the current assistant turn finishes executing its tool calls,
     * before the next LLM call.
     */
    @discardableResult
    public func steer(_ text: String, _ images: [ImageContent]? = nil) async throws -> QueuedInputDisposition {
        try await _queueUserInput(text, images, .steer)
    }

    /**
     * Queue a follow-up message to be processed after the agent finishes.
     * Delivered only when agent has no more tool calls or steering messages.
     */
    @discardableResult
    public func followUp(_ text: String, _ images: [ImageContent]? = nil) async throws -> QueuedInputDisposition {
        try await _queueUserInput(text, images, .followUp)
    }

    private func _queueUserInput(_ text: String, _ images: [ImageContent]?, _ behavior: StreamingBehavior) async throws -> QueuedInputDisposition {
        guard !disposed.withLock({ $0 }), _state.withLock({ $0.preparation == nil }) else { throw PiError("Session is closed or changing") }
        if try await extensionRunner?.command(text) == true { return .handled }
        var text = text, images = images
        if let result = try await extensionRunner?.input(text, images: images) {
            switch result {
            case .handled: return .handled
            case .transform(let next, let nextImages): text = next; images = nextImages
            case .continueInput: break
            }
        }
        guard !disposed.withLock({ $0 }), _state.withLock({ $0.preparation == nil }) else { throw PiError("Session is closed or changing") }
        text = expandPromptTemplate(_expandSkillCommand(text), templates: resourceLoader?.getPrompts().templates ?? [])
        if behavior == .steer {
            await _queueSteer(text, images)
        } else {
            await _queueFollowUp(text, images)
        }
        return .queued
    }

    /**
     * Internal: Queue a steering message (already expanded, no extension command check).
     */
    private func _queueSteer(_ text: String, _ images: [ImageContent]?) async {
        _state.withLock { $0.steeringMessages.append(text) }
        _emitQueueUpdate()
        var content: [UserContent] = [.text(TextContent(text: text))]
        if let images {
            content.append(contentsOf: images.map { .image($0) })
        }
        agent.steer(.user(UserMessage(content: .blocks(content), timestamp: dateNow())))
    }

    /**
     * Internal: Queue a follow-up message (already expanded, no extension command check).
     */
    private func _queueFollowUp(_ text: String, _ images: [ImageContent]?) async {
        _state.withLock { $0.followUpMessages.append(text) }
        _emitQueueUpdate()
        var content: [UserContent] = [.text(TextContent(text: text))]
        if let images {
            content.append(contentsOf: images.map { .image($0) })
        }
        agent.followUp(.user(UserMessage(content: .blocks(content), timestamp: dateNow())))
    }

    // Not ported: sendCustomMessage, sendUserMessage, pending custom messages.

    /**
     * Clear all queued messages and return them.
     * Useful for restoring to editor when user aborts.
     */
    @discardableResult
    public func clearQueue() -> (steering: [String], followUp: [String]) {
        let result = _state.withLock { state -> (steering: [String], followUp: [String]) in
            defer {
                state.steeringMessages = []
                state.followUpMessages = []
            }
            return (state.steeringMessages, state.followUpMessages)
        }
        agent.clearAllQueues()
        _emitQueueUpdate()
        return result
    }

    /** Number of pending messages (includes both steering and follow-up) */
    public var pendingMessageCount: Int {
        _state.withLock { $0.steeringMessages.count + $0.followUpMessages.count }
    }

    /** Get pending steering messages (read-only) */
    public func getSteeringMessages() -> [String] {
        _state.withLock { $0.steeringMessages }
    }

    /** Get pending follow-up messages (read-only) */
    public func getFollowUpMessages() -> [String] {
        _state.withLock { $0.followUpMessages }
    }

    /**
     * Abort current operation and wait for agent to become idle.
     */
    public func abort() async {
        _requestAbort()
        await waitForIdle()
    }

    /// Swift-only: the synchronous part of `abort()` (everything before its first `await`), so callers that cannot
    /// await (event listeners doing `void session.abort()` upstream) can request the abort before returning.
    func _requestAbort() {
        _state.withLock { state in
            if state.isAgentRunActive {
                state.agentRunAbortRequested = true
            }
        }
        abortRetry()
        abortCompaction()
        abortBranchSummary()
        // Not ported: before-settle abort flag (extensions).
        agent.abort()
    }

    public func waitForIdle() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let idle = _state.withLock { state -> Bool in
                if Self.isIdle(state) { return true }
                state.idleWaiters.append(continuation)
                return false
            }
            if idle { continuation.resume() }
        }
    }

    // =========================================================================
    // Model Management
    // =========================================================================

    // Not ported: setModel, cycleModel, cycleThinkingLevel, queue mode setters.

    public func getAvailableThinkingLevels() async -> [ModelThinkingLevel] {
        getSupportedThinkingLevels(await model)
    }

    public func setThinkingLevel(_ level: ModelThinkingLevel) async throws {
        let boundary = try reserveIdleBoundary()
        defer { releaseIdleBoundary(boundary) }
        let effective = clampThinkingLevel(await model, level)
        let changed = try await agent.update { agent -> Bool in
            guard agent.state.thinkingLevel != effective else { return false }
            try self.sessionManager.appendThinkingLevelChange(effective.rawValue)
            agent.state.thinkingLevel = effective
            return true
        }
        if changed { _emit(.thinkingLevelChanged(level: effective)) }
    }

    /// Upstream tree semantics: user/custom messages return to the editor, all other nodes
    /// continue after the selected entry. Navigation never deletes the abandoned branch.
    public func navigateTree(_ targetID: String, summarize: Bool = false,
                             customInstructions: String? = nil) async throws -> String? {
        let boundary = try reserveIdleBoundary()
        defer { releaseIdleBoundary(boundary) }
        let oldLeaf = sessionManager.getLeafId()
        if oldLeaf == targetID { return nil }
        guard let target = sessionManager.getEntry(targetID) else { throw PiError("Entry not found") }
        if try await extensionRunner?.beforeSessionChange("tree") == false { throw PiError("Navigation cancelled") }
        let controller = AbortController()
        _state.withLock { $0.branchSummaryAbortController = controller }
        defer { _state.withLock { $0.branchSummaryAbortController = nil } }
        var summary: BranchSummaryResult?
        if summarize {
            let entries = collectEntriesForBranchSummary(sessionManager, oldLeaf, targetID).entries
            if !entries.isEmpty {
                let model = await self.model
                let key = await agent.getApiKey
                summary = try await generateBranchSummary(entries, .init(model: model,
                    apiKey: await key?(model.provider), signal: controller.signal,
                    customInstructions: customInstructions,
                    reserveTokens: settingsManager.getBranchSummarySettings().reserveTokens,
                    streamFn: await agent.streamFunction, retry: settingsManager.getRetrySettings(),
                    callbacks: _summarizationRetryCallbacks(.branchSummary)))
                if let error = summary?.error { throw PiError(error) }
                if summary?.aborted == true { throw PiError("Branch summarization cancelled") }
            }
        }
        try controller.signal.throwIfAborted()
        guard sessionManager.getLeafId() == oldLeaf else { throw PiError("Session changed during navigation") }
        let editorText = sessionEntryEditorText(target)
        let newLeaf = editorText != nil ? target.parentId : targetID
        if let text = summary?.summary {
            try sessionManager.branchWithSummary(newLeaf, text,
                BranchSummaryDetails(readFiles: summary?.readFiles ?? [], modifiedFiles: summary?.modifiedFiles ?? []).json,
                false, summary?.usage)
        } else if let newLeaf { try sessionManager.branch(newLeaf) }
        else { sessionManager.resetLeaf() }
        await _refreshFinalizedContext()
        try await agent.update { agent in
            let names = getCurrentTools(convertToLlm(self.sessionManager.buildSessionContext().messages)).map(\.name)
            self.extensionTools.state.withLock { $0.activated = Set(names) }
            try self._publishToolLoadout(agent)
        }
        nestedTools.clear(); _ = clearQueue()
        await extensionRunner?.emitEvent(.sessionChanged(reason: "tree"))
        return editorText
    }

    // =========================================================================
    // Compaction
    // =========================================================================

    private func _runDefaultCompaction(
        _ preparation: CompactionPreparation,
        _ model: Model,
        _ customInstructions: String?,
        _ signal: AbortSignal,
        _ reason: CompactionReason
    ) async throws -> CompactionResult {
        // Not ported: model runtime auth and virtual routing (_getSummarizationRequestAuth).
        // Swift: the agent's getApiKey supplies the key.
        let getApiKey = await agent.getApiKey
        let apiKey = await getApiKey?(model.provider)
        let thinkingLevel = await agent.state.thinkingLevel
        return try await PiCodingAgent.compact(
            preparation,
            model,
            apiKey,
            nil, // headers
            customInstructions,
            signal,
            thinkingLevel,
            await agent.streamFunction,
            nil, // env
            settingsManager.getRetrySettings(),
            _summarizationRetryCallbacks(.compaction(reason: reason)),
            nil // sessionId
        )
    }

    private func _clearManualCompactionState() {
        _state.withLock { $0.compactionAbortController = nil }
        _resolveIdleWaitIfIdle()
    }

    /**
     * Manually compact the session context.
     *
     * This is the manual entry point used by `/compact`, RPC, and extensions. It is
     * separate from automatic threshold/overflow compaction, which enters through
     * `_checkCompaction()` and `_runAutoCompaction()`. Both paths call the lower-level
     * `compact()` function.
     *
     * Aborts the current agent operation first. Manual compaction never retries or
     * continues the interrupted agent turn.
     *
     * @param customInstructions Optional instructions for the compaction summary
     */
    @discardableResult
    public func compact(_ customInstructions: String? = nil) async throws -> CompactionResult {
        await abort()
        let compactionAbortController = AbortController()
        _state.withLock { $0.compactionAbortController = compactionAbortController }
        _emit(.compactionStart(reason: .manual))
        let fromExtension = false

        do {
            let model = await self.model

            let settings = try settingsManager.getCompactionSettings(model)
            let pathEntries = sessionManager.getBranch()

            let preparation = prepareCompaction(pathEntries, settings)
            let leaf = sessionManager.getLeafId()
            let override = try await compactionHandler.withLock { $0 }?(model, settings, preparation, compactionAbortController.signal)
            let result: CompactionResult
            if let override { result = override }
            else if let preparation {
                result = try await _runDefaultCompaction(preparation, model, customInstructions, compactionAbortController.signal, .manual)
            } else { throw PiError("Nothing to compact (session too small)") }
            if compactionAbortController.signal.aborted { throw PiError("Compaction cancelled") }
            guard sessionManager.getLeafId() == leaf else { throw PiError("Session changed during compaction") }
            let summary = result.summary
            let firstKeptEntryId = result.firstKeptEntryId
            let tokensBefore = result.tokensBefore
            let usage = result.usage
            let details = result.details

            if compactionAbortController.signal.aborted {
                throw PiError("Compaction cancelled")
            }

            try sessionManager.appendCompaction(summary, firstKeptEntryId, tokensBefore, details, fromExtension, usage)
            await _refreshFinalizedContext()
            let estimatedTokensAfter = estimateMessagesTokens(sessionManager.buildSessionProjection().messages)

            // Not ported: session_compact extension event.

            let compactionResult = CompactionResult(
                summary: summary,
                firstKeptEntryId: firstKeptEntryId,
                tokensBefore: tokensBefore,
                estimatedTokensAfter: estimatedTokensAfter,
                usage: usage,
                details: details
            )
            // compaction_end listeners may submit queued prompts, so expose idle state before notifying them.
            _clearManualCompactionState()
            _emit(.compactionEnd(reason: .manual, result: compactionResult, aborted: false, willRetry: false, errorMessage: nil))
            return compactionResult
        } catch {
            let message = errorMessage(error)
            let aborted = compactionAbortController.signal.aborted
            let errorMessage = aborted ? nil : "Compaction failed: \(message)"
            _clearManualCompactionState()
            _emit(.compactionEnd(reason: .manual, result: nil, aborted: aborted, willRetry: false, errorMessage: errorMessage))
            // Not ported: session_compact_failed extension event.
            throw error
        }
    }

    /**
     * Cancel in-progress compaction (manual or auto).
     */
    public func abortCompaction() {
        let (manual, auto) = _state.withLock { ($0.compactionAbortController, $0.autoCompactionAbortController) }
        manual?.abort()
        auto?.abort()
    }

    /**
     * Cancel in-progress branch summarization.
     */
    public func abortBranchSummary() {
        _state.withLock { $0.branchSummaryAbortController }?.abort()
    }

    /**
     * Dispatch automatic compaction after `agent_end` or before prompt submission.
     * Manual compaction does not call this method; it enters through `compact()`.
     *
     * Automatic cases:
     * 1. Overflow with retry: a context-overflow error or recoverable length stop;
     *    remove the failed assistant message, compact, and retry the turn once.
     * 2. Overflow without retry: a successful response exceeded the configured
     *    context window; compact but preserve the completed response.
     * 3. Threshold without retry: valid or estimated context usage crossed the
     *    configured threshold; compact without retrying the completed response.
     *
     * @param assistantMessage The assistant message to check
     * @param skipAbortedCheck If false, include aborted messages (for pre-prompt check). Default: true
     * @returns Whether the post-run loop should call `agent.continue()` for overflow recovery or queued messages
     */
    func _checkCompaction(
        _ assistantMessage: AssistantMessage,
        _ skipAbortedCheck: Bool = true,
        _ toolResults: [AgentMessage] = []
    ) async throws -> Bool {
        let settings = try settingsManager.getCompactionSettings(await self.model)
        if !settings.enabled { return false }

        // Skip if message was aborted (user cancelled) - unless skipAbortedCheck is false
        if skipAbortedCheck && assistantMessage.stopReason == .aborted { return false }

        // Skip overflow check if the message came from a different model.
        // This handles the case where user switched from a smaller-context model (e.g. opus)
        // to a larger-context model (e.g. codex) - the overflow error from the old model
        // shouldn't trigger compaction for the new model.
        let messageModel = await _modelForMessage(assistantMessage)
        let sameModel = messageModel != nil
        let contextWindow: Int
        if let messageModel {
            contextWindow = messageModel.contextWindow
        } else {
            contextWindow = await self.model.contextWindow
        }

        // Skip compaction checks if this assistant message is older than the latest
        // compaction boundary. This prevents a stale pre-compaction usage/error
        // from retriggering compaction on the first prompt after compaction.
        let compactionEntry = getLatestCompactionEntry(sessionManager.getBranch())
        let compactionTime = compactionEntry.flatMap { parseIsoTimestamp($0.timestamp) }
        let assistantIsFromBeforeCompaction = compactionTime.map { assistantMessage.timestamp <= $0 } ?? false
        if assistantIsFromBeforeCompaction {
            return false
        }

        // Automatic cases 1 and 2: context overflow.
        // A length stop is recoverable when output ended below the model's original desired limit,
        // independent of the configured context size or any context-clamped provider request limit.
        let currentProjection = sessionManager.buildSessionProjection()
        let assistantEntryId = await _findPersistedMessageEntryId(.assistant(assistantMessage))
        let assistantIsProjected =
            assistantEntryId == nil
            || currentProjection.entries.contains { entry in
                entry.sourceEntry.id == assistantEntryId && entry.messages.contains { $0.role == "assistant" }
            }
        let branch = sessionManager.getBranch()
        let assistantIndex = assistantEntryId.flatMap { id in branch.firstIndex { $0.id == id } } ?? -1
        let entriesAfterAssistant = assistantIndex >= 0 ? Array(branch[(assistantIndex + 1)...]) : []
        let hasPostAssistantContextEdit = entriesAfterAssistant.contains { $0.type == "context_edit" }
        let latestAssistantEdit = entriesAfterAssistant
            .compactMap(\.contextEditEntry)
            .filter { $0.targetId == assistantEntryId }
            .last
        let assistantRetainedForExplicitRecovery =
            assistantEntryId == nil
            || (!entriesAfterAssistant.contains { $0.type == "compaction" }
                // `latestAssistantEdit?.replacement !== null`
                && (latestAssistantEdit == nil || latestAssistantEdit!.replacement != nil))
        let assistantUsageMatchesProjection = assistantIsProjected && !hasPostAssistantContextEdit
        let explicitOverflow = assistantMessage.stopReason == .error && isContextOverflow(assistantMessage)
        let contextOverflow =
            sameModel
            && ((explicitOverflow && assistantRetainedForExplicitRecovery)
                || (assistantUsageMatchesProjection && isContextOverflow(assistantMessage, contextWindow)))
        let recoverableLength =
            sameModel && assistantIsProjected && isRecoverableLength(assistantMessage, messageModel!.maxTokens)
        if contextOverflow || recoverableLength {
            let willRetry = assistantMessage.stopReason != .stop

            // Case 2: the response completed successfully. Compact, but do not retry because
            // agent.continue() cannot continue from a completed assistant response.
            if !willRetry {
                return try await _runAutoCompaction(.overflow, false)
            }

            if _state.withLock({ $0.overflowRecoveryAttempted }) {
                let errorMessage = contextOverflow
                    ? "Context overflow recovery failed after one compact-and-retry attempt. Try reducing context or switching to a larger-context model."
                    : "Truncated response recovery failed after one compact-and-retry attempt."
                _emit(.compactionEnd(reason: .overflow, result: nil, aborted: false, willRetry: false, errorMessage: errorMessage))
                // Not ported: session_compact_failed extension event.
                return false
            }

            // Persistently omit the selected final attempt before post-run recovery compaction.
            _state.withLock { $0.overflowRecoveryAttempted = true }
            try await _omitRecoveryAttempt(assistantMessage, toolResults)
            let retry = try await _runAutoCompaction(.overflow, willRetry)
            if retry { _state.withLock { $0.failedResponse = assistantMessage } }
            return retry
        }

        // Case 3: threshold compaction without retry.
        // For error messages or all-zero usage messages, estimate from the last valid response.
        // This ensures sessions that hit persistent API errors (e.g. 529) or malformed zero-usage
        // responses can still compact and do not reset context accounting.
        var contextTokens: Int
        let projection = currentProjection
        let hasContextEdits = projection.entries.contains { $0.sourceEntry.type == "context_edit" }
        let directContextTokens = calculateContextTokens(assistantMessage.usage)
        if hasContextEdits {
            contextTokens = estimateProjectedContextTokens(projection, branch).tokens
        } else if assistantMessage.stopReason == .error || directContextTokens == 0 {
            let messages = await agent.state.messages
            let estimate = estimateContextTokens(messages)
            // Without provider usage, estimate.tokens is the pure message-size estimate.
            // Only usage-backed estimates need the stale pre-compaction check.
            if let lastUsageIndex = estimate.lastUsageIndex {
                // Verify the usage source is post-compaction. Kept pre-compaction messages
                // have stale usage reflecting the old (larger) context and would falsely
                // trigger compaction right after one just finished.
                let usageMsg = messages[lastUsageIndex]
                if compactionEntry != nil,
                   case .assistant(let usageAssistant) = usageMsg,
                   let compactionTime,
                   usageAssistant.timestamp <= compactionTime {
                    return false
                }
            }
            contextTokens = estimate.tokens
        } else {
            contextTokens = directContextTokens
        }
        if shouldCompact(contextTokens, contextWindow, settings) {
            return try await _runAutoCompaction(.threshold, false)
        }
        return false
    }

    /// Swift-only test seam: replaces `_runAutoCompaction` (upstream tests use `vi.spyOn`).
    func _setRunAutoCompactionOverride(_ override: (@Sendable (CompactionReason, Bool) async throws -> Bool)?) {
        _state.withLock { $0.runAutoCompactionOverride = override }
    }

    /**
     * Execute threshold or overflow compaction. Manual compaction uses
     * `AgentSession.compact()` instead.
     *
     * @param reason Automatic trigger selected by `_checkCompaction()`
     * @param willRetry Whether to continue the interrupted turn after overflow compaction
     * @returns Whether the post-run loop should call `agent.continue()`
     */
    func _runAutoCompaction(_ reason: CompactionReason, _ willRetry: Bool) async throws -> Bool {
        if let override = _state.withLock({ $0.runAutoCompactionOverride }) {
            return try await override(reason, willRetry)
        }
        let model = await self.model
        let settings = try settingsManager.getCompactionSettings(model)
        var abortController: AbortController?
        var started = false
        let fromExtension = false

        defer {
            _state.withLock { state in
                if state.autoCompactionAbortController === abortController {
                    state.autoCompactionAbortController = nil
                }
            }
            _resolveIdleWaitIfIdle()
        }

        do {
            let pathEntries = sessionManager.getBranch()
            let preparation = prepareCompaction(pathEntries, settings)
            if preparation == nil && compactionHandler.withLock({ $0 }) == nil { return false }
            let leaf = sessionManager.getLeafId()
            let controller = AbortController()
            abortController = controller
            _state.withLock { $0.autoCompactionAbortController = controller }
            started = true
            _emit(.compactionStart(reason: reason))
            try controller.signal.throwIfAborted()

            // Not ported: session_before_compact (extension-provided compaction / cancel).
            try controller.signal.throwIfAborted()

            // Shared default summary generator, also used by manual compaction.
            let override = try await compactionHandler.withLock { $0 }?(model, settings, preparation, controller.signal)
            let compactResult: CompactionResult
            if let override { compactResult = override }
            else if let preparation { compactResult = try await _runDefaultCompaction(preparation, model, nil, controller.signal, reason) }
            else {
                _emit(.compactionEnd(reason: reason, result: nil, aborted: false, willRetry: false, errorMessage: nil))
                return false
            }
            guard sessionManager.getLeafId() == leaf else { throw PiError("Session changed during compaction") }
            let summary = compactResult.summary
            let firstKeptEntryId = compactResult.firstKeptEntryId
            let tokensBefore = compactResult.tokensBefore
            let usage = compactResult.usage
            let details = compactResult.details
            try controller.signal.throwIfAborted()

            try sessionManager.appendCompaction(summary, firstKeptEntryId, tokensBefore, details, fromExtension, usage)
            await _refreshFinalizedContext()
            let estimatedTokensAfter = estimateMessagesTokens(sessionManager.buildSessionProjection().messages)

            // Not ported: session_compact extension event.

            let result = CompactionResult(
                summary: summary,
                firstKeptEntryId: firstKeptEntryId,
                tokensBefore: tokensBefore,
                estimatedTokensAfter: estimatedTokensAfter,
                usage: usage,
                details: details
            )
            _emit(.compactionEnd(reason: reason, result: result, aborted: false, willRetry: willRetry, errorMessage: nil))

            if willRetry { return true }

            // Auto-compaction can complete while follow-up/steering/custom messages are waiting.
            // Continue once so queued messages are delivered.
            return agent.hasQueuedMessages()
        } catch {
            let message = errorMessage(error)
            let aborted = abortController?.signal.aborted == true
            if started {
                let errorMessage: String? = aborted
                    ? nil
                    : reason == .overflow
                        ? "Context overflow recovery failed: \(message)"
                        : "Auto-compaction failed: \(message)"
                _emit(.compactionEnd(reason: reason, result: nil, aborted: aborted, willRetry: false, errorMessage: errorMessage))
                // Not ported: session_compact_failed extension event.
            }
            return false
        }
    }

    /**
     * Toggle auto-compaction setting.
     */
    public func setAutoCompactionEnabled(_ enabled: Bool) {
        settingsManager.setCompactionEnabled(enabled)
    }

    /** Whether auto-compaction is enabled */
    public var autoCompactionEnabled: Bool {
        settingsManager.getCompactionEnabled()
    }

    // Not ported: bindExtensions, extension resources, tool registry, _buildRuntime, reload.

    // =========================================================================
    // Auto-Retry
    // =========================================================================

    private func _isRetryableError(_ message: AssistantMessage) async -> Bool {
        // Context overflow is handled by compaction, not retry.
        let contextWindow: Int
        if let messageModel = await _modelForMessage(message) {
            contextWindow = messageModel.contextWindow
        } else {
            contextWindow = await self.model.contextWindow
        }
        if isContextOverflow(message, contextWindow) { return false }
        return isRetryableAssistantError(message)
    }

    /**
     * Retry policy + callbacks shared by compaction and branch-summary summarization calls.
     * Uses the same `settings.retry` budget/backoff as agent-turn retries so a single transient
     * stream drop no longer fails the whole operation. `source` carries the context
     * the TUI needs to render the retry and recreate the underlying indicator.
     */
    private func _summarizationRetryCallbacks(_ source: SummarizationRetrySource) -> RetryCallbacks {
        RetryCallbacks(
            onRetryScheduled: { [weak self] attempt, maxAttempts, delayMs, errorMessage in
                self?._emit(.summarizationRetryScheduled(attempt: attempt, maxAttempts: maxAttempts, delayMs: delayMs, errorMessage: errorMessage))
            },
            onRetryAttemptStart: { [weak self] in
                self?._emit(.summarizationRetryAttemptStart(source: source))
            },
            onRetryFinished: { [weak self] _, _, _ in
                self?._emit(.summarizationRetryFinished)
            }
        )
    }

    private func _finishCancelledRetry() {
        let attempt = _state.withLock { state -> Int in
            defer { state.retryAttempt = 0 }
            return state.retryAttempt
        }
        if attempt == 0 { return }
        _emit(.autoRetryEnd(success: false, attempt: attempt, finalError: "Retry cancelled"))
    }

    /**
     * Prepare a retryable error for continuation with exponential backoff.
     * @returns true if the caller should continue the agent, false otherwise
     */
    private func _prepareRetry(_ message: AssistantMessage) async throws -> Bool {
        let settings = settingsManager.getRetrySettings()
        if !settings.enabled {
            return false
        }

        let attempt = _state.withLock { state -> Int? in
            state.retryAttempt += 1
            if state.retryAttempt > settings.maxRetries {
                // Preserve the completed attempt count so post-run handling can emit the final failure.
                state.retryAttempt -= 1
                return nil
            }
            return state.retryAttempt
        }
        guard let attempt else { return false }

        let delayMs = retryDelayMs(settings, attempt)

        let errorMessage = message.errorMessage.flatMap { $0.isEmpty ? nil : $0 } ?? "Unknown error"
        _emit(.autoRetryStart(attempt: attempt, maxAttempts: settings.maxRetries, delayMs: delayMs, errorMessage: errorMessage))

        // Keep the failed attempt in raw history while durably omitting it from model projection.
        try await _omitRecoveryAttempt(message)

        // Wait with exponential backoff (abortable)
        let retryAbortController = AbortController()
        _state.withLock { $0.retryAbortController = retryAbortController }
        do {
            try await PiAI.sleep(delayMs, retryAbortController.signal)
        } catch {
            _state.withLock { $0.retryAbortController = nil }
            // Aborted during sleep - emit end event so UI can clean up
            _finishCancelledRetry()
            return false
        }
        _state.withLock { $0.retryAbortController = nil }

        return true
    }

    /**
     * Cancel in-progress retry.
     */
    public func abortRetry() {
        _state.withLock { $0.retryAbortController }?.abort()
    }

    /** Whether auto-retry is currently in progress */
    public var isRetrying: Bool {
        _state.withLock { $0.retryAbortController != nil }
    }

    /** Whether auto-retry is enabled */
    public var autoRetryEnabled: Bool {
        settingsManager.getRetryEnabled()
    }

    /**
     * Toggle auto-retry setting.
     */
    public func setAutoRetryEnabled(_ enabled: Bool) {
        settingsManager.setRetryEnabled(enabled)
    }

    // Not ported: bash execution, session naming, tree navigation, forking helpers.

    /**
     * Get session statistics.
     */
    public func getSessionStats() async -> SessionStats {
        var userMessages = 0
        var assistantMessages = 0
        var toolResults = 0
        var totalMessages = 0
        var toolCalls = 0
        var usageTotals = createUsageTotals()

        for entry in sessionManager.getEntries() {
            if case .usage(let usageEntry) = entry {
                addUsageToTotals(&usageTotals, usageEntry.usage)
            } else if let usage = entry.branchSummaryEntry?.usage ?? entry.compactionEntry?.usage {
                addUsageToTotals(&usageTotals, usage)
            }
            guard let message = entry.message else { continue }
            totalMessages += 1
            switch message {
            case .user:
                userMessages += 1
            case .toolResult(let toolResult):
                toolResults += 1
                if let usage = toolResult.usage {
                    addUsageToTotals(&usageTotals, usage)
                }
            case .assistant(let assistantMsg):
                assistantMessages += 1
                toolCalls += assistantMsg.content.filter { if case .toolCall = $0 { return true } else { return false } }.count
                addUsageToTotals(&usageTotals, assistantMsg.usage)
            default:
                break
            }
        }

        return SessionStats(
            sessionFile: sessionFile,
            sessionId: sessionId,
            userMessages: userMessages,
            assistantMessages: assistantMessages,
            toolCalls: toolCalls,
            toolResults: toolResults,
            totalMessages: totalMessages,
            tokens: SessionStats.Tokens(
                input: usageTotals.input,
                output: usageTotals.output,
                cacheRead: usageTotals.cacheRead,
                cacheWrite: usageTotals.cacheWrite,
                total: usageTotals.input + usageTotals.output + usageTotals.cacheRead + usageTotals.cacheWrite
            ),
            cost: usageTotals.cost,
            contextUsage: await getContextUsage()
        )
    }

    public func getContextUsage() async -> ContextUsage? {
        let model = await _limitsModel()

        let contextWindow = model.contextWindow
        if contextWindow <= 0 { return nil }

        // After compaction, the last assistant usage reflects pre-compaction context size.
        // We can only trust usage from an assistant that responded after the latest compaction.
        // If no such assistant exists, context token count is unknown until the next LLM response.
        let projection = sessionManager.buildSessionProjection()
        let branch = sessionManager.getBranch()
        let latestCompaction = getLatestCompactionEntry(branch)

        if let latestCompaction {
            let projectedAssistants = Set(projection.entries.compactMap { entry -> String? in
                entry.messages.contains { message in
                    guard case .assistant(let assistant) = message else { return false }
                    return assistant.stopReason != .aborted
                        && assistant.stopReason != .error
                        && calculateContextTokens(assistant.usage) > 0
                } ? entry.sourceEntry.id : nil
            })
            let compactionIndex = branch.firstIndex { $0.id == latestCompaction.id } ?? -1
            let hasPostCompactionUsage = branch[(compactionIndex + 1)...].contains { projectedAssistants.contains($0.id) }
            if !hasPostCompactionUsage { return ContextUsage(tokens: nil, contextWindow: contextWindow, percent: nil) }
        }

        let estimate = estimateProjectedContextTokens(projection, branch)
        let percent = Double(estimate.tokens) / Double(contextWindow) * 100

        return ContextUsage(tokens: estimate.tokens, contextWindow: contextWindow, percent: percent)
    }

    // Not ported: exportToHtml, exportToJsonl, summarizeForBugReport.

    /**
     * Get text content of last assistant message.
     * Useful for /copy command.
     * @returns Text content, or undefined if no assistant message exists
     */
    public func getLastAssistantText() async -> String? {
        let lastAssistant = await messages.reversed().lazy.compactMap { m -> AssistantMessage? in
            guard case .assistant(let msg) = m else { return nil }
            // Skip aborted messages with no content
            if msg.stopReason == .aborted && msg.content.isEmpty { return nil }
            return msg
        }.first

        guard let lastAssistant else { return nil }

        var text = ""
        for content in lastAssistant.content {
            if case .text(let t) = content {
                text += t.text
            }
        }

        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    // Not ported: extension system (createReplacedSessionContext, hasExtensionHandlers, extensionRunner).
}

private extension SystemMessage {
    func withTimestamp(_ timestamp: Int) -> SystemMessage {
        var copy = self
        copy.timestamp = timestamp
        return copy
    }
}
