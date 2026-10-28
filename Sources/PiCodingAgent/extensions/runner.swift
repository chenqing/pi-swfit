// Native subset of core/extensions/{types,runner}.ts @ 42cb822f1c5d3153069dd0661bfd297424666cf1.
// Swift closures replace the JS loader. This does not execute TypeScript extension packages.
import Foundation
import PiAI
import PiAgent

public struct ExtensionError: Sendable {
    public let extensionPath: String
    public let event: String
    public let error: String
}

public struct ExtensionContext: Sendable {
    public let cwd: String
    public let projectTrusted: Bool
    public let signal: AbortSignal
    /// Atomically replaces this extension's tools, withdrawing old declarations and handles.
    public let replaceTools: @Sendable ([AgentTool]) async throws -> Void
    public let registerTools: @Sendable ([ExtensionTool]) async throws -> Void
    public let getTools: @Sendable () async -> [ExtensionToolInfo]
    public let activateTools: @Sendable ([String]) async throws -> Void
    public let executeTool: @Sendable (String, String, JsonObject, AbortSignal?) async throws -> AgentToolCallOutcome
    // Built-in catalogs retain unchanged registrations when a different server refreshes.
    let replaceVersionedTools: @Sendable ([AgentTool], [String: UUID]) async throws -> Void
}

public enum ExtensionEvent: Sendable {
    case sessionStart
    case sessionShutdown
    case resourcesReloaded
    case sessionChanged(reason: String)
    case beforeAgentStart(prompt: String)
    case agent(AgentEvent)
    case nestedToolExecution(AgentEvent, parentToolCallId: String)
    public var type: String {
        switch self {
        case .sessionStart: "session_start"
        case .sessionShutdown: "session_shutdown"
        case .resourcesReloaded: "resources_reload"
        case .sessionChanged: "session_switch"
        case .beforeAgentStart: "before_agent_start"
        case .agent(let event), .nestedToolExecution(let event, _): event.type
        }
    }
}

public enum ExtensionInputResult: Sendable {
    case continueInput
    case transform(String, images: [ImageContent]?)
    case handled
}
public struct ExtensionCommand: Sendable {
    public let name: String
    public let description: String
    public let execute: @Sendable (String, ExtensionContext) async throws -> Void
    public init(name: String, description: String, execute: @escaping @Sendable (String, ExtensionContext) async throws -> Void) {
        self.name = name; self.description = description; self.execute = execute
    }
}

/// Trusted, host-supplied Swift extension. Handlers run in registration order.
public struct NativeExtension: Sendable {
    public let id: String
    public var tools: [AgentTool]
    public var commands: [ExtensionCommand]
    public var onInput: (@Sendable (String, [ImageContent]?, ExtensionContext) async throws -> ExtensionInputResult)?
    public var onContext: (@Sendable ([AgentMessage], ExtensionContext) async throws -> [AgentMessage])?
    public var onBeforeSessionChange: (@Sendable (String, ExtensionContext) async throws -> Bool)?
    public var onEvent: (@Sendable (ExtensionEvent, ExtensionContext) async throws -> Void)?
    public var onToolCall: (@Sendable (BeforeToolCallContext, ExtensionContext) async throws -> BeforeToolCallResult?)?
    public var onToolResult: (@Sendable (AfterToolCallContext, ExtensionContext) async throws -> AfterToolCallResult?)?
    public init(id: String, tools: [AgentTool] = [],
                onEvent: (@Sendable (ExtensionEvent, ExtensionContext) async throws -> Void)? = nil,
                onToolCall: (@Sendable (BeforeToolCallContext, ExtensionContext) async throws -> BeforeToolCallResult?)? = nil,
                onToolResult: (@Sendable (AfterToolCallContext, ExtensionContext) async throws -> AfterToolCallResult?)? = nil,
                commands: [ExtensionCommand] = [],
                onInput: (@Sendable (String, [ImageContent]?, ExtensionContext) async throws -> ExtensionInputResult)? = nil,
                onContext: (@Sendable ([AgentMessage], ExtensionContext) async throws -> [AgentMessage])? = nil,
                onBeforeSessionChange: (@Sendable (String, ExtensionContext) async throws -> Bool)? = nil) {
        self.id = id; self.tools = tools; self.onEvent = onEvent
        self.onToolCall = onToolCall; self.onToolResult = onToolResult
        self.commands = commands; self.onInput = onInput; self.onContext = onContext; self.onBeforeSessionChange = onBeforeSessionChange
    }
}

