import Foundation
import PiAI

// Port of packages/agent/src/types.ts

/// Stream function used by the agent loop. `Models.streamSimple` satisfies
/// this shape.
///
/// The loop passes a normalized transcript: the system prompt and tool
/// declarations are carried by the transcript's system messages, never by
/// `context.systemPrompt` or `context.tools`.
///
/// Contract:
/// - Must not throw or return a rejected promise for request/model/runtime failures.
/// - Must return an AssistantMessageEventStream.
/// - Failures must be encoded in the returned stream via protocol events and a
///   final AssistantMessage with stopReason "error" or "aborted" and errorMessage.
///
/// Swift: `AssistantMessageEventStream | Promise<AssistantMessageEventStream>` -> `async throws`.
public typealias StreamFn = @Sendable (Model, TranscriptContext, SimpleStreamOptions?) async throws -> AssistantMessageEventStream

/// Configuration for how tool calls from a single assistant message are executed.
///
/// - "sequential": each tool call is prepared, executed, and finalized before the next one starts.
/// - "parallel": tool calls are prepared sequentially, then allowed tools execute concurrently.
///   `tool_execution_end` is emitted in tool completion order after each tool is finalized,
///   while tool-result message artifacts are emitted later in assistant source order.
public enum ToolExecutionMode: String, Sendable, Hashable {
    case sequential
    case parallel
}

/// Controls how many queued user messages are injected when the agent loop reaches a queue drain point.
///
/// - "all": drain and inject every queued message at that point.
/// - "one-at-a-time": drain and inject only the oldest queued message, leaving the rest queued for later drain points.
public enum QueueMode: String, Sendable, Hashable {
    case all
    case oneAtATime = "one-at-a-time"
}

/// A single tool call content block emitted by an assistant message.
public typealias AgentToolCall = ToolCall

/// Result returned from `beforeToolCall`.
///
/// Returning `{ block: true }` prevents the tool from executing. The loop emits an error tool result instead.
/// `reason` becomes the text shown in that error result. If omitted, a default blocked message is used.
public struct BeforeToolCallResult: Sendable {
    public var block: Bool?
    public var reason: String?
    /// Hint that the agent should stop after the current tool batch when this call is blocked.
    /// Early termination only happens when every finalized tool result in the batch sets this to true.
    public var terminate: Bool?
    public init(block: Bool? = nil, reason: String? = nil, terminate: Bool? = nil) {
        self.block = block; self.reason = reason; self.terminate = terminate
    }
}

/// Partial override returned from `afterToolCall`.
///
/// Merge semantics are field-by-field:
/// - `content`: if provided, replaces the tool result content array in full
/// - `details`: if provided, replaces the tool result details value in full
/// - `isError`: if provided, replaces the tool result error flag
/// - `usage`: if provided, replaces the tool result usage
/// - `terminate`: if provided, replaces the early-termination hint
/// - `structuredContent`: if provided, replaces the structured content. If `content` is provided
///   without it, the structured content is dropped, because it may no longer match the content.
///   Return it along with `content` to keep it.
///
/// Other omitted fields keep the original executed tool result values.
/// There is no deep merge for `content`, `details`, or `usage`.
public struct AfterToolCallResult: Sendable {
    public var content: [UserContent]?
    public var details: JsonValue?
    public var structuredContent: JsonValue?
    public var isError: Bool?
    /// Usage from the final tool execution itself, if available. Not used for main LLM context accounting.
    public var usage: Usage?
    /// Hint that the agent should stop after the current tool batch.
    /// Early termination only happens when every finalized tool result in the batch sets this to true.
    public var terminate: Bool?
    public init(content: [UserContent]? = nil, details: JsonValue? = nil, structuredContent: JsonValue? = nil, isError: Bool? = nil, usage: Usage? = nil, terminate: Bool? = nil) {
        self.content = content; self.details = details; self.structuredContent = structuredContent
        self.isError = isError; self.usage = usage; self.terminate = terminate
    }
}

