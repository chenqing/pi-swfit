// Port of packages/ai/src/providers/compat-schema.ts
//
// Upstream declares TypeBox schemas and derives the TypeScript types from them. Swift has no
// TypeBox, so each schema becomes a typed struct with a lenient `init(json:)` (values that do not
// match the schema are dropped, as if absent) plus `json` serialization. Unknown keys are kept in
// `extra` because the object schemas declare `additionalProperties: true`.
//
// Not ported: the schema constants themselves (SessionAffinityFormatSchema, ..., ProviderCompatSchema),
// CompatSchemasByApi and mergeCompatProperties — they only exist to feed TypeBox validation and
// JSON-schema generation for models.json, which belong to models.ts / model-schema.ts.
// Not ported: BedrockCompat and MistralConversationsCompat — their providers are not part of this port.
//
// Schema `default` values are exposed through each compat struct's static `defaults`, mirroring
// `Compile(Schema).Default({})`.

// MARK: - JSON helpers

private func compatBool(_ o: JsonObject, _ key: String) -> Bool? { o[key]?.boolValue }
private func compatNumber(_ o: JsonObject, _ key: String) -> Double? {
    guard let v = o[key]?.doubleValue, v.isFinite else { return nil }
    return v
}
private func compatString(_ o: JsonObject, _ key: String) -> String? { o[key]?.stringValue }
private func compatStrings(_ o: JsonObject, _ key: String) -> [String]? {
    guard let array = o[key]?.arrayValue else { return nil }
    var out: [String] = []
    for item in array {
        guard let s = item.stringValue else { return nil }
        out.append(s)
    }
    return out
}
private func compatEnum<T: RawRepresentable>(_ o: JsonObject, _ key: String) -> T? where T.RawValue == String {
    o[key]?.stringValue.flatMap(T.init(rawValue:))
}
private func compatExtra(_ o: JsonObject, _ known: Set<String>) -> JsonObject {
    var extra = JsonObject()
    for (key, value) in o where !known.contains(key) { extra[key] = value }
    return extra
}
private func put(_ o: inout JsonObject, _ key: String, _ value: Bool?) { if let value { o[key] = .bool(value) } }
private func put(_ o: inout JsonObject, _ key: String, _ value: Double?) { if let value { o[key] = .number(value) } }
private func put(_ o: inout JsonObject, _ key: String, _ value: String?) { if let value { o[key] = .string(value) } }
private func put(_ o: inout JsonObject, _ key: String, _ value: [String]?) {
    if let value { o[key] = .array(value.map { .string($0) }) }
}
private func put<T: RawRepresentable>(_ o: inout JsonObject, _ key: String, _ value: T?) where T.RawValue == String {
    if let value { o[key] = .string(value.rawValue) }
}
private func merged(_ o: JsonObject, _ extra: JsonObject) -> JsonObject {
    var out = o
    for (key, value) in extra where out[key] == nil { out[key] = value }
    return out
}

// MARK: - Literal unions

/// Session-affinity header format used to route related requests consistently.
public enum SessionAffinityFormat: String, Sendable, Hashable, CaseIterable {
    case openai = "openai"
    case openaiNosession = "openai-nosession"
    case openrouter = "openrouter"
}

/// Top-level request field used to cap reasoning tokens on OpenAI-compatible servers.
///
/// Top-level request field name used by OpenAI-compatible endpoints to cap reasoning tokens. "thinking_token_budget" is
/// used by vLLM, "thinking_budget" by Qwen, DashScope, or SGLang, and "thinking_budget_tokens" by llama.cpp.
public enum ThinkingTokenBudgetField: String, Sendable, Hashable, CaseIterable {
    case thinkingTokenBudget = "thinking_token_budget"
    case thinkingBudget = "thinking_budget"
    case thinkingBudgetTokens = "thinking_budget_tokens"
}

/// Which field to use for max tokens.
public enum MaxTokensField: String, Sendable, Hashable, CaseIterable {
    case maxCompletionTokens = "max_completion_tokens"
    case maxTokens = "max_tokens"
}

/// Format for reasoning or thinking parameters (see `OpenAICompletionsCompat.thinkingFormat`).
public enum ThinkingFormat: String, Sendable, Hashable, CaseIterable {
    case openai = "openai"
    case openrouter = "openrouter"
    case deepseek = "deepseek"
    case together = "together"
    case baseten = "baseten"
    case zai = "zai"
    case qwen = "qwen"
    case chatTemplate = "chat-template"
    case qwenChatTemplate = "qwen-chat-template"
    case stringThinking = "string-thinking"
    case antLing = "ant-ling"
}

/// Cache control convention for prompt caching.
public enum CacheControlFormat: String, Sendable, Hashable, CaseIterable {
    case anthropic = "anthropic"
}

/// Session-affinity format for Anthropic Messages-compatible APIs.
public enum AnthropicSessionAffinityFormat: String, Sendable, Hashable, CaseIterable {
    case openrouter = "openrouter"
}

/// pi-controlled values usable through `$var` in chat template kwargs.
public enum ChatTemplateVariable: String, Sendable, Hashable, CaseIterable {
    case thinkingEnabled = "thinking.enabled"
    case thinkingEffort = "thinking.effort"
    case thinkingBudget = "thinking.budget"
}

public enum ChatTemplateKwargValue: Sendable, Hashable {
    case string(String)
    case number(Double)
    case bool(Bool)
    case null
    case variable(ChatTemplateVariable, omitWhenOff: Bool? = nil)