public final class ExtensionRunner: Sendable {
    private struct State {
        var start: Task<Void, Never>?
        var shutdown: Task<Void, Never>?
        var contexts: [String: ExtensionContext] = [:]
        var errors: [ExtensionError] = []
    }
    private let state = Locked(State())
    private let lifetime = AbortController()
    private let extensions: [NativeExtension]
    public var isActive: Bool { !lifetime.signal.aborted }
    public init(_ extensions: [NativeExtension]) throws {
        var ids = Set<String>(), commands = Set<String>()
        for item in extensions {
            guard !item.id.isEmpty, ids.insert(item.id).inserted else { throw PiError("Duplicate or empty extension ID: \(item.id)") }
        }
        for item in extensions { for command in item.commands {
            guard command.name.range(of: "^[A-Za-z0-9_-]+$", options: .regularExpression) != nil,
                  commands.insert(command.name).inserted else { throw PiError("Duplicate or invalid extension command: \(command.name)") }
        } }
        self.extensions = extensions
    }
    public func drainErrors() -> [ExtensionError] {
        state.withLock { let result = $0.errors; $0.errors.removeAll(); return result }
    }
    private func report(_ id: String, _ event: String, _ error: any Error) {
        state.withLock { $0.errors.append(.init(extensionPath: id, event: event, error: errorMessage(error))) }
    }
    func start(cwd: String, projectTrusted: Bool,
               publish: @escaping @Sendable (String, [ExtensionTool]) async throws -> Void,
               getTools: @escaping @Sendable () async -> [ExtensionToolInfo],
               activateTools: @escaping @Sendable ([String]) async throws -> Void,
               executeTool: @escaping @Sendable (String, String, JsonObject, AbortSignal?) async throws -> AgentToolCallOutcome) async {
        let task = state.withLock { state -> Task<Void, Never> in
            if let task = state.start { return task }
            let task = Task { [self] in
                for item in extensions {
                    guard isActive else { break }
                    let owner = item.id
                    let context = ExtensionContext(cwd: cwd, projectTrusted: projectTrusted, signal: lifetime.signal,
                        replaceTools: { [weak self] tools in
                            guard self?.isActive == true else { throw PiError("Extension runtime is closed") }
                            try await publish(owner, tools.map { ExtensionTool($0) })
                        }, registerTools: { [weak self] tools in
                            guard self?.isActive == true else { throw PiError("Extension runtime is closed") }
                            try await publish(owner, tools)
                        }, getTools: getTools, activateTools: activateTools, executeTool: executeTool,
                        replaceVersionedTools: { [weak self] tools, versions in
                            guard self?.isActive == true else { throw PiError("Extension runtime is closed") }
                            try await publish(owner, tools.map { ExtensionTool($0, version: versions[$0.name]) })
                        })
                    self.state.withLock { $0.contexts[item.id] = context }
                    do {
                        try await context.replaceTools(item.tools)
                        try await item.onEvent?(.sessionStart, context)
                    } catch { report(item.id, "session_start", error) }
                }
            }
            state.start = task
            return task
        }
        await task.value
    }
    /// Synchronously revokes callbacks and tool handles; shutdown awaits resource cleanup.
    public func invalidate() { lifetime.abort() }
    public func shutdown() async {
        invalidate()
        let task = state.withLock { state -> Task<Void, Never> in
            if let task = state.shutdown { return task }
            let start = state.start
            let task = Task { [self] in
                await start?.value
                for item in extensions {
                    guard let context = self.state.withLock({ $0.contexts[item.id] }) else { continue }
                    do { try await item.onEvent?(.sessionShutdown, context) }
                    catch { report(item.id, "session_shutdown", error) }
                }
                self.state.withLock { $0.contexts.removeAll(); $0.start = nil }
            }
            state.shutdown = task
            return task
        }
        await task.value
    }
    func emit(_ event: AgentEvent) async { await emitEvent(.agent(event)) }
    func emitEvent(_ event: ExtensionEvent) async {
        for item in extensions {
            guard isActive, let context = state.withLock({ $0.contexts[item.id] }) else { return }
            do { try await item.onEvent?(event, context) }
            catch { report(item.id, event.type, error) }
        }
    }
    public func getCommands() -> [(name: String, description: String)] {
        extensions.flatMap { $0.commands.map { (name: $0.name, description: $0.description) } }
    }
    func command(_ text: String) async throws -> Bool {
        guard text.hasPrefix("/") else { return false }
        let parts = text.dropFirst().split(maxSplits: 1, whereSeparator: \.isWhitespace)
        guard let name = parts.first else { return false }
        for item in extensions {
            guard let command = item.commands.first(where: { $0.name == name }),
                  let context = state.withLock({ $0.contexts[item.id] }) else { continue }
            try lifetime.signal.throwIfAborted()
            try await command.execute(parts.count > 1 ? String(parts[1]) : "", context)
            return true
        }
        return false
    }
    func input(_ text: String, images: [ImageContent]?) async throws -> ExtensionInputResult {
        var text = text, images = images
        for item in extensions {
            try lifetime.signal.throwIfAborted()
            guard let context = state.withLock({ $0.contexts[item.id] }), let handler = item.onInput else { continue }
            switch try await handler(text, images, context) {
            case .continueInput: break
            case .handled: return .handled
            case .transform(let next, let nextImages): text = next; images = nextImages
            }
        }
        return .transform(text, images: images)
    }
    func context(_ messages: [AgentMessage]) async throws -> [AgentMessage] {
        var messages = messages
        for item in extensions {
            try lifetime.signal.throwIfAborted()
            guard let context = state.withLock({ $0.contexts[item.id] }), let handler = item.onContext else { continue }
            messages = try await handler(messages, context)
        }
        return messages
    }
    func beforeSessionChange(_ reason: String) async throws -> Bool {
        for item in extensions {
            try lifetime.signal.throwIfAborted()
            guard let context = state.withLock({ $0.contexts[item.id] }) else { continue }
            if try await item.onBeforeSessionChange?(reason, context) == false { return false }
        }
        return true
    }
    func before(_ event: BeforeToolCallContext) async throws -> BeforeToolCallResult? {
        var result: BeforeToolCallResult?
        for item in extensions {
            try lifetime.signal.throwIfAborted()
            guard let context = state.withLock({ $0.contexts[item.id] }) else { continue }
            // Like upstream, permission handler failures block the call rather than failing open.
            do {
                if let next = try await item.onToolCall?(event, context) {
                    result = next
                    if next.block == true { return next }
                }
            } catch { report(item.id, "tool_call", error); throw error }
        }
        try lifetime.signal.throwIfAborted()
        return result
    }
    func after(_ event: AfterToolCallContext) async -> AfterToolCallResult? {
        var current = event
        var modified = false
        for item in extensions {
            guard isActive, let context = state.withLock({ $0.contexts[item.id] }) else { break }
            do {
                if let patch = try await item.onToolResult?(current, context) {
                    current.result = applyingToolResult(patch, to: current.result, isError: current.isError)
                    current.isError = current.result.isError ?? current.isError
                    modified = true
                }
            } catch { report(item.id, "tool_result", error) }
        }
        return modified ? completeToolResultPatch(current.result, isError: current.isError) : nil
    }
}

func applyingToolResult(_ patch: AfterToolCallResult, to original: AgentToolResult, isError: Bool) -> AgentToolResult {
    var result = original
    result.structuredContent = patch.structuredContent ?? (patch.content != nil ? nil : original.structuredContent)
    result.content = patch.content ?? original.content
    result.details = patch.details ?? original.details
    result.isError = patch.isError ?? isError
    result.usage = patch.usage ?? original.usage
    result.terminate = patch.terminate ?? original.terminate
    return result
}
func completeToolResultPatch(_ result: AgentToolResult, isError: Bool) -> AfterToolCallResult {
    .init(content: result.content, details: result.details, structuredContent: result.structuredContent,
          isError: isError, usage: result.usage, terminate: result.terminate)
}
