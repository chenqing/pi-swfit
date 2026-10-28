import Foundation

// Port of packages/ai/src/providers/qwen-token-plan.ts
// The generated `qwen-token-plan.models.ts` catalog is not ported: models come from `models` or the builtin registry.

public func qwenTokenPlanProvider(models: [AnyModel]? = nil) -> Provider {
    builtinCreateProvider(CreateProviderOptions(
        id: "qwen-token-plan",
        name: "Qwen Token Plan",
        baseUrl: "https://token-plan.ap-southeast-1.maas.aliyuncs.com/compatible-mode/v1",
        auth: ProviderAuth(apiKey: envApiKeyAuth("Qwen Token Plan API key", ["QWEN_TOKEN_PLAN_API_KEY"])),
        models: models ?? getAllBuiltinModels("qwen-token-plan"),
        api: .single(openAICompletionsApi())
    ))
}
