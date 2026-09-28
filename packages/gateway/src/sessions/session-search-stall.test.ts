import { mkdtemp, rm, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
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
//
// The measured after-numbers are kept at TRON_SEARCH_STALL_REPORT
// (default $TMPDIR/tron-search-stall-report.json) for regeneration.

const roots: string[] = [];
afterEach(async () => { await Promise.all(roots.splice(0).map(root => rm(root, { recursive: true, force: true }))); });

const STAMP: SearchIndexStamp = { fileIdentity: "file-1", size: 1, mtimeMs: 1 };

/** Every case's measurement, written once at a stable path so the numbers in the
 * handoff can be regenerated with this file alone. */
const measurements: Record<string, unknown> = {};
afterAll(async () => {
  await writeFile(process.env.TRON_SEARCH_STALL_REPORT ?? join(tmpdir(), "tron-search-stall-report.json"), `${JSON.stringify(measurements, null, 2)}\n`);
});

/** The longest the event loop was held by synchronous work: the largest gap
 * between two timer ticks while `run` was in flight. */
async function measureStretch(run: () => void | Promise<void>): Promise<number> {
  let last = performance.now();
  let max = 0;
  const timer = setInterval(() => { const now = performance.now(); max = Math.max(max, now - last); last = now; }, 5);
  try { await run(); } finally { clearInterval(timer); }
  return Math.max(max, performance.now() - last);
}

function bigDocument(entries: number): SearchIndexDocument {
  const text = Array.from({ length: 60 }, (_, index) => `word-${index % 17}`).join(" ");
  return {
    sessionId: "session-1", title: "Stall fixture", cwd: "/tmp/project", updatedAt: "2025-01-01T00:00:00Z", fileIdentity: "file-1", branchDigest: "branch-1",
    entries: Array.from({ length: entries }, (_, index) => ({
      id: `entry-${index}`, parentId: index === 0 ? null : `entry-${index - 1}`, timestamp: "2025-01-01T00:00:00Z", role: index % 2 === 0 ? "user" as const : "assistant" as const, text, ordinal: index,
    })),
  };
}

describe("session search index event-loop bounds", () => {
  it("bounds the synchronous stretch of one document's posting insert", async () => {
    const root = await mkdtemp(join(tmpdir(), "tron-search-stall-insert-")); roots.push(root);
    const index = await SessionSearchIndex.open(join(root, "index.sqlite"));
    const startedAt = performance.now();
    const insertStretchMs = await measureStretch(() => index.replace(bigDocument(3_000), STAMP));
    const insertMs = performance.now() - startedAt;
    expect(index.stats().passagesIndexed).toBe(3_000);
    index.close();

    measurements.insert = { passages: 3_000, insertMs, insertStretchMs, slices: insertMs / Math.max(insertStretchMs, 1) };
    // The document's whole insert takes far more work than any one held
    // stretch: the loop is handed back between slices, so its size no longer
    // sets the longest held stretch. The ratio is the load-independent form of
    // that claim (an unsliced insert has a stretch equal to its whole insert).
    expect(insertMs).toBeGreaterThan(40);
    expect(insertStretchMs * 5).toBeLessThan(insertMs);
  });

  it("keeps a summary publication's invalidation off the event loop", async () => {
    const root = await mkdtemp(join(tmpdir(), "tron-search-stall-invalidate-")); roots.push(root);
    const index = await SessionSearchIndex.open(join(root, "index.sqlite"));
    await index.replace(bigDocument(3_000), STAMP);
    // What the previous invalidator did inline on every summary publication.
    const inlineRemoveStretchMs = await measureStretch(() => index.remove("session-1"));
    await index.replace(bigDocument(3_000), STAMP);

    let invalidate: ((sessionID: string, nextSessionID?: string) => void) | undefined;
    const sessions = {
      setSearchInvalidator(callback: typeof invalidate) { invalidate = callback; },
      isArchived: () => false,
      catalog: async () => ({ sessions: [{ id: "session-1" }] }),
      readSearchCut: async () => ({ summary: { id: "session-1", name: "Fixture", firstMessage: "Fixture", cwd: "/tmp", modified: new Date("2026-01-01T00:00:00Z") }, entries: [], fileIdentity: "file-1" }),
    } as any;
    const service = new SessionSearchService(sessions, index);
    const invalidationStretchMs = await measureStretch(() => invalidate!("session-1"));
    await service.close();

    measurements.invalidate = { inlineRemoveStretchMs, invalidationStretchMs, ratio: inlineRemoveStretchMs / Math.max(invalidationStretchMs, 1) };
    // The invalidation is now in-memory bookkeeping, so it is an order of
    // magnitude cheaper than the posting delete it replaced. The ratio is the
    // load-independent form of that claim.
    expect(inlineRemoveStretchMs).toBeGreaterThan(50);
    expect(invalidationStretchMs * 10).toBeLessThan(inlineRemoveStretchMs);
  });
});
