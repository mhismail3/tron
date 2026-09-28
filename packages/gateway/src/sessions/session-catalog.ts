import { watch } from "node:fs";
import { lstat, readdir, realpath } from "node:fs/promises";
import { basename, dirname, isAbsolute, join, relative, resolve, sep } from "node:path";
import { isIgnoredCatalogDirectory } from "./catalog-discovery.js";
import type {
  CatalogMetadataIndex,
  CatalogMetadataIndexRow,
  CatalogMetadataIndexSummary,
} from "./catalog-metadata-index.js";

/** pi-subagents' reserved run directory inside one producer's child folder. */
export const SUBAGENT_RUN_DIRECTORY = /^run-\d+$/u;

/** pi-subagents reserves exactly two layouts beneath the canonical catalog for
 * delegated transcripts: `<parent-stem>/forks/<fork>.jsonl` and
 * `<parent-stem>/<producer>/run-N/session.jsonl`. Anything else at the same
 * depth, and any deeper path, stays an ordinary user session. The catalog owns
 * this rule because it classifies its own rows with it. */
export function delegatedSessionParentPath(sessionPath: string, catalogRoot: string): string | undefined {
  const resolvedPath = resolve(sessionPath);
  const fromCatalog = relative(catalogRoot, resolvedPath);
  if (fromCatalog === "" || fromCatalog === ".." || fromCatalog.startsWith(`..${sep}`)
    || isAbsolute(fromCatalog) || !resolvedPath.endsWith(".jsonl")) return undefined;

  const containingDirectory = dirname(resolvedPath);
  let expectedParent: string | undefined;
  if (basename(containingDirectory) === "forks" && basename(resolvedPath) !== ".jsonl") {
    expectedParent = resolve(`${dirname(containingDirectory)}.jsonl`);
  } else if (basename(resolvedPath) === "session.jsonl"
    && SUBAGENT_RUN_DIRECTORY.test(basename(containingDirectory))) {
    const producerDirectory = dirname(containingDirectory);
    const producer = basename(producerDirectory);
    if (producer && producer !== "forks") expectedParent = resolve(`${dirname(producerDirectory)}.jsonl`);
  }
  if (!expectedParent) return undefined;
  const parentFromCatalog = relative(catalogRoot, expectedParent);
  return parentFromCatalog !== "" && parentFromCatalog !== ".."
    && !parentFromCatalog.startsWith(`..${sep}`) && !isAbsolute(parentFromCatalog)
    ? expectedParent : undefined;
}

/** Acceleration is written from a bursty owner, so a durable write waits for a
 * quiet spell; a burst of Gateway-owned changes costs one write. A stream that
 * never goes quiet must still reach the document before a crash, so the quiet
 * spell is capped: at 3,000 rows one write is about 1.5 MB, and G-10 owns its
 * measured volume. */
export const CATALOG_PERSIST_DEBOUNCE_MS = 5_000;
export const CATALOG_PERSIST_MAX_WAIT_MS = 60_000;

/** One filesystem event is a hint, not a fact: Pi appends in bursts and a
 * platform reports create, write and close separately, so a path is re-read
 * once per quiet spell instead of once per event. A writer that never goes quiet
 * still has to reach its row, so the quiet spell is capped the way persistence
 * is: events arriving faster than the quiet spell cost one read a second. The
 * ceiling bounds how long a read is delayed, not how often reads happen — a
 * writer whose bursts each outlast the quiet spell costs one read per burst, so
 * about four a second per path. */
export const CATALOG_EVENT_DEBOUNCE_MS = 250;
export const CATALOG_EVENT_MAX_WAIT_MS = 1_000;

/** A directory event names the folder, not the transcripts inside it, so the
 * folder's own `.jsonl` files are re-read. A folder holding more transcripts
 * than this is re-derived by one whole-folder pass instead, which bounds the
 * per-path debounce map and the work a single event can name. */
export const CATALOG_EVENT_DIRECTORY_LIMIT = 64;

/** The backstop for every change the watcher cannot see: an event the platform
 * coalesced, dropped or reported while the watcher was restarting is repaired
 * by reading the folder's own cut this often. */
export const CATALOG_RECONCILE_INTERVAL_MS = 30 * 60_000;

/** How soon a watcher that could not start is tried again: a root that is
 * missing now (a fresh installation, a folder being moved back) is watched as
 * soon as it exists instead of at the next reconciliation. */
export const CATALOG_WATCH_RETRY_MS = 5_000;

/** How many tail reads one change costs before its row is re-derived from the
 * whole file. A Pi append that lands inside the read is the transient this
 * retries; anything else (a replaced inode, a truncated file) is not. */
const APPEND_ATTEMPTS = 2;

/** What one reconcile did, for the catalog juncture's `catalog.reconciled`. An
 * incomplete or failed pass publishes nothing, so it is recorded instead of
 * being silent. */
export interface SessionCatalogReconcileOutcome {
  outcome: "reconciled" | "incomplete" | "failed";
  files: number;
  added: number;
  removed: number;
  modified: number;
  /** Candidates this pass could not prove. Their rows are the ones the index
   * already published, if any, so a file left out is visible here. */
  unproven: number;
  durationMs: number;
}

/** One canonical session file. `CatalogMetadataIndexRow` owns everything read
 * from the file; the catalog adds only the classification of its own paths. */
export interface SessionCatalogRow extends CatalogMetadataIndexRow {
  /** A pi-subagents reserved transcript (fork or child run), never a dashboard
   * session row. Derived from the path, so it is not persisted. */
  delegated: boolean;
}

export interface SessionCatalogCandidate {
  path: string;
  id: string;
  cwd: string;
  fileIdentity: string;
  size: number;
  mtimeMs: number;
}

