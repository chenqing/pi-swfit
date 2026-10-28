import Foundation
import PiAI

// Port of packages/agent/src/agent-loop.ts
//
// Agent loop that works with AgentMessage throughout.
// Transforms to Message[] only at the LLM call boundary.

public let DEFAULT_AGENT_IDENTITY = ClientIdentity(attribution: .some(PI_ATTRIBUTION))

public typealias AgentEventSink = @Sendable (AgentEvent) async throws -> Void

/// Start an agent loop with a new prompt message.
/// The prompt is added to the context and events are emitted for it.
///
/// Swift: when the loop throws (a hook or the stream function threw, or no default stream function is
/// configured), upstream's promise rejects and the returned stream never ends. Here the stream is ended
/// with an empty result instead, so consumers never hang.
public func agentLoop(
    _ prompts: [AgentMessage],
    _ context: AgentContext,
    _ config: AgentLoopConfig,
    _ signal: AbortSignal?,
    _ streamFn: StreamFn? = nil
) -> EventStream<AgentEvent, [AgentMessage]> {
    let stream = createAgentStream()

    Task {
        do {
            let messages = try await runAgentLoop(
                prompts,
                context,
                config,
                { event in stream.push(event) },
                signal,
                streamFn
            )
            stream.end(messages)
        } catch {
            stream.end([])
        }
    }

    return stream
}

/// Continue an agent loop from the current context without adding a new message.
/// Used for retries - context already has user message or tool results.
///
/// **Important:** The last message in context must convert to a `user` or `toolResult` message
/// via `convertToLlm`. If it doesn't, the LLM provider will reject the request.
/// This cannot be validated here since `convertToLlm` is only called once per turn.
public func agentLoopContinue(
    _ context: AgentContext,
    _ config: AgentLoopConfig,
    _ signal: AbortSignal?,
    _ streamFn: StreamFn? = nil
) throws -> EventStream<AgentEvent, [AgentMessage]> {
    if context.messages.isEmpty {
        throw PiError("Cannot continue: no messages in context")
    }

    if context.messages[context.messages.count - 1].role == "assistant" {
        throw PiError("Cannot continue from message role: assistant")
    }

    let stream = createAgentStream()

    Task {
        do {
            let messages = try await runAgentLoopContinue(
                context,
                config,
                { event in stream.push(event) },
                signal,
                streamFn
            )
            stream.end(messages)
        } catch {
            stream.end([])
        }
    }

    return stream
}

public func runAgentLoop(
    _ prompts: [AgentMessage],
    _ context: AgentContext,
    _ config: AgentLoopConfig,
    _ emit: @escaping AgentEventSink,
    _ signal: AbortSignal?,
    _ streamFn: StreamFn? = nil
) async throws -> [AgentMessage] {
    let initialMessages = declareToolChanges(context, prompts)
    var newMessages: [AgentMessage] = initialMessages
    var currentContext = context
    currentContext.messages = context.messages + initialMessages

    try await emit(.agentStart)
    try await emit(.turnStart)
    for message in initialMessages {
        try await emit(.messageStart(message: message))
        try await emit(.messageEnd(message: message))
    }

    try await runLoop(currentContext, &newMessages, config, signal, emit, try streamFn ?? getDefaultStreamFn())
    return newMessages
}

/// Swift: upstream's `{ ...context }` shares the caller's `messages` array, so a continuation run appends
/// to it in place. Swift arrays are values; the caller's context is not mutated.
public func runAgentLoopContinue(
    _ context: AgentContext,
    _ config: AgentLoopConfig,
    _ emit: @escaping AgentEventSink,
    _ signal: AbortSignal?,
    _ streamFn: StreamFn? = nil
) async throws -> [AgentMessage] {
    if context.messages.isEmpty {
        throw PiError("Cannot continue: no messages in context")
    }

    if context.messages[context.messages.count - 1].role == "assistant" {
        throw PiError("Cannot continue from message role: assistant")
    }

    var newMessages: [AgentMessage] = []
    let currentContext = context

    try await emit(.agentStart)
    try await emit(.turnStart)

    try await runLoop(currentContext, &newMessages, config, signal, emit, try streamFn ?? getDefaultStreamFn())
    return newMessages
}

private func createAgentStream() -> EventStream<AgentEvent, [AgentMessage]> {
    EventStream<AgentEvent, [AgentMessage]>(
        isComplete: { event in
            if case .agentEnd = event { return true }
            return false
        },
        extractResult: { event in
            if case .agentEnd(let messages) = event { return messages }
            return []
        }
    )
}

