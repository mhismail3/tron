import { createHash } from "node:crypto";
import { mkdir, readFile, writeFile } from "node:fs/promises";
import { expect, it } from "vitest";
import type { NoteContent } from "./profile-note-contract.js";
import { legacyProfileFixture } from "../../../test-support/profile-v1-fixture.js";
import { fixture, homeActivation, profileReportFile, profileSection, readProfilePage, say } from "../../../test-support/home-profile-fixture.js";

profileReportFile("test-results/home-profile/exposure-cases.json");

// Opt-in private snapshot, copied only into a disposable real Gateway fixture.
// No live Knowledge root or external model is used. The artifact contains metrics,
// not the personal note text. Synthetic tests cover the ordinary CI boundary.
it.skipIf(!process.env.TRON_PROFILE_BASELINE)("measures metadata and explicit-read exposure for the retained 21-note snapshot", async () => {
  // The retained export is an active-row projection, not full original records.
  // Its content is exact; missing creation/provenance/history are not invented as evidence.
  const baseline = await readFile(process.env.TRON_PROFILE_BASELINE!, "utf8");
  const records = JSON.parse(baseline) as Array<{ id: string; updatedAt: string; content: NoteContent }>;
  const provenance = { actor: "import" as const, source: "retained-profile-projection", evidence: [] };
  expect(records).toHaveLength(21);
  const f = await fixture("private-exposure");
  for (const [index, value] of records.entries()) {
    await legacyProfileFixture(f.workspace, `exposure-seed-${index}-note`, { kind: "note", id: value.id, scope: "personal", createdAt: value.updatedAt, updatedAt: value.updatedAt, provenance, relations: [], content: value.content });
  }
  const turn = await homeActivation(f, "Inspect discovery metadata only.", [say("index seen")]);
  const index = profileSection(turn.first.systemPrompt);
  const expected = records;
  for (const note of expected) expect(index).not.toContain(note.content.title);
  const pages = [];
  let cursor: string | undefined;
  const pageBytes = [];
  do {
    const page = await readProfilePage(f, "prior", cursor);
    pages.push(...page.items);
    pageBytes.push(Buffer.byteLength(JSON.stringify(page)));
    cursor = page.nextCursor;
  } while (cursor !== undefined);
  expect(pages.map(item => item.id).sort()).toEqual(expected.map(note => note.id).sort());
  for (const original of expected) {
    const read = pages.find(item => item.id === original.id)!;
    expect(read.content).toEqual(original.content);
    expect(read.provenance).toEqual(provenance);
    expect(read.confirmed).toBe(original.content.confirmed);
  }
  await mkdir("test-results/home-profile", { recursive: true });
  await writeFile("test-results/home-profile/exposure.json", JSON.stringify({ source: "retained active-row projection, disposable real Gateway + faux model; exact content exposure, NOT actual provenance/history migration proof", noteCount: expected.length, indexBytes: Buffer.byteLength(index), noteTextBytesAutomaticallyInserted: 0, wholeHomeSystemPromptBytes: Buffer.byteLength(turn.first.systemPrompt), explicitlyReadNotes: pages.length, explicitReadPageBytes: pageBytes, exactProjectedContentPreserved: true, originalProvenanceAndCreationNotPresentInExport: true, fixtureProvenanceExplicitlySynthetic: true, mapping: "all retained legacy notes read under Prior organization; no semantic classification or live mapping applied", baselineSha256: createHash("sha256").update(baseline).digest("hex"), limits: "not a migration or original-provenance/history proof; no whole-prompt/worker before comparison" }, null, 2) + "\n");
});
