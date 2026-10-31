import { randomUUID, createHash } from "node:crypto";
import { chmod, mkdir, mkdtemp, open, readFile, readdir, rm, stat } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { afterEach, expect, it } from "vitest";
import { TronWorkspace } from "../../workspace/tron-workspace.js";
import { ProfileStore } from "./profile-store.js";
import { createProfileFile, profileFileRecords, readProfileFile, writeProfileFile } from "./profile-file.js";
import { boundedProfilePartition } from "../../../test-support/profile-partition-crash.js";
import { legacyProfileFixture } from "../../../test-support/profile-v1-fixture.js";
import type { ProfileNoteNoteMutationRequest } from "./profile-note-contract.js";

const fixtures: Array<{ root: string; workspace: TronWorkspace }> = [];
afterEach(async () => { for (const f of fixtures.splice(0)) { await f.workspace.dispose(); await rm(f.root, { recursive: true, force: true }); } });
async function fixture() {
  const root = await mkdtemp(join(tmpdir(), "tron-current-profile-")), home = join(root, "home"), workspace = new TronWorkspace(home);
  fixtures.push({ root, workspace }); await workspace.initialize();
  return { root, home, workspace, store: new ProfileStore(workspace), path: join((await workspace.describe()).root, "files", "Profile.json") };
}
const draft = (title: string): ProfileNoteNoteMutationRequest["record"] => ({ kind: "note", scope: "personal", provenance: { actor: "user", source: "fixture", evidence: [], reason: "Exact source reason" }, relations: [],
  content: { title, body: "Current body, not an edition ledger.", role: "fact", confirmed: true, tags: ["home-profile", "kind-fact"], profile: { version: 2, path: ["life"] } } });

it("publishes only the current head, refuses old/missing revisions and preserves its durable command fence", async () => {
  const f = await fixture(), request = { commandId: "current-create-command", record: draft("Original statement") };
  const original = (await f.store.createNote(request)).record;
  expect(await f.store.createNote(request)).toMatchObject({ record: original });
  const next = (await f.store.updateNote({ commandId: "current-update-command", recordId: original.id, expectedRevision: original.revisionId,
    record: { ...original, content: { ...original.content, title: "Replacement statement" } } })).record;
  expect(await new ProfileStore(f.workspace).read(original.id)).toEqual(next);
  await expect(f.store.read(original.id, original.revisionId)).rejects.toMatchObject({ code: "conflict", details: { kind: "profile_revision_unavailable" } });
  await expect(f.store.read(randomUUID(), randomUUID())).rejects.toMatchObject({ code: "conflict", details: { kind: "profile_revision_unavailable" } });
  await expect(f.store.createNote(request)).rejects.toMatchObject({ details: { kind: "profile_revision_unavailable" } });
  expect(profileFileRecords((await readProfileFile(f.workspace))!)).toEqual([next]);
  expect(await readFile(f.path, "utf8")).not.toContain(original.content.title);
  expect(await readdir(join(f.path, ".."))).toEqual(["Profile.json"]);
  expect((await stat(f.path)).mode & 0o777).toBe(0o600);
  await expect(stat(join((await f.workspace.describe()).root, "state", "profile"))).rejects.toMatchObject({ code: "ENOENT" });
});

it("serializes conflicting writers without a partial file or extra retained editions", async () => {
  const f = await fixture(), original = (await f.store.createNote({ commandId: "conflict-create-command", record: draft("Initial") })).record;
  const results = await Promise.allSettled(["One", "Two"].map((title, index) => new ProfileStore(f.workspace).updateNote({ commandId: `conflict-update-${index}`, recordId: original.id, expectedRevision: original.revisionId, record: { ...original, content: { ...original.content, title } } })));
  expect(results.filter(result => result.status === "fulfilled")).toHaveLength(1);
  expect(results.filter(result => result.status === "rejected")).toHaveLength(1);
  const file = (await readProfileFile(f.workspace))!;
  expect(profileFileRecords(file)).toHaveLength(1);
  expect(file.anchors).toEqual([]);
  const before = await readFile(f.path);
  await expect(f.store.updateNote({ commandId: "conflict-stale-command", recordId: original.id, expectedRevision: original.revisionId, record: original })).rejects.toThrow(/stale/);
  expect(await readFile(f.path)).toEqual(before);
});

it("keeps Not now until a new note, never reinstating it through receipt replay or edits", async () => {
  const f = await fixture(), original = (await f.store.createNote({ commandId: "sorting-create-command", record: draft("Existing") })).record;
  const version = (await f.store.profileMetadata()).sorting.version;
  const acknowledgement = await f.store.deferProfileSorting("sorting-defer-command", version);
  await f.store.updateNote({ commandId: "sorting-update-command", recordId: original.id, expectedRevision: original.revisionId, record: { ...original, content: { ...original.content, title: "Edited existing note" } } });
  expect((await new ProfileStore(f.workspace).profileMetadata()).sorting.deferred).toBe(true);
  await f.store.createNote({ commandId: "sorting-arrival-command", record: draft("New arrival") });
  expect((await f.store.profileMetadata()).sorting.deferred).toBe(false);
  expect(await f.store.deferProfileSorting("sorting-defer-command", version)).toEqual(acknowledgement);
  expect((await f.store.profileMetadata()).sorting.deferred).toBe(false);
});

