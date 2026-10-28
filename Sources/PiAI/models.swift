import Foundation

// Port of packages/ai/src/models.ts
//
// Swift notes:
// - `Provider` and the `Models` collection are value/closure based; `Models`/`MutableModels` are protocols
//   implemented by `ModelsImpl`, created through `createModels()`.
// - `ModelsRequestTransforms` is passed as a separate trailing `transforms:` argument instead of being
//   intersected into the options type (`ModelsSimpleStreamOptions = SimpleStreamOptions & ModelsRequestTransforms`).
// - Image generation and classification (`generateImages`, `classify`, `images`, `classifiers`) are not ported:
//   image/classifier models still list, filter and persist (they are `Model`s with `type`), but have no operations.
// - Not ported: telemetry (`observeModelRequest`, `AI_TELEMETRY_SCHEMA`).

public struct ModelsPublication: Sendable {
    /// Provider-selected persisted catalog. nil leaves storage unchanged; `.some(nil)` (upstream `null`) deletes it.
    public var persist: ModelsStoreEntry??
    /// Optional synchronous update of provider-private in-memory catalog state.
    public var update: (@Sendable () -> Void)?
    public init(persist: ModelsStoreEntry?? = nil, update: (@Sendable () -> Void)? = nil) { self.persist = persist; self.update = update }
}

public struct RefreshModelsContext: Sendable {
    /// Effective configured credential. OAuth credentials are refreshed before network access.
    public var credential: Credential?
    /// Immutable provider-scoped catalog snapshot captured before this refresh phase.
    public var stored: ModelsStoreEntry?
    /// Generation-checked publication. Persistence policy remains provider-owned;
    /// the update runs synchronously only after the selected persistence mutation.
    public var publish: @Sendable (ModelsPublication) async throws -> Bool
    /// False during offline/cache-only initialization.
    public var allowNetwork: Bool
    /// Bypass provider freshness checks and fetch immediately when network access is allowed.
    public var force: Bool?
    /// Always present, including when the public refresh caller omits its optional signal.
    public var signal: AbortSignal
    /// Base URL of the registered provider, including configuration overrides that wrappers apply
    /// outside the provider receiving this context.
    public var baseUrl: String?
    public init(credential: Credential? = nil, stored: ModelsStoreEntry? = nil, publish: @escaping @Sendable (ModelsPublication) async throws -> Bool,
                allowNetwork: Bool, force: Bool? = nil, signal: AbortSignal, baseUrl: String? = nil) {
        self.credential = credential; self.stored = stored; self.publish = publish; self.allowNetwork = allowNetwork
        self.force = force; self.signal = signal; self.baseUrl = baseUrl
    }
}

public struct ModelsRefreshOptions: Sendable {
    public var allowNetwork: Bool?
    /// Restrict refresh to these provider IDs. Unknown and static providers are ignored.
    public var providers: [String]?
    /// Bypass provider freshness checks and fetch immediately when network access is allowed.
    public var force: Bool?
    public var signal: AbortSignal?
    public init(allowNetwork: Bool? = nil, providers: [String]? = nil, force: Bool? = nil, signal: AbortSignal? = nil) {
        self.allowNetwork = allowNetwork; self.providers = providers; self.force = force; self.signal = signal
    }
}

public struct ModelsRefreshResult: Sendable {
    public var aborted: Bool
    public var errors: [String: any Error]
    public init(aborted: Bool, errors: [String: any Error]) { self.aborted = aborted; self.errors = errors }
}

public struct ModelsRequestTransforms: Sendable {
    /// Transform fully assembled model/auth/request headers before provider dispatch.
    public var transformHeaders: (@Sendable (ProviderHeaders) async throws -> ProviderHeaders)?
    public init(transformHeaders: (@Sendable (ProviderHeaders) async throws -> ProviderHeaders)? = nil) { self.transformHeaders = transformHeaders }
}

private let KNOWN_MODEL_TYPES: Set<ModelType> = ["chat", "image", "classifier"]

/// Models from stores and remote sources may have types that only newer versions know.
func hasKnownModelType(_ model: AnyModel) -> Bool {
    KNOWN_MODEL_TYPES.contains(getModelType(model))
}

/// Drops stored models whose type this version does not know.
private func withKnownModelTypes(_ entry: ModelsStoreEntry) -> ModelsStoreEntry {
    var entry = entry
    entry.models = entry.models.filter(hasKnownModelType)
    return entry
}

/// A provider is the concrete runtime unit. It owns id/name/base metadata,
/// auth methods, model listing, and the operations its models support
/// (streaming; image generation and classification are not ported).
public struct Provider: Sendable {
    public var id: String
    public var name: String

    public var baseUrl: String?
    public var headers: ProviderHeaders?

    /// Required: at least one of `apiKey`/`oauth`. Every provider has auth
    /// semantics — even providers with only ambient credentials (env vars, AWS
    /// profiles, ADC files) and keyless local servers provide `apiKey` auth
    /// whose `resolve()` reports whether the provider is configured.
    /// `Models.getAuth()` returns nil when the provider is unconfigured.
    public var auth: ProviderAuth

    /// Current known chat models, sync. Static providers return their catalog;
    /// dynamic providers return the list as of the last `refreshModels()` (empty
    /// before the first). Should not throw; `Models` treats a throwing
    /// implementation as having no models.
    public var getModels: @Sendable () throws -> [Model]

    /// Current known models of every type, sync, with the same contract as
    /// `getModels()`. Providers with only chat models may omit it; `Models` then
    /// uses `getModels()`.
    public var getAllModels: (@Sendable () throws -> [AnyModel])?

    /// Dynamic providers only: restore `context.stored` and optionally fetch a newer list using
    /// the effective credential. Implementations retain their previous list on failure, publish
    /// persistence and synchronous state changes through `context.publish()`, and honor the
    /// shared abort signal for blocking work.
    public var refreshModels: (@Sendable (RefreshModelsContext) async throws -> Void)?

    /// Optional provider policy for credential-specific model availability.
    public var filterModels: (@Sendable ([Model], Credential?) -> [Model])?

    /// Optional credential-specific availability policy across every model type.
    public var filterAllModels: (@Sendable ([AnyModel], Credential?) -> [AnyModel])?

