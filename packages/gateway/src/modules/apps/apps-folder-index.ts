import { constants } from "node:fs";
import { lstat, open, readdir } from "node:fs/promises";
import { directoryPublisher, manifestReplacer, type DirectoryPublisher, type ManifestReplacer } from "../../machine/directory-publication.js";
import { publishApp, type AppPublication } from "./apps-publication.js";
import { AppPublicationStaging, publicationFilesystemMismatch } from "./apps-publication-staging.js";
import { constants as osConstants } from "node:os";
import { isAbsolute, join, relative, resolve } from "node:path";
import { backgroundWork } from "../../background-work.js";
import { asUncertainOutcome, GatewayError } from "../../errors.js";
import { isDurablePublicationUncertain, syncDurably } from "../../util/durable-json.js";
import { watchFolder, FOLDER_WATCH_RETRY_MS, FOLDER_RECONCILE_INTERVAL_MS, type FolderWatchHandle } from "../../util/folder-watch.js";
import type { TronWorkspace } from "../../workspace/tron-workspace.js";
import { APP_ID, hash, isReadyAppEntry, readAppEntry, readAppManifest, type AppEntry, type AppRow, type ReadyAppEntry } from "./apps-folder-format.js";
import type { ByteLease, ByteRange } from "../../util/byte-stream.js";
import { AppPreviewLeases } from "./apps-preview-leases.js";
import { abortableRead } from "../../util/abortable-read.js";
import { fileIdentity, snapshotDigest, type StreamedAppFile } from "./apps-folder-files.js";

interface PreviewCut { identity: string; path: string; file: StreamedAppFile; mimeType: string }
type IndexedEntry = Pick<AppEntry, "name" | "row" | "changedAt"> & { preview: PreviewCut | undefined };
function ordered(entries: Iterable<IndexedEntry>): IndexedEntry[] {
  return [...entries].sort((a, b) => Number(b.row.section === "Apps") - Number(a.row.section === "Apps")
    || b.changedAt - a.changedAt || a.name.localeCompare(b.name));
}
function previewCut(entry: AppEntry): PreviewCut | undefined {
  return isReadyAppEntry(entry) && entry.payload.kind === "artifact" && !Buffer.isBuffer(entry.file)
    ? { identity: entry.identity, path: entry.entry, file: entry.file, mimeType: entry.payload.artifact.mimeType } : undefined;
}

/** Disposable membership, never a registry. Every publication is a filesystem
 * cut; events bound the pending set and enqueue work on the same serial lane. */
