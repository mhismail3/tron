import { mkdtemp, rm } from "node:fs/promises";
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

describe("Knowledge unscoped lexical recall ranking", () => {
  it("prefers personal observations on lexical ties and keeps newer observations first", async () => {
    const root = await mkdtemp(join(tmpdir(), "tron-knowledge-recall-")); roots.push(root);
    const workspace = new TronWorkspace(join(root, "tron")); workspaces.push(workspace);
    await workspace.initialize();
    const store = new KnowledgeStore(workspace);
    const source = await store.captureSource({ commandId: "capture-research", record: {
      kind: "source", id: "research-blur-source", scope: "research", provenance: { actor: "user", evidence: [] }, relations: [],
      content: { title: "Research", text: "bottom blur height", captureDisposition: "partial", capturedAt: "2026-01-01T00:00:00Z" },
    } });
    const config = await store.config();
    await store.configure("enable-observation-test", { ...config, eligibility: { ...config.eligibility, allSessions: true } });
    const range = { sessionId: "synthetic-session", fromEntryId: "entry-1", toEntryId: "entry-1", entryIds: ["entry-1"], entryDigest: "a".repeat(64) };
    for (const [id, observedAt, text] of [
      ["old-bottom-blur", "2026-01-02T00:00:00Z", "bottom blur height was 12"],
      ["new-bottom-blur", "2026-02-02T00:00:00Z", "bottom blur height is 16"],
    ]) {
      await store.publishObservationGroup({
        commandId: `publish-${id}`, expectedConfigRevision: (await store.config()).revision,
        coverage: { id: `coverage-${id}`, range: { ...range, fromEntryId: `entry-${id}`, toEntryId: `entry-${id}`, entryIds: [`entry-${id}`] }, disposition: "observed", reason: "terminal:completed" },
        records: [{ id, kind: "observation", scope: "personal", provenance: { actor: "agent", sessionId: range.sessionId, evidence: [] }, relations: [], content: { range: { ...range, fromEntryId: `entry-${id}`, toEntryId: `entry-${id}`, entryIds: [`entry-${id}`] }, items: [{ text, attribution: "user", certainty: "certain", observedAt }], observer: { promptVersion: "integration-test" } } }],
      });
    }
    const result = await store.recall({ query: "bottom blur height" });
    expect(result.records.map(record => record.id)).toEqual(["new-bottom-blur", "old-bottom-blur", source.record!.id]);
    expect(result.records.filter(record => record.kind === "observation").flatMap(record => record.kind === "observation" ? record.content.items.map(item => item.observedAt) : [])).toEqual(["2026-02-02T00:00:00Z", "2026-01-02T00:00:00Z"]);
    expect((await store.recall({ query: "bottom blur height", kind: "source" })).records.map(record => record.id)).toEqual([source.record!.id]);
    expect((await store.recall({ query: "bottom blur height", scope: "research" })).records.map(record => record.id)).toEqual([source.record!.id]);
  });
});
