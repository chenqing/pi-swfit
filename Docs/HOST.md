# Shared macOS host

`PiHost` supplies the platform glue shared by `pf` and `ChatSession.openCoding`. The model loop, session tree, retries and persistence remain in PiAgent/PiCodingAgent. UI rows are projections of the finalized runtime messages.

## Storage

Default root: `~/.pf/agent`, overridden by `PF_AGENT_DIR` / CLI `--agent-dir`.

- `connections.json`: profile IDs, labels, model IDs, API formats, endpoints and default selection. No API keys.
- Login Keychain service `dev.chenqing.pi-swift.connections`: per-connection API keys. The account is a hash of profile ID and routing destination. Changing routing requires a new profile identity. Keychain writes and reads can require macOS authorization.
- `sessions/<workspace-hash>/*.jsonl`: upstream-format session entries. The workspace hash is the first 12 SHA-256 bytes of the canonical absolute folder path. Workspace directories are owner-only. Original messages and tool-result diffs are stored here, so treat these files as private project data.
- `playground.json`: last workspace, connection ID and session path. Drafts and pending approvals are not persisted.
- `*.lock`: advisory locks held by an open host. Empty lock files may remain after exit; the operating system releases ownership when the process ends. Upstream Pi and third-party readers that do not use this host do not honor these locks.

A `pf.connection` custom session entry records the selected profile ID without injecting it into model context. Explicit CLI model routing clears that association; to resume that session in Playground, first associate a saved connection through `pf --connection NAME --session PATH`.

## Credentials

Keychain is the durable store. The active session holds a key in memory for requests; forgetting the saved key removes durable storage and takes effect on the next connection. No key is written into a session or profile by the host. Normal tool output or user messages may themselves contain sensitive project data; the transcript is not a secret scrubber.

macOS manages executable access independently. First access by the UI/CLI, or rebuilt unsigned development binaries, may prompt for authorization. The host does not add broad Keychain ACLs or weaken access controls. Keychain operations that can wait for UI authorization run off the UI's main actor. Batch `pf` disables legacy Keychain UI prompts and returns an error when authorization is needed. Explicit `PF_API_KEY` bypasses saved-key lookup for that process and is not persisted.

## Tools and approval

The UI uses the same `read`, `write`, `edit`, `bash` implementations as the CLI. Every UI tool invocation waits for an explicit per-call decision. Write/edit approvals include a bounded diff (400 lines / 32 KiB); the complete validated arguments remain accessible on the tool row. A file snapshot is checked again after approval to detect intervening edits. Result diffs are persisted in `details.diff` and shown again on resume.

This is not a filesystem sandbox. The workspace determines relative-path resolution; absolute paths and shell commands run with the user's permissions. Bash side effects are not transformed into edit previews. The CLI preserves its direct tool-execution policy, with `--no-tools` available.

## Reproduce native acceptance locally

```sh
python3 scripts/playground-fixture.py
# In another terminal, use the printed agent_dir to isolate configuration/history:
PF_AGENT_DIR=/printed/agent_dir ./scripts/run-playground.sh
```

Connect to the printed endpoint with model `fixture` and key `local-fixture-only`, choose the printed workspace, then ask to read and update `sample.txt`. The fixture exercises real loopback HTTP/SSE, read/edit approval, the actual filesystem, Keychain storage and JSONL persistence. Quit the app, run `pf --continue` in that workspace with the same `PF_AGENT_DIR`, then reopen the app. This is a deterministic local fixture, not proof of any external provider's behavior.
