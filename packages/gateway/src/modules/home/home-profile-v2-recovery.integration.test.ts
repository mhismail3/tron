import { legacyProfileFixture } from "../../../test-support/profile-v1-fixture.js";
import * as fs from "node:fs/promises";
import { join } from "node:path";
import { profileOperationKey } from "../../knowledge/knowledge-notes.js";
import { afterEach, expect, it } from "vitest";
import { crashProfilePartition } from "../../../test-support/profile-partition-crash.js";
import { fixture, disposeFixtures } from "../../../test-support/home-task-fixture.js";
import { workspaceModule } from "../../workspace/workspace-module.js";
import { KnowledgeStore } from "../../knowledge/knowledge-store.js";
import { KnowledgeService } from "../../knowledge/knowledge-service.js";
import { HomeProfileItems } from "./home-profile.js";
import type { KnowledgeRecord } from "../../knowledge/knowledge-contract.js";

type Note = Extract<KnowledgeRecord, { kind: "note" }>;
let knowledge: KnowledgeService | undefined;
const evidence: unknown[] = [];
afterEach(async () => {
  knowledge?.dispose(); knowledge = undefined;
  await disposeFixtures();
  await fs.mkdir("test-results/home-profile", { recursive: true });
  await fs.writeFile("test-results/home-profile/v2-recovery.json", JSON.stringify(evidence, null, 2));
});
async function setup() {
  const f = await fixture(false, false, undefined, false, undefined, { knowledge: () => knowledge });
  knowledge = new KnowledgeService(new KnowledgeStore(f.registry.moduleHost.contract(workspaceModule), () => {}));
  return { f, profile: new HomeProfileItems(() => knowledge) };
}
async function seed(index: number, path?: string[], retired = false): Promise<Note> {
  const record = {
    kind: "note", scope: "personal", provenance: { actor: "agent", source: "home", evidence: [], reason: `Original capture ${index}` }, relations: [],
    content: { title: `Exact original note ${index}`, role: "fact", confirmed: false, ...(retired ? { retired: true } : {}),
      tags: path ? ["home-profile", "kind-fact"] : ["fixture-label", "home-file-home", "home-profile", "kind-fact"], ...(path ? { profile: { version: 2, path } } : {}) },
  } as const;
  if (!path) return legacyProfileFixture(knowledge!.store, `v2-seed-${index}`, structuredClone(record));
  return (await knowledge!.store.createNote({ commandId: `v2-seed-${index}`, record: structuredClone(record) })).record as Note;
}

it("refuses native legacy-placement creation before writing a body or head", async () => {
  const { profile } = await setup();
  await expect(knowledge!.store.createNote({ commandId: "unplaced-native-profile", record: {
    kind: "note", scope: "personal", provenance: { actor: "user", evidence: [] }, relations: [],
    content: { title: "An unlinked unplaced correction must not bypass bounds.", role: "fact", confirmed: false, tags: ["home-profile", "kind-correction"] },
  } })).rejects.toThrow(/v2 placement/);
  expect((await profile.read()).items).toHaveLength(0);
  evidence.push({ nativeLegacyWriterRefused: true, profileHeadsAfterRefusal: 0 });
}, 60_000);

