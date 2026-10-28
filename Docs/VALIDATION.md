# Validation — 2026-10-28

Environment: Apple Silicon macOS, Apple Swift 6.4, deployment target macOS 14. This is evidence for the standalone source, not a claim that all declared platforms or providers were tested.

- `swift test --no-parallel`: all eight targets passed. The runner reports 1,125 tests across PiAI (734), PiAgent (76), PiCodingAgent (267), PiMCP (23), PiChat (8), PiCLI (5), PiHost (6), PiUI (6). The real codemode sandbox fixture is conditionally skipped when `PI_CODEMODE_HELPER` is unset; no sandbox execution is claimed here. The opt-in Keychain test is skipped by default and was run separately on this Mac using a disposable credential.
- `scripts/smoke-cli.py`: version, unsupported flags, stdin, no-session mode, disk session continuation, saved connection selection, JSONL event shape, failure exit status and a loopback OpenAI-compatible SSE → read tool → final response passed.
- Release `pf` build and offline execution verified locally.
- Pi Swift native checks: empty state, Cmd-Return submission, tool approval and rejection, expandable tool detail, stopping with partial text retained, compact layout, light/dark appearance, model configuration sheet, manual scrolling and return-to-latest. Scroll observation uses native NSScrollView metrics so offscreen SwiftUI content does not reset follow state.
- Presentation refinement: unified native toolbar, 12 pt transcript top inset, trailing user bubbles, paragraph spacing, compact expandable tool rows, one-line growing composer, compact/dark layouts and full-screen transition inspected in the native Pi Swift.
- Scoped source export inspected for private credential patterns and personal absolute paths; no matches in exported source. Build caches, local sessions and Pagie application data are excluded.

- Shared-host tests: approved edit and persisted diff, restoration without duplicate user turns, session lock/release, refusal after an intervening file edit, declined writes, cancellation while approval is pending, new-session preservation, canonical folder aliases, secret-free configuration/transcripts, and destination-bound credential lookup.
- Native acceptance used a loopback OpenAI-compatible SSE server and a temporary workspace: save a connection in Keychain → read approval → edit diff preview → approve actual file change → quit/reopen with restored tool results → `pf --continue` using the saved Keychain credential → reopen Pi Swift with the CLI turn restored. Selecting an older session from the native history sheet also restored its messages and tool results. The fixture confirmed authenticated requests and retained earlier tool results in the second user turn. This was not a paid model call.
- Keychain executable authorization was completed by the user in the macOS system prompt. No broad Keychain access lists or security settings were changed. Noninteractive CLI authorization failure returns promptly; interactive `pf` successfully continued after authorization.

- Native Markdown acceptance: headings, inline styles, Chinese block quotes, ordered/nested/task lists, table alignment and horizontal scrolling in the 440 pt companion layout, code-copy round trip with blank lines and indentation, light/dark appearance, and opaque toolbar while scrolling. These checks used a separate preview bundle and offline streaming fixture, preserving the existing live connection and conversation.
- Markdown unit tests cover incomplete fences, indented code, nested list numbering, tables, literal HTML/image descriptions, link scheme filtering, streaming convergence and cancellation. The parser runs off the main actor and coalesces updates; no performance benchmark or syntax-coloring support is claimed.
- Release Pi Swift build with the Markdown dependency passed locally.

- Branding: the app/product is Pi Swift/PiSwift; the editable flat SVG and 1024 px PNG feed the ICNS packaging script. The Celadon palette was checked in light/dark native windows, with a text-only title and the icon reserved for Dock/empty state. README images contain only local demonstration content. Existing host storage names are preserved for continuity.

- Composer layout follows the locally inspected Claude Desktop Code input structure, implemented independently in SwiftUI: 14 pt corners, leading Add action, conditional circular send/stop, and a separate policy/model footer. Native checks cover empty input, multiline drafts, text-file insertion, model settings, send/stop, and light/dark compact layouts.

- Sidebar acceptance: three conversations created through `pf` against a loopback fixture; search, clear, native selection/restoration and new-conversation preservation checked. The sidebar replaces the history sheet, refreshes after responses/on activation, and supports a compact window or collapse.

Not validated: paid/live provider calls, real OAuth accounts, iOS UI, Intel hardware, full VoiceOver traversal, Chinese IME composition, packaged/notarized distribution, or a new run of the historical official MCP conformance suite.

CI builds all targets, then runs every test module in its own process with `--skip-build --no-parallel --filter '^ModuleName\.'`, matching the per-module process isolation of the local Swift 6.4 runner. Default parallel execution on the CI runner overloaded sub-second timing fixtures. Each module retains its assertions and internal concurrency, with explicit step timeouts and unbuffered logs. Independent modules still run after a test failure so their diagnostics remain available. Stress tests observe the agent-start event instead of polling a transient state, and their deadlines can report a suspended operation without waiting indefinitely for task-group teardown.

The tool-duration regression compares the reported execution time with measured hook and enclosing intervals, rather than assuming a 30 ms sleep finishes within 100 ms on a shared CI runner. It still verifies hook exclusion and absent duration on a blocked tool.

## Detail polish — 2026-10-29

Native acceptance used the isolated local fixture: search focus/filter/Escape, code-copy confirmation, the circular return-to-latest control, long model names in the sidebar and composer, and light/dark compact layouts. The eight-module test suite passed. README screenshots were refreshed from this build. No live provider or personal conversation was used.
