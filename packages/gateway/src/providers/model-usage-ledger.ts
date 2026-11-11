import { constants } from "node:fs";
import { open } from "node:fs/promises";
import type { AssistantMessage, Usage } from "../kernel/pi/ai.js";
import type { ModelQueueRole } from "./model-queue-extension.js";
import { durableAtomicWriteText } from "../foundation/durable-json.js";
import { tronHomePath } from "../foundation/tron-home-layout.js";

const MAX_BYTES = 8 * 1024 * 1024;
const MAX_RECORDS = 10_000;
const RETENTION_MS = 30 * 24 * 60 * 60_000;
const COUNTERS = ["input", "output", "cacheRead", "cacheWrite", "cacheWrite1h", "cacheWrite5m"] as const;
const STATUSES = ["pending", "stop", "length", "toolUse", "error", "aborted", "deferred", "threw"] as const;

type Counter = typeof COUNTERS[number];
type Status = typeof STATUSES[number];
export type ModelUsageCaller = { sessionId: string } | { taskId: string };
export interface ModelUsageIdentity {
  provider: string;
  model: string;
  role: ModelQueueRole;
  kind: "background" | "summarizer";
  caller: ModelUsageCaller;
}
type Record = ModelUsageIdentity & { timestamp: number; status: Status } & { [K in Counter]: number | null };

export class ModelUsageLedgerError extends Error {
  constructor(readonly code: "invalid-store" | "read-failed" | "write-failed") {
    super(`Model usage ledger ${code}`);
  }
}

export function modelUsageLedgerPath(tronHome: string): string {
  return tronHomePath(tronHome, "gateway/model-usage.json");
}

function object(value: unknown): value is { [key: string]: unknown } {
  return value !== null && typeof value === "object" && !Array.isArray(value);
}

function keys(value: { [key: string]: unknown }, expected: readonly string[]): boolean {
  return Object.keys(value).length === expected.length && expected.every(key => Object.hasOwn(value, key));
}

function identifier(value: unknown, maximum: number): value is string {
  return typeof value === "string" && value.length > 0 && Buffer.byteLength(value) <= maximum && !/[\u0000-\u001f\u007f]/u.test(value);
}

function counter(value: unknown): value is number {
  return Number.isSafeInteger(value) && (value as number) >= 0;
}

function validRecord(value: unknown): value is Record {
  if (!object(value) || !keys(value, ["provider", "model", "role", "kind", "caller", "timestamp", "status", ...COUNTERS])) return false;
  if (!identifier(value.provider, 256) || !identifier(value.model, 1_024) || !counter(value.timestamp)) return false;
  if (!["worker", "background", "subagent"].includes(value.role as string)
    || !["background", "summarizer"].includes(value.kind as string) || !STATUSES.includes(value.status as Status)) return false;
  if (!object(value.caller) || !(keys(value.caller, ["sessionId"]) && identifier(value.caller.sessionId, 256)
    || keys(value.caller, ["taskId"]) && identifier(value.caller.taskId, 256))) return false;
  if (!COUNTERS.every(key => value[key] === null || counter(value[key]))) return false;
  if (counter(value.cacheWrite)) {
    if (counter(value.cacheWrite1h) && value.cacheWrite1h > value.cacheWrite) return false;
    if (counter(value.cacheWrite5m) && value.cacheWrite5m > value.cacheWrite) return false;
    if (counter(value.cacheWrite1h) && counter(value.cacheWrite5m) && value.cacheWrite1h + value.cacheWrite5m !== value.cacheWrite) return false;
  }
  return true;
}

function usageRecord(identity: ModelUsageIdentity, timestamp: number, status: Status, usage?: Usage): Record {
  const known = status !== "threw" && (!(status === "error" || status === "aborted")
    || [usage?.input, usage?.output, usage?.cacheRead, usage?.cacheWrite].some(value => counter(value) && value > 0));
  const token = (value: unknown) => known && counter(value) ? value : null;
  const cacheWrite = token(usage?.cacheWrite);
  const longWrite = token(usage?.cacheWrite1h);
  const cacheWrite1h = cacheWrite !== null && longWrite !== null && longWrite <= cacheWrite ? longWrite : null;
  const caller: ModelUsageCaller = "sessionId" in identity.caller
    ? { sessionId: identity.caller.sessionId } : { taskId: identity.caller.taskId };
  return { provider: identity.provider, model: identity.model, role: identity.role, kind: identity.kind, caller,
    timestamp, status, input: token(usage?.input), output: token(usage?.output), cacheRead: token(usage?.cacheRead), cacheWrite,
    cacheWrite1h, cacheWrite5m: cacheWrite !== null && cacheWrite1h !== null ? cacheWrite - cacheWrite1h : null };
}

