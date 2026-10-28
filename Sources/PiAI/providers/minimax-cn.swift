import Foundation

// Port of packages/ai/src/providers/minimax-cn.ts
// The generated `minimax-cn.models.ts` catalog is not ported: models come from `models` or the builtin registry.

public func minimaxCnProvider(models: [AnyModel]? = nil) -> Provider {
    builtinCreateProvider(CreateProviderOptions(
        id: "minimax-cn",
        name: "MiniMax CN",
        baseUrl: "https://api.minimaxi.com/anthropic",
        auth: ProviderAuth(apiKey: envApiKeyAuth("MiniMax CN API key", ["MINIMAX_CN_API_KEY"])),
        models: models ?? getAllBuiltinModels("minimax-cn"),
        api: .single(anthropicMessagesApi())
    ))
}
