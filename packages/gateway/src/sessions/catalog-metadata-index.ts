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
/** The catalog's own session bound: the index never holds more rows than the
 * catalog can list. */
const CATALOG_METADATA_INDEX_MAX_ENTRIES = 25_000;
const CATALOG_METADATA_INDEX_WARN_ENTRIES = 20_000;
/** Rows are spread over a fixed set of shards by a hash of their canonical
 * path, so no one file grows with the catalog: 25,000 average rows (~1.6 KiB)
 * are ~625 KiB per shard, and even rows at every field bound stay under the
 * ceiling. The warning fires at a quarter of the ceiling, far above normal use
 * and far below refusal. */
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
  // System-message transcript deltas carry provider context in Pi 0.87 but
  // aren't visible conversation rows. Keep malformed non-system records counted
  // as before, while matching live and cold catalog counts for that new entry.
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

/** Cold catalogs and live summaries share the same canonical recency boundary.
 * Restoring settings or extension metadata must not impersonate conversation work. */
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
  /** The file size the counts above were parsed from. A source that can observe
   * it sets it, and the index then refuses to stamp a row with a later size:
   * an append between the parse and the stamp would make the row claim an
   * offset past content it never counted. */
  parsedSize?: number;
}

/** One reconcile's result. A candidate the pass could not prove is reported
 * instead of failing the whole cut: the caller keeps its own prior row for that
 * path, because an unprovable file proves neither presence nor absence. */
interface CatalogMetadataIndexReconciliation {
  rows: CatalogMetadataIndexRow[];
  unproven: string[];
}

/** What one reconcile has proven so far. A candidate whose row is missing from
 * `rows` and from `unproven` has not been read yet. */
interface CatalogMetadataReconcileProgress {
  proven: number;
  unproven: number;
}

/** The owner's own control over one reconcile pass, asked between batches of
 * candidates and before each transcript parse. Returning true stops the pass;
 * the call is awaited, so it is also where a pass hands the loop back — the
 * session catalog yields to the background-work scheduler's pause there, which
 * is what keeps a startup or watcher-triggered pass from holding the loop while
 * a request waits. The owner passes its own shutdown flag — the index's `closed`
 * is set only after the owner has finished closing, so it cannot report the
 * owner's shutdown — and the pre-index acquisition path stops at the first file
 * it cannot prove, because it discards the whole cut in that case and would
 * otherwise parse every later candidate for nothing. A stopped pass reports the
 * remaining candidates as unproven. */
type CatalogMetadataReconcileStop = (progress: CatalogMetadataReconcileProgress) => boolean | Promise<boolean>;

/** A handled index failure. The affected rows are left to be rebuilt from
 * canonical files, so nothing else records it; the index write is
 * fire-and-forget outside any request span, which is why its owner reports it.
 * A refused save names why and how large the refused part was, so one log line
 * diagnoses a bound. */
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

/** A save that is still accepted but has passed its warning threshold: one
 * shard's bytes, or the whole store's rows. Reported once per process for each
 * shard (or for the row count), well before the refusal bound. */
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

/** The commit point of one save. It names each non-empty shard with the hash of
 * the exact bytes that save wrote; a shard the save refused is listed as
 * refused, and its last accepted file is kept. Only a manifest whose every
 * listed shard reads back with its hash, and that refused nothing, is a
 * complete cut. */
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

/** What the store holds for one root. `complete` rows are one save's whole cut;
 * otherwise `rows` are every row a readable shard still holds, which are reuse
 * candidates only (each is re-verified against its file before reuse). */
interface CatalogMetadataStoreRead {
  complete: boolean;
  rows: CatalogMetadataIndexRow[];
  readable: boolean;
}

function hash(value: Buffer): string {
  return createHash("sha256").update(value).digest("base64url");
}

/** The shard a row lives in: a stable function of its canonical path relative
 * to the catalog root, so the assignment does not depend on where the root is. */
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

/** Gateway-owned acceleration only. This never stores transcript content.
 *
 * The store is a directory of shard files plus a manifest, each published by an
 * atomic temporary-file write, fsync and rename. A save rewrites only the shards
 * whose bytes changed, then the manifest, then removes shards that became empty.
 * A crash at any point leaves either the previous manifest (whose hashes then
 * disagree with a rewritten shard, so the cut is incomplete) or the new one;
 * neither is ever read as a cut it is not. A corrupt, oversized or missing
 * shard costs only its own rows: the others still accelerate the rebuild. */
