# Local signing and Keychain access

The macOS linker gives an otherwise unsigned Swift executable an ad-hoc signature. Its designated requirement is its code hash, which changes when the binary changes. Keychain can therefore request authorization again after every rebuild, even if you previously chose **Always Allow**.

Use one certificate identity consistently for local builds. List available identities with `security find-identity -v -p codesigning`, then save the chosen certificate's fingerprint as the only line of `~/.config/pi-swift/codesign-identity`. This local file contains a certificate identifier, never a password or private key. Alternatively set `PI_CODESIGN_IDENTITY` for a build. The environment value takes precedence; the scripts do not automatically choose or switch certificates.

```sh
bash scripts/build-app.sh release
bash scripts/build-cli.sh release
```

Both scripts apply the configured signature after assembling their artifact and verify it. A configured identity that cannot sign fails the build; it does not silently fall back to ad-hoc signing. Contributors without an identity get a valid ad-hoc signature, with a warning about repeated Keychain prompts. Direct `swift build` / `swift run` bypasses this packaging/signing step.

Keep the application bundle identifier and signing identity consistent when updating an installed copy. If copying the executable or changing Info.plist in a separately named QA bundle, sign that **final bundle** afterward:

```sh
bash scripts/sign-local.sh '/path/to/Pi Swift QA.app'
```

Do not change the identifier of an existing QA bundle merely to match the normal app: that can reset preferences and change its Keychain identity. The CLI has its own stable identifier, `dev.chenqing.pi-swift.pf`, and may require its own initial authorization.

The first transition from an ad-hoc build to a certificate-signed build can still require a system prompt. Complete it yourself and choose **Always Allow** if you trust the app. Later builds satisfying the same designated requirement can reuse that authorization. A locked Keychain, changed signing channel/identity or system access policy can still require interaction. Signing does not remove macOS authentication requirements, broaden credential access lists or store credentials outside Keychain.

This is local development signing with no timestamp. It is not notarized distribution or a clean-machine Gatekeeper acceptance check.

References: Apple's [code signature guide](https://developer.apple.com/library/archive/documentation/Security/Conceptual/CodeSigningGuide/AboutCS/AboutCS.html) and [TN3127: code requirements](https://developer.apple.com/documentation/technotes/tn3127-inside-code-signing-requirements).