    public init?(json: JsonValue) {
        switch json {
        case .string(let v): self = .string(v)
        case .number(let v) where v.isFinite: self = .number(v)
        case .bool(let v): self = .bool(v)
        case .null: self = .null
        case .object(let o):
            guard let raw = o["$var"]?.stringValue, let variable = ChatTemplateVariable(rawValue: raw) else { return nil }
            let omit = o["omitWhenOff"]
            if let omit, omit.boolValue == nil { return nil }
            self = .variable(variable, omitWhenOff: omit?.boolValue)
        default: return nil
        }
    }

    public var json: JsonValue {
        switch self {
        case .string(let v): return .string(v)
        case .number(let v): return .number(v)
        case .bool(let v): return .bool(v)
        case .null: return .null
        case .variable(let variable, let omitWhenOff):
            var o: JsonObject = ["$var": .string(variable.rawValue)]
            if let omitWhenOff { o["omitWhenOff"] = .bool(omitWhenOff) }
            return .object(o)
        }
    }
}

/// Ordered record of chat template kwargs (`Record<string, ChatTemplateKwargValue>`).
public typealias ChatTemplateKwargs = [(String, ChatTemplateKwargValue)]

private func chatTemplateKwargs(_ o: JsonObject, _ key: String) -> ChatTemplateKwargs? {
    guard let record = o[key]?.objectValue else { return nil }
    var out: ChatTemplateKwargs = []
    for (name, value) in record {
        guard let parsed = ChatTemplateKwargValue(json: value) else { return nil }
        out.append((name, parsed))
    }
    return out
}
private func put(_ o: inout JsonObject, _ key: String, _ value: ChatTemplateKwargs?) {
    if let value { o[key] = .object(JsonObject(value.map { ($0.0, $0.1.json) })) }
}

// MARK: - OpenRouter routing

public struct PercentileCutoffs: Sendable, Hashable {
    public var p50: Double?
    public var p75: Double?
    public var p90: Double?
    public var p99: Double?
    public init(p50: Double? = nil, p75: Double? = nil, p90: Double? = nil, p99: Double? = nil) {
        self.p50 = p50; self.p75 = p75; self.p90 = p90; self.p99 = p99
    }
    public init(json o: JsonObject) {
        self.init(p50: compatNumber(o, "p50"), p75: compatNumber(o, "p75"), p90: compatNumber(o, "p90"), p99: compatNumber(o, "p99"))
    }
    public var json: JsonObject {
        var o = JsonObject()
        put(&o, "p50", p50); put(&o, "p75", p75); put(&o, "p90", p90); put(&o, "p99", p99)
        return o
    }
}

/// A number applies to p50.
public enum PercentilePreference: Sendable, Hashable {
    case number(Double)
    case cutoffs(PercentileCutoffs)

    init?(json: JsonValue?) {
        switch json {
        case .number(let v)? where v.isFinite: self = .number(v)
        case .object(let o)?: self = .cutoffs(PercentileCutoffs(json: o))
        default: return nil
        }
    }
    var json: JsonValue {
        switch self {
        case .number(let v): return .number(v)
        case .cutoffs(let c): return .object(c.json)
        }
    }
}

/// Number or string price.
public enum RoutingPrice: Sendable, Hashable {
    case number(Double)
    case string(String)

    init?(json: JsonValue?) {
        switch json {
        case .number(let v)? where v.isFinite: self = .number(v)
        case .string(let v)?: self = .string(v)
        default: return nil
        }
    }
    var json: JsonValue {
        switch self {
        case .number(let v): return .number(v)
        case .string(let v): return .string(v)
        }
    }
}

/// Maximum price per million tokens in USD.
public struct OpenRouterMaxPrice: Sendable, Hashable {
    /// Price per million prompt tokens.
    public var prompt: RoutingPrice?
    /// Price per million completion tokens.
    public var completion: RoutingPrice?
    /// Price per image.
    public var image: RoutingPrice?
    /// Price per audio unit.
    public var audio: RoutingPrice?
    /// Price per request.
    public var request: RoutingPrice?
    public init(prompt: RoutingPrice? = nil, completion: RoutingPrice? = nil, image: RoutingPrice? = nil, audio: RoutingPrice? = nil, request: RoutingPrice? = nil) {
        self.prompt = prompt; self.completion = completion; self.image = image; self.audio = audio; self.request = request
    }
    public init(json o: JsonObject) {
        self.init(prompt: RoutingPrice(json: o["prompt"]), completion: RoutingPrice(json: o["completion"]),
                  image: RoutingPrice(json: o["image"]), audio: RoutingPrice(json: o["audio"]), request: RoutingPrice(json: o["request"]))
    }
    public var json: JsonObject {
        var o = JsonObject()
        for (key, value) in [("prompt", prompt), ("completion", completion), ("image", image), ("audio", audio), ("request", request)] {
            if let value { o[key] = value.json }
        }
        return o
    }
}

/// Sorting strategy. Can be a string such as "price", "throughput", or "latency", or an object.
public enum OpenRouterSort: Sendable, Hashable {
    case string(String)
    /// `partition`: outer nil = absent, `.some(nil)` = JSON null.
    case object(by: String?, partition: String??)

