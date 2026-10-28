import Foundation

// Port of packages/ai/src/auth/resolve.ts

public struct AuthResolutionOverrides: Sendable {
    public var apiKey: String?
    public var env: ProviderEnv?
    /// Require this much remaining OAuth-token validity; defaults to five minutes.
    public var minOAuthValidityMs: Int?
    public var signal: AbortSignal?
    public init(apiKey: String? = nil, env: ProviderEnv? = nil, minOAuthValidityMs: Int? = nil, signal: AbortSignal? = nil) {
        self.apiKey = apiKey; self.env = env; self.minOAuthValidityMs = minOAuthValidityMs; self.signal = signal
    }
}

/// Auth resolution shared by all operations in a `Models` collection.
/// A stored credential owns the provider: ambient/env is consulted only when
/// nothing is stored. No silent env fallback after a failed refresh or for a
/// credential type without a matching handler.
public func resolveProviderAuth(
    _ provider: (id: String, auth: ProviderAuth),
    _ credentials: any CredentialStore,
    _ authContext: AuthContext,
    _ overrides: AuthResolutionOverrides? = nil
) async throws -> AuthResult? {
    let signal = operationSignal(overrides?.signal)
    let id = provider.id
    let auth = provider.auth
    return try await raceWithAbortSignal(
        { try await resolveProviderAuthWithSignal((id, auth), credentials, authContext, overrides, signal) },
        signal
    )
}

private func resolveProviderAuthWithSignal(
    _ provider: (id: String, auth: ProviderAuth),
    _ credentials: any CredentialStore,
    _ authContext: AuthContext,
    _ overrides: AuthResolutionOverrides?,
    _ signal: AbortSignal
) async throws -> AuthResult? {
    try signal.throwIfAborted()
    let requestAuthContext = overrides?.env.map { overlayEnvAuthContext(authContext, $0) } ?? authContext

    if let overrideApiKey = overrides?.apiKey, let apiKey = provider.auth.apiKey {
        return try await resolveApiKey(
            requestAuthContext,
            apiKey,
            provider.id,
            ApiKeyCredential(key: overrideApiKey, env: overrides?.env),
            signal
        )
    }

    let stored = try await readCredential(credentials, provider.id, signal)
    if let stored {
        if case .oauth(let oauthCredential) = stored, let oauth = provider.auth.oauth {
            return try await resolveStoredOAuth(
                credentials,
                provider.id,
                oauth,
                oauthCredential,
                signal,
                overrides?.minOAuthValidityMs
            )
        }
        if case .apiKey(var apiKeyCredential) = stored, let apiKey = provider.auth.apiKey {
            if let env = overrides?.env {
                apiKeyCredential.env = (apiKeyCredential.env ?? [:]).merging(env) { _, override in override }
            }
            return try await resolveApiKey(requestAuthContext, apiKey, provider.id, apiKeyCredential, signal)
        }
        return nil
    }

    // Ambient (env vars, AWS profiles, ADC files).
    if let apiKey = provider.auth.apiKey {
        return try await resolveApiKey(requestAuthContext, apiKey, provider.id, nil, signal)
    }
    return nil
}

private func overlayEnvAuthContext(_ base: AuthContext, _ env: ProviderEnv) -> AuthContext {
    AuthContext(
        env: { name in
            if let value = env[name], !value.isEmpty { return value }
            return await base.env(name)
        },
        fileExists: { path in await base.fileExists(path) }
    )
}

private let DEFAULT_OAUTH_MINIMUM_VALIDITY_MS = 5 * 60 * 1000
private let DEFAULT_OAUTH_REFRESH_TIMEOUT_MS = 15_000

