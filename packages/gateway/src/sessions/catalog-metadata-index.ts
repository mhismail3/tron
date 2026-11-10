import { createHash, randomBytes } from "node:crypto";
import { lstat, mkdir, open, readdir, realpath, rename, rm } from "node:fs/promises";
import { CatalogLineLimitError, readCatalogLines } from "./catalog-jsonl.js";
import { AsyncMutex } from "../util/async-mutex.js";
import { durableAtomicWriteText, durableRemove, syncDurably } from "../foundation/durable-json.js";
import { isAbsolute, join, relative, resolve } from "node:path";
import type { SessionCreationOrigin } from "../protocol/types.js";
import { userFacingPromptPreview } from "../kernel/resources/resource-invocation.js";
import { boundedSummaryText, MAX_SUMMARY_TEXT_BYTES } from "../util/bounded-text.js";

const CATALOG_METADATA_INDEX_VERSION = 3 as const;
const CATALOG_METADATA_INDEX_MAX_ENTRIES = 25_000;
const CATALOG_METADATA_INDEX_WARN_ENTRIES = 20_000;
const CATALOG_METADATA_SHARD_COUNT = 64;
const CATALOG_METADATA_SHARD_MAX_BYTES = 8 * 1_024 * 1_024;
const CATALOG_METADATA_SHARD_WARN_BYTES = 2 * 1_024 * 1_024;
const CATALOG_METADATA_MANIFEST_MAX_BYTES = 64 * 1_024;
const STORE_DIRECTORY_NAME = "catalog-metadata-v3";
const MANIFEST_NAME = "manifest.json";
const SHARD_FILE = /^shard-([0-9a-f]{2})\.json$/u;
const TEMPORARY_FILE = /\.tmp$/u;
const TAIL_BOUNDARY_BYTES = 4_096;
const RECONCILE_CONCURRENCY = 16;
const SHARD_WRITE_CONCURRENCY = 8;

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
    target.name = typeof entry.name === "string" ? boundedSummaryText(entry.name.trim()) || undefined : undefined;
    return;
  }
  if (entry.type !== "message") return;
  const message = entry.message && typeof entry.message === "object" && !Array.isArray(entry.message)
    ? entry.message as Record<string, unknown>
    : undefined;
  if (message?.role === "system") return;
  target.messageCount += 1;
  if (!message) return;
  if ((message.role !== "user" && message.role !== "assistant") || !("content" in message)) return;
  if (target.firstMessage === "(no messages)" && message.role === "user") {
    const content = message.content;
    const text = typeof content === "string" ? content
      : Array.isArray(content) ? content
        .filter((part): part is Record<string, unknown> => !!part && typeof part === "object" && !Array.isArray(part))
        .filter((part) => part.type === "text" && typeof part.text === "string")
        .map((part) => part.text as string).join(" ") : "";
    if (text) target.firstMessage = boundedSummaryText(userFacingPromptPreview(text));
  }
  const timestamp = catalogActivityTimestamp(entry);
  if (timestamp !== undefined) {
    const current = Date.parse(target.updatedAt);
    if (!Number.isFinite(current) || timestamp > current) {
      target.updatedAt = new Date(timestamp).toISOString();
    }
  }
}

export function catalogActivityTimestamp(entry: { type?: unknown; timestamp?: unknown; message?: unknown }): number | undefined {
  if (entry.type !== "message" || !entry.message || typeof entry.message !== "object" || Array.isArray(entry.message)) return;
  const message = entry.message as Record<string, unknown>;
  if ((message.role !== "user" && message.role !== "assistant") || !("content" in message)) return;
  const timestamp = typeof message.timestamp === "number"
    ? message.timestamp
    : typeof entry.timestamp === "number" ? entry.timestamp
      : typeof entry.timestamp === "string" ? Date.parse(entry.timestamp) : NaN;
  return Number.isFinite(timestamp) && timestamp > 0 ? timestamp : undefined;
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
  parsedSize?: number;
}

interface CatalogMetadataIndexReconciliation {
  rows: CatalogMetadataIndexRow[];
  unproven: string[];
}

interface CatalogMetadataReconcileProgress {
  proven: number;
  unproven: number;
}

type CatalogMetadataReconcileStop = (progress: CatalogMetadataReconcileProgress) => boolean | Promise<boolean>;

