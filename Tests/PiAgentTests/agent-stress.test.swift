import Foundation
import PiAI
import PiAgent
import Testing

// Not an upstream test: stress coverage for run termination. Every run must finish, `waitForIdle()`
// must return, and `agent_end` must be the last event, whatever the abort timing.

/// Runs `body`; returns false when it does not finish within `seconds`.
private func finishes(within seconds: Double, _ body: @escaping @Sendable () async -> Void) async -> Bool {
    // A task group waits for every child on exit, even after cancellation. That makes a
    // timeout ineffective when the body is stuck waiting on a continuation.
    await withCheckedContinuation { continuation in
        let settled = Locked(false)
        let finish: @Sendable (Bool) -> Void = { result in
            let first = settled.withLock { value in
                guard !value else { return false }
                value = true
                return true
            }
            if first { continuation.resume(returning: result) }
        }
        let operation = Task { await body(); finish(true) }
        let timer = Task {
            do { try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000)) }
            catch { return }
            operation.cancel()
            finish(false)
        }
        Task { await operation.value; timer.cancel() }
    }
}

/// A provider that streams a few deltas with abortable pauses. On abort it ends with an aborted
/// error, like real providers. Depending on `variant` the first request asks for tools, fails, or throws.
private func stressStream(variant: Int, requests: Locked<Int>) -> StreamFn {
    { _, _, options in
        let request = requests.increment()
        if variant == 3 && request == 1 { throw PiError("provider exploded") }
        let signal = options?.signal
        let stream = createAssistantMessageEventStream()
        Task {
            var partial = createAssistantMessage([])
            stream.push(.start(partial: partial))
            do {
                partial.content = [text("")]
                stream.push(.textStart(contentIndex: 0, partial: partial))
                for i in 0..<3 {
                    try await sleep(Int.random(in: 0...3), signal)
                    partial.content = [text(String(repeating: "x", count: i + 1))]
                    stream.push(.textDelta(contentIndex: 0, delta: "x", partial: partial))
                }
                if variant == 2 && request == 1 {
                    var failed = partial
                    failed.stopReason = .error
                    failed.errorMessage = "boom"
                    stream.push(.error(reason: .error, error: failed))
                    return
                }
                if (variant == 0 || variant == 1) && request == 1 {
                    let message = createAssistantMessage([
                        toolCall("calc-\(request)", "calculate", ["expression": "1 + 2"]),
                        toolCall("slow-\(request)", "slow", ["value": "v"]),
                    ], .toolUse)
                    stream.push(done(message))
                    return
                }
                var final = partial
                final.stopReason = .stop
                stream.push(done(final))
            } catch {
                var aborted = partial
                aborted.stopReason = .aborted
                aborted.errorMessage = "Request was aborted"
                stream.push(.error(reason: .aborted, error: aborted))
            }
        }
        return stream
    }
}

private let slowTool = AgentTool(name: "slow", label: "Slow", description: "Sleeps", parameters: valueSchema) { _, _, signal, onUpdate in
    onUpdate?(textResult("working"))
    try await sleep(Int.random(in: 0...5), signal)
    return textResult("slept")
}

@Suite("Agent stress")
struct AgentStressTests {
    @Test("stress deadline returns while a continuation is still suspended")
    func deadlineDoesNotWaitForBody() async {
        let release = Deferred()
        let completed = Deferred()
        let finished = await finishes(within: 0.01) {
            await release.wait()
            completed.resolve()
        }
        release.resolve()
        await completed.wait()
        #expect(!finished)
    }

