import Foundation

// Port of packages/ai/src/providers/azure.ts
// The generated `azure.models.ts` catalog is not ported: models come from `models` or the builtin registry.

private func resolveAzureModel(_ model: Model, _ options: StreamOptions?) throws -> Model {
    var resolved = model
    resolved.baseUrl = try resolveAzureBaseUrl(model, options)
    return resolved
}

/// Send the deployment name as the request's model, keeping `model.id` as the catalog id.
private func withDeploymentName(_ model: Model, _ options: StreamOptions?) -> StreamOptions? {
    let deploymentName = resolveDeploymentName(model, options)
    if deploymentName == model.id { return options }
    let original = options?.onPayload
    var next = options ?? StreamOptions()
    next.onPayload = { payload, payloadModel in
        var object = payload.objectValue ?? JsonObject()
        object["model"] = .string(deploymentName)
        let params = JsonValue.object(object)
        return (try await original?(params, payloadModel)) ?? params
    }
    return next
}

/// Resolve the Azure endpoint and deployment before dispatch, inside `lazyStream` so an
/// unconfigured endpoint errors on the stream instead of throwing out of `stream()`.
private func azureStreams(_ streams: ProviderStreams) -> ProviderStreams {
    ProviderStreams(
        stream: { model, context, options in
            lazyStream(model, {
                streams.stream(try resolveAzureModel(model, options), context, withDeploymentName(model, options))
            })
        },
        streamSimple: { model, context, options in
            lazyStream(model, {
                streams.streamSimple(try resolveAzureModel(model, options), context, withDeploymentName(model, options))
            })
        }
    )
}

public func azureProvider(models: [AnyModel]? = nil) -> Provider {
    builtinCreateProvider(CreateProviderOptions(
        id: "azure",
        name: "Azure",
        auth: ProviderAuth(apiKey: envApiKeyAuth("Azure OpenAI API key", ["AZURE_OPENAI_API_KEY"])),
        models: models ?? getAllBuiltinModels("azure"),
        api: .byApi([
            "azure-openai-responses": azureOpenAIResponsesApi(),
            "openai-completions": azureStreams(openAICompletionsApi()),
        ])
    ))
}