export type CatalogMetadataIndexFailureStage = "save" | "rebuild" | "append" | "line-limit";
export interface CatalogMetadataIndexFailureDetail {
  reason: "entries" | "shard-bytes" | "write";
  shard?: string;
  rows?: number;
  bytes?: number;
  limit?: number;
}
export type CatalogMetadataIndexFailure =
  (stage: CatalogMetadataIndexFailureStage, durationMs: number, detail?: CatalogMetadataIndexFailureDetail) => void;

export interface CatalogMetadataIndexPressure {
  shard?: string;
  rows: number;
  bytes?: number;
  limit: number;
}

interface CatalogMetadataIndexDocument {
  version: typeof CATALOG_METADATA_INDEX_VERSION;
  root: string;
  rows: CatalogMetadataIndexRow[];
}

interface CatalogMetadataShardDocument extends CatalogMetadataIndexDocument {
  shard: string;
}

interface CatalogMetadataManifest {
  version: typeof CATALOG_METADATA_INDEX_VERSION;
  root: string;
  shards: Array<{ shard: string; digest: string }>;
  refused: string[];
}

interface ShardFileIdentity {
  digest: string;
  ino: number;
  size: number;
  mtimeMs: number;
}

interface BoundedFile {
  bytes: Buffer;
  ino: number;
  size: number;
  mtimeMs: number;
}

interface CatalogMetadataStoreRead {
  complete: boolean;
  rows: CatalogMetadataIndexRow[];
  readable: boolean;
}

function hash(value: Buffer): string {
  return createHash("sha256").update(value).digest("base64url");
}

export function catalogMetadataShard(catalogRoot: string, path: string): string {
  const first = createHash("sha256").update(relative(resolve(catalogRoot), resolve(path))).digest()[0]!;
  return (first % CATALOG_METADATA_SHARD_COUNT).toString(16).padStart(2, "0");
}

