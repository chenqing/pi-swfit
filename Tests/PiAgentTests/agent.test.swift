import Foundation
import PiAI
import PiAgent
import Testing

// Port of packages/agent/test/agent.test.ts

private func createTool(_ name: String) -> AgentTool {
    AgentTool(name: name, label: name, description: "\(name) tool", parameters: emptySchema) { _, _, _, _ in
        textResult(name)
    }
}

private let unusedStreamFunction: StreamFn = { _, _, _ in throw PiError("Unexpected stream call") }

private let okStream: StreamFn = { _, _, _ in respond { done(createAssistantMessage("ok")) } }

/// `getModel("openai", "gpt-4o-mini")` stand-in (the model registry is not part of this target).
private func customModel(_ id: String) -> Model {
    Model(id: id, name: id, api: "openai-responses", provider: "openai", baseUrl: "https://api.openai.com/v1")
}

/// Pushes `start`, then polls the abort signal every 5 ms and ends with an aborted error.
private let abortPollingStream: StreamFn = { _, _, options in
    let stream = createAssistantMessageEventStream()
    Task {
        stream.push(.start(partial: createAssistantMessage("")))
        while options?.signal?.aborted != true { await sleepMs(5) }
        stream.push(.error(reason: .aborted, error: createAssistantMessage("Aborted")))
    }
    return stream
}

private func recordingUserRequests(_ requests: Locked<[[String]]>, _ reply: String = "done") -> StreamFn {
    { _, context, _ in
        requests.append(userStrings(context))
        return respond { done(createAssistantMessage(reply)) }
    }
}

private func systemMessage(_ message: AgentMessage?) -> SystemMessage? { message?.systemMessage }

extension DefaultStreamFnTests {
    @Test("Agent uses the configured default when a legacy caller omits streamFn")
    func agentDefault() async throws {
        try await GlobalStreamFnLock.shared.run {
            let calls = Locked(0)
            setDefaultStreamFn { _, _, _ in
                calls.increment()
                return respond { done(createAssistantMessage("fallback")) }
            }
            defer { setDefaultStreamFn(nil) }
            let agent = try Agent(AgentOptions())
            try await agent.prompt("Hello")
            #expect(calls.current == 1)
        }
    }
}

@Suite("Agent")
struct AgentTests {
    @Test("should create an agent instance with default state")
    func defaultState() async throws {
        let agent = try Agent(AgentOptions(streamFn: unusedStreamFunction))
        let state = await agent.state
        #expect(state.model.id == "unknown")
        #expect(state.thinkingLevel == .off)
        #expect(state.tools.isEmpty)
        #expect(state.messages.isEmpty)
        #expect(state.isStreaming == false)
        #expect(state.streamingMessage == nil)
        #expect(state.pendingToolCalls == [])
        #expect(state.errorMessage == nil)
    }

    @Test("should create an agent instance with custom initial state")
    func customInitialState() async throws {
        let model = customModel("gpt-4o-mini")
        let agent = try Agent(AgentOptions(
            initialState: AgentInitialState(systemPrompt: "You are a helpful assistant.", model: model, thinkingLevel: .low),
            streamFn: unusedStreamFunction
        ))
        let state = await agent.state
        #expect(same(state.messages, [.system(SystemMessage(content: "You are a helpful assistant.", timestamp: 0))]))
        #expect(state.model.id == "gpt-4o-mini")
        #expect(state.thinkingLevel == .low)
    }

    @Test("converts initial prompt and tools into transcript state")
    func initialTranscript() async throws {
        let agent = try Agent(AgentOptions(
            initialState: AgentInitialState(systemPrompt: "You are helpful.", tools: [createTool("echo")]),
            streamFn: unusedStreamFunction
        ))
        let initial = systemMessage(await agent.state.messages.first)
        #expect(initial?.content == .string("You are helpful."))
        #expect(initial?.toolsAdded?.map(\.name) == ["echo"])
    }

