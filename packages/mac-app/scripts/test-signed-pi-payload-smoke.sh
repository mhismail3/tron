#!/usr/bin/env bash
# Read-only smoke test for a built and signed TronMac.app. It executes only the
# host-native embedded Node and Pi projection; it never starts the Gateway or
# invokes the foreign architecture.
set -euo pipefail
APP_PATH="${1:-}"
[[ -n "$APP_PATH" && "$APP_PATH" == *.app ]] || {
  echo "usage: test-signed-pi-payload-smoke.sh BUILT_TronMac.app" >&2
  exit 64
}
APP_PATH="$(realpath "$APP_PATH")"
[[ -d "$APP_PATH" && ! -L "$APP_PATH" ]] || { echo "built app is missing or symlinked" >&2; exit 2; }
LOGIN_ITEM="$APP_PATH/Contents/Library/LoginItems/Tron Agent.app"
[[ -d "$LOGIN_ITEM" && ! -L "$LOGIN_ITEM" ]] || { echo "signed Login Item is missing" >&2; exit 2; }
codesign --verify --deep --strict "$APP_PATH" >/dev/null 2>&1 || { echo "outer TronMac.app signature invalid" >&2; exit 2; }
codesign --verify --deep --strict "$LOGIN_ITEM" >/dev/null 2>&1 || { echo "Login Item signature invalid" >&2; exit 2; }
PAYLOAD="$APP_PATH/Contents/Resources/Gateway"
APP="$PAYLOAD/app"
LAUNCHER="$LOGIN_ITEM/Contents/MacOS/tron"
[[ -f "$LAUNCHER" && ! -L "$LAUNCHER" && -x "$LAUNCHER" ]] || { echo "signed Login Item launcher is missing" >&2; exit 2; }
RUNTIME="$PAYLOAD/runtime"
[[ -d "$PAYLOAD" && ! -L "$PAYLOAD" && -d "$APP" && ! -L "$APP" && -d "$RUNTIME" && ! -L "$RUNTIME" ]] || {
  echo "built app Gateway payload is missing or substituted" >&2; exit 2;
}
case "$(uname -m)" in
  arm64) HOST_ARCH=arm64 ;;
  x86_64) HOST_ARCH=x86_64 ;;
  *) echo "unsupported host architecture" >&2; exit 2 ;;
esac
case "$HOST_ARCH" in arm64) ARCH=arm64 ;; x86_64) ARCH=x64 ;; esac
ALIAS_DIR="$RUNTIME/bin-$ARCH"
NODE="$RUNTIME/node-$ARCH"
PI_ALIAS="$ALIAS_DIR/pi"
PI_PROJECTION="$APP/node_modules/.bin/pi"
PI_PACKAGE="$APP/node_modules/@earendil-works/pi-coding-agent"
[[ -f "$APP/dist/index.js" && ! -L "$APP/dist/index.js" ]] || { echo "built Gateway entrypoint is missing" >&2; exit 2; }
for architecture in arm64 x64; do
  candidate="$RUNTIME/node-$architecture"
  [[ -f "$candidate" && ! -L "$candidate" && -x "$candidate" ]] || { echo "Node $architecture runtime is invalid" >&2; exit 2; }
  [[ "$(file "$candidate" 2>/dev/null)" == *Mach-O* ]] || { echo "Node $architecture runtime is not Mach-O" >&2; exit 2; }
  [[ "$(lipo -archs "$candidate" 2>/dev/null)" == "$([ "$architecture" = arm64 ] && echo arm64 || echo x86_64)" ]] || { echo "Node $architecture runtime is not thin/canonical" >&2; exit 2; }
  codesign --verify --deep --strict "$candidate" >/dev/null 2>&1 || { echo "Node $architecture runtime signature invalid" >&2; exit 2; }
  entitlements="$(codesign -d --entitlements :- "$candidate" 2>/dev/null || true)"
  [[ "$entitlements" == *'<key>com.apple.security.cs.allow-jit</key>'*'<true/>'* ]] || { echo "Node $architecture runtime lacks allow-jit" >&2; exit 2; }
  alias="$RUNTIME/bin-$architecture/node"
  [[ -L "$alias" && "$(readlink "$alias")" == "../node-$architecture" && "$(realpath "$alias")" == "$(realpath "$candidate")" ]] || { echo "Node $architecture alias is invalid" >&2; exit 2; }