    /// Stream a normalized transcript. `Models` normalizes the caller's `Context` before dispatching here.
    public var stream: StreamFunction
    public var streamSimple: StreamFunction
    public var fetchDeferred: FetchDeferredFunction?
    public var cancelDeferred: CancelDeferredFunction?

    // Not ported: generateImages, classify.

    public init(
        id: String,
        name: String,
        baseUrl: String? = nil,
        headers: ProviderHeaders? = nil,
        auth: ProviderAuth,
        getModels: @escaping @Sendable () throws -> [Model],
        getAllModels: (@Sendable () throws -> [AnyModel])? = nil,
        refreshModels: (@Sendable (RefreshModelsContext) async throws -> Void)? = nil,
        filterModels: (@Sendable ([Model], Credential?) -> [Model])? = nil,
        filterAllModels: (@Sendable ([AnyModel], Credential?) -> [AnyModel])? = nil,
        stream: @escaping StreamFunction,
        streamSimple: @escaping StreamFunction,
        fetchDeferred: FetchDeferredFunction? = nil,
        cancelDeferred: CancelDeferredFunction? = nil
    ) {
        self.id = id; self.name = name; self.baseUrl = baseUrl; self.headers = headers; self.auth = auth
        self.getModels = getModels; self.getAllModels = getAllModels; self.refreshModels = refreshModels
        self.filterModels = filterModels; self.filterAllModels = filterAllModels
        self.stream = stream; self.streamSimple = streamSimple; self.fetchDeferred = fetchDeferred; self.cancelDeferred = cancelDeferred
    }
}

/// Runtime collection of providers plus auth application and request
/// convenience. Providers own request behavior; `Models` resolves auth and
/// delegates each request to the provider that owns the model.
///
/// Read accessors come in three flavors: the unqualified ones (`getModels`,
/// `getModel`, `getAvailable`) return chat models, the `*OfType` accessors
/// return one model type, and `getAllModels`/`getAllAvailable` return every type.
public protocol Models: Sendable {
    func getProviders() -> [Provider]
    func getProvider(_ id: String) -> Provider?

    /// Sync read of last-known chat models from one provider or all providers.
    /// Best-effort: a provider whose `getModels()` throws yields no models.
    func getModels(_ provider: String?) -> [Model]

    /// Sync runtime chat model lookup against last-known lists.
    func getModel(_ provider: String, _ id: String) -> Model?

    /// Sync read of last-known models of one type from one provider or all providers.
    func getModelsOfType(_ type: ModelType, _ provider: String?) -> [AnyModel]

    /// Sync runtime lookup of a model of one type against last-known lists.
    func getModelOfType(_ type: ModelType, _ provider: String, _ id: String) -> AnyModel?

    /// Sync read of last-known models of every type from one provider or all providers.
    func getAllModels(_ provider: String?) -> [AnyModel]

    /// Refresh selected configured dynamic providers concurrently (all when `providers` is omitted).
    /// Provider errors and cancellation are returned without rejecting; static, unknown, and
    /// unconfigured providers are skipped.
    func refresh(_ options: ModelsRefreshOptions) async throws -> ModelsRefreshResult

    /// Check whether a provider has complete auth configuration without refreshing OAuth.
    func checkAuth(_ providerId: String, _ options: AuthOperationOptions?) async throws -> AuthCheck?

    /// Return chat models whose providers have complete auth configuration.
    func getAvailable(_ providerId: String?, _ options: AuthOperationOptions?) async throws -> [Model]

    /// Return models of one type whose providers have complete auth configuration.
    func getAvailableOfType(_ type: ModelType, _ providerId: String?, _ options: AuthOperationOptions?) async throws -> [AnyModel]

    /// Return models of every type whose providers have complete auth configuration.
    func getAllAvailable(_ providerId: String?, _ options: AuthOperationOptions?) async throws -> [AnyModel]

    /// Resolve provider-scoped auth by provider id, or provider auth plus static
    /// model headers when passed a model. Includes a source label for status UI.
    /// Resolves nil when the provider is unknown or unconfigured.
    /// Throws `ModelsError`: code "oauth" when a token refresh fails (the
    /// stored credential is preserved for retry; re-login fixes it), code "auth"
    /// when api-key resolution or the credential store fails. Request paths
    /// surface rejections as stream errors.
    func getAuth(_ providerId: String, _ overrides: AuthResolutionOverrides?) async throws -> AuthResult?
    func getAuth(_ model: AnyModel, _ overrides: AuthResolutionOverrides?) async throws -> AuthResult?

    /// Run a provider-owned login flow and persist its returned credential.
    func login(_ providerId: String, _ type: AuthType, _ interaction: AuthInteraction, _ options: LoginOptions?) async throws -> Credential

    /// Remove the stored credential for a provider.
    func logout(_ providerId: String, _ options: AuthOperationOptions?) async throws

    func stream(_ model: Model, _ context: Context, _ options: StreamOptions?, transforms: ModelsRequestTransforms?) -> AssistantMessageEventStream
    func complete(_ model: Model, _ context: Context, _ options: StreamOptions?, transforms: ModelsRequestTransforms?) async -> AssistantMessage
    func streamSimple(_ model: Model, _ context: Context, _ options: SimpleStreamOptions?, transforms: ModelsRequestTransforms?) -> AssistantMessageEventStream
    func completeSimple(_ model: Model, _ context: Context, _ options: SimpleStreamOptions?, transforms: ModelsRequestTransforms?) async -> AssistantMessage
    func streamDeferred(_ model: Model, _ handle: DeferredHandle, _ options: DeferredFetchOptions?, transforms: ModelsRequestTransforms?) -> AssistantMessageEventStream
    func fetchDeferred(_ model: Model, _ handle: DeferredHandle, _ options: DeferredFetchOptions?, transforms: ModelsRequestTransforms?) async -> AssistantMessage
    func cancelDeferred(_ model: Model, _ handle: DeferredHandle, _ options: DeferredCancelOptions?, transforms: ModelsRequestTransforms?) async throws

    // Not ported: generateImages, classify.
}

