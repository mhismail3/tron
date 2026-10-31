import assert from "node:assert/strict";
import { createHash } from "node:crypto";
import { cp, lstat, mkdir, open, readFile, readdir, rename, rm } from "node:fs/promises";
import { dirname, join, relative, resolve } from "node:path";
import { DatabaseSync } from "node:sqlite";
import { durableAtomicWriteJson, syncDurably } from "../foundation/durable-json.js";
import { TronWorkspace } from "../workspace/tron-workspace.js";
import { acquireAgentRuntimeLocks } from "../sessions/agent-runtime-lock.js";
import { ProfileStore } from "../modules/home/profile-store.js";
import { homeProfileSection, readHomeProfile, profileListItem } from "../modules/home/home-profile.js";
import { profileFileRecords, validateProfileFile, writeProfileFile } from "../modules/home/profile-file.js";

export const PROFILE_CUTOVER_BINDING = {
  source: "905e0510a6fbae727fdeb4cc3667d9a676fc3b99",
  preparation: "d32758370a03f4770a329a39433d0cd0146a840e2641e8b7a286dd1d25af66e1",
  manifest: "78f6b40ec280f9b8c309bc52a40847c8ac3aeb8fad36caab502b88bdd6789b40",
  candidate: "a18e8ea1277cf3f660bdf59065f3f719803cf3ad6a0a08f50457cb25a555b6bb",
  heads: 60,
};
export const PROFILE_BACKUP_NAME = "2138-profile-cutover-20261031T180029Z";
export type CutoverBinding = typeof PROFILE_CUTOVER_BINDING;
export interface CutoverLifecycle {
  stop(): Promise<void>;
  start(): Promise<void>;
  rpc(method: string, params: Record<string, unknown>): Promise<unknown>;
}
type Files = Record<string, { sha256: string; mode?: string }>;
type Receipt = { phase: string; candidate: string; manifest: string };
const digest = (bytes: string | Uint8Array) => createHash("sha256").update(bytes).digest("hex");
const exists = async (path: string) => lstat(path).then(() => true, error => { if (error.code === "ENOENT") return false; throw error; });
async function privateBytes(path: string, expectedMode = 0o600): Promise<Buffer> {
  const info = await lstat(path);
  assert([0o600, 0o644].includes(expectedMode), "Unsupported pinned source mode");
  assert(info.isFile() && !info.isSymbolicLink() && info.uid === process.getuid?.() && (info.mode & 0o777) === expectedMode && info.size <= 64 * 1_048_576,
    `Unsafe or oversized cutover input: ${path} (mode 0o${(info.mode & 0o777).toString(8)}; expected 0o${expectedMode.toString(8)})`);
  return readFile(path);
}
async function tree(root: string, pinnedModes?: Files): Promise<Record<string, string>> {
  const files: Record<string, string> = {};
  async function walk(path: string): Promise<void> {
    const info = await lstat(path);
    assert(!info.isSymbolicLink() && info.uid === process.getuid?.(), "Unsafe cutover tree");
    if (info.isDirectory()) {
      assert.equal(info.mode & 0o777, 0o700);
      for (const name of (await readdir(path)).sort()) await walk(join(path, name));
    } else {
      const name = relative(root, path), mode = pinnedModes?.[name]?.mode;
      files[name] = digest(await privateBytes(path, mode === undefined ? 0o600 : Number(mode)));
    }
  }
  await walk(root); return files;
}
function child(root: string, name: string): string {
  assert(!name.startsWith("/") && !name.split("/").some(part => !part || part === "." || part === ".."), "Unsafe manifest path");
  return join(root, name);
}
async function syncDirectory(path: string): Promise<void> {
  const fd = await open(path, "r"); try { await syncDurably(fd); } finally { await fd.close(); }
}
async function syncTree(path: string): Promise<void> {
  const info = await lstat(path);
  if (info.isDirectory()) {
    for (const name of await readdir(path)) await syncTree(join(path, name));
  }
  await syncDirectory(path); // same durable fsync owner for files and directories
}
function sqlRows(db: DatabaseSync): unknown {
  assert.equal(db.prepare("PRAGMA integrity_check").get()!.integrity_check, "ok");
  return [db.prepare("SELECT name,sql FROM sqlite_master WHERE type='table' ORDER BY name").all(),
    db.prepare("SELECT id,value FROM control ORDER BY id").all(), db.prepare("SELECT collection,key,value FROM entries ORDER BY collection,key").all()];
}