/** One complete structural cut of the canonical catalog. A scan is only a path
 * set: every row is rebuilt from its canonical file through the durable index,
 * so an incomplete cut is never membership evidence. */
export interface SessionCatalogScan {
  complete: boolean;
  candidates: readonly SessionCatalogCandidate[];
}

/** Why the folder watcher is not observing the catalog. `error` is a watcher
 * that was observing and stopped; `unavailable` is a watcher that found the
 * folder itself gone, or a start attempt that got no watcher (a missing or
 * unreadable root). A platform overflow is not reported
 * separately — `fs.watch` does not surface it — so dropped events are the
 * periodic reconciliation's job rather than this path's. */
export type SessionCatalogWatcherResetReason = "error" | "unavailable";

/** One row the watcher changed for a single file, for `catalog.changed`. A
 * Gateway-owned change is not reported: it is attributable to the commit that
 * made it, and reporting every persist would fill the debug buffer that exists
 * to keep the changes no request can explain. */
export interface SessionCatalogChange {
  sessionId: string;
  /** `appended` advanced the durable tail; `rebuilt` re-derived the whole row
   * because the file's identity, size or tail no longer matched it; `removed`
   * dropped the row because the file it was built from is gone. */
  outcome: "appended" | "rebuilt" | "removed";
  durationMs: number;
}

export interface SessionCatalogWatcherReset {
  reason: SessionCatalogWatcherResetReason;
}

/** What the catalog owner needs from a folder watcher: one hint per changed
 * path, and one call when a watcher it already returned stops observing. A
 * start that fails throws instead. */
export interface SessionCatalogWatchRequest {
  /** The canonical (realpath) folder to watch; events name paths under it. */
  root: string;
  /** One event's path, relative to `root`, or null when the platform could not
   * name the changed file. */
  onEvent(filename: string | null): void;
  onReset(reason: SessionCatalogWatcherResetReason): void;
}

export interface SessionCatalogWatchHandle {
  close(): void;
}

/** The production watcher: a recursive `fs.watch` (FSEvents on macOS), the only
 * source that sees an external writer — a subagent child, a copied-in file —
 * without a walk. `persistent: false` keeps it from holding the process open. */
function watchCatalogFolder(request: SessionCatalogWatchRequest): SessionCatalogWatchHandle {
  const watcher = watch(request.root, { recursive: true, persistent: false }, (_event, filename) => {
    request.onEvent(typeof filename === "string" ? filename : null);
  });
  watcher.on("error", () => request.onReset("error"));
  return { close: () => watcher.close() };
}

/** The watcher ignores exactly the directories discovery ignores, or the index
 * would carry rows no scan can prove are canonical. */
function ignoredCatalogPath(path: string, canonicalRoot: string): boolean {
  for (let directory = dirname(path);; directory = dirname(directory)) {
    if (isIgnoredCatalogDirectory(directory, canonicalRoot)) return true;
    if (directory === canonicalRoot || dirname(directory) === directory) return false;
  }
}

/** True only when the path is absent. Any other error (a permission failure, an
 * I/O error) proves neither presence nor absence, so it is not membership
 * evidence and keeps whatever row the index already published. */
async function pathMissing(path: string): Promise<boolean> {
  return lstat(path).then(() => false, (error: NodeJS.ErrnoException) => error.code === "ENOENT");
}

/** The catalog's canonical readers: the folder cut, and one file's metadata. */
export interface SessionCatalogSource {
  scan(): Promise<SessionCatalogScan>;
  /** Canonical metadata for one file, or undefined when it cannot be read as a
   * canonical session right now. */
  summaryFor(path: string): Promise<CatalogMetadataIndexSummary | undefined>;
}

export interface SessionCatalogOptions {
  /** Absolute canonical session folder; the durable document belongs to it. */
  catalogRoot: () => string;
  /** The durable form. One document has one writer — this owner — because a
   * reader's rows carry counts and a size it parsed for its own cut. */
  index: CatalogMetadataIndex;
  source: SessionCatalogSource;
  /** The folder watcher backend. Production watches the root recursively; a
   * test that must force a dropped event or a watcher failure supplies its own. */
  watchCatalog?: (request: SessionCatalogWatchRequest) => SessionCatalogWatchHandle;
  /** How soon an unwatchable root is retried, and the backstop cadence. */
  watchRetryMs?: number;
  reconcileIntervalMs?: number;
  /** One call per reconcile, for the catalog juncture's `catalog.reconciled`. */
  onReconciled?: (reconciled: SessionCatalogReconcileOutcome) => void;
  /** One row the folder watcher changed for one file, for `catalog.changed`. */
  onChanged?: (change: SessionCatalogChange) => void;
  /** The watcher stopped observing, so the index is re-derived from the folder's
   * own cut once a replacement is attached; for `catalog.watcher-reset`. */
  onWatcherReset?: (reset: SessionCatalogWatcherReset) => void;
  persistDebounceMs?: number;
  persistMaxWaitMs?: number;
  now?: () => number;
}

/** The fields one row is compared on. The catalog owner decides whether a
 * change was real, so it must compare the facts, not the object identity. */
function rowFactsEqual(left: CatalogMetadataIndexRow, right: CatalogMetadataIndexRow): boolean {
  return left.path === right.path && left.id === right.id && left.cwd === right.cwd
    && left.parentSessionPath === right.parentSessionPath
    && left.creationOrigin?.kind === right.creationOrigin?.kind
    && left.creationOrigin?.automationId === right.creationOrigin?.automationId
    && left.name === right.name && left.firstMessage === right.firstMessage
    && left.createdAt === right.createdAt && left.updatedAt === right.updatedAt
    && left.messageCount === right.messageCount && left.fileIdentity === right.fileIdentity
    && left.size === right.size && left.mtimeMs === right.mtimeMs
    && left.eofOffset === right.eofOffset && left.tailBoundaryHash === right.tailBoundaryHash;
}