/// `thinkingLevel === undefined ? config.reasoning : thinkingLevel === "off" ? undefined : thinkingLevel`
private func resolveReasoning(_ thinkingLevel: AgentThinkingLevel?, _ current: ThinkingLevel?) -> ThinkingLevel? {
    guard let thinkingLevel else { return current }
    return thinkingLevel == .off ? nil : thinkingLevel.thinkingLevel
}

/// Main loop logic shared by agentLoop and agentLoopContinue.
private func runLoop(
    _ initialContext: AgentContext,
    _ newMessages: inout [AgentMessage],
    _ initialConfig: AgentLoopConfig,
    _ signal: AbortSignal?,
    _ emit: @escaping AgentEventSink,
    _ streamFunction: StreamFn
) async throws {
    var currentContext = initialContext
    var config = initialConfig
    var lastCompletedTurn: PrepareNextTurnContext?
    var explicitContinuation = false
    // Check for steering messages at start (user may have typed while waiting)
    var pendingMessages: [AgentMessage] = await config.getSteeringMessages?() ?? []

    // Outer loop: continues when queued follow-up messages arrive after agent would stop
    while true {
        var hasMoreToolCalls = true

        // Inner loop: process tool calls and steering messages
        while hasMoreToolCalls || !pendingMessages.isEmpty {
            var preparedMessages: [AgentMessage] = []
            if let lastCompletedTurn {
                if let nextTurnSnapshot = try await config.prepareNextTurn?(lastCompletedTurn) {
                    currentContext = nextTurnSnapshot.context ?? currentContext
                    preparedMessages = nextTurnSnapshot.messages ?? []
                    config.model = nextTurnSnapshot.model ?? config.model
                    config.reasoning = resolveReasoning(nextTurnSnapshot.thinkingLevel, config.reasoning)
                }
                // Preparation can be long-running (for example, compaction). Pick up steering
                // queued while it ran. Only poll again if the earlier poll returned nothing;
                // otherwise one-at-a-time mode would deliver two messages in this turn.
                if pendingMessages.isEmpty {
                    pendingMessages = await config.getSteeringMessages?() ?? []
                }
                try await emit(.turnStart)
            }

            // Process prepared and queued messages before the next assistant response.
            for message in declareToolChanges(currentContext, preparedMessages + pendingMessages) {
                try await emit(.messageStart(message: message))
                try await emit(.messageEnd(message: message))
                currentContext.messages.append(message)
                newMessages.append(message)
            }
            pendingMessages = []

            let requestUpdate = try await config.prepareRequest?(
                PrepareRequestContext(
                    context: currentContext,
                    model: config.model,
                    thinkingLevel: config.reasoning.map(ModelThinkingLevel.init) ?? .off
                ),
                signal
            )
            if let requestUpdate {
                currentContext = requestUpdate.context ?? currentContext
                config.model = requestUpdate.model ?? config.model
                config.reasoning = resolveReasoning(requestUpdate.thinkingLevel, config.reasoning)
            }

            // Stream assistant response
            let message = try await streamAssistantResponse(&currentContext, config, signal, emit, streamFunction)
            newMessages.append(.assistant(message))

            if message.stopReason == .error || message.stopReason == .aborted {
                let turn = PrepareNextTurnContext(
                    message: message,
                    toolResults: [],
                    context: currentContext,
                    newMessages: newMessages
                )
                lastCompletedTurn = turn
                _ = try await config.finishTurn?(turn, signal)
                try await emit(.turnEnd(message: .assistant(message), toolResults: []))
                try await emit(.agentEnd(messages: newMessages))
                return
            }

            // Check for tool calls
            let toolCalls = message.content.compactMap(\.toolCallContent)

            var toolResults: [ToolResultMessage] = []
            hasMoreToolCalls = false
            if !toolCalls.isEmpty {
                // A "length" stop means the output was cut off by the token limit, so
                // every tool call in the message may carry truncated arguments. Fail
                // them all instead of executing potentially borked calls.
                let executedToolBatch = message.stopReason == .length
                    ? try await failToolCallsFromTruncatedMessage(toolCalls, emit)
                    : try await executeToolCalls(currentContext, message, config, signal, emit)
                toolResults.append(contentsOf: executedToolBatch.messages)
                hasMoreToolCalls = !executedToolBatch.terminate

                for result in toolResults {
                    currentContext.messages.append(.toolResult(result))
                    newMessages.append(.toolResult(result))
                }
            }

            let turn = PrepareNextTurnContext(
                message: message,
                toolResults: toolResults,
                context: currentContext,
                newMessages: newMessages
            )
            lastCompletedTurn = turn
            let decision = try await config.finishTurn?(turn, signal)
            try await emit(.turnEnd(message: .assistant(message), toolResults: toolResults))

            if decision == .end {
                try await emit(.agentEnd(messages: newMessages))
                return
            }

            explicitContinuation = decision == .continue
            pendingMessages = await config.getSteeringMessages?() ?? []
            if hasMoreToolCalls || !pendingMessages.isEmpty {
                explicitContinuation = false
            }
        }

        // Agent would stop here. Check for follow-up messages.
        let followUpMessages = await config.getFollowUpMessages?() ?? []
        if !followUpMessages.isEmpty {
            // Set as pending so inner loop processes them
            explicitContinuation = false
            pendingMessages = followUpMessages
            continue
        }

        // No natural request was selected, so fulfill the continuation decision with one context-only turn.
        if explicitContinuation {
            explicitContinuation = false
            continue
        }

        // No more messages, exit
        break
    }

    try await emit(.agentEnd(messages: newMessages))
}

