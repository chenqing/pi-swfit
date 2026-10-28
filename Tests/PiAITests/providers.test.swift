import Foundation
import Testing
@testable import PiAI

// Port of packages/ai/test/providers.test.ts
//
// Not ported:
// - Catalog-data cases ("builtinModels registers every builtin provider with models" against the generated
//   catalog, constrained sampling, image resize/limits, Google effort levels, mid-conversation system
//   messages, proxied tool changes, Kimi pricing): the generated `*.models.ts` catalogs are not ported.
//   The registry mechanics are covered against an installed test catalog instead.
// - Bedrock and Vertex auth cases: amazon-bedrock and google-vertex are not ported.
// - "fauxProvider" suite: providers/faux belongs to another group.
// - image/classifier getters: image and classifier operations are not ported.

private func fakeAuthContext(_ env: [String: String], _ files: [String] = []) -> AuthContext {
    AuthContext(env: { env[$0] }, fileExists: { files.contains($0) })
}

private let neverAbortedSignal = AbortController().signal

private let context = normalizeContext(Context(messages: [.user(UserMessage(content: .string("hi"), timestamp: dateNow()))]))

private func catalogModel(_ provider: String, _ id: String, api: Api) -> Model {
    Model(id: id, name: id, api: api, provider: provider, baseUrl: "https://example.test/v1", reasoning: false, input: ["text"],
          cost: ModelCost(input: 0, output: 0, cacheRead: 0, cacheWrite: 0), contextWindow: 10000, maxTokens: 1000)
}

@Suite("builtin providers", .serialized)
struct BuiltinProvidersTests {
    @Test("builtinModels registers every builtin provider with models")
    func registersEveryProvider() {
        // Swift has no generated catalog; install one so the factories pick it up.
        setBuiltinModels("anthropic", [catalogModel("anthropic", "claude-haiku-4-5", api: "anthropic-messages")])
        defer { setBuiltinModels("anthropic", []) }

        let models = builtinModels()
        let providers = models.getProviders()
        #expect(providers.count == builtinProviders().count)
        #expect(providers.map(\.id).contains("anthropic"))

        let anthropic = models.getModel("anthropic", "claude-haiku-4-5")
        #expect(anthropic?.api == "anthropic-messages")
        #expect(getBuiltinModel("anthropic", "claude-haiku-4-5")?.provider == "anthropic")
        #expect(getBuiltinProviders().contains("anthropic"))

        for provider in providers {
            #expect(models.getAllModels(provider.id).allSatisfy { $0.provider == provider.id })
        }
    }

    @Test("returns empty results for unknown provider ids")
    func unknownProviderIds() {
        let unknownProvider = "not-a-provider"
        let unknownModel = "x"

        #expect(getBuiltinModel(unknownProvider, unknownModel) == nil)
        #expect(getBuiltinModels(unknownProvider).isEmpty)
        #expect(getAllBuiltinModels(unknownProvider).isEmpty)
        #expect(getModel(unknownProvider, unknownModel) == nil)
        #expect(getModels(unknownProvider).isEmpty)
    }

    @Test("resolves Anthropic bearer auth from env with auth token precedence")
    func anthropicBearer() async throws {
        let models = createModels(CreateModelsOptions(authContext: fakeAuthContext([
            "ANTHROPIC_AUTH_TOKEN": "auth-token",
            "ANTHROPIC_OAUTH_TOKEN": "oauth-token",
            "ANTHROPIC_API_KEY": "api-key",
        ])))
        models.setProvider(anthropicProvider())

        let result = try #require(try await models.getAuth("anthropic"))
        #expect(result.auth.apiKey == nil)
        #expect(gHeaders(result.auth.headers) == ["Authorization=Bearer auth-token"])
        #expect(result.env == nil)
        #expect(result.source == "ANTHROPIC_AUTH_TOKEN")
    }

