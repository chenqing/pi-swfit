import Foundation

// Port of packages/ai/src/types.ts and providers/model-schema.ts (type parts).
//
// Conventions for the Swift port:
// - TS `interface` -> `struct` (value semantics; Sendable). TS unions of object shapes -> `enum`
//   with associated values. String-literal unions that upstream extends with `(string & {})`
//   -> `String` typealias plus constants.
// - Optional TS fields -> Swift optionals; property names are identical to upstream.
// - Timestamps are integer Unix milliseconds (`Date.now()`).
// - Every type converts to/from the exact upstream JSON shape (`json` / `init(json:)`), used for
//   session files and for byte-stable request bodies.

// MARK: - Identifiers

public typealias Api = String
public enum KnownApi {
    public static let openaiCompletions: Api = "openai-completions"
    public static let mistralConversations: Api = "mistral-conversations"
    public static let openaiResponses: Api = "openai-responses"
    public static let azureOpenaiResponses: Api = "azure-openai-responses"
    public static let openaiCodexResponses: Api = "openai-codex-responses"
    public static let anthropicMessages: Api = "anthropic-messages"
    public static let bedrockConverseStream: Api = "bedrock-converse-stream"
    public static let googleGenerativeAi: Api = "google-generative-ai"
    public static let googleVertex: Api = "google-vertex"
    public static let piMessages: Api = "pi-messages"
}

public typealias ProviderId = String
public typealias ToolChoice = String // "auto" | "none"
public typealias SamplingParams = JsonObject
public typealias SamplingParamsByThinkingLevel = [ModelThinkingLevel: SamplingParams]

// MARK: - model-schema.ts

public enum ThinkingLevel: String, Sendable, Hashable, CaseIterable, Codable {
    case minimal, low, medium, high, xhigh, max
}

public enum ModelThinkingLevel: String, Sendable, Hashable, CaseIterable, Codable {
    case off, minimal, low, medium, high, xhigh, max

    public init(_ level: ThinkingLevel) { self = ModelThinkingLevel(rawValue: level.rawValue)! }
    public var thinkingLevel: ThinkingLevel? { ThinkingLevel(rawValue: rawValue) }
}

public let THINKING_LEVELS: [ThinkingLevel] = ThinkingLevel.allCases
public let MODEL_THINKING_LEVELS: [ModelThinkingLevel] = ModelThinkingLevel.allCases

public typealias ModelInputModality = String // "text" | "image"

public enum CacheRetention: String, Sendable, Hashable, Codable {
    case none, short, long
}

/// Provider value sent for each thinking level. `.some(nil)` (JSON null) marks a level unsupported.
public typealias ThinkingLevelMap = [ModelThinkingLevel: String?]

/// Best-effort prompt cache lifetime in seconds for the short and long retention tiers.
public struct ModelPromptCache: Sendable, Hashable {
    public var short: Double?
    public var long: Double?
    public init(short: Double? = nil, long: Double? = nil) { self.short = short; self.long = long }
}

public struct ModelCostTier: Sendable, Hashable {
    public var inputTokensAbove: Double
    public var input: Double
    public var output: Double
    public var cacheRead: Double
    public var cacheWrite: Double
    public init(inputTokensAbove: Double, input: Double, output: Double, cacheRead: Double, cacheWrite: Double) {
        self.inputTokensAbove = inputTokensAbove; self.input = input; self.output = output; self.cacheRead = cacheRead; self.cacheWrite = cacheWrite
    }
}

/// USD per million tokens.
public struct ModelCost: Sendable, Hashable {
    public var input: Double
    public var output: Double
    public var cacheRead: Double
    public var cacheWrite: Double
    public var tiers: [ModelCostTier]?
    public init(input: Double = 0, output: Double = 0, cacheRead: Double = 0, cacheWrite: Double = 0, tiers: [ModelCostTier]? = nil) {
        self.input = input; self.output = output; self.cacheRead = cacheRead; self.cacheWrite = cacheWrite; self.tiers = tiers
    }
}

public struct ModelImageResizeOptions: Sendable, Hashable {
    public var maxWidth: Int?
    public var maxHeight: Int?
    public var maxBytes: Int?
    public var jpegQuality: Int?
    public init(maxWidth: Int? = nil, maxHeight: Int? = nil, maxBytes: Int? = nil, jpegQuality: Int? = nil) {
        self.maxWidth = maxWidth; self.maxHeight = maxHeight; self.maxBytes = maxBytes; self.jpegQuality = jpegQuality
    }
}

