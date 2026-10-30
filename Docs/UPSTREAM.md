# Upstream alignment

Pi Swift is a **selective community port** of [earendil-works/pi](https://github.com/earendil-works/pi). It is not an official distribution or a claim of complete compatibility with upstream main.

## Revisions

| Area | Reference |
| --- | --- |
| Original PiAI / PiAgent port | `16f5f0af4` |
| Resources, skills, native extensions and MCP | `42cb822f1c5d3153069dd0661bfd297424666cf1` |
| Incremental JSON parsing and client identity | `d5b3de22d0e24a3e9c38a9410d3329b099717283` |
| Standalone source review, 2026-10-28 | `4ba356228c7fea1524413b1d56f9a31351329575` |
| pi-ai provider fixes, 2026-10-30 | `f09d01b85` |

`upstream-reference.json` preserves the resource/MCP source blob inventory. `upstream-lock.json` records the reviewed head and exact hashes of selected API/session/CLI/tool sources. These files distinguish a reviewed source from an implemented feature.

## Alignment rules

1. Preserve runtime public names, event ordering, transcript structure, tool-call IDs, cancellation and error semantics wherever the Swift platform permits.
2. `PiChat` / `PiUI` are Swift additions. They consume events, never redefine the Agent loop or persist a competing model transcript. Display-only states such as “Needs approval” are projections.
3. `pf` uses `PiCodingAgent.AgentSession`, not a separate CLI loop implementation. Its host code handles arguments and presentation. The REPL is not the upstream terminal UI.
4. Keep intentional platform adaptations documented. Never label a stub, unsupported flag or untested platform as compatible.
5. Backport runtime changes with a source commit and regression test before updating the corresponding compatibility claim.

## Standalone release backports and repairs

- [`ae823bc0b`](https://github.com/earendil-works/pi/commit/ae823bc0b): tool-name queries take priority over BM25 description-length normalization. Full and `__` suffix matches are normalized the same way; partial-name queries retain BM25 ordering. Regression covers the upstream name/query examples.
- [`807a5c051`](https://github.com/earendil-works/pi/commit/807a5c051): restore the previous session leaf and remove the in-memory entry if persistence fails. Tests cover failed initial flush and failed append, then recovery/reopen.
- Relevant Kimi URL-return behavior from [`89c921d8b`](https://github.com/earendil-works/pi/commit/89c921d8b): pass the normalized HTTP(S) verification URLs to the host instead of returning unchecked originals after validation. Copilot and Meta already enforce HTTP(S) and return normalized URLs in this port. This is a selective application, not a claim that the entire upstream security commit was ported.
- Restored manual compaction cancellation wording to `Compaction cancelled` at the post-summary boundary, matching the reviewed upstream `agent-session.ts`. Two existing cancellation characterization tests now pass unchanged.
- Native SDK client filenames use `OpenAIClient.swift` and `AnthropicClient.swift` to avoid case-insensitive object-file collisions with provider filenames on Swift 6.3 builds. Public type names remain unchanged.
- Swift platform repair: ChatGPT OAuth waits for Network.framework listener cancellation before returning, so an immediate next login can reuse the callback port. A regression repeatedly closes and rebinds the same loopback port.
- Local session recovery repair, compared with `session-manager.ts` at [`16f5f0af4`](https://github.com/earendil-works/pi/blob/16f5f0af4d85ca583d045ceb5ed6d646fcaf7761/packages/coding-agent/src/core/session-manager.ts): v1 migration now reserves each generated ID, and context projection stops when a parent ID repeats. This intentionally adds protection beyond that reference for colliding or malformed chains; well-formed session layout and v3 JSONL remain unchanged. A forced-collision test and self/two-node cycle regressions cover the repair.
- MCP OAuth's default client display name is now `Pi Swift`; the extracted SDK no longer labels third-party login as Pagie.

## Native navigation backport, 2026-10-29

Reviewed `e65b3b88c08412bb8ffbd21fb5dc5756064a6e5a`: thinking-level mutation and event, tree target semantics and optional branch summaries, and fork-before-user-message behavior. Runtime persistence retains upstream entries; PiHost snapshots the source manager before forking so failed setup cannot replace the leased source. Desktop draft branch positions are native sidecar state. See [SLASH_COMMANDS.md](SLASH_COMMANDS.md) for verified behavior and unported selector/extension features.

## pi-ai provider sync, 2026-10-30

Shared with Pagie's `Vendor/Pi`. Ported upstream ai commits after `16f5f0af4` for the five supported APIs:

- Retry and overflow: cedefc532, 29057ece3, 6e491cfa9, c719d5b08 (ChatGPT workspace limit is non-retryable and gets a hint in openai-responses; Zhipu 1308; status codes only as whole numbers; Codex "stream disconnected"), d3398f826 (LiteLLM "context window exceeded").
- Google: 7314819f0, a7b94a03f (`const` rewritten to a single-value `enum` in tool schemas).
- Cost: 7c22a93d0, cae8d69e5 (`UsageCost.totalFromProvider`; OpenRouter-reported cost in openai-completions and anthropic-messages). Replay fixtures expect `"totalFromProvider": false`, which upstream `calculateCost` writes.
- Anthropic: 3bc6eebac (pending system messages flush after assistant turns with no blocks), e3bc05e87 (managed adaptive effort sends `low`), 842c73170 (strict-tool limit fallback).
- faux f3fa8bd92, OpenCode comment 177e2ad7e, and the OAuth part of 89c921d8b: one shared `trustedHttpUrl` (`auth/oauth/trusted-url.swift`) for GitHub Copilot, Kimi Code and Meta.

Not applicable here: System One classifiers, pi-messages, Bedrock, Vertex, Mistral, Codex and Radius. Pi Swift installs no builtin model catalog, so upstream model-list changes do not apply; connections name their model ID. `PI_AI_VERSION` stays `1.3.0`.

## Capability matrix

| Surface | Status |
| --- | --- |
| PiAI / PiAgent streaming, tools, events and queues | Existing Swift port; synthetic regression tests included |
| Session tree, persistence, compaction and retry SDK | Existing partial PiCodingAgent port |
| Skills, settings and native Swift extension callbacks | Supported subset; see historical PORTING.md |
| MCP HTTP / stdio, resources and OAuth | Native SDK; stdio/codemode are macOS-specific |
| CLI print / JSONL / sessions / slash commands | Native host subset; shared command parser and native selectors documented in CLI.md and SLASH_COMMANDS.md |
| CLI read / write / edit / bash | Matching reviewed input schemas; native behavior limits documented |
| CLI TUI, RPC, npm extensions and package installation | Not ported |
| PiHost / PiChat / PiUI | Swift-native host and presentation; shared AgentSession persistence and native UI permission modes; not upstream APIs |
| iOS | Runtime manifest declares iOS 17; complete package/UI not validated on iOS |
| Linux / Windows | Not claimed |

The upstream repository also contains packages outside this port (including TUI, durable and environment integrations). The review found changes after the selective baseline, including provider-specific tool handling, branch-summary thinking and active-tool ordering. Those changes are not implicitly included by recording the newer reviewed head. Future updates should assess and port them individually with tests.

## Checking drift

```sh
python3 scripts/check-upstream.py --ref main
```

This compares ten selected upstream source blobs with the reviewed snapshot, exits nonzero on differences, and does not modify the lock or source. It is a review aid, not a conformance test. There is no unattended auto-merge or scheduled updater.

## Verification

Use `swift test` for runtime/host regressions and `python3 scripts/smoke-cli.py` for CLI integration. See `VALIDATION.md` for the current release evidence. Historical official MCP conformance results in `Conformance/` retain their known failures and date; they were not re-certified as part of this extraction.

## Resource slash backport, 2026-10-29

Reviewed `aee933269ba79b84e7b7454097c1d4c426021d82`: prompt-template parsing/substitution, explicit skills, command precedence and extension invocation-name disambiguation. Desktop and pf share discovery/help/completion and native reload. This does not load TypeScript/npm extensions or replicate extension argument completion. See [SLASH_COMMANDS.md](SLASH_COMMANDS.md#phase-3-resource-commands) for source, usage, trust and native boundaries.

## Native interactive command feedback — 2026-10-29

Desktop and interactive pf explicitly opt into `PromptOptions.strictSkillCommands`, a Swift-native adaptation at the existing post-input-hook expansion boundary. A missing/unreadable skill fails before transcript insertion and provider execution. The option defaults to false, preserving the pinned upstream-compatible SDK literal fallback, extension precedence, and noninteractive pf behavior. Shared host presentation classifies compaction no-ops without changing runtime retention policy or errors.
