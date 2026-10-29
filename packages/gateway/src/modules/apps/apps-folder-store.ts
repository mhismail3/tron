import { createHmac, randomBytes, randomUUID, timingSafeEqual } from "node:crypto";
import { lstat, mkdir, open, rename, rm } from "node:fs/promises";
import { dirname, join } from "node:path";
import { asUncertainOutcome, GatewayError } from "../../errors.js";
import { AsyncMutex } from "../../util/async-mutex.js";
import { durableAtomicWriteJson, syncDurably } from "../../util/durable-json.js";
import { readSecureJson } from "../../util/secure-json.js";
import type { TronWorkspace } from "../../workspace/tron-workspace.js";
import { AppDataStore, type AppDataCommit } from "./app-data-store.js";
import { AppsFolderIndex } from "./apps-folder-index.js";
import { APP_ID, readAppEntry, type AppEntry, type AppPermissions } from "./apps-folder-format.js";
import { readIOSBuildsFeed } from "./ios-builds-feed.js";

interface Grant { version: 1; executableDigest: string; identity: string; permissions: AppPermissions; revision: string; device: string }
interface Consent { id: string; contentRevision: string; executableDigest: string; identity: string; device: string; expires: number }
/** One mutation lane owns data admission with file/grant changes. Signed prompt
 * tokens are process-local, bounded, expiring and never an agent capability. */
export class AppsFolderStore {
  readonly index: AppsFolderIndex;
  private readonly data: AppDataStore;
  private readonly mutex = new AsyncMutex();
  private readonly signingKey = randomBytes(32);
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
  private async grantFor(entry: AppEntry): Promise<Grant | undefined> {
    try {
      const raw = await readSecureJson<unknown>(await this.permissionPath(entry.name), 8192);
      if (!raw.present || !raw.value || typeof raw.value !== "object") return undefined;
      const grant = raw.value as Grant;
      return grant.version === 1 && grant.executableDigest === entry.executableDigest && grant.identity === entry.identity
        && JSON.stringify(grant.permissions) === JSON.stringify(entry.permissions) && typeof grant.revision === "string" && typeof grant.device === "string"
        ? grant : undefined;
    } catch { return undefined; } // Unsafe/corrupt grants confer no authority.
  }
  private needsAccess(entry: AppEntry): boolean {
    return entry.permissions.data !== "none" || entry.permissions.feeds.length > 0 || entry.permissions.network.length > 0;
  }
  private token(consent: Consent): string {
    const payload = Buffer.from(JSON.stringify(consent)).toString("base64url");
    return `${payload}.${createHmac("sha256", this.signingKey).update(payload).digest("base64url")}`;
  }
  private readToken(token: string, device: string): Consent {
    if (token.length > 4096) throw new GatewayError("invalid_request", "Invalid access prompt");
    const [payload, signature, extra] = token.split(".");
    if (!payload || !signature || extra) throw new GatewayError("invalid_request", "Invalid access prompt");
    const expected = createHmac("sha256", this.signingKey).update(payload).digest();
    const supplied = Buffer.from(signature, "base64url");
    if (expected.length !== supplied.length || !timingSafeEqual(expected, supplied)) throw new GatewayError("auth_required", "Access prompt expired; open again");
    const consent = JSON.parse(Buffer.from(payload, "base64url").toString()) as Consent;
    if (consent.device !== device || consent.expires < Date.now()) throw new GatewayError("auth_required", "Access prompt expired; open again");
    return consent;
  }
  async open(id: string, contentRevision: string, device: string) {
    return this.mutex.run(async () => {
      const entry = await this.index.requireEntry(id, contentRevision), grant = await this.grantFor(entry);
      if (this.needsAccess(entry) && !grant) {
        return { kind: "permissionRequired", row: entry.row, permissions: entry.permissions, token: this.token({ id, contentRevision,
          executableDigest: entry.executableDigest, identity: entry.identity, device, expires: Date.now() + 10 * 60_000 }) };
      }
      const state = entry.permissions.data === "none" ? { appId: id, revision: 0, entries: [] } : await this.data.state(id);
      const feeds = entry.permissions.feeds.includes("ios-builds") ? { "ios-builds": await readIOSBuildsFeed(this.tronHome) } : {};
      // Feed/data awaits cannot extend authority across an external replacement.
      await this.index.requireEntry(id, contentRevision);
      return { kind: entry.row.kind, row: entry.row, source: entry.files.get(entry.entry!)!.toString("utf8"), permissions: entry.permissions,
        state, feeds, grantRevision: grant?.revision ?? null };
    });
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
  async deleteFiles(rowKey: string, expectedContentRevision: string) {
    return this.mutex.run(async () => {
      // Row keys bind directory identity, including broken foreign basenames.
      await this.index.reconcile();
      const files = await this.workspace.filesRoot(), root = join(files, "apps");
      const entry = await this.index.entryForDeletion(rowKey);
      const current = await readAppEntry(root, entry.name);
      if (current.row.rowKey !== rowKey || current.row.contentRevision !== expectedContentRevision) throw new GatewayError("conflict", "Entry changed; refresh before deleting", true, { reason: "entry_changed" });
      const staging = join(files, ".apps-staging");
      try { await mkdir(staging, { mode: 0o700 }); } catch (error) { if ((error as NodeJS.ErrnoException).code !== "EEXIST") throw error; }
      const info = await lstat(staging);
      if (!info.isDirectory() || info.isSymbolicLink() || info.uid !== process.getuid?.() || (info.mode & 0o777) !== 0o700) throw new GatewayError("conflict", "Unsafe Apps staging directory");
      const retired = join(staging, randomUUID());
      await rename(join(root, entry.name), retired);
      try {
        const renamed = await lstat(retired);
        if (`${renamed.dev}:${renamed.ino}:${renamed.birthtimeMs}` !== entry.identity) {
          throw new GatewayError("conflict", "An external replacement raced deletion; its files are retained in Apps staging");
        }
        // Renaming a symlink never follows or deletes its target.
        if (APP_ID.test(entry.name)) await this.removeGrant(entry.name);
        for (const path of [root, staging]) {
          const directory = await open(path, "r");
          try { await syncDurably(directory); } finally { await directory.close(); }
        }
        await rm(retired, { recursive: true, force: true });
        await this.index.refreshAll();
      } catch (error) { throw asUncertainOutcome(error, "App file deletion could not be verified"); }
      return { rowKey, deleted: true };
    });
  }
  async dispose(): Promise<void> { await this.index.dispose(); }
}
