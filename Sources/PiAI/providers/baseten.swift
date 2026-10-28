import Foundation

// Port of packages/ai/src/providers/baseten.ts
// The generated `baseten.models.ts` catalog is not ported: models come from `models` or the builtin registry.

public func basetenProvider(models: [AnyModel]? = nil) -> Provider {
    builtinCreateProvider(CreateProviderOptions(
        id: "baseten",
        name: "Baseten",
        baseUrl: "https://inference.baseten.co/v1",
        auth: ProviderAuth(apiKey: envApiKeyAuth("Baseten API key", ["BASETEN_API_KEY"])),
        models: models ?? getAllBuiltinModels("baseten"),
        api: .single(openAICompletionsApi())
    ))
}