    init?(json: JsonValue?) {
        switch json {
        case .string(let v)?: self = .string(v)
        case .object(let o)?:
            let partition: String??
            switch o["partition"] {
            case nil: partition = nil
            case .null?: partition = .some(nil)
            case .string(let s)?: partition = .some(s)
            default: partition = nil
            }
            self = .object(by: compatString(o, "by"), partition: partition)
        default: return nil
        }
    }
    var json: JsonValue {
        switch self {
        case .string(let v): return .string(v)
        case .object(let by, let partition):
            var o = JsonObject()
            put(&o, "by", by)
            if let partition { o["partition"] = partition.map { .string($0) } ?? .null }
            return .object(o)
        }
    }
}

public enum OpenRouterDataCollection: String, Sendable, Hashable, CaseIterable {
    case deny = "deny"
    case allow = "allow"
}

/// OpenRouter provider routing preferences.
///
/// OpenRouter provider routing preferences. Controls which upstream providers OpenRouter routes requests to. Sent as
/// the provider field in the OpenRouter API request body. See https://openrouter.ai/docs/guides/routing/provider-selection.
public struct OpenRouterRouting: Sendable, Hashable {
    /// Whether to allow backup providers to serve requests. (default: true)
    public var allow_fallbacks: Bool?
    /// Whether to filter providers to only those that support all parameters in the request. (default: false)
    public var require_parameters: Bool?
    /// Data collection setting. "allow": allow providers that may store or train on data. "deny": only use providers
    /// that do not collect user data. (default: "allow")
    public var data_collection: OpenRouterDataCollection?
    /// Whether to restrict routing to only ZDR (Zero Data Retention) endpoints.
    public var zdr: Bool?
    /// Whether to restrict routing to only models that allow text distillation.
    public var enforce_distillable_text: Bool?
    /// An ordered list of provider names or slugs to try in sequence, falling back to the next if unavailable.
    public var order: [String]?
    /// List of provider names or slugs to exclusively allow for this request.
    public var only: [String]?
    /// List of provider names or slugs to skip for this request.
    public var ignore: [String]?
    /// A list of quantization levels to filter providers by, for example ["fp16", "bf16", "fp8", "fp6", "int8", "int4", "fp4", "fp32"].
    public var quantizations: [String]?
    /// Sorting strategy. Can be a string such as "price", "throughput", or "latency", or an object.
    public var sort: OpenRouterSort?
    /// Maximum price per million tokens in USD.
    public var max_price: OpenRouterMaxPrice?
    /// Preferred minimum throughput in tokens per second. A number applies to p50.
    public var preferred_min_throughput: PercentilePreference?
    /// Preferred maximum latency in seconds. A number applies to p50.
    public var preferred_max_latency: PercentilePreference?
    /// Unknown keys (TypeBox objects allow additional properties by default).
    public var extra: JsonObject

    public init(allow_fallbacks: Bool? = nil, require_parameters: Bool? = nil, data_collection: OpenRouterDataCollection? = nil,
                zdr: Bool? = nil, enforce_distillable_text: Bool? = nil, order: [String]? = nil, only: [String]? = nil,
                ignore: [String]? = nil, quantizations: [String]? = nil, sort: OpenRouterSort? = nil,
                max_price: OpenRouterMaxPrice? = nil, preferred_min_throughput: PercentilePreference? = nil,
                preferred_max_latency: PercentilePreference? = nil, extra: JsonObject = JsonObject()) {
        self.allow_fallbacks = allow_fallbacks; self.require_parameters = require_parameters; self.data_collection = data_collection
        self.zdr = zdr; self.enforce_distillable_text = enforce_distillable_text; self.order = order; self.only = only
        self.ignore = ignore; self.quantizations = quantizations; self.sort = sort; self.max_price = max_price
        self.preferred_min_throughput = preferred_min_throughput; self.preferred_max_latency = preferred_max_latency
        self.extra = extra
    }

    private static let keys: Set<String> = [
        "allow_fallbacks", "require_parameters", "data_collection", "zdr", "enforce_distillable_text", "order", "only",
        "ignore", "quantizations", "sort", "max_price", "preferred_min_throughput", "preferred_max_latency",
    ]

    public init(json: JsonObject?) {
        let o = json ?? JsonObject()
        self.init(
            allow_fallbacks: compatBool(o, "allow_fallbacks"), require_parameters: compatBool(o, "require_parameters"),
            data_collection: compatEnum(o, "data_collection"), zdr: compatBool(o, "zdr"),
            enforce_distillable_text: compatBool(o, "enforce_distillable_text"), order: compatStrings(o, "order"),
            only: compatStrings(o, "only"), ignore: compatStrings(o, "ignore"), quantizations: compatStrings(o, "quantizations"),
            sort: OpenRouterSort(json: o["sort"]), max_price: o["max_price"]?.objectValue.map(OpenRouterMaxPrice.init(json:)),
            preferred_min_throughput: PercentilePreference(json: o["preferred_min_throughput"]),
            preferred_max_latency: PercentilePreference(json: o["preferred_max_latency"]),
            extra: compatExtra(o, Self.keys)
        )
    }

    public var json: JsonObject {
        var o = JsonObject()
        put(&o, "allow_fallbacks", allow_fallbacks); put(&o, "require_parameters", require_parameters)
        put(&o, "data_collection", data_collection); put(&o, "zdr", zdr); put(&o, "enforce_distillable_text", enforce_distillable_text)
        put(&o, "order", order); put(&o, "only", only); put(&o, "ignore", ignore); put(&o, "quantizations", quantizations)
        if let sort { o["sort"] = sort.json }
        if let max_price { o["max_price"] = .object(max_price.json) }
        if let preferred_min_throughput { o["preferred_min_throughput"] = preferred_min_throughput.json }
        if let preferred_max_latency { o["preferred_max_latency"] = preferred_max_latency.json }
        return merged(o, extra)
    }
}

