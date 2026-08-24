#!/usr/bin/env bash
# Validate the one maintainer-owned public Tron Push origin shared by official clients.
set -euo pipefail

allow_empty=0
if [[ "${1:-}" == "--allow-empty" ]]; then
    allow_empty=1
    shift
fi
[[ $# -eq 1 ]] || { echo "usage: $0 [--allow-empty] <PushService.xcconfig>" >&2; exit 64; }
config="$1"
[[ -f "$config" && ! -L "$config" ]] || { echo "missing or unsafe PushService.xcconfig: $config" >&2; exit 3; }

assignments=()
while IFS= read -r line; do assignments+=("$line"); done < <(sed -nE 's/^[[:space:]]*TRON_PUSH_SERVICE_ORIGIN[[:space:]]*=[[:space:]]*(.*)[[:space:]]*$/\1/p' "$config")
[[ ${#assignments[@]} -eq 1 ]] || { echo "PushService.xcconfig must contain exactly one TRON_PUSH_SERVICE_ORIGIN assignment" >&2; exit 3; }
origin="${assignments[0]}"
if [[ -z "$origin" ]]; then
    ((allow_empty)) && exit 0
    echo "official builds require config/PushService.xcconfig TRON_PUSH_SERVICE_ORIGIN" >&2
    exit 3
fi
prefix='https:/$()/'
[[ "$origin" == "$prefix"* ]] || { echo "TRON_PUSH_SERVICE_ORIGIN must be one exact public HTTPS origin in xcconfig form" >&2; exit 3; }
host="${origin#"$prefix"}"
[[ -n "$host" && ${#host} -le 253 && "$host" == *.* && "$host" != .* && "$host" != *. && "$host" != *..* ]] || {
    echo "TRON_PUSH_SERVICE_ORIGIN must contain one valid public DNS hostname" >&2; exit 3;
}
[[ "$host" =~ ^[A-Za-z0-9.-]+$ && ! "$host" =~ ^[0-9.]+$ ]] || {
    echo "TRON_PUSH_SERVICE_ORIGIN must contain one valid public DNS hostname" >&2; exit 3;
}
lower_host="$(printf '%s' "$host" | tr '[:upper:]' '[:lower:]')"
case "$lower_host" in
    localhost|*.localhost|*.local|*.internal) echo "TRON_PUSH_SERVICE_ORIGIN must not use a local hostname" >&2; exit 3 ;;
esac
IFS='.' read -r -a labels <<< "$host"
for label in "${labels[@]}"; do
    [[ ${#label} -le 63 && "$label" =~ ^[A-Za-z0-9]([A-Za-z0-9-]*[A-Za-z0-9])?$ ]] || {
        echo "TRON_PUSH_SERVICE_ORIGIN contains an invalid DNS label" >&2; exit 3;
    }
done
printf '%s\n' "$origin"
