#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
configuration="${1:-debug}"
case "$configuration" in debug|release) ;; *) echo "Usage: $0 [debug|release]" >&2; exit 2 ;; esac
swift scripts/render-icon.swift >/dev/null
swift build -c "$configuration" --product PiSwift
pi_bin_dir=$(swift build -c "$configuration" --show-bin-path)
pi_app="$PWD/.build/Pi Swift.app"
pi_iconset="$PWD/.build/PiSwift.iconset"
mkdir -p "$pi_app/Contents/MacOS" "$pi_app/Contents/Resources" "$pi_iconset"
cp "$pi_bin_dir/PiSwift" "$pi_app/Contents/MacOS/PiSwift"
# Bundle.module searches resourceURL. Keep resources inside Contents so the
# final app has a sealable macOS bundle layout.
rm -rf "$pi_app/Pi_PiSwift.bundle"
ditto "$pi_bin_dir/Pi_PiSwift.bundle" "$pi_app/Contents/Resources/Pi_PiSwift.bundle"
for size in 16 32 128 256 512; do
    sips -z "$size" "$size" Examples/PiSwift/Assets/AppIcon.png --out "$pi_iconset/icon_${size}x${size}.png" >/dev/null
    double=$((size * 2))
    sips -z "$double" "$double" Examples/PiSwift/Assets/AppIcon.png --out "$pi_iconset/icon_${size}x${size}@2x.png" >/dev/null
done
iconutil -c icns "$pi_iconset" -o "$pi_app/Contents/Resources/AppIcon.icns"
cat > "$pi_app/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>PiSwift</string>
<key>CFBundleIdentifier</key><string>dev.chenqing.pi-swift</string>
<key>CFBundleName</key><string>Pi Swift</string>
<key>CFBundleDisplayName</key><string>Pi Swift</string>
<key>CFBundleIconFile</key><string>AppIcon</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>0.1.0</string>
<key>CFBundleVersion</key><string>1</string>
<key>LSMinimumSystemVersion</key><string>14.0</string>
<key>NSHighResolutionCapable</key><true/>
</dict></plist>
PLIST
bash scripts/sign-local.sh "$pi_app"
printf '%s\n' "$pi_app"
