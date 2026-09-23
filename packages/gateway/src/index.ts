import { appendFileSync, mkdirSync } from "node:fs";
import { homedir } from "node:os";
import { join } from "node:path";
import { resolveTronHome } from "./tron-home.js";
import { boundedMessage } from "./transport/logger.js";

/*
 * The supervised launcher executes this file directly. Everything the Gateway
 * runs lives in gateway-main.ts; loading it here means a failure anywhere in
 * its module graph or startup (a missing shipped file, a config or lock error)
 * rejects the import below before GatewayLogger exists. Record that cause once
 * in gateway.jsonl so the deploy helper and operators can read it. Keep this
 * module's own imports limited to Node built-ins and the two small modules
 * above, or its failures become invisible again.
 */

// Payload and home prefixes are shortened before the standard redaction, which
// would otherwise replace whole paths and hide which shipped file was missing.
function shortenedPaths(value: string): string {
  const payloadRoot = process.env.TRON_GATEWAY_PAYLOAD_ROOT;
  const withPayload = payloadRoot ? value.replaceAll(payloadRoot, "<payload>") : value;
  return boundedMessage(withPayload.replaceAll(homedir(), "~"));
}

interface DescribedError {
  name: string;
  code?: string;
  message: string;
  stack?: string;
  cause?: DescribedError;
}

// One level of `cause` keeps the root reason of a wrapped startup error while
// bounding the record.
function describeError(error: unknown, includeCause = true): DescribedError {
  if (!(error instanceof Error)) return { name: "NonError", message: shortenedPaths(String(error)) };
  const code = (error as NodeJS.ErrnoException).code;
  return {
    name: error.name,
    ...(typeof code === "string" ? { code } : {}),
    message: shortenedPaths(error.message),
    ...(error.stack ? { stack: shortenedPaths(error.stack) } : {}),
    ...(includeCause && error.cause !== undefined ? { cause: describeError(error.cause, false) } : {}),
  };
}

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
    // stderr below is the only remaining channel when the log is unwritable.
  }
  process.stderr.write(`${record.message}\n`);
}

try {
  await import("./gateway-main.js");
} catch (error) {
  recordFatalStartup(error);
  process.exit(1);
}
