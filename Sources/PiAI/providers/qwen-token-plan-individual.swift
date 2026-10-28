import Foundation

// Port of packages/ai/src/providers/qwen-token-plan-individual.ts
// The generated `qwen-token-plan-individual.models.ts` catalog is not ported: models come from `models` or the builtin registry.

public func qwenTokenPlanIndividualProvider(models: [AnyModel]? = nil) -> Provider {
    builtinCreateProvider(CreateProviderOptions(
        id: "qwen-token-plan-individual",
        name: "Qwen Token Plan Individual",
        baseUrl: "https://token-plan.ap-southeast-1.maas.aliyuncs.com/compatible-mode/v1",
        auth: ProviderAuth(apiKey: envApiKeyAuth("Qwen Token Plan Individual API key", ["QWEN_TOKEN_PLAN_API_KEY"])),
        models: models ?? getAllBuiltinModels("qwen-token-plan-individual"),
        api: .single(openAICompletionsApi())
    ))
}
