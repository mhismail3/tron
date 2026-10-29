import { lstat, readdir } from "node:fs/promises";
import { join } from "node:path";
import { backgroundWork } from "../../background-work.js";
import { GatewayError } from "../../errors.js";
import { watchFolder, FOLDER_WATCH_RETRY_MS, FOLDER_RECONCILE_INTERVAL_MS, type FolderWatchHandle } from "../../util/folder-watch.js";
import type { TronWorkspace } from "../../workspace/tron-workspace.js";
import { APP_ID, hash, isReadyAppEntry, readAppEntry, type AppEntry, type AppRow, type ReadyAppEntry } from "./apps-folder-format.js";

type IndexedEntry = Pick<AppEntry, "name" | "row" | "changedAt">;

/** Disposable membership, never a registry. Every publication is a filesystem
 * cut; events bound the pending set and enqueue work on the same serial lane. */
export class AppsFolderIndex {
  private entries = new Map<string, IndexedEntry>();
  private revision = hash("empty");
  private lane: Promise<void> = Promise.resolve();
  private watcher: FolderWatchHandle | undefined;
  private watchedIdentity: string | undefined;
  private rootCut: string | undefined;
  private pending = new Set<string>();
  private full = true;
  private scheduled: NodeJS.Timeout | undefined;
  private watchRetry: NodeJS.Timeout | undefined;
  private unregister?: () => void;
  private closed = false;
  private started = false;
  private generation = 0;
  private unavailable?: unknown;
  constructor(private readonly workspace: TronWorkspace, private readonly changed: (revision: string) => void = () => {},
    private readonly observe: typeof watchFolder = watchFolder) {}