/// Vercel AI Gateway routing preferences.
///
/// Vercel AI Gateway routing preferences. Controls which upstream providers the gateway routes requests to. See
/// https://vercel.com/docs/ai-gateway/models-and-providers/provider-options.
public struct VercelGatewayRouting: Sendable, Hashable {
    /// List of provider slugs to exclusively use for this request, for example ["bedrock", "anthropic"].
    public var only: [String]?
    /// List of provider slugs to try in order, for example ["anthropic", "openai"].
    public var order: [String]?
    public var extra: JsonObject

    public init(only: [String]? = nil, order: [String]? = nil, extra: JsonObject = JsonObject()) {
        self.only = only; self.order = order; self.extra = extra
    }
    public init(json: JsonObject?) {
        let o = json ?? JsonObject()
        self.init(only: compatStrings(o, "only"), order: compatStrings(o, "order"), extra: compatExtra(o, ["only", "order"]))
    }
    public var json: JsonObject {
        var o = JsonObject()
        put(&o, "only", only); put(&o, "order", order)
        return merged(o, extra)
    }
}

/// An Anthropic server-side refusal fallback model with local pricing metadata.
public struct AnthropicAllowedFallbackModel: Sendable, Hashable {
    public var provider: String
    public var model: String
    public var cost: ModelCost

    public init(provider: String, model: String, cost: ModelCost) {
        self.provider = provider; self.model = model; self.cost = cost
    }
    /// Returns nil when the value does not match the schema (provider/model must be non-empty strings, cost a ModelCost).
    public init?(json: JsonObject?) {
        guard let o = json, let provider = compatString(o, "provider"), !provider.isEmpty,
              let model = compatString(o, "model"), !model.isEmpty,
              let costJson = o["cost"], let cost = try? ModelCost(json: costJson) else { return nil }
        self.init(provider: provider, model: model, cost: cost)
    }
    public var json: JsonObject {
        ["provider": .string(provider), "model": .string(model), "cost": cost.json]
    }
}

// MARK: - OpenAI completions

/// Compatibility settings for OpenAI-compatible completions APIs.
///
/// Compatibility settings for OpenAI-compatible completions APIs. Use this to override URL-based auto-detection for custom providers.
public struct OpenAICompletionsCompat: Sendable, Hashable {
    /// Whether the provider supports the store field. Default: auto-detected from URL.
    public var supportsStore: Bool?
    /// Whether the provider supports the developer role instead of system. Default: auto-detected from URL.
    public var supportsDeveloperRole: Bool?
    /// Whether the provider supports reasoning_effort. Default: auto-detected from URL.
    public var supportsReasoningEffort: Bool?
    /// Whether the provider supports stream_options.include_usage for token usage in streaming responses. (default: true)
    public var supportsUsageInStreaming: Bool?
    /// Whether streamed responses include finish_reason. When false, pi infers stop or toolUse when the stream ends. (default: true)
    public var supportsFinishReason: Bool?
    /// Which field to use for max tokens. Default: auto-detected from URL.
    public var maxTokensField: MaxTokensField?
    /// Whether tool results require the name field. Default: auto-detected from URL.
    public var requiresToolResultName: Bool?
    /// Whether a user message after tool results requires an assistant message in between. Default: auto-detected from URL.
    public var requiresAssistantAfterToolResult: Bool?
    /// Whether thinking blocks must be converted to text blocks with <thinking> delimiters. Default: auto-detected from URL.
    public var requiresThinkingAsText: Bool?
    /// Whether all replayed assistant messages must include an empty reasoning_content field when reasoning is enabled. Default: auto-detected from URL.
    public var requiresReasoningContentOnAssistantMessages: Bool?
    /// Format for reasoning or thinking parameters. When omitted, Pi auto-detects the format from the provider URL. "openai"
    /// uses reasoning_effort, "openrouter" uses reasoning.effort, "deepseek" uses thinking.type plus reasoning_effort when
    /// supported, "together" uses reasoning.enabled plus reasoning_effort when supported, "baseten" uses configurable
    /// chat_template_args plus reasoning_effort when supported, "zai" uses thinking.type, "qwen" uses top-level
    /// enable_thinking, "qwen-chat-template" uses chat_template_kwargs.enable_thinking and preserve_thinking,
    /// "chat-template" uses configurable chat_template_kwargs, "string-thinking" uses top-level thinking, and "ant-ling"
    /// uses reasoning.effort only when the mapped effort is non-null.
    public var thinkingFormat: ThinkingFormat?
    /// Kwargs sent as chat_template_kwargs when thinkingFormat is "chat-template". Use $var with "thinking.enabled",
    /// "thinking.effort", or "thinking.budget" for pi-controlled values.
    public var chatTemplateKwargs: ChatTemplateKwargs?
    /// Arguments sent as chat_template_args when thinkingFormat is "baseten". Use $var with "thinking.enabled",
    /// "thinking.effort", or "thinking.budget" for pi-controlled values.
    public var chatTemplateArgs: ChatTemplateKwargs?
    public var openRouterRouting: OpenRouterRouting?
    public var vercelGatewayRouting: VercelGatewayRouting?
    /// Whether z.ai supports top-level tool_stream for streaming tool call deltas. (default: false)
    public var zaiToolStream: Bool?
    /// Top-level request field used to cap reasoning tokens from thinkingBudgets. Reasoning and the answer share
    /// max_tokens on these endpoints. "thinking_token_budget" is vLLM, "thinking_budget" is Qwen, DashScope, or SGLang,
    /// and "thinking_budget_tokens" is llama.cpp. Off by default and not set on the generated catalog.
    public var thinkingTokenBudgetField: ThinkingTokenBudgetField?
    /// Alias for thinkingTokenBudgetField: "thinking_token_budget" (vLLM). Prefer thinkingTokenBudgetField. (default: false)
    public var supportsThinkingTokenBudget: Bool?
    /// Whether the provider supports OpenAI custom tools with Lark or regex grammar formats. When false,
    /// grammar-constrained tools fall back to normal function tools. The generated catalog enables this for capable models. (default: false)
    public var supportsOpenAIGrammarTools: Bool?
    /// Whether the exact model accepts system or developer messages after the conversation has started. When false,
    /// later system messages are folded into the leading system message. The generated catalog enables this for verified models. (default: false)
    public var supportsMidConvoSystemMessages: Bool?
    /// Whether system messages can introduce additional tools mid-conversation. Requires supportsMidConvoSystemMessages.
    /// The generated catalog enables this for capable models. (default: false)
    public var supportsMidConvoToolAdditions: Bool?
    /// Whether the provider supports the strict field in tool definitions. Generated capable models enable it explicitly. (default: false)
    public var supportsStrictMode: Bool?
    /// Cache control convention for prompt caching. Anthropic applies cache_control markers to the system prompt, last
    /// tool definition, and last user, assistant, or tool-result text content.
    public var cacheControlFormat: CacheControlFormat?
    /// Whether to send session-affinity data from options.sessionId. Default: true for OpenRouter endpoints, false otherwise.
    public var sendSessionAffinityHeaders: Bool?
    /// Session-affinity header format. openai sends session_id, x-client-request-id, and x-session-affinity;
    /// openai-nosession sends x-client-request-id and x-session-affinity; openrouter sends x-session-id. Does not affect
    /// prompt_cache_key. Default: auto-detected.
    public var sessionAffinityFormat: SessionAffinityFormat?
    /// Whether the provider supports long prompt cache retention (prompt_cache_retention: "24h" or Anthropic-style
    /// cache_control.ttl: "1h", depending on format). Default: auto-detected from provider and URL.
    public var supportsLongCacheRetention: Bool?
    /// vLLM scheduler priority sent as the top-level priority request field. Lower values are handled earlier and the
    /// server default is 0. Only meaningful with --scheduling-policy priority. Off by default and not set on the generated catalog.
    public var vllmPriority: Double?
    /// Unknown keys (`additionalProperties: true`).
    public var extra: JsonObject = JsonObject()