/** Dedicated one-shot migration. The caller owns coordinated lifecycle; this owner
 * holds the same canonical runtime/workspace leases as Gateway throughout effects. */
export class ProfileCutover {
  private constructor(readonly home: string, readonly backup: string, readonly operation: string,
    readonly binding: CutoverBinding, private readonly candidate: ReturnType<typeof validateProfileFile>,
    private readonly sourceFiles: { profile: Files; changes: Files }, private readonly backupFiles: Files) {}

  static async prepare(home: string, backup: string, operation: string, binding: CutoverBinding): Promise<ProfileCutover> {
    home = resolve(home); backup = resolve(backup); operation = resolve(operation);
    assert(!(await lstat(backup)).isSymbolicLink());
    const preparationBytes = await privateBytes(join(backup, "preparation-manifest.json"));
    assert.equal(digest(preparationBytes), binding.preparation, "Preparation hash mismatch");
    const preparation = JSON.parse(preparationBytes.toString()) as { sourceCommit: string; files: Files };
    assert.equal(preparation.sourceCommit, binding.source, "Source identity mismatch");
    for (const [name, metadata] of Object.entries(preparation.files)) {
      assert.equal(digest(await privateBytes(child(backup, name))), metadata.sha256, `Backup input hash mismatch: ${name}`);
    }
    // Checking the full tree also refuses symlinked intermediate directories.
    await tree(backup);
    const manifestBytes = await privateBytes(join(backup, "full-backup-manifest.json"));
    assert.equal(digest(manifestBytes), binding.manifest, "Backup manifest mismatch");
    const manifest = JSON.parse(manifestBytes.toString()) as { files: Files };
    const candidateBytes = await privateBytes(join(backup, "Profile.complete-candidate.json"));
    assert.equal(digest(candidateBytes), binding.candidate, "Candidate hash mismatch");
    const candidate = validateProfileFile(JSON.parse(candidateBytes.toString()));
    const snapshot = JSON.parse((await privateBytes(join(backup, "Profile.complete-export.snapshot.json"))).toString()) as {
      notes: Array<{ head: { latestRevisionId: string }; history: ReturnType<typeof profileFileRecords> }>;
      collections: { receipts: Array<[string, { operation: string; requestHash: string }]>; suppressions: unknown[]; scopeExclusions: unknown[]; cleanup: unknown[]; recordCleanup: unknown[] };
    };
    const heads = snapshot.notes.map(note => note.history.find(record => record.revisionId === note.head.latestRevisionId)!);
    assert.equal(heads.length, binding.heads); assert(heads.every(Boolean));
    const byId = (a: { id: string }, b: { id: string }) => a.id.localeCompare(b.id);
    assert.deepEqual(profileFileRecords(candidate).sort(byId), heads.sort(byId), "Current-head conservation failed");
    for (const collection of [snapshot.collections.suppressions, snapshot.collections.scopeExclusions, snapshot.collections.cleanup, snapshot.collections.recordCleanup]) assert.equal(collection.length, 0, "Unexpected privacy/cleanup state for this bound cutover");
    assert.equal(Object.keys(candidate.control.commands).length, snapshot.collections.receipts.length);
    for (const [key, receipt] of snapshot.collections.receipts) {
      assert.equal(candidate.control.commands[key]?.operation, receipt.operation);
      assert.equal(candidate.control.commands[key]?.requestHash, receipt.requestHash);
    }
    const sourceFiles = JSON.parse((await privateBytes(join(backup, "fresh-source-inventory.json"))).toString()) as { profile: Files; changes: Files };
    return new ProfileCutover(home, backup, operation, binding, candidate, sourceFiles, manifest.files);
  }
  private get legacy(): string { return join(this.home, "workspace/state/profile"); }
  private get published(): string { return join(this.home, "workspace/files/Profile.json"); }
  private get journal(): string { return join(this.home, "gateway/settings/changes"); }
  private get preserved(): string { return join(this.operation, "legacy"); }
  private async receipt(phase: string): Promise<void> {
    await durableAtomicWriteJson(join(this.operation, "receipt.json"), { phase, candidate: this.binding.candidate, manifest: this.binding.manifest });
  }
  private expected(prefix: string, files: Files): Record<string, string> {
    return Object.fromEntries(Object.entries(files).filter(([name]) => !prefix || name.startsWith(prefix)).map(([name, value]) => [prefix ? name.slice(prefix.length) : name, value.sha256]));
  }
  // Only the original, hash-bound live journal modes may differ from backup 0600.
  // Every enclosing directory remains owner-only 0700; never chmod live state.
  private async journalUnchanged(): Promise<void> { assert.deepEqual(await tree(this.journal, this.sourceFiles.changes), this.expected("", this.sourceFiles.changes), "Changes changed; refusing destructive rollback"); }
  private async namespaceUnchanged(): Promise<void> {
    const namespace = JSON.parse((await privateBytes(join(this.backup, "namespace-manifest.json"))).toString()) as { namespace: Record<string, { present: boolean; sha256?: string }> };
    for (const name of ["gateway/workspace-state/initialized.json", "gateway/workspace-state/profile-initialized.json"]) {
      const value = namespace.namespace[name]!; assert(value.present);
      assert.equal(digest(await privateBytes(child(this.home, name))), value.sha256, "Initialization marker changed");
    }
  }
  private async leased<T>(action: (workspace: TronWorkspace) => Promise<T>): Promise<T> {
    assert((await lstat(join(this.home, "agent"))).isDirectory(), "Canonical agent directory missing");
    const release = await acquireAgentRuntimeLocks([join(this.home, "agent")]);
    const workspace = new TronWorkspace(this.home);
    try {
      await workspace.initialize(); assert((await workspace.describe()).available, "Workspace writer lease unavailable");
      await this.namespaceUnchanged(); return await action(workspace);
    } finally { await workspace.dispose(); await release(); }
  }
  private async restore(): Promise<void> {
    await this.journalUnchanged();
    if (await exists(this.published)) assert.equal(digest(await privateBytes(this.published)), this.binding.candidate, "Profile changed after publication; keep it and reconcile forward, never overwrite new writes");
    assert(!(await exists(this.legacy)), "Legacy destination exists; refusing overwrite");
    assert(await exists(this.preserved), "Preserved original namespace missing");
    const staging = join(this.operation, "restore-stage");
    assert(!(await exists(staging)), "Restore stage exists; inspect interrupted recovery");
    await cp(join(this.backup, "profile"), staging, { recursive: true, errorOnExist: true, force: false });
    assert.deepEqual(await tree(staging), this.expected("profile/", this.backupFiles));
    const dbName = Object.keys(this.sourceFiles.profile).find(name => name.endsWith(".sqlite"))!;
    const restoredDb = new DatabaseSync(join(staging, dbName), { readOnly: true }), backupDb = new DatabaseSync(join(this.backup, "profile", dbName), { readOnly: true });
    try { assert.deepEqual(sqlRows(restoredDb), sqlRows(backupDb)); } finally { restoredDb.close(); backupDb.close(); }
    await syncTree(staging);
    if (await exists(this.published)) await rm(this.published);
    await syncDirectory(dirname(this.published)); await rename(staging, this.legacy); await syncDirectory(dirname(this.legacy));
    assert.deepEqual(await tree(this.legacy), this.expected("profile/", this.backupFiles));
    await this.namespaceUnchanged(); await this.receipt("rolled-back");
  }
  private async apply(): Promise<void> {
    assert(!(await exists(this.operation)), "Cutover already attempted; inspect receipt or use --rollback");
    assert(!(await exists(this.published)), "Profile.json already exists");
    assert.deepEqual(await tree(this.legacy), this.expected("", this.sourceFiles.profile), "Live Profile source hash mismatch");
    await this.journalUnchanged();
    await mkdir(this.operation, { recursive: true, mode: 0o700 }); await this.receipt("prepared");
    const dbName = Object.keys(this.sourceFiles.profile).find(name => name.endsWith(".sqlite"))!;
    const legacyDb = new DatabaseSync(join(this.legacy, dbName)); let transaction = false;
    try {
      // Also excludes a legacy SQLite writer; no DML or schema changes are issued.
      legacyDb.exec("BEGIN EXCLUSIVE"); transaction = true;
      const backupDb = new DatabaseSync(join(this.backup, "profile", dbName), { readOnly: true });
      try { assert.deepEqual(sqlRows(legacyDb), sqlRows(backupDb)); } finally { backupDb.close(); }
      await rename(this.legacy, this.preserved); await syncDirectory(dirname(this.legacy)); await syncDirectory(this.operation);
      await this.receipt("preserved");
      await writeProfileFile({ describe: () => TronWorkspace.describeExisting(this.home) }, this.candidate);
      assert.equal(digest(await privateBytes(this.published)), this.binding.candidate);
      await this.receipt("published");
    } finally { try { if (transaction) legacyDb.exec("ROLLBACK"); } finally { legacyDb.close(); } }
  }
  /** Read-only live-file inspection uses the existing-path descriptor, never a second workspace owner. */
  async inspect(): Promise<{ items: ReturnType<typeof profileListItem>[]; index: string; groups: string[] }> {
    assert.equal(digest(await privateBytes(this.published)), this.binding.candidate, "Published Profile changed");
    const store = new ProfileStore({ describe: () => TronWorkspace.describeExisting(this.home),
      featureInitialized: () => TronWorkspace.featureInitializedExisting(this.home, "profile"),
      markFeatureInitialized: async () => { throw new Error("Read-only cutover inspection"); } });
    const read = await readHomeProfile(store); assert.equal(read.items.length, this.binding.heads);
    const section = await homeProfileSection(() => store, "user"); assert(section.text.length > 0);
    for (const record of profileFileRecords(this.candidate)) assert.deepEqual(await store.read(record.id, record.revisionId), record);
    const groups = new Set<string>();
    for (const name of Object.keys(this.sourceFiles.changes).filter(name => name.endsWith(".jsonl"))) {
      for (const line of (await privateBytes(join(this.backup, "changes", name))).toString().trim().split("\n").filter(Boolean)) {
        const entry = JSON.parse(line) as { key: string; status: string; group?: { id: string } };
        if (entry.key === "home.profile.item" && entry.status === "applied" && entry.group) groups.add(entry.group.id);
      }
    }
    assert.equal(digest(await privateBytes(this.published)), this.binding.candidate);
    return { items: read.items.map(profileListItem), index: section.text, groups: [...groups] };
  }
  async run(lifecycle: CutoverLifecycle, rollback = false): Promise<{ status: string; heads?: number; groups?: number }> {
    if (rollback) {
      const receipt = JSON.parse((await privateBytes(join(this.operation, "receipt.json"))).toString()) as Receipt;
      assert.equal(receipt.candidate, this.binding.candidate); assert.equal(receipt.manifest, this.binding.manifest);
      assert.notEqual(receipt.phase, "rolled-back", "Already rolled back");
    } else assert(!(await exists(this.operation)), "Already attempted; inspect receipt or use --rollback");
    await lifecycle.stop();
    try {
      await this.leased(async () => { if (rollback) await this.restore(); else await this.apply(); });
    } catch (error) {
      // Restore only our own partially published transaction; preflight failures have no effects.
      if (!rollback && await exists(this.preserved) && !(await exists(this.legacy))) await this.leased(() => this.restore());
      await lifecycle.start(); throw error;
    }
    if (rollback) { await lifecycle.start(); return { status: "rolled-back" }; }
    const startedAt = new Date().toISOString();
    try {
      await lifecycle.start(); const expected = await this.inspect();
      const listed = await lifecycle.rpc("home.profileList", {}) as { items: unknown[]; unclassified: number };
      assert.equal(listed.unclassified, 0); assert.deepEqual(listed.items, expected.items, "Live Profile read mismatch");
      const groups = new Set<string>(); let cursor: string | undefined;
      do {
        const page = await lifecycle.rpc("settings.history", { key: "home.profile.item", status: "applied", limit: 200, ...(cursor ? { cursor } : {}) }) as { entries: Array<{ group?: { id: string } }>; nextCursor?: string };
        for (const entry of page.entries) if (entry.group) groups.add(entry.group.id); cursor = page.nextCursor;
      } while (cursor);
      for (const group of expected.groups) assert(groups.has(group), "Prior shared Changes/Undo group missing");
      const logs = await lifecycle.rpc("system.logs", { limit: 1_000 }) as { records: Array<{ timestamp: string; level: string }> };
      assert(!logs.records.some(record => record.timestamp >= startedAt && ["warning", "error"].includes(record.level) && /profile/i.test(JSON.stringify(record))), "Profile errors in new Gateway logs");
      await this.inspect(); await this.receipt("verified");
      return { status: "verified", heads: expected.items.length, groups: expected.groups.length };
    } catch (error) {
      await lifecycle.stop(); await this.leased(() => this.restore()); await lifecycle.start();
      throw new Error("Cutover live check failed; backup restored byte-exactly and Gateway restarted", { cause: error });
    }
  }
}
