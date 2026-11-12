import { existsSync, readFileSync } from "node:fs";
import { homedir } from "node:os";
import { RotatingJsonl } from "./rotating-jsonl.js";
import { redact, redactCredentialField } from "../util/credential-redaction.js";
import { GatewayError } from "../errors.js";
import type { HomeHardBoundary } from "../modules/home/home-diagnostic.js";
import type { CommandReceiptRouteCategory } from "../protocol/types.js";

export type LogLevel = "debug" | "info" | "warning" | "error";

export interface LogError {
  name: string;
  code?: string;
  message: string;
  stack?: string;
  details?: string;
  cause?: LogError;
}

export interface LogRecord {
  timestamp: string;
  level: LogLevel;
  message: string;
  event?: string;
  source?: string;
  process?: "gateway";
  runtimeEpoch?: string;
  payloadVersion?: string;
  sessionId?: string;
  connectionId?: string;
  peerClientId?: string;
  peerAttemptId?: string;
  peerEpoch?: string;
  peerProtocolVersion?: number;
  commandId?: string;
  pid?: number;
  step?: string;
  requestID?: string;
  method?: string;
  outcome?: string;
  code?: string;
  reason?: string;
  operation?: "pauseMemory" | "resumeMemory";
  category?: "open" | CommandReceiptRouteCategory;
  boundary?: HomeHardBoundary;
  chapterOrdinal?: number;
  crossingBytes?: number;
  crossingEntries?: number;
  settledBytes?: number;
  settledEntries?: number;
  durationMs?: number;
  acceptToCloseMs?: number;
  bytesRead?: number;
  transportEnd?: "reset" | "timeout" | "fin" | "none";
  stages?: string;
  stage?: string;
  unaccountedMs?: number;
  phaseReached?: string;
  acceptToUpgradeMs?: number;
  authMs?: number;
  handshakeMs?: number;
  helloMs?: number;
  peerPath?: string;
  peerPathSource?: string;
  peerRelay?: string;
  peerLastHandshake?: string;
  peerRxBytes?: number;
  peerTxBytes?: number;
  transport?: string;
  silentMs?: number;
  counts?: Record<string, number>;
  taskHash?: string;
  operationHash?: string;
  eventHash?: string;
  referenceHash?: string;
  spendReference?: string;
  revision?: number;
  inputTokens?: number;
  cacheReadTokens?: number;
  cacheWriteTokens?: number;
  outputTokens?: number;
  elapsedMs?: number;
  transition?: string;
  state?: string;
  action?: string;
  disposition?: string;
  cancelAndJoin?: string;
  error?: LogError;
}

interface LogMetadata extends Pick<LogRecord, "operation" | "category" | "boundary" | "chapterOrdinal" | "crossingBytes" | "crossingEntries" | "settledBytes" | "settledEntries" | "pid"> {
  event?: string;
  source?: string;
  kind?: string;
  sessionId?: string;
  connectionId?: string;
  peerClientId?: string;
  peerAttemptId?: string;
  peerEpoch?: string;
  peerProtocolVersion?: number;
  commandId?: string;
  step?: string;
  requestID?: string;
  method?: string;
  outcome?: string;
  code?: string;
  reason?: string;
  cause?: string;
  durationMs?: number;
  acceptToCloseMs?: number;
  bytesRead?: number;
  transportEnd?: "reset" | "timeout" | "fin" | "none";
  stages?: string;
  stage?: string;
  unaccountedMs?: number;
  phaseReached?: string;
  admission?: string;
  acceptToUpgradeMs?: number;
  authMs?: number;
  handshakeMs?: number;
  helloMs?: number;
  peerPath?: string;
  peerPathSource?: string;
  peerRelay?: string;
  peerLastHandshake?: string;
  peerRxBytes?: number;
  peerTxBytes?: number;
  transport?: string;
  silentMs?: number;
  counts?: Readonly<Record<string, number>>;
  taskHash?: string;
  operationHash?: string | null;
  eventHash?: string;
  referenceHash?: string;
  spendReference?: string;
  revision?: number;
  inputTokens?: number;
  cacheReadTokens?: number;
  cacheWriteTokens?: number;
  outputTokens?: number;
  elapsedMs?: number;
  transition?: string;
  state?: string;
  action?: string;
  disposition?: string;
  cancelAndJoin?: string;
  error?: unknown;
}

