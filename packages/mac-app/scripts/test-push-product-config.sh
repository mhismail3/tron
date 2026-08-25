#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd -P)"
VALIDATE="$REPO_ROOT/scripts/validate-push-service-config.sh"

bash -n "$SCRIPT_DIR/bundle-gateway.sh" "$SCRIPT_DIR/ensure-gateway-bundle.sh" \
  "$SCRIPT_DIR/verify-gateway-payload.sh" "$VALIDATE"
grep -F '#include "../../../config/PushService.xcconfig"' "$REPO_ROOT/packages/ios-app/Configuration/Base.xcconfig" >/dev/null
grep -F 'cp "$REPO_ROOT/config/PushService.xcconfig" "$APP_DIR/"' "$SCRIPT_DIR/bundle-gateway.sh" >/dev/null
grep -F '"$PAYLOAD_DIR/app/PushService.xcconfig"' "$SCRIPT_DIR/verify-gateway-payload.sh" >/dev/null
grep -F 'cmp -s "$REPO_ROOT/config/PushService.xcconfig" "$APP_DIR/PushService.xcconfig"' "$SCRIPT_DIR/bundle-gateway.sh" >/dev/null
grep -F 'payload_channel=dev' "$SCRIPT_DIR/bundle-gateway.sh" >/dev/null
grep -F '"$EXPECTED_CHANNEL"' "$SCRIPT_DIR/verify-gateway-payload.sh" >/dev/null
if grep -R 'TRON_PUSH_SERVICE_ORIGIN' "$REPO_ROOT/packages/gateway/src" --include='*.ts' | grep -F 'environment.TRON_PUSH_SERVICE_ORIGIN' >/dev/null; then
  echo "Gateway must not accept a runtime Push origin" >&2
  exit 1
fi

temp="$(mktemp -d)"
trap 'rm -rf "$temp"' EXIT
valid=(
  'https:/$()/push.example.com'
  'https:/$()/tron-push-relay.account.workers.dev'
)
invalid=(
  'http:/$()/push.example.com'
  'https:/$()/127.0.0.1'
  'https:/$()/localhost'
  'https:/$()/relay.local'
  'https:/$()/-bad.example'
  'https:/$()/bad-.example'
  'https:/$()/bad..example'
  'https:/$()/push.example.com/path'
  'https:/$()/push.example.com:443'
)
for origin in "${valid[@]}"; do
  printf 'TRON_PUSH_SERVICE_ORIGIN = %s\n' "$origin" > "$temp/config"
  "$VALIDATE" "$temp/config" >/dev/null
done
for origin in "${invalid[@]}"; do
  printf 'TRON_PUSH_SERVICE_ORIGIN = %s\n' "$origin" > "$temp/config"
  if "$VALIDATE" "$temp/config" >/dev/null 2>&1; then
    echo "invalid Push origin was admitted: $origin" >&2
    exit 1
  fi
done
printf 'TRON_PUSH_SERVICE_ORIGIN =\n' > "$temp/config"
"$VALIDATE" --allow-empty "$temp/config" >/dev/null
if "$VALIDATE" "$temp/config" >/dev/null 2>&1; then
  echo "empty official Push origin was admitted" >&2
  exit 1
fi

origin="$(sed -nE 's/^[[:space:]]*TRON_PUSH_SERVICE_ORIGIN[[:space:]]*=[[:space:]]*(.*)[[:space:]]*$/\1/p' "$REPO_ROOT/config/PushService.xcconfig")"
if [[ -z "$origin" ]]; then
  set +e
  output="$($SCRIPT_DIR/bundle-gateway.sh --skip-install --skip-download 2>&1)"
  status=$?
  set -e
  [[ $status -eq 3 && "$output" == *"official builds require"* ]] || {
    echo "unconfigured official payload did not fail closed" >&2
    printf '%s\n' "$output" >&2
    exit 1
  }
fi
printf 'Push product configuration boundary passed\n'
