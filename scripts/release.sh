#!/bin/bash
# Produce an independently verifiable, notarized local distribution. Never publishes.
set -euo pipefail
cd "$(dirname "$0")/.."
pi_version="${1:-0.1.0}"
pi_build="${2:-$(date -u +%Y%m%d%H%M)}"
: "${PI_NOTARY_PROFILE:?Set PI_NOTARY_PROFILE to an existing notarytool Keychain profile}"
[[ "$pi_version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ && "$pi_build" =~ ^[0-9]+$ ]] || { echo "Usage: $0 VERSION NUMERIC_BUILD" >&2; exit 2; }
pi_identity="${PI_CODESIGN_IDENTITY:-}"
if [[ -z "$pi_identity" && -f "$HOME/.config/pi-swift/codesign-identity" ]]; then
    pi_identity=$(cat "$HOME/.config/pi-swift/codesign-identity")
fi
[[ -n "$pi_identity" && "$pi_identity" != "-" ]] || { echo "A Developer ID signing identity is required." >&2; exit 1; }
[[ -z "$(git status --porcelain --untracked-files=no)" || "${PI_RELEASE_ALLOW_DIRTY:-0}" == 1 ]] || { echo "Commit source changes before packaging (or explicitly set PI_RELEASE_ALLOW_DIRTY=1)." >&2; exit 1; }
pi_arch=$(uname -m)
[[ "$pi_arch" == arm64 || "$pi_arch" == x86_64 ]] || exit 1
pi_out="$PWD/.build/releases/$pi_version-$pi_build-$pi_arch"
[[ ! -e "$pi_out" ]] || { echo "Release directory already exists: $pi_out" >&2; exit 1; }
mkdir -p "$pi_out/staging"
# Build serially; the local packaging scripts also verify their signatures.
bash scripts/build-cli.sh release > "$pi_out/cli-build.log" 2>&1
bash scripts/build-app.sh release > "$pi_out/app-build.log" 2>&1
pi_bin=$(swift build -c release --show-bin-path)
[[ "$("$pi_bin/pf" --version)" == "pf $pi_version" ]] || { echo "pf version does not match requested release" >&2; exit 1; }
pi_app="$pi_out/staging/Pi Swift.app"
ditto '.build/Pi Swift.app' "$pi_app"
cp "$pi_bin/pf" "$pi_app/Contents/MacOS/pf"
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $pi_version" "$pi_app/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $pi_build" "$pi_app/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Add :PiSourceRevision string $(git rev-parse HEAD)" "$pi_app/Contents/Info.plist"
cp LICENSE THIRD_PARTY_NOTICES.md "$pi_app/Contents/Resources/"
codesign --force --options runtime --timestamp --sign "$pi_identity" --identifier dev.chenqing.pi-swift.pf "$pi_app/Contents/MacOS/pf"
codesign --force --options runtime --timestamp --sign "$pi_identity" "$pi_app"
codesign --verify --deep --strict "$pi_app"
codesign -dv --verbose=4 "$pi_app" 2> "$pi_out/signature.txt"
grep -q 'Authority=Developer ID Application:' "$pi_out/signature.txt" || { echo "Distribution requires Developer ID Application signing." >&2; exit 1; }
notarize() {
    local artifact="$1" report="$2"
    xcrun notarytool submit "$artifact" --keychain-profile "$PI_NOTARY_PROFILE" --wait --output-format json > "$report"
    python3 - "$report" <<'PY'
import json,sys
result=json.load(open(sys.argv[1]))
if result.get('status') != 'Accepted':
    raise SystemExit('Notarization not accepted: '+str(result))
print('Notarization accepted: '+result['id'])
PY
}
ditto -c -k --keepParent "$pi_app" "$pi_out/notarize-app.zip"
notarize "$pi_out/notarize-app.zip" "$pi_out/notary-app.json"
xcrun stapler staple "$pi_app"
xcrun stapler validate "$pi_app"
spctl --assess --type execute --verbose=2 "$pi_app"
ln -s /Applications "$pi_out/staging/Applications"
cat > "$pi_out/staging/Read Me.txt" <<TXT
Pi Swift $pi_version ($pi_build) — $pi_arch

Drag Pi Swift.app into Applications, then open it.
The bundled CLI is /Applications/Pi Swift.app/Contents/MacOS/pf.
Run it with --help for usage. Requires macOS 14 or later.

Default data directory: ~/.pf/agent (or PF_AGENT_DIR when launched from a shell).
Installing this package does not migrate a separate development/QA data directory.
No account, credential or conversation data is included.
TXT
pi_dmg="$pi_out/Pi-Swift-$pi_version-macOS-$pi_arch.dmg"
hdiutil create -volname "Pi Swift $pi_version" -srcfolder "$pi_out/staging" -format UDZO "$pi_dmg"
codesign --force --timestamp --sign "$pi_identity" "$pi_dmg"
notarize "$pi_dmg" "$pi_out/notary-dmg.json"
xcrun stapler staple "$pi_dmg"
xcrun stapler validate "$pi_dmg"
hdiutil verify "$pi_dmg"
spctl --assess --type open --context context:primary-signature --verbose=2 "$pi_dmg"
(cd "$pi_out" && shasum -a 256 "$(basename "$pi_dmg")" > SHA256SUMS)
printf '\nRelease ready: %s\n' "$pi_dmg"
