# Native slash commands

## Delivery plan

1. Share command names, parsing, argument validation and descriptions in PiHost. Keep runtime/session formats unchanged.
2. Add a native desktop command list above the composer, keyboard selection, and modal model/session pickers. Route management commands before ChatSession.send so they do not become transcript messages. Preserve command input on cancellation/failure.
3. Add equivalent line-oriented pf commands, using saved connections and leased session hosts. Keep non-interactive prompts unchanged.
4. Test parser, draft/error behavior, real session persistence and CLI interaction; inspect native light/dark layouts and keyboard behavior.

This delivery covers `/new`, `/resume`, `/name`, `/model`, `/settings`, `/compact`, `/session`, `/copy`, and native `/help`. pf also keeps `/quit` and `/exit`. Model selection uses saved connections, not upstream catalog discovery. Desktop `/settings` opens the standard macOS Settings window (General and Connections); pf shows its current configuration and configuration paths.

Skills/templates/native-extension commands and dynamic completion are covered in Phase 3 below. Upstream reference: [builtin definitions](https://github.com/earendil-works/pi/blob/main/packages/coding-agent/src/core/slash-commands.ts), reviewed 2026-10-29. `/help` and `/exit` are native conveniences.

Commands execute only while idle. `/compact [instructions]` invokes the existing model-backed compaction flow and may incur provider usage. Read-only info, copy, selection and rename commands do not submit prompts. Unknown single-slash command names fail locally. Absolute paths containing a second slash remain ordinary prompt text. Builtin command arguments remain plain text. Template arguments use the quoting/substitution rules described below; no shell evaluation occurs.

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

## Phase 3: resource commands

Reference: upstream [`aee933269ba79b84e7b7454097c1d4c426021d82`](https://github.com/earendil-works/pi/tree/aee933269ba79b84e7b7454097c1d4c426021d82), reviewed 2026-10-29: `core/prompt-templates.ts`, `core/resource-loader.ts`, `core/agent-session.ts`, `core/extensions/runner.ts` and interactive completion.

Desktop and pf share a live catalog for `/help`, completion and routing. Desktop shows the resource type and path tooltip; pf completes a leading command token with Tab or lists multiple matches without submitting. Builtins take precedence, then native extensions, then prompt templates. Commands remain idle-only. Reloading does not create a conversation or clear drafts.

| Surface | Behavior |
| --- | --- |
| `/skill:name [instructions]` | Loads the skill's current SKILL.md and wraps it with its name, location and reference directory before appending instructions. `disable-model-invocation` excludes automatic model discovery but retains explicit invocation. `enableSkillCommands: false` hides completion, not explicit execution. |
| `/template-name [args]` | A direct `.md` child of a prompts directory becomes a command named after the file. YAML `description` and `argument-hint` feed the menu. Expanded content becomes the model/transcript input. |
| Extension commands | Host-supplied Swift callbacks execute before input hooks, skill expansion and template expansion. Handled commands produce no provider request or synthetic user message; failures remain editable. Duplicate names across extensions become `name:1`, `name:2` in registration order. |
| `/reload` | Reloads settings, skills and templates, refreshes the catalog and skill system-prompt section, and invokes existing native `resourcesReloaded` callbacks. Reports resource diagnostics. |

Template arguments support single/double quotes (including empty quoted values), `$1`, `$2`, `$@`, `$ARGUMENTS`, `${1:-default}`, `${@:-default}`, `${ARGUMENTS:-default}`, `${@:2}` and `${@:2:3}`. Slices are one-based (`0` also starts at the first argument); omitted values become empty unless a default is supplied. Substitution is a single pass: dollar patterns in supplied values/defaults stay literal. Backslashes do not implement shell escapes. Unknown templates remain literal at the runtime API; the interactive hosts reject unknown command names locally.

Example at `~/.pf/agent/prompts/review.md`:

```markdown
---
description: Review a file
argument-hint: file [focus]
---
Review $1, focusing on ${2:-correctness}.
```

`/review "Sources/My File.swift"` expands to `Review Sources/My File.swift, focusing on correctness.`

The host agent directory defaults to `~/.pf/agent`, overridable with `PF_AGENT_DIR`. Global skills/templates load automatically. Project `.pi/skills`, `.pi/prompts`, `.pi/settings.json` and ancestor `.agents/skills` require explicit workspace trust. Desktop exposes this under Model & workspace; its canonical-folder choice is stored in `trusted-workspaces.json`, shared with pf. `pf --trust-project` enables it for that invocation only. Changing saved trust applies when opening the workspace again; `/reload` does not escalate an existing host's trust. Tool approval modes remain separate.

The local loader evaluates configured global paths, trusted configured project paths, trusted project auto-discovery, then global auto-discovery; first name wins and collisions are reported. The `skills`/`prompts` settings arrays support local paths and the existing inclusion/exclusion rules. Templates are nonrecursive; regular-file symlinks are followed. Installed package resources are not resolved by this native loader.

Native extension injection uses existing Swift types rather than interpreting JavaScript:

```swift
let commands = NativeExtension(id: "example", commands: [
    ExtensionCommand(name: "hello", description: "Local callback") { arguments, context in
        print("Hello \(arguments) from \(context.cwd)")
    }
])
// Desktop embedding:
let chat = try await ChatSession.openCoding(cwd: cwd, profile: profile, store: store,
                                           extensions: [commands])
// Custom pf entry point:
let status = await PFCLI.run(Array(CommandLine.arguments.dropFirst()), extensions: [commands])
```

The distributed app/pf do not scan for Swift or TypeScript executable extensions. TS/npm installation, extension argument-completion callbacks, upstream custom TUI widgets, themes and keybinding reload are not implemented. Native command names are ASCII letters/digits/underscore/hyphen; duplicates within one extension remain invalid. Existing native queued-input hooks are unchanged and are not a claim of parity with upstream steer/follow-up restrictions. `expandPromptTemplates: false` suppresses extension dispatch and resource expansion while retaining input hooks. The SDK retains its literal-input fallback and `drainSkillErrors()` diagnostic API by default. Desktop and interactive pf opt into `PromptOptions.strictSkillCommands`: missing or unreadable skills fail before creating a turn or calling a provider, with the original command retained for editing. This is a native host adaptation; noninteractive pf and default SDK callers retain existing behavior.

Validation: `scripts/smoke-slash-resources.py` exercises actual pf input and persisted expanded messages. Unit tests cover substitution boundaries, resource trust/reload, collisions, callbacks, disabled model invocation, no-message dispatch and desktop draft recovery.

## Native feedback and recovery

Desktop and interactive pf distinguish success, no-op, cancellation and failure. Short/already compacted contexts and empty `/copy` are informational; selectors explain empty results, and current tree/model/session selections report no change. pf restores failed/cancelled command input; desktop retains failed input and restores it on cancelled operations. Failed branch summaries leave the branch unchanged and set the operation state to failed. Desktop command errors appear beside the composer, with expandable details and dismissal, and are cleared by the next command. Runtime compaction retention settings and session formats are unchanged.