it.each(["before-backup", "after-backup", "mid-body", "precommit", "after-commit"])("v2 placement survives a real %s process death, cold retry and exact historical Undo", async cut => {
  const { f, profile } = await setup();
  const originals = await Promise.all([seed(0), seed(1), seed(2)]);
  const inactive = await seed(3, undefined, true);
  const assignments = originals.map(note => ({ id: note.id, expectedRevision: note.revisionId, path: "engineering/testing" }));
  const context = { actor: { kind: "ui" as const, id: "fixture-maintainer" }, commandId: `v2-crash-${cut}`, reason: "Exact approved placement" };
  knowledge!.dispose();
  await f.registry.dispose();
  await f.registry.administrativeWorkRegistry.waitUntilSettled();
  await crashProfilePartition(f.root, f.tronHome, assignments, cut, undefined, { context });
  const registry = await f.restartToReadiness();
  knowledge = new KnowledgeService(new KnowledgeStore(registry.moduleHost.contract(workspaceModule), () => {}));
  for (const note of originals) {
    const current = await knowledge.store.read(note.id) as Note;
    if (cut !== "after-commit") expect(current).toEqual(note);
    else expect(current.content.profile?.version).toBe(2);
  }
  const changes = f.settings.settingsChanges;
  const saved = cut === "before-backup" ? undefined : await knowledge.store.profilePartitionRecovery(context.commandId);
  const result = saved ? await profile.retryPartition(changes, context.commandId, "ui") : await profile.partition(changes, { commandId: context.commandId, mode: "migrate", assignments }, context);
  const recovery = await knowledge.store.profilePartitionRecovery(context.commandId);
  if (saved) expect(recovery.prepared.map(note => note.revisionId)).toEqual(saved.prepared.map(note => note.revisionId));
  expect(result.changes).toHaveLength(3);
  await changes.undo(result.changes[0]!.changeId, { actor: { kind: "ui", id: "fixture-maintainer" }, commandId: `v2-undo-${cut}` });
  for (const note of originals) {
    const current = await knowledge.store.read(note.id) as Note;
    expect({ ...current, revisionId: note.revisionId }).toEqual(note);
    expect(await knowledge.store.read(note.id, note.revisionId)).toEqual(note);
  }
  expect(await knowledge.store.read(inactive.id)).toEqual(inactive);
  evidence.push({ cut, exactOriginalsRestored: 3, originalPreparedIdentitiesReused: !!saved, atomicGroupSize: result.changes.length });
}, 60_000);

it("enforces personal, unsorted and sub-area limits atomically without losing over-bound originals", async () => {
  const { f, profile } = await setup();
  const originals: Note[] = [];
  for (let index = 0; index < 385; index++) originals.push(await seed(index, undefined, index === 384));
  const assignments = originals.map((note, index) => ({ id: note.id, expectedRevision: note.revisionId,
    path: index < 256 ? `engineering/leaf-${Math.floor(index / 32)}` : index === 384 ? "inferred/uncertain" : "inferred/review" }));
  const context = { actor: { kind: "ui" as const, id: "fixture" }, reason: "Exact bounded fixture migration" };
  const result = await profile.partition(f.settings.settingsChanges, { commandId: "at-all-caps", mode: "reorganize", assignments }, { ...context, commandId: "at-all-caps" });
  expect(result.changes).toHaveLength(385);
  const full = await profile.read();
  expect(full.items.filter(item => item.status === "active" && item.path.startsWith("engineering/"))).toHaveLength(256);
  expect(full.items.filter(item => item.status === "active" && item.path.startsWith("inferred/"))).toHaveLength(128);
  const personal = full.items.filter(item => item.path.startsWith("engineering/"));
  const unsorted = full.items.find(item => item.path === "inferred/review")!;
  const proposals = [
    { commandId: "too-many-personal", assignments: [{ id: unsorted.id, expectedRevision: unsorted.revisionId, path: "communication/answers" }], error: /personal limit 256/ },
    { commandId: "too-many-unsorted", assignments: [{ id: personal[0]!.id, expectedRevision: personal[0]!.revisionId, path: "inferred/review" }], error: /unsorted limit 128/ },
    { commandId: "too-many-subareas", assignments: personal.slice(0, 44).map((item, index) => ({ id: item.id, expectedRevision: item.revisionId, path: `engineering/branch-${index}/child/leaf` })), error: /sub-areas limit 128/ },
  ];
  for (const proposal of proposals) {
    await expect(profile.partition(f.settings.settingsChanges, { commandId: proposal.commandId, mode: "reorganize", assignments: proposal.assignments }, { ...context, commandId: proposal.commandId })).rejects.toThrow(proposal.error);
    expect((await profile.read()).items.map(item => item.record)).toEqual(full.items.map(item => item.record));
  }
  await f.settings.settingsChanges.undo(result.changes[0]!.changeId, { actor: { kind: "ui", id: "fixture" }, commandId: "undo-all-cap-fixture" });
  for (const note of originals) expect({ ...await knowledge!.store.read(note.id), revisionId: note.revisionId }).toEqual(note);
  evidence.push({ personal: 256, unsorted: 128, inactive: 1, rejectedOverflows: 3, exactUndoCount: originals.length });
}, 180_000);