/// Optional-argument conveniences (upstream optional parameters).
extension Models {
    public func getModels() -> [Model] { getModels(nil) }
    public func getModelsOfType(_ type: ModelType) -> [AnyModel] { getModelsOfType(type, nil) }
    public func getAllModels() -> [AnyModel] { getAllModels(nil) }
    public func refresh() async throws -> ModelsRefreshResult { try await refresh(ModelsRefreshOptions()) }
    public func checkAuth(_ providerId: String) async throws -> AuthCheck? { try await checkAuth(providerId, nil) }
    public func getAvailable() async throws -> [Model] { try await getAvailable(nil, nil) }
    public func getAvailable(_ providerId: String?) async throws -> [Model] { try await getAvailable(providerId, nil) }
    public func getAvailableOfType(_ type: ModelType, _ providerId: String? = nil) async throws -> [AnyModel] { try await getAvailableOfType(type, providerId, nil) }
    public func getAllAvailable() async throws -> [AnyModel] { try await getAllAvailable(nil, nil) }
    public func getAllAvailable(_ providerId: String?) async throws -> [AnyModel] { try await getAllAvailable(providerId, nil) }
    public func getAuth(_ providerId: String) async throws -> AuthResult? { try await getAuth(providerId, nil) }
    public func getAuth(_ model: AnyModel) async throws -> AuthResult? { try await getAuth(model, nil) }
    public func login(_ providerId: String, _ type: AuthType, _ interaction: AuthInteraction) async throws -> Credential {
        try await login(providerId, type, interaction, nil)
    }
    public func logout(_ providerId: String) async throws { try await logout(providerId, nil) }
    public func stream(_ model: Model, _ context: Context, _ options: StreamOptions? = nil) -> AssistantMessageEventStream {
        stream(model, context, options, transforms: nil)
    }
    public func complete(_ model: Model, _ context: Context, _ options: StreamOptions? = nil) async -> AssistantMessage {
        await complete(model, context, options, transforms: nil)
    }
    public func streamSimple(_ model: Model, _ context: Context, _ options: SimpleStreamOptions? = nil) -> AssistantMessageEventStream {
        streamSimple(model, context, options, transforms: nil)
    }
    public func completeSimple(_ model: Model, _ context: Context, _ options: SimpleStreamOptions? = nil) async -> AssistantMessage {
        await completeSimple(model, context, options, transforms: nil)
    }
    public func streamDeferred(_ model: Model, _ handle: DeferredHandle, _ options: DeferredFetchOptions? = nil) -> AssistantMessageEventStream {
        streamDeferred(model, handle, options, transforms: nil)
    }
    public func fetchDeferred(_ model: Model, _ handle: DeferredHandle, _ options: DeferredFetchOptions? = nil) async -> AssistantMessage {
        await fetchDeferred(model, handle, options, transforms: nil)
    }
    public func cancelDeferred(_ model: Model, _ handle: DeferredHandle, _ options: DeferredCancelOptions? = nil) async throws {
        try await cancelDeferred(model, handle, options, transforms: nil)
    }
}

public protocol MutableModels: Models {
    /// Upsert/replace by provider.id. Provider ids are unique.
    func setProvider(_ provider: Provider)
    func deleteProvider(_ id: String)
    func clearProviders()
}

public struct CreateModelsOptions: Sendable {
    public var credentials: (any CredentialStore)?
    public var modelsStore: (any ModelsStore)?
    public var authContext: AuthContext?
    public var identity: ClientIdentity?
    public init(credentials: (any CredentialStore)? = nil, modelsStore: (any ModelsStore)? = nil, authContext: AuthContext? = nil, identity: ClientIdentity? = nil) {
        self.credentials = credentials; self.modelsStore = modelsStore; self.authContext = authContext; self.identity = identity
    }
}

func mergeHeaders(_ base: ProviderHeaders?, _ override: ProviderHeaders?) -> ProviderHeaders? {
    if base == nil && override == nil { return nil }
    var merged = base ?? []
    for (name, value) in override ?? [] {
        let lowerName = name.lowercased()
        merged.removeAll { $0.0.lowercased() == lowerName }
        merged.append((name, value))
    }
    return merged
}

final class ModelsImpl: MutableModels {
    private struct State {
        var providers = JSMap<Provider>()
        var refreshGenerations: [String: Int] = [:]
        var refreshControllers = JSMap<AbortController>()
        var publicationChains: [String: (id: Int, tail: Task<Void, Never>)] = [:]
        var nextChainId = 0
    }

    private let state = Locked(State())
    private let credentials: any CredentialStore
    private let modelsStore: any ModelsStore
    private let authContext: AuthContext
    private let identity: ClientIdentity?

    init(_ options: CreateModelsOptions?) {
        credentials = options?.credentials ?? InMemoryCredentialStore()
        modelsStore = options?.modelsStore ?? InMemoryModelsStore()
        authContext = options?.authContext ?? defaultProviderAuthContext()
        identity = options?.identity
    }

    func setProvider(_ provider: Provider) {
        supersedeProviderRefresh(provider.id)
        state.withLock { $0.providers[provider.id] = provider }
    }

    func deleteProvider(_ id: String) {
        supersedeProviderRefresh(id)
        state.withLock { $0.providers[id] = nil }
    }

    func clearProviders() {
        let ids = state.withLock { s -> [String] in
            var ids = s.providers.keys
            for id in s.refreshControllers.keys where !ids.contains(id) { ids.append(id) }
            return ids
        }
        for id in ids {
            supersedeProviderRefresh(id)
        }
        state.withLock { $0.providers.removeAll() }
    }

    func getProviders() -> [Provider] {
        state.withLock { $0.providers.values }
    }

    func getProvider(_ id: String) -> Provider? {
        state.withLock { $0.providers[id] }
    }

    func getModels(_ provider: String?) -> [Model] {
        if let provider {
            guard let entry = getProvider(provider) else { return [] }
            return (try? entry.getModels()) ?? []
        }

        var models: [Model] = []
        for entry in getProviders() {
            // Best-effort: ill-behaved providers yield no models.
            if let entryModels = try? entry.getModels() { models.append(contentsOf: entryModels) }
        }
        return models
    }