  private async root(): Promise<string> {
    const files = await this.workspace.filesRoot().catch(error => {
      this.watcher?.close(); this.watcher = undefined; this.watchedIdentity = undefined;
      this.full = true; this.retryObservation(); throw error;
    });
    const info = await lstat(files), identity = `${info.dev}:${info.ino}`;
    if (identity !== this.watchedIdentity) {
      this.watcher?.close(); this.watcher = undefined; this.watchedIdentity = undefined; this.full = true;
    }
    if (!this.watcher && !this.closed && !this.watchRetry) {
      const registration: { handle?: FolderWatchHandle } = {};
      try {
        const handle = this.observe({ root: files, onEvent: path => {
          if (this.closed || this.watcher !== registration.handle) return;
          if (path !== null && path !== "apps" && !path.startsWith("apps/")) return;
          this.invalidate(path?.split("/")[1]);
        }, onReset: () => {
          if (this.closed || this.watcher !== registration.handle) return;
          registration.handle?.close(); this.watcher = undefined; this.watchedIdentity = undefined;
          this.full = true; this.retryObservation();
        } });
        registration.handle = handle; this.watcher = handle; this.watchedIdentity = identity;
      } catch { this.full = true; this.retryObservation(); }
    }
    // The watch backend being down does not make an inspected filesystem cut
    // empty/unavailable. Reads scan while the owner repairs observation.
    if (!this.watcher) this.full = true;
    const root = join(files, "apps");
    let cut = "missing";
    try {
      const info = await lstat(root);
      if (!info.isDirectory() || info.isSymbolicLink()) throw new GatewayError("conflict", "Apps folder is not a safe directory");
      cut = `${info.dev}:${info.ino}:${info.mtimeMs}:${info.ctimeMs}`;
    } catch (error) { if ((error as NodeJS.ErrnoException).code !== "ENOENT") throw error; }
    // The first recursive OS hint can be lost while observation starts. A
    // changed root cut proves membership needs reconciliation, without adding
    // a polling loop or walking every unchanged bundle on each read.
    if (cut !== this.rootCut) { this.rootCut = cut; this.full = true; }
    return root;
  }
  private retryObservation(): void {
    if (this.closed || this.watchRetry) return;
    this.watchRetry = setTimeout(() => {
      this.watchRetry = undefined; this.full = true;
      void this.reconcile().catch(() => { /* root() owns the next observation attempt. */ });
    }, FOLDER_WATCH_RETRY_MS);
    this.watchRetry.unref();
  }
  private enqueue<T>(operation: () => Promise<T>): Promise<T> {
    const result = this.lane.then(operation); this.lane = result.then(() => {}, () => {}); return result;
  }
  private invalidate(entry?: string): void {
    if (!entry || this.pending.size >= 256) { this.full = true; this.pending.clear(); }
    else this.pending.add(entry);
    this.schedule();
  }
  private schedule(): void {
    if (this.scheduled || this.closed) return;
    this.scheduled = setTimeout(() => {
      this.scheduled = undefined;
      void this.reconcile().catch(() => { /* Reads report unavailable; shared backstop retries. */ });
    }, 250);
    this.scheduled.unref();
  }
  private async initialize(): Promise<void> {
    if (this.closed) throw new GatewayError("conflict", "Apps index is closed");
    if (this.started) return;
    this.started = true;
    this.unregister = backgroundWork.register({ name: "apps.reconcile", intervalMs: FOLDER_RECONCILE_INTERVAL_MS,
      slice: async () => { this.full = true; await this.reconcile(); } });
    await this.reconcile();
  }
  /** Display publication and RPC reads await the same observation cut. */
  async reconcile(): Promise<void> {
    return this.enqueue(async () => {
      if (this.closed) return;
      const generation = this.generation;
      try {
        const root = await this.root(); // Attach before baseline enumeration.
        const all = this.full; this.full = false;
        const pending = [...this.pending]; this.pending.clear();
        const next = all ? new Map<string, IndexedEntry>() : new Map(this.entries);
        let names: string[];
        if (all) {
          try { names = await readdir(root); }
          catch (error) { if ((error as NodeJS.ErrnoException).code !== "ENOENT") throw error; names = []; }
        } else names = pending;
        let count = 0;
        for (const name of names) {
          try {
            const info = await lstat(join(root, name));
            if (info.isDirectory() || info.isSymbolicLink()) {
              const entry = await readAppEntry(root, name);
              // Keep only the catalog projection; admission owns a fresh typed
              // byte snapshot, never a cleared or incomplete execution object.
              next.set(name, { name: entry.name, row: entry.row, changedAt: entry.changedAt });
            } else next.delete(name); // Loose regular/special files are not entries.
          } catch (error) { if ((error as NodeJS.ErrnoException).code !== "ENOENT") throw error; next.delete(name); }
          if (++count % 50 === 0) await backgroundWork.yieldToLoop();
          if (this.closed || generation !== this.generation) return;
        }
        await this.workspace.filesRoot();
        if (this.closed || generation !== this.generation) return;
        const revision = hash(JSON.stringify([...next.values()].sort((a, b) => a.name.localeCompare(b.name)).map(entry => entry.row)));
        const changed = revision !== this.revision;
        this.entries = next; this.revision = revision; this.unavailable = undefined;
        if (changed) this.changed(revision);
      } catch (error) { this.full = true; this.unavailable = error; throw error; }
    });
  }
  async catalog(cursor?: string, limit = 50): Promise<{ revision: string; rows: AppRow[]; nextCursor?: string }> {
    await this.initialize(); await this.reconcile();
    if (this.unavailable) throw this.unavailable;
    let offset = 0;
    if (!Number.isInteger(limit) || limit < 1 || limit > 50) throw new GatewayError("invalid_request", "Catalog limit must be 1–50");
    if (cursor !== undefined) {
      let cut: unknown;
      try { cut = JSON.parse(Buffer.from(cursor, "base64url").toString()); } catch { throw new GatewayError("invalid_request", "Invalid catalog cursor"); }
      if (!Array.isArray(cut) || cut.length !== 2 || typeof cut[0] !== "string" || !Number.isSafeInteger(cut[1]) || cut[1] < 0) throw new GatewayError("invalid_request", "Invalid catalog cursor");
      if (cut[0] !== this.revision) throw new GatewayError("conflict", "Apps catalog changed; read the first page again", true, { reason: "catalog_changed" }, "catalog_changed");
      offset = cut[1] as number;
    }
    const rows = [...this.entries.values()].sort((a, b) =>
      Number(b.row.section === "Apps") - Number(a.row.section === "Apps") || b.changedAt - a.changedAt || a.name.localeCompare(b.name));
    return { revision: this.revision, rows: rows.slice(offset, offset + limit).map(entry => entry.row),
      ...(offset + limit < rows.length ? { nextCursor: Buffer.from(JSON.stringify([this.revision, offset + limit])).toString("base64url") } : {}) };
  }
  /** One edge read for every admission path, including opaque broken-row keys. */
  private async current(name: string, expectedContentRevision: string): Promise<AppEntry> {
    const root = await this.root();
    let entry: AppEntry;
    try { entry = await readAppEntry(root, name); }
    catch (error) {
      if (!["ENOENT", "ENOTDIR"].includes((error as NodeJS.ErrnoException).code ?? "")) throw error;
      this.invalidate(name);
      // Verify the parent availability, never retry the entry read. Losing the
      // workspace is unavailable, not a missing row or an empty Apps catalog.
      await this.root();
      throw new GatewayError("not_found", "Entry no longer exists", true, { reason: "entry_changed" });
    }
    if (entry.row.contentRevision !== expectedContentRevision) {
      // A rejected admission also invalidates a known-stale cut if its OS hint
      // was lost. It does not publish another membership authority.
      this.entryChanged(name);
    }
    return entry;
  }
  private entryChanged(name: string): never {
    this.invalidate(name);
    throw new GatewayError("conflict", "Entry changed; open its current version", true, { reason: "entry_changed" });
  }
  /** Admission always reopens bytes, including a replacement missed by fs.watch. */
  async requireEntry(id: string, expectedContentRevision: string): Promise<ReadyAppEntry> {
    if (!APP_ID.test(id)) throw new GatewayError("invalid_request", "Invalid app id");
    await this.initialize();
    return this.enqueue(async () => {
      const entry = await this.current(id, expectedContentRevision);
      if (!isReadyAppEntry(entry)) throw new GatewayError("unsupported", entry.row.status.reason);
      return entry;
    });
  }
  async validateRow(rowKey: string, expectedContentRevision: string): Promise<void> {
    await this.initialize();
    return this.enqueue(async () => {
      const indexed = [...this.entries.values()].find(entry => entry.row.rowKey === rowKey);
      if (!indexed) throw new GatewayError("not_found", "Entry no longer exists");
      const entry = await this.current(indexed.name, expectedContentRevision);
      if (entry.row.rowKey !== rowKey) this.entryChanged(indexed.name);
    });
  }
  async membership(ids: readonly string[]): Promise<ReadonlySet<string>> {
    await this.initialize(); await this.reconcile();
    return new Set(ids.filter(id => this.entries.has(id)));
  }
  async refreshAll(): Promise<void> { this.full = true; await this.reconcile(); }
  async dispose(): Promise<void> {
    this.closed = true; this.generation++;
    this.watcher?.close(); this.watcher = undefined; this.unregister?.();
    if (this.scheduled) clearTimeout(this.scheduled);
    if (this.watchRetry) clearTimeout(this.watchRetry);
    await this.lane; this.entries.clear(); this.pending.clear();
  }
}
