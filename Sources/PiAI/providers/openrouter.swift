import Foundation

// Port of packages/ai/src/providers/openrouter.ts
// The generated `openrouter.models.ts` catalogs are not ported: models come from `models` or the builtin registry.

private let OPENROUTER_BASE_URL = "https://openrouter.ai/api/v1"
private let OPENROUTER_USER_MODELS_TIMEOUT_MS = 15_000

private func readOpenRouterModel(_ entry: JsonValue, id: String) -> OpenRouterModel {
    let topProvider = entry["top_provider"]?.objectValue.map { top in
        OpenRouterModel.TopProvider(
            context_length: top["context_length"]?.doubleValue,
            max_completion_tokens: top["max_completion_tokens"]?.doubleValue
        )
    }
    let pricing = entry["pricing"].flatMap { $0.objectValue != nil ? OpenRouterPricing(json: $0) : nil }
    return OpenRouterModel(id: id, context_length: entry["context_length"]?.doubleValue, top_provider: topProvider, pricing: pricing)
}

/// JS `||` on an optional number: absent, null and 0 fall through.
private func positiveInt(_ value: Double?) -> Int? {
    guard let value, value != 0, !value.isNaN else { return nil }
    return Int(value)
}

/// Restrict an OpenRouter catalog to the chat models the key may use, with the key's limits and
/// prices from `GET /models/user`. Image and classifier models are returned unchanged. A missing
/// limit keeps the catalog value. The request uses the provider's configured base URL, so regional
/// endpoints such as `https://us.openrouter.ai/api/v1` apply their region's filtering. When the
/// endpoint rejects the key (401/403) or does not exist (404), for example with a proxy configured
/// in models.json, the catalog is returned unchanged.
///
/// Swift: `fetch` replaces the global `fetch` so callers and tests can inject a transport.
public func personalizeOpenRouterCatalog(
    _ catalog: [AnyModel],
    _ context: RefreshModelsContext,
    fetch: FetchFunction = defaultFetch
) async throws -> [AnyModel] {
    let key: String?
    if case .oauth(let oauth) = context.credential { key = oauth.access } else { key = context.credential?.apiKeyCredential?.key }
    guard let key, !key.isEmpty else { return catalog }
    var base = context.baseUrl ?? OPENROUTER_BASE_URL
    while base.hasSuffix("/") { base.removeLast() }
    guard let url = URL(string: "\(base)/models/user") else { throw PiError("Invalid URL: \(base)/models/user") }
    let response = try await fetch(FetchRequest(
        url: url,
        headers: Headers([("accept", "application/json"), ("authorization", "Bearer \(key)")]),
        signal: AbortSignal.any([context.signal, AbortSignal.timeout(OPENROUTER_USER_MODELS_TIMEOUT_MS)])
    ))
    if response.status == 401 || response.status == 403 || response.status == 404 { return catalog }
    if !response.ok { throw PiError("OpenRouter model list request failed: \(response.status)") }
    let body = try await response.json()
    guard case .object(let object) = body, let data = object["data"]?.arrayValue else {
        throw PiError("Invalid OpenRouter model list response")
    }
    var allowed: [String: OpenRouterModel] = [:]
    for entry in data {
        if case .object = entry, let id = entry["id"]?.stringValue {
            allowed[id] = readOpenRouterModel(entry, id: id)
        }
    }
    return catalog.flatMap { model -> [AnyModel] in
        if !isModelType(model, "chat") { return [model] }
        guard let entry = allowed[model.id] else { return [] }
        var next = model
        // `||`: OpenRouter reports a missing limit as absent, null or 0, like the generator's fallback.
        next.contextWindow = positiveInt(entry.top_provider?.context_length) ?? positiveInt(entry.context_length) ?? model.contextWindow
        next.maxTokens = positiveInt(entry.top_provider?.max_completion_tokens) ?? model.maxTokens
        next.cost = entry.pricing.map { openRouterCost($0) } ?? model.cost
        return [next]
    }
}

public func openrouterProvider(models: [AnyModel]? = nil) -> Provider {
    builtinCreateProvider(CreateProviderOptions(
        id: "openrouter",
        name: "OpenRouter",
        baseUrl: OPENROUTER_BASE_URL,
        auth: ProviderAuth(
            apiKey: envApiKeyAuth("OpenRouter API key", ["OPENROUTER_API_KEY"]),
            oauth: lazyOAuth(
                name: "OpenRouter OAuth",
                loginLabel: "Sign in with OpenRouter",
                load: loadOpenRouterOAuth
            )
        ),
        models: models ?? getAllBuiltinModels("openrouter"),
        api: .byApi([
            "anthropic-messages": anthropicMessagesApi(),
            "openai-completions": openAICompletionsApi(),
        ])
        // Not ported: images ["openrouter-images"], classifiers ["typesafe-system-one"].
    ))
}
