import { lstat, mkdir, open, realpath } from "node:fs/promises";
import { join, resolve } from "node:path";
import lockfile from "proper-lockfile";
import { GatewayError } from "../errors.js";
import { readSecureJson } from "../util/secure-json.js";
import { durableAtomicWriteJson, syncDurably } from "../util/durable-json.js";

export interface TronWorkspaceDescriptor {
  root: string;
  available: boolean;
  reason?: "unavailable" | "owned_elsewhere" | "closed";
}

/** The capabilities that record their namespace's initialization beside the
 * workspace root. Adding one here is what lets a missing namespace be reported
 * as lost state instead of a fresh installation. */
export type TronWorkspaceFeature = "knowledge" | "episodic" | "home-tasks";

export type TronWorkspaceUnavailableCause =
  | "invalid-record" | "unsafe-directory" | "missing-root"
  | "owned-elsewhere" | "record-write-failed" | "root-changed";

// Frozen at the shipped schema: a rolled-back build must accept our writes.
function validSharedRecord(value: unknown): value is { version: 1; knowledgeInitialized?: boolean } {
  if (!value || typeof value !== "object" || Array.isArray(value)) return false;
  const record = value as Record<string, unknown>;
  return Object.keys(record).every(key => key === "version" || key === "knowledgeInitialized")
    && record.version === 1
    && (record.knowledgeInitialized === undefined || typeof record.knowledgeInitialized === "boolean");
}

/** Only owns internal-workspace initialization and availability. It neither
 * selects session cwd nor scans content nor owns extension data schemas. */
export class TronWorkspace {
  private home: string;
  private root: string;
  private initialization?: Promise<void>;
  private release: (() => Promise<void>) | undefined;
  private identity: { dev: number; ino: number } | undefined;
  private failure: NonNullable<TronWorkspaceDescriptor["reason"]> = "unavailable";
  private closed = false;

  private unavailableCause?: TronWorkspaceUnavailableCause;
  private markerWrites: Promise<void> = Promise.resolve();

  constructor(tronHome: string, private readonly options: { unavailable?: (cause: TronWorkspaceUnavailableCause) => void } = {}) {
    this.home = resolve(tronHome);
    this.root = join(this.home, "workspace");
  }

  private unavailable(cause: TronWorkspaceUnavailableCause): void {
    this.identity = undefined;
    if (this.unavailableCause) return;
    this.unavailableCause = cause;
    this.options.unavailable?.(cause);
  }

  /** Inspection must not acquire the live owner's lock or create a missing
   * workspace. Offline migration CLIs use this existing-path descriptor. */
  static async describeExisting(tronHome: string): Promise<TronWorkspaceDescriptor> {
    const workspace = new TronWorkspace(tronHome);
    try {
      await workspace.directory(workspace.home);
      await workspace.directory(workspace.root);
      return { root: workspace.root, available: true };
    } catch { return { root: workspace.root, available: false, reason: "unavailable" }; }
  }

  private async directory(path: string, create = false): Promise<{ dev: number; ino: number }> {
    if (create) {
      try { await mkdir(path, { mode: 0o700 }); }
      catch (error) { if ((error as NodeJS.ErrnoException).code !== "EEXIST") throw error; }
    }
    const info = await lstat(path);
    if (!info.isDirectory() || info.isSymbolicLink() || info.uid !== process.getuid?.()
      || (info.mode & 0o777) !== 0o700) throw new Error("Workspace directory must be owner-only and accessible");
    return { dev: info.dev, ino: info.ino };
  }

  async initialize(): Promise<void> {
    if (this.closed) return;
    this.initialization ??= this.initializeOwned();
    await this.initialization;
  }

