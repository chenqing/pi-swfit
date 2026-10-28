import Foundation
import Testing
@testable import PiAI

// Port of the openai-responses case of packages/ai/test/provider-error-body-regression.test.ts.
// Swift: instead of mocking the SDK to throw a fake APIError, a fake fetch answers 403 with the body,
// so the real `OpenAI.APIError` reaches the adapter's catch path.

private let responsesModel = Model(id: "gpt-test", name: "GPT Test", api: "openai-responses", provider: "openai",
                                   baseUrl: "https://api.openai.com/v1", reasoning: false, input: ["text"],
                                   contextWindow: 1000, maxTokens: 100)

private func context() -> TranscriptContext {
    normalizeContext(Context(messages: [.user(UserMessage(content: "hi"))]))
}

@Suite struct OpenAIResponsesProviderErrorBodyRegressionTests {
    @Test func openaiResponsesStatusOnlyKeepsThePrefixAndSurfacesTheBody() async {
        var options = StreamOptions()
        options.apiKey = "test"
        options.maxRetries = 0
        options.fetch = dErrorFetch(status: 403, json: #"{"error":"blocked by gateway WAF"}"#)
        let (_, output) = await dCollect(streamOpenAIResponses(responsesModel, context(), options))

        #expect(output.stopReason == .error)
        #expect(output.errorMessage?.contains("OpenAI API error (403)") == true, "\(output.errorMessage ?? "")")
        #expect(output.errorMessage?.contains("blocked by gateway WAF") == true, "\(output.errorMessage ?? "")")
    }

    // Swift addition: the same path through the Azure adapter.
    @Test func azureOpenAIResponsesKeepsThePrefixAndSurfacesTheBody() async {
        var model = responsesModel
        model.api = "azure-openai-responses"
        model.provider = "azure"
        model.baseUrl = "https://my-resource.openai.azure.com"
        var options = StreamOptions()
        options.apiKey = "test"
        options.maxRetries = 0
        options.env = [:]
        options.fetch = dErrorFetch(status: 403, json: #"{"error":"blocked by gateway WAF"}"#)
        let (_, output) = await dCollect(streamAzureOpenAIResponses(model, context(), options))

        #expect(output.stopReason == .error)
        #expect(output.errorMessage?.contains("Azure OpenAI API error (403)") == true, "\(output.errorMessage ?? "")")
        #expect(output.errorMessage?.contains("blocked by gateway WAF") == true, "\(output.errorMessage ?? "")")
    }
}
