#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
./scripts/build-app.sh "${1:-debug}"
pi_app="$PWD/.build/Pi Swift.app"
if [[ -n "${PF_AGENT_DIR:-}" ]]; then
    open --env "PF_AGENT_DIR=$PF_AGENT_DIR" "$pi_app"
else
    open "$pi_app"
fi