  private async initializeOwned(): Promise<void> {
    let cause: TronWorkspaceUnavailableCause = "unsafe-directory";
    try {
      await this.directory(this.home, true);
      this.home = await realpath(this.home);
      this.root = join(this.home, "workspace");
      const gateway = join(this.home, "gateway");
      await this.directory(gateway, true);
      const state = join(gateway, "workspace-state");
      await this.directory(state, true);
      try {
        this.release = await lockfile.lock(state, {
          realpath: true, retries: 0, stale: 60_000, update: 10_000,
          onCompromised: () => {
            this.failure = "owned_elsewhere";
            this.unavailable("owned-elsewhere");
            // proper-lockfile has already retired this ownership. Do not try
            // to release an unowned lock or fail unrelated runtime shutdown.
            this.release = undefined;
          },
        });
      } catch { this.failure = "owned_elsewhere"; this.unavailable("owned-elsewhere"); return; }
      const marker = join(state, "initialized.json");
      cause = "invalid-record";
      const read = await readSecureJson<unknown>(marker, 128);
      if (read.present && !validSharedRecord(read.value)) throw new Error("Invalid workspace initialization record");
      // A missing established root is loss of data, not a new installation.
      cause = "unsafe-directory";
      try { this.identity = await this.directory(this.root, !read.present); }
      catch (error) {
        if (read.present && (error as NodeJS.ErrnoException).code === "ENOENT") cause = "missing-root";
        throw error;
      }
      if (!read.present) {
        cause = "record-write-failed";
        const parent = await open(this.home, "r");
        try { await syncDurably(parent); } finally { await parent.close(); }
        await durableAtomicWriteJson(marker, { version: 1 });
      }
      if (this.failure === "owned_elsewhere") this.identity = undefined;
      if (this.closed) { this.identity = undefined; await this.release?.(); this.release = undefined; }
    } catch {
      this.unavailable(cause);
      // Preserve invalid data; unrelated project sessions remain available.
      const release = this.release;
      this.release = undefined;
      await release?.().catch(() => {});
    }
  }

  async describe(): Promise<TronWorkspaceDescriptor> {
    await this.initialize();
    if (this.closed) return { root: this.root, available: false, reason: "closed" };
    if (this.identity) {
      try {
        await this.directory(this.home);
        const current = await this.directory(this.root);
        if (current.dev === this.identity.dev && current.ino === this.identity.ino) {
          return { root: this.root, available: true };
        }
      } catch { /* Unavailable is a fact, never permission to recreate. */ }
      this.unavailable("root-changed");
    }
    return { root: this.root, available: false, reason: this.failure };
  }

  /** Feature initialization evidence lives beside the workspace root so loss of
   * a feature namespace cannot be mistaken for a fresh installation. */
  async featureInitialized(feature: TronWorkspaceFeature): Promise<boolean> {
    if (!(await this.describe()).available) throw new Error(`${feature}: Tron workspace is unavailable`);
    const marker = this.featureMarker(feature);
    try {
      const read = await readSecureJson<unknown>(marker, 128);
      if (!read.present) return false;
      if (feature === "knowledge") {
        if (!validSharedRecord(read.value)) throw new Error("Invalid shared initialization record");
        return read.value.knowledgeInitialized === true;
      }
      if (!read.value || typeof read.value !== "object" || Array.isArray(read.value)
        || Object.keys(read.value).length !== 1 || (read.value as { version?: unknown }).version !== 1) {
        throw new Error("Invalid initialization record");
      }
      return true;
    } catch (error) { throw new Error(`${feature}: invalid initialization record`, { cause: error }); }
  }

  private featureMarker(feature: TronWorkspaceFeature): string {
    return join(this.home, "gateway", "workspace-state", feature === "knowledge" ? "initialized.json" : `${feature}-initialized.json`);
  }

  async markFeatureInitialized(feature: TronWorkspaceFeature): Promise<void> {
    // Separate feature files remove cross-feature lost updates. This queue
    // serializes same-feature check/publication so concurrent initialization
    // does not republish valid evidence. Knowledge alone writes the frozen record.
    const write = this.markerWrites.then(async () => {
      if (await this.featureInitialized(feature)) return;
      await durableAtomicWriteJson(this.featureMarker(feature), feature === "knowledge"
        ? { version: 1, knowledgeInitialized: true } : { version: 1 });
    });
    this.markerWrites = write.catch(() => {});
    await write;
  }

  /** Read-only resolution for display. The document producer creates files/;
   * displaying a missing directory must never mutate the workspace. */
  async filesRoot(): Promise<string> {
    if (!(await this.describe()).available) {
      throw new GatewayError("conflict", "Tron internal workspace is unavailable; restore it before using internal files");
    }
    const files = join(this.root, "files");
    try {
      const info = await lstat(files);
      if (!info.isDirectory() || info.isSymbolicLink() || info.uid !== process.getuid?.()
        || (info.mode & 0o700) !== 0o700 || (info.mode & 0o022) !== 0) throw new Error("Invalid files directory");
    } catch { throw new GatewayError("conflict", "Tron internal files must be an existing directory writable only by its owner"); }
    return files;
  }

  async dispose(): Promise<void> {
    this.closed = true;
    await this.initialization;
    await this.markerWrites;
    const release = this.release;
    this.identity = undefined;
    await release?.();
    // Keep the release callback until it has retired successfully so a
    // registry retry can prove the workspace lock was actually released.
    if (this.release === release) this.release = undefined;
  }
}
