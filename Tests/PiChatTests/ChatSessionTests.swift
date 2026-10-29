import Foundation
import Testing
import PiAI
import PiAgent
@testable import PiChat

@Suite("PiChat lifecycle") @MainActor
struct ChatSessionTests {
    private func options(executions: Locked<Int> = Locked(0), streaming: Bool = false, failure: Bool = false) -> AgentOptions {
        let model = Model(id: "fixture", name: "Fixture", api: "openai-responses", provider: "test", baseUrl: "https://example.invalid")
        let tool = AgentTool(name: "fixture_tool", label: "Fixture", description: "Count calls", parameters: .object(["type": "object", "properties": .object([:])])) { _, _, _, _ in
            executions.withLock { $0 += 1 }
            return AgentToolResult(content: [.text(TextContent(text: "executed"))])
        }
        return AgentOptions(initialState: AgentInitialState(model: model, tools: [tool]), streamFn: { _, context, options in
            let stream = createAssistantMessageEventStream()
            Task {
                var message = AssistantMessage(api: model.api, provider: model.provider, model: model.id)
                if failure {
                    message.stopReason = .error; message.errorMessage = "fixture failure"
                    stream.push(.error(reason: .error, error: message)); return
                }
                if streaming {
                    message.content = [.text(TextContent(text: "Partial response"))]
                    stream.push(.start(partial: message))
                    stream.push(.textDelta(contentIndex: 0, delta: "Partial response", partial: message))
                    while options?.signal?.aborted != true { try? await Task.sleep(for: .milliseconds(5)) }
                    message.stopReason = .aborted
                    stream.push(.error(reason: .aborted, error: message)); return
                }
                if context.messages.last?.role == "toolResult" {
                    message.content = [.text(TextContent(text: "Finished"))]
                } else {
                    message.content = [.text(TextContent(text: "Before tool")), .toolCall(ToolCall(id: UUID().uuidString, name: "fixture_tool", arguments: [:]))]
                    message.stopReason = .toolUse
                }
                stream.push(.done(reason: message.stopReason, message: message))
            }
            return stream
        })
    }
    private func until(_ predicate: () -> Bool) async throws {
        for _ in 0..<400 {
            if predicate() { return }
            try await Task.sleep(for: .milliseconds(5))
        }
        throw PiError("Timed out waiting for chat state")
    }

    @Test func toolWaitsForApprovalAndRunsOnce() async throws {
        let calls = Locked(0)
        let session = try ChatSession(options: options(executions: calls))
        let task = Task { await session.send("Hello") }
        try await until { !session.approvals.pending.isEmpty }
        #expect(calls.current == 0)
        let id = try #require(session.approvals.pending.first?.id)
        session.approvals.resolve(id, allow: true)
        session.approvals.resolve(id, allow: true)
        await task.value
        #expect(calls.current == 1)
        #expect(session.state == .completed)
        #expect(session.messages.last?.text == "Finished")
        #expect(session.messages.flatMap(\.tools).first?.state == .succeeded)
    }

