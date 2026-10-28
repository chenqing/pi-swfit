import Foundation
import Testing
@testable import PiAI

// Port of packages/ai/test/github-copilot-anthropic.test.ts
// Swift: upstream mocks `@anthropic-ai/sdk` and inspects the constructor options and `create()` params. Here the real
// SDK runs over a fake `FetchFunction`: `apiKey`/`authToken`/`defaultHeaders` show up as request headers and
// `params.betas` as the `anthropic-beta` header; the other params are read from the JSON request body.

private let copilotSse = [
    "event: message_start\ndata: " + JsonValue.object([
        "type": "message_start",
        "message": ["id": "msg_test", "usage": ["input_tokens": 10, "output_tokens": 0]],
    ]).serialized() + "\n",
    "event: message_delta\ndata: " + JsonValue.object([
        "type": "message_delta",
        "delta": ["stop_reason": "end_turn"],
        "usage": ["output_tokens": 5],
    ]).serialized() + "\n",
].joined(separator: "\n")

/// `COPILOT_STATIC_HEADERS` from scripts/generate-models.ts.
private let copilotStaticHeaders: [(String, String)] = [
    ("User-Agent", "GitHubCopilotChat/0.35.0"),
    ("Editor-Version", "vscode/1.107.0"),
    ("Editor-Plugin-Version", "copilot-chat/0.35.0"),
    ("Copilot-Integration-Id", "vscode-chat"),
]

/// A github-copilot Claude entry as the generated catalog builds it: anthropic-messages API, Copilot base URL and
/// static headers, `forceAdaptiveThinking` (isAnthropicAdaptiveThinkingModel), the Anthropic effort levels
/// (xhigh/max), GITHUB_COPILOT_THINKING_LEVEL_OVERRIDES, and the 1M context window from
/// GITHUB_COPILOT_EXTENDED_CONTEXT_MODELS. `maxTokens` comes from models.dev upstream (any value works here).
private func copilotClaude(
    _ id: String,
    thinkingLevelMap: ThinkingLevelMap,
    compat: JsonObject = ["forceAdaptiveThinking": true]
) -> Model {
    var model = bModel(
        id: id,
        provider: "github-copilot",
        baseUrl: "https://api.individual.githubcopilot.com",
        reasoning: true,
        input: ["text", "image"],
        contextWindow: 1_000_000,
        maxTokens: 64_000,
        headers: copilotStaticHeaders,
        compat: compat
    )
    model.thinkingLevelMap = thinkingLevelMap
    return model
}

// Mirrors the generated catalog entry for github-copilot/claude-opus-4.7 (opus-4.7: xhigh + max; override minimal: low).
private let copilotOpus47 = copilotClaude("claude-opus-4.7", thinkingLevelMap: [.minimal: "low", .xhigh: "xhigh", .max: "max"])
// Mirrors the generated catalog entry for github-copilot/claude-opus-5 (opus-5: xhigh + max; override minimal: low).
private let copilotOpus5 = copilotClaude(
    "claude-opus-5",
    thinkingLevelMap: [.minimal: "low", .xhigh: "xhigh", .max: "max"],
    compat: ["forceAdaptiveThinking": true, "supportsTemperature": false, "supportsMidConvoSystemMessages": true]
)
// Mirrors the generated catalog entry for github-copilot/claude-opus-5.5 (models.dev effort options without
// off/minimal, plus xhigh + max).
private let copilotOpus55 = copilotClaude(
    "claude-opus-5.5",
    thinkingLevelMap: [.off: String?.none, .minimal: String?.none, .xhigh: "xhigh", .max: "max"],
    compat: ["forceAdaptiveThinking": true, "supportsTemperature": false, "supportsMidConvoSystemMessages": true]
)
// Mirrors the generated catalog entry for github-copilot/claude-sonnet-4.6 (sonnet-4.6: max; override minimal: low, max: max).
private let copilotSonnet46 = copilotClaude("claude-sonnet-4.6", thinkingLevelMap: [.minimal: "low", .max: "max"])

private let copilotContext = normalizeContext(Context(
    systemPrompt: "You are a helpful assistant.",
    messages: [.user(UserMessage(content: "Hello"))]
))

