import Testing
import PiAI
import PiAgent
@testable import PiChat

@MainActor struct ChatUsageTests {
    @Test func distinguishesAbsentUsageAndCacheInclusiveInput() {
        #expect(ChatUsageSummary(messages: []).lastInput == nil)
        let messages = [
            ChatMessage(role: .user, usage: Usage(input: 999)),
            ChatMessage(role: .assistant, usage: Usage(input: 20, output: 7, cacheRead: 100, cacheWrite: 30)),
            ChatMessage(role: .assistant, usage: Usage(input: 10, output: 8, cacheRead: 150)),
            ChatMessage(role: .assistant)
        ]
        let usage = ChatUsageSummary(messages: messages)
        #expect(usage.reportedRequests == 2)
        #expect(usage.lastInput == 160)
        #expect(usage.input == 310)
        #expect(usage.output == 15)
        #expect(usage.cacheRead == 250)
        #expect(usage.cacheWrite == 30)
    }

    @Test func streamingSnapshotsReplaceUsageInsteadOfDoubleCounting() async throws {
        let model = Model(id: "fixture", name: "Fixture", api: "openai-responses", provider: "test", baseUrl: "https://example.invalid")
        let session = try ChatSession(options: AgentOptions(initialState: AgentInitialState(model: model), streamFn: { _, _, _ in
            let stream = createAssistantMessageEventStream()
            Task {
                var message = AssistantMessage(api: model.api, provider: model.provider, model: model.id)
                message.usage = Usage(input: 20, output: 1)
                stream.push(.start(partial: message))
                message.content = [.text(TextContent(text: "Hello"))]
                message.usage.output = 2
                stream.push(.textDelta(contentIndex: 0, delta: "Hello", partial: message))
                message.usage.output = 3
                stream.push(.done(reason: .stop, message: message))
            }
            return stream
        }))
        await session.send("First")
        #expect(session.usage.reportedRequests == 1)
        #expect(session.usage.input == 20)
        #expect(session.usage.output == 3)
        await session.send("Second")
        #expect(session.usage.reportedRequests == 2)
        #expect(session.usage.input == 40)
        #expect(session.usage.output == 6)
        try await session.reset()
        #expect(session.usage.lastInput == nil)
        #expect(session.usage.reportedRequests == 0)
    }
}
