import * as fs from "node:fs/promises";
import { join } from "node:path";
import { afterEach, expect, it, vi } from "vitest";
import { crashProfilePartition } from "../../../test-support/profile-partition-crash.js";
import { legacyProfileFixture } from "../../../test-support/profile-v1-fixture.js";
import { fixture, disposeFixtures } from "../../../test-support/home-task-fixture.js";
import { workspaceModule } from "../../workspace/workspace-module.js";

import { ProfileStore } from "./profile-store.js";
import { profileOperationKey } from "./profile-notes.js";
import { HomeProfileItems } from "./home-profile.js";
import type { ProfileNoteRecord } from "./profile-note-contract.js";
import * as durability from "../../foundation/durable-json.js";

const evidence: unknown[] = [];
let knowledge: ProfileStore | undefined;
afterEach(async () => {
  vi.restoreAllMocks();  knowledge = undefined;
  await disposeFixtures();
  await fs.mkdir("test-results/home-profile", { recursive: true });
  await fs.writeFile("test-results/home-profile/migration-changes.json", JSON.stringify(evidence, null, 2));
});
async function setup(mode: "v2" | "migration") {
  const f = await fixture(false, false, undefined, false, undefined, { knowledge: () => knowledge });
  knowledge = new ProfileStore(f.registry.moduleHost.contract(workspaceModule));
  const profile = new HomeProfileItems(() => knowledge);
  const originals: Extract<ProfileNoteRecord, { kind: "note" }>[] = [];
  for (let i = 0; i < 3; i++) {
    const record: Parameters<ProfileStore["createNote"]>[0]["record"] = {
      kind: "note", scope: "personal", provenance: { actor: "user", source: "fixture", evidence: [], reason: `Original provenance ${i}` },
      relations: mode !== "migration" && i === 2 ? [{ type: "supersedes", recordId: originals[0]!.id, revisionId: originals[0]!.revisionId }] : [],
      content: { title: `Original confirmed standing instruction ${i}`, body: `Original private body ${i}`, role: "decision", confirmed: true,
        ...(mode !== "migration" && i === 1 ? { retired: true } : {}), tags: ["home-profile", "kind-standing-decision", "fixture-label", ...(mode === "migration" ? [i === 1 ? "home-file-home" : "home-file-core"] : [])],
        ...(mode === "v2" ? { profile: { version: 2 as const, path: ["engineering", "originals"] } } : {}) },
    };
    originals.push(mode === "migration"
      ? await legacyProfileFixture(knowledge, `create-original-${i}`, record)
      : (await knowledge.createNote({ commandId: `create-original-${i}`, record })).record as Extract<ProfileNoteRecord, { kind: "note" }>);
  }
  if (mode === "migration") {
    const state = join((await f.registry.moduleHost.contract(workspaceModule).describe()).root, "state", "profile", "profile-backups");
    for (let i = 0; i < 3; i++) await fs.rm(join(state, `${profileOperationKey(`create-original-${i}-historical-fixture`)}.json`));
  }
  const context = { commandId: "original-partition-command", actor: { kind: "ui" as const, id: "home-fixture", sessionId: "home-fixture", toolCallId: "original-tool-call" }, reason: "Original private audit reason" };
  const assignments = originals.map((record, index) => ({ id: record.id, expectedRevision: record.revisionId, path: `engineering/selected-${index}` }));
  const request = { commandId: context.commandId, mode: mode === "v2" ? "reorganize" as const : "migrate" as const, assignments };
  const cold = async () => {

    const registry = await f.restartToReadiness();
    knowledge = new ProfileStore(registry.moduleHost.contract(workspaceModule));
    return f.settings.settingsChanges;
  };
  return { f, profile, originals, context, request, cold };
}
function withoutPartition(record: Extract<ProfileNoteRecord, { kind: "note" }>) {
  const { revisionId: _revisionId, ...rest } = record;
  return { ...rest, content: { ...rest.content, tags: rest.content.tags?.filter(tag => !tag.startsWith("home-file-")) } };
}
async function failPublication(path: string) {
  await fs.mkdir(path, { recursive: true });
  const parent = await fs.stat(path);
  const sync = durability.syncDurably;
  return vi.spyOn(durability, "syncDurably").mockImplementation(async handle => {
    const actual = await handle.stat();
    if (actual.dev === parent.dev && actual.ino === parent.ino) throw new Error("Owned original group publication fault");
    await sync(handle);
  });
}

