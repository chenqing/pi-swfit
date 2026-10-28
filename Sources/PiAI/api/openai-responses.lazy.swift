import Foundation

// Port of packages/ai/src/api/openai-responses.lazy.ts

public func openAIResponsesApi() -> ProviderStreams {
    lazyApi { ProviderStreams(stream: streamOpenAIResponses, streamSimple: streamSimpleOpenAIResponses) }
}