export class CatalogMetadataIndex {
  /** The sharded store directory. */
  readonly directory: string;
  private readonly onFailure: CatalogMetadataIndexFailure | undefined;
  private readonly onPressure: ((pressure: CatalogMetadataIndexPressure) => void) | undefined;
  private readonly writeMutex = new AsyncMutex();
  /** Each shard file as this process last read or wrote it: its hash and the
   * file it was in. A save skips a shard only when its new bytes hash the same
   * and that same file is still in place unchanged, so a file replaced or
   * damaged behind the owner is rewritten. A stale entry can only cost an
   * extra write. */
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

  /** Its caller persists this index fire-and-forget (a catalog read must not
   * wait for acceleration), so the write can still be in flight when the owning
   * registry reports disposal. Shutdown owns that window: refuse new writes and
   * settle the admitted one, or a temp file and its rename can land in the
   * Gateway state directory after the owner has released it. */
  async dispose(): Promise<void> {
    this.closed = true;
    await this.writeMutex.run(() => {});
  }

  /** The durable rows of one complete cut, or undefined when the store is
   * missing, incomplete, corrupt or bound to another root. Its caller (the
   * catalog owner) rebuilds from canonical files, so an unusable store is never
   * membership evidence. */
  async load(catalogRoot: string): Promise<CatalogMetadataIndexRow[] | undefined> {
    const store = await this.readStore(catalogRoot);
    return store.complete ? store.rows.map((row) => ({ ...row })) : undefined;
  }

  /** Publish one complete cut. False when any part was refused (the entry
   * bound, or a shard over its byte ceiling) or the store is closed: a refused
   * shard keeps its last accepted file, the manifest records the refusal, and
   * the failure is reported with its size. */
  async save(catalogRoot: string, rows: readonly CatalogMetadataIndexRow[]): Promise<boolean> {
    return this.writeMutex.run(async () => {
      // Checked inside the mutex: a write queued after disposal began, but
      // before its drain, must observe the closed owner instead of publishing.
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
    // Every readable shard's rows are reuse candidates, whether or not the cut
    // they belong to is complete: each is re-verified against its file below.
    const store = await this.readStore(catalogRoot);
    if (!store.readable) return undefined;
    const prior = new Map(store.rows.map((row) => [resolve(row.path), row]));
    // Reconcile is an independent bounded read phase: serializing every
    // lstat/header/tail read would make a valid index an O(session-count)
    // startup stall on large catalogs. Keep the candidate
    // order for deterministic output while allowing bounded filesystem
    // parallelism; each candidate still performs the same identity and
    // stability checks before its row is admitted.
    const rows: CatalogMetadataIndexRow[] = [];
    const unproven: string[] = [];
    // A disposed index must not keep reading files it can no longer publish,
    // and the caller may have its own reason to stop and its own yield point.
    // Either way the remaining candidates stay unproven instead of holding this
    // pass open.
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
    // The candidate set is the exact structural evidence cut. A proven row is
    // published; a candidate this pass could not prove is reported so its
    // caller retains whatever row it already had, and a candidate that is
    // absent from the cut is still a removed canonical path.
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
      // The summary's counts only describe the bytes it parsed. A file that
      // grew since then must not be stamped with the later size, or the row
      // claims an offset past a message it never counted and every later
      // append starts from there.
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

  /** The store for one root. */
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
    // A complete cut is exactly the manifest's shards: a file the manifest no
    // longer lists is one a crash left before its removal.
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

  /** One save, inside the write mutex. */
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
      // One Gateway owns this directory and its writes are serialized here, so
      // any temporary file present now is debris of an interrupted write.
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
      // Pruned only after the manifest commit: a shard that became empty. A
      // refused shard keeps its last accepted file.
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

  /** Each changed shard is written to its own temporary file and synchronized
   * (a bounded number at once), renamed into place, and the directory is
   * synchronized once before the caller commits the manifest: no manifest can
   * become durable ahead of a shard rename it names. */
  private async publishShards(changed: readonly { shard: string; path: string; encoded: string; digest: string }[]): Promise<void> {
    if (changed.length === 0) return;
    for (let start = 0; start < changed.length; start += SHARD_WRITE_CONCURRENCY) {
      // Settled, not raced: no write of a failed batch may still rename after
      // this save has returned and released the mutex.
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

  /** One owner-written file read whole, or undefined when it is missing, not a
   * regular file, over its bound, or changed while it was read. */
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
