import Foundation
import PiAI
import PiAgent

// Shared helpers for the PiAgent test ports (stand-ins for the per-file helpers upstream and for
// JavaScript features the tests lean on: closures over `let` counters, `queueMicrotask`, deferreds).

func createUsage() -> Usage {
    Usage(
        input: 0,
        output: 0,
        cacheRead: 0,
        cacheWrite: 0,
        totalTokens: 0,
        cost: UsageCost(input: 0, output: 0, cacheRead: 0, cacheWrite: 0, total: 0)
    )
}

func createModel() -> Model {
    Model(
        id: "mock",
        name: "mock",
        api: "openai-responses",
        provider: "openai",
        baseUrl: "https://example.invalid",
        reasoning: false,
        input: ["text"],
        cost: ModelCost(input: 0, output: 0, cacheRead: 0, cacheWrite: 0),
        contextWindow: 8192,
        maxTokens: 2048
    )
}

func createAssistantMessage(_ content: [AssistantContent], _ stopReason: StopReason = .stop) -> AssistantMessage {
    AssistantMessage(
        content: content,
        api: "openai-responses",
        provider: "openai",
        model: "mock",
        usage: createUsage(),
        stopReason: stopReason,
        timestamp: dateNow()
    )
}

func createAssistantMessage(_ text: String) -> AssistantMessage {
    createAssistantMessage([.text(TextContent(text: text))])
}

func createAssistantToolUseMessage(_ content: [AssistantContent]) -> AssistantMessage {
    createAssistantMessage(content, .toolUse)
}

func createUserMessage(_ text: String) -> AgentMessage {
    .user(UserMessage(content: .string(text), timestamp: dateNow()))
}

func text(_ value: String) -> AssistantContent { .text(TextContent(text: value)) }

func toolCall(_ id: String, _ name: String, _ arguments: JsonObject = [:]) -> AssistantContent {
    .toolCall(ToolCall(id: id, name: name, arguments: arguments))
}

/// Simple identity converter for tests - just passes through standard messages
@Sendable func identityConverter(_ messages: [AgentMessage]) async -> [Message] {
    messages.compactMap(\.llmMessage)
}

/// `createAssistantMessageEventStream()` + `queueMicrotask(() => stream.push(event))`.
func respond(_ event: @escaping @Sendable () -> AssistantMessageEvent) -> AssistantMessageEventStream {
    let stream = createAssistantMessageEventStream()
    Task { stream.push(event()) }
    return stream
}

/// `{ type: "done", reason: message.stopReason, message }`
func done(_ message: AssistantMessage) -> AssistantMessageEvent {
    .done(reason: message.stopReason, message: message)
}

func collect(_ stream: EventStream<AgentEvent, [AgentMessage]>) async -> [AgentEvent] {
    var events: [AgentEvent] = []
    for await event in stream { events.append(event) }
    return events
}

/// String content of a user message, if any (`message.role === "user" && typeof message.content === "string"`).
func userString(_ message: Message) -> String? {
    if case .user(let user) = message, case .string(let value) = user.content { return value }
    return nil
}

func userString(_ message: AgentMessage) -> String? {
    message.llmMessage.flatMap(userString)
}

/// User string contents of a provider context.
func userStrings(_ context: TranscriptContext) -> [String] {
    context.messages.compactMap(userString)
}

/// Structural equality for messages (upstream compares with `toEqual` / `toBe`).
func same(_ left: AgentMessage, _ right: AgentMessage) -> Bool {
    String(describing: left) == String(describing: right)
}

func same(_ left: [AgentMessage], _ right: [AgentMessage]) -> Bool {
    left.count == right.count && zip(left, right).allSatisfy { same($0, $1) }
}

func contains(_ messages: [AgentMessage], _ message: AgentMessage) -> Bool {
    messages.contains { same($0, message) }
}

func contains(_ messages: [Message], _ message: AgentMessage) -> Bool {
    messages.contains { same(AgentMessage($0), message) }
}

func textResult(_ value: String, details: JsonValue? = .emptyObject, terminate: Bool? = nil) -> AgentToolResult {
    AgentToolResult(content: [.text(TextContent(text: value))], details: details, terminate: terminate)
}

func firstText(_ content: [UserContent]) -> String? {
    for block in content { if case .text(let t) = block { return t.text } }
    return nil
}

/// `Type.Object({ value: Type.String() })`
let valueSchema: JsonValue = [
    "type": "object",
    "properties": ["value": ["type": "string"]],
    "required": ["value"],
]

/// `Type.Object({})`
let emptySchema: JsonValue = ["type": "object", "properties": [:]]

func sleepMs(_ ms: Int) async {
    try? await Task.sleep(nanoseconds: UInt64(ms) * 1_000_000)
}

extension Locked where Value == Int {
    @discardableResult
    func increment() -> Int { withLock { $0 += 1; return $0 } }
}

extension Locked {
    func append<Element>(_ element: Element) where Value == [Element] {
        withLock { $0.append(element) }
    }
}

/// `createDeferred()`: a promise resolved from outside.
final class Deferred: Sendable {
    private let state = Locked<(resolved: Bool, waiters: [CheckedContinuation<Void, Never>])>((false, []))

    func resolve() {
        let waiters = state.withLock { s -> [CheckedContinuation<Void, Never>] in
            s.resolved = true
            defer { s.waiters = [] }
            return s.waiters
        }
        for waiter in waiters { waiter.resume() }
    }

    func wait() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let resolved = state.withLock { s -> Bool in
                if s.resolved { return true }
                s.waiters.append(continuation)
                return false
            }
            if resolved { continuation.resume() }
        }
    }
}

/// Upstream starts `agent.prompt()` without awaiting it; the run is active synchronously. Here the
/// prompt runs in a task, so tests wait until the run has started.
func waitUntilStreaming(_ agent: Agent) async {
    while !(await agent.state.isStreaming) { await Task.yield() }
}

/// Serializes the tests that install a global default stream function.
actor GlobalStreamFnLock {
    static let shared = GlobalStreamFnLock()
    private var busy = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func run<T: Sendable>(_ body: @Sendable () async throws -> T) async rethrows -> T {
        while busy {
            await withCheckedContinuation { waiters.append($0) }
        }
        busy = true
        defer {
            busy = false
            if !waiters.isEmpty { waiters.removeFirst().resume() }
        }
        return try await body()
    }
}