/// Validated tool arguments shared by reference with `beforeToolCall`.
///
/// Swift: upstream passes the validated arguments object itself, and hooks may mutate it in place
/// (the mutated value is executed without revalidation). JSON values are value types in Swift, so the
/// arguments live in this box; assign `value` to change what the tool receives.
public final class ToolCallArguments: @unchecked Sendable {
    private let storage: Locked<JsonValue>
    public init(_ value: JsonValue) { storage = Locked(value) }
    public var value: JsonValue {
        get { storage.current }
        set { storage.withLock { $0 = newValue } }
    }
    /// Read or write one top-level argument.
    public subscript(key: String) -> JsonValue? {
        get { storage.current[key] }
        set { storage.withLock { $0[key] = newValue } }
    }
}

/// Context passed to `beforeToolCall`.
public struct BeforeToolCallContext: Sendable {
    /// Set by the session adapter for a tool-issued nested call.
    public var parentToolCallId: String? = nil
    /// The assistant message that requested the tool call.
    public var assistantMessage: AssistantMessage
    /// The raw tool call block from `assistantMessage.content`.
    public var toolCall: AgentToolCall
    /// Validated tool arguments for the target tool schema.
    public var args: ToolCallArguments
    /// Current agent context at the time the tool call is prepared.
    public var context: AgentContext
    public init(assistantMessage: AssistantMessage, toolCall: AgentToolCall, args: ToolCallArguments, context: AgentContext) {
        self.assistantMessage = assistantMessage; self.toolCall = toolCall; self.args = args; self.context = context
    }
}

/// Context passed to `afterToolCall`.
public struct AfterToolCallContext: Sendable {
    /// Set by the session adapter for a tool-issued nested call.
    public var parentToolCallId: String? = nil
    /// The assistant message that requested the tool call.
    public var assistantMessage: AssistantMessage
    /// The raw tool call block from `assistantMessage.content`.
    public var toolCall: AgentToolCall
    /// Validated tool arguments for the target tool schema.
    public var args: JsonValue
    /// The executed tool result before any `afterToolCall` overrides are applied.
    public var result: AgentToolResult
    /// Whether the executed tool result is currently treated as an error.
    public var isError: Bool
    /// Current agent context at the time the tool call is finalized.
    public var context: AgentContext
    public init(assistantMessage: AssistantMessage, toolCall: AgentToolCall, args: JsonValue, result: AgentToolResult, isError: Bool, context: AgentContext) {
        self.assistantMessage = assistantMessage; self.toolCall = toolCall; self.args = args; self.result = result; self.isError = isError; self.context = context
    }
}

/// Context passed to completed-turn callbacks.
public struct AgentTurnContext: Sendable {
    /// The assistant message that completed the turn.
    public var message: AssistantMessage
    /// Tool result messages emitted for the completed turn.
    public var toolResults: [ToolResultMessage]
    /// Current agent context after the turn's assistant message and tool results have been appended.
    public var context: AgentContext
    /// Messages that this loop invocation will return if it exits at this point. Prompt runs include the initial prompt messages; continuation runs do not include pre-existing context messages.
    public var newMessages: [AgentMessage]
    public init(message: AssistantMessage, toolResults: [ToolResultMessage], context: AgentContext, newMessages: [AgentMessage]) {
        self.message = message; self.toolResults = toolResults; self.context = context; self.newMessages = newMessages
    }
}

/// Decision returned by `FinishTurn`. Returning nil preserves normal scheduling.
public enum AgentTurnDecision: String, Sendable, Hashable {
    case `continue`
    case end

    public var action: String { rawValue }
}

/// Called after a completed assistant turn and all of its tool-result messages, but before `turn_end`.
/// On a normal turn, `.continue` ensures one next provider request. Tool-result, steering, or
/// follow-up scheduling can satisfy that request and adds no extra request; otherwise the loop continues once
/// with the current context. Error and aborted responses remain hard exits.
public typealias FinishTurn = @Sendable (AgentTurnContext, AbortSignal?) async throws -> AgentTurnDecision?

/// Replacement runtime state used by the agent loop before starting another provider request.
public struct AgentLoopTurnUpdate: Sendable {
    /// Context for the next provider request.
    public var context: AgentContext?
    /// Messages to append before the next provider request, with normal lifecycle events.
    public var messages: [AgentMessage]?
    /// Model for the next provider request.
    public var model: Model?
    /// Thinking level for the next provider request.
    public var thinkingLevel: AgentThinkingLevel?
    public init(context: AgentContext? = nil, messages: [AgentMessage]? = nil, model: Model? = nil, thinkingLevel: AgentThinkingLevel? = nil) {
        self.context = context; self.messages = messages; self.model = model; self.thinkingLevel = thinkingLevel
    }
}

