import Foundation

// Port of packages/ai/src/providers/openrouter-api.ts

/// OpenRouter's per-token prices, as decimal strings.
public struct OpenRouterPricing: Sendable, Hashable {
    public var prompt: String?
    public var completion: String?
    public var input_cache_read: String?
    public var input_cache_write: String?
    public var overrides: [OpenRouterPricingOverride]?
    public init(prompt: String? = nil, completion: String? = nil, input_cache_read: String? = nil, input_cache_write: String? = nil, overrides: [OpenRouterPricingOverride]? = nil) {
        self.prompt = prompt; self.completion = completion; self.input_cache_read = input_cache_read; self.input_cache_write = input_cache_write; self.overrides = overrides
    }

    /// Reads the shape from a JSON response (non-string prices are treated as missing).
    public init(json: JsonValue) {
        prompt = json["prompt"]?.stringValue
        completion = json["completion"]?.stringValue
        input_cache_read = json["input_cache_read"]?.stringValue
        input_cache_write = json["input_cache_write"]?.stringValue
        overrides = json["overrides"]?.arrayValue?.map(OpenRouterPricingOverride.init(json:))
    }
}

/// A conditional price. `min_prompt_tokens` selects prompt-length pricing; `utc_*` fields select
/// time-of-day or weekday pricing. Missing rates keep the base price.
public struct OpenRouterPricingOverride: Sendable, Hashable {
    public var min_prompt_tokens: Double?
    public var utc_start: Double?
    public var utc_end: Double?
    public var utc_days: [String]?
    public var prompt: String?
    public var completion: String?
    public var input_cache_read: String?
    public var input_cache_write: String?
    public init(min_prompt_tokens: Double? = nil, utc_start: Double? = nil, utc_end: Double? = nil, utc_days: [String]? = nil,
                prompt: String? = nil, completion: String? = nil, input_cache_read: String? = nil, input_cache_write: String? = nil) {
        self.min_prompt_tokens = min_prompt_tokens; self.utc_start = utc_start; self.utc_end = utc_end; self.utc_days = utc_days
        self.prompt = prompt; self.completion = completion; self.input_cache_read = input_cache_read; self.input_cache_write = input_cache_write
    }

    public init(json: JsonValue) {
        min_prompt_tokens = json["min_prompt_tokens"]?.doubleValue
        utc_start = json["utc_start"]?.doubleValue
        utc_end = json["utc_end"]?.doubleValue
        utc_days = json["utc_days"]?.arrayValue?.compactMap(\.stringValue)
        prompt = json["prompt"]?.stringValue
        completion = json["completion"]?.stringValue
        input_cache_read = json["input_cache_read"]?.stringValue
        input_cache_write = json["input_cache_write"]?.stringValue
    }
}

/// The fields pi reads from a model in OpenRouter's `GET /models` and `GET /models/user`.
public struct OpenRouterModel: Sendable, Hashable {
    public struct TopProvider: Sendable, Hashable {
        public var context_length: Double?
        public var max_completion_tokens: Double?
        public init(context_length: Double? = nil, max_completion_tokens: Double? = nil) { self.context_length = context_length; self.max_completion_tokens = max_completion_tokens }
    }
    public var id: String
    public var context_length: Double?
    public var top_provider: TopProvider?
    public var pricing: OpenRouterPricing?
    public init(id: String, context_length: Double? = nil, top_provider: TopProvider? = nil, pricing: OpenRouterPricing? = nil) {
        self.id = id; self.context_length = context_length; self.top_provider = top_provider; self.pricing = pricing
    }
}

/// `Number.parseFloat`: parses the longest leading decimal literal; NaN when there is none.
private func parseFloat(_ value: String) -> Double {
    let scalars = Array(value.drop(while: { $0.isWhitespace }).unicodeScalars)
    var end = 0
    var i = 0
    if i < scalars.count, scalars[i] == "+" || scalars[i] == "-" { i += 1 }
    if value.drop(while: { $0.isWhitespace }).dropFirst(i).hasPrefix("Infinity") {
        return scalars.first == "-" ? -.infinity : .infinity
    }
    var sawDigit = false
    while i < scalars.count, ("0"..."9").contains(scalars[i]) { i += 1; sawDigit = true; end = i }
    if i < scalars.count, scalars[i] == "." {
        i += 1
        while i < scalars.count, ("0"..."9").contains(scalars[i]) { i += 1; sawDigit = true; end = i }
        if sawDigit && end < i { end = i }
    }
    if !sawDigit { return .nan }
    if i < scalars.count, scalars[i] == "e" || scalars[i] == "E" {
        var j = i + 1
        if j < scalars.count, scalars[j] == "+" || scalars[j] == "-" { j += 1 }
        var expDigits = false
        while j < scalars.count, ("0"..."9").contains(scalars[j]) { j += 1; expDigits = true }
        if expDigits { end = j }
    }
    var text = ""
    text.unicodeScalars.append(contentsOf: scalars[0..<end])
    return Double(text) ?? .nan
}

/// Convert one $/token price to $/1M tokens. 0 means free. Missing, invalid and negative prices use
/// the fallback: OpenRouter reports -1 for router models such as `openrouter/auto`, whose price
/// depends on the model they pick.
private func perMillion(_ value: String?, _ fallback: Double) -> Double {
    let perToken = parseFloat(value ?? "")
    return perToken >= 0 ? Double(String(format: "%.6f", perToken * 1_000_000))! : fallback
}

/// Convert OpenRouter's $/token prices to pi's $/1M tokens. Missing, invalid and negative base
/// prices are 0. Prompt-length overrides become request-wide tiers; a rate a tier does not list
/// keeps the base price. Time-of-day overrides are skipped because ModelCost cannot express them.
public func openRouterCost(_ pricing: OpenRouterPricing?) -> ModelCost {
    let base = ModelCost(
        input: perMillion(pricing?.prompt, 0),
        output: perMillion(pricing?.completion, 0),
        cacheRead: perMillion(pricing?.input_cache_read, 0),
        cacheWrite: perMillion(pricing?.input_cache_write, 0)
    )
    let tiers = (pricing?.overrides ?? []).flatMap { override -> [ModelCostTier] in
        guard let minPromptTokens = override.min_prompt_tokens,
              override.utc_start == nil, override.utc_end == nil, override.utc_days == nil
        else {
            return []
        }
        return [
            ModelCostTier(
                inputTokensAbove: minPromptTokens,
                input: perMillion(override.prompt, base.input),
                output: perMillion(override.completion, base.output),
                cacheRead: perMillion(override.input_cache_read, base.cacheRead),
                cacheWrite: perMillion(override.input_cache_write, base.cacheWrite)
            ),
        ]
    }
    var cost = base
    if !tiers.isEmpty { cost.tiers = tiers }
    return cost
}
