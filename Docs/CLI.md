# `pf` CLI

`pf` is a native command-line host for `PiCodingAgent.AgentSession`. Its supported options use the spelling and intent of `pi-coding-agent`. It is not the upstream CLI rewritten in full.

## Supported

- `--provider`, `--model`, `--thinking`, `--system-prompt`.
- `-p` / `--print`: final assistant response on stdout, then exit. Multiple positional prompts run sequentially.
- `--mode json`: a session header followed by JSONL events (`message_update`, `tool_execution_*`, `agent_end`, `agent_settled`, etc.). Diagnostics stay on stderr. This is **not RPC**.
- `-c` / `--continue`: latest session for this working directory; `--session PATH`: an existing JSONL file.
- `--session-dir`, `--no-session`, `--tools read,bash,edit,write`, `--no-tools`.
- Piped UTF-8 stdin, limited to 8 MiB, prepended to the first prompt.
- Interactive line input, `/exit`, `/quit`, `/compact`. Ctrl-C aborts the active session, cleans up shell children, and exits with 130.
- Provider environment keys supported by PiAI. Saved connections read their API key from Keychain; explicit `PF_API_KEY` overrides key lookup for the current process. No keys are written to CLI configuration or session files by the host.

The native tool schemas match the reviewed upstream versions: `read(path, offset?, limit?)`, `write(path, content)`, `edit(path, edits: [{ oldText, newText }])`, `bash(command, timeout?)`. Do not use the older top-level `oldText`/`newText` edit shape.

## Deliberate native differences

- `PF_AGENT_DIR` / `--agent-dir` defaults to `~/.pf/agent`; upstream Pi's global directory is not modified. Project `.pi` resources are read only with `--trust-project`.
- `--base-url` and `--api` configure custom endpoints. HTTP is accepted only on loopback; other endpoints use HTTPS.
- `--demo` exercises the real session pipeline with deterministic output, without credentials, network or tools.
- Live use requires explicit model routing (`--model` or `PF_MODEL`) or a saved Playground connection. `--connection NAME_OR_ID` selects one; `--list-connections` lists names, IDs and endpoints without credentials. With no routing flags, resume uses the session’s saved connection, otherwise the default saved connection.
- Unknown flags fail with an explicit message. Unsupported commands are not silently ignored.
- Text reads are UTF-8 only, capped at 10 MiB input and 2000 lines/50 KiB per result. Image reads, exact upstream diff formatting, fuzzy matching, shell progress updates and shell environment hooks are not ported.
- Edits use exact, unique, non-overlapping matches against the original file. A failed match leaves the file unchanged. Atomic text writes are used. The native host records a bounded textual diff in tool-result details.
- Bash has no default timeout, accepts an explicit timeout, captures combined stdout/stderr, and retains truncated full output in a private temporary file. The first native version's structured output is limited to 50 KiB rather than upstream's larger structured-result budget.
- The CLI's tool set can access files and execute commands with the caller's permissions. It is not a sandbox. Use the host authorization hooks or `--no-tools` when embedding.
- No TUI, RPC, `@file` prompt expansion, OAuth login UI, `/model`, `/tree`, session picker, npm/git extension installation or MCP configuration UI yet. The MCP SDK remains available separately; this CLI does not enable MCP.

## Example custom endpoint

```sh
pf --provider openai --api openai-completions \
   --base-url http://localhost:8080/v1 --model local-model \
   --no-tools -p "Hello"
```

## Validation

`python3 scripts/smoke-cli.py` starts a loopback SSE fixture, invokes the compiled `pf`, checks a real model-request → read-tool → model-response cycle, checks JSONL, session continuation, stdin and failure exit status. It uses a temporary directory and a synthetic key.

## Sharing with Playground

Save a connection and choose a workspace in Playground, then quit the app before continuing the same session in `pf`:

```sh
cd /path/to/project
pf --list-connections
pf --connection "My model" --continue
```

Connection names must be unambiguous; IDs always work. `--connection` cannot be combined with explicit provider/model/API/endpoint flags. `--session` must belong to the current working directory. Both hosts use an advisory file lock to prevent simultaneous writers. Separate conversations can still run concurrently.

First Keychain access by `pf` may need approval in an interactive terminal. Noninteractive runs disable legacy Keychain dialogs and report missing authorization instead of hanging. Rebuilding an unsigned executable can require authorization again. `PF_API_KEY` is a per-process alternative for unattended runs. A saved key is never redirected to a changed profile endpoint: credential accounts include the profile ID, endpoint, API format and provider.

CLI tools retain their existing noninteractive execution policy. The Playground’s per-call approval is a UI host policy; it does not silently become a terminal prompt in `pf`.
