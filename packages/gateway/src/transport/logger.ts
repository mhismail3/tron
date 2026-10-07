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
  /** The phone's hello correlation key (O-1): joins its records to this connection. */
  peerClientId?: string;
  peerAttemptId?: string;
  peerEpoch?: string;
  /** The protocol version a refused hello asked for (`http.upgrade`,
   * `reason=protocol_mismatch`): names the stale side of a version mismatch. */
  peerProtocolVersion?: number;
  /** Retired legacy connection instance IDs. */
  instanceIds?: readonly string[];
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
  /** The request span's compact stage breakdown, one bounded string. */
  stages?: string;
  /** The measured stage a request was in at one instant, e.g. the stage a
   * cancellation interrupted (`rpc.cancelled`). */
  stage?: string;
  /** The part of `durationMs` no named stage accounted for. */
  unaccountedMs?: number;
  /** How far an upgrade got: `request`, `auth`, `handshake` or `hello`. */
  phaseReached?: string;
  /** Upgrade phase durations, in the order they run (`http.upgrade`). */
  acceptToUpgradeMs?: number;
  authMs?: number;
  handshakeMs?: number;
  helloMs?: number;
  /** The peer's Tailscale path at an inbound-silence episode (`connection.inbound-silent`). */
  peerPath?: string;
  peerRelay?: string;
  /** The listener a connection reached: `lan`, `tailscale` or `primary`
   * (`http.upgrade`). The phone names the two real legs it races the same way. */
  transport?: string;
  /** How long the socket had been silent when it spoke again. */
  silentMs?: number;
  /** Named counters for one record (a reconcile's files and rows): the writer
   * bounds how many, their names and their values. */
  counts?: Record<string, number>;
  error?: LogError;
}

export interface LogMetadata {
  event?: string;
  source?: string;
  sessionId?: string;
  connectionId?: string;
  peerClientId?: string;
  peerAttemptId?: string;
  peerEpoch?: string;
  peerProtocolVersion?: number;
  instanceIds?: readonly string[];
  commandId?: string;
  step?: string;
  requestID?: string;
  method?: string;
  outcome?: string;
  code?: string;
  reason?: string;
  cause?: string;
  durationMs?: number;
  /** `name=12ms×2/610KB;name=5ms`; the writer bounds it. */
  stages?: string;
  /** The measured stage a request was in at one instant, e.g. the stage a
   * cancellation interrupted (`rpc.cancelled`). */
  stage?: string;
  /** The part of `durationMs` the stage breakdown did not cover. */
  unaccountedMs?: number;
  phaseReached?: string;
  /** The admission a capacity shed refused (`gateway.shed` with `reason=heap`):
   * a cold runtime load (`open`) or a JSONL import. A deadline shed names its
   * `method` instead. */
  admission?: string;
  acceptToUpgradeMs?: number;
  authMs?: number;
  handshakeMs?: number;
  helloMs?: number;
  peerPath?: string;
  peerRelay?: string;
  /** The listener a connection reached; the `transport` field of `http.upgrade`. */
  transport?: string;
  silentMs?: number;
  /** Named integer counters, e.g. `{ files: 12, added: 1 }`. */
  counts?: Readonly<Record<string, number>>;
  /** Any thrown value; the writer bounds and redacts it. */
  error?: unknown;
}