public struct ModelImageInputLimits: Sendable, Hashable {
    public var resize: ModelImageResizeOptions?
    public var maxPerMessage: Int?
    public var maxPerRequest: Int?
    public init(resize: ModelImageResizeOptions? = nil, maxPerMessage: Int? = nil, maxPerRequest: Int? = nil) {
        self.resize = resize; self.maxPerMessage = maxPerMessage; self.maxPerRequest = maxPerRequest
    }
}

public struct ModelInputLimits: Sendable, Hashable {
    public var maxRequestBytes: Int?
    public var images: ModelImageInputLimits?
    public init(maxRequestBytes: Int? = nil, images: ModelImageInputLimits? = nil) { self.maxRequestBytes = maxRequestBytes; self.images = images }
}

// MARK: - Options

/// Token budgets for each thinking level (token-based providers only)
public struct ThinkingBudgets: Sendable, Hashable {
    public var minimal: Int?
    public var low: Int?
    public var medium: Int?
    public var high: Int?
    public init(minimal: Int? = nil, low: Int? = nil, medium: Int? = nil, high: Int? = nil) {
        self.minimal = minimal; self.low = low; self.medium = medium; self.high = high
    }
}

public typealias Transport = String // "sse" | "websocket" | "websocket-cached" | "auto"

/// Provider-scoped environment overrides. Values take precedence over the process environment.
public typealias ProviderEnv = [String: String]
/// Ordered custom headers. A nil value suppresses a provider/API default header with the same name.
public typealias ProviderHeaders = [(String, String?)]

public struct ProviderResponse: Sendable {
    public var status: Int
    public var headers: [String: String]
    public init(status: Int, headers: [String: String]) { self.status = status; self.headers = headers }
}

/// Optional callback for inspecting or replacing provider payloads before sending. Return nil to keep the payload.
public typealias OnPayload = @Sendable (JsonValue, Model) async throws -> JsonValue?
public typealias OnResponse = @Sendable (ProviderResponse, Model) async throws -> Void
public typealias OnProviderStreamEvent = @Sendable (JsonValue, Model) async -> Void

/// Authentication, HTTP transport, and lifecycle callbacks shared by provider requests.
public struct StreamOptions: Sendable {
    public var signal: AbortSignal?
    public var apiKey: String?
    /// Optional fetch implementation for provider HTTP requests. Defaults to `defaultFetch`.
    public var fetch: FetchFunction?
    /// Provider-scoped environment values. These take precedence over the process environment.
    public var env: ProviderEnv?
    public var onPayload: OnPayload?
    /// Invoked after an HTTP response is received and before its body stream is consumed.
    public var onResponse: OnResponse?
    /// Observer for each parsed provider stream event before Pi normalization (adapter-owned, read-only).
    public var onProviderStreamEvent: OnProviderStreamEvent?
    /// Custom HTTP headers merged with provider defaults; caller values override defaults.
    public var headers: ProviderHeaders?
    /// HTTP request timeout in milliseconds (SDK clients default to 10 minutes).
    public var timeoutMs: Int?
    /// Maximum retry attempts for client-side retries (SDK clients default to 2).
    public var maxRetries: Int?
    /// Maximum delay to wait for a server-requested retry. Default 60000; 0 disables the cap.
    public var maxRetryDelayMs: Int?
    public var temperature: Double?
    /// Arbitrary sampling parameters merged into the request body as-is (OpenAI-compatible adapters only).
    public var samplingParams: SamplingParams?
    public var maxTokens: Int?
    public var transport: Transport?
    /// Prompt cache retention preference. Default: "short".
    public var cacheRetention: CacheRetention?
    public var sessionId: String?
    public var identity: ClientIdentity?
    public var websocketConnectTimeoutMs: Int?
    public var metadata: JsonObject?
    /// Provider-specific options (`ProviderStreamOptions = StreamOptions & Record<string, unknown>`).
    public var extra: JsonObject

    // SimpleStreamOptions
    /// Provider-neutral tool selection for simple requests.
    public var toolChoice: ToolChoice?
    public var reasoning: ThinkingLevel?
    /// Ask a capable provider to return a durable handle and continue the request asynchronously.
    public var deferred: JsonValue?
    /// Custom token budgets for thinking levels (token-based providers only)
    public var thinkingBudgets: ThinkingBudgets?

