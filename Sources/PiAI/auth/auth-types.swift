import Foundation

// Port of packages/ai/src/auth/types.ts (renamed: SwiftPM forbids two `types.swift` in one target)

/// Request auth for a single model request. If a value cannot be expressed as
/// `apiKey`, `headers`, or `baseUrl`, it is provider config, not auth.
public struct ModelAuth: Sendable {
    public var apiKey: String?
    public var headers: ProviderHeaders?
    public var baseUrl: String?
    public init(apiKey: String? = nil, headers: ProviderHeaders? = nil, baseUrl: String? = nil) {
        self.apiKey = apiKey; self.headers = headers; self.baseUrl = baseUrl
    }
}

/// Stored api-key credential. `env` holds provider-scoped environment/config
/// values such as Cloudflare account/gateway ids.
public struct ApiKeyCredential: Sendable, Hashable {
    public var type: String { "api_key" }
    public var key: String?
    public var env: ProviderEnv?
    public init(key: String? = nil, env: ProviderEnv? = nil) { self.key = key; self.env = env }
}

/// OAuth token data returned by extension compatibility flows.
/// `[key: string]: unknown` extra fields live in `extra` (insertion-ordered).
public struct OAuthCredentials: Sendable, Hashable {
    public var refresh: String
    public var access: String
    public var expires: Int
    public var extra: JsonObject
    public init(refresh: String, access: String, expires: Int, extra: JsonObject = JsonObject()) {
        self.refresh = refresh; self.access = access; self.expires = expires; self.extra = extra
    }
}

/// Stored canonical OAuth credential (`OAuthCredential extends OAuthCredentials { type: "oauth" }`).
public typealias OAuthCredential = OAuthCredentials

/// One type-tagged credential per provider — the shape of today's auth.json.
public enum Credential: Sendable, Hashable {
    case apiKey(ApiKeyCredential)
    case oauth(OAuthCredential)

    /// "api_key" | "oauth"
    public var type: AuthType {
        switch self {
        case .apiKey: return "api_key"
        case .oauth: return "oauth"
        }
    }
    public var apiKeyCredential: ApiKeyCredential? { if case .apiKey(let c) = self { return c } else { return nil } }
    public var oauthCredential: OAuthCredential? { if case .oauth(let c) = self { return c } else { return nil } }
}

/// Non-secret credential metadata for account/status enumeration.
public struct CredentialInfo: Sendable, Hashable {
    public var providerId: String
    public var type: AuthType
    public init(providerId: String, type: AuthType) { self.providerId = providerId; self.type = type }
}

/// Optional cancellation for public auth and credential operations.
public struct AuthOperationOptions: Sendable {
    public var signal: AbortSignal?
    public init(signal: AbortSignal? = nil) { self.signal = signal }
}

/// App-owned credential storage, keyed by `Provider.id`, one credential per
/// provider. `modify` is the only write path, so every mutation is a
/// serialized read-modify-write; `Models.getAuth()` runs OAuth refresh inside
/// `modify` so concurrent requests cannot double-refresh a rotated token. The
/// app persists a credential after login via
/// `modify(provider.id, async () => credential)`. Login/logout orchestration
/// is app-owned.
///
/// Error semantics: `read` resolves `undefined` for missing entries. Methods
/// reject only on storage failure; `Models` wraps such rejections in
/// `ModelsError` with code "auth". Best-effort stores that serve an in-memory
/// view and record persistence errors internally (like coding-agent's
/// AuthStorage) are valid implementations.
public protocol CredentialStore: Sendable {
    /// Read the stored credential, possibly expired. Display/status use;
    /// resolved request auth comes from `Models.getAuth()`.
    func read(_ providerId: String, _ options: AuthOperationOptions?) async throws -> Credential?

    /// List stored credential metadata without resolving or exposing secrets.
    /// Implementations must not execute configured API-key commands while listing.
    func list(_ options: AuthOperationOptions?) async throws -> [CredentialInfo]

    /// Serialized write — the only write path. `fn` sees the current credential
    /// because correct writes (refresh, login-during-refresh) depend on it;
    /// return the new credential, or nil to leave the entry unchanged.
    /// Mutual exclusion per provider id, cross-process too where the backing
    /// store supports it (e.g. a file lock). Resolves with the post-write
    /// credential. Rejections from `fn` propagate.
    func modify(
        _ providerId: String,
        _ fn: @escaping @Sendable (Credential?) async throws -> Credential?,
        _ options: AuthOperationOptions?
    ) async throws -> Credential?

    /// Remove a credential (logout). Implementations serialize this against `modify`.
    func delete(_ providerId: String, _ options: AuthOperationOptions?) async throws
}

