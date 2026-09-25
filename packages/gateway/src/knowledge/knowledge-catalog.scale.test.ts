import { afterEach, describe, expect, it, vi } from "vitest";
import { createHash } from "node:crypto";
import { mkdir, mkdtemp, readFile, readdir, rm, stat, symlink, writeFile } from "node:fs/promises";
import { join } from "node:path";
import { tmpdir } from "node:os";
import { DatabaseSync } from "node:sqlite";
import { jsonNodeCount } from "../protocol/json-budget.js";
import { TronWorkspace } from "../workspace/tron-workspace.js";
import { KnowledgeCatalog } from "./knowledge-catalog.js";
import { KnowledgeStore } from "./knowledge-store.js";
import { DEFAULT_KNOWLEDGE_CONFIG, type KnowledgeRecord, type KnowledgeRecordDraft, type ObservationCoverage } from "./knowledge-contract.js";

const workspaces: TronWorkspace[] = [];
const roots: string[] = [];
afterEach(async () => {
  vi.restoreAllMocks();
  for (const workspace of workspaces.splice(0)) await workspace.dispose();
  await Promise.all(roots.splice(0).map(root => rm(root, { recursive: true, force: true })));
});

async function fixture() {
  const home = await mkdtemp(join(tmpdir(), "tron-catalog-test-")); roots.push(home);
  const workspace = new TronWorkspace(home); workspaces.push(workspace); await workspace.initialize();
  return { home, workspace, root: join(home, "workspace/state/knowledge"), store: new KnowledgeStore(workspace) };
}
function revision(index: number): string { return `00000000-0000-4000-8000-${String(index).padStart(12, "0")}`; }
function observation(index: number, text = `Statement ${index}`): KnowledgeRecord & { kind: "observation" } {
  const timestamp = new Date(Date.UTC(2026, 0, 1) + index * 60_000).toISOString();
  const entry = `entry-${index}`;
  return { schemaVersion: 1, id: `observation-${String(index).padStart(5, "0")}`, revisionId: revision(index),
    kind: "observation", scope: "personal", createdAt: timestamp, updatedAt: timestamp,
    provenance: { actor: "agent", sessionId: "session-fixture", evidence: [{ sessionEntry: { sessionId: "session-fixture", entryId: entry } }] }, relations: [],
    content: { range: { sessionId: "session-fixture", fromEntryId: entry, toEntryId: entry, entryIds: [entry], entryDigest: "a".repeat(64) },
      items: [{ text, attribution: "user", certainty: "qualified", observedAt: timestamp }], observer: { model: "fixture/model", promptVersion: "tron-observer-v2" } } };
}
async function writeRecord(root: string, record: KnowledgeRecord) {
  const directory = join(root, "records", record.id); await mkdir(directory, { recursive: true, mode: 0o700 });
  await writeFile(join(directory, `${record.revisionId}.json`), JSON.stringify(record), { mode: 0o600 });
}
async function legacyFixture() {
  const result = await fixture();
  for (const name of ["", "records", "objects", "groups"]) await mkdir(join(result.root, name), { recursive: true, mode: 0o700 });
  await writeFile(join(result.root, "initialized.json"), JSON.stringify({ version: 1 }), { mode: 0o600 });
  await result.workspace.markFeatureInitialized("knowledge");
  const old = observation(1, "Original supported statement");
  const corrected = { ...old, revisionId: revision(2), updatedAt: "2026-02-01T00:00:00Z", content: { ...old.content, items: [{ ...old.content.items[0]!, text: "Corrected supported statement" }] } };
  const excluded = observation(3, "Excluded private statement");
  await Promise.all([old, corrected, excluded].map(record => writeRecord(result.root, record)));
  const coverage: ObservationCoverage = { schemaVersion: 1, id: "coverage-old", revisionId: revision(4), range: old.content.range, disposition: "observed", groupRevisionIds: [old.revisionId], recordedAt: old.createdAt };
  const state = { schemaVersion: 1, stateRevision: 12,
    records: { [old.id]: { latestRevisionId: corrected.revisionId, revisionIds: [old.revisionId, corrected.revisionId] }, [excluded.id]: { latestRevisionId: excluded.revisionId, revisionIds: [excluded.revisionId] } },
    coverage: { [coverage.id]: coverage }, suppressions: { [excluded.id]: { excluded: true, forgotten: false, updatedAt: excluded.updatedAt } },
    scopeExclusions: { "session:excluded-session": { sessionId: "excluded-session", excluded: true, updatedAt: old.updatedAt } },
    cleanup: [], recordCleanup: [], receipts: {},
    config: { ...structuredClone(DEFAULT_KNOWLEDGE_CONFIG), revision: 3, eligibility: { ...DEFAULT_KNOWLEDGE_CONFIG.eligibility, allSessions: true as const }, observation: { ...DEFAULT_KNOWLEDGE_CONFIG.observation, enabled: true, model: "fixture/model" } }, connectors: {} };
  await writeFile(join(result.root, "state.json"), JSON.stringify(state), { mode: 0o600 });
  return { ...result, old, corrected, excluded, coverage, state };
}
async function catalogPath(root: string) {
  const manifest = JSON.parse(await readFile(join(root, "state.json"), "utf8"));
  return join(root, `catalog-${manifest.catalogID}.sqlite`);
}