interface RowDiff { added: number; removed: number; modified: number; }

/**
 * The catalog owner: one in-memory row per canonical session file, kept current
 * by the Gateway's own changes at their commit points and by the folder watcher
 * for external writers, with reconciliation against the canonical files as the
 * backstop for everything neither saw. Published values are always canonical
 * file facts; the live slot summary is a presentation overlay this index never
 * adopts.
 */
export class SessionCatalog {
  /** Keyed by canonical path: one row per canonical file, so two files that
   * claim one session ID are two rows and the ID is reported as duplicated. */
  private readonly rowsByPath = new Map<string, SessionCatalogRow>();
  private readonly pendingPaths = new Map<string, boolean>();
  private readonly persistDebounceMs: number;
  private readonly persistMaxWaitMs: number;
  private readonly now: () => number;
  /** One lane: every index change is applied in order, so a reconcile cannot
   * interleave with a Gateway-owned change it has already superseded. */
  private lane: Promise<void> = Promise.resolve();
  private refreshQueued = false;
  private persistTimer: NodeJS.Timeout | undefined;
  private persistWindowStartedAt: number | undefined;
  private persistRun: Promise<void> = Promise.resolve();
  /** The folder watcher, its per-path debounce timers and the cadences that keep
   * external writers visible without a walk. */
  private readonly watchCatalog: (request: SessionCatalogWatchRequest) => SessionCatalogWatchHandle;
  private readonly watchRetryMs: number;
  private readonly reconcileIntervalMs: number;
  private watcher: SessionCatalogWatchHandle | undefined;
  private watchedRoot: string | undefined;
  private readonly eventTimers = new Map<string, NodeJS.Timeout>();
  /** When each path's current quiet spell started, so a writer that never goes
   * quiet still reaches its row. */
  private readonly eventWindowStartedAt = new Map<string, number>();
  private unnamedEventTimer: NodeJS.Timeout | undefined;
  /** The unnamed event's ceiling window, so an unnameable event that never stops
   * arriving still reaches one whole-folder pass. */
  private unnamedEventWindowStartedAt: number | undefined;
  private watchRetryTimer: NodeJS.Timeout | undefined;
  private watchOutageClearTimer: NodeJS.Timeout | undefined;
  private reconcileTimer: NodeJS.Timeout | undefined;
  /** One record per outage rather than per retry: while the watcher is down,
   * every attempt fails for the same reason. Cleared once a replacement has
   * survived one retry interval, so an outage of its own gets its own record. */
  private watchOutageReported = false;
  /** The row paths come from the walk's realpath form, so the classification
   * compares them against the same form of the configured folder. */
  private canonicalRoot: string | undefined;
  /** Every canonical deletion announced, by row path. A pass that read a file
   * before its removal was announced compares its own read epoch against this
   * to refuse publishing the removed row back. */
  private readonly removalGenerations = new Map<string, number>();
  private removalGeneration = 0;
  /** The durable document is written only from a canonical cut (a completed
   * load or reconcile) that a change made stale. Anything else — a shutdown
   * before the load, a load that was interrupted, a partial scan — is not
   * membership, and writing it would erase rows the next startup would then
   * have to re-parse every transcript to rebuild. The same flag is the one
   * answer to whether the published rows are complete membership: a reader that
   * prunes against them and a recoverer that treats an absent row as a removed
   * session must both refuse an incomplete cut. */
  private canonicalCut = false;
  private readonly firstPublished: Promise<void>;
  private publishFirstCut: (() => void) | undefined;
  private changeGeneration = 0;
  private durableGeneration = 0;
  private closed = false;

  constructor(private readonly options: SessionCatalogOptions) {
    this.persistDebounceMs = options.persistDebounceMs ?? CATALOG_PERSIST_DEBOUNCE_MS;
    this.persistMaxWaitMs = options.persistMaxWaitMs ?? CATALOG_PERSIST_MAX_WAIT_MS;
    this.watchCatalog = options.watchCatalog ?? watchCatalogFolder;
    this.watchRetryMs = options.watchRetryMs ?? CATALOG_WATCH_RETRY_MS;
    this.reconcileIntervalMs = options.reconcileIntervalMs ?? CATALOG_RECONCILE_INTERVAL_MS;
    this.now = options.now ?? Date.now;
    this.firstPublished = new Promise((resolve) => { this.publishFirstCut = resolve; });
  }

  /** True while the published rows come from a complete cut: the durable
   * document this startup loaded, or a reconcile that saw the whole folder.
   * False before the first such cut and after an incomplete or failed pass that
   * has not been superseded, so a caller that would treat an absent row as a
   * removed session knows it cannot. */
  hasCompleteCut(): boolean {
    return this.canonicalCut;
  }

  /** The first complete cut, however it arrived: the durable rows a startup
   * loaded (a previous complete cut, already on disk), or the first reconcile
   * that saw the whole folder. A reader joins this instead of walking, so a
   * restart's first read serves the durable rows while the folder's own cut is
   * still being read. */
  whenPublished(): Promise<void> {
    return this.canonicalCut ? Promise.resolve() : this.firstPublished;
  }

  /** Every canonical session, ordered by canonical path. */
  rows(): readonly SessionCatalogRow[] {
    return [...this.rowsByPath.values()]
      .sort((left, right) => (left.path < right.path ? -1 : left.path > right.path ? 1 : 0));
  }

  row(path: string): SessionCatalogRow | undefined {
    return this.indexed(resolve(path));
  }

