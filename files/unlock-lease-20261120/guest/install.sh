#!/bin/bash
# Build, ad-hoc sign and install or uninstall the unlock-lease prototype inside a disposable macOS guest only.
set -euo pipefail
[ "$(sysctl -n kern.hv_vmm_present)" = 1 ] || { echo "refusing: not a VM guest" >&2; exit 1; }
src="$(cd "$(dirname "$0")/.." && pwd)"
out="$HOME/tron-unlock"
plugins=/Library/Security/SecurityAgentPlugins
home="/Library/Application Support/Tron"
broker="$home/tron-unlock-broker"
agent="$HOME/Library/LaunchAgents/com.tron.unlock.broker.plist"
backup="$out/screensaver.backup.plist"
tcc="/Library/Application Support/com.apple.TCC/TCC.db"
mkdir -p "$out/build" "$HOME/Library/LaunchAgents"
cd "$out/build"

restore_rule() {
  plutil -lint -s "$backup" && sudo security authorizationdb write system.login.screensaver < "$backup"
}

case "${1:-install}" in
install)
  if [ ! -s "$backup" ]; then
    security authorizationdb read system.login.screensaver > backup.tmp
    plutil -lint -s backup.tmp && mv backup.tmp "$backup"
  fi
  swiftc -O ${FAULTS:+-D FAULTS} -o tron-unlock-broker "$src/broker/main.swift"
  codesign -f -s - -i com.tron.unlock.broker tron-unlock-broker
  requirement="$(codesign -d -r- tron-unlock-broker 2>&1 | sed -n 's/^#* *designated => //p')"
  [ -n "$requirement" ] || { echo "no broker designated requirement" >&2; exit 1; }
  printf '#define BROKER_REQUIREMENT "%s"\n' "${requirement//\"/\\\"}" > requirement.h
  rm -rf TronUnlock.bundle && mkdir -p TronUnlock.bundle/Contents/MacOS
  clang -O2 -bundle -I. -o TronUnlock.bundle/Contents/MacOS/TronUnlock "$src/plugin/TronUnlock.c" -framework Security -framework CoreFoundation
  cp "$src/plugin/Info.plist" TronUnlock.bundle/Contents/Info.plist
  codesign -f -s - -o runtime TronUnlock.bundle

  trap 'echo "install failed; restoring the backed-up right" >&2; restore_rule' ERR
  sudo install -d -o root -g wheel -m 755 "$home"
  sudo install -d -o "$(id -u)" -g wheel -m 755 "$home/run"
  sudo install -o root -g wheel -m 755 tron-unlock-broker "$broker"
  sudo rm -rf "$plugins/TronUnlock.bundle"
  sudo cp -R TronUnlock.bundle "$plugins/"
  sudo chown -R root:wheel "$plugins/TronUnlock.bundle"
  sudo sqlite3 "$tcc" "insert or replace into access (service,client,client_type,auth_value,auth_reason,auth_version,flags) values ('kTCCServiceListenEvent','$broker',1,2,4,1,0)"
  launchctl bootout "gui/$(id -u)/com.tron.unlock.broker" 2>/dev/null || true
  cp "$src/guest/com.tron.unlock.broker.plist" "$agent"
  launchctl bootstrap "gui/$(id -u)" "$agent"
  for _ in $(seq 20); do [ -S "$home/run/plugin.sock" ] && break; sleep 0.25; done
  [ -S "$home/run/plugin.sock" ]
  sudo security authorizationdb write com.tron.unlock < "$src/guest/right.plist"
  cp "$backup" current.plist
  plutil -replace rule -json '["com.tron.unlock","use-login-window-ui"]' current.plist
  plutil -replace k-of-n -integer 1 current.plist
  sudo security authorizationdb write system.login.screensaver < current.plist
  trap - ERR
  ;;
uninstall)
  plutil -lint -s "$backup"
  restore_rule
  sudo security authorizationdb remove com.tron.unlock 2>/dev/null || true
  launchctl bootout "gui/$(id -u)/com.tron.unlock.broker" 2>/dev/null || true
  rm -f "$agent"
  sudo sqlite3 "$tcc" "delete from access where client='$broker'"
  sudo rm -rf "$plugins/TronUnlock.bundle" "$home"
  ;;
esac
security authorizationdb read system.login.screensaver 2>/dev/null | plutil -p - | sed -n '/rule/,/]/p'
