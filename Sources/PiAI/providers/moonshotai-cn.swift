import Foundation

// Port of packages/ai/src/providers/moonshotai-cn.ts
// The generated `moonshotai-cn.models.ts` catalog is not ported: models come from `models` or the builtin registry.

public func moonshotaiCnProvider(models: [AnyModel]? = nil) -> Provider {
    builtinCreateProvider(CreateProviderOptions(
        id: "moonshotai-cn",
        name: "Moonshot AI CN",
        baseUrl: "https://api.moonshot.cn/v1",
        auth: ProviderAuth(apiKey: envApiKeyAuth("Moonshot AI API key", ["MOONSHOT_API_KEY"])),
        models: models ?? getAllBuiltinModels("moonshotai-cn"),
        api: .single(openAICompletionsApi())
    ))
}
