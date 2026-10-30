import { expect, it } from "vitest";
import { rename } from "node:fs/promises";
import { dirname, join } from "node:path";
import { legacyProfileFixture } from "../../../test-support/profile-v1-fixture.js";
import { waitFor } from "../../../test-support/wait-for.js";
import { answerChangeCard } from "../../../test-support/native-change.js";
import { fixture, homeActivation, profileCall, say, command, history, undo, profileReportFile, recordCase, maintainer } from "../../../test-support/home-profile-fixture.js";
import type { ProfileNoteRecord } from "./profile-note-contract.js";

profileReportFile("test-results/home-profile/you-centred.json");

it("migrates exact legacy placement through a real Home activation and Changes Undo restores its exact tags and prior organization", async () => {
  const f = await fixture("you-centred-migrate");
  const original = await legacyProfileFixture(f.store, command("legacy-seed"), {
    kind: "note", scope: "personal", provenance: { actor: "agent", source: "home", evidence: [], reason: "Original inferred capture" }, relations: [],
    content: { title: "Prefers concise questions.", body: "Keep this exact body.", role: "fact", confirmed: false,
      tags: ["fixture-first", "home-file-home", "home-profile", "kind-fact", "fixture-last"] },
  });
  const retired = await legacyProfileFixture(f.store, command("legacy-retired"), { kind: "note", scope: "personal", provenance: { actor: "agent", source: "home", evidence: [] }, relations: [], content: { title: "An inactive original stays byte-for-byte unchanged.", role: "fact", confirmed: false, retired: true, tags: ["home-profile", "kind-fact", "home-file-home"] } });
  const turn = homeActivation(f, "Sort this inferred nonbinding note without changing its content.", [
    profileCall({ action: "migrate", assignments: [{ id: original.id, expectedRevision: original.revisionId, path: "communication/questions" }], reason: "File the original inferred capture" }, "you-centred-migrate"), say("sorted"),
  ]);
  const { response } = await answerChangeCard(f.service, maintainer, f.slot, true, command("approve-migration"));
  await response;
  const result = (await turn).last.messages.find(message => message.role === "toolResult" && message.toolCallId === "you-centred-migrate")?.details as { status: string };
  expect(result.status).toBe("organized");
  const migrated = await f.store.read(original.id) as typeof original;
  expect(migrated.content).toEqual({ ...original.content, tags: original.content.tags!.filter(tag => !tag.startsWith("home-file-")), profile: { version: 2, path: ["communication", "questions"] } });
  expect({ ...migrated, revisionId: original.revisionId, content: original.content }).toEqual(original);
  expect(await f.store.read(original.id, original.revisionId)).toEqual(original);
  const audit = await history(f);
  expect(audit).toHaveLength(1);
  expect(audit[0]).toMatchObject({ before: { fileLabels: [{ index: 1, tag: "home-file-home" }] }, after: { profile: { version: 2, path: ["communication", "questions"] } } });
  await undo(f, audit[0]!.changeId, "you-centred-undo");
  const restored = await f.store.read(original.id) as typeof original;
  expect({ ...restored, revisionId: original.revisionId }).toEqual(original);
  const listed = await f.service.invoke(maintainer, "home.profileList", {}) as unknown;
  expect(JSON.stringify(listed)).toContain("prior");
  expect(await f.store.read(retired.id)).toEqual(retired);
  recordCase("v2-migration-exact-v1-undo", { originalId: original.id, originalRevision: original.revisionId, migratedRevision: migrated.revisionId, restoredRevision: restored.revisionId, exactTextAndProvenance: true });
}, 120_000);

