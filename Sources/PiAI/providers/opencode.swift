import Foundation

// Port of packages/ai/src/providers/opencode.ts
// The generated `opencode.models.ts` catalog is not ported: models come from `models` or the builtin registry.

public func opencodeProvider(models: [AnyModel]? = nil) -> Provider {
    builtinCreateProvider(CreateProviderOptions(
        id: "opencode",
        name: "OpenCode Zen",
        auth: ProviderAuth(apiKey: envApiKeyAuth("OpenCode API key", ["OPENCODE_API_KEY"])),
        models: models ?? getAllBuiltinModels("opencode"),
        api: .byApi([
            "anthropic-messages": withOpenCodeSessionHeader(anthropicMessagesApi()),
            "google-generative-ai": withOpenCodeSessionHeader(googleGenerativeAIApi()),
            "openai-completions": withOpenCodeSessionHeader(openAICompletionsApi()),
            "openai-responses": withOpenCodeSessionHeader(openAIResponsesApi()),
        ])
        // Not ported: classifiers ["typesafe-system-one"] (OpenCode Zen serves TypeSafe's System One protocol at /inference/systemone/v1/systemone).
    ))
}