it("forget physically scrubs v2 prepared bodies and the whole quoted audit while keeping unrelated recovery history", async () => {
  const { f, profile } = await setup();
  const originals = await Promise.all([seed(0), seed(1)]);
  const legacyInactive = await seed(2, undefined, true);
  const assignments = originals.map(note => ({ id: note.id, expectedRevision: note.revisionId, path: "engineering/privacy" }));
  const context = { actor: { kind: "ui" as const, id: "fixture" }, commandId: "v2-forget-prepared", reason: "Opaque context quotes both private members; remove the whole envelope" };
  knowledge!.dispose(); await f.registry.dispose(); await f.registry.administrativeWorkRegistry.waitUntilSettled();
  await crashProfilePartition(f.root, f.tronHome, assignments, "after-backup", undefined, { context });
  const registry = await f.restartToReadiness();
  knowledge = new KnowledgeService(new KnowledgeStore(registry.moduleHost.contract(workspaceModule), () => {}));
  const recovery = await knowledge.store.profilePartitionRecovery(context.commandId);
  const forgotten = originals[0]!, kept = originals[1]!;
  const prepared = recovery.prepared.find(note => note.id === forgotten.id)!;
  await knowledge.store.forget("forget-v2-prepared", forgotten.id, "Explicit fixture forget", forgotten.revisionId);
  await expect(profile.retryPartition(f.settings.settingsChanges, context.commandId, "ui")).rejects.toThrow(/invalidated|unavailable/);
  const root = join((await registry.moduleHost.contract(workspaceModule).describe()).root, "state", "knowledge");
  const backup = join(root, "profile-backups", `${profileOperationKey(context.commandId)}.json`);
  const bytes = await fs.readFile(backup, "utf8");
  expect(bytes).not.toContain(context.reason); expect(bytes).not.toContain(forgotten.content.title);
  expect(bytes).toContain(kept.content.title); expect(JSON.parse(bytes).operation).toBeUndefined();
  await expect(fs.access(join(root, "records", prepared.id, `${prepared.revisionId}.json`))).rejects.toThrow();
  expect(await knowledge.store.read(kept.id)).toEqual(kept);
  expect((await f.settings.settingsChanges.history({ key: "home.profile.item" })).entries).toEqual([]);
  await knowledge.store.forget("forget-legacy-inactive", legacyInactive.id, "Explicit fixture forget of a retired legacy original", legacyInactive.revisionId);
  expect(await knowledge.store.read(legacyInactive.id, undefined, true)).toBeNull();
  expect(await knowledge.store.read(kept.id)).toEqual(kept);
  evidence.push({ v2ForgetAfterPreparedCrash: true, legacyInactiveForgetSucceeded: true, canceledBodyRemoved: true, wholeAuditRemoved: true, unrelatedOriginalUnchanged: true });
}, 60_000);

it("concurrent direct note writers cannot exceed a leaf cap; overflow and invalid paths preserve all current heads", async () => {
  const { f, profile } = await setup();
  for (let index = 0; index < 31; index++) await seed(index, ["engineering", "testing"]);
  const before = await profile.read();
  const attempts = await Promise.allSettled([seed(31, ["engineering", "testing"]), seed(32, ["engineering", "testing"])]);
  expect(attempts.filter(result => result.status === "fulfilled")).toHaveLength(1);
  expect(attempts.filter(result => result.status === "rejected")).toHaveLength(1);
  const after = await profile.read();
  expect(after.items).toHaveLength(32);
  for (const item of before.items) expect(await knowledge!.store.read(item.id)).toEqual(item.record);
  const one = after.items[0]!;
  for (const [index, path] of ["engineering/a/b/c/d", "devices/computers", "engineering/../testing", "inferred/history"].entries()) {
    await expect(profile.partition(f.settings.settingsChanges, { commandId: `invalid-path-${index}`, mode: "reorganize", assignments: [{ id: one.id, expectedRevision: one.revisionId, path }] }, { actor: { kind: "ui", id: "fixture" }, commandId: `invalid-path-${index}`, reason: "Invalid proposal" })).rejects.toThrow(/Profile path|inactive profile notes/);
    expect((await profile.read()).items.map(item => item.record)).toEqual(after.items.map(item => item.record));
  }
  evidence.push({ concurrentLeafWriters: 2, committed: 1, activeAfter: after.items.length, priorHeadsUnchanged: before.items.length });
}, 60_000);