    // DeferredFetchOptions
    /// Maximum provider long-poll duration in milliseconds. Defaults to 0, which performs one status check.
    public var wait: Int?

    public init() { extra = JsonObject() }
}

/// `SimpleStreamOptions extends StreamOptions`: the same struct; simple-only fields are ignored by `stream()`.
public typealias SimpleStreamOptions = StreamOptions
public typealias ProviderStreamOptions = StreamOptions
/// `DeferredFetchOptions extends ProviderRequestOptions`: the same struct (`wait`).
public typealias DeferredFetchOptions = StreamOptions
public typealias DeferredCancelOptions = StreamOptions

// MARK: - Content

public struct TextSignatureV1: Sendable, Hashable {
    public var v: Int = 1
    public var id: String
    public var phase: String? // "commentary" | "final_answer"
    public init(id: String, phase: String? = nil) { self.id = id; self.phase = phase }
}

public struct TextContent: Sendable, Hashable {
    public var type: String { "text" }
    public var text: String
    /// e.g., for OpenAI responses, message metadata (legacy id string or TextSignatureV1 JSON)
    public var textSignature: String?
    public init(text: String, textSignature: String? = nil) { self.text = text; self.textSignature = textSignature }
}

public struct ThinkingContent: Sendable, Hashable {
    public var type: String { "thinking" }
    public var thinking: String
    /// Provider-specific opaque or serialized reasoning replay data
    public var thinkingSignature: String?
    /// When true, the thinking content was redacted by safety filters; the encrypted payload is in `thinkingSignature`.
    public var redacted: Bool?
    public init(thinking: String, thinkingSignature: String? = nil, redacted: Bool? = nil) {
        self.thinking = thinking; self.thinkingSignature = thinkingSignature; self.redacted = redacted
    }
}

public struct ImageContent: Sendable, Hashable {
    public var type: String { "image" }
    /// base64 encoded image data
    public var data: String
    /// e.g., "image/jpeg", "image/png"
    public var mimeType: String
    public init(data: String, mimeType: String) { self.data = data; self.mimeType = mimeType }
}

public struct ToolCall: Sendable, Hashable {
    public var type: String { "toolCall" }
    public var id: String
    public var name: String
    public var arguments: JsonObject
    /// Google-specific: opaque signature for reusing thought context
    public var thoughtSignature: String?
    /// OpenAI Responses namespace for calls to dynamically loaded or namespaced tools.
    public var namespace: String?
    /// Set when the model's complete arguments text was not a valid JSON object. `arguments` is then `{}`.
    public var argumentsError: String?
    public init(id: String, name: String, arguments: JsonObject = JsonObject(), thoughtSignature: String? = nil, namespace: String? = nil, argumentsError: String? = nil) {
        self.id = id; self.name = name; self.arguments = arguments; self.thoughtSignature = thoughtSignature; self.namespace = namespace; self.argumentsError = argumentsError
    }
}

/// `TextContent | ThinkingContent | ToolCall`
public enum AssistantContent: Sendable, Hashable {
    case text(TextContent)
    case thinking(ThinkingContent)
    case toolCall(ToolCall)

    public var type: String {
        switch self {
        case .text: return "text"
        case .thinking: return "thinking"
        case .toolCall: return "toolCall"
        }
    }
    public var textContent: TextContent? { if case .text(let v) = self { return v } else { return nil } }
    public var thinkingContent: ThinkingContent? { if case .thinking(let v) = self { return v } else { return nil } }
    public var toolCallContent: ToolCall? { if case .toolCall(let v) = self { return v } else { return nil } }
}

/// `TextContent | ImageContent`
public enum UserContent: Sendable, Hashable {
    case text(TextContent)
    case image(ImageContent)

    public var type: String {
        switch self {
        case .text: return "text"
        case .image: return "image"
        }
    }
    public var textContent: TextContent? { if case .text(let v) = self { return v } else { return nil } }
    public var imageContent: ImageContent? { if case .image(let v) = self { return v } else { return nil } }
}

/// `string | (TextContent | ImageContent)[]`
public enum UserMessageContent: Sendable, Hashable, ExpressibleByStringLiteral {
    case string(String)
    case blocks([UserContent])
    public init(stringLiteral value: String) { self = .string(value) }
}

