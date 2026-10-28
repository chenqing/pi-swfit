import Foundation

// Port of packages/ai/src/api/google-generative-ai.lazy.ts
//
// Swift: `ProviderStreams.streamSimple` cannot throw, so the synchronous throw of `streamSimpleGoogleGenerativeAI`
// (missing API key, unsupported thinking level) is turned into the stream's setup error event by `lazyStream`,
// exactly where upstream `lazyApi` catches it.

public func googleGenerativeAIApi() -> ProviderStreams {
    lazyApi {
        ProviderStreams(
            stream: { model, context, options in streamGoogleGenerativeAI(model, context, options) },
            streamSimple: { model, context, options in
                lazyStream(model, { try streamSimpleGoogleGenerativeAI(model, context, options) })
            }
        )
    }
}