/// Declare tool loadout changes to the model.
///
/// `context.tools` is what the runtime can execute; the transcript's system messages declare
/// what the model may call. Before each request the difference becomes `toolsAdded` and
/// `toolsRemoved` on a system message. When a pending system message exists, its tool fields
/// are treated as intent and replaced with the delta between the committed transcript and
/// the executable set, so replay always yields exactly `context.tools`. Otherwise a new
/// system message is inserted before the first non-system pending message.
private func declareToolChanges(_ context: AgentContext, _ pendingMessages: [AgentMessage]) -> [AgentMessage] {
    var systemIndex = -1
    var i = pendingMessages.count - 1
    while i >= 0 {
        if pendingMessages[i].systemMessage != nil {
            systemIndex = i
            break
        }
        i -= 1
    }
    let pending: SystemMessage? = systemIndex >= 0 ? pendingMessages[systemIndex].systemMessage : nil
    let baseline: [AgentMessage]
    if let pending {
        baseline = pendingMessages.enumerated().map { index, message in
            index == systemIndex ? .system(withToolChanges(pending, NO_CHANGES)) : message
        }
    } else {
        baseline = pendingMessages
    }
    let changes = getToolStateChanges(
        getCurrentTools((context.messages + baseline).transcriptSystemMessages),
        (context.tools ?? []).map { toToolDeclaration($0.asTool) }
    )
    let unchanged = changes.toolsAdded.isEmpty && changes.toolsRemoved.isEmpty

    if let pending {
        // Keep the caller's message object when it already declares no tool changes.
        if unchanged && (pending.toolsAdded?.isEmpty ?? true) && (pending.toolsRemoved?.isEmpty ?? true) { return pendingMessages }
        return baseline.enumerated().map { index, message in
            index == systemIndex ? .system(withToolChanges(pending, changes)) : message
        }
    }
    if unchanged { return pendingMessages }
    let update = withToolChanges(SystemMessage(content: .string(""), timestamp: dateNow()), changes)
    let insertIndex = pendingMessages.firstIndex { $0.systemMessage == nil }
    let index = insertIndex ?? pendingMessages.count
    return Array(pendingMessages[..<index]) + [.system(update)] + Array(pendingMessages[index...])
}

private let NO_CHANGES = ToolStateChanges(toolsAdded: [], toolsRemoved: [])

/// Copy a system message with its tool fields replaced by `changes`; empty lists omit the field.
private func withToolChanges(_ message: SystemMessage, _ changes: ToolStateChanges) -> SystemMessage {
    var rest = message
    rest.toolsAdded = changes.toolsAdded.isEmpty ? nil : changes.toolsAdded
    rest.toolsRemoved = changes.toolsRemoved.isEmpty ? nil : changes.toolsRemoved
    return rest
}

/// JavaScript `value || fallback` for optional strings: an empty string is falsy.
private func truthy(_ value: String?) -> String? {
    guard let value, !value.isEmpty else { return nil }
    return value
}

