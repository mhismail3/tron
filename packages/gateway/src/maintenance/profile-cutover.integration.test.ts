import { afterEach, expect, it } from "vitest";
import { createHash } from "node:crypto";
import { chmod, cp, lstat, mkdir, mkdtemp, readFile, readdir, rm, writeFile } from "node:fs/promises";
import { join, relative } from "node:path";
import { tmpdir } from "node:os";
import { DatabaseSync } from "node:sqlite";
import { fauxAssistantMessage } from "@earendil-works/pi-ai";
import { startLockGateway, type LockGateway, type LockClient } from "../../test-support/gateway-lock-harness.js";
import { workspaceModule } from "../workspace/workspace-module.js";
import { ProfileStore } from "../modules/home/profile-store.js";
import { GatewayLogger } from "../transport/logger.js";
import { readProfileFile, profileFileRecords } from "../modules/home/profile-file.js";
import { acquireAgentRuntimeLocks } from "../sessions/agent-runtime-lock.js";
import { ProfileCutover, type CutoverBinding, type CutoverLifecycle } from "./profile-cutover.js";

const sha = (bytes: Uint8Array | string) => createHash("sha256").update(bytes).digest("hex");
const roots: string[] = [];
let gateway: LockGateway | undefined, client: LockClient | undefined, releaseRuntime: (() => Promise<void>) | undefined;
const options = { knowledge: true, home: { memorySummarizer: () => async () => fauxAssistantMessage("Summary.") } };
async function start(root?: string): Promise<void> {
  gateway = await startLockGateway("profile-cutover", { ...options, logger: new GatewayLogger(), ...(root ? { root } : {}) });
  releaseRuntime = await acquireAgentRuntimeLocks([gateway.agentDir]);
  client = await gateway.connect("cutover-maintainer");
}
async function stop(): Promise<void> {
  if (gateway) { const current = gateway; gateway = undefined; await current.dispose({ keepRoot: true }); }
  await releaseRuntime?.(); releaseRuntime = undefined; client = undefined;
}
afterEach(async () => { await stop(); for (const root of roots.splice(0)) await rm(root, { recursive: true, force: true }); });
async function put(path: string, value: unknown): Promise<void> {
  await mkdir(join(path, ".."), { recursive: true, mode: 0o700 });
  await writeFile(path, JSON.stringify(value, null, 2) + "\n", { mode: 0o600 });
}
async function tree(root: string): Promise<Record<string, { sha256: string }>> {
  const result: Record<string, { sha256: string }> = {};
  async function walk(path: string): Promise<void> {
    for (const entry of await readdir(path, { withFileTypes: true })) {
      const child = join(path, entry.name);
      if (entry.isDirectory()) await walk(child); else result[relative(root, child)] = { sha256: sha(await readFile(child)) };
    }
  }
  await walk(root); return result;
}