function counterField(value: unknown): number | undefined {
  return typeof value === "number" && Number.isSafeInteger(value) && value >= 0 ? value : undefined;
}

function durationField(value: unknown): number | undefined {
  return typeof value === "number" && Number.isFinite(value)
    ? Math.max(0, Math.min(Number.MAX_SAFE_INTEGER, Math.round(value)))
    : undefined;
}

interface LoggerIdentity {
  runtimeEpoch?: string | undefined;
  payloadVersion?: string | undefined;
}

const PERSISTED_TAIL_RECORDS = 1_000;
const DEBUG_BUFFER_MAX_RECORDS = 4_000;
const DEBUG_BUFFER_MAX_BYTES = 2 * 1_024 * 1_024;
const MAX_MESSAGE_BYTES = 2_000;
const MAX_STAGES_BYTES = 1_024;
const MAX_ERROR_MESSAGE_BYTES = 1_000;
const MAX_ERROR_DETAIL_NODES = 64;
const MAX_STACK_BYTES = 4_000;
const MAX_FIELD_CHARS = 160;
const MAX_COUNT_FIELDS = 16;
const MAX_COUNT_NAME_CHARS = 32;
const PERSISTED_LEVELS: ReadonlySet<LogLevel> = new Set(["info", "warning", "error"]);

function boundedBytes(value: string, maximum: number): string {
  const bytes = Buffer.from(value, "utf8");
  if (bytes.length <= maximum) return value;
  return `${bytes.subarray(0, maximum - 3).toString("utf8").replace(/\uFFFD$/u, "")}…`;
}

function boundedMessage(value: string): string {
  return boundedBytes(redact(value), MAX_MESSAGE_BYTES);
}

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

function boundedToken(value: unknown): string | undefined {
  return typeof value === "string" ? boundedDiagnosticID(value).slice(0, 64) : undefined;
}

function boundedStages(value: string): string {
  return boundedBytes(redact(value), MAX_STAGES_BYTES);
}

function shortenedPaths(value: string): string {
  const payloadRoot = process.env.TRON_GATEWAY_PAYLOAD_ROOT;
  const withPayload = payloadRoot ? value.replaceAll(payloadRoot, "<payload>") : value;
  return redact(withPayload.replaceAll(homedir(), "~"));
}

function internalErrorDetails(value: unknown): string {
  try {
    let nodes = 0;
    const details = JSON.stringify(value, (key, value: unknown) => {
      if (++nodes > MAX_ERROR_DETAIL_NODES) throw new RangeError("Internal diagnostic detail limit");
      const safe = redactCredentialField(key, value);
      return typeof safe === "string" ? boundedBytes(shortenedPaths(safe), MAX_ERROR_MESSAGE_BYTES) : safe;
    });
    return details === undefined ? "[Unserializable internal details]" : boundedBytes(shortenedPaths(details), MAX_ERROR_MESSAGE_BYTES);
  } catch {
    return "[Unserializable or oversized internal details]";
  }
}

export function describeError(error: unknown, includeCause = true): LogError {
  if (!(error instanceof Error)) {
    return { name: "NonError", message: boundedBytes(shortenedPaths(String(error)), MAX_ERROR_MESSAGE_BYTES) };
  }
  return {
    ...boundedErrorFields(error.name, (error as NodeJS.ErrnoException).code, error.message, error.stack, shortenedPaths),
    ...(error instanceof GatewayError && error.code === "internal" && error.details !== undefined ? { details: internalErrorDetails(error.details) } : {}),
    ...(includeCause && error.cause !== undefined ? { cause: describeError(error.cause, false) } : {}),
  };
}

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
  return {
    ...error,
    ...(typeof raw.details === "string" ? { details: boundedBytes(redact(raw.details), MAX_ERROR_MESSAGE_BYTES) } : {}),
    ...(cause ? { cause } : {}),
  };
}

