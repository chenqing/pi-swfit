#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
swift build --product PiPlayground
pi_bin_dir=$(swift build --show-bin-path)
pi_app="$PWD/.build/PiPlayground.app"
mkdir -p "$pi_app/Contents/MacOS"
cp "$pi_bin_dir/PiPlayground" "$pi_app/Contents/MacOS/"
cat > "$pi_app/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?><!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd"><plist version="1.0"><dict><key>CFBundleExecutable</key><string>PiPlayground</string><key>CFBundleIdentifier</key><string>dev.chenqing.pi-playground</string><key>CFBundleName</key><string>Pi Playground</string><key>CFBundlePackageType</key><string>APPL</string><key>LSMinimumSystemVersion</key><string>14.0</string><key>NSHighResolutionCapable</key><true/></dict></plist>
PLIST
open "$pi_app"