export class ModelUsageLedger {
  private writing: Promise<void> = Promise.resolve();
  private readonly path: string;

  constructor(tronHome: string, private readonly now: () => number = Date.now) {
    this.path = modelUsageLedgerPath(tronHome);
  }

  async initialize(): Promise<void> {
    await this.serialize(async () => this.publish(await this.load()));
  }

  async check(identity: ModelUsageIdentity): Promise<void> {
    if (!validRecord(usageRecord(identity, this.now(), "threw"))) throw new ModelUsageLedgerError("invalid-store");
    await this.writing;
    await this.load();
  }

  async record(identity: ModelUsageIdentity, status: AssistantMessage["stopReason"] | "threw", usage?: Usage): Promise<void> {
    const record = usageRecord(identity, this.now(), status, usage);
    if (!validRecord(record)) throw new ModelUsageLedgerError("invalid-store");
    await this.serialize(async () => this.publish([...(await this.load()), record]));
  }

  private async serialize(action: () => Promise<void>): Promise<void> {
    const write = this.writing.then(action);
    this.writing = write.catch(() => {});
    await write;
  }

  private async load(): Promise<Record[]> {
    try {
      let handle;
      try { handle = await open(this.path, constants.O_RDONLY | constants.O_NOFOLLOW | constants.O_NONBLOCK); }
      catch (error) {
        if ((error as NodeJS.ErrnoException).code === "ENOENT") return [];
        throw error;
      }
      let text: string;
      try {
        const info = await handle.stat();
        if (!info.isFile() || info.size > MAX_BYTES) throw new ModelUsageLedgerError("invalid-store");
        const buffer = Buffer.alloc(info.size + 1);
        let length = 0;
        while (length < buffer.length) {
          const { bytesRead } = await handle.read(buffer, length, buffer.length - length, length);
          if (bytesRead === 0) break;
          length += bytesRead;
        }
        if (length > info.size) throw new ModelUsageLedgerError("invalid-store");
        try { text = new TextDecoder("utf-8", { fatal: true }).decode(buffer.subarray(0, length)); }
        catch { throw new ModelUsageLedgerError("invalid-store"); }
      } finally { await handle.close(); }
      let document: unknown;
      try { document = JSON.parse(text); }
      catch { throw new ModelUsageLedgerError("invalid-store"); }
      if (!object(document) || !keys(document, ["version", "records"]) || document.version !== 1
        || !Array.isArray(document.records) || document.records.length > MAX_RECORDS || !document.records.every(validRecord)) {
        throw new ModelUsageLedgerError("invalid-store");
      }
      return document.records;
    } catch (error) {
      throw error instanceof ModelUsageLedgerError ? error : new ModelUsageLedgerError("read-failed");
    }
  }

  private async publish(records: Record[]): Promise<void> {
    const cutoff = this.now() - RETENTION_MS;
    const retained = records.filter(record => record.timestamp >= cutoff).sort((a, b) => a.timestamp - b.timestamp).slice(-MAX_RECORDS);
    const lines = retained.map(record => JSON.stringify(record));
    let bytes = Buffer.byteLength('{"version":1,"records":[]}\n') + lines.reduce((sum, line) => sum + Buffer.byteLength(line), 0) + Math.max(0, lines.length - 1);
    let start = 0;
    while (bytes > MAX_BYTES && start < lines.length) {
      bytes -= Buffer.byteLength(lines[start++]!) + (start < lines.length ? 1 : 0);
    }
    try { await durableAtomicWriteText(this.path, `{"version":1,"records":[${lines.slice(start).join(",")}]}\n`); }
    catch { throw new ModelUsageLedgerError("write-failed"); }
  }
}