    func getAllModels(_ provider: String?) -> [AnyModel] {
        if let provider {
            guard let entry = getProvider(provider) else { return [] }
            return (try? (entry.getAllModels?() ?? entry.getModels())) ?? []
        }

        var models: [AnyModel] = []
        for entry in getProviders() {
            // Best-effort: ill-behaved providers yield no models.
            if let entryModels = try? (entry.getAllModels?() ?? entry.getModels()) { models.append(contentsOf: entryModels) }
        }
        return models
    }

    func getModelsOfType(_ type: ModelType, _ provider: String?) -> [AnyModel] {
        getAllModels(provider).filter { isModelType($0, type) }
    }

    func getModel(_ provider: String, _ id: String) -> Model? {
        getModels(provider).first { $0.id == id }
    }

    func getModelOfType(_ type: ModelType, _ provider: String, _ id: String) -> AnyModel? {
        getModelsOfType(type, provider).first { $0.id == id }
    }

    @discardableResult
    private func supersedeProviderRefresh(_ providerId: String) -> Int {
        let (generation, previous) = state.withLock { s -> (Int, AbortController?) in
            let generation = (s.refreshGenerations[providerId] ?? 0) + 1
            s.refreshGenerations[providerId] = generation
            let previous = s.refreshControllers[providerId]
            if previous != nil { s.refreshControllers[providerId] = nil }
            return (generation, previous)
        }
        previous?.abort()
        return generation
    }

    private func beginProviderRefresh(_ providerId: String) -> (generation: Int, controller: AbortController) {
        let generation = supersedeProviderRefresh(providerId)
        let controller = AbortController()
        state.withLock { $0.refreshControllers[providerId] = controller }
        return (generation, controller)
    }

    private func currentGeneration(_ providerId: String) -> Int? {
        state.withLock { $0.refreshGenerations[providerId] }
    }

    private func publishProviderModels(
        _ providerId: String,
        _ generation: Int,
        _ signal: AbortSignal,
        _ publication: ModelsPublication
    ) async throws -> Bool {
        let modelsStore = self.modelsStore
        let queued: Task<Bool, any Error> = state.withLock { s in
            let previous = s.publicationChains[providerId]?.tail
            let queued = Task<Bool, any Error> { [weak self] in
                await previous?.value
                guard let self else { return false }
                if signal.aborted || self.currentGeneration(providerId) != generation { return false }

                if let persist = publication.persist {
                    if let entry = persist {
                        try await modelsStore.write(providerId, entry, ModelsStoreOperationOptions(signal: signal))
                    } else {
                        try await modelsStore.delete(providerId, ModelsStoreOperationOptions(signal: signal))
                    }
                }

                if signal.aborted || self.currentGeneration(providerId) != generation { return false }
                publication.update?()
                return true
            }
            let tail = Task<Void, Never> { _ = try? await queued.value }
            s.nextChainId += 1
            let id = s.nextChainId
            s.publicationChains[providerId] = (id, tail)
            Task { [weak self] in
                await tail.value
                self?.state.withLock { s in
                    if s.publicationChains[providerId]?.id == id { s.publicationChains[providerId] = nil }
                }
            }
            return queued
        }
        return try await raceWithAbortSignal({ try await queued.value }, signal)
    }

    private func runProviderRefreshPhase(
        _ provider: Provider,
        _ refreshModels: @Sendable (RefreshModelsContext) async throws -> Void,
        _ credential: Credential?,
        _ allowNetwork: Bool,
        _ force: Bool?,
        _ generation: Int,
        _ signal: AbortSignal
    ) async throws {
        let stored = try await modelsStore.read(provider.id, ModelsStoreOperationOptions(signal: signal))
        let providerId = provider.id
        try await refreshModels(RefreshModelsContext(
            credential: credential,
            stored: stored.map(withKnownModelTypes),
            publish: { [weak self] publication in
                guard let self else { return false }
                return try await self.publishProviderModels(providerId, generation, signal, publication)
            },
            allowNetwork: allowNetwork,
            force: allowNetwork ? force : nil,
            signal: signal,
            baseUrl: provider.baseUrl
        ))
    }

    func refresh(_ options: ModelsRefreshOptions = ModelsRefreshOptions()) async throws -> ModelsRefreshResult {
        let allowNetwork = options.allowNetwork ?? true
        let callerSignal = operationSignal(options.signal)
        let errors = Locked([String: any Error]())
        if callerSignal.aborted { return ModelsRefreshResult(aborted: true, errors: [:]) }
        let selected = options.providers.map(Set.init)
        let refreshable = getProviders().filter { provider in
            provider.refreshModels != nil && (selected == nil || selected!.contains(provider.id))
        }

        // Upstream starts every provider refresh synchronously before awaiting any of them.
        let starts = refreshable.map { provider -> (Provider, Int, AbortController) in
            let (generation, controller) = beginProviderRefresh(provider.id)
            return (provider, generation, controller)
        }

        let refresh = Task { [self] in
            await withTaskGroup(of: Void.self) { group in
                for (provider, generation, controller) in starts {
                    group.addTask { [self] in
                        let refreshModels = provider.refreshModels!
                        let signal = AbortSignal.any([callerSignal, controller.signal])
                        let operation: @Sendable () async throws -> Void = { [self] in
                            var storedCredential: Credential?
                            var credentialError: (any Error)?
                            do {
                                storedCredential = try await readCredential(provider.id, signal)
                            } catch {
                                credentialError = error
                            }

                            // Restore cached provider state before auth resolution or network access.
                            try await runProviderRefreshPhase(provider, refreshModels, storedCredential, false, nil, generation, signal)
                            if let credentialError { throw credentialError }
                            if !allowNetwork || signal.aborted { return }

                            guard let credential = try await resolveRefreshCredential(provider, storedCredential, signal) else { return }
                            try await runProviderRefreshPhase(provider, refreshModels, credential, true, options.force, generation, signal)
                        }

                        do {
                            try await raceWithAbortSignal(operation, signal)
                        } catch {
                            if !signal.aborted {
                                errors.withLock { $0[provider.id] = error }
                            }
                        }
                        state.withLock { s in
                            if s.refreshControllers[provider.id] === controller {
                                s.refreshControllers[provider.id] = nil
                            }
                        }
                    }
                }
            }
        }

        do {
            try await raceWithAbortSignal({ await refresh.value }, callerSignal)
        } catch {
            if !callerSignal.aborted { throw error }
        }

        return ModelsRefreshResult(aborted: callerSignal.aborted, errors: errors.current)
    }

