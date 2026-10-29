#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
configuration="${1:-release}"
case "$configuration" in debug|release) ;; *) echo "Usage: $0 [debug|release]" >&2; exit 2 ;; esac
swift build -c "$configuration" --product pf
pi_bin_dir=$(swift build -c "$configuration" --show-bin-path)
bash scripts/sign-local.sh "$pi_bin_dir/pf" dev.chenqing.pi-swift.pf
printf '%s\n' "$pi_bin_dir/pf"
