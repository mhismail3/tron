#!/usr/bin/env bash
# Stage the app inputs into the bundler-owned fresh directory.
set -euo pipefail
[[ $# == 2 ]] || { echo 'usage: stage-gateway-app.sh GATEWAY_DIR APP_DIR' >&2; exit 64; }
GATEWAY_DIR="$1"
APP_DIR="$2"
REPO_ROOT="$(cd "$GATEWAY_DIR/../.." && pwd)"
stop_stage() {
  local status="$1" child
  trap - EXIT HUP INT TERM
  for child in $(jobs -pr); do kill -TERM "$child" 2>/dev/null || :; done
  wait || :
  exit "$status"
}
trap 'stop_stage "$?"' EXIT
trap 'stop_stage 129' HUP
trap 'stop_stage 130' INT
trap 'stop_stage 143' TERM
stage_child() { "$@" <&0 & wait "$!"; }
stage_child mkdir -p "$APP_DIR/scripts"
stage_child cp -R "$GATEWAY_DIR/dist" "$APP_DIR/dist"
stage_child cp "$GATEWAY_DIR/package.json" "$GATEWAY_DIR/package-lock.json" "$APP_DIR/"
stage_child cp "$REPO_ROOT/config/PushService.xcconfig" "$APP_DIR/"
stage_child cp "$REPO_ROOT/scripts/gateway-payload-deploy.mjs" "$APP_DIR/scripts/"
stage_child cp "$GATEWAY_DIR/pi-coding-agent-patch.json" "$APP_DIR/"
stage_child python3 - "$GATEWAY_DIR" "$APP_DIR" <<'PY'
import json, pathlib, shutil, sys
source, target = map(pathlib.Path, sys.argv[1:])
relative = pathlib.PurePosixPath(json.loads((target / 'pi-coding-agent-patch.json').read_text())['artifact']['path'])
if relative.is_absolute() or '..' in relative.parts or relative.parts[:2] != ('third_party', 'pi-coding-agent') or len(relative.parts) != 3:
    raise SystemExit('pi-coding-agent artifact path must be third_party/pi-coding-agent/<file>')
(target / relative).parent.mkdir(parents=True, exist_ok=True)
shutil.copyfile(source / relative, target / relative)
PY
stage_child cp "$GATEWAY_DIR/pi-subagents-pin.json" "$APP_DIR/"
stage_child cp "$GATEWAY_DIR/scripts/check-pi-subagents.mjs" "$GATEWAY_DIR/scripts/install-pi-subagents.mjs" "$APP_DIR/scripts/"
stage_child python3 - "$GATEWAY_DIR" "$APP_DIR" <<'PY'
import json, pathlib, shutil, sys
source, target = map(pathlib.Path, sys.argv[1:])
pin = json.loads((target / 'pi-subagents-pin.json').read_text())
for selection in (pin, pin.get('previous')):
    if selection is None:
        continue
    for record in (selection.get('sourceArchive', selection), selection['lockfile'], selection['closure']):
        relative = pathlib.PurePosixPath(record['path'])
        if relative.is_absolute() or '..' in relative.parts or relative.parts[0] != 'artifacts':
            raise SystemExit('provider artifact path must be confined to artifacts/')
        destination = target / relative
        destination.parent.mkdir(parents=True, exist_ok=True)
        shutil.copyfile(source / relative, destination)
PY
stage_child node "$APP_DIR/scripts/check-pi-subagents.mjs"