/// Stream an assistant response from the LLM.
/// This is where AgentMessage[] gets transformed to Message[] for the LLM.
private func streamAssistantResponse(
    _ context: inout AgentContext,
    _ config: AgentLoopConfig,
    _ signal: AbortSignal?,
    _ emit: @escaping AgentEventSink,
    _ streamFunction: StreamFn
) async throws -> AssistantMessage {
    // Apply context transform if configured (AgentMessage[] → AgentMessage[])
    var messages = context.messages
    if let transformContext = config.transformContext {
        messages = await transformContext(messages, signal)
    }

    // Convert to LLM-compatible messages (AgentMessage[] → Message[])
    let llmMessages = await config.convertToLlm(messages)

    let llmContext = normalizeContext(Context(messages: llmMessages))

    // Resolve API key (important for expiring tokens)
    var resolvedApiKey: String?
    if let getApiKey = config.getApiKey {
        resolvedApiKey = await getApiKey(config.model.provider)
    }
    resolvedApiKey = truthy(resolvedApiKey) ?? config.apiKey

    var options = config.options
    options.identity = mergeClientIdentity(DEFAULT_AGENT_IDENTITY, config.identity)
    options.apiKey = resolvedApiKey
    options.signal = signal
    let response = try await streamFunction(config.model, llmContext, options)
    // Record the requested level, whichever stream function answered.
    let thinkingLevel = config.reasoning.map(ModelThinkingLevel.init) ?? .off
    // Swift: upstream's `await response.result()` never settles when a stream ends without a final
    // message (a broken StreamFn contract), hanging the run. Here that fails the run instead.
    let result: @Sendable () async throws -> AssistantMessage = {
        guard var message = await response.resultIfAny() else {
            throw PiError("Assistant message stream ended without a final message")
        }
        message.thinkingLevel = thinkingLevel
        return message
    }

    var partialMessage: AssistantMessage?
    var addedPartial = false

    for await event in response {
        switch event {
        case .start(let partial):
            partialMessage = partial
            context.messages.append(.assistant(partial))
            addedPartial = true
            try await emit(.messageStart(message: .assistant(partial)))

        case .textStart, .textDelta, .textEnd,
             .thinkingStart, .thinkingDelta, .thinkingEnd,
             .toolcallStart, .toolcallDelta, .toolcallEnd:
            if partialMessage != nil {
                let partial = event.message
                partialMessage = partial
                context.messages[context.messages.count - 1] = .assistant(partial)
                try await emit(.messageUpdate(message: .assistant(partial), assistantMessageEvent: event))
            }

        case .done, .error:
            let finalMessage = try await result()
            if addedPartial {
                context.messages[context.messages.count - 1] = .assistant(finalMessage)
            } else {
                context.messages.append(.assistant(finalMessage))
            }
            if !addedPartial {
                try await emit(.messageStart(message: .assistant(finalMessage)))
            }
            try await emit(.messageEnd(message: .assistant(finalMessage)))
            return finalMessage
        }
    }

    let finalMessage = try await result()
    if addedPartial {
        context.messages[context.messages.count - 1] = .assistant(finalMessage)
    } else {
        context.messages.append(.assistant(finalMessage))
        try await emit(.messageStart(message: .assistant(finalMessage)))
    }
    try await emit(.messageEnd(message: .assistant(finalMessage)))
    return finalMessage
}

/// Fail all tool calls from an assistant message that was truncated by the
/// output token limit. Streamed tool-call arguments are finalized with a
/// best-effort JSON salvage parser, so a truncated message can yield tool calls
/// whose arguments parse and validate but are silently incomplete. None of them
/// are safe to execute; report each as an error so the model can re-issue them.
private func failToolCallsFromTruncatedMessage(
    _ toolCalls: [AgentToolCall],
    _ emit: @escaping AgentEventSink
) async throws -> ExecutedToolCallBatch {
    var messages: [ToolResultMessage] = []
    for toolCall in toolCalls {
        try await emit(.toolExecutionStart(toolCallId: toolCall.id, toolName: toolCall.name, args: toolCall.arguments))
        let finalized = FinalizedToolCallOutcome(
            toolCall: toolCall,
            result: createErrorToolResult(
                "Tool call \"\(toolCall.name)\" was not executed: the response hit the output token limit, so its arguments may be truncated. Re-issue the tool call with complete arguments."
            ),
            isError: true
        )
        try await emitToolExecutionEnd(finalized, emit)
        let toolResultMessage = createToolResultMessage(finalized)
        try await emitToolResultMessage(toolResultMessage, emit)
        messages.append(toolResultMessage)
    }
    return ExecutedToolCallBatch(messages: messages, terminate: false)
}

/// Execute tool calls from an assistant message.
private func executeToolCalls(
    _ currentContext: AgentContext,
    _ assistantMessage: AssistantMessage,
    _ config: AgentLoopConfig,
    _ signal: AbortSignal?,
    _ emit: @escaping AgentEventSink
) async throws -> ExecutedToolCallBatch {
    let toolCalls = assistantMessage.content.compactMap(\.toolCallContent)
    let hasSequentialToolCall = toolCalls.contains { tc in
        currentContext.tools?.first(where: { $0.name == tc.name })?.executionMode == .sequential
    }
    if config.toolExecution == .sequential || hasSequentialToolCall {
        return try await executeToolCallsSequential(currentContext, assistantMessage, toolCalls, config, signal, emit)
    }
    return try await executeToolCallsParallel(currentContext, assistantMessage, toolCalls, config, signal, emit)
}

