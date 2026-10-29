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

- Full-height sidebar: native light/dark compact windows and sidebar collapse checked. The native toolbar uses an opaque split background aligned with the sidebar; transcript scrolling remains below the toolbar, without text bleeding behind window controls.


## Composer interaction — 2026-10-29

Rechecked the local Claude Code composer with an unsent temporary draft (cleared afterward). Pi Swift now uses a fixed 28 pt Add button and a native plain-text editor; the Add and send/stop actions stay aligned at the bottom while the editor grows upward. Native QA covered empty/single/multiline drafts, Shift-Return, Return submission, draft preservation while running, stopping pending tool approval, Escape from the Add popover, UTF-8 file insertion and resumed editing, a 20-line internally scrolling draft, and light/dark compact layouts. README screenshots contain only the isolated local fixture.

Three new AppKit tests cover Return/Cmd-Return submission, modified Return/newlines, held-key suppression, marked-text confirmation without submission, and multiline insertion without submission. This tests the marked-text API; real Chinese/Japanese IME candidate selection and full VoiceOver traversal still need manual acceptance. All eight test modules and the Release app build passed locally. Model/workspace configuration and text-file insertion retain their existing scope; image uploads, Claude slash commands and permission modes are not emulated.


## Icon consistency — 2026-10-29

Shared regular monochrome icons now cover sidebar navigation, toolbar actions, composer, copy, disclosure and tool states. Native light/dark and compact-window checks confirmed the vertical More menu, Return-arrow send button, copy confirmation and tool approval → completion → disclosure. The screenshots were refreshed using only the isolated demonstration profile. The eight-module test suite and Release app packaging passed.

## Session details — 2026-10-29

The right inspector displays the actual workspace/model, provider-reported token usage, available tools and recent calls, and diffs recorded by tools in the current conversation. Tests cover missing usage, cache-inclusive last input, replacement of repeated streaming snapshots, accumulation across turns, reset, and persisted usage restoration.

Native acceptance used a temporary workspace and a loopback SSE fixture: `pf` made an actual approved file edit, then Pi Swift restored its conversation, usage and diff. Wide inline and compact popover layouts, resizing, Option-Command-I, card folding, diff disclosure, configuration-sheet presentation, and light/dark appearance passed. An offline approval scenario verified Needs approval → Stopped and interrupted tool state. README includes only the isolated fixture screenshot. All eight test modules and Release app packaging passed. This does not validate a live provider, Git working-tree status, or full VoiceOver traversal.


## Model menu, inspector and conversation management — 2026-10-29

- Full serial suite: 1,133 tests across eight modules passed (PiAI 734, PiAgent 76, PiCodingAgent 267, PiMCP 23, PiChat 11, PiCLI 5, PiHost 8, PiUI 9). The existing opt-in sandbox/Keychain limitations above still apply. CLI smoke and Release app packaging passed.
- Model switching tests verify transcript/draft/file-lease retention, destination-specific credentials on the next request, connection persistence, the selected route surviving New conversation, restoration, rejection of an invalid endpoint without changing the active route, and no credentials in JSONL. These requests use a simulated stream and memory credential store.
- Organization tests verify that pin/archive leave transcript bytes unchanged, rename respects a live file lease, active and inactive renames persist, invalid titles fail, and restoring preserves the pin. Recorded-change tests count hunk additions/removals without confusing file headers or literal leading plus/minus characters.
- Native acceptance used a separate copy of the local edit fixture and two credential-free saved connections. Verified model menu selection while retaining an unsent draft and transcript; Manage connections presentation with wrapped description; rename updating sidebar/header; pin; archive of the active conversation preserving its draft; archived-list restore; reopened messages/tool results/diff; and restart restoring the title, pin and selected model. Test drafts were cleared without sending.
- Release native checks covered light/dark and compact/wide layouts, Option-Command-I popover, Usage and Tools disclosure, bounded raw arguments/results with no repeated diff, opening the diff from the compact popover, Copy diff feedback and paste round trip, and Escape dismissal. README screenshots are exclusively the isolated demonstration content.
- Remaining scope: saved-connection quick selection, local desktop organization, and recorded-edit reading. No live provider calls, model-catalog discovery, Git/PR diff aggregation, full VoiceOver traversal or real IME validation was added in this pass.