function shardFileName(shard: string): string {
  return `shard-${shard}.json`;
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

export class CatalogMetadataIndex {
  readonly directory: string;
  private readonly onFailure: CatalogMetadataIndexFailure | undefined;
  private readonly onPressure: ((pressure: CatalogMetadataIndexPressure) => void) | undefined;
  private readonly writeMutex = new AsyncMutex();
  private readonly shardFiles = new Map<string, ShardFileIdentity>();
  private readonly pressureReported = new Set<string>();
  private closed = false;

  constructor(
    gatewayStateRoot: string,
    onFailure?: CatalogMetadataIndexFailure,
    onPressure?: (pressure: CatalogMetadataIndexPressure) => void,
  ) {
    this.directory = join(gatewayStateRoot, STORE_DIRECTORY_NAME);
    this.onFailure = onFailure;
    this.onPressure = onPressure;
  }

  async dispose(): Promise<void> {
    this.closed = true;
    await this.writeMutex.run(() => {});
  }

  async load(catalogRoot: string): Promise<CatalogMetadataIndexRow[] | undefined> {
    const store = await this.readStore(catalogRoot);
    return store.complete ? store.rows.map((row) => ({ ...row })) : undefined;
  }

  async save(catalogRoot: string, rows: readonly CatalogMetadataIndexRow[]): Promise<boolean> {
    return this.writeMutex.run(async () => {
      if (this.closed) return false;
      const root = await realpath(catalogRoot).catch(() => resolve(catalogRoot));
      return this.writeStore(root, rows);
    });
  }

  async reconcile(
    catalogRoot: string,
    candidates: readonly { path: string; id: string; cwd: string; fileIdentity: string; size: number; mtimeMs: number }[],
    rebuild: (candidate: { path: string; id: string; cwd: string; fileIdentity: string; size: number; mtimeMs: number }) => Promise<CatalogMetadataIndexSummary | undefined>,
    stop?: CatalogMetadataReconcileStop,
  ): Promise<CatalogMetadataIndexReconciliation | undefined> {
    const store = await this.readStore(catalogRoot);
    if (!store.readable) return undefined;
    const prior = new Map(store.rows.map((row) => [resolve(row.path), row]));
    const rows: CatalogMetadataIndexRow[] = [];
    const unproven: string[] = [];
    const shouldStop = async (): Promise<boolean> => this.closed
      || ((await stop?.({ proven: rows.length, unproven: unproven.length })) ?? false);
    for (let start = 0; start < candidates.length; start += RECONCILE_CONCURRENCY) {
      if (await shouldStop()) {
        unproven.push(...candidates.slice(start).map((candidate) => resolve(candidate.path)));
        break;
      }
      const batch = candidates.slice(start, start + RECONCILE_CONCURRENCY);
      const results = await Promise.all(batch.map(async (candidate) => {
        const candidatePath = await realpath(candidate.path).catch(() => resolve(candidate.path));
        const old = prior.get(candidatePath);
        if (old && old.id === candidate.id && old.cwd === candidate.cwd && old.fileIdentity === candidate.fileIdentity) {
          if (await this.verifyUnchanged(old)) return old;
          const advanced = await this.append(old);
          if (advanced) return advanced;
        }
        if (await shouldStop()) return undefined;
        const summary = await rebuild(candidate);
        if (!summary) return undefined;
        const rebuilt = await this.entryFromSummary(summary);
        if (!rebuilt || rebuilt.id !== candidate.id || rebuilt.cwd !== candidate.cwd
          || rebuilt.fileIdentity !== candidate.fileIdentity) return undefined;
        return rebuilt;
      }));
      for (let index = 0; index < results.length; index += 1) {
        const result = results[index];
        if (result) rows.push(result);
        else unproven.push(resolve(batch[index]!.path));
      }
    }
    return { rows, unproven };
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
      const next = { ...row };
      for await (const line of readCatalogLines(handle, row.eofOffset, opened.size)) {
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
      return next;
    } catch (error) {
      this.failed(error instanceof CatalogLineLimitError ? "line-limit" : "append", started);
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
      if (summary.parsedSize !== undefined && summary.parsedSize !== before.size) return undefined;
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
        firstMessage: boundedSummaryText(summary.firstMessage),
        ...(summary.name !== undefined ? { name: boundedSummaryText(summary.name) } : {}),
        path: canonical,
        fileIdentity: `${after.dev}:${after.ino}`,
        size: after.size,
        mtimeMs: after.mtimeMs,
        eofOffset: after.size,
        tailBoundaryHash: await this.tailBoundaryHandle(handle, after.size),
      };
    } catch {
      this.failed("rebuild", started);
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

  private async readStore(catalogRoot: string): Promise<CatalogMetadataStoreRead> {
    return this.readShards(await realpath(catalogRoot).catch(() => resolve(catalogRoot)));
  }

  private async readShards(root: string): Promise<CatalogMetadataStoreRead> {
    const names = await readdir(this.directory).catch(() => [] as string[]);
    const manifest = await this.readManifest(root);
    const byShard = new Map<string, CatalogMetadataIndexRow[]>();
    const digests = new Map<string, string>();
    let total = 0;
    for (const name of names.sort()) {
      const shard = SHARD_FILE.exec(name)?.[1];
      if (shard === undefined) continue;
      const file = await this.readBounded(join(this.directory, name), CATALOG_METADATA_SHARD_MAX_BYTES);
      let document: unknown;
      try { document = file ? JSON.parse(file.bytes.toString("utf8")) : undefined; } catch { document = undefined; }
      if (!file || !this.admitShard(document, shard, root) || total + document.rows.length > CATALOG_METADATA_INDEX_MAX_ENTRIES) {
        this.shardFiles.delete(shard);
        continue;
      }
      total += document.rows.length;
      const digest = hash(file.bytes);
      this.shardFiles.set(shard, { digest, ino: file.ino, size: file.size, mtimeMs: file.mtimeMs });
      digests.set(shard, digest);
      byShard.set(shard, document.rows);
    }
    const complete = manifest !== undefined && manifest.refused.length === 0
      && manifest.shards.every(({ shard, digest }) => byShard.has(shard) && digests.get(shard) === digest);
    const shards = complete ? manifest.shards.map(({ shard }) => shard) : [...byShard.keys()];
    return {
      complete,
      rows: shards.flatMap((shard) => byShard.get(shard) ?? []),
      readable: manifest !== undefined || byShard.size > 0,
    };
  }

  private async readManifest(root: string): Promise<CatalogMetadataManifest | undefined> {
    const file = await this.readBounded(join(this.directory, MANIFEST_NAME), CATALOG_METADATA_MANIFEST_MAX_BYTES);
    if (!file) return undefined;
    try {
      const value = JSON.parse(file.bytes.toString("utf8")) as Partial<CatalogMetadataManifest> | null;
      if (!value || typeof value !== "object" || Array.isArray(value)
        || value.version !== CATALOG_METADATA_INDEX_VERSION || !validString(value.root, 4_096)
        || resolve(value.root) !== resolve(root)
        || !Array.isArray(value.shards)
        || !Array.isArray(value.refused)) return undefined;
      const shardName = (shard: unknown) => typeof shard === "string" && /^[0-9a-f]{2}$/u.test(shard)
        && Number.parseInt(shard, 16) < CATALOG_METADATA_SHARD_COUNT;
      const listed = new Set<unknown>();
      if (!value.shards.every((entry: unknown) => {
        const { shard, digest } = (entry && typeof entry === "object" ? entry : {}) as { shard?: unknown; digest?: unknown };
        if (!shardName(shard) || !validString(digest, 128) || listed.has(shard)) return false;
        listed.add(shard);
        return true;
      })
        || !value.refused.every(shardName)) return undefined;
      return value as CatalogMetadataManifest;
    } catch { return undefined; }
  }

  private async writeStore(root: string, rows: readonly CatalogMetadataIndexRow[]): Promise<boolean> {
    const stage = "save";
    const started = Date.now();
    if (rows.length > CATALOG_METADATA_INDEX_MAX_ENTRIES) {
      this.failed(stage, started, { reason: "entries", rows: rows.length, limit: CATALOG_METADATA_INDEX_MAX_ENTRIES });
      return false;
    }
    const groups = new Map<string, CatalogMetadataIndexRow[]>();
    for (const row of rows) {
      const shard = catalogMetadataShard(root, row.path);
      const group = groups.get(shard);
      if (group) group.push({ ...row });
      else groups.set(shard, [{ ...row }]);
    }
    try {
      await mkdir(this.directory, { recursive: true, mode: 0o700 });
      const existing = await readdir(this.directory);
      for (const name of existing) {
        if (TEMPORARY_FILE.test(name)) await rm(join(this.directory, name), { force: true });
      }
      const manifest: CatalogMetadataManifest = { version: CATALOG_METADATA_INDEX_VERSION, root, shards: [], refused: [] };
      const changed: Array<{ shard: string; path: string; encoded: string; digest: string }> = [];
      for (const [shard, group] of [...groups].sort(([a], [b]) => a.localeCompare(b))) {
        const document: CatalogMetadataShardDocument = { version: CATALOG_METADATA_INDEX_VERSION, root, shard, rows: group };
        const encoded = JSON.stringify(document);
        const bytes = Buffer.byteLength(encoded);
        if (bytes > CATALOG_METADATA_SHARD_MAX_BYTES) {
          manifest.refused.push(shard);
          this.failed(stage, started, { reason: "shard-bytes", shard, rows: group.length, bytes, limit: CATALOG_METADATA_SHARD_MAX_BYTES });
          continue;
        }
        if (bytes > CATALOG_METADATA_SHARD_WARN_BYTES) {
          this.pressure(shard, { shard, rows: group.length, bytes, limit: CATALOG_METADATA_SHARD_MAX_BYTES });
        }
        const digest = hash(Buffer.from(encoded, "utf8"));
        manifest.shards.push({ shard, digest });
        const path = join(this.directory, shardFileName(shard));
        if (!(await this.shardInPlace(shard, path, digest))) changed.push({ shard, path, encoded, digest });
      }
      await this.publishShards(changed);
      if (rows.length > CATALOG_METADATA_INDEX_WARN_ENTRIES) {
        this.pressure("rows", { rows: rows.length, limit: CATALOG_METADATA_INDEX_MAX_ENTRIES });
      }
      await durableAtomicWriteText(join(this.directory, MANIFEST_NAME), JSON.stringify(manifest));
      for (const name of existing) {
        const shard = SHARD_FILE.exec(name)?.[1];
        if (shard === undefined || manifest.shards.some((entry) => entry.shard === shard) || manifest.refused.includes(shard)) continue;
        this.shardFiles.delete(shard);
        await durableRemove(join(this.directory, name));
      }
      return manifest.refused.length === 0;
    } catch (error) {
      this.failed(stage, started, { reason: "write", rows: rows.length });
      throw error;
    }
  }

  private async publishShards(changed: readonly { shard: string; path: string; encoded: string; digest: string }[]): Promise<void> {
    if (changed.length === 0) return;
    for (let start = 0; start < changed.length; start += SHARD_WRITE_CONCURRENCY) {
      const results = await Promise.allSettled(changed.slice(start, start + SHARD_WRITE_CONCURRENCY).map(async ({ shard, path, encoded, digest }) => {
        this.shardFiles.delete(shard);
        const temporary = `${path}.${process.pid}.${randomBytes(6).toString("hex")}.tmp`;
        try {
          const handle = await open(temporary, "wx", 0o600);
          try {
            await handle.writeFile(encoded, "utf8");
            await syncDurably(handle);
          } finally { await handle.close(); }
          await rename(temporary, path);
        } catch (error) {
          await rm(temporary, { force: true }).catch(() => {});
          throw error;
        }
        const written = await lstat(path);
        this.shardFiles.set(shard, { digest, ino: written.ino, size: written.size, mtimeMs: written.mtimeMs });
      }));
      const failure = results.find((result) => result.status === "rejected");
      if (failure) throw failure.reason;
    }
    const directory = await open(this.directory, "r");
    try { await syncDurably(directory); } finally { await directory.close(); }
  }

  private async shardInPlace(shard: string, path: string, digest: string): Promise<boolean> {
    const known = this.shardFiles.get(shard);
    if (!known || known.digest !== digest) return false;
    const current = await lstat(path).catch(() => undefined);
    return current !== undefined && current.isFile() && current.ino === known.ino
      && current.size === known.size && current.mtimeMs === known.mtimeMs;
  }

  private async readBounded(path: string, maximumBytes: number): Promise<BoundedFile | undefined> {
    let handle: Awaited<ReturnType<typeof open>> | undefined;
    try {
      const beforePath = await lstat(path);
      if (!beforePath.isFile() || beforePath.isSymbolicLink() || beforePath.size > maximumBytes) return undefined;
      handle = await open(path, "r");
      const before = await handle.stat();
      if (!before.isFile() || before.size !== beforePath.size
        || before.dev !== beforePath.dev || before.ino !== beforePath.ino
        || before.size > maximumBytes) return undefined;
      const bytes = Buffer.alloc(before.size);
      let offset = 0;
      while (offset < bytes.length) {
        const read = await handle.read(bytes, offset, bytes.length - offset, offset);
        if (read.bytesRead <= 0) return undefined;
        offset += read.bytesRead;
      }
      const after = await handle.stat();
      const afterPath = await lstat(path);
      if (!after.isFile() || after.dev !== before.dev || after.ino !== before.ino
        || after.size !== before.size || after.mtimeMs !== before.mtimeMs
        || !afterPath.isFile() || afterPath.isSymbolicLink()
        || afterPath.dev !== before.dev || afterPath.ino !== before.ino
        || afterPath.size !== before.size || afterPath.mtimeMs !== before.mtimeMs) return undefined;
      return { bytes, ino: before.ino, size: before.size, mtimeMs: before.mtimeMs };
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

  private admitShard(value: unknown, shard: string, catalogRoot: string): value is CatalogMetadataShardDocument {
    return this.admitDocument(value, catalogRoot)
      && (value as Partial<CatalogMetadataShardDocument>).shard === shard
      && value.rows.every((row) => catalogMetadataShard(catalogRoot, row.path) === shard);
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
      && (value.name === undefined || (validString(value.name, MAX_SUMMARY_TEXT_BYTES)
        && Buffer.byteLength(value.name) <= MAX_SUMMARY_TEXT_BYTES))
      && validString(value.firstMessage, MAX_SUMMARY_TEXT_BYTES)
      && Buffer.byteLength(value.firstMessage) <= MAX_SUMMARY_TEXT_BYTES && validString(value.createdAt, 128)
      && validString(value.updatedAt, 128) && Number.isFinite(Date.parse(value.createdAt))
      && Number.isFinite(Date.parse(value.updatedAt)) && validString(value.fileIdentity, 128)
      && Number.isSafeInteger(value.messageCount) && value.messageCount! >= 0
      && Number.isSafeInteger(value.size) && value.size! >= 0
      && Number.isFinite(value.mtimeMs) && Number.isSafeInteger(value.eofOffset)
      && value.eofOffset! >= 0 && value.eofOffset === value.size
      && validString(value.tailBoundaryHash, 128);
  }

  private failed(stage: CatalogMetadataIndexFailureStage, started: number, detail?: CatalogMetadataIndexFailureDetail): void {
    this.onFailure?.(stage, Math.max(0, Date.now() - started), ...(detail ? [detail] as const : []));
  }

  private pressure(key: string, pressure: CatalogMetadataIndexPressure): void {
    if (this.pressureReported.has(key)) return;
    this.pressureReported.add(key);
    this.onPressure?.(pressure);
  }
}
