import { appendFileSync, mkdirSync } from "node:fs";
import { join } from "node:path";
import { resolveTronHome } from "./tron-home.js";
import { describeError } from "./transport/logger.js";

function recordFatalStartup(error: unknown): void {
  const described = describeError(error);
  const record = {
    timestamp: new Date().toISOString(),
    level: "error",
    event: "gateway.fatal-startup",
    source: "lifecycle",
    message: `Gateway failed during startup: ${described.message}`,
    process: "gateway",
    ...(process.env.TRON_GATEWAY_RUNTIME_EPOCH ? { runtimeEpoch: process.env.TRON_GATEWAY_RUNTIME_EPOCH } : {}),
    ...(process.env.TRON_GATEWAY_PAYLOAD_VERSION ? { payloadVersion: process.env.TRON_GATEWAY_PAYLOAD_VERSION } : {}),
    error: described,
  };
  try {
    const logs = join(resolveTronHome(), "logs");
    mkdirSync(logs, { recursive: true, mode: 0o700 });
    appendFileSync(join(logs, "gateway.jsonl"), `${JSON.stringify(record)}\n`, { mode: 0o600 });
  } catch {
  }
  process.stderr.write(`${record.message}\n`);
}

try {
  await import("./gateway-main.js");
} catch (error) {
  recordFatalStartup(error);
  process.exit(1);
}