    private func resolveRefreshCredential(
        _ provider: Provider,
        _ stored: Credential?,
        _ signal: AbortSignal
    ) async throws -> Credential? {
        if case .oauth(let storedOAuth) = stored {
            guard let oauth = provider.auth.oauth else { return nil }
            if dateNow() < storedOAuth.expires { return stored }
            if signal.aborted { return nil }
            // A refresh that has started survives cancellation or a superseding model refresh, so a
            // rotated refresh token is always persisted. A newer refresh then sees the fresh credential.
            return try await refreshStoredOAuthCredential(
                credentials,
                provider.id,
                oauth,
                { current in dateNow() >= current.expires },
                signal
            ).map { .oauth($0) }
        }

        guard let apiKey = provider.auth.apiKey else { return nil }
        let credential = stored?.apiKeyCredential
        guard let result = try await apiKey.resolve(ApiKeyAuthInput(ctx: authContext, credential: credential, signal: signal)) else { return nil }
        return .apiKey(ApiKeyCredential(key: result.auth.apiKey, env: result.env))
    }

    private func readCredential(_ providerId: String, _ signal: AbortSignal) async throws -> Credential? {
        do {
            return try await credentials.read(providerId, AuthOperationOptions(signal: signal))
        } catch {
            throw ModelsError(.auth, "Credential store read failed for \(providerId)", cause: error)
        }
    }

    private func checkProviderAuth(
        _ provider: Provider,
        _ credential: Credential?,
        _ signal: AbortSignal
    ) async throws -> AuthCheck? {
        if case .oauth = credential {
            return provider.auth.oauth != nil ? AuthCheck(source: "OAuth", type: "oauth") : nil
        }
        guard let apiKey = provider.auth.apiKey else { return nil }
        if let check = apiKey.check {
            do {
                return try await check(ApiKeyAuthInput(ctx: authContext, credential: credential?.apiKeyCredential, signal: signal))
            } catch {
                throw ModelsError(.auth, "API key auth check failed for provider \(provider.id)", cause: error)
            }
        }

        let resolution = try await resolveProviderAuth((provider.id, provider.auth), credentials, authContext, AuthResolutionOverrides(signal: signal))
        return resolution.map { AuthCheck(source: $0.source, type: "api_key") }
    }

    func checkAuth(_ providerId: String, _ options: AuthOperationOptions? = nil) async throws -> AuthCheck? {
        let signal = operationSignal(options?.signal)
        return try await raceWithAbortSignal({ [self] in
            try signal.throwIfAborted()
            guard let provider = getProvider(providerId) else { return nil }
            return try await checkProviderAuth(provider, try await readCredential(providerId, signal), signal)
        }, signal)
    }

    private struct AuthenticatedProvider: Sendable {
        var provider: Provider
        var credential: Credential?
        var auth: AuthCheck?
    }

    private func getAuthenticatedProviders(_ providerId: String?, _ signal: AbortSignal) async throws -> [AuthenticatedProvider] {
        try signal.throwIfAborted()
        let providers = providerId.map { id in [getProvider(id)].compactMap { $0 } } ?? getProviders()
        let checks = try await withThrowingTaskGroup(of: (Int, AuthenticatedProvider).self) { group in
            for (index, provider) in providers.enumerated() {
                group.addTask { [self] in
                    let credential = try await readCredential(provider.id, signal)
                    return (index, AuthenticatedProvider(provider: provider, credential: credential, auth: try await checkProviderAuth(provider, credential, signal)))
                }
            }
            var results: [(Int, AuthenticatedProvider)] = []
            for try await result in group { results.append(result) }
            return results.sorted { $0.0 < $1.0 }.map(\.1)
        }
        return checks.filter { $0.auth != nil }
    }

    func getAvailable(_ providerId: String? = nil, _ options: AuthOperationOptions? = nil) async throws -> [Model] {
        let signal = operationSignal(options?.signal)
        return try await raceWithAbortSignal({ [self] in
            let providers = try await getAuthenticatedProviders(providerId, signal)
            return providers.flatMap { entry -> [Model] in
                let models = (try? entry.provider.getModels()) ?? []
                return entry.provider.filterModels?(models, entry.credential) ?? models
            }
        }, signal)
    }

    func getAvailableOfType(_ type: ModelType, _ providerId: String? = nil, _ options: AuthOperationOptions? = nil) async throws -> [AnyModel] {
        try await getAllAvailable(providerId, options).filter { isModelType($0, type) }
    }

    func getAllAvailable(_ providerId: String? = nil, _ options: AuthOperationOptions? = nil) async throws -> [AnyModel] {
        let signal = operationSignal(options?.signal)
        return try await raceWithAbortSignal({ [self] in
            let providers = try await getAuthenticatedProviders(providerId, signal)
            return providers.flatMap { entry -> [AnyModel] in
                let provider = entry.provider
                let models = (try? (provider.getAllModels?() ?? provider.getModels())) ?? []
                if let filterAllModels = provider.filterAllModels { return filterAllModels(models, entry.credential) }
                guard let filterModels = provider.filterModels else { return models }
                let availableChatIds = Set(filterModels((try? provider.getModels()) ?? [], entry.credential).map(\.id))
                return models.filter { !isModelType($0, "chat") || availableChatIds.contains($0.id) }
            }
        }, signal)
    }

    func getAuth(_ providerId: String, _ overrides: AuthResolutionOverrides? = nil) async throws -> AuthResult? {
        try await getAuth(providerId, nil, overrides)
    }

    func getAuth(_ model: AnyModel, _ overrides: AuthResolutionOverrides? = nil) async throws -> AuthResult? {
        try await getAuth(model.provider, model, overrides)
    }

    private func getAuth(_ providerId: String, _ model: AnyModel?, _ overrides: AuthResolutionOverrides?) async throws -> AuthResult? {
        let signal = operationSignal(overrides?.signal)
        guard let provider = getProvider(providerId) else { return nil }
        var resolveOverrides = overrides ?? AuthResolutionOverrides()
        resolveOverrides.signal = signal
        let result = try await resolveProviderAuth((provider.id, provider.auth), credentials, authContext, resolveOverrides)
        guard var result, let model, let modelHeaders = model.headers else { return result }
        result.auth.headers = mergeHeaders(result.auth.headers, modelHeaders.map { ($0.0, Optional($0.1)) })
        return result
    }

