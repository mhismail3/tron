import { randomUUID } from "node:crypto";
import { mkdtemp, readFile, rename, rm, symlink, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { afterEach, expect, it } from "vitest";
import { TronWorkspace } from "../../workspace/tron-workspace.js";
import { createProfileFile, profileFileRecords, readProfileFile, readProfileFileRecord, writeProfileFile } from "./profile-file.js";
import { type ProfileNoteRecord } from "./profile-note-contract.js";

const owned: Array<{ root: string; workspace: TronWorkspace }> = [];
afterEach(async () => { for (const item of owned.splice(0)) { await item.workspace.dispose(); await rm(item.root, { recursive: true, force: true }); } });
async function fixture() {
  const root = await mkdtemp(join(tmpdir(), "tron-profile-file-"));
  const workspace = new TronWorkspace(root);
  owned.push({ root, workspace });
  await workspace.initialize();
  return { root, workspace, path: join(root, "workspace", "files", "Profile.json") };
}
function note(title: string): ProfileNoteRecord {
  return { schemaVersion: 1, id: randomUUID(), revisionId: randomUUID(), kind: "note", scope: "personal",
    createdAt: "2026-01-01T00:00:00.000Z", updatedAt: "2026-01-01T00:00:00.000Z",
    provenance: { actor: "user", source: "fixture", reason: "Exact fixture provenance", evidence: [] }, relations: [],
    content: { title, role: "fact", confirmed: true, tags: ["home-profile", "kind-fact"], profile: { version: 2, path: ["engineering", "tests"] } } };
}

it("stores one hierarchical file, resolves only the current head or an exact linked claim, and retains no other historical body", async () => {
  const f = await fixture();
  const wrong = note("Original wrong claim");
  const unanchored = { ...wrong, revisionId: randomUUID(), content: { ...wrong.content, title: "Unreferenced intermediate text" } };
  const current = { ...wrong, revisionId: randomUUID(), content: { ...wrong.content, title: "Current revised statement" } };
  const correction = { ...note("Exact correction of the original claim"), content: { title: "Exact correction of the original claim", role: "fact" as const,
    confirmed: false, tags: ["home-profile", "kind-correction"], profile: { version: 2 as const, path: ["corrections"] } },
    relations: [{ type: "corrects" as const, recordId: wrong.id, revisionId: wrong.revisionId }] };
  await writeProfileFile(f.workspace, createProfileFile([current, correction], { anchorCandidates: [wrong, unanchored], stateRevision: 3 }));
  const bytes = await readFile(f.path, "utf8");
  expect(bytes).not.toContain(unanchored.content.title);
  const file = (await readProfileFile(f.workspace))!;
  expect(file.anchors).toEqual([wrong]);
  expect(readProfileFileRecord(file, wrong.id)).toEqual(current);
  expect(readProfileFileRecord(file, wrong.id, wrong.revisionId)).toEqual(wrong);
  expect(readProfileFileRecord(file, correction.id)?.relations).toEqual(correction.relations);
  expect(() => readProfileFileRecord(file, wrong.id, unanchored.revisionId)).toThrow(expect.objectContaining({ code: "conflict", details: { kind: "profile_revision_unavailable", id: wrong.id, revisionId: unanchored.revisionId } }));
  expect(() => readProfileFileRecord(file, randomUUID(), randomUUID())).toThrow(expect.objectContaining({ code: "conflict", details: expect.objectContaining({ kind: "profile_revision_unavailable" }) }));
});

it("retains Prior placement, Unsorted, Not now, retirement and full provenance without inventing a destination", async () => {
  const f = await fixture();
  const prior = note("Prior organization retained");
  delete prior.content.profile;
  prior.content.tags!.push("home-file-core");
  const inferred = note("Unconfirmed proposal");
  inferred.content.confirmed = false;
  inferred.content.profile = { version: 2, path: ["inferred", "review"] };
  const retired = note("Retired record with its reason");
  retired.content.retired = true;
  retired.provenance.reason = "Maintainer retained this retirement reason";
  const deferred = "a".repeat(64);
  await writeProfileFile(f.workspace, createProfileFile([prior, inferred, retired], { deferred }));
  const reopened = (await readProfileFile(f.workspace))!;
  expect(reopened.deferred).toBe(deferred);
  expect(profileFileRecords(reopened).sort((a, b) => a.id.localeCompare(b.id))).toEqual([prior, inferred, retired].sort((a, b) => a.id.localeCompare(b.id)));
  expect(reopened.sections.prior!.notes).toHaveLength(1);
  expect(reopened.sections.inferred!.children.review!.notes).toHaveLength(1);
  expect(reopened.sections.prior!.notes[0]!.content).not.toHaveProperty("profile");
});

it("refuses missing claim anchors and hidden unreferenced historical data instead of returning an empty Profile", async () => {
  const f = await fixture();
  const claim = note("Claim whose body must not be silently lost");
  const correction = note("Correction still linked");
  correction.relations = [{ type: "corrects", recordId: claim.id, revisionId: claim.revisionId }];
  expect(() => createProfileFile([correction])).toThrow("no exact claim anchor");
  await writeProfileFile(f.workspace, createProfileFile([claim]));
  const raw = JSON.parse(await readFile(f.path, "utf8"));
  raw.anchors.push(note("Unreferenced hidden historical body"));
  await writeFile(f.path, JSON.stringify(raw));
  await expect(readProfileFile(f.workspace)).rejects.toMatchObject({ code: "conflict", details: { kind: "profile_file_invalid" } });
});

it("uses the hierarchy as the sole placement authority including inherited Object property names", async () => {
  const f = await fixture();
  const record = note("Constructor is a valid literal sub-area");
  record.content.profile = { version: 2, path: ["engineering", "constructor"] };
  await writeProfileFile(f.workspace, createProfileFile([record]));
  expect(profileFileRecords((await readProfileFile(f.workspace))!)).toEqual([record]);
  const raw = JSON.parse(await readFile(f.path, "utf8"));
  raw.sections.engineering.children.constructor.notes[0].content.profile = { version: 2, path: ["life"] };
  await writeFile(f.path, JSON.stringify(raw));
  await expect(readProfileFile(f.workspace)).rejects.toMatchObject({ code: "conflict", details: { kind: "profile_file_invalid" } });
});

it("keeps a shared claim until its last current Correction link is removed, then releases the old body in one published file", async () => {
  const f = await fixture();
  const claim = note("Old wrong claim that must leave the current file after its last link");
  const head = { ...claim, revisionId: randomUUID(), content: { ...claim.content, title: "Current replacement claim" } };
  const corrections = [note("First correction"), note("Second correction")];
  for (const correction of corrections) {
    correction.content.confirmed = false;
    correction.content.tags = ["home-profile", "kind-correction"];
    correction.content.profile = { version: 2, path: ["corrections"] };
    correction.relations = [{ type: "corrects", recordId: claim.id, revisionId: claim.revisionId }];
  }
  await writeProfileFile(f.workspace, createProfileFile([head, ...corrections], { anchorCandidates: [claim] }));
  const initial = (await readProfileFile(f.workspace))!;
  await writeProfileFile(f.workspace, createProfileFile([head, corrections[1]!], { anchorCandidates: initial.anchors }));
  const remaining = (await readProfileFile(f.workspace))!;
  expect(readProfileFileRecord(remaining, claim.id, claim.revisionId)).toEqual(claim);
  await writeProfileFile(f.workspace, createProfileFile([head], { anchorCandidates: remaining.anchors }));
  const released = (await readProfileFile(f.workspace))!;
  expect(released.anchors).toEqual([]);
  expect(await readFile(f.path, "utf8")).not.toContain(claim.content.title);
  expect(() => readProfileFileRecord(released, claim.id, claim.revisionId)).toThrow(expect.objectContaining({ code: "conflict", details: expect.objectContaining({ kind: "profile_revision_unavailable" }) }));
});

it("never follows a substituted files directory to publish Profile", async () => {
  const f = await fixture();
  await writeProfileFile(f.workspace, createProfileFile([note("Owned file")]));
  await rename(join(f.root, "workspace", "files"), join(f.root, "workspace", "files-real"));
  await symlink(join(f.root, "workspace", "files-real"), join(f.root, "workspace", "files"));
  await expect(writeProfileFile(f.workspace, createProfileFile([note("Must not publish through symlink")]))).rejects.toMatchObject({ code: "conflict" });
});
