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

- Return or Cmd-Return sends; Shift-Return inserts a newline and multiline text input remains native. Drafts can be prepared while the agent works.
- Scroll upward to inspect history; “Back to latest” restores following. Toggling the sidebar keeps the same session and draft.
- Tool rows summarize the action and filename, or the first command line. Details expand in place; raw arguments/results are secondary disclosures. Approval arguments stay visible; the decision applies to one call.
- Copy actions, native text selection, keyboard focus, accessibility labels and light/dark appearance are included.
- **More → Manage connections…** saves non-secret routing in `connections.json` and the API key in Keychain. The selected folder supplies the coding-tool working directory.
- The collapsible left sidebar lists and searches saved conversations for the selected workspace. New conversation preserves the previous JSONL file; quitting and reopening restores the last selection.
- `edit` and `write` show a bounded, colored diff before approval and preserve it with their tool result. Changes while approval is pending cause the operation to fail rather than overwrite the newer file.

## First release limits

No attachment upload, image message view, reference/question components, branch navigation or PiCodingAgent-specific compaction/retry presentation yet. Block Markdown is included: headings, paragraphs, nested/ordered/task lists, quotes, fenced/indented code, tables, separators and inline styles. Code blocks preserve source whitespace and offer a separate copy action. Long code and wide tables scroll within their blocks. Syntax coloring, math and footnotes are not implemented. VoiceOver and real Chinese IME composition require additional validation. The package's iOS platform declaration is inherited from the runtime and is not a claim that the complete UI/CLI works on iOS.

## Presentation

Pi Swift combines its title and actions in one native window toolbar with the current conversation title, sidebar toggle and More menu; scenarios, appearance and connection settings live in More. The sidebar background continues to the top window edge behind the traffic lights and navigation control. The conversation title begins at the main-column edge and opens Rename when clicked. Its boundary stays aligned with the sidebar when the window resizes, and disappears when the sidebar is collapsed. Conversation content starts 12 pt below the toolbar; the opaque native toolbar keeps scrolled text from showing behind its title and actions. User text sits in a trailing, content-sized bubble; assistant text uses an unboxed paragraph layout. Tool rows disclose details on demand. Copy is available on hover, through the context menu, and as an accessibility action. The composer uses a 14 pt corner radius, grows from one line to a 168 pt editor, then scrolls internally, and shows its Return-arrow send action only for nonblank text. Pi Swift places a 28 pt Add button at the bottom leading edge, aligned with the send/stop control, with approval policy and the model/settings control in a separate footer; approval arguments fit their content up to a scrollable 100 pt limit, and diff previews have a separate 180 pt limit. The sidebar defaults to 232 pt and can be dragged between 200 and 360 pt (further bounded in narrow windows); its width survives restarts, and double-clicking the boundary restores the default. It uses quiet selection and hover states, a new-conversation action and a bottom model/workspace entry. It refreshes after responses and on app activation so CLI-written sessions are discoverable. Cmd-N starts a conversation; Control-Cmd-S toggles the sidebar. Resizing the window keeps the composer and transcript usable in a narrow column.

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

Pi Swift does not automatically trust project `.pi` resources. Connections and working-directory choices are saved locally; conversation drafts are restored separately, while in-flight network requests are not resumed. Imported CLI sessions need a saved connection association (`pf --connection NAME --session PATH`) before Pi Swift can reopen them. See [HOST.md](HOST.md).


## Markdown rendering

`MarkdownMessage(source)` is also usable on its own. PiUI uses Swift Markdown 0.8.0 (cmark-gfm) for parsing, then renders native SwiftUI blocks; the coding runtime remains independent of the parser. User messages are literal text. Copy message returns the original Markdown; Copy code returns the parsed code, including indentation and trailing newlines.

Parsing runs off the main actor. Each visible message coalesces streaming deltas at a 60 ms cadence and updates once more with the newest source. Incomplete fenced code remains a code block. Cancelling a render prevents stale results from replacing a later message; completed replies are not reparsed when unrelated view state changes.

Only HTTP, HTTPS and mailto links are interactive. Images display their alternative text, and raw HTML is shown literally; rendering a reply does not fetch images or execute HTML. Tables honor column alignment and scroll horizontally in a narrow companion layout. **More → Scenarios → Rich Markdown** provides a deterministic streaming fixture for all these blocks.


`ComposerContext` lets a host supply the model label, approval label, settings action and text-file insertion action. Pi Swift's Add menu inserts UTF-8 file text (up to 128 KiB) into the draft; it does not upload an attachment or submit a message. The draft stays editable during generation. The Add popover closes with Escape and returns focus to the editor; inserting a file preserves the existing draft. Native selection, undo, multiline paste and internal scrolling are supported. The model footer opens a quick menu of saved connections, with a checkmark for the active model and a separate Manage connections action. Hosts supply choices through `ComposerContext.modelChoices`. Switching changes subsequent requests while keeping the current transcript, draft and session file; the active file lease remains held and credentials follow the selected connection. The model control is disabled while a request is running, and permissions remain explicit per tool call. Empty input has no send button; On macOS, Return (or Cmd-Return) sends nonblank input; Shift-Return and Option-Return insert a newline. Return confirms marked IME text without sending. Held Return does not repeat submission. During generation, Return leaves the next draft untouched.

### Detail polish

The composer keeps a 12 pt gap from the transcript and a smaller 11 pt metadata footer. Long model names truncate in the middle, with the full name available in the tooltip; the permission label stays readable. Back to latest is a quiet 30 pt circular overlay. Code uses a 13 pt monospaced face, a tighter header and a stable-width copy action. Sidebar actions share hover/pressed/selection treatment; search has a subtle focus border and Escape clears and leaves the field.