/** One duration field: finite, non-negative, rounded, never NaN in a record. */
function durationField(value: unknown): number | undefined {
  return typeof value === "number" && Number.isFinite(value)
    ? Math.max(0, Math.min(Number.MAX_SAFE_INTEGER, Math.round(value)))
    : undefined;
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
/** A stage breakdown is read as one line beside the record it explains; past
 * this it stops naming stages rather than crowding the other fields. Wide
 * enough for a cold open's ~260-byte breakdown with room for a nested catalog
 * walk. */
const MAX_STAGES_BYTES = 1_024;
const MAX_ERROR_MESSAGE_BYTES = 1_000;
const MAX_STACK_BYTES = 4_000;
const MAX_FIELD_CHARS = 160;
/** A record names a handful of counters; more would make the field a payload. */
const MAX_COUNT_FIELDS = 16;
/** A counter name is a short identifier: the shape check below already rejects
 * anything but letters and digits, so only its length needs bounding. */
const MAX_COUNT_NAME_CHARS = 32;
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

/** Named counters are fields a reader can aggregate, so their names are short
 * plain identifiers and their values are bounded integers. */
function boundedCounts(value: Readonly<Record<string, number>>): Record<string, number> {
  const bounded: Record<string, number> = {};
  for (const [name, count] of Object.entries(value)) {
    if (Object.keys(bounded).length >= MAX_COUNT_FIELDS) break;
    if (!/^[A-Za-z][A-Za-z0-9]*$/u.test(name) || !Number.isFinite(count)) continue;
    bounded[name.slice(0, MAX_COUNT_NAME_CHARS)] = Math.max(0, Math.min(Number.MAX_SAFE_INTEGER, Math.round(count)));
  }
  return bounded;
}

function boundedDiagnosticID(value: string): string {
  return value.replace(/[^A-Za-z0-9._:-]/gu, "_").slice(0, MAX_FIELD_CHARS);
}

/** The stage breakdown keeps its `=`, `;`, `×` and `/` separators, so it is
 * bounded by bytes and redacted like a message, not diagnostic-ID-escaped. */
function boundedStages(value: string): string {
  return boundedBytes(redact(value), MAX_STAGES_BYTES);
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
  const durationMs = durationField(value.durationMs);
  const unaccountedMs = durationField(value.unaccountedMs);
  const acceptToUpgradeMs = durationField(value.acceptToUpgradeMs);
  const authMs = durationField(value.authMs);
  const handshakeMs = durationField(value.handshakeMs);
  const helloMs = durationField(value.helloMs);
  const silentMs = durationField(value.silentMs);
  return {
    ...(typeof value.event === "string" ? { event: boundedMessage(value.event).slice(0, MAX_FIELD_CHARS) } : {}),
    ...(typeof value.source === "string" ? { source: boundedMessage(value.source).slice(0, 64) } : {}),
    ...(typeof value.sessionId === "string" ? { sessionId: boundedDiagnosticID(value.sessionId) } : {}),
    ...(typeof value.connectionId === "string" ? { connectionId: boundedDiagnosticID(value.connectionId) } : {}),
    ...(typeof value.peerClientId === "string" ? { peerClientId: boundedDiagnosticID(value.peerClientId) } : {}),
    ...(typeof value.peerAttemptId === "string" ? { peerAttemptId: boundedDiagnosticID(value.peerAttemptId) } : {}),
    ...(typeof value.peerEpoch === "string" ? { peerEpoch: boundedDiagnosticID(value.peerEpoch) } : {}),
    ...(Number.isSafeInteger(value.peerProtocolVersion) ? { peerProtocolVersion: value.peerProtocolVersion } : {}),
    ...(Array.isArray(value.instanceIds) ? { instanceIds: value.instanceIds.filter((id): id is string => typeof id === "string").slice(0, 64).map(id => boundedDiagnosticID(id)) } : {}),
    ...(typeof value.commandId === "string" ? { commandId: boundedDiagnosticID(value.commandId) } : {}),
    ...(typeof value.step === "string" ? { step: boundedDiagnosticID(value.step).slice(0, 64) } : {}),
    ...(typeof value.requestID === "string" ? { requestID: boundedDiagnosticID(value.requestID) } : {}),
    ...(typeof value.method === "string" ? { method: boundedMessage(value.method).slice(0, MAX_FIELD_CHARS) } : {}),
    ...(typeof value.outcome === "string" ? { outcome: boundedMessage(value.outcome).slice(0, 64) } : {}),
    ...(typeof value.reason === "string" ? { reason: boundedDiagnosticID(value.reason).slice(0, 64) } : {}),
    ...(typeof value.cause === "string" ? { cause: boundedDiagnosticID(value.cause).slice(0, 64) } : {}),
    ...(typeof value.code === "string" ? { code: boundedMessage(value.code).slice(0, 64) } : {}),
    ...(durationMs !== undefined ? { durationMs } : {}),
    ...(typeof value.stages === "string" ? { stages: boundedStages(value.stages) } : {}),
    ...(typeof value.stage === "string" ? { stage: boundedDiagnosticID(value.stage).slice(0, 64) } : {}),
    ...(unaccountedMs !== undefined ? { unaccountedMs } : {}),
    ...(typeof value.phaseReached === "string" ? { phaseReached: boundedDiagnosticID(value.phaseReached).slice(0, 32) } : {}),
    ...(acceptToUpgradeMs !== undefined ? { acceptToUpgradeMs } : {}),
    ...(authMs !== undefined ? { authMs } : {}),
    ...(handshakeMs !== undefined ? { handshakeMs } : {}),
    ...(helloMs !== undefined ? { helloMs } : {}),
    ...(typeof value.peerPath === "string" ? { peerPath: boundedDiagnosticID(value.peerPath).slice(0, 32) } : {}),
    ...(typeof value.peerRelay === "string" ? { peerRelay: boundedDiagnosticID(value.peerRelay).slice(0, 32) } : {}),
    ...(typeof value.transport === "string" ? { transport: boundedDiagnosticID(value.transport).slice(0, 32) } : {}),
    ...(silentMs !== undefined ? { silentMs } : {}),
    ...(value.counts ? { counts: boundedCounts(value.counts) } : {}),
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
