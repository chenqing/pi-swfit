import Foundation
import PiAI
import PiAgent

public enum DemoScenario: String, CaseIterable, Sendable {
    case tool, failure, longReply, markdown
    public var title: String {
        switch self {
        case .tool: "Tool approval"
        case .failure: "Connection failure"
        case .longReply: "Long streaming reply"
        case .markdown: "Rich Markdown"
        }
    }
}

/// Deterministic, offline fixture. It uses the real Agent loop and tool authorization pipeline.
@MainActor
public func makeDemoSession(scenario: DemoScenario = .tool) throws -> ChatSession {
    let model = Model(id: "offline-demo", name: "Offline demo", api: "openai-responses", provider: "demo", baseUrl: "https://example.invalid")
    let tool = AgentTool(name: "read_example", label: "Read example", description: "Read a bundled example. No files or network are accessed.",
                         parameters: .object(["type": "object", "properties": .object([:])])) { _, _, signal, _ in
        for _ in 0..<8 { try signal?.throwIfAborted(); try await Task.sleep(for: .milliseconds(100)) }
        return AgentToolResult(content: [.text(TextContent(text: "PiAI → PiAgent → PiChat → PiUI. Each layer can be used independently."))])
    }
    let stream: StreamFn = { _, context, options in
        let output = createAssistantMessageEventStream()
        Task {
            var message = AssistantMessage(api: model.api, provider: model.provider, model: model.id)
            do {
                try options?.signal?.throwIfAborted()
                output.push(.start(partial: message))
                if scenario == .failure { throw PiError("Demo connection failed. Your message and partial response stay in the conversation.") }
                let hasResult = context.messages.last?.role == "toolResult"
                let words: String
                if scenario == .markdown {
                    words = markdownExample
                } else if scenario == .longReply {
                    words = Array(repeating: "Streaming stays readable. Scroll upward to explore earlier messages, or stop to keep what has already arrived. ", count: 18).joined()
                } else if hasResult {
                    words = "A small stack, ready for your app.\n\n**PiAI** connects models. **PiAgent** runs tools. **PiChat** owns conversation state. **PiUI** gives it a native interface.\n\nYou can replace each piece as your product grows."
                } else {
                    words = "Let's look at the example architecture. I'll ask before running the tool."
                }
                var accumulated = ""
                for character in words {
                    try options?.signal?.throwIfAborted()
                    try await Task.sleep(for: .milliseconds(scenario == .markdown ? 2 : scenario == .longReply ? 8 : 14))
                    accumulated.append(character)
                    message.content = [.text(TextContent(text: accumulated))]
                    output.push(.textDelta(contentIndex: 0, delta: String(character), partial: message))
                }
                if scenario == .tool && !hasResult {
                    message.content.append(.toolCall(ToolCall(id: UUID().uuidString, name: "read_example", arguments: [:])))
                    message.stopReason = .toolUse
                }
                output.push(.done(reason: message.stopReason, message: message))
            } catch {
                message.stopReason = options?.signal?.aborted == true ? .aborted : .error
                message.errorMessage = String(describing: error)
                output.push(.error(reason: message.stopReason, error: message))
            }
        }
        return output
    }
    return try ChatSession(options: AgentOptions(initialState: AgentInitialState(systemPrompt: "You are a helpful assistant.", model: model, tools: [tool]), streamFn: stream))
}


private let markdownExample = """
## A conversation with structure

Keep the explanation readable, and the code ready to use. **Strong ideas**, *small details*, and `inline code` each have their place.

```swift
import PiUI

ConversationView(session: session)
    .chatTheme(ChatTheme(accent: .teal))
```

### A small, deliberate checklist

- [x] Keep your conversation when you restart.
- [x] Review file changes before approving them.
- [ ] Connect a model of your choice.

> 好的界面让内容成为主角。
>
> A quiet interface leaves room for the work.

3. Read the relevant files.
4. Review the proposed change.
   - Inspect the diff.
   - Keep the original conversation.
5. Continue in `pf` or Playground.

| Layer | Responsibility | Surface |
| :--- | :--- | ---: |
| PiAI | Model connections | Shared |
| PiChat | Conversation state | Native |
| PiUI | A focused interface | macOS |

---

Read the [project documentation](https://github.com/chenqing/pi-swfit) when you want to build your own host. ~~One fixed layout~~ — a conversation that fits your app.
"""