it("a tapped organization keeps its original recovery identity through audit failure, retry and Undo", async () => {
  const { f, profile, originals, request } = await setup("v2");
  const context = { commandId: "home-original-organization", actor: { kind: "home" as const, id: "home", toolCallId: "organize" },
    author: { kind: "home" as const, sessionId: "home", entryId: "maintainer-message" }, reason: "Exact placement review" };
  const fault = await failPublication(f.settings.settingsChanges.record.path);
  let taps = 0;
  await expect(profile.change(f.settings.settingsChanges, [{ action: "reorganize", assignments: request.assignments }], {
    ...context, confirm: async (_review, apply) => { taps++; return apply({ deviceId: "maintainer", commandId: "distinct-native-tap-receipt" }); },
  })).rejects.toThrow("Owned original group publication fault");
  fault.mockRestore();
  expect(taps).toBe(1);
  const recovery = await knowledge!.profilePartitionRecovery(context.commandId);
  expect(recovery.committed).toBe(true);
  const heads = await Promise.all(originals.map(note => knowledge!.read(note.id)));
  const retry = () => profile.change(f.settings.settingsChanges, [{ action: "retry", commandId: context.commandId }], context);
  const result = await retry();
  expect((await retry()).changes).toEqual(result.changes);
  expect(await Promise.all(originals.map(note => knowledge!.read(note.id)))).toEqual(heads);
  const audit = (await f.settings.settingsChanges.history({ key: "home.profile.item" })).entries;
  expect(audit).toHaveLength(originals.length);
  expect(audit.every(entry => entry.commandId === context.commandId)).toBe(true);
  await f.settings.settingsChanges.undo(result.changes[0]!.changeId, { actor: { kind: "ui", id: "maintainer" }, commandId: "undo-tapped-organization" });
  for (const original of originals) {
    const restored = await knowledge!.read(original.id);
    expect({ ...restored, revisionId: original.revisionId }).toEqual(original);
  }
});

it("backs up exact original audit, publishes the full migration group on cold retry, and undoes/reorganizes only labels through real Changes", async () => {
  const { f, profile, originals, context, request, cold } = await setup("v2");
  const fault = await failPublication(f.settings.settingsChanges.record.path);
  await expect(profile.partition(f.settings.settingsChanges, request, context)).rejects.toThrow("Owned original group publication fault");
  expect((await f.settings.settingsChanges.history({ key: "home.profile.item" })).entries).toEqual([]);
  const recovery = await knowledge!.profilePartitionRecovery(context.commandId);
  expect(recovery.committed).toBe(true);
  const envelope = recovery.envelope as { replayAt: string; context: unknown; writes: unknown[] };
  expect(envelope.context).toEqual(context);
  expect(envelope.writes).toHaveLength(3);
  const projected = await profile.read();
  expect(projected.items.map(item => item.status).sort()).toEqual(["active", "retired", "superseded"]);
  for (const original of originals) {
    const current = await knowledge!.read(original.id) as typeof original;
    const destination = request.assignments.find(assignment => assignment.id === original.id)!.path!;
    expect({ ...current, revisionId: original.revisionId }).toEqual({ ...original,
      content: { ...original.content, profile: { version: 2, path: destination.split("/") } } });
    expect(await knowledge!.read(original.id, original.revisionId)).toEqual(original);
  }
  const headRevisions = recovery.prepared.map(record => record.revisionId);
  fault.mockRestore();
  const changes = await cold();
  const published = await profile.retryPartition(changes, context.commandId, "home");
  expect(published.status).toBe("applied");
  const audit = (await changes.history({ key: "home.profile.item" })).entries;
  expect(audit).toHaveLength(3);
  expect(audit.every(entry => entry.at === envelope.replayAt && entry.commandId === context.commandId && entry.group?.size === 3 && entry.actor.toolCallId === "original-tool-call")).toBe(true);
  expect(audit.map(entry => entry.qualifiers?.note).reverse()).toEqual(recovery.prepared.map(record => record.id));
  expect((await profile.retryPartition(changes, context.commandId, "home")).changes).toEqual(published.changes);
  expect((await changes.history({ key: "home.profile.item" })).entries).toEqual(audit);
  expect((await knowledge!.profilePartitionRecovery(context.commandId)).prepared.map(record => record.revisionId)).toEqual(headRevisions);

  const undone = await changes.undo(published.changes[0]!.changeId, { actor: { kind: "ui", id: "fixture" }, commandId: "undo-partition-command", reason: "Undo only labels" });
  for (const original of originals) {
    const now = await knowledge!.read(original.id) as typeof original;
    expect(withoutPartition(now)).toEqual(withoutPartition(original));
    expect(now.content.tags).toEqual(original.content.tags);
  }
  const undoEntries = (await changes.history({ key: "home.profile.item" })).entries.filter(entry => entry.undoOf);
  expect(undoEntries.map(entry => entry.undoOf).sort()).toEqual(published.changes.map(change => change.changeId).sort());
  expect(undoEntries.every(entry => entry.commandId === "undo-partition-command" && entry.group?.size === 3)).toBe(true);
  const one = await knowledge!.read(originals[0]!.id) as typeof originals[number];
  const reorganized = await profile.partition(changes, { commandId: "reorganize-one", mode: "reorganize", assignments: [{ id: one.id, expectedRevision: one.revisionId, path: "engineering/selected" }] }, { ...context, commandId: "reorganize-one" });
  expect(reorganized.changes).toHaveLength(1);
  expect((await knowledge!.read(one.id) as typeof one).content.profile).toEqual({ version: 2, path: ["engineering", "selected"] });
  await changes.undo(reorganized.changes[0]!.changeId, { actor: { kind: "ui", id: "fixture" }, commandId: "undo-reorganize" });
  const restored = await knowledge!.read(one.id) as typeof one;
  expect(withoutPartition(restored)).toEqual(withoutPartition(one));
  expect(restored.content.tags).toEqual(one.content.tags);
  evidence.push({ case: "canonical-migrate-cold-retry-undo-reorganize", audit, undoEntries, undone, originalHeadsPreserved: true, canonicalChanges: true });
}, 60_000);