    @Test("200 concurrent agent runs with random abort timing always terminate")
    func concurrentAgentRuns() async throws {
        let failures = Locked<[String]>([])
        let abortedRuns = Locked(0)
        await withTaskGroup(of: Void.self) { group in
            for run in 0..<200 {
                group.addTask {
                    let variant = run % 5
                    let requests = Locked(0)
                    let agent: Agent
                    do {
                        agent = try Agent(AgentOptions(
                            initialState: AgentInitialState(systemPrompt: "stress", tools: [calculateTool, slowTool]),
                            streamFn: stressStream(variant: variant, requests: requests),
                            toolExecution: variant == 1 ? .sequential : .parallel
                        ))
                    } catch {
                        failures.append("run \(run): init failed")
                        return
                    }
                    let events = Locked<[String]>([])
                    let started = Deferred()
                    agent.subscribe { event, _ in
                        events.append(event.type)
                        if case .agentStart = event { started.resolve() }
                        if Int.random(in: 0..<4) == 0 { await Task.yield() }
                    }
                    if run % 7 == 0 { agent.followUp(createUserMessage("follow-up \(run)")) }
                    if run % 11 == 0 { agent.steer(createUserMessage("steer \(run)")) }

                    let abortAfter = run % 6 == 0 ? nil : Int.random(in: 0...12)
                    let abortTask = Task {
                        guard let abortAfter else { return }
                        // Observe the start event; polling isStreaming can miss a short run
                        // and leave a spinning task behind after the prompt finishes.
                        await started.wait()
                        await sleepMs(abortAfter)
                        guard !Task.isCancelled else { return }
                        agent.abort()
                    }

                    let promptDone = await finishes(within: 10) {
                        do { try await agent.prompt("go \(run)") } catch { failures.append("run \(run): prompt threw \(error)") }
                    }
                    if !promptDone { failures.append("run \(run): prompt hung"); agent.abort() }
                    abortTask.cancel()
                    await abortTask.value
                    let idle = await finishes(within: 5) { await agent.waitForIdle() }
                    if !idle { failures.append("run \(run): waitForIdle hung") }

                    let types = events.current
                    if types.first != "agent_start" { failures.append("run \(run): first event \(types.first ?? "none")") }
                    if types.last != "agent_end" { failures.append("run \(run): last event \(types.last ?? "none")") }
                    if types.filter({ $0 == "agent_end" }).count != 1 { failures.append("run \(run): agent_end count") }
                    let state = await agent.state
                    if state.isStreaming { failures.append("run \(run): still streaming") }
                    if state.streamingMessage != nil { failures.append("run \(run): streamingMessage left") }
                    if !state.pendingToolCalls.isEmpty { failures.append("run \(run): pending tool calls left") }
                    if agent.signal != nil { failures.append("run \(run): active run left") }
                    if state.messages.last?.assistantMessage?.stopReason == .aborted { abortedRuns.increment() }
                }
            }
        }
        #expect(failures.current == [])
        // The abort timing must actually interrupt a share of the runs.
        #expect(abortedRuns.current > 0)
    }

    @Test("200 concurrent loop runs with random abort timing always emit agent_end")
    func concurrentLoopRuns() async {
        let failures = Locked<[String]>([])
        await withTaskGroup(of: Void.self) { group in
            for run in 0..<200 {
                group.addTask {
                    let controller = AbortController()
                    let requests = Locked(0)
                    let config = AgentLoopConfig(
                        model: createModel(),
                        convertToLlm: identityConverter,
                        toolExecution: run % 2 == 0 ? .parallel : .sequential
                    )
                    let stream = agentLoop(
                        [createUserMessage("go \(run)")],
                        AgentContext(tools: [calculateTool, slowTool]),
                        config,
                        controller.signal,
                        stressStream(variant: run % 5, requests: requests)
                    )
                    let abortTask = Task {
                        await sleepMs(Int.random(in: 0...12))
                        if run % 4 != 0 { controller.abort() }
                    }
                    let events = Locked<[String]>([])
                    let drained = await finishes(within: 10) {
                        for await event in stream { events.append(event.type) }
                        _ = await stream.resultIfAny()
                    }
                    abortTask.cancel()
                    if !drained { failures.append("loop \(run): hung"); return }
                    let types = events.current
                    // Variant 3 throws from the stream function: the loop fails and the stream ends early.
                    if run % 5 != 3 && types.last != "agent_end" { failures.append("loop \(run): last event \(types.last ?? "none")") }
                }
            }
        }
        #expect(failures.current == [])
    }

    @Test("calculate tool helper")
    func calculateHelper() throws {
        #expect(firstText(try calculate("2 * (3 + 4)").content) == "2 * (3 + 4) = 14")
        #expect(throws: PiError.self) { try calculate("2 *") }
    }
}
