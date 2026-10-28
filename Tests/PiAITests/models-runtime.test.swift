import Foundation
import Testing
@testable import PiAI

// Port of packages/ai/test/models-runtime.test.ts

private func testModel(_ provider: String, _ id: String) -> Model {
    Model(
        id: id,
        name: id,
        api: "test-api",
        provider: provider,
        baseUrl: "https://example.test/v1",
        reasoning: false,
        input: ["text"],
        cost: ModelCost(input: 0, output: 0, cacheRead: 0, cacheWrite: 0),
        contextWindow: 10000,
        maxTokens: 1000
    )
}

private struct ProviderCall: Sendable {
    var model: Model
    var options: StreamOptions?
}

/// Ambient auth for keyless test providers; reports "configured" with no auth values.
private let ambientAuth = ApiKeyAuth(name: "Ambient", resolve: { _ in AuthResult(auth: ModelAuth()) })

private func testProvider(
    id: String,
    models: [Model]? = nil,
    auth: ProviderAuth? = nil,
    getModels: (@Sendable () throws -> [Model])? = nil,
    refreshModels: (@Sendable (RefreshModelsContext) async throws -> Void)? = nil,
    calls: Locked<[ProviderCall]>? = nil
) -> Provider {
    let models = models ?? [testModel(id, "model-a")]
    let respond: @Sendable (Model, StreamOptions?) -> AssistantMessageEventStream = { model, options in
        calls?.withLock { $0.append(ProviderCall(model: model, options: options)) }
        return gRespond(model)
    }
    return Provider(
        id: id,
        name: id,
        auth: auth ?? ProviderAuth(apiKey: ambientAuth),
        getModels: getModels ?? { models },
        refreshModels: refreshModels,
        stream: { model, _, options in respond(model, options) },
        streamSimple: { model, _, options in respond(model, options) }
    )
}

private let context = gUserContext()

private func envKeyAuth(_ key: String?) -> ApiKeyAuth {
    ApiKeyAuth(name: "Test API key", resolve: { input in
        guard let resolved = input.credential?.key ?? key else { return nil }
        return AuthResult(auth: ModelAuth(apiKey: resolved), source: input.credential != nil ? "stored" : "env")
    })
}

private func testOAuth(
    refresh: (@Sendable (OAuthCredential, AbortSignal) async throws -> OAuthCredential)? = nil
) -> OAuthAuth {
    OAuthAuth(
        name: "Test OAuth",
        login: { _, _ in throw PiError("not used") },
        refresh: refresh ?? { credential, _ in credential },
        toAuth: { credential in ModelAuth(apiKey: credential.access) }
    )
}

private func emptyStreams() -> ProviderStreams {
    ProviderStreams(stream: { _, _, _ in AssistantMessageEventStream() }, streamSimple: { _, _, _ in AssistantMessageEventStream() })
}

private func noInteraction(signal: AbortSignal? = nil) -> AuthInteraction {
    AuthInteraction(signal: signal, prompt: { _ in "unused" }, notify: { _ in })
}

/// A credential store whose methods are supplied as closures (an object literal upstream).
private struct ClosureCredentialStore: CredentialStore {
    var readFn: @Sendable (String) async throws -> Credential?
    var listFn: @Sendable () async throws -> [CredentialInfo]
    var modifyFn: @Sendable (String, @escaping @Sendable (Credential?) async throws -> Credential?) async throws -> Credential?
    var deleteFn: @Sendable (String) async throws -> Void
    func read(_ providerId: String, _ options: AuthOperationOptions?) async throws -> Credential? { try await readFn(providerId) }
    func list(_ options: AuthOperationOptions?) async throws -> [CredentialInfo] { try await listFn() }
    func modify(_ providerId: String, _ fn: @escaping @Sendable (Credential?) async throws -> Credential?, _ options: AuthOperationOptions?) async throws -> Credential? {
        try await modifyFn(providerId, fn)
    }
    func delete(_ providerId: String, _ options: AuthOperationOptions?) async throws { try await deleteFn(providerId) }
}

private struct ClosureModelsStore: ModelsStore {
    var readFn: @Sendable (String, ModelsStoreOperationOptions?) async throws -> ModelsStoreEntry?
    var writeFn: @Sendable (String, ModelsStoreEntry, ModelsStoreOperationOptions?) async throws -> Void
    var deleteFn: @Sendable (String, ModelsStoreOperationOptions?) async throws -> Void
    func read(_ providerId: String, _ options: ModelsStoreOperationOptions?) async throws -> ModelsStoreEntry? { try await readFn(providerId, options) }
    func write(_ providerId: String, _ entry: ModelsStoreEntry, _ options: ModelsStoreOperationOptions?) async throws { try await writeFn(providerId, entry, options) }
    func delete(_ providerId: String, _ options: ModelsStoreOperationOptions?) async throws { try await deleteFn(providerId, options) }
}

