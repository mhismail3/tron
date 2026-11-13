#!/bin/bash
# Read-only snapshot of this Mac's shared resources for agents. Changes nothing.
set -u
export LC_ALL=C
cores=$(sysctl -n hw.ncpu)
echo "host: $(hostname -s)  cores: $cores  memory: $(( $(sysctl -n hw.memsize) / 1073741824 )) GB  at: $(date -u +%FT%TZ)"
echo "load (1/5/15 min): $(sysctl -n vm.loadavg | tr -d '{}' | xargs)"
echo "cpu idle now: $(top -l 2 -n 0 -s 1 | awk '/CPU usage/ {idle=$7} END {print idle}')"
echo "memory free: $(memory_pressure 2>/dev/null | awk -F': ' '/free percentage/ {print $2}')  swap: $(sysctl -n vm.swapusage | awk '{print $6" used of "$3}')"
echo
echo "heavy processes (cpu%, minutes running, working directory or command):"
ps -Ao pid=,pcpu=,etime=,comm= | awk '{n=split($4,a,"/"); name=a[n]}
  name ~ /^(xcodebuild|xctest|swift-frontend|swift-build|clang|ld|node|vitest|python3?|Python|perl|ruby|cargo|rustc|go|java|ffmpeg)$/ && $2+0 >= 20 {print $1, $2, $3, name}' |
while read -r pid cpu etime name; do
  cwd=$(lsof -a -p "$pid" -d cwd -Fn 2>/dev/null | sed -n 's/^n//p' | sed "s|^$HOME|~|")
  printf '  %-7s %5s%%  %-11s %-14s %s\n' "$pid" "$cpu" "$etime" "$name" "${cwd:-?}"
done
echo
echo "test and build drivers (any cpu):"
ps -Ao pid=,etime=,command= | grep -E 'xcodebuild|xctest|tron-ios-test|ios-gateway-e2e-test|tools/verify/(verify|batch|mini|gateway)\.py|vitest|node --test' | grep -v -E 'grep|host-state' |
  sed -E "s|[^ ]*/Python\.app/Contents/MacOS/Python|python|; s|[^ ]*/usr/bin/xcodebuild|xcodebuild|; s|$HOME|~|g" | cut -c1-170 | sed 's/^/  /'
echo
echo "booted simulators: $(xcrun simctl list devices booted 2>/dev/null | grep -c Booted)  simulator processes over 20% cpu: $(ps -Ao pcpu=,command= | awk '$1+0 >= 20 && /CoreSimulator/ {c++} END {print c+0}')"
xcrun simctl list devices booted 2>/dev/null | grep Booted | sed 's/^ */  /'
lock="$HOME/Workspace/tron/scripts/ios-test-lock.py"
[ -f "$lock" ] && python3 "$lock" --list-host-slots 2>/dev/null
gw=/tmp/tron-full-gateway.lock
[ -s "$gw" ] && echo "full-Gateway lock last holder record: $(head -c 200 "$gw")"