    @Test("preserves Anthropic OAuth token precedence over the API key")
    func anthropicOAuthToken() async throws {
        let models = createModels(CreateModelsOptions(authContext: fakeAuthContext([
            "ANTHROPIC_API_KEY": "key",
            "ANTHROPIC_OAUTH_TOKEN": "oauth-token",
        ])))
        models.setProvider(anthropicProvider())

        let result = try await models.getAuth("anthropic")
        #expect(result?.auth.apiKey == "oauth-token")
        #expect(result?.source == "ANTHROPIC_OAUTH_TOKEN")
    }

    @Test("requires Cloudflare Workers AI account config and returns scoped env")
    func cloudflareWorkersAI() async throws {
        let catalog: [AnyModel] = [catalogModel("cloudflare-workers-ai", "@cf/test", api: "openai-completions")]
        let missingAccount = createModels(CreateModelsOptions(authContext: fakeAuthContext(["CLOUDFLARE_API_KEY": "cf-key"])))
        missingAccount.setProvider(cloudflareWorkersAIProvider(models: catalog))
        let model = try #require(missingAccount.getModels("cloudflare-workers-ai").first)
        #expect(try await missingAccount.getAuth(model.provider) == nil)

        let configured = createModels(CreateModelsOptions(authContext: fakeAuthContext([
            "CLOUDFLARE_API_KEY": "cf-key",
            "CLOUDFLARE_ACCOUNT_ID": "account-id",
        ])))
        configured.setProvider(cloudflareWorkersAIProvider(models: catalog))
        let result = try #require(try await configured.getAuth(model.provider))
        #expect(result.auth.apiKey == "cf-key")
        #expect(result.auth.headers == nil)
        #expect(result.auth.baseUrl == nil)
        #expect(result.env == ["CLOUDFLARE_ACCOUNT_ID": "account-id"])
    }

    @Test("requires Cloudflare AI Gateway account and gateway config and returns scoped env headers")
    func cloudflareAIGateway() async throws {
        let catalog: [AnyModel] = [catalogModel("cloudflare-ai-gateway", "openai/gpt-test", api: "openai-responses")]
        let missingGateway = createModels(CreateModelsOptions(authContext: fakeAuthContext([
            "CLOUDFLARE_API_KEY": "cf-key",
            "CLOUDFLARE_ACCOUNT_ID": "account-id",
        ])))
        missingGateway.setProvider(cloudflareAIGatewayProvider(models: catalog))
        let model = try #require(missingGateway.getModels("cloudflare-ai-gateway").first)
        #expect(try await missingGateway.getAuth(model.provider) == nil)

        let configured = createModels(CreateModelsOptions(authContext: fakeAuthContext([
            "CLOUDFLARE_API_KEY": "cf-key",
            "CLOUDFLARE_ACCOUNT_ID": "account-id",
            "CLOUDFLARE_GATEWAY_ID": "gateway-id",
        ])))
        configured.setProvider(cloudflareAIGatewayProvider(models: catalog))
        let result = try #require(try await configured.getAuth(model.provider))
        #expect(result.auth.apiKey == nil)
        #expect(gHeaders(result.auth.headers) == [
            "cf-aig-authorization=Bearer cf-key",
            "Authorization=<nil>",
            "x-api-key=<nil>",
        ])
        #expect(result.env == ["CLOUDFLARE_ACCOUNT_ID": "account-id", "CLOUDFLARE_GATEWAY_ID": "gateway-id"])
    }
}

@Suite("envApiKeyAuth")
struct EnvApiKeyAuthTests {
    @Test("prefers the stored credential key and falls back through env vars in order")
    func resolveOrder() async throws {
        let auth = envApiKeyAuth("Test key", ["FIRST_KEY", "SECOND_KEY"])

        let stored = try await auth.resolve(ApiKeyAuthInput(
            ctx: fakeAuthContext(["FIRST_KEY": "env"]),
            credential: ApiKeyCredential(key: "stored"),
            signal: neverAbortedSignal
        ))
        #expect(stored?.auth.apiKey == "stored")
        #expect(stored?.source == "stored credential")

        let second = try await auth.resolve(ApiKeyAuthInput(ctx: fakeAuthContext(["SECOND_KEY": "second"]), signal: neverAbortedSignal))
        #expect(second?.auth.apiKey == "second")
        #expect(second?.source == "SECOND_KEY")

        #expect(try await auth.resolve(ApiKeyAuthInput(ctx: fakeAuthContext([:]), signal: neverAbortedSignal)) == nil)
    }

