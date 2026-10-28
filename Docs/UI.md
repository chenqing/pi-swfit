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
ConversationView(session: session, brandIcon: Image("YourAppIcon"))
    .chatTheme(ChatTheme(accent: .teal, contentWidth: 680))

// Replace the complete message renderer when you need custom Markdown,
// citations, attachments, domain-specific tool results or rich artifacts.
ConversationView(session: session) { message in
    YourMessageView(message: message)
}
```

`MessageView`, `ToolCallView`, `ApprovalView`, `Composer`, `ChatButtonStyle` and `ChatTheme` are public. `session.displayedMessages` projects waiting approvals onto tool status without changing the agent's event order. Runtime events, provider signatures and opaque reasoning payloads are not reconstructed from UI text.

## Interaction

- Cmd-Return sends; multiline text input remains native. Drafts can be prepared while the agent works.
- Scroll upward to inspect history; “Back to latest” restores following. Toggling the sidebar keeps the same session and draft.
- Tool details expand in place. Approval arguments stay visible; the decision applies to one call.
- Copy actions, native text selection, keyboard focus, accessibility labels and light/dark appearance are included.
- **More → Model & workspace** saves non-secret routing in `connections.json` and the API key in Keychain. The selected folder supplies the coding-tool working directory.
- The collapsible left sidebar lists and searches saved conversations for the selected workspace. New conversation preserves the previous JSONL file; quitting and reopening restores the last selection.
- `edit` and `write` show a bounded, colored diff before approval and preserve it with their tool result. Changes while approval is pending cause the operation to fail rather than overwrite the newer file.

## First release limits

No attachment upload, image message view, reference/question components, branch navigation or PiCodingAgent-specific compaction/retry presentation yet. Block Markdown is included: headings, paragraphs, nested/ordered/task lists, quotes, fenced/indented code, tables, separators and inline styles. Code blocks preserve source whitespace and offer a separate copy action. Long code and wide tables scroll within their blocks. Syntax coloring, math and footnotes are not implemented. VoiceOver and real Chinese IME composition require additional validation. The package's iOS platform declaration is inherited from the runtime and is not a claim that the complete UI/CLI works on iOS.

## Presentation

Pi Swift combines its title and actions in one native window toolbar with a text-only title, sidebar toggle and More menu; scenarios, appearance and model settings live in More. Conversation content starts 12 pt below the toolbar; the opaque native toolbar keeps scrolled text from showing behind its title and actions. User text sits in a trailing, content-sized bubble; assistant text uses an unboxed paragraph layout. Tool rows disclose details on demand. Copy is available on hover, through the context menu, and as an accessibility action. The composer uses a 14 pt corner radius, grows from one to eight lines, and shows its circular send action only for nonblank text. Pi Swift places an Add menu inside the leading edge, with approval policy and the model/settings control in a separate footer; approval arguments fit their content up to a scrollable 100 pt limit, and diff previews have a separate 180 pt limit. The 232 pt sidebar uses quiet selection and hover states, a new-conversation action and a bottom model/workspace entry. It refreshes after responses and on app activation so CLI-written sessions are discoverable. Cmd-N starts a conversation; Control-Cmd-S toggles the sidebar. Resizing the window keeps the composer and transcript usable in a narrow column.

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

Pi Swift does not automatically trust project `.pi` resources. Connections and working-directory choices are saved locally; conversation drafts and in-flight network requests are not resumed. Imported CLI sessions need a saved connection association (`pf --connection NAME --session PATH`) before Pi Swift can reopen them. See [HOST.md](HOST.md).


## Markdown rendering

`MarkdownMessage(source)` is also usable on its own. PiUI uses Swift Markdown 0.8.0 (cmark-gfm) for parsing, then renders native SwiftUI blocks; the coding runtime remains independent of the parser. User messages are literal text. Copy message returns the original Markdown; Copy code returns the parsed code, including indentation and trailing newlines.

Parsing runs off the main actor. Each visible message coalesces streaming deltas at a 60 ms cadence and updates once more with the newest source. Incomplete fenced code remains a code block. Cancelling a render prevents stale results from replacing a later message; completed replies are not reparsed when unrelated view state changes.

Only HTTP, HTTPS and mailto links are interactive. Images display their alternative text, and raw HTML is shown literally; rendering a reply does not fetch images or execute HTML. Tables honor column alignment and scroll horizontally in a narrow companion layout. **More → Scenarios → Rich Markdown** provides a deterministic streaming fixture for all these blocks.


`ComposerContext` lets a host supply the model label, approval label, settings action and text-file insertion action. Pi Swift's Add menu inserts UTF-8 file text (up to 128 KiB) into the draft; it does not upload an attachment or submit a message. The draft stays editable during generation. The model control is disabled while a request is running, and permissions remain explicit per tool call. Empty input has no send button; Cmd-Return sends nonblank input and Return inserts a newline.