/// Runtime state available immediately before a conversational provider request.
public struct PrepareRequestContext: Sendable {
    public var context: AgentContext
    public var model: Model
    public var thinkingLevel: AgentThinkingLevel
    public init(context: AgentContext, model: Model, thinkingLevel: AgentThinkingLevel) {
        self.context = context; self.model = model; self.thinkingLevel = thinkingLevel
    }
}

/// Replacement runtime state for the provider request being prepared.
/// (`Omit<AgentLoopTurnUpdate, "messages">`)
public struct AgentRequestUpdate: Sendable {
    public var context: AgentContext?
    public var model: Model?
    public var thinkingLevel: AgentThinkingLevel?
    public init(context: AgentContext? = nil, model: Model? = nil, thinkingLevel: AgentThinkingLevel? = nil) {
        self.context = context; self.model = model; self.thinkingLevel = thinkingLevel
    }
}

/// Called immediately before every conversational provider request, including the first.
/// Pending messages have already been appended and emitted when this callback runs.
public typealias PrepareRequest = @Sendable (PrepareRequestContext, AbortSignal?) async throws -> AgentRequestUpdate?

/// `interface PrepareNextTurnContext extends AgentTurnContext {}`
public typealias PrepareNextTurnContext = AgentTurnContext

/// `AgentLoopConfig extends SimpleStreamOptions`.
///
/// Swift: the inherited stream options live in `options`; `@dynamicMemberLookup` forwards them, so
/// `config.reasoning`, `config.apiKey`, `config.sessionId` read and write like upstream.
///
/// Callbacks whose upstream contract is "must not throw or reject" are non-throwing here.
@dynamicMemberLookup
public struct AgentLoopConfig: Sendable {
    public var model: Model

    /// The inherited `SimpleStreamOptions` fields.
    public var options: SimpleStreamOptions

    /// Converts AgentMessage[] to LLM-compatible Message[] before each LLM call.
    ///
    /// Each AgentMessage must be converted to a SystemMessage, UserMessage, AssistantMessage, or ToolResultMessage
    /// that the LLM can understand. AgentMessages that cannot be converted (e.g., UI-only notifications,
    /// status messages) should be filtered out.
    ///
    /// Contract: must not throw or reject. Return a safe fallback value instead.
    public var convertToLlm: @Sendable ([AgentMessage]) async -> [Message]

    /// Optional transform applied to the context before `convertToLlm`.
    ///
    /// Use this for operations that work at the AgentMessage level:
    /// - Context window management (pruning old messages)
    /// - Injecting context from external sources
    ///
    /// Contract: must not throw or reject. Return the original messages or another
    /// safe fallback value instead.
    public var transformContext: (@Sendable ([AgentMessage], AbortSignal?) async -> [AgentMessage])?

    /// Resolves an API key dynamically for each LLM call.
    ///
    /// Useful for short-lived OAuth tokens (e.g., GitHub Copilot) that may expire
    /// during long-running tool execution phases.
    ///
    /// Contract: must not throw or reject. Return nil when no key is available.
    public var getApiKey: (@Sendable (String) async -> String?)?

    /// Called after the assistant message and all tool-result messages have been emitted, immediately before `turn_end`.
    /// `.end` ends the run without polling queues or preparing another request.
    /// On a normal turn, `.continue` ensures one next provider request. Tool-result, steering, or
    /// follow-up scheduling can satisfy that request and adds no extra request; otherwise the loop continues once
    /// with the current context. Returning nil preserves normal scheduling. Error and aborted responses remain
    /// hard exits.
    public var finishTurn: FinishTurn?

    /// Called immediately before every conversational provider request, including the first.
    /// Pending messages have already been appended. The returned context, model, and thinking level
    /// replace the runtime values for this and later requests in the run. This hook does not poll queues.
    public var prepareRequest: PrepareRequest?

