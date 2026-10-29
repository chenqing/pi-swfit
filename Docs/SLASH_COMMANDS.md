# Native slash commands

## Delivery plan

1. Share command names, parsing, argument validation and descriptions in PiHost. Keep runtime/session formats unchanged.
2. Add a native desktop command list above the composer, keyboard selection, and modal model/session pickers. Route management commands before ChatSession.send so they do not become transcript messages. Preserve command input on cancellation/failure.
3. Add equivalent line-oriented pf commands, using saved connections and leased session hosts. Keep non-interactive prompts unchanged.
4. Test parser, draft/error behavior, real session persistence and CLI interaction; inspect native light/dark layouts and keyboard behavior.

This delivery covers `/new`, `/resume`, `/name`, `/model`, `/settings`, `/compact`, `/session`, `/copy`, and native `/help`. pf also keeps `/quit` and `/exit`. Model selection uses saved connections, not upstream catalog discovery. Desktop settings opens the existing connection sheet; pf shows its current configuration and configuration paths.

Next phases: `/thinking`, `/tree`, `/fork`, then skills/templates/extensions and dynamic resource completion. These are not advertised as implemented. Upstream reference: [builtin definitions](https://github.com/earendil-works/pi/blob/main/packages/coding-agent/src/core/slash-commands.ts), reviewed 2026-10-29. `/help` and `/exit` are native conveniences.

Commands execute only while idle. `/compact [instructions]` invokes the existing model-backed compaction flow and may incur provider usage. Read-only info, copy, selection and rename commands do not submit prompts. Unknown single-slash command names fail locally. Absolute paths containing a second slash remain ordinary prompt text. Existing `/skill:name` inputs still pass to the runtime skill expander; discovery/completion is deferred. Command arguments are plain text, not shell syntax; no quote parsing or shell execution occurs.
