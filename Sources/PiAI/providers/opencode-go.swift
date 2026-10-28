import Foundation

// Port of packages/ai/src/providers/opencode-go.ts
// The generated `opencode-go.models.ts` catalog is not ported: models come from `models` or the builtin registry.

public func opencodeGoProvider(models: [AnyModel]? = nil) -> Provider {
    builtinCreateProvider(CreateProviderOptions(
        id: "opencode-go",
        name: "OpenCode Go",
        auth: ProviderAuth(apiKey: envApiKeyAuth("OpenCode API key", ["OPENCODE_API_KEY"])),
        models: models ?? getAllBuiltinModels("opencode-go"),
        api: .byApi([
            "anthropic-messages": withOpenCodeSessionHeader(anthropicMessagesApi()),
            "google-generative-ai": withOpenCodeSessionHeader(googleGenerativeAIApi()),
            "openai-completions": withOpenCodeSessionHeader(openAICompletionsApi()),
            "openai-responses": withOpenCodeSessionHeader(openAIResponsesApi()),
        ])
    ))
}