@Suite("Models runtime")
struct ModelsRuntimeTests {
    @Test("enumerates credential metadata without exposing secrets")
    func enumeratesCredentialMetadata() async throws {
        let credentials = InMemoryCredentialStore()
        _ = try await credentials.modify("api-provider") { _ in gApiKey("secret") }
        _ = try await credentials.modify("oauth-provider") { _ in gOAuth(access: "access", refresh: "refresh", expires: dateNow() + 60_000) }

        #expect(try await credentials.list() == [
            CredentialInfo(providerId: "api-provider", type: "api_key"),
            CredentialInfo(providerId: "oauth-provider", type: "oauth"),
        ])
    }

    @Test("applies request-wide pricing tiers above the configured input threshold")
    func pricingTiers() {
        var model = testModel("openai", "gpt-5.6-sol")
        model.cost = ModelCost(
            input: 5,
            output: 30,
            cacheRead: 0.5,
            cacheWrite: 6.25,
            tiers: [ModelCostTier(inputTokensAbove: 272000, input: 10, output: 45, cacheRead: 1, cacheWrite: 12.5)]
        )
        func createUsage(_ cacheWrite: Int) -> Usage {
            Usage(input: 200000, output: 100000, cacheRead: 72000, cacheWrite: cacheWrite, totalTokens: 372000 + cacheWrite)
        }

        var shortUsage = createUsage(0)
        let short = calculateCost(model, &shortUsage)
        #expect(short.input == 1)
        #expect(short.output == 3)
        #expect(short.cacheRead == 0.036)
        #expect(short.cacheWrite == 0)

        var longUsage = createUsage(1)
        let long = calculateCost(model, &longUsage)
        #expect(long.input == 2)
        #expect(long.output == 4.5)
        #expect(long.cacheRead == 0.072)
        #expect(long.cacheWrite == 0.0000125)
    }

    @Test("registers, replaces, and deletes providers")
    func registersReplacesDeletes() {
        let models = createModels()
        models.setProvider(testProvider(id: "p1"))
        models.setProvider(testProvider(id: "p2"))
        #expect(models.getProviders().map(\.id) == ["p1", "p2"])

        var replacement = testProvider(id: "p1")
        replacement.name = "replacement"
        models.setProvider(replacement)
        #expect(models.getProvider("p1")?.name == "replacement")
        #expect(models.getProviders().count == 2)

        models.deleteProvider("p1")
        #expect(models.getProvider("p1") == nil)

        models.clearProviders()
        #expect(models.getProviders().count == 0)
    }

    @Test("lists and finds models per provider")
    func listsAndFinds() {
        let models = createModels()
        models.setProvider(testProvider(id: "p1", models: [testModel("p1", "m1"), testModel("p1", "m2")]))
        models.setProvider(testProvider(id: "p2", models: [testModel("p2", "m3")]))

        #expect(models.getModels().map(\.id) == ["m1", "m2", "m3"])
        #expect(models.getModels("p1").map(\.id) == ["m1", "m2"])
        #expect(models.getModels("nope").count == 0)
        #expect(models.getModel("p2", "m3")?.id == "m3")
        #expect(models.getModel("p2", "missing") == nil)

        // hasApi() checks dynamically looked-up models at runtime
        let found = models.getModel("p2", "m3")
        #expect(found.map { hasApi($0, "openai-completions") } == false)
        #expect(found.map { hasApi($0, "test-api") } == true)
    }

    @Test("keeps chat reads independent from the all-model catalog")
    func chatReadsIndependent() async throws {
        var provider = testProvider(id: "chat-only")
        provider.getAllModels = { throw PiError("all models unavailable") }
        let models = createModels()
        models.setProvider(provider)

        #expect(models.getModels("chat-only").map(\.id) == ["model-a"])
        #expect(models.getModel("chat-only", "model-a")?.id == "model-a")
        #expect(try await models.getAvailable("chat-only").map(\.id) == ["model-a"])
        #expect(models.getAllModels("chat-only").isEmpty)
    }

    @Test("swallows provider source failures for both all-provider and single-provider listing")
    func swallowsSourceFailures() {
        let models = createModels()
        models.setProvider(testProvider(id: "broken", getModels: { throw PiError("boom") }))
        models.setProvider(testProvider(id: "ok", models: [testModel("ok", "m1")]))

        #expect(models.getModels().map(\.id) == ["m1"])
        #expect(models.getModels("broken").isEmpty)
        // precise failures come from the provider directly
        #expect(throws: PiError("boom")) { _ = try models.getProvider("broken")?.getModels() }
    }

    @Test("refresh() updates every configured dynamic provider and reports failures")
    func refreshUpdatesDynamicProviders() async throws {
        let list = Locked([testModel("dyn", "before")])
        let refreshes = Locked(0)
        let models = createModels()
        models.setProvider(testProvider(
            id: "dyn",
            getModels: { list.current },
            refreshModels: { refresh in
                if !refresh.allowNetwork { return }
                refreshes.withLock { $0 += 1 }
                _ = try await refresh.publish(ModelsPublication(update: {
                    list.withLock { $0 = [testModel("dyn", "after")] }
                }))
            }
        ))
        models.setProvider(testProvider(id: "static", models: [testModel("static", "s1")]))

        #expect(models.getModel("dyn", "before") != nil)
        let first = try await models.refresh()
        #expect(first.errors.isEmpty)
        #expect(refreshes.current == 1)
        #expect(models.getModel("dyn", "after") != nil)
        #expect(models.getModel("dyn", "before") == nil)

        models.setProvider(testProvider(id: "flaky", refreshModels: { context in
            if context.allowNetwork { throw PiError("fetch failed") }
        }))
        let second = try await models.refresh()
        #expect(refreshes.current == 2)
        #expect(second.errors["flaky"].map(errorMessage) == "fetch failed")
    }

    @Test("restricts refresh work to selected providers")
    func restrictsRefresh() async throws {
        let calls = Locked<[String]>([])
        let models = createModels()
        for id in ["one", "two"] {
            models.setProvider(testProvider(id: id, refreshModels: { context in
                calls.withLock { $0.append("\(id):\(context.allowNetwork ? "network" : "cache")") }
            }))
        }

        let result = try await models.refresh(ModelsRefreshOptions(providers: ["two", "unknown"]))

        #expect(result.errors.isEmpty)
        #expect(calls.current == ["two:cache", "two:network"])
    }

    @Test("restores cached models before waiting for network auth")
    func restoresCachedBeforeAuth() async throws {
        let store = InMemoryModelsStore()
        try await store.write("dynamic", ModelsStoreEntry(models: [testModel("dynamic", "cached")]))
        let authStarted = GGate()
        let blockedAuth = GGate()
        let provider = try createProvider(CreateProviderOptions(
            id: "dynamic",
            auth: ProviderAuth(apiKey: ApiKeyAuth(name: "Blocked auth", resolve: { _ in
                authStarted.open()
                await blockedAuth.wait()
                return AuthResult(auth: ModelAuth(apiKey: "key"))
            })),
            models: [],
            fetchModels: { _ in throw PiError("must not fetch") },
            api: .single(emptyStreams())
        ))
        let models = createModels(CreateModelsOptions(modelsStore: store))
        models.setProvider(provider)
        let controller = AbortController()
        let pending = Task { try await models.refresh(ModelsRefreshOptions(providers: ["dynamic"], signal: controller.signal)) }
        await authStarted.wait()

        #expect(models.getModel("dynamic", "cached") != nil)
        controller.abort()
        #expect(try await pending.value.aborted == true)
        blockedAuth.open()
    }

    @Test("lets providers choose persistent deletion and ephemeral publication atomically")
    func persistentDeletionAndEphemeralPublication() async throws {
        let entry = Locked<ModelsStoreEntry?>(ModelsStoreEntry(models: [testModel("dynamic", "stored")]))
        let store = ClosureModelsStore(
            readFn: { _, _ in entry.current },
            writeFn: { _, next, _ in entry.withLock { $0 = next } },
            deleteFn: { _, _ in entry.withLock { $0 = nil } }
        )
        let state = Locked("initial")
        let storedId = Locked<String?>(nil)
        let deletedBeforeUpdate = Locked<Bool?>(nil)
        let models = createModels(CreateModelsOptions(modelsStore: store))
        models.setProvider(testProvider(id: "dynamic", refreshModels: { context in
            storedId.withLock { $0 = context.stored?.models.first?.id }
            _ = try await context.publish(ModelsPublication(persist: .some(nil), update: {
                deletedBeforeUpdate.withLock { $0 = entry.current == nil }
                state.withLock { $0 = "deleted" }
            }))
            _ = try await context.publish(ModelsPublication(update: {
                state.withLock { $0 = "ephemeral" }
            }))
        }))

        let result = try await models.refresh(ModelsRefreshOptions(allowNetwork: false))

        #expect(storedId.current == "stored")
        #expect(deletedBeforeUpdate.current == true)
        #expect(result.errors.isEmpty)
        #expect(entry.current == nil)
        #expect(state.current == "ephemeral")
    }

    @Test("persists dynamic catalogs and restores them without network access")
    func persistsDynamicCatalogs() async throws {
        let credentials = InMemoryCredentialStore()
        let modelsStore = InMemoryModelsStore()
        _ = try await credentials.modify("dynamic") { _ in gApiKey("key") }
        func createDynamicProvider(_ fetchModels: (@Sendable () async throws -> [Model])?) throws -> Provider {
            try createProvider(CreateProviderOptions(
                id: "dynamic",
                auth: ProviderAuth(apiKey: envKeyAuth(nil)),
                models: [],
                fetchModels: fetchModels.map { fetch -> @Sendable (RefreshModelsContext) async throws -> [AnyModel] in
                    { _ in try await fetch() }
                },
                api: .single(emptyStreams())
            ))
        }

        let online = createModels(CreateModelsOptions(credentials: credentials, modelsStore: modelsStore))
        online.setProvider(try createDynamicProvider { [testModel("dynamic", "fetched")] })
        #expect(try await online.refresh().errors.isEmpty)
        #expect(online.getModel("dynamic", "fetched") != nil)

        let offline = createModels(CreateModelsOptions(credentials: credentials, modelsStore: modelsStore))
        offline.setProvider(try createDynamicProvider { throw PiError("must not fetch") })
        #expect(try await offline.refresh(ModelsRefreshOptions(allowNetwork: false)).errors.isEmpty)
        #expect(offline.getModel("dynamic", "fetched") != nil)
    }

    @Test("passes effective API-key credentials and refresh options while skipping unconfigured providers")
    func passesEffectiveCredentials() async throws {
        let effectiveCredential = Locked<Credential?>(nil)
        let forceRefresh = Locked<Bool?>(nil)
        let unconfiguredRefreshes = Locked(0)
        let models = createModels()
        models.setProvider(testProvider(id: "configured", auth: ProviderAuth(apiKey: envKeyAuth("ambient-key")), refreshModels: { context in
            if !context.allowNetwork { return }
            effectiveCredential.withLock { $0 = context.credential }
            forceRefresh.withLock { $0 = context.force }
        }))
        models.setProvider(testProvider(id: "unconfigured", auth: ProviderAuth(apiKey: envKeyAuth(nil)), refreshModels: { context in
            if context.allowNetwork { unconfiguredRefreshes.withLock { $0 += 1 } }
        }))

        _ = try await models.refresh(ModelsRefreshOptions(force: true))
        #expect(effectiveCredential.current == gApiKey("ambient-key"))
        #expect(forceRefresh.current == true)
        #expect(unconfiguredRefreshes.current == 0)
    }

    @Test("passes the registered provider's base URL, including wrapper overrides, to refreshModels")
    func passesRegisteredBaseUrl() async throws {
        let baseUrls = Locked<[String?]>([])
        var inner = testProvider(id: "dynamic", refreshModels: { context in
            baseUrls.withLock { $0.append(context.baseUrl) }
        })
        inner.baseUrl = "https://default.example.test/v1"
        let models = createModels()
        var wrapped = inner
        wrapped.baseUrl = "https://regional.example.test/v1"
        models.setProvider(wrapped)

        _ = try await models.refresh()
        #expect(baseUrls.current == ["https://regional.example.test/v1", "https://regional.example.test/v1"])
    }

    @Test("refreshes expired OAuth before refreshing models")
    func refreshesExpiredOAuthBeforeModels() async throws {
        let credentials = InMemoryCredentialStore()
        let modelRefreshCredential = Locked<Credential?>(nil)
        _ = try await credentials.modify("oauth-dynamic") { _ in gOAuth(access: "expired", refresh: "refresh", expires: 0) }
        let models = createModels(CreateModelsOptions(credentials: credentials))
        models.setProvider(testProvider(
            id: "oauth-dynamic",
            auth: ProviderAuth(oauth: testOAuth(refresh: { _, _ in
                OAuthCredentials(refresh: "rotated", access: "fresh", expires: dateNow() + 60_000)
            })),
            refreshModels: { context in
                if context.allowNetwork { modelRefreshCredential.withLock { $0 = context.credential } }
            }
        ))

        #expect(try await models.refresh().errors.isEmpty)
        #expect(modelRefreshCredential.current?.oauthCredential?.access == "fresh")
        #expect(modelRefreshCredential.current?.oauthCredential?.refresh == "rotated")
        let stored = try await credentials.read("oauth-dynamic")?.oauthCredential
        #expect(stored?.access == "fresh")
        #expect(stored?.refresh == "rotated")
    }

    @Test("persists an OAuth refresh that started before the model refresh was cancelled")
    func persistsOAuthRefreshAfterModelRefreshCancel() async throws {
        let credentials = InMemoryCredentialStore()
        _ = try await credentials.modify("p1") { _ in gOAuth(access: "old", refresh: "old-refresh", expires: 0) }
        let controller = AbortController()
        let models = createModels(CreateModelsOptions(credentials: credentials))
        models.setProvider(testProvider(
            id: "p1",
            auth: ProviderAuth(oauth: testOAuth(refresh: { credential, _ in
                controller.abort()
                var next = credential
                next.access = "new"; next.refresh = "new-refresh"; next.expires = dateNow() + 60_000
                return next
            })),
            refreshModels: { _ in }
        ))

        #expect(try await models.refresh(ModelsRefreshOptions(signal: controller.signal)).aborted == true)
        #expect(try await gWaitFor { try await credentials.read("p1")?.oauthCredential?.refresh == "new-refresh" })
    }

    @Test("always gives providers a concrete signal")
    func concreteSignal() async throws {
        let receivedSignal = Locked<AbortSignal?>(nil)
        let models = createModels()
        models.setProvider(testProvider(id: "dynamic", refreshModels: { context in
            receivedSignal.withLock { $0 = context.signal }
        }))

        let result = try await models.refresh()
        #expect(result.aborted == false)
        #expect(receivedSignal.current != nil)
        #expect(receivedSignal.current?.aborted == false)
    }

    @Test("binds model-store waits to the provider refresh signal")
    func bindsModelStoreWaits() async throws {
        let storageSignals = Locked<[AbortSignal?]>([])
        let store = ClosureModelsStore(
            readFn: { _, options in storageSignals.withLock { $0.append(options?.signal) }; return nil },
            writeFn: { _, _, options in storageSignals.withLock { $0.append(options?.signal) } },
            deleteFn: { _, options in storageSignals.withLock { $0.append(options?.signal) } }
        )
        let providerSignal = Locked<AbortSignal?>(nil)
        let models = createModels(CreateModelsOptions(modelsStore: store))
        models.setProvider(testProvider(id: "dynamic", auth: ProviderAuth(apiKey: envKeyAuth("key")), refreshModels: { context in
            providerSignal.withLock { $0 = context.signal }
            if !context.allowNetwork { return }
            _ = try await context.publish(ModelsPublication(persist: .some(ModelsStoreEntry(models: [testModel("dynamic", "fresh")]))))
        }))

        let result = try await models.refresh(ModelsRefreshOptions(providers: ["dynamic"]))

        #expect(result.errors.isEmpty)
        let signals = storageSignals.current
        #expect(signals.count == 3)
        #expect(signals.allSatisfy { $0 != nil && $0 === providerSignal.current })
    }

    @Test("returns aborted state without reporting cancellation as a provider error")
    func abortedWithoutProviderError() async throws {
        let controller = AbortController()
        let models = createModels()
        models.setProvider(testProvider(id: "dynamic", refreshModels: { context in
            controller.abort()
            if context.signal.aborted { return }
        }))

        let result = try await models.refresh(ModelsRefreshOptions(signal: controller.signal))
        #expect(result.aborted == true)
        #expect(result.errors.isEmpty)
    }

    @Test("stops waiting on abort when a provider ignores its signal")
    func stopsWaitingOnIgnoredSignal() async throws {
        let controller = AbortController()
        let started = GGate()
        let stalled = GGate()
        let calls = Locked(0)
        let models = createModels()
        models.setProvider(testProvider(id: "dynamic", refreshModels: { _ in
            let call = calls.withLock { $0 += 1; return $0 }
            if call != 1 { return }
            started.open()
            await stalled.wait()
            throw PiError("late provider failure")
        }))

        let pending = Task { try await models.refresh(ModelsRefreshOptions(signal: controller.signal)) }
        await started.wait()
        controller.abort()

        let result = try await pending.value
        #expect(result.aborted == true)
        #expect(result.errors.isEmpty)

        stalled.open()
        try await Task.sleep(nanoseconds: 10_000_000)
        #expect(result.errors.isEmpty)
    }

    @Test("rejects late publication from a superseded non-cooperative provider")
    func rejectsLatePublication() async throws {
        let store = InMemoryModelsStore()
        let state = Locked("initial")
        let calls = Locked(0)
        let firstStarted = GGate()
        let firstBlocked = GGate()
        let models = createModels(CreateModelsOptions(modelsStore: store))
        models.setProvider(testProvider(id: "dynamic", refreshModels: { context in
            if !context.allowNetwork { return }
            let current = calls.withLock { $0 += 1; return $0 }
            if current == 1 {
                firstStarted.open()
                await firstBlocked.wait()
            }
            let value = "generation-\(current)"
            _ = try await context.publish(ModelsPublication(
                persist: .some(ModelsStoreEntry(models: [testModel("dynamic", value)])),
                update: { state.withLock { $0 = value } }
            ))
        }))

        let first = Task { try await models.refresh(ModelsRefreshOptions(providers: ["dynamic"])) }
        await firstStarted.wait()
        let second = Task { try await models.refresh(ModelsRefreshOptions(providers: ["dynamic"])) }
        _ = try await second.value
        _ = try await first.value
        firstBlocked.open()
        try await Task.sleep(nanoseconds: 20_000_000)

        #expect(state.current == "generation-2")
        #expect(try await store.read("dynamic")?.models.first?.id == "generation-2")
    }

    @Test("passes caller signals to provider auth callbacks")
    func passesCallerSignals() async throws {
        let controller = AbortController()
        let received = Locked<[AbortSignal]>([])
        let apiKey = ApiKeyAuth(
            name: "Signal auth",
            login: { interaction in
                received.withLock { $0.append(interaction.signal) }
                return ApiKeyCredential(key: "saved")
            },
            check: { input in
                received.withLock { $0.append(input.signal) }
                return AuthCheck(type: "api_key")
            },
            resolve: { input in
                received.withLock { $0.append(input.signal) }
                return AuthResult(auth: ModelAuth(apiKey: "resolved"))
            }
        )
        let models = createModels()
        models.setProvider(testProvider(id: "p1", auth: ProviderAuth(apiKey: apiKey)))

        _ = try await models.checkAuth("p1", AuthOperationOptions(signal: controller.signal))
        _ = try await models.getAuth("p1", AuthResolutionOverrides(signal: controller.signal))
        _ = try await models.login("p1", "api_key", noInteraction(signal: controller.signal))

        let signals = received.current
        #expect(signals.count == 3)
        #expect(signals.allSatisfy { $0 === controller.signal })
    }

    @Test("stops waiting for non-cooperative auth callbacks")
    func stopsWaitingForNonCooperativeAuth() async throws {
        let checkStarted = GGate()
        let blockedCheck = GGate()
        let resolveStarted = GGate()
        let blockedResolve = GGate()
        let models = createModels()
        models.setProvider(testProvider(id: "p1", auth: ProviderAuth(apiKey: ApiKeyAuth(
            name: "Blocked auth",
            check: { _ in
                checkStarted.open()
                await blockedCheck.wait()
                return AuthCheck(type: "api_key")
            },
            resolve: { _ in
                resolveStarted.open()
                await blockedResolve.wait()
                return AuthResult(auth: ModelAuth(apiKey: "key"))
            }
        ))))

        let availableController = AbortController()
        let available = Task { try await models.getAvailable(nil, AuthOperationOptions(signal: availableController.signal)) }
        await checkStarted.wait()
        availableController.abort()
        #expect(gIsAbortError(await gCaught { _ = try await available.value }))

        let authController = AbortController()
        let auth = Task { try await models.getAuth("p1", AuthResolutionOverrides(signal: authController.signal)) }
        await resolveStarted.wait()
        authController.abort()
        #expect(gIsAbortError(await gCaught { _ = try await auth.value }))

        blockedCheck.open()
        blockedResolve.open()
    }

    @Test("cancels queued credential mutations without running them later")
    func cancelsQueuedMutations() async throws {
        let credentials = InMemoryCredentialStore()
        let firstBlocked = GGate()
        let secondRan = Locked(false)
        let first = Task {
            try await credentials.modify("p1") { _ in
                await firstBlocked.wait()
                return gApiKey("first")
            }
        }
        // Let the first mutation take the chain before queueing the second.
        try await Task.sleep(nanoseconds: 10_000_000)
        let controller = AbortController()
        let second = Task {
            try await credentials.modify("p1", { _ in
                secondRan.withLock { $0 = true }
                return gApiKey("second")
            }, AuthOperationOptions(signal: controller.signal))
        }
        try await Task.sleep(nanoseconds: 10_000_000)

        controller.abort()
        #expect(gIsAbortError(await gCaught { _ = try await second.value }))
        firstBlocked.open()
        _ = try await first.value
        try await Task.sleep(nanoseconds: 10_000_000)

        #expect(secondRan.current == false)
        #expect(try await credentials.read("p1") == gApiKey("first"))
    }

    // Radius bug report 01a10855-43d8-7447-a710-2acf5ee0b2ee: refresh_token_invalidated after a cancelled refresh.
    @Test("persists an OAuth refresh that started before the request was cancelled")
    func persistsOAuthRefreshAfterRequestCancel() async throws {
        let credentials = InMemoryCredentialStore()
        _ = try await credentials.modify("p1") { _ in gOAuth(access: "old", refresh: "old-refresh", expires: 0) }
        let controller = AbortController()
        let models = createModels(CreateModelsOptions(credentials: credentials))
        models.setProvider(testProvider(id: "p1", auth: ProviderAuth(oauth: testOAuth(refresh: { credential, _ in
            // The provider has rotated old-refresh by the time the request is cancelled.
            controller.abort()
            var next = credential
            next.access = "new"; next.refresh = "new-refresh"; next.expires = dateNow() + 60_000
            return next
        }))))

        #expect(gIsAbortError(await gCaught { _ = try await models.getAuth("p1", AuthResolutionOverrides(signal: controller.signal)) }))
        #expect(try await gWaitFor { try await credentials.read("p1")?.oauthCredential?.refresh == "new-refresh" })
    }

    @Test("resolves auth: stored credential owns the provider, ambient only when nothing stored")
    func storedCredentialOwnsProvider() async throws {
        let credentials = InMemoryCredentialStore()
        let models = createModels(CreateModelsOptions(credentials: credentials))
        models.setProvider(testProvider(id: "p1", auth: ProviderAuth(apiKey: envKeyAuth("env-key"), oauth: testOAuth())))
        let model = testModel("p1", "model-a")

        // model and provider-id overloads resolve the same provider-scoped auth
        #expect(try await models.getAuth(model)?.auth.apiKey == "env-key")
        #expect(try await models.getAuth(model.provider)?.auth.apiKey == "env-key")
        #expect(try await models.getAuth(model, AuthResolutionOverrides(apiKey: "explicit-key"))?.auth.apiKey == "explicit-key")

        // stored oauth credential (persisted via the single write path): beats ambient env
        _ = try await credentials.modify("p1") { _ in gOAuth(access: "oauth-token", refresh: "r", expires: dateNow() + 10 * 60_000) }
        let resolution = try await models.getAuth(model.provider)
        #expect(resolution?.auth.apiKey == "oauth-token")
        #expect(resolution?.source == "OAuth")

        // stored api-key credential resolves through apiKey auth, beats env
        _ = try await credentials.modify("p1") { _ in gApiKey("stored-key") }
        let apiKeyResolution = try await models.getAuth(model.provider)
        #expect(apiKeyResolution?.auth.apiKey == "stored-key")
        #expect(apiKeyResolution?.source == "stored")
    }

    @Test("checks provider auth without refreshing OAuth and filters available models")
    func checksAuthWithoutRefreshing() async throws {
        let credentials = InMemoryCredentialStore()
        let refreshes = Locked(0)
        let models = createModels(CreateModelsOptions(credentials: credentials))
        models.setProvider(testProvider(id: "ambient", auth: ProviderAuth(apiKey: envKeyAuth("env-key"))))
        models.setProvider(testProvider(id: "missing", auth: ProviderAuth(apiKey: envKeyAuth(nil))))
        models.setProvider(testProvider(id: "oauth", auth: ProviderAuth(oauth: testOAuth(refresh: { credential, _ in
            refreshes.withLock { $0 += 1 }
            return credential
        }))))
        _ = try await credentials.modify("oauth") { _ in gOAuth(access: "expired", refresh: "refresh", expires: 0) }

        let ambient = try await models.checkAuth("ambient")
        #expect(ambient?.source == "env" && ambient?.type == "api_key")
        #expect(try await models.checkAuth("missing") == nil)
        let oauth = try await models.checkAuth("oauth")
        #expect(oauth?.source == "OAuth" && oauth?.type == "oauth")
        #expect(refreshes.current == 0)
        #expect(try await models.getAvailable().map(\.provider) == ["ambient", "oauth"])
        #expect(try await models.getAvailable("ambient").map(\.provider) == ["ambient"])
    }

    @Test("runs provider login and logout through the credential store")
    func loginAndLogout() async throws {
        let credentials = InMemoryCredentialStore()
        var apiKey = envKeyAuth(nil)
        apiKey.login = { _ in ApiKeyCredential(key: "logged-in") }
        let models = createModels(CreateModelsOptions(credentials: credentials))
        models.setProvider(testProvider(id: "p1", auth: ProviderAuth(apiKey: apiKey)))

        let credential = try await models.login("p1", "api_key", noInteraction())
        #expect(credential == gApiKey("logged-in"))
        #expect(try await credentials.read("p1") == credential)

        try await models.logout("p1")
        #expect(try await credentials.read("p1") == nil)
    }

    @Test("a stored credential without a matching handler blocks ambient fallback")
    func storedCredentialWithoutHandler() async throws {
        let credentials = InMemoryCredentialStore()
        let models = createModels(CreateModelsOptions(credentials: credentials))
        // provider has only apiKey auth, but an oauth credential is stored (stale config)
        models.setProvider(testProvider(id: "p1", auth: ProviderAuth(apiKey: envKeyAuth("env-key"))))
        _ = try await credentials.modify("p1") { _ in gOAuth(access: "a", refresh: "r", expires: 0) }

        #expect(try await models.getAuth("p1") == nil)
    }

    @Test("refreshes expired oauth credentials and persists the rotated credential")
    func refreshesExpiredOAuth() async throws {
        let credentials = InMemoryCredentialStore()
        let oauth = testOAuth(refresh: { credential, _ in
            var next = credential
            next.access = "new-token"; next.expires = dateNow() + 60 * 60_000
            return next
        })
        let models = createModels(CreateModelsOptions(credentials: credentials))
        models.setProvider(testProvider(id: "p1", auth: ProviderAuth(oauth: oauth)))
        _ = try await credentials.modify("p1") { _ in gOAuth(access: "old-token", refresh: "r", expires: 0) }

        let resolution = try await models.getAuth("p1")
        #expect(resolution?.auth.apiKey == "new-token")
        #expect(try await credentials.read("p1")?.oauthCredential?.access == "new-token")
    }

    @Test("refreshes oauth credentials with less than five minutes remaining")
    func refreshesNearExpiry() async throws {
        let credentials = InMemoryCredentialStore()
        let refreshCalls = Locked(0)
        let models = createModels(CreateModelsOptions(credentials: credentials))
        models.setProvider(testProvider(id: "p1", auth: ProviderAuth(oauth: testOAuth(refresh: { credential, _ in
            refreshCalls.withLock { $0 += 1 }
            var next = credential
            next.access = "new-token"; next.expires = dateNow() + 60 * 60_000
            return next
        }))))
        _ = try await credentials.modify("p1") { _ in gOAuth(access: "old-token", refresh: "r", expires: dateNow() + 60_000) }

        #expect(try await models.getAuth("p1")?.auth.apiKey == "new-token")
        #expect(refreshCalls.current == 1)
    }

    @Test("honors a caller's longer OAuth minimum validity")
    func honorsMinimumValidity() async throws {
        let credentials = InMemoryCredentialStore()
        let refreshCalls = Locked(0)
        let models = createModels(CreateModelsOptions(credentials: credentials))
        models.setProvider(testProvider(id: "p1", auth: ProviderAuth(oauth: testOAuth(refresh: { credential, _ in
            refreshCalls.withLock { $0 += 1 }
            var next = credential
            next.access = "new-token"; next.expires = dateNow() + 60 * 60_000
            return next
        }))))
        _ = try await credentials.modify("p1") { _ in gOAuth(access: "old-token", refresh: "r", expires: dateNow() + 10 * 60_000) }

        #expect(try await models.getAuth("p1", AuthResolutionOverrides(minOAuthValidityMs: 30 * 60_000))?.auth.apiKey == "new-token")
        #expect(refreshCalls.current == 1)
    }

    @Test("rejects with code oauth when refresh fails, preserving the stored credential")
    func rejectsWithOAuthCode() async throws {
        let credentials = InMemoryCredentialStore()
        let oauth = testOAuth(refresh: { _, _ in throw PiError("invalid_grant") })
        let models = createModels(CreateModelsOptions(credentials: credentials))
        models.setProvider(testProvider(id: "p1", auth: ProviderAuth(oauth: oauth)))
        _ = try await credentials.modify("p1") { _ in gOAuth(access: "old", refresh: "r", expires: 0) }

        let error = await gCaught { _ = try await models.getAuth("p1") }
        #expect((error as? ModelsError)?.code == .oauth)
        // credential preserved for retry / re-login
        #expect(try await credentials.read("p1")?.oauthCredential?.access == "old")
    }

    @Test("serializes concurrent OAuth refreshes through store.modify (no double refresh)")
    func serializesConcurrentRefreshes() async throws {
        let credentials = InMemoryCredentialStore()
        _ = try await credentials.modify("p1") { _ in gOAuth(access: "old", refresh: "r1", expires: 0) }

        let refreshes = Locked(0)
        let oauth = testOAuth(refresh: { _, _ in
            let count = refreshes.withLock { $0 += 1; return $0 }
            try await Task.sleep(nanoseconds: 10_000_000)
            return OAuthCredentials(refresh: "r2", access: "new-\(count)", expires: dateNow() + 60 * 60_000)
        })
        let models = createModels(CreateModelsOptions(credentials: credentials))
        models.setProvider(testProvider(id: "p1", auth: ProviderAuth(oauth: oauth)))
        let model = testModel("p1", "model-a")

        async let a = models.getAuth(model.provider)
        async let b = models.getAuth(model.provider)
        let (ra, rb) = try await (a, b)
        #expect(refreshes.current == 1)
        #expect(ra?.auth.apiKey == "new-1")
        #expect(rb?.auth.apiKey == "new-1")
    }

    @Test("valid oauth tokens resolve without touching modify")
    func validTokensSkipModify() async throws {
        let modifies = Locked(0)
        let base = InMemoryCredentialStore()
        let credentials = ClosureCredentialStore(
            readFn: { try await base.read($0) },
            listFn: { try await base.list() },
            modifyFn: { pid, fn in
                modifies.withLock { $0 += 1 }
                return try await base.modify(pid, fn)
            },
            deleteFn: { try await base.delete($0) }
        )
        _ = try await base.modify("p1") { _ in gOAuth(access: "valid", refresh: "r", expires: dateNow() + 10 * 60_000) }
        let models = createModels(CreateModelsOptions(credentials: credentials))
        models.setProvider(testProvider(id: "p1", auth: ProviderAuth(oauth: testOAuth())))

        #expect(try await models.getAuth("p1")?.auth.apiKey == "valid")
        #expect(modifies.current == 0)
    }

    @Test("wraps credential store failures in ModelsError")
    func wrapsCredentialStoreFailures() async throws {
        // read failure
        let readFailing = ClosureCredentialStore(
            readFn: { _ in throw PiError("disk on fire") },
            listFn: { [] },
            modifyFn: { _, _ in nil },
            deleteFn: { _ in }
        )
        let models = createModels(CreateModelsOptions(credentials: readFailing))
        models.setProvider(testProvider(id: "p1", auth: ProviderAuth(apiKey: envKeyAuth("env-key"))))
        #expect((await gCaught { _ = try await models.getAuth("p1") } as? ModelsError)?.code == .auth)

        // modify failure during refresh
        let modifyFailing = ClosureCredentialStore(
            readFn: { _ in gOAuth(access: "old", refresh: "r", expires: 0) },
            listFn: { [CredentialInfo(providerId: "p1", type: "oauth")] },
            modifyFn: { _, _ in throw PiError("disk on fire") },
            deleteFn: { _ in }
        )
        let oauthModels = createModels(CreateModelsOptions(credentials: modifyFailing))
        oauthModels.setProvider(testProvider(id: "p1", auth: ProviderAuth(oauth: testOAuth())))
        #expect((await gCaught { _ = try await oauthModels.getAuth("p1") } as? ModelsError)?.code == .auth)
    }

    @Test("keeps the underlying reason in wrapped oauth refresh errors")
    func keepsUnderlyingReason() async throws {
        let credentials = InMemoryCredentialStore()
        _ = try await credentials.modify("p1") { _ in gOAuth(access: "old", refresh: "r", expires: 0) }
        let models = createModels(CreateModelsOptions(credentials: credentials))
        models.setProvider(testProvider(id: "p1", auth: ProviderAuth(oauth: testOAuth(refresh: { _, _ in
            throw PiError("token refresh failed (400): invalid_grant")
        }))))

        let error = await gCaught { _ = try await models.getAuth("p1") }
        #expect(error.map(errorMessage)?.contains("OAuth refresh failed for p1: token refresh failed (400): invalid_grant") == true)
    }

    @Test("wraps api-key auth failures in ModelsError")
    func wrapsApiKeyFailures() async throws {
        let failing = ApiKeyAuth(name: "Failing", resolve: { _ in throw PiError("nope") })
        let models = createModels()
        models.setProvider(testProvider(id: "p1", auth: ProviderAuth(apiKey: failing)))
        #expect((await gCaught { _ = try await models.getAuth("p1") } as? ModelsError)?.code == .auth)
    }

    @Test("uses explicit request api key and env during provider auth resolution")
    func explicitApiKeyAndEnv() async throws {
        let calls = Locked<[ProviderCall]>([])
        let apiKey = ApiKeyAuth(name: "Scoped", resolve: { input in
            let account: String?
            if let fromCredential = input.credential?.env?["ACCOUNT_ID"] { account = fromCredential } else { account = await input.ctx.env("ACCOUNT_ID") }
            guard let key = input.credential?.key, let account else { return nil }
            return AuthResult(auth: ModelAuth(apiKey: key, baseUrl: "https://example.test/\(account)"), env: ["ACCOUNT_ID": account])
        })
        let models = createModels()
        models.setProvider(testProvider(id: "p1", auth: ProviderAuth(apiKey: apiKey), calls: calls))
        let model = testModel("p1", "model-a")

        var options = StreamOptions()
        options.apiKey = "explicit-key"
        options.env = ["ACCOUNT_ID": "acct"]
        _ = await models.completeSimple(model, context, options)

        let call = try #require(calls.current.first)
        #expect(call.model.baseUrl == "https://example.test/acct")
        #expect(call.options?.apiKey == "explicit-key")
        #expect(call.options?.env == ["ACCOUNT_ID": "acct"])
    }

    @Test("merges resolved auth into stream options; explicit options win per field")
    func mergesResolvedAuth() async throws {
        let calls = Locked<[ProviderCall]>([])
        let apiKey = ApiKeyAuth(name: "Test", resolve: { _ in
            AuthResult(auth: ModelAuth(
                apiKey: "resolved-key",
                headers: [("Authorization", "Bearer resolved-key"), ("x-a", "auth"), ("x-b", "auth")],
                baseUrl: "https://auth.test/v1"
            ))
        })
        let models = createModels()
        models.setProvider(testProvider(id: "p1", auth: ProviderAuth(apiKey: apiKey), calls: calls))
        let model = testModel("p1", "model-a")

        var options = StreamOptions()
        options.apiKey = "explicit-key"
        options.headers = [("authorization", "Explicit token"), ("x-b", "explicit")]
        let result = await models.completeSimple(model, context, options)
        #expect(result.stopReason == .stop)
        #expect(calls.current.count == 1)
        let first = calls.current[0]
        #expect(first.options?.apiKey == "explicit-key")
        #expect(gHeaders(first.options?.headers)?.sorted() == ["authorization=Explicit token", "x-a=auth", "x-b=explicit"])
        #expect(first.model.baseUrl == "https://auth.test/v1")

        // without explicit options, resolved auth applies
        let result2 = await models.completeSimple(model, context)
        #expect(result2.stopReason == .stop)
        #expect(calls.current[1].options?.apiKey == "resolved-key")
    }

    @Test("adds model headers only for model auth and transforms assembled headers once")
    func modelHeadersAndTransforms() async throws {
        let calls = Locked<[ProviderCall]>([])
        let models = createModels()
        models.setProvider(testProvider(id: "p1", auth: ProviderAuth(apiKey: envKeyAuth("key")), calls: calls))
        var model = testModel("p1", "model-a")
        model.headers = [("x-model", "model"), ("x-shared", "model")]

        #expect(try await models.getAuth("p1")?.auth.headers == nil)
        #expect(gHeaders(try await models.getAuth(model)?.auth.headers) == ["x-model=model", "x-shared=model"])

        let transforms = Locked(0)
        let seen = Locked<[String]?>(nil)
        var options = StreamOptions()
        options.headers = [("x-explicit", "explicit"), ("X-Shared", "explicit")]
        _ = await models.completeSimple(model, context, options, transforms: ModelsRequestTransforms(transformHeaders: { headers in
            transforms.withLock { $0 += 1 }
            seen.withLock { $0 = gHeaders(headers)?.sorted() }
            return headers + [("x-transformed", "yes")]
        }))

        #expect(transforms.current == 1)
        #expect(seen.current == ["X-Shared=explicit", "x-explicit=explicit", "x-model=model"])
        #expect(gHeaders(calls.current.first?.options?.headers)?.sorted() == [
            "X-Shared=explicit", "x-explicit=explicit", "x-model=model", "x-transformed=yes",
        ])
    }

    @Test("produces an error stream for unknown providers instead of throwing")
    func errorStreamForUnknownProvider() async {
        let models = createModels()
        let result = await models.completeSimple(testModel("ghost", "model-a"), context)
        #expect(result.stopReason == .error)
        #expect(result.errorMessage?.contains("Unknown provider: ghost") == true)
    }

    @Test("streams through the provider")
    func streamsThroughProvider() async {
        let models = createModels()
        models.setProvider(testProvider(id: "p1"))
        let model = testModel("p1", "model-a")

        var events: [String] = []
        let stream = models.streamSimple(model, context)
        for await event in stream {
            events.append(event.type)
        }
        #expect(events == ["start", "done"])
        let message = await stream.result()
        #expect(message.stopReason == .stop)
    }
}
