import Foundation

// Port of packages/ai/src/providers/cerebras.ts
// The generated `cerebras.models.ts` catalog is not ported: models come from `models` or the builtin registry.

public func cerebrasProvider(models: [AnyModel]? = nil) -> Provider {
    builtinCreateProvider(CreateProviderOptions(
        id: "cerebras",
        name: "Cerebras",
        baseUrl: "https://api.cerebras.ai/v1",
        auth: ProviderAuth(apiKey: envApiKeyAuth("Cerebras API key", ["CEREBRAS_API_KEY"])),
        models: models ?? getAllBuiltinModels("cerebras"),
        api: .single(openAICompletionsApi())
    ))
}