/// Refresh a stored OAuth credential under the credential-store lock and persist
/// the result before the lock is released. `needsRefresh` is re-checked under
/// the lock, so concurrent callers and processes refresh only once.
///
/// `signal` cancels only the wait for the lock. Once a refresh starts, the
/// provider may already have rotated the refresh token, so the refresh and its
/// persistence ignore `signal` and are bounded only by a timeout. Otherwise a
/// cancelled caller could discard the only valid refresh token. Callers that
/// must return promptly on cancellation race this promise with their signal.
///
/// Resolves with the stored OAuth credential after the operation, or nil
/// when the provider no longer has an OAuth credential.
public func refreshStoredOAuthCredential(
    _ credentials: any CredentialStore,
    _ providerId: String,
    _ oauth: OAuthAuth,
    _ needsRefresh: @escaping @Sendable (OAuthCredential) -> Bool,
    _ signal: AbortSignal
) async throws -> OAuthCredential? {
    let post: Credential?
    let lockWait = AbortController()
    let cancelLockWait: @Sendable () -> Void = { lockWait.abort(signal.reason) }
    let listenerId = signal.addEventListener(cancelLockWait)
    if signal.aborted { cancelLockWait() }
    defer { signal.removeEventListener(listenerId) }
    do {
        post = try await credentials.modify(
            providerId,
            { current in
                signal.removeEventListener(listenerId)
                try signal.throwIfAborted()
                guard case .oauth(let currentOAuth) = current else { return nil } // logged out meanwhile
                if !needsRefresh(currentOAuth) { return nil } // another process/request refreshed
                do {
                    return .oauth(try await oauth.refresh(currentOAuth, AbortSignal.timeout(DEFAULT_OAUTH_REFRESH_TIMEOUT_MS)))
                } catch {
                    throw ModelsError(.oauth, "OAuth refresh failed for \(providerId)", cause: error)
                }
            },
            AuthOperationOptions(signal: lockWait.signal)
        )
    } catch {
        if error is ModelsError { throw error }
        try signal.throwIfAborted()
        throw ModelsError(.auth, "Credential store modify failed for \(providerId)", cause: error)
    }
    if case .oauth(let credential) = post { return credential }
    return nil
}

/// OAuth resolution with double-checked locking: tokens with less than five
/// minutes remaining are refreshed through `refreshStoredOAuthCredential`.
private func resolveStoredOAuth(
    _ credentials: any CredentialStore,
    _ providerId: String,
    _ oauth: OAuthAuth,
    _ stored: OAuthCredential,
    _ signal: AbortSignal,
    _ minOAuthValidityMs: Int?
) async throws -> AuthResult? {
    let minimumValidityMs = max(DEFAULT_OAUTH_MINIMUM_VALIDITY_MS, minOAuthValidityMs ?? 0)
    let expiresSoon: @Sendable (OAuthCredential) -> Bool = { credential in dateNow() + minimumValidityMs >= credential.expires }
    var credential = stored

    if expiresSoon(credential) {
        // Optimistic check said expired; the authoritative check runs under the lock.
        guard let post = try await refreshStoredOAuthCredential(credentials, providerId, oauth, expiresSoon, signal) else {
            return nil // logged out meanwhile
        }
        credential = post
        // The normal five-minute window triggers a refresh but does not impose a
        // provider contract. Explicit callers (such as bearer-token export) do
        // require the requested minimum after the refresh.
        if minOAuthValidityMs != nil && expiresSoon(credential) {
            throw ModelsError(.oauth, "OAuth refresh returned a token that expires too soon for \(providerId)")
        }
    }

    do {
        return AuthResult(auth: try await oauth.toAuth(credential), source: "OAuth")
    } catch {
        throw ModelsError(.oauth, "OAuth auth derivation failed for \(providerId)", cause: error)
    }
}

private func resolveApiKey(
    _ authContext: AuthContext,
    _ apiKey: ApiKeyAuth,
    _ providerId: String,
    _ credential: ApiKeyCredential?,
    _ signal: AbortSignal
) async throws -> AuthResult? {
    do {
        return try await apiKey.resolve(ApiKeyAuthInput(ctx: authContext, credential: credential, signal: signal))
    } catch {
        throw ModelsError(.auth, "API key auth failed for provider \(providerId)", cause: error)
    }
}

private func readCredential(
    _ credentials: any CredentialStore,
    _ providerId: String,
    _ signal: AbortSignal
) async throws -> Credential? {
    do {
        return try await credentials.read(providerId, AuthOperationOptions(signal: signal))
    } catch {
        throw ModelsError(.auth, "Credential store read failed for \(providerId)", cause: error)
    }
}