function normalizedFields(value: LogMetadata & { error?: unknown }, errorIsDescribed: boolean): Omit<LogRecord, "timestamp" | "level" | "message"> {
  const error = value.error === undefined
    ? undefined
    : errorIsDescribed ? boundedError(value.error) : describeError(value.error);
  const durationMs = durationField(value.durationMs);
  const unaccountedMs = durationField(value.unaccountedMs);
  const acceptToUpgradeMs = durationField(value.acceptToUpgradeMs);
  const acceptToCloseMs = durationField(value.acceptToCloseMs);
  const bytesRead = counterField(value.bytesRead);
  const transportEnd = value.transportEnd;
  const authMs = durationField(value.authMs);
  const handshakeMs = durationField(value.handshakeMs);
  const helloMs = durationField(value.helloMs);
  const silentMs = durationField(value.silentMs);
  const elapsedMs = durationField(value.elapsedMs);
  const taskHash = boundedToken(value.taskHash);
  const operationHash = boundedToken(value.operationHash);
  const eventHash = boundedToken(value.eventHash);
  const referenceHash = boundedToken(value.referenceHash);
  const spendReference = boundedToken(value.spendReference);
  const transition = boundedToken(value.transition);
  const state = boundedToken(value.state);
  const action = boundedToken(value.action);
  const disposition = boundedToken(value.disposition);
  const cancelAndJoin = boundedToken(value.cancelAndJoin);
  return {
    ...(typeof value.event === "string" ? { event: boundedMessage(value.event).slice(0, MAX_FIELD_CHARS) } : {}),
    ...(typeof value.source === "string" ? { source: boundedMessage(value.source).slice(0, 64) } : {}),
    ...(typeof value.sessionId === "string" ? { sessionId: boundedDiagnosticID(value.sessionId) } : {}),
    ...(typeof value.connectionId === "string" ? { connectionId: boundedDiagnosticID(value.connectionId) } : {}),
    ...(typeof value.peerClientId === "string" ? { peerClientId: boundedDiagnosticID(value.peerClientId) } : {}),
    ...(typeof value.peerAttemptId === "string" ? { peerAttemptId: boundedDiagnosticID(value.peerAttemptId) } : {}),
    ...(typeof value.peerEpoch === "string" ? { peerEpoch: boundedDiagnosticID(value.peerEpoch) } : {}),
    ...(Number.isSafeInteger(value.peerProtocolVersion) ? { peerProtocolVersion: value.peerProtocolVersion } : {}),
    ...(typeof value.commandId === "string" ? { commandId: boundedDiagnosticID(value.commandId) } : {}),
    ...(typeof value.step === "string" ? { step: boundedDiagnosticID(value.step).slice(0, 64) } : {}),
    ...(typeof value.requestID === "string" ? { requestID: boundedDiagnosticID(value.requestID) } : {}),
    ...(typeof value.method === "string" ? { method: boundedMessage(value.method).slice(0, MAX_FIELD_CHARS) } : {}),
    ...(typeof value.outcome === "string" ? { outcome: boundedMessage(value.outcome).slice(0, 64) } : {}),
    ...(typeof value.reason === "string" ? { reason: boundedDiagnosticID(value.reason).slice(0, 64) } : {}),
    ...(value.operation === "pauseMemory" || value.operation === "resumeMemory" ? { operation: value.operation } : {}),
    ...(value.category === "open" || value.category === "fresh" || value.category === "replay" ? { category: value.category } : {}),
    ...(value.boundary === "hard-bytes" || value.boundary === "hard-entries" ? { boundary: value.boundary } : {}),
    ...(counterField(value.chapterOrdinal) !== undefined ? { chapterOrdinal: value.chapterOrdinal } : {}),
    ...(counterField(value.crossingBytes) !== undefined ? { crossingBytes: value.crossingBytes } : {}),
    ...(counterField(value.crossingEntries) !== undefined ? { crossingEntries: value.crossingEntries } : {}),
    ...(counterField(value.settledBytes) !== undefined ? { settledBytes: value.settledBytes } : {}),
    ...(counterField(value.settledEntries) !== undefined ? { settledEntries: value.settledEntries } : {}),
    ...(typeof value.cause === "string" ? { cause: boundedDiagnosticID(value.cause).slice(0, 64) } : {}),
    ...(typeof value.code === "string" ? { code: boundedMessage(value.code).slice(0, 64) } : {}),
    ...(Number.isSafeInteger(value.pid) && Number(value.pid) > 0 ? { pid: Number(value.pid) } : {}),
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
    ...(typeof value.peerPathSource === "string" ? { peerPathSource: boundedDiagnosticID(value.peerPathSource).slice(0, 32) } : {}),
    ...(typeof value.peerRelay === "string" ? { peerRelay: boundedDiagnosticID(value.peerRelay).slice(0, 32) } : {}),
    ...(typeof value.peerLastHandshake === "string" ? { peerLastHandshake: boundedDiagnosticID(value.peerLastHandshake).slice(0, 64) } : {}),
    ...(typeof value.peerRxBytes === "number" && Number.isSafeInteger(value.peerRxBytes) && value.peerRxBytes >= 0 ? { peerRxBytes: value.peerRxBytes } : {}),
    ...(typeof value.peerTxBytes === "number" && Number.isSafeInteger(value.peerTxBytes) && value.peerTxBytes >= 0 ? { peerTxBytes: value.peerTxBytes } : {}),
    ...(typeof value.transport === "string" ? { transport: boundedDiagnosticID(value.transport).slice(0, 32) } : {}),
    ...(acceptToCloseMs !== undefined ? { acceptToCloseMs } : {}),
    ...(bytesRead !== undefined ? { bytesRead } : {}),
    ...(transportEnd === "reset" || transportEnd === "timeout" || transportEnd === "fin" || transportEnd === "none" ? { transportEnd } : {}),
    ...(silentMs !== undefined ? { silentMs } : {}),
    ...(taskHash !== undefined ? { taskHash } : {}),
    ...(operationHash !== undefined ? { operationHash } : {}),
    ...(eventHash !== undefined ? { eventHash } : {}),
    ...(referenceHash !== undefined ? { referenceHash } : {}),
    ...(spendReference !== undefined ? { spendReference } : {}),
    ...(counterField(value.revision) !== undefined ? { revision: value.revision } : {}),
    ...(counterField(value.inputTokens) !== undefined ? { inputTokens: value.inputTokens } : {}),
    ...(counterField(value.cacheReadTokens) !== undefined ? { cacheReadTokens: value.cacheReadTokens } : {}),
    ...(counterField(value.cacheWriteTokens) !== undefined ? { cacheWriteTokens: value.cacheWriteTokens } : {}),
    ...(counterField(value.outputTokens) !== undefined ? { outputTokens: value.outputTokens } : {}),
    ...(elapsedMs !== undefined ? { elapsedMs } : {}),
    ...(transition !== undefined ? { transition } : {}),
    ...(state !== undefined ? { state } : {}),
    ...(action !== undefined ? { action } : {}),
    ...(disposition !== undefined ? { disposition } : {}),
    ...(cancelAndJoin !== undefined ? { cancelAndJoin } : {}),
    ...(value.counts ? { counts: boundedCounts(value.counts) } : {}),
    ...(error ? { error } : {}),
  };
}

