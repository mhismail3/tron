import { mkdir, mkdtemp, readFile, readdir, rm, stat, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { afterEach, expect, it } from "vitest";
import { TronWorkspace } from "../../workspace/tron-workspace.js";
import { ProfileStore } from "./profile-store.js";
import { boundedProfilePartition, crashProfilePartition } from "../../../test-support/profile-partition-crash.js";
import { profileFileTags, profileOperationKey, type ProfileAssignment } from "./profile-notes.js";
import { restoreLegacyProfileFixture } from "../../../test-support/profile-v1-fixture.js";
import type { ProfileNoteNoteMutationRequest, ProfileNoteRecord } from "./profile-note-contract.js";

const fixtures: Array<{ root: string; workspace: TronWorkspace }> = [];
afterEach(async () => { for (const f of fixtures.splice(0)) { await f.workspace.dispose(); await rm(f.root, { recursive: true, force: true }); } });
async function fixture(mode: "legacy" | "v2" | "migration" = "legacy") {
  const root = await mkdtemp(join(tmpdir(), "tron-profile-partition-"));
  const workspace = new TronWorkspace(join(root, "home")); fixtures.push({ root, workspace });
  await workspace.initialize();
  const store = new ProfileStore(workspace);
  const records = [];
  for (let index = 0; index < 21; index++) {
    const request: ProfileNoteNoteMutationRequest = { commandId: `partition-create-${index}`, record: { kind: "note", scope: "personal", provenance: { actor: index % 2 ? "agent" : "user", source: "partition-fixture", evidence: index === 2 ? [{ recordId: records[0]!.id, revisionId: records[0]!.revisionId }] : [], reason: `original ${index}` }, relations: mode !== "migration" && index === 3 ? [{ type: "supersedes", recordId: records[1]!.id, revisionId: records[1]!.revisionId }] : [], content: { title: `Exact profile text ${index}.`, body: `Complete body ${index}.\nDo not truncate this history.`, role: index % 2 ? "preference" : "decision", confirmed: index % 2 === 0, ...(mode !== "migration" && index % 7 === 0 ? { retired: true } : {}), tags: ["home-profile", index % 2 ? "kind-preference" : "kind-standing-decision", "fixture-label"], ...(mode === "v2" ? { profile: { version: 2 as const, path: ["life"] } } : {}) } } };
    if (mode === "migration") {
      // Preserve the original two TEXT editions, not just two placement states.
      // The admitted v2 create/edit followed by exact historical restore needs
      // three revisions: the text edit and placement restore each retain their source.
      const created = (await store.createNote({ ...request, record: { ...request.record, content: { ...request.record.content, profile: { version: 2, path: ["life"] } } } })).record;
      if (created.kind !== "note") throw new Error("Expected note");
      const edited = (await store.updateNote({ commandId: `partition-history-${index}`, recordId: created.id, expectedRevision: created.revisionId, record: { ...created, content: { ...created.content, body: created.content.body + "\nSecond edition." } } })).record;
      if (edited.kind !== "note") throw new Error("Expected note");
      records.push(edited);
    } else {
      const draft = (await store.createNote(request)).record;
      if (draft.kind !== "note") throw new Error("Expected note");
      records.push((await store.updateNote({ commandId: `partition-history-${index}`, recordId: draft.id, expectedRevision: draft.revisionId, record: { ...draft, content: { ...draft.content, body: draft.content.body + "\nSecond edition." } } })).record);
    }
  }
  if (mode === "migration") {
    // Arrange all historical placements in one real transaction, rather than
    // repeatedly backing up the growing fixture before the crash oracle starts.
    const commandId = "partition-seed-historical-fixture";
    await store.partitionProfile({ commandId, mode: "reorganize", assignments: records.map(record => ({ id: record.id, expectedRevision: record.revisionId, labels: [] })) },
      { restoring: true, create: () => ({ fixture: "historical-profile-restore" }), validate: envelope => { if ((envelope as { fixture?: string }).fixture !== "historical-profile-restore") throw new Error("Unexpected fixture recovery envelope"); } });
    for (let index = 0; index < records.length; index++) records[index] = (await store.read(records[index]!.id))!;
    const state = join((await workspace.describe()).root, "state", "profile", "profile-backups");
    await rm(join(state, `${profileOperationKey(commandId)}.json`));
  }
  const assignments: ProfileAssignment[] = records.map((note, index) => ({ id: note.id, expectedRevision: note.revisionId,
    ...(mode !== "legacy" ? { path: `engineering/selected-${Math.floor(index / 10)}` } : { file: index < 10 ? "core" as const : index < 20 ? "home" as const : "scopes/ui" as const }) }));
  return { root, workspace, store, records, assignments };
}

it("backs up complete histories before label-only migration; replay/reopen retain every exact value", async () => {
  const f = await fixture("migration");
  const result = await f.store.partitionProfile({ commandId: "partition-migrate-one", mode: "migrate", assignments: f.assignments });
  if (!result.backup) throw new Error("Migration must publish its backup");
  const backup = JSON.parse(await readFile(result.backup, "utf8")) as { originals: Array<{ record: ProfileNoteRecord; history: ProfileNoteRecord[] }> };
  expect((await stat(result.backup)).mode & 0o777).toBe(0o600);
  expect(backup.originals).toHaveLength(21);
  for (const [index, original] of f.records.entries()) {
    const saved = backup.originals.find(item => item.record.id === original.id)!;
    expect(saved.record).toEqual(original);
    // V2 creation, distinct text edit, then historical placement restore.
    expect(saved.history).toHaveLength(3);
    expect(saved.history[2]).toEqual(original);
    if (saved.history[0]?.kind !== "note" || saved.history[1]?.kind !== "note") throw new Error("Missing text editions");
    expect(saved.history[1].content.body).toBe(saved.history[0].content.body + "\nSecond edition.");
    const after = await f.store.read(original.id);
    if (original.kind !== "note" || after?.kind !== "note") throw new Error("Missing note");
    expect(after).toEqual({ ...original, revisionId: after.revisionId, content: { ...original.content, tags: profileFileTags(original.content.tags ?? []), profile: { version: 2, path: f.assignments[index]!.path!.split("/") } } });
    expect(after.revisionId).not.toBe(original.revisionId);
    for (const historical of saved.history) expect(await f.store.read(original.id, historical.revisionId)).toEqual(historical);
  }
  const heads = await Promise.all(f.records.map(note => f.store.read(note.id)));
  const repeat = await new ProfileStore(f.workspace).partitionProfile({ commandId: "partition-migrate-two", mode: "migrate", assignments: [...f.assignments].reverse().map(({ id, expectedRevision, path }) => ({ path: path!, expectedRevision, id })) });
  expect(repeat).toEqual(result);
  expect(await Promise.all(f.records.map(note => f.store.read(note.id)))).toEqual(heads);
  const rescanned: ProfileAssignment[] = heads.map((note, index) => ({ id: note!.id, expectedRevision: note!.revisionId, path: f.assignments[index]!.path! }));
  expect(await f.store.partitionProfile({ commandId: "partition-rescanned", mode: "reorganize", assignments: rescanned })).toEqual({ changes: [] });
  const directory = join(result.backup, "..", "..", "records");
  // Three retained seed revisions plus the single placement publication.
  for (const note of f.records) expect(await readdir(join(directory, note.id))).toHaveLength(3 + 1);
  await mkdir("test-results/home-profile", { recursive: true });
  await writeFile("test-results/home-profile/migration-store.json", JSON.stringify({ notes: 21, historicalRevisions: 21 * 3, exactMetadataAndContentPreserved: true, extraRevisionsOnRepeat: 0, ownerOnlyBackup: true }, null, 2) + "\n");
});

const crashEvidence: Array<Record<string, unknown>> = [];
it.each(["before-backup", "after-backup", "mid-body", "precommit", "after-commit"])("recovers every canonical/body reference after a process crash at %s", async cut => {
  const f = await fixture("migration");
  const home = join(f.root, "home");
  const root = join((await f.workspace.describe()).root, "state", "profile");
  await f.workspace.dispose();
  await crashProfilePartition(f.root, home, f.assignments, cut);
  const reopened = new TronWorkspace(home);
  fixtures.find(item => item.root === f.root)!.workspace = reopened;
  await reopened.initialize();
  const store = new ProfileStore(reopened);
  const heads = await Promise.all(f.records.map(note => store.read(note.id)));
  if (cut !== "after-commit") expect(heads).toEqual(f.records);
  else expect(heads.every((note, index) => note?.revisionId !== f.records[index]!.revisionId)).toBe(true);
  const backupFiles = (await readdir(join(root, "profile-backups"))).filter(name => name.endsWith(".json"));
  expect(backupFiles).toHaveLength(cut === "before-backup" ? 0 : 1);
  const prepared: ProfileNoteRecord[] = backupFiles.length ? JSON.parse(await readFile(join(root, "profile-backups", backupFiles[0]!), "utf8")).prepared : [];
  let staged = 0;
  for (const original of f.records) {
    const files = await readdir(join(root, "records", original.id));
    for (const name of files) {
      const record = JSON.parse(await readFile(join(root, "records", original.id, name), "utf8")) as ProfileNoteRecord;
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
    // Create + text edit + historical restore + one resumed migration, never two.
    expect(await readdir(join(root, "records", original.id))).toHaveLength(3 + 1);
  }
  crashEvidence.push({ cut, notes: 21, stagedBodies: staged, allStagedBodiesReferencedByBackup: true, originalHeadsUnchangedUntilCommit: cut !== "after-commit", resumedWithoutExtraBodies: true, canonicalAuditUndo: "not yet integrated; store-only evidence" });
  await mkdir("test-results/home-profile", { recursive: true });
  await writeFile("test-results/home-profile/migration-crashes.json", JSON.stringify(crashEvidence, null, 2) + "\n");
});

it("a missing historical body refuses migration before any new record body or backup is published", async () => {
  const f = await fixture("migration");
  const root = join((await f.workspace.describe()).root, "state", "profile");
  const first = f.records[0]!;
  const files = await readdir(join(root, "records", first.id));
  const historical = files.find(name => name !== `${first.revisionId}.json`)!;
  await rm(join(root, "records", first.id, historical));
  await expect(f.store.partitionProfile({ commandId: "partition-missing-history", mode: "migrate", assignments: f.assignments })).rejects.toThrow(/Record revision is missing/);
  expect(await Promise.all(f.records.map(note => f.store.read(note.id)))).toEqual(f.records);
  expect(await readdir(join(root, "profile-backups"))).toEqual([]);
  // Missing one member's body must not delete any of the other three-revision histories.
  for (const note of f.records.slice(1)) expect(await readdir(join(root, "records", note.id))).toHaveLength(3);
});

it("a valid-JSON but altered backup cannot rewrite text or discard a historical revision", async () => {
  const f = await fixture("migration");
  const result = await f.store.partitionProfile({ commandId: "partition-backup-original", mode: "migrate", assignments: f.assignments });
  if (!result.backup) throw new Error("Missing migration backup");
  const bytes = await readFile(result.backup, "utf8");
  const heads = await Promise.all(f.records.map(note => f.store.read(note.id)));
  const changedText = JSON.parse(bytes);
  changedText.prepared[0].content.title = "An unauthorized replacement.";
  await writeFile(result.backup, JSON.stringify(changedText));
  await expect(f.store.partitionProfile({ commandId: "partition-bad-text-backup", mode: "migrate", assignments: f.assignments })).rejects.toThrow(/more than profile placement/);
  expect(await Promise.all(f.records.map(note => f.store.read(note.id)))).toEqual(heads);
  const changedHistory = JSON.parse(bytes);
  changedHistory.originals[0].history.shift();
  await writeFile(result.backup, JSON.stringify(changedHistory));
  await expect(f.store.partitionProfile({ commandId: "partition-bad-history-backup", mode: "migrate", assignments: f.assignments })).rejects.toThrow(/history differs/);
  expect(await Promise.all(f.records.map(note => f.store.read(note.id)))).toEqual(heads);
  await writeFile(result.backup, bytes);
});

it("malformed partition labels can be explicitly normalized without inferring a destination or changing other data", async () => {
  const f = await fixture("v2");
  const note = f.records[0]!;
  if (note.kind !== "note") throw new Error("Expected note");
  const tags = [...note.content.tags!, "home-file-core", "home-file-home"];
  await expect(f.store.updateNote({ commandId: "partition-malformed-refused", recordId: note.id, expectedRevision: note.revisionId, record: { ...note, content: { ...note.content, tags } } })).rejects.toThrow(/no legacy file labels/);
  expect(await f.store.read(note.id)).toEqual(note);
  const malformed = await restoreLegacyProfileFixture(f.store, "partition-malformed-seed", note, tags);
  await expect(f.store.partitionProfile({ commandId: "partition-legacy-repair-refused", mode: "reorganize", assignments: [{ id: malformed.id, expectedRevision: malformed.revisionId, file: "scopes/repaired" }] })).rejects.toThrow(/v2 path/);
  expect(await f.store.read(note.id)).toEqual(malformed);
  const result = await f.store.partitionProfile({ commandId: "partition-explicit-repair", mode: "reorganize", assignments: [{ id: malformed.id, expectedRevision: malformed.revisionId, path: "engineering/repaired" }] });
  const after = await f.store.read(note.id);
  expect(after).toEqual({ ...malformed, revisionId: after!.revisionId, content: { ...malformed.content, tags: profileFileTags(note.content.tags!), profile: { version: 2, path: ["engineering", "repaired"] } } });
  expect(await Promise.all(f.records.slice(1).map(record => f.store.read(record.id)))).toEqual(f.records.slice(1));
  const backup = JSON.parse(await readFile(result.backup!, "utf8"));
  expect(backup.originals[0].record).toEqual(malformed);
  expect(backup.originals[0].history).toHaveLength(3);
});

it("profile receipt references are invalidated by forget, and cannot resurrect or replay forgotten data", async () => {
  const f = await fixture("migration");
  const request = { commandId: "partition-forget-original", mode: "migrate" as const, assignments: f.assignments };
  const migration = await f.store.partitionProfile(request);
  const unrelated = await f.store.read(f.records[1]!.id);
  const abandonedTemporary = `${migration.backup}.999999.123456789abc.tmp`;
  await writeFile(abandonedTemporary, await readFile(migration.backup!));
  const id = f.records[0]!.id;
  const current = await f.store.read(id);
  await f.store.forget("partition-forget-target", id, "Explicit fixture forget", current!.revisionId);
  expect(await f.store.read(id)).toBeNull();
  await expect(f.store.partitionProfile(request)).rejects.toThrow(/forgotten/);
  await expect(f.store.partitionProfile({ ...request, commandId: "partition-after-forget" })).rejects.toMatchObject({ code: "conflict" });
  expect(await f.store.read(id)).toBeNull();
  expect(await f.store.read(f.records[1]!.id)).toEqual(unrelated);
  const bytes = await readFile(migration.backup!, "utf8");
  const target = f.records[0]!;
  if (target.kind !== "note") throw new Error("Expected note");
  expect(bytes).not.toContain(target.content.title);
  expect(bytes).not.toContain(JSON.stringify(target.content.body).slice(1, -1));
  expect(JSON.parse(bytes).originals.find((item: { record: ProfileNoteRecord }) => item.record.id === f.records[1]!.id).record).toEqual(f.records[1]);
  await expect(readFile(abandonedTemporary)).rejects.toMatchObject({ code: "ENOENT" });
  const moved = await f.store.partitionProfile({ commandId: "partition-unrelated-after-forget", mode: "reorganize", assignments: [{ id: unrelated!.id, expectedRevision: unrelated!.revisionId, path: "routines/retained" }] });
  expect(moved.changes.map(change => change.id)).toEqual([unrelated!.id]);
});

it("forget cancels uncommitted partition bodies without erasing unrelated backup recovery data", async () => {
  const f = await fixture("migration");
  const workspaceRoot = (await f.workspace.describe()).root, home = join(f.root, "home");
  await f.workspace.dispose();
  await crashProfilePartition(f.root, home, f.assignments, "mid-body");
  const directory = join(workspaceRoot, "state", "profile", "profile-backups");
  const path = join(directory, (await readdir(directory)).find(name => name.endsWith(".json"))!);
  const before = JSON.parse(await readFile(path, "utf8"));
  const workspace = new TronWorkspace(home);
  await workspace.initialize();
  try {
    const store = new ProfileStore(workspace);
    await store.forget("partition-cancel-by-forget", f.records[0]!.id, "Explicit fixture forget", f.records[0]!.revisionId);
    const bytes = await readFile(path, "utf8"), after = JSON.parse(bytes);
    const target = f.records[0]!;
    if (target.kind !== "note") throw new Error("Expected note");
    expect(bytes).not.toContain(target.content.title);
    const unrelated = f.records[1]!;
    expect(after.originals.find((item: { record: ProfileNoteRecord }) => item.record.id === unrelated.id)).toEqual(before.originals.find((item: { record: ProfileNoteRecord }) => item.record.id === unrelated.id));
    expect(after.prepared.find((item: ProfileNoteRecord) => item.id === unrelated.id)).toEqual(before.prepared.find((item: ProfileNoteRecord) => item.id === unrelated.id));
    expect(await store.read(unrelated.id)).toEqual(unrelated);
    for (const record of before.prepared) await expect(readFile(join(workspaceRoot, "state", "profile", "records", record.id, `${record.revisionId}.json`))).rejects.toMatchObject({ code: "ENOENT" });
    await expect(store.partitionProfile({ commandId: "partition-canceled-retry", mode: "migrate", assignments: f.assignments })).rejects.toMatchObject({ code: "conflict" });
  } finally { await workspace.dispose(); }
});

it("forget tombstones resume backup redaction after a real postcommit crash", async () => {
  const f = await fixture("migration");
  const migration = await f.store.partitionProfile({ commandId: "partition-before-forget-crash", mode: "migrate", assignments: f.assignments });
  const target = await f.store.read(f.records[0]!.id), unrelated = await f.store.read(f.records[1]!.id);
  if (target?.kind !== "note") throw new Error("Expected note");
  await f.workspace.dispose();
  await crashProfilePartition(f.root, join(f.root, "home"), f.assignments, "before-backup", { recordId: target.id, expectedRevision: target.revisionId });
  const workspace = new TronWorkspace(join(f.root, "home"));
  await workspace.initialize();
  try {
    const store = new ProfileStore(workspace);
    expect(await store.read(target.id)).toBeNull();
    expect(await readFile(migration.backup!, "utf8")).toContain(target.content.title);
    await store.reconcile();
    const bytes = await readFile(migration.backup!, "utf8");
    expect(bytes).not.toContain(target.content.title);
    expect(bytes).not.toContain(JSON.stringify(target.content.body).slice(1, -1));
    expect(await store.read(unrelated!.id)).toEqual(unrelated);
    const settled = bytes;
    await store.reconcile();
    expect(await readFile(migration.backup!, "utf8")).toBe(settled);
    await mkdir("test-results/home-profile", { recursive: true });
    await writeFile("test-results/home-profile/migration-forget.json", JSON.stringify({ canonicalTargetUnavailableBeforeCleanup: true, postcommitCrashRecoveredFromExistingTombstone: true, forgottenBackupTextPurged: true, unrelatedCurrentHeadRetained: true, repeatCleanupStable: true, canonicalHomeEnvelope: "not integrated" }, null, 2) + "\n");
  } finally { await workspace.dispose(); }
});

it("excluded members require an explicit eligibility decision rather than incomplete migration", async () => {
  const f = await fixture("migration");
  const note = f.records[0]!;
  await f.store.setExclusion("partition-exclude-member", note.id, true, note.revisionId);
  await expect(f.store.partitionProfile({ commandId: "partition-with-excluded", mode: "migrate", assignments: f.assignments })).rejects.toThrow(/eligibility decision/);
  expect(await Promise.all(f.records.map(record => f.store.read(record.id, undefined, true)))).toEqual(f.records);
  const root = join((await f.workspace.describe()).root, "state", "profile");
  expect(await readdir(join(root, "profile-backups"))).toEqual([]);
});

it("streams and bounds deep histories before publishing backup or replacement bodies", async () => {
  const f = await fixture("v2");
  let current = f.records[0]!;
  if (current.kind !== "note") throw new Error("Expected note");
  const body = "界".repeat(100_000);
  for (let index = 0; index < 235; index++) current = (await f.store.updateNote({ commandId: `partition-deep-history-${index}`, recordId: current.id, expectedRevision: current.revisionId, record: { ...current, kind: "note", content: { ...current.content, body } } })).record;
  const before = await Promise.all(f.records.map(note => f.store.read(note.id)));
  const assignments = f.assignments.map(item => item.id === current.id ? { ...item, expectedRevision: current.revisionId } : item);
  const workspaceRoot = (await f.workspace.describe()).root;
  const home = join(f.root, "home");
  await f.workspace.dispose();
  const outcome = await boundedProfilePartition(f.root, home, assignments, "reorganize");
  expect(outcome, outcome.stderr).toMatchObject({ code: 0, signal: null });
  expect(JSON.parse(outcome.stdout)).toMatchObject({ status: "refused", message: expect.stringMatching(/backup exceeds its bound/) });
  const workspace = new TronWorkspace(home);
  await workspace.initialize();
  try {
    const store = new ProfileStore(workspace);
    expect(await Promise.all(f.records.map(note => store.read(note.id)))).toEqual(before);
    expect((await workspace.describe()).root).toBe(workspaceRoot);
    const root = join(workspaceRoot, "state", "profile");
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
  const f = await fixture("migration");
  await expect(f.store.partitionProfile({ commandId: "partition-incomplete", mode: "migrate", assignments: f.assignments.slice(1) })).rejects.toMatchObject({ code: "conflict" });
  expect(await Promise.all(f.records.map(note => f.store.read(note.id)))).toEqual(f.records);
  await f.store.partitionProfile({ commandId: "partition-admitted", mode: "migrate", assignments: f.assignments });
  const original = await f.store.read(f.records.at(-1)!.id);
  if (original?.kind !== "note") throw new Error("Expected note");
  const full = (await f.store.updateNote({ commandId: "partition-full-tags", recordId: original.id, expectedRevision: original.revisionId, record: { ...original, content: { ...original.content, tags: ["home-profile", "kind-standing-decision", "label-a", "label-b", "label-c", "label-d", "label-e", "label-f"] } } })).record;
  await expect(f.store.partitionProfile({ commandId: "partition-stale-plan", mode: "reorganize", assignments: f.assignments })).rejects.toMatchObject({ code: "conflict" });
  const before = await Promise.all(f.records.map(note => f.store.read(note.id)));
  // V2 placement does not add a ninth tag: overflow is refused by the actual note writer.
  await expect(f.store.updateNote({ commandId: "partition-overflow-tags", recordId: full.id, expectedRevision: full.revisionId, record: { ...full, content: { ...full.content, tags: [...full.content.tags!, "ninth-label"] } } })).rejects.toThrow();
  expect(await Promise.all(f.records.map(note => f.store.read(note.id)))).toEqual(before);
  const assignments = f.assignments.map((item, index) => ({ ...item, expectedRevision: before[index]!.revisionId }));
  expect(await f.store.partitionProfile({ commandId: "partition-full-plan", mode: "reorganize", assignments })).toEqual({ changes: [] });
  expect(await Promise.all(f.records.map(note => f.store.read(note.id)))).toEqual(before);
  const state = join((await f.workspace.describe()).root, "state", "profile");
  for (const note of f.records.slice(0, -1)) expect(await readdir(join(state, "records", note.id))).toHaveLength(3 + 1);
  expect(await readdir(join(state, "records", full.id))).toHaveLength(3 + 1 + 1);
});