extension CredentialStore {
    public func read(_ providerId: String) async throws -> Credential? { try await read(providerId, nil) }
    public func list() async throws -> [CredentialInfo] { try await list(nil) }
    public func modify(_ providerId: String, _ fn: @escaping @Sendable (Credential?) async throws -> Credential?) async throws -> Credential? {
        try await modify(providerId, fn, nil)
    }
    public func delete(_ providerId: String) async throws { try await delete(providerId, nil) }
}

/// Environment access for auth resolution. Injectable for tests and browsers.
public struct AuthContext: Sendable {
    public var env: @Sendable (String) async -> String?
    /// Check whether a file exists. Supports a leading `~`. Always false in browsers.
    public var fileExists: @Sendable (String) async -> Bool
    public init(env: @escaping @Sendable (String) async -> String?, fileExists: @escaping @Sendable (String) async -> Bool) {
        self.env = env; self.fileExists = fileExists
    }
}

/// Result of resolving auth for a model.
public struct AuthResult: Sendable {
    public var auth: ModelAuth
    /// Provider-scoped environment/config values resolved from credentials and ambient context.
    public var env: ProviderEnv?
    /// Human-readable label for status UI: "ANTHROPIC_API_KEY", "OAuth", "~/.aws/credentials".
    public var source: String?
    public init(auth: ModelAuth, env: ProviderEnv? = nil, source: String? = nil) { self.auth = auth; self.env = env; self.source = source }
}

public struct AuthCheck: Sendable, Hashable {
    public var source: String?
    public var type: AuthType
    public init(source: String? = nil, type: AuthType) { self.source = source; self.type = type }
}

/// "api_key" | "oauth"
public typealias AuthType = String

public struct AuthPromptOption: Sendable, Hashable {
    public var id: String
    public var label: String
    public var description: String?
    public init(id: String, label: String, description: String? = nil) { self.id = id; self.label = label; self.description = description }
}

/// Prompt shown to the user during login. `signal` lets the flow cancel a
/// pending prompt when an out-of-band event resolves the step, e.g. a
/// `manual_code` prompt raced against a callback server, aborted when the
/// callback wins.
public struct AuthPrompt: Sendable {
    public enum Kind: Sendable {
        case text(message: String, placeholder: String? = nil)
        case secret(message: String, placeholder: String? = nil)
        case select(message: String, options: [AuthPromptOption])
        case manual_code(message: String, placeholder: String? = nil)
    }

    public var signal: AbortSignal?
    public var kind: Kind
    public init(_ kind: Kind, signal: AbortSignal? = nil) { self.kind = kind; self.signal = signal }

    /// "text" | "secret" | "select" | "manual_code"
    public var type: String {
        switch kind {
        case .text: return "text"
        case .secret: return "secret"
        case .select: return "select"
        case .manual_code: return "manual_code"
        }
    }
    public var message: String {
        switch kind {
        case .text(let m, _), .secret(let m, _), .select(let m, _), .manual_code(let m, _): return m
        }
    }
}

public struct AuthInfoLink: Sendable, Hashable {
    public var url: String
    public var label: String?
    public init(url: String, label: String? = nil) { self.url = url; self.label = label }
}

public enum AuthEvent: Sendable, Hashable {
    case info(message: String, links: [AuthInfoLink]? = nil)
    case auth_url(url: String, instructions: String? = nil)
    case device_code(userCode: String, verificationUri: String, intervalSeconds: Int? = nil, expiresInSeconds: Int? = nil)
    case progress(message: String)

    public var type: String {
        switch self {
        case .info: return "info"
        case .auth_url: return "auth_url"
        case .device_code: return "device_code"
        case .progress: return "progress"
        }
    }
}

/// Login interaction callbacks serving both api-key and OAuth flows.
///
/// `prompt()` returns the entered/selected string (`select` returns the option
/// id). Rejects on cancel/abort. `signal` aborts the whole login flow;
/// per-prompt cancellation uses `AuthPrompt.signal`.
public struct AuthInteraction: Sendable {
    public var signal: AbortSignal?
    public var prompt: @Sendable (AuthPrompt) async throws -> String
    public var notify: @Sendable (AuthEvent) -> Void
    public init(signal: AbortSignal? = nil, prompt: @escaping @Sendable (AuthPrompt) async throws -> String, notify: @escaping @Sendable (AuthEvent) -> Void) {
        self.signal = signal; self.prompt = prompt; self.notify = notify
    }
}

/// Normalized interaction passed to provider login implementations.
public struct ProviderAuthInteraction: Sendable {
    public var signal: AbortSignal
    public var prompt: @Sendable (AuthPrompt) async throws -> String
    public var notify: @Sendable (AuthEvent) -> Void
    public init(signal: AbortSignal, prompt: @escaping @Sendable (AuthPrompt) async throws -> String, notify: @escaping @Sendable (AuthEvent) -> Void) {
        self.signal = signal; self.prompt = prompt; self.notify = notify
    }
}