    /// Called after `turn_end` when the loop will continue, immediately before the next turn starts.
    /// Return replacement context/model/thinking state or messages to append to affect that turn.
    /// Return nil to keep using the current context/config.
    public var prepareNextTurn: (@Sendable (PrepareNextTurnContext) async throws -> AgentLoopTurnUpdate?)?

    /// Returns steering messages to inject into the conversation mid-run.
    ///
    /// Called after the current assistant turn finishes executing its tool calls, unless `finishTurn` ends the run.
    /// If messages are returned, they are added to the context before the next LLM call.
    /// Tool calls from the current assistant message are not skipped.
    ///
    /// Use this for "steering" the agent while it's working.
    ///
    /// Contract: must not throw or reject. Return [] when no steering messages are available.
    public var getSteeringMessages: (@Sendable () async -> [AgentMessage])?

    /// Returns follow-up messages to process after the agent would otherwise stop.
    ///
    /// Called when the agent has no more tool calls and no steering messages.
    /// If messages are returned, they're added to the context and the agent
    /// continues with another turn.
    ///
    /// Use this for follow-up messages that should wait until the agent finishes.
    ///
    /// Contract: must not throw or reject. Return [] when no follow-up messages are available.
    public var getFollowUpMessages: (@Sendable () async -> [AgentMessage])?

    /// Tool execution mode.
    /// - "sequential": execute tool calls one by one
    /// - "parallel": preflight tool calls sequentially, then execute allowed tools concurrently;
    ///   emit `tool_execution_end` in tool completion order after each tool is finalized,
    ///   then emit tool-result message artifacts later in assistant source order
    ///
    /// Default: "parallel"
    public var toolExecution: ToolExecutionMode?

    /// Called before a tool is executed, after arguments have been validated.
    ///
    /// Return `block: true` to prevent execution. The loop emits an error tool result instead.
    /// A blocked result can also set `terminate: true` to participate in the batch early-termination rule.
    /// The hook receives the agent abort signal and is responsible for honoring it.
    public var beforeToolCall: (@Sendable (BeforeToolCallContext, AbortSignal?) async throws -> BeforeToolCallResult?)?

    /// Called after a tool finishes executing, before `tool_execution_end` and tool-result message events are emitted.
    ///
    /// Return an `AfterToolCallResult` to override parts of the executed tool result:
    /// - `content` replaces the full content array
    /// - `details` replaces the full details payload
    /// - `isError` replaces the error flag
    /// - `usage` replaces the tool result usage
    /// - `terminate` replaces the early-termination hint
    ///
    /// Any omitted fields keep their original values. No deep merge is performed.
    /// The hook receives the agent abort signal and is responsible for honoring it.
    public var afterToolCall: (@Sendable (AfterToolCallContext, AbortSignal?) async throws -> AfterToolCallResult?)?

    public init(
        model: Model,
        options: SimpleStreamOptions = SimpleStreamOptions(),
        convertToLlm: @escaping @Sendable ([AgentMessage]) async -> [Message],
        transformContext: (@Sendable ([AgentMessage], AbortSignal?) async -> [AgentMessage])? = nil,
        getApiKey: (@Sendable (String) async -> String?)? = nil,
        finishTurn: FinishTurn? = nil,
        prepareRequest: PrepareRequest? = nil,
        prepareNextTurn: (@Sendable (PrepareNextTurnContext) async throws -> AgentLoopTurnUpdate?)? = nil,
        getSteeringMessages: (@Sendable () async -> [AgentMessage])? = nil,
        getFollowUpMessages: (@Sendable () async -> [AgentMessage])? = nil,
        toolExecution: ToolExecutionMode? = nil,
        beforeToolCall: (@Sendable (BeforeToolCallContext, AbortSignal?) async throws -> BeforeToolCallResult?)? = nil,
        afterToolCall: (@Sendable (AfterToolCallContext, AbortSignal?) async throws -> AfterToolCallResult?)? = nil
    ) {
        self.model = model; self.options = options; self.convertToLlm = convertToLlm; self.transformContext = transformContext
        self.getApiKey = getApiKey; self.finishTurn = finishTurn; self.prepareRequest = prepareRequest; self.prepareNextTurn = prepareNextTurn
        self.getSteeringMessages = getSteeringMessages; self.getFollowUpMessages = getFollowUpMessages; self.toolExecution = toolExecution
        self.beforeToolCall = beforeToolCall; self.afterToolCall = afterToolCall
    }

