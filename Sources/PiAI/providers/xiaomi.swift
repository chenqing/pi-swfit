import Foundation

// Port of packages/ai/src/providers/xiaomi.ts
// The generated `xiaomi.models.ts` catalog is not ported: models come from `models` or the builtin registry.

public func xiaomiProvider(models: [AnyModel]? = nil) -> Provider {
    builtinCreateProvider(CreateProviderOptions(
        id: "xiaomi",
        name: "Xiaomi",
        baseUrl: "https://api.xiaomimimo.com/v1",
        auth: ProviderAuth(apiKey: envApiKeyAuth("Xiaomi API key", ["XIAOMI_API_KEY"])),
        models: models ?? getAllBuiltinModels("xiaomi"),
        api: .single(openAICompletionsApi())
    ))
}
