import Foundation

// Port of packages/ai/src/providers/vercel-ai-gateway.ts
// The generated `vercel-ai-gateway.models.ts` catalog is not ported: models come from `models` or the builtin registry.

public func vercelAIGatewayProvider(models: [AnyModel]? = nil) -> Provider {
    builtinCreateProvider(CreateProviderOptions(
        id: "vercel-ai-gateway",
        name: "Vercel AI Gateway",
        baseUrl: "https://ai-gateway.vercel.sh",
        auth: ProviderAuth(apiKey: envApiKeyAuth("Vercel AI Gateway API key", ["AI_GATEWAY_API_KEY"])),
        models: models ?? getAllBuiltinModels("vercel-ai-gateway"),
        api: .single(anthropicMessagesApi())
        // Not ported: classifiers ["typesafe-system-one"] (AI Gateway serves TypeSafe's System One protocol at /typesafe/v1/systemone).
    ))
}