    public subscript<T>(dynamicMember keyPath: WritableKeyPath<SimpleStreamOptions, T>) -> T {
        get { options[keyPath: keyPath] }
        set { options[keyPath: keyPath] = newValue }
    }
}

/// Thinking/reasoning level for models that support it.
/// Note: "xhigh" and "max" are only supported by selected model families. Use model
/// thinking-level metadata from PiAI to detect support for a concrete model.
///
/// Swift: upstream's agent `ThinkingLevel` ("off" | ... | "max") is PiAI's `ModelThinkingLevel`;
/// the PiAI name `ThinkingLevel` (without "off") is the provider-side `reasoning` level.
public typealias AgentThinkingLevel = ModelThinkingLevel

/// A custom app message (upstream: `CustomAgentMessages` extended by declaration merging).
///
/// `role` is the app-defined discriminator (e.g. "notification", "custom", "bashExecution");
/// `payload` carries the remaining fields. `convertToLlm` decides how (or whether) it reaches the model.
public struct CustomAgentMessage: Sendable, Hashable {
    public var role: String
    public var payload: JsonValue
    public var timestamp: Int
    public init(role: String, payload: JsonValue = .emptyObject, timestamp: Int = dateNow()) {
        self.role = role; self.payload = payload; self.timestamp = timestamp
    }
}

/// AgentMessage: Union of LLM messages + custom messages.
/// This abstraction allows apps to add custom message types while maintaining
/// type safety and compatibility with the base LLM messages.
public enum AgentMessage: Sendable {
    case system(SystemMessage)
    case user(UserMessage)
    case assistant(AssistantMessage)
    case toolResult(ToolResultMessage)
    case custom(CustomAgentMessage)

    public init(_ message: Message) {
        switch message {
        case .system(let m): self = .system(m)
        case .user(let m): self = .user(m)
        case .assistant(let m): self = .assistant(m)
        case .toolResult(let m): self = .toolResult(m)
        }
    }

    public var role: String {
        switch self {
        case .system: return "system"
        case .user: return "user"
        case .assistant: return "assistant"
        case .toolResult: return "toolResult"
        case .custom(let m): return m.role
        }
    }

    public var timestamp: Int {
        switch self {
        case .system(let m): return m.timestamp
        case .user(let m): return m.timestamp
        case .assistant(let m): return m.timestamp
        case .toolResult(let m): return m.timestamp
        case .custom(let m): return m.timestamp
        }
    }

    /// The LLM message, or nil for custom messages.
    public var llmMessage: Message? {
        switch self {
        case .system(let m): return .system(m)
        case .user(let m): return .user(m)
        case .assistant(let m): return .assistant(m)
        case .toolResult(let m): return .toolResult(m)
        case .custom: return nil
        }
    }

    public var systemMessage: SystemMessage? { if case .system(let m) = self { return m } else { return nil } }
    public var userMessage: UserMessage? { if case .user(let m) = self { return m } else { return nil } }
    public var assistantMessage: AssistantMessage? { if case .assistant(let m) = self { return m } else { return nil } }
    public var toolResultMessage: ToolResultMessage? { if case .toolResult(let m) = self { return m } else { return nil } }
    public var customMessage: CustomAgentMessage? { if case .custom(let m) = self { return m } else { return nil } }
}

extension Array where Element == AgentMessage {
    /// The system messages of an agent transcript as LLM messages. The transcript replay helpers
    /// (`getCurrentTools`, `getCurrentSystemMessage`, ...) only read system messages.
    var transcriptSystemMessages: [Message] { compactMap { $0.systemMessage.map(Message.system) } }
}

