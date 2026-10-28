import Foundation

// Port of packages/ai/src/providers/zai.ts
// The generated `zai.models.ts` catalog is not ported: models come from `models` or the builtin registry.

public func zaiProvider(models: [AnyModel]? = nil) -> Provider {
    builtinCreateProvider(CreateProviderOptions(
        id: "zai",
        name: "Z.AI",
        baseUrl: "https://api.z.ai/api/coding/paas/v4",
        auth: ProviderAuth(apiKey: envApiKeyAuth("Z.AI API key", ["ZAI_API_KEY"])),
        models: models ?? getAllBuiltinModels("zai"),
        api: .single(openAICompletionsApi())
    ))
}
