import Foundation

// Port of packages/ai/src/env-api-keys.ts

public let ANTHROPIC_AUTH_TOKEN_ENV = "ANTHROPIC_AUTH_TOKEN"
public let ANTHROPIC_OAUTH_TOKEN_ENV = "ANTHROPIC_OAUTH_TOKEN"
public let ANTHROPIC_API_KEY_ENV = "ANTHROPIC_API_KEY"
public let ANTHROPIC_FEDERATION_RULE_ID_ENV = "ANTHROPIC_FEDERATION_RULE_ID"
public let ANTHROPIC_ORGANIZATION_ID_ENV = "ANTHROPIC_ORGANIZATION_ID"
public let ANTHROPIC_SERVICE_ACCOUNT_ID_ENV = "ANTHROPIC_SERVICE_ACCOUNT_ID"
public let ANTHROPIC_IDENTITY_TOKEN_FILE_ENV = "ANTHROPIC_IDENTITY_TOKEN_FILE"
public let ANTHROPIC_WORKSPACE_ID_ENV = "ANTHROPIC_WORKSPACE_ID"

private let cachedVertexAdcCredentialsExists = Locked<Bool?>(nil)

private func existsSync(_ path: String) -> Bool { FileManager.default.fileExists(atPath: path) }

// Not ported: the Node module async-import race (`_existsSync` not loaded yet); FileManager is always available.
private func hasVertexAdcCredentials(_ env: ProviderEnv?) -> Bool {
    if let explicitCredentialsPath = env?["GOOGLE_APPLICATION_CREDENTIALS"], !explicitCredentialsPath.isEmpty {
        return existsSync(explicitCredentialsPath)
    }

    return cachedVertexAdcCredentialsExists.withLock { cached in
        if let cached { return cached }
        let exists: Bool
        // Check GOOGLE_APPLICATION_CREDENTIALS env var first (standard way)
        if let gacPath = getProviderEnvValue("GOOGLE_APPLICATION_CREDENTIALS", env) {
            exists = existsSync(gacPath)
        } else {
            // Fall back to default ADC path (lazy evaluation)
            exists = existsSync(
                FileManager.default.homeDirectoryForCurrentUser
                    .appendingPathComponent(".config").appendingPathComponent("gcloud")
                    .appendingPathComponent("application_default_credentials.json").path
            )
        }
        cached = exists
        return exists
    }
}

private func getApiKeyEnvVars(_ provider: String) -> [String]? {
    if provider == "github-copilot" {
        return ["COPILOT_GITHUB_TOKEN"]
    }

    // ANTHROPIC_AUTH_TOKEN participates in env discovery/status, but
    // getEnvApiKey() skips it because requests must pass it as Authorization: Bearer.
    if provider == "anthropic" {
        return [ANTHROPIC_AUTH_TOKEN_ENV, ANTHROPIC_OAUTH_TOKEN_ENV, ANTHROPIC_API_KEY_ENV]
    }

    let envMap: [String: String] = [
        "ant-ling": "ANT_LING_API_KEY",
        "qwen-token-plan": "QWEN_TOKEN_PLAN_API_KEY",
        "qwen-token-plan-cn": "QWEN_TOKEN_PLAN_CN_API_KEY",
        "qwen-token-plan-individual": "QWEN_TOKEN_PLAN_API_KEY",
        "openai": "OPENAI_API_KEY",
        "azure": "AZURE_OPENAI_API_KEY",
        "nvidia": "NVIDIA_API_KEY",
        "deepseek": "DEEPSEEK_API_KEY",
        "google": "GEMINI_API_KEY",
        "google-vertex": "GOOGLE_CLOUD_API_KEY",
        "groq": "GROQ_API_KEY",
        "cerebras": "CEREBRAS_API_KEY",
        "xai": "XAI_API_KEY",
        "typesafe": "TYPESAFE_API_KEY",
        "radius": "RADIUS_API_KEY",
        "openrouter": "OPENROUTER_API_KEY",
        "vercel-ai-gateway": "AI_GATEWAY_API_KEY",
        "zai": "ZAI_API_KEY",
        "zai-coding-cn": "ZAI_CODING_CN_API_KEY",
        "mistral": "MISTRAL_API_KEY",
        "minimax": "MINIMAX_API_KEY",
        "minimax-cn": "MINIMAX_CN_API_KEY",
        "moonshotai": "MOONSHOT_API_KEY",
        "moonshotai-cn": "MOONSHOT_API_KEY",
        "huggingface": "HF_TOKEN",
        "fireworks": "FIREWORKS_API_KEY",
        "together": "TOGETHER_API_KEY",
        "baseten": "BASETEN_API_KEY",
        "opencode": "OPENCODE_API_KEY",
        "opencode-go": "OPENCODE_API_KEY",
        "kimi-coding": "KIMI_API_KEY",
        "meta": "META_API_KEY",
        "cloudflare-workers-ai": "CLOUDFLARE_API_KEY",
        "cloudflare-ai-gateway": "CLOUDFLARE_API_KEY",
        "xiaomi": "XIAOMI_API_KEY",
        "xiaomi-token-plan-cn": "XIAOMI_TOKEN_PLAN_CN_API_KEY",
        "xiaomi-token-plan-ams": "XIAOMI_TOKEN_PLAN_AMS_API_KEY",
        "xiaomi-token-plan-sgp": "XIAOMI_TOKEN_PLAN_SGP_API_KEY",
    ]

    return envMap[provider].map { [$0] }
}