/// `string | TextContent[]`
public enum SystemMessageContent: Sendable, Hashable, ExpressibleByStringLiteral {
    case string(String)
    case blocks([TextContent])
    public init(stringLiteral value: String) { self = .string(value) }
}

// MARK: - Usage

public struct UsageCost: Sendable, Hashable {
    public var input: Double = 0
    public var output: Double = 0
    public var cacheRead: Double = 0
    public var cacheWrite: Double = 0
    /// Best available total: provider-reported billed cost when supported, otherwise the catalog estimate.
    public var total: Double = 0
    /// True when `total` is the billed cost reported by the provider. False when it is a catalog estimate; absent also means false.
    public var totalFromProvider: Bool?
    public init(input: Double = 0, output: Double = 0, cacheRead: Double = 0, cacheWrite: Double = 0, total: Double = 0, totalFromProvider: Bool? = nil) {
        self.input = input; self.output = output; self.cacheRead = cacheRead; self.cacheWrite = cacheWrite; self.total = total
        self.totalFromProvider = totalFromProvider
    }
}

public struct Usage: Sendable, Hashable {
    public var input: Int = 0
    public var output: Int = 0
    public var cacheRead: Int = 0
    public var cacheWrite: Int = 0
    /// Subset of `cacheWrite` written with 1h retention. Only Anthropic reports this split.
    public var cacheWrite1h: Int?
    /// Reasoning/thinking tokens, when the provider reports them. A subset of `output`.
    public var reasoning: Int?
    public var totalTokens: Int = 0
    public var cost = UsageCost()
    public init(input: Int = 0, output: Int = 0, cacheRead: Int = 0, cacheWrite: Int = 0, cacheWrite1h: Int? = nil, reasoning: Int? = nil, totalTokens: Int = 0, cost: UsageCost = UsageCost()) {
        self.input = input; self.output = output; self.cacheRead = cacheRead; self.cacheWrite = cacheWrite
        self.cacheWrite1h = cacheWrite1h; self.reasoning = reasoning; self.totalTokens = totalTokens; self.cost = cost
    }
}

public enum StopReason: String, Sendable, Hashable, Codable {
    case pending, stop, length, toolUse, error, aborted, deferred
}

public struct DeferredHandle: Sendable, Hashable {
    public var provider: String
    public var modelId: String
    public var api: String
    /// Provider token, such as a response id or batch id plus row id.
    public var id: String
    public var expiresAt: Int?
    public var pollAfterMs: Int?
    /// Provider conversion data required to reconstruct the final assistant message.
    public var data: JsonValue?
    public init(provider: String, modelId: String, api: String, id: String, expiresAt: Int? = nil, pollAfterMs: Int? = nil, data: JsonValue? = nil) {
        self.provider = provider; self.modelId = modelId; self.api = api; self.id = id; self.expiresAt = expiresAt; self.pollAfterMs = pollAfterMs; self.data = data
    }
}

// MARK: - Messages

/// Named, ordered prompt sections. A nil value removes a section.
public typealias SystemSections = [(name: String, text: String?)]

/// System instructions and tool declarations at one point in the transcript.
///
/// The leading system message is the system prompt. Later system messages change it:
/// `content` adds instructions from that point on, `sections` replace or remove named
/// prompt sections, and `toolsAdded`/`toolsRemoved` change the tool set. Replaying
/// every system message in order yields the current prompt and tools.
public struct SystemMessage: Sendable {
    public var role: String { "system" }
    /// Instruction text. On the leading message this is the base prompt; later, additional instructions.
    public var content: SystemMessageContent
    /// Named, ordered prompt sections rendered verbatim after `content`.
    public var sections: SystemSections?
    /// Complete definitions of tools that become available at this point.
    public var toolsAdded: [Tool]?
    /// Tools that stop being available at this point.
    public var toolsRemoved: [ToolReference]?
    public var timestamp: Int
    public init(content: SystemMessageContent, sections: SystemSections? = nil, toolsAdded: [Tool]? = nil, toolsRemoved: [ToolReference]? = nil, timestamp: Int = dateNow()) {
        self.content = content; self.sections = sections; self.toolsAdded = toolsAdded; self.toolsRemoved = toolsRemoved; self.timestamp = timestamp
    }
}