### Icons

`ChatSymbol` and `ChatIcon` provide the shared action vocabulary. Navigation and composer icons use regular monochrome 16–18 pt symbols; copy and tool status use 13–14 pt, disclosure arrows 10 pt. Hit areas remain larger than the glyphs. New conversation uses a plus on a quiet circular background; Send uses a Return arrow; Copy uses overlapping squares; settings uses a gear; More uses vertical dots. The dots are a small template image on macOS because native menu buttons discard SwiftUI rotation modifiers. Running tools use a native progress indicator, with separate approval, failed, stopped and completed states. Decorative icons are hidden from accessibility; buttons retain their action labels.


### Session details

The right-hand inspector contains collapsible Environment, Usage, Tools and Changes cards. Environment shows the workspace and run state; the model stays in the composer, and Reveal saved session lives in More. Usage shows the latest reported input count (including cache) and expands to cumulative input/output/cache counts. These are reported usage values, not context capacity. Missing usage stays unavailable. Streaming snapshots replace their response's usage, and persisted branches restore the same totals.

Tools starts collapsed, lists available tools and the most recent five calls, and offers Show all. Call rows disclose bounded raw arguments/results without repeating the diff. Changes shows one row per recorded tool edit with the filename and added/removed line counts. Selecting a row opens an independent, resizable diff window with old/new line numbers, colored lines, wrapping enabled by default, optional horizontal scrolling, previous/next hunk navigation, a recorded-edit picker, Copy diff and Escape/Close. The same reader opens from transcript tool rows. The conversation remains editable while the reader is open; changing conversations closes the reader to avoid stale context. Recorded edits are not a Git working-tree or PR view, and repeated edits are not aggregated into a file total.

Use the top-right sidebar button or Option-Command-I to toggle details. At widths of at least 1080 pt with navigation visible (848 pt without it), the 288 pt inspector sits beside the conversation. Smaller windows use a dismissible 300 pt popover. Card expansion is shared between inline and popover presentations.

### Conversation management

Each sidebar row has a More menu and a context menu for Rename, Pin/Unpin and Archive/Restore. Pinned conversations sort first. The list options menu switches between active and archived conversations; search applies within the selected list. Renaming updates the native toolbar title and appends upstream-compatible session metadata. Active sessions rename through their owning host; inactive renames respect the session lock.

Pin/archive state lives in `conversation-library.json` under the host agent directory. Archiving never moves or deletes the JSONL transcript. Archiving the current conversation opens a new one and retains the unsent draft; restoring returns the original transcript to the normal list. Organization is local to the desktop host and does not hide sessions from `pf`. Drafts are saved separately from the model transcript, keyed by session file. Editing autosaves after 400 ms of inactivity; switching conversations and quitting flush immediately. Sending or clearing input removes its saved draft. Restart restores the selected conversation and its draft, including the current new conversation before its first message. Unsent drafts remain accessible in the sidebar before a transcript exists; empty conversations without a draft are not retained. Cursor selection and transcript scroll position are not restored. Save failures are shown, and quitting is cancelled if the final save fails. Offline demonstration drafts are not persisted.

### Draft recovery, search and remembered layout

The sidebar includes unsent drafts even when no transcript has been written yet. Selecting one restores its text and saved connection without sending it; older sidecars without connection metadata use the current connection. Suggestions and text-file insertion append to existing text. Programmatic edits participate in the native Edit → Undo/Redo history, which is cleared when switching conversations. New conversation focuses the composer, including when the sidebar is hidden.

After a failed request, Edit last message prepares an editable draft; if a draft already exists, Add last message to draft appends instead. Manage connections is available alongside the error. These controls do not replay tools, remove the failed turn, or submit automatically. The user reviews and sends a new message explicitly.

Sidebar search matches titles and user/assistant transcript text, displays a contextual excerpt, and also finds unsent drafts. Opening a result highlights matching messages in the current branch and provides previous/next navigation. A match from another recorded branch can produce “No text matches in this branch”; this UI does not change branches automatically. Appearance and left/right sidebar visibility are remembered across launches; the compact inspector stays a temporary popover.

### Transcript space and reply continuity

The transcript lays out visible events as a continuous assistant reply until the next user message. Empty streaming placeholders take no space. Consecutive tool steps have a 4 pt gap, other assistant continuations 12 pt, user-to-assistant transitions 24 pt, and a new user turn 32 pt. Event IDs and tool order are preserved, so search anchors and expanded details still refer to the original messages; the runtime transcript is not merged.

Intermediate assistant fragments have no hidden action shelf. Their original text remains available through the context menu and accessibility Copy action. The reply's final text message has a stable 24 pt hover/focus copy shelf after generation finishes. User Copy appears below its bubble without adding row height. User bubbles fit their content up to 85% of the reading column. The default column is 816 pt including gutters (768 pt of content at full width), shared by transcript and composer; gutters shrink from 24 to 16 pt below a 560 pt main-column width. The transcript's bottom inset is 16 pt. The composer stays outside the transcript scroll view and grows independently.

These choices were checked against locally installed Claude Desktop 4.29.0's bundled design-system CSS and native Code interface. The bundle exposes message and composer primitives, including the 85% bubble measure; it does not contain the complete remotely loaded conversation implementation. The Swift turn-spacing rules above are PiUI's implementation, not copied proprietary code or a claim of exact source parity.