    public init() {}

    private static let keys: Set<String> = [
        "supportsStore", "supportsDeveloperRole", "supportsReasoningEffort", "supportsUsageInStreaming", "supportsFinishReason",
        "maxTokensField", "requiresToolResultName", "requiresAssistantAfterToolResult", "requiresThinkingAsText",
        "requiresReasoningContentOnAssistantMessages", "thinkingFormat", "chatTemplateKwargs", "chatTemplateArgs",
        "openRouterRouting", "vercelGatewayRouting", "zaiToolStream", "thinkingTokenBudgetField", "supportsThinkingTokenBudget",
        "supportsOpenAIGrammarTools", "supportsMidConvoSystemMessages", "supportsMidConvoToolAdditions", "supportsStrictMode",
        "cacheControlFormat", "sendSessionAffinityHeaders", "sessionAffinityFormat", "supportsLongCacheRetention", "vllmPriority",
    ]

    public init(json: JsonObject?) {
        let o = json ?? JsonObject()
        supportsStore = compatBool(o, "supportsStore")
        supportsDeveloperRole = compatBool(o, "supportsDeveloperRole")
        supportsReasoningEffort = compatBool(o, "supportsReasoningEffort")
        supportsUsageInStreaming = compatBool(o, "supportsUsageInStreaming")
        supportsFinishReason = compatBool(o, "supportsFinishReason")
        maxTokensField = compatEnum(o, "maxTokensField")
        requiresToolResultName = compatBool(o, "requiresToolResultName")
        requiresAssistantAfterToolResult = compatBool(o, "requiresAssistantAfterToolResult")
        requiresThinkingAsText = compatBool(o, "requiresThinkingAsText")
        requiresReasoningContentOnAssistantMessages = compatBool(o, "requiresReasoningContentOnAssistantMessages")
        thinkingFormat = compatEnum(o, "thinkingFormat")
        chatTemplateKwargs = PiAI.chatTemplateKwargs(o, "chatTemplateKwargs")
        chatTemplateArgs = PiAI.chatTemplateKwargs(o, "chatTemplateArgs")
        openRouterRouting = o["openRouterRouting"]?.objectValue.map { OpenRouterRouting(json: $0) }
        vercelGatewayRouting = o["vercelGatewayRouting"]?.objectValue.map { VercelGatewayRouting(json: $0) }
        zaiToolStream = compatBool(o, "zaiToolStream")
        thinkingTokenBudgetField = compatEnum(o, "thinkingTokenBudgetField")
        supportsThinkingTokenBudget = compatBool(o, "supportsThinkingTokenBudget")
        supportsOpenAIGrammarTools = compatBool(o, "supportsOpenAIGrammarTools")
        supportsMidConvoSystemMessages = compatBool(o, "supportsMidConvoSystemMessages")
        supportsMidConvoToolAdditions = compatBool(o, "supportsMidConvoToolAdditions")
        supportsStrictMode = compatBool(o, "supportsStrictMode")
        cacheControlFormat = compatEnum(o, "cacheControlFormat")
        sendSessionAffinityHeaders = compatBool(o, "sendSessionAffinityHeaders")
        sessionAffinityFormat = compatEnum(o, "sessionAffinityFormat")
        supportsLongCacheRetention = compatBool(o, "supportsLongCacheRetention")
        vllmPriority = compatNumber(o, "vllmPriority")
        extra = compatExtra(o, Self.keys)
    }

