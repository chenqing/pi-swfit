import Foundation
import Observation
import PiAI
import PiAgent

/// Main-actor presentation adapter. The Agent owns the model transcript; the UI owns no provider state.
@MainActor @Observable
public final class ChatSession {
    public private(set) var messages: [ChatMessage] = []
    public private(set) var state: ChatRunState = .idle
    public private(set) var error: String?
    public var displayedMessages: [ChatMessage] {
        let pendingIDs = Set(approvals.pending.map(\.id))
        return messages.map { message in
            var message = message
            for i in message.tools.indices where pendingIDs.contains(message.tools[i].id) {
                message.tools[i].state = .awaitingApproval
            }
            return message
        }
    }
    public var draft = ""
    public let approvals: ApprovalCenter
    public var isRunning: Bool { state == .running || state == .stopping }
    @ObservationIgnored private let agent: Agent
    @ObservationIgnored private var assistantID: UUID?

    public init(options: AgentOptions, approvalPolicy: ChatApprovalPolicy = .always) throws {
        let center = ApprovalCenter()
        approvals = center
        var options = options
        if options.streamFn == nil {
            options.streamFn = { model, context, options in
                try PiAI.streamSimple(model, Context(messages: context.messages), options)
            }
        }
        let hostAuthorization = options.beforeToolCall
        options.beforeToolCall = { context, signal in
            if let decision = try await hostAuthorization?(context, signal), decision.block == true { return decision }
            guard approvalPolicy == .always else { return nil }
            let allowed = await center.request(ChatApproval(id: context.toolCall.id, toolName: context.toolCall.name,
                                                          arguments: context.args.value.serialized()), signal: signal)
            return allowed ? nil : BeforeToolCallResult(block: true, reason: "Tool execution was declined.", terminate: true)
        }
        agent = try Agent(options)
    }

    public func send(_ text: String? = nil) async {
        let input = (text ?? draft).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !input.isEmpty, !isRunning else { return }
        draft = ""; error = nil; state = .running; assistantID = nil
        approvals.reset()
        messages.append(ChatMessage(role: .user, text: input))
        let unsubscribe = agent.subscribe { [weak self] event, _ in await self?.receive(event) }
        defer {
            unsubscribe(); approvals.cancelAll()
            if state == .running { state = .completed }
            if state == .stopping { state = .cancelled }
            finishPendingTools()
        }
        await withTaskCancellationHandler {
            do {
                try await agent.prompt(input)
            } catch {
                if state == .stopping || Task.isCancelled { state = .cancelled }
                else { self.error = String(describing: error); state = .failed }
            }
        } onCancel: { [agent] in agent.abort() }
        if Task.isCancelled { state = .cancelled }
    }

    /// Cancels the current request. Completed tool effects are never rolled back or automatically replayed.
    public func stop() {
        guard state == .running else { return }
        state = .stopping
        agent.abort()
        approvals.cancelAll()
    }

    public func reset() async throws {
        guard !isRunning else { return }
        try await agent.reset()
        messages = []; draft = ""; error = nil; state = .idle; assistantID = nil
        approvals.reset()
    }

    private func receive(_ event: AgentEvent) {
        switch event {
        case .messageStart(.assistant(let message)):
            let item = ChatMessage(role: .assistant)
            assistantID = item.id; messages.append(item); update(message)
        case .messageUpdate(.assistant(let message), _): update(message)
        case .messageEnd(.assistant(let message)):
            update(message)
            if message.stopReason == .error { error = message.errorMessage ?? "The model request failed."; state = .failed }
            if message.stopReason == .aborted { state = .cancelled }
        case .toolExecutionStart(let id, let name, let args):
            upsertTool(id, name: name, arguments: JsonValue.object(args).serialized()) { $0.state = .running }
        case .toolExecutionUpdate(let id, let name, _, let result):
            upsertTool(id, name: name) { $0.output = Self.text(result) }
        case .toolExecutionEnd(let id, let name, let result, let isError, _):
            upsertTool(id, name: name) { tool in
                tool.output = Self.text(result)
                if state == .stopping || state == .cancelled { tool.state = isError ? .interrupted : .succeeded }
                else if approvals.wasRejected(id) { tool.state = .denied }
                else { tool.state = isError ? .failed : .succeeded }
            }
        default: break
        }
    }

    private func update(_ message: AssistantMessage) {
        guard let index = messages.firstIndex(where: { $0.id == assistantID }) else { return }
        messages[index].text = message.content.compactMap { if case .text(let t) = $0 { return t.text }; return nil }.joined()
        for case .toolCall(let call) in message.content {
            upsertTool(call.id, name: call.name, arguments: JsonValue.object(call.arguments).serialized()) { _ in }
        }
    }

    private func upsertTool(_ id: String, name: String, arguments: String? = nil, mutate: (inout ChatToolCall) -> Void) {
        for i in messages.indices {
            if let j = messages[i].tools.firstIndex(where: { $0.id == id }) {
                var tool = messages[i].tools[j]
                if let arguments { tool.arguments = arguments }
                mutate(&tool); messages[i].tools[j] = tool; return
            }
        }
        guard let i = messages.firstIndex(where: { $0.id == assistantID }) else { return }
        var tool = ChatToolCall(id: id, name: name, arguments: arguments ?? "{}")
        mutate(&tool); messages[i].tools.append(tool)
    }

    private func finishPendingTools() {
        for i in messages.indices {
            for j in messages[i].tools.indices where [.pending, .running].contains(messages[i].tools[j].state) {
                messages[i].tools[j].state = .interrupted
            }
        }
    }
    private static func text(_ result: AgentToolResult) -> String {
        result.content.compactMap { if case .text(let t) = $0 { return t.text }; return nil }.joined(separator: "\n")
    }
}
