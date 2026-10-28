import Foundation
import PiAI

// Port of packages/agent/src/agent.ts

private func defaultConvertToLlm(_ messages: [AgentMessage]) -> [Message] {
    messages.compactMap { message in
        // message.role === "system" || "user" || "assistant" || "toolResult"
        message.llmMessage
    }
}

private let EMPTY_USAGE = Usage(
    input: 0,
    output: 0,
    cacheRead: 0,
    cacheWrite: 0,
    totalTokens: 0,
    cost: UsageCost(input: 0, output: 0, cacheRead: 0, cacheWrite: 0, total: 0)
)

private let DEFAULT_MODEL = Model(
    id: "unknown",
    name: "unknown",
    api: "unknown",
    provider: "unknown",
    baseUrl: "",
    reasoning: false,
    input: [],
    cost: ModelCost(input: 0, output: 0, cacheRead: 0, cacheWrite: 0),
    contextWindow: 0,
    maxTokens: 0
)

/// Initial state for `Agent`. `systemPrompt` and `tools` become the leading system message unless `messages` already starts with one.
public struct AgentInitialState: Sendable {
    public var systemPrompt: String?
    public var model: Model?
    public var thinkingLevel: AgentThinkingLevel?
    public var tools: [AgentTool]?
    public var messages: [AgentMessage]?
    public init(
        systemPrompt: String? = nil,
        model: Model? = nil,
        thinkingLevel: AgentThinkingLevel? = nil,
        tools: [AgentTool]? = nil,
        messages: [AgentMessage]? = nil
    ) {
        self.systemPrompt = systemPrompt; self.model = model; self.thinkingLevel = thinkingLevel
        self.tools = tools; self.messages = messages
    }
}

private func createMutableAgentState(_ initialState: AgentInitialState?) -> AgentState {
    let tools = initialState?.tools ?? []
    var messages = initialState?.messages ?? []
    let initialMessage = createInitialSystemMessage(initialState?.systemPrompt, tools.map { toToolDeclaration($0.asTool) })
    if messages.first?.role != "system", let initialMessage { messages.insert(.system(initialMessage), at: 0) }

    return AgentState(
        model: initialState?.model ?? DEFAULT_MODEL,
        thinkingLevel: initialState?.thinkingLevel ?? .off,
        tools: tools,
        messages: messages
    )
}

/// Options for constructing an `Agent`.
public struct AgentOptions: Sendable {
    public var initialState: AgentInitialState?
    public var convertToLlm: (@Sendable ([AgentMessage]) async -> [Message])?
    public var transformContext: (@Sendable ([AgentMessage], AbortSignal?) async -> [AgentMessage])?
    /// Swift: optional like the runtime fallback upstream; nil uses the default stream function.
    public var streamFn: StreamFn?
    public var getApiKey: (@Sendable (String) async -> String?)?
    public var onPayload: OnPayload?
    public var onResponse: OnResponse?
    public var onProviderStreamEvent: OnProviderStreamEvent?
    public var beforeToolCall: (@Sendable (BeforeToolCallContext, AbortSignal?) async throws -> BeforeToolCallResult?)?
    public var afterToolCall: (@Sendable (AfterToolCallContext, AbortSignal?) async throws -> AfterToolCallResult?)?
    public var finishTurn: FinishTurn?
    public var prepareRequest: PrepareRequest?
    public var prepareNextTurn: (@Sendable (AbortSignal?) async throws -> AgentLoopTurnUpdate?)?
    public var prepareNextTurnWithContext: (@Sendable (PrepareNextTurnContext, AbortSignal?) async throws -> AgentLoopTurnUpdate?)?
    public var steeringMode: QueueMode?
    public var followUpMode: QueueMode?
    public var sessionId: String?
    public var identity: ClientIdentity?
    public var thinkingBudgets: ThinkingBudgets?
    public var transport: Transport?
    public var maxRetryDelayMs: Int?
    public var toolExecution: ToolExecutionMode?