/// Public agent state.
///
/// Swift: a value snapshot. Mutate it inside `Agent.update { $0.state... }`.
public struct AgentState: Sendable {
    /// Current system prompt, replayed from the transcript's system messages.
    ///
    /// Read-only: to change the prompt, append a system message with `content` or `sections`.
    /// In `initialState`, this seeds the leading system message.
    public var systemPrompt: String { getCurrentSystemPrompt(messages.transcriptSystemMessages) }
    /// Active model used for future turns.
    public var model: Model
    /// Requested reasoning level for future turns.
    public var thinkingLevel: AgentThinkingLevel
    /// Executable tools.
    ///
    /// Differences from the tools declared in the transcript are announced to the model
    /// with a system message before the next request.
    public var tools: [AgentTool]
    /// Conversation transcript.
    ///
    /// System messages in the transcript carry the prompt and tool declarations.
    public var messages: [AgentMessage]
    /// True while the agent is processing a prompt or continuation.
    ///
    /// This remains true until awaited `agent_end` listeners settle.
    public internal(set) var isStreaming: Bool
    /// Partial assistant message for the current streamed response, if any.
    public internal(set) var streamingMessage: AgentMessage?
    /// Tool call ids currently executing.
    public internal(set) var pendingToolCalls: Set<String>
    /// Error message from the most recent failed or aborted assistant turn, if any.
    public internal(set) var errorMessage: String?

    init(model: Model, thinkingLevel: AgentThinkingLevel, tools: [AgentTool], messages: [AgentMessage]) {
        self.model = model; self.thinkingLevel = thinkingLevel; self.tools = tools; self.messages = messages
        isStreaming = false; streamingMessage = nil; pendingToolCalls = []; errorMessage = nil
    }
}

/// Final or partial result produced by a tool.
public struct AgentToolResult: Sendable, Hashable {
    /// Text or image content returned to the model.
    public var content: [UserContent]
    /// Arbitrary structured details for logs or UI rendering.
    public var details: JsonValue?
    /// Machine-readable result matching the tool's `outputSchema`, for programmatic callers. Not sent
    /// to the model; `content` remains the model-facing result.
    public var structuredContent: JsonValue?
    /// Usage from the final tool execution itself, if available. Not used for main LLM context accounting.
    public var usage: Usage?
    /// Report a failure without throwing. The model sees `content` as an error result, like a thrown
    /// error, but `details` and `structuredContent` are kept for the UI and programmatic callers.
    public var isError: Bool?
    /// Hint that the agent should stop after the current tool batch.
    /// Early termination only happens when every finalized tool result in the batch sets this to true.
    public var terminate: Bool?
    public init(content: [UserContent], details: JsonValue? = nil, structuredContent: JsonValue? = nil, usage: Usage? = nil, isError: Bool? = nil, terminate: Bool? = nil) {
        self.content = content; self.details = details; self.structuredContent = structuredContent
        self.usage = usage; self.isError = isError; self.terminate = terminate
    }
}

/// Final outcome of a tool call after hooks ran.
public struct AgentToolCallOutcome: Sendable {
    public var toolCall: AgentToolCall
    public var result: AgentToolResult
    public var isError: Bool
    /// Milliseconds `execute()` took, measured with a monotonic clock; absent when the tool did not run.
    public var durationMs: Int?
    public init(toolCall: AgentToolCall, result: AgentToolResult, isError: Bool, durationMs: Int? = nil) {
        self.toolCall = toolCall; self.result = result; self.isError = isError; self.durationMs = durationMs
    }
}

/// Callback used by tools to stream partial execution updates.
///
/// The callback is scoped to the current `execute()` invocation. Calls made after
/// the tool promise settles are ignored.
public typealias AgentToolUpdateCallback = @Sendable (AgentToolResult) -> Void

/// Recovery policy for an effect whose durable intent exists but whose outcome is unknown.
public enum AgentToolReplay: String, Sendable, Hashable {
    case never
    case safe
}

/// Tool definition used by the agent runtime (`AgentTool extends Tool`).
public struct AgentTool: Sendable {
    // Tool
    public var name: String
    public var description: String
    /// JSON Schema of the parameters.
    public var parameters: JsonValue
    public var constrainedSampling: ConstrainedSamplingConfig??

