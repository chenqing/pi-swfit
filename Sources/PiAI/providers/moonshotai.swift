import Foundation

// Port of packages/ai/src/providers/moonshotai.ts
// The generated `moonshotai.models.ts` catalog is not ported: models come from `models` or the builtin registry.

public func moonshotaiProvider(models: [AnyModel]? = nil) -> Provider {
    builtinCreateProvider(CreateProviderOptions(
        id: "moonshotai",
        name: "Moonshot AI",
        baseUrl: "https://api.moonshot.ai/v1",
        auth: ProviderAuth(apiKey: envApiKeyAuth("Moonshot AI API key", ["MOONSHOT_API_KEY"])),
        models: models ?? getAllBuiltinModels("moonshotai"),
        api: .single(openAICompletionsApi())
    ))
}
