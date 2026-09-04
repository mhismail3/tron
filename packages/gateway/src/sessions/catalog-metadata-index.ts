import { createHash, randomUUID } from "node:crypto";
import { lstat, mkdir, open, realpath, rename, rm } from "node:fs/promises";
import { createReadStream } from "node:fs";
import { createInterface } from "node:readline";
import { AsyncMutex } from "../util/async-mutex.js";
import { dirname, isAbsolute, join, relative, resolve } from "node:path";
import type { SessionCreationOrigin } from "../protocol/types.js";
import { userFacingPromptPreview } from "./resource-invocation.js";

export const CATALOG_METADATA_INDEX_VERSION = 2 as const;
export const CATALOG_METADATA_INDEX_MAX_BYTES = 8 * 1_024 * 1_024;
export const CATALOG_METADATA_INDEX_MAX_ENTRIES = 25_000;
const TAIL_BOUNDARY_BYTES = 4_096;

export interface CatalogMetadataIndexRow {
  id: string;
  path: string;
  cwd: string;
  parentSessionPath?: string;
  creationOrigin?: SessionCreationOrigin;
  name?: string;
  firstMessage: string;
  createdAt: string;
  updatedAt: string;
  messageCount: number;
  fileIdentity: string;
  size: number;
  mtimeMs: number;
  eofOffset: number;
  tailBoundaryHash: string;
}

export interface CatalogMetadataAccumulator {
  messageCount: number;
  firstMessage: string;
  name: string | undefined;
  updatedAt: string;
}

export function applyCatalogMetadataEntry(target: CatalogMetadataAccumulator, entry: Record<string, unknown>): void {
  if (entry.type === "session_info" && (typeof entry.name === "string" || entry.name === null)) {
    target.name = typeof entry.name === "string" ? entry.name.trim() || undefined : undefined;
    return;
  }
  if (entry.type !== "message") return;
  // Match the pinned SDK catalog contract: every parsed message entry counts,
  // even when its payload is unusable for preview/activity projection.
  target.messageCount += 1;
  if (!entry.message || typeof entry.message !== "object" || Array.isArray(entry.message)) return;
  const message = entry.message as Record<string, unknown>;
  if ((message.role !== "user" && message.role !== "assistant") || !("content" in message)) return;
  if (target.firstMessage === "(no messages)" && message.role === "user") {
    const content = message.content;
    const text = typeof content === "string" ? content
      : Array.isArray(content) ? content
        .filter((part): part is Record<string, unknown> => !!part && typeof part === "object" && !Array.isArray(part))
        .filter((part) => part.type === "text" && typeof part.text === "string")
        .map((part) => part.text as string).join(" ") : "";
    if (text) target.firstMessage = userFacingPromptPreview(text);
  }
  const timestamp = typeof message.timestamp === "number"
    ? message.timestamp
    : typeof entry.timestamp === "number" ? entry.timestamp
      : typeof entry.timestamp === "string" ? Date.parse(entry.timestamp) : NaN;
  if (Number.isFinite(timestamp) && timestamp > 0) {
    const current = Date.parse(target.updatedAt);
    if (!Number.isFinite(current) || timestamp > current) {
      target.updatedAt = new Date(timestamp).toISOString();
    }
  }
}

export interface CatalogMetadataIndexSummary {
  id: string;
  path: string;
  cwd: string;
  parentSessionPath?: string;
  creationOrigin?: SessionCreationOrigin;
  name?: string;
  firstMessage: string;
  createdAt: string;
  updatedAt: string;
  messageCount: number;
}

export interface CatalogMetadataIndexDiagnostics {
  (stage: "load" | "discard" | "rebuild" | "append" | "save", durationMs: number, outcome: "success" | "failure"): void;
}

interface CatalogMetadataIndexDocument {
  version: 2;
  root: string;
  rows: CatalogMetadataIndexRow[];
}

function hash(value: Buffer): string {
  return createHash("sha256").update(value).digest("base64url");
}

function validString(value: unknown, max: number): value is string {
  return typeof value === "string" && value.length <= max;
}