it("bound offline cutover uses real writer leases and real Gateway reads; a lost verification socket restores exact backup bytes", async () => {
  await start(); const root = gateway!.root, home = gateway!.tronHome; roots.push(root);
  const workspace = gateway!.registry.moduleHost.contract(workspaceModule), store = new ProfileStore(workspace);
  const originals = [];
  for (let i = 0; i < 60; i++) originals.push((await store.createNote({ commandId: `cutover-create-${i}`, record: { kind: "note", scope: "personal",
    provenance: { actor: "user", source: "fixture", evidence: [] }, relations: [],
    content: { title: `Current statement ${i}`, role: "fact", confirmed: true, tags: ["home-profile", "kind-fact"], profile: { version: 2, path: ["engineering", `part-${Math.floor(i / 30)}`] } } } })).record);
  const change = await client!.request("home.profileChange", { commandId: "cutover-grouped-refine", changes: originals.slice(0, 2).map(record => ({ action: "refine", id: record.id, expectedRevision: record.revisionId, text: record.content.title + " revised" })) });
  expect(change.ok).toBe(true);
  const file = (await readProfileFile(workspace))!, heads = profileFileRecords(file), backup = join(root, "backup");
  const journalRoot = join(home, "gateway/settings/changes");
  const segment = (await readdir(journalRoot)).find(name => name.endsWith(".jsonl"))!;
  // Historical live segments are 0644 beneath private 0700 directories; retained backups are 0600.
  await chmod(join(journalRoot, segment), 0o644);
  const journalBefore = await tree(journalRoot);
  const journalSource = Object.fromEntries(await Promise.all(Object.entries(journalBefore).map(async ([name, value]) =>
    [name, { ...value, mode: "0o" + ((await lstat(join(journalRoot, name))).mode & 0o777).toString(8) }])));
  await stop();
  const legacy = join(home, "workspace/state/profile"); await mkdir(legacy, { recursive: true, mode: 0o700 });
  const histories = heads.map(head => ({ id: head.id, head: { latestRevisionId: head.revisionId, revisionIds: [...new Set([originals.find(r => r.id === head.id)!.revisionId, head.revisionId])] },
    history: [originals.find(r => r.id === head.id)!, ...(head.revisionId === originals.find(r => r.id === head.id)!.revisionId ? [] : [head])] }));
  const db = new DatabaseSync(join(legacy, "catalog-fixture.sqlite"));
  db.exec("CREATE TABLE control(id INTEGER PRIMARY KEY,value TEXT); CREATE TABLE entries(collection TEXT,key TEXT,value TEXT,PRIMARY KEY(collection,key)) WITHOUT ROWID");
  db.prepare("INSERT INTO control VALUES(1,?)").run(JSON.stringify({ config: file.control.config, stateRevision: file.stateRevision }));
  const insert = db.prepare("INSERT INTO entries VALUES(?,?,?)");
  for (const note of histories) {
    insert.run("records", JSON.stringify(note.id), JSON.stringify(note.head));
    for (const record of note.history) await put(join(legacy, "records", record.id, record.revisionId + ".json"), record);
  }
  for (const [key, receipt] of Object.entries(file.control.commands)) insert.run("receipts", JSON.stringify(key), JSON.stringify(receipt));
  db.close();
  // Node SQLite follows umask; this fixture deliberately uses the private owning format.
  await chmod(join(legacy, "catalog-fixture.sqlite"), 0o600);
  await rm(join(home, "workspace/files/Profile.json"));
  await mkdir(backup, { mode: 0o700 }); await cp(legacy, join(backup, "profile"), { recursive: true }); await cp(join(home, "gateway/settings/changes"), join(backup, "changes"), { recursive: true });
  await chmod(join(backup, "changes", segment), 0o600);
  const files = { ...Object.fromEntries(Object.entries(await tree(join(backup, "profile"))).map(([k, v]) => ["profile/" + k, v])),
    ...Object.fromEntries(Object.entries(await tree(join(backup, "changes"))).map(([k, v]) => ["changes/" + k, v])) };
  await put(join(backup, "full-backup-manifest.json"), { files });
  await put(join(backup, "fresh-source-inventory.json"), { profile: await tree(legacy), changes: journalSource });
  await put(join(backup, "namespace-manifest.json"), { namespace: Object.fromEntries(await Promise.all(["gateway/workspace-state/initialized.json", "gateway/workspace-state/profile-initialized.json"].map(async name => [name, { present: true, sha256: sha(await readFile(join(home, name))) }]))) });
  await put(join(backup, "Profile.complete-export.snapshot.json"), { notes: histories, collections: { receipts: Object.entries(file.control.commands), suppressions: [], scopeExclusions: [], cleanup: [], recordCleanup: [] } });
  await cp(join(root, "backup/profile"), join(root, "original-profile"), { recursive: true });
  await put(join(backup, "Profile.complete-candidate.json"), file);
  await put(join(backup, "preparation-manifest.json"), { sourceCommit: "fixture-source", files: await tree(backup) });
  const binding: CutoverBinding = { source: "fixture-source", heads: 60, preparation: sha(await readFile(join(backup, "preparation-manifest.json"))),
    manifest: sha(await readFile(join(backup, "full-backup-manifest.json"))), candidate: sha(await readFile(join(backup, "Profile.complete-candidate.json"))) };
  const baseline = await mkdtemp(join(tmpdir(), "tron-cutover-baseline-")); roots.push(baseline); await cp(root, baseline, { recursive: true });
  await expect(ProfileCutover.prepare(home, backup, join(root, "operation"), { ...binding, source: "wrong-source" })).rejects.toThrow(/Source identity/);
  await expect(ProfileCutover.prepare(home, backup, join(root, "operation"), { ...binding, candidate: "0".repeat(64) })).rejects.toThrow(/Candidate hash/);
  await expect(ProfileCutover.prepare(home, backup, join(root, "operation"), { ...binding, manifest: "0".repeat(64) })).rejects.toThrow(/manifest mismatch/);
  await chmod(join(backup, "changes", segment), 0o644);
  await expect(ProfileCutover.prepare(home, backup, join(root, "operation"), binding)).rejects.toThrow(/Unsafe or oversized/);
  await chmod(join(backup, "changes", segment), 0o600);
  await start(root);
  const owner = await ProfileCutover.prepare(home, backup, join(root, "operation"), binding);
  // A false 'zero workers/stopped' claim cannot defeat the actual runtime lease.
  await expect(owner.run({ stop: async () => {}, start: async () => {}, rpc: async () => { throw new Error("must not reach reads"); } })).rejects.toThrow(/already owns/);
  expect(await tree(legacy)).toEqual(await tree(join(backup, "profile")));
  const lifecycle: CutoverLifecycle = { stop, start: () => start(root), rpc: async (method, params) => {
    const response = await client!.request(method, params); if (!response.ok) throw new Error(JSON.stringify(response.error)); return response.result;
  } };
  await chmod(join(journalRoot, segment), 0o666);
  await expect(owner.run(lifecycle)).rejects.toThrow(/mode 0o666; expected 0o644/);
  expect(await tree(legacy)).toEqual(await tree(join(backup, "profile")));
  await chmod(join(journalRoot, segment), 0o644);
  expect(await owner.run(lifecycle)).toMatchObject({ status: "verified", heads: 60, groups: 1 });
  expect((await lstat(join(journalRoot, segment))).mode & 0o777).toBe(0o644);
  expect(await tree(join(home, "gateway/settings/changes"))).toEqual(journalBefore);
  expect(await owner.run(lifecycle, true)).toEqual({ status: "rolled-back" });
  expect(await tree(legacy)).toEqual(await tree(join(backup, "profile")));
  await stop();
  const failureRoot = await mkdtemp(join(tmpdir(), "tron-cutover-failure-")); roots.push(failureRoot); await cp(baseline, failureRoot, { recursive: true });
  await start(failureRoot);
  const failed = await ProfileCutover.prepare(gateway!.tronHome, join(failureRoot, "backup"), join(failureRoot, "operation"), binding);
  let dropped = false;
  const failingLifecycle: CutoverLifecycle = { stop, start: () => start(failureRoot), rpc: async (method, params) => {
    if (!dropped) { dropped = true; await stop(); }
    // The actual socket/runtime is gone, not a fabricated successful oracle.
    if (!client) throw new Error("Verification connection lost after real Gateway stop");
    const response = await client.request(method, params); if (!response.ok) throw new Error(JSON.stringify(response.error)); return response.result;
  } };
  await expect(failed.run(failingLifecycle)).rejects.toThrow(/backup restored byte-exactly/);
  expect(await tree(join(gateway!.tronHome, "workspace/state/profile"))).toEqual(await tree(join(failureRoot, "backup/profile")));
  expect(await tree(join(gateway!.tronHome, "gateway/settings/changes"))).toEqual(journalBefore);
  expect((await client!.request("home.profileList", {})).ok).toBe(false); // original offline feature, data preserved
}, 120_000);