    public var json: JsonObject {
        var o = JsonObject()
        put(&o, "supportsStore", supportsStore)
        put(&o, "supportsDeveloperRole", supportsDeveloperRole)
        put(&o, "supportsReasoningEffort", supportsReasoningEffort)
        put(&o, "supportsUsageInStreaming", supportsUsageInStreaming)
        put(&o, "supportsFinishReason", supportsFinishReason)
        put(&o, "maxTokensField", maxTokensField)
        put(&o, "requiresToolResultName", requiresToolResultName)
        put(&o, "requiresAssistantAfterToolResult", requiresAssistantAfterToolResult)
        put(&o, "requiresThinkingAsText", requiresThinkingAsText)
        put(&o, "requiresReasoningContentOnAssistantMessages", requiresReasoningContentOnAssistantMessages)
        put(&o, "thinkingFormat", thinkingFormat)
        put(&o, "chatTemplateKwargs", chatTemplateKwargs)
        put(&o, "chatTemplateArgs", chatTemplateArgs)
        if let openRouterRouting { o["openRouterRouting"] = .object(openRouterRouting.json) }
        if let vercelGatewayRouting { o["vercelGatewayRouting"] = .object(vercelGatewayRouting.json) }
        put(&o, "zaiToolStream", zaiToolStream)
        put(&o, "thinkingTokenBudgetField", thinkingTokenBudgetField)
        put(&o, "supportsThinkingTokenBudget", supportsThinkingTokenBudget)
        put(&o, "supportsOpenAIGrammarTools", supportsOpenAIGrammarTools)
        put(&o, "supportsMidConvoSystemMessages", supportsMidConvoSystemMessages)
        put(&o, "supportsMidConvoToolAdditions", supportsMidConvoToolAdditions)
        put(&o, "supportsStrictMode", supportsStrictMode)
        put(&o, "cacheControlFormat", cacheControlFormat)
        put(&o, "sendSessionAffinityHeaders", sendSessionAffinityHeaders)
        put(&o, "sessionAffinityFormat", sessionAffinityFormat)
        put(&o, "supportsLongCacheRetention", supportsLongCacheRetention)
        put(&o, "vllmPriority", vllmPriority)
        return merged(o, extra)
    }

    /// Mirrors `Compile(OpenAICompletionsCompatSchema).Default({})`.
    public static var defaults: OpenAICompletionsCompat {
        var c = OpenAICompletionsCompat()
        c.supportsUsageInStreaming = true
        c.supportsFinishReason = true
        c.zaiToolStream = false
        c.supportsThinkingTokenBudget = false
        c.supportsOpenAIGrammarTools = false
        c.supportsMidConvoSystemMessages = false
        c.supportsMidConvoToolAdditions = false
        c.supportsStrictMode = false
        return c
    }

    public static func == (lhs: Self, rhs: Self) -> Bool { JsonValue.object(lhs.json) == .object(rhs.json) }
    public func hash(into hasher: inout Hasher) { hasher.combine(JsonValue.object(json)) }
}

// MARK: - OpenAI Responses

/// Compatibility settings for OpenAI Responses APIs.
public struct OpenAIResponsesCompat: Sendable, Hashable {
    /// Whether the provider supports the developer role instead of system. (default: true)
    public var supportsDeveloperRole: Bool?
    /// Whether the exact model accepts developer or system messages after the conversation has started. When false,
    /// later system messages are folded into the leading system message. The generated catalog enables this for verified models. (default: false)
    public var supportsMidConvoSystemMessages: Bool?
    /// Session-affinity header format. openai sends session_id and x-client-request-id; openai-nosession sends
    /// x-client-request-id; openrouter sends x-session-id. Does not affect prompt_cache_key. Default: auto-detected.
    public var sessionAffinityFormat: SessionAffinityFormat?
    /// Whether the provider supports long prompt cache retention. This uses prompt_cache_options.ttl: "30m" on GPT-5.6+
    /// and prompt_cache_retention: "24h" on earlier models. (default: true)
    public var supportsLongCacheRetention: Bool?
    /// Whether the provider supports strict JSON-schema function tools. Defaults are API-specific; generated OpenAI models enable it explicitly.
    public var supportsStrictMode: Bool?
    /// Whether to emit OpenAI custom tools with Lark or regex grammar formats. When false, grammar-constrained tools
    /// fall back to normal function tools. The generated catalog enables this for capable models. (default: false)
    public var supportsOpenAIGrammarTools: Bool?
    /// Whether the model supports message-anchored additional_tools input items. (default: false)
    public var supportsAdditionalTools: Bool?
    /// Whether the model supports client-executed tool search for transcript-anchored additions. (default: false)
    public var supportsToolSearch: Bool?
    /// Whether the model accepts prompt_cache_options. Older OpenAI models reject the parameter. (default: false)
    public var supportsExplicitPromptCacheMode: Bool?
    /// Whether thinking level changes are sent as configuration_update input items instead of changing
    /// reasoning.effort, so a change keeps the prompt cache. Only used by the openai-responses API, and ignored with
    /// Sign in with ChatGPT on the openai provider. (default: false)
    public var supportsMidConvoEffort: Bool?
    /// Whether the provider accepts max_output_tokens. Some Codex-protocol gateways reject it. (default: true)
    public var supportsMaxOutputTokens: Bool?
    /// Unknown keys (`additionalProperties: true`).
    public var extra: JsonObject = JsonObject()

