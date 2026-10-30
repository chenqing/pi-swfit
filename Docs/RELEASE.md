# Local macOS distribution

`scripts/release.sh` creates an optimized, Developer ID signed and Apple-notarized DMG containing Pi Swift, its bundled `pf`, and an Applications shortcut. It does not publish a GitHub release or replace an installed app.

Use the stable signing identity described in [LOCAL_SIGNING.md](LOCAL_SIGNING.md) and an existing `notarytool` Keychain profile. Credentials and profile names remain local:

```sh
PI_NOTARY_PROFILE=your-profile bash scripts/release.sh 0.1.0 2026102901
```

The source must be committed; the version must match `pf --version`. Builds run serially. The script applies Hardened Runtime and secure timestamps, notarizes and staples the app, then separately notarizes and staples its signed DMG. Any failed signature, notarization or Gatekeeper assessment stops packaging. Outputs, checksums, source revision and notarization reports remain under `.build/releases/` and are not committed.

Each build targets the current Mac's architecture; it is not a universal binary. Check the executable's actual minimum OS and linked libraries before claiming support beyond the tested machine. Local launch and notarization do not establish clean-machine or Intel acceptance.

Drag the app from the DMG into `/Applications`. Its CLI is `/Applications/Pi Swift.app/Contents/MacOS/pf`. The production bundle identifier is `dev.chenqing.pi-swift`; a separately identified QA app can coexist. The normal data directory is `~/.pf/agent`. A QA directory selected with `PF_AGENT_DIR` is not automatically migrated, and no user data or credentials are included in the package.


## Published release

[Pi Swift v0.1.1](https://github.com/chenqing/pi-swfit/releases/tag/v0.1.1) distributes build `2026103001` (source `41f9e79`) with the pi-ai provider sync. Earlier:

[Pi Swift v0.1.0](https://github.com/chenqing/pi-swfit/releases/tag/v0.1.0) distributes build `2026102906` for macOS 14+ on Apple Silicon. The tag points to the binary's source revision `004b60216fb63e85b771c81129f4dd0ac6cc3c50`; subsequent commits record installation validation and download instructions. Assets contain the notarized DMG and `SHA256SUMS`. A fresh download was checked against the local validated DMG before publication.
