// Port of packages/ai/test/faux-provider.test.ts
//
// Upstream goes through compat.ts (`registerFauxProvider`, `complete`, `stream`); those wrap the api registry,
// which this group does not own. The tests drive `createFauxCore` directly: `complete` = normalizeContext +
// core.stream + result().

import Foundation
import Testing
@testable import PiAI

private func collectEvents(_ stream: AssistantMessageEventStream) async -> [AssistantMessageEvent] {
    var events: [AssistantMessageEvent] = []
    for await event in stream {
        events.append(event)
    }
    return events
}

private func complete(_ core: FauxCore, _ model: Model, _ context: Context, _ options: StreamOptions? = nil) async -> AssistantMessage {
    await core.stream(model, normalizeContext(context), options).result()
}

private func stream(_ core: FauxCore, _ model: Model, _ context: Context, _ options: StreamOptions? = nil) -> AssistantMessageEventStream {
    core.stream(model, normalizeContext(context), options)
}

private func userMessage(_ content: String, timestamp: Int = dateNow()) -> Message {
    .user(UserMessage(content: .string(content), timestamp: timestamp))
}

private func hiContext() -> Context {
    Context(messages: [userMessage("hi")])
}

private func sessionOptions(_ sessionId: String, _ retention: CacheRetention) -> StreamOptions {
    var options = StreamOptions()
    options.sessionId = sessionId
    options.cacheRetention = retention
    return options
}

private func abortOptions(_ controller: AbortController) -> StreamOptions {
    var options = StreamOptions()
    options.signal = controller.signal
    return options
}

@Suite("faux provider")
struct FauxProviderTests {
    @Test("registers a custom provider and estimates usage")
    func registersAndEstimates() async {
        let registration = createFauxCore()
        registration.setResponses([.message(fauxAssistantMessage("hello world"))])

        let context = Context(systemPrompt: "Be concise.", messages: [userMessage("hi there")])

        let response = await complete(registration, registration.getModel(), context)
        #expect(response.content == [.text(TextContent(text: "hello world"))])
        #expect(response.usage.input > 0)
        #expect(response.usage.output > 0)
        #expect(response.usage.totalTokens == response.usage.input + response.usage.output)
        #expect(registration.state.callCount == 1)
    }

    @Test("supports helper blocks for text, thinking, and tool calls")
    func helperBlocks() async throws {
        let registration = createFauxCore()
        registration.setResponses([
            .message(fauxAssistantMessage([fauxThinking("think"), fauxToolCall("echo", ["text": "hi"]), fauxText("done")], stopReason: .toolUse)),
        ])

        let response = await complete(registration, registration.getModel(), hiContext())

        #expect(response.content.count == 3)
        #expect(response.content[0] == .thinking(ThinkingContent(thinking: "think")))
        let toolCall = try #require(response.content[1].toolCallContent)
        #expect(!toolCall.id.isEmpty)
        #expect(toolCall.name == "echo")
        #expect(toolCall.arguments == ["text": "hi"])
        #expect(response.content[2] == .text(TextContent(text: "done")))
        #expect(response.stopReason == .toolUse)
    }

