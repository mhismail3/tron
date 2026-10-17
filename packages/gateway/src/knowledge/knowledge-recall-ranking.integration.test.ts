import { mkdir, mkdtemp, rm, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { afterEach, describe, expect, it } from "vitest";
import { TronWorkspace } from "../workspace/tron-workspace.js";
import { KnowledgeStore } from "./knowledge-store.js";
import { KnowledgeService } from "./knowledge-service.js";
import { KnowledgeObservationService } from "./knowledge-observation.js";

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
    const service = new KnowledgeService(store, new KnowledgeObservationService(store, undefined), {});
    services.push(service);
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
    const config = await store.config();
    await store.configure("enable-observation-test", { ...config, eligibility: { ...config.eligibility, allSessions: true } });
    const range = { sessionId: "synthetic-session", fromEntryId: "entry-1", toEntryId: "entry-1", entryIds: ["entry-1"], entryDigest: "a".repeat(64) };
    const observations = [
      ["old-bottom-blur", "2026-01-02T00:00:00Z", "bottom blur height was 12"],
      ["new-bottom-blur", "2026-02-02T00:00:00Z", "bottom blur height is 16"],
    ] as const;
    for (const [id, observedAt, text] of observations) {
      const observedRange = { ...range, fromEntryId: `entry-${id}`, toEntryId: `entry-${id}`, entryIds: [`entry-${id}`] };
      await store.publishObservationGroup({
        commandId: `publish-${id}`, expectedConfigRevision: (await store.config()).revision,
        coverage: { id: `coverage-${id}`, range: observedRange, disposition: "observed", reason: "terminal:completed" },
        records: [{ id, kind: "observation", scope: "personal", provenance: { actor: "agent", sessionId: range.sessionId, evidence: [] }, relations: [], content: {
          range: observedRange, items: [{ text, attribution: "user", certainty: "certain", observedAt }], observer: { promptVersion: "integration-test" },
        } }],
      });
    }
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

    const outcomes = {
      realLexicalTie: lexicalTie,
      defaultOrder: JSON.stringify(ids) === JSON.stringify([observations[1][0], observations[0][0], source.id, researchNote.id]),
      newestObservationFirst: JSON.stringify(dates) === JSON.stringify([observations[1][1], observations[0][1]]),
      limitedRecallPrefersPersonal: first.records[0]?.id === observations[1][0],
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
    };
    const reportPath = join(process.cwd(), "test-results", "knowledge-recall-ranking", "report.json");
    await mkdir(join(process.cwd(), "test-results", "knowledge-recall-ranking"), { recursive: true });
    await writeFile(reportPath, `${JSON.stringify({ outcomes, tiedScores: scores, observationDates: dates }, null, 2)}\n`);
    expect(outcomes).toEqual(Object.fromEntries(Object.keys(outcomes).map(key => [key, true])));
  });
});