  /** Session IDs that more than one canonical file claims. A reader must not
   * resolve such an ID to either file; the registry quarantines it. */
  duplicateSessionIds(): ReadonlySet<string> {
    const counts = new Map<string, number>();
    for (const row of this.rowsByPath.values()) counts.set(row.id, (counts.get(row.id) ?? 0) + 1);
    return new Set([...counts].filter(([, count]) => count > 1).map(([id]) => id));
  }

  /** Startup: publish the durable rows, then reconcile once in the background.
   * A missing, corrupt or foreign durable document leaves the index empty and
   * the reconcile rebuilds every row from its canonical file. The folder
   * watcher and the periodic backstop start with it, so a file an external
   * writer changes reaches its row without any reader walking the catalog. */
  start(): void {
    this.enqueue(async () => {
      const rows = await this.options.index.load(this.options.catalogRoot()).catch(() => undefined);
      if (this.closed || !rows) return;
      const catalogRoot = await this.catalogRoot();
      this.publishRows(rows, catalogRoot);
      // The document and the rows agree, so this cut is durable as it stands.
      this.canonicalCut = true;
      this.publishFirstCut?.();
    });
    void this.reconcile();
    void this.ensureWatching();
    this.scheduleReconcileInterval();
  }

  /** Reconcile the whole index against one complete cut of the canonical
   * folder. Durable rows are reused where their file is provably unchanged,
   * which keeps a restart off the transcript bodies. */
  reconcile(): Promise<void> {
    if (this.closed) return this.lane;
    return this.enqueue(() => this.reconcileIndex());
  }

  /** The Gateway's own change committed to one canonical file (create, persist,
   * summary change, rename, rekey or fork). The row is re-derived from the file:
   * the appended tail when the durable offset still proves the prefix, the whole
   * file when it does not. */
  refresh(path: string | undefined): Promise<void> {
    return this.queueRefresh(path, false);
  }

  /** One path a folder event named: the same read, reported as the external
   * writer's change because no request or commit explains it. */
  private refreshFromWatcher(path: string): Promise<void> {
    return this.queueRefresh(path, true);
  }

  private queueRefresh(path: string | undefined, fromWatcher: boolean): Promise<void> {
    if (path === undefined || this.closed) return this.lane;
    const key = resolve(path);
    // A path both the Gateway and the watcher named is reported as the watcher's
    // change: the reader's question is whether a change happened outside a
    // request, and it did.
    this.pendingPaths.set(key, (this.pendingPaths.get(key) ?? false) || fromWatcher);
    if (this.refreshQueued) return this.lane;
    this.refreshQueued = true;
    return this.enqueue(async () => {
      // Cleared before the drain, so a change that lands while this pass reads
      // files queues one more pass instead of being dropped.
      this.refreshQueued = false;
      const pending = [...this.pendingPaths];
      this.pendingPaths.clear();
      // Each changed row marks itself: a pass that read only an unchanged file
      // owes no durable write.
      for (const [queued, fromWatcher] of pending) await this.refreshPath(queued, fromWatcher);
    });
  }

  /** A canonical file whose deletion the Gateway committed. Removal is announced
   * by its owner because an unreadable file proves neither absence nor presence.
   * The row is dropped synchronously: the commit has already removed the file,
   * and the list-changed event its caller fires right after this call must not
   * be able to publish a row the owner no longer admits. The removal is recorded
   * when it is announced: a reconcile or refresh pass that read the file before
   * this call must not publish the removed row when it finishes afterwards. The
   * record is cleared by the removal's own lane work: every pass that read before
   * it has finished by then, and a pass that starts later captures an epoch at or
   * above the removal, so the record cannot outlive its one use. */
  remove(path: string): void {
    if (this.closed) return;
    const key = resolve(path);
    this.removalGenerations.set(key, (this.removalGeneration += 1));
    if (this.rowsByPath.delete(key)) this.markChanged();
    void this.enqueue(async () => { this.removalGenerations.delete(key); });
  }

  /** Settle every queued change and durable write, without closing the owner.
   * A caller that wants the durable document current now clears the debounce. */
  async settled(): Promise<void> {
    while (true) {
      const lane = this.lane;
      await lane;
      if (this.persistTimer) {
        clearTimeout(this.persistTimer);
        this.persistTimer = undefined;
        this.persistWindowStartedAt = undefined;
        await this.persistNow();
      }
      const persist = this.persistRun;
      await persist;
      if (lane === this.lane && persist === this.persistRun && !this.persistTimer) return;
    }
  }

  async dispose(): Promise<void> {
    this.closed = true;
    this.stopWatching();
    if (this.persistTimer) {
      clearTimeout(this.persistTimer);
      this.persistTimer = undefined;
      this.persistWindowStartedAt = undefined;
    }
    await this.settled();
    await this.persistNow();
  }

  /** One event's path reached the watcher. It is a hint, so the row is
   * re-derived from the file the same way a Gateway-owned change is. A path the
   * platform named that is not a transcript is resolved against the folder
   * itself; an event the platform could not name proves only that something
   * under the folder changed, so the whole index is re-derived once per quiet
   * spell instead. */
  private watchEvent(filename: string | null): void {
    if (this.closed) return;
    const root = this.watchedRoot;
    if (root === undefined) return;
    if (filename === null) return this.debounceUnnamedEvent();
    const path = resolve(root, filename);
    if (ignoredCatalogPath(path, root)) return;
    if (path.endsWith(".jsonl")) return this.debounceEvent(path);
    void this.resolveFolderEvent(path, root);
  }