it("repairs original committed audit after a later native edit without replaying domain effects, then refuses stale grouped Undo", async () => {
  const { f, profile, originals, context, request, cold } = await setup("v2");
  const fault = await failPublication(f.settings.settingsChanges.record.path);
  await expect(profile.partition(f.settings.settingsChanges, request, context)).rejects.toThrow("Owned original group publication fault");
  const current = await knowledge!.read(originals[0]!.id) as typeof originals[number];
  const later = await knowledge!.updateNote({ commandId: "later-native-edit", recordId: current.id, expectedRevision: current.revisionId,
    record: { ...current, provenance: { actor: "user", source: "native", evidence: [] }, content: { ...current.content, title: "Later native instruction" } } });
  fault.mockRestore();
  const changes = await cold();
  const result = await profile.retryPartition(changes, context.commandId, "home");
  expect(await knowledge!.read(current.id)).toEqual(later.record);
  expect(result.changes).toHaveLength(3);
  const audit = (await changes.history({ key: "home.profile.item" })).entries;
  expect(audit.find(entry => entry.qualifiers?.note === current.id)?.after).toMatchObject({ text: originals[0]!.content.title, revisionId: current.revisionId });
  await expect(changes.undo(result.changes[0]!.changeId, { actor: { kind: "ui", id: "fixture" }, commandId: "stale-undo" })).rejects.toThrow(/changed since/);
  expect(await knowledge!.read(current.id)).toEqual(later.record);
  evidence.push({ case: "historical-committed-audit-only-and-stale-undo", audit, current: later.record, canonicalChanges: true });
}, 60_000);

it("invalidates and physically removes the WHOLE opaque audit envelope on forget while preserving unrelated recovery snapshots", async () => {
  const { f, profile, originals, context, request } = await setup("v2");
  const fault = await failPublication(f.settings.settingsChanges.record.path);
  await expect(profile.partition(f.settings.settingsChanges, request, context)).rejects.toThrow("Owned original group publication fault");
  fault.mockRestore();
  const current = await knowledge!.read(originals[0]!.id) as typeof originals[number];
  await knowledge!.forget("forget-original-partition-member", current.id, "Explicit fixture forget", current.revisionId);
  await expect(profile.retryPartition(f.settings.settingsChanges, context.commandId, "home")).rejects.toThrow(/invalidated/);
  const root = join((await f.registry.moduleHost.contract(workspaceModule).describe()).root, "state", "profile", "profile-backups");
  const names = await fs.readdir(root);
  expect(names).toHaveLength(1);
  const bytes = await fs.readFile(join(root, names[0]!), "utf8");
  expect(bytes).not.toContain(context.reason);
  expect(bytes).not.toContain(originals[0]!.content.body);
  expect(bytes).toContain(originals[1]!.content.body);
  expect((JSON.parse(bytes) as { operation?: unknown }).operation).toBeUndefined();
  expect((await fs.stat(join(root, names[0]!))).mode & 0o777).toBe(0o600);
  expect((await knowledge!.read(originals[1]!.id) as typeof originals[number]).content.profile).toEqual({ version: 2, path: ["engineering", "selected-1"] });
  expect((await f.settings.settingsChanges.history({ key: "home.profile.item" })).entries).toEqual([]);
  evidence.push({ case: "forget-invalidates-envelope-without-partial-audit", preservedUnrelatedBackup: true, forgottenEnvelopeRemoved: true });
}, 60_000);

