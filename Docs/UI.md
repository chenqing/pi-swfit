# Native UI

The v0.1 UI targets macOS 14+. `PiChat` is a presentation adapter around `PiAgent` or a persistent `PiCodingAgent.AgentSession`; runtime messages remain owned by the agent. UI state is updated on the main actor, and all tool approvals go through `beforeToolCall`.

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
- **More → Model & workspace** saves non-secret routing in `connections.json` and the API key in Keychain. The selected folder supplies the coding-tool working directory.
- **More → Resume conversation** lists saved conversations for that workspace. New conversation preserves the previous JSONL file; quitting and reopening restores the last selection.
- `edit` and `write` show a bounded, colored diff before approval and preserve it with their tool result. Changes while approval is pending cause the operation to fail rather than overwrite the newer file.

## First release limits

No attachment upload, image message view, reference/question components, branch navigation or PiCodingAgent-specific compaction/retry presentation yet. Inline Markdown is supported; full block Markdown is a renderer extension point. VoiceOver and real Chinese IME composition require additional validation. The package's iOS platform declaration is inherited from the runtime and is not a claim that the complete UI/CLI works on iOS.

## Presentation

The Playground combines its title and actions in one native window toolbar with a single-line title and three actions; scenarios, appearance and model settings live in More. Conversation content starts 12 pt below the toolbar. User text sits in a trailing, content-sized bubble; assistant text uses an unboxed paragraph layout. Tool rows disclose details on demand. Copy is available on hover, through the context menu, and as an accessibility action. The composer starts at one line and expands up to eight; approval arguments fit their content up to a scrollable 100 pt limit, and diff previews have a separate 180 pt limit. The same session can switch between full-width and 440 pt companion layouts.

## Persistent coding session

```swift
import PiHost
import PiChat

// MainActor; `profile` is a ConnectionProfile chosen by your application.
let store = ConnectionStore() // ~/.pf/agent and the login Keychain
let chat = try await ChatSession.openCoding(
    cwd: projectDirectory,
    profile: profile,
    store: store,
    sessionFile: existingSessionPath // nil starts a new conversation
)
// Call when releasing the session, before another host opens the same file.
await chat.shutdown()
```

The session owns persistence and the original model transcript. Restoration projects user/assistant text and tool results into UI rows; it does not resubmit old tool calls. Every coding tool asks for approval, including reads and shell commands. The selected workspace is a working directory, not a sandbox: absolute paths and bash can reach outside it.

The Playground does not automatically trust project `.pi` resources. Connections and working-directory choices are saved locally; conversation drafts and in-flight network requests are not resumed. Imported CLI sessions need a saved connection association (`pf --connection NAME --session PATH`) before the Playground can reopen them. See [HOST.md](HOST.md).
