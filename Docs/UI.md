# Native UI

The v0.1 UI targets macOS 14+. `PiChat` is a presentation adapter around `PiAgent`; runtime messages remain owned by the agent. UI state is updated on the main actor, and all tool approvals go through `beforeToolCall`.

## Create a live session

```swift
import PiAI
import PiAgent
import PiChat

// On MainActor. Supply credentials through your host's Keychain/service.
let session = try ChatSession(options: AgentOptions(
    initialState: AgentInitialState(
        systemPrompt: "You are a helpful assistant.",
        model: model,
        tools: tools
    ),
    getApiKey: { provider in await credentials.key(for: provider) }
))
```

`model`, `tools` and `credentials` above are host-owned values. They are not globals supplied by this package.

Every tool requires a per-call decision by default. An existing host `beforeToolCall` denial is preserved. `.handledByHost` disables the UI gate only when the host supplies its own authorization. Declining an approval does not execute the tool. Stopping clears pending approvals, retains partial text, and does not replay tools or roll back completed external effects.

## Compose

```swift
ConversationView(session: session)
    .chatTheme(ChatTheme(accent: .teal, contentWidth: 680))

// Replace the complete message renderer when you need block Markdown,
// citations, attachments, domain-specific tool results or rich artifacts.
ConversationView(session: session) { message in
    YourMessageView(message: message)
}
```

`MessageView`, `ToolCallView`, `ApprovalView`, `Composer`, `ChatButtonStyle` and `ChatTheme` are public. `session.displayedMessages` projects waiting approvals onto tool status without changing the agent's event order. Runtime events, provider signatures and opaque reasoning payloads are not reconstructed from UI text.

## Interaction

- Cmd-Return sends; multiline text input remains native. Drafts can be prepared while the agent works.
- Scroll upward to inspect history; “Back to latest” restores following. Switching demo layout keeps the same session.
- Tool details expand in place. Approval arguments stay visible; the decision applies to one call.
- Copy actions, native text selection, keyboard focus, accessibility labels and light/dark appearance are included.
- The Playground connection sheet keeps its API key in memory only. It does not persist settings or credentials.

## First release limits

No attachment upload, image message view, reference/question components, persisted UI history, branches or PiCodingAgent-specific compaction/retry presentation yet. Inline Markdown is supported; full block Markdown is a renderer extension point. VoiceOver and real Chinese IME composition require additional validation. The package's iOS platform declaration is inherited from the runtime and is not a claim that the complete UI/CLI works on iOS.

## Presentation

The Playground combines its title and actions in one native window toolbar with a single-line title and three actions; scenarios, appearance and model settings live in More. Conversation content starts 12 pt below the toolbar. User text sits in a trailing, content-sized bubble; assistant text uses an unboxed paragraph layout. Tool rows disclose details on demand. Copy is available on hover, through the context menu, and as an accessibility action. The composer starts at one line and expands up to eight; approval arguments fit their content up to a scrollable 100 pt limit. The same session can switch between full-width and 440 pt companion layouts.
