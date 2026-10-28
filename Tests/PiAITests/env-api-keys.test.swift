import Foundation
import Testing
@testable import PiAI

// Port of packages/ai/test/env-api-keys.test.ts
// The tests mutate the process environment, so they run serialized and restore it afterwards.

private let trackedEnvVars = [
    "COPILOT_GITHUB_TOKEN", "GH_TOKEN", "GITHUB_TOKEN", "ZAI_CODING_CN_API_KEY",
    "ANTHROPIC_AUTH_TOKEN", "ANTHROPIC_OAUTH_TOKEN", "ANTHROPIC_API_KEY",
]

/// Run `body` with a scratch environment, then restore the original values (`afterEach`).
private func withRestoredEnv(_ body: () throws -> Void) rethrows {
    let original = trackedEnvVars.map { name in (name, getenv(name).map { String(cString: $0) }) }
    defer {
        for (name, value) in original {
            if let value { setenv(name, value, 1) } else { unsetenv(name) }
        }
    }
    try body()
}

@Suite("environment API keys", .serialized)
struct EnvApiKeysTests {
    @Test("does not treat generic GitHub tokens as GitHub Copilot credentials")
    func genericGitHubTokens() {
        withRestoredEnv {
            unsetenv("COPILOT_GITHUB_TOKEN")
            setenv("GH_TOKEN", "gh-token", 1)
            setenv("GITHUB_TOKEN", "github-token", 1)

            #expect(findEnvKeys("github-copilot") == nil)
            #expect(getEnvApiKey("github-copilot") == nil)
        }
    }

    @Test("resolves GitHub Copilot credentials from COPILOT_GITHUB_TOKEN")
    func copilotToken() {
        withRestoredEnv {
            setenv("COPILOT_GITHUB_TOKEN", "copilot-token", 1)
            setenv("GH_TOKEN", "gh-token", 1)
            setenv("GITHUB_TOKEN", "github-token", 1)

            #expect(findEnvKeys("github-copilot") == ["COPILOT_GITHUB_TOKEN"])
            #expect(getEnvApiKey("github-copilot") == "copilot-token")
        }
    }

    @Test("resolves ZAI China Coding Plan credentials from ZAI_CODING_CN_API_KEY")
    func zaiCodingCn() {
        withRestoredEnv {
            setenv("ZAI_CODING_CN_API_KEY", "zai-coding-cn-token", 1)

            #expect(findEnvKeys("zai-coding-cn") == ["ZAI_CODING_CN_API_KEY"])
            #expect(getEnvApiKey("zai-coding-cn") == "zai-coding-cn-token")
        }
    }

    @Test("reports ANTHROPIC_AUTH_TOKEN but preserves OAuth token API key lookup")
    func anthropicAuthTokenReported() {
        withRestoredEnv {
            setenv("ANTHROPIC_AUTH_TOKEN", "auth-token", 1)
            setenv("ANTHROPIC_OAUTH_TOKEN", "oauth-token", 1)
            setenv("ANTHROPIC_API_KEY", "api-key", 1)

            #expect(findEnvKeys("anthropic") == ["ANTHROPIC_AUTH_TOKEN", "ANTHROPIC_OAUTH_TOKEN", "ANTHROPIC_API_KEY"])
            #expect(getEnvApiKey("anthropic") == "oauth-token")
        }
    }

    @Test("does not return ANTHROPIC_AUTH_TOKEN as an API key")
    func authTokenIsNotApiKey() {
        withRestoredEnv {
            setenv("ANTHROPIC_AUTH_TOKEN", "auth-token", 1)
            unsetenv("ANTHROPIC_OAUTH_TOKEN")
            unsetenv("ANTHROPIC_API_KEY")

            #expect(findEnvKeys("anthropic") == ["ANTHROPIC_AUTH_TOKEN"])
            #expect(getEnvApiKey("anthropic") == nil)
        }
    }

    @Test("preserves ANTHROPIC_OAUTH_TOKEN as an API key")
    func oauthTokenIsApiKey() {
        withRestoredEnv {
            unsetenv("ANTHROPIC_AUTH_TOKEN")
            setenv("ANTHROPIC_OAUTH_TOKEN", "oauth-token", 1)
            unsetenv("ANTHROPIC_API_KEY")

            #expect(findEnvKeys("anthropic") == ["ANTHROPIC_OAUTH_TOKEN"])
            #expect(getEnvApiKey("anthropic") == "oauth-token")
        }
    }

    @Test("falls back to ANTHROPIC_API_KEY for API key lookup")
    func fallsBackToApiKey() {
        withRestoredEnv {
            unsetenv("ANTHROPIC_AUTH_TOKEN")
            unsetenv("ANTHROPIC_OAUTH_TOKEN")
            setenv("ANTHROPIC_API_KEY", "api-key", 1)

            #expect(getEnvApiKey("anthropic") == "api-key")
        }
    }
}