function validCreationOrigin(value: unknown): value is SessionCreationOrigin {
  if (!value || typeof value !== "object" || Array.isArray(value)) return false;
  const origin = value as Partial<SessionCreationOrigin>;
  return origin.kind === "automation" && typeof origin.automationId === "string"
    && /^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/iu.test(origin.automationId);
}

/** Gateway-owned acceleration only. This never stores transcript content. */
export class CatalogMetadataIndex {
  readonly path: string;
  private readonly diagnostics: CatalogMetadataIndexDiagnostics | undefined;
  private readonly writeMutex = new AsyncMutex();

  constructor(private readonly gatewayStateRoot: string, diagnostics?: CatalogMetadataIndexDiagnostics) {
    this.path = join(gatewayStateRoot, "catalog-metadata-v2.json");
    this.diagnostics = diagnostics;
  }

  async save(catalogRoot: string, rows: readonly CatalogMetadataIndexRow[]): Promise<boolean> {
    return this.writeMutex.run(async () => {
      const started = Date.now();
    if (rows.length > CATALOG_METADATA_INDEX_MAX_ENTRIES) {
      this.note("save", started, "failure");
      return false;
    }
    const document: CatalogMetadataIndexDocument = {
      version: CATALOG_METADATA_INDEX_VERSION,
      root: await realpath(catalogRoot).catch(() => resolve(catalogRoot)),
      rows: rows.map((row) => ({ ...row })),
    };
    const encoded = JSON.stringify(document);
    if (Buffer.byteLength(encoded) > CATALOG_METADATA_INDEX_MAX_BYTES) {
      this.note("save", started, "failure");
      return false;
    }
    await mkdir(this.gatewayStateRoot, { recursive: true });
    const temporary = `${this.path}.tmp-${process.pid}-${randomUUID()}`;
    try {
      await rm(temporary, { force: true });
      const handle = await open(temporary, "wx", 0o600);
      try {
        await handle.writeFile(encoded, "utf8");
        await handle.sync();
      } finally { await handle.close(); }
      await rename(temporary, this.path);
      const directory = await open(dirname(this.path), "r");
      try { await directory.sync(); } finally { await directory.close(); }
      this.note("save", started, "success");
      return true;
    } catch (error) {
      this.note("save", started, "failure");
      throw error;
    } finally { await rm(temporary, { force: true }).catch(() => {}); }
    });
  }

  async reconcile(
    catalogRoot: string,
    candidates: readonly { path: string; id: string; cwd: string; fileIdentity: string; size: number; mtimeMs: number }[],
    rebuild: (candidate: { path: string; id: string; cwd: string; fileIdentity: string; size: number; mtimeMs: number }) => Promise<CatalogMetadataIndexSummary | undefined>,
  ): Promise<CatalogMetadataIndexRow[] | undefined> {
    const started = Date.now();
    const document = await this.readDocument(catalogRoot);
    if (!document) {
      this.note("discard", started, "success");
      return undefined;
    }
    const prior = new Map(document.rows.map((row) => [resolve(row.path), row]));
    const rows: CatalogMetadataIndexRow[] = [];
    let rebuiltAny = false;
    for (const candidate of candidates) {
      const candidatePath = await realpath(candidate.path).catch(() => resolve(candidate.path));
      const old = prior.get(candidatePath);
      if (old && old.id === candidate.id && old.cwd === candidate.cwd && old.fileIdentity === candidate.fileIdentity) {
        const unchanged = await this.verifyUnchanged(old);
        if (unchanged) { rows.push(old); continue; }
        const advanced = await this.append(old);
        if (advanced) { rows.push(advanced); continue; }
      }
      rebuiltAny = true;
      const summary = await rebuild(candidate);
      if (!summary) return undefined;
      const rebuilt = await this.entryFromSummary(summary);
      if (!rebuilt || rebuilt.id !== candidate.id || rebuilt.cwd !== candidate.cwd
        || rebuilt.fileIdentity !== candidate.fileIdentity) return undefined;
      rows.push(rebuilt);
    }
    // The candidate set is the exact structural evidence cut. Dropped rows
    // therefore represent removed canonical paths, never stale index entries.
    this.note(rebuiltAny ? "rebuild" : "load", started, "success");
    return rows;
  }

