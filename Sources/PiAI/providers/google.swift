import Foundation

// Port of packages/ai/src/providers/google.ts
// The generated `google.models.ts` catalog is not ported: models come from `models` or the builtin registry.

public func googleProvider(models: [AnyModel]? = nil) -> Provider {
    builtinCreateProvider(CreateProviderOptions(
        id: "google",
        name: "Google",
        baseUrl: "https://generativelanguage.googleapis.com/v1beta",
        auth: ProviderAuth(apiKey: envApiKeyAuth("Gemini API key", ["GEMINI_API_KEY"])),
        models: models ?? getAllBuiltinModels("google"),
        api: .single(googleGenerativeAIApi())
    ))
}