export class AppsFolderIndex {
  private entries = new Map<string, IndexedEntry>();
  private readonly previews = new AppPreviewLeases();
  private readonly publicationStop = new AbortController();
  private readonly staging: AppPublicationStaging;
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
    private readonly observe: typeof watchFolder = watchFolder, private readonly publishDirectory: DirectoryPublisher = directoryPublisher(),
    private readonly replaceManifest: ManifestReplacer = manifestReplacer()) { this.staging = new AppPublicationStaging(workspace, this.publicationStop.signal); }

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
              next.set(name, { name: entry.name, row: entry.row, changedAt: entry.changedAt, preview: previewCut(entry) });
            } else next.delete(name); // Loose regular/special files are not entries.
          } catch (error) { if ((error as NodeJS.ErrnoException).code !== "ENOENT") throw error; next.delete(name); }
          if (++count % 50 === 0) await backgroundWork.yieldToLoop();
          if (this.closed || generation !== this.generation) return;
        }
        await this.previews.retireStale(id => next.get(id)?.row.contentRevision);
        await this.workspace.filesRoot();
        if (this.closed || generation !== this.generation) return;
        const revision = hash(JSON.stringify(ordered(next.values()).map(entry => entry.row)));
        const changed = revision !== this.revision || this.unavailable !== undefined;
        this.entries = next; this.revision = revision; this.unavailable = undefined;
        if (changed) this.changed(revision);
      } catch (error) {
        const changed = this.unavailable === undefined;
        this.full = true; this.unavailable = error;
        await this.previews.retireStale(() => undefined);
        if (changed && !this.closed && generation === this.generation) this.changed(this.revision);
        throw error;
      }
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
    const rows = ordered(this.entries.values());
    return { revision: this.revision, rows: rows.slice(offset, offset + limit).map(entry => entry.row),
      ...(offset + limit < rows.length ? { nextCursor: Buffer.from(JSON.stringify([this.revision, offset + limit])).toString("base64url") } : {}) };
  }
  /** One edge read for every admission path, including opaque broken-row keys. */
  private async withRoot<T>(name: string, accept: (root: string) => Promise<T>): Promise<T> {
    if (this.closed) throw new GatewayError("conflict", "Apps index is closed");
    const root = await this.root();
    try { return await accept(root); }
    catch (error) {
      if (error instanceof GatewayError && error.code === "conflict") this.invalidate(name);
      if (!["ENOENT", "ENOTDIR"].includes((error as NodeJS.ErrnoException).code ?? "")) throw error;
      this.invalidate(name);
      // Verify parent availability, never retry the read or lease admission.
      await this.root();
      throw new GatewayError("not_found", "Entry no longer exists", true, { reason: "entry_changed" });
    }
  }
  private async snapshot(root: string, name: string, expected: string, signal?: AbortSignal): Promise<AppEntry> {
    const entry = await readAppEntry(root, name, signal);
    if (this.closed) throw new GatewayError("conflict", "Apps index is closed");
    if (entry.row.contentRevision !== expected) this.entryChanged(name);
    const indexed = this.entries.get(name);
    if (indexed?.row.contentRevision === expected) indexed.preview = previewCut(entry);
    return entry;
  }
  private admit<T>(name: string, expected: string, accept: (entry: AppEntry, root: string) => Promise<T>): Promise<T> {
    return this.withRoot(name, async root => accept(await this.snapshot(root, name, expected), root));
  }
  private entryChanged(name: string): never {
    this.invalidate(name);
    throw new GatewayError("conflict", "Entry changed; open its current version", true, { reason: "entry_changed" });
  }
  /** Admission always reopens bytes, including a replacement missed by fs.watch. */
  async requireEntry(id: string, expectedContentRevision: string): Promise<ReadyAppEntry> {
    if (!APP_ID.test(id)) throw new GatewayError("invalid_request", "Invalid app id");
    await this.initialize();
    return this.enqueue(() => this.admit(id, expectedContentRevision, async entry => {
      if (!isReadyAppEntry(entry)) throw new GatewayError("unsupported", entry.row.status.reason);
      return entry;
    }));
  }
  async setMetadata(id: string, expected: string, edits: { title?: unknown; icon?: unknown }): Promise<AppRow> {
    if (!APP_ID.test(id) || !Object.keys(edits).length) throw new GatewayError("invalid_request", "Choose a title or icon to edit");
    await this.initialize();
    return this.enqueue(() => this.admit(id, expected, async (entry, root) => {
      if (!isReadyAppEntry(entry)) throw new GatewayError("unsupported", entry.row.status.reason);
      const previous = entry.files.get("app.json");
      const manifest = previous && Buffer.isBuffer(previous) ? JSON.parse(previous.toString("utf8")) : {};
      for (const [key, value] of Object.entries(edits)) { if (value === null) delete manifest[key]; else manifest[key] = value; }
      const bytes = Buffer.from(`${JSON.stringify(manifest)}\n`); readAppManifest(bytes);
      const stage = await this.staging.create();
      let source, destination;
      try {
        const file = await open(join(stage.path, "app.json"), "wx", 0o600);
        try { await file.writeFile(bytes); await syncDurably(file); } finally { await file.close(); }
        source = await open(stage.path, constants.O_RDONLY | constants.O_DIRECTORY | constants.O_NOFOLLOW);
        destination = await open(join(root, id), constants.O_RDONLY | constants.O_DIRECTORY | constants.O_NOFOLLOW);
        if (fileIdentity(await destination.stat()) !== entry.identity) this.entryChanged(id);
        await this.snapshot(root, id, expected); await stage.fence();
        await this.replaceManifest(source.fd, destination.fd);
        try {
          await this.root();
          const current = await readAppEntry(root, id), actual = isReadyAppEntry(current) ? current.files.get("app.json") : undefined;
          if (!isReadyAppEntry(current) || current.identity !== entry.identity || !Buffer.isBuffer(actual) || !actual.equals(bytes)
            || current.files.size !== entry.files.size + (previous ? 0 : 1)
            || [...entry.files].some(([path, file]) => path !== "app.json" && (!current.files.has(path) || snapshotDigest(current.files.get(path)!) !== snapshotDigest(file)))) this.entryChanged(id);
          return current.row;
        } catch (error) { throw asUncertainOutcome(error, "Metadata was published but its current entry could not be verified"); }
      } catch (error) {
        if (isDurablePublicationUncertain(error)) throw asUncertainOutcome(error, "Metadata publication could not be durably verified");
        throw error;
      } finally {
        this.invalidate(id);
        const cleanup = await Promise.allSettled([source?.close(), destination?.close(), stage.release()]);
        const failed = cleanup.find(result => result.status === "rejected");
        if (failed?.status === "rejected") throw asUncertainOutcome(failed.reason, "Metadata cleanup could not be verified");
      }
    }));
  }
  async validateRow(rowKey: string, expectedContentRevision: string): Promise<void> {
    await this.initialize();
    return this.enqueue(async () => {
      const indexed = [...this.entries.values()].find(entry => entry.row.rowKey === rowKey);
      if (!indexed) throw new GatewayError("not_found", "Entry no longer exists");
      await this.admit(indexed.name, expectedContentRevision, async entry => {
        if (entry.row.rowKey !== rowKey) this.entryChanged(indexed.name);
      });
    });
  }
  async acquireArtifact(id: string, expectedContentRevision: string, range?: ByteRange, signal?: AbortSignal): Promise<ByteLease> {
    if (!APP_ID.test(id)) throw new GatewayError("invalid_request", "Invalid app id");
    await abortableRead(signal, () => this.initialize());
    return this.enqueue(() => this.withRoot(id, async root => {
      signal?.throwIfAborted();
      const indexed = this.entries.get(id);
      const cached = indexed?.row.contentRevision === expectedContentRevision ? indexed.preview : undefined;
      // A readonly byte range pins an already admitted primary-file cut. Reopen
      // and fence its inode/size/mtime/ctime, not a multi-GiB rehash per AVPlayer
      // range. Executable open/grant/write admission always hashes fresh bytes.
      if (cached) return this.previews.acquire({ ...cached, id, revision: expectedContentRevision, root: join(root, id) }, range, signal);
      const entry = await this.snapshot(root, id, expectedContentRevision, signal);
      if (!isReadyAppEntry(entry)) throw new GatewayError("unsupported", entry.row.status.reason);
      if (entry.payload.kind !== "artifact") throw new GatewayError("unsupported", "Executable source is not an artifact preview");
      return this.previews.acquire({ id, revision: expectedContentRevision, root: join(root, id), identity: entry.identity,
        path: entry.entry, file: entry.file, mimeType: entry.payload.artifact.mimeType }, range, signal);
    }));
  }
  /** Only this owner interprets whether a displayed path is an existing entry. */
  async selectDisplayedFile(path: string, digest: string): Promise<ReadyAppEntry["row"] | undefined> {
    const descriptor = await this.workspace.describe();
    if (!descriptor.available) throw new GatewayError("conflict", "Tron workspace is unavailable");
    const selected = relative(join(descriptor.root, "files/apps"), resolve(path));
    if (isAbsolute(selected) || selected === ".." || selected.startsWith("../")) return undefined;
    await this.initialize();
    return this.enqueue(async () => {
      const [name, ...parts] = selected.split("/");
      if (!name || !APP_ID.test(name)) throw new GatewayError("invalid_request", "Display an app's declared entry");
      return this.withRoot(name, async root => {
        const entry = await readAppEntry(root, name);
        if (!isReadyAppEntry(entry) || parts.join("/") !== entry.entry || snapshotDigest(entry.file) !== digest)
          throw new GatewayError("conflict", "Display must select the app's current declared entry");
        return entry.row;
      });
    });
  }
  stopPublications(): void { this.publicationStop.abort(new GatewayError("conflict", "Apps publication is closed")); }
  recoverPublications(): Promise<void> { return this.enqueue(() => this.staging.recoverAtStartup()); }
  /** The same lane owns publication and discovery; no producer installs a row. */
  async publish(input: AppPublication, signal?: AbortSignal): Promise<ReadyAppEntry["row"]> {
    const lifetime = signal ? AbortSignal.any([signal, this.publicationStop.signal]) : this.publicationStop.signal;
    const accepted = await this.enqueue(async () => {
      const active = () => { lifetime.throwIfAborted(); if (this.closed) throw new GatewayError("conflict", "Apps index is closed"); };
      try { return await publishApp(this.workspace, input, this.publishDirectory, active, lifetime, this.staging); }
      catch (error) {
        this.full = true; active();
        if (Math.abs((error as NodeJS.ErrnoException).errno ?? 0) === osConstants.errno.EXDEV) publicationFilesystemMismatch();
        if (["ENOENT", "ENOTDIR", "ELOOP"].includes((error as NodeJS.ErrnoException).code ?? "")) throw new GatewayError("conflict", "Publication namespace changed");
        throw error;
      }
    });
    this.full = true; await this.initialize(); await this.reconcile();
    return (await this.requireEntry(accepted.name, accepted.row.contentRevision)).row;
  }
  /** Access changes invalidate capabilities even when file membership is unchanged. */
  accessChanged(): void { if (!this.closed) this.changed(this.revision); }
  async membership(ids: readonly string[]): Promise<ReadonlySet<string>> {
    await this.initialize(); await this.reconcile();
    return new Set(ids.filter(id => this.entries.has(id)));
  }
  async refreshAll(): Promise<void> { this.full = true; await this.reconcile(); }
  async dispose(): Promise<void> {
    this.closed = true; this.generation++;
    this.stopPublications();
    this.watcher?.close(); this.watcher = undefined; this.unregister?.();
    if (this.scheduled) clearTimeout(this.scheduled);
    if (this.watchRetry) clearTimeout(this.watchRetry);
    await Promise.all([this.lane, this.previews.dispose()]); await this.staging.dispose(); this.entries.clear(); this.pending.clear();
  }
}