    func login(
        _ providerId: String,
        _ type: AuthType,
        _ interaction: AuthInteraction,
        _ options: LoginOptions? = nil
    ) async throws -> Credential {
        let signal = operationSignal(interaction.signal)
        try signal.throwIfAborted()
        guard let provider = getProvider(providerId) else { throw ModelsError(.provider, "Unknown provider: \(providerId)") }
        let providerInteraction = ProviderAuthInteraction(signal: signal, prompt: interaction.prompt, notify: interaction.notify)
        let loginOperation: @Sendable () async throws -> Credential
        if type == "oauth" {
            guard let oauth = provider.auth.oauth else {
                throw ModelsError(.auth, "\(provider.name) does not support \(type) login")
            }
            loginOperation = { .oauth(try await oauth.login(providerInteraction, options)) }
        } else {
            guard let login = provider.auth.apiKey?.login else {
                throw ModelsError(.auth, "\(provider.name) does not support \(type) login")
            }
            loginOperation = { .apiKey(try await login(providerInteraction)) }
        }
        let credential = try await raceWithAbortSignal(loginOperation, signal)

        struct MutationState {
            var started = false
            var onStarted: (@Sendable () -> Void)?
        }
        let mutationState = Locked(MutationState())
        let credentials = self.credentials
        let mutation = Task<Credential?, any Error> {
            try await credentials.modify(
                providerId,
                { _ in
                    let onStarted = mutationState.withLock { s -> (@Sendable () -> Void)? in
                        s.started = true
                        return s.onStarted
                    }
                    onStarted?()
                    return credential
                },
                AuthOperationOptions(signal: signal)
            )
        }
        do {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                let settled = Locked(false)
                let settle: @Sendable (Result<Void, any Error>) -> Void = { result in
                    let first = settled.withLock { s -> Bool in
                        if s { return false }
                        s = true
                        return true
                    }
                    if first { continuation.resume(with: result) }
                }
                let onAbort: @Sendable () -> Void = {
                    if !mutationState.withLock({ $0.started }) { settle(.failure(signal.reason ?? AbortError())) }
                }
                let listenerId = signal.addEventListener(onAbort)
                let alreadyStarted = mutationState.withLock { s -> Bool in
                    s.onStarted = {
                        signal.removeEventListener(listenerId)
                        settle(.success(()))
                    }
                    return s.started
                }
                if alreadyStarted {
                    signal.removeEventListener(listenerId)
                    settle(.success(()))
                }
                Task {
                    do {
                        _ = try await mutation.value
                        signal.removeEventListener(listenerId)
                        settle(.success(()))
                    } catch {
                        signal.removeEventListener(listenerId)
                        settle(.failure(error))
                    }
                }
                if signal.aborted { onAbort() }
            }
            _ = try await mutation.value
        } catch {
            try signal.throwIfAborted()
            throw ModelsError(.auth, "Credential store modify failed for \(providerId)", cause: error)
        }
        return credential
    }

    func logout(_ providerId: String, _ options: AuthOperationOptions? = nil) async throws {
        let signal = operationSignal(options?.signal)
        try signal.throwIfAborted()
        do {
            try await credentials.delete(providerId, AuthOperationOptions(signal: signal))
        } catch {
            try signal.throwIfAborted()
            throw ModelsError(.auth, "Credential store delete failed for \(providerId)", cause: error)
        }
    }

    private func requireProvider(_ model: AnyModel) throws -> Provider {
        guard let provider = getProvider(model.provider) else {
            throw ModelsError(.provider, "Unknown provider: \(model.provider)")
        }
        return provider
    }

    private func requireChatProvider(_ model: Model) throws -> Provider {
        try assertChatModel(model)
        return try requireProvider(model)
    }

    private func applyAuth(
        _ model: AnyModel,
        _ options: StreamOptions?,
        _ transforms: ModelsRequestTransforms?
    ) async throws -> (requestModel: AnyModel, requestOptions: StreamOptions) {
        _ = try requireProvider(model)
        let resolution = try await getAuth(model, AuthResolutionOverrides(
            apiKey: options?.apiKey,
            env: options?.env,
            signal: options?.signal
        ))
        guard let resolution else {
            throw ModelsError(.auth, "Provider is not configured: \(model.provider)")
        }
        let auth = resolution.auth

        // Explicit request options win per-field; the Models-only transform runs last.
        let apiKey = options?.apiKey ?? auth.apiKey
        var headers = mergeHeaders(getOpenCodeSessionHeaders(.init(provider: model.provider, baseUrl: auth.baseUrl ?? model.baseUrl), options?.sessionId), mergeHeaders(auth.headers, options?.headers))
        if let transformHeaders = transforms?.transformHeaders { headers = try await transformHeaders(headers ?? []) }
        let env: ProviderEnv? = resolution.env != nil || options?.env != nil
            ? (resolution.env ?? [:]).merging(options?.env ?? [:]) { _, override in override }
            : nil
        var requestModel = model
        if let baseUrl = auth.baseUrl, !baseUrl.isEmpty { requestModel.baseUrl = baseUrl }
        var requestOptions = options ?? StreamOptions()
        requestOptions.identity = mergeClientIdentity(identity, options?.identity)
        requestOptions.apiKey = apiKey
        requestOptions.headers = headers
        requestOptions.env = env

        return (requestModel, requestOptions)
    }

    func stream(_ model: Model, _ context: Context, _ options: StreamOptions? = nil, transforms: ModelsRequestTransforms? = nil) -> AssistantMessageEventStream {
        let transcript = normalizeContext(context)
        return lazyStream(model, { [self] in
            let provider = try requireChatProvider(model)
            let (requestModel, requestOptions) = try await applyAuth(model, options, transforms)
            return provider.stream(requestModel, transcript, requestOptions)
        })
        // Not ported: observeModelRequest(model, options, false) telemetry observer.
    }

    func complete(_ model: Model, _ context: Context, _ options: StreamOptions? = nil, transforms: ModelsRequestTransforms? = nil) async -> AssistantMessage {
        await stream(model, context, options, transforms: transforms).result()
    }

    func streamSimple(_ model: Model, _ context: Context, _ options: SimpleStreamOptions? = nil, transforms: ModelsRequestTransforms? = nil) -> AssistantMessageEventStream {
        let transcript = normalizeContext(context)
        return lazyStream(model, { [self] in
            let provider = try requireChatProvider(model)
            let (requestModel, requestOptions) = try await applyAuth(model, options, transforms)
            return provider.streamSimple(requestModel, transcript, requestOptions)
        })
    }

    func completeSimple(_ model: Model, _ context: Context, _ options: SimpleStreamOptions? = nil, transforms: ModelsRequestTransforms? = nil) async -> AssistantMessage {
        await streamSimple(model, context, options, transforms: transforms).result()
    }

    func streamDeferred(_ model: Model, _ handle: DeferredHandle, _ options: DeferredFetchOptions? = nil, transforms: ModelsRequestTransforms? = nil) -> AssistantMessageEventStream {
        lazyStream(model, { [self] in
            let provider = try requireChatProvider(model)
            guard let fetchDeferred = provider.fetchDeferred else {
                throw ModelsError(.provider, "Provider \(model.provider) does not support deferred responses")
            }
            let (requestModel, requestOptions) = try await applyAuth(model, options, transforms)
            return fetchDeferred(requestModel, handle, requestOptions)
        })
    }

    func fetchDeferred(_ model: Model, _ handle: DeferredHandle, _ options: DeferredFetchOptions? = nil, transforms: ModelsRequestTransforms? = nil) async -> AssistantMessage {
        await streamDeferred(model, handle, options, transforms: transforms).result()
    }

    func cancelDeferred(_ model: Model, _ handle: DeferredHandle, _ options: DeferredCancelOptions? = nil, transforms: ModelsRequestTransforms? = nil) async throws {
        let provider = try requireChatProvider(model)
        guard let cancelDeferred = provider.cancelDeferred else {
            throw ModelsError(.provider, "Provider \(model.provider) does not support deferred responses")
        }
        let (requestModel, requestOptions) = try await applyAuth(model, options, transforms)
        try await cancelDeferred(requestModel, handle, requestOptions)
    }

    // Not ported: generateImages, classify (image/classifier APIs are out of scope).
}

