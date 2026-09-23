import { appendFileSync, existsSync, mkdirSync, readFileSync, renameSync, statSync, unlinkSync } from "node:fs";
import { dirname } from "node:path";

export interface LogRecord {
  timestamp: string;
  level: "info" | "warning" | "error";
  message: string;
  event?: string;
  source?: string;
  /** Sanitized transport request correlation; never a session or payload ID. */
  requestID?: string;
  method?: string;
  outcome?: string;
  code?: string;
  reason?: string;
  durationMs?: number;
}

const MAX_RECORDS = 1_000;
const MAX_MESSAGE_BYTES = 2_000;
const MAX_FILE_BYTES = 1_048_576;


function redact(value: string): string {
  return value
    .replace(/\bBearer\s+[^\s,;]+/giu, "Bearer [REDACTED]")
    .replace(/((?:authorization|api[-_ ]?key|access[-_ ]?token|refresh[-_ ]?token|password|secret)\s*[:=]\s*)[^\s,;]+/giu, "$1[REDACTED]")
    .replace(/\/Users\/[^\s'"]+/gu, "[USER_PATH]")
    .replace(/\/private\/var\/[^\s'"]+/gu, "[PRIVATE_PATH]");
}

function boundedMessage(value: string): string {
  const redacted = redact(value);
  const bytes = Buffer.from(redacted, "utf8");
  if (bytes.length <= MAX_MESSAGE_BYTES) return redacted;
  return `${bytes.subarray(0, MAX_MESSAGE_BYTES - 3).toString("utf8").replace(/\uFFFD$/u, "")}…`;
}

function boundedDiagnosticID(value: string): string {
  return value.replace(/[^A-Za-z0-9._:-]/gu, "_").slice(0, 160);
}

export class GatewayLogger {
  private readonly records: LogRecord[] = [];
  private readonly path: string | undefined;

  constructor(path?: string) {
    this.path = path;
    this.loadPersisted();
  }

  log(level: LogRecord["level"], message: string, metadata: { event?: string; source?: string; requestID?: string; method?: string; outcome?: string; code?: string; reason?: string; durationMs?: number } = {}): void {
    const record: LogRecord = {
      timestamp: new Date().toISOString(),
      level,
      message: boundedMessage(message),
      ...(metadata.event ? { event: boundedMessage(metadata.event) } : {}),
      ...(metadata.source ? { source: boundedMessage(metadata.source) } : {}),
      ...(metadata.requestID ? { requestID: boundedDiagnosticID(metadata.requestID) } : {}),
      ...(metadata.method ? { method: boundedMessage(metadata.method).slice(0, 160) } : {}),
      ...(metadata.outcome ? { outcome: boundedMessage(metadata.outcome).slice(0, 64) } : {}),
      ...(metadata.reason ? { reason: boundedDiagnosticID(metadata.reason).slice(0, 64) } : {}),
      ...(metadata.code ? { code: boundedMessage(metadata.code).slice(0, 64) } : {}),
      ...(metadata.durationMs !== undefined ? { durationMs: Math.max(0, Math.min(Number.MAX_SAFE_INTEGER, Math.round(metadata.durationMs))) } : {}),
    };
    this.records.push(record);
    if (this.records.length > MAX_RECORDS) this.records.splice(0, this.records.length - MAX_RECORDS);
    this.persist(record);
    const output = `[${record.timestamp}] ${level.toUpperCase()}${record.event ? ` ${record.event}` : ""} ${record.message}\n`;
    if (level === "error") process.stderr.write(output);
    else process.stdout.write(output);
  }

  recent(limit = 200): LogRecord[] {
    return this.records.slice(-Math.max(1, Math.min(limit, MAX_RECORDS)));
  }

  private loadPersisted(): void {
    if (!this.path) return;
    try {
      for (const candidate of [this.rotatedPath(), this.path]) {
        if (!existsSync(candidate)) continue;
        const lines = readFileSync(candidate, "utf8").split("\n").filter(Boolean).slice(-MAX_RECORDS);
        for (const line of lines) {
          try {
            const value = JSON.parse(line) as Partial<LogRecord>;
            if (typeof value.timestamp !== "string" || !["info", "warning", "error"].includes(value.level ?? "") || typeof value.message !== "string") continue;
            this.records.push({
              timestamp: value.timestamp,
              level: value.level as LogRecord["level"],
              message: boundedMessage(value.message),
              ...(typeof value.event === "string" ? { event: boundedMessage(value.event) } : {}),
              ...(typeof value.source === "string" ? { source: boundedMessage(value.source) } : {}),
              ...(typeof value.requestID === "string" ? { requestID: boundedDiagnosticID(value.requestID) } : {}),
              ...(typeof value.method === "string" ? { method: boundedMessage(value.method).slice(0, 160) } : {}),
              ...(typeof value.outcome === "string" ? { outcome: boundedMessage(value.outcome).slice(0, 64) } : {}),
              ...(typeof value.reason === "string" ? { reason: boundedDiagnosticID(value.reason).slice(0, 64) } : {}),
              ...(typeof value.code === "string" ? { code: boundedMessage(value.code).slice(0, 64) } : {}),
              ...(typeof value.durationMs === "number" ? { durationMs: Math.max(0, Math.min(Number.MAX_SAFE_INTEGER, Math.round(value.durationMs))) } : {}),
            });
          } catch {
            // Ignore a partial final line or malformed historical record.
          }
        }
      }
      if (this.records.length > MAX_RECORDS) this.records.splice(0, this.records.length - MAX_RECORDS);
    } catch {
      // Diagnostics must never prevent Gateway startup.
    }
  }

  private persist(record: LogRecord): void {
    if (!this.path) return;
    try {
      mkdirSync(dirname(this.path), { recursive: true, mode: 0o700 });
      const line = `${JSON.stringify(record)}\n`;
      if (existsSync(this.path) && statSync(this.path).size + Buffer.byteLength(line) > MAX_FILE_BYTES) {
        const rotated = this.rotatedPath();
        try { unlinkSync(rotated); } catch { /* no prior rotation */ }
        renameSync(this.path, rotated);
      }
      appendFileSync(this.path, line, { mode: 0o600 });
    } catch {
      // Stdout/stderr remains the fallback diagnostic sink.
    }
  }

  private rotatedPath(): string {
    return `${this.path ?? "gateway.log"}.1`;
  }
}
