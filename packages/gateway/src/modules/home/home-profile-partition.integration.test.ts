import * as fs from "node:fs/promises";
import { join } from "node:path";
import { afterEach, expect, it, vi } from "vitest";
import { crashProfilePartition } from "../../../test-support/profile-partition-crash.js";
import { legacyProfileFixture } from "../../../test-support/profile-v1-fixture.js";
import { fixture, disposeFixtures } from "../../../test-support/home-task-fixture.js";
import { workspaceModule } from "../../workspace/workspace-module.js";
import { ProfileStore } from "./profile-store.js";
import { HomeProfileItems } from "./home-profile.js";
import { profileFileRecords, readProfileFile } from "./profile-file.js";
import type { ProfileNoteRecord } from "./profile-note-contract.js";
import * as durability from "../../foundation/durable-json.js";
import type { SettingsChangePath } from "../../kernel/settings/settings-change.js";

let knowledge: ProfileStore | undefined;
afterEach(async () => { vi.restoreAllMocks(); knowledge = undefined; await disposeFixtures(); });
async function setup(mode: "v2" | "migration" = "v2") {
  const f = await fixture(false, false, undefined, false, undefined, { knowledge: () => knowledge });
  let resource = f.registry.moduleHost.contract(workspaceModule);
  knowledge = new ProfileStore(resource);
  const profile = new HomeProfileItems(() => knowledge), originals: ProfileNoteRecord[] = [];
  for (let i = 0; i < 3; i++) {
    const record: Parameters<ProfileStore["createNote"]>[0]["record"] = { kind: "note", scope: "personal", provenance: { actor: "user", source: "fixture", evidence: [], reason: `Original provenance ${i}` },
      relations: mode === "v2" && i === 2 ? [{ type: "supersedes", recordId: originals[0]!.id, revisionId: originals[0]!.revisionId }] : [],
      content: { title: `Original confirmed standing instruction ${i}`, body: `Original private body ${i}`, role: "decision", confirmed: true,
        ...(mode === "v2" && i === 1 ? { retired: true } : {}), tags: ["home-profile", "kind-standing-decision", "fixture-label", ...(mode === "migration" ? [i === 1 ? "home-file-home" : "home-file-core"] : [])],
        ...(mode === "v2" ? { profile: { version: 2, path: ["engineering", "originals"] } } : {}) } };
    originals.push(mode === "migration" ? await legacyProfileFixture(resource, `create-original-${i}`, record) : (await knowledge.createNote({ commandId: `create-original-${i}`, record })).record);
  }
  const context = { commandId: "original-partition-command", actor: { kind: "ui" as const, id: "home-fixture", sessionId: "home-fixture", toolCallId: "original-tool-call" }, reason: "Original private audit reason" };
  const request = { commandId: context.commandId, mode: mode === "v2" ? "reorganize" as const : "migrate" as const,
    assignments: originals.map((record, index) => ({ id: record.id, expectedRevision: record.revisionId, path: `engineering/selected-${index}` })) };
  const cold = async () => { const registry = await f.restartToReadiness(); resource = registry.moduleHost.contract(workspaceModule); knowledge = new ProfileStore(resource); return f.settings.settingsChanges; };
  return { f, resource, currentResource: () => resource, profile, originals, context, request, cold };
}
async function applied(changes: SettingsChangePath) {
  return (await changes.history({ key: "home.profile.item", status: "applied" })).entries;
}

