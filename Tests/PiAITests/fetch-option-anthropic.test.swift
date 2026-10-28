import Foundation
import Testing
@testable import PiAI

// Port of the anthropic-messages case of packages/ai/test/fetch-option.test.ts
// Swift has no stubbable global `fetch`; the port checks that the custom fetch receives the request.
// Not ported: the OpenAI, Azure, Mistral, Codex, pi-messages, Google and image-generation cases (other adapters).

@Suite("fetch stream option - anthropic-messages")
struct FetchOptionAnthropicTests {
    @Test("passes fetch through streamSimple to the Anthropic SDK")
    func customFetch() async {
        let model = bModel(
            id: "test-model",
            name: "Test Model",
            provider: "test-provider",
            baseUrl: "https://upstream.test/v1",
            reasoning: false,
            contextWindow: 10_000,
            maxTokens: 1_000
        )
        let requests = BRequests()
        var options = SimpleStreamOptions()
        options.apiKey = "test-key"
        options.maxRetries = 0
        options.fetch = bFetch(
            JsonValue.object(["error": ["message": "upstream rejected request"]]).serialized(),
            status: 401,
            headers: [("content-type", "application/json")],
            requests: requests
        )
        _ = await streamSimpleAnthropicMessages(model, normalizeContext(bUserContext("hello")), options).result()
        #expect(requests.count > 0)
        #expect(requests.last?.url.absoluteString.hasPrefix("https://upstream.test/v1") == true)
    }
}
