# Validation — 2026-10-28

Environment: Apple Silicon macOS, Apple Swift 6.4, deployment target macOS 14. This is evidence for the standalone source, not a claim that all declared platforms or providers were tested.

- `swift test`: all six targets passed. The runner reports 1,111 tests across PiAI (733), PiAgent (75), PiCodingAgent (267), PiMCP (23), PiChat (8), PiCLI (5). The real codemode sandbox fixture is conditionally skipped when `PI_CODEMODE_HELPER` is unset; no sandbox execution is claimed here.
- `scripts/smoke-cli.py`: version, unsupported flags, stdin, no-session mode, disk session continuation, JSONL event shape, failure exit status and a loopback OpenAI-compatible SSE → read tool → final response passed.
- Release `pf` build and offline execution verified locally.
- Playground native checks: empty state, Cmd-Return submission, tool approval and rejection, expandable tool detail, stopping with partial text retained, compact layout, light/dark appearance, model configuration sheet, manual scrolling and return-to-latest. Scroll observation uses native NSScrollView metrics so offscreen SwiftUI content does not reset follow state.
- Presentation refinement: unified native toolbar, 12 pt transcript top inset, trailing user bubbles, paragraph spacing, compact expandable tool rows, one-line growing composer, compact/dark layouts and full-screen transition inspected in the native Playground.
- Scoped source export inspected for private credential patterns and personal absolute paths; no matches in exported source. Build caches, local sessions and Pagie application data are excluded.

Not validated: paid/live provider calls, real OAuth accounts, iOS UI, Intel hardware, full VoiceOver traversal, Chinese IME composition, packaged/notarized distribution, or a new run of the historical official MCP conformance suite.

CI explicitly uses `swift test --no-parallel`: Swift 6.3 combines all targets into one test process, and simultaneous execution of 1,111 tests on a shared runner starved sub-second retry/cancellation fixtures. Serialization preserves their existing deadlines and assertions; concurrency within each test still runs normally. Local default-parallel and serial runs are both checked.
