import Foundation

// Port of packages/ai/src/providers/kimi-coding.ts
// The generated `kimi-coding.models.ts` catalog is not ported: models come from `models` or the builtin registry.

public func kimiCodingProvider(models: [AnyModel]? = nil) -> Provider {
    builtinCreateProvider(CreateProviderOptions(
        id: "kimi-coding",
        name: "Kimi For Coding",
        baseUrl: "https://api.kimi.com/coding/v1",
        auth: ProviderAuth(
            apiKey: envApiKeyAuth("Kimi API key", ["KIMI_API_KEY"]),
            oauth: lazyOAuth(
                name: "Kimi Code (subscription)",
                isSubscription: true,
                loginLabel: "Sign in with Kimi Code",
                load: loadKimiCodingOAuth
            )
        ),
        models: models ?? getAllBuiltinModels("kimi-coding"),
        api: .single(openAICompletionsApi())
    ))
}
