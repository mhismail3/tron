// Preload for a subagent runner process (#1021): hold the runner's own terminal
// status.json publication for TRON_LATE_RUNNER_TERMINAL_MS, widening the window in
// which the child's step already reads terminal while its run still reads running.
// Only the runner that owns the status (its `pid`) is delayed; the Gateway is not.
import fs from "node:fs";
import { syncBuiltinESMExports } from "node:module";

const delayMs = Number(process.env.TRON_LATE_RUNNER_TERMINAL_MS ?? 0);
const rename = fs.renameSync;
fs.renameSync = function renameSync(source, target) {
  if (delayMs > 0 && String(target).endsWith("/status.json")) {
    let payload;
    try { payload = JSON.parse(fs.readFileSync(source, "utf8")); } catch { payload = undefined; }
    if (payload?.pid === process.pid && payload.parentWorkflowRunId && !["queued", "running"].includes(payload.state)) {
      Atomics.wait(new Int32Array(new SharedArrayBuffer(4)), 0, 0, delayMs);
    }
  }
  return rename.apply(this, arguments);
};
syncBuiltinESMExports();
