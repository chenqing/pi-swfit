import Foundation

// Port of packages/ai/src/providers/cloudflare-ai-gateway.ts
// The generated `cloudflare-ai-gateway.models.ts` catalog is not ported: models come from `models` or the builtin registry.

public func cloudflareAIGatewayProvider(models: [AnyModel]? = nil) -> Provider {
    // The api map is pinned to all three APIs: models.dev's gateway catalog drops and
    // restores `workers-ai/*` (openai-completions) entries over time, and inference from
    // `models` alone would otherwise reject the openai-completions entry whenever the
    // generated catalog happens to contain none.
    builtinCreateProvider(CreateProviderOptions(
        id: "cloudflare-ai-gateway",
        name: "Cloudflare AI Gateway",
        auth: ProviderAuth(apiKey: cloudflareAIGatewayAuth()),
        models: models ?? getAllBuiltinModels("cloudflare-ai-gateway"),
        api: .byApi([
            "anthropic-messages": cloudflareStreams(anthropicMessagesApi()),
            "openai-completions": cloudflareStreams(openAICompletionsApi()),
            "openai-responses": cloudflareStreams(openAIResponsesApi()),
        ])
    ))
}