    /// Human-readable label for UI display.
    public var label: String
    /// Optional compatibility shim for raw tool-call arguments before schema validation.
    /// Must return an object that matches `parameters`.
    public var prepareArguments: (@Sendable (JsonObject) throws -> JsonObject)?
    /// JSON Schema of `structuredContent` in successful results. Tools that declare it should always
    /// set `structuredContent`.
    public var outputSchema: JsonValue?
    /// Execute the tool call. Throw on failure, or return a result with `isError: true`; do not only
    /// describe the failure in `content`.
    public var execute: @Sendable (_ toolCallId: String, _ params: JsonValue, _ signal: AbortSignal?, _ onUpdate: AgentToolUpdateCallback?) async throws -> AgentToolResult
    /// Recovery policy for an effect whose durable intent exists but whose outcome is unknown.
    public var replay: AgentToolReplay?
    /// Per-tool execution mode override.
    /// - "sequential": this tool must execute one at a time with other tool calls.
    /// - "parallel": this tool can execute concurrently with other tool calls.
    ///
    /// If omitted, the default execution mode applies.
    public var executionMode: ToolExecutionMode?

    public init(
        name: String,
        label: String,
        description: String,
        parameters: JsonValue,
        constrainedSampling: ConstrainedSamplingConfig?? = nil,
        prepareArguments: (@Sendable (JsonObject) throws -> JsonObject)? = nil,
        outputSchema: JsonValue? = nil,
        replay: AgentToolReplay? = nil,
        executionMode: ToolExecutionMode? = nil,
        execute: @escaping @Sendable (_ toolCallId: String, _ params: JsonValue, _ signal: AbortSignal?, _ onUpdate: AgentToolUpdateCallback?) async throws -> AgentToolResult
    ) {
        self.name = name; self.label = label; self.description = description; self.parameters = parameters
        self.constrainedSampling = constrainedSampling; self.prepareArguments = prepareArguments; self.outputSchema = outputSchema
        self.replay = replay; self.executionMode = executionMode; self.execute = execute
    }

    /// The `Tool` part of this definition (what `AgentTool extends Tool` gives upstream).
    public var asTool: Tool {
        Tool(name: name, description: description, parameters: parameters, constrainedSampling: constrainedSampling)
    }
}

/// Context snapshot passed into the low-level agent loop.
public struct AgentContext: Sendable {
    /// Transcript visible to the model.
    public var messages: [AgentMessage]
    /// Tools available for execution in this run.
    public var tools: [AgentTool]?
    public init(messages: [AgentMessage] = [], tools: [AgentTool]? = nil) { self.messages = messages; self.tools = tools }
}

/// Events emitted by the Agent for UI updates.
///
/// `agent_end` is the last event emitted for a run, but awaited `Agent.subscribe()`
/// listeners for that event are still part of run settlement. The agent becomes
/// idle only after those listeners finish.
public enum AgentEvent: Sendable {
    // Agent lifecycle
    case agentStart
    case agentEnd(messages: [AgentMessage])
    // Turn lifecycle - a turn is one assistant response + any tool calls/results
    case turnStart
    case turnEnd(message: AgentMessage, toolResults: [ToolResultMessage])
    // Message lifecycle - emitted for system, user, assistant, and toolResult messages
    case messageStart(message: AgentMessage)
    // Only emitted for assistant messages during streaming
    case messageUpdate(message: AgentMessage, assistantMessageEvent: AssistantMessageEvent)
    case messageEnd(message: AgentMessage)
    // Tool execution lifecycle
    case toolExecutionStart(toolCallId: String, toolName: String, args: JsonObject)
    case toolExecutionUpdate(toolCallId: String, toolName: String, args: JsonObject, partialResult: AgentToolResult)
    /// `durationMs`: milliseconds `execute()` took, measured with a monotonic clock; absent when the tool did not run.
    case toolExecutionEnd(toolCallId: String, toolName: String, result: AgentToolResult, isError: Bool, durationMs: Int?)

    public var type: String {
        switch self {
        case .agentStart: return "agent_start"
        case .agentEnd: return "agent_end"
        case .turnStart: return "turn_start"
        case .turnEnd: return "turn_end"
        case .messageStart: return "message_start"
        case .messageUpdate: return "message_update"
        case .messageEnd: return "message_end"
        case .toolExecutionStart: return "tool_execution_start"
        case .toolExecutionUpdate: return "tool_execution_update"
        case .toolExecutionEnd: return "tool_execution_end"
        }
    }
}
