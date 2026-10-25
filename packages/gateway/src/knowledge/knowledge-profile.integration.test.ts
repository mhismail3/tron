import { mkdir, mkdtemp, readFile, readdir, rm, stat, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { afterEach, expect, it } from "vitest";
import { TronWorkspace } from "../workspace/tron-workspace.js";
import { KnowledgeStore } from "./knowledge-store.js";
import { boundedProfilePartition, crashProfilePartition } from "../../test-support/profile-partition-crash.js";
import { profileFileTags, type ProfileAssignment } from "./knowledge-notes.js";
import type { KnowledgeRecord } from "./knowledge-contract.js";

const fixtures: Array<{ root: string; workspace: TronWorkspace }> = [];
afterEach(async () => { for (const f of fixtures.splice(0)) { await f.workspace.dispose(); await rm(f.root, { recursive: true, force: true }); } });
async function fixture() {
  const root = await mkdtemp(join(tmpdir(), "tron-profile-partition-"));
  const workspace = new TronWorkspace(join(root, "home")); fixtures.push({ root, workspace });
  await workspace.initialize();
  const store = new KnowledgeStore(workspace);
  const records = [];
  for (let index = 0; index < 21; index++) {
    const created = await store.createNote({ commandId: `partition-create-${index}`, record: { kind: "note", scope: "personal", provenance: { actor: index % 2 ? "agent" : "user", source: "partition-fixture", evidence: index === 2 ? [{ recordId: records[0]!.id, revisionId: records[0]!.revisionId }] : [], reason: `original ${index}` }, relations: index === 3 ? [{ type: "supersedes", recordId: records[1]!.id, revisionId: records[1]!.revisionId }] : [], content: { title: `Exact profile text ${index}.`, body: `Complete body ${index}.\nDo not truncate this history.`, role: index % 2 ? "preference" : "decision", confirmed: index % 2 === 0, ...(index % 7 === 0 ? { retired: true } : {}), tags: ["home-profile", index % 2 ? "kind-preference" : "kind-standing-decision", "fixture-label"] } } });
    const draft = created.record;
    if (draft.kind !== "note") throw new Error("Expected note");
    records.push((await store.updateNote({ commandId: `partition-history-${index}`, recordId: draft.id, expectedRevision: draft.revisionId, record: { ...draft, content: { ...draft.content, body: draft.content.body + "\nSecond edition." } } })).record);
  }
  const assignments: ProfileAssignment[] = records.map((note, index) => ({ id: note.id, expectedRevision: note.revisionId, file: index < 10 ? "core" : index < 20 ? "home" : "scopes/ui" }));
  return { root, workspace, store, records, assignments };
}

it("backs up complete histories before label-only migration; replay/reopen retain every exact value", async () => {
  const f = await fixture();
  const result = await f.store.partitionProfile({ commandId: "partition-migrate-one", mode: "migrate", assignments: f.assignments });
  if (!result.backup) throw new Error("Migration must publish its backup");
  const backup = JSON.parse(await readFile(result.backup, "utf8")) as { originals: Array<{ record: KnowledgeRecord; history: KnowledgeRecord[] }> };
  expect((await stat(result.backup)).mode & 0o777).toBe(0o600);
  expect(backup.originals).toHaveLength(21);
  for (const [index, original] of f.records.entries()) {
    const saved = backup.originals.find(item => item.record.id === original.id)!;
    expect(saved.record).toEqual(original);
    expect(saved.history).toHaveLength(2);
    expect(saved.history[1]).toEqual(original);
    const after = await f.store.read(original.id);
    if (original.kind !== "note" || after?.kind !== "note") throw new Error("Missing note");
    expect(after).toEqual({ ...original, revisionId: after.revisionId, content: { ...original.content, tags: profileFileTags(original.content.tags ?? [], f.assignments[index]!.file) } });
    expect(after.revisionId).not.toBe(original.revisionId);
    for (const historical of saved.history) expect(await f.store.read(original.id, historical.revisionId)).toEqual(historical);
  }
  const heads = await Promise.all(f.records.map(note => f.store.read(note.id)));
  const repeat = await new KnowledgeStore(f.workspace).partitionProfile({ commandId: "partition-migrate-two", mode: "migrate", assignments: [...f.assignments].reverse().map(({ id, expectedRevision, file }) => ({ file, expectedRevision, id })) });
  expect(repeat).toEqual(result);
  expect(await Promise.all(f.records.map(note => f.store.read(note.id)))).toEqual(heads);
  const rescanned: ProfileAssignment[] = heads.map((note, index) => ({ id: note!.id, expectedRevision: note!.revisionId, file: f.assignments[index]!.file! }));
  expect(await f.store.partitionProfile({ commandId: "partition-rescanned", mode: "migrate", assignments: rescanned })).toEqual({ changes: [] });
  const directory = join(result.backup, "..", "..", "records");
  for (const note of f.records) expect(await readdir(join(directory, note.id))).toHaveLength(3);
  await mkdir("test-results/home-profile", { recursive: true });
  await writeFile("test-results/home-profile/migration-store.json", JSON.stringify({ notes: 21, historicalRevisions: 42, exactMetadataAndContentPreserved: true, extraRevisionsOnRepeat: 0, ownerOnlyBackup: true }, null, 2) + "\n");
});

const crashEvidence: Array<Record<string, unknown>> = [];
it.each(["before-backup", "after-backup", "mid-body", "precommit", "after-commit"])("recovers every canonical/body reference after a process crash at %s", async cut => {
  const f = await fixture();
  const home = join(f.root, "home");
  const root = join((await f.workspace.describe()).root, "state", "knowledge");
  await f.workspace.dispose();
  await crashProfilePartition(f.root, home, f.assignments, cut);
  const reopened = new TronWorkspace(home);
  fixtures.find(item => item.root === f.root)!.workspace = reopened;
  await reopened.initialize();
  const store = new KnowledgeStore(reopened);
  const heads = await Promise.all(f.records.map(note => store.read(note.id)));
  if (cut !== "after-commit") expect(heads).toEqual(f.records);
  else expect(heads.every((note, index) => note?.revisionId !== f.records[index]!.revisionId)).toBe(true);
  const backupFiles = (await readdir(join(root, "profile-backups"))).filter(name => name.endsWith(".json"));
  expect(backupFiles).toHaveLength(cut === "before-backup" ? 0 : 1);
  const prepared: KnowledgeRecord[] = backupFiles.length ? JSON.parse(await readFile(join(root, "profile-backups", backupFiles[0]!), "utf8")).prepared : [];
  let staged = 0;
  for (const original of f.records) {
    const files = await readdir(join(root, "records", original.id));
    for (const name of files) {
      const record = JSON.parse(await readFile(join(root, "records", original.id, name), "utf8")) as KnowledgeRecord;
      const planned = prepared.find(item => item.id === record.id && item.revisionId === record.revisionId);
      if (planned && cut !== "after-commit") {
        await expect(store.read(record.id, record.revisionId)).rejects.toThrow(/not committed/);
        expect(record).toEqual(planned);
      } else expect(record).toEqual(await store.read(record.id, record.revisionId));
      if (record.revisionId !== original.revisionId && prepared.some(item => item.id === original.id && item.revisionId === record.revisionId)) {
        expect(record).toEqual(prepared.find(item => item.id === record.id));
        staged++;
      }
    }
  }
  expect(staged).toBe(cut === "before-backup" || cut === "after-backup" ? 0 : cut === "mid-body" ? 7 : 21);
  const result = await store.partitionProfile({ commandId: "partition-resume-command", mode: "migrate", assignments: f.assignments });
  const after = await Promise.all(f.records.map(note => store.read(note.id)));
  expect(after.every((note, index) => note?.revisionId !== f.records[index]!.revisionId)).toBe(true);
  const beforeRetry = JSON.stringify(after);
  expect(await store.partitionProfile({ commandId: "partition-repeat-command", mode: "migrate", assignments: f.assignments })).toEqual(result);
  expect(JSON.stringify(await Promise.all(f.records.map(note => store.read(note.id))))).toBe(beforeRetry);
  for (const original of f.records) {
    expect(await store.read(original.id, original.revisionId)).toEqual(original);
    expect(await readdir(join(root, "records", original.id))).toHaveLength(3);
  }
  crashEvidence.push({ cut, notes: 21, stagedBodies: staged, allStagedBodiesReferencedByBackup: true, originalHeadsUnchangedUntilCommit: cut !== "after-commit", resumedWithoutExtraBodies: true, canonicalAuditUndo: "not yet integrated; store-only evidence" });
  await mkdir("test-results/home-profile", { recursive: true });
  await writeFile("test-results/home-profile/migration-crashes.json", JSON.stringify(crashEvidence, null, 2) + "\n");
});

it("a missing historical body refuses migration before any new record body or backup is published", async () => {
  const f = await fixture();
  const root = join((await f.workspace.describe()).root, "state", "knowledge");
  const first = f.records[0]!;
  const files = await readdir(join(root, "records", first.id));
  const historical = files.find(name => name !== `${first.revisionId}.json`)!;
  await rm(join(root, "records", first.id, historical));
  await expect(f.store.partitionProfile({ commandId: "partition-missing-history", mode: "migrate", assignments: f.assignments })).rejects.toThrow(/Record revision is missing/);
  expect(await Promise.all(f.records.map(note => f.store.read(note.id)))).toEqual(f.records);
  expect(await readdir(join(root, "profile-backups"))).toEqual([]);
  for (const note of f.records.slice(1)) expect(await readdir(join(root, "records", note.id))).toHaveLength(2);
});

it("a valid-JSON but altered backup cannot rewrite text or discard a historical revision", async () => {
  const f = await fixture();
  const result = await f.store.partitionProfile({ commandId: "partition-backup-original", mode: "migrate", assignments: f.assignments });
  if (!result.backup) throw new Error("Missing migration backup");
  const bytes = await readFile(result.backup, "utf8");
  const heads = await Promise.all(f.records.map(note => f.store.read(note.id)));
  const changedText = JSON.parse(bytes);
  changedText.prepared[0].content.title = "An unauthorized replacement.";
  await writeFile(result.backup, JSON.stringify(changedText));
  await expect(f.store.partitionProfile({ commandId: "partition-bad-text-backup", mode: "migrate", assignments: f.assignments })).rejects.toThrow(/more than partition labels/);
  expect(await Promise.all(f.records.map(note => f.store.read(note.id)))).toEqual(heads);
  const changedHistory = JSON.parse(bytes);
  changedHistory.originals[0].history.shift();
  await writeFile(result.backup, JSON.stringify(changedHistory));
  await expect(f.store.partitionProfile({ commandId: "partition-bad-history-backup", mode: "migrate", assignments: f.assignments })).rejects.toThrow(/history differs/);
  expect(await Promise.all(f.records.map(note => f.store.read(note.id)))).toEqual(heads);
  await writeFile(result.backup, bytes);
});

it("profile receipt references are invalidated by forget, and cannot resurrect or replay forgotten data", async () => {
  const f = await fixture();
  const request = { commandId: "partition-forget-original", mode: "migrate" as const, assignments: f.assignments };
  await f.store.partitionProfile(request);
  const id = f.records[0]!.id;
  const current = await f.store.read(id);
  await f.store.forget("partition-forget-target", id, "Explicit fixture forget", current!.revisionId);
  expect(await f.store.read(id)).toBeNull();
  await expect(f.store.partitionProfile(request)).rejects.toThrow(/forgotten/);
  await expect(f.store.partitionProfile({ ...request, commandId: "partition-after-forget" })).rejects.toMatchObject({ code: "conflict" });
  expect(await f.store.read(id)).toBeNull();
});

it("excluded members require an explicit eligibility decision rather than incomplete migration", async () => {
  const f = await fixture();
  const note = f.records[0]!;
  await f.store.setExclusion("partition-exclude-member", note.id, true, note.revisionId);
  await expect(f.store.partitionProfile({ commandId: "partition-with-excluded", mode: "migrate", assignments: f.assignments })).rejects.toThrow(/eligibility decision/);
  expect(await Promise.all(f.records.map(record => f.store.read(record.id, undefined, true)))).toEqual(f.records);
  const root = join((await f.workspace.describe()).root, "state", "knowledge");
  expect(await readdir(join(root, "profile-backups"))).toEqual([]);
});

it("streams and bounds deep histories before publishing backup or replacement bodies", async () => {
  const f = await fixture();
  let current = f.records[0]!;
  if (current.kind !== "note") throw new Error("Expected note");
  const body = "界".repeat(100_000);
  for (let index = 0; index < 235; index++) current = (await f.store.updateNote({ commandId: `partition-deep-history-${index}`, recordId: current.id, expectedRevision: current.revisionId, record: { ...current, kind: "note", content: { ...current.content, body } } })).record;
  const before = await Promise.all(f.records.map(note => f.store.read(note.id)));
  const assignments = f.assignments.map(item => item.id === current.id ? { ...item, expectedRevision: current.revisionId } : item);
  const workspaceRoot = (await f.workspace.describe()).root;
  const home = join(f.root, "home");
  await f.workspace.dispose();
  const outcome = await boundedProfilePartition(f.root, home, assignments);
  expect(outcome, outcome.stderr).toMatchObject({ code: 0, signal: null });
  expect(JSON.parse(outcome.stdout)).toMatchObject({ status: "refused", message: expect.stringMatching(/backup exceeds its bound/) });
  const workspace = new TronWorkspace(home);
  await workspace.initialize();
  try {
    const store = new KnowledgeStore(workspace);
    expect(await Promise.all(f.records.map(note => store.read(note.id)))).toEqual(before);
    expect((await workspace.describe()).root).toBe(workspaceRoot);
    const root = join(workspaceRoot, "state", "knowledge");
    expect(await readdir(join(root, "profile-backups"))).toEqual([]);
    let retainedRevisions = 0;
    for (const note of f.records) {
      const revisions = await readdir(join(root, "records", note.id));
      expect(revisions).toHaveLength(note.id === current.id ? 237 : 2);
      retainedRevisions += revisions.length;
    }
    await mkdir("test-results/home-profile", { recursive: true });
    await writeFile("test-results/home-profile/migration-bounds.json", JSON.stringify({ heapMiB: 96, historicalRecordCount: retainedRevisions, outcome: JSON.parse(outcome.stdout), canonicalHeadsUnchanged: true, backupPublished: false, replacementBodiesPublished: 0 }, null, 2) + "\n");
  } finally { await workspace.dispose(); }
});

it("refuses incomplete/stale plans and a later tag-cap overflow before any canonical head or body changes", async () => {
  const f = await fixture();
  await expect(f.store.partitionProfile({ commandId: "partition-incomplete", mode: "migrate", assignments: f.assignments.slice(1) })).rejects.toMatchObject({ code: "conflict" });
  const original = f.records.at(-1)!;
  if (original.kind !== "note") throw new Error("Expected note");
  const full = (await f.store.updateNote({ commandId: "partition-full-tags", recordId: original.id, expectedRevision: original.revisionId, record: { ...original, content: { ...original.content, tags: ["home-profile", "kind-standing-decision", "label-a", "label-b", "label-c", "label-d", "label-e", "label-f"] } } })).record;
  await expect(f.store.partitionProfile({ commandId: "partition-stale-plan", mode: "migrate", assignments: f.assignments })).rejects.toMatchObject({ code: "conflict" });
  const assignments = f.assignments.map(item => item.id === full.id ? { ...item, expectedRevision: full.revisionId } : item);
  const before = await Promise.all(f.records.map(note => f.store.read(note.id)));
  await expect(f.store.partitionProfile({ commandId: "partition-full-plan", mode: "migrate", assignments })).rejects.toThrow();
  expect(await Promise.all(f.records.map(note => f.store.read(note.id)))).toEqual(before);
  const state = join((await f.workspace.describe()).root, "state", "knowledge");
  for (const note of f.records.slice(0, -1)) expect(await readdir(join(state, "records", note.id))).toHaveLength(2);
});
