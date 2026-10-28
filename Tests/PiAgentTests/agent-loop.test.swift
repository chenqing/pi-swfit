import Foundation
import PiAI
import PiAgent
import Testing

// Port of packages/agent/test/agent-loop.test.ts

private func echoTool(
    name: String = "echo",
    executionMode: ToolExecutionMode? = nil,
    _ body: @escaping @Sendable (String) async throws -> AgentToolResult
) -> AgentTool {
    AgentTool(name: name, label: name, description: "\(name) tool", parameters: valueSchema, executionMode: executionMode) { _, params, _, _ in
        try await body(params["value"]?.stringValue ?? "")
    }
}

private func noopTool() -> AgentTool {
    AgentTool(name: "noop", label: "Noop", description: "Noop tool", parameters: emptySchema) { _, _, _, _ in
        textResult("done", details: nil)
    }
}

private func config(
    _ configure: (inout AgentLoopConfig) -> Void = { _ in }
) -> AgentLoopConfig {
    var config = AgentLoopConfig(model: createModel(), convertToLlm: identityConverter)
    configure(&config)
    return config
}

/// First call answers with `first`, later calls with a plain "done".
private func twoStepStream(_ calls: Locked<Int>, _ first: [AssistantContent], _ firstReason: StopReason = .toolUse) -> StreamFn {
    { _, _, _ in
        let index = calls.increment() - 1
        return respond {
            index == 0 ? done(createAssistantMessage(first, firstReason)) : done(createAssistantMessage([text("done")]))
        }
    }
}

private func roles(_ messages: [AgentMessage]) -> [String] { messages.map(\.role) }

@Suite("default stream function compatibility", .serialized)
struct DefaultStreamFnTests {
    @Test("uses the configured default when a legacy caller omits streamFn")
    func loopDefault() async {
        await GlobalStreamFnLock.shared.run {
            let calls = Locked(0)
            setDefaultStreamFn { _, _, _ in
                calls.increment()
                return respond { done(createAssistantMessage([text("fallback")])) }
            }
            defer { setDefaultStreamFn(nil) }
            let stream = agentLoop([createUserMessage("Hello")], AgentContext(messages: [], tools: []), config(), nil)
            _ = await stream.result()
            #expect(calls.current == 1)
        }
    }
}

@Suite("agentLoop with AgentMessage")
struct AgentLoopTests {
    @Test("should emit events with AgentMessage types")
    func basicEvents() async {
        let stream = agentLoop([createUserMessage("Hello")], AgentContext(messages: [], tools: []), config(), nil) { _, _, _ in
            respond { done(createAssistantMessage([text("Hi there!")])) }
        }
        let events = await collect(stream)
        let messages = await stream.result()
        #expect(messages.count == 2)
        #expect(messages[0].role == "user")
        #expect(messages[1].role == "assistant")
        let types = events.map(\.type)
        for type in ["agent_start", "turn_start", "message_start", "message_end", "turn_end", "agent_end"] {
            #expect(types.contains(type))
        }
    }

    @Test("should build provider context exclusively from transcript messages")
    func transcriptOnly() async {
        let initialSystem = AgentMessage.system(SystemMessage(content: "Transcript prompt", toolsAdded: [], timestamp: 1))
        let first = Locked<AgentMessage?>(nil)
        let stream = agentLoop([initialSystem, createUserMessage("Hello")], AgentContext(messages: [], tools: []), config(), nil) { _, ctx, _ in
            // The provider receives a transcript: no top-level prompt or tool fields.
            first.withLock { $0 = ctx.messages.first.map(AgentMessage.init) }
            return respond { done(createAssistantMessage([text("done")])) }
        }
        _ = await stream.result()
        #expect(first.current.map { same($0, initialSystem) } == true)
    }

    @Test("should handle custom message types via convertToLlm")
    func customMessages() async {
        let notification = AgentMessage.custom(CustomAgentMessage(role: "notification", payload: ["text": "This is a notification"]))
        let converted = Locked<[Message]>([])
        let cfg = config {
            $0.convertToLlm = { messages in
                let result = messages.filter { $0.role != "notification" }.compactMap(\.llmMessage)
                converted.withLock { $0 = result }
                return result
            }
        }
        let stream = agentLoop([createUserMessage("Hello")], AgentContext(messages: [notification], tools: []), cfg, nil) { _, _, _ in
            respond { done(createAssistantMessage([text("Response")])) }
        }
        _ = await collect(stream)
        #expect(converted.current.count == 1)
        #expect(converted.current.first.map { AgentMessage($0).role } == "user")
    }

    @Test("should apply transformContext before convertToLlm")
    func transformBeforeConvert() async {
        let context = AgentContext(messages: [
            createUserMessage("old message 1"), .assistant(createAssistantMessage([text("old response 1")])),
            createUserMessage("old message 2"), .assistant(createAssistantMessage([text("old response 2")])),
        ], tools: [])
        let transformed = Locked(0)
        let converted = Locked(0)
        let cfg = config {
            $0.transformContext = { messages, _ in
                let kept = Array(messages.suffix(2))
                transformed.withLock { $0 = kept.count }
                return kept
            }
            $0.convertToLlm = { messages in
                let result = messages.compactMap(\.llmMessage).filter { if case .system = $0 { return false }; return true }
                converted.withLock { $0 = result.count }
                return result
            }
        }
        let stream = agentLoop([createUserMessage("new message")], context, cfg, nil) { _, _, _ in
            respond { done(createAssistantMessage([text("Response")])) }
        }
        _ = await collect(stream)
        #expect(transformed.current == 2)
        #expect(converted.current == 2)
    }

