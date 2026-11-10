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
