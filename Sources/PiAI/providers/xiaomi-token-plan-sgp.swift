import Foundation

// Port of packages/ai/src/providers/xiaomi-token-plan-sgp.ts
// The generated `xiaomi-token-plan-sgp.models.ts` catalog is not ported: models come from `models` or the builtin registry.

public func xiaomiTokenPlanSgpProvider(models: [AnyModel]? = nil) -> Provider {
    builtinCreateProvider(CreateProviderOptions(
        id: "xiaomi-token-plan-sgp",
        name: "Xiaomi Token Plan SGP",
        baseUrl: "https://token-plan-sgp.xiaomimimo.com/v1",
        auth: ProviderAuth(apiKey: envApiKeyAuth("Xiaomi Token Plan SGP API key", ["XIAOMI_TOKEN_PLAN_SGP_API_KEY"])),
        models: models ?? getAllBuiltinModels("xiaomi-token-plan-sgp"),
        api: .single(openAICompletionsApi())
    ))
}