    @Test("should handle tool calls and results")
    func toolCalls() async {
        let executed = Locked<[String]>([])
        let toolUsage = Usage(input: 1, output: 2, cacheRead: 3, cacheWrite: 4, totalTokens: 10,
                              cost: UsageCost(input: 0.1, output: 0.2, cacheRead: 0.3, cacheWrite: 0.4, total: 1))
        let patched = Usage(input: 5, output: 6, cacheRead: 7, cacheWrite: 8, totalTokens: 26,
                            cost: UsageCost(input: 0.5, output: 0.6, cacheRead: 0.7, cacheWrite: 0.8, total: 2.6))
        let observed = Locked<Usage?>(nil)
        let tool = echoTool { value in
            executed.append(value)
            return AgentToolResult(content: [.text(TextContent(text: "echoed: \(value)"))], details: ["value": .string(value)], usage: toolUsage)
        }
        let cfg = config {
            $0.afterToolCall = { ctx, _ in
                observed.withLock { $0 = ctx.result.usage }
                return AfterToolCallResult(usage: patched)
            }
        }
        let calls = Locked(0)
        let stream = agentLoop([createUserMessage("echo something")], AgentContext(tools: [tool]), cfg, nil,
                               twoStepStream(calls, [toolCall("tool-1", "echo", ["value": "hello"])]))
        let events = await collect(stream)
        #expect(executed.current == ["hello"])
        #expect(events.contains { $0.type == "tool_execution_start" })
        let end = events.first { $0.type == "tool_execution_end" }
        if case .toolExecutionEnd(_, _, _, let isError, _)? = end { #expect(isError == false) } else { Issue.record("no end") }
        #expect(observed.current == toolUsage)
        let messages = await stream.result()
        #expect(messages.compactMap(\.toolResultMessage).first?.usage == patched)
    }

    // #10549
    @Test("records how long execute() took on the tool result, excluding hooks")
    func durationExcludesHooks() async {
        let tool = echoTool { value in
            await sleepMs(30)
            return textResult(value, details: ["value": .string(value)])
        }
        let cfg = config {
            $0.beforeToolCall = { ctx, _ in
                await sleepMs(100)
                return ctx.toolCall.id == "blocked" ? BeforeToolCallResult(block: true, reason: "no") : nil
            }
        }
        let calls = Locked(0)
        let stream = agentLoop([createUserMessage("go")], AgentContext(tools: [tool]), cfg, nil,
                               twoStepStream(calls, [toolCall("ran", "echo", ["value": "a"]), toolCall("blocked", "echo", ["value": "b"])]))
        _ = await collect(stream)
        let results = await stream.result().compactMap(\.toolResultMessage)
        #expect(results.count == 2)
        #expect((results[0].durationMs ?? -1) >= 25)
        #expect((results[0].durationMs ?? 1000) < 100)
        #expect(results[1].isError == true)
        #expect(results[1].durationMs == nil)
    }

    @Test("should not execute tool calls from a length-truncated assistant message")
    func lengthTruncated() async {
        let executed = Locked<[String]>([])
        let tool = echoTool { value in
            executed.append(value)
            return textResult("echoed: \(value)")
        }
        let calls = Locked(0)
        let stream = agentLoop([createUserMessage("echo something")], AgentContext(tools: [tool]), config(), nil,
                               twoStepStream(calls, [toolCall("tool-1", "echo", ["value": "hel"])], .length))
        let events = await collect(stream)
        #expect(executed.current.isEmpty)
        guard case .toolExecutionEnd(_, _, let result, let isError, _)? = events.first(where: { $0.type == "tool_execution_end" }) else {
            Issue.record("missing tool_execution_end"); return
        }
        #expect(isError)
        #expect(firstText(result.content)?.contains("output token limit") == true)
        #expect(calls.current == 2)
        #expect(await stream.result().last?.role == "assistant")
    }

    @Test("should execute mutated beforeToolCall args without revalidation")
    func mutatedArgs() async {
        let executed = Locked<[JsonValue]>([])
        let tool = AgentTool(name: "echo", label: "Echo", description: "Echo tool", parameters: valueSchema) { _, params, _, _ in
            executed.append(params["value"] ?? .null)
            return textResult("echoed")
        }
        let cfg = config {
            $0.beforeToolCall = { ctx, _ in
                ctx.args["value"] = 123
                return nil
            }
        }
        let calls = Locked(0)
        let stream = agentLoop([createUserMessage("echo something")], AgentContext(tools: [tool]), cfg, nil,
                               twoStepStream(calls, [toolCall("tool-1", "echo", ["value": "hello"])]))
        _ = await collect(stream)
        #expect(executed.current == [123])
    }

    @Test("should prepare tool arguments for validation")
    func prepareArguments() async {
        let replaceSchema: JsonValue = [
            "type": "object", "properties": ["oldText": ["type": "string"], "newText": ["type": "string"]],
            "required": ["oldText", "newText"],
        ]
        let schema: JsonValue = ["type": "object", "properties": ["edits": ["type": "array", "items": replaceSchema]], "required": ["edits"]]
        let executed = Locked<[JsonValue]>([])
        let tool = AgentTool(
            name: "edit", label: "Edit", description: "Edit tool", parameters: schema,
            prepareArguments: { args in
                guard let oldText = args["oldText"]?.stringValue, let newText = args["newText"]?.stringValue else { return args }
                let edits = (args["edits"]?.arrayValue ?? []) + [["oldText": .string(oldText), "newText": .string(newText)]]
                return ["edits": .array(edits)]
            }
        ) { _, params, _, _ in
            executed.append(params["edits"] ?? .null)
            return textResult("edited")
        }
        let calls = Locked(0)
        let stream = agentLoop([createUserMessage("edit something")], AgentContext(tools: [tool]), config(), nil,
                               twoStepStream(calls, [toolCall("tool-1", "edit", ["oldText": "before", "newText": "after"])]))
        _ = await collect(stream)
        #expect(executed.current == [[["oldText": "before", "newText": "after"]]])
    }

    @Test("should emit tool_execution_end in completion order but persist tool results in source order")
    func parallelOrdering() async {
        let firstDone = Deferred()
        let firstResolved = Locked(false)
        let parallelObserved = Locked(false)
        let tool = echoTool { value in
            if value == "first" {
                await firstDone.wait()
                firstResolved.withLock { $0 = true }
            }
            if value == "second" && !firstResolved.current { parallelObserved.withLock { $0 = true } }
            return textResult("echoed: \(value)")
        }
        let calls = Locked(0)
        let inner = twoStepStream(calls, [toolCall("tool-1", "echo", ["value": "first"]), toolCall("tool-2", "echo", ["value": "second"])])
        let stream = agentLoop([createUserMessage("echo both")], AgentContext(tools: [tool]), config { $0.toolExecution = .parallel }, nil) { m, c, o in
            if calls.current == 0 { Task { await sleepMs(20); firstDone.resolve() } }
            return try await inner(m, c, o)
        }
        let events = await collect(stream)
        let endIds = events.compactMap { e -> String? in if case .toolExecutionEnd(let id, _, _, _, _) = e { return id }; return nil }
        let resultIds = events.compactMap { e -> String? in if case .messageEnd(.toolResult(let r)) = e { return r.toolCallId }; return nil }
        let turnIds = events.flatMap { e -> [String] in if case .turnEnd(_, let rs) = e { return rs.map(\.toolCallId) }; return [] }
        #expect(parallelObserved.current)
        #expect(endIds == ["tool-2", "tool-1"])
        #expect(resultIds == ["tool-1", "tool-2"])
        #expect(turnIds == ["tool-1", "tool-2"])
    }

    @Test("should inject queued messages after all tool calls complete")
    func steeringAfterTools() async {
        let executed = Locked<[String]>([])
        let tool = echoTool { value in
            executed.append(value)
            return textResult("ok:\(value)")
        }
        let delivered = Locked(false)
        let sawInterrupt = Locked(false)
        let cfg = config {
            $0.toolExecution = .sequential
            $0.getSteeringMessages = {
                if executed.current.count >= 1 && !delivered.current {
                    delivered.withLock { $0 = true }
                    return [createUserMessage("interrupt")]
                }
                return []
            }
        }
        let calls = Locked(0)
        let inner = twoStepStream(calls, [toolCall("tool-1", "echo", ["value": "first"]), toolCall("tool-2", "echo", ["value": "second"])])
        let stream = agentLoop([createUserMessage("start")], AgentContext(tools: [tool]), cfg, nil) { m, ctx, o in
            if calls.current == 1 { sawInterrupt.withLock { $0 = userStrings(ctx).contains("interrupt") } }
            return try await inner(m, ctx, o)
        }
        let events = await collect(stream)
        #expect(executed.current == ["first", "second"])
        let ends = events.compactMap { e -> Bool? in if case .toolExecutionEnd(_, _, _, let isError, _) = e { return isError }; return nil }
        #expect(ends == [false, false])
        let sequence = events.compactMap { e -> String? in
            guard case .messageStart(let message) = e else { return nil }
            if case .toolResult(let r) = message { return "tool:\(r.toolCallId)" }
            return userString(message)
        }
        #expect(sequence.contains("interrupt"))
        if let interrupt = sequence.firstIndex(of: "interrupt") {
            #expect(sequence.firstIndex(of: "tool:tool-1")! < interrupt)
            #expect(sequence.firstIndex(of: "tool:tool-2")! < interrupt)
        }
        #expect(sawInterrupt.current)
    }

    @Test("should force sequential execution when a tool has executionMode=sequential even with default parallel config")
    func forcedSequential() async {
        let firstDone = Deferred()
        let firstResolved = Locked(false)
        let parallelObserved = Locked(false)
        let tool = echoTool(name: "slow", executionMode: .sequential) { value in
            if value == "first" {
                await firstDone.wait()
                firstResolved.withLock { $0 = true }
            }
            if value == "second" && !firstResolved.current { parallelObserved.withLock { $0 = true } }
            return textResult("slow: \(value)")
        }
        let calls = Locked(0)
        let inner = twoStepStream(calls, [toolCall("tool-1", "slow", ["value": "first"]), toolCall("tool-2", "slow", ["value": "second"])])
        let stream = agentLoop([createUserMessage("run both")], AgentContext(tools: [tool]), config(), nil) { m, c, o in
            if calls.current == 0 { Task { await sleepMs(20); firstDone.resolve() } }
            return try await inner(m, c, o)
        }
        let events = await collect(stream)
        #expect(!parallelObserved.current)
        let ids = events.compactMap { e -> String? in if case .messageEnd(.toolResult(let r)) = e { return r.toolCallId }; return nil }
        #expect(ids == ["tool-1", "tool-2"])
    }

    @Test("should force sequential execution when one of multiple tools has executionMode=sequential")
    func mixedSequential() async {
        let order = Locked<[String]>([])
        let slowDone = Deferred()
        let slow = echoTool(name: "slow", executionMode: .sequential) { value in
            order.append("slow:\(value)")
            if value == "a" { await slowDone.wait() }
            return textResult("slow: \(value)")
        }
        let fast = echoTool(name: "fast") { value in
            order.append("fast:\(value)")
            return textResult("fast: \(value)")
        }
        let calls = Locked(0)
        let inner = twoStepStream(calls, [toolCall("tool-1", "slow", ["value": "a"]), toolCall("tool-2", "fast", ["value": "b"])])
        let stream = agentLoop([createUserMessage("run both")], AgentContext(tools: [slow, fast]), config(), nil) { m, c, o in
            if calls.current == 0 { Task { await sleepMs(20); slowDone.resolve() } }
            return try await inner(m, c, o)
        }
        _ = await collect(stream)
        #expect(order.current.first == "slow:a")
        #expect(order.current.contains("fast:b"))
    }

    @Test("should allow parallel execution when all tools have executionMode=parallel")
    func explicitParallel() async {
        let firstDone = Deferred()
        let firstResolved = Locked(false)
        let parallelObserved = Locked(false)
        let tool = echoTool(executionMode: .parallel) { value in
            if value == "first" {
                await firstDone.wait()
                firstResolved.withLock { $0 = true }
            }
            if value == "second" && !firstResolved.current { parallelObserved.withLock { $0 = true } }
            return textResult("echoed: \(value)")
        }
        let calls = Locked(0)
        let inner = twoStepStream(calls, [toolCall("tool-1", "echo", ["value": "first"]), toolCall("tool-2", "echo", ["value": "second"])])
        let stream = agentLoop([createUserMessage("echo both")], AgentContext(tools: [tool]), config(), nil) { m, c, o in
            if calls.current == 0 { Task { await sleepMs(20); firstDone.resolve() } }
            return try await inner(m, c, o)
        }
        _ = await collect(stream)
        #expect(parallelObserved.current)
    }

    @Test("runs finishTurn after tool-result messages and before turn_end")
    func finishTurnOrdering() async throws {
        let tool = echoTool { value in textResult(value, terminate: true) }
        let ordering = Locked<[String]>([])
        let cfg = config {
            $0.finishTurn = { turn, _ in
                ordering.append("finishTurn")
                #expect(turn.toolResults.count == 1)
                #expect(turn.context.messages.last?.role == "toolResult")
                return nil
            }
        }
        _ = try await runAgentLoop([createUserMessage("echo")], AgentContext(tools: [tool]), cfg, { event in
            if case .messageEnd(let m) = event { ordering.append("message_end:\(m.role)") }
            if case .turnEnd = event { ordering.append("turn_end") }
        }, nil) { _, _, _ in
            respond { done(createAssistantMessage([toolCall("tool-1", "echo", ["value": "hello"])], .toolUse)) }
        }
        #expect(Array(ordering.current.suffix(3)) == ["message_end:toolResult", "finishTurn", "turn_end"])
    }

    @Test("runs finishTurn for an error/aborted assistant before turn_end without changing the hard exit",
          arguments: [StopReason.error, StopReason.aborted])
    func finishTurnHardExit(reason: StopReason) async throws {
        let ordering = Locked<[String]>([])
        let providerCalls = Locked(0)
        let steeringPolls = Locked(0)
        let followUpPolls = Locked(0)
        let cfg = config {
            $0.finishTurn = { turn, _ in
                #expect(turn.message.stopReason == reason)
                ordering.append("finishTurn")
                return .continue
            }
            $0.getSteeringMessages = { steeringPolls.increment(); return [] }
            $0.getFollowUpMessages = { followUpPolls.increment(); return [createUserMessage("queued")] }
        }
        _ = try await runAgentLoop([createUserMessage("run")], AgentContext(tools: []), cfg, { event in
            if case .turnEnd = event { ordering.append("turn_end") }
        }, nil) { _, _, _ in
            providerCalls.increment()
            return respond {
                var error = createAssistantMessage([], reason)
                error.errorMessage = reason.rawValue
                return .error(reason: reason, error: error)
            }
        }
        #expect(ordering.current == ["finishTurn", "turn_end"])
        #expect(providerCalls.current == 1)
        #expect(steeringPolls.current == 1)
        #expect(followUpPolls.current == 0)
    }

    @Test("action:end skips queue polling and next-turn preparation")
    func actionEndSkipsPolling() async {
        let providerCalls = Locked(0)
        let steeringPolls = Locked(0)
        let followUpPolls = Locked(0)
        let prepareCalls = Locked(0)
        let cfg = config {
            $0.finishTurn = { _, _ in .end }
            $0.prepareNextTurn = { _ in prepareCalls.increment(); return nil }
            $0.getSteeringMessages = { steeringPolls.increment(); return [] }
            $0.getFollowUpMessages = { followUpPolls.increment(); return [createUserMessage("queued")] }
        }
        let stream = agentLoop([createUserMessage("run")], AgentContext(tools: [noopTool()]), cfg, nil) { _, _, _ in
            providerCalls.increment()
            return respond { done(createAssistantMessage([toolCall("tool-1", "noop")], .toolUse)) }
        }
        _ = await stream.result()
        #expect(providerCalls.current == 1)
        #expect(steeringPolls.current == 1)
        #expect(followUpPolls.current == 0)
        #expect(prepareCalls.current == 0)
    }

    @Test("makes exactly one context-only request when no natural request satisfies continuation")
    func contextOnlyContinuation() async {
        let providerCalls = Locked(0)
        let finishCalls = Locked(0)
        let cfg = config { $0.finishTurn = { _, _ in finishCalls.increment() == 1 ? .continue : nil } }
        let stream = agentLoop([createUserMessage("run")], AgentContext(tools: []), cfg, nil) { _, _, _ in
            let n = providerCalls.increment()
            return respond { done(createAssistantMessage([text("response \(n)")])) }
        }
        _ = await stream.result()
        #expect(providerCalls.current == 2)
        #expect(finishCalls.current == 2)
    }

    @Test("lets a natural tool-result request satisfy continuation")
    func toolResultSatisfiesContinuation() async {
        let providerCalls = Locked(0)
        let finishCalls = Locked(0)
        let cfg = config { $0.finishTurn = { _, _ in finishCalls.increment() == 1 ? .continue : nil } }
        let stream = agentLoop([createUserMessage("run")], AgentContext(tools: [noopTool()]), cfg, nil) { _, _, _ in
            let n = providerCalls.increment()
            return respond {
                n == 1 ? done(createAssistantMessage([toolCall("tool-1", "noop")], .toolUse)) : done(createAssistantMessage([text("done")]))
            }
        }
        _ = await stream.result()
        #expect(providerCalls.current == 2)
        #expect(finishCalls.current == 2)
    }

    @Test("lets a natural steering/follow-up request satisfy continuation", arguments: ["steering", "follow-up"])
    func queueSatisfiesContinuation(queueKind: String) async {
        let providerCalls = Locked(0)
        let finishCalls = Locked(0)
        let steeringPolls = Locked(0)
        let followUpDelivered = Locked(false)
        let secondRequestUsers = Locked<[String]>([])
        let cfg = config {
            $0.finishTurn = { _, _ in finishCalls.increment() == 1 ? .continue : nil }
            $0.getSteeringMessages = {
                let polls = steeringPolls.increment()
                return queueKind == "steering" && polls == 2 ? [createUserMessage(queueKind)] : []
            }
            $0.getFollowUpMessages = {
                if queueKind != "follow-up" || followUpDelivered.current { return [] }
                followUpDelivered.withLock { $0 = true }
                return [createUserMessage(queueKind)]
            }
        }
        let stream = agentLoop([createUserMessage("run")], AgentContext(tools: []), cfg, nil) { _, ctx, _ in
            if providerCalls.increment() == 2 { secondRequestUsers.withLock { $0 += userStrings(ctx) } }
            return respond { done(createAssistantMessage([text("done")])) }
        }
        _ = await stream.result()
        #expect(providerCalls.current == 2)
        #expect(finishCalls.current == 2)
        #expect(secondRequestUsers.current.contains(queueKind))
    }

    @Test("prepares the initial request after pending messages and can replace request state")
    func prepareRequestReplaces() async throws {
        var replacementModel = createModel()
        replacementModel.id = "replacement"
        replacementModel.name = "replacement"
        let canonical = createUserMessage("canonical projection")
        let steering = createUserMessage("steering")
        let completed = Locked<[AgentMessage]>([])
        let steeringDelivered = Locked(false)
        let prepareCalls = Locked(0)
        let model = replacementModel
        let cfg = config {
            $0.getSteeringMessages = {
                if steeringDelivered.current { return [] }
                steeringDelivered.withLock { $0 = true }
                return [steering]
            }
            $0.prepareRequest = { request, _ in
                prepareCalls.increment()
                #expect(contains(completed.current, steering))
                #expect(contains(request.context.messages, steering))
                var context = request.context
                context.messages = [canonical]
                return AgentRequestUpdate(context: context, model: model, thinkingLevel: .high)
            }
        }
        _ = try await runAgentLoop([createUserMessage("prompt")], AgentContext(tools: []), cfg, { event in
            if case .messageEnd(let m) = event { completed.append(m) }
        }, nil) { m, ctx, options in
            #expect(m.id == "replacement")
            #expect(ctx.messages.count == 1 && contains(ctx.messages, canonical))
            #expect(options?.reasoning == .high)
            return respond { done(createAssistantMessage([text("done")])) }
        }
        #expect(prepareCalls.current == 1)
    }

    @Test("does not poll steering after prepareRequest")
    func noSteeringPollAfterPrepareRequest() async {
        let queued = Locked<[AgentMessage]>([])
        let late = createUserMessage("late steering")
        let included = Locked<[Bool]>([])
        let preparations = Locked(0)
        let steeringPolls = Locked(0)
        let cfg = config {
            $0.getSteeringMessages = {
                steeringPolls.increment()
                return queued.withLock { q in defer { q = [] }; return q }
            }
            $0.prepareRequest = { _, _ in
                if preparations.increment() == 1 { queued.append(late) }
                return nil
            }
        }
        let stream = agentLoop([createUserMessage("run")], AgentContext(tools: []), cfg, nil) { _, ctx, _ in
            included.append(contains(ctx.messages, late))
            return respond { done(createAssistantMessage([text("done")])) }
        }
        _ = await stream.result()
        #expect(included.current == [false, true])
        #expect(preparations.current == 2)
        // Startup, post-turn delivery, then the final natural-stop check.
        #expect(steeringPolls.current == 3)
    }

    @Test("should use prepareNextTurn snapshot before continuing")
    func prepareNextTurnSnapshot() async {
        let tool = echoTool { value in textResult("echoed: \(value)") }
        let hasUpdate = Locked(false)
        let prepareCalls = Locked(0)
        let prepared = Locked(false)
        let cfg = config {
            $0.prepareNextTurn = { turn in
                prepareCalls.increment()
                if prepared.current { return nil }
                prepared.withLock { $0 = true }
                return AgentLoopTurnUpdate(
                    context: AgentContext(messages: turn.context.messages, tools: turn.context.tools),
                    messages: [.system(SystemMessage(content: "updated guidance", timestamp: 1))]
                )
            }
        }
        let llmCalls = Locked(0)
        let stream = agentLoop([createUserMessage("echo something")], AgentContext(tools: [tool]), cfg, nil) { _, ctx, _ in
            let n = llmCalls.increment()
            if n == 2 {
                hasUpdate.withLock { $0 = ctx.messages.contains { m in
                    if case .system(let s) = m, case .string("updated guidance") = s.content { return true }
                    return false
                } }
            }
            return respond {
                n == 1 ? done(createAssistantMessage([toolCall("tool-1", "echo", ["value": "hello"])], .toolUse))
                    : done(createAssistantMessage([text("done")]))
            }
        }
        _ = await collect(stream)
        #expect(llmCalls.current == 2)
        #expect(prepareCalls.current == 1)
        #expect(hasUpdate.current)
    }

    @Test("picks up steering queued during prepareNextTurn before the next request")
    func steeringDuringPrepareNextTurn() async {
        let queued = Locked<[AgentMessage]>([])
        let late = createUserMessage("late steering")
        let providerCalls = Locked(0)
        let included = Locked(false)
        let cfg = config {
            $0.prepareNextTurn = { _ in queued.append(late); return nil }
            $0.getSteeringMessages = { queued.withLock { q in defer { q = [] }; return q } }
        }
        let stream = agentLoop([createUserMessage("run")], AgentContext(tools: [noopTool()]), cfg, nil) { _, ctx, _ in
            let n = providerCalls.increment()
            if n == 2 { included.withLock { $0 = contains(ctx.messages, late) } }
            return respond {
                n == 1 ? done(createAssistantMessage([toolCall("tool-1", "noop")], .toolUse)) : done(createAssistantMessage([text("done")]))
            }
        }
        _ = await stream.result()
        #expect(providerCalls.current == 2)
        #expect(included.current)
    }

    @Test("action:end receives finalized turn context and stops before queue polling")
    func actionEndContext() async {
        let executed = Locked<[String]>([])
        let tool = echoTool { value in
            executed.append(value)
            return textResult("echoed: \(value)")
        }
        let steeringPolls = Locked(0)
        let followUpPolls = Locked(0)
        let callbackIds = Locked<[String]>([])
        let callbackRoles = Locked<[String]>([])
        let cfg = config {
            $0.finishTurn = { turn, _ in
                callbackIds.withLock { $0 = turn.toolResults.map(\.toolCallId) }
                callbackRoles.withLock { $0 = roles(turn.context.messages) }
                return .end
            }
            $0.getSteeringMessages = { steeringPolls.increment(); return [] }
            $0.getFollowUpMessages = { followUpPolls.increment(); return [createUserMessage("follow up should stay queued")] }
        }
        let llmCalls = Locked(0)
        let stream = agentLoop([createUserMessage("echo something")], AgentContext(tools: [tool]), cfg, nil) { _, _, _ in
            let n = llmCalls.increment()
            return respond {
                n == 1 ? done(createAssistantMessage([toolCall("tool-1", "echo", ["value": "hello"])], .toolUse))
                    : done(createAssistantMessage([text("should not run")]))
            }
        }
        let events = await collect(stream)
        let messages = await stream.result()
        #expect(llmCalls.current == 1)
        #expect(executed.current == ["hello"])
        #expect(steeringPolls.current == 1)
        #expect(followUpPolls.current == 0)
        #expect(callbackIds.current == ["tool-1"])
        #expect(callbackRoles.current == ["system", "user", "assistant", "toolResult"])
        // The context declares no tools, so the loop announces the loadout with a system message.
        #expect(roles(messages) == ["system", "user", "assistant", "toolResult"])
        #expect(events.map(\.type) == [
            "agent_start", "turn_start",
            "message_start", "message_end", "message_start", "message_end", "message_start", "message_end",
            "tool_execution_start", "tool_execution_end",
            "message_start", "message_end",
            "turn_end", "agent_end",
        ])
    }

    @Test("should stop after a tool batch when every tool result sets terminate=true")
    func terminateBatch() async {
        let tool = echoTool { value in textResult("echoed: \(value)", terminate: true) }
        let llmCalls = Locked(0)
        let stream = agentLoop([createUserMessage("echo something")], AgentContext(tools: [tool]), config(), nil) { _, _, _ in
            llmCalls.increment()
            return respond { done(createAssistantMessage([toolCall("tool-1", "echo", ["value": "hello"])], .toolUse)) }
        }
        let events = await collect(stream)
        #expect(llmCalls.current == 1)
        #expect(roles(await stream.result()) == ["system", "user", "assistant", "toolResult"])
        #expect(events.filter { $0.type == "turn_end" }.count == 1)
    }

    @Test("should stop after a blocked tool call when beforeToolCall sets terminate=true")
    func blockedTerminate() async {
        let executed = Locked(false)
        let tool = echoTool { _ in
            executed.withLock { $0 = true }
            return textResult("should not execute")
        }
        let cfg = config { $0.beforeToolCall = { _, _ in BeforeToolCallResult(block: true, reason: "Blocked by policy", terminate: true) } }
        let llmCalls = Locked(0)
        let stream = agentLoop([createUserMessage("echo something")], AgentContext(tools: [tool]), cfg, nil) { _, _, _ in
            let n = llmCalls.increment()
            return respond {
                n == 1 ? done(createAssistantMessage([toolCall("tool-1", "echo", ["value": "hello"])], .toolUse))
                    : done(createAssistantMessage([text("should not run")]))
            }
        }
        _ = await collect(stream)
        let toolResult = await stream.result().compactMap(\.toolResultMessage).first
        #expect(!executed.current)
        #expect(llmCalls.current == 1)
        #expect(toolResult?.isError == true)
        #expect(toolResult?.content.contains(.text(TextContent(text: "Blocked by policy"))) == true)
    }

    @Test("should continue after a mixed batch with one terminating blocked call")
    func mixedBlockedBatch() async {
        let executed = Locked<[String]>([])
        let tool = echoTool { value in
            executed.append(value)
            return textResult("echoed: \(value)")
        }
        let cfg = config {
            $0.toolExecution = .parallel
            $0.beforeToolCall = { ctx, _ in
                ctx.args["value"]?.stringValue == "first" ? BeforeToolCallResult(block: true, reason: "Blocked first", terminate: true) : nil
            }
        }
        let calls = Locked(0)
        let stream = agentLoop([createUserMessage("echo both")], AgentContext(tools: [tool]), cfg, nil,
                               twoStepStream(calls, [toolCall("tool-1", "echo", ["value": "first"]), toolCall("tool-2", "echo", ["value": "second"])]))
        _ = await collect(stream)
        #expect(executed.current == ["second"])
        #expect(calls.current == 2)
    }

    @Test("should continue after parallel tool calls when not all tool results terminate")
    func partialTerminate() async {
        let tool = echoTool { value in textResult("echoed: \(value)", terminate: value == "first") }
        let calls = Locked(0)
        let stream = agentLoop([createUserMessage("echo both")], AgentContext(tools: [tool]), config { $0.toolExecution = .parallel }, nil,
                               twoStepStream(calls, [toolCall("tool-1", "echo", ["value": "first"]), toolCall("tool-2", "echo", ["value": "second"])]))
        _ = await collect(stream)
        #expect(calls.current == 2)
        #expect(roles(await stream.result()) == ["system", "user", "assistant", "toolResult", "toolResult", "assistant"])
    }

    @Test("should allow afterToolCall to mark a tool batch as terminating")
    func afterToolCallTerminate() async {
        let tool = echoTool { value in textResult("echoed: \(value)") }
        let llmCalls = Locked(0)
        let stream = agentLoop([createUserMessage("echo something")], AgentContext(tools: [tool]),
                               config { $0.afterToolCall = { _, _ in AfterToolCallResult(terminate: true) } }, nil) { _, _, _ in
            llmCalls.increment()
            return respond { done(createAssistantMessage([toolCall("tool-1", "echo", ["value": "hello"])], .toolUse)) }
        }
        _ = await collect(stream)
        #expect(llmCalls.current == 1)
    }
}

