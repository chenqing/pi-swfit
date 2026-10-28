import Foundation

// Port of packages/ai/src/providers/nvidia.ts
// The generated `nvidia.models.ts` catalog is not ported: models come from `models` or the builtin registry.

public func nvidiaProvider(models: [AnyModel]? = nil) -> Provider {
    builtinCreateProvider(CreateProviderOptions(
        id: "nvidia",
        name: "NVIDIA",
        baseUrl: "https://integrate.api.nvidia.com/v1",
        auth: ProviderAuth(apiKey: envApiKeyAuth("NVIDIA API key", ["NVIDIA_API_KEY"])),
        models: models ?? getAllBuiltinModels("nvidia"),
        api: .single(openAICompletionsApi())
    ))
}
