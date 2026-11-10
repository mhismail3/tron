import { watch } from "node:fs";
import { lstat, readdir, realpath } from "node:fs/promises";
import { basename, dirname, isAbsolute, join, relative, resolve, sep } from "node:path";
import { backgroundWork, type BackgroundWorkRegistration } from "../background-work.js";
import { isIgnoredCatalogDirectory } from "./catalog-discovery.js";
import { offLoop } from "../util/request-span.js";
import type {
  CatalogMetadataIndex,
  CatalogMetadataIndexRow,
  CatalogMetadataIndexSummary,
} from "./catalog-metadata-index.js";

export const SUBAGENT_RUN_DIRECTORY = /^run-\d+$/u;

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

const CATALOG_PERSIST_DEBOUNCE_MS = 5_000;
const CATALOG_PERSIST_MAX_WAIT_MS = 60_000;

export const CATALOG_EVENT_DEBOUNCE_MS = 250;
const CATALOG_EVENT_MAX_WAIT_MS = 1_000;

const CATALOG_EVENT_DIRECTORY_LIMIT = 64;

const CATALOG_EVENT_PENDING_PATH_LIMIT = 256;

const CATALOG_RECONCILE_INTERVAL_MS = 30 * 60_000;

const CATALOG_INCOMPLETE_RETRY_MS = 2_000;
const CATALOG_INCOMPLETE_RETRY_ATTEMPTS = 3;

const CATALOG_WATCH_RETRY_MS = 5_000;

const APPEND_ATTEMPTS = 2;

export interface SessionCatalogReconcileOutcome {
  outcome: "reconciled" | "incomplete" | "failed";
  files: number;
  added: number;
  removed: number;
  modified: number;
  unproven: number;
  durationMs: number;
  trigger?: "watcher-overflow";
}

interface SessionCatalogRow extends CatalogMetadataIndexRow {
  delegated: boolean;
}

interface SessionCatalogCandidate {
  path: string;
  id: string;
  cwd: string;
  fileIdentity: string;
  size: number;
  mtimeMs: number;
}

export interface SessionCatalogIdentity {
  fileIdentity: string;
  size: number;
  mtimeMs: number;
}

export interface SessionCatalogScan {
  catalogRoot: string;
  complete: boolean;
  candidates: readonly SessionCatalogCandidate[];
  unproven?: readonly string[];
}

type SessionCatalogWatcherResetReason = "error" | "unavailable";

export interface SessionCatalogChange {
  sessionId: string;
  outcome: "appended" | "rebuilt" | "removed";
  durationMs: number;
}

export interface SessionCatalogWatcherReset {
  reason: SessionCatalogWatcherResetReason;
}

export interface SessionCatalogWatchRequest {
  root: string;
  onEvent(filename: string | null): void;
  onReset(reason: SessionCatalogWatcherResetReason): void;
}

interface SessionCatalogWatchHandle {
  close(): void;
}

function watchCatalogFolder(request: SessionCatalogWatchRequest): SessionCatalogWatchHandle {
  const watcher = watch(request.root, { recursive: true, persistent: false }, (_event, filename) => {
    request.onEvent(typeof filename === "string" ? filename : null);
  });
  watcher.on("error", () => request.onReset("error"));
  return { close: () => watcher.close() };
}

function ignoredCatalogPath(path: string, canonicalRoot: string): boolean {
  for (let directory = dirname(path);; directory = dirname(directory)) {
    if (isIgnoredCatalogDirectory(directory, canonicalRoot)) return true;
    if (directory === canonicalRoot || dirname(directory) === directory) return false;
  }
}

async function pathMissing(path: string): Promise<boolean> {
  return lstat(path).then(() => false, (error: NodeJS.ErrnoException) => error.code === "ENOENT");
}

export interface SessionCatalogSource {
  scan(): Promise<SessionCatalogScan>;
  summaryFor(path: string, yieldToLoop?: () => Promise<void>): Promise<CatalogMetadataIndexSummary | undefined>;
}

