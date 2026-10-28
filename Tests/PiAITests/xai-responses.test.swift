import Foundation
import Testing
@testable import PiAI

// Port of the OpenAI Responses parts of packages/ai/test/xai-responses.test.ts.
// Not ported here: the built-in catalog checks (Swift has no generated `xai.models` catalog) and the
// Completions User-Agent cases (openai-completions belongs to another group).

private let completedSSE: String = {
    let event: JsonValue = ["type": "response.completed", "sequence_number": 0, "response": [
        "id": "resp_xai_test", "status": "completed", "output": [],
        "usage": ["input_tokens": 1, "output_tokens": 1, "total_tokens": 2, "input_tokens_details": ["cached_tokens": 0]],
    ]]
    return "data: \(event.serialized())\n\ndata: [DONE]\n\n"
}()

private func xaiModel(_ id: String) -> Model { dModel("xai", id) }

private func captureRequest(_ model: Model, _ context: Context, _ configure: (inout StreamOptions) -> Void) async throws -> DCapturedRequest {
    let recorder = DRecorder()
    var options = StreamOptions()
    options.fetch = dSSEFetch(recorder, completedSSE)
    configure(&options)
    let result = await xaiProvider(models: [model]).stream(model, normalizeContext(context), options).result()
    #expect(result.stopReason == .stop, "\(result.errorMessage ?? "")")
    return try #require(recorder.last)
}

private func hello() -> Message { .user(UserMessage(content: "hello", timestamp: 1)) }

@Suite struct XAIResponsesProviderTests {
    @Test func usesResponsesWithBearerAuthAndXAICompatibleRequestFields() async throws {
        let captured = try await captureRequest(
            xaiModel("grok-4.5"),
            Context(systemPrompt: "You are a careful coding assistant.", messages: [hello()])
        ) {
            $0.apiKey = "xai-test-token"
            $0.sessionId = "pi-session-123"
            $0.cacheRetention = .long
            $0.extra["reasoningEffort"] = "medium"
        }

        #expect(captured.url.absoluteString == "https://api.x.ai/v1/responses")
        #expect(captured.header("authorization") == "Bearer xai-test-token")
        #expect(captured.header("user-agent") == getPiUserAgent())
        #expect(captured.header("session_id") == "pi-session-123")
        let body = try #require(captured.body)
        #expect(body["model"] == "grok-4.5")
        #expect(body["store"] == false)
        #expect(body["stream"] == true)
        #expect(body["prompt_cache_key"] == "pi-session-123")
        #expect(body["reasoning"]?["effort"] == "medium")
        #expect(body["include"] == ["reasoning.encrypted_content"])
        #expect(body["prompt_cache_retention"] == nil)
        #expect(body["input"]?.arrayValue?.contains {
            $0["role"] == "developer" && $0["content"] == "You are a careful coding assistant."
        } == true)
    }

    @Test func requestsEncryptedReasoningWithoutAnEffortOverride() async throws {
        let captured = try await captureRequest(xaiModel("grok-4.5"), Context(messages: [hello()])) { $0.apiKey = "xai-test-token" }
        let body = try #require(captured.body)
        #expect(body["model"] == "grok-4.5")
        #expect(body["store"] == false)
        #expect(body["include"] == ["reasoning.encrypted_content"])
        #expect(body["reasoning"] == nil)
    }

    @Test func usesResponsesForGrok47WithXhighEffortAndEncryptedReasoning() async throws {
        let captured = try await captureRequest(
            xaiModel("grok-4.7"),
            Context(systemPrompt: "You are a careful coding assistant.", messages: [hello()])
        ) {
            $0.apiKey = "xai-test-token"
            $0.extra["reasoningEffort"] = "xhigh"
        }
        #expect(captured.url.absoluteString == "https://api.x.ai/v1/responses")
        let body = try #require(captured.body)
        #expect(body["model"] == "grok-4.7")
        #expect(body["store"] == false)
        #expect(body["stream"] == true)
        #expect(body["reasoning"]?["effort"] == "xhigh")
        #expect(body["include"] == ["reasoning.encrypted_content"])
    }

    @Test func usesResponsesForGrok43() async throws {
        let captured = try await captureRequest(xaiModel("grok-4.3"), Context(messages: [hello()])) {
            $0.apiKey = "xai-test-token"
            $0.extra["reasoningEffort"] = "low"
        }
        #expect(captured.url.absoluteString == "https://api.x.ai/v1/responses")
        let body = try #require(captured.body)
        #expect(body["model"] == "grok-4.3")
        #expect(body["store"] == false)
        #expect(body["include"] == ["reasoning.encrypted_content"])
        #expect(body["reasoning"]?["effort"] == "low")
    }

    @Test func usesPisUserAgentByDefaultForResponsesRequests() async throws {
        var openaiModel = xaiModel("grok-4.5")
        openaiModel.provider = "openai"
        openaiModel.baseUrl = "https://api.openai.com/v1"
        let recorder = DRecorder()
        var options = StreamOptions()
        options.apiKey = "test-token"
        options.fetch = dSSEFetch(recorder, completedSSE)
        let result = await streamOpenAIResponses(openaiModel, normalizeContext(Context(messages: [hello()])), options).result()

        #expect(result.stopReason == .stop, "\(result.errorMessage ?? "")")
        #expect(recorder.last?.header("user-agent") == getPiUserAgent())
    }

    @Test func letsExplicitHeadersOverrideTheDefaultResponsesUserAgent() async throws {
        let captured = try await captureRequest(xaiModel("grok-4.5"), Context(messages: [hello()])) {
            $0.apiKey = "xai-test-token"
            $0.headers = [("User-Agent", "custom-agent")]
        }
        #expect(captured.header("user-agent") == "custom-agent")
    }
}