    public init(
        initialState: AgentInitialState? = nil,
        convertToLlm: (@Sendable ([AgentMessage]) async -> [Message])? = nil,
        transformContext: (@Sendable ([AgentMessage], AbortSignal?) async -> [AgentMessage])? = nil,
        streamFn: StreamFn? = nil,
        getApiKey: (@Sendable (String) async -> String?)? = nil,
        onPayload: OnPayload? = nil,
        onResponse: OnResponse? = nil,
        onProviderStreamEvent: OnProviderStreamEvent? = nil,
        beforeToolCall: (@Sendable (BeforeToolCallContext, AbortSignal?) async throws -> BeforeToolCallResult?)? = nil,
        afterToolCall: (@Sendable (AfterToolCallContext, AbortSignal?) async throws -> AfterToolCallResult?)? = nil,
        finishTurn: FinishTurn? = nil,
        prepareRequest: PrepareRequest? = nil,
        prepareNextTurn: (@Sendable (AbortSignal?) async throws -> AgentLoopTurnUpdate?)? = nil,
        prepareNextTurnWithContext: (@Sendable (PrepareNextTurnContext, AbortSignal?) async throws -> AgentLoopTurnUpdate?)? = nil,
        steeringMode: QueueMode? = nil,
        followUpMode: QueueMode? = nil,
        sessionId: String? = nil,
        identity: ClientIdentity? = nil,
        thinkingBudgets: ThinkingBudgets? = nil,
        transport: Transport? = nil,
        maxRetryDelayMs: Int? = nil,
        toolExecution: ToolExecutionMode? = nil
    ) {
        self.initialState = initialState; self.convertToLlm = convertToLlm; self.transformContext = transformContext
        self.streamFn = streamFn; self.getApiKey = getApiKey; self.onPayload = onPayload; self.onResponse = onResponse
        self.onProviderStreamEvent = onProviderStreamEvent; self.beforeToolCall = beforeToolCall; self.afterToolCall = afterToolCall
        self.finishTurn = finishTurn; self.prepareRequest = prepareRequest; self.prepareNextTurn = prepareNextTurn
        self.prepareNextTurnWithContext = prepareNextTurnWithContext; self.steeringMode = steeringMode
        self.followUpMode = followUpMode; self.sessionId = sessionId; self.identity = identity; self.thinkingBudgets = thinkingBudgets
        self.transport = transport; self.maxRetryDelayMs = maxRetryDelayMs; self.toolExecution = toolExecution
    }
}

/// Swift: a lock-protected class so the queueing APIs stay synchronous (`nonisolated`) like upstream.
private final class PendingMessageQueue: Sendable {
    private struct State {
        var messages: [AgentMessage] = []
        var mode: QueueMode
    }

    private let state: Locked<State>

    init(_ mode: QueueMode) {
        state = Locked(State(mode: mode))
    }

    var mode: QueueMode {
        get { state.withLock { $0.mode } }
        set { state.withLock { $0.mode = newValue } }
    }

    func enqueue(_ message: AgentMessage) {
        state.withLock { $0.messages.append(message) }
    }

    func hasItems() -> Bool {
        state.withLock { !$0.messages.isEmpty }
    }

    func peek() -> [AgentMessage] {
        state.withLock { Self.peek($0) }
    }

    private static func peek(_ s: State) -> [AgentMessage] {
        if s.mode == .all { return s.messages }
        guard let first = s.messages.first else { return [] }
        return [first]
    }

    func drain() -> [AgentMessage] {
        state.withLock { s in
            let drained = Self.peek(s)
            s.messages = Array(s.messages.dropFirst(drained.count))
            return drained
        }
    }

    func clear() {
        state.withLock { $0.messages = [] }
    }

    func remove(_ message: UserMessage) -> Bool {
        state.withLock { s in
            guard let i = s.messages.firstIndex(where: { if case .user(let value) = $0 { return value == message }; return false }) else { return false }
            s.messages.remove(at: i)
            return true
        }
    }
}

/// `{ promise, resolve, abortController }`: the promise is the list of `waitForIdle()` waiters.
private struct ActiveRun {
    var waiters: [CheckedContinuation<Void, Never>] = []
    let abortController: AbortController
}

public typealias AgentListener = @Sendable (AgentEvent, AbortSignal) async throws -> Void

