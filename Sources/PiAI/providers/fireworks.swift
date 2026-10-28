import Foundation

// Port of packages/ai/src/providers/fireworks.ts
// The generated `fireworks.models.ts` catalog is not ported: models come from `models` or the builtin registry.

public func fireworksProvider(models: [AnyModel]? = nil) -> Provider {
    builtinCreateProvider(CreateProviderOptions(
        id: "fireworks",
        name: "Fireworks",
        baseUrl: "https://api.fireworks.ai/inference",
        auth: ProviderAuth(apiKey: envApiKeyAuth("Fireworks API key", ["FIREWORKS_API_KEY"])),
        models: models ?? getAllBuiltinModels("fireworks"),
        api: .byApi([
            "anthropic-messages": anthropicMessagesApi(),
            "openai-completions": openAICompletionsApi(),
        ])
    ))
}