it("reversible organization applies without a tap, logs exact provenance and undoes without changing standing authority", async () => {
  const { f, profile, originals, request } = await setup();
  const context = { commandId: "home-reversible-organization", actor: { kind: "home" as const, id: "home", toolCallId: "organize" }, author: { kind: "home" as const, sessionId: "home", entryId: "maintainer-message" }, reason: "Maintainer selected these exact destinations" };
  const result = await profile.change(f.settings.settingsChanges, [{ action: "reorganize", assignments: request.assignments }], context);
  expect(result.status).toBe("applied");
  const entries = await applied(f.settings.settingsChanges);
  expect(entries).toHaveLength(3);
  expect(entries.every(entry => entry.commandId === context.commandId && entry.actor.kind === "home" && entry.reason === context.reason)).toBe(true);
  for (const original of originals) { const moved = (await knowledge!.read(original.id))!; expect({ ...moved, revisionId: original.revisionId, content: { ...moved.content, profile: original.content.profile } }).toEqual(original); }
  await f.settings.settingsChanges.undo(result.changes[0]!.changeId, { actor: { kind: "ui", id: "maintainer" }, commandId: "undo-reversible-organization" });
  for (const original of originals) expect({ ...await knowledge!.read(original.id), revisionId: original.revisionId }).toEqual(original);
});

it("Profile keeps a linked claim, refuses unanchored revisions and undoes through shared Changes", async () => {
  const { f, resource, profile, originals } = await setup();
  const wrong = originals[2]!, actor = { kind: "ui" as const, id: "maintainer" };
  const correction = await profile.change(f.settings.settingsChanges, [{ action: "learn", kind: "correction", text: "Exact correction of the original fixture claim", corrects: { id: wrong.id, revisionId: wrong.revisionId } }],
    { commandId: "one-file-correction", actor, author: { kind: "maintainer" }, reason: "Maintainer corrected this exact wrong claim" });
  const first = await profile.change(f.settings.settingsChanges, [{ action: "refine", id: wrong.id, expectedRevision: wrong.revisionId, text: "Intermediate revised fixture statement" }],
    { commandId: "one-file-first-edit", actor, author: { kind: "maintainer" }, reason: "Explicit first edit" });
  const unanchored = first.saved[0]!.revisionId;
  const second = await profile.change(f.settings.settingsChanges, [{ action: "refine", id: wrong.id, expectedRevision: unanchored, text: "Latest current fixture statement" }],
    { commandId: "one-file-second-edit", actor, author: { kind: "maintainer" }, reason: "Explicit second edit" });
  expect(await knowledge!.read(wrong.id, wrong.revisionId)).toEqual(wrong);
  expect((await knowledge!.read(correction.saved[0]!.id))!.relations).toContainEqual({ type: "corrects", recordId: wrong.id, revisionId: wrong.revisionId });
  await expect(knowledge!.read(wrong.id, unanchored)).rejects.toMatchObject({ code: "conflict", details: { kind: "profile_revision_unavailable", id: wrong.id, revisionId: unanchored } });
  await f.settings.settingsChanges.undo(second.changes[0]!.changeId, { actor, commandId: "one-file-shared-undo" });
  expect((await knowledge!.read(wrong.id))!.content.title).toBe("Intermediate revised fixture statement");
  expect(await knowledge!.read(wrong.id, wrong.revisionId)).toEqual(wrong);
  await f.settings.settingsChanges.undo(correction.changes[0]!.changeId, { actor, commandId: "one-file-correction-undo" });
  const retired = (await knowledge!.read(correction.saved[0]!.id))!;
  expect(retired.content.retired).toBe(true);
  expect(await knowledge!.read(wrong.id, wrong.revisionId)).toEqual(wrong);
  await knowledge!.forget("one-file-forget-correction", retired.id, "Remove the last fixture claim link", retired.revisionId);
  await expect(knowledge!.read(wrong.id, wrong.revisionId)).rejects.toMatchObject({ details: { kind: "profile_revision_unavailable" } });
  const file = (await readProfileFile(resource))!;
  expect(file.anchors).toEqual([]);
  expect(profileFileRecords(file)).toHaveLength(3);
  const descriptor = await resource.describe();
  await expect(fs.lstat(join(descriptor.root, "state", "profile"))).rejects.toMatchObject({ code: "ENOENT" });
  expect(await fs.readdir(join(descriptor.root, "files"))).toEqual(["Profile.json"]);
});