public func createModels(_ options: CreateModelsOptions? = nil) -> any MutableModels {
    ModelsImpl(options)
}

/// Chat implementation of `CreateProviderOptions.api`: a single one for all chat models,
/// or a map keyed by `model.api` for mixed-API providers.
public enum ProviderApi: Sendable {
    case single(ProviderStreams)
    case byApi([Api: ProviderStreams])
}

public struct CreateProviderOptions: Sendable {
    public var id: String
    /// Display name. Default: `id`.
    public var name: String?
    public var baseUrl: String?
    public var headers: ProviderHeaders?
    /// Required — every provider has auth semantics, even ambient/keyless ones.
    public var auth: ProviderAuth
    /// Static baseline models of every type (empty for purely dynamic providers).
    /// Models without `type` are chat models.
    public var models: [AnyModel]
    /// Fetch a dynamic model overlay of every type. createProvider restores and
    /// publishes it transactionally and drops models of unknown types.
    public var fetchModels: (@Sendable (RefreshModelsContext) async throws -> [AnyModel])?
    /// Credential-specific chat model availability. See `Provider.filterModels`.
    public var filterModels: (@Sendable ([Model], Credential?) -> [Model])?
    /// Credential-specific availability across every model type. See `Provider.filterAllModels`.
    public var filterAllModels: (@Sendable ([AnyModel], Credential?) -> [AnyModel])?
    /// Chat implementation. Required in Swift: `images` and `classifiers` are not ported.
    public var api: ProviderApi?
    // Not ported: images, classifiers.

    public init(
        id: String,
        name: String? = nil,
        baseUrl: String? = nil,
        headers: ProviderHeaders? = nil,
        auth: ProviderAuth,
        models: [AnyModel],
        fetchModels: (@Sendable (RefreshModelsContext) async throws -> [AnyModel])? = nil,
        filterModels: (@Sendable ([Model], Credential?) -> [Model])? = nil,
        filterAllModels: (@Sendable ([AnyModel], Credential?) -> [AnyModel])? = nil,
        api: ProviderApi?
    ) {
        self.id = id; self.name = name; self.baseUrl = baseUrl; self.headers = headers; self.auth = auth; self.models = models
        self.fetchModels = fetchModels; self.filterModels = filterModels; self.filterAllModels = filterAllModels; self.api = api
    }
}

