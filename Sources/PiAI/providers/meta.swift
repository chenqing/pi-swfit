import Foundation

// Port of packages/ai/src/providers/meta.ts
// The generated `meta.models.ts` catalog is not ported: models come from `models` or the builtin registry.

public func metaProvider(models: [AnyModel]? = nil) -> Provider {
    builtinCreateProvider(CreateProviderOptions(
        id: "meta",
        name: "Meta",
        baseUrl: "https://api.meta.ai/v1",
        auth: ProviderAuth(
            apiKey: envApiKeyAuth("Meta Model API key", ["META_API_KEY"]),
            oauth: lazyOAuth(
                name: "Meta (Muse subscription)",
                isSubscription: true,
                loginLabel: "Sign in with Meta",
                load: loadMetaOAuth
            )
        ),
        models: models ?? getAllBuiltinModels("meta"),
        api: .single(openAIResponsesApi())
    ))
}
