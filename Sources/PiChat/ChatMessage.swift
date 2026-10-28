import Foundation

public enum ChatRole: String, Sendable { case user, assistant }
public enum ChatRunState: String, Sendable { case idle, running, stopping, completed, cancelled, failed }
public enum ChatToolState: String, Sendable { case pending, awaitingApproval, running, succeeded, failed, denied, interrupted }

public struct ChatToolCall: Identifiable, Sendable {
    public let id: String
    public var name: String
    public var arguments: String
    public var output: String
    public var state: ChatToolState
    public init(id: String, name: String, arguments: String = "{}", output: String = "", state: ChatToolState = .pending) {
        self.id = id; self.name = name; self.arguments = arguments; self.output = output; self.state = state
    }
}

public struct ChatMessage: Identifiable, Sendable {
    public let id: UUID
    public let role: ChatRole
    public var text: String
    public var tools: [ChatToolCall]
    public init(id: UUID = UUID(), role: ChatRole, text: String = "", tools: [ChatToolCall] = []) {
        self.id = id; self.role = role; self.text = text; self.tools = tools
    }
}

public struct ChatApproval: Identifiable, Sendable {
    public let id: String
    public let toolName: String
    /// Exact validated arguments passed to the tool. Hosts should avoid placing secrets in tool arguments.
    public let arguments: String
}

public enum ChatApprovalPolicy: Sendable {
    /// Every tool waits for an explicit decision. This is the default.
    case always
    /// Use only when the host has already supplied its own authorization policy.
    case handledByHost
}