it("keeps original context and repairs only shared facts after preparation failure and a later edit", async () => {
  const { f, profile, originals, request, context, cold } = await setup();
  await fs.mkdir(f.settings.settingsChanges.record.path, { recursive: true });
  const directory = await fs.stat(f.settings.settingsChanges.record.path), sync = durability.syncDurably;
  const fault = vi.spyOn(durability, "syncDurably").mockImplementation(async handle => { const actual = await handle.stat(); if (actual.ino === directory.ino && actual.dev === directory.dev) throw new Error("Owned shared preparation fault"); await sync(handle); });
  await expect(profile.partition(f.settings.settingsChanges, request, context)).rejects.toThrow(/preparation|Owned shared/);
  expect(await Promise.all(originals.map(record => knowledge!.read(record.id)))).toEqual(originals);
  expect(await applied(f.settings.settingsChanges)).toEqual([]);
  fault.mockRestore();
  const changes = await cold();
  const result = await profile.retryPartition(changes, context.commandId, "ui");
  const heads = await Promise.all(originals.map(record => knowledge!.read(record.id)));
  const entries = await applied(changes);
  expect(entries).toHaveLength(3);
  expect(entries.every(entry => entry.commandId === context.commandId && entry.reason === context.reason && entry.actor.toolCallId === context.actor.toolCallId)).toBe(true);
  const first = heads[0]!;
  await knowledge!.updateNote({ commandId: "later-native-edit", recordId: first.id, expectedRevision: first.revisionId, record: { ...first, content: { ...first.content, title: "Later native text must remain" } } });
  const afterEdit = await Promise.all(originals.map(record => knowledge!.read(record.id)));
  expect((await profile.retryPartition(changes, context.commandId, "ui")).changes).toEqual(result.changes);
  expect(await Promise.all(originals.map(record => knowledge!.read(record.id)))).toEqual(afterEdit);
  expect(await applied(changes)).toEqual(entries);
  await expect(changes.undo(result.changes[0]!.changeId, { actor: { kind: "ui", id: "fixture" }, commandId: "stale-grouped-undo" })).rejects.toThrow(/changed since/);
});

it.each(["before-intent", "after-intent", "after-prepare", "before-domain", "staged-domain", "after-domain", "before-publication", "after-publication", "after-ack"])("retains the original intent, cold audit and exact Changes Undo after process death at %s", async cut => {
  const { f, profile, originals, request, context, cold } = await setup("migration");
  await f.registry.dispose(); await f.registry.administrativeWorkRegistry.waitUntilSettled();
  await crashProfilePartition(f.root, f.tronHome, request.assignments, cut, { context });
  const changes = await cold();
  const committed = ["after-domain", "before-publication", "after-publication", "after-ack"].includes(cut);
  const beforeRetry = await Promise.all(originals.map(record => knowledge!.read(record.id)));
  if (!committed) expect(beforeRetry).toEqual(originals);
  else expect(beforeRetry.every((record, index) => record!.revisionId !== originals[index]!.revisionId)).toBe(true);
  if (cut === "before-intent") await expect(knowledge!.profilePartitionRecovery(context.commandId)).rejects.toMatchObject({ code: "not_found" });
  else expect((await knowledge!.profilePartitionRecovery(context.commandId)).committed).toBe(committed);
  const result = cut === "before-intent" ? await profile.partition(changes, request, context) : await profile.retryPartition(changes, context.commandId, "ui");
  expect(await fs.readdir(join(f.tronHome, "workspace", "files"))).toEqual(["Profile.json"]);
  const heads = await Promise.all(originals.map(record => knowledge!.read(record.id)));
  if (committed) expect(heads).toEqual(beforeRetry);
  for (const [index, original] of originals.entries()) {
    const current = heads[index]!;
    expect({ ...current, revisionId: original.revisionId }).toEqual({ ...original, content: { ...original.content, tags: original.content.tags!.filter(tag => !tag.startsWith("home-file-")), profile: { version: 2, path: request.assignments[index]!.path.split("/") } } });
    await expect(knowledge!.read(original.id, original.revisionId)).rejects.toMatchObject({ details: { kind: "profile_revision_unavailable" } });
  }
  const entries = await applied(changes);
  expect(entries).toHaveLength(3);
  expect(entries.every(entry => entry.commandId === context.commandId && entry.reason === context.reason && entry.actor.toolCallId === "original-tool-call")).toBe(true);
  expect((await profile.retryPartition(changes, context.commandId, "ui")).changes).toEqual(result.changes);
  expect(await applied(changes)).toEqual(entries);
  expect(await Promise.all(originals.map(record => knowledge!.read(record.id)))).toEqual(heads);
  await changes.undo(result.changes[0]!.changeId, { actor: { kind: "ui", id: "fixture" }, commandId: "cold-process-undo" });
  for (const original of originals) expect({ ...await knowledge!.read(original.id), revisionId: original.revisionId }).toEqual(original);
});

