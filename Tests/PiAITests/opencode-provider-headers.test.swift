import Foundation
import Testing
@testable import PiAI

// Port of packages/ai/test/opencode-provider-headers.test.ts

private let model = Model(
    id: "test-model",
    name: "Test model",
    api: "test-api",
    provider: "opencode",
    baseUrl: "https://opencode.ai/zen/v1",
    reasoning: false,
    input: ["text"],
    cost: ModelCost(),
    contextWindow: 1000,
    maxTokens: 100
)
private let context = normalizeContext(Context(messages: [.user(UserMessage(content: "hi", timestamp: 0))]))

private func recordingStreams(_ captured: Locked<StreamOptions?>) -> ProviderStreams {
    ProviderStreams(
        stream: { model, _, options in
            captured.withLock { $0 = options }
            return gRespond(model)
        },
        streamSimple: { model, _, options in
            captured.withLock { $0 = options }
            return gRespond(model)
        }
    )
}

@Suite("OpenCode provider headers")
struct OpenCodeProviderHeadersTests {
    // Regression test for https://github.com/earendil-works/pi/issues/9326
    @Test("maps sessionId for requests even without cache retention", arguments: ["stream", "streamSimple"])
    func mapsSessionId(method: String) {
        let captured = Locked<StreamOptions?>(nil)
        let streams = withOpenCodeSessionHeader(recordingStreams(captured))

        var options = StreamOptions()
        options.sessionId = "conversation-1"
        options.cacheRetention = CacheRetention(rawValue: "none")
        _ = method == "stream" ? streams.stream(model, context, options) : streams.streamSimple(model, context, options)

        #expect(gHeaders(captured.current?.headers) == ["x-opencode-session=conversation-1"])
    }

    @Test("preserves a case-insensitive caller override", arguments: [
        [("X-OpenCode-Session", "caller-value")] as ProviderHeaders,
        [("X-OpenCode-Session", nil)] as ProviderHeaders,
    ])
    func preservesCallerOverride(headers: ProviderHeaders) {
        let captured = Locked<StreamOptions?>(nil)
        let streams = withOpenCodeSessionHeader(recordingStreams(captured))

        var options = StreamOptions()
        options.sessionId = "generated-value"
        options.headers = headers
        _ = streams.streamSimple(model, context, options)

        #expect(gHeaders(captured.current?.headers) == gHeaders(headers))
    }

    @Test("does not fabricate a session header when sessionId is absent")
    func noSessionHeaderWithoutSessionId() {
        let captured = Locked<StreamOptions?>(nil)
        let streams = withOpenCodeSessionHeader(recordingStreams(captured))

        var options = StreamOptions()
        options.headers = [("x-custom", "value")]
        _ = streams.streamSimple(model, context, options)

        #expect(gHeaders(captured.current?.headers) == ["x-custom=value"])
    }
}