private struct ExecutedToolCallBatch: Sendable {
    var messages: [ToolResultMessage]
    var terminate: Bool
}

private func executeToolCallsSequential(
    _ currentContext: AgentContext,
    _ assistantMessage: AssistantMessage,
    _ toolCalls: [AgentToolCall],
    _ config: AgentLoopConfig,
    _ signal: AbortSignal?,
    _ emit: @escaping AgentEventSink
) async throws -> ExecutedToolCallBatch {
    var finalizedCalls: [FinalizedToolCallOutcome] = []
    var messages: [ToolResultMessage] = []
    let hooks = ToolCallHooks(config)

    for toolCall in toolCalls {
        try await emit(.toolExecutionStart(toolCallId: toolCall.id, toolName: toolCall.name, args: toolCall.arguments))

        let preparation = await prepareToolCall(currentContext, assistantMessage, toolCall, hooks, signal)
        let finalized: FinalizedToolCallOutcome
        switch preparation {
        case .immediate(let result, let isError):
            finalized = FinalizedToolCallOutcome(toolCall: toolCall, result: result, isError: isError)
        case .prepared(let prepared):
            let executed = try await executePreparedToolCall(prepared, signal, emitToolExecutionUpdate(toolCall, emit))
            finalized = await finalizeExecutedToolCall(currentContext, assistantMessage, prepared, executed, hooks, signal)
        }

        try await emitToolExecutionEnd(finalized, emit)
        let toolResultMessage = createToolResultMessage(finalized)
        try await emitToolResultMessage(toolResultMessage, emit)
        finalizedCalls.append(finalized)
        messages.append(toolResultMessage)

        if signal?.aborted == true {
            break
        }
    }

    return ExecutedToolCallBatch(messages: messages, terminate: shouldTerminateToolBatch(finalizedCalls))
}

private func executeToolCallsParallel(
    _ currentContext: AgentContext,
    _ assistantMessage: AssistantMessage,
    _ toolCalls: [AgentToolCall],
    _ config: AgentLoopConfig,
    _ signal: AbortSignal?,
    _ emit: @escaping AgentEventSink
) async throws -> ExecutedToolCallBatch {
    var finalizedCalls: [FinalizedToolCallEntry] = []
    let hooks = ToolCallHooks(config)

    for toolCall in toolCalls {
        try await emit(.toolExecutionStart(toolCallId: toolCall.id, toolName: toolCall.name, args: toolCall.arguments))

        let preparation = await prepareToolCall(currentContext, assistantMessage, toolCall, hooks, signal)
        guard case .prepared(let prepared) = preparation else {
            guard case .immediate(let result, let isError) = preparation else { continue }
            let finalized = FinalizedToolCallOutcome(toolCall: toolCall, result: result, isError: isError)
            try await emitToolExecutionEnd(finalized, emit)
            finalizedCalls.append(.finalized(finalized))
            if signal?.aborted == true {
                break
            }
            continue
        }

        finalizedCalls.append(.deferred({
            if signal?.aborted == true {
                let finalized = FinalizedToolCallOutcome(
                    toolCall: toolCall,
                    result: createErrorToolResult("Operation aborted"),
                    isError: true
                )
                try await emitToolExecutionEnd(finalized, emit)
                return finalized
            }
            let executed = try await executePreparedToolCall(prepared, signal, emitToolExecutionUpdate(toolCall, emit))
            let finalized = await finalizeExecutedToolCall(currentContext, assistantMessage, prepared, executed, hooks, signal)
            try await emitToolExecutionEnd(finalized, emit)
            return finalized
        }))
        if signal?.aborted == true {
            break
        }
    }

    let orderedFinalizedCalls = try await promiseAll(finalizedCalls.map { entry in
        switch entry {
        case .finalized(let finalized): return { finalized }
        case .deferred(let run): return run
        }
    })
    var messages: [ToolResultMessage] = []
    for finalized in orderedFinalizedCalls {
        let toolResultMessage = createToolResultMessage(finalized)
        try await emitToolResultMessage(toolResultMessage, emit)
        messages.append(toolResultMessage)
    }

    return ExecutedToolCallBatch(messages: messages, terminate: shouldTerminateToolBatch(orderedFinalizedCalls))
}

