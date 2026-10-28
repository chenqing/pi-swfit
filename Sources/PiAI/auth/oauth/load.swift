import Foundation

// Port of packages/ai/src/auth/oauth/load.ts
//
// Upstream loads each flow module through a variable `import()` specifier so bundlers cannot follow the
// import into Node-only flow code. Swift links every flow statically, so each loader returns the flow
// constant directly.
// Not ported: `registerBundledOAuthFlowLoaders` (standalone Bun binaries only), `loadOpenAICodexOAuth`
// (openai-codex.ts is out of scope) and `loadRadiusOAuth` (radius.ts is out of scope).

public let loadAnthropicOAuth: @Sendable () async throws -> OAuthAuth = { anthropicOAuth }

public let loadOpenAIChatGPTOAuth: @Sendable () async throws -> OAuthAuth = { openaiChatGPTOAuth }

public let loadGitHubCopilotOAuth: @Sendable () async throws -> OAuthAuth = { githubCopilotOAuth }

public let loadOpenRouterOAuth: @Sendable () async throws -> OAuthAuth = { openRouterOAuth }

public let loadKimiCodingOAuth: @Sendable () async throws -> OAuthAuth = { kimiCodingOAuth }

public let loadMetaOAuth: @Sendable () async throws -> OAuthAuth = { metaOAuth }

public let loadXaiOAuth: @Sendable () async throws -> OAuthAuth = { xaiOAuth }
