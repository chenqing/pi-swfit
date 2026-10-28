import Foundation

// Port of packages/ai/src/providers/cloudflare-workers-ai.ts
// The generated `cloudflare-workers-ai.models.ts` catalog is not ported: models come from `models` or the builtin registry.

public func cloudflareWorkersAIProvider(models: [AnyModel]? = nil) -> Provider {
    builtinCreateProvider(CreateProviderOptions(
        id: "cloudflare-workers-ai",
        name: "Cloudflare Workers AI",
        auth: ProviderAuth(apiKey: cloudflareWorkersAIAuth()),
        models: models ?? getAllBuiltinModels("cloudflare-workers-ai"),
        api: .single(cloudflareStreams(openAICompletionsApi()))
        // Not ported: classifiers ["cloudflare-workers-ai-system-one"].
    ))
}
