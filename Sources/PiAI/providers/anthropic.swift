import Foundation

// Port of packages/ai/src/providers/anthropic.ts
// The generated `anthropic.models.ts` catalog is not ported: models come from `models` or the builtin registry.

func anthropicApiKeyAuth() -> ApiKeyAuth {
    ApiKeyAuth(
        name: "Anthropic API key",
        login: { interaction in
            try interaction.signal.throwIfAborted()
            let key = try await interaction.prompt(AuthPrompt(.secret(message: "Enter Anthropic API key")))
            try interaction.signal.throwIfAborted()
            return ApiKeyCredential(key: key)
        },
        resolve: { input in
            let ctx = input.ctx, credential = input.credential, signal = input.signal
            try signal.throwIfAborted()
            if let key = credential?.key, !key.isEmpty {
                return AuthResult(auth: ModelAuth(apiKey: key), env: credential?.env, source: "stored credential")
            }

            let authToken = await ctx.env(ANTHROPIC_AUTH_TOKEN_ENV)
            try signal.throwIfAborted()
            if let authToken, !authToken.isEmpty {
                return AuthResult(
                    auth: ModelAuth(headers: [("Authorization", "Bearer \(authToken)")]),
                    source: ANTHROPIC_AUTH_TOKEN_ENV
                )
            }

            for envVar in [ANTHROPIC_OAUTH_TOKEN_ENV, ANTHROPIC_API_KEY_ENV] {
                let apiKey = await ctx.env(envVar)
                try signal.throwIfAborted()
                if let apiKey, !apiKey.isEmpty { return AuthResult(auth: ModelAuth(apiKey: apiKey), source: envVar) }
            }

            // Workload identity federation: the Anthropic SDK exchanges the identity
            // token for a short-lived access token and refreshes it itself. Last in
            // line so keys and ANTHROPIC_AUTH_TOKEN keep winning, as in the SDK. The
            // ids are provider config rather than auth, so they travel in `env`.
            var federation: ProviderEnv = [:]
            for envVar in [
                ANTHROPIC_FEDERATION_RULE_ID_ENV,
                ANTHROPIC_ORGANIZATION_ID_ENV,
                ANTHROPIC_IDENTITY_TOKEN_FILE_ENV,
            ] {
                let value = await ctx.env(envVar)
                try signal.throwIfAborted()
                guard let value, !value.isEmpty else { return nil }
                federation[envVar] = value
            }
            for envVar in [ANTHROPIC_SERVICE_ACCOUNT_ID_ENV, ANTHROPIC_WORKSPACE_ID_ENV] {
                let value = await ctx.env(envVar)
                try signal.throwIfAborted()
                if let value, !value.isEmpty { federation[envVar] = value }
            }
            return AuthResult(auth: ModelAuth(), env: federation, source: "workload identity federation")
        }
    )
}

public func anthropicProvider(models: [AnyModel]? = nil) -> Provider {
    builtinCreateProvider(CreateProviderOptions(
        id: "anthropic",
        name: "Anthropic",
        baseUrl: "https://api.anthropic.com",
        auth: ProviderAuth(
            apiKey: anthropicApiKeyAuth(),
            oauth: lazyOAuth(
                name: "Anthropic (Claude Pro/Max)",
                isSubscription: true,
                load: loadAnthropicOAuth
            )
        ),
        models: models ?? getAllBuiltinModels("anthropic"),
        api: .single(anthropicMessagesApi())
    ))
}
