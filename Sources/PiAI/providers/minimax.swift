import Foundation

// Port of packages/ai/src/providers/minimax.ts
// The generated `minimax.models.ts` catalog is not ported: models come from `models` or the builtin registry.

public func minimaxProvider(models: [AnyModel]? = nil) -> Provider {
    builtinCreateProvider(CreateProviderOptions(
        id: "minimax",
        name: "MiniMax",
        baseUrl: "https://api.minimax.io/anthropic",
        auth: ProviderAuth(apiKey: envApiKeyAuth("MiniMax API key", ["MINIMAX_API_KEY"])),
        models: models ?? getAllBuiltinModels("minimax"),
        api: .single(anthropicMessagesApi())
    ))
}
