import { mkdtemp, rm } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { afterEach, describe, expect, it } from "vitest";
import { TronWorkspace } from "../workspace/tron-workspace.js";
import { GatewayError } from "../errors.js";
import { KnowledgeObservationService } from "./knowledge-observation.js";
import { KnowledgeService } from "./knowledge-service.js";
import { KnowledgeStore } from "./knowledge-store.js";
import { validateKnowledgeTagVocabulary, type KnowledgeTagEditRequest, type KnowledgeTagVocabularyConfig } from "./knowledge-contract.js";

const roots: string[] = [];
afterEach(async () => { await Promise.all(roots.splice(0).map(root => rm(root, { recursive: true, force: true }))); });
const command = (suffix: string) => `knowledge-tags-${suffix}`;
const activeTag: KnowledgeTagVocabularyConfig["tags"][number] = { id: "systems", label: "Systems", definition: "Tools and systems used in work.", category: "work", decayClass: "ages", state: "active" };
async function fixture() {
  const root = await mkdtemp(join(tmpdir(), "tron-knowledge-tags-")); roots.push(root);
  const workspace = new TronWorkspace(root);
  const store = new KnowledgeStore(workspace);
  const service = new KnowledgeService(store, new KnowledgeObservationService(store, undefined));
  return { root, workspace, store, service };
}
async function addTag(store: KnowledgeStore, tag = activeTag) {
  const config = await store.config();
  return store.configureTags({ commandId: command(`add-${tag.id}`), expectedConfigRevision: config.revision, edit: { kind: "add", tag } });
}
async function capture(store: KnowledgeStore, index: number) {
  return (await store.captureSource({ commandId: command(`capture-${index}`), record: {
    kind: "source", scope: "research", provenance: { actor: "connector", evidence: [] }, relations: [],
    content: { title: `Source ${index}`, uri: `https://example.test/${index}`, text: `Text ${index}`, mediaType: "text/plain", captureDisposition: "complete", capturedAt: "2026-01-01T00:00:00Z", admission: { status: "retained", reason: "test", decidedAt: "2026-01-01T00:00:00Z" } },
  } })).record;
}
async function setTags(store: KnowledgeStore, id: string, revisionId: string, tagIds: string[]) {
  return store.curateSource({ commandId: command(`select-${id}-${tagIds.join("-")}`), operation: "tags", producer: { actor: "agent", model: "test/model" }, item: { recordId: id, expectedRevision: revisionId, tagIds } });
}

/** Failure modes written before the vocabulary implementation:
 * - stale config edits must never overwrite a newer taxonomy;
 * - duplicate normalized labels, malformed IDs and excessive definitions must fail validation;
 * - merge cycles and merging into retired tags must be rejected;
 * - retiring during a concurrent taxonomy edit must produce a clean config conflict;
 * - merge repoint work must resume after an owner restart without duplicate revisions;
 * - retired IDs must be rejected by the existing typed curation operation;
 * - re-tag-needed listing and source rows/search must use catalog heads, not read source bodies;
 * - vocabulary queries must remain bounded on a 12,600-record / 440-source corpus. */
