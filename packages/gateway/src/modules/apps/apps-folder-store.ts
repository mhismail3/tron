import { randomBytes, randomUUID } from "node:crypto";
import { lstat, mkdir, open, rm } from "node:fs/promises";
import { dirname, join } from "node:path";
import { asUncertainOutcome, GatewayError } from "../../errors.js";
import { AsyncMutex } from "../../util/async-mutex.js";
import type { ByteRange } from "../../util/byte-stream.js";
import type { AppOpenProjection } from "./apps-open-projection.js";
import { durableAtomicWriteJson, syncDurably } from "../../util/durable-json.js";
import { readSecureJson } from "../../util/secure-json.js";
import type { TronWorkspace } from "../../workspace/tron-workspace.js";
import { AppDataStore, type AppDataCommit } from "./app-data-store.js";
import { AppsFolderIndex } from "./apps-folder-index.js";
import { APP_ID, type ReadyAppEntry, type AppPermissions } from "./apps-folder-format.js";
import { readIOSBuildsFeed } from "./ios-builds-feed.js";

interface Grant { version: 1; executableDigest: string; identity: string; permissions: AppPermissions; revision: string; device: string }
interface Consent { id: string; contentRevision: string; executableDigest: string; identity: string; device: string; expires: number }
/** One mutation lane owns data admission with file/grant changes. One-use prompt
 * tokens are process-local, bounded, expiring and never an agent capability. */
