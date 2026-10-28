import Foundation

// Port of packages/ai/src/providers/qwen-token-plan-cn.ts
// The generated `qwen-token-plan-cn.models.ts` catalog is not ported: models come from `models` or the builtin registry.

public func qwenTokenPlanCnProvider(models: [AnyModel]? = nil) -> Provider {
    builtinCreateProvider(CreateProviderOptions(
        id: "qwen-token-plan-cn",
        name: "Qwen Token Plan CN",
        baseUrl: "https://token-plan.cn-beijing.maas.aliyuncs.com/compatible-mode/v1",
        auth: ProviderAuth(apiKey: envApiKeyAuth("Qwen Token Plan CN API key", ["QWEN_TOKEN_PLAN_CN_API_KEY"])),
        models: models ?? getAllBuiltinModels("qwen-token-plan-cn"),
        api: .single(openAICompletionsApi())
    ))
}
