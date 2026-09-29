import { afterEach, describe, expect, it, vi } from "vitest";
import { readFile, rm } from "node:fs/promises";
import { join } from "node:path";
import { tmpdir } from "node:os";
import { mkdtemp } from "node:fs/promises";
import { KnowledgeCatalog } from "./knowledge-catalog.js";
import { KnowledgeStore } from "./knowledge-store.js";
import { TronWorkspace } from "../workspace/tron-workspace.js";

const roots: string[] = [];
const workspaces: TronWorkspace[] = [];
afterEach(async () => {
  vi.restoreAllMocks();
  for (const workspace of workspaces.splice(0)) await workspace.dispose();
  await Promise.all(roots.splice(0).map(root => rm(root, { recursive: true, force: true })));
});
const revision = (index: number) => `00000000-0000-4000-8000-${String(index).padStart(12, "0")}`;

describe("Knowledge tag catalog scale", () => {
  it("keeps tag row/search/retag projections body-free on 12,600 records and 440 sources", async () => {
    const home = await mkdtemp(join(tmpdir(), "tron-tags-scale-")); roots.push(home);
    const workspace = new TronWorkspace(home); workspaces.push(workspace); await workspace.initialize();
    const store = new KnowledgeStore(workspace);
    const config = await store.config();
    const installed = await store.configureTags({ commandId: "knowledge-tags-scale-install", expectedConfigRevision: config.revision,
      edit: { kind: "add", tag: { id: "knowledge", label: "Knowledge Systems", definition: "Systems used to organize and retrieve knowledge.", category: "work", decayClass: "stable", state: "active" } } });
    const root = join(home, "workspace/state/knowledge");
    const manifest = JSON.parse(await readFile(join(root, "state.json"), "utf8")) as { catalogID: string };
    const catalog = new KnowledgeCatalog(join(root, `catalog-${manifest.catalogID}.sqlite`), false);
    try {
      catalog.begin();
      const records = catalog.table("records");
      for (let index = 0; index < 12_600; index++) {
        const id = `scale-${String(index).padStart(5, "0")}`;
        const revisionId = revision(index + 1);
        const isSource = index < 440;
        const timestamp = new Date(Date.UTC(2026, 0, 1) + index * 1_000).toISOString();
        records.set(id, {
          latestRevisionId: revisionId, revisionIds: [revisionId], kind: isSource ? "source" : "observation", scope: isSource ? "research" : "personal",
          createdAt: timestamp, updatedAt: timestamp, sortAt: Date.parse(timestamp),
          searchFields: isSource ? [["title", `saved item ${index}`], ["tags", "knowledge systems"]] : [["observation", `statement ${index}`]],
          recordRefs: [], objectHashes: [], ...(isSource ? { sourceRow: { title: `Saved item ${index}`, captureDisposition: "complete", tagIds: ["knowledge"], tagVocabularyRevision: installed.revision - 1, tags: [{ id: "knowledge", label: "Knowledge Systems", category: "work", decayClass: "stable", state: "active" }] } } : {}),
        });
        catalog.setRevisions(id, [revisionId]);
      }
      catalog.commit();
    } finally { catalog.close(); }
    const reads = vi.spyOn(store as unknown as { readRecord: (...args: unknown[]) => Promise<unknown> }, "readRecord");
    const started = performance.now();
    const rows = await store.listSourceRows({ kind: "source", limit: 50 });
    const listMs = performance.now() - started;
    const searchedAt = performance.now();
    const search = await store.searchSourceRows({ kind: "source", query: "knowledge systems", limit: 50 });
    const searchMs = performance.now() - searchedAt;
    const retaggedAt = performance.now();
    const retag = await store.tagsNeedingRetag({ vocabularyRevision: installed.revision, limit: 25 });
    const retagMs = performance.now() - retaggedAt;
    expect(rows.rows).toHaveLength(50);
    expect(search.rows).toHaveLength(50);
    expect(search.rows[0]?.tags?.[0]?.label).toBe("Knowledge Systems");
    expect(retag.items).toHaveLength(25);
    expect(reads).not.toHaveBeenCalled();
    // These are intentionally generous ceiling checks; count and body-read
    // assertions are the stable regression signal, while the timings flag a
    // pathological corpus scan without making normal host variance flaky.
    expect(listMs).toBeLessThan(2_000);
    expect(searchMs).toBeLessThan(2_000);
    expect(retagMs).toBeLessThan(2_000);
    console.log(JSON.stringify({ records: 12_600, sources: 440, listMs: +listMs.toFixed(1), searchMs: +searchMs.toFixed(1), retagMs: +retagMs.toFixed(1), bodyReads: reads.mock.calls.length }));
  }, 60_000);
});
