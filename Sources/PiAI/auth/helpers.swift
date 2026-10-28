import Foundation

// Port of packages/ai/src/auth/helpers.ts

/// Standard api-key auth: a stored credential key wins, otherwise the first
/// set env var resolves. Includes a `login` that prompts for the key.
/// Providers with non-standard resolution (provider env, ambient files, IAM)
/// write their own `ApiKeyAuth`.
public func envApiKeyAuth(_ name: String, _ envVars: [String]) -> ApiKeyAuth {
    ApiKeyAuth(
        name: name,
        login: { interaction in
            try interaction.signal.throwIfAborted()
            let key = try await interaction.prompt(AuthPrompt(.secret(message: "Enter \(name)")))
            try interaction.signal.throwIfAborted()
            return ApiKeyCredential(key: key)
        },
        resolve: { input in
            try input.signal.throwIfAborted()
            if let key = input.credential?.key, !key.isEmpty {
                return AuthResult(auth: ModelAuth(apiKey: key), env: input.credential?.env, source: "stored credential")
            }
            for envVar in envVars {
                let value = await input.ctx.env(envVar)
                try input.signal.throwIfAborted()
                if let value, !value.isEmpty { return AuthResult(auth: ModelAuth(apiKey: value), source: envVar) }
            }
            return nil
        }
    )
}

/// Wraps a lazily loaded `OAuthAuth` so provider definitions can advertise
/// OAuth without loading the implementation. The flow loads on first
/// `login`/`refresh`/`toAuth` call; the load is memoized (including a failed load,
/// like the upstream memoized promise).
public func lazyOAuth(
    name: String,
    isSubscription: Bool? = nil,
    loginLabel: String? = nil,
    load: @escaping @Sendable () async throws -> OAuthAuth
) -> OAuthAuth {
    let promise = Locked<Task<OAuthAuth, any Error>?>(nil)
    let loaded: @Sendable () async throws -> OAuthAuth = {
        let task = promise.withLock { p -> Task<OAuthAuth, any Error> in
            if let p { return p }
            let task = Task { try await load() }
            p = task
            return task
        }
        return try await task.value
    }
    return OAuthAuth(
        name: name,
        isSubscription: isSubscription,
        loginLabel: loginLabel,
        login: { interaction, options in try await loaded().login(interaction, options) },
        refresh: { credential, signal in try await loaded().refresh(credential, signal) },
        toAuth: { credential in try await loaded().toAuth(credential) }
    )
}
