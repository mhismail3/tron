import { spawn } from "node:child_process";

const EXIT_STALL_GRACE_MS = 5_000;

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

export function exitAfterShutdown(code: number, logPath: string | undefined, graceMs = EXIT_STALL_GRACE_MS): never {
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
    }
  }
  process.exit(code);
}
