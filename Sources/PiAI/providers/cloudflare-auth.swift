import Foundation

// Port of packages/ai/src/providers/cloudflare-auth.ts

private let CLOUDFLARE_API_KEY = "CLOUDFLARE_API_KEY"
private let CLOUDFLARE_ACCOUNT_ID = "CLOUDFLARE_ACCOUNT_ID"
private let CLOUDFLARE_GATEWAY_ID = "CLOUDFLARE_GATEWAY_ID"

private enum CloudflareAuthKind { case workersAi, aiGateway }

private func resolveValue(
    _ name: String,
    _ ctx: AuthContext,
    _ credential: ApiKeyCredential?,
    _ signal: AbortSignal
) async throws -> String? {
    // Per-field merge: prefer the credential value, fall back to ambient env.
    // A credential carrying only the API key must still pick up the account /
    // gateway id from the environment.
    let fromCredential = credential.flatMap { credential in
        name == CLOUDFLARE_API_KEY ? credential.key : credential.env?[name]
    }
    if let fromCredential { return fromCredential }
    try signal.throwIfAborted()
    let value = await ctx.env(name)
    try signal.throwIfAborted()
    return value
}

private func resolveCloudflareEnv(
    _ kind: CloudflareAuthKind,
    _ ctx: AuthContext,
    _ credential: ApiKeyCredential?,
    _ signal: AbortSignal
) async throws -> (apiKey: String, env: ProviderEnv, source: String)? {
    let apiKey = try await resolveValue(CLOUDFLARE_API_KEY, ctx, credential, signal)
    let accountId = try await resolveValue(CLOUDFLARE_ACCOUNT_ID, ctx, credential, signal)
    let gatewayId = kind == .aiGateway ? try await resolveValue(CLOUDFLARE_GATEWAY_ID, ctx, credential, signal) : nil

    guard let apiKey, !apiKey.isEmpty, let accountId, !accountId.isEmpty else { return nil }
    if kind == .aiGateway && (gatewayId ?? "").isEmpty { return nil }

    var env: ProviderEnv = [CLOUDFLARE_ACCOUNT_ID: accountId]
    if let gatewayId, !gatewayId.isEmpty { env[CLOUDFLARE_GATEWAY_ID] = gatewayId }
    return (apiKey, env, credential != nil ? "stored credential" : CLOUDFLARE_API_KEY)
}

public func cloudflareWorkersAIAuth() -> ApiKeyAuth {
    ApiKeyAuth(
        name: "Cloudflare API key",
        login: { interaction in
            let key = try await interaction.prompt(AuthPrompt(.secret(message: "Enter Cloudflare API key")))
            let accountId = try await interaction.prompt(AuthPrompt(.text(message: "Enter Cloudflare account ID")))
            return ApiKeyCredential(key: key, env: [CLOUDFLARE_ACCOUNT_ID: accountId])
        },
        resolve: { input in
            guard let resolved = try await resolveCloudflareEnv(.workersAi, input.ctx, input.credential, input.signal) else { return nil }
            return AuthResult(auth: ModelAuth(apiKey: resolved.apiKey), env: resolved.env, source: resolved.source)
        }
    )
}

public func cloudflareAIGatewayAuth() -> ApiKeyAuth {
    ApiKeyAuth(
        name: "Cloudflare API key",
        login: { interaction in
            let key = try await interaction.prompt(AuthPrompt(.secret(message: "Enter Cloudflare API key")))
            let accountId = try await interaction.prompt(AuthPrompt(.text(message: "Enter Cloudflare account ID")))
            let gatewayId = try await interaction.prompt(AuthPrompt(.text(message: "Enter Cloudflare AI Gateway ID")))
            return ApiKeyCredential(key: key, env: [CLOUDFLARE_ACCOUNT_ID: accountId, CLOUDFLARE_GATEWAY_ID: gatewayId])
        },
        resolve: { input in
            guard let resolved = try await resolveCloudflareEnv(.aiGateway, input.ctx, input.credential, input.signal) else { return nil }
            return AuthResult(
                auth: ModelAuth(headers: [
                    ("cf-aig-authorization", "Bearer \(resolved.apiKey)"),
                    ("Authorization", nil),
                    ("x-api-key", nil),
                ]),
                env: resolved.env,
                source: resolved.source
            )
        }
    )
}