it("supersedes only after an exact tap, preserves placement, and stale approval never overwrites a concurrent native edit", async () => {
  const f = await fixture("you-centred-approval");
  const original = (await f.store.createNote({ commandId: command("confirmed-seed"), record: { kind: "note", scope: "personal", provenance: { actor: "user", source: "fixture", evidence: [] }, relations: [], content: { title: "Keep unique work.", role: "decision", confirmed: true, tags: ["home-profile", "kind-standing-decision"], profile: { version: 2, path: ["engineering", "collaboration"] } } } })).record as Extract<ProfileNoteRecord, { kind: "note" }>;
  const proposed = homeActivation(f, "Consider moving the note.", [profileCall({ action: "reorganize", assignments: [{ id: original.id, expectedRevision: original.revisionId, path: "resources/cleanup" }], reason: "Exact organization proposal" }, "stale-approval"), say("the stale card applied nothing; original placement stays")]);
  const stale = await waitFor(() => f.slot.snapshot().extensionPresentation.pendingInteractions.find(item => item.method === "change"), "Home's exact organization card");
  expect(await f.store.read(original.id)).toEqual(original);
  const edited = (await f.store.updateNote({ commandId: command("native-concurrent"), recordId: original.id, expectedRevision: original.revisionId, record: { ...original, content: { ...original.content, title: "Keep every unique checkpoint." } } })).record;
  const { interaction, response } = await answerChangeCard(f.service, maintainer, f.slot, true, command("stale-decision"));
  expect(interaction.id).toBe(stale.id);
  await expect(response).rejects.toThrow(/changed since this exact/);
  await proposed;
  expect(await f.store.read(original.id)).toEqual(edited);
  const replacement = homeActivation(f, "Propose a replacement in the same area.", [profileCall({ action: "supersede", id: original.id, kind: "standing-decision", text: "Preserve all unique work and checkpoints.", reason: "Exact replacement reviewed by the maintainer" }, "replacement-approval"), say("The exact replacement was approved.")]);
  await (await answerChangeCard(f.service, maintainer, f.slot, true, command("replacement-decision"))).response;
  expect((await replacement).last.messages.find(message => message.role === "toolResult" && message.toolCallId === "replacement-approval")?.details).toMatchObject({ status: "saved", action: "supersede" });
  const notes = (await f.store.list({ kind: "note", scope: "personal" })).records.filter((note): note is Extract<ProfileNoteRecord, { kind: "note" }> => note.kind === "note");
  const successor = notes.find(note => note.id !== original.id)!;
  expect(successor.content.profile).toEqual(original.content.profile);
  expect(successor.relations).toContainEqual({ type: "supersedes", recordId: original.id, revisionId: edited.revisionId });
  recordCase("approval-stale-fence-and-supersede-placement", { unchangedOnStaleApproval: true, successorId: successor.id, pathPreserved: true });
}, 120_000);

it("exposes eight unsorted notes at a maintainer turn without bodies, and refuses a nine-note sorting batch without effects", async () => {
  const f = await fixture("you-centred-triage");
  const originals: ProfileNoteRecord[] = [];
  for (let index = 0; index < 8; index++) originals.push((await f.store.createNote({ commandId: command("triage-seed"), record: { kind: "note", scope: "personal", provenance: { actor: "agent", source: "home", evidence: [] }, relations: [], content: { title: `Private inferred note ${index}.`, role: "fact", confirmed: false, tags: ["home-profile", "kind-fact"], profile: { version: 2, path: ["inferred", "review"] } } } })).record);
  const turn = await homeActivation(f, "Start an ordinary maintainer turn.", [profileCall({ action: "read" }, "triage-index"), say("Would you like to sort up to eight notes?")]);
  const index = turn.last.messages.find(message => message.role === "toolResult" && message.toolCallId === "triage-index")?.details as { index: string };
  expect(index.index).toContain("Unsorted active: 8");
  expect(Buffer.byteLength(index.index)).toBeLessThanOrEqual(8192);
  for (const note of originals) if (note.kind === "note") { expect(turn.first.systemPrompt).not.toContain(note.content.title); expect(index.index).not.toContain(note.content.title); }
  const suppressed = await homeActivation(f, "Not now. Do not suggest sorting again until a new note arrives.", [say("Understood.")]);
  for (const note of originals) expect(await f.store.read(note.id)).toEqual(note);
  expect(JSON.stringify(suppressed.first.messages)).toContain("Not now");
  const denied = await homeActivation(f, "Do not apply an over-size proposal.", [profileCall({ action: "reorganize", assignments: [...originals, originals[0]!].map(note => ({ id: note.id, expectedRevision: note.revisionId, path: "communication/answers" })), reason: "Nine is above the sorting batch limit" }, "triage-nine"), say("not applied")]);
  const refused = denied.last.messages.find(message => message.role === "toolResult" && message.toolCallId === "triage-nine")?.details as { status: string; reason: string };
  expect(refused.reason).toContain("at most 8");
  for (const note of originals) expect(await f.store.read(note.id)).toEqual(note);
  recordCase("triage-threshold-metadata-and-batch-cap", { unsorted: originals.length, indexBytes: Buffer.byteLength(index.index), oversizedBatchUnchanged: true, suppression: "conversation evidence and prompt guidance; faux model is not behavioral proof of semantic discretion" });
}, 120_000);

