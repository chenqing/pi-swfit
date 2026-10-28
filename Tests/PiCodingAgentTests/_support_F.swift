import Foundation
import PiAI
import PiAgent
@testable import PiCodingAgent

// Shared helpers for the PiCodingAgent test ports (stand-ins for test/utilities.ts and for
// vitest matchers that read untyped object fields).

/// `userMsg(text)` from test/utilities.ts.
func userMsg(_ text: String) -> AgentMessage {
    .user(UserMessage(content: .string(text), timestamp: dateNow()))
}

/// `assistantMsg(text)` from test/utilities.ts.
func assistantMsg(_ text: String) -> AgentMessage {
    .assistant(AssistantMessage(
        content: [.text(TextContent(text: text))],
        api: "anthropic-messages",
        provider: "anthropic",
        model: "test",
        usage: Usage(input: 1, output: 1, cacheRead: 0, cacheWrite: 0, totalTokens: 2, cost: UsageCost()),
        stopReason: .stop,
        timestamp: dateNow()
    ))
}

/// `readSessionFileRoles(file)` from test/utilities.ts.
func readSessionFileRoles(_ file: String) throws -> [String] {
    let content = try String(contentsOfFile: file, encoding: .utf8)
    return try content.trimmingCharacters(in: .whitespacesAndNewlines)
        .split(separator: "\n")
        .map { line in
            let record = try JsonValue.parse(String(line))
            return record["message"]?["role"]?.stringValue ?? record["type"]?.stringValue ?? ""
        }
}

/// The usage value several upstream tests share.
let sampleUsage = Usage(
    input: 10, output: 20, cacheRead: 30, cacheWrite: 40, totalTokens: 100,
    cost: UsageCost(input: 0.1, output: 0.2, cacheRead: 0.3, cacheWrite: 0.4, total: 1)
)

/// `(message as any).content` when it is a string.
func contentString(_ message: AgentMessage) -> String? {
    switch message {
    case .user(let user):
        if case .string(let text) = user.content { return text }
        return nil
    case .custom(let custom):
        return custom.payload["content"]?.stringValue
    default:
        return nil
    }
}

/// `(message as any).content[0].text`.
func firstText(_ message: AgentMessage) -> String? {
    switch message {
    case .assistant(let assistant):
        for block in assistant.content { if case .text(let t) = block { return t.text } }
        return nil
    case .user(let user):
        if case .blocks(let blocks) = user.content, case .text(let t)? = blocks.first { return t.text }
        if case .string(let text) = user.content { return text }
        return nil
    case .toolResult(let result):
        if case .text(let t)? = result.content.first { return t.text }
        return nil
    default:
        return nil
    }
}

/// `(message as any).summary`.
func summaryOf(_ message: AgentMessage) -> String? {
    if case .custom(let custom) = message { return custom.payload["summary"]?.stringValue }
    return nil
}

/// The thrown error's message, or nil when `body` does not throw (`expect(...).toThrow(text)`).
func thrownMessage(_ body: () throws -> Void) -> String? {
    do {
        try body()
        return nil
    } catch {
        return errorMessage(error)
    }
}

func thrownMessage(_ body: () async throws -> Void) async -> String? {
    do {
        try await body()
        return nil
    } catch {
        return errorMessage(error)
    }
}

/// A fresh temp directory (`join(tmpdir(), name-Date.now())` + `mkdirSync`).
func makeTempDir(_ name: String) throws -> String {
    let dir = (NSTemporaryDirectory() as NSString).appendingPathComponent("\(name)-\(dateNow())-\(UUID().uuidString.prefix(8))")
    try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
    return dir
}

func removeDir(_ dir: String) {
    try? FileManager.default.removeItem(atPath: dir)
}

/// Collects values from `@Sendable` callbacks.
final class Collector<T: Sendable>: Sendable {
    private let state = Locked<[T]>([])
    init() {}
    func append(_ value: T) { state.withLock { $0.append(value) } }
    var values: [T] { state.withLock { $0 } }
}

/// `vi.waitFor`: retry `condition` until it holds or the timeout passes.
func waitUntil(timeoutMs: Int = 2000, _ condition: @Sendable () async throws -> Bool) async rethrows -> Bool {
    let deadline = dateNow() + timeoutMs
    while dateNow() < deadline {
        if try await condition() { return true }
        try? await Task.sleep(nanoseconds: 2_000_000)
    }
    return try await condition()
}