public struct UserMessage: Sendable, Hashable {
    public var role: String { "user" }
    public var content: UserMessageContent
    public var timestamp: Int
    public init(content: UserMessageContent, timestamp: Int = dateNow()) { self.content = content; self.timestamp = timestamp }
}

public struct AssistantMessage: Sendable, Hashable {
    public var role: String { "assistant" }
    public var content: [AssistantContent]
    public var api: Api
    public var provider: ProviderId
    public var model: String
    /// Concrete model reported by the provider when different from the requested `model`
    public var responseModel: String?
    /// Provider-specific response/message identifier when the upstream API exposes one
    public var responseId: String?
    /// Exact provider-native effort level used for this response.
    public var providerThinkingLevel: String?
    /// Pi thinking level the agent loop requested for this response.
    public var thinkingLevel: ModelThinkingLevel?
    /// Redacted provider/runtime diagnostics for failures and recoveries.
    public var diagnostics: [AssistantMessageDiagnostic]?
    public var usage: Usage
    public var stopReason: StopReason
    public var deferred: DeferredHandle?
    public var errorMessage: String?
    public var rawStopReason: String?
    /// Provider indication of whether the model explicitly ended its turn.
    public var endTurn: Bool?
    /// Unix timestamp in milliseconds when the request started.
    public var timestamp: Int
    /// Milliseconds from `timestamp` until the response ended (monotonic clock).
    public var durationMs: Int?

    public init(content: [AssistantContent] = [], api: Api, provider: ProviderId, model: String, usage: Usage = Usage(), stopReason: StopReason = .stop, errorMessage: String? = nil, timestamp: Int = dateNow()) {
        self.content = content; self.api = api; self.provider = provider; self.model = model; self.usage = usage
        self.stopReason = stopReason; self.errorMessage = errorMessage; self.timestamp = timestamp
    }
}

/// A tool call that another tool made while it ran.
public struct NestedToolCallRecord: Sendable, Hashable {
    public var id: String
    public var name: String
    public var arguments: JsonObject?
    public var argumentsBytes: Int?
    /// "ok" | "error" | "unfinished"
    public var status: String
    public var durationMs: Int?
    public var error: String?
    public init(id: String, name: String, arguments: JsonObject? = nil, argumentsBytes: Int? = nil, status: String, durationMs: Int? = nil, error: String? = nil) {
        self.id = id; self.name = name; self.arguments = arguments; self.argumentsBytes = argumentsBytes; self.status = status; self.durationMs = durationMs; self.error = error
    }
}

public struct NestedToolCalls: Sendable, Hashable {
    public var calls: [NestedToolCallRecord]
    public var complete: Bool
    public init(calls: [NestedToolCallRecord], complete: Bool) { self.calls = calls; self.complete = complete }
}

public struct ToolResultMessage: Sendable, Hashable {
    public var role: String { "toolResult" }
    public var toolCallId: String
    public var toolName: String
    /// Supports text and images
    public var content: [UserContent]
    public var details: JsonValue?
    /// Usage from the tool execution itself, if available. Not part of main LLM context accounting.
    public var usage: Usage?
    /// Calls this tool made to other tools. Kept for the session record; not sent to the model.
    public var nestedCalls: NestedToolCalls?
    public var isError: Bool
    public var timestamp: Int
    /// Milliseconds the tool's execution took (monotonic clock).
    public var durationMs: Int?
    public init(toolCallId: String, toolName: String, content: [UserContent], details: JsonValue? = nil, usage: Usage? = nil, nestedCalls: NestedToolCalls? = nil, isError: Bool, timestamp: Int = dateNow(), durationMs: Int? = nil) {
        self.toolCallId = toolCallId; self.toolName = toolName; self.content = content; self.details = details; self.usage = usage
        self.nestedCalls = nestedCalls; self.isError = isError; self.timestamp = timestamp; self.durationMs = durationMs
    }
}

/// `SystemMessage | UserMessage | AssistantMessage | ToolResultMessage`
public enum Message: Sendable {
    case system(SystemMessage)
    case user(UserMessage)
    case assistant(AssistantMessage)
    case toolResult(ToolResultMessage)

