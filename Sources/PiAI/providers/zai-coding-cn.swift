import Foundation

// Port of packages/ai/src/providers/zai-coding-cn.ts
// The generated `zai-coding-cn.models.ts` catalog is not ported: models come from `models` or the builtin registry.

public func zaiCodingCnProvider(models: [AnyModel]? = nil) -> Provider {
    builtinCreateProvider(CreateProviderOptions(
        id: "zai-coding-cn",
        name: "Z.AI Coding CN",
        baseUrl: "https://open.bigmodel.cn/api/coding/paas/v4",
        auth: ProviderAuth(apiKey: envApiKeyAuth("Z.AI Coding CN API key", ["ZAI_CODING_CN_API_KEY"])),
        models: models ?? getAllBuiltinModels("zai-coding-cn"),
        api: .single(openAICompletionsApi())
    ))
}
