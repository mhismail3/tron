import { mkdir, mkdtemp, rm, writeFile } from "node:fs/promises";
import { dirname, join } from "node:path";
import { DatabaseSync } from "node:sqlite";
import { tmpdir } from "node:os";
import { afterAll, afterEach, describe, expect, it } from "vitest";
import { SessionSearchService } from "./session-search-service.js";
import { SessionSearchIndex, type SearchIndexDocument, type SearchIndexStamp } from "./session-search-index.js";

// Failure modes this file covers, written before the change (G-11's profile of
// the real Gateway, 2026-09-28, report
// ~/Library/Developer/Tron/profiles/gateway/20260928T201020Z-multi-session-4ca8a6):
// 1. One large transcript's posting insert held the event loop for 565-821 ms,
//    so every request that arrived during a reindex waited for a whole document.
// 2. The search invalidator ran SessionSearchIndex.remove synchronously from
//    another owner's summary publication: a 491 ms stretch in the same profile.
// 3. A dirty refresh always *replaces* the row an earlier start wrote, so the
//    insert case above is measured over an existing session in a populated
//    index, and its whole-session delete is batched the same way.
// 4. The insert's pre-flight pricing summed every posting in the index before
//    each document, which is another whole-index stretch on the write path. It
//    now reads the persisted per-row total, which is why the replace case below
//    measures a document replacement whose whole time is not a budget scan.
//
// The measured after-numbers are kept at TRON_SEARCH_STALL_REPORT (default
// packages/gateway/test-results/session-search-stall.json, inside the worktree
// that ran it, so concurrent runs in two worktrees keep two reports) for
// regeneration. Every case
// asserts the load-independent form of its claim: how often the loop was handed
// back, and a stretch well below the operation's whole time once the host's own
// scheduling floor is subtracted.

const roots: string[] = [];
afterEach(async () => { await Promise.all(roots.splice(0).map(root => rm(root, { recursive: true, force: true }))); });

const STAMP: SearchIndexStamp = { fileIdentity: "file-1", size: 1, mtimeMs: 1 };

/** Every case's measurement, written once at a stable path so the numbers in the
 * handoff can be regenerated with this file alone. */
const measurements: Record<string, unknown> = {};
const REPORT_PATH = process.env.TRON_SEARCH_STALL_REPORT ?? join(process.cwd(), "test-results", "session-search-stall.json");
afterAll(async () => {
  await mkdir(dirname(REPORT_PATH), { recursive: true });
  await writeFile(REPORT_PATH, `${JSON.stringify(measurements, null, 2)}\n`);
});

interface Stretch {
  /** Longest gap between two timer ticks while `run` was in flight. */
  stretchMs: number;
  /** How many times the event loop was served during `run`. */
  ticks: number;
}

/** The longest the event loop was held by synchronous work and how many times it
 * was handed back, from one 5 ms sampler around `run`. */
async function measureStretch(run: () => void | Promise<void>): Promise<Stretch> {
  let last = performance.now();
  let max = 0;
  let ticks = 0;
  const timer = setInterval(() => { const now = performance.now(); max = Math.max(max, now - last); last = now; ticks += 1; }, 5);
  try { await run(); } finally { clearInterval(timer); }
  return { stretchMs: Math.max(max, performance.now() - last), ticks };
}

/** The host's own scheduling floor: a stretch measured over work this process
 * does not hold the loop for, so a loaded machine's unrelated preemption is not
 * charged to the code under test. */
async function hostJitterMs(): Promise<number> {
  const measured = await measureStretch(() => new Promise(resolve => setTimeout(resolve, 200)));
  return Math.max(0, measured.stretchMs - 5);
}

function bigDocument(entries: number, sessionId = "session-1"): SearchIndexDocument {
  const text = Array.from({ length: 60 }, (_, index) => `word-${index % 17}`).join(" ");
  return {
    sessionId, title: "Stall fixture", cwd: "/tmp/project", updatedAt: "2025-01-01T00:00:00Z", fileIdentity: "file-1", branchDigest: "branch-1",
    entries: Array.from({ length: entries }, (_, index) => ({
      id: `entry-${index}`, parentId: index === 0 ? null : `entry-${index - 1}`, timestamp: "2025-01-01T00:00:00Z", role: index % 2 === 0 ? "user" as const : "assistant" as const, text, ordinal: index,
    })),
  };
}

