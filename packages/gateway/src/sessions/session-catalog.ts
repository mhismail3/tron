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
 * quiet spell; a burst of Gateway-owned changes costs one write. */
export const CATALOG_PERSIST_DEBOUNCE_MS = 5_000;

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
  /** The durable form. One document has one writer: the Gateway's registry. */
  index: CatalogMetadataIndex;
  source: SessionCatalogSource;
  /** One call per reconcile, for the catalog juncture's `catalog.reconciled`. */
  onReconciled?: (reconciled: { files: number; changed: number; durationMs: number }) => void;
  persistDebounceMs?: number;
  now?: () => number;
}

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
  private readonly now: () => number;
  /** One lane: every index change is applied in order, so a reconcile cannot
   * interleave with a Gateway-owned change it has already superseded. */
  private lane: Promise<void> = Promise.resolve();
  private refreshQueued = false;
  private persistTimer: NodeJS.Timeout | undefined;
  private persistRun: Promise<void> = Promise.resolve();
  /** The row paths come from the walk's realpath form, so the classification
   * compares them against the same form of the configured folder. */
  private canonicalRoot: string | undefined;
  private closed = false;

  constructor(private readonly options: SessionCatalogOptions) {
    this.persistDebounceMs = options.persistDebounceMs ?? CATALOG_PERSIST_DEBOUNCE_MS;
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
      this.publishRows(rows.map((row) => this.classify(row, catalogRoot)));
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
      let produced = false;
      for (const pending of paths) produced = (await this.refreshPath(pending)) || produced;
      if (produced) this.schedulePersist();
    });
  }

  /** A canonical file whose deletion the Gateway committed. Removal is announced
   * by its owner because an unreadable file proves neither absence nor presence. */
  remove(path: string): void {
    if (this.closed) return;
    const canonical = resolve(path);
    const indexed = this.indexed(canonical);
    if (!indexed || !this.rowsByPath.delete(resolve(indexed.path))) return;
    this.schedulePersist();
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
    }
    await this.settled();
    await this.persistNow();
  }

  private async reconcileIndex(): Promise<void> {
    if (this.closed) return;
    const startedAt = this.now();
    const scan = await this.options.source.scan();
    if (!scan.complete) return;
    const reused = await this.options.index.reconcile(
      this.options.catalogRoot(),
      scan.candidates,
      (candidate) => this.options.source.summaryFor(candidate.path),
    );
    const rows = reused ?? await this.rebuild(scan);
    const catalogRoot = await this.catalogRoot();
    this.publishRows(rows.map((row) => this.classify(row, catalogRoot)));
    this.schedulePersist();
    this.options.onReconciled?.({
      files: this.rowsByPath.size,
      changed: rows.length,
      durationMs: this.now() - startedAt,
    });
  }

  private async refreshPath(canonicalPath: string): Promise<boolean> {
    // Rows are keyed by the walk's realpath form, and a caller may name the same
    // file through a symlinked root (macOS `/var`), so the fallback resolves it
    // once per miss rather than rebuilding the row from the body every time.
    const existing = this.indexed(canonicalPath)
      ?? this.rowsByPath.get(await realpath(canonicalPath).catch(() => canonicalPath));
    if (existing) {
      const advanced = await this.options.index.append(existing);
      if (advanced) {
        this.publishRow(this.classify(advanced, await this.catalogRoot()));
        return true;
      }
    }
    const summary = await this.options.source.summaryFor(canonicalPath);
    if (!summary) return false;
    const rebuilt = await this.options.index.entryFromSummary(summary);
    if (!rebuilt) return false;
    this.publishRow(this.classify(rebuilt, await this.catalogRoot()));
    return true;
  }

  /** Every candidate whose durable row is unusable, rebuilt from its file. A
   * candidate that cannot be read is left out of the cut it cannot prove. */
  private async rebuild(scan: SessionCatalogScan): Promise<CatalogMetadataIndexRow[]> {
    const rows: CatalogMetadataIndexRow[] = [];
    for (const candidate of scan.candidates) {
      const summary = await this.options.source.summaryFor(candidate.path);
      if (!summary) continue;
      const row = await this.options.index.entryFromSummary(summary);
      if (row && row.id === candidate.id && row.cwd === candidate.cwd) rows.push(row);
    }
    return rows;
  }

  private async catalogRoot(): Promise<string> {
    this.canonicalRoot ??= await realpath(this.options.catalogRoot())
      .catch(() => resolve(this.options.catalogRoot()));
    return this.canonicalRoot;
  }

  private classify(row: CatalogMetadataIndexRow, catalogRoot: string): SessionCatalogRow {
    return { ...row, delegated: delegatedSessionParentPath(row.path, catalogRoot) !== undefined };
  }

  /** A reconcile replaces the whole set, because its cut is the exact
   * membership evidence: a row the cut omits is a removed canonical file. */
  private publishRows(rows: readonly SessionCatalogRow[]): void {
    const next = new Map<string, SessionCatalogRow>();
    for (const row of rows) next.set(resolve(row.path), row);
    this.rowsByPath.clear();
    for (const [path, row] of next) this.rowsByPath.set(path, row);
  }

  private publishRow(row: SessionCatalogRow): void {
    this.rowsByPath.set(resolve(row.path), row);
  }

  /** Rows are keyed by the walk's realpath form. A caller may hold the same file
   * as an equivalent but differently spelled path (a symlinked temp root), so a
   * miss falls back to the exact file the row names. */
  private indexed(canonicalPath: string): SessionCatalogRow | undefined {
    const direct = this.rowsByPath.get(canonicalPath);
    if (direct) return direct;
    return [...this.rowsByPath.values()].find((row) => resolve(row.path) === canonicalPath);
  }

  private schedulePersist(): void {
    if (this.closed || this.persistTimer) return;
    this.persistTimer = setTimeout(() => {
      this.persistTimer = undefined;
      void this.persistNow();
    }, this.persistDebounceMs);
    this.persistTimer.unref();
  }

  /** The durable form never carries the derived classification. */
  private persistNow(): Promise<void> {
    const catalogRoot = this.options.catalogRoot();
    const rows: CatalogMetadataIndexRow[] = [...this.rowsByPath.values()]
      .map(({ delegated: _delegated, ...row }) => row);
    const write = this.options.index.save(catalogRoot, rows).then(() => {}).catch(() => {});
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
