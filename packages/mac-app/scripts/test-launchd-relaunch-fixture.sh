#!/usr/bin/env bash
# Opt-in isolated launchd fixture for Stable-style handled-exit relaunch.
# Run only with: TRON_RUN_LAUNCHD_FIXTURE=1 ./test-launchd-relaunch-fixture.sh
set -euo pipefail

[[ "$(uname -s)" == "Darwin" ]] || { echo "macOS is required" >&2; exit 77; }
[[ "${TRON_RUN_LAUNCHD_FIXTURE:-}" == "1" ]] || {
    echo "set TRON_RUN_LAUNCHD_FIXTURE=1 to run the isolated launchd fixture" >&2
    exit 77
}

uid="$(id -u)"
label="com.example.tron-gateway-relaunch.${uid}.$$"
temp="$(mktemp -d "${TMPDIR:-/tmp}/tron-launchd-fixture.XXXXXX")"
plist="$temp/$label.plist"
selection="$temp/current.json"
log="$temp/launches.log"
child="$temp/fake-gateway.sh"

cleanup() {
    /bin/launchctl bootout "gui/$uid/$label" >/dev/null 2>&1 || true
    rm -rf "$temp"
}
trap cleanup EXIT INT TERM HUP

cat > "$child" <<'CHILD'
#!/usr/bin/env bash
set -euo pipefail
selection="$1"
log="$2"
trap 'exit 0' TERM INT
printf '%s\t%s\n' "$$" "$(cat "$selection")" >> "$log"
while :; do sleep 1; done
CHILD
chmod 0700 "$child"
printf '%s\n' 'first-selection' > "$selection"

cat > "$plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>$label</string>
  <key>ProgramArguments</key>
  <array><string>$child</string><string>$selection</string><string>$log</string></array>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key><true/>
  <key>ThrottleInterval</key><integer>1</integer>
</dict>
</plist>
PLIST
plutil -lint "$plist" >/dev/null

wait_for_lines() {
    local expected="$1"
    for _ in {1..100}; do
        [[ -f "$log" ]] && [[ "$(wc -l < "$log" | tr -d ' ')" -ge "$expected" ]] && return 0
        sleep 0.1
    done
    echo "timed out waiting for launch $expected" >&2
    return 1
}

/bin/launchctl bootstrap "gui/$uid" "$plist"
wait_for_lines 1
first_pid="$(awk 'NR==1 { print $1 }' "$log")"
[[ "$(awk -F '\t' 'NR==1 { print $2 }' "$log")" == "first-selection" ]]

printf '%s\n' 'second-selection' > "$selection"
kill -TERM "$first_pid"
wait_for_lines 2
second_pid="$(awk 'NR==2 { print $1 }' "$log")"
[[ "$second_pid" != "$first_pid" ]]
[[ "$(awk -F '\t' 'NR==2 { print $2 }' "$log")" == "second-selection" ]]
printf 'launchd fixture passed: handled exit produced a new PID and reread current.json\n'
