import Foundation

// Port of packages/ai/src/providers/together.ts
// The generated `together.models.ts` catalog is not ported: models come from `models` or the builtin registry.

public func togetherProvider(models: [AnyModel]? = nil) -> Provider {
    builtinCreateProvider(CreateProviderOptions(
        id: "together",
        name: "Together",
        baseUrl: "https://api.together.ai/v1",
        auth: ProviderAuth(apiKey: envApiKeyAuth("Together API key", ["TOGETHER_API_KEY"])),
        models: models ?? getAllBuiltinModels("together"),
        api: .single(openAICompletionsApi())
    ))
}