  async append(row: CatalogMetadataIndexRow): Promise<CatalogMetadataIndexRow | undefined> {
    const started = Date.now();
    let handle: Awaited<ReturnType<typeof open>> | undefined;
    try {
      const physical = await lstat(row.path);
      if (!physical.isFile() || physical.isSymbolicLink()
        || `${physical.dev}:${physical.ino}` !== row.fileIdentity
        || row.eofOffset !== row.size || physical.size < row.eofOffset) return undefined;
      handle = await open(row.path, "r");
      const opened = await handle.stat();
      if (!opened.isFile() || `${opened.dev}:${opened.ino}` !== row.fileIdentity
        || opened.size !== physical.size || opened.mtimeMs !== physical.mtimeMs) return undefined;
      if (!(await this.headerMatches(handle, row))) return undefined;
      const before = await this.tailBoundaryHandle(handle, row.eofOffset);
      if (before !== row.tailBoundaryHash) return undefined;
      if (opened.size === row.eofOffset) {
        return opened.mtimeMs === row.mtimeMs ? { ...row } : undefined;
      }
      const finalByte = Buffer.alloc(1);
      const finalRead = await handle.read(finalByte, 0, 1, opened.size - 1);
      if (finalRead.bytesRead !== 1 || finalByte[0] !== 0x0a) return undefined;
      const stream = createReadStream(row.path, {
        start: row.eofOffset,
        end: opened.size - 1,
        fd: handle.fd,
        autoClose: false,
      });
      const lines = createInterface({ input: stream, crlfDelay: Infinity });
      const next = { ...row };
      for await (const line of lines) {
        if (!line) continue;
        let value: unknown;
        try { value = JSON.parse(line); } catch { return undefined; }
        if (!value || typeof value !== "object" || Array.isArray(value)) return undefined;
        this.applyEntry(next, value as Record<string, unknown>);
      }
      const after = await handle.stat();
      const afterPath = await lstat(row.path);
      if (!after.isFile() || !afterPath.isFile() || afterPath.isSymbolicLink()
        || `${after.dev}:${after.ino}` !== row.fileIdentity
        || `${afterPath.dev}:${afterPath.ino}` !== row.fileIdentity
        || after.size !== afterPath.size || after.mtimeMs !== afterPath.mtimeMs
        || after.size !== opened.size || after.mtimeMs !== opened.mtimeMs) return undefined;
      next.size = after.size;
      next.mtimeMs = after.mtimeMs;
      next.eofOffset = after.size;
      next.tailBoundaryHash = await this.tailBoundaryHandle(handle, after.size);
      this.note("append", started, "success");
      return next;
    } catch {
      this.note("append", started, "failure");
      return undefined;
    } finally { await handle?.close().catch(() => {}); }
  }

  async entryFromSummary(summary: CatalogMetadataIndexSummary): Promise<CatalogMetadataIndexRow | undefined> {
    const started = Date.now();
    let handle: Awaited<ReturnType<typeof open>> | undefined;
    try {
      const beforeInput = await lstat(summary.path);
      if (!beforeInput.isFile() || beforeInput.isSymbolicLink()) return undefined;
      const canonical = await realpath(summary.path);
      const beforePath = await lstat(canonical);
      if (!beforePath.isFile() || beforePath.isSymbolicLink()) return undefined;
      handle = await open(canonical, "r");
      const before = await handle.stat();
      if (!before.isFile() || `${before.dev}:${before.ino}` !== `${beforePath.dev}:${beforePath.ino}`) return undefined;
      const header = await this.headerMatches(handle, { ...summary, fileIdentity: `${before.dev}:${before.ino}` } as CatalogMetadataIndexRow);
      if (!header || before.size === 0) return undefined;
      const final = Buffer.alloc(1);
      const finalRead = await handle.read(final, 0, 1, before.size - 1);
      if (finalRead.bytesRead !== 1 || final[0] !== 0x0a) return undefined;
      const after = await handle.stat();
      const afterPath = await lstat(canonical);
      if (!after.isFile() || !afterPath.isFile() || afterPath.isSymbolicLink()
        || `${after.dev}:${after.ino}` !== `${before.dev}:${before.ino}`
        || `${afterPath.dev}:${afterPath.ino}` !== `${before.dev}:${before.ino}`
        || after.size !== before.size || after.mtimeMs !== before.mtimeMs) return undefined;
      return {
        ...summary,
        path: canonical,
        fileIdentity: `${after.dev}:${after.ino}`,
        size: after.size,
        mtimeMs: after.mtimeMs,
        eofOffset: after.size,
        tailBoundaryHash: await this.tailBoundaryHandle(handle, after.size),
      };
    } catch {
      this.note("rebuild", started, "failure");
      return undefined;
    } finally { await handle?.close().catch(() => {}); }
  }