/// Stateful wrapper around the low-level agent loop.
///
/// `Agent` owns the current transcript, emits lifecycle events, executes tools,
/// and exposes queueing APIs for steering and follow-up messages.
///
/// Swift: an actor. Hook properties and `state` are actor-isolated; set them inside `update { ... }`.
/// Listeners, queues, `signal`, `abort()` and `waitForIdle()` are `nonisolated` so they can be used
/// while a run is in progress, as upstream allows.
public actor Agent {
    private var _state: AgentState
    private let listeners = Locked<(nextId: Int, entries: [(id: Int, listener: AgentListener)])>((0, []))
    private let steeringQueue: PendingMessageQueue
    private let followUpQueue: PendingMessageQueue

    public var convertToLlm: @Sendable ([AgentMessage]) async -> [Message]
    public var transformContext: (@Sendable ([AgentMessage], AbortSignal?) async -> [AgentMessage])?
    public var streamFunction: StreamFn
    public var getApiKey: (@Sendable (String) async -> String?)?
    public var onPayload: OnPayload?
    public var onResponse: OnResponse?
    public var onProviderStreamEvent: OnProviderStreamEvent?
    public var beforeToolCall: (@Sendable (BeforeToolCallContext, AbortSignal?) async throws -> BeforeToolCallResult?)?
    public var afterToolCall: (@Sendable (AfterToolCallContext, AbortSignal?) async throws -> AfterToolCallResult?)?
    public var finishTurn: FinishTurn?
    public var prepareRequest: PrepareRequest?
    public var prepareNextTurn: (@Sendable (AbortSignal?) async throws -> AgentLoopTurnUpdate?)?
    public var prepareNextTurnWithContext: (@Sendable (PrepareNextTurnContext, AbortSignal?) async throws -> AgentLoopTurnUpdate?)?
    private let activeRun = Locked<ActiveRun?>(nil)
    /// Session identifier forwarded to providers for cache-aware backends.
    public var sessionId: String?
    public var identity: ClientIdentity?
    /// Optional per-level thinking token budgets forwarded to the stream function.
    public var thinkingBudgets: ThinkingBudgets?
    /// Preferred transport forwarded to the stream function.
    public var transport: Transport
    /// Optional cap for provider-requested retry delays.
    public var maxRetryDelayMs: Int?
    /// Tool execution strategy for assistant messages that contain multiple tool calls.
    public var toolExecution: ToolExecutionMode

    /// Swift: throws when `streamFn` is nil and no default stream function is configured
    /// (upstream's `getDefaultStreamFn()` throws in the constructor).
    public init(_ options: AgentOptions = AgentOptions()) throws {
        // Older compiled consumers may omit options or streamFn even though the current API requires them.
        let runtimeOptions = options
        self._state = createMutableAgentState(runtimeOptions.initialState)
        self.convertToLlm = runtimeOptions.convertToLlm ?? { defaultConvertToLlm($0) }
        self.transformContext = runtimeOptions.transformContext
        self.streamFunction = try runtimeOptions.streamFn ?? getDefaultStreamFn()
        self.getApiKey = runtimeOptions.getApiKey
        self.onPayload = runtimeOptions.onPayload
        self.onResponse = runtimeOptions.onResponse
        self.onProviderStreamEvent = runtimeOptions.onProviderStreamEvent
        self.beforeToolCall = runtimeOptions.beforeToolCall
        self.afterToolCall = runtimeOptions.afterToolCall
        self.finishTurn = runtimeOptions.finishTurn
        self.prepareRequest = runtimeOptions.prepareRequest
        self.prepareNextTurn = runtimeOptions.prepareNextTurn
        self.prepareNextTurnWithContext = runtimeOptions.prepareNextTurnWithContext
        self.steeringQueue = PendingMessageQueue(runtimeOptions.steeringMode ?? .oneAtATime)
        self.followUpQueue = PendingMessageQueue(runtimeOptions.followUpMode ?? .oneAtATime)
        self.sessionId = runtimeOptions.sessionId
        self.identity = runtimeOptions.identity
        self.thinkingBudgets = runtimeOptions.thinkingBudgets
        self.transport = runtimeOptions.transport ?? "auto"
        self.maxRetryDelayMs = runtimeOptions.maxRetryDelayMs
        self.toolExecution = runtimeOptions.toolExecution ?? .parallel
    }

    /// Run `body` on the actor, e.g. `await agent.update { $0.state.messages = [] }` or
    /// `await agent.update { $0.beforeToolCall = ... }`. (Upstream assigns the public fields directly.)
    @discardableResult
    public func update<T: Sendable>(_ body: @Sendable (isolated Agent) throws -> T) rethrows -> T {
        try body(self)
    }

    /// Subscribe to agent lifecycle events.
    ///
    /// Listener promises are awaited in subscription order and are included in
    /// the current run's settlement. Listeners also receive the active abort
    /// signal for the current run.
    ///
    /// `agent_end` is the final emitted event for a run, but the agent does not
    /// become idle until all awaited listeners for that event have settled.
    ///
    /// Swift: closures have no identity, so subscribing the same closure twice registers it twice
    /// (upstream's `Set` would keep one).
    @discardableResult
    public nonisolated func subscribe(_ listener: @escaping AgentListener) -> @Sendable () -> Void {
        let id = listeners.withLock { l -> Int in
            let id = l.nextId
            l.nextId += 1
            l.entries.append((id: id, listener: listener))
            return id
        }
        let listeners = self.listeners
        return { listeners.withLock { $0.entries.removeAll { $0.id == id } } }
    }

    /// Current agent state.
    ///
    /// Assigning `state` (inside `update`) copies `model`, `thinkingLevel`, `tools` and `messages`;
    /// the runtime-owned fields (`isStreaming`, `streamingMessage`, `pendingToolCalls`, `errorMessage`) are kept.
    public var state: AgentState {
        get { _state }
        set {
            _state.model = newValue.model
            _state.thinkingLevel = newValue.thinkingLevel
            _state.tools = newValue.tools
            _state.messages = newValue.messages
        }
    }

    /// Controls how queued steering messages are drained.
    public nonisolated var steeringMode: QueueMode {
        get { steeringQueue.mode }
        set { steeringQueue.mode = newValue }
    }

    /// Controls how queued follow-up messages are drained.
    public nonisolated var followUpMode: QueueMode {
        get { followUpQueue.mode }
        set { followUpQueue.mode = newValue }
    }

    /// Queue a message to be injected after the current assistant turn finishes.
    public nonisolated func steer(_ message: AgentMessage) {
        steeringQueue.enqueue(message)
    }

    /// Atomically withdraw one user message only while it is still queued.
    /// A false result means the loop already claimed it (or it was never queued).
    public nonisolated func withdrawSteeringMessage(_ message: UserMessage) -> Bool {
        steeringQueue.remove(message)
    }

    /// Queue a message to run only after the agent would otherwise stop.
    public nonisolated func followUp(_ message: AgentMessage) {
        followUpQueue.enqueue(message)
    }

    /// Host extension matching withdrawSteeringMessage: succeeds only before the loop claims it.
    public nonisolated func withdrawFollowUpMessage(_ message: UserMessage) -> Bool {
        followUpQueue.remove(message)
    }

    /// Remove all queued steering messages.
    public nonisolated func clearSteeringQueue() {
        steeringQueue.clear()
    }

    /// Remove all queued follow-up messages.
    public nonisolated func clearFollowUpQueue() {
        followUpQueue.clear()
    }

    /// Remove all queued steering and follow-up messages.
    public nonisolated func clearAllQueues() {
        clearSteeringQueue()
        clearFollowUpQueue()
    }

    /// Returns true when either queue still contains pending messages.
    public nonisolated func hasQueuedMessages() -> Bool {
        steeringQueue.hasItems() || followUpQueue.hasItems()
    }

    /// Preview the messages selected for the next turn without consuming them.
    public nonisolated func peekQueuedMessages() -> [AgentMessage] {
        let steering = steeringQueue.peek()
        return !steering.isEmpty ? steering : followUpQueue.peek()
    }

    /// Active abort signal for the current run, if any.
    public nonisolated var signal: AbortSignal? {
        activeRun.withLock { $0?.abortController.signal }
    }

    /// Abort the current run, if one is active.
    public nonisolated func abort() {
        activeRun.withLock { $0?.abortController }?.abort()
    }

    /// Resolve when the current run and all awaited event listeners have finished.
    ///
    /// This resolves after `agent_end` listeners settle.
    public nonisolated func waitForIdle() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let idle = activeRun.withLock { run -> Bool in
                guard run != nil else { return true }
                run!.waiters.append(continuation)
                return false
            }
            if idle { continuation.resume() }
        }
    }

    /// Clear conversation state and queues while retaining the replayed prompt/tool baseline.
    public func reset() throws {
        if activeRun.current != nil {
            throw PiError("Agent is already processing. Wait for completion before resetting.")
        }

        let baseline = getCurrentSystemMessage(_state.messages.transcriptSystemMessages)
        _state.messages = baseline.map { [.system($0)] } ?? []
        _state.isStreaming = false
        _state.streamingMessage = nil
        _state.pendingToolCalls = Set<String>()
        _state.errorMessage = nil
        clearFollowUpQueue()
        clearSteeringQueue()
    }

    /// Start a new prompt from a batch of messages.
    public func prompt(_ messages: [AgentMessage]) async throws {
        try await prompt(input: .messages(messages))
    }

    /// Start a new prompt from a single message.
    public func prompt(_ message: AgentMessage) async throws {
        try await prompt(input: .message(message))
    }

    /// Start a new prompt from text.
    public func prompt(_ input: String, images: [ImageContent]? = nil) async throws {
        try await prompt(input: .text(input), images: images)
    }

    private enum PromptInput {
        case text(String)
        case message(AgentMessage)
        case messages([AgentMessage])
    }

    private func prompt(input: PromptInput, images: [ImageContent]? = nil) async throws {
        if activeRun.current != nil {
            throw PiError(
                "Agent is already processing a prompt. Use steer() or followUp() to queue messages, or wait for completion."
            )
        }
        let messages = normalizePromptInput(input, images)
        try await runPromptMessages(messages)
    }

    /// Continue from the current transcript. The last message must be a user or tool-result message.
    public func `continue`() async throws {
        if activeRun.current != nil {
            throw PiError("Agent is already processing. Wait for completion before continuing.")
        }

        guard let lastMessage = _state.messages.last, !_state.messages.allSatisfy({ $0.role == "system" }) else {
            throw PiError("No messages to continue from")
        }

        if lastMessage.role == "assistant" {
            let queuedSteering = steeringQueue.drain()
            if !queuedSteering.isEmpty {
                try await runPromptMessages(queuedSteering, skipInitialSteeringPoll: true)
                return
            }

            let queuedFollowUps = followUpQueue.drain()
            if !queuedFollowUps.isEmpty {
                try await runPromptMessages(queuedFollowUps)
                return
            }

            throw PiError("Cannot continue from message role: assistant")
        }

        try await runContinuation()
    }

    private func normalizePromptInput(_ input: PromptInput, _ images: [ImageContent]?) -> [AgentMessage] {
        switch input {
        case .messages(let messages):
            return messages
        case .message(let message):
            return [message]
        case .text(let text):
            var content: [UserContent] = [.text(TextContent(text: text))]
            if let images, !images.isEmpty {
                content.append(contentsOf: images.map { .image($0) })
            }
            return [.user(UserMessage(content: .blocks(content), timestamp: dateNow()))]
        }
    }

    private func runPromptMessages(_ messages: [AgentMessage], skipInitialSteeringPoll: Bool = false) async throws {
        try await runWithLifecycle { agent, signal in
            _ = try await runAgentLoop(
                messages,
                agent.createContextSnapshot(),
                agent.createLoopConfig(skipInitialSteeringPoll: skipInitialSteeringPoll),
                { event in try await agent.processEvents(event) },
                signal,
                agent.streamFunction
            )
        }
    }

    private func runContinuation() async throws {
        try await runWithLifecycle { agent, signal in
            _ = try await runAgentLoopContinue(
                agent.createContextSnapshot(),
                agent.createLoopConfig(),
                { event in try await agent.processEvents(event) },
                signal,
                agent.streamFunction
            )
        }
    }

    private func createContextSnapshot() -> AgentContext {
        AgentContext(messages: _state.messages, tools: _state.tools)
    }

    private func createLoopConfig(skipInitialSteeringPoll: Bool = false) -> AgentLoopConfig {
        let skipInitialSteeringPoll = Locked(skipInitialSteeringPoll)
        var options = SimpleStreamOptions()
        options.reasoning = _state.thinkingLevel == .off ? nil : _state.thinkingLevel.thinkingLevel
        options.sessionId = sessionId
        options.identity = identity
        options.onPayload = onPayload
        options.onResponse = onResponse
        options.onProviderStreamEvent = onProviderStreamEvent
        options.transport = transport
        options.thinkingBudgets = thinkingBudgets
        options.maxRetryDelayMs = maxRetryDelayMs
        let steeringQueue = self.steeringQueue
        let followUpQueue = self.followUpQueue
        var prepareNextTurn: (@Sendable (PrepareNextTurnContext) async throws -> AgentLoopTurnUpdate?)?
        if self.prepareNextTurnWithContext != nil || self.prepareNextTurn != nil {
            prepareNextTurn = { [self] (context: PrepareNextTurnContext) async throws -> AgentLoopTurnUpdate? in
                if let prepareNextTurnWithContext = await self.prepareNextTurnWithContext {
                    return try await prepareNextTurnWithContext(context, self.signal)
                }
                return try await self.prepareNextTurn?(self.signal)
            }
        }
        let getSteeringMessages: @Sendable () async -> [AgentMessage] = {
            let skip = skipInitialSteeringPoll.withLock { skip -> Bool in
                if skip {
                    skip = false
                    return true
                }
                return false
            }
            if skip {
                return []
            }
            return steeringQueue.drain()
        }
        let getFollowUpMessages: @Sendable () async -> [AgentMessage] = { followUpQueue.drain() }
        return AgentLoopConfig(
            model: _state.model,
            options: options,
            convertToLlm: convertToLlm,
            transformContext: transformContext,
            getApiKey: getApiKey,
            finishTurn: finishTurn,
            prepareRequest: prepareRequest,
            prepareNextTurn: prepareNextTurn,
            getSteeringMessages: getSteeringMessages,
            getFollowUpMessages: getFollowUpMessages,
            toolExecution: toolExecution,
            beforeToolCall: beforeToolCall,
            afterToolCall: afterToolCall
        )
    }

    private func runWithLifecycle(
        _ executor: @Sendable (isolated Agent, AbortSignal) async throws -> Void
    ) async throws {
        let abortController = AbortController()
        let started = activeRun.withLock { run -> Bool in
            if run != nil { return false }
            run = ActiveRun(abortController: abortController)
            return true
        }
        if !started {
            throw PiError("Agent is already processing.")
        }

        _state.isStreaming = true
        _state.streamingMessage = nil
        _state.errorMessage = nil

        defer { finishRun() }
        do {
            try await executor(self, abortController.signal)
        } catch {
            try await handleRunFailure(error, abortController.signal.aborted)
        }
    }

    private func handleRunFailure(_ error: any Error, _ aborted: Bool) async throws {
        let failureMessage = AgentMessage.assistant(AssistantMessage(
            content: [.text(TextContent(text: ""))],
            api: _state.model.api,
            provider: _state.model.provider,
            model: _state.model.id,
            usage: EMPTY_USAGE,
            stopReason: aborted ? .aborted : .error,
            errorMessage: errorMessage(error),
            timestamp: dateNow()
        ))
        try await processEvents(.messageStart(message: failureMessage))
        try await processEvents(.messageEnd(message: failureMessage))
        try await processEvents(.turnEnd(message: failureMessage, toolResults: []))
        try await processEvents(.agentEnd(messages: [failureMessage]))
    }

    private func finishRun() {
        _state.isStreaming = false
        _state.streamingMessage = nil
        _state.pendingToolCalls = Set<String>()
        let run = activeRun.withLock { run -> ActiveRun? in
            defer { run = nil }
            return run
        }
        for waiter in run?.waiters ?? [] {
            waiter.resume()
        }
    }

    /// Reduce internal state for a loop event, then await listeners.
    ///
    /// `agent_end` only means no further loop events will be emitted. The run is
    /// considered idle later, after all awaited listeners for `agent_end` finish
    /// and `finishRun()` clears runtime-owned state.
    private func processEvents(_ event: AgentEvent) async throws {
        switch event {
        case .messageStart(let message):
            _state.streamingMessage = message

        case .messageUpdate(let message, _):
            _state.streamingMessage = message

        case .messageEnd(let message):
            _state.streamingMessage = nil
            _state.messages.append(message)

        case .toolExecutionStart(let toolCallId, _, _):
            var pendingToolCalls = _state.pendingToolCalls
            pendingToolCalls.insert(toolCallId)
            _state.pendingToolCalls = pendingToolCalls

        case .toolExecutionEnd(let toolCallId, _, _, _, _):
            var pendingToolCalls = _state.pendingToolCalls
            pendingToolCalls.remove(toolCallId)
            _state.pendingToolCalls = pendingToolCalls

        case .turnEnd(let message, _):
            if case .assistant(let assistant) = message, let errorMessage = assistant.errorMessage, !errorMessage.isEmpty {
                _state.errorMessage = errorMessage
            }

        case .agentEnd:
            _state.streamingMessage = nil

        case .agentStart, .turnStart, .toolExecutionUpdate:
            break
        }

        guard let signal = activeRun.withLock({ $0?.abortController.signal }) else {
            throw PiError("Agent listener invoked outside active run")
        }
        // `for (const listener of this.listeners)`: Set iteration visits listeners added during
        // iteration and skips ones removed before they are reached.
        var lastId = -1
        while let next = listeners.withLock({ l in l.entries.first { $0.id > lastId } }) {
            lastId = next.id
            try await next.listener(event, signal)
        }
    }
}
