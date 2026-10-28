import Foundation

// Port of packages/ai/src/compat.ts
//
// Temporary compatibility entrypoint preserving the old global pi-ai API
// surface: api-dispatch `stream()`/`complete()` with env API key injection,
// the api-registry, generated catalog reads (`getModel`/`getModels`/
// `getProviders`), and per-API lazy stream wrappers.
//
// The `export *` re-exports are implicit in Swift (one module). Not ported: image generation
// (`image-models`, `images`, `images-api-registry`, `providers/images/register-builtins`),
// `registerFauxProvider` (providers/faux), and the bedrock, vertex, mistral, codex and
// pi-messages API wrappers.

/// @deprecated Static catalog read. Use `getBuiltinModel` or `Models.getModel()`.
public func getModel(_ provider: BuiltinProvider, _ modelId: String) -> Model? { getBuiltinModel(provider, modelId) }

/// @deprecated Static catalog read. Use `getBuiltinModels` or `Models.getModels()`.
public func getModels(_ provider: BuiltinProvider) -> [Model] { getBuiltinModels(provider) }

/// @deprecated Static catalog read. Use `getBuiltinProviders` or `Models.getProviders()`.
public func getProviders() -> [BuiltinProvider] { getBuiltinProviders() }

/// `(model, context: TranscriptContext, options?) => AssistantMessageEventStream`; throws on api mismatch.
public typealias ApiStreamFunction = @Sendable (Model, TranscriptContext, StreamOptions?) throws -> AssistantMessageEventStream
public typealias ApiStreamSimpleFunction = @Sendable (Model, TranscriptContext, SimpleStreamOptions?) throws -> AssistantMessageEventStream

public struct ApiProvider: Sendable {
    public var api: Api
    public var stream: StreamFunction
    public var streamSimple: StreamFunction
    public init(api: Api, stream: @escaping StreamFunction, streamSimple: @escaping StreamFunction) {
        self.api = api; self.stream = stream; self.streamSimple = streamSimple
    }
}

/// A registered provider. A class so registrations compare by identity, like the upstream objects.
public final class ApiProviderInternal: Sendable {
    public let api: Api
    public let stream: ApiStreamFunction
    public let streamSimple: ApiStreamSimpleFunction
    init(api: Api, stream: @escaping ApiStreamFunction, streamSimple: @escaping ApiStreamSimpleFunction) {
        self.api = api; self.stream = stream; self.streamSimple = streamSimple
    }
}

private struct RegisteredApiProvider: Sendable {
    var provider: ApiProviderInternal
    var sourceId: String?
}

private struct CompatState: Sendable {
    var apiProviderRegistry = JSMap<RegisteredApiProvider>()
    var builtinApiProviderInstances = JSMap<ApiProviderInternal?>()
}

/// Module state. The upstream module registers the builtin APIs at import time; Swift does it on
/// first use of the registry.
private let compatState: Locked<CompatState> = {
    let state = Locked(CompatState())
    registerBuiltInApiProviders(into: state)
    return state
}()

private func wrapStream(_ api: Api, _ stream: @escaping StreamFunction) -> ApiStreamFunction {
    { model, context, options in
        if model.api != api {
            throw PiError("Mismatched api: \(model.api) expected \(api)")
        }
        return stream(model, context, options)
    }
}

private func wrapStreamSimple(_ api: Api, _ streamSimple: @escaping StreamFunction) -> ApiStreamSimpleFunction {
    { model, context, options in
        if model.api != api {
            throw PiError("Mismatched api: \(model.api) expected \(api)")
        }
        return streamSimple(model, context, options)
    }
}

private func register(_ provider: ApiProvider, _ sourceId: String?, in state: inout CompatState) {
    state.apiProviderRegistry[provider.api] = RegisteredApiProvider(
        provider: ApiProviderInternal(
            api: provider.api,
            stream: wrapStream(provider.api, provider.stream),
            streamSimple: wrapStreamSimple(provider.api, provider.streamSimple)
        ),
        sourceId: sourceId
    )
}

public func registerApiProvider(_ provider: ApiProvider, _ sourceId: String? = nil) {
    compatState.withLock { register(provider, sourceId, in: &$0) }
}

public func getApiProvider(_ api: Api) -> ApiProviderInternal? {
    compatState.withLock { $0.apiProviderRegistry[api]?.provider }
}

public func getApiProviders() -> [ApiProviderInternal] {
    compatState.withLock { $0.apiProviderRegistry.values.map(\.provider) }
}

public func unregisterApiProviders(_ sourceId: String) {
    compatState.withLock { state in
        for (api, entry) in state.apiProviderRegistry.entries where entry.sourceId == sourceId {
            state.apiProviderRegistry[api] = nil
        }
    }
}

private func clearApiProviders(_ state: inout CompatState) {
    state.apiProviderRegistry.removeAll()
}

// Not ported: registerFauxProvider (providers/faux belongs to another group).

