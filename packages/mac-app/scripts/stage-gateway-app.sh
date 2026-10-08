#!/usr/bin/env bash
# Stage the app inputs into the bundler-owned fresh directory. Dependency
# installation, fingerprinting and publication remain the bundler's lifecycle.
set -euo pipefail
[[ $# == 2 ]] || { echo 'usage: stage-gateway-app.sh GATEWAY_DIR APP_DIR' >&2; exit 64; }
GATEWAY_DIR="$1"
APP_DIR="$2"
REPO_ROOT="$(cd "$GATEWAY_DIR/../.." && pwd)"
mkdir -p "$APP_DIR/scripts"
cp -R "$GATEWAY_DIR/dist" "$APP_DIR/dist"
cp "$GATEWAY_DIR/package.json" "$GATEWAY_DIR/package-lock.json" "$APP_DIR/"
cp "$REPO_ROOT/config/PushService.xcconfig" "$APP_DIR/"
cp "$GATEWAY_DIR/scripts/ensure-node-pty-helper.mjs" "$APP_DIR/scripts/"
cp "$REPO_ROOT/scripts/gateway-payload-deploy.mjs" "$APP_DIR/scripts/"
# Pin metadata and both immutable selections share the fingerprinted app tree.
# No provider is installed into a runtime home during packaging.
cp "$GATEWAY_DIR/pi-subagents-pin.json" "$APP_DIR/"
cp "$GATEWAY_DIR/scripts/check-pi-subagents.mjs" "$GATEWAY_DIR/scripts/install-pi-subagents.mjs" "$APP_DIR/scripts/"
python3 - "$GATEWAY_DIR" "$APP_DIR" <<'PY'
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
node "$APP_DIR/scripts/check-pi-subagents.mjs"