/** What the invalidator ran inline on every summary publication before this
 * change: one whole-session delete, unsliced, from another owner's lane. */
function rawSessionDelete(path: string, sessionId: string): void {
  const raw = new DatabaseSync(path, { enableForeignKeyConstraints: true });
  try { raw.prepare("DELETE FROM sessions WHERE session_id = ?").run(sessionId); } finally { raw.close(); }
}

/** What the insert's pre-flight budget check used to run before every document:
 * a byte sum over every posting in the index. */
function rawPostingScan(path: string): void {
  const raw = new DatabaseSync(path);
  try {
    raw.prepare("SELECT ifnull(sum(length(term)+length(row_id)),0) AS n FROM passage_terms").get();
    raw.prepare("SELECT ifnull(sum(length(gram)+length(row_id)),0) AS n FROM passage_trigrams").get();
  } finally { raw.close(); }
}

describe("session search index event-loop bounds", () => {
  it("bounds replacing an existing session in a populated index", async () => {
    const root = await mkdtemp(join(tmpdir(), "tron-search-stall-replace-")); roots.push(root);
    const path = join(root, "index.sqlite");
    const index = await SessionSearchIndex.open(path);
    await index.replace(bigDocument(3_000), STAMP);
    // A real dirty refresh always replaces a row an earlier start wrote, and it
    // runs with the rest of the corpus already indexed.
    await index.replace(bigDocument(3_000, "session-2"), STAMP);
    const hostJitter = await hostJitterMs();
    const startedAt = performance.now();
    const replace = await measureStretch(() => index.replace(bigDocument(3_000), STAMP));
    const replaceMs = performance.now() - startedAt;
    expect(index.stats()).toMatchObject({ sessionsIndexed: 2, passagesIndexed: 6_000, state: "complete" });
    const inlineDelete = await measureStretch(() => rawSessionDelete(path, "session-1"));
    index.close();

    measurements.replace = { passages: 3_000, indexPassages: 6_000, replaceMs, hostJitter, ...replace, inlineDeleteStretchMs: inlineDelete.stretchMs, heldDiscountingHostJitter: replace.stretchMs - hostJitter };
    // The document's whole replacement takes far more work than any one held
    // stretch: the row delete and the posting insert are handed back between
    // slices, so neither contains the whole operation.
    expect(replaceMs).toBeGreaterThan(40);
    expect(replace.ticks).toBeGreaterThan(30);
    expect((replace.stretchMs - hostJitter) * 5).toBeLessThan(replaceMs);
    // The batched delete also stays under the whole-session cascade delete it
    // replaced (491 ms in G-11's profile).
    expect(replace.stretchMs - hostJitter).toBeLessThan(inlineDelete.stretchMs);
  }, 120_000);

  it("keeps a summary publication's invalidation off the event loop", async () => {
    const root = await mkdtemp(join(tmpdir(), "tron-search-stall-invalidate-")); roots.push(root);
    const path = join(root, "index.sqlite");
    const index = await SessionSearchIndex.open(path);
    await index.replace(bigDocument(3_000), STAMP);
    const inlineRemove = await measureStretch(() => rawSessionDelete(path, "session-1"));
    await index.replace(bigDocument(3_000), STAMP);

    let invalidate: ((sessionID: string, nextSessionID?: string) => void) | undefined;
    const sessions = {
      setSearchInvalidator(callback: typeof invalidate) { invalidate = callback; },
      isArchived: () => false,
      catalog: async () => ({ sessions: [{ id: "session-1" }] }),
      readSearchCut: async () => ({ summary: { id: "session-1", name: "Fixture", firstMessage: "Fixture", cwd: "/tmp", modified: new Date("2026-01-01T00:00:00Z") }, entries: [], fileIdentity: "file-1" }),
    } as any;
    const service = new SessionSearchService(sessions, index);
    const invalidation = await measureStretch(() => invalidate!("session-1"));
    await service.close();

    measurements.invalidate = { inlineRemoveStretchMs: inlineRemove.stretchMs, invalidationStretchMs: invalidation.stretchMs, ratio: inlineRemove.stretchMs / Math.max(invalidation.stretchMs, 1) };
    // The invalidation is now in-memory bookkeeping, so it is an order of
    // magnitude cheaper than the posting delete it replaced.
    expect(inlineRemove.stretchMs).toBeGreaterThan(50);
    expect(invalidation.stretchMs * 10).toBeLessThan(inlineRemove.stretchMs);
  }, 120_000);
});
