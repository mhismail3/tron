import { lstat, mkdir, open, realpath } from "node:fs/promises";
import { join, resolve } from "node:path";
import lockfile from "proper-lockfile";
import { GatewayError } from "../errors.js";
import { readSecureJson } from "../util/secure-json.js";
import { durableAtomicWriteJson } from "../util/durable-json.js";

export interface TronWorkspaceDescriptor {
  root: string;
  available: boolean;
  reason?: "unavailable" | "owned_elsewhere" | "closed";
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

  constructor(tronHome: string) {
    this.home = resolve(tronHome);
    this.root = join(this.home, "workspace");
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
            this.identity = undefined;
            this.failure = "owned_elsewhere";
            // proper-lockfile has already retired this ownership. Do not try
            // to release an unowned lock or fail unrelated runtime shutdown.
            this.release = undefined;
          },
        });
      } catch { this.failure = "owned_elsewhere"; return; }
      const marker = join(state, "initialized.json");
      const read = await readSecureJson<unknown>(marker, 128);
      if (read.present) {
        const value = read.value as Record<string, unknown> | null;
        if (!value || typeof value !== "object" || Array.isArray(value)
          || Object.keys(value).some(key => key !== "version" && key !== "knowledgeInitialized")
          || value.version !== 1 || (value.knowledgeInitialized !== undefined && typeof value.knowledgeInitialized !== "boolean")) {
          throw new Error("Invalid workspace initialization record");
        }
      }
      // A missing established root is loss of data, not a new installation.
      this.identity = await this.directory(this.root, !read.present);
      if (!read.present) {
        const parent = await open(this.home, "r");
        try { await parent.sync(); } finally { await parent.close(); }
        await durableAtomicWriteJson(marker, { version: 1 });
      }
      if (this.failure === "owned_elsewhere") this.identity = undefined;
      if (this.closed) { this.identity = undefined; await this.release?.(); this.release = undefined; }
    } catch {
      this.identity = undefined;
      // Preserve invalid data and make the failure local to this feature.
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
      this.identity = undefined;
    }
    return { root: this.root, available: false, reason: this.failure };
  }

  /** Feature initialization evidence lives beside the workspace root so loss of
   * a feature namespace cannot be mistaken for a fresh installation. */
  async featureInitialized(feature: "knowledge"): Promise<boolean> {
    await this.initialize();
    const marker = join(this.home, "gateway", "workspace-state", "initialized.json");
    const read = await readSecureJson<unknown>(marker, 256);
    if (!read.present) return false;
    if (!read.value || typeof read.value !== "object" || Array.isArray(read.value)) return false;
    return (read.value as Record<string, unknown>)[`${feature}Initialized`] === true;
  }

  async markFeatureInitialized(feature: "knowledge"): Promise<void> {
    await this.initialize();
    const marker = join(this.home, "gateway", "workspace-state", "initialized.json");
    const read = await readSecureJson<unknown>(marker, 256);
    const value = read.present && read.value && typeof read.value === "object" && !Array.isArray(read.value) ? read.value as Record<string, unknown> : { version: 1 };
    await durableAtomicWriteJson(marker, { ...value, version: 1, [`${feature}Initialized`]: true });
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
    const release = this.release;
    this.identity = undefined;
    await release?.();
    // Keep the release callback until it has retired successfully so a
    // registry retry can prove the workspace lock was actually released.
    if (this.release === release) this.release = undefined;
  }
}
