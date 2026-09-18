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
    cleanup: [], recordCleanup: [], imports: {}, receipts: {},
    config: { ...structuredClone(DEFAULT_KNOWLEDGE_CONFIG), revision: 3, eligibility: { ...DEFAULT_KNOWLEDGE_CONFIG.eligibility, allSessions: true as const }, observation: { ...DEFAULT_KNOWLEDGE_CONFIG.observation, enabled: true, model: "fixture/model" } }, connectors: {} };
  await writeFile(join(result.root, "state.json"), JSON.stringify(state), { mode: 0o600 });
  return { ...result, old, corrected, excluded, coverage, state };
}
async function catalogPath(root: string) {
  const manifest = JSON.parse(await readFile(join(root, "state.json"), "utf8"));
  return join(root, `catalog-${manifest.catalogID}.sqlite`);
}

describe("Knowledge canonical catalog", () => {
  it("upgrades an existing corpus once without changing revisions, evidence, configuration or exclusions", async () => {
    const f = await legacyFixture();
    const originalBytes = await readFile(join(f.root, "records", f.old.id, `${f.old.revisionId}.json`));
    expect((await f.store.status()).available).toBe(false);
    expect(JSON.parse(await readFile(join(f.root, "state.json"), "utf8"))).toEqual(f.state);
    await f.store.upgradeStorage();
    expect(await f.store.read(f.old.id, f.old.revisionId)).toEqual(f.old);
    expect(await f.store.read(f.old.id)).toEqual(f.corrected);
    expect(await f.store.coverage(f.coverage.id)).toEqual(f.coverage);
    expect(await f.store.config()).toEqual(f.state.config);
    expect(await f.store.scopeExcluded({ sessionId: "excluded-session" })).toBe(true);
    expect(await f.store.read(f.excluded.id)).toBeNull();
    expect((await f.store.list()).records.map(record => record.id)).toEqual([f.old.id]);
    expect((await f.store.recall({ query: "corrected" })).records[0]?.revisionId).toBe(f.corrected.revisionId);
    expect(await readFile(join(f.root, "records", f.old.id, `${f.old.revisionId}.json`))).toEqual(originalBytes);
    const manifest = await readFile(join(f.root, "state.json"));
    await f.store.upgradeStorage();
    expect(await readFile(join(f.root, "state.json"))).toEqual(manifest);
    const reopened = new KnowledgeStore(f.workspace);
    expect((await reopened.status()).recordCount).toBe(2);
    await reopened.forget("catalog-forget-migrated", f.old.id, "test erasure", f.corrected.revisionId);
    expect(await reopened.read(f.old.id, f.old.revisionId, true)).toBeNull();
    expect((await reopened.search({ query: "corrected" })).hits).toEqual([]);
  });

  it("retains the old manifest on a missing committed revision and retries without an empty reset", async () => {
    const f = await legacyFixture();
    const path = join(f.root, "records", f.old.id, `${f.old.revisionId}.json`);
    const bytes = await readFile(path); const before = await readFile(join(f.root, "state.json")); await rm(path);
    await expect(f.store.upgradeStorage()).rejects.toThrow(/missing/);
    expect(await readFile(join(f.root, "state.json"))).toEqual(before);
    expect((await readdir(f.root)).filter(name => name.endsWith(".sqlite"))).toEqual([]);
    await writeFile(path, bytes, { mode: 0o600 });
    await f.store.upgradeStorage();
    expect((await f.store.status()).recordCount).toBe(2);
  });

  it("rescues a legacy coverage catalog that already exceeded its four-MiB read ceiling", async () => {
    const f = await legacyFixture();
    const coverage = Object.fromEntries(Array.from({ length: 16_000 }, (_, index) => {
      const id = `empty-history-${index}`; const entry = `entry-${index}`;
      return [id, { ...f.coverage, id, revisionId: revision(index + 100_000), disposition: "empty", groupRevisionIds: [],
        range: { ...f.coverage.range, fromEntryId: entry, toEntryId: entry, entryIds: [entry] } }];
    }));
    const bytes = JSON.stringify({ ...f.state, coverage });
    expect(Buffer.byteLength(bytes)).toBeGreaterThan(4 * 1_048_576);
    await writeFile(join(f.root, "state.json"), bytes, { mode: 0o600 });
    expect((await f.store.status()).available).toBe(false);
    await f.store.upgradeStorage();
    const status = await f.store.status();
    expect(status.available).toBe(true);
    expect(status.recordCount).toBe(2);
    expect(status.coverage.emptyCount).toBe(16_000);
    expect(await f.store.read(f.old.id, f.old.revisionId)).toEqual(f.old);
  });

  it("filters coverage pages to the dispositions a client displays", async () => {
    const f = await fixture(); await f.store.configure("catalog-coverage-filter", structuredClone(DEFAULT_KNOWLEDGE_CONFIG));
    const dispositions = ["observed", "empty", "excluded", "pending", "failed", "unavailable"] as const;
    const catalog = new KnowledgeCatalog(await catalogPath(f.root), false);
    try {
      catalog.begin(); const coverage = catalog.table<ObservationCoverage>("coverage");
      for (let index = 0; index < 60; index += 1) {
        const record = observation(index);
        coverage.set(`cut-${record.id}`, { schemaVersion: 1, id: `cut-${record.id}`, revisionId: record.revisionId, range: record.content.range,
          disposition: dispositions[index % dispositions.length]!, groupRevisionIds: [], recordedAt: record.createdAt });
      }
      catalog.commit();
    } finally { catalog.close(); }
    // A client that lists cuts needing attention must not receive settled rows.
    const attention = ["pending", "failed", "unavailable"] as const;
    const unsettled = Array.from({ length: 60 }, (_, index) => index).filter(index => index % dispositions.length >= 3);
    const id = (index: number) => `cut-observation-${String(index).padStart(5, "0")}`;
    const page = await f.store.observationCoveragePage(100, undefined, [...attention]);
    expect(page.coverage.map(cut => cut.id)).toEqual(unsettled.map(id));
    expect(page.nextCursor).toBeUndefined();
    const first = await f.store.observationCoveragePage(7, undefined, [...attention]);
    const second = await f.store.observationCoveragePage(7, first.nextCursor, [...attention]);
    expect(first.coverage.map(cut => cut.id)).toEqual(unsettled.slice(0, 7).map(id));
    expect(second.coverage.map(cut => cut.id)).toEqual(unsettled.slice(7, 14).map(id));
    // The unfiltered ledger still pages every cut, and the filter is validated.
    expect((await f.store.observationCoveragePage(100)).coverage).toHaveLength(60);
    await expect(f.store.observationCoveragePage(10, undefined, ["pending", "pending"])).rejects.toThrow(/disposition/);
    await expect(f.store.observationCoveragePage(10, undefined, [])).rejects.toThrow(/disposition/);
    await expect(f.store.observationCoveragePage(10, undefined, ["bogus" as "pending"])).rejects.toThrow(/disposition/);
  });

  it("preserves NUL-separated receipt identities and invalidates migrated replay after forgetting", async () => {
    const f = await legacyFixture();
    const draft: KnowledgeRecordDraft & { kind: "note" } = { id: "receipt-note", kind: "note", scope: "personal", provenance: { actor: "user", evidence: [] }, relations: [], content: { title: "Receipt test", body: "Exact receipt", role: "fact", confirmed: true } };
    const record: KnowledgeRecord = { ...draft, schemaVersion: 1, id: draft.id!, revisionId: revision(8), createdAt: f.old.createdAt, updatedAt: f.old.updatedAt };
    await writeRecord(f.root, record);
    const request = { commandId: "catalog-receipt-original", record: draft };
    const operation = "knowledge.note.create";
    const state = { ...f.state, records: { ...f.state.records, [record.id]: { latestRevisionId: record.revisionId, revisionIds: [record.revisionId] } }, receipts: {
      [`${operation}\0${request.commandId}`]: { operation, requestHash: createHash("sha256").update(operation).update("\0").update(JSON.stringify(request)).digest("hex"), createdAt: record.createdAt,
        recordIds: [record.id], result: { kind: "record", recordId: record.id, revisionId: record.revisionId, stateRevision: 12 } },
    } };
    await writeFile(join(f.root, "state.json"), JSON.stringify(state), { mode: 0o600 });
    await f.store.upgradeStorage();
    expect((await f.store.createNote(request)).record).toEqual(record);
    await f.store.forget("catalog-receipt-forget", record.id, "test erasure");
    await expect(f.store.createNote(request)).rejects.toThrow(/forgotten/);
    const catalog = new KnowledgeCatalog(await catalogPath(f.root), true);
    try { expect([...catalog.table("receipts").keys()]).toContain(`${operation}\0${request.commandId}`); }
    finally { catalog.close(); }
  });

  it("keeps group heads and coverage atomic when catalog commit fails", async () => {
    const f = await fixture(); const config = await f.store.configure("catalog-group-config", { ...DEFAULT_KNOWLEDGE_CONFIG, eligibility: { ...DEFAULT_KNOWLEDGE_CONFIG.eligibility, allSessions: true } });
    const first = observation(1); const second = { ...observation(2), content: { ...observation(2).content, range: first.content.range } };
    const failure = vi.spyOn(f.store as unknown as { save: () => Promise<void> }, "save").mockRejectedValueOnce(new Error("catalog commit failure"));
    await expect(f.store.publishObservationGroup({ commandId: "catalog-group-publication", expectedConfigRevision: config.revision, coverage: { id: "cut-atomic", range: first.content.range, disposition: "observed" }, records: [first, second] })).rejects.toThrow("catalog commit failure");
    failure.mockRestore();
    const reopened = new KnowledgeStore(f.workspace);
    expect((await reopened.status()).recordCount).toBe(0);
    expect(await reopened.coverage("cut-atomic")).toBeNull();
    expect(await reopened.read(first.id)).toBeNull();
  });

  it("does not recreate a missing catalog or follow a catalog symlink", async () => {
    const f = await fixture(); await f.store.configure("catalog-initialize", structuredClone(DEFAULT_KNOWLEDGE_CONFIG));
    const path = await catalogPath(f.root); await rm(path);
    expect((await f.store.status()).available).toBe(false);
    await expect(f.store.configure("catalog-missing-write", structuredClone(DEFAULT_KNOWLEDGE_CONFIG))).rejects.toThrow(/missing/);
    const outside = join(f.home, "outside"); await writeFile(outside, "not a catalog", { mode: 0o600 }); await symlink(outside, path);
    expect((await f.store.status()).state).toBe("unsafe");
    expect(await readFile(outside, "utf8")).toBe("not a catalog");
  });

  it("pages evidence-heavy records within both transport byte and native node bounds", async () => {
    const f = await fixture();
    const config = await f.store.configure("catalog-node-budget-config", { ...DEFAULT_KNOWLEDGE_CONFIG, eligibility: { ...DEFAULT_KNOWLEDGE_CONFIG.eligibility, allSessions: true } });
    const ids = Array.from({ length: 4_500 }, (_, index) => `e${index}`);
    const base = observation(1);
    const first = { ...base, provenance: { ...base.provenance, evidence: ids.map(entryId => ({ sessionEntry: { sessionId: "s", entryId } })) },
      content: { ...base.content, range: { ...base.content.range, fromEntryId: ids[0]!, toEntryId: ids.at(-1)!, entryIds: ids } } };
    const second = { ...first, id: "another-observation" };
    expect(Buffer.byteLength(JSON.stringify([first, second]))).toBeLessThan(750_000);
    expect(jsonNodeCount([first, second])).toBeGreaterThan(32_768);
    await f.store.publishObservationGroup({ commandId: "catalog-node-budget-publish", expectedConfigRevision: config.revision,
      coverage: { id: "node-budget-cut", range: first.content.range, disposition: "observed" }, records: [first, second] });
    const page = await f.store.list({ limit: 100 });
    expect(page.records).toHaveLength(1);
    expect(jsonNodeCount({ id: "response", result: page })).toBeLessThan(32_768);
    expect((await f.store.list({ cursor: page.nextCursor! })).records).toHaveLength(1);
  });

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
