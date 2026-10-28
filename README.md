# Pi Swift

**A native Swift agent runtime, a small coding CLI, and composable chat UI.**

[![Swift](https://github.com/chenqing/pi-swfit/actions/workflows/ci.yml/badge.svg)](https://github.com/chenqing/pi-swfit/actions/workflows/ci.yml)

Community Swift port of [earendil-works/pi](https://github.com/earendil-works/pi), extracted from [Pagie](https://github.com/chenqing/pagie). Not an official Pi distribution and not a complete port of upstream main. Runtime names and event semantics follow Pi; native presentation lives in separate modules.

The repository is named **`pi-swfit`**. The product is **Pi Swift**, and the command is **`pf`**.

## Try it

Requires macOS 14+ and a Swift 6 toolchain. Apple Silicon is the validated platform. No Node runtime is needed for Swift products; the optional upstream MCP conformance runner uses Node.

```sh
git clone https://github.com/chenqing/pi-swfit.git
cd pi-swfit
swift run pf --demo -p "Hello"
./scripts/run-playground.sh
```

The Playground starts with an **offline demonstration** that runs through the actual Agent loop, including per-call approval, streaming, tool execution, and cancellation. Its connection sheet accepts a provider endpoint and model ID; keys stay in memory. It also includes failure/long-stream scenarios, light/dark appearance, and a compact layout.

## `pf` — Pi for Swift

```sh
# Supply your provider key through its environment variable, e.g. OPENAI_API_KEY.
swift run pf --provider openai --model YOUR_MODEL -p "Explain this project"
swift run pf --provider openai --model YOUR_MODEL --mode json "Explain this project"
swift run pf --provider openai --model YOUR_MODEL --continue
swift run pf --demo --no-session -p "No key needed"
```

`pf` uses **PiCodingAgent.AgentSession**, including its session manager and compaction behavior. It provides a line-oriented REPL, print mode, JSONL events, stdin, session resume, and native `read`, `bash`, `edit`, `write` tools. Those tools run with your user's permissions; `--no-tools` gives a chat-only session. Sessions default to `~/.pf/agent`, separate from upstream Pi. See [CLI usage and differences](Docs/CLI.md).

To install the CLI locally:

```sh
swift build -c release --product pf
mkdir -p "$HOME/.local/bin"
cp "$(swift build -c release --show-bin-path)/pf" "$HOME/.local/bin/pf"
# Add ~/.local/bin to PATH if it is not already there.
```

## Add native chat to an app

```swift
.package(url: "https://github.com/chenqing/pi-swfit.git", branch: "main")
```

Choose products independently:

| Product | Responsibility |
| --- | --- |
| `PiAI` | Provider requests, message types, streaming, authentication |
| `PiAgent` | Agent loop, tool execution, events, steering and cancellation |
| `PiMCP` | Native MCP client, transports and OAuth |
| `PiCodingAgent` | Sessions, persistence, compaction, resources, skills and native extensions |
| `PiChat` | Main-actor conversation presentation and approval adapter for `PiAgent` |
| `PiUI` | SwiftUI conversation, message, composer, tool and approval components |
| `PiCLI` | `pf` argument parsing, coding tools and CLI host |

For an offline SwiftUI preview:

```swift
import SwiftUI
import PiChat
import PiUI

@MainActor
struct DemoView: View {
    @State private var session: ChatSession?
    @State private var error: String?

    var body: some View {
        Group {
            if let session {
                ConversationView(session: session)
                    .chatTheme(ChatTheme(accent: .teal))
            } else if let error {
                Text(error)
            }
        }
        .task {
            do { session = try makeDemoSession() }
            catch { self.error = String(describing: error) }
        }
    }
}
```

For a real model, create `ChatSession(options: AgentOptions(...))` with a model, tools and credential closure. See [native UI integration](Docs/UI.md). The UI adapter currently wraps `PiAgent`; it does **not** claim to persist chats, expose branching, or implement the entire `PiCodingAgent` lifecycle. Use the session SDK directly for those capabilities, as `pf` does.

## Upstream compatibility

The project uses **pinned, selective porting**, not a blanket “fully compatible” claim. [The compatibility record](Docs/UPSTREAM.md) lists source revisions, backported fixes, platform differences and remaining gaps. [PORTING.md](PORTING.md) preserves historical translation conventions. `scripts/check-upstream.py` compares tracked upstream file blobs without changing the pins.

Not included in this first release: full terminal TUI, RPC mode, JavaScript/npm extension loading, browser tools, iOS UI validation, attachment rendering, or a production release installer. The default message view supports inline Markdown and preserves line breaks; applications can inject a richer renderer.

## Development

```sh
swift test
python3 scripts/smoke-cli.py
swift build -c release --product pf
```

Tests use synthetic provider transports and local fixtures. Some imported tests require an external upstream checkout or a signed codemode helper and are conditionally skipped. Historical MCP results are in [Conformance](Conformance/README.md); they are not an all-green protocol certification.

## License

MIT for the original Pi code and Swift additions, with preserved third-party license notices for adapted provider SDK code. See [LICENSE](LICENSE) and [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md).
