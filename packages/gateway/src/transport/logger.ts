import { appendFileSync, existsSync, mkdirSync, readFileSync, renameSync, statSync, unlinkSync } from "node:fs";
import { homedir } from "node:os";
import { dirname } from "node:path";

/*
 * Level policy (owned by packages/gateway/docs/observability.md): error means
 * someone should look; warning is degraded
 * but handled; info reconstructs a timeline; debug is per-request detail kept
 * only in the in-memory buffer that diagnostic exports include.
 */
export type LogLevel = "debug" | "info" | "warning" | "error";

export interface LogError {
  name: string;
  code?: string;
  message: string;
  stack?: string;
  cause?: LogError;
}

export interface LogRecord {
  timestamp: string;
  level: LogLevel;
  message: string;
  event?: string;
  source?: string;
  /** Stamped by the writer, never by call sites. */
  process?: "gateway";
  runtimeEpoch?: string;
  payloadVersion?: string;
  sessionId?: string;
  connectionId?: string;
  commandId?: string;
  /** A named lifecycle step, such as a startup checkpoint. */
  step?: string;
  /** Sanitized transport request correlation; never a session or payload ID. */
  requestID?: string;
  method?: string;
  outcome?: string;
  code?: string;
  reason?: string;
  durationMs?: number;
  error?: LogError;
}

export interface LogMetadata {
  event?: string;
  source?: string;
  sessionId?: string;
  connectionId?: string;
  commandId?: string;
  step?: string;
  requestID?: string;
  method?: string;
  outcome?: string;
  code?: string;
  reason?: string;
  durationMs?: number;
  /** Any thrown value; the writer bounds and redacts it. */
  error?: unknown;
}

export interface LoggerIdentity {
  runtimeEpoch?: string | undefined;
  payloadVersion?: string | undefined;
}

/** Records served to iOS and `recent()`: persisted levels only. */
const PERSISTED_TAIL_RECORDS = 1_000;
/** Debug detail for exports: enough for several minutes of busy RPC traffic. */
const DEBUG_BUFFER_MAX_RECORDS = 4_000;
const DEBUG_BUFFER_MAX_BYTES = 2 * 1_024 * 1_024;
/** User-chosen Gateway retention (2026-09-23): 8 segments × 5 MB = 40 MB. */
const SEGMENT_MAX_BYTES = 5 * 1_024 * 1_024;
const SEGMENT_COUNT = 8;
const MAX_MESSAGE_BYTES = 2_000;
const MAX_ERROR_MESSAGE_BYTES = 1_000;
const MAX_STACK_BYTES = 4_000;
const MAX_FIELD_CHARS = 160;
const PERSISTED_LEVELS: ReadonlySet<LogLevel> = new Set(["info", "warning", "error"]);

/** The one redaction rule set. Every writer applies it at its write boundary,
 * and readers that copy raw text (the diagnostic bundle) apply the same rules so
 * a token cannot reach a shared artifact through a path the writers never saw. */
