#!/bin/bash
# Keep local upgrades recognizable to Keychain without committing a developer identity.
set -euo pipefail
if [[ $# -lt 1 || $# -gt 2 ]]; then
    echo "Usage: $0 APP_OR_EXECUTABLE [EXECUTABLE_IDENTIFIER]" >&2
    exit 2
fi
pi_identity="${PI_CODESIGN_IDENTITY:-}"
pi_identity_file="${HOME}/.config/pi-swift/codesign-identity"
if [[ -z "$pi_identity" && -f "$pi_identity_file" ]]; then
    pi_identity=$(cat "$pi_identity_file")
    if [[ -z "$pi_identity" ]]; then
        echo "Empty signing identity in $pi_identity_file" >&2
        exit 1
    fi
fi
if [[ -z "$pi_identity" ]]; then
    echo "No local signing identity configured; using ad-hoc signing. Keychain may ask again after rebuilding. See Docs/LOCAL_SIGNING.md." >&2
    pi_identity="-"
elif [[ "$pi_identity" == "-" ]]; then
    echo "Ad-hoc signing does not preserve Keychain identity across builds. Choose a certificate identity." >&2
    exit 1
fi
pi_args=(--force --sign "$pi_identity" --timestamp=none)
if [[ $# -eq 2 ]]; then
    pi_args+=(--identifier "$2")
fi
codesign "${pi_args[@]}" "$1"
codesign --verify --strict "$1"
