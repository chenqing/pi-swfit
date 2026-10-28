# Swift MCP conformance

Runs the same official client suite as
[Pi at 42cb822f](https://github.com/earendil-works/pi/tree/42cb822f1c5d3153069dd0661bfd297424666cf1/packages/coding-agent/test/mcp-conformance).
The npm package is pinned to `@modelcontextprotocol/conformance@0.2.0-alpha.11`.
`baseline.json` is the unmodified upstream blob `0401d64b04da978dc0e26acf1c15eff387f0500e`;
`run.ts` adapts its runner to the production Swift `PiMCP` transport and OAuth client.
It never rewrites the baseline. Each run writes its own `swift-results.json` separately.

Requires macOS, Swift 6, Node 24 and npm. No LLM or third-party account is used. npm install
scripts are disabled. Scenario servers, OAuth redirects and callback listeners run on loopback;
credentials are synthetic and remain in memory. Build and run from a real temporary copy:

```sh
# From the repository root; do not run QA from Documents or from a symlink into it.
task_dir=$(mktemp -d "${TMPDIR:-/tmp}/pi-swift-mcp.XXXXXX")
rsync -a --exclude .git --exclude .build --exclude .swiftpm ./ "$task_dir/Pi/"
cd "$task_dir/Pi"
swift build --product PiMCPConformance
PI_MCP_CONFORMANCE_CLIENT="$(swift build --show-bin-path)/PiMCPConformance" \
  node Conformance/run.ts --keep-results
```

Use `--mode 2025-11-25 --scenario sse-retry` for a focused rerun. A missing baseline check,
missing scenario or newly failing check fails the comparison. The runner prints the retained
temporary result directory; raw `checks.json` files include the suite's HTTP traces.

## Recorded result, 2026-10-23

Apple Silicon macOS 27.0.1, macOS 14 deployment target:

| Protocol | Scenarios | Passing checks | Known failing checks |
|---|---:|---:|---:|
| 2025-03-26 | 2 | 15 | 0 |
| 2025-06-18 | 5 | 53 | 0 |
| 2025-11-25 | 19 | 193 | 8 |
| Total | 26 | 261 | 8 |

No regressions against the upstream baseline. This is **not** an all-green protocol certification.
The eight known failures are six elicitation default checks (no elicitation UI), one CIMD default
selection check (DCR is the default), and the expected client failure after three sign-ins in
`auth/scope-retry-limit`. Protocol 2026-07-28 is outside this matrix. The independently generated
Swift check inventory is committed as `swift-results.json`.

`oauth-lifecycle.py` is a separate local HTTP fixture used by `PiMCPOAuthTests` to exercise the
actual URLSession transport: discovery, registration, PKCE/issuer callback, refresh after 401,
logout during login, explicit cancellation and subsequent login. It does not validate a real
third-party identity provider or production Keychain behavior.
