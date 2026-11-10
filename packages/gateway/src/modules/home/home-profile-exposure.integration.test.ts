import { mkdir, writeFile } from "node:fs/promises";
import { expect, it } from "vitest";
import type { ProfileNoteRecord, ProfileNoteRecordDraft } from "./profile-note-contract.js";
import { fixture, homeActivation, profileCall, profileReportFile, profileSection, readProfilePage, say } from "../../../test-support/home-profile-fixture.js";

profileReportFile("test-results/home-profile/exposure-cases.json");

const syntheticNotes: ProfileNoteRecordDraft[] = Array.from({ length: 21 }, (_, index) => ({
  id: `synthetic-exposure-${String(index).padStart(2, "0")}`,
  kind: "note", scope: "personal",
  provenance: { actor: index % 2 === 0 ? "user" : "agent", source: "synthetic-exposure",
    evidence: [{ sessionEntry: { sessionId: "synthetic-session", entryId: `synthetic-entry-${index}` } }] },
  relations: [],
  content: {
    title: `Synthetic exposure title ${index}`,
    body: `Synthetic exposure body ${index}: preserve exact explicit-read content, never automatic insertion.`,
    role: "fact", confirmed: index % 2 === 0,
    tags: ["home-profile", index === 20 ? "kind-correction" : "kind-fact"],
    profile: { version: 2, path: index < 17 ? ["engineering", "review"]
      : index === 18 ? ["inferred", "review"] : index === 20 ? ["corrections"] : ["life"] },
    ...(index === 19 ? { retired: true } : {}),
  },
}));

it("keeps a synthetic 21-note current Profile metadata-only and preserves every explicit read", async () => {
  const f = await fixture("synthetic-exposure");
  const records: ProfileNoteRecord[] = [];
  for (const [index, value] of syntheticNotes.entries()) {
    const draft = structuredClone(value);
    if (index === 20) draft.relations = [{ type: "corrects", recordId: records[0]!.id, revisionId: records[0]!.revisionId }];
    const { record } = await f.store.createNote({ commandId: `synthetic-exposure-seed-${index}`, record: draft });
    records.push(record);
  }
  expect(records).toHaveLength(21);
  const turn = await homeActivation(f, "Inspect discovery metadata only.", [say("index seen")]);
  const index = profileSection(turn.first.systemPrompt);
  for (const note of records) {
    expect(index).not.toContain(note.content.title);
    expect(index).not.toContain(note.content.body);
  }
  const pages = [];
  const pageBytes: number[] = [];
  let engineeringPages = 0;
  for (const path of ["engineering", "life", "inferred", "corrections"]) {
    let cursor: string | undefined;
    do {
      const page = await readProfilePage(f, path, cursor, true);
      pages.push(...page.items);
      pageBytes.push(Buffer.byteLength(JSON.stringify(page)));
      if (path === "engineering") engineeringPages += 1;
      cursor = page.nextCursor;
    } while (cursor !== undefined);
  }
  expect(engineeringPages).toBe(2);
  expect(pages.map(item => item.id).sort()).toEqual(records.map(note => note.id).sort());
  for (const original of records) {
    const read = pages.find(item => item.id === original.id)!;
    expect(read.revisionId).toBe(original.revisionId);
    expect(read.content).toEqual(original.content);
    expect(read.provenance).toEqual(original.provenance);
    expect(read.confirmed).toBe(original.content.confirmed);
    expect(read.status).toBe(original.content.retired ? "retired" : "active");
  }
  expect((await readProfilePage(f, "life")).items.map(item => item.id)).toEqual([records[17]!.id]);
  const correction = pages.find(item => item.id === records[20]!.id)!;
  const exactTurn = await homeActivation(f, "Read the exact Correction.", [
    profileCall({ action: "read", id: correction.id, revisionId: correction.revisionId }, "synthetic-correction-read"), say("read"),
  ]);
  const exact = exactTurn.last.messages.find(message => message.role === "toolResult" && message.toolCallId === "synthetic-correction-read")?.details as { status: string; chunk: string; nextOffset?: number };
  expect(exact.status).toBe("read-record");
  expect(exact.nextOffset).toBeUndefined();
  expect(JSON.parse(exact.chunk)).toEqual(records[20]);
  expect(JSON.parse(exact.chunk).relations).toEqual([{ type: "corrects", recordId: records[0]!.id, revisionId: records[0]!.revisionId }]);
  await mkdir("test-results/home-profile", { recursive: true });
  await writeFile("test-results/home-profile/exposure.json", JSON.stringify({
    source: "committed synthetic current Profile.json fixture; disposable real Gateway + faux model",
    noteCount: records.length, indexBytes: Buffer.byteLength(index), noteTextBytesAutomaticallyInserted: 0,
    wholeHomeSystemPromptBytes: Buffer.byteLength(turn.first.systemPrompt), explicitlyReadNotes: pages.length,
    explicitReadPageBytes: pageBytes, exactContentAndProvenancePreserved: true,
    engineeringPages, inactiveReadExplicit: true, correctionClaimLinked: true,
    limits: "synthetic current-file exposure proof, not private-data migration or original-provenance proof",
  }, null, 2) + "\n");
});