/// `Promise.all`: runs every operation concurrently, resolves with results in input order, and
/// rejects with the first failure in time (the remaining operations keep running unobserved).
private func promiseAll<T: Sendable>(_ operations: [@Sendable () async throws -> T]) async throws -> [T] {
    if operations.isEmpty { return [] }
    return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<[T], any Error>) in
        let state = Locked(PromiseAllState<T>(results: Array(repeating: nil, count: operations.count), remaining: operations.count))
        for (index, operation) in operations.enumerated() {
            Task {
                do {
                    let value = try await operation()
                    let completed: [T]? = state.withLock { s in
                        s.results[index] = value
                        s.remaining -= 1
                        if s.remaining == 0 && !s.settled {
                            s.settled = true
                            return s.results.map { $0! }
                        }
                        return nil
                    }
                    if let completed { continuation.resume(returning: completed) }
                } catch {
                    let first = state.withLock { s -> Bool in
                        if s.settled { return false }
                        s.settled = true
                        return true
                    }
                    if first { continuation.resume(throwing: error) }
                }
            }
        }
    }
}

private struct PromiseAllState<T> {
    var results: [T?]
    var remaining: Int
    var settled = false
}

private struct PreparedToolCall: Sendable {
    var toolCall: AgentToolCall
    var tool: AgentTool
    var args: ToolCallArguments
}

private enum ToolCallPreparation: Sendable {
    /// `{ kind: "prepared", ... }`
    case prepared(PreparedToolCall)
    /// `{ kind: "immediate", result, isError }`
    case immediate(result: AgentToolResult, isError: Bool)
}

private struct ExecutedToolCallOutcome: Sendable {
    var result: AgentToolResult
    var isError: Bool
    var durationMs: Int
}

private typealias FinalizedToolCallOutcome = AgentToolCallOutcome

/// The `beforeToolCall` and `afterToolCall` hooks of `AgentLoopConfig`.
/// (`Pick<AgentLoopConfig, "beforeToolCall" | "afterToolCall">`)
public struct ToolCallHooks: Sendable {
    public var beforeToolCall: (@Sendable (BeforeToolCallContext, AbortSignal?) async throws -> BeforeToolCallResult?)?
    public var afterToolCall: (@Sendable (AfterToolCallContext, AbortSignal?) async throws -> AfterToolCallResult?)?
    public init(
        beforeToolCall: (@Sendable (BeforeToolCallContext, AbortSignal?) async throws -> BeforeToolCallResult?)? = nil,
        afterToolCall: (@Sendable (AfterToolCallContext, AbortSignal?) async throws -> AfterToolCallResult?)? = nil
    ) {
        self.beforeToolCall = beforeToolCall; self.afterToolCall = afterToolCall
    }
    init(_ config: AgentLoopConfig) {
        self.init(beforeToolCall: config.beforeToolCall, afterToolCall: config.afterToolCall)
    }
}

public typealias ToolUpdateSink = @Sendable (AgentToolResult) async throws -> Void

private enum FinalizedToolCallEntry: Sendable {
    case finalized(FinalizedToolCallOutcome)
    case deferred(@Sendable () async throws -> FinalizedToolCallOutcome)
}

private func shouldTerminateToolBatch(_ finalizedCalls: [FinalizedToolCallOutcome]) -> Bool {
    !finalizedCalls.isEmpty && finalizedCalls.allSatisfy { $0.result.terminate == true }
}

private func prepareToolCallArguments(_ tool: AgentTool, _ toolCall: AgentToolCall) throws -> AgentToolCall {
    guard let prepareArguments = tool.prepareArguments else {
        return toolCall
    }
    let preparedArguments = try prepareArguments(toolCall.arguments)
    if preparedArguments == toolCall.arguments {
        return toolCall
    }
    var prepared = toolCall
    prepared.arguments = preparedArguments
    return prepared
}

private func prepareToolCall(
    _ currentContext: AgentContext,
    _ assistantMessage: AssistantMessage,
    _ toolCall: AgentToolCall,
    _ config: ToolCallHooks,
    _ signal: AbortSignal?,
    _ toolsOverride: [AgentTool]? = nil
) async -> ToolCallPreparation {
    let tools = toolsOverride ?? currentContext.tools ?? []
    guard let tool = tools.first(where: { $0.name == toolCall.name }) else {
        return .immediate(result: createErrorToolResult("Tool \(toolCall.name) not found"), isError: true)
    }

    do {
        let preparedToolCall = try prepareToolCallArguments(tool, toolCall)
        let validatedArgs = ToolCallArguments(try validateToolArguments(tool.asTool, preparedToolCall))
        if let beforeToolCall = config.beforeToolCall {
            let beforeResult = try await beforeToolCall(
                BeforeToolCallContext(
                    assistantMessage: assistantMessage,
                    toolCall: toolCall,
                    args: validatedArgs,
                    context: currentContext
                ),
                signal
            )
            if signal?.aborted == true {
                return .immediate(result: createErrorToolResult("Operation aborted"), isError: true)
            }
            if beforeResult?.block == true {
                var result = createErrorToolResult(truthy(beforeResult?.reason) ?? "Tool execution was blocked")
                if beforeResult?.terminate == true {
                    result.terminate = true
                }
                return .immediate(result: result, isError: true)
            }
        }
        if signal?.aborted == true {
            return .immediate(result: createErrorToolResult("Operation aborted"), isError: true)
        }
        return .prepared(PreparedToolCall(toolCall: toolCall, tool: tool, args: validatedArgs))
    } catch {
        return .immediate(result: createErrorToolResult(errorMessage(error)), isError: true)
    }
}