export interface SessionCatalogOptions {
  catalogRoot: () => string;
  index: CatalogMetadataIndex;
  source: SessionCatalogSource;
  watchCatalog?: (request: SessionCatalogWatchRequest) => SessionCatalogWatchHandle;
  watchRetryMs?: number;
  reconcileIntervalMs?: number;
  backgroundWork?: BackgroundWorkRegistration;
  onReconciled?: (reconciled: SessionCatalogReconcileOutcome) => void;
  onChanged?: (change: SessionCatalogChange) => void;
  onWatcherReset?: (reset: SessionCatalogWatcherReset) => void;
  persistDebounceMs?: number;
  persistMaxWaitMs?: number;
}

function rowFactsEqual(left: SessionCatalogRow, right: SessionCatalogRow): boolean {
  return left.path === right.path && left.id === right.id && left.cwd === right.cwd
    && left.delegated === right.delegated
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

export class SessionCatalog {
  private readonly rowsByPath = new Map<string, SessionCatalogRow>();
  private readonly pendingPaths = new Map<string, boolean>();
  private readonly persistDebounceMs: number;
  private readonly persistMaxWaitMs: number;
  private lane: Promise<void> = Promise.resolve();
  private refreshQueued = false;
  private persistTimer: NodeJS.Timeout | undefined;
  private persistWindowStartedAt: number | undefined;
  private persistRun: Promise<void> = Promise.resolve();
  private readonly watchCatalog: (request: SessionCatalogWatchRequest) => SessionCatalogWatchHandle;
  private readonly watchRetryMs: number;
  private readonly reconcileIntervalMs: number;
  private readonly backgroundWork: BackgroundWorkRegistration;
  private unregisterReconcile: (() => void) | undefined;
  private watcher: SessionCatalogWatchHandle | undefined;
  private watchedRoot: string | undefined;
  private readonly eventTimers = new Map<string, NodeJS.Timeout>();
  private readonly eventWindowStartedAt = new Map<string, number>();
  private unnamedEventTimer: NodeJS.Timeout | undefined;
  private unnamedEventWindowStartedAt: number | undefined;
  private watcherOverflowReconcilePending = false;
  private watchRetryTimer: NodeJS.Timeout | undefined;
  private watchOutageClearTimer: NodeJS.Timeout | undefined;
  private watchOutageReported = false;
  private readonly removalGenerations = new Map<string, number>();
  private removalGeneration = 0;
  private publishedRoot: string | undefined;
  private reconciledCut = false;
  private readonly unprovenIds = new Set<string>();
  private unknownMembership = false;
  private incompleteRetryTimer: NodeJS.Timeout | undefined;
  private incompleteRetryAttempts = 0;
  private readonly firstPublished: Promise<void>;
  private publishFirstCut: (() => void) | undefined;
  private readonly firstReconcileReported: Promise<void>;
  private reportFirstReconcile: (() => void) | undefined;
  private changeGeneration = 0;
  private durableGeneration = 0;
  private closed = false;

  constructor(private readonly options: SessionCatalogOptions) {
    this.persistDebounceMs = options.persistDebounceMs ?? CATALOG_PERSIST_DEBOUNCE_MS;
    this.persistMaxWaitMs = options.persistMaxWaitMs ?? CATALOG_PERSIST_MAX_WAIT_MS;
    this.watchCatalog = options.watchCatalog ?? watchCatalogFolder;
    this.watchRetryMs = options.watchRetryMs ?? CATALOG_WATCH_RETRY_MS;
    this.reconcileIntervalMs = options.reconcileIntervalMs ?? CATALOG_RECONCILE_INTERVAL_MS;
    this.backgroundWork = options.backgroundWork ?? backgroundWork;
    this.firstPublished = new Promise((resolve) => { this.publishFirstCut = resolve; });
    this.firstReconcileReported = new Promise((resolve) => { this.reportFirstReconcile = resolve; });
  }

  hasCompleteCut(): boolean {
    return this.publishedRoot !== undefined;
  }

  hasReconciledCut(): boolean {
    return this.reconciledCut;
  }

  awaitQueuedChanges(): Promise<void> {
    return offLoop(() => this.lane);
  }

  unprovenSessionIds(): ReadonlySet<string> {
    return this.unprovenIds;
  }

  hasUnknownMembership(): boolean {
    return this.unknownMembership;
  }

  whenPublished(): Promise<void> {
    return this.publishedRoot !== undefined ? Promise.resolve() : this.firstPublished;
  }

  whenReconciled(): Promise<void> {
    return this.firstReconcileReported;
  }

  rows(): readonly SessionCatalogRow[] {
    return [...this.rowsByPath.values()]
      .sort((left, right) => (left.path < right.path ? -1 : left.path > right.path ? 1 : 0));
  }

  row(path: string): SessionCatalogRow | undefined {
    return this.indexed(resolve(path));
  }

  async searchIdentities(): Promise<ReadonlyMap<string, SessionCatalogIdentity> | undefined> {
    await offLoop(() => this.lane);
    if (this.closed || !this.reconciledCut) return undefined;
    const duplicates = this.duplicateSessionIds();
    const identities = new Map<string, SessionCatalogIdentity>();
    for (const row of this.rowsByPath.values()) {
      if (row.delegated || duplicates.has(row.id)) continue;
      identities.set(row.id, { fileIdentity: row.fileIdentity, size: row.size, mtimeMs: row.mtimeMs });
    }
    return identities;
  }

  duplicateSessionIds(): ReadonlySet<string> {
    const counts = new Map<string, number>();
    for (const row of this.rowsByPath.values()) counts.set(row.id, (counts.get(row.id) ?? 0) + 1);
    return new Set([...counts].filter(([, count]) => count > 1).map(([id]) => id));
  }

  start(): void {
    this.enqueue(async () => {
      const catalogRoot = await this.catalogRoot();
      const rows = await this.options.index.load(catalogRoot).catch(() => undefined);
      if (this.closed || !rows) return;
      this.publishRows(rows, catalogRoot);
      this.publishedRoot = catalogRoot;
      this.publishFirstCut?.();
    });
    void this.reconcile();
    void this.ensureWatching();
    this.scheduleReconcileInterval();
  }

  reconcile(): Promise<void> {
    if (this.closed) return this.lane;
    return this.enqueue(() => this.reconcileIndex());
  }

  refresh(path: string | undefined): Promise<void> {
    return this.queueRefresh(path, false);
  }

  private refreshFromWatcher(path: string): Promise<void> {
    return this.queueRefresh(path, true);
  }

  private queueRefresh(path: string | undefined, fromWatcher: boolean): Promise<void> {
    if (path === undefined || this.closed) return this.lane;
    const key = resolve(path);
    this.pendingPaths.set(key, (this.pendingPaths.get(key) ?? false) || fromWatcher);
    if (this.refreshQueued) return this.lane;
    this.refreshQueued = true;
    return this.enqueue(async () => {
      this.refreshQueued = false;
      const pending = [...this.pendingPaths];
      this.pendingPaths.clear();
      for (const [queued, fromWatcher] of pending) await this.refreshPath(queued, fromWatcher);
    });
  }

  remove(path: string): void {
    if (this.closed) return;
    const key = resolve(path);
    this.removalGenerations.set(key, (this.removalGeneration += 1));
    if (this.rowsByPath.delete(key)) this.markChanged();
    void this.enqueue(async () => { this.removalGenerations.delete(key); });
  }

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
    this.reportFirstReconcile?.();
    this.stopWatching();
    if (this.persistTimer) {
      clearTimeout(this.persistTimer);
      this.persistTimer = undefined;
      this.persistWindowStartedAt = undefined;
    }
    await this.settled();
    await this.persistNow();
  }

  private watchEvent(filename: string | null): void {
    if (this.closed) return;
    const root = this.watchedRoot;
    if (root === undefined) return;
    if (filename === null) return this.debounceUnnamedEvent();
    const path = resolve(root, filename);
    if (ignoredCatalogPath(path, root)) return;
    if (this.watcherOverflowReconcilePending) return this.debounceUnnamedEvent();
    if (path.endsWith(".jsonl")) return this.debounceEvent(path);
    void this.resolveFolderEvent(path, root);
  }

  private async resolveFolderEvent(path: string, root: string): Promise<void> {
    const info = await lstat(path).catch(() => undefined);
    if (info === undefined) return this.resolveAbsentEvent(path, root);
    if (!info.isDirectory()) return;
    const transcripts = await this.transcriptsBeneath(path, root);
    if (transcripts === undefined) return this.debounceUnnamedEvent();
    for (const transcript of transcripts) this.debounceEvent(transcript);
  }

  private async resolveAbsentEvent(path: string, root: string): Promise<void> {
    if (!(await pathMissing(path))) return;
    if (!(await lstat(root).then((stats) => stats.isDirectory(), () => false))) return this.rootVanished();
    if (path === join(root, basename(root))) return;
    for (const indexed of this.indexedBeneath(path)) this.debounceEvent(indexed);
  }

  private async transcriptsBeneath(directory: string, root: string): Promise<string[] | undefined> {
    if (isIgnoredCatalogDirectory(directory, root)) return [];
    const transcripts: string[] = [];
    let frontier = [directory];
    while (frontier.length > 0) {
      const nextFrontier: string[] = [];
      for (const candidate of frontier) {
        let entries;
        try {
          entries = await readdir(candidate, { withFileTypes: true });
        } catch (error) {
          const code = (error as NodeJS.ErrnoException).code;
          if (code !== "ENOENT") return undefined;
          transcripts.push(...this.indexedBeneath(candidate));
          continue;
        }
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

  private indexedBeneath(path: string): string[] {
    const key = resolve(path);
    const prefix = `${key}${sep}`;
    const indexed: string[] = [];
    for (const row of this.rowsByPath.keys()) {
      if (row === key || row.startsWith(prefix)) indexed.push(row);
    }
    return indexed;
  }

  private debounceUnnamedEvent(): void {
    if (this.closed) return;
    if (this.unnamedEventTimer) clearTimeout(this.unnamedEventTimer);
    const now = Date.now();
    const windowStartedAt = this.unnamedEventWindowStartedAt ?? now;
    this.unnamedEventWindowStartedAt = windowStartedAt;
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
    if (!this.eventTimers.has(path) && this.eventTimers.size >= CATALOG_EVENT_PENDING_PATH_LIMIT) {
      this.reconcileWatcherOverflow();
      return;
    }
    const armed = this.eventTimers.get(path);
    if (armed) clearTimeout(armed);
    const now = Date.now();
    const windowStartedAt = this.eventWindowStartedAt.get(path) ?? now;
    this.eventWindowStartedAt.set(path, windowStartedAt);
    const untilCeiling = CATALOG_EVENT_MAX_WAIT_MS - (now - windowStartedAt);
    const timer = setTimeout(() => {
      this.eventTimers.delete(path);
      this.eventWindowStartedAt.delete(path);
      void this.refreshFromWatcher(path);
    }, Math.max(0, Math.min(CATALOG_EVENT_DEBOUNCE_MS, untilCeiling)));
    timer.unref();
    this.eventTimers.set(path, timer);
  }

  private reconcileWatcherOverflow(): void {
    if (this.watcherOverflowReconcilePending || this.closed) return;
    this.watcherOverflowReconcilePending = true;
    for (const timer of this.eventTimers.values()) clearTimeout(timer);
    this.eventTimers.clear();
    this.eventWindowStartedAt.clear();
    if (this.unnamedEventTimer) {
      clearTimeout(this.unnamedEventTimer);
      this.unnamedEventTimer = undefined;
      this.unnamedEventWindowStartedAt = undefined;
    }
    void this.enqueue(() => this.reconcileIndex("watcher-overflow")).finally(() => {
      this.watcherOverflowReconcilePending = false;
    });
  }

  private async ensureWatching(): Promise<boolean> {
    if (this.closed) return false;
    if (this.watcher) return true;
    const root = await this.catalogRoot();
    if (this.closed) return false;
    if (this.watcher) return true;
    let handle: SessionCatalogWatchHandle;
    const registration: { watcher?: SessionCatalogWatchHandle } = {};
    try {
      handle = this.watchCatalog({
        root,
        onEvent: (filename) => this.watchEvent(filename),
        onReset: (reason) => this.watcherStopped(registration.watcher, reason),
      });
    } catch {
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
    if (this.watchOutageReported) void this.reconcile();
    this.scheduleOutageClear(handle);
    return true;
  }

  private watcherStopped(handle: SessionCatalogWatchHandle | undefined, reason: SessionCatalogWatcherResetReason): void {
    if (handle !== this.watcher) return handle?.close();
    this.stopObserving(handle, reason, true);
  }

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
    const firstStop = !this.watchOutageReported;
    this.reportWatcherOutage(reason);
    this.scheduleWatchRetry();
    if (reconcile && firstStop) void this.reconcile();
  }

  private reportWatcherOutage(reason: SessionCatalogWatcherResetReason): void {
    if (this.watchOutageReported) return;
    this.watchOutageReported = true;
    this.options.onWatcherReset?.({ reason });
  }

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
    this.unregisterReconcile = this.backgroundWork.register({
      name: "catalog.reconcile",
      intervalMs: this.reconcileIntervalMs,
      slice: async () => {
        this.ensureWatching();
        await this.reconcile();
      },
    });
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
    this.unregisterReconcile?.();
    this.unregisterReconcile = undefined;
    if (this.incompleteRetryTimer) {
      clearTimeout(this.incompleteRetryTimer);
      this.incompleteRetryTimer = undefined;
    }
  }

  private async reconcileIndex(trigger?: SessionCatalogReconcileOutcome["trigger"]): Promise<void> {
    if (this.closed) return;
    const startedAt = Date.now();
    const removalFloor = this.removalGeneration;
    const report = (outcome: SessionCatalogReconcileOutcome["outcome"], files: number, diff?: RowDiff, unproven = 0): void => {
      this.reportFirstReconcile?.();
      this.options.onReconciled?.({
        outcome,
        files,
        added: diff?.added ?? 0,
        removed: diff?.removed ?? 0,
        modified: diff?.modified ?? 0,
        unproven,
        durationMs: Date.now() - startedAt,
        ...(trigger ? { trigger } : {}),
      });
    };
    let scan: SessionCatalogScan;
    try {
      scan = await this.options.source.scan();
    } catch {
      this.reconciledCut = false;
      report("failed", 0);
      return;
    }
    const files = scan.candidates.length + (scan.unproven?.length ?? 0);
    const cutRoot = scan.catalogRoot;
    if (!(await this.catalogRootIsDirectory(cutRoot)) && (this.publishedRoot !== undefined || this.rowsByPath.size > 0)) {
      this.reconciledCut = false;
      report("incomplete", files);
      return;
    }
    if (!scan.complete) {
      this.reconciledCut = false;
      report("incomplete", files);
      return;
    }
    const reconciled = await this.reconcileRows(scan, cutRoot);
    if (this.closed) return;
    this.rememberUnprovenIds(scan, reconciled.withoutRow);
    const unknownMembership = reconciled.withoutRow.length > 0;
    this.unknownMembership = unknownMembership;
    if (unknownMembership) {
      this.reconciledCut = false;
      this.scheduleIncompleteRetry();
    } else {
      this.incompleteRetryAttempts = 0;
      this.reconciledCut = true;
    }
    const rootChanged = this.publishedRoot !== cutRoot;
    const diff = this.publishRows(reconciled.rows, cutRoot, removalFloor);
    if (this.closed) return;
    this.publishedRoot = cutRoot;
    this.publishFirstCut?.();
    if (rootChanged || diff.added + diff.removed + diff.modified > 0) this.markChanged();
    report(unknownMembership ? "incomplete" : "reconciled", files, diff, reconciled.unproven.length);
  }

  private rememberUnprovenIds(scan: SessionCatalogScan, withoutRow: readonly string[]): void {
    this.unprovenIds.clear();
    if (withoutRow.length === 0) return;
    const missing = new Set(withoutRow.map((path) => resolve(path)));
    for (const candidate of scan.candidates) {
      if (missing.has(resolve(candidate.path))) this.unprovenIds.add(candidate.id);
    }
  }

  private scheduleIncompleteRetry(): void {
    if (this.closed || this.incompleteRetryTimer) return;
    if (this.incompleteRetryAttempts >= CATALOG_INCOMPLETE_RETRY_ATTEMPTS) return;
    this.incompleteRetryAttempts += 1;
    this.incompleteRetryTimer = setTimeout(() => {
      this.incompleteRetryTimer = undefined;
      void this.reconcile();
    }, CATALOG_INCOMPLETE_RETRY_MS);
    this.incompleteRetryTimer.unref();
  }

  private async reconcileRows(
    scan: SessionCatalogScan,
    catalogRoot: string,
  ): Promise<{ rows: CatalogMetadataIndexRow[]; unproven: string[]; withoutRow: string[] }> {
    const reconciled = await this.options.index.reconcile(
      catalogRoot,
      scan.candidates,
      (candidate) => this.options.source.summaryFor(candidate.path, () => this.backgroundWork.yieldToLoop()),
      async () => {
        if (this.closed) return true;
        await this.backgroundWork.yieldToLoop();
        return this.closed;
      },
    );
    const rebuilt = reconciled ? undefined : await this.rebuild(scan);
    const rows = reconciled ? [...reconciled.rows] : [...rebuilt!.rows];
    const unproven = reconciled ? [...reconciled.unproven] : [...rebuilt!.unproven];
    for (const path of scan.unproven ?? []) {
      const key = resolve(path);
      if (!unproven.includes(key)) unproven.push(key);
    }
    const withoutRow: string[] = [];
    for (const path of unproven) {
      const key = resolve(path);
      const retained = this.rowsByPath.get(key);
      if (retained) rows.push(retained);
      else withoutRow.push(key);
    }
    return { rows, unproven, withoutRow };
  }

  private async refreshPath(canonicalPath: string, fromWatcher: boolean): Promise<boolean> {
    const catalogRoot = this.publishedRoot ?? await this.catalogRoot();
    const removalFloor = this.removalGeneration;
    const startedAt = Date.now();
    const lookupPath = resolve(canonicalPath);
    const rowPath = this.rowsByPath.has(lookupPath) ? lookupPath : await realpath(canonicalPath).catch(() => lookupPath);
    const fromRoot = relative(catalogRoot, rowPath);
    if (fromRoot === ".." || fromRoot.startsWith(`..${sep}`) || isAbsolute(fromRoot)) {
      await this.reconcileIndex();
      return false;
    }
    const existing = this.rowsByPath.get(rowPath);
    if (await pathMissing(rowPath)) {
      if (!existing || !(await this.catalogRootIsDirectory(catalogRoot))) return false;
      if (!this.rowsByPath.delete(resolve(existing.path))) return false;
      this.markChanged();
      if (fromWatcher) this.reportChanged(existing, "removed", startedAt);
      return true;
    }
    if (existing) {
      for (let attempt = 0; attempt < APPEND_ATTEMPTS; attempt += 1) {
        const advanced = await this.options.index.append(existing);
        if (advanced) {
          const row = this.classify(advanced, catalogRoot);
          if (!this.publishRow(row, removalFloor)) return false;
          if (fromWatcher) this.reportChanged(row, "appended", startedAt);
          return true;
        }
      }
    }
    const summary = await this.options.source.summaryFor(rowPath, () => this.backgroundWork.yieldToLoop());
    if (!summary) return false;
    const rebuilt = await this.options.index.entryFromSummary(summary);
    if (!rebuilt) return false;
    const row = this.classify(rebuilt, catalogRoot);
    if (!this.publishRow(row, removalFloor)) return false;
    if (fromWatcher) this.reportChanged(row, "rebuilt", startedAt);
    return true;
  }

  private reportChanged(row: SessionCatalogRow, outcome: SessionCatalogChange["outcome"], startedAt: number): void {
    this.options.onChanged?.({ sessionId: row.id, outcome, durationMs: Math.max(0, Date.now() - startedAt) });
  }

  private async rebuild(
    scan: SessionCatalogScan,
  ): Promise<{ rows: CatalogMetadataIndexRow[]; unproven: string[] }> {
    const rows: CatalogMetadataIndexRow[] = [];
    const unproven: string[] = [];
    for (const candidate of scan.candidates) {
      if (this.closed) {
        unproven.push(...scan.candidates.map((pending) => resolve(pending.path)));
        return { rows: [], unproven };
      }
      await this.backgroundWork.yieldToLoop();
      const summary = await this.options.source.summaryFor(candidate.path, () => this.backgroundWork.yieldToLoop());
      const row = summary ? await this.options.index.entryFromSummary(summary) : undefined;
      if (!row || row.id !== candidate.id || row.cwd !== candidate.cwd) {
        const key = resolve(candidate.path);
        if (!unproven.includes(key)) unproven.push(key);
        const retained = this.rowsByPath.get(key);
        if (retained) rows.push(retained);
        continue;
      }
      rows.push(row);
    }
    return { rows, unproven };
  }

  private async catalogRoot(): Promise<string> {
    const configured = this.options.catalogRoot();
    const resolved = await realpath(configured).catch(() => undefined);
    return resolved ?? resolve(configured);
  }

  private async catalogRootIsDirectory(catalogRoot: string): Promise<boolean> {
    return lstat(catalogRoot).then((stats) => stats.isDirectory(), () => false);
  }

  private classify(row: CatalogMetadataIndexRow, catalogRoot: string): SessionCatalogRow {
    return { ...row, delegated: delegatedSessionParentPath(row.path, catalogRoot) !== undefined };
  }

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

  private publishRow(row: SessionCatalogRow, removalFloor: number): boolean {
    const path = resolve(row.path);
    if ((this.removalGenerations.get(path) ?? 0) > removalFloor) return false;
    const previous = this.rowsByPath.get(path);
    if (previous && rowFactsEqual(previous, row)) return false;
    this.rowsByPath.set(path, row);
    this.markChanged();
    return true;
  }

  private indexed(canonicalPath: string): SessionCatalogRow | undefined {
    return this.rowsByPath.get(resolve(canonicalPath));
  }

  private markChanged(): void {
    this.changeGeneration += 1;
    this.schedulePersist();
  }

  private schedulePersist(): void {
    if (this.closed) return;
    const now = Date.now();
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

  private persistNow(): Promise<void> {
    if (this.publishedRoot === undefined || this.changeGeneration === this.durableGeneration) return this.persistRun;
    const generation = this.changeGeneration;
    const catalogRoot = this.publishedRoot;
    const rows: CatalogMetadataIndexRow[] = [...this.rowsByPath.values()]
      .map(({ delegated: _delegated, ...row }) => row);
    const write = this.options.index.save(catalogRoot, rows)
      .then(() => {
        this.durableGeneration = Math.max(this.durableGeneration, generation);
      })
      .catch(() => {});
    this.persistRun = write;
    return write;
  }

  private enqueue(work: () => Promise<void>): Promise<void> {
    const next = this.lane.then(work, work);
    this.lane = next.catch(() => {});
    return this.lane;
  }
}
