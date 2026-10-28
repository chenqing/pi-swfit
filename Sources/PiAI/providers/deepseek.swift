import Foundation

// Port of packages/ai/src/providers/deepseek.ts
// The generated `deepseek.models.ts` catalog is not ported: models come from `models` or the builtin registry.

public func deepseekProvider(models: [AnyModel]? = nil) -> Provider {
    builtinCreateProvider(CreateProviderOptions(
        id: "deepseek",
        name: "DeepSeek",
        baseUrl: "https://api.deepseek.com",
        auth: ProviderAuth(apiKey: envApiKeyAuth("DeepSeek API key", ["DEEPSEEK_API_KEY"])),
        models: models ?? getAllBuiltinModels("deepseek"),
        api: .single(openAICompletionsApi())
    ))
}
