/**
 * Chronicle generation is retired (#1315); its history is not.
 *
 * A real RuntimeRegistry and faux chat model run over a Knowledge namespace that
 * a pre-#1315 Gateway left behind: Chronicle enabled with the global grant,
 * observed v2 records citing a real canonical entry, and pending/failed gaps.
 * The journey fails if a settled conversation turn still produces observation
 * records, coverage cuts or background work; if the retired configuration keeps
 * steering behavior or survives the next config write; or if any legacy
 * record, revision, citation, coverage row, reflection, correction or privacy
 * exclusion stops working through its existing reader.
 *
 * The retained artifact is `test-results/legacy-chronicle/report.json`.
 */
import { mkdir, mkdtemp, readFile, rm, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { ModelRuntime } from "@earendil-works/pi-coding-agent";
import { fauxAssistantMessage, fauxProvider } from "@earendil-works/pi-ai";
import { afterEach, describe, expect, it } from "vitest";
import { TrustService } from "../admin/trust-service.js";
import { KnowledgeStore } from "../knowledge/knowledge-store.js";
import { KnowledgeService } from "../knowledge/knowledge-service.js";
import type { KnowledgeRecord } from "../knowledge/knowledge-contract.js";
import { RuntimeRegistry } from "./runtime-registry.js";
import { waitFor } from "../../test-support/wait-for.js";
import { LEGACY_CHRONICLE_CONFIG, legacyEntriesDigest, persistedKnowledgeConfig, seedLegacyChronicle } from "../../test-support/legacy-chronicle.js";

describe("retired Chronicle generation over preserved legacy history", { concurrent: false }, () => {
  const cleanup: Array<() => Promise<void>> = [];
  const originalAgentDir = process.env.PI_CODING_AGENT_DIR;
  afterEach(async () => {
    for (const release of cleanup.splice(0).reverse()) await release();
    if (originalAgentDir === undefined) delete process.env.PI_CODING_AGENT_DIR;
    else process.env.PI_CODING_AGENT_DIR = originalAgentDir;
  });

  it("generates nothing on settled turns and keeps every legacy reader, citation and exclusion", async () => {
    const root = await mkdtemp(join(tmpdir(), "tron-legacy-chronicle-"));
    cleanup.push(() => rm(root, { recursive: true, force: true }));
    const agentDir = join(root, "agent");
    const cwd = join(root, "project");
    await Promise.all([mkdir(agentDir), mkdir(cwd)]);
    process.env.PI_CODING_AGENT_DIR = agentDir;
    await writeFile(join(agentDir, "settings.json"), JSON.stringify({ retry: { enabled: false }, compaction: { enabled: false } }));
    const runtime = await ModelRuntime.create({ modelsPath: null, refreshOnCreate: false });
    const faux = fauxProvider({ provider: "tron-legacy-chronicle", tokensPerSecond: 100_000 });
    faux.setResponses([
      fauxAssistantMessage("LEGACY-DECISION: keep the bottom blur at 16 points."),
      fauxAssistantMessage("Noted, replies stay concise."),
    ]);
    runtime.registerNativeProvider(faux.provider);
    const registry = new RuntimeRegistry({
      agentDir, tronHome: join(root, "tron"), idleRuntimeMs: 60_000,
      modelRuntimeFactory: async () => runtime, trust: new TrustService(agentDir),
      broadcast: () => {}, sessionSummaryChanged: () => {}, sessionListChanged: () => {},
    });
    cleanup.push(() => registry.dispose());
    const workspace = registry.knowledgeWorkspace();
    const store = new KnowledgeStore(workspace);
    // Reflection is an explicit reader of legacy observations; its model is a
    // deterministic stand-in for the background queue.
    const reflections: string[] = [];
    const reflectionModel = {
      reflect: async (input: { sourceText: string }) => { reflections.push(input.sourceText); return "Reflected handoff over the legacy decision."; },
      synthesize: async () => "unused", summarizeSource: async () => ({ text: "unused", model: "unused" }),
      assess: async () => { throw new Error("unused"); },
    };
    const knowledge = new KnowledgeService(store, {}, () => reflectionModel as never);
    registry.setKnowledgeService(knowledge);
    await registry.initialize();
    const slot = await registry.create(cwd);
    const model = faux.getModel();
    await slot.setModel(model.provider, model.id);

    // The historical turn a pre-#1315 observer had cited.
    await slot.prompt("What did we decide about the bottom blur?");
    await waitFor(() => !slot.isBusy, "the historical turn to settle");
    const anchor = slot.canonicalSessionEntries().find(entry => entry.type === "message" && entry.message.role === "assistant");
    if (!anchor) throw new Error("fixture has no historical answer");
    const digest = legacyEntriesDigest([anchor]);
    const range = { sessionId: slot.id, fromEntryId: anchor.id, toEntryId: anchor.id, entryIds: [anchor.id], entryDigest: digest };
    const gapRange = (id: string) => ({ sessionId: slot.id, fromEntryId: id, toEntryId: id, entryIds: [id], entryDigest: "b".repeat(64) });
    const legacy = await seedLegacyChronicle(workspace, store, {
      groups: [{ coverageId: "legacy-observed-cut", range, records: [{ id: "legacy-blur-decision",
        item: { text: "LEGACY-DECISION: the bottom blur stays at 16 points", attribution: "assistant", certainty: "certain", observedAt: anchor.timestamp } }] }],
      gaps: [
        { coverageId: "legacy-pending-cut", range: gapRange("legacy-pending-entry"), disposition: "pending", reason: "observer-admitted" },
        { coverageId: "legacy-failed-cut", range: gapRange("legacy-failed-entry"), disposition: "failed", reason: "No background models are configured (model.queue[role=background])." },
      ],
    });
    const seeded = legacy.records[0]!;
    const seededBody = JSON.stringify(seeded);
    const before = await store.status();

    // Retired configuration: still on disk, stripped on every read, gone after the next write.
    const persistedBefore = await persistedKnowledgeConfig(workspace);
    const config = await store.config();
    const statusKeys = Object.keys(before);
    const oldClientWrite = await store.configure("old-client-config", { ...config, observation: LEGACY_CHRONICLE_CONFIG.observation } as never)
      .then(() => "accepted", (error: Error) => error.message);
    const written = await store.configure("knowledge-config-after-retirement", config);
    const persistedAfter = await persistedKnowledgeConfig(workspace);

    // A settled ordinary turn under the legacy global grant produces nothing.
    const chatCallsBefore = faux.state.callCount;
    await slot.prompt("I prefer concise replies.");
    await waitFor(() => !slot.isBusy && !slot.isDrainBusy, "the new turn to settle");
    const after = await store.status();
    const workKinds = registry.administrativeWorkRegistry.sessionWorkKinds(slot.id);
    const observationsAfterTurn = (await store.list({ kind: "observation" })).records;

    // Legacy readers: recall, search, read, the agent-facing tool and the coverage ledger.
    const recalled = await store.recall({ query: "bottom blur" });
    const searched = await store.search({ kind: "observation", query: "LEGACY-DECISION" });
    const read = await store.read(seeded.id, seeded.revisionId);
    const rendered = await knowledge.tool({ action: "recall", query: "bottom blur" });
    const attention = await store.observationCoveragePage(100, undefined, ["pending", "failed", "unavailable"]);
    const pending = attention.coverage.find(item => item.id === "legacy-pending-cut")!;
    const failed = attention.coverage.find(item => item.id === "legacy-failed-cut")!;
    const dismissedPending = await store.dismissCoverage({ commandId: "dismiss-pending", coverageId: pending.id, expectedRevision: pending.revisionId });
    const dismissedFailed = await store.dismissCoverage({ commandId: "dismiss-failed", coverageId: failed.id, expectedRevision: failed.revisionId });
    const observedCut = (await store.observationCoveragePage()).coverage.find(item => item.id === "legacy-observed-cut");

    // Explicit derivations over legacy records keep working without any grant.
    const reflection = await knowledge.invoke({ operation: "knowledge.reflect", request: {
      commandId: "reflect-legacy", sessionId: slot.id, sourceRevisionIds: [seeded.revisionId] } }) as { record: KnowledgeRecord };
    const correction = await store.correct("correct-legacy", seeded.id, seeded.revisionId, {
      kind: "observation", scope: seeded.scope, provenance: seeded.provenance, relations: [],
      content: { ...(seeded as KnowledgeRecord & { kind: "observation" }).content, items: [{
        text: "LEGACY-DECISION: the bottom blur stays at 16 points (confirmed)", attribution: "assistant", certainty: "certain", observedAt: anchor.timestamp }] },
    }, { type: "corrects", recordId: seeded.id, revisionId: seeded.revisionId });
    const originalRevision = await store.read(seeded.id, seeded.revisionId);

    // The cited canonical source still proves the legacy range.
    const canonicalAnchor = slot.canonicalSessionEntries().find(entry => entry.id === anchor.id);

    // Privacy exclusions still hide existing history and refuse derivation.
    const current = await store.config();
    await store.configure("exclude-legacy-session", { ...current, eligibility: { ...current.eligibility, excludedSessionIds: [slot.id] } });
    const excludedRecall = await store.recall({ query: "bottom blur" });
    const excludedReflect = await knowledge.invoke({ operation: "knowledge.reflect", request: {
      commandId: "reflect-excluded", sessionId: slot.id, sourceRevisionIds: [correction.record.revisionId] } }).then(() => "accepted", (error: Error) => error.message);

    const outcomes = {
      legacyConfigStillPersistedBeforeWrite: (persistedBefore as { observation?: unknown }).observation !== undefined
        && (persistedBefore.eligibility as { allSessions?: unknown }).allSessions === true,
      retiredFieldsStrippedOnRead: !("observation" in config) && JSON.stringify(Object.keys(config.eligibility).sort()) === JSON.stringify(["excludedProjectIds", "excludedSessionIds"]),
      statusHasNoObservationFlag: !statusKeys.includes("observationConfigured"),
      oldClientObservationWriteRefused: oldClientWrite !== "accepted",
      retiredFieldsGoneAfterWrite: !("observation" in persistedAfter) && JSON.stringify(Object.keys(persistedAfter.eligibility as object).sort()) === JSON.stringify(["excludedProjectIds", "excludedSessionIds"]),
      configWriteKeepsRevisionMonotonic: written.revision === config.revision + 1,
      settledTurnAddsNoObservation: observationsAfterTurn.length === 1 && observationsAfterTurn[0]!.id === seeded.id,
      settledTurnAddsNoCoverage: after.coverageCount === before.coverageCount,
      settledTurnLeavesNoKnowledgeWork: !workKinds.includes("knowledge-observation"),
      onlyTheChatModelRan: faux.state.callCount === chatCallsBefore + 1,
      recallReturnsLegacyRevision: recalled.records.some(record => record.id === seeded.id && record.revisionId === seeded.revisionId),
      searchFindsLegacyRecord: searched.hits.length === 1 && searched.hits[0]!.record.id === seeded.id,
      readIsByteIdentical: JSON.stringify(read) === seededBody,
      toolRendersCitation: rendered.text.includes(seeded.id) && rendered.text.includes(digest) && rendered.text.includes(anchor.id),
      ledgerReadable: Boolean(observedCut && observedCut.groupRevisionIds.includes(seeded.revisionId)) && attention.coverage.length === 2,
      pendingGapClearable: dismissedPending.coverage.disposition === "excluded",
      failedGapClearable: dismissedFailed.coverage.disposition === "excluded",
      attentionClearedAfterDismiss: (await store.status()).coverage.remainingCount === 0,
      reflectionOverLegacyWorks: reflection.record.kind === "note" && reflection.record.relations.some(relation => relation.type === "derivedFrom" && relation.revisionId === seeded.revisionId)
        && reflections.length === 1 && reflections[0]!.includes("LEGACY-DECISION"),
      correctionKeepsOriginalRevision: correction.record.revisionId !== seeded.revisionId && JSON.stringify(originalRevision) === seededBody,
      canonicalSourceStillMatchesDigest: canonicalAnchor !== undefined && legacyEntriesDigest([canonicalAnchor]) === digest,
      exclusionHidesLegacyHistory: excludedRecall.records.every(record => record.kind !== "observation"),
      exclusionRefusesReflection: excludedReflect !== "accepted",
    };
    const reportDir = join(process.cwd(), "test-results", "legacy-chronicle");
    await mkdir(reportDir, { recursive: true });
    await writeFile(join(reportDir, "report.json"), `${JSON.stringify({ outcomes, legacyRecord: seeded.id, legacyRevision: seeded.revisionId,
      coverageBefore: before.coverage, coverageAfterTurn: after.coverage, oldClientWrite, excludedReflect }, null, 2)}\n`);
    expect(outcomes).toEqual(Object.fromEntries(Object.keys(outcomes).map(key => [key, true])));
    // The canonical transcript is never rewritten by any of the above.
    expect(await readFile(slot.persistedSessionFile!, "utf8")).toContain(anchor.id);
  }, 60_000);
});
