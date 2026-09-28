import { realpath } from "node:fs/promises";
import { basename, dirname, isAbsolute, relative, resolve, sep } from "node:path";
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
  /** One call per reconcile, for the catalog juncture's `catalog.reconciled`. */
  onReconciled?: (reconciled: SessionCatalogReconcileOutcome) => void;
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
 * by the Gateway's own changes and, as its backstop, by reconciliation against
 * the canonical files. Published values are always canonical file facts; the
 * live slot summary is a presentation overlay this index never adopts.
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
   * the reconcile rebuilds every row from its canonical file. */
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
    if (this.persistTimer) {
      clearTimeout(this.persistTimer);
      this.persistTimer = undefined;
      this.persistWindowStartedAt = undefined;
    }
    await this.settled();
    await this.persistNow();
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
          return this.publishRow(this.classify(advanced, await this.catalogRoot()), removalFloor);
        }
      }
    }
    const summary = await this.options.source.summaryFor(canonicalPath);
    if (!summary) return false;
    const rebuilt = await this.options.index.entryFromSummary(summary);
    if (!rebuilt) return false;
    return this.publishRow(this.classify(rebuilt, await this.catalogRoot()), removalFloor);
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
