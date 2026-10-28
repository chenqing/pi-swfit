# Pi Swift

Use Swift 6. Preserve upstream runtime names and behavior. See Docs/UPSTREAM.md and PORTING.md before editing PiAI, PiAgent, PiMCP or PiCodingAgent. Keep native UI and CLI adaptations in their own targets.

Run Swift builds/tests serially. Use focused tests during edits and the full suite before publishing. Validate CLI changes with scripts/smoke-cli.py. UI work must be inspected in the actual native Playground, including compact/dark layouts and relevant interactions.

Do not copy user sessions, credentials, .build, .swiftpm, or unrelated Pagie source into this repository. The user chose the repository name pi-swfit and executable name pf.