/// Runs the stream until its first error event (like the upstream `for await` loop) and returns the captured request.
private func runCopilot(_ model: Model, _ configure: (inout AnthropicOptions) -> Void = { _ in }) async -> BRequests {
    let requests = BRequests()
    var options = AnthropicOptions()
    options.apiKey = "tid_copilot_session_test_token"
    options.fetch = bFetch(copilotSse, requests: requests)
    configure(&options)
    let stream = streamAnthropicMessages(model, copilotContext, options)
    for await event in stream {
        if case .error = event { break }
    }
    return requests
}

@Suite("Copilot Claude via Anthropic Messages")
struct GithubCopilotAnthropicTests {
    @Test("applies Copilot-specific adaptive thinking effort overrides")
    func thinkingEffortOverrides() {
        let opus47 = copilotOpus47
        #expect(opus47.thinkingLevelMap?[.minimal] == "low")
        #expect(opus47.thinkingLevelMap?[.xhigh] == "xhigh")
        #expect(opus47.thinkingLevelMap?[.max] == "max")
        #expect(getSupportedThinkingLevels(opus47).contains(.xhigh))
        #expect(getSupportedThinkingLevels(opus47).contains(.max))

        let opus5 = copilotOpus5
        #expect(opus5.api == "anthropic-messages")
        #expect(opus5.contextWindow == 1_000_000)
        #expect(opus5.thinkingLevelMap?[.minimal] == "low")
        #expect(opus5.thinkingLevelMap?[.xhigh] == "xhigh")
        #expect(opus5.thinkingLevelMap?[.max] == "max")
        #expect(getSupportedThinkingLevels(opus5).contains(.xhigh))
        #expect(getSupportedThinkingLevels(opus5).contains(.max))

        let opus55 = copilotOpus55
        #expect(opus55.api == "anthropic-messages")
        #expect(opus55.contextWindow == 1_000_000)
        #expect(getSupportedThinkingLevels(opus55) == [.low, .medium, .high, .xhigh, .max])

        let sonnet46 = copilotSonnet46
        #expect(sonnet46.thinkingLevelMap?[.minimal] == "low")
        #expect(sonnet46.thinkingLevelMap?[.max] == "max")
        #expect(getSupportedThinkingLevels(sonnet46).contains(.max))
        #expect(!getSupportedThinkingLevels(sonnet46).contains(.xhigh))
    }

    @Test("uses Bearer auth, Copilot headers, and valid Anthropic Messages payload")
    func bearerAuthAndHeaders() async throws {
        let model = copilotSonnet46
        #expect(model.api == "anthropic-messages")

        let requests = await runCopilot(model)

        let request = try #require(requests.last)

        // Auth: apiKey null, authToken for Bearer
        #expect(request.headers.get("x-api-key") == nil)
        #expect(request.headers.get("Authorization") == "Bearer tid_copilot_session_test_token")
        let headers = request.headers

        // Copilot static headers from model.headers
        #expect(headers.get("User-Agent")?.contains("GitHubCopilotChat") == true)
        #expect(headers.get("Copilot-Integration-Id") == "vscode-chat")

        // Dynamic headers
        #expect(headers.get("X-Initiator") == "user")
        #expect(headers.get("Openai-Intent") == "conversation-edits")

        // Payload is valid Anthropic Messages format
        let params = try #require(requests.lastBody)
        #expect((headers.get("anthropic-beta") ?? "").contains("fine-grained-tool-streaming-2025-05-14") == false)
        #expect(params["model"] == "claude-sonnet-4.6")
        #expect(params["stream"] == true)
        #expect(params["max_tokens"]?.doubleValue == Double(model.maxTokens))
        #expect(params["messages"]?.arrayValue != nil)
    }

    @Test("omits interleaved-thinking beta for adaptive-thinking models")
    func omitsInterleavedBeta() async throws {
        let requests = await runCopilot(copilotSonnet46) { $0.interleavedThinking = true }

        #expect(requests.count == 1)
        #expect((requests.last?.headers.get("anthropic-beta") ?? "").contains("interleaved-thinking-2025-05-14") == false)
    }
}
