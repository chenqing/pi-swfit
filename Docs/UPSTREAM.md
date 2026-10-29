# Upstream alignment

Pi Swift is a **selective community port** of [earendil-works/pi](https://github.com/earendil-works/pi). It is not an official distribution or a claim of complete compatibility with upstream main.

## Revisions

| Area | Reference |
| --- | --- |
| Original PiAI / PiAgent port | `16f5f0af4` |
| Resources, skills, native extensions and MCP | `42cb822f1c5d3153069dd0661bfd297424666cf1` |
| Incremental JSON parsing and client identity | `d5b3de22d0e24a3e9c38a9410d3329b099717283` |
| Standalone source review, 2026-10-28 | `4ba356228c7fea1524413b1d56f9a31351329575` |

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

## Capability matrix

| Surface | Status |
| --- | --- |
| PiAI / PiAgent streaming, tools, events and queues | Existing Swift port; synthetic regression tests included |
| Session tree, persistence, compaction and retry SDK | Existing partial PiCodingAgent port |
| Skills, settings and native Swift extension callbacks | Supported subset; see historical PORTING.md |
| MCP HTTP / stdio, resources and OAuth | Native SDK; stdio/codemode are macOS-specific |
| CLI print / JSONL / sessions | Native host implemented; subset documented in CLI.md |
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