private func BUILTIN_APIS() -> [(Api, ProviderStreams)] {
    [
        ("anthropic-messages", anthropicMessagesApi()),
        ("openai-completions", openAICompletionsApi()),
        ("openai-responses", openAIResponsesApi()),
        // Not ported: ("openai-codex-responses", openAICodexResponsesApi())
        ("azure-openai-responses", azureOpenAIResponsesApi()),
        ("google-generative-ai", googleGenerativeAIApi()),
        // Not ported: google-vertex, mistral-conversations, bedrock-converse-stream, pi-messages
    ]
}

private func registerBuiltInApiProviders(_ state: inout CompatState) {
    for (api, streams) in BUILTIN_APIS() {
        if state.apiProviderRegistry[api] == nil {
            register(ApiProvider(api: api, stream: streams.stream, streamSimple: streams.streamSimple), nil, in: &state)
        }
        state.builtinApiProviderInstances[api] = .some(state.apiProviderRegistry[api]?.provider)
    }
}

private func registerBuiltInApiProviders(into state: Locked<CompatState>) {
    state.withLock { registerBuiltInApiProviders(&$0) }
}

/// Registers the builtin API implementations into the api-registry without
/// clobbering existing entries: compat may load after a test or extension has
/// already registered an override for a builtin api id.
public func registerBuiltInApiProviders() {
    registerBuiltInApiProviders(into: compatState)
}

public func resetApiProviders() {
    compatState.withLock { state in
        clearApiProviders(&state)
        state.builtinApiProviderInstances.removeAll()
        registerBuiltInApiProviders(&state)
    }
}

/// Upstream builds this once at import, after the app's catalog is fixed. Swift builds it on first
/// use, so install builtin catalogs (`setBuiltinModels`) before the first compat stream call.
private let compatModels: any MutableModels = builtinModels()
public let AMBIENT_AUTH_MARKER = "<authenticated>"

private func hasExplicitApiKey(_ apiKey: String?) -> Bool {
    guard let apiKey else { return false }
    return !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
}

func withEnvApiKey(_ model: Model, _ options: StreamOptions?) -> StreamOptions? {
    if hasExplicitApiKey(options?.apiKey) { return options }
    let apiKey = getEnvApiKey(model.provider, options?.env)
    guard let apiKey, !apiKey.isEmpty, apiKey != AMBIENT_AUTH_MARKER else { return options }
    var next = options ?? StreamOptions()
    next.apiKey = apiKey
    return next
}

func hasResolvedCloudflareAuth(_ options: StreamOptions?) -> Bool {
    hasExplicitApiKey(options?.apiKey)
        || options?.headers?.contains(where: { $0.0 == "cf-aig-authorization" && $0.1 != nil }) == true
}

func getBuiltinProviderForModel(_ model: Model) -> Provider? {
    let (current, builtin) = compatState.withLock { state in
        (state.apiProviderRegistry[model.api]?.provider, state.builtinApiProviderInstances[model.api] ?? nil)
    }
    if current !== builtin { return nil }
    guard let provider = compatModels.getProvider(model.provider) else { return nil }
    return ((try? provider.getModels()) ?? []).contains { $0.api == model.api } ? provider : nil
}

private func resolveApiProvider(_ api: Api) throws -> ApiProviderInternal {
    guard let provider = getApiProvider(api) else {
        throw PiError("No API provider registered for api: \(api)")
    }
    return provider
}

public func stream(_ model: Model, _ context: Context, _ options: ProviderStreamOptions? = nil) throws -> AssistantMessageEventStream {
    let transcript = normalizeContext(context)
    if let builtinProvider = getBuiltinProviderForModel(model) {
        if model.provider.hasPrefix("cloudflare-") && !hasResolvedCloudflareAuth(options) {
            return compatModels.stream(model, context, options)
        }
        return builtinProvider.stream(model, transcript, withEnvApiKey(model, options))
    }
    let provider = try resolveApiProvider(model.api)
    return try provider.stream(model, transcript, withEnvApiKey(model, options))
}

public func complete(_ model: Model, _ context: Context, _ options: ProviderStreamOptions? = nil) async throws -> AssistantMessage {
    let s = try stream(model, context, options)
    return await s.result()
}

public func streamSimple(_ model: Model, _ context: Context, _ options: SimpleStreamOptions? = nil) throws -> AssistantMessageEventStream {
    let transcript = normalizeContext(context)
    if let builtinProvider = getBuiltinProviderForModel(model) {
        if model.provider.hasPrefix("cloudflare-") && !hasResolvedCloudflareAuth(options) {
            return compatModels.streamSimple(model, context, options)
        }
        return builtinProvider.streamSimple(model, transcript, withEnvApiKey(model, options))
    }
    let provider = try resolveApiProvider(model.api)
    return try provider.streamSimple(model, transcript, withEnvApiKey(model, options))
}

public func completeSimple(_ model: Model, _ context: Context, _ options: SimpleStreamOptions? = nil) async throws -> AssistantMessage {
    let s = try streamSimple(model, context, options)
    return await s.result()
}