it("discovers SQL profile metadata without immutable bodies, bounds query-fenced pages, and links and protects a confirmed correction", async () => {
  const f = await fixture("you-centred-pages");
  const originals: Array<Extract<ProfileNoteRecord, { kind: "note" }>> = [];
  for (let index = 0; index < 21; index++) originals.push((await f.store.createNote({ commandId: command("page-seed"), record: { kind: "note", scope: "personal", provenance: { actor: "agent", source: "home", evidence: [] }, relations: [], content: { title: `Opaque statement ${index}.`, body: "x".repeat(index === 20 ? 40_000 : 500), role: "fact", confirmed: false, tags: ["home-profile", "kind-fact"], profile: { version: 2, path: ["engineering", index === 20 ? "large" : "pages"] } } } })).record as Extract<ProfileNoteRecord, { kind: "note" }>);
  const large = originals[20]!;
  const bodyPath = join(dirname(f.project), "tron", "workspace", "state", "profile", "records", large.id, `${large.revisionId}.json`);
  await rename(bodyPath, `${bodyPath}.hidden`);
  try {
    const discovery = await homeActivation(f, "Read only metadata and a disjoint path.", [profileCall({ action: "read" }, "bodyless-index"), profileCall({ action: "read", path: "engineering/pages" }, "first-page"), say("Read.")]);
    const metadata = discovery.last.messages.find(message => message.role === "toolResult" && message.toolCallId === "bodyless-index")?.details as { index: string };
    expect(metadata.index).toContain("Engineering");
    expect(metadata.index).not.toContain(large.content.title);
    const page = discovery.last.messages.find(message => message.role === "toolResult" && message.toolCallId === "first-page")?.details as { status: string; items: Array<{ id: string }>; nextCursor: string };
    expect(page.status).toBe("read"); expect(page.items.length).toBe(16);
    expect(Buffer.byteLength(JSON.stringify(page))).toBeLessThanOrEqual(32 * 1024);
    const next = await homeActivation(f, "Continue the same page.", [profileCall({ action: "read", path: "engineering/pages", cursor: page.nextCursor }, "next-page"), say("Read.")]);
    const continuation = next.last.messages.find(message => message.role === "toolResult" && message.toolCallId === "next-page")?.details as typeof page;
    expect(continuation.items.length).toBe(4);
    expect(new Set([...page.items, ...continuation.items].map(item => item.id)).size).toBe(20);
    const changed = originals[0]!;
    await f.store.updateNote({ commandId: command("invalidate-page"), recordId: changed.id, expectedRevision: changed.revisionId, record: { ...changed, content: { ...changed.content, title: "A changed canonical statement." } } });
    const stale = await homeActivation(f, "An old cursor must not silently mix snapshots.", [profileCall({ action: "read", path: "engineering/pages", cursor: page.nextCursor }, "stale-page"), say("Restart.")]);
    const refusal = stale.last.messages.find(message => message.role === "toolResult" && message.toolCallId === "stale-page")?.details as { status: string; reason: string };
    expect(refusal.status).toBe("refused"); expect(refusal.reason).toContain("snapshot changed");
  } finally { await rename(`${bodyPath}.hidden`, bodyPath); }
  const linked = await homeActivation(f, "This is the corrected claim; propose it in Corrections.", [profileCall({ action: "read", path: "engineering/large" }, "large-page"), profileCall({ action: "learn", kind: "correction", text: "The large example is a synthetic claim, not personal truth.", corrects: { id: large.id, revisionId: large.revisionId } }, "linked-correction"), say("Proposed.")]);
  const referenced = linked.last.messages.find(message => message.role === "toolResult" && message.toolCallId === "large-page")?.details as { items: Array<{ contentReference: { id: string; revisionId: string } }> };
  expect(referenced.items[0]!.contentReference).toMatchObject({ tool: "profile", action: "read", id: large.id, revisionId: large.revisionId });
  const saved = linked.last.messages.find(message => message.role === "toolResult" && message.toolCallId === "linked-correction")?.details as { status: string; id: string };
  expect(saved.status).toBe("saved");
  const correction = await f.store.read(saved.id) as Extract<ProfileNoteRecord, { kind: "note" }>;
  expect(correction.relations).toContainEqual({ type: "corrects", recordId: large.id, revisionId: large.revisionId });
  expect(correction.content.profile?.path).toEqual(["corrections"]);
  await f.service.invoke(maintainer, "home.profileChange", { commandId: command("confirm-correction"), changes: [{ action: "confirm", id: correction.id, expectedRevision: correction.revisionId }] });
  const confirmed = await f.store.read(correction.id) as typeof correction; expect(confirmed.content.confirmed).toBe(true);
  const attempted = homeActivation(f, "An inferred rewrite must not override my confirmed correction.", [profileCall({ action: "refine", id: correction.id, text: "A different inferred correction.", reason: "A proposal, not permission" }, "correction-hold"), say("Declined.")]);
  expect(await f.store.read(correction.id)).toEqual(confirmed);
  await (await answerChangeCard(f.service, maintainer, f.slot, false, command("decline-correction"))).response;
  const hold = (await attempted).last.messages.find(message => message.role === "toolResult" && message.toolCallId === "correction-hold")?.details as { status: string };
  expect(hold.status).toBe("declined"); expect(await f.store.read(correction.id)).toEqual(confirmed);
  recordCase("metadata-pages-and-confirmed-correction", { disjointMissingBodyReadSucceeded: true, pageSizes: [16, 4], staleCursorRefused: true, largeReferenceExact: true, linkedCorrectionHeldForExactCard: true });
}, 120_000);