  private applyEntry(row: CatalogMetadataIndexRow, entry: Record<string, unknown>): void {
    const target: CatalogMetadataAccumulator = {
      messageCount: row.messageCount,
      firstMessage: row.firstMessage,
      name: row.name,
      updatedAt: row.updatedAt,
    };
    applyCatalogMetadataEntry(target, entry);
    row.messageCount = target.messageCount;
    row.firstMessage = target.firstMessage;
    row.updatedAt = target.updatedAt;
    if (target.name) row.name = target.name;
    else delete row.name;
  }

  private async headerMatches(handle: Awaited<ReturnType<typeof open>>, row: CatalogMetadataIndexRow): Promise<boolean> {
    const bytes = Buffer.alloc(64 * 1_024);
    const read = await handle.read(bytes, 0, bytes.length, 0);
    const line = bytes.subarray(0, read.bytesRead).toString("utf8").split("\n", 1)[0] ?? "";
    try {
      const value = JSON.parse(line) as Record<string, unknown>;
      return value.type === "session" && value.id === row.id && value.cwd === row.cwd;
    } catch { return false; }
  }

  private async verifyUnchanged(row: CatalogMetadataIndexRow): Promise<boolean> {
    let handle: Awaited<ReturnType<typeof open>> | undefined;
    try {
      const beforePath = await lstat(row.path);
      if (!beforePath.isFile() || beforePath.isSymbolicLink() || row.eofOffset !== row.size) return false;
      handle = await open(row.path, "r");
      const before = await handle.stat();
      if (!before.isFile() || `${before.dev}:${before.ino}` !== row.fileIdentity
        || `${beforePath.dev}:${beforePath.ino}` !== row.fileIdentity
        || before.size !== row.size || before.mtimeMs !== row.mtimeMs) return false;
      if (!(await this.headerMatches(handle, row))) return false;
      const final = Buffer.alloc(1);
      const finalRead = await handle.read(final, 0, 1, before.size - 1);
      if (finalRead.bytesRead !== 1 || final[0] !== 0x0a) return false;
      if (await this.tailBoundaryHandle(handle, row.size) !== row.tailBoundaryHash) return false;
      const after = await handle.stat();
      const afterPath = await lstat(row.path);
      return after.isFile() && after.dev === before.dev && after.ino === before.ino
        && after.size === before.size && after.mtimeMs === before.mtimeMs
        && afterPath.isFile() && !afterPath.isSymbolicLink()
        && afterPath.dev === before.dev && afterPath.ino === before.ino;
    } catch { return false; }
    finally { await handle?.close().catch(() => {}); }
  }

