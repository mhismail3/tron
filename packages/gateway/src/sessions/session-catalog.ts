import { watch } from "node:fs";
import { realpath } from "node:fs/promises";
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
 * once per quiet spell instead of once per event. */
export const CATALOG_EVENT_DEBOUNCE_MS = 250;

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
 * that was observing and stopped; `unavailable` is a start attempt that got no
 * watcher (a missing or unreadable root). A platform overflow is not reported
 * separately — `fs.watch` does not surface it — so dropped events are the
 * periodic reconciliation's job rather than this path's. */
export type SessionCatalogWatcherResetReason = "error" | "unavailable";

/** One row the owner changed for a single file, for `catalog.changed`. */
export interface SessionCatalogChange {
  sessionId: string;
  /** `appended` advanced the durable tail; `rebuilt` re-derived the whole row
   * because the file's identity, size or tail no longer matched it. */
  outcome: "appended" | "rebuilt";
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
  /** One row this owner changed for one file, for `catalog.changed`. */
  onChanged?: (change: SessionCatalogChange) => void;
  /** The watcher stopped observing, so the index is re-derived from the folder's
   * own cut; for `catalog.watcher-reset`. */
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
  private readonly pendingPaths = new Set<string>();
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
  private unnamedEventTimer: NodeJS.Timeout | undefined;
  private watchRetryTimer: NodeJS.Timeout | undefined;
  private reconcileTimer: NodeJS.Timeout | undefined;
  /** One record per outage rather than per retry: while the watcher is down,
   * every attempt fails for the same reason. */
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
   * have to re-parse every transcript to rebuild. */
  private canonicalCut = false;
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
    if (path === undefined || this.closed) return this.lane;
    this.pendingPaths.add(resolve(path));
    if (this.refreshQueued) return this.lane;
    this.refreshQueued = true;
    return this.enqueue(async () => {
      // Cleared before the drain, so a change that lands while this pass reads
      // files queues one more pass instead of being dropped.
      this.refreshQueued = false;
      const paths = [...this.pendingPaths];
      this.pendingPaths.clear();
      // Each changed row marks itself: a pass that read only an unchanged file
      // owes no durable write.
      for (const pending of paths) await this.refreshPath(pending);
    });
  }

  /** A canonical file whose deletion the Gateway committed. Removal is announced
   * by its owner because an unreadable file proves neither absence nor presence.
   * The row is dropped in the lane, but the removal is recorded when it is
   * announced: a reconcile or refresh pass that read the file before this call
   * must not publish the removed row when it finishes afterwards. The record is
   * cleared by the removal's own lane work: every pass that read before it has
   * finished by then, and a pass that starts later captures an epoch at or above
   * the removal, so the record cannot outlive its one use. */
  remove(path: string): void {
    if (this.closed) return;
    const key = resolve(path);
    this.removalGenerations.set(key, (this.removalGeneration += 1));
    void this.enqueue(async () => {
      this.removalGenerations.delete(key);
      if (!this.rowsByPath.delete(key)) return;
      this.markChanged();
    });
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
   * re-derived from the file the same way a Gateway-owned change is; an event
   * the platform could not name proves only that something under the folder
   * changed, so the whole index is re-derived once per quiet spell instead. */
  private watchEvent(filename: string | null): void {
    if (this.closed) return;
    const root = this.watchedRoot;
    if (root === undefined) return;
    if (filename === null) return this.debounceUnnamedEvent();
    const path = resolve(root, filename);
    if (!path.endsWith(".jsonl") || ignoredCatalogPath(path, root)) return;
    this.debounceEvent(path);
  }

  /** An unnamed event proves only that something under the folder changed, so
   * the folder's own cut is re-derived once per quiet spell. */
  private debounceUnnamedEvent(): void {
    if (this.unnamedEventTimer) clearTimeout(this.unnamedEventTimer);
    this.unnamedEventTimer = setTimeout(() => {
      this.unnamedEventTimer = undefined;
      void this.reconcile();
    }, CATALOG_EVENT_DEBOUNCE_MS);
    this.unnamedEventTimer.unref();
  }

  private debounceEvent(path: string): void {
    const armed = this.eventTimers.get(path);
    if (armed) clearTimeout(armed);
    const timer = setTimeout(() => {
      this.eventTimers.delete(path);
      void this.refresh(path);
    }, CATALOG_EVENT_DEBOUNCE_MS);
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
    try {
      // The root is resolved once here: event names are relative to the folder
      // the watcher was given, and rows are keyed by the same canonical form.
      this.watcher = this.watchCatalog({
        root,
        onEvent: (filename) => this.watchEvent(filename),
        onReset: (reason) => this.watcherStopped(reason),
      });
      this.watchedRoot = root;
      this.watchOutageReported = false;
      if (this.watchRetryTimer) {
        clearTimeout(this.watchRetryTimer);
        this.watchRetryTimer = undefined;
      }
      return true;
    } catch {
      // A missing or unreadable root: the index keeps serving what it has, and
      // the retry watches it as soon as it exists.
      this.reportWatcherOutage("unavailable");
      this.scheduleWatchRetry();
      return false;
    }
  }

  /** A watcher that was observing stopped, so every event from here on is
   * missing: it is replaced and the folder's own cut is re-read. */
  private watcherStopped(reason: SessionCatalogWatcherResetReason): void {
    if (this.closed) return;
    const watcher = this.watcher;
    this.watcher = undefined;
    watcher?.close();
    this.reportWatcherOutage(reason);
    void this.ensureWatching();
    void this.reconcile();
  }

  private reportWatcherOutage(reason: SessionCatalogWatcherResetReason): void {
    if (this.watchOutageReported) return;
    this.watchOutageReported = true;
    this.options.onWatcherReset?.({ reason });
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
    if (this.unnamedEventTimer) {
      clearTimeout(this.unnamedEventTimer);
      this.unnamedEventTimer = undefined;
    }
    if (this.watchRetryTimer) {
      clearTimeout(this.watchRetryTimer);
      this.watchRetryTimer = undefined;
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

  private async refreshPath(canonicalPath: string): Promise<boolean> {
    const removalFloor = this.removalGeneration;
    const startedAt = this.now();
    // Rows are keyed by the walk's realpath form, and a caller may name the same
    // file through a symlinked root (macOS `/var`), so the fallback resolves it
    // once per miss rather than rebuilding the row from the body every time.
    const existing = this.indexed(canonicalPath)
      ?? this.rowsByPath.get(await realpath(canonicalPath).catch(() => canonicalPath));
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
          this.reportChanged(row, "appended", startedAt);
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
    this.reportChanged(row, "rebuilt", startedAt);
    return true;
  }

  /** One row changed for one file, at the one place a single-row change is
   * published: a Gateway-owned write and an external writer's append are the
   * same event to a reader. An unchanged row is not a change. */
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
