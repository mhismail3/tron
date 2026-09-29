import { afterEach, describe, expect, it } from "vitest";
import { mkdir, mkdtemp, rm, stat, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { performance } from "node:perf_hooks";
import { TronWorkspace } from "../workspace/tron-workspace.js";
import { KnowledgeCatalog } from "./knowledge-catalog.js";
import { KnowledgeStore } from "./knowledge-store.js";

const roots: string[] = [];
afterEach(async () => { await Promise.all(roots.splice(0).map(root => rm(root, { recursive: true, force: true }))); });
const revision = (index: number) => `00000000-0000-4000-8000-${String(index).padStart(12, "0")}`;

// A 12,600-head corpus models the on-disk store scale while keeping 440 real
// source revisions available for search/recall body reads. Other heads are
// bounded catalog-only notes, which are irrelevant to the tested token.
describe("Knowledge take/freshness retrieval scale", () => {
  it("keeps source list, search, recall, and row projection bounded at 12,600 records", async () => {
    const root = await mkdtemp(join(tmpdir(), "knowledge-k6-scale-")); roots.push(root);
    const workspace = new TronWorkspace(root);
    const store = new KnowledgeStore(workspace);
    const captured = await store.captureSource({ commandId: "k6-scale-initial-source", record: { kind: "source", scope: "research", provenance: { actor: "connector", evidence: [] }, relations: [], content: {
      title: "scale-token Source 0", uri: "https://scale.example/0", text: "scale-token indexed body", captureDisposition: "complete", capturedAt: "2026-09-29T00:00:00.000Z", sourceSavedAt: "2026-09-29T00:00:00.000Z", admission: { status: "retained", decidedAt: "2026-09-29T00:00:00.000Z" },
    } } });
    const statePath = join(root, "workspace/state/knowledge/state.json");
    const manifest = JSON.parse(await (await import("node:fs/promises")).readFile(statePath, "utf8")) as { catalogID: string };
    const catalogPath = join(root, `workspace/state/knowledge/catalog-${manifest.catalogID}.sqlite`);
    const catalog = new KnowledgeCatalog(catalogPath, false);
    const now = "2026-09-29T00:00:00.000Z";
    try {
      catalog.begin();
      const records = catalog.table<Record<string, unknown>>("records");
      for (let index = 1; index < 440; index += 1) {
        const id = `k6-scale-source-${String(index).padStart(4, "0")}`;
        const rev = revision(index + 1);
        const source = { schemaVersion: 1, id, revisionId: rev, kind: "source", scope: "research", createdAt: now, updatedAt: now,
          provenance: { actor: "connector", evidence: [] }, relations: [], content: { title: `scale-token Source ${index}`, uri: `https://scale.example/${index}`, text: "scale-token indexed body", mediaType: "text/plain", captureDisposition: "complete", capturedAt: now, sourceSavedAt: now, admission: { status: "retained", decidedAt: now } } };
        const directory = join(root, "workspace/state/knowledge/records", id); await mkdir(directory, { recursive: true, mode: 0o700 });
        await writeFile(join(directory, `${rev}.json`), JSON.stringify(source), { mode: 0o600 });
        records.set(id, { latestRevisionId: rev, revisionIds: [rev], kind: "source", scope: "research", createdAt: now, updatedAt: now, sortAt: Date.parse(now) - index,
          searchFields: [["source", `scale-token source ${index}`], ["text", "scale-token indexed body"]], recordRefs: [], objectHashes: [], admission: "retained",
          sourceRow: { title: `scale-token Source ${index}`, uri: `https://scale.example/${index}`, captureDisposition: "complete", sourceSavedAt: now, ageBasis: "sourceSavedAt", ageDays: 0, ageSince: now, freshness: "unknown", freshnessRank: 1, decayClass: "unknown", hasTake: false, tagsStale: false } });
        catalog.setRevisions(id, [rev]);
      }
      for (let index = 0; index < 12_160; index += 1) {
        const id = `k6-scale-note-${String(index).padStart(5, "0")}`;
        const rev = revision(10_000 + index);
        records.set(id, { latestRevisionId: rev, revisionIds: [rev], kind: "note", scope: "personal", createdAt: now, updatedAt: now, sortAt: Date.parse(now) - index - 10_000,
          searchFields: [["note", `unrelated note ${index}`]], recordRefs: [], objectHashes: [] });
        catalog.setRevisions(id, [rev]);
      }
      catalog.commit();
    } finally { catalog.close(); }
    expect((await store.status()).recordCount).toBe(12_600);

    const timed = async <T>(operation: () => Promise<T>) => { const start = performance.now(); const value = await operation(); return { value, ms: performance.now() - start }; };
    const rows = await timed(() => store.listSourceRows({ kind: "source", limit: 50 }));
    const rowSearch = await timed(() => store.searchSourceRows({ query: "scale-token", kind: "source", limit: 50 }));
    const list = await timed(() => store.list({ kind: "source", limit: 20 }));
    const search = await timed(() => store.search({ query: "scale-token", kind: "source", limit: 20 }));
    const recall = await timed(() => store.recall({ query: "scale-token", limit: 20 }));
    expect(rows.value.rows).toHaveLength(50);
    expect(rowSearch.value.rows).toHaveLength(50);
    expect(list.value.records).toHaveLength(20);
    expect(search.value.hits).toHaveLength(20);
    expect(recall.value.records).toHaveLength(20);
    expect(await stat(catalogPath)).toBeDefined();
    // Regression budgets are generous to avoid host jitter while rejecting a
    // return to full-body projection or repeated corpus serialization.
    expect(rows.ms).toBeLessThan(1_000);
    expect(rowSearch.ms).toBeLessThan(1_500);
    expect(list.ms).toBeLessThan(1_500);
    expect(search.ms).toBeLessThan(2_000);
    expect(recall.ms).toBeLessThan(2_000);
    console.info("K6 retrieval scale ms", JSON.stringify({ corpus: 12_600, sources: 440, rows: rows.ms, rowSearch: rowSearch.ms, list: list.ms, search: search.ms, recall: recall.ms }));
  }, 60_000);
});