/// Input of `ApiKeyAuth.check` / `ApiKeyAuth.resolve`.
public struct ApiKeyAuthInput: Sendable {
    public var ctx: AuthContext
    public var credential: ApiKeyCredential?
    public var signal: AbortSignal
    public init(ctx: AuthContext, credential: ApiKeyCredential? = nil, signal: AbortSignal) { self.ctx = ctx; self.credential = credential; self.signal = signal }
}

/// Api-key auth: stored key/provider env plus ambient sources (env vars, AWS
/// profiles, ADC files). Ambient-only providers omit `login`.
public struct ApiKeyAuth: Sendable {
    /// Display name, e.g. "Anthropic API key".
    public var name: String

    /// Interactive setup (prompt for key/provider env). Absent = ambient-only.
    public var login: (@Sendable (ProviderAuthInteraction) async throws -> ApiKeyCredential)?

    /// Optional side-effect-free availability check. Use this when `resolve()` may
    /// execute commands or perform other request-time work. Missing means Models
    /// checks availability by resolving auth.
    public var check: (@Sendable (ApiKeyAuthInput) async throws -> AuthCheck?)?

    /// Resolve auth from the stored credential and/or ambient sources, merging
    /// per field (`credential.key ?? env("...")`, `credential.env?.NAME ?? env("...")`).
    /// nil = not configured. Resolution is provider-scoped; model-specific
    /// endpoint preparation happens after auth has been resolved.
    public var resolve: @Sendable (ApiKeyAuthInput) async throws -> AuthResult?

    public init(
        name: String,
        login: (@Sendable (ProviderAuthInteraction) async throws -> ApiKeyCredential)? = nil,
        check: (@Sendable (ApiKeyAuthInput) async throws -> AuthCheck?)? = nil,
        resolve: @escaping @Sendable (ApiKeyAuthInput) async throws -> AuthResult?
    ) {
        self.name = name; self.login = login; self.check = check; self.resolve = resolve
    }
}

/// App-supplied context for `Models.login`.
public struct LoginOptions: Sendable {
    /// Returns the stable ID of this app installation, e.g. sent to OpenAI as its
    /// agent host ID. Called only by login flows that need it, so apps can create
    /// the ID on first use and must return the same ID on every later call.
    public var getDeviceId: (@Sendable () -> String)?
    /// Name this app introduces itself with during login, e.g. OpenAI's agent name hint and
    /// Codex originator. Defaults to pi's own name.
    public var agentName: String?
    public init(getDeviceId: (@Sendable () -> String)? = nil, agentName: String? = nil) { self.getDeviceId = getDeviceId; self.agentName = agentName }
}

/// OAuth auth. The `refresh`/`toAuth` split lets `Models` own the locked
/// refresh pattern: `refresh` produces a credential, `toAuth` derives request
/// auth from whatever credential ends up stored.
public struct OAuthAuth: Sendable {
    /// Display name, e.g. "Anthropic (Claude Pro/Max)".
    public var name: String

    /// Whether access through this auth method is backed by a provider subscription.
    public var isSubscription: Bool?

    /// Selector label for the OAuth login option, e.g. "Sign in with SuperGrok or X Premium".
    public var loginLabel: String?

    public var login: @Sendable (ProviderAuthInteraction, LoginOptions?) async throws -> OAuthCredential

    /// Exchange the refresh token. Network call; throws on failure
    /// (invalid_grant etc.). `Models` runs this under the store lock.
    public var refresh: @Sendable (OAuthCredential, AbortSignal) async throws -> OAuthCredential

    /// Side-effect-free derivation of request auth from a valid credential.
    /// Covers per-credential baseUrl (GitHub Copilot). Async so lazy wrappers
    /// can load the implementation on first use.
    public var toAuth: @Sendable (OAuthCredential) async throws -> ModelAuth

    public init(
        name: String,
        isSubscription: Bool? = nil,
        loginLabel: String? = nil,
        login: @escaping @Sendable (ProviderAuthInteraction, LoginOptions?) async throws -> OAuthCredential,
        refresh: @escaping @Sendable (OAuthCredential, AbortSignal) async throws -> OAuthCredential,
        toAuth: @escaping @Sendable (OAuthCredential) async throws -> ModelAuth
    ) {
        self.name = name; self.isSubscription = isSubscription; self.loginLabel = loginLabel
        self.login = login; self.refresh = refresh; self.toAuth = toAuth
    }
}

/// Provider auth. At least one of `apiKey`/`oauth` must be present: even
/// ambient-credential providers and keyless local servers provide `apiKey`
/// auth whose `resolve()` reports whether the provider is configured.
public struct ProviderAuth: Sendable {
    public var apiKey: ApiKeyAuth?
    public var oauth: OAuthAuth?
    public init(apiKey: ApiKeyAuth? = nil, oauth: OAuthAuth? = nil) { self.apiKey = apiKey; self.oauth = oauth }
}
