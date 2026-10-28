import Foundation
import Testing
@testable import PiAI

// Port of packages/ai/test/openrouter-user-models.test.ts
// `vi.spyOn(globalThis, "fetch")` becomes the `fetch:` parameter of `personalizeOpenRouterCatalog`.

private func chatModel(_ id: String) -> Model {
    Model(
        id: id,
        name: id,
        api: "openai-completions",
        provider: "openrouter",
        baseUrl: "https://openrouter.ai/api/v1",
        reasoning: false,
        input: ["text"],
        cost: ModelCost(input: 1, output: 2, cacheRead: 0.1, cacheWrite: 0),
        contextWindow: 200_000,
        maxTokens: 50_000
    )
}

private let zeroCost = ModelCost(input: 0, output: 0, cacheRead: 0, cacheWrite: 0)

private let imageModel: AnyModel = {
    var model = Model(id: "image", name: "image", api: "openrouter-images", provider: "openrouter", baseUrl: "https://openrouter.ai/api/v1", cost: zeroCost)
    model.type = "image"
    return model
}()

private let classifierModel: AnyModel = {
    var model = Model(id: "classifier", name: "classifier", api: "typesafe-system-one", provider: "openrouter", baseUrl: "https://openrouter.ai/api/v1",
                      cost: zeroCost, contextWindow: 64_000)
    model.type = "classifier"
    return model
}()

private func refreshContext() -> RefreshModelsContext {
    RefreshModelsContext(
        credential: .apiKey(ApiKeyCredential(key: "sk-or-test")),
        publish: { _ in true },
        allowNetwork: true,
        signal: AbortController().signal
    )
}

private func stubUserModels(_ response: FetchResponse, _ requests: Locked<[FetchRequest]>? = nil) -> FetchFunction {
    { request in
        requests?.withLock { $0.append(request) }
        return response
    }
}

@Suite("personalizeOpenRouterCatalog")
struct OpenRouterUserModelsTests {
    @Test("keeps only the key's chat models, with the key's limits and prices")
    func keepsKeyModels() async throws {
        let data = """
        {"data": [
          {"id": "listed", "context_length": 1000000,
           "top_provider": {"context_length": 262144, "max_completion_tokens": 32768},
           "pricing": {"prompt": "0.000003", "completion": "0.000015"}},
          {"id": "no-limits", "context_length": 0, "top_provider": {"context_length": null, "max_completion_tokens": null}},
          {"id": "router", "pricing": {"prompt": "-1", "completion": "-1"}}
        ]}
        """
        let requests = Locked<[FetchRequest]>([])
        let catalog: [AnyModel] = [
            chatModel("listed"),
            chatModel("no-limits"),
            chatModel("router"),
            chatModel("blocked"),
            imageModel,
            classifierModel,
        ]

        let result = try await personalizeOpenRouterCatalog(catalog, refreshContext(), fetch: stubUserModels(gFetchResponse(status: 200, json: data), requests))

        #expect(result.map(\.id) == ["listed", "no-limits", "router", "image", "classifier"])
        #expect(result[0].contextWindow == 262_144)
        #expect(result[0].maxTokens == 32_768)
        #expect(result[0].cost == ModelCost(input: 3, output: 15, cacheRead: 0, cacheWrite: 0))
        #expect(result[1].contextWindow == 200_000)
        #expect(result[1].maxTokens == 50_000)
        #expect(result[1].cost == chatModel("x").cost)
        #expect(result[2].cost == zeroCost)
        // /models/user lists text models only, so image and classifier models are not filtered.
        #expect(result[3].type == "image")
        #expect(result[4].type == "classifier")

        let request = try #require(requests.current.first)
        #expect(request.url.absoluteString == "https://openrouter.ai/api/v1/models/user")
        #expect(request.headers.get("authorization") == "Bearer sk-or-test")
    }

    @Test("returns the catalog unchanged when the endpoint rejects the key or is missing", arguments: [401, 403, 404])
    func unchangedOnRejection(status: Int) async throws {
        // For example a proxy configured in models.json that rejects the key or has no /models/user:
        // the user keeps the full list instead of a failing refresh.
        let catalog: [AnyModel] = [chatModel("a")]

        let result = try await personalizeOpenRouterCatalog(catalog, refreshContext(), fetch: stubUserModels(gFetchResponse(status: status, json: "")))
        #expect(result.map(\.id) == ["a"])
        #expect(result[0].cost == catalog[0].cost)
    }

    @Test("rejects other failures and malformed bodies")
    func rejectsFailures() async {
        let catalog: [AnyModel] = [chatModel("a")]
        let failed = await gCaught { _ = try await personalizeOpenRouterCatalog(catalog, refreshContext(), fetch: stubUserModels(gFetchResponse(status: 500, json: ""))) }
        #expect(failed.map(errorMessage) == "OpenRouter model list request failed: 500")
        let malformed = await gCaught { _ = try await personalizeOpenRouterCatalog(catalog, refreshContext(), fetch: stubUserModels(gFetchResponse(status: 200, json: "{}"))) }
        #expect(malformed.map(errorMessage) == "Invalid OpenRouter model list response")
    }
}
