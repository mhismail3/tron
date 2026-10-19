import { mkdir, mkdtemp, rm, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { afterEach, describe, expect, it } from "vitest";
import { TronWorkspace } from "../workspace/tron-workspace.js";
import { KnowledgeStore } from "./knowledge-store.js";
import { KnowledgeService } from "./knowledge-service.js";
import { seedLegacyChronicle, type LegacyObservationGroup } from "../../test-support/legacy-chronicle.js";

const roots: string[] = [];
const workspaces: TronWorkspace[] = [];
const services: KnowledgeService[] = [];
afterEach(async () => {
  for (const service of services.splice(0)) service.dispose();
  for (const workspace of workspaces.splice(0)) await workspace.dispose();
  for (const root of roots.splice(0)) await rm(root, { recursive: true, force: true });
});

describe("Knowledge unscoped lexical recall ranking", () => {
  it("prefers personal evidence only on unscoped lexical ties while preserving recall controls", async () => {
    const root = await mkdtemp(join(tmpdir(), "tron-knowledge-recall-")); roots.push(root);
    const workspace = new TronWorkspace(join(root, "tron")); workspaces.push(workspace);
    await workspace.initialize();
    const store = new KnowledgeStore(workspace);
    const service = new KnowledgeService(store, {});
    services.push(service);
    // Legacy Chronicle records, as a pre-#1315 observer published them. The
    // fixture must run before other Knowledge writes.
    const range = { sessionId: "synthetic-session", fromEntryId: "entry-1", toEntryId: "entry-1", entryIds: ["entry-1"], entryDigest: "a".repeat(64) };
    const group = (id: string, text: string, observedAt: string): LegacyObservationGroup => {
      const observedRange = { ...range, fromEntryId: `entry-${id}`, toEntryId: `entry-${id}`, entryIds: [`entry-${id}`] };
      return { coverageId: `coverage-${id}`, range: observedRange, records: [{ id, evidence: [], item: { text, attribution: "user", certainty: "certain", observedAt } }] };
    };
    const observations = [
      ["old-bottom-blur", "2026-01-02T00:00:00Z", "bottom blur height was 12"],
      ["new-bottom-blur", "2026-02-02T00:00:00Z", "bottom blur height is 16"],
    ] as const;
    // Observation ranking uses observedAt, so these dates really tie despite
    // distinct write times. Two rejected bodies force raw-key continuation.
    const keyIDs = ["key-order-a", "key-order-b", "key-order-z"];
    const keyObservedAt = "2026-03-02T00:00:00Z";
    await seedLegacyChronicle(workspace, store, { groups: [
      ...observations.map(([id, observedAt, text]) => group(id, text, observedAt)),
      group("isolated-boundary-observation", "isolated boundary evidence", "2026-03-01T00:00:00Z"),
      ...[...keyIDs].reverse().map(id => group(id, "key ordering marker", keyObservedAt)),
    ] });
    // The isolated record's coverage keeps its legacy identity.
    const isolatedCoverageId = "coverage-isolated-boundary-observation";
    const capture = async (id: string, title: string, text: string, scope: "research" | "personal" = "research") => (await store.captureSource({
      commandId: `capture-${id}`, record: {
        kind: "source", id, scope, provenance: { actor: "user", evidence: [] }, relations: [],
        content: { title, text, captureDisposition: "partial", capturedAt: "2026-01-01T00:00:00Z" },
      },
    })).record!;
    const note = async (id: string, scope: "research" | "personal", body: string) => (await store.createNote({
      commandId: `note-${id}`, record: {
        kind: "note", id, scope, provenance: { actor: "user", evidence: [] }, relations: [],
        content: { title: "Synthetic preference", body, role: "preference", confirmed: false },
      },
    })).record!;
    const source = await capture("research-blur-source", "Research", "bottom blur height");
    const researchNote = await note("research-blur-note", "research", "bottom blur height");
    const isolatedEntryMiss = await store.recall({ query: "isolated boundary", entryId: "entry-not-in-current-range", limit: 1 });
    const query = "bottom blur height";
    const scores = (await store.search({ query })).hits.map(hit => ({ id: hit.record.id, score: hit.score }));
    const lexicalTie = scores.length === 4 && scores.every(hit => hit.score === scores[0]?.score);
    const result = await store.recall({ query });
    const ids = result.records.map(record => record.id);
    const dates = result.records.flatMap(record => record.kind === "observation" ? record.content.items.map(item => item.observedAt) : []);
    // Exercise the read tool owner used unchanged by Home, not just store order.
    const rendered = await service.tool({ action: "recall", query });
    const researchOnly = await store.recall({ query, scope: "research" });
    const entryScoped = await store.recall({ query, sessionId: range.sessionId, entryId: `entry-${observations[1][0]}` });
    const first = await store.recall({ query, limit: 1 });
    const olderEntryTopOne = await store.recall({ query, entryId: `entry-${observations[0][0]}`, limit: 1 });
    const nonmatchingSessionTopOne = await store.recall({ query, sessionId: "nonmatching-session", limit: 1 });

    const noteSource = await capture("research-contour-source", "Research", "contour tint");
    const personalNote = await note("personal-contour-note", "personal", "contour tint");
    const noteScores = (await store.search({ query: "contour tint" })).hits;
    const noteRecall = await store.recall({ query: "contour tint" });
    const strongerSource = await capture("stronger-blur-source", query, query);
    const strongerRecall = await store.recall({ query, limit: 1 });
    const strongerScores = (await store.search({ query })).hits;
    const strongerScore = strongerScores.find(hit => hit.record.id === strongerSource.id)?.score;
    const observationScore = scores.find(hit => hit.id === observations[1][0])?.score;
    const personalSource = await capture("personal-blur-source", "Personal source", query, "personal");
    const explicitPersonal = await store.recall({ query, scope: "personal", limit: 1 });
    const queryless = await store.recall({ limit: 1 });
    const hiddenPersonalSources = await store.recall({ query, excludePersonalSources: true });
    const keyHits = (await store.search({ query: "key ordering marker" })).hits;
    const equalTupleOrder = await store.recall({ query: "key ordering marker", limit: 3 });
    const equalTupleContinuation = await store.recall({ query: "key ordering marker", entryId: "entry-key-order-z", limit: 1 });
    // Isolate correction from the stronger lexical source: only this observation
    // matches, and its original coverage still names the old entry.
    const isolatedObservation = await store.read("isolated-boundary-observation");
    if (!isolatedObservation || isolatedObservation.kind !== "observation") throw new Error("Expected isolated observation in recall fixture");
    const correction = await store.correct(`correct-${isolatedObservation.id}`, isolatedObservation.id, isolatedObservation.revisionId, {
      kind: "observation", scope: isolatedObservation.scope, provenance: isolatedObservation.provenance, relations: [],
      content: { ...isolatedObservation.content, range: { ...isolatedObservation.content.range, fromEntryId: "entry-corrected", toEntryId: "entry-corrected", entryIds: ["entry-corrected"] } },
    }, { type: "corrects", recordId: isolatedObservation.id, revisionId: isolatedObservation.revisionId });
    const oldCoverage = (await store.observationCoveragePage()).coverage;
    const correctedOldEntry = await store.recall({ query: "isolated boundary", entryId: "entry-isolated-boundary-observation", limit: 1 });
    const correctedNewEntry = await store.recall({ query: "isolated boundary", entryId: "entry-corrected", limit: 1 });

    const outcomes = {
      realLexicalTie: lexicalTie,
      defaultOrder: JSON.stringify(ids) === JSON.stringify([observations[1][0], observations[0][0], source.id, researchNote.id]),
      newestObservationFirst: JSON.stringify(dates) === JSON.stringify([observations[1][1], observations[0][1]]),
      limitedRecallPrefersPersonal: first.records[0]?.id === observations[1][0],
      olderEntryTopOneRefills: olderEntryTopOne.records[0]?.id === observations[0][0],
      nonmatchingSessionTopOneFallsBack: nonmatchingSessionTopOne.records[0]?.id === source.id,
      toolRendersObservationFirst: rendered.text.indexOf(observations[1][0]) >= 0 && rendered.text.indexOf(observations[1][0]) < rendered.text.indexOf(source.id),
      toolRetainsBothDates: observations.every(([, observedAt]) => rendered.text.includes(observedAt)),
      explicitResearchHonored: JSON.stringify(researchOnly.records.map(record => record.id)) === JSON.stringify([source.id, researchNote.id]),
      entryFilterHonored: JSON.stringify(entryScoped.records.map(record => record.id)) === JSON.stringify([observations[1][0], source.id, researchNote.id]),
      personalNoteHasRealTie: noteScores.length === 2 && noteScores.every(hit => hit.score === noteScores[0]?.score),
      personalNotePreferred: JSON.stringify(noteRecall.records.map(record => record.id)) === JSON.stringify([personalNote.id, noteSource.id]),
      strongerSourceHasHigherScore: strongerScore !== undefined && observationScore !== undefined && strongerScore > observationScore,
      strongerSourceStillWins: strongerRecall.records[0]?.id === strongerSource.id,
      explicitPersonalFreshnessUnchanged: explicitPersonal.records[0]?.id === personalSource.id,
      querylessHasNoFamilyPreference: queryless.records[0]?.kind === "source",
      personalSourceExclusionPreserved: hiddenPersonalSources.records.every(record => record.id !== personalSource.id),
      equalTupleHasRealScoresAndDates: keyHits.length === 3 && new Set(keyHits.map(hit => hit.score)).size === 1 && keyHits.every(hit => hit.record.kind === "observation" && hit.record.content.items.every(item => item.observedAt === keyObservedAt)),
      equalTupleOrderUsesStoredKey: JSON.stringify(equalTupleOrder.records.map(record => record.id)) === JSON.stringify(keyIDs),
      equalTupleRejectsTwoBodiesBeforeKeyContinuation: equalTupleContinuation.records.length === 1 && equalTupleContinuation.records[0]?.id === "key-order-z",
      correctionRetainsOldCoverage: oldCoverage.some(item => item.id === isolatedCoverageId && item.range.entryIds.includes("entry-isolated-boundary-observation")),
      correctedOldEntryIsNoMatch: correctedOldEntry.records.length === 0 && correctedOldEntry.availability === "no-match",
      correctedNewEntryReturnsCurrentRevision: correctedNewEntry.records.length === 1 && correctedNewEntry.records[0]?.id === isolatedObservation.id && correctedNewEntry.records[0]?.revisionId === correction.record?.revisionId,
      exhaustedEntryFilterReturnsNoMatch: isolatedEntryMiss.records.length === 0 && isolatedEntryMiss.availability === "no-match",
    };
    const reportPath = join(process.cwd(), "test-results", "knowledge-recall-ranking", "report.json");
    await mkdir(join(process.cwd(), "test-results", "knowledge-recall-ranking"), { recursive: true });
    const keyTuples = keyHits.map(hit => ({ id: hit.record.id, score: hit.score, dates: hit.record.kind === "observation" ? hit.record.content.items.map(item => item.observedAt) : [] }));
    await writeFile(reportPath, `${JSON.stringify({ outcomes, tiedScores: scores, observationDates: dates, keyTuples }, null, 2)}\n`);
    expect(outcomes).toEqual(Object.fromEntries(Object.keys(outcomes).map(key => [key, true])));
  });
});