export function redact(value: string): string {
  return value
    .replace(/\bBearer\s+[^\s,;]+/giu, "Bearer [REDACTED]")
    .replace(/((?:authorization|api[-_ ]?key|access[-_ ]?token|refresh[-_ ]?token|password|secret)\s*[:=]\s*)[^\s,;]+/giu, "$1[REDACTED]")
    .replace(/\/Users\/[^\s'"]+/gu, "[USER_PATH]")
    .replace(/\/private\/var\/[^\s'"]+/gu, "[PRIVATE_PATH]");
}

function boundedBytes(value: string, maximum: number): string {
  const bytes = Buffer.from(value, "utf8");
  if (bytes.length <= maximum) return value;
  return `${bytes.subarray(0, maximum - 3).toString("utf8").replace(/\uFFFD$/u, "")}…`;
}

export function boundedMessage(value: string): string {
  return boundedBytes(redact(value), MAX_MESSAGE_BYTES);
}

function boundedDiagnosticID(value: string): string {
  return value.replace(/[^A-Za-z0-9._:-]/gu, "_").slice(0, MAX_FIELD_CHARS);
}

// Payload and home prefixes are shortened before the standard redaction, which
// would otherwise replace whole paths and hide which file an error names.
function shortenedPaths(value: string): string {
  const payloadRoot = process.env.TRON_GATEWAY_PAYLOAD_ROOT;
  const withPayload = payloadRoot ? value.replaceAll(payloadRoot, "<payload>") : value;
  return redact(withPayload.replaceAll(homedir(), "~"));
}

/** Bounded, redacted error shape. One level of `cause` keeps the root reason
 * of a wrapped error while bounding the record. */
export function describeError(error: unknown, includeCause = true): LogError {
  if (!(error instanceof Error)) {
    return { name: "NonError", message: boundedBytes(shortenedPaths(String(error)), MAX_ERROR_MESSAGE_BYTES) };
  }
  return {
    ...boundedErrorFields(error.name, (error as NodeJS.ErrnoException).code, error.message, error.stack, shortenedPaths),
    ...(includeCause && error.cause !== undefined ? { cause: describeError(error.cause, false) } : {}),
  };
}

/** The one place error fields are bounded, for live errors and restored lines. */
function boundedErrorFields(
  name: string, code: unknown, message: string, stack: unknown, clean: (text: string) => string,
): LogError {
  return {
    name: boundedDiagnosticID(name),
    ...(typeof code === "string" ? { code: boundedDiagnosticID(code) } : {}),
    message: boundedBytes(clean(message), MAX_ERROR_MESSAGE_BYTES),
    ...(typeof stack === "string" && stack ? { stack: boundedBytes(clean(stack), MAX_STACK_BYTES) } : {}),
  };
}

function boundedError(value: unknown): LogError | undefined {
  if (!value || typeof value !== "object") return undefined;
  const raw = value as Partial<LogError>;
  if (typeof raw.name !== "string" || typeof raw.message !== "string") return undefined;
  const error = boundedErrorFields(raw.name, raw.code, raw.message, raw.stack, redact);
  const cause = raw.cause ? boundedError({ ...raw.cause, cause: undefined }) : undefined;
  return cause ? { ...error, cause } : error;
}

/** Normalizes call-site metadata or a persisted line into one bounded shape. */
function normalizedFields(value: LogMetadata & { error?: unknown }, errorIsDescribed: boolean): Omit<LogRecord, "timestamp" | "level" | "message"> {
  const error = value.error === undefined
    ? undefined
    : errorIsDescribed ? boundedError(value.error) : describeError(value.error);
  return {
    ...(typeof value.event === "string" ? { event: boundedMessage(value.event).slice(0, MAX_FIELD_CHARS) } : {}),
    ...(typeof value.source === "string" ? { source: boundedMessage(value.source).slice(0, 64) } : {}),
    ...(typeof value.sessionId === "string" ? { sessionId: boundedDiagnosticID(value.sessionId) } : {}),
    ...(typeof value.connectionId === "string" ? { connectionId: boundedDiagnosticID(value.connectionId) } : {}),
    ...(typeof value.commandId === "string" ? { commandId: boundedDiagnosticID(value.commandId) } : {}),
    ...(typeof value.step === "string" ? { step: boundedDiagnosticID(value.step).slice(0, 64) } : {}),
    ...(typeof value.requestID === "string" ? { requestID: boundedDiagnosticID(value.requestID) } : {}),
    ...(typeof value.method === "string" ? { method: boundedMessage(value.method).slice(0, MAX_FIELD_CHARS) } : {}),
    ...(typeof value.outcome === "string" ? { outcome: boundedMessage(value.outcome).slice(0, 64) } : {}),
    ...(typeof value.reason === "string" ? { reason: boundedDiagnosticID(value.reason).slice(0, 64) } : {}),
    ...(typeof value.code === "string" ? { code: boundedMessage(value.code).slice(0, 64) } : {}),
    ...(typeof value.durationMs === "number" && Number.isFinite(value.durationMs)
      ? { durationMs: Math.max(0, Math.min(Number.MAX_SAFE_INTEGER, Math.round(value.durationMs))) }
      : {}),
    ...(error ? { error } : {}),
  };
}

/**
 * The Gateway's single log writer. Info and above append to numbered JSONL
 * segments and a bounded tail served to clients; debug stays in a separate
 * bounded memory buffer that only diagnostic exports read.
 */
export class GatewayLogger {
  private readonly records: LogRecord[] = [];
  private readonly debugRecords: Array<{ record: LogRecord; bytes: number }> = [];
  private debugBytes = 0;
  private readonly path: string | undefined;
  private readonly identity: Pick<LogRecord, "runtimeEpoch" | "payloadVersion">;
  /** Tracked in memory so each append avoids a stat call. */
  private activeBytes: number | undefined;

  constructor(path?: string, identity: LoggerIdentity = {}) {
    this.path = path;
    this.identity = {
      ...(identity.runtimeEpoch ? { runtimeEpoch: boundedDiagnosticID(identity.runtimeEpoch) } : {}),
      ...(identity.payloadVersion ? { payloadVersion: boundedDiagnosticID(identity.payloadVersion) } : {}),
    };
    this.loadPersisted();
  }

  log(level: LogLevel, message: string, metadata: LogMetadata = {}): void {
    const record: LogRecord = {
      timestamp: new Date().toISOString(),
      level,
      message: boundedMessage(message),
      process: "gateway",
      ...this.identity,
      ...normalizedFields(metadata, false),
    };
    if (level === "debug") {
      this.retainDebug(record);
      return;
    }
    this.records.push(record);
    if (this.records.length > PERSISTED_TAIL_RECORDS) this.records.splice(0, this.records.length - PERSISTED_TAIL_RECORDS);
    this.persist(record);
    if (process.env.TRON_GATEWAY_SUPERVISED === "1") return;
    const output = `[${record.timestamp}] ${level.toUpperCase()}${record.event ? ` ${record.event}` : ""} ${record.message}\n`;
    if (level === "error") process.stderr.write(output);
    else process.stdout.write(output);
  }

  /** Persisted levels only; debug detail is reachable through exports. */
  recent(limit = 200): LogRecord[] {
    return this.records.slice(-Math.max(1, Math.min(limit, PERSISTED_TAIL_RECORDS)));
  }

  /** The in-memory debug buffer, oldest first, for diagnostic exports. */
  debugTail(): LogRecord[] {
    return this.debugRecords.map((entry) => entry.record);
  }

  private retainDebug(record: LogRecord): void {
    const bytes = Buffer.byteLength(JSON.stringify(record));
    this.debugRecords.push({ record, bytes });
    this.debugBytes += bytes;
    while (this.debugRecords.length > DEBUG_BUFFER_MAX_RECORDS || this.debugBytes > DEBUG_BUFFER_MAX_BYTES) {
      const evicted = this.debugRecords.shift();
      if (!evicted) break;
      this.debugBytes -= evicted.bytes;
    }
  }

  private loadPersisted(): void {
    if (!this.path) return;
    try {
      // Newest segments hold the tail; read until the tail is full, then
      // restore chronological order.
      const newestFirst: LogRecord[] = [];
      for (let index = 0; index < SEGMENT_COUNT && newestFirst.length < PERSISTED_TAIL_RECORDS; index += 1) {
        const candidate = this.segmentPath(index);
        if (!existsSync(candidate)) continue;
        const lines = readFileSync(candidate, "utf8").split("\n").filter(Boolean);
        for (let line = lines.length - 1; line >= 0 && newestFirst.length < PERSISTED_TAIL_RECORDS; line -= 1) {
          const record = this.parsePersisted(lines[line]!);
          if (record) newestFirst.push(record);
        }
      }
      this.records.push(...newestFirst.reverse());
    } catch {
      // Diagnostics must never prevent Gateway startup.
    }
  }

  private parsePersisted(line: string): LogRecord | undefined {
    try {
      const value = JSON.parse(line) as Partial<LogRecord>;
      if (typeof value.timestamp !== "string" || !PERSISTED_LEVELS.has(value.level as LogLevel) || typeof value.message !== "string") {
        return undefined;
      }
      return {
        timestamp: value.timestamp,
        level: value.level as LogLevel,
        message: boundedMessage(value.message),
        ...(value.process === "gateway" ? { process: "gateway" as const } : {}),
        ...(typeof value.runtimeEpoch === "string" ? { runtimeEpoch: boundedDiagnosticID(value.runtimeEpoch) } : {}),
        ...(typeof value.payloadVersion === "string" ? { payloadVersion: boundedDiagnosticID(value.payloadVersion) } : {}),
        ...normalizedFields(value as LogMetadata, true),
      };
    } catch {
      // Ignore a partial final line or malformed historical record.
      return undefined;
    }
  }

  private persist(record: LogRecord): void {
    if (!this.path) return;
    try {
      mkdirSync(dirname(this.path), { recursive: true, mode: 0o700 });
      const line = `${JSON.stringify(record)}\n`;
      const lineBytes = Buffer.byteLength(line);
      if (this.activeBytes === undefined) {
        this.activeBytes = existsSync(this.path) ? statSync(this.path).size : 0;
      }
      if (this.activeBytes > 0 && this.activeBytes + lineBytes > SEGMENT_MAX_BYTES) this.rotate();
      appendFileSync(this.path, line, { mode: 0o600 });
      this.activeBytes += lineBytes;
    } catch {
      // Re-measure after any failure; stdout/stderr remains the fallback sink.
      this.activeBytes = undefined;
    }
  }

  /** Shifts gateway.jsonl → .1 → … → .7, discarding the oldest segment. */
  private rotate(): void {
    try { unlinkSync(this.segmentPath(SEGMENT_COUNT - 1)); } catch { /* fewer segments exist */ }
    for (let index = SEGMENT_COUNT - 2; index >= 0; index -= 1) {
      try { renameSync(this.segmentPath(index), this.segmentPath(index + 1)); } catch { /* gap in the sequence */ }
    }
    this.activeBytes = 0;
  }

  private segmentPath(index: number): string {
    const base = this.path ?? "gateway.jsonl";
    return index === 0 ? base : `${base}.${index}`;
  }
}
