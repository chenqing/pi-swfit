import Foundation

// Port of packages/ai/src/providers/xiaomi-token-plan-ams.ts
// The generated `xiaomi-token-plan-ams.models.ts` catalog is not ported: models come from `models` or the builtin registry.

public func xiaomiTokenPlanAmsProvider(models: [AnyModel]? = nil) -> Provider {
    builtinCreateProvider(CreateProviderOptions(
        id: "xiaomi-token-plan-ams",
        name: "Xiaomi Token Plan AMS",
        baseUrl: "https://token-plan-ams.xiaomimimo.com/v1",
        auth: ProviderAuth(apiKey: envApiKeyAuth("Xiaomi Token Plan AMS API key", ["XIAOMI_TOKEN_PLAN_AMS_API_KEY"])),
        models: models ?? getAllBuiltinModels("xiaomi-token-plan-ams"),
        api: .single(openAICompletionsApi())
    ))
}