    public init() {}

    private static let keys: Set<String> = [
        "supportsDeveloperRole", "supportsMidConvoSystemMessages", "sessionAffinityFormat", "supportsLongCacheRetention",
        "supportsStrictMode", "supportsOpenAIGrammarTools", "supportsAdditionalTools", "supportsToolSearch",
        "supportsExplicitPromptCacheMode", "supportsMidConvoEffort", "supportsMaxOutputTokens",
    ]

    public init(json: JsonObject?) {
        let o = json ?? JsonObject()
        supportsDeveloperRole = compatBool(o, "supportsDeveloperRole")
        supportsMidConvoSystemMessages = compatBool(o, "supportsMidConvoSystemMessages")
        sessionAffinityFormat = compatEnum(o, "sessionAffinityFormat")
        supportsLongCacheRetention = compatBool(o, "supportsLongCacheRetention")
        supportsStrictMode = compatBool(o, "supportsStrictMode")
        supportsOpenAIGrammarTools = compatBool(o, "supportsOpenAIGrammarTools")
        supportsAdditionalTools = compatBool(o, "supportsAdditionalTools")
        supportsToolSearch = compatBool(o, "supportsToolSearch")
        supportsExplicitPromptCacheMode = compatBool(o, "supportsExplicitPromptCacheMode")
        supportsMidConvoEffort = compatBool(o, "supportsMidConvoEffort")
        supportsMaxOutputTokens = compatBool(o, "supportsMaxOutputTokens")
        extra = compatExtra(o, Self.keys)
    }

    public var json: JsonObject {
        var o = JsonObject()
        put(&o, "supportsDeveloperRole", supportsDeveloperRole)
        put(&o, "supportsMidConvoSystemMessages", supportsMidConvoSystemMessages)
        put(&o, "sessionAffinityFormat", sessionAffinityFormat)
        put(&o, "supportsLongCacheRetention", supportsLongCacheRetention)
        put(&o, "supportsStrictMode", supportsStrictMode)
        put(&o, "supportsOpenAIGrammarTools", supportsOpenAIGrammarTools)
        put(&o, "supportsAdditionalTools", supportsAdditionalTools)
        put(&o, "supportsToolSearch", supportsToolSearch)
        put(&o, "supportsExplicitPromptCacheMode", supportsExplicitPromptCacheMode)
        put(&o, "supportsMidConvoEffort", supportsMidConvoEffort)
        put(&o, "supportsMaxOutputTokens", supportsMaxOutputTokens)
        return merged(o, extra)
    }

    /// Mirrors `Compile(OpenAIResponsesCompatSchema).Default({})`.
    public static var defaults: OpenAIResponsesCompat {
        var c = OpenAIResponsesCompat()
        c.supportsDeveloperRole = true
        c.supportsMidConvoSystemMessages = false
        c.supportsLongCacheRetention = true
        c.supportsOpenAIGrammarTools = false
        c.supportsAdditionalTools = false
        c.supportsToolSearch = false
        c.supportsExplicitPromptCacheMode = false
        c.supportsMidConvoEffort = false
        c.supportsMaxOutputTokens = true
        return c
    }
}

// MARK: - Anthropic Messages