  /** The platform named a path that is not a transcript. FSEvents reports a
   * folder moved into the root as one event for the folder and none for the
   * transcripts inside it, and reports a folder renamed inside the root as one
   * event for each name, so the folder's own `.jsonl` files are re-read. A path
   * that is gone re-reads only the rows at or under it, which the absence rule
   * then drops. Anything else (a lock, a scratch file, the temporary name of an
   * atomic write) is not a row and costs nothing. */
  private async resolveFolderEvent(path: string, root: string): Promise<void> {
    const info = await lstat(path).catch(() => undefined);
    if (info === undefined) return this.resolveAbsentEvent(path, root);
    if (!info.isDirectory()) return;
    const transcripts = await this.transcriptsBeneath(path, root);
    if (transcripts === undefined) return this.debounceUnnamedEvent();
    for (const transcript of transcripts) this.debounceEvent(transcript);
  }

  /** The named path is not there. Only absence is evidence, and only of the rows
   * this owner published at or under the path: an atomic write's temporary name,
   * a scratch file and the Gateway's own quarantine rename name a path no row
   * was ever cut from, so they cost nothing rather than a whole-folder pass. */
  private async resolveAbsentEvent(path: string, root: string): Promise<void> {
    if (!(await pathMissing(path))) return;
    // The folder a path was named from is gone: no cut of it is membership
    // evidence, so the rows stay and the retry attaches to it when it exists
    // again.
    if (!(await lstat(root).then((stats) => stats.isDirectory(), () => false))) return this.rootVanished();
    // A recursive watcher names the folder itself through the root's own
    // basename, once when the watch attaches. With the folder there, that
    // names the folder and not a path inside it: its contents arrive as their
    // own events, and no cut of the whole folder is owed for it.
    if (path === join(root, basename(root))) return;
    for (const indexed of this.indexedBeneath(path)) this.debounceEvent(indexed);
  }

  /** The transcripts under one folder the platform named, or undefined when the
   * folder holds more than one event can name: the whole-folder pass is then the
   * bounded reader, and it applies discovery's own capacity limits. */
  private async transcriptsBeneath(directory: string, root: string): Promise<string[] | undefined> {
    // Discovery never reads an ignored folder, so an event that named one holds
    // no rows either.
    if (isIgnoredCatalogDirectory(directory, root)) return [];
    const transcripts: string[] = [];
    // Walked by hand rather than with `readdir({recursive: true})`: the ignored
    // folders discovery skips are never read, so a producer's artifacts do not
    // cost a directory read and cannot fill the cap first.
    let frontier = [directory];
    while (frontier.length > 0) {
      const nextFrontier: string[] = [];
      for (const candidate of frontier) {
        const entries = await readdir(candidate, { withFileTypes: true }).catch(() => undefined);
        if (entries === undefined) return undefined;
        for (const entry of entries) {
          const path = join(candidate, entry.name);
          if (entry.isDirectory()) {
            if (!isIgnoredCatalogDirectory(path, root)) nextFrontier.push(path);
            continue;
          }
          if (!entry.isFile() || !entry.name.endsWith(".jsonl")) continue;
          if (transcripts.length >= CATALOG_EVENT_DIRECTORY_LIMIT) return undefined;
          transcripts.push(path);
        }
      }
      frontier = nextFrontier;
    }
    return transcripts;
  }

  /** The indexed rows at or under one path: the rows its absence can reach. */
  private indexedBeneath(path: string): string[] {
    const key = resolve(path);
    const prefix = `${key}${sep}`;
    const indexed: string[] = [];
    for (const row of this.rowsByPath.keys()) {
      if (row === key || row.startsWith(prefix)) indexed.push(row);
    }
    return indexed;
  }

  /** An unnamed event proves only that something under the folder changed, so
   * the folder's own cut is re-derived once per quiet spell. */
  private debounceUnnamedEvent(): void {
    if (this.closed) return;
    if (this.unnamedEventTimer) clearTimeout(this.unnamedEventTimer);
    const now = this.now();
    const windowStartedAt = this.unnamedEventWindowStartedAt ?? now;
    this.unnamedEventWindowStartedAt = windowStartedAt;
    // Capped the way persistence and the per-path debounce are: an event the
    // platform keeps re-reporting without a quiet spell still reaches one pass a
    // second instead of being re-armed forever.
    const untilCeiling = CATALOG_EVENT_MAX_WAIT_MS - (now - windowStartedAt);
    const timer = setTimeout(() => {
      this.unnamedEventTimer = undefined;
      this.unnamedEventWindowStartedAt = undefined;
      void this.reconcile();
    }, Math.max(0, Math.min(CATALOG_EVENT_DEBOUNCE_MS, untilCeiling)));
    timer.unref();
    this.unnamedEventTimer = timer;
  }

  private debounceEvent(path: string): void {
    const armed = this.eventTimers.get(path);
    if (armed) clearTimeout(armed);
    const now = this.now();
    const windowStartedAt = this.eventWindowStartedAt.get(path) ?? now;
    this.eventWindowStartedAt.set(path, windowStartedAt);
    // Capped the way persistence is: a path written more often than the quiet
    // spell is still re-read once the ceiling is reached.
    const untilCeiling = CATALOG_EVENT_MAX_WAIT_MS - (now - windowStartedAt);
    const timer = setTimeout(() => {
      this.eventTimers.delete(path);
      this.eventWindowStartedAt.delete(path);
      void this.refreshFromWatcher(path);
    }, Math.max(0, Math.min(CATALOG_EVENT_DEBOUNCE_MS, untilCeiling)));
    timer.unref();
    this.eventTimers.set(path, timer);
  }

