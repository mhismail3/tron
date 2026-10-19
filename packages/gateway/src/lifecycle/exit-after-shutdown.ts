import { spawn } from "node:child_process";

/** How long a finished shutdown may spend inside Node's own exit before it is killed. */
export const EXIT_STALL_GRACE_MS = 5_000;

// Runs in a separate process because nothing in the Gateway can run once its
// main thread is blocked inside process.exit. Its stdin is a pipe from the
// Gateway: EOF means the exit completed and the PID may already be reused, so
// it never signals after EOF. Only the Gateway holds the write end.
const WATCHER = `
const { appendFileSync } = require("node:fs");
const [pid, code, graceMs, logPath] = process.argv.slice(1);
let exited = false;
process.stdin.on("end", () => { exited = true; process.exit(0); });
process.stdin.resume();
setTimeout(() => {
  if (exited) return;
  if (logPath) {
    try {
      appendFileSync(logPath, JSON.stringify({
        timestamp: new Date().toISOString(),
        level: "warning",
        message: "Gateway exit stalled " + graceMs + " ms after its shutdown completed; killed pid " + pid,
        process: "gateway",
        ...(process.env.TRON_GATEWAY_RUNTIME_EPOCH ? { runtimeEpoch: process.env.TRON_GATEWAY_RUNTIME_EPOCH } : {}),
        ...(process.env.TRON_GATEWAY_PAYLOAD_VERSION ? { payloadVersion: process.env.TRON_GATEWAY_PAYLOAD_VERSION } : {}),
        event: "gateway.exit-stalled",
        source: "lifecycle",
        pid: Number(pid),
        code,
        durationMs: Number(graceMs),
      }) + "\\n", { mode: 0o600 });
    } catch {}
  }
  try { process.kill(Number(pid), "SIGKILL"); } catch {}
  process.exit(0);
}, Number(graceMs));
`;

/**
 * Ends the process after its shutdown has completed and been recorded.
 *
 * Node's native exit joins every libuv threadpool worker
 * (uv_library_shutdown -> uv__threadpool_cleanup -> uv_thread_join) and blocks
 * forever when one never returns for the exit message (#729, #1120). On macOS
 * that happens to idle workers: after hours of Gateway fs traffic, Darwin's
 * psynch condition variable can leave parked workers that no signal reaches
 * (https://github.com/libuv/libuv/issues/5280). The live Stable Gateway showed
 * three of four workers parked and never woken; the incident samples showed the
 * same three left behind with main in uv_thread_join.
 *
 * Nothing in the Gateway needs that join: every owned operation has settled and
 * been recorded before this point. So Node's exit runs unchanged (the `exit`
 * event and its listeners, then RunAtExit), except that its final native step
 * replaces the process image with `/bin/sh -c 'exit <code>'` instead of tearing
 * libuv down. The PID and its exit status are unchanged for launchd and the Mac
 * wrapper; no signal is involved, so exit 0 stays a successful exit.
 *
 * launchd relaunches the Gateway after any unsuccessful exit (KeepAlive with
 * SuccessfulExit=false), and a signal death is unsuccessful too. For a non-zero
 * code a kill therefore has the same outcome as the exit it replaces. Exit 0 is
 * a requested stop: a kill would be read as a crash and relaunch a Gateway its
 * caller asked to stop, so that exit is left to Node alone.
 */
export function exitAfterShutdown(code: number, logPath: string | undefined, graceMs = EXIT_STALL_GRACE_MS): never {
  // process.exit emits `exit`, then calls the undocumented process.reallyExit
  // (the same hook signal-exit wraps). Only that native step is replaced. The
  // experimental warning process.execve emits is never printed: it is queued
  // for a later tick. The pinned Node runtime always provides execve on macOS.
  (process as NodeJS.Process & { reallyExit(exitCode?: number | string | null): void }).reallyExit = (exitCode) => {
    process.execve!("/bin/sh", ["/bin/sh", "-c", `exit ${Number(exitCode ?? 0) & 0xff}`], {});
  };
  if (code !== 0) {
    try {
      const watcher = spawn(process.execPath, ["-e", WATCHER, String(process.pid), String(code), String(graceMs), logPath ?? ""], {
        detached: true,
        stdio: ["pipe", "ignore", "ignore"],
      });
      watcher.unref();
    } catch {
      // Without a watcher the exit is only as reliable as Node's own.
    }
  }
  process.exit(code);
}