## Conversation continuity and diff reading — 2026-10-29

- Full serial suite: 1,137 tests across eight modules passed (PiAI 734, PiAgent 76, PiCodingAgent 267, PiMCP 23, PiChat 14, PiCLI 5, PiHost 8, PiUI 10). New tests cover unified-diff line numbering across hunks/files, zero-length ranges, metadata/literal plus signs, action summaries, and editor updates not stealing focus from another text field. The prior section's PiChat/PiUI labels were corrected; its aggregate was unchanged. Existing opt-in sandbox/Keychain limitations still apply. Release app packaging passed after the final layout adjustment.
- Native draft acceptance: independent drafts in two existing conversations, new conversation then return, clearing a draft without resurrecting old text, and continued editing while the diff window is minimized. No fixture messages were submitted. Draft caching is process-local; restart persistence and unsent blank conversations in the history list are not implemented.
- Header/sidebar acceptance: rename from the toolbar updates both title and history; title stays aligned with the main column; pointer drag and double-click reset, accessibility width adjustment, and width retention after restart passed. Search retains keyboard focus and Escape clears/leaves it; Add-popover Escape returns to continued draft input.
- Diff acceptance: independent 960 pt window, old/new line numbers, long-line wrapping, horizontal scrolling with wrapping off, hunk navigation, record switching with navigation reset, Escape, and compact-inspector opening passed. Light/dark and compact/wide layouts were inspected. Transcript tool rows show action/file/count summaries and keep raw output collapsed.
- README screenshots use only a credential-free, isolated local fixture. Its original greeting edit was extended with a synthetic long-line hunk and second file record to exercise the reader; this pass made no live provider calls. Real IME composition, full VoiceOver traversal, large-diff performance, and notarized distribution remain unvalidated.


## Draft restoration — 2026-10-29

- Full serial suite: 1,141 tests across eight modules passed; PiHost now has 12 tests. Four new tests cover exact Unicode/multiline text across store instances, separate session keys, clearing and missing transcripts, unchanged transcript bytes, owner-only permissions, corrupt-file errors without overwriting the source, and lock contention retaining saved text. Release packaging passed.
- Native acceptance used a separate credential-free fixture bundle and storage directory. Two existing conversations retained distinct drafts after Cmd-Q/relaunch; clearing one did not restore its previous text. The current new conversation restored its unsent draft despite having no JSONL yet, and its old draft entry was retired after the new bookmark was saved. Autosave was inspected on disk before quitting.
- A held fixture draft lock caused Cmd-Q to leave the app open with a save error and its draft intact. After releasing it, clearing worked and normal quit/relaunch succeeded. Submitting a restored draft against the credential-free loopback profile recorded the user message and failed before a provider request; the saved draft was removed and remained empty after restart. No real provider, personal credentials, or upstream session format changes are involved. Drafts are local plaintext sidecars, excluded from model context; the 400 ms autosave interval is not a guarantee against abrupt power loss during active typing.
- README images were deliberately left unchanged for a later user-assisted capture without the screen-sharing indicator.

## Draft access, recovery and search — 2026-10-29

