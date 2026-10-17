import { mkdtemp, rm, mkdir, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { afterEach, describe, expect, it } from "vitest";
import { TronWorkspace } from "../workspace/tron-workspace.js";
import { KnowledgeStore, type KnowledgeChange } from "./knowledge-store.js";
import { KnowledgeChangeCoalescer } from "./knowledge-change.js";

const roots: string[] = [];
const workspaces: TronWorkspace[] = [];
afterEach(async () => {
  for (const workspace of workspaces.splice(0)) await workspace.dispose();
  for (const root of roots.splice(0)) await rm(root, { recursive: true, force: true });
});

async function workspace(onChanged?: (change: KnowledgeChange) => void) {
  const root = await mkdtemp(join(tmpdir(), "tron-knowledge-forget-"));
  roots.push(root);
  const tronRoot = join(root, "tron");
  const tronWorkspace = new TronWorkspace(tronRoot);
  workspaces.push(tronWorkspace);
  await tronWorkspace.initialize();
  const store = new KnowledgeStore(tronWorkspace, onChanged);
  const capture = async (id: string) => {
    const result = await store.captureSource({ commandId: `capture-${id}`, record: {
      kind: "source", id, scope: "research", provenance: { actor: "user", evidence: [] }, relations: [],
      content: { title: `Title ${id}`, text: `Body ${id}`, captureDisposition: "partial", capturedAt: "2026-01-01T00:00:00Z" },
    } });
    return (await store.setSourceTake({ commandId: `take-${id}`, recordId: id, expectedRevision: result.record!.revisionId, text: `Take ${id}` })).record!;
  };
  return { workspace: tronWorkspace, store, capture };
}

async function curate(store: KnowledgeStore, id: string, revisionId: string, operation: "verdict" | "relation", fields: { supersededBy?: string; relationId?: string; verdict?: "evergreen" }, commandId: string) {
  return store.curateSource({ commandId, operation, producer: { actor: "user" }, item: {
    recordId: id, expectedRevision: revisionId,
    ...(operation === "verdict" ? { verdict: fields.verdict ? { verdict: fields.verdict } : { verdict: "superseded" as const, supersededBy: fields.supersededBy! } } : { relation: { type: "related" as const, recordId: fields.relationId!, action: "add" as const } }),
  } });
}

describe("Knowledge forget scrubs source replacement projections", () => {
  it("finds persisted replacement pointers and clears only the forgotten verdict", async () => {
    const fixture = await workspace();
    const { store, capture } = fixture;
    const B = await capture("forget-target-b");
    const U = await capture("unrelated-u");
    const A0 = await capture("replacement-only-a");
    const C0 = await capture("replacement-and-relation-c");
    const E0 = await capture("untouched-e");
    const D0 = await capture("nonmatching-verdict-d");
    const A1 = (await curate(store, A0.id, A0.revisionId, "verdict", { supersededBy: B.id }, "curate-a-verdict")).record!;
    const C1 = (await curate(store, C0.id, C0.revisionId, "verdict", { supersededBy: B.id }, "curate-c-verdict")).record!;
    const A2 = (await curate(store, A0.id, A1.revisionId, "relation", { relationId: U.id }, "curate-a-u")).record!;
    const C2 = (await curate(store, C0.id, C1.revisionId, "relation", { relationId: B.id }, "curate-c-b")).record!;
    const C3 = (await curate(store, C0.id, C2.revisionId, "relation", { relationId: U.id }, "curate-c-u")).record!;
    const E = (await curate(store, E0.id, E0.revisionId, "verdict", { verdict: "evergreen" }, "curate-e-evergreen")).record!;
    const D1 = (await curate(store, D0.id, D0.revisionId, "verdict", { supersededBy: U.id }, "curate-d-verdict")).record!;
    const D2 = (await curate(store, D0.id, D1.revisionId, "relation", { relationId: B.id }, "curate-d-b")).record!;

    // A new store instance exercises the normal persistent SQLite close/reopen boundary.
    const reopened = new KnowledgeStore(fixture.workspace);
    const readBefore = await Promise.all([A0.id, C0.id].map(id => reopened.read(id)));
    expect(readBefore.map(record => record?.kind === "source" ? record.content.verdict?.supersededBy : undefined)).toEqual([B.id, B.id]);
    expect(readBefore.map(record => record?.revisionId)).toEqual([A2.revisionId, C3.revisionId]);
    const rowsBefore = await reopened.listSourceRows({ kind: "source", ids: [A0.id, C0.id] });
    expect(rowsBefore.rows.map(row => row.id)).toEqual([A0.id, C0.id]);
    expect(rowsBefore.rows.map(row => row.supersededBy)).toEqual([B.id, B.id]);
    expect((await reopened.read(A0.id))?.relations.some(relation => relation.recordId === B.id)).toBe(false);
    expect((await reopened.read(C0.id))?.relations.some(relation => relation.recordId === B.id)).toBe(true);

    const forgotten = await reopened.forget("forget-b-command", B.id, "User requested forgetting", B.revisionId);
    const after = new KnowledgeStore(fixture.workspace);
    expect(await after.read(B.id, undefined, true)).toBeNull();
    const ordinaryReads = await Promise.all([after.read(A0.id), after.read(C0.id), after.read(D0.id)]);
    const [A, C, D] = await Promise.all([after.read(A0.id, undefined, true), after.read(C0.id, undefined, true), after.read(D0.id, undefined, true)]);
    expect(A?.kind).toBe("source");
    expect(C?.kind).toBe("source");
    if (A?.kind !== "source" || C?.kind !== "source" || D?.kind !== "source" || D2.kind !== "source") throw new Error("Expected scrubbed sources");
    // Observe both independent failure routes before asserting either one.
    const observed = {
      replacementOnlySuppressed: ordinaryReads[0] === null,
      relationControlSuppressed: ordinaryReads[1] === null,
      replacementOnlyVerdictCleared: A.content.verdict === undefined,
      relationControlVerdictCleared: C.content.verdict === undefined,
      nonmatchingVerdictPreserved: D.content.verdict?.supersededBy === U.id,
    };
    const resultPath = join(process.cwd(), "test-results", "knowledge-forget", "report.json");
    await mkdir(join(process.cwd(), "test-results", "knowledge-forget"), { recursive: true });
    await writeFile(resultPath, `${JSON.stringify({ outcomes: observed }, null, 2)}\n`);
    expect(observed).toEqual({ replacementOnlySuppressed: true, relationControlSuppressed: true, replacementOnlyVerdictCleared: true, relationControlVerdictCleared: true, nonmatchingVerdictPreserved: true });
    expect(ordinaryReads[2]).toBeNull();
    expect(D.content.verdict).toEqual(D2.content.verdict);
    expect(D.relations).toEqual([]);
    expect(A.relations.map(relation => relation.recordId)).toEqual([U.id]);
    expect(C.relations.map(relation => relation.recordId)).toEqual([U.id]);
    expect(A.content.take?.text).toBe("Take replacement-only-a");
    expect(C.content.take?.text).toBe("Take replacement-and-relation-c");
    expect((await after.sourceRowForRecord(A))?.supersededBy).toBeUndefined();
    expect((await after.sourceRowForRecord(C))?.supersededBy).toBeUndefined();
    expect(await after.read(E0.id)).toEqual(E);
    expect((await after.listSourceRows({ kind: "source", ids: [A0.id, B.id, C0.id, D0.id, E0.id] })).rows.map(row => row.id)).toEqual([E0.id]);
    const search = await after.search({ query: "Body", kind: "source" });
    expect(search.hits.map(hit => hit.record.id)).not.toContain(A0.id);
    expect(search.hits.map(hit => hit.record.id)).not.toContain(C0.id);
    expect(search.hits.map(hit => hit.record.id)).not.toContain(B.id);
    expect(search.hits.map(hit => hit.record.id)).toContain(E0.id);
    const recall = await after.recall({ query: "Body" });
    expect(recall.records.map(record => record.id)).not.toContain(A0.id);
    expect(recall.records.map(record => record.id)).not.toContain(C0.id);
    expect(recall.records.map(record => record.id)).not.toContain(B.id);
    expect(recall.records.map(record => record.id)).toContain(E0.id);
    for (const old of [A0, A1, A2, C0, C1, C2, C3, D2]) {
      await expect(after.read(old.id, old.revisionId, true)).rejects.toThrow(/not committed/);
    }
    await expect(curate(after, A0.id, A0.revisionId, "verdict", { supersededBy: B.id }, "curate-a-verdict")).rejects.toThrow(/forgotten/);
    await expect(curate(after, C0.id, C0.revisionId, "verdict", { supersededBy: B.id }, "curate-c-verdict")).rejects.toThrow(/forgotten/);
    expect(await after.forget("forget-b-command", B.id, "User requested forgetting", B.revisionId)).toEqual(forgotten);
    expect(await after.read(A0.id, undefined, true)).toEqual(A);
    expect(await after.read(C0.id, undefined, true)).toEqual(C);
    expect(await after.read(B.id, undefined, true)).toBeNull();
    await writeFile(resultPath, `${JSON.stringify({ outcomes: { ...observed, scrubbedDependents: [A0.id, C0.id, D0.id], preservedUnrelatedRelation: U.id, historicalReadsRejected: [A0, A1, A2, C0, C1, C2, C3, D2].map(record => ({ id: record.id, revision: record.revisionId })), forgottenTargetAbsent: true, oldRevisionsAndMutationReceiptsBlocked: true, repeatedForgetReplayStable: true, ordinaryRetrievalSuppressesDependents: true } }, null, 2)}\n`);
  });

  it("coalesces an unknown forget as a full refresh in either commit order", async () => {
    const committedChanges: KnowledgeChange[] = [];
    const fixture = await workspace(change => committedChanges.push(change));
    const { store, capture } = fixture;
    const forgotten = await capture("coalesce-forgotten");
    const survivor = await capture("coalesce-survivor");
    const beforeForget = committedChanges.length;
    const forgetReceipt = await store.forget("coalesce-forget", forgotten.id, "User requested forgetting", forgotten.revisionId);
    const unknownChange = committedChanges[beforeForget];
    const targetedResult = await store.setSourceTake({
      commandId: "coalesce-survivor-take",
      recordId: survivor.id,
      expectedRevision: survivor.revisionId,
      text: "Updated survivor take",
    });
    const targetedChange = committedChanges[beforeForget + 1];
    expect(unknownChange).toBeDefined();
    expect(targetedChange).toBeDefined();
    expect(unknownChange?.recordIds).toEqual([]);
    expect(targetedChange?.recordIds).toEqual([survivor.id]);
    expect(await store.read(forgotten.id, undefined, true)).toBeNull();
    expect((await store.read(survivor.id))?.revisionId).toBe(targetedResult.record!.revisionId);

    const waiters: Array<(change: KnowledgeChange) => void> = [];
    const coalescer = new KnowledgeChangeCoalescer(change => waiters.shift()?.(change));
    const published = () => new Promise<KnowledgeChange>(resolve => waiters.push(resolve));
    const unknownThenTargeted = published();
    coalescer.record(unknownChange!);
    coalescer.record(targetedChange!);
    const firstWindow = await unknownThenTargeted;

    const targetedOnly = published();
    coalescer.record(targetedChange!);
    const secondWindow = await targetedOnly;

    const reversePublished = published();
    const reverseCoalescer = new KnowledgeChangeCoalescer(change => waiters.shift()?.(change));
    reverseCoalescer.record(targetedChange!);
    reverseCoalescer.record(unknownChange!);
    const reverseWindow = await reversePublished;

    const outcomes = {
      forgottenRecordAbsent: await store.read(forgotten.id, undefined, true) === null,
      survivingRecordUpdated: (await store.read(survivor.id))?.revisionId === targetedResult.record!.revisionId,
      unknownPayloadCount: 1,
      targetedPayloadCount: 1,
      unknownThenTargetedFullRefresh: firstWindow.recordIds === undefined,
      targetedThenUnknownFullRefresh: reverseWindow.recordIds === undefined,
      maxRevisionPreserved: firstWindow.stateRevision === Math.max(unknownChange!.stateRevision, targetedChange!.stateRevision)
        && reverseWindow.stateRevision === Math.max(unknownChange!.stateRevision, targetedChange!.stateRevision),
      nextWindowTargetedOnly: secondWindow.recordIds?.join(",") === survivor.id,
      nextWindowRevisionPreserved: secondWindow.stateRevision === targetedChange!.stateRevision,
    };
    const reportPath = join(process.cwd(), "test-results", "knowledge-change-coalescing", "report.json");
    await mkdir(join(process.cwd(), "test-results", "knowledge-change-coalescing"), { recursive: true });
    await writeFile(reportPath, `${JSON.stringify({ outcomes, committedPayloads: {
      unknown: { recordIdCount: unknownChange!.recordIds?.length ?? 0, stateRevision: unknownChange!.stateRevision },
      targeted: { recordIdCount: targetedChange!.recordIds?.length ?? 0, stateRevision: targetedChange!.stateRevision },
    }, forgetRevision: forgetReceipt.stateRevision, targetedRevision: targetedResult.stateRevision }, null, 2)}\n`);
    expect(outcomes).toEqual({
      forgottenRecordAbsent: true,
      survivingRecordUpdated: true,
      unknownPayloadCount: 1,
      targetedPayloadCount: 1,
      unknownThenTargetedFullRefresh: true,
      targetedThenUnknownFullRefresh: true,
      maxRevisionPreserved: true,
      nextWindowTargetedOnly: true,
      nextWindowRevisionPreserved: true,
    });
  });
});