it("retains Prior placement as current data and refuses automatic conversion or an empty replacement for lost initialized data", async () => {
  const f = await fixture(), record = draft("Prior exact data"); delete record.content.profile; record.content.tags!.push("home-file-home");
  const prior = await legacyProfileFixture(f.workspace, "prior-fixture-command", record);
  expect(await f.store.read(prior.id)).toEqual(prior);
  expect((await readProfileFile(f.workspace))!.sections.prior!.notes).toHaveLength(1);
  await rm(f.path);
  await expect(f.store.list()).rejects.toThrow(/missing/);
  await mkdir(join((await f.workspace.describe()).root, "state", "profile"), { recursive: true, mode: 0o700 });
  await expect(f.store.list()).rejects.toThrow(/offline Profile cutover/);
  await expect(stat(f.path)).rejects.toMatchObject({ code: "ENOENT" });
});

it("hard-forgets an anchored claim and scrubs its current derivative without an archive lookup or hidden body", async () => {
  const f = await fixture(), claim = (await f.store.createNote({ commandId: "privacy-claim-command", record: draft("Private wrong fixture claim") })).record;
  const correction = draft("A corrected fixture statement"); correction.content.tags = ["home-profile", "kind-correction"]; correction.content.profile = { version: 2, path: ["corrections"] };
  correction.relations = [{ type: "corrects", recordId: claim.id, revisionId: claim.revisionId }];
  const linked = (await f.store.createNote({ commandId: "privacy-correction-command", record: correction })).record;
  const current = (await f.store.updateNote({ commandId: "privacy-advance-command", recordId: claim.id, expectedRevision: claim.revisionId, record: { ...claim, content: { ...claim.content, title: "Current revised claim" } } })).record;
  expect(await f.store.read(claim.id, claim.revisionId)).toEqual(claim);
  await f.store.forget("privacy-forget-command", claim.id, "Explicit fixture privacy removal", current.revisionId);
  await expect(f.store.read(claim.id, claim.revisionId)).rejects.toMatchObject({ details: { kind: "profile_revision_unavailable" } });
  expect(await f.store.read(linked.id, undefined, true)).toBeNull();
  const file = (await readProfileFile(f.workspace))!;
  expect(file.anchors).toEqual([]);
  expect(await readFile(f.path, "utf8")).not.toContain(claim.content.title);
  expect(await readFile(f.path, "utf8")).not.toContain(current.content.title);
  await expect(f.store.createNote({ commandId: "privacy-recreate-command", record: { ...draft("Cannot resurrect"), id: claim.id } })).rejects.toThrow(/forgotten/);
});

it("reads existing over-cap current data but refuses net growth without dropping a head", async () => {
  const f = await fixture(), original = (await f.store.createNote({ commandId: "capacity-base-command", record: draft("Base") })).record;
  const notes = Array.from({ length: 33 }, (_, index) => ({ ...original, id: randomUUID(), revisionId: randomUUID(), content: { ...original.content, title: `Existing leaf ${index}` } }));
  await writeProfileFile(f.workspace, createProfileFile(notes));
  const before = await readFile(f.path);
  await expect(f.store.createNote({ commandId: "capacity-overflow-command", record: draft("No overflow") })).rejects.toThrow(/limit 32/);
  expect(await readFile(f.path)).toEqual(before);
  expect((await f.store.profileMetadata()).rows).toHaveLength(33);
});

it("admits only current data under a real 96 MiB heap despite a sealed 235-by-300000-byte offline history", async () => {
  const f = await fixture(), records = [];
  for (let index = 0; index < 21; index++) { const record = draft(`Current fixture ${index}`); delete record.content.profile; records.push(await legacyProfileFixture(f.workspace, `bounded-fixture-${index}`, record)); }
  const archive = join(f.root, "sealed-offline-history.bin"), handle = await open(archive, "w", 0o600);
  try { const body = Buffer.alloc(300_000, "h"); for (let index = 0; index < 235; index++) await handle.write(body); await handle.sync(); } finally { await handle.close(); }
  const digest = createHash("sha256").update(await readFile(archive)).digest("hex");
  await chmod(archive, 0o000);
  await f.workspace.dispose();
  const assignments = records.map((record, index) => ({ id: record.id, expectedRevision: record.revisionId, path: `engineering/group-${Math.floor(index / 10)}` }));
  const result = await boundedProfilePartition(f.root, f.home, assignments, "migrate");
  expect({ code: result.code, signal: result.signal }).toEqual({ code: 0, signal: null });
  expect(JSON.parse(result.stdout)).toEqual({ status: "committed", changes: 21 });
  await chmod(archive, 0o600);
  expect(createHash("sha256").update(await readFile(archive)).digest("hex")).toBe(digest);
  expect((await stat(archive)).size).toBe(235 * 300_000);
  const reopened = new TronWorkspace(f.home); fixtures.find(item => item.root === f.root)!.workspace = reopened; await reopened.initialize();
  const file = (await readProfileFile(reopened))!;
  expect(profileFileRecords(file)).toHaveLength(21);
  expect(file.anchors).toEqual([]);
  expect(await readdir(join(f.path, ".."))).toEqual(["Profile.json"]);
});
