import Foundation

// Port of packages/ai/src/providers/xai.ts
// The generated `xai.models.ts` catalog is not ported: models come from `models` or the builtin registry.

public func xaiProvider(models: [AnyModel]? = nil) -> Provider {
    builtinCreateProvider(CreateProviderOptions(
        id: "xai",
        name: "xAI",
        baseUrl: "https://api.x.ai/v1",
        auth: ProviderAuth(
            apiKey: envApiKeyAuth("xAI API key", ["XAI_API_KEY"]),
            oauth: lazyOAuth(
                name: "xAI (Grok/X subscription)",
                isSubscription: true,
                loginLabel: "Sign in with SuperGrok or X Premium",
                load: loadXaiOAuth
            )
        ),
        models: models ?? getAllBuiltinModels("xai"),
        api: .single(openAIResponsesApi())
    ))
}