private func emitToolExecutionUpdate(_ toolCall: AgentToolCall, _ emit: @escaping AgentEventSink) -> ToolUpdateSink {
    { partialResult in
        try await emit(.toolExecutionUpdate(
            toolCallId: toolCall.id,
            toolName: toolCall.name,
            args: toolCall.arguments,
            partialResult: partialResult
        ))
    }
}

/// Options for `runToolCall`.
public struct RunToolCallOptions: Sendable {
    /// Tools the call resolves against.
    public var tools: [AgentTool]
    /// Passed to the hooks as the message that issued the call.
    public var assistantMessage: AssistantMessage
    /// Passed to the hooks as the current agent context.
    public var context: AgentContext
    public var signal: AbortSignal?
    public var onUpdate: ToolUpdateSink?
    public var beforeToolCall: (@Sendable (BeforeToolCallContext, AbortSignal?) async throws -> BeforeToolCallResult?)?
    public var afterToolCall: (@Sendable (AfterToolCallContext, AbortSignal?) async throws -> AfterToolCallResult?)?
    public init(
        tools: [AgentTool],
        assistantMessage: AssistantMessage,
        context: AgentContext,
        signal: AbortSignal? = nil,
        onUpdate: ToolUpdateSink? = nil,
        beforeToolCall: (@Sendable (BeforeToolCallContext, AbortSignal?) async throws -> BeforeToolCallResult?)? = nil,
        afterToolCall: (@Sendable (AfterToolCallContext, AbortSignal?) async throws -> AfterToolCallResult?)? = nil
    ) {
        self.tools = tools; self.assistantMessage = assistantMessage; self.context = context; self.signal = signal
        self.onUpdate = onUpdate; self.beforeToolCall = beforeToolCall; self.afterToolCall = afterToolCall
    }
}

/// Run one tool call through the same steps as a model-issued call: argument preparation, schema
/// validation, `beforeToolCall`, execution, and `afterToolCall`. Emits no events and adds no
/// messages. Tools that call other tools use this so the hooks (for example permission checks)
/// apply to those calls too.
///
/// Never rejects for tool failures: unknown tools, validation errors, blocked calls, and thrown
/// errors come back as `isError: true`.
public func runToolCall(_ toolCall: AgentToolCall, _ options: RunToolCallOptions) async throws -> AgentToolCallOutcome {
    let hooks = ToolCallHooks(beforeToolCall: options.beforeToolCall, afterToolCall: options.afterToolCall)
    let preparation = await prepareToolCall(options.context, options.assistantMessage, toolCall, hooks, options.signal, options.tools)
    switch preparation {
    case .immediate(let result, let isError):
        return AgentToolCallOutcome(toolCall: toolCall, result: result, isError: isError)
    case .prepared(let prepared):
        let executed = try await executePreparedToolCall(prepared, options.signal, options.onUpdate ?? { _ in })
        return await finalizeExecutedToolCall(options.context, options.assistantMessage, prepared, executed, hooks, options.signal)
    }
}

/// Ordered sink for `onUpdate` calls of one `execute()` invocation.
///
/// Upstream calls `emit` synchronously inside `onUpdate`, so updates are delivered in call order and
/// collected as promises that are awaited once the tool settles. Here each update runs in a task chained
/// after the previous one, which keeps the call order; `finish()` awaits the chain and rethrows the
/// first emission failure (`Promise.all(updateEvents)`).
private final class ToolUpdateQueue: Sendable {
    private struct State {
        var acceptingUpdates = true
        var last: Task<Void, Never>?
        var error: (any Error)?
    }

    private let state = Locked(State())
    private let onUpdate: ToolUpdateSink

    init(_ onUpdate: @escaping ToolUpdateSink) { self.onUpdate = onUpdate }