  /** Keep one live watcher on the canonical folder. False means the index is the
   * only feed until a retry or the periodic reconciliation repairs it. */
  private async ensureWatching(): Promise<boolean> {
    if (this.closed) return false;
    if (this.watcher) return true;
    const root = await this.catalogRoot();
    if (this.closed) return false;
    // Resolving the root released the caller: a concurrent attempt (the retry
    // timer, an interval tick) may have attached a watcher meanwhile, and two
    // watchers would double every event.
    if (this.watcher) return true;
    let handle: SessionCatalogWatchHandle;
    const registration: { watcher?: SessionCatalogWatchHandle } = {};
    try {
      // The root is resolved once here: event names are relative to the folder
      // the watcher was given, and rows are keyed by the same canonical form.
      handle = this.watchCatalog({
        root,
        onEvent: (filename) => this.watchEvent(filename),
        // Tied to this handle: a reset from a watcher this owner already
        // replaced must not stop the replacement.
        onReset: (reason) => this.watcherStopped(registration.watcher, reason),
      });
    } catch {
      // A missing or unreadable root: the index keeps serving what it has, and
      // the retry watches it as soon as it exists.
      this.reportWatcherOutage("unavailable");
      this.scheduleWatchRetry();
      return false;
    }
    registration.watcher = handle;
    this.watcher = handle;
    this.watchedRoot = root;
    if (this.watchRetryTimer) {
      clearTimeout(this.watchRetryTimer);
      this.watchRetryTimer = undefined;
    }
    // No event reached this owner between the stop and this attach, so the
    // folder's own cut is re-read once to repair that gap (the reconcile at the
    // stop ran before the replacement could attach).
    if (this.watchOutageReported) void this.reconcile();
    this.scheduleOutageClear(handle);
    return true;
  }

  /** A watcher that was observing stopped, so every event from here on is
   * missing: it is replaced and the folder's own cut is re-read. */
  private watcherStopped(handle: SessionCatalogWatchHandle | undefined, reason: SessionCatalogWatcherResetReason): void {
    // A reset from a watcher this owner already stopped or replaced is not the
    // current observation: its successor is the one observing now.
    if (handle !== this.watcher) return handle?.close();
    this.stopObserving(handle, reason, true);
  }

  /** The root's own path event and the root is gone: the watcher watches a
   * folder that is no longer there. The published rows stay as they are — an
   * absent root proves no removal — and the retry attaches to the folder when it
   * exists again, whose reconcile republishes the folder's own cut. */
  private rootVanished(): void {
    this.stopObserving(this.watcher, "unavailable", false);
  }

  private stopObserving(
    handle: SessionCatalogWatchHandle | undefined,
    reason: SessionCatalogWatcherResetReason,
    reconcile: boolean,
  ): void {
    if (this.closed) return;
    this.watcher = undefined;
    this.watchedRoot = undefined;
    handle?.close();
    // One reconcile per outage: the first stop reads the folder's own cut, and
    // the one that follows the next attach repairs everything the gap missed.
    const firstStop = !this.watchOutageReported;
    this.reportWatcherOutage(reason);
    // A watcher that dies right after every attach must not restart in a loop:
    // the replacement waits one retry interval, like a root that is not there.
    this.scheduleWatchRetry();
    if (reconcile && firstStop) void this.reconcile();
  }

  private reportWatcherOutage(reason: SessionCatalogWatcherResetReason): void {
    if (this.watchOutageReported) return;
    this.watchOutageReported = true;
    this.options.onWatcherReset?.({ reason });
  }

  /** A watcher that survived one retry interval is observing: only then is the
   * outage over, so the next failure is a new outage with its own record. */
  private scheduleOutageClear(handle: SessionCatalogWatchHandle): void {
    if (this.watchOutageClearTimer) clearTimeout(this.watchOutageClearTimer);
    this.watchOutageClearTimer = setTimeout(() => {
      this.watchOutageClearTimer = undefined;
      if (this.watcher === handle) this.watchOutageReported = false;
    }, this.watchRetryMs);
    this.watchOutageClearTimer.unref();
  }

  private scheduleWatchRetry(): void {
    if (this.closed || this.watchRetryTimer) return;
    this.watchRetryTimer = setTimeout(() => {
      this.watchRetryTimer = undefined;
      void this.ensureWatching();
    }, this.watchRetryMs);
    this.watchRetryTimer.unref();
  }

  private scheduleReconcileInterval(): void {
    if (this.closed || this.reconcileIntervalMs <= 0) return;
    this.reconcileTimer = setInterval(() => {
      // The retry is belt and braces beside `scheduleWatchRetry`: the pass is
      // the one place that always runs, so an unwatched root cannot stay
      // unwatched for the life of the process.
      void this.ensureWatching();
      void this.reconcile();
    }, this.reconcileIntervalMs);
    this.reconcileTimer.unref();
  }

  private stopWatching(): void {
    this.watcher?.close();
    this.watcher = undefined;
    this.watchedRoot = undefined;
    for (const timer of this.eventTimers.values()) clearTimeout(timer);
    this.eventTimers.clear();
    this.eventWindowStartedAt.clear();
    if (this.unnamedEventTimer) {
      clearTimeout(this.unnamedEventTimer);
      this.unnamedEventTimer = undefined;
    }
    this.unnamedEventWindowStartedAt = undefined;
    if (this.watchRetryTimer) {
      clearTimeout(this.watchRetryTimer);
      this.watchRetryTimer = undefined;
    }
    if (this.watchOutageClearTimer) {
      clearTimeout(this.watchOutageClearTimer);
      this.watchOutageClearTimer = undefined;
    }
    if (this.reconcileTimer) {
      clearInterval(this.reconcileTimer);
      this.reconcileTimer = undefined;
    }
  }

