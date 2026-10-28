import Foundation

// Port of pi@d5b3de22 packages/ai/src/utils/identity.ts (native request identity).
// The version describes the existing PiAI baseline, not a whole-package upgrade.
public let PI_AI_VERSION = "1.3.0"

public enum UserAgentMode: Sendable, Hashable, Codable {
    case short, detailed, custom(String)
    public init(from decoder: Decoder) throws {
        let value = try decoder.singleValueContainer()
        if let string = try? value.decode(String.self) {
            switch string {
            case "short": self = .short
            case "detailed": self = .detailed
            default: throw DecodingError.dataCorruptedError(in: value, debugDescription: "Unknown user agent mode")
            }
        } else {
            let object = try value.decode([String: String].self)
            guard let custom = object["custom"] else {
                throw DecodingError.dataCorruptedError(in: value, debugDescription: "Missing custom user agent")
            }
            self = .custom(custom)
        }
    }
    public func encode(to encoder: Encoder) throws {
        var value = encoder.singleValueContainer()
        switch self {
        case .short: try value.encode("short")
        case .detailed: try value.encode("detailed")
        case .custom(let custom): try value.encode(["custom": custom])
        }
    }
}

public struct ClientAttribution: Sendable, Hashable, Codable {
    public var name: String
    public var url: String
    public var categories: [String]?
    public init(name: String, url: String, categories: [String]? = nil) {
        self.name = name; self.url = url; self.categories = categories
    }
}
public let PI_ATTRIBUTION = ClientAttribution(name: "pi", url: "https://pi.dev", categories: ["cli-agent"])

public struct ClientIdentity: Sendable, Hashable, Codable {
    public var userAgent: UserAgentMode?
    /// nil inherits; .some(nil) explicitly disables attribution from an earlier identity.
    public var attribution: ClientAttribution??
    public var version: String?
    public init(userAgent: UserAgentMode? = nil, attribution: ClientAttribution?? = nil, version: String? = nil) {
        self.userAgent = userAgent; self.attribution = attribution; self.version = version
    }
    private enum CodingKeys: CodingKey { case userAgent, attribution, version }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        userAgent = try c.decodeIfPresent(UserAgentMode.self, forKey: .userAgent)
        attribution = c.contains(.attribution) ? .some(try c.decodeIfPresent(ClientAttribution.self, forKey: .attribution)) : nil
        version = try c.decodeIfPresent(String.self, forKey: .version)
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encodeIfPresent(userAgent, forKey: .userAgent)
        if let attribution { try c.encode(attribution, forKey: .attribution) }
        try c.encodeIfPresent(version, forKey: .version)
    }
}

public struct ClientIdentityTarget: Sendable {
    public let provider: String
    public let baseUrl: String
    public init(provider: String, baseUrl: String) { self.provider = provider; self.baseUrl = baseUrl }
    public init(_ model: Model) { self.init(provider: model.provider, baseUrl: model.baseUrl) }
}

public func mergeClientIdentity(_ sources: ClientIdentity?...) -> ClientIdentity? {
    var merged: ClientIdentity?
    for source in sources {
        guard let source else { continue }
        if merged == nil { merged = ClientIdentity() }
        if let mode = source.userAgent { merged?.userAgent = mode }
        if let attribution = source.attribution { merged?.attribution = .some(attribution) }
        if let version = source.version { merged?.version = version }
    }
    return merged
}

public func getClientVersion(_ identity: ClientIdentity? = nil) -> String { identity?.version ?? PI_AI_VERSION }

public func formatUserAgent(_ identity: ClientIdentity? = nil) -> String {
    switch identity?.userAgent ?? .detailed {
    case .short: return "pi"
    case .custom(let value): return value
    case .detailed:
        #if os(macOS) || os(iOS)
        let platform = "darwin"
        #elseif os(Linux)
        let platform = "linux"
        #else
        let platform = "unknown"
        #endif
        #if arch(arm64)
        let architecture = "arm64"
        #elseif arch(x86_64)
        let architecture = "x64"
        #else
        let architecture = "unknown"
        #endif
        return "pi/\(getClientVersion(identity)) (\(platform); swift/6; \(architecture))"
    }
}

private func isOpenCode(_ target: ClientIdentityTarget) -> Bool {
    target.provider == "opencode" || target.provider == "opencode-go" || URL(string: target.baseUrl)?.host == "opencode.ai"
}

public func getAttributionHeaders(_ target: ClientIdentityTarget, _ identity: ClientIdentity? = nil) -> ProviderHeaders {
    guard let optional = identity?.attribution, let attribution = optional else { return [] }
    if target.provider == "openrouter" || target.baseUrl.contains("openrouter.ai") {
        var headers: ProviderHeaders = [("HTTP-Referer", attribution.url), ("X-OpenRouter-Title", attribution.name)]
        if let categories = attribution.categories, !categories.isEmpty { headers.append(("X-OpenRouter-Categories", categories.joined(separator: ","))) }
        return headers
    }
    if target.provider == "nvidia" || URL(string: target.baseUrl)?.host == "integrate.api.nvidia.com" {
        return [("X-BILLING-INVOKE-ORIGIN", attribution.name.prefix(1).uppercased() + attribution.name.dropFirst())]
    }
    if isOpenCode(target) { return [("x-opencode-client", attribution.name)] }
    return []
}

public func getOpenCodeSessionHeaders(_ target: ClientIdentityTarget, _ sessionId: String?) -> ProviderHeaders? {
    guard let sessionId, !sessionId.isEmpty, isOpenCode(target) else { return nil }
    return [("x-opencode-session", sessionId)]
}

