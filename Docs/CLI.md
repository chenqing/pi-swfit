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
- Provider environment keys supported by PiAI. No keys are written to CLI configuration or session files by the host.

The native tool schemas match the reviewed upstream versions: `read(path, offset?, limit?)`, `write(path, content)`, `edit(path, edits: [{ oldText, newText }])`, `bash(command, timeout?)`. Do not use the older top-level `oldText`/`newText` edit shape.

## Deliberate native differences

- `PF_AGENT_DIR` / `--agent-dir` defaults to `~/.pf/agent`; upstream Pi's global directory is not modified. Project `.pi` resources are read only with `--trust-project`.
- `--base-url` and `--api` configure custom endpoints. HTTP is accepted only on loopback; other endpoints use HTTPS.
- `--demo` exercises the real session pipeline with deterministic output, without credentials, network or tools.
- A model ID is required for live use (`--model` or `PF_MODEL`); this host does not pick a provider's current recommended model.
- Unknown flags fail with an explicit message. Unsupported commands are not silently ignored.
- Text reads are UTF-8 only, capped at 10 MiB input and 2000 lines/50 KiB per result. Image reads, upstream diff formatting, fuzzy matching, shell progress updates and shell environment hooks are not ported.
- Edits use exact, unique, non-overlapping matches against the original file. A failed match leaves the file unchanged. Atomic text writes are used.
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