    @Test("supports multiple models with per-model reasoning and model-aware factories")
    func multipleModels() async throws {
        let registration = createFauxCore(RegisterFauxProviderOptions(models: [
            FauxModelDefinition(id: "faux-fast", name: "Faux Fast", reasoning: false),
            FauxModelDefinition(id: "faux-thinker", name: "Faux Thinker", reasoning: true),
        ]))
        registration.setResponses([
            .factory { _, _, _, model in fauxAssistantMessage("\(model.id):\(model.reasoning)") },
            .factory { _, _, _, model in fauxAssistantMessage("\(model.id):\(model.reasoning)") },
        ])

        #expect(registration.models.map(\.id) == ["faux-fast", "faux-thinker"])
        #expect(registration.getModel().id == registration.models[0].id)
        #expect(registration.getModel("faux-fast")?.reasoning == false)
        #expect(registration.getModel("faux-thinker")?.reasoning == true)

        let fast = await complete(registration, try #require(registration.getModel("faux-fast")), hiContext())
        let thinker = await complete(registration, try #require(registration.getModel("faux-thinker")), hiContext())

        #expect(fast.content == [.text(TextContent(text: "faux-fast:false"))])
        #expect(thinker.content == [.text(TextContent(text: "faux-thinker:true"))])
    }

    @Test("rewrites api, provider, and model on returned messages")
    func rewritesIdentity() async {
        let registration = createFauxCore(RegisterFauxProviderOptions(
            api: "faux:test",
            provider: "faux-provider",
            models: [FauxModelDefinition(id: "faux-model")]
        ))
        registration.setResponses([.message(fauxAssistantMessage("hello"))])

        let response = await complete(registration, registration.getModel(), hiContext())

        #expect(response.api == "faux:test")
        #expect(response.provider == "faux-provider")
        #expect(response.model == "faux-model")
    }

    @Test("consumes queued responses in order and errors when exhausted")
    func queueOrder() async {
        let registration = createFauxCore()
        registration.setResponses([.message(fauxAssistantMessage("first")), .message(fauxAssistantMessage("second"))])

        let context = hiContext()

        let first = await complete(registration, registration.getModel(), context)
        let second = await complete(registration, registration.getModel(), context)
        let exhausted = await complete(registration, registration.getModel(), context)

        #expect(first.content == [.text(TextContent(text: "first"))])
        #expect(second.content == [.text(TextContent(text: "second"))])
        #expect(exhausted.stopReason == .error)
        #expect(exhausted.errorMessage == "No more faux responses queued")
        #expect(registration.getPendingResponseCount() == 0)
        #expect(registration.state.callCount == 3)
    }

    @Test("can replace and append queued responses")
    func replaceAndAppend() async {
        let registration = createFauxCore()
        registration.setResponses([.message(fauxAssistantMessage("first"))])

        let context = hiContext()

        #expect(await complete(registration, registration.getModel(), context).content == [.text(TextContent(text: "first"))])
        #expect(registration.getPendingResponseCount() == 0)

        registration.setResponses([.message(fauxAssistantMessage("second"))])
        #expect(registration.getPendingResponseCount() == 1)
        #expect(await complete(registration, registration.getModel(), context).content == [.text(TextContent(text: "second"))])

        registration.appendResponses([.message(fauxAssistantMessage("third")), .message(fauxAssistantMessage("fourth"))])
        #expect(registration.getPendingResponseCount() == 2)
        #expect(await complete(registration, registration.getModel(), context).content == [.text(TextContent(text: "third"))])
        #expect(await complete(registration, registration.getModel(), context).content == [.text(TextContent(text: "fourth"))])
        #expect(registration.getPendingResponseCount() == 0)
    }

    @Test("supports async response factories")
    func asyncFactories() async {
        let registration = createFauxCore()
        registration.setResponses([
            .factory { context, _, state, _ in
                await Task.yield()
                return fauxAssistantMessage("\(context.messages.count):\(state.callCount)")
            },
        ])

        let response = await complete(registration, registration.getModel(), hiContext())

        #expect(response.content == [.text(TextContent(text: "1:1"))])
    }

    @Test("emits an error when a response factory throws")
    func factoryThrows() async {
        let registration = createFauxCore()
        registration.setResponses([
            .factory { _, _, _, _ in throw PiError("boom") },
        ])

        let events = await collectEvents(stream(registration, registration.getModel(), hiContext()))

        #expect(events.count == 1)
        #expect(events[0].type == "error")
        if case .error(_, let error) = events[0] {
            #expect(error.stopReason == .error)
            #expect(error.errorMessage == "boom")
        }
    }

    @Test("rejects a queued response without a terminal stop reason")
    func pendingStopReason() async {
        let registration = createFauxCore()
        registration.setResponses([.message(fauxAssistantMessage("partial", stopReason: .pending))])

        let events = await collectEvents(stream(registration, registration.getModel(), hiContext()))

        #expect(!events.contains { $0.type == "done" })
        let terminal = events.last
        #expect(terminal?.type == "error")
        if case .error(_, let error)? = terminal {
            #expect(error.stopReason == .error)
            #expect(error.errorMessage == "Faux response ended without a stop reason")
        }
    }

    @Test("estimates prompt and output tokens from serialized context")
    func estimatesTokens() async {
        let registration = createFauxCore()
        registration.setResponses([.message(fauxAssistantMessage("done"))])

        let tool = Tool(
            name: "echo",
            description: "Echo back text",
            parameters: ["type": "object", "properties": ["text": ["type": "string"]], "required": ["text"]]
        )
        let context = Context(
            systemPrompt: "sys",
            messages: [
                .user(UserMessage(
                    content: .blocks([.text(TextContent(text: "hello")), .image(ImageContent(data: "abcd", mimeType: "image/png"))]),
                    timestamp: 1
                )),
                .assistant(fauxAssistantMessage("prior")),
                .toolResult(ToolResultMessage(
                    toolCallId: "tool-1",
                    toolName: "echo",
                    content: [.text(TextContent(text: "tool out"))],
                    isError: false,
                    timestamp: 2
                )),
            ],
            tools: [tool]
        )

        let response = await complete(registration, registration.getModel(), context)
        let promptText = [
            "system:sys",
            "user:hello\n[image:image/png:4]",
            "assistant:prior",
            "toolResult:echo\ntool out",
            "tools:\(JsonValue.array([tool.json]).serialized())",
        ].joined(separator: "\n\n")
        let expectedPromptTokens = Int((Double(promptText.utf16.count) / 4).rounded(.up))
        let expectedOutputTokens = Int((Double("done".utf16.count) / 4).rounded(.up))

        #expect(response.usage.input == expectedPromptTokens)
        #expect(response.usage.output == expectedOutputTokens)
        #expect(response.usage.cacheRead == 0)
        #expect(response.usage.cacheWrite == 0)
        #expect(response.usage.totalTokens == expectedPromptTokens + expectedOutputTokens)
    }

    @Test("does not share cache across sessions or requests without sessionId")
    func cacheIsolation() async {
        let registration = createFauxCore()
        registration.setResponses([
            .message(fauxAssistantMessage("first")),
            .message(fauxAssistantMessage("second")),
            .message(fauxAssistantMessage("third")),
        ])

        var context = Context(messages: [userMessage("hello")])

        let first = await complete(registration, registration.getModel(), context, sessionOptions("session-1", .short))
        #expect(first.usage.cacheWrite > 0)
        context.messages.append(.assistant(first))
        context.messages.append(userMessage("follow up", timestamp: dateNow() + 1))

        let second = await complete(registration, registration.getModel(), context, sessionOptions("session-2", .short))
        #expect(second.usage.cacheRead == 0)
        #expect(second.usage.cacheWrite > 0)

        let third = await complete(registration, registration.getModel(), context)
        #expect(third.usage.cacheRead == 0)
        #expect(third.usage.cacheWrite == 0)
    }

    @Test("simulates prompt caching per sessionId")
    func cachePerSession() async {
        let registration = createFauxCore()
        registration.setResponses([.message(fauxAssistantMessage("first")), .message(fauxAssistantMessage("second"))])

        var context = Context(systemPrompt: "Be concise.", messages: [userMessage("hello")])

        let first = await complete(registration, registration.getModel(), context, sessionOptions("session-1", .short))
        #expect(first.usage.cacheRead == 0)
        #expect(first.usage.cacheWrite > 0)

        context.messages.append(.assistant(first))
        context.messages.append(userMessage("follow up", timestamp: dateNow() + 1))

        let second = await complete(registration, registration.getModel(), context, sessionOptions("session-1", .short))
        #expect(second.usage.cacheRead > 0)
        #expect(second.usage.input + second.usage.cacheRead > second.usage.input)
    }

    @Test("counts cached characters up to the first difference in the joined prompt")
    func cachedCharacters() async {
        let registration = createFauxCore()
        registration.setResponses([.message(fauxAssistantMessage("a")), .message(fauxAssistantMessage("b")), .message(fauxAssistantMessage("c"))])
        let options = sessionOptions("session-1", .short)
        let user = { (content: String) in userMessage(content, timestamp: 1) }

        // Prompt texts: "user:hello world" (16 characters), then 16 + 2 + "user:next" (9) = 27.
        _ = await complete(registration, registration.getModel(), Context(messages: [user("hello world")]), options)
        let extended = await complete(registration, registration.getModel(), Context(messages: [user("hello world"), user("next")]), options)
        #expect(extended.usage.input == 3)
        #expect(extended.usage.cacheRead == 4)
        #expect(extended.usage.cacheWrite == 3)

        // The first message now differs after "user:hello w" (12 characters): "user:hello wide" + 2 + 9 = 26.
        let edited = await complete(registration, registration.getModel(), Context(messages: [user("hello wide"), user("next")]), options)
        #expect(edited.usage.input == 4)
        #expect(edited.usage.cacheRead == 3)
        #expect(edited.usage.cacheWrite == 4)
    }

    @Test("does not simulate caching when cacheRetention is none")
    func noCacheWhenNone() async {
        let registration = createFauxCore()
        registration.setResponses([.message(fauxAssistantMessage("first")), .message(fauxAssistantMessage("second"))])

        var context = Context(messages: [userMessage("hello")])

        _ = await complete(registration, registration.getModel(), context, sessionOptions("session-1", .none))
        context.messages.append(.assistant(fauxAssistantMessage("first")))
        context.messages.append(userMessage("follow up", timestamp: dateNow() + 1))
        let second = await complete(registration, registration.getModel(), context, sessionOptions("session-1", .none))
        #expect(second.usage.cacheRead == 0)
        #expect(second.usage.cacheWrite == 0)
    }

    @Test("streams thinking, text, and partial tool call deltas")
    func streamsDeltas() async throws {
        let registration = createFauxCore()
        registration.setResponses([
            .message(fauxAssistantMessage(
                [
                    fauxThinking("thinking text"),
                    fauxText("answer text"),
                    fauxToolCall("echo", ["text": "hi", "count": 12], id: "tool-1"),
                ],
                stopReason: .toolUse
            )),
        ])

        var events: [String] = []
        var toolCallDeltas: [String] = []
        let s = stream(registration, registration.getModel(), hiContext())
        for await event in s {
            events.append(event.type)
            if case .toolcallDelta(_, let delta, _) = event {
                toolCallDeltas.append(delta)
            }
        }

        #expect(events.contains("thinking_start"))
        #expect(events.contains("thinking_delta"))
        #expect(events.contains("text_start"))
        #expect(events.contains("text_delta"))
        #expect(events.contains("toolcall_start"))
        #expect(events.contains("toolcall_delta"))
        #expect(events.contains("toolcall_end"))
        #expect(toolCallDeltas.count > 1)
        #expect(try parseJsonWithRepair(toolCallDeltas.joined()) == ["text": "hi", "count": 12])
    }

    @Test("streams an exact event order for fixed-size chunks")
    func exactEventOrder() async {
        let registration = createFauxCore(RegisterFauxProviderOptions(tokenSize: .init(min: 1, max: 1)))
        registration.setResponses([
            .message(fauxAssistantMessage([fauxThinking("go"), fauxText("ok"), fauxToolCall("echo", [:], id: "tool-1")], stopReason: .toolUse)),
        ])

        let events = await collectEvents(stream(registration, registration.getModel(), hiContext()))

        #expect(events[0].type == "start")
        if case .start(let partial) = events[0] { #expect(partial.stopReason == .pending) }
        #expect(events.map(\.type) == [
            "start",
            "thinking_start",
            "thinking_delta",
            "thinking_end",
            "text_start",
            "text_delta",
            "text_end",
            "toolcall_start",
            "toolcall_delta",
            "toolcall_end",
            "done",
        ])
    }

    @Test("streams multiple tool calls in one message")
    func multipleToolCalls() async {
        let registration = createFauxCore()
        registration.setResponses([
            .message(fauxAssistantMessage(
                [
                    fauxToolCall("echo", ["text": "one"], id: "tool-1"),
                    fauxToolCall("echo", ["text": "two"], id: "tool-2"),
                ],
                stopReason: .toolUse
            )),
        ])

        let events = await collectEvents(stream(registration, registration.getModel(), hiContext()))

        #expect(events.filter { $0.type == "toolcall_start" }.count == 2)
        #expect(events.filter { $0.type == "toolcall_end" }.count == 2)
    }

    @Test("streams an explicit assistant error message as a terminal error")
    func explicitError() async {
        let registration = createFauxCore(RegisterFauxProviderOptions(tokenSize: .init(min: 2, max: 2)))
        var message = fauxAssistantMessage("partial")
        message.stopReason = .error
        message.errorMessage = "upstream failed"
        registration.setResponses([.message(message)])

        let events = await collectEvents(stream(registration, registration.getModel(), hiContext()))

        #expect(events.map(\.type) == ["start", "text_start", "text_delta", "text_end", "error"])
        let terminal = events[events.count - 1]
        #expect(terminal.type == "error")
        if case .error(let reason, let error) = terminal {
            #expect(reason == .error)
            #expect(error.stopReason == .error)
            #expect(error.errorMessage == "upstream failed")
        }
    }

    @Test("streams an explicit assistant aborted message as a terminal error")
    func explicitAborted() async {
        let registration = createFauxCore(RegisterFauxProviderOptions(tokenSize: .init(min: 2, max: 2)))
        var message = fauxAssistantMessage("partial")
        message.stopReason = .aborted
        message.errorMessage = "Request was aborted"
        registration.setResponses([.message(message)])

        let events = await collectEvents(stream(registration, registration.getModel(), hiContext()))

        #expect(events.map(\.type) == ["start", "text_start", "text_delta", "text_end", "error"])
        let terminal = events[events.count - 1]
        #expect(terminal.type == "error")
        if case .error(let reason, let error) = terminal {
            #expect(reason == .aborted)
            #expect(error.stopReason == .aborted)
            #expect(error.errorMessage == "Request was aborted")
        }
    }

    @Test("supports aborting before the first chunk")
    func abortBeforeFirstChunk() async {
        let registration = createFauxCore(RegisterFauxProviderOptions(tokensPerSecond: 50, tokenSize: .init(min: 3, max: 3)))
        registration.setResponses([.message(fauxAssistantMessage("abcdefghijklmnopqrstuvwxyz"))])

        let controller = AbortController()
        controller.abort()
        let events = await collectEvents(stream(registration, registration.getModel(), hiContext(), abortOptions(controller)))

        #expect(events.count == 1)
        #expect(events[0].type == "error")
        if case .error(let reason, let error) = events[0] {
            #expect(reason == .aborted)
            #expect(error.stopReason == .aborted)
        }
    }

    @Test("supports aborting mid-text stream when paced")
    func abortMidText() async {
        let registration = createFauxCore(RegisterFauxProviderOptions(tokensPerSecond: 100, tokenSize: .init(min: 3, max: 3)))
        registration.setResponses([.message(fauxAssistantMessage("abcdefghijklmnopqrstuvwxyz"))])

        let controller = AbortController()
        var events: [String] = []
        var textDeltaCount = 0
        let s = stream(registration, registration.getModel(), hiContext(), abortOptions(controller))
        for await event in s {
            events.append(event.type)
            if event.type == "text_delta" {
                textDeltaCount += 1
                controller.abort()
            }
        }

        #expect(textDeltaCount == 1)
        #expect(events.contains("text_start"))
        #expect(events.contains("text_delta"))
        #expect(events.contains("error"))
        #expect(!events.contains("text_end"))
    }

    @Test("supports aborting mid-thinking stream when paced")
    func abortMidThinking() async {
        let registration = createFauxCore(RegisterFauxProviderOptions(tokensPerSecond: 100, tokenSize: .init(min: 3, max: 3)))
        var message = fauxAssistantMessage("ignored")
        message.content = [.thinking(ThinkingContent(thinking: "abcdefghijklmnopqrstuvwxyz"))]
        registration.setResponses([.message(message)])

        let controller = AbortController()
        var events: [String] = []
        var thinkingDeltaCount = 0
        let s = stream(registration, registration.getModel(), hiContext(), abortOptions(controller))
        for await event in s {
            events.append(event.type)
            if event.type == "thinking_delta" {
                thinkingDeltaCount += 1
                controller.abort()
            }
        }

        #expect(thinkingDeltaCount == 1)
        #expect(events.contains("thinking_start"))
        #expect(events.contains("thinking_delta"))
        #expect(events.contains("error"))
        #expect(!events.contains("thinking_end"))
    }

    @Test("supports aborting mid-toolcall stream when paced")
    func abortMidToolCall() async {
        let registration = createFauxCore(RegisterFauxProviderOptions(tokensPerSecond: 100, tokenSize: .init(min: 3, max: 3)))
        var message = fauxAssistantMessage("done")
        message.content = [
            .toolCall(ToolCall(id: "tool-1", name: "echo", arguments: ["text": "abcdefghijklmnopqrstuvwxyz", "count": 123456789])),
        ]
        message.stopReason = .toolUse
        registration.setResponses([.message(message)])

        let controller = AbortController()
        var events: [String] = []
        var toolCallDeltaCount = 0
        let s = stream(registration, registration.getModel(), hiContext(), abortOptions(controller))
        for await event in s {
            events.append(event.type)
            if event.type == "toolcall_delta" {
                toolCallDeltaCount += 1
                controller.abort()
            }
        }

        #expect(toolCallDeltaCount == 1)
        #expect(events.contains("toolcall_start"))
        #expect(events.contains("toolcall_delta"))
        #expect(events.contains("error"))
        #expect(!events.contains("toolcall_end"))
    }

    // Swift-only coverage for the deferred path of createFauxCore (exercised upstream through models tests).
    @Test("resolves deferred responses after pending fetches and honours cancellation")
    func deferredResponses() async throws {
        let core = createFauxCore(RegisterFauxProviderOptions(deferred: .init(pendingFetches: 1, pollAfterMs: 5)))
        core.setResponses([.message(fauxAssistantMessage("later")), .message(fauxAssistantMessage("never"))])
        var options = StreamOptions()
        options.deferred = true

        let submitted = await complete(core, core.getModel(), hiContext(), options)
        #expect(submitted.stopReason == .deferred)
        let handle = try #require(submitted.deferred)
        #expect(handle.pollAfterMs == 5)

        let pending = await core.fetchDeferred(core.getModel(), handle).result()
        #expect(pending.stopReason == .deferred)
        let final = await core.fetchDeferred(core.getModel(), handle).result()
        #expect(final.content == [.text(TextContent(text: "later"))])
        #expect(core.state.deferredFetchCount == 2)

        let second = try #require(await complete(core, core.getModel(), hiContext(), options).deferred)
        try await core.cancelDeferred(core.getModel(), second)
        let cancelled = await core.fetchDeferred(core.getModel(), second).result()
        #expect(cancelled.errorMessage == "Faux deferred response was cancelled: \(second.id)")
        #expect(core.state.cancelledDeferred.map(\.id) == [second.id])
    }

    // Not ported: "unregisters the provider" — it exercises the api registry (compat.ts registerFauxProvider /
    // unregisterApiProviders), which is outside this group.
}