    func push(_ partialResult: AgentToolResult) {
        let onUpdate = self.onUpdate
        let state = self.state
        state.withLock { s in
            if !s.acceptingUpdates { return }
            let previous = s.last
            s.last = Task {
                await previous?.value
                do {
                    try await onUpdate(partialResult)
                } catch {
                    state.withLock { s in if s.error == nil { s.error = error } }
                }
            }
        }
    }

    func stopAccepting() {
        state.withLock { $0.acceptingUpdates = false }
    }

    func finish() async throws {
        let last = state.withLock { $0.last }
        await last?.value
        if let error = state.withLock({ $0.error }) { throw error }
    }
}

private func executePreparedToolCall(
    _ prepared: PreparedToolCall,
    _ signal: AbortSignal?,
    _ onUpdate: @escaping ToolUpdateSink
) async throws -> ExecutedToolCallOutcome {
    let updateEvents = ToolUpdateQueue(onUpdate)
    let startedAt = performanceNow()
    let elapsed = { Int((performanceNow() - startedAt).rounded()) }
    defer { updateEvents.stopAccepting() }

    let result: AgentToolResult
    do {
        result = try await prepared.tool.execute(
            prepared.toolCall.id,
            prepared.args.value,
            signal,
            { partialResult in updateEvents.push(partialResult) }
        )
    } catch {
        let durationMs = elapsed()
        updateEvents.stopAccepting()
        try await updateEvents.finish()
        return ExecutedToolCallOutcome(
            result: createErrorToolResult(errorMessage(error)),
            isError: true,
            durationMs: durationMs
        )
    }
    let durationMs = elapsed()
    updateEvents.stopAccepting()
    // Upstream: a failed update emission here jumps to the catch block, which awaits the same
    // updates again and rethrows; the net effect is that the failure propagates.
    try await updateEvents.finish()
    return ExecutedToolCallOutcome(result: result, isError: result.isError == true, durationMs: durationMs)
}

private func finalizeExecutedToolCall(
    _ currentContext: AgentContext,
    _ assistantMessage: AssistantMessage,
    _ prepared: PreparedToolCall,
    _ executed: ExecutedToolCallOutcome,
    _ config: ToolCallHooks,
    _ signal: AbortSignal?
) async -> FinalizedToolCallOutcome {
    var result = executed.result
    var isError = executed.isError

    if let afterToolCall = config.afterToolCall {
        do {
            let afterResult = try await afterToolCall(
                AfterToolCallContext(
                    assistantMessage: assistantMessage,
                    toolCall: prepared.toolCall,
                    args: prepared.args.value,
                    result: result,
                    isError: isError,
                    context: currentContext
                ),
                signal
            )
            if let afterResult {
                // Structured content not replaced along with the content may no longer match it.
                let structuredContent = afterResult.structuredContent ?? (afterResult.content != nil ? nil : result.structuredContent)
                result.content = afterResult.content ?? result.content
                result.details = afterResult.details ?? result.details
                result.usage = afterResult.usage ?? result.usage
                result.terminate = afterResult.terminate ?? result.terminate
                result.structuredContent = structuredContent
                isError = afterResult.isError ?? isError
            }
        } catch {
            result = createErrorToolResult(errorMessage(error))
            isError = true
        }
    }

    return FinalizedToolCallOutcome(
        toolCall: prepared.toolCall,
        result: result,
        isError: isError,
        durationMs: executed.durationMs
    )
}

private func createErrorToolResult(_ message: String) -> AgentToolResult {
    AgentToolResult(content: [.text(TextContent(text: message))], details: .emptyObject)
}

private func emitToolExecutionEnd(_ finalized: FinalizedToolCallOutcome, _ emit: @escaping AgentEventSink) async throws {
    try await emit(.toolExecutionEnd(
        toolCallId: finalized.toolCall.id,
        toolName: finalized.toolCall.name,
        result: finalized.result,
        isError: finalized.isError,
        durationMs: finalized.durationMs
    ))
}

private func createToolResultMessage(_ finalized: FinalizedToolCallOutcome) -> ToolResultMessage {
    ToolResultMessage(
        toolCallId: finalized.toolCall.id,
        toolName: finalized.toolCall.name,
        // Untyped tools (JS extensions) can return results without content; normalize
        // so the null never enters session history or provider payloads.
        content: finalized.result.content,
        details: finalized.result.details,
        usage: finalized.result.usage,
        isError: finalized.isError,
        timestamp: dateNow(),
        durationMs: finalized.durationMs
    )
}

private func emitToolResultMessage(_ toolResultMessage: ToolResultMessage, _ emit: @escaping AgentEventSink) async throws {
    try await emit(.messageStart(message: .toolResult(toolResultMessage)))
    try await emit(.messageEnd(message: .toolResult(toolResultMessage)))
}
