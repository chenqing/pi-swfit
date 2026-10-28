import Foundation

// Port of packages/ai/src/api/anthropic-messages.lazy.ts

/// `lazyApi(() => import("./anthropic-messages.js"))`. Generic `StreamOptions` reach the adapter through
/// `AnthropicOptions(streamOptions:)`, which reads the Anthropic-only fields from `extra`.
public func anthropicMessagesApi() -> ProviderStreams {
    lazyApi {
        ProviderStreams(
            stream: { model, context, options in
                streamAnthropicMessages(model, context, options.map { AnthropicOptions(streamOptions: $0) })
            },
            streamSimple: { model, context, options in
                streamSimpleAnthropicMessages(model, context, options)
            }
        )
    }
}