    public var role: String {
        switch self {
        case .system: return "system"
        case .user: return "user"
        case .assistant: return "assistant"
        case .toolResult: return "toolResult"
        }
    }
    public var timestamp: Int {
        switch self {
        case .system(let m): return m.timestamp
        case .user(let m): return m.timestamp
        case .assistant(let m): return m.timestamp
        case .toolResult(let m): return m.timestamp
        }
    }
    public var systemMessage: SystemMessage? { if case .system(let m) = self { return m } else { return nil } }
    public var userMessage: UserMessage? { if case .user(let m) = self { return m } else { return nil } }
    public var assistantMessage: AssistantMessage? { if case .assistant(let m) = self { return m } else { return nil } }
    public var toolResultMessage: ToolResultMessage? { if case .toolResult(let m) = self { return m } else { return nil } }
}

// MARK: - Tools

/// OpenAI grammar variants for constrained sampling ("openai_lark" | "openai_regex").
public typealias GrammarVariants = [(format: String, grammar: String)]

/// Optional provider-side constrained sampling configs for a tool.
public enum ConstrainedSamplingConfig: Sendable {
    /// `{ type: "json_schema", strict: "prefer" | "require" }`
    case jsonSchema(strict: String)
    /// `{ type: "grammar", variants }`
    case grammar(variants: GrammarVariants)
}

public struct Tool: Sendable {
    public var name: String
    public var description: String
    /// JSON Schema of the parameters (TypeBox `TSchema` upstream).
    public var parameters: JsonValue
    /// `false | ConstrainedSamplingConfig`; nil means unset, `.some(nil)` means explicit `false`.
    public var constrainedSampling: ConstrainedSamplingConfig??
    public init(name: String, description: String, parameters: JsonValue, constrainedSampling: ConstrainedSamplingConfig?? = nil) {
        self.name = name; self.description = description; self.parameters = parameters; self.constrainedSampling = constrainedSampling
    }
}

public struct ToolReference: Sendable, Hashable {
    public var name: String
    public init(name: String) { self.name = name }
}

// MARK: - Context

/// Request input accepted by the public stream entry points. `systemPrompt` and `tools` are shorthand for a
/// leading system message; `normalizeContext()` folds them into one before the request reaches a provider.
public struct Context: Sendable {
    public var systemPrompt: String?
    public var messages: [Message]
    public var tools: [Tool]?
    public init(systemPrompt: String? = nil, messages: [Message] = [], tools: [Tool]? = nil) {
        self.systemPrompt = systemPrompt; self.messages = messages; self.tools = tools
    }
}

/// Normalized request context passed to providers and API implementations. The prompt and tool declarations are
/// carried by the transcript's system messages. Only `normalizeContext()` produces this type.
public struct TranscriptContext: Sendable {
    public var messages: [Message]
    /// Internal: use `normalizeContext()`.
    init(normalizedMessages: [Message]) { messages = normalizedMessages }
}

// MARK: - Events

/// Event protocol for AssistantMessageEventStream.
///
/// Successful streams emit `start` before partial updates and terminate with `done`. A stream may terminate
/// directly with `error` when request setup fails before generation starts; after `start`, failures also
/// terminate with `error`. Updates and `done` must never appear before `start`.
///
/// Swift: `partial` is a snapshot of the response so far at the time of the event (upstream shares one live object).
public enum AssistantMessageEvent: Sendable {
    case start(partial: AssistantMessage)
    case textStart(contentIndex: Int, partial: AssistantMessage)
    case textDelta(contentIndex: Int, delta: String, partial: AssistantMessage)
    case textEnd(contentIndex: Int, content: String, partial: AssistantMessage)
    case thinkingStart(contentIndex: Int, partial: AssistantMessage)
    case thinkingDelta(contentIndex: Int, delta: String, partial: AssistantMessage)
    case thinkingEnd(contentIndex: Int, content: String, partial: AssistantMessage)
    case toolcallStart(contentIndex: Int, partial: AssistantMessage)
    case toolcallDelta(contentIndex: Int, delta: String, partial: AssistantMessage)
    case toolcallEnd(contentIndex: Int, toolCall: ToolCall, partial: AssistantMessage)
    /// reason: "stop" | "length" | "toolUse" | "deferred"
    case done(reason: StopReason, message: AssistantMessage)
    /// reason: "aborted" | "error"
    case error(reason: StopReason, error: AssistantMessage)