it("keeps separate original commands separate and never adopts another intent's prepared identities", async () => {
  const { f, profile, originals, request, context, cold } = await setup("migration");
  await f.registry.dispose(); await f.registry.administrativeWorkRegistry.waitUntilSettled();
  await crashProfilePartition(f.root, f.tronHome, request.assignments, "after-prepare", { context });
  const changes = await cold(), first = await knowledge!.profilePartitionRecovery(context.commandId);
  expect(first.committed).toBe(false);
  if (first.committed) throw new Error("Expected pending command");
  const secondContext = { ...context, commandId: "distinct-original-command", reason: "Distinct explicit intent" };
  await profile.partition(changes, { ...request, commandId: secondContext.commandId }, secondContext);
  const heads = await Promise.all(originals.map(record => knowledge!.read(record.id)));
  expect(heads.every(record => !Object.values(first.revisions).includes(record!.revisionId))).toBe(true);
  await expect(profile.retryPartition(changes, context.commandId, "ui")).rejects.toThrow(/revision is stale/);
  const entries = await applied(changes);
  expect(entries).toHaveLength(3);
  expect(entries.every(entry => entry.commandId === secondContext.commandId && entry.reason === secondContext.reason)).toBe(true);
});

it("invalidates the complete proof when Forget races cold publication after shared preparation was read", async () => {
  const { f, currentResource, profile, originals, request, context, cold } = await setup("migration");
  await f.registry.dispose(); await f.registry.administrativeWorkRegistry.waitUntilSettled();
  await crashProfilePartition(f.root, f.tronHome, request.assignments, "after-domain", { context });
  const changes = await cold(), current = (await knowledge!.read(originals[0]!.id))!;
  const readPrepared = changes.readPreparedSubjectAudit.bind(changes);
  vi.spyOn(changes, "readPreparedSubjectAudit").mockImplementationOnce(async reference => {
    const prepared = await readPrepared(reference);
    await knowledge!.forget("forget-before-publication", current.id, "Explicit fixture privacy removal", current.revisionId);
    return prepared;
  });
  await expect(profile.retryPartition(changes, context.commandId, "ui")).rejects.toThrow(/invalidated/);
  expect(await applied(changes)).toEqual([]);
  const file = (await readProfileFile(currentResource()))!;
  expect(JSON.stringify(file)).not.toContain(originals[0]!.content.body);
});

it("refuses moving a linked correction out of Corrections at the canonical owner", async () => {
  const { f, profile, originals } = await setup();
  const correction = await profile.change(f.settings.settingsChanges, [{ action: "learn", kind: "correction", text: "Linked correction", corrects: { id: originals[2]!.id, revisionId: originals[2]!.revisionId } }],
    { commandId: "guard-correction-create", actor: { kind: "ui", id: "fixture" }, author: { kind: "maintainer" }, reason: "Explicit fixture correction" });
  const note = (await knowledge!.read(correction.saved[0]!.id))!;
  await expect(knowledge!.partitionProfile({ commandId: "guard-correction-move", mode: "reorganize", assignments: [{ id: note.id, expectedRevision: note.revisionId, path: "engineering" }] })).rejects.toThrow(/Corrections/);
});
