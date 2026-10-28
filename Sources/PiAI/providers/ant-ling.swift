import Foundation

// Port of packages/ai/src/providers/ant-ling.ts
// The generated `ant-ling.models.ts` catalog is not ported: models come from `models` or the builtin registry.

public func antLingProvider(models: [AnyModel]? = nil) -> Provider {
    builtinCreateProvider(CreateProviderOptions(
        id: "ant-ling",
        name: "Ant Ling",
        baseUrl: "https://api.ant-ling.com/v1",
        auth: ProviderAuth(apiKey: envApiKeyAuth("Ant Ling API key", ["ANT_LING_API_KEY"])),
        models: models ?? getAllBuiltinModels("ant-ling"),
        api: .single(openAICompletionsApi())
    ))
}
