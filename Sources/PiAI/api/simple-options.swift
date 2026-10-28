import Foundation

// Port of packages/ai/src/api/simple-options.ts.

private let CONTEXT_SAFETY_TOKENS = 4096
private let MIN_MAX_TOKENS = 1

public func clampMaxTokensToContext(_ model: Model, _ context: TranscriptContext, _ maxTokens: Int) -> Int {
	if model.contextWindow <= 0 { return max(MIN_MAX_TOKENS, maxTokens) }
	let available = model.contextWindow - estimateContextTokens(context).tokens - CONTEXT_SAFETY_TOKENS
	return min(maxTokens, max(MIN_MAX_TOKENS, available))
}

public func resolveSamplingParams(
	_ model: Model,
	_ thinkingLevel: ModelThinkingLevel,
	_ requestParams: SamplingParams? = nil
) -> SamplingParams? {
	let effectiveThinkingLevel = clampThinkingLevel(model, thinkingLevel)
	let thinkingLevelParams = model.samplingParamsByThinkingLevel?[effectiveThinkingLevel]
	guard model.samplingParams != nil || thinkingLevelParams != nil || requestParams != nil else {
		return nil
	}
	var merged = SamplingParams()
	for source in [model.samplingParams, thinkingLevelParams, requestParams] {
		for (key, value) in source ?? SamplingParams() { merged[key] = value }
	}
	return merged
}

public func buildBaseOptions(
	_ model: Model,
	_ context: TranscriptContext,
	_ options: SimpleStreamOptions? = nil,
	_ apiKey: String? = nil
) -> StreamOptions {
	let samplingParams = resolveSamplingParams(
		model,
		options?.reasoning.map(ModelThinkingLevel.init) ?? .off,
		options?.samplingParams
	)
	var base = StreamOptions()
	base.temperature = options?.temperature
	base.samplingParams = samplingParams
	base.maxTokens = clampMaxTokensToContext(model, context, options?.maxTokens ?? model.maxTokens)
	base.signal = options?.signal
	// Not ported: `telemetry` (StreamOptions has no telemetry hook in the Swift types).
	base.apiKey = (apiKey?.isEmpty == false ? apiKey : nil) ?? options?.apiKey
	base.fetch = options?.fetch
	base.transport = options?.transport
	base.cacheRetention = options?.cacheRetention
	base.sessionId = options?.sessionId
	base.identity = options?.identity
	base.headers = options?.headers
	base.onPayload = options?.onPayload
	base.onResponse = options?.onResponse
	base.onProviderStreamEvent = options?.onProviderStreamEvent
	base.timeoutMs = options?.timeoutMs
	base.websocketConnectTimeoutMs = options?.websocketConnectTimeoutMs
	base.maxRetries = options?.maxRetries
	base.maxRetryDelayMs = options?.maxRetryDelayMs
	base.metadata = options?.metadata
	base.env = options?.env
	return base
}

/** Tokens always left for the answer when a thinking budget shares the response ceiling. */
public let MIN_ANSWER_TOKENS = 1024

public let DEFAULT_THINKING_BUDGETS = ThinkingBudgets(
	minimal: 1024,
	low: 2048,
	medium: 8192,
	high: 16384
)

/// `Exclude<ThinkingLevel, "xhigh" | "max">`: xhigh and max collapse to high.
public func clampReasoning(_ effort: ThinkingLevel?) -> ThinkingLevel? {
	return effort == .xhigh || effort == .max ? .high : effort
}

public func thinkingBudgetForLevel(_ reasoningLevel: ThinkingLevel, _ customBudgets: ThinkingBudgets? = nil) -> Int {
	let level = clampReasoning(reasoningLevel)!
	switch level {
	case .minimal: return customBudgets?.minimal ?? DEFAULT_THINKING_BUDGETS.minimal!
	case .low: return customBudgets?.low ?? DEFAULT_THINKING_BUDGETS.low!
	case .medium: return customBudgets?.medium ?? DEFAULT_THINKING_BUDGETS.medium!
	case .high, .xhigh, .max: return customBudgets?.high ?? DEFAULT_THINKING_BUDGETS.high!
	}
}

/** Cap a thinking budget so at least MIN_ANSWER_TOKENS remain under a shared response ceiling. */
public func clampThinkingBudgetToAnswerRoom(_ thinkingBudget: Int, _ ceiling: Int) -> Int {
	return min(thinkingBudget, max(0, ceiling - MIN_ANSWER_TOKENS))
}

public func adjustMaxTokensForThinking(
	// Undefined means no explicit caller cap. Use the model cap and fit thinking inside it.
	_ baseMaxTokens: Int?,
	_ modelMaxTokens: Int,
	_ reasoningLevel: ThinkingLevel,
	_ customBudgets: ThinkingBudgets? = nil
) -> (maxTokens: Int, thinkingBudget: Int) {
	var thinkingBudget = thinkingBudgetForLevel(reasoningLevel, customBudgets)
	let maxTokens = baseMaxTokens.map { min($0 + thinkingBudget, modelMaxTokens) } ?? modelMaxTokens

	if maxTokens <= thinkingBudget {
		thinkingBudget = clampThinkingBudgetToAnswerRoom(thinkingBudget, maxTokens)
	}

	return (maxTokens, thinkingBudget)
}