  private async reconcileIndex(): Promise<void> {
    if (this.closed) return;
    const startedAt = this.now();
    // This pass's read epoch, captured before its first read. Every later
    // announcement of a removal is compared against it; a marker left by an
    // earlier removal cannot gate this pass, because the lane is serial and its
    // own work has already consumed it.
    const removalFloor = this.removalGeneration;
    const report = (outcome: SessionCatalogReconcileOutcome["outcome"], files: number, diff?: RowDiff, unproven = 0): void => {
      this.options.onReconciled?.({
        outcome,
        files,
        added: diff?.added ?? 0,
        removed: diff?.removed ?? 0,
        modified: diff?.modified ?? 0,
        unproven,
        durationMs: this.now() - startedAt,
      });
    };
    let scan: SessionCatalogScan;
    try {
      scan = await this.options.source.scan();
    } catch {
      report("failed", 0);
      return;
    }
    const files = scan.candidates.length;
    // A cut of a folder that is not there is not membership evidence either: a
    // root that is missing or unreadable leaves every published row alone, the
    // way an unreadable candidate does. An empty catalog folder that *is* there
    // is a real empty cut and publishes nothing.
    if (!(await this.catalogRootIsDirectory())) {
      report("incomplete", files);
      return;
    }
    if (!scan.complete) {
      // An incomplete cut is never membership evidence: the published rows stay
      // as they are rather than shrinking to what this pass happened to see.
      report("incomplete", files);
      return;
    }
    const reconciled = await this.reconcileRows(scan);
    if (this.closed) return;
    const diff = this.publishRows(reconciled.rows, await this.catalogRoot(), removalFloor);
    if (this.closed) return;
    this.canonicalCut = true;
    this.publishFirstCut?.();
    if (diff.added + diff.removed + diff.modified > 0) this.markChanged();
    report("reconciled", files, diff, reconciled.unproven);
  }

  /** One complete cut, resolved per file: durable rows are reused where their
   * file verifies, and a file this pass cannot prove keeps the row the index
   * already published instead of shrinking the catalog to what it could read. */
  private async reconcileRows(
    scan: SessionCatalogScan,
  ): Promise<{ rows: CatalogMetadataIndexRow[]; unproven: number }> {
    const reconciled = await this.options.index.reconcile(
      this.options.catalogRoot(),
      scan.candidates,
      (candidate) => this.options.source.summaryFor(candidate.path),
      // The index's own `closed` flag is set only after this owner has finished
      // disposing, so shutdown has to tell the pass where to stop.
      () => this.closed,
    );
    if (!reconciled) return this.rebuild(scan);
    const rows: CatalogMetadataIndexRow[] = [...reconciled.rows];
    for (const unproven of reconciled.unproven) {
      const retained = this.rowsByPath.get(resolve(unproven));
      if (retained) rows.push(retained);
    }
    return { rows, unproven: reconciled.unproven.length };
  }

  private async refreshPath(canonicalPath: string, fromWatcher: boolean): Promise<boolean> {
    const removalFloor = this.removalGeneration;
    const startedAt = this.now();
    // Rows are keyed by the walk's realpath form, and a caller may name the same
    // file through a symlinked root (macOS `/var`), so the fallback resolves it
    // once per miss rather than rebuilding the row from the body every time.
    const existing = this.indexed(canonicalPath)
      ?? this.rowsByPath.get(await realpath(canonicalPath).catch(() => canonicalPath));
    // An exact path that is gone is removal evidence for the row it published:
    // the Gateway deletes the files it rolls back (a failed import, an
    // uncommitted fork artifact) without announcing a removal, and an external
    // writer deletes a session the same way. Reading such a path would only
    // report a failure for a file that is provably not canonical any more.
    if (await pathMissing(canonicalPath)) {
      // Absence is removal evidence only while the folder it was named from is
      // there: a root that has been moved away takes every path inside it with
      // it, and that is an outage to repair, not a deletion to publish.
      if (!existing || !(await this.catalogRootIsDirectory())) return false;
      if (!this.rowsByPath.delete(resolve(existing.path))) return false;
      this.markChanged();
      if (fromWatcher) this.reportChanged(existing, "removed", startedAt);
      return true;
    }
    if (existing) {
      // A Pi append can land between the index's stat and its tail read. The
      // appended tail is all that changed, so the tail is re-read instead of
      // re-parsing the whole transcript for a race that does not disprove the
      // counted prefix.
      for (let attempt = 0; attempt < APPEND_ATTEMPTS; attempt += 1) {
        const advanced = await this.options.index.append(existing);
        if (advanced) {
          const row = this.classify(advanced, await this.catalogRoot());
          if (!this.publishRow(row, removalFloor)) return false;
          if (fromWatcher) this.reportChanged(row, "appended", startedAt);
          return true;
        }
      }
    }
    const summary = await this.options.source.summaryFor(canonicalPath);
    if (!summary) return false;
    const rebuilt = await this.options.index.entryFromSummary(summary);
    if (!rebuilt) return false;
    const row = this.classify(rebuilt, await this.catalogRoot());
    if (!this.publishRow(row, removalFloor)) return false;
    if (fromWatcher) this.reportChanged(row, "rebuilt", startedAt);
    return true;
  }

  /** One row the watcher changed for one file, at the one place a row the Gateway
   * did not change is published. An unchanged row is not a change. */
  private reportChanged(row: SessionCatalogRow, outcome: SessionCatalogChange["outcome"], startedAt: number): void {
    this.options.onChanged?.({ sessionId: row.id, outcome, durationMs: Math.max(0, this.now() - startedAt) });
  }

