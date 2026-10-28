import Foundation

// Port of packages/ai/src/api/openai-completions.lazy.ts

public func openAICompletionsApi() -> ProviderStreams {
    lazyApi { ProviderStreams(stream: streamOpenAICompletions, streamSimple: streamSimpleOpenAICompletions) }
}
