import { execFileSync, spawn, type ExecFileSyncOptionsWithStringEncoding } from "node:child_process";
import { existsSync, mkdirSync } from "node:fs";
import { join, resolve } from "node:path";

export const NATIVE_EXEC_STALL_THRESHOLD_MS = 5_000;

export const NATIVE_EXEC_STALL_DIRECTORY = resolve("test-results", "native-exec-stalls");

export function execFileSyncWithStallCapture(
  file: string,
  args: readonly string[],
  options: ExecFileSyncOptionsWithStringEncoding,
  capture: { label: string; thresholdMs?: number; directory?: string },
): string {
  const directory = capture.directory ?? NATIVE_EXEC_STALL_DIRECTORY;
  mkdirSync(directory, { recursive: true });
  const record = join(directory, `${capture.label}-${process.pid}-${Date.now()}.log`);
  const seconds = ((capture.thresholdMs ?? NATIVE_EXEC_STALL_THRESHOLD_MS) / 1000).toFixed(3);
  const watcher = spawn("/bin/sh", ["-c", WATCHER, "stall-capture", seconds, String(process.pid), file, record],
    { detached: true, stdio: "ignore" });
  watcher.unref();
  try {
    return execFileSync(file, args, options);
  } finally {
    try { process.kill(-watcher.pid!, "SIGKILL"); } catch { }
    for (const path of [record, `${record}.partial`]) if (existsSync(path)) process.stderr.write(`native exec stall captured: ${path}\n`);
  }
}

const WATCHER = `
sleep "$1" || exit 0
child=$(pgrep -P "$2" -f "$3" | head -1)
{
  echo "native exec stall: alive past $1 s"
  echo "time: $(date -u +%FT%TZ)"
  echo "executable: $3"
  echo "load: $(sysctl -n vm.loadavg)"
  echo "== processes"; ps -o pid,ppid,pgid,etime,stat,pcpu,rss,command -p "$2"\${child:+,$child}
  if [ -n "$child" ]; then echo "== child stdio"; lsof -nP -p "$child" -a -d 0,1,2; fi
  echo "== parent unix sockets"; lsof -nP -p "$2" -a -U
  if [ -n "$child" ]; then echo "== child sample"; sample "$child" 1 -mayDie 2>&1; fi
  echo "== parent sample"; sample "$2" 1 -mayDie 2>&1
} > "$4.partial" 2>&1
mv "$4.partial" "$4"
`;