- Added coverage for workspace-scoped unsent draft discovery, legacy sidecars, saved connection metadata, excluding existing transcripts, Unicode search excerpts, programmatic editor undo/redo, menu validation, separate send/re-edit undo groups, session-bound undo history, and marked-text preservation.
- Native Release acceptance used the isolated credential-free audit fixture. A legacy orphan draft was recovered from the sidebar; multiple unsent drafts remained accessible after switching and restarting. New conversation focuses the composer. Suggestions append without replacing existing Chinese text; keyboard/menu Undo and Redo and text-file insertion undo were exercised. Switching conversations does not allow undoing into the previous draft.
- A request with a missing fixture API key failed before any provider call. Edit last message restored editable text without resubmitting; its undo returned to empty input. With another draft already present, recovery appended the failed message, and undo preserved that original draft. Manage connections opened from the error card. No tools were replayed.
- Body search found `print(greeting)` inside a saved assistant code block, displayed excerpts and highlighted the matching message. Search retained input focus. Dark appearance and hidden left/right sidebars survived quit/relaunch; the current unsent draft and other sidebar drafts also survived. Wide light/dark and compact dark layouts were inspected. Real IME candidate selection, full VoiceOver navigation, and live-provider recovery remain unverified.
- README screenshots and image assets were deliberately left unchanged.

- One full run stalled inside the existing large-session fixture’s parent-path projection and was terminated. Inspection found missing cycle bounds and an unpopulated migration ID set. The local repair reserves IDs and bounds repeated parent traversal; deterministic forced-collision and cyclic-chain regressions pass, along with all three upstream large-session fixture tests. This is documented as a Swift safety adaptation, not an upstream format change.
- The final full run attempted 1,149 tests: all modules except two existing Anthropic OAuth fixed-port checks passed. Those two failed because another local application held TCP source port 53692; the port conflict was confirmed through the OS socket table and the focused suite. That application was left untouched. CLI smoke passed, including local SSE/tool execution, saved connections, session resume and failure exit behavior.
- Excluding only those two port-dependent checks, the final serial rerun passed all 1,147 selected tests across eight modules (PiUI 13, PiMCP 23, PiHost 15, PiCodingAgent 269, PiChat 14, PiCLI 5, PiAgent 76, PiAI 732). Release packaging passed. Final native checks verified the global File → New conversation / Cmd-N command after hiding and re-showing the sidebar, preserving the outgoing draft and focusing the new composer.

## Conversation space and continuity — 2026-10-29

- Inspected Claude Desktop 4.29.0's installed ASAR main-window CSS and its native Code view. Only bundled layout primitives were available; no proprietary source/assets were added to this repository. PiUI now distinguishes assistant continuations, adjacent tools and new turns, omits empty streaming rows/intermediate copy shelves, caps user bubbles at 85%, and shares a wider bounded reading column with the composer and adaptive narrow-column gutters.
- Four projection tests cover original message identity/tool order, turn boundaries, empty placeholders, and action-shelf suppression while streaming. Full serial suite attempted 1,153 tests: 1,151 passed. The same two existing Anthropic OAuth checks failed because an unrelated application still held TCP source port 53692, confirmed using the OS socket table. No unrelated process was stopped and no tests were weakened. PiUI's 17 tests passed.
- Native Release QA used a new isolated, credential-free JSONL fixture reproducing the user's Chinese prompt, bash/read steps, explanation and Swift block. Inspected 1504 pt wide/light, 900×612 compact/dark, and a 540 pt main column obtained by widening the sidebar. Tool details/raw result expansion, long mixed-language user bubbles, eight-turn history, Back to latest, and a 16-line unsent draft were exercised. Growing/clearing the draft preserved the historical reading position and used the editor's internal scrolling. The local long-streaming scenario retained the scrolled-up position after completion. No live provider calls were made.
- README and its user-supplied screenshot were left byte-for-byte unchanged. Private QA captures are separate from publication assets. Existing limitations for real IME composition and full VoiceOver traversal still apply.
- Release app packaging passed. The user's running local app was normally quit and updated after backing up its agent directory and prior bundle. All three existing JSONL transcripts matched their pre-update hashes. Reopening the credential-backed app triggered the macOS Keychain/SecurityAgent handoff; fixture-based visual acceptance above is independent of that authorization.