export class AppsFolderStore {
  readonly index: AppsFolderIndex;
  private readonly data: AppDataStore;
  private readonly mutex = new AsyncMutex();
  private readonly prompts = new Map<string, Consent>();
  constructor(private readonly workspace: TronWorkspace, private readonly tronHome: string, changed?: (revision: string) => void) {
    this.index = new AppsFolderIndex(workspace, changed); this.data = new AppDataStore(workspace);
  }
  private async permissionPath(id: string, create = false): Promise<string> {
    if (!APP_ID.test(id)) throw new GatewayError("invalid_request", "Invalid app id");
    const descriptor = await this.workspace.describe();
    if (!descriptor.available) throw new GatewayError("conflict", "Tron workspace is unavailable");
    let path = descriptor.root;
    for (const part of ["state", "app-permissions"]) {
      path = join(path, part);
      if (create) {
        try { await mkdir(path, { mode: 0o700 }); }
        catch (error) { if ((error as NodeJS.ErrnoException).code !== "EEXIST") throw error; }
      }
      try {
        const info = await lstat(path);
        if (!info.isDirectory() || info.isSymbolicLink() || info.uid !== process.getuid?.() || (info.mode & 0o777) !== 0o700) throw new GatewayError("conflict", "Unsafe permissions directory");
      } catch (error) { if (create || (error as NodeJS.ErrnoException).code !== "ENOENT") throw error; }
    }
    return join(path, `${id}.json`);
  }
  private async grantFor(entry: ReadyAppEntry): Promise<Grant | undefined> {
    try {
      const raw = await readSecureJson<unknown>(await this.permissionPath(entry.name), 8192);
      if (!raw.present || !raw.value || typeof raw.value !== "object") return undefined;
      const grant = raw.value as Grant;
      return grant.version === 1 && grant.executableDigest === entry.executableDigest && grant.identity === entry.identity
        && JSON.stringify(grant.permissions) === JSON.stringify(entry.permissions) && typeof grant.revision === "string" && typeof grant.device === "string"
        ? grant : undefined;
    } catch { return undefined; } // Unsafe/corrupt grants confer no authority.
  }
  private needsAccess(entry: ReadyAppEntry): boolean {
    return entry.permissions.data !== "none" || entry.permissions.feeds.length > 0 || entry.permissions.network.length > 0;
  }
  private token(consent: Consent): string {
    for (const [token, prompt] of this.prompts) if (prompt.expires < Date.now()) this.prompts.delete(token);
    if (this.prompts.size >= 256) throw new GatewayError("busy", "Too many access prompts are pending; close them or wait for expiry", true);
    const token = randomBytes(32).toString("base64url");
    this.prompts.set(token, consent);
    return token;
  }
  private invalidatePrompts(id: string): void {
    for (const [token, prompt] of this.prompts) if (prompt.id === id) this.prompts.delete(token);
  }
  private readToken(token: string, device: string): Consent {
    const consent = this.prompts.get(token);
    if (!consent || consent.device !== device || consent.expires < Date.now()) throw new GatewayError("auth_required", "Access prompt expired; open again");
    // Consume before any await. A new command ID is not a new consent tap;
    // transport replay of the accepted command returns its original receipt.
    this.invalidatePrompts(consent.id);
    return consent;
  }
  async open(id: string, contentRevision: string, device: string): Promise<AppOpenProjection> {
    return this.mutex.run(async () => {
      const entry = await this.index.requireEntry(id, contentRevision), grant = await this.grantFor(entry);
      if (this.needsAccess(entry) && !grant) {
        return { kind: "permissionRequired", row: entry.row, permissions: entry.permissions, token: this.token({ id, contentRevision,
          executableDigest: entry.executableDigest, identity: entry.identity, device, expires: Date.now() + 10 * 60_000 }) };
      }
      if (entry.payload.kind === "artifact") return { kind: "artifact", row: entry.row, artifact: entry.payload.artifact };
      const state = entry.permissions.data === "none" ? { appId: id, revision: 0, entries: [] } : await this.data.state(id);
      const feeds = entry.permissions.feeds.includes("ios-builds") ? { "ios-builds": await readIOSBuildsFeed(this.tronHome) } : {};
      // Feed/data awaits cannot extend authority across an external replacement.
      await this.index.requireEntry(id, contentRevision);
      return { kind: "swift", row: entry.row, source: entry.payload.source.toString("utf8"), permissions: entry.permissions,
        state, feeds, grantRevision: grant?.revision ?? null };
    });
  }
  acquireArtifact(id: string, contentRevision: string, range?: ByteRange, signal?: AbortSignal) {
    return this.index.acquireArtifact(id, contentRevision, range, signal);
  }
  async grant(token: string, device: string) {
    return this.mutex.run(async () => {
      const consent = this.readToken(token, device), entry = await this.index.requireEntry(consent.id, consent.contentRevision);
      if (entry.executableDigest !== consent.executableDigest || entry.identity !== consent.identity) throw new GatewayError("conflict", "Entry changed; open again");
      const grant: Grant = { version: 1, executableDigest: entry.executableDigest, identity: entry.identity,
        permissions: entry.permissions, revision: randomUUID(), device };
      await durableAtomicWriteJson(await this.permissionPath(entry.name, true), grant);
      return { id: entry.name, grantRevision: grant.revision };
    });
  }
  private async removeGrant(id: string): Promise<void> {
    this.invalidatePrompts(id);
    const path = await this.permissionPath(id);
    await rm(path, { force: true });
    let directory;
    try { directory = await open(dirname(path), "r"); }
    catch (error) { if ((error as NodeJS.ErrnoException).code === "ENOENT") return; throw asUncertainOutcome(error, "Access revocation could not be verified"); }
    try { await syncDurably(directory); }
    catch (error) { throw asUncertainOutcome(error, "Access revocation could not be verified"); }
    finally { await directory.close(); }
  }
  async revoke(id: string) {
    return this.mutex.run(async () => {
      await this.removeGrant(id);
      return { id, revoked: true };
    });
  }
  async commit(input: AppDataCommit & { expectedContentRevision: string; grantRevision: string }) {
    return this.mutex.run(async () => {
      const entry = await this.index.requireEntry(input.appId, input.expectedContentRevision), grant = await this.grantFor(entry);
      if (entry.permissions.data !== "readWrite" || !grant || input.grantRevision !== grant.revision) throw new GatewayError("auth_required", "App write access expired; reopen it");
      return this.data.commit(input, async () => {
        const live = await this.index.requireEntry(input.appId, input.expectedContentRevision);
        const current = await this.grantFor(live);
        if (current?.revision !== input.grantRevision) throw new GatewayError("auth_required", "App write access expired; reopen it");
      });
    });
  }
  async listData(cursor?: string) {
    return this.mutex.run(async () => {
      const page = await this.data.list(cursor), ids = await this.index.membership(page.states.map(state => state.id));
      return { ...page, states: page.states.map(state => ({ ...state, orphan: !ids.has(state.id) })) };
    });
  }
  async managedState(id: string) { return this.mutex.run(() => this.data.state(id)); }
  async seedData(input: AppDataCommit) {
    // Agent data management is not app execution and confers no runtime grant.
    return this.mutex.run(() => this.data.commit(input, async () => {}));
  }
  async clearData(id: string, expectedRevision: number, confirmed: unknown) {
    if (confirmed !== true) throw new GatewayError("invalid_request", "Clearing saved app data requires separate explicit authorization");
    return this.mutex.run(() => this.data.reset(id, expectedRevision));
  }
  async deleteFiles(rowKey: string, expectedContentRevision: string): Promise<never> {
    return this.mutex.run(async () => {
      await this.index.reconcile();
      await this.index.validateRow(rowKey, expectedContentRevision);
      // Node's pathname rename has no compare-and-rename or no-replace restore.
      // Admission may refuse a stale request, but never moves any directory.
      // Keep the receipt-backed endpoint inert until its filesystem owner can
      // provide an atomic native transaction; do not mislabel relocation as CAS.
      throw new GatewayError("unsupported", "Delete Files is disabled until Apps has a race-safe filesystem transaction. No files or saved data were changed.");
    });
  }
  async dispose(): Promise<void> {
    // An open can hold this mutex while queued behind a publication source.
    this.index.stopPublications();
    await this.mutex.run(async () => { this.prompts.clear(); await this.index.dispose(); });
  }
}