    @Test("login prompts for a secret and returns an api-key credential")
    func loginPromptsForSecret() async throws {
        let auth = envApiKeyAuth("Test key", ["TEST_KEY"])
        let promptTypes = Locked<[String]>([])
        let credential = try await auth.login?(ProviderAuthInteraction(
            signal: neverAbortedSignal,
            prompt: { prompt in
                promptTypes.withLock { $0.append(prompt.type) }
                return "entered-key"
            },
            notify: { _ in }
        ))
        #expect(promptTypes.current == ["secret"])
        #expect(credential?.key == "entered-key")
        #expect(credential?.env == nil)
    }
}

private func recordingStreams(_ label: String, _ calls: Locked<[String]>) -> ProviderStreams {
    let respond: StreamFunction = { model, _, _ in
        calls.withLock { $0.append("\(label):\(model.id)") }
        return gRespond(model)
    }
    return ProviderStreams(stream: respond, streamSimple: respond)
}

private func testModel(_ api: String, _ id: String, provider: String = "mixed") -> Model {
    Model(id: id, name: id, api: api, provider: provider, baseUrl: "https://example.test/v1", reasoning: false, input: ["text"],
          cost: ModelCost(input: 0, output: 0, cacheRead: 0, cacheWrite: 0), contextWindow: 10000, maxTokens: 1000)
}

private let emptyAuth = ProviderAuth(apiKey: ApiKeyAuth(name: "Test", resolve: { _ in AuthResult(auth: ModelAuth()) }))

@Suite("createProvider")
struct CreateProviderTests {
    @Test("lazily exposes only declared deferred capabilities")
    func lazyDeferredCapabilities() async throws {
        let loads = Locked(0)
        var streams = recordingStreams("deferred", Locked([]))
        let streamSimple = streams.streamSimple
        streams.fetchDeferred = { model, _, _ in streamSimple(model, context, nil) }
        let loaded = streams
        let api = lazyApi({
            loads.withLock { $0 += 1 }
            return loaded
        }, LazyApiCapabilities(fetchDeferred: true))
        let model = testModel("api-a", "model-a")
        let handle = DeferredHandle(provider: model.provider, modelId: model.id, api: model.api, id: "response-1")

        #expect(loads.current == 0)
        #expect(api.cancelDeferred == nil)
        let fetchDeferred = try #require(api.fetchDeferred)
        #expect(await fetchDeferred(model, handle, nil).result().stopReason == .stop)
        #expect(loads.current == 1)
    }

    @Test("dispatches on model.api for mixed-API providers")
    func mixedApiDispatch() async throws {
        let calls = Locked<[String]>([])
        let provider = try createProvider(CreateProviderOptions(
            id: "mixed",
            auth: emptyAuth,
            models: [testModel("api-a", "model-a"), testModel("api-b", "model-b")],
            api: .byApi(["api-a": recordingStreams("a", calls), "api-b": recordingStreams("b", calls)])
        ))
        let models = createModels()
        models.setProvider(provider)

        _ = await models.completeSimple(testModel("api-a", "model-a"), Context(messages: context.messages))
        _ = await models.completeSimple(testModel("api-b", "model-b"), Context(messages: context.messages))
        #expect(calls.current == ["a:model-a", "b:model-b"])
    }