## Titlebar/sidebar seam — 2026-10-29

- Replaced the material-treated hard-stop toolbar gradient with the same fixed-width, solid-color split used by the content background. A non-interactive cover sized from the top safe-area inset masks scrolled content behind native toolbar controls. No window coordinates, private AppKit hierarchy, session data or runtime behavior changed.
- Native checks in the isolated layout fixture passed for dark/light appearance, 232→296 pt sidebar resizing, hidden/shown navigation, long-history scrolling, and 900×612 compact layout. The sidebar edge stays straight through the titlebar boundary and the hidden sidebar leaves no residual color strip. README image assets were unchanged.
- Full serial suite: all 1,153 tests passed across eight modules, including the two fixed-port OAuth checks previously blocked by an unrelated connection. No new tests were added for this presentation-only change.
- Debug and Release app packaging passed. The credential-free fixture shows the fix; the user's other running bundle remained at its existing Keychain authorization prompt and was not replaced while blocked.


## Conversation permission modes — 2026-10-29

- Compared the installed Claude Desktop 4.29.0 Code mode menu and official permission documentation. Added Manual, Accept edits and Bypass permissions to the composer, backed by actual ChatSession approval decisions. Auto classification, Plan workflows, saved allow/deny rules, read-only shell classification and sandboxing are not implemented. No Claude source or assets were copied.
- Full serial suite: all 1,160 tests passed across eight modules (PiUI 17, PiMCP 23, PiHost 17, PiCodingAgent 269, PiChat 19, PiCLI 5, PiAgent 76, PiAI 734). Release app packaging passed. Tests exercise workspace/outside paths, parent and dangling symlinks, protected metadata, custom-tool trust, pending-approval locking, host denials, reset/reopen defaults and model-switch retention. Temporary-workspace integration tests perform actual file edits and harmless shell commands under all three policies, preserving diffs and transcript bytes.
- Native QA inspected light/dark and compact layouts, menu labels/checkmarks, Escape returning to the editor, draft preservation, and disabled selection during streaming with restoration after Stop. Automatic-mode switching was exercised only in the offline scenario with no filesystem/network capabilities. Final Release inspection confirmed the model selector remains right-aligned. Existing real IME and full VoiceOver limitations remain.
- Permission choice belongs to the open ChatSession, never the upstream JSONL; reopening/reset starts in Manual. Non-bypass shell calls still ask. Bypass skips application prompts, not host denials, cancellation, preview consistency checks or macOS permissions.
- Updated the user's existing local bundle after normal quit and a private backup of its previous bundle and agent directory. All three transcript hashes matched after replacement. The new binary triggered another macOS Keychain handoff. After the user completed it, the credential-backed app restored its conversation and model selection; the permission menu opened with Manual selected, and Escape returned focus to the composer. All three transcript hashes were verified unchanged again. No message or tool was submitted during this check.
- README and screenshot assets remain unchanged.


## Conversation title inset — 2026-10-29

- Added a 24 pt leading inset between the visible sidebar boundary and the conversation title, with 8 pt additional separation from the sidebar control when collapsed. Recreates the toolbar identity view when sidebar visibility changes so AppKit refreshes its intrinsic layout instead of retaining a collapsed title region.
- Native checks in the isolated dark fixture verified the visible inset and repeated sidebar collapse/expansion. No conversation state, permissions or README screenshots changed. The initial spacing-only build also received narrow-window inspection.
- Serial regression suites passed all 1,160 tests. An additional run exposed an intermittent existing lazyStream observer assertion in PiAI; an unchanged rerun passed all 734 PiAI tests. No test or runtime implementation was changed for this presentation fix.
- Final serial rerun after the toolbar identity adjustment passed all 1,160 tests. Debug and Release packaging passed. The user's local bundle was normally quit, backed up and updated; all three JSONL transcripts retained their hashes. The new executable is awaiting another user-completed macOS Keychain authorization.
