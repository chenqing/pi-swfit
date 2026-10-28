import Foundation

// Port of packages/ai/src/providers/openai.ts
// The generated `openai.models.ts` catalog is not ported: models come from `models` or the builtin registry.

public func openaiProvider(models: [AnyModel]? = nil) -> Provider {
    builtinCreateProvider(CreateProviderOptions(
        id: "openai",
        name: "OpenAI",
        baseUrl: "https://api.openai.com/v1",
        auth: ProviderAuth(
            apiKey: envApiKeyAuth("OpenAI API key", ["OPENAI_API_KEY"]),
            oauth: lazyOAuth(
                name: "OpenAI (ChatGPT subscription)",
                isSubscription: true,
                loginLabel: "Sign in with ChatGPT",
                load: loadOpenAIChatGPTOAuth
            )
        ),
        models: models ?? getAllBuiltinModels("openai"),
        // Sign in with ChatGPT tokens only reach the Responses API; the Decisions API rejects them.
        filterAllModels: { models, credential in
            if case .oauth = credential { return models.filter { !isModelType($0, "classifier") } }
            return models
        },
        api: .single(openAIResponsesApi())
        // Not ported: classifiers ["openai-decisions": openAIDecisionsApi()].
    ))
}