@Suite("agentLoopContinue with AgentMessage")
struct AgentLoopContinueTests {
    @Test("should throw when context has no messages")
    func throwsWhenEmpty() {
        #expect(throws: PiError("Cannot continue: no messages in context")) {
            _ = try agentLoopContinue(AgentContext(tools: []), config(), nil) { _, _, _ in throw PiError("Unexpected stream call") }
        }
    }

    @Test("should continue from existing context without emitting user message events")
    func continueWithoutUserEvents() async throws {
        let stream = try agentLoopContinue(AgentContext(messages: [createUserMessage("Hello")], tools: []), config(), nil) { _, _, _ in
            respond { done(createAssistantMessage([text("Response")])) }
        }
        let events = await collect(stream)
        let messages = await stream.result()
        #expect(messages.count == 1)
        #expect(messages.first?.role == "assistant")
        let ends = events.compactMap { e -> AgentMessage? in if case .messageEnd(let m) = e { return m }; return nil }
        #expect(ends.count == 1)
        #expect(ends.first?.role == "assistant")
    }

    @Test("should allow custom message types as last message (caller responsibility)")
    func customLastMessage() async throws {
        let custom = AgentMessage.custom(CustomAgentMessage(role: "custom", payload: ["text": "Hook content"]))
        let cfg = config {
            $0.convertToLlm = { messages in
                messages.compactMap { m -> Message? in
                    if case .custom(let c) = m, c.role == "custom" {
                        return .user(UserMessage(content: .string(c.payload["text"]?.stringValue ?? ""), timestamp: c.timestamp))
                    }
                    return m.llmMessage
                }
            }
        }
        let stream = try agentLoopContinue(AgentContext(messages: [custom], tools: []), cfg, nil) { _, _, _ in
            respond { done(createAssistantMessage([text("Response to custom message")])) }
        }
        _ = await collect(stream)
        let messages = await stream.result()
        #expect(messages.count == 1)
        #expect(messages.first?.role == "assistant")
    }
}