  /** Every candidate whose durable row is unusable, rebuilt from its file. A
   * candidate that cannot be read keeps the row the index already published: an
   * unprovable file proves neither presence nor absence. */
  private async rebuild(
    scan: SessionCatalogScan,
  ): Promise<{ rows: CatalogMetadataIndexRow[]; unproven: number }> {
    const rows: CatalogMetadataIndexRow[] = [];
    let unproven = 0;
    for (const candidate of scan.candidates) {
      // Shutdown must not wait behind one startup parse per file: the pass stops
      // between files and publishes nothing it could not finish.
      if (this.closed) return { rows: [], unproven: scan.candidates.length };
      const summary = await this.options.source.summaryFor(candidate.path);
      const row = summary ? await this.options.index.entryFromSummary(summary) : undefined;
      if (!row || row.id !== candidate.id || row.cwd !== candidate.cwd) {
        unproven += 1;
        const retained = this.rowsByPath.get(resolve(candidate.path));
        if (retained) rows.push(retained);
        continue;
      }
      rows.push(row);
    }
    return { rows, unproven };
  }

  private async catalogRoot(): Promise<string> {
    if (this.canonicalRoot) return this.canonicalRoot;
    // A root that does not exist yet (a fresh install) is not cached in its
    // unresolved form: once it is created, the realpath form must win, or rows
    // and the configured folder classify differently.
    const resolved = await realpath(this.options.catalogRoot()).catch(() => undefined);
    if (resolved) this.canonicalRoot = resolved;
    return resolved ?? resolve(this.options.catalogRoot());
  }

  /** The folder every row belongs to is there to be read. A root that is missing
   * or unreadable is an outage: neither a cut of it nor an absent path inside it
   * is membership evidence. */
  private async catalogRootIsDirectory(): Promise<boolean> {
    return lstat(await this.catalogRoot()).then((stats) => stats.isDirectory(), () => false);
  }

  private classify(row: CatalogMetadataIndexRow, catalogRoot: string): SessionCatalogRow {
    return { ...row, delegated: delegatedSessionParentPath(row.path, catalogRoot) !== undefined };
  }

  /** A reconcile replaces the whole set, because its cut is the exact
   * membership evidence: a row the cut omits is a removed canonical file. A row
   * whose removal was announced after this pass began reading is left out
   * instead of being published back. The returned diff is what actually
   * changed, so a pass that saw only status flips writes nothing. */
  private publishRows(
    rows: readonly CatalogMetadataIndexRow[],
    catalogRoot: string,
    removalFloor = Number.MAX_SAFE_INTEGER,
  ): RowDiff {
    const next = new Map<string, SessionCatalogRow>();
    for (const row of rows) {
      const path = resolve(row.path);
      if ((this.removalGenerations.get(path) ?? 0) > removalFloor) continue;
      next.set(path, this.classify(row, catalogRoot));
    }
    const diff: RowDiff = { added: 0, removed: 0, modified: 0 };
    for (const [path, row] of next) {
      const previous = this.rowsByPath.get(path);
      if (!previous) diff.added += 1;
      else if (!rowFactsEqual(previous, row)) diff.modified += 1;
    }
    for (const path of this.rowsByPath.keys()) if (!next.has(path)) diff.removed += 1;
    this.rowsByPath.clear();
    for (const [path, row] of next) this.rowsByPath.set(path, row);
    return diff;
  }

  /** A single-row change. False means the published row's facts did not change,
   * so nothing is dirty and no durable write is owed. */
  private publishRow(row: SessionCatalogRow, removalFloor: number): boolean {
    const path = resolve(row.path);
    if ((this.removalGenerations.get(path) ?? 0) > removalFloor) return false;
    const previous = this.rowsByPath.get(path);
    if (previous && rowFactsEqual(previous, row)) return false;
    this.rowsByPath.set(path, row);
    this.markChanged();
    return true;
  }

  /** Rows are keyed by the walk's realpath form. A caller may hold the same file
   * as an equivalent but differently spelled path (a symlinked temp root), so a
   * miss falls back to the exact file the row names. */
  private indexed(canonicalPath: string): SessionCatalogRow | undefined {
    const direct = this.rowsByPath.get(canonicalPath);
    if (direct) return direct;
    return [...this.rowsByPath.values()].find((row) => resolve(row.path) === canonicalPath);
  }

  /** One change is owed a write. The write waits for a quiet spell, capped so a
   * catalog that never goes quiet still reaches the document. */
  private markChanged(): void {
    this.changeGeneration += 1;
    this.schedulePersist();
  }

  private schedulePersist(): void {
    if (this.closed) return;
    const now = this.now();
    this.persistWindowStartedAt ??= now;
    const untilCeiling = this.persistMaxWaitMs - (now - this.persistWindowStartedAt);
    if (this.persistTimer) clearTimeout(this.persistTimer);
    this.persistTimer = setTimeout(() => {
      this.persistTimer = undefined;
      this.persistWindowStartedAt = undefined;
      void this.persistNow();
    }, Math.max(0, Math.min(this.persistDebounceMs, untilCeiling)));
    this.persistTimer.unref();
  }

  /** The durable form never carries the derived classification. A row set that
   * no completed load or reconcile produced is not written at all: it would
   * replace a good document with a partial or empty one. */
  private persistNow(): Promise<void> {
    if (!this.canonicalCut || this.changeGeneration === this.durableGeneration) return this.persistRun;
    const generation = this.changeGeneration;
    const catalogRoot = this.options.catalogRoot();
    const rows: CatalogMetadataIndexRow[] = [...this.rowsByPath.values()]
      .map(({ delegated: _delegated, ...row }) => row);
    const write = this.options.index.save(catalogRoot, rows)
      .then(() => {
        // A change that landed during the write is still owed its own write.
        this.durableGeneration = Math.max(this.durableGeneration, generation);
      })
      .catch(() => {});
    this.persistRun = write;
    return write;
  }

  /** Every change runs in one lane; a failing change never stops the lane. */
  private enqueue(work: () => Promise<void>): Promise<void> {
    const next = this.lane.then(work, work);
    this.lane = next.catch(() => {});
    return this.lane;
  }
}
