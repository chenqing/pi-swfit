import Foundation

// Port of packages/ai/src/providers/groq.ts
// The generated `groq.models.ts` catalog is not ported: models come from `models` or the builtin registry.

public func groqProvider(models: [AnyModel]? = nil) -> Provider {
    builtinCreateProvider(CreateProviderOptions(
        id: "groq",
        name: "Groq",
        baseUrl: "https://api.groq.com/openai/v1",
        auth: ProviderAuth(apiKey: envApiKeyAuth("Groq API key", ["GROQ_API_KEY"])),
        models: models ?? getAllBuiltinModels("groq"),
        api: .single(openAICompletionsApi())
    ))
}
