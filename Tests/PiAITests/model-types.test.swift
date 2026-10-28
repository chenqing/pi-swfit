import Foundation
import Testing
@testable import PiAI

// Port of packages/ai/test/model-types.test.ts
// `fauxProvider` is not ported (providers/faux belongs to another group); the handwritten provider
// answers through `gRespond` instead. Not ported: "built-in catalog getters" (a compile-time check on
// generated catalog literal types, which do not exist in Swift).

private func chatModel(_ provider: String, _ id: String) -> Model {
    Model(
        id: id,
        name: id,
        api: "test-chat",
        provider: provider,
        baseUrl: "https://example.test/v1",
        reasoning: false,
        input: ["text"],
        cost: ModelCost(input: 0, output: 0, cacheRead: 0, cacheWrite: 0),
        contextWindow: 1000,
        maxTokens: 100
    )
}

private func imageModel(_ provider: String, _ id: String) -> AnyModel {
    var model = Model(id: id, name: id, api: "test-images", provider: provider, baseUrl: "https://example.test/v1",
                      input: ["text"], cost: ModelCost(input: 0, output: 0, cacheRead: 0, cacheWrite: 0))
    model.type = "image"
    return model
}

private func typed(_ model: AnyModel, _ type: ModelType) -> AnyModel {
    var model = model
    model.type = type
    return model
}

private let noAuth = ProviderAuth(apiKey: ApiKeyAuth(name: "Test", resolve: { _ in AuthResult(auth: ModelAuth()) }))
private let chatStreams = ProviderStreams(
    stream: { _, _, _ in AssistantMessageEventStream() },
    streamSimple: { _, _, _ in AssistantMessageEventStream() }
)

@Suite("chat models without a type")
struct ChatModelsWithoutTypeTests {
    @Test("work through a handwritten provider without getAllModels")
    func handwrittenProvider() async throws {
        let providerModels = [chatModel("handwritten", "handwritten-model")]
        let handwritten = Provider(
            id: "handwritten",
            name: "Handwritten",
            auth: noAuth,
            getModels: { providerModels },
            stream: { model, _, _ in gRespond(model, "hi") },
            streamSimple: { model, _, _ in gRespond(model, "hi") }
        )
        let models = createModels()
        models.setProvider(handwritten)

        let model = try #require(models.getModel("handwritten", providerModels[0].id))
        #expect(model.type == nil)
        #expect(getModelType(model) == "chat")
        #expect(hasApi(model, model.api))
        #expect(modelsAreEqual(model, typed(model, "chat")))
        #expect(!modelsAreEqual(model, imageModel(model.provider, model.id)))
        #expect(models.getModelsOfType("chat", "handwritten").map(\.id) == providerModels.map(\.id))
        #expect(models.getAllModels("handwritten").map(\.id) == providerModels.map(\.id))
        #expect(models.getModelsOfType("image", "handwritten").isEmpty)

        let result = await models.complete(model, Context(messages: [.user(UserMessage(content: .string("hi"), timestamp: 0))]))
        #expect(result.stopReason == .stop)
    }

    @Test("narrow mixed lists with isModelType")
    func narrowMixedLists() {
        let mixed: [AnyModel] = [chatModel("p", "c"), typed(chatModel("p", "typed"), "chat"), imageModel("p", "i")]
        #expect(mixed.filter { isModelType($0, "chat") }.map(\.id) == ["c", "typed"])
        #expect(mixed.filter { isModelType($0, "image") }.map(\.id) == ["i"])
        #expect(mixed.filter { isModelType($0, "classifier") }.isEmpty)
    }
}

@Suite("stored and fetched models of unknown types")
struct UnknownModelTypesTests {
    @Test("are dropped instead of failing the refresh")
    func droppedOnRefresh() async throws {
        let modelsStore = InMemoryModelsStore()
        try await modelsStore.write("dyn", ModelsStoreEntry(models: [
            chatModel("dyn", "stored-chat"),
            imageModel("dyn", "stored-image"),
            typed(chatModel("dyn", "future-embedding"), "embedding"),
            typed(imageModel("dyn", "future-video"), "video"),
        ]))

        let fetched = Locked<[AnyModel]>([])
        let models = createModels(CreateModelsOptions(modelsStore: modelsStore))
        models.setProvider(try createProvider(CreateProviderOptions(
            id: "dyn",
            auth: noAuth,
            models: [],
            fetchModels: { _ in fetched.current },
            api: .single(chatStreams)
        )))

        let restored = try await models.refresh(ModelsRefreshOptions(allowNetwork: false, providers: ["dyn"]))
        #expect(restored.errors.isEmpty)
        #expect(models.getAllModels("dyn").map(\.id) == ["stored-chat", "stored-image"])

        fetched.withLock { $0 = [chatModel("dyn", "fetched-chat"), typed(imageModel("dyn", "fetched-video"), "video")] }
        let refreshed = try await models.refresh(ModelsRefreshOptions(providers: ["dyn"]))
        #expect(refreshed.errors.isEmpty)
        #expect(models.getAllModels("dyn").map(\.id) == ["fetched-chat"])
        #expect(try await modelsStore.read("dyn")?.models.map(\.id) == ["fetched-chat"])
    }
}