    @Test("merges provider-resolved env into stream options")
    func mergesProviderEnv() async throws {
        let captured = Locked<(env: ProviderEnv?, apiKey: String?)>((nil, nil))
        let envModel = testModel("api-a", "model-a", provider: "env-provider")
        let capture: StreamFunction = { model, _, options in
            captured.withLock { $0 = (options?.env, options?.apiKey) }
            return gRespond(model)
        }
        let provider = try createProvider(CreateProviderOptions(
            id: "env-provider",
            auth: ProviderAuth(apiKey: ApiKeyAuth(name: "Test", resolve: { _ in
                AuthResult(auth: ModelAuth(apiKey: "provider-key"), env: ["PROVIDER_ONLY": "provider", "SHARED": "provider"])
            })),
            models: [envModel],
            api: .single(ProviderStreams(stream: capture, streamSimple: capture))
        ))
        let models = createModels()
        models.setProvider(provider)

        var options = SimpleStreamOptions()
        options.apiKey = "request-key"
        options.env = ["REQUEST_ONLY": "request", "SHARED": "request"]
        _ = await models.completeSimple(envModel, Context(messages: context.messages), options)

        #expect(captured.current.apiKey == "request-key")
        #expect(captured.current.env == ["PROVIDER_ONLY": "provider", "REQUEST_ONLY": "request", "SHARED": "request"])
    }

    @Test("applies resolved request options to deferred fetch and cancellation")
    func deferredRequestOptions() async throws {
        let fetched = Locked<(model: Model?, options: DeferredFetchOptions?)>((nil, nil))
        let cancelled = Locked<DeferredCancelOptions?>(nil)
        let deferredModel = testModel("api-a", "model-a", provider: "deferred-provider")
        var streams = recordingStreams("deferred", Locked([]))
        let streamSimple = streams.streamSimple
        streams.fetchDeferred = { model, _, options in
            fetched.withLock { $0 = (model, options) }
            return streamSimple(model, context, nil)
        }
        streams.cancelDeferred = { _, _, options in
            cancelled.withLock { $0 = options }
        }
        let provider = try createProvider(CreateProviderOptions(
            id: "deferred-provider",
            auth: ProviderAuth(apiKey: ApiKeyAuth(name: "Test", resolve: { _ in
                AuthResult(
                    auth: ModelAuth(
                        apiKey: "provider-key",
                        headers: [("Authorization", "Bearer provider"), ("X-Shared", "provider")],
                        baseUrl: "https://resolved.test/v1"
                    ),
                    env: ["PROVIDER_ONLY": "provider", "SHARED": "provider"]
                )
            })),
            models: [deferredModel],
            api: .single(streams)
        ))
        let models = createModels()
        models.setProvider(provider)
        let handle = DeferredHandle(provider: deferredModel.provider, modelId: deferredModel.id, api: deferredModel.api, id: "response-1")

        var fetchOptions = DeferredFetchOptions()
        fetchOptions.wait = 50
        fetchOptions.timeoutMs = 100
        fetchOptions.apiKey = "request-key"
        fetchOptions.headers = [("X-Request", "request"), ("x-shared", "request")]
        fetchOptions.env = ["REQUEST_ONLY": "request", "SHARED": "request"]
        _ = await models.fetchDeferred(deferredModel, handle, fetchOptions, transforms: ModelsRequestTransforms(transformHeaders: { $0 + [("X-Transformed", "yes")] }))
        var cancelOptions = DeferredCancelOptions()
        cancelOptions.timeoutMs = 200
        try await models.cancelDeferred(deferredModel, handle, cancelOptions, transforms: ModelsRequestTransforms(transformHeaders: { $0 + [("X-Cancel", "yes")] }))

        #expect(fetched.current.model?.baseUrl == "https://resolved.test/v1")
        let fetchedOptions = try #require(fetched.current.options)
        #expect(fetchedOptions.wait == 50)
        #expect(fetchedOptions.timeoutMs == 100)
        #expect(fetchedOptions.apiKey == "request-key")
        #expect(Set(gHeaders(fetchedOptions.headers) ?? []) == [
            "Authorization=Bearer provider",
            "X-Request=request",
            "x-shared=request",
            "X-Transformed=yes",
        ])
        #expect(fetchedOptions.env == ["PROVIDER_ONLY": "provider", "REQUEST_ONLY": "request", "SHARED": "request"])

        let cancelledOptions = try #require(cancelled.current)
        #expect(cancelledOptions.timeoutMs == 200)
        #expect(cancelledOptions.apiKey == "provider-key")
        #expect(Set(gHeaders(cancelledOptions.headers) ?? []) == ["Authorization=Bearer provider", "X-Shared=provider", "X-Cancel=yes"])
        #expect(cancelledOptions.env == ["PROVIDER_ONLY": "provider", "SHARED": "provider"])
    }

    @Test("produces a stream error for a model whose api has no implementation")
    func missingApiImplementation() async throws {
        let provider = try createProvider(CreateProviderOptions(
            id: "mixed",
            auth: emptyAuth,
            models: [testModel("api-a", "model-a")],
            api: .byApi(["api-a": recordingStreams("a", Locked([]))])
        ))
        let result = await provider.streamSimple(testModel("api-ghost", "model-x"), context, nil).result()
        #expect(result.stopReason == .error)
        #expect(result.errorMessage?.contains("no API implementation") == true)
    }

    @Test("lets a newer dynamic refresh bypass and supersede older network work")
    func newerRefreshSupersedes() async throws {
        let fetches = Locked(0)
        let firstStarted = GGate()
        let firstBlocked = GGate()
        let provider = try createProvider(CreateProviderOptions(
            id: "dynamic",
            auth: emptyAuth,
            models: [],
            fetchModels: { _ in
                let current = fetches.withLock { count -> Int in
                    count += 1
                    return count
                }
                if current == 1 {
                    firstStarted.open()
                    await firstBlocked.wait()
                }
                return [testModel("api-a", "listed-\(current)", provider: "dynamic")]
            },
            api: .single(recordingStreams("a", Locked([])))
        ))

        let store = InMemoryModelsStore()
        let models = createModels(CreateModelsOptions(modelsStore: store))
        models.setProvider(provider)
        #expect(try provider.getModels().isEmpty)

        let first = Task { try await models.refresh(ModelsRefreshOptions(providers: ["dynamic"])) }
        await firstStarted.wait()
        let second = try await models.refresh(ModelsRefreshOptions(providers: ["dynamic"]))
        #expect(second.aborted == false)
        #expect(try await first.value.aborted == false)
        #expect(fetches.current == 2)
        #expect(try provider.getModels().map(\.id) == ["listed-2"])
        #expect(try await store.read("dynamic")?.models.map(\.id) == ["listed-2"])

        firstBlocked.open()
        try await Task.sleep(nanoseconds: 10_000_000)
        #expect(try provider.getModels().map(\.id) == ["listed-2"])
        #expect(try await store.read("dynamic")?.models.map(\.id) == ["listed-2"])
    }
}

