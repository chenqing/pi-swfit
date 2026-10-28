import Foundation

// Port of packages/ai/src/api/azure-openai-responses.lazy.ts

public func azureOpenAIResponsesApi() -> ProviderStreams {
    lazyApi { ProviderStreams(stream: streamAzureOpenAIResponses, streamSimple: streamSimpleAzureOpenAIResponses) }
}
