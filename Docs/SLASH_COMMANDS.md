# Native slash commands

## Delivery plan

1. Share command names, parsing, argument validation and descriptions in PiHost. Keep runtime/session formats unchanged.
2. Add a native desktop command list above the composer, keyboard selection, and modal model/session pickers. Route management commands before ChatSession.send so they do not become transcript messages. Preserve command input on cancellation/failure.
3. Add equivalent line-oriented pf commands, using saved connections and leased session hosts. Keep non-interactive prompts unchanged.
4. Test parser, draft/error behavior, real session persistence and CLI interaction; inspect native light/dark layouts and keyboard behavior.

This delivery covers `/new`, `/resume`, `/name`, `/model`, `/settings`, `/compact`, `/session`, `/copy`, and native `/help`. pf also keeps `/quit` and `/exit`. Model selection uses saved connections, not upstream catalog discovery. Desktop settings opens the existing connection sheet; pf shows its current configuration and configuration paths.

Deferred: skills/templates/extensions and dynamic resource completion. These are not advertised as implemented. Upstream reference: [builtin definitions](https://github.com/earendil-works/pi/blob/main/packages/coding-agent/src/core/slash-commands.ts), reviewed 2026-10-29. `/help` and `/exit` are native conveniences.

Commands execute only while idle. `/compact [instructions]` invokes the existing model-backed compaction flow and may incur provider usage. Read-only info, copy, selection and rename commands do not submit prompts. Unknown single-slash command names fail locally. Absolute paths containing a second slash remain ordinary prompt text. Existing `/skill:name` inputs still pass to the runtime skill expander; discovery/completion is deferred. Command arguments are plain text, not shell syntax; no quote parsing or shell execution occurs.

## Phase 2: thinking and session navigation

Reference: upstream [`e65b3b88c08412bb8ffbd21fb5dc5756064a6e5a`](https://github.com/earendil-works/pi/tree/e65b3b88c08412bb8ffbd21fb5dc5756064a6e5a), reviewed 2026-10-29. Sources: `core/agent-session.ts` (`setThinkingLevel`, `navigateTree`, `getUserMessagesForForking`), `core/agent-session-runtime.ts` (`fork`), and `modes/interactive/interactive-mode.ts`.

| Command | Desktop and pf behavior |
| --- | --- |
| `/thinking [level]` | Choose a supported level, or set it directly. Invalid/unsupported input fails locally. Changed levels append upstream `thinking_level_change` entries and reach provider stream options. Reopening restores the branch's recorded level; explicit `pf --thinking` overrides it. |
| `/tree` | Browse the full entry tree, including abandoned branches. The current leaf is a no-op. Selecting a user/custom message moves before it and restores its text; other entries continue after the selected entry. No messages are deleted or sent by selection. |
| `/fork` | Choose any previous user message, including one on another branch. Create a new session with the selected message's ancestors and `parentSession` linkage; restore the selected text for editing. The source transcript and its file lease are not mutated. Empty first-message forks remain drafts until the first send. |

Desktop selectors provide search, branch indentation, current-position markers and explicit navigation confirmation. `/tree` optionally summarizes the abandoned branch with the current model, with optional instructions and cancellation. pf uses numbered choices; empty input cancels. Its system libedit input supports editing the restored text, including Unicode, before Enter sends it. No command history is saved to disk.

Drafts remain outside JSONL. Desktop drafts also record their branch position, including the root position, so restarting with an unsent tree draft restores the intended context. Navigation alone uses upstream's in-memory leaf semantics; a subsequent entry makes that branch durable in JSONL. Existing branches remain selectable. Text-only restoration does not silently resend image attachments.

Thinking capabilities come from an exact model-catalog match or a saved connection's explicit `thinkingLevels` list. Unknown custom models default to `off`; configure supported levels in the connection sheet or `connections.json`. Do not assume every endpoint supports `xhigh` or `max`. Optional capability fields do not change credential scope and old profiles remain readable.

Native boundaries: commands require an idle host. Tree navigation keeps the current model and thinking level, matching upstream; a reopened/forked session restores its recorded level under the current connection's capabilities. Model selection remains based on saved connections. The upstream thinking selector's global-default shortcut, tree labels/filter shortcuts and specialized TypeScript `session_before_tree`/`session_before_fork` extension hooks are not ported. The native runtime uses its existing session lifecycle hook for tree navigation. This is not a full upstream TUI or extension-runtime compatibility claim.

Validation includes host/desktop adapter tests for restore, branching, fork isolation, drafts and failed writes; `scripts/smoke-slash-navigation.py` exercises the actual pf PTY, editable prefill, local validation and resulting JSONL trees.