// Swift replacement for packages/ai/test/lazy-module-load.test.ts, which probes Node's dynamic SDK
// imports. These cover the lazyStream contract that the lazy API wrappers rely on.
@Suite("lazyStream")
struct LazyStreamTests {
    @Test("terminates the stream with an error event when setup fails")
    func setupFailure() async {
        let model = testModel("api-a", "model-a")
        let events = Locked<[String]>([])
        let results = Locked(0)
        let stream = lazyStream(model, { throw PiError("setup failed") }, LazyStreamObserver(
            onEvent: { event in events.withLock { $0.append(event.type) } },
            onResult: { _ in results.withLock { $0 += 1 } }
        ))
        var seen: [String] = []
        for await event in stream { seen.append(event.type) }
        let result = await stream.result()

        #expect(seen == ["error"])
        #expect(result.stopReason == .error)
        #expect(result.errorMessage == "setup failed")
        #expect(result.provider == model.provider)
        #expect(events.current == ["error"])
        #expect(results.current == 1)
    }

    @Test("forwards the inner stream and observes its result once")
    func forwardsInnerStream() async {
        let model = testModel("api-a", "model-a")
        let events = Locked<[String]>([])
        let results = Locked<[String?]>([])
        let stream = lazyStream(model, { gRespond(model, "forwarded") }, LazyStreamObserver(
            onEvent: { event in events.withLock { $0.append(event.type) } },
            onResult: { message in results.withLock { $0.append(message?.model) } }
        ))
        var seen: [String] = []
        for await event in stream { seen.append(event.type) }
        let result = await stream.result()

        #expect(seen == ["start", "done"])
        #expect(result.stopReason == .stop)
        #expect(events.current == ["start", "done"])
        #expect(results.current == ["model-a"])
    }
}