export class GatewayLogger {
  private readonly records: LogRecord[] = [];
  private readonly debugRecords: Array<{ record: LogRecord; bytes: number }> = [];
  private debugBytes = 0;
  private readonly file: RotatingJsonl | undefined;
  private readonly identity: Pick<LogRecord, "runtimeEpoch" | "payloadVersion">;

  constructor(path?: string, identity: LoggerIdentity = {}) {
    this.file = path ? new RotatingJsonl(path) : undefined;
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
    this.file?.append(record);
    if (process.env.TRON_GATEWAY_SUPERVISED === "1") return;
    const output = `[${record.timestamp}] ${level.toUpperCase()}${record.event ? ` ${record.event}` : ""} ${record.message}\n`;
    if (level === "error") process.stderr.write(output);
    else process.stdout.write(output);
  }

  recent(limit = 200): LogRecord[] {
    return this.records.slice(-Math.max(1, Math.min(limit, PERSISTED_TAIL_RECORDS)));
  }

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
    const file = this.file;
    if (!file) return;
    try {
      const newestFirst: LogRecord[] = [];
      for (let index = 0; index < file.segments && newestFirst.length < PERSISTED_TAIL_RECORDS; index += 1) {
        const candidate = file.segmentPath(index);
        if (!existsSync(candidate)) continue;
        const lines = readFileSync(candidate, "utf8").split("\n").filter(Boolean);
        for (let line = lines.length - 1; line >= 0 && newestFirst.length < PERSISTED_TAIL_RECORDS; line -= 1) {
          const record = this.parsePersisted(lines[line]!);
          if (record) newestFirst.push(record);
        }
      }
      this.records.push(...newestFirst.reverse());
    } catch {
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
      return undefined;
    }
  }
}
