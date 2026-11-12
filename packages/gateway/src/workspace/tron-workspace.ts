import { lstat, mkdir, open, realpath } from "node:fs/promises";
import { join, resolve } from "node:path";
import lockfile from "proper-lockfile";
import { GatewayError } from "../errors.js";
import type { TronWorkspaceDescriptor } from "../kernel/resources/resource-root.js";
import { readSecureJson } from "../foundation/secure-json.js";
import { durableAtomicWriteJson, syncDurably } from "../foundation/durable-json.js";
import { tronHomePath } from "../foundation/tron-home-layout.js";

export type TronWorkspaceFeature = "profile" | "episodic" | "home-tasks" | "apps";

export type TronWorkspaceUnavailableCause =
  | "invalid-record" | "unsafe-directory" | "missing-root"
  | "owned-elsewhere" | "record-write-failed" | "root-changed";

function validInitializationRecord(value: unknown): value is { version: 1 } {
  return value !== null && typeof value === "object" && !Array.isArray(value)
    && Object.keys(value).length === 1 && (value as { version?: unknown }).version === 1;
}

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
    this.root = tronHomePath(this.home, "workspace");
  }

  private unavailable(cause: TronWorkspaceUnavailableCause): void {
    this.identity = undefined;
    if (this.unavailableCause) return;
    this.unavailableCause = cause;
    this.options.unavailable?.(cause);
  }

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
      this.root = tronHomePath(this.home, "workspace");
      const gateway = tronHomePath(this.home, "state");
      await this.directory(gateway, true);
      const state = tronHomePath(this.home, "state/workspace-state");
      await this.directory(state, true);
      try {
        this.release = await lockfile.lock(state, {
          realpath: true, retries: 0, stale: 60_000, update: 10_000,
          onCompromised: () => {
            this.failure = "owned_elsewhere";
            this.unavailable("owned-elsewhere");
            this.release = undefined;
          },
        });
      } catch { this.failure = "owned_elsewhere"; this.unavailable("owned-elsewhere"); return; }
      const marker = join(state, "initialized.json");
      cause = "invalid-record";
      const read = await readSecureJson<unknown>(marker, 128);
      if (read.present && !validInitializationRecord(read.value)) throw new Error("Invalid workspace initialization record");
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
      } catch { }
      this.unavailable("root-changed");
    }
    return { root: this.root, available: false, reason: this.failure };
  }

  async featureInitialized(feature: TronWorkspaceFeature): Promise<boolean> {
    if (!(await this.describe()).available) throw new Error(`${feature}: Tron workspace is unavailable`);
    return TronWorkspace.featureInitializedExisting(this.home, feature);
  }

  static async featureInitializedExisting(home: string, feature: TronWorkspaceFeature): Promise<boolean> {
    const marker = tronHomePath(home, "state/workspace-state", `${feature}-initialized.json`);
    try {
      const read = await readSecureJson<unknown>(marker, 128);
      if (!read.present) return false;
      if (!validInitializationRecord(read.value)) {
        throw new Error("Invalid initialization record");
      }
      return true;
    } catch (error) { throw new Error(`${feature}: invalid initialization record`, { cause: error }); }
  }

  private featureMarker(feature: TronWorkspaceFeature): string {
    return tronHomePath(this.home, "state/workspace-state", `${feature}-initialized.json`);
  }

  async markFeatureInitialized(feature: TronWorkspaceFeature): Promise<void> {
    const write = this.markerWrites.then(async () => {
      if (await this.featureInitialized(feature)) return;
      await durableAtomicWriteJson(this.featureMarker(feature), { version: 1 });
    });
    this.markerWrites = write.catch(() => {});
    await write;
  }

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
    if (this.release === release) this.release = undefined;
  }
}