describe("Knowledge catalog scale", () => {
  it("browses beyond 10,000 records and 4 MiB with bounded body reads, stable cursors and complete lexical search", async () => {
    const f = await fixture(); await f.store.configure("catalog-scale-config", { ...DEFAULT_KNOWLEDGE_CONFIG, maximumSearchResults: 100 });
    const count = 10_005;
    const catalog = new KnowledgeCatalog(await catalogPath(f.root), false);
    try {
      catalog.begin(); const records = catalog.table("records"); const coverage = catalog.table("coverage");
      // Independent synthetic canonical fixture; no ten-thousand-command test
      // loop, and every catalog head owns a real immutable record body.
      for (let start = 0; start < count; start += 100) {
        const batch = Array.from({ length: Math.min(100, count - start) }, (_, offset) => observation(start + offset,
          start + offset === count - 1 ? "Rare needle beyond the former scan boundary" : `Statement ${start + offset}`));
        await Promise.all(batch.map(record => writeRecord(f.root, record)));
        for (const record of batch) {
          records.set(record.id, { latestRevisionId: record.revisionId, revisionIds: [record.revisionId], kind: record.kind, scope: record.scope,
            sortAt: Date.parse(record.createdAt), searchFields: [["observation", record.content.items[0]!.text.toLowerCase()], ["session", "session-fixture"]], recordRefs: [], objectHashes: [] });
          catalog.setRevisions(record.id, [record.revisionId]);
          coverage.set(`cut-${record.id}`, { schemaVersion: 1, id: `cut-${record.id}`, revisionId: record.revisionId, range: record.content.range,
            disposition: "observed", groupRevisionIds: [record.revisionId], recordedAt: record.createdAt });
        }
      }
      catalog.commit();
    } finally { catalog.close(); }
    expect((await stat(await catalogPath(f.root))).size).toBeGreaterThan(4 * 1_048_576);
    expect((await stat(join(f.root, "state.json"))).size).toBeLessThan(512);
    expect((await f.store.status()).recordCount).toBe(count);
    const reads = vi.spyOn(f.store as unknown as { readRecord: (...args: unknown[]) => Promise<KnowledgeRecord> }, "readRecord");
    const first = await f.store.list({ kind: "observation", scope: "personal", limit: 100 });
    expect(first.records[0]?.id).toBe(observation(count - 1).id);
    expect(reads).toHaveBeenCalledTimes(101);
    const anchor = first.records.at(-1)!;
    await f.store.forget("catalog-scale-forget-anchor", anchor.id, "test cursor deletion");
    reads.mockClear();
    const second = await f.store.list({ kind: "observation", scope: "personal", limit: 100, cursor: first.nextCursor! });
    expect(second.records[0]?.id).toBe(observation(count - 101).id);
    expect(reads).toHaveBeenCalledTimes(101);
    await expect(f.store.list({ kind: "note", cursor: first.nextCursor! })).rejects.toThrow(/cursor/);
    reads.mockClear();
    const search = await f.store.search({ query: "rare needle" });
    expect(search.hits.map(hit => hit.record.id)).toEqual([observation(count - 1).id]);
    expect(reads).toHaveBeenCalledTimes(1);
    expect((await f.store.recall({ query: "rare needle" })).records).toHaveLength(1);
    let cursor: string | undefined; let found = 0;
    do {
      const page = await f.store.list({ limit: 100, ...(cursor ? { cursor } : {}) });
      found += page.records.length; cursor = page.nextCursor;
    } while (cursor);
    expect(found).toBe(count - 1);
    const cutPage = await f.store.observationCoveragePage(100);
    expect(cutPage.coverage).toHaveLength(100);
    expect((await f.store.observationCoveragePage(100, cutPage.nextCursor)).coverage[0]?.id).toBe(`cut-${observation(100).id}`);
    expect(await f.store.observationCoverageForScope("session-fixture", undefined, undefined, ["entry-10004"])).toHaveLength(1);
    await expect(f.store.observationCoveragePage(100, "missing-cut")).rejects.toThrow(/cursor/);
    const database = new DatabaseSync(await catalogPath(f.root), { readOnly: true });
    try {
      const plan = database.prepare("EXPLAIN QUERY PLAN SELECT key FROM entries WHERE collection = 'records' ORDER BY json_extract(value, '$.sortAt') DESC, key LIMIT 100").all();
      expect(plan.some(row => String(row.detail).includes("records_date"))).toBe(true);
      expect(plan.some(row => String(row.detail).includes("TEMP B-TREE"))).toBe(false);
      const continuation = database.prepare("EXPLAIN QUERY PLAN SELECT key FROM entries WHERE collection = 'records' AND json_extract(value, '$.sortAt') <= ? AND (json_extract(value, '$.sortAt') < ? OR key > json_quote(?)) ORDER BY json_extract(value, '$.sortAt') DESC, key LIMIT 100").all(Date.parse(anchor.createdAt), Date.parse(anchor.createdAt), anchor.id);
      expect(continuation.some(row => String(row.detail).includes("records_date") && String(row.detail).includes("<expr>"))).toBe(true);
    } finally { database.close(); }
  }, 60_000);
});
