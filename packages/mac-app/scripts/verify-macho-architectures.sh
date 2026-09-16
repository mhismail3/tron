#!/usr/bin/env bash
# Verify one exact Mach-O architecture set without relying on lipo's
# version-sensitive multi-architecture -verify_arch argument parsing.
set -euo pipefail

[[ $# -ge 2 ]] || { echo "usage: verify-macho-architectures.sh BINARY ARCH..." >&2; exit 64; }
BINARY="$1"
shift
[[ -f "$BINARY" && ! -L "$BINARY" ]] || { echo "Mach-O input must be a regular file" >&2; exit 2; }

[[ "$1" =~ ^[A-Za-z0-9_]+$ ]] || { echo "invalid expected architecture" >&2; exit 64; }
EXPECTED=("$1")
shift
for architecture in "$@"; do
    [[ "$architecture" =~ ^[A-Za-z0-9_]+$ ]] || { echo "invalid expected architecture" >&2; exit 64; }
    for existing in "${EXPECTED[@]}"; do
        [[ "$existing" != "$architecture" ]] || { echo "duplicate expected architecture" >&2; exit 64; }
    done
    EXPECTED+=("$architecture")
done

LIPO="$(command -v lipo 2>/dev/null || true)"
[[ -n "$LIPO" ]] || { echo "lipo is unavailable" >&2; exit 69; }
ARCH_OUTPUT="$("$LIPO" -archs "$BINARY" 2>/dev/null)" || { echo "unable to inspect Mach-O architectures" >&2; exit 2; }
[[ -n "$ARCH_OUTPUT" ]] || { echo "Mach-O architecture set is empty" >&2; exit 2; }
read -r -a ACTUAL <<< "$ARCH_OUTPUT"
[[ "${#ACTUAL[@]}" -eq "${#EXPECTED[@]}" ]] || { echo "Mach-O architecture set differs from the release pin" >&2; exit 2; }

for architecture in "${EXPECTED[@]}"; do
    found=false
    for actual in "${ACTUAL[@]}"; do
        if [[ "$actual" == "$architecture" ]]; then found=true; break; fi
    done
    [[ "$found" == true ]] || { echo "Mach-O architecture set differs from the release pin" >&2; exit 2; }
done