@Suite("runToolCall")
struct RunToolCallTests {
    let echo = AgentTool(
        name: "echo", label: "Echo", description: "Echo tool", parameters: valueSchema,
        outputSchema: ["type": "object", "properties": ["value": ["type": "string"]], "required": ["value"]]
    ) { _, params, _, onUpdate in
        onUpdate?(AgentToolResult(content: [.text(TextContent(text: "partial"))], details: .emptyObject))
        let value = params["value"] ?? .null
        return AgentToolResult(content: [.text(TextContent(text: value.stringValue ?? ""))], details: .emptyObject,
                               structuredContent: ["value": value])
    }
    let failing = AgentTool(name: "failing", label: "Failing", description: "Returns an error result", parameters: emptySchema) { _, _, _, _ in
        AgentToolResult(content: [.text(TextContent(text: "bad"))], details: ["partial": true], isError: true)
    }
    let assistantMessage = createAssistantMessage([])

    private func call(_ id: String, _ name: String, _ args: JsonObject) -> AgentToolCall {
        ToolCall(id: id, name: name, arguments: args)
    }

    @Test("validates, runs the hooks, and reports failures as error outcomes")
    func validatesAndRunsHooks() async throws {
        let hookCalls = Locked<[String]>([])
        let updates = Locked<[AgentToolResult]>([])
        let options = RunToolCallOptions(
            tools: [echo, failing],
            assistantMessage: assistantMessage,
            context: AgentContext(messages: []),
            onUpdate: { partial in updates.append(partial) },
            beforeToolCall: { ctx, _ in
                hookCalls.append("before \(ctx.toolCall.id)")
                if ctx.args["value"]?.stringValue == "blocked" { return BeforeToolCallResult(block: true, reason: "nope") }
                return nil
            },
            afterToolCall: { ctx, _ in
                hookCalls.append("after \(ctx.toolCall.id)")
                return nil
            }
        )

        let a = try await runToolCall(call("a", "echo", ["value": "a"]), options)
        #expect(a.toolCall.id == "a")
        #expect(a.result.structuredContent == ["value": "a"])
        #expect(a.isError == false)
        #expect(try await runToolCall(call("b", "echo", ["value": ["nested": true]]), options).isError)
        let c = try await runToolCall(call("c", "echo", ["value": "blocked"]), options)
        #expect(c.result.content == [.text(TextContent(text: "nope"))])
        #expect(c.isError)
        let d = try await runToolCall(call("d", "missing", [:]), options)
        #expect(d.result.content == [.text(TextContent(text: "Tool missing not found"))])
        #expect(d.isError)
        // Error results keep their details.
        let e = try await runToolCall(call("e", "failing", [:]), options)
        #expect(e.result.details == ["partial": true])
        #expect(e.isError)
        #expect(updates.current == [AgentToolResult(content: [.text(TextContent(text: "partial"))], details: .emptyObject)])
        // Validation failures and unknown tools never reach the hooks; blocked calls skip afterToolCall.
        #expect(hookCalls.current == ["before a", "after a", "before c", "before e", "after e"])
    }

    @Test("lets afterToolCall replace structured content and drops it when only content is replaced")
    func structuredContentMerge() async throws {
        let redacted: [UserContent] = [.text(TextContent(text: "redacted"))]
        let results = [
            AfterToolCallResult(content: redacted),
            AfterToolCallResult(structuredContent: ["value": "replaced"]),
            AfterToolCallResult(content: redacted, structuredContent: ["value": "both"]),
            AfterToolCallResult(details: ["note": "kept"]),
        ]
        var seen: [JsonValue?] = []
        for afterResult in results {
            let outcome = try await runToolCall(call("x", "echo", ["value": "original"]), RunToolCallOptions(
                tools: [echo], assistantMessage: assistantMessage, context: AgentContext(messages: []),
                afterToolCall: { _, _ in afterResult }
            ))
            seen.append(outcome.result.structuredContent)
        }
        #expect(seen == [nil, ["value": "replaced"], ["value": "both"], ["value": "original"]])
    }
}