    public var type: String {
        switch self {
        case .start: return "start"
        case .textStart: return "text_start"
        case .textDelta: return "text_delta"
        case .textEnd: return "text_end"
        case .thinkingStart: return "thinking_start"
        case .thinkingDelta: return "thinking_delta"
        case .thinkingEnd: return "thinking_end"
        case .toolcallStart: return "toolcall_start"
        case .toolcallDelta: return "toolcall_delta"
        case .toolcallEnd: return "toolcall_end"
        case .done: return "done"
        case .error: return "error"
        }
    }

    /// The partial (or final) message carried by the event.
    public var message: AssistantMessage {
        switch self {
        case .start(let p), .textStart(_, let p), .textDelta(_, _, let p), .textEnd(_, _, let p),
             .thinkingStart(_, let p), .thinkingDelta(_, _, let p), .thinkingEnd(_, _, let p),
             .toolcallStart(_, let p), .toolcallDelta(_, _, let p), .toolcallEnd(_, _, let p):
            return p
        case .done(_, let m): return m
        case .error(_, let m): return m
        }
    }
}

// MARK: - Models

public struct Model: Sendable {
    public var id: String
    public var name: String
    public var api: Api
    public var provider: ProviderId
    public var baseUrl: String
    public var input: [ModelInputModality]
    /// Provider input limits and cache-safe preprocessing metadata.
    public var inputLimits: ModelInputLimits?
    public var cost: ModelCost
    public var headers: [(String, String)]?
    /// Optional: "chat" (default), "image" or "classifier".
    public var type: String?
    public var reasoning: Bool
    /// Maps pi thinking levels to provider/model-specific values. Missing keys use provider defaults.
    public var thinkingLevelMap: ThinkingLevelMap?
    /// Prompt cache lifetimes per retention tier.
    public var promptCache: ModelPromptCache?
    public var contextWindow: Int
    public var maxTokens: Int
    /// Default sampling parameters for this model; per-request keys override these.
    public var samplingParams: SamplingParams?
    /// Sampling parameter overrides selected by the effective pi thinking level.
    public var samplingParamsByThinkingLevel: SamplingParamsByThinkingLevel?
    /// Compatibility overrides (shape depends on `api`; see compat-schema). If not set, auto-detected from baseUrl.
    public var compat: JsonObject?

    public init(id: String, name: String, api: Api, provider: ProviderId, baseUrl: String, reasoning: Bool = false, input: [ModelInputModality] = ["text"],
                cost: ModelCost = ModelCost(), contextWindow: Int = 128_000, maxTokens: Int = 16_384, headers: [(String, String)]? = nil, compat: JsonObject? = nil) {
        self.id = id; self.name = name; self.api = api; self.provider = provider; self.baseUrl = baseUrl; self.reasoning = reasoning
        self.input = input; self.cost = cost; self.contextWindow = contextWindow; self.maxTokens = maxTokens; self.headers = headers; self.compat = compat
    }
}

/// Uniform stream contract of an API implementation module.
public typealias StreamFunction = @Sendable (Model, TranscriptContext, StreamOptions?) -> AssistantMessageEventStream

/// `fetchDeferred?(model, handle, options?: DeferredFetchOptions)`.
public typealias FetchDeferredFunction = @Sendable (Model, DeferredHandle, DeferredFetchOptions?) -> AssistantMessageEventStream
/// `cancelDeferred?(model, handle, options?: DeferredCancelOptions): Promise<void>`.
public typealias CancelDeferredFunction = @Sendable (Model, DeferredHandle, DeferredCancelOptions?) async throws -> Void

public struct ProviderStreams: Sendable {
    public var stream: StreamFunction
    public var streamSimple: StreamFunction
    public var fetchDeferred: FetchDeferredFunction?
    public var cancelDeferred: CancelDeferredFunction?
    public init(stream: @escaping StreamFunction, streamSimple: @escaping StreamFunction, fetchDeferred: FetchDeferredFunction? = nil, cancelDeferred: CancelDeferredFunction? = nil) {
        self.stream = stream; self.streamSimple = streamSimple; self.fetchDeferred = fetchDeferred; self.cancelDeferred = cancelDeferred
    }
}

/// `AnyModel = Model | ImageModel | ClassifierModel`. Image and classifier models are not ported, so every
/// model is a `Model`; `type` distinguishes them at runtime.
public typealias AnyModel = Model