it("reads an oversized exact Profile reference through the surviving tool without truncation or split Unicode", async () => {
  const f = await fixture("exact-profile-reference");
  const { record } = await f.store.createNote({ commandId: command("exact-reference-seed"), record: {
    kind: "note", scope: "personal", provenance: { actor: "user", evidence: [] }, relations: [],
    content: { title: "Exact large Profile record", body: "x".repeat(20_000) + "🙂".repeat(5_000), role: "preference", confirmed: false,
      tags: ["home-profile", "kind-preference"], profile: { version: 2, path: ["inferred", "review"] } },
  } });
  const revisionBefore = (await f.store.list({ limit: 1 })).stateRevision;
  let offset = 0, assembled = "", parts = 0;
  for (;;) {
    const call = `exact-profile-part-${parts}`;
    const turn = await homeActivation(f, "Read the selected exact Profile reference.", [profileCall({ action: "read", id: record.id, revisionId: record.revisionId, contentOffset: offset }, call), say("Read.")]);
    const result = turn.last.messages.find(message => message.role === "toolResult" && message.toolCallId === call);
    const details = result?.details as { status: string; id: string; revisionId: string; offset: number; chunk: string; totalChars: number; nextOffset?: number };
    expect(details).toMatchObject({ status: "read-record", id: record.id, revisionId: record.revisionId, offset });
    expect(Buffer.byteLength(JSON.stringify(result))).toBeLessThan(32 * 1_024);
    expect(details.chunk).not.toMatch(/[\ud800-\udbff]$|^[\udc00-\udfff]/u);
    assembled += details.chunk; parts += 1;
    if (details.nextOffset === undefined) { expect(assembled.length).toBe(details.totalChars); break; }
    expect(details.nextOffset).toBeGreaterThan(offset);
    offset = details.nextOffset;
    expect(parts).toBeLessThan(32);
  }
  expect(parts).toBeGreaterThan(1);
  expect(JSON.parse(assembled)).toEqual(record);
  expect((await f.store.list({ limit: 1 })).stateRevision).toBe(revisionBefore);
}, 120_000);