    @Test("declares tool loadout changes to the model before the next request")
    func declaresToolChanges() async throws {
        let first = createTool("first")
        let second = createTool("second")
        let requests = Locked<[[String]]>([])
        let agent = try Agent(AgentOptions(
            initialState: AgentInitialState(systemPrompt: "You are helpful.", tools: [first]),
            streamFn: { _, context, _ in
                requests.append(context.messages.flatMap { message -> [String] in
                    guard case .system(let s) = message else { return [] }
                    return ["+" + (s.toolsAdded ?? []).map(\.name).joined(separator: ","),
                            "-" + (s.toolsRemoved ?? []).map(\.name).joined(separator: ",")]
                })
                return respond { done(createAssistantMessage("done")) }
            }
        ))

        try await agent.prompt("one")
        await agent.update { $0.state.tools = [second] }
        try await agent.prompt("two")
        try await agent.prompt("three")

        #expect(requests.current == [
            ["+first", "-"],
            ["+first", "-", "+second", "-first"],
            ["+first", "-", "+second", "-first"],
        ])
        let messages = await agent.state.messages
        let update = messages.compactMap(\.systemMessage).first { $0.toolsRemoved != nil }
        #expect(update?.content == .string(""))
        #expect(update?.sections == nil)
        #expect(update?.toolsAdded.map { $0.map { declarationsEqual($0, Tool(name: "second", description: "second tool", parameters: emptySchema)) } } == [true])
        #expect(update?.toolsRemoved == [ToolReference(name: "first")])
        // Declarations carry no executable part (Swift: `Tool` has no `execute` field by construction).
        #expect(systemMessage(messages.first)?.toolsAdded?.first?.name == "first")
    }

    @Test("merges tool changes into a pending system message")
    func mergesPendingSystemMessage() async throws {
        let systemCounts = Locked<[Int]>([])
        let agent = try Agent(AgentOptions(
            initialState: AgentInitialState(systemPrompt: "You are helpful."),
            streamFn: { _, context, _ in
                systemCounts.append(context.messages.filter { if case .system = $0 { return true }; return false }.count)
                return respond { done(createAssistantMessage("done")) }
            }
        ))
        await agent.update { $0.state.tools = [createTool("echo")] }
        try await agent.prompt([
            .system(SystemMessage(content: "", sections: [(name: "skills", text: "<skills>x</skills>")], timestamp: 1)),
            .user(UserMessage(content: "hi", timestamp: 2)),
        ])
        #expect(systemCounts.current == [2])
        #expect(same(await agent.state.messages[1], .system(SystemMessage(
            content: "",
            sections: [(name: "skills", text: "<skills>x</skills>")],
            toolsAdded: [Tool(name: "echo", description: "echo tool", parameters: emptySchema)],
            timestamp: 1
        ))))
    }

    @Test("rewrites pending tool declarations to match the executable set")
    func rewritesPendingDeclarations() async throws {
        let agent = try Agent(AgentOptions(
            initialState: AgentInitialState(systemPrompt: "You are helpful.", tools: [createTool("first")]),
            streamFn: { _, _, _ in respond { done(createAssistantMessage("done")) } }
        ))
        // The pending message claims to add `second` and remove `first`, but the executable
        // set still has `first` and lacks `second`: the executable set wins.
        try await agent.prompt([
            .system(SystemMessage(
                content: "",
                sections: [(name: "note", text: "<note>x</note>")],
                toolsAdded: [toToolDeclaration(createTool("second").asTool)],
                toolsRemoved: [ToolReference(name: "first")],
                timestamp: 1
            )),
            .user(UserMessage(content: "hi", timestamp: 2)),
        ])
        let messages = await agent.state.messages
        #expect(same(messages[1], .system(SystemMessage(content: "", sections: [(name: "note", text: "<note>x</note>")], timestamp: 1))))
        let current = getCurrentSystemMessage(messages.compactMap { $0.systemMessage.map(Message.system) })
        #expect(current?.toolsAdded?.map(\.name) == ["first"])
    }

    @Test("restores the transcript baseline when reset")
    func resetBaseline() async throws {
        let agent = try Agent(AgentOptions(
            initialState: AgentInitialState(
                systemPrompt: "You are helpful.",
                tools: [createTool("echo")],
                messages: [.user(UserMessage(content: "old", timestamp: 1))]
            ),
            streamFn: unusedStreamFunction
        ))
        try await agent.reset()
        let messages = await agent.state.messages
        #expect(messages.count == 1)
        #expect(systemMessage(messages.first)?.content == .string("You are helpful."))
        #expect(systemMessage(messages.first)?.toolsAdded?.map(\.name) == ["echo"])
    }

    @Test("should subscribe to events")
    func subscribe() async throws {
        let agent = try Agent(AgentOptions(streamFn: unusedStreamFunction))
        let eventCount = Locked(0)
        let unsubscribe = agent.subscribe { _, _ in eventCount.increment() }
        // No initial event on subscribe
        #expect(eventCount.current == 0)
        // State mutators don't emit events
        await agent.update { $0.state.thinkingLevel = .low }
        #expect(eventCount.current == 0)
        #expect(await agent.state.thinkingLevel == .low)
        // Unsubscribe should work
        unsubscribe()
        await agent.update { $0.state.thinkingLevel = .high }
        #expect(eventCount.current == 0)
    }

    @Test("emits full lifecycle events for thrown run failures")
    func thrownRunFailure() async throws {
        let agent = try Agent(AgentOptions(streamFn: { _, _, _ in throw PiError("provider exploded") }))
        let events = Locked<[String]>([])
        agent.subscribe { event, _ in events.append(event.type) }
        try await agent.prompt("hello")
        #expect(events.current == [
            "agent_start", "turn_start", "message_start", "message_end",
            "message_start", "message_end", "turn_end", "agent_end",
        ])
        let state = await agent.state
        let last = state.messages.last?.assistantMessage
        #expect(last?.stopReason == .error)
        #expect(last?.errorMessage == "provider exploded")
        #expect(state.errorMessage == "provider exploded")
    }

    @Test("should await async subscribers before prompt resolves")
    func awaitsSubscribers() async throws {
        let barrier = Deferred()
        let agent = try Agent(AgentOptions(streamFn: okStream))
        let listenerFinished = Locked(false)
        agent.subscribe { event, _ in
            if case .agentEnd = event {
                await barrier.wait()
                listenerFinished.withLock { $0 = true }
            }
        }
        let promptResolved = Locked(false)
        let promptTask = Task {
            try await agent.prompt("hello")
            promptResolved.withLock { $0 = true }
        }
        await sleepMs(10)
        #expect(!promptResolved.current)
        #expect(!listenerFinished.current)
        #expect(await agent.state.isStreaming)

        barrier.resolve()
        try await promptTask.value
        #expect(listenerFinished.current)
        #expect(promptResolved.current)
        #expect(await agent.state.isStreaming == false)
    }

    @Test("waitForIdle should wait for async subscribers")
    func waitForIdleWaitsForSubscribers() async throws {
        let barrier = Deferred()
        let agent = try Agent(AgentOptions(streamFn: okStream))
        agent.subscribe { event, _ in
            if case .messageEnd(.assistant) = event { await barrier.wait() }
        }
        let promptTask = Task { try await agent.prompt("hello") }
        await waitUntilStreaming(agent)
        let idleResolved = Locked(false)
        let idleTask = Task {
            await agent.waitForIdle()
            idleResolved.withLock { $0 = true }
        }
        await sleepMs(10)
        #expect(!idleResolved.current)
        #expect(await agent.state.isStreaming)

        barrier.resolve()
        try await promptTask.value
        await idleTask.value
        #expect(idleResolved.current)
        #expect(await agent.state.isStreaming == false)
    }

    @Test("should pass the active abort signal to subscribers")
    func passesAbortSignal() async throws {
        let received = Locked<AbortSignal?>(nil)
        let agent = try Agent(AgentOptions(streamFn: abortPollingStream))
        agent.subscribe { event, signal in
            if case .agentStart = event { received.withLock { $0 = signal } }
        }
        let promptTask = Task { try await agent.prompt("hello") }
        await sleepMs(10)
        #expect(received.current != nil)
        #expect(received.current?.aborted == false)
        agent.abort()
        try await promptTask.value
        #expect(received.current?.aborted == true)
    }

    @Test("should ignore tool updates after the tool execution settles")
    func ignoresLateUpdates() async throws {
        let delayedUpdate = Locked<AgentToolUpdateCallback?>(nil)
        let events = Locked<[AgentEvent]>([])
        let tool = AgentTool(name: "delayed_tool", label: "Delayed Tool", description: "Captures progress callbacks", parameters: emptySchema) { _, _, _, onUpdate in
            delayedUpdate.withLock { $0 = onUpdate }
            onUpdate?(textResult("running", details: ["status": "running"]))
            return textResult("ok", details: ["status": "done"], terminate: true)
        }
        let agent = try Agent(AgentOptions(
            initialState: AgentInitialState(tools: [tool]),
            streamFn: { _, _, _ in respond { done(createAssistantToolUseMessage([toolCall("call-1", "delayed_tool")])) } }
        ))
        agent.subscribe { event, _ in events.append(event) }

        try await agent.prompt("run tool")
        let countAfterPrompt = events.current.count
        delayedUpdate.current?(textResult("late", details: ["status": "late"]))
        await sleepMs(1)
        #expect(events.current.filter { $0.type == "tool_execution_update" }.count == 1)
        #expect(events.current.count == countAfterPrompt)
    }

    @Test("should ignore a settled parallel tool update while another tool is still running")
    func ignoresSettledParallelUpdate() async throws {
        let slowStarted = Deferred()
        let settledToolEnded = Deferred()
        let releaseSlow = Deferred()
        let settledUpdate = Locked<AgentToolUpdateCallback?>(nil)
        let events = Locked<[AgentEvent]>([])
        let settledTool = AgentTool(name: "settled_tool", label: "Settled Tool", description: "Captures progress callbacks", parameters: emptySchema) { _, _, _, onUpdate in
            settledUpdate.withLock { $0 = onUpdate }
            return textResult("done", details: ["status": "done"], terminate: true)
        }
        let slowTool = AgentTool(name: "slow_tool", label: "Slow Tool", description: "Keeps the agent run active", parameters: emptySchema) { _, _, _, _ in
            slowStarted.resolve()
            await releaseSlow.wait()
            return textResult("done", details: ["status": "done"], terminate: true)
        }
        let agent = try Agent(AgentOptions(
            initialState: AgentInitialState(tools: [settledTool, slowTool]),
            streamFn: { _, _, _ in
                respond { done(createAssistantToolUseMessage([toolCall("call-1", "settled_tool"), toolCall("call-2", "slow_tool")])) }
            }
        ))
        agent.subscribe { event, _ in
            events.append(event)
            if case .toolExecutionEnd("call-1", _, _, _, _) = event { settledToolEnded.resolve() }
        }
        let promptTask = Task { try await agent.prompt("run tools") }
        await slowStarted.wait()
        await settledToolEnded.wait()
        let countBeforeLateUpdate = events.current.count
        settledUpdate.current?(textResult("late", details: ["status": "late"]))
        await sleepMs(1)
        #expect(events.current.count == countBeforeLateUpdate)

        releaseSlow.resolve()
        try await promptTask.value
        #expect(events.current.filter { $0.type == "tool_execution_update" }.isEmpty)
    }

    @Test("should update state with mutators")
    func stateMutators() async throws {
        let agent = try Agent(AgentOptions(streamFn: unusedStreamFunction))
        let newModel = customModel("gemini-2.5-flash")
        await agent.update { $0.state.model = newModel }
        #expect(await agent.state.model.id == "gemini-2.5-flash")
        await agent.update { $0.state.thinkingLevel = .high }
        #expect(await agent.state.thinkingLevel == .high)
        await agent.update { $0.state.tools = [createTool("test")] }
        #expect(await agent.state.tools.map(\.name) == ["test"])
        let messages: [AgentMessage] = [.user(UserMessage(content: "Hello", timestamp: dateNow()))]
        await agent.update { $0.state.messages = messages }
        #expect(same(await agent.state.messages, messages))
        let newMessage = AgentMessage.assistant(createAssistantMessage("Hi"))
        await agent.update { $0.state.messages.append(newMessage) }
        #expect(await agent.state.messages.count == 2)
        #expect(same(await agent.state.messages[1], newMessage))
        await agent.update { $0.state.messages = [] }
        #expect(await agent.state.messages.isEmpty)
    }

    @Test("should support steering message queue")
    func steeringQueue() async throws {
        let agent = try Agent(AgentOptions(streamFn: unusedStreamFunction))
        let message = AgentMessage.user(UserMessage(content: "Steering message", timestamp: dateNow()))
        agent.steer(message)
        // The message is queued but not yet in state.messages
        #expect(!contains(await agent.state.messages, message))
    }

    @Test("should support follow-up message queue")
    func followUpQueue() async throws {
        let agent = try Agent(AgentOptions(streamFn: unusedStreamFunction))
        let message = AgentMessage.user(UserMessage(content: "Follow-up message", timestamp: dateNow()))
        agent.followUp(message)
        #expect(!contains(await agent.state.messages, message))
    }

    @Test("should handle abort controller")
    func abortWhenIdle() throws {
        let agent = try Agent(AgentOptions(streamFn: unusedStreamFunction))
        // Should not throw even if nothing is running
        agent.abort()
    }

    @Test("should reject reset while processing without corrupting the transcript")
    func rejectResetWhileProcessing() async throws {
        let streamStarted = Deferred()
        let releaseResponse = Deferred()
        let agent = try Agent(AgentOptions(streamFn: { _, _, _ in
            let stream = createAssistantMessageEventStream()
            Task {
                stream.push(.start(partial: createAssistantMessage("")))
                streamStarted.resolve()
                await releaseResponse.wait()
                stream.push(done(createAssistantMessage("Done")))
            }
            return stream
        }))
        let promptTask = Task { try await agent.prompt("Hello") }
        await streamStarted.wait()
        await sleepMs(5)

        #expect(await agent.state.isStreaming)
        #expect(await agent.state.messages.map(\.role) == ["user"])
        await #expect(throws: PiError("Agent is already processing. Wait for completion before resetting.")) {
            try await agent.reset()
        }
        #expect(await agent.state.isStreaming)
        #expect(await agent.state.messages.map(\.role) == ["user"])

        releaseResponse.resolve()
        try await promptTask.value
        #expect(await agent.state.isStreaming == false)
        #expect(await agent.state.messages.map(\.role) == ["user", "assistant"])
    }

    @Test("should throw when prompt() called while streaming")
    func promptWhileStreaming() async throws {
        let agent = try Agent(AgentOptions(streamFn: abortPollingStream))
        let firstPrompt = Task { try await agent.prompt("First message") }
        await sleepMs(10)
        #expect(await agent.state.isStreaming)
        await #expect(throws: PiError("Agent is already processing a prompt. Use steer() or followUp() to queue messages, or wait for completion.")) {
            try await agent.prompt("Second message")
        }
        agent.abort()
        _ = try? await firstPrompt.value
    }

    @Test("should throw when continue() called while streaming")
    func continueWhileStreaming() async throws {
        let agent = try Agent(AgentOptions(streamFn: abortPollingStream))
        let firstPrompt = Task { try await agent.prompt("First message") }
        await sleepMs(10)
        #expect(await agent.state.isStreaming)
        await #expect(throws: PiError("Agent is already processing. Wait for completion before continuing.")) {
            try await agent.continue()
        }
        agent.abort()
        _ = try? await firstPrompt.value
    }

    @Test("continue() should process queued follow-up messages after an assistant turn")
    func continueProcessesFollowUp() async throws {
        let agent = try Agent(AgentOptions(streamFn: { _, _, _ in respond { done(createAssistantMessage("Processed")) } }))
        let initial: [AgentMessage] = [
            .user(UserMessage(content: .blocks([.text(TextContent(text: "Initial"))]), timestamp: dateNow() - 10)),
            .assistant(createAssistantMessage("Initial response")),
        ]
        await agent.update { $0.state.messages = initial }
        agent.followUp(.user(UserMessage(content: .blocks([.text(TextContent(text: "Queued follow-up"))]), timestamp: dateNow())))

        try await agent.continue()

        let messages = await agent.state.messages
        let hasQueuedFollowUp = messages.contains { message in
            guard case .user(let user) = message else { return false }
            switch user.content {
            case .string(let value): return value == "Queued follow-up"
            case .blocks(let blocks): return blocks.contains(.text(TextContent(text: "Queued follow-up")))
            }
        }
        #expect(hasQueuedFollowUp)
        #expect(messages.last?.role == "assistant")
    }

    @Test("continue() keeps steering semantics for assistant-tail fallback",
          arguments: [(QueueMode.oneAtATime, 2), (QueueMode.all, 1)])
    func continueSteeringSemantics(mode: QueueMode, expectedRequests: Int) async throws {
        let requests = Locked<[[String]]>([])
        let agent = try Agent(AgentOptions(streamFn: recordingUserRequests(requests, "Processed"), steeringMode: mode))
        await agent.update { $0.state.messages = [createUserMessage("Initial"), .assistant(createAssistantMessage("Initial response"))] }
        agent.steer(createUserMessage("Steering 1"))
        agent.steer(createUserMessage("Steering 2"))

        try await agent.continue()

        let r = requests.current
        #expect(r.count == expectedRequests)
        #expect(r.first?.contains("Steering 1") == true)
        if mode == .oneAtATime {
            #expect(r.first?.contains("Steering 2") == false)
            #expect(r.count > 1 && r[1].contains("Steering 2"))
        } else {
            #expect(r.first?.contains("Steering 2") == true)
        }
    }

    @Test("keeps legacy prepareNextTurn signal callback behavior")
    func legacyPrepareNextTurn() async throws {
        let requestCount = Locked(0)
        let sawAbortSignal = Locked(false)
        let tool = AgentTool(name: "noop", label: "Noop", description: "Noop tool", parameters: emptySchema) { _, _, _, _ in textResult("ok") }
        let agent = try Agent(AgentOptions(
            initialState: AgentInitialState(tools: [tool]),
            streamFn: { _, _, _ in
                let n = requestCount.increment()
                return respond {
                    n == 1 ? done(createAssistantToolUseMessage([toolCall("tool-1", "noop")])) : done(createAssistantMessage("done"))
                }
            },
            prepareNextTurn: { signal in
                sawAbortSignal.withLock { $0 = signal != nil }
                return nil
            }
        ))
        try await agent.prompt("start")
        #expect(requestCount.current == 2)
        #expect(sawAbortSignal.current)
    }

    @Test("forwards finishTurn through AgentOptions with the active abort signal")
    func forwardsFinishTurn() async throws {
        let requestCount = Locked(0)
        let sawAbortSignal = Locked(false)
        let roles = Locked<[String]>([])
        let tool = AgentTool(name: "noop", label: "Noop", description: "Noop tool", parameters: emptySchema) { _, _, _, _ in textResult("tool complete") }
        let agent = try Agent(AgentOptions(
            initialState: AgentInitialState(tools: [tool]),
            streamFn: { _, _, _ in
                let n = requestCount.increment()
                return respond {
                    n == 1 ? done(createAssistantToolUseMessage([toolCall("tool-1", "noop")])) : done(createAssistantMessage("should not run"))
                }
            },
            finishTurn: { turn, signal in
                sawAbortSignal.withLock { $0 = signal != nil }
                roles.withLock { $0 = turn.context.messages.map(\.role) }
                return .end
            }
        ))
        try await agent.prompt("start")
        #expect(requestCount.current == 1)
        #expect(sawAbortSignal.current)
        #expect(roles.current == ["system", "user", "assistant", "toolResult"])
    }

    @Test("rejects a queued continuation from empty/system-only context without draining queues",
          arguments: [[AgentMessage](), [AgentMessage.system(SystemMessage(content: "system only", timestamp: 1))]])
    func rejectsEmptyContinuation(messages: [AgentMessage]) async throws {
        let agent = try Agent(AgentOptions(initialState: AgentInitialState(messages: messages), streamFn: unusedStreamFunction))
        let steering = createUserMessage("steering")
        let followUp = createUserMessage("follow-up")
        agent.steer(steering)
        agent.followUp(followUp)

        await #expect(throws: PiError("No messages to continue from")) { try await agent.continue() }
        #expect(same(agent.peekQueuedMessages(), [steering]))
        agent.clearSteeringQueue()
        #expect(same(agent.peekQueuedMessages(), [followUp]))
    }

    @Test("defers follow-up input on the first continuation request from a user/toolResult tail",
          arguments: [
            [createUserMessage("existing user")],
            [
                createUserMessage("existing user"),
                AgentMessage.assistant(createAssistantToolUseMessage([toolCall("call-1", "noop")])),
                AgentMessage.toolResult(ToolResultMessage(toolCallId: "call-1", toolName: "noop", content: [.text(TextContent(text: "done"))], isError: false, timestamp: 1)),
            ],
          ])
    func defersFollowUp(messages: [AgentMessage]) async throws {
        let requests = Locked<[[String]]>([])
        let agent = try Agent(AgentOptions(initialState: AgentInitialState(messages: messages), streamFn: recordingUserRequests(requests)))
        agent.followUp(createUserMessage("follow-up"))
        try await agent.continue()
        let r = requests.current
        #expect(r.count == 2)
        #expect(r.first?.contains("follow-up") == false)
        #expect(r.count > 1 && r[1].contains("follow-up"))
    }

    @Test("polls steering at continuation startup", arguments: [(QueueMode.oneAtATime, 2), (QueueMode.all, 1)])
    func pollsSteeringAtStartup(mode: QueueMode, expectedRequests: Int) async throws {
        let requests = Locked<[[String]]>([])
        let agent = try Agent(AgentOptions(
            initialState: AgentInitialState(messages: [createUserMessage("existing")]),
            streamFn: recordingUserRequests(requests),
            steeringMode: mode
        ))
        agent.steer(createUserMessage("first"))
        agent.steer(createUserMessage("second"))
        try await agent.continue()
        let r = requests.current
        #expect(r.count == expectedRequests)
        #expect(r.first?.contains("first") == true)
        if mode == .oneAtATime {
            #expect(r.first?.contains("second") == false)
            #expect(r.count > 1 && r[1].contains("second"))
        } else {
            #expect(r.first?.contains("second") == true)
        }
    }

    @Test("keeps steering ahead of follow-up from a non-assistant continuation tail")
    func steeringAheadOfFollowUp() async throws {
        let requests = Locked<[[String]]>([])
        let agent = try Agent(AgentOptions(
            initialState: AgentInitialState(messages: [createUserMessage("existing")]),
            streamFn: recordingUserRequests(requests)
        ))
        agent.steer(createUserMessage("steering"))
        agent.followUp(createUserMessage("follow-up"))
        try await agent.continue()
        let r = requests.current
        #expect(r.count == 2)
        #expect(r.first?.contains("steering") == true)
        #expect(r.first?.contains("follow-up") == false)
        #expect(r.count > 1 && r[1].contains("follow-up"))
    }

    @Test("keeps queues on an error/aborted response even when finishTurn requests continuation",
          arguments: [StopReason.error, StopReason.aborted])
    func keepsQueuesOnErrorResponse(stopReason: StopReason) async throws {
        let queuedDuringResponse = createUserMessage("steering")
        let followUp = createUserMessage("follow-up")
        let agent = try Agent(AgentOptions(
            streamFn: { _, _, _ in
                respond {
                    var error = createAssistantMessage(stopReason.rawValue)
                    error.stopReason = stopReason
                    error.errorMessage = stopReason.rawValue
                    return .error(reason: stopReason, error: error)
                }
            },
            finishTurn: { _, _ in .continue }
        ))
        agent.followUp(followUp)
        agent.subscribe { event, _ in
            if case .messageEnd(.assistant) = event { agent.steer(queuedDuringResponse) }
        }
        try await agent.prompt("start")
        #expect(same(agent.peekQueuedMessages(), [queuedDuringResponse]))
        agent.clearSteeringQueue()
        #expect(same(agent.peekQueuedMessages(), [followUp]))
    }

    @Test("keeps queues when finishTurn ends the run")
    func keepsQueuesOnEnd() async throws {
        let queuedDuringResponse = createUserMessage("steering")
        let followUp = createUserMessage("follow-up")
        let agent = try Agent(AgentOptions(
            streamFn: { _, _, _ in respond { done(createAssistantMessage("done")) } },
            finishTurn: { _, _ in .end }
        ))
        agent.followUp(followUp)
        agent.subscribe { event, _ in
            if case .messageEnd(.assistant) = event { agent.steer(queuedDuringResponse) }
        }
        try await agent.prompt("start")
        #expect(same(agent.peekQueuedMessages(), [queuedDuringResponse]))
        agent.clearSteeringQueue()
        #expect(same(agent.peekQueuedMessages(), [followUp]))
    }

    @Test("previews the next selected queued messages without consuming them")
    func previewQueued() throws {
        let agent = try Agent(AgentOptions(
            streamFn: { _, _, _ in createAssistantMessageEventStream() },
            steeringMode: .oneAtATime,
            followUpMode: .all
        ))
        let first = createUserMessage("first steering")
        let second = createUserMessage("second steering")
        let followUp = createUserMessage("follow-up")
        agent.steer(first)
        agent.steer(second)
        agent.followUp(followUp)
        #expect(same(agent.peekQueuedMessages(), [first]))
        #expect(same(agent.peekQueuedMessages(), [first]))
        agent.clearSteeringQueue()
        #expect(same(agent.peekQueuedMessages(), [followUp]))
    }

    @Test("forwards provider stream event observers through AgentOptions")
    func forwardsProviderStreamEvents() async throws {
        let providerEvents = Locked<[JsonValue]>([])
        let agent = try Agent(AgentOptions(
            streamFn: { model, _, options in
                let stream = createAssistantMessageEventStream()
                Task {
                    await options?.onProviderStreamEvent?(["request_cost": 0.01], model)
                    stream.push(done(createAssistantMessage("ok")))
                }
                return stream
            },
            onProviderStreamEvent: { data, _ in providerEvents.append(data) }
        ))
        try await agent.prompt("hello")
        #expect(providerEvents.current == [["request_cost": 0.01]])
    }

    @Test("forwards sessionId to streamFunction options")
    func forwardsSessionId() async throws {
        let received = Locked<String?>(nil)
        let agent = try Agent(AgentOptions(
            streamFn: { _, _, options in
                received.withLock { $0 = options?.sessionId }
                return respond { done(createAssistantMessage("ok")) }
            },
            sessionId: "session-abc"
        ))
        try await agent.prompt("hello")
        #expect(received.current == "session-abc")

        // Test setter
        await agent.update { $0.sessionId = "session-def" }
        #expect(await agent.sessionId == "session-def")

        try await agent.prompt("hello again")
        #expect(received.current == "session-def")
    }
}
