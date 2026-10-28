import Foundation

// Port of packages/ai/src/providers/huggingface.ts
// The generated `huggingface.models.ts` catalog is not ported: models come from `models` or the builtin registry.

public func huggingfaceProvider(models: [AnyModel]? = nil) -> Provider {
    builtinCreateProvider(CreateProviderOptions(
        id: "huggingface",
        name: "Hugging Face",
        baseUrl: "https://router.huggingface.co/v1",
        auth: ProviderAuth(apiKey: envApiKeyAuth("Hugging Face token", ["HF_TOKEN"])),
        models: models ?? getAllBuiltinModels("huggingface"),
        api: .single(openAICompletionsApi())
    ))
}