// V2 recovery owns exact postcommit placement/authority/Undo; this matrix isolates
// precommit audit recovery. Knowledge separately covers the postcommit store boundary.
it.each(["before-backup", "after-backup", "mid-body", "precommit"])("preserves one original audit and explicit retry across a real %s process death", async cut => {
  const { f, profile, originals, context, request, cold } = await setup("migration");

  await f.registry.dispose();
  await f.registry.administrativeWorkRegistry.waitUntilSettled();
  await crashProfilePartition(f.root, f.tronHome, request.assignments, cut, undefined, { context });
  const changes = await cold();
  expect((await changes.history({ key: "home.profile.item" })).entries).toEqual([]);
  for (const original of originals) {
    const current = await knowledge!.read(original.id) as typeof original;
    expect(withoutPartition(current)).toEqual(withoutPartition(original));
    if (cut !== "after-commit") expect(current).toEqual(original);
  }
  let savedTime: string | undefined;
  let prepared: string[] | undefined;
  if (cut === "before-backup") await expect(knowledge!.profilePartitionRecovery(context.commandId)).rejects.toThrow(/No backed-up/);
  else {
    const recovered = await knowledge!.profilePartitionRecovery(context.commandId);
    expect(recovered.committed).toBe(cut === "after-commit");
    expect((recovered.envelope as { context: unknown }).context).toEqual(context);
    savedTime = (recovered.envelope as { replayAt: string }).replayAt;
    prepared = recovered.prepared.map(record => record.revisionId);
  }
  const result = cut === "before-backup" ? await profile.partition(changes, request, context) : await profile.retryPartition(changes, context.commandId, context.actor.kind);
  const recovery = await knowledge!.profilePartitionRecovery(context.commandId);
  if (prepared) expect(recovery.prepared.map(record => record.revisionId)).toEqual(prepared);
  const audit = (await changes.history({ key: "home.profile.item" })).entries;
  expect(audit).toHaveLength(3);
  expect(audit.every(entry => entry.commandId === context.commandId && entry.group?.size === 3 && entry.at === (savedTime ?? (recovery.envelope as { replayAt: string }).replayAt))).toBe(true);
  await changes.undo(result.changes[0]!.changeId, { actor: { kind: "ui", id: "fixture" }, commandId: `undo-after-${cut}` });
  for (const original of originals) expect((await knowledge!.read(original.id) as typeof original).content.tags).toEqual(original.content.tags);
  evidence.push({ case: `canonical-process-${cut}`, originalContextPreserved: true, explicitRetryOnly: true, preparedIdentitiesAdopted: prepared !== undefined, groupUndo: true, audit });
}, 60_000);

it("keeps distinct original commands with identical assignments as distinct intents, never adopting another command's prepared identities or context", async () => {
  const { f, profile, originals, context, request, cold } = await setup("migration");

  await f.registry.dispose();
  await f.registry.administrativeWorkRegistry.waitUntilSettled();
  await crashProfilePartition(f.root, f.tronHome, request.assignments, "after-backup", undefined, { context });
  const changes = await cold();
  const first = await knowledge!.profilePartitionRecovery(context.commandId);
  expect(first.committed).toBe(false);
  const secondContext = { ...context, commandId: "distinct-original-command", reason: "A distinct explicit intent" };
  const second = await profile.partition(changes, { ...request, commandId: secondContext.commandId }, secondContext);
  expect(second.changes).toHaveLength(3);
  const recovery = await knowledge!.profilePartitionRecovery(secondContext.commandId);
  expect(recovery.prepared.every(record => !first.prepared.some(prior => prior.revisionId === record.revisionId))).toBe(true);
  expect((recovery.envelope as { context: unknown }).context).toEqual(secondContext);
  await expect(profile.retryPartition(changes, context.commandId, context.actor.kind)).rejects.toThrow(/changed since/);
  const audit = (await changes.history({ key: "home.profile.item" })).entries;
  expect(audit).toHaveLength(3);
  expect(audit.every(entry => entry.commandId === secondContext.commandId && entry.reason === secondContext.reason)).toBe(true);
  for (const original of originals) {
    const current = await knowledge!.read(original.id) as typeof original;
    const destination = request.assignments.find(assignment => assignment.id === original.id)!.path!;
    expect({ ...current, revisionId: original.revisionId }).toEqual({ ...original, content: { ...original.content,
      tags: original.content.tags!.filter(tag => !tag.startsWith("home-file-")), profile: { version: 2, path: destination.split("/") } } });
    expect(await knowledge!.read(original.id, original.revisionId)).toEqual(original);
  }
  evidence.push({ case: "distinct-original-commands-not-assignment-identity", separatePreparedIdentities: true, firstIntentNeverCommitted: true, audit });
}, 60_000);

