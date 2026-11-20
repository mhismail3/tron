#!/bin/bash
# Build, ad-hoc sign and install the unlock-lease prototype inside a disposable macOS guest only.
set -euo pipefail
[ "$(sysctl -n kern.hv_vmm_present)" = 1 ] || { echo "refusing: not a VM guest" >&2; exit 1; }
src="$(cd "$(dirname "$0")/.." && pwd)"
out="$HOME/tron-unlock"
plugins=/Library/Security/SecurityAgentPlugins
broker="/Library/Application Support/Tron/tron-unlock-broker"
mkdir -p "$out/build"
cd "$out/build"

swiftc -O -o tron-unlock-broker "$src/broker/main.swift"
codesign -f -s - -i com.tron.unlock.broker tron-unlock-broker
requirement="$(codesign -d -r- tron-unlock-broker 2>&1 | sed -n 's/^#* *designated => //p')"
[ -n "$requirement" ] || { echo "no broker designated requirement" >&2; exit 1; }
printf '#define BROKER_REQUIREMENT "%s"\n' "${requirement//\"/\\\"}" > requirement.h

rm -rf TronUnlock.bundle && mkdir -p TronUnlock.bundle/Contents/MacOS
clang -O2 -bundle -I. -o TronUnlock.bundle/Contents/MacOS/TronUnlock "$src/plugin/TronUnlock.c" -framework Security -framework CoreFoundation
cp "$src/plugin/Info.plist" TronUnlock.bundle/Contents/Info.plist
codesign -f -s - -o runtime TronUnlock.bundle

case "${1:-install}" in
install)
  [ -f "$out/screensaver.backup.plist" ] || security authorizationdb read system.login.screensaver > "$out/screensaver.backup.plist"
  sudo rm -rf "$plugins/TronUnlock.bundle"
  sudo cp -R TronUnlock.bundle "$plugins/"
  sudo chown -R root:wheel "$plugins/TronUnlock.bundle"
  sudo install -d -o root -g wheel /Library/Application\ Support/Tron
  sudo install -o root -g wheel -m 755 tron-unlock-broker "$broker"
  security authorizationdb read system.login.screensaver > current.plist
  sudo security authorizationdb write com.tron.unlock < "$src/guest/right.plist"
  plutil -replace rule -json '["com.tron.unlock","use-login-window-ui"]' current.plist
  plutil -replace k-of-n -integer 1 current.plist
  sudo security authorizationdb write system.login.screensaver < current.plist
  sudo sqlite3 "/Library/Application Support/com.apple.TCC/TCC.db" "insert or replace into access (service,client,client_type,auth_value,auth_reason,auth_version,flags) values ('kTCCServiceListenEvent','$broker',1,2,4,1,0)"
  launchctl bootout "gui/$(id -u)/com.tron.unlock.broker" 2>/dev/null || true
  cp "$src/guest/com.tron.unlock.broker.plist" "$HOME/Library/LaunchAgents/"
  launchctl bootstrap "gui/$(id -u)" "$HOME/Library/LaunchAgents/com.tron.unlock.broker.plist"
  ;;
uninstall)
  launchctl bootout "gui/$(id -u)/com.tron.unlock.broker" 2>/dev/null || true
  rm -f "$HOME/Library/LaunchAgents/com.tron.unlock.broker.plist"
  sudo security authorizationdb write system.login.screensaver < "$out/screensaver.backup.plist"
  sudo security authorizationdb remove com.tron.unlock || true
  sudo rm -rf "$plugins/TronUnlock.bundle" "$broker"
  ;;
esac
security authorizationdb read system.login.screensaver 2>/dev/null | plutil -p - | sed -n '/rule/,/]/p'