    @Test func rejectionNeverExecutesTool() async throws {
        let calls = Locked(0)
        let session = try ChatSession(options: options(executions: calls))
        let task = Task { await session.send("Hello") }
        try await until { !session.approvals.pending.isEmpty }
        session.approvals.resolve(try #require(session.approvals.pending.first?.id), allow: false)
        await task.value
        #expect(calls.current == 0)
        #expect(session.messages.flatMap(\.tools).first?.state == .denied)
        #expect(session.approvals.pending.isEmpty)
    }

    @Test func stopWhileWaitingSettlesAndCanStartAgain() async throws {
        let calls = Locked(0)
        let session = try ChatSession(options: options(executions: calls))
        let task = Task { await session.send("Hello") }
        try await until { !session.approvals.pending.isEmpty }
        session.stop()
        await task.value
        #expect(calls.current == 0)
        #expect(session.state == .cancelled)
        #expect(session.approvals.pending.isEmpty)
        #expect(session.messages.contains { $0.text == "Before tool" })
        try await session.reset()
        #expect(session.messages.isEmpty)
        #expect(session.state == .idle)
    }

    @Test func stopPreservesPartialResponseAndDraft() async throws {
        let session = try ChatSession(options: options(streaming: true))
        let task = Task { await session.send("Hello") }
        try await until { session.messages.last?.text == "Partial response" }
        session.draft = "Next question"
        session.stop()
        await task.value
        #expect(session.messages.last?.text == "Partial response")
        #expect(session.draft == "Next question")
        #expect(session.state == .cancelled)
    }

    @Test func hostCancellationClearsApproval() async throws {
        let calls = Locked(0)
        let session = try ChatSession(options: options(executions: calls))
        let task = Task { await session.send("Hello") }
        try await until { !session.approvals.pending.isEmpty }
        task.cancel()
        await task.value
        #expect(session.approvals.pending.isEmpty)
        #expect(session.state == .cancelled)
        #expect(calls.current == 0)
    }

    @Test func providerErrorIsVisible() async throws {
        let session = try ChatSession(options: options(failure: true))
        await session.send("Hello")
        #expect(session.state == .failed)
        #expect(session.error == "fixture failure")
        #expect(session.messages.first?.text == "Hello")
    }

    @Test func concurrentSendDoesNotAppendOrClearDraft() async throws {
        let session = try ChatSession(options: options(streaming: true))
        let task = Task { await session.send("First") }
        try await until { session.isRunning }
        session.draft = "Keep me"
        await session.send()
        #expect(session.messages.filter { $0.role == .user }.count == 1)
        #expect(session.draft == "Keep me")
        session.stop(); await task.value
    }

    @Test func existingHostDenialIsRespected() async throws {
        let calls = Locked(0)
        var config = options(executions: calls)
        config.beforeToolCall = { _, _ in BeforeToolCallResult(block: true, reason: "Host denied", terminate: true) }
        let session = try ChatSession(options: config)
        await session.send("Hello")
        #expect(calls.current == 0)
        #expect(session.approvals.pending.isEmpty)
        #expect(session.messages.flatMap(\.tools).first?.output.contains("Host denied") == true)
    }

    @Test func bypassExecutesOnceAndModeChangesPreserveDraftAndTranscript() async throws {
        let calls = Locked(0)
        let session = try ChatSession(options: options(executions: calls))
        session.draft = "Keep this draft"
        try session.selectPermissionMode(.bypassPermissions)
        #expect(session.draft == "Keep this draft")
        #expect(session.messages.isEmpty)
        await session.send("First")
        #expect(calls.current == 1 && session.approvals.pending.isEmpty)
        let ids = session.messages.map(\.id)
        session.draft = "Next draft"
        try session.selectPermissionMode(.manual)
        #expect(session.messages.map(\.id) == ids && session.draft == "Next draft")
        try session.selectPermissionMode(.bypassPermissions)
        try await session.reset()
        #expect(session.permissionMode == .manual)
    }

    @Test func changingModeCannotApproveAnAlreadyPendingCall() async throws {
        let calls = Locked(0)
        let session = try ChatSession(options: options(executions: calls))
        let task = Task { await session.send("Hello") }
        try await until { !session.approvals.pending.isEmpty }
        #expect(!session.canSelectPermissionMode)
        #expect(throws: (any Error).self) { try session.selectPermissionMode(.bypassPermissions) }
        #expect(session.permissionMode == .manual && calls.current == 0)
        session.stop(); await task.value
        #expect(session.canSelectPermissionMode)
    }

    @Test func bypassStillHonorsHostDenialAndHostManagedSessionsCannotChangePolicy() async throws {
        let calls = Locked(0)
        var config = options(executions: calls)
        config.beforeToolCall = { _, _ in BeforeToolCallResult(block: true, reason: "Host denied", terminate: true) }
        let session = try ChatSession(options: config)
        try session.selectPermissionMode(.bypassPermissions)
        await session.send("Hello")
        #expect(calls.current == 0 && session.approvals.pending.isEmpty)
        let managed = try ChatSession(options: config, approvalPolicy: .handledByHost)
        #expect(!managed.canSelectPermissionMode)
        #expect(throws: (any Error).self) { try managed.selectPermissionMode(.bypassPermissions) }
    }
}