it("retains original Undo links across a real postcommit Undo crash and cold publication retry", async () => {
  const { f, profile, originals, context, request, cold } = await setup("v2");
  const applied = await profile.partition(f.settings.settingsChanges, request, context);
  const undoContext = { commandId: "original-crashed-undo", actor: { kind: "ui" as const, id: "fixture" }, reason: "Original Undo reason" };

  await f.registry.dispose();
  await f.registry.administrativeWorkRegistry.waitUntilSettled();
  await crashProfilePartition(f.root, f.tronHome, [], "after-commit", undefined, { context: undoContext, undoChangeId: applied.changes[0]!.changeId });
  const changes = await cold();
  const pending = await knowledge!.profilePartitionRecovery(undoContext.commandId);
  expect(pending.committed).toBe(true);
  expect((pending.envelope as { context: unknown }).context).toEqual(undoContext);
  expect((await changes.history({ key: "home.profile.item" })).entries).toHaveLength(3);
  const result = await changes.undo(applied.changes[0]!.changeId, undoContext);
  expect(result.changes).toHaveLength(3);
  const audit = (await changes.history({ key: "home.profile.item" })).entries;
  const undoEntries = audit.filter(entry => entry.undoOf);
  expect(undoEntries.map(entry => entry.undoOf).sort()).toEqual(applied.changes.map(change => change.changeId).sort());
  expect(undoEntries.every(entry => entry.commandId === undoContext.commandId && entry.reason === undoContext.reason && entry.group?.size === 3)).toBe(true);
  for (const original of originals) {
    const now = await knowledge!.read(original.id) as typeof original;
    expect(withoutPartition(now)).toEqual(withoutPartition(original));
    expect(now.content.tags).toEqual(original.content.tags);
  }
  expect((await knowledge!.profilePartitionRecovery(undoContext.commandId)).prepared.map(record => record.revisionId)).toEqual(pending.prepared.map(record => record.revisionId));
  evidence.push({ case: "original-undo-crash-cold-retry", originalUndoOfPreserved: true, domainNotRepeated: true, undoEntries });
}, 60_000);

it("refuses recovery through a replaced backup-directory symlink without publishing or rewriting anything", async () => {
  const { f, profile, context, request } = await setup("v2");
  const applied = await profile.partition(f.settings.settingsChanges, request, context);
  const directory = join((await f.registry.moduleHost.contract(workspaceModule).describe()).root, "state", "profile", "profile-backups");
  const before = await Promise.all(request.assignments.map(item => knowledge!.read(item.id)));
  await fs.rename(directory, `${directory}-original`);
  await fs.symlink(`${directory}-original`, directory, "dir");
  await expect(profile.retryPartition(f.settings.settingsChanges, context.commandId, "home")).rejects.toThrow(/Unsafe profile backup directory/);
  expect(await Promise.all(request.assignments.map(item => knowledge!.read(item.id)))).toEqual(before);
  expect((await f.settings.settingsChanges.history({ key: "home.profile.item" })).entries.map(entry => entry.changeId).sort()).toEqual(applied.changes.map(change => change.changeId).sort());
  evidence.push({ case: "unsafe-recovery-directory-refused", unchangedHeadsAndAudit: true });
}, 60_000);

it("preflights the complete Changes group before backup/body publication", async () => {
  const { f, profile, originals, context, request } = await setup("v2");
  await expect(profile.partition(f.settings.settingsChanges, request, { ...context, reason: "x".repeat(1024 * 1024) })).rejects.toThrow(/bound/);
  for (const record of originals) expect(await knowledge!.read(record.id)).toEqual(record);
  expect((await f.settings.settingsChanges.history({ key: "home.profile.item" })).entries).toEqual([]);
  await expect(knowledge!.profilePartitionRecovery(context.commandId)).rejects.toThrow(/No backed-up/);
  evidence.push({ case: "preflight-before-effects", unchangedHeads: true, canonicalChanges: true });
}, 60_000);