/// Compatibility settings for Anthropic Messages-compatible APIs.
public struct AnthropicMessagesCompat: Sendable, Hashable {
    /// Whether the provider accepts per-tool eager_input_streaming. When false, the Anthropic provider omits
    /// tools[].eager_input_streaming and sends the legacy fine-grained-tool-streaming-2025-05-14 beta header for
    /// tool-enabled requests. (default: true)
    public var supportsEagerToolInputStreaming: Bool?
    /// Whether the provider supports Anthropic long cache retention through cache_control.ttl. (default: true)
    public var supportsLongCacheRetention: Bool?
    /// Whether to send x-session-affinity from options.sessionId when caching is enabled. Required for providers like
    /// Fireworks that use session affinity for prompt cache routing; requests to the same replica maximize cache hits.
    /// Default: true for OpenRouter endpoints, false otherwise.
    public var sendSessionAffinityHeaders: Bool?
    /// Session-affinity format. openrouter sends x-session-id; when unset, sends x-session-affinity.
    public var sessionAffinityFormat: AnthropicSessionAffinityFormat?
    /// Whether the provider supports Anthropic-style cache_control markers on tool definitions. When false,
    /// cache_control is omitted from tool parameters. Some Anthropic-compatible providers, such as Fireworks, do not
    /// support this field on tools and may reject or ignore it. (default: true)
    public var supportsCacheControlOnTools: Bool?
    /// Whether the model accepts the Anthropic temperature request field. Claude Opus 4.7+ rejects non-default values. (default: true)
    public var supportsTemperature: Bool?
    /// Whether to force adaptive thinking (thinking.type: adaptive plus output_config.effort) regardless of model ID.
    /// Built-in models that require adaptive thinking set this in generated metadata. Custom Anthropic-compatible
    /// providers can set this to true for any model whose upstream requires the adaptive format. Set false to opt out
    /// on overridden built-in models. (default: false)
    public var forceAdaptiveThinking: Bool?
    /// Whether to replay empty thinking signatures instead of converting thinking to text. (default: false)
    public var allowEmptySignature: Bool?
    /// Whether the provider supports Anthropic strict tool schemas. Generated Anthropic models enable it explicitly. (default: false)
    public var supportsStrictTools: Bool?
    /// Whether the exact model transport supports effort-only system messages and thinking binding controls. (default: false)
    public var supportsMidConvoEffort: Bool?
    /// Whether the exact model accepts system-role messages inside the conversation. When false, later system messages
    /// are folded into the top-level system prompt. (default: false)
    public var supportsMidConvoSystemMessages: Bool?
    /// Whether the exact model accepts mid-conversation tool_addition and tool_removal blocks. Requires supportsMidConvoSystemMessages. (default: false)
    public var supportsMidConvoToolChanges: Bool?
    /// Models Anthropic accepts for server-side refusal fallback, with local pricing metadata for returned fallback
    /// responses. When absent or empty, callers must omit fallbacks; Anthropic rejects the field for models with no
    /// permitted fallback targets. (maxItems: 3)
    public var allowedFallbackModels: [AnthropicAllowedFallbackModel]?
    /// Unknown keys (`additionalProperties: true`).
    public var extra: JsonObject = JsonObject()

    public init() {}

    private static let keys: Set<String> = [
        "supportsEagerToolInputStreaming", "supportsLongCacheRetention", "sendSessionAffinityHeaders", "sessionAffinityFormat",
        "supportsCacheControlOnTools", "supportsTemperature", "forceAdaptiveThinking", "allowEmptySignature",
        "supportsStrictTools", "supportsMidConvoEffort", "supportsMidConvoSystemMessages", "supportsMidConvoToolChanges",
        "allowedFallbackModels",
    ]

    public init(json: JsonObject?) {
        let o = json ?? JsonObject()
        supportsEagerToolInputStreaming = compatBool(o, "supportsEagerToolInputStreaming")
        supportsLongCacheRetention = compatBool(o, "supportsLongCacheRetention")
        sendSessionAffinityHeaders = compatBool(o, "sendSessionAffinityHeaders")
        sessionAffinityFormat = compatEnum(o, "sessionAffinityFormat")
        supportsCacheControlOnTools = compatBool(o, "supportsCacheControlOnTools")
        supportsTemperature = compatBool(o, "supportsTemperature")
        forceAdaptiveThinking = compatBool(o, "forceAdaptiveThinking")
        allowEmptySignature = compatBool(o, "allowEmptySignature")
        supportsStrictTools = compatBool(o, "supportsStrictTools")
        supportsMidConvoEffort = compatBool(o, "supportsMidConvoEffort")
        supportsMidConvoSystemMessages = compatBool(o, "supportsMidConvoSystemMessages")
        supportsMidConvoToolChanges = compatBool(o, "supportsMidConvoToolChanges")
        if let array = o["allowedFallbackModels"]?.arrayValue, array.count <= 3 {
            let models = array.compactMap { AnthropicAllowedFallbackModel(json: $0.objectValue) }
            allowedFallbackModels = models.count == array.count ? models : nil
        }
        extra = compatExtra(o, Self.keys)
    }

    public var json: JsonObject {
        var o = JsonObject()
        put(&o, "supportsEagerToolInputStreaming", supportsEagerToolInputStreaming)
        put(&o, "supportsLongCacheRetention", supportsLongCacheRetention)
        put(&o, "sendSessionAffinityHeaders", sendSessionAffinityHeaders)
        put(&o, "sessionAffinityFormat", sessionAffinityFormat)
        put(&o, "supportsCacheControlOnTools", supportsCacheControlOnTools)
        put(&o, "supportsTemperature", supportsTemperature)
        put(&o, "forceAdaptiveThinking", forceAdaptiveThinking)
        put(&o, "allowEmptySignature", allowEmptySignature)
        put(&o, "supportsStrictTools", supportsStrictTools)
        put(&o, "supportsMidConvoEffort", supportsMidConvoEffort)
        put(&o, "supportsMidConvoSystemMessages", supportsMidConvoSystemMessages)
        put(&o, "supportsMidConvoToolChanges", supportsMidConvoToolChanges)
        if let allowedFallbackModels { o["allowedFallbackModels"] = .array(allowedFallbackModels.map { .object($0.json) }) }
        return merged(o, extra)
    }

    /// Mirrors `Compile(AnthropicMessagesCompatSchema).Default({})`.
    public static var defaults: AnthropicMessagesCompat {
        var c = AnthropicMessagesCompat()
        c.supportsEagerToolInputStreaming = true
        c.supportsLongCacheRetention = true
        c.supportsCacheControlOnTools = true
        c.supportsTemperature = true
        c.forceAdaptiveThinking = false
        c.allowEmptySignature = false
        c.supportsStrictTools = false
        c.supportsMidConvoEffort = false
        c.supportsMidConvoSystemMessages = false
        c.supportsMidConvoToolChanges = false
        return c
    }
}