  private async readDocument(catalogRoot: string): Promise<CatalogMetadataIndexDocument | undefined> {
    let handle: Awaited<ReturnType<typeof open>> | undefined;
    try {
      const beforePath = await lstat(this.path);
      if (!beforePath.isFile() || beforePath.isSymbolicLink() || beforePath.size > CATALOG_METADATA_INDEX_MAX_BYTES) return undefined;
      handle = await open(this.path, "r");
      const before = await handle.stat();
      if (!before.isFile() || before.size !== beforePath.size
        || before.dev !== beforePath.dev || before.ino !== beforePath.ino
        || before.size > CATALOG_METADATA_INDEX_MAX_BYTES) return undefined;
      const bytes = Buffer.alloc(before.size);
      let offset = 0;
      while (offset < bytes.length) {
        const read = await handle.read(bytes, offset, bytes.length - offset, offset);
        if (read.bytesRead <= 0) return undefined;
        offset += read.bytesRead;
      }
      const after = await handle.stat();
      const afterPath = await lstat(this.path);
      if (!after.isFile() || after.dev !== before.dev || after.ino !== before.ino
        || after.size !== before.size || after.mtimeMs !== before.mtimeMs
        || !afterPath.isFile() || afterPath.isSymbolicLink()
        || afterPath.dev !== before.dev || afterPath.ino !== before.ino
        || afterPath.size !== before.size || afterPath.mtimeMs !== before.mtimeMs) return undefined;
      const document = JSON.parse(bytes.toString("utf8")) as unknown;
      const canonicalRoot = await realpath(catalogRoot).catch(() => resolve(catalogRoot));
      return this.admitDocument(document, canonicalRoot) ? document : undefined;
    } catch { return undefined; }
    finally { await handle?.close().catch(() => {}); }
  }

  private async tailBoundaryHandle(handle: Awaited<ReturnType<typeof open>>, eofOffset: number): Promise<string> {
    const length = Math.min(TAIL_BOUNDARY_BYTES, eofOffset);
    if (length === 0) return hash(Buffer.alloc(0));
    const bytes = Buffer.alloc(length);
    let offset = 0;
    while (offset < length) {
      const read = await handle.read(bytes, offset, length - offset, eofOffset - length + offset);
      if (read.bytesRead <= 0) throw new Error("short catalog boundary");
      offset += read.bytesRead;
    }
    return hash(bytes);
  }

  private admitDocument(value: unknown, catalogRoot: string): value is CatalogMetadataIndexDocument {
    if (!value || typeof value !== "object" || Array.isArray(value)) return false;
    const document = value as Partial<CatalogMetadataIndexDocument>;
    return document.version === CATALOG_METADATA_INDEX_VERSION
      && validString(document.root, 4_096)
      && resolve(document.root) === resolve(catalogRoot)
      && Array.isArray(document.rows)
      && document.rows.length <= CATALOG_METADATA_INDEX_MAX_ENTRIES
      && document.rows.every((row) => this.admitRow(row, catalogRoot));
  }

  private admitRow(row: unknown, catalogRoot: string): row is CatalogMetadataIndexRow {
    if (!row || typeof row !== "object" || Array.isArray(row)) return false;
    const value = row as Partial<CatalogMetadataIndexRow>;
    const fromRoot = typeof value.path === "string" ? relative(resolve(catalogRoot), resolve(value.path)) : "..";
    return validString(value.id, 256) && validString(value.path, 4_096) && isAbsolute(value.path)
      && fromRoot !== ".." && !fromRoot.startsWith("..") && !isAbsolute(fromRoot)
      && value.path.endsWith(".jsonl") && validString(value.cwd, 4_096)
      && (value.parentSessionPath === undefined || validString(value.parentSessionPath, 4_096))
      && (value.creationOrigin === undefined || (
        value.parentSessionPath === undefined && validCreationOrigin(value.creationOrigin)
      ))
      && (value.name === undefined || validString(value.name, 1_024))
      && validString(value.firstMessage, 64 * 1_024) && validString(value.createdAt, 128)
      && validString(value.updatedAt, 128) && Number.isFinite(Date.parse(value.createdAt))
      && Number.isFinite(Date.parse(value.updatedAt)) && validString(value.fileIdentity, 128)
      && Number.isSafeInteger(value.messageCount) && value.messageCount! >= 0
      && Number.isSafeInteger(value.size) && value.size! >= 0
      && Number.isFinite(value.mtimeMs) && Number.isSafeInteger(value.eofOffset)
      && value.eofOffset! >= 0 && value.eofOffset === value.size
      && validString(value.tailBoundaryHash, 128);
  }

  private note(stage: Parameters<NonNullable<CatalogMetadataIndexDiagnostics>>[0], started: number, outcome: "success" | "failure"): void {
    this.diagnostics?.(stage, Math.max(0, Date.now() - started), outcome);
  }
}