done
[[ -L "$PI_PROJECTION" && -L "$PI_ALIAS" && ! -L "$PI_PACKAGE" && "$(readlink "$PI_ALIAS")" == "../../app/node_modules/.bin/pi" ]] || { echo "Pi npm aliases are invalid" >&2; exit 2; }
PI_REAL="$(realpath "$PI_PROJECTION")"; PACKAGE_REAL="$(realpath "$PI_PACKAGE")"; NODE_MODULES_REAL="$(realpath "$APP/node_modules")"
[[ "$PACKAGE_REAL" == "$NODE_MODULES_REAL"/* && "$PI_REAL" == "$PACKAGE_REAL"/* && -f "$PI_REAL" && -x "$PI_REAL" && "$(realpath "$PI_ALIAS")" == "$PI_REAL" ]] || { echo "Pi projection or package root escapes app/node_modules" >&2; exit 2; }
EXPECTED_FINGERPRINT="$(plutil -extract payloadFingerprint raw -o - "$PAYLOAD/manifest.json" 2>/dev/null || true)"
ACTUAL_FINGERPRINT="$("$LAUNCHER" --fingerprint "$PAYLOAD")"
[[ "$EXPECTED_FINGERPRINT" =~ ^[0-9a-f]{64}$ && "$ACTUAL_FINGERPRINT" == "$EXPECTED_FINGERPRINT" ]] || { echo "signed launcher fingerprint disagrees with manifest" >&2; exit 2; }
TMP="$(mktemp -d "${TMPDIR:-/tmp}/tron-pi-smoke.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/pi-coding-agent"
export PI_CODING_AGENT_DIR="$TMP/pi-coding-agent"
export PATH="$ALIAS_DIR:/usr/bin:/bin:/usr/sbin:/sbin"
(cd "$APP" && node - "$PI_PACKAGE" "$PI_PROJECTION" <<'NODE'
const fs = require("node:fs");
const path = require("node:path");
const [packageRoot, projection] = process.argv.slice(2);
const info = fs.lstatSync(path.join(packageRoot, "package.json"));
if (!info.isFile() || info.isSymbolicLink() || info.size > 64 * 1024) throw new Error("package metadata is invalid or oversized");
const metadata = JSON.parse(fs.readFileSync(path.join(packageRoot, "package.json"), "utf8"));
const bin = metadata.bin && typeof metadata.bin === "object" ? metadata.bin.pi : undefined;
if (typeof bin !== "string" || !bin || path.isAbsolute(bin) || bin.split(/[\\/]/u).includes("..")) throw new Error("unsafe or missing bin.pi");
const declared = fs.realpathSync(path.resolve(packageRoot, bin));
const expected = path.relative(path.dirname(projection), path.resolve(packageRoot, bin));
if (fs.readlinkSync(projection) !== expected || declared !== fs.realpathSync(projection)) throw new Error(".bin/pi disagrees with declared bin.pi");
NODE
)
NODE_OUTPUT="$(cd "$APP" && node --version 2>&1 | head -c 256)"; [[ "$NODE_OUTPUT" == v* ]] || { echo "embedded Node --version failed" >&2; exit 2; }
PI_OUTPUT="$(cd "$APP" && pi --version 2>&1 | head -c 256)"; [[ -n "$PI_OUTPUT" ]] || { echo "embedded Pi --version failed" >&2; exit 2; }
(cd "$APP" && node --input-type=module - "$TMP" <<'NODE'
import { strict as assert } from "node:assert";
import { mkdirSync } from "node:fs";
import { join } from "node:path";
const [temp] = process.argv.slice(2);
for (const name of ["@earendil-works/pi-agent-core", "@earendil-works/pi-ai", "@earendil-works/pi-coding-agent", "@earendil-works/pi-tui"]) await import(name);
const { SessionManager } = await import("@earendil-works/pi-coding-agent");
const { renderSessionCutToHtml } = await import("./dist/sessions/session-export.js");
const sessionDir = join(temp, "sessions");
mkdirSync(sessionDir, { recursive: true });
const manager = SessionManager.create(temp, sessionDir);
manager.appendMessage({ role: "user", content: "Tron signed Pi smoke fixture", timestamp: Date.now() });
manager.appendMessage({
  role: "assistant", content: [{ type: "text", text: "smoke response" }],
  api: "fixture", provider: "fixture", model: "fixture",
  usage: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0, totalTokens: 0,
    cost: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0, total: 0 } },
  stopReason: "stop", timestamp: Date.now(),
});
const sessionFile = manager.getSessionFile();
assert.ok(sessionFile, "SessionManager did not materialize canonical JSONL");
const opened = SessionManager.open(sessionFile, sessionDir);
assert.equal(opened.getSessionId(), manager.getSessionId());
const html = join(temp, "export.html");
const size = await renderSessionCutToHtml(sessionFile, html);
assert.ok(size > 0, "standalone session export was empty");
NODE
)
[[ -s "$TMP/export.html" ]] || { echo "staged session export produced no HTML" >&2; exit 2; }
printf 'signed Pi payload smoke passed (Node %s, Pi %s, signed app/Login Item, canonical session append/open/export)\n' "$NODE_OUTPUT" "$PI_OUTPUT"