describe("Knowledge tag vocabulary", () => {
  it("fences stale config revisions and receipted retries", async () => {
    const { store } = await fixture();
    const initial = await store.config();
    const first = await store.configureTags({ commandId: command("first"), expectedConfigRevision: initial.revision, edit: { kind: "add", tag: activeTag } });
    await expect(store.configureTags({ commandId: command("stale"), expectedConfigRevision: initial.revision, edit: { kind: "add", tag: { ...activeTag, id: "ideas", label: "Ideas" } } })).rejects.toMatchObject({ code: "conflict" });
    expect(await store.configureTags({ commandId: command("first"), expectedConfigRevision: initial.revision, edit: { kind: "add", tag: activeTag } })).toEqual(first);
    await expect(store.configureTags({ commandId: command("first"), expectedConfigRevision: initial.revision, edit: { kind: "add", tag: { ...activeTag, id: "ideas" } } })).rejects.toMatchObject({ code: "conflict" });
  });

  it("keeps the vocabulary edition stable across unrelated Knowledge config changes", async () => {
    const { store } = await fixture();
    await addTag(store);
    const record = await capture(store, 1);
    await setTags(store, record.id, record.revisionId, ["systems"]);
    const tagged = await store.config();
    await store.configure(command("unrelated-config"), { ...tagged, maximumSearchResults: 40 });
    const after = await store.config();
    expect(after.revision).toBe(tagged.revision + 1);
    expect(after.tagVocabulary.revision).toBe(tagged.tagVocabulary.revision);
    expect((await store.tagsNeedingRetag({ vocabularyRevision: after.tagVocabulary.revision })).items).toEqual([]);
  });

  it("rejects duplicate normalized labels and invalid bounded fields", async () => {
    const { store } = await fixture();
    await addTag(store);
    const config = await store.config();
    await expect(store.configureTags({ commandId: command("duplicate-label"), expectedConfigRevision: config.revision, edit: { kind: "add", tag: { ...activeTag, id: "work-systems", label: " systems " } } })).rejects.toMatchObject({ code: "invalid_request" });
    await expect(store.configureTags({ commandId: command("bad-id"), expectedConfigRevision: config.revision, edit: { kind: "add", tag: { ...activeTag, id: "not a slug", label: "Other" } } })).rejects.toMatchObject({ code: "invalid_request" });
    await expect(store.configureTags({ commandId: command("oversize"), expectedConfigRevision: config.revision, edit: { kind: "add", tag: { ...activeTag, id: "other", label: "Other", definition: "x".repeat(513) } } })).rejects.toMatchObject({ code: "invalid_request" });
  });

  it("rejects merge cycles and merges into retired tags", async () => {
    const { store } = await fixture();
    await addTag(store);
    let config = await store.config();
    config = await store.configureTags({ commandId: command("add-design"), expectedConfigRevision: config.revision, edit: { kind: "add", tag: { ...activeTag, id: "design", label: "Design" } } });
    config = await store.configureTags({ commandId: command("merge-design"), expectedConfigRevision: config.revision, edit: { kind: "merge", id: "design", mergedInto: "systems" } });
    await expect(store.configureTags({ commandId: command("cycle"), expectedConfigRevision: config.revision, edit: { kind: "merge", id: "systems", mergedInto: "design" } })).rejects.toMatchObject({ code: "invalid_request" });
    const malformedCycle = { revision: 2, tags: [{ ...activeTag, state: "merged" as const, mergedInto: "other" }, { ...activeTag, id: "other", label: "Other", state: "merged" as const, mergedInto: "systems" }], guidelines: "" };
    expect(() => validateKnowledgeTagVocabulary(malformedCycle)).toThrow(/cycle/);
    config = await store.configureTags({ commandId: command("add-retired-target"), expectedConfigRevision: config.revision, edit: { kind: "add", tag: { ...activeTag, id: "retired-target", label: "Retired target" } } });
    config = await store.configureTags({ commandId: command("retire-target"), expectedConfigRevision: config.revision, edit: { kind: "retire", id: "retired-target" } });
    await expect(store.configureTags({ commandId: command("merge-retired"), expectedConfigRevision: config.revision, edit: { kind: "merge", id: "design", mergedInto: "retired-target" } })).rejects.toMatchObject({ code: "invalid_request" });
  });

  it("routes typed tag operations through the agent tool and RPC, auto-starting merge re-pointing", async () => {
    const { store, service } = await fixture();
    const result = await service.tool({ action: "configureTags", commandId: command("tool-add"), expectedConfigRevision: 0, tagEdit: { kind: "add", tag: activeTag } });
    expect((result.details as { tagVocabulary: KnowledgeTagVocabularyConfig }).tagVocabulary.tags[0]?.id).toBe("systems");
    let config = await store.config();
    config = await store.configureTags({ commandId: command("tool-add-legacy"), expectedConfigRevision: config.revision, edit: { kind: "add", tag: { ...activeTag, id: "legacy", label: "Legacy" } } });
    const record = await capture(store, 7);
    await setTags(store, record.id, record.revisionId, ["legacy"]);
    const rpcResult = await service.invoke({ operation: "knowledge.tags.configure", request: { commandId: command("rpc-merge"), expectedConfigRevision: config.revision, edit: { kind: "merge", id: "legacy", mergedInto: "systems" } } });
    expect(rpcResult).toMatchObject({ config: { revision: config.revision + 1 }, reconciliation: { applied: 1, outcomes: [{ id: record.id, status: "applied" }] } });
    expect((await store.read(record.id))?.content.tags?.tagIds).toEqual(["systems"]);
  });

  it("reports a committed merge when a concurrent config revision fences its automatic first batch", async () => {
    const { store, service } = await fixture();
    await addTag(store);
    let config = await store.config();
    config = await store.configureTags({ commandId: command("add-race-merge"), expectedConfigRevision: config.revision, edit: { kind: "add", tag: { ...activeTag, id: "legacy-race", label: "Legacy race" } } });
    const reconcile = store.reconcileTagMerges.bind(store);
    store.reconcileTagMerges = async request => {
      const current = await store.config();
      await store.configure(command("concurrent-config"), { ...current, maximumSearchResults: current.maximumSearchResults - 1 });
      throw new GatewayError("conflict", "Knowledge configuration changed during automatic merge reconciliation");
    };
    const result = await service.invoke({ operation: "knowledge.tags.configure", request: { commandId: command("merge-race"), expectedConfigRevision: config.revision, edit: { kind: "merge", id: "legacy-race", mergedInto: "systems" } } }) as { config: { revision: number }; reconciliation: { conflict?: boolean; configRevision: number; reason?: string } };
    expect(result.config.revision).toBe(config.revision + 1);
    expect(result.reconciliation).toMatchObject({ conflict: true, configRevision: config.revision + 2 });
    store.reconcileTagMerges = reconcile;
    await expect(store.reconcileTagMerges({ commandId: command("merge-race-resume"), expectedConfigRevision: result.reconciliation.configRevision })).resolves.toMatchObject({ applied: 0 });
  });

  it("rejects a concurrent retire at the stale configuration revision", async () => {
    const { store } = await fixture();
    await addTag(store);
    const config = await store.config();
    const rename: KnowledgeTagEditRequest = { commandId: command("rename-race"), expectedConfigRevision: config.revision, edit: { kind: "rename", id: "systems", label: "Infrastructure" } };
    const retire: KnowledgeTagEditRequest = { commandId: command("retire-race"), expectedConfigRevision: config.revision, edit: { kind: "retire", id: "systems" } };
    const outcomes = await Promise.allSettled([store.configureTags(rename), store.configureTags(retire)]);
    expect(outcomes.filter(outcome => outcome.status === "fulfilled")).toHaveLength(1);
    expect(outcomes.filter(outcome => outcome.status === "rejected")).toHaveLength(1);
    expect(outcomes.find(outcome => outcome.status === "rejected")).toMatchObject({ reason: { code: "conflict" } });
  });

  it("repoints a merge in bounded receipted batches and resumes after restart", async () => {
    const { root, workspace, store, service } = await fixture();
    await addTag(store);
    let config = await store.config();
    config = await store.configureTags({ commandId: command("add-legacy"), expectedConfigRevision: config.revision, edit: { kind: "add", tag: { ...activeTag, id: "legacy", label: "Legacy" } } });
    const records = await Promise.all(Array.from({ length: 13 }, (_, index) => capture(store, index)));
    for (const record of records) await setTags(store, record.id, record.revisionId, ["legacy"]);
    config = await store.config();
    config = await store.configureTags({ commandId: command("merge-legacy"), expectedConfigRevision: config.revision, edit: { kind: "merge", id: "legacy", mergedInto: "systems" } });
    const firstPage = await store.reconcileTagMerges({ commandId: command("repoint-partial"), expectedConfigRevision: config.revision, limit: 12 });
    expect(firstPage.applied).toBe(12);
    const reopened = new KnowledgeStore(workspace);
    const resumed = await reopened.reconcileTagMerges({ commandId: command("repoint-resume"), expectedConfigRevision: config.revision, cursor: firstPage.nextCursor, limit: 25 });
    expect(resumed.applied).toBe(1);
    expect(resumed.nextCursor).toBeUndefined();
    const replay = await reopened.reconcileTagMerges({ commandId: command("repoint-resume"), expectedConfigRevision: config.revision, cursor: firstPage.nextCursor, limit: 25 });
    expect(replay).toEqual(resumed);
    for (const record of records) {
      const latest = await reopened.read(record.id);
      expect(latest?.content.tags?.tagIds).toEqual(["systems"]);
      expect(latest?.content.tags?.producer).toMatchObject({ actor: "system" });
    }
    expect(service).toBeDefined();
    expect(root).toBeTruthy();
  });

  it("fences a merge continuation when the vocabulary changes mid-flight", async () => {
    const { store } = await fixture();
    await addTag(store);
    let config = await store.config();
    config = await store.configureTags({ commandId: command("add-legacy-midflight"), expectedConfigRevision: config.revision, edit: { kind: "add", tag: { ...activeTag, id: "legacy", label: "Legacy" } } });
    config = await store.configureTags({ commandId: command("add-other-midflight"), expectedConfigRevision: config.revision, edit: { kind: "add", tag: { ...activeTag, id: "other", label: "Other" } } });
    const records = await Promise.all([1, 2].map(index => capture(store, 100 + index)));
    for (const record of records) await setTags(store, record.id, record.revisionId, ["legacy"]);
    config = await store.config();
    config = await store.configureTags({ commandId: command("merge-midflight"), expectedConfigRevision: config.revision, edit: { kind: "merge", id: "legacy", mergedInto: "systems" } });
    const first = await store.reconcileTagMerges({ commandId: command("repoint-midflight-one"), expectedConfigRevision: config.revision, limit: 1 });
    expect(first.applied).toBe(1);
    const newer = await store.configureTags({ commandId: command("retire-midflight-other"), expectedConfigRevision: config.revision, edit: { kind: "retire", id: "other" } });
    expect(newer.revision).toBe(config.revision + 1);
    await expect(store.reconcileTagMerges({ commandId: command("repoint-midflight-two"), expectedConfigRevision: config.revision, cursor: first.nextCursor, limit: 1 })).rejects.toMatchObject({ code: "conflict" });
  });

  it("retires a tag from future curation and exposes stale selections for re-tagging", async () => {
    const { store } = await fixture();
    await addTag(store);
    const record = await capture(store, 1);
    await setTags(store, record.id, record.revisionId, ["systems"]);
    let config = await store.config();
    config = await store.configureTags({ commandId: command("retire"), expectedConfigRevision: config.revision, edit: { kind: "retire", id: "systems" } });
    const current = await store.read(record.id);
    await expect(store.curateSource({ commandId: command("unknown-after-retire"), operation: "tags", producer: { actor: "agent" }, item: { recordId: record.id, expectedRevision: current!.revisionId, tagIds: ["systems"] } })).rejects.toMatchObject({ code: "unknown-tag" });
    const stale = await store.tagsNeedingRetag({ vocabularyRevision: config.revision, limit: 25 });
    expect(stale.items.map(item => item.id)).toContain(record.id);
  });

  it("projects current tag labels and searches them from catalog heads without body reads", async () => {
    const { store } = await fixture();
    await addTag(store);
    const record = await capture(store, 1);
    await setTags(store, record.id, record.revisionId, ["systems"]);
    let bodyReads = 0;
    const original = (store as unknown as { readRecord: (...args: unknown[]) => Promise<unknown> }).readRecord;
    (store as unknown as { readRecord: (...args: unknown[]) => Promise<unknown> }).readRecord = async (...args) => { bodyReads++; return original.apply(store, args as never); };
    const listed = await store.listSourceRows({ kind: "source", limit: 10 });
    const searched = await store.searchSourceRows({ kind: "source", query: "systems", limit: 10 });
    expect(listed.rows.find(row => row.id === record.id)?.tags).toEqual([{ id: "systems", label: "Systems", category: "work", decayClass: "ages", state: "active" }]);
    expect(searched.rows.map(row => row.id)).toContain(record.id);
    let config = await store.config();
    await store.configureTags({ commandId: command("rename-projected-tag"), expectedConfigRevision: config.revision, edit: { kind: "rename", id: "systems", label: "Infrastructure" } });
    config = await store.config();
    const renamed = await store.listSourceRows({ kind: "source", limit: 10 });
    expect(renamed.rows.find(row => row.id === record.id)?.tags?.[0]?.label).toBe("Infrastructure");
    expect((await store.searchSourceRows({ kind: "source", query: "infrastructure", limit: 10 })).rows.map(row => row.id)).toContain(record.id);
    expect(bodyReads).toBe(0);
  });

  it("validates an oversized vocabulary before accepting configuration", async () => {
    const { store } = await fixture();
    const config = await store.config();
    const tags = Array.from({ length: 257 }, (_, index) => ({ ...activeTag, id: `tag-${index}`, label: `Tag ${index}` }));
    expect(() => validateKnowledgeTagVocabulary({ revision: 0, tags, guidelines: "" })).toThrow(/at most 256 tags/);
  });
});
