import { mkdtemp, rm, mkdir, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { afterEach, describe, expect, it } from "vitest";
import { TronWorkspace } from "../workspace/tron-workspace.js";
import { KnowledgeStore } from "./knowledge-store.js";

const roots: string[] = [];
const workspaces: TronWorkspace[] = [];
afterEach(async () => {
  for (const workspace of workspaces.splice(0)) await workspace.dispose();
  for (const root of roots.splice(0)) await rm(root, { recursive: true, force: true });
});

async function workspace() {
  const root = await mkdtemp(join(tmpdir(), "tron-knowledge-forget-"));
  roots.push(root);
  const tronRoot = join(root, "tron");
  const tronWorkspace = new TronWorkspace(tronRoot);
  await tronWorkspace.initialize();
  workspaces.push(tronWorkspace);
  const store = new KnowledgeStore(tronWorkspace);
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
    const A1 = (await curate(store, A0.id, A0.revisionId, "verdict", { supersededBy: B.id }, "curate-a-verdict")).record!;
    const C1 = (await curate(store, C0.id, C0.revisionId, "verdict", { supersededBy: B.id }, "curate-c-verdict")).record!;
    await curate(store, A0.id, A1.revisionId, "relation", { relationId: U.id }, "curate-a-u");
    const C2 = (await curate(store, C0.id, C1.revisionId, "relation", { relationId: B.id }, "curate-c-b")).record!;
    await curate(store, C0.id, C2.revisionId, "relation", { relationId: U.id }, "curate-c-u");
    const E = (await curate(store, E0.id, E0.revisionId, "verdict", { verdict: "evergreen" }, "curate-e-evergreen")).record!;

    // A new store instance exercises the normal persistent SQLite close/reopen boundary.
    const reopened = new KnowledgeStore(fixture.workspace);
    const readBefore = await Promise.all([A0.id, C0.id].map(id => reopened.read(id)));
    expect(readBefore.map(record => record?.kind === "source" ? record.content.verdict?.supersededBy : undefined)).toEqual([B.id, B.id]);
    const rowsBefore = await reopened.listSourceRows({ kind: "source", ids: [A0.id, C0.id] });
    expect(rowsBefore.rows.map(row => row.id)).toEqual([A0.id, C0.id]);
    expect(rowsBefore.rows.map(row => row.supersededBy)).toEqual([B.id, B.id]);
    expect((await reopened.read(A0.id))?.relations.some(relation => relation.recordId === B.id)).toBe(false);
    expect((await reopened.read(C0.id))?.relations.some(relation => relation.recordId === B.id)).toBe(true);

    const forgotten = await reopened.forget("forget-b-command", B.id, "User requested forgetting", B.revisionId);
    const after = new KnowledgeStore(fixture.workspace);
    expect(await after.read(B.id, undefined, true)).toBeNull();
    expect(await after.read(A0.id)).toBeNull();
    expect(await after.read(C0.id)).toBeNull();
    const [A, C] = await Promise.all([after.read(A0.id, undefined, true), after.read(C0.id, undefined, true)]);
    expect(A?.kind).toBe("source");
    expect(C?.kind).toBe("source");
    if (A?.kind !== "source" || C?.kind !== "source") throw new Error("Expected scrubbed sources");
    expect(A.content.verdict).toBeUndefined();
    expect(C.content.verdict).toBeUndefined();
    expect(A.relations.map(relation => relation.recordId)).toEqual([U.id]);
    expect(C.relations.map(relation => relation.recordId)).toEqual([U.id]);
    expect(A.content.take?.text).toBe("Take replacement-only-a");
    expect(C.content.take?.text).toBe("Take replacement-and-relation-c");
    expect((await after.sourceRowForRecord(A))?.supersededBy).toBeUndefined();
    expect((await after.sourceRowForRecord(C))?.supersededBy).toBeUndefined();
    expect(await after.read(E0.id)).toEqual(E);
    expect((await after.listSourceRows({ kind: "source", ids: [A0.id, B.id, C0.id, E0.id] })).rows.map(row => row.id)).toEqual([E0.id]);
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
    await expect(after.read(A0.id, A0.revisionId, true)).rejects.toThrow(/not committed/);
    await expect(after.read(C0.id, C0.revisionId, true)).rejects.toThrow(/not committed/);
    await expect(curate(after, A0.id, A0.revisionId, "verdict", { supersededBy: B.id }, "curate-a-verdict")).rejects.toThrow(/forgotten/);
    await expect(curate(after, C0.id, C0.revisionId, "verdict", { supersededBy: B.id }, "curate-c-verdict")).rejects.toThrow(/forgotten/);
    expect(await after.forget("forget-b-command", B.id, "User requested forgetting", B.revisionId)).toEqual(forgotten);
    expect((await after.read(A0.id, undefined, true))?.kind).toBe("source");
    const resultPath = join(process.cwd(), "test-results", "knowledge-forget", "report.json");
    await mkdir(join(process.cwd(), "test-results", "knowledge-forget"), { recursive: true });
    await writeFile(resultPath, `${JSON.stringify({ outcomes: { reopenedReplacementPointers: 2, replacementOnlyHadNoRelationToTarget: true, relationControlHadTargetRelation: true, scrubbedDependents: [A0.id, C0.id], preservedUnrelatedRelation: U.id, matchingVerdictsCleared: true, forgottenTargetAbsent: true, oldRevisionsAndMutationReceiptsBlocked: true, repeatedForgetReplayStable: true, ordinaryRetrievalSuppressesDependents: true } }, null, 2)}\n`);
  });
});