public func getIdentityHeaders(_ target: ClientIdentityTarget, _ identity: ClientIdentity? = nil) -> ProviderHeaders {
    [("User-Agent", formatUserAgent(identity))] + getAttributionHeaders(target, identity)
}

/// Adds request defaults without mutating the collection; request fields take precedence.
public func withClientIdentity(_ models: any Models, _ identity: ClientIdentity) -> any Models {
    if let mutable = models as? any MutableModels { return IdentityMutableModels(mutable, identity) }
    return IdentityModels(models, identity)
}
public func withClientIdentity(_ models: any MutableModels, _ identity: ClientIdentity) -> any MutableModels {
    IdentityMutableModels(models, identity)
}

// Immutable forwarding objects. The wrapped collection owns its synchronization.
private class IdentityModels: Models, @unchecked Sendable {
    let base: any Models
    let identity: ClientIdentity
    init(_ base: any Models, _ identity: ClientIdentity) { self.base = base; self.identity = identity }
    func options(_ input: StreamOptions?) -> StreamOptions {
        var result = input ?? StreamOptions()
        result.identity = mergeClientIdentity(identity, input?.identity)
        return result
    }
    func getProviders() -> [Provider] { base.getProviders() }
    func getProvider(_ id: String) -> Provider? { base.getProvider(id) }
    func getModels(_ provider: String?) -> [Model] { base.getModels(provider) }
    func getModel(_ provider: String, _ id: String) -> Model? { base.getModel(provider, id) }
    func getModelsOfType(_ type: ModelType, _ provider: String?) -> [AnyModel] { base.getModelsOfType(type, provider) }
    func getModelOfType(_ type: ModelType, _ provider: String, _ id: String) -> AnyModel? { base.getModelOfType(type, provider, id) }
    func getAllModels(_ provider: String?) -> [AnyModel] { base.getAllModels(provider) }
    func refresh(_ options: ModelsRefreshOptions) async throws -> ModelsRefreshResult { try await base.refresh(options) }
    func checkAuth(_ providerId: String, _ options: AuthOperationOptions?) async throws -> AuthCheck? { try await base.checkAuth(providerId, options) }
    func getAvailable(_ providerId: String?, _ options: AuthOperationOptions?) async throws -> [Model] { try await base.getAvailable(providerId, options) }
    func getAvailableOfType(_ type: ModelType, _ providerId: String?, _ options: AuthOperationOptions?) async throws -> [AnyModel] { try await base.getAvailableOfType(type, providerId, options) }
    func getAllAvailable(_ providerId: String?, _ options: AuthOperationOptions?) async throws -> [AnyModel] { try await base.getAllAvailable(providerId, options) }
    func getAuth(_ providerId: String, _ overrides: AuthResolutionOverrides?) async throws -> AuthResult? { try await base.getAuth(providerId, overrides) }
    func getAuth(_ model: AnyModel, _ overrides: AuthResolutionOverrides?) async throws -> AuthResult? { try await base.getAuth(model, overrides) }
    func login(_ providerId: String, _ type: AuthType, _ interaction: AuthInteraction, _ options: LoginOptions?) async throws -> Credential { try await base.login(providerId, type, interaction, options) }
    func logout(_ providerId: String, _ options: AuthOperationOptions?) async throws { try await base.logout(providerId, options) }
    func stream(_ model: Model, _ context: Context, _ input: StreamOptions?, transforms: ModelsRequestTransforms?) -> AssistantMessageEventStream { base.stream(model, context, options(input), transforms: transforms) }
    func complete(_ model: Model, _ context: Context, _ input: StreamOptions?, transforms: ModelsRequestTransforms?) async -> AssistantMessage { await base.complete(model, context, options(input), transforms: transforms) }
    func streamSimple(_ model: Model, _ context: Context, _ input: SimpleStreamOptions?, transforms: ModelsRequestTransforms?) -> AssistantMessageEventStream { base.streamSimple(model, context, options(input), transforms: transforms) }
    func completeSimple(_ model: Model, _ context: Context, _ input: SimpleStreamOptions?, transforms: ModelsRequestTransforms?) async -> AssistantMessage { await base.completeSimple(model, context, options(input), transforms: transforms) }
    func streamDeferred(_ model: Model, _ handle: DeferredHandle, _ input: DeferredFetchOptions?, transforms: ModelsRequestTransforms?) -> AssistantMessageEventStream { base.streamDeferred(model, handle, options(input), transforms: transforms) }
    func fetchDeferred(_ model: Model, _ handle: DeferredHandle, _ input: DeferredFetchOptions?, transforms: ModelsRequestTransforms?) async -> AssistantMessage { await base.fetchDeferred(model, handle, options(input), transforms: transforms) }
    func cancelDeferred(_ model: Model, _ handle: DeferredHandle, _ input: DeferredCancelOptions?, transforms: ModelsRequestTransforms?) async throws { try await base.cancelDeferred(model, handle, options(input), transforms: transforms) }
}

private final class IdentityMutableModels: IdentityModels, MutableModels, @unchecked Sendable {
    private let mutable: any MutableModels
    init(_ base: any MutableModels, _ identity: ClientIdentity) { mutable = base; super.init(base, identity) }
    func setProvider(_ provider: Provider) { mutable.setProvider(provider) }
    func deleteProvider(_ id: String) { mutable.deleteProvider(id) }
    func clearProviders() { mutable.clearProviders() }
}
