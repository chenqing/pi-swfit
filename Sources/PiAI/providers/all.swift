import Foundation

// Port of packages/ai/src/providers/all.ts
//
// The generated catalogs (`models.generated.ts`, `*.models.ts`, `data/.manifest.json`) are not
// ported. Swift keeps an app-populated builtin registry instead: hosts load catalog data (for
// example decoded from JSON) and install it with `setBuiltinModels`; the provider factories read it.
//
// Not ported providers: amazon-bedrock, google-vertex, mistral, openai-codex, radius, typesafe.

/// Providers present in the builtin catalog.
public typealias BuiltinProvider = String

private struct BuiltinCatalog: Sendable {
    var models = JSMap<[AnyModel]>()
    var generatedAt: Int?
}

private let builtinCatalog = Locked(BuiltinCatalog())

/// Swift-only: install one provider's builtin catalog (models of every type, in catalog order).
public func setBuiltinModels(_ provider: BuiltinProvider, _ models: [AnyModel]) {
    builtinCatalog.withLock { $0.models[provider] = models }
}

/// Swift-only: set the generation timestamp shared by the builtin catalogs (ms since epoch).
public func setBuiltinModelDataGeneratedAt(_ generatedAt: Int?) {
    builtinCatalog.withLock { $0.generatedAt = generatedAt }
}

/// Swift-only: drop every installed builtin catalog.
public func clearBuiltinModels() {
    builtinCatalog.withLock { $0 = BuiltinCatalog() }
}

/// Read of one builtin chat model.
public func getBuiltinModel(_ provider: BuiltinProvider, _ modelId: String) -> Model? {
    getBuiltinModels(provider).first { $0.id == modelId }
}

// Not ported: getBuiltinImageModel, getBuiltinClassifierModel (image and classifier models).

public func getBuiltinProviders() -> [BuiltinProvider] {
    builtinCatalog.withLock { $0.models.keys }
}

/// Generation timestamp shared by all built-in provider catalogs.
public func getBuiltinModelDataGeneratedAt() -> Int? {
    builtinCatalog.withLock { $0.generatedAt }
}

public func getBuiltinModels(_ provider: BuiltinProvider) -> [Model] {
    getAllBuiltinModels(provider).filter { isModelType($0, "chat") }
}

// Not ported: getBuiltinImageModels, getBuiltinClassifierModels.

public func getAllBuiltinModels(_ provider: BuiltinProvider) -> [AnyModel] {
    builtinCatalog.withLock { $0.models[provider] } ?? []
}

/// `createProvider` for factories whose `api` is always present, so it cannot throw.
func builtinCreateProvider(_ options: CreateProviderOptions) -> Provider {
    do {
        return try createProvider(options)
    } catch {
        preconditionFailure("builtin provider \(options.id): \(errorMessage(error))")
    }
}

/// All built-in providers, freshly constructed.
public func builtinProviders() -> [Provider] {
    [
        // Not ported: amazonBedrockProvider()
        antLingProvider(),
        anthropicProvider(),
        azureProvider(),
        basetenProvider(),
        cerebrasProvider(),
        cloudflareAIGatewayProvider(),
        cloudflareWorkersAIProvider(),
        deepseekProvider(),
        fireworksProvider(),
        githubCopilotProvider(),
        googleProvider(),
        // Not ported: googleVertexProvider()
        groqProvider(),
        huggingfaceProvider(),
        kimiCodingProvider(),
        metaProvider(),
        minimaxProvider(),
        minimaxCnProvider(),
        // Not ported: mistralProvider()
        moonshotaiProvider(),
        moonshotaiCnProvider(),
        nvidiaProvider(),
        openaiProvider(),
        // Not ported: openaiCodexProvider()
        opencodeProvider(),
        opencodeGoProvider(),
        openrouterProvider(),
        qwenTokenPlanProvider(),
        qwenTokenPlanCnProvider(),
        qwenTokenPlanIndividualProvider(),
        // Not ported: radiusProvider()
        togetherProvider(),
        // Not ported: typesafeProvider()
        vercelAIGatewayProvider(),
        xaiProvider(),
        xiaomiProvider(),
        xiaomiTokenPlanAmsProvider(),
        xiaomiTokenPlanCnProvider(),
        xiaomiTokenPlanSgpProvider(),
        zaiProvider(),
        zaiCodingCnProvider(),
    ]
}

/// A `Models` collection with every built-in provider registered.
public func builtinModels(_ options: CreateModelsOptions? = nil) -> any MutableModels {
    let models = createModels(options)
    for provider in builtinProviders() {
        models.setProvider(provider)
    }
    return models
}
