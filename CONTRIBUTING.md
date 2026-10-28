# Contributing

Keep the runtime recognizable as a Swift port of Pi. Preserve upstream names, transcript fields, event ordering, cancellation, retry and persistence semantics unless a platform difference is documented.

For an upstream fix, include its commit URL and a behavior-focused regression test. Update `Docs/UPSTREAM.md` and the relevant source comments. A pinned upstream revision is not a claim that every file has been ported.

Put native UI behavior in `PiChat` / `PiUI`, and CLI hosting in `PiCLI`. Do not import SwiftUI or application-specific business models into PiAI/PiAgent/PiCodingAgent.

Run `swift test` and `python3 scripts/smoke-cli.py`. UI changes also need actual macOS inspection, including long streaming content, approval/cancellation, compact layout, dark mode and keyboard interaction. Never commit provider keys, local sessions or build products.

This is an early 0.1 API. Discuss broad API changes in an issue before implementing them.
