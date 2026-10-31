import { legacyProfileFixture } from "../../../test-support/profile-v1-fixture.js";
import * as fs from "node:fs/promises";
import { afterEach, expect, it } from "vitest";
import { crashProfilePartition } from "../../../test-support/profile-partition-crash.js";
import { fixture, disposeFixtures } from "../../../test-support/home-task-fixture.js";
import { workspaceModule } from "../../workspace/workspace-module.js";

import { ProfileStore } from "./profile-store.js";
import { HomeProfileItems } from "./home-profile.js";
import type { ProfileNoteRecord } from "./profile-note-contract.js";

type Note = Extract<ProfileNoteRecord, { kind: "note" }>;
let knowledge: ProfileStore | undefined;
let resource: ConstructorParameters<typeof ProfileStore>[0];
const evidence: unknown[] = [];
afterEach(async () => {
   knowledge = undefined;
  await disposeFixtures();
  await fs.mkdir("test-results/home-profile", { recursive: true });
  await fs.writeFile("test-results/home-profile/v2-recovery.json", JSON.stringify(evidence, null, 2));
});
async function setup() {
  const f = await fixture(false, false, undefined, false, undefined, { knowledge: () => knowledge });
  resource = f.registry.moduleHost.contract(workspaceModule);
  knowledge = new ProfileStore(resource);
  return { f, profile: new HomeProfileItems(() => knowledge) };
}
async function seed(index: number, path?: string[], retired = false): Promise<Note> {
  const record = {
    kind: "note", scope: "personal", provenance: { actor: "agent", source: "home", evidence: [], reason: `Original capture ${index}` }, relations: [],
    content: { title: `Exact original note ${index}`, role: "fact", confirmed: false, ...(retired ? { retired: true } : {}),
      tags: path ? ["home-profile", "kind-fact"] : ["fixture-label", "home-file-home", "home-profile", "kind-fact"], ...(path ? { profile: { version: 2, path } } : {}) },
  } as const;
  if (!path) return legacyProfileFixture(resource, `v2-seed-${index}`, structuredClone(record));
  return (await knowledge!.createNote({ commandId: `v2-seed-${index}`, record: structuredClone(record) })).record as Note;
}

it("refuses native legacy-placement creation before writing a body or head", async () => {
  const { profile } = await setup();
  await expect(knowledge!.createNote({ commandId: "unplaced-native-profile", record: {
    kind: "note", scope: "personal", provenance: { actor: "user", evidence: [] }, relations: [],
    content: { title: "An unlinked unplaced correction must not bypass bounds.", role: "fact", confirmed: false, tags: ["home-profile", "kind-correction"] },
  } })).rejects.toThrow(/v2 placement/);
  expect((await profile.read()).items).toHaveLength(0);
  evidence.push({ nativeLegacyWriterRefused: true, profileHeadsAfterRefusal: 0 });
}, 60_000);

// Current-file crash, cold publication and exact Prior Undo use the nine
// real-process stages in home-profile-partition.integration.test.ts.

it("repairs a v2-to-historical Undo audit after a real postcommit process death without replaying note effects", async () => {
  const { f, profile } = await setup();
  const originals = [await seed(0), await seed(1)];
  const context = { actor: { kind: "ui" as const, id: "fixture" }, commandId: "v2-before-undo-crash", reason: "Exact fixture migration" };
  const migrated = await profile.partition(f.settings.settingsChanges, { commandId: context.commandId, mode: "migrate", assignments: originals.map(note => ({ id: note.id, expectedRevision: note.revisionId, path: "engineering/undo" })) }, context);
  const undoContext = { actor: context.actor, commandId: "v2-undo-postcommit-crash", reason: "Restore exact historical placement" };
   await f.registry.dispose(); await f.registry.administrativeWorkRegistry.waitUntilSettled();
  await crashProfilePartition(f.root, f.tronHome, [], "after-domain", { context: undoContext, undoChangeId: migrated.changes[0]!.changeId });
  const registry = await f.restartToReadiness();
  knowledge = new ProfileStore(registry.moduleHost.contract(workspaceModule));
  const committedHeads = await Promise.all(originals.map(note => knowledge!.read(note.id)));
  for (const note of originals) expect({ ...committedHeads.find(head => head?.id === note.id), revisionId: note.revisionId }).toEqual(note);
  const repaired = await profile.retryPartition(f.settings.settingsChanges, undoContext.commandId, "ui");
  expect(repaired.changes).toHaveLength(2);
  const undoFacts = (await f.settings.settingsChanges.history({ key: "home.profile.item" })).entries.filter(entry => entry.commandId === undoContext.commandId && entry.status === "applied");
  expect(undoFacts.map(entry => entry.undoOf).sort()).toEqual(migrated.changes.map(entry => entry.changeId).sort());
  expect(await Promise.all(originals.map(note => knowledge!.read(note.id)))).toEqual(committedHeads);
  evidence.push({ v2UndoPostcommitCrash: true, originalUndoLinksRepaired: 2, committedHeadsNotReplayed: true });
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
  for (const note of originals) expect({ ...await knowledge!.read(note.id), revisionId: note.revisionId }).toEqual(note);
  evidence.push({ personal: 256, unsorted: 128, inactive: 1, rejectedOverflows: 3, exactUndoCount: originals.length });
}, 180_000);

it("concurrent direct note writers cannot exceed a leaf cap; overflow and invalid paths preserve all current heads", async () => {
  const { f, profile } = await setup();
  for (let index = 0; index < 31; index++) await seed(index, ["engineering", "testing"]);
  const before = await profile.read();
  const attempts = await Promise.allSettled([seed(31, ["engineering", "testing"]), seed(32, ["engineering", "testing"])]);
  expect(attempts.filter(result => result.status === "fulfilled")).toHaveLength(1);
  expect(attempts.filter(result => result.status === "rejected")).toHaveLength(1);
  const after = await profile.read();
  expect(after.items).toHaveLength(32);
  for (const item of before.items) expect(await knowledge!.read(item.id)).toEqual(item.record);
  const one = after.items[0]!;
  for (const [index, path] of ["engineering/a/b/c/d", "devices/computers", "engineering/../testing", "inferred/history"].entries()) {
    await expect(profile.partition(f.settings.settingsChanges, { commandId: `invalid-path-${index}`, mode: "reorganize", assignments: [{ id: one.id, expectedRevision: one.revisionId, path }] }, { actor: { kind: "ui", id: "fixture" }, commandId: `invalid-path-${index}`, reason: "Invalid proposal" })).rejects.toThrow(/Profile path|inactive profile notes/);
    expect((await profile.read()).items.map(item => item.record)).toEqual(after.items.map(item => item.record));
  }
  evidence.push({ concurrentLeafWriters: 2, committed: 1, activeAfter: after.items.length, priorHeadsUnchanged: before.items.length });
}, 60_000);
