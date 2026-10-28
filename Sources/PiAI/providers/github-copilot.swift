import Foundation

// Port of packages/ai/src/providers/github-copilot.ts
// The generated `github-copilot.models.ts` catalog is not ported: models come from `models` or the builtin registry.

public func githubCopilotProvider(models: [AnyModel]? = nil) -> Provider {
    builtinCreateProvider(CreateProviderOptions(
        id: "github-copilot",
        name: "GitHub Copilot",
        baseUrl: "https://api.individual.githubcopilot.com",
        auth: ProviderAuth(
            apiKey: envApiKeyAuth("GitHub Copilot token", ["COPILOT_GITHUB_TOKEN"]),
            oauth: lazyOAuth(name: "GitHub Copilot", isSubscription: true, load: loadGitHubCopilotOAuth)
        ),
        models: models ?? getAllBuiltinModels("github-copilot"),
        filterModels: { models, credential in
            guard case .oauth(let oauth) = credential else { return models }
            guard let availableModelIds = oauth.extra["availableModelIds"]?.arrayValue,
                  availableModelIds.allSatisfy({ $0.stringValue != nil })
            else {
                return models
            }
            let available = Set(availableModelIds.compactMap(\.stringValue))
            return models.filter { available.contains($0.id) }
        },
        api: .byApi([
            "anthropic-messages": anthropicMessagesApi(),
            "openai-completions": openAICompletionsApi(),
            "openai-responses": openAIResponsesApi(),
        ])
    ))
}
