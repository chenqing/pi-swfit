import Foundation

// Port of packages/ai/src/providers/xiaomi-token-plan-cn.ts
// The generated `xiaomi-token-plan-cn.models.ts` catalog is not ported: models come from `models` or the builtin registry.

public func xiaomiTokenPlanCnProvider(models: [AnyModel]? = nil) -> Provider {
    builtinCreateProvider(CreateProviderOptions(
        id: "xiaomi-token-plan-cn",
        name: "Xiaomi Token Plan CN",
        baseUrl: "https://token-plan-cn.xiaomimimo.com/v1",
        auth: ProviderAuth(apiKey: envApiKeyAuth("Xiaomi Token Plan CN API key", ["XIAOMI_TOKEN_PLAN_CN_API_KEY"])),
        models: models ?? getAllBuiltinModels("xiaomi-token-plan-cn"),
        api: .single(openAICompletionsApi())
    ))
}