/// Find configured environment variables that can provide an API key for a provider.
///
/// This only reports actual API key variables. It intentionally excludes ambient
/// credential sources such as AWS profiles, AWS IAM credentials, and Google
/// Application Default Credentials.
public func findEnvKeys(_ provider: String, _ env: ProviderEnv? = nil) -> [String]? {
    guard let envVars = getApiKeyEnvVars(provider) else { return nil }

    let found = envVars.filter { getProviderEnvValue($0, env) != nil }
    return found.isEmpty ? nil : found
}

/// Get API key for provider from known environment variables, e.g. OPENAI_API_KEY.
///
/// Will not return API keys for providers that require OAuth tokens.
public func getEnvApiKey(_ provider: String, _ env: ProviderEnv? = nil) -> String? {
    if let envKeys = findEnvKeys(provider, env), !envKeys.isEmpty {
        let apiKeyEnv = provider == "anthropic" ? envKeys.first { $0 != ANTHROPIC_AUTH_TOKEN_ENV } : envKeys[0]
        if let apiKeyEnv { return getProviderEnvValue(apiKeyEnv, env) }
    }

    // Vertex AI supports either an explicit API key or Application Default Credentials.
    // Auth is configured via `gcloud auth application-default login`.
    if provider == "google-vertex" {
        let hasCredentials = hasVertexAdcCredentials(env)
        let hasProject = getProviderEnvValue("GOOGLE_CLOUD_PROJECT", env) != nil || getProviderEnvValue("GCLOUD_PROJECT", env) != nil
        let hasLocation = getProviderEnvValue("GOOGLE_CLOUD_LOCATION", env) != nil

        if hasCredentials && hasProject && hasLocation {
            return "<authenticated>"
        }
    }

    if provider == "amazon-bedrock" {
        // Amazon Bedrock supports multiple credential sources:
        // 1. AWS_PROFILE - named profile from ~/.aws/credentials
        // 2. AWS_ACCESS_KEY_ID + AWS_SECRET_ACCESS_KEY - standard IAM keys
        // 3. AWS_BEARER_TOKEN_BEDROCK - Bedrock bearer token
        // 4. AWS_CONTAINER_CREDENTIALS_RELATIVE_URI - ECS task roles
        // 5. AWS_CONTAINER_CREDENTIALS_FULL_URI - ECS task roles (full URI)
        // 6. AWS_WEB_IDENTITY_TOKEN_FILE - IRSA (IAM Roles for Service Accounts)
        if getProviderEnvValue("AWS_PROFILE", env) != nil
            || (getProviderEnvValue("AWS_ACCESS_KEY_ID", env) != nil && getProviderEnvValue("AWS_SECRET_ACCESS_KEY", env) != nil)
            || getProviderEnvValue("AWS_BEARER_TOKEN_BEDROCK", env) != nil
            || getProviderEnvValue("AWS_CONTAINER_CREDENTIALS_RELATIVE_URI", env) != nil
            || getProviderEnvValue("AWS_CONTAINER_CREDENTIALS_FULL_URI", env) != nil
            || getProviderEnvValue("AWS_WEB_IDENTITY_TOKEN_FILE", env) != nil
        {
            return "<authenticated>"
        }
    }

    return nil
}