/// Builds a provider from parts. Built-in provider factories and models.json
/// custom providers both go through this. A single `api` streams all chat
/// models; an `api` map dispatches on `model.api`, and a model whose api has
/// no entry produces a stream error. At least one concrete implementation is
/// required; empty maps are rejected.
public func createProvider(_ input: CreateProviderOptions) throws -> Provider {
    let single: ProviderStreams?
    let byApi: [Api: ProviderStreams]?
    switch input.api {
    case .single(let streams): single = streams; byApi = nil
    case .byApi(let map): single = nil; byApi = map
    case nil: single = nil; byApi = nil
    }
    let streams = single.map { [$0] } ?? Array((byApi ?? [:]).values)
    if streams.isEmpty {
        throw PiError("Provider \(input.id): at least one of \"api\", \"images\", or \"classifiers\" is required.")
    }

    let baselineModels = input.models
    let dynamicModels = Locked<[AnyModel]>([])
    let fetchModels = input.fetchModels
    let providerId = input.id
    let currentModels: @Sendable () -> [AnyModel] = {
        var merged = baselineModels
        for model in dynamicModels.current {
            if let index = merged.firstIndex(where: { getModelType($0) == getModelType(model) && $0.id == model.id }) {
                merged[index] = model
            } else {
                merged.append(model)
            }
        }
        return merged
    }
    let apiFor: @Sendable (Model) -> ProviderStreams? = { model in single ?? byApi?[model.api] }

    let dispatch: @Sendable (Model, (ProviderStreams) -> AssistantMessageEventStream) -> AssistantMessageEventStream = { model, run in
        guard let streams = apiFor(model) else {
            return lazyStream(model, {
                throw ModelsError(.stream, "Provider \(providerId) has no API implementation for \"\(model.api)\"")
            })
        }
        return run(streams)
    }

    var refreshModels: (@Sendable (RefreshModelsContext) async throws -> Void)?
    if let fetchModels {
        refreshModels = { (context: RefreshModelsContext) async throws -> Void in
            if let stored = context.stored {
                let restored = stored.models.filter { $0.provider == providerId }
                if !(try await context.publish(ModelsPublication(update: { dynamicModels.withLock { $0 = restored } }))) {
                    return
                }
            }
            if !context.allowNetwork || context.signal.aborted { return }
            let fetched = try await fetchModels(context)
            if context.signal.aborted { return }
            let refreshed = fetched.filter(hasKnownModelType)
            _ = try await context.publish(ModelsPublication(
                persist: .some(ModelsStoreEntry(models: refreshed, checkedAt: dateNow())),
                update: { dynamicModels.withLock { $0 = refreshed } }
            ))
        }
    }

    var provider = Provider(
        id: input.id,
        name: input.name ?? input.id,
        baseUrl: input.baseUrl,
        headers: input.headers,
        auth: input.auth,
        getModels: { currentModels().filter { isModelType($0, "chat") } },
        getAllModels: currentModels,
        refreshModels: refreshModels,
        filterModels: input.filterModels,
        filterAllModels: input.filterAllModels,
        stream: { (model: Model, context: TranscriptContext, options: StreamOptions?) in
            dispatch(model) { $0.stream(model, context, options) }
        },
        streamSimple: { (model: Model, context: TranscriptContext, options: StreamOptions?) in
            dispatch(model) { $0.streamSimple(model, context, options) }
        }
    )

    if streams.contains(where: { $0.fetchDeferred != nil }) {
        provider.fetchDeferred = { (model: Model, handle: DeferredHandle, options: DeferredFetchOptions?) in
            lazyStream(model, {
                guard let fetchDeferred = apiFor(model)?.fetchDeferred else {
                    throw ModelsError(.provider, "Provider \(providerId) does not support deferred responses for \"\(model.api)\"")
                }
                return fetchDeferred(model, handle, options)
            })
        }
    }
    if streams.contains(where: { $0.cancelDeferred != nil }) {
        provider.cancelDeferred = { (model: Model, handle: DeferredHandle, options: DeferredCancelOptions?) async throws in
            guard let cancelDeferred = apiFor(model)?.cancelDeferred else {
                throw ModelsError(.provider, "Provider \(providerId) cannot cancel deferred responses for \"\(model.api)\"")
            }
            try await cancelDeferred(model, handle, options)
        }
    }
    // Not ported: images / classifiers dispatch.

    return provider
}

/// Runtime-checked narrowing for dynamically looked-up models.
/// Non-chat models never match, even when their api id equals `api`.
public func hasApi(_ model: AnyModel, _ api: Api) -> Bool {
    isModelType(model, "chat") && model.api == api
}

/// Computes and stores `usage.cost` (upstream mutates `usage.cost` in place and returns it).
@discardableResult
public func calculateCost(_ model: AnyModel, _ usage: inout Usage) -> UsageCost {
    let inputTokens = Double(usage.input + usage.cacheRead + usage.cacheWrite)
    var rates = (input: model.cost.input, output: model.cost.output, cacheRead: model.cost.cacheRead, cacheWrite: model.cost.cacheWrite)
    var matchedThreshold = -1.0
    for tier in model.cost.tiers ?? [] {
        if inputTokens > tier.inputTokensAbove && tier.inputTokensAbove > matchedThreshold {
            rates = (tier.input, tier.output, tier.cacheRead, tier.cacheWrite)
            matchedThreshold = tier.inputTokensAbove
        }
    }

    // Anthropic charges 2x base input for 1h cache writes.
    let longWrite = Double(usage.cacheWrite1h ?? 0)
    let shortWrite = Double(usage.cacheWrite) - longWrite
    usage.cost.input = (rates.input / 1000000) * Double(usage.input)
    usage.cost.output = (rates.output / 1000000) * Double(usage.output)
    usage.cost.cacheRead = (rates.cacheRead / 1000000) * Double(usage.cacheRead)
    usage.cost.cacheWrite = (rates.cacheWrite * shortWrite + rates.input * 2 * longWrite) / 1000000
    usage.cost.total = usage.cost.input + usage.cost.output + usage.cost.cacheRead + usage.cost.cacheWrite
    return usage.cost
}

private let EXTENDED_THINKING_LEVELS: [ModelThinkingLevel] = [.off, .minimal, .low, .medium, .high, .xhigh, .max]

public func getSupportedThinkingLevels(_ model: Model) -> [ModelThinkingLevel] {
    if !model.reasoning { return [.off] }

    return EXTENDED_THINKING_LEVELS.filter { level in
        let mapped = model.thinkingLevelMap?[level]
        if case .some(.none) = mapped { return false } // explicit null: unsupported
        if level == .xhigh || level == .max { return mapped != nil }
        return true
    }
}

public func clampThinkingLevel(_ model: Model, _ level: ModelThinkingLevel) -> ModelThinkingLevel {
    let availableLevels = getSupportedThinkingLevels(model)
    if availableLevels.contains(level) { return level }

    guard let requestedIndex = EXTENDED_THINKING_LEVELS.firstIndex(of: level) else { return availableLevels.first ?? .off }

    for i in requestedIndex..<EXTENDED_THINKING_LEVELS.count {
        let candidate = EXTENDED_THINKING_LEVELS[i]
        if availableLevels.contains(candidate) { return candidate }
    }
    for i in stride(from: requestedIndex - 1, through: 0, by: -1) {
        let candidate = EXTENDED_THINKING_LEVELS[i]
        if availableLevels.contains(candidate) { return candidate }
    }
    return availableLevels.first ?? .off
}

/// Check if two models are equal by comparing their type, id, and provider.
/// Returns false if either model is nil.
public func modelsAreEqual(_ a: AnyModel?, _ b: AnyModel?) -> Bool {
    guard let a, let b else { return false }
    return getModelType(a) == getModelType(b) && a.id == b.id && a.provider == b.provider
}
