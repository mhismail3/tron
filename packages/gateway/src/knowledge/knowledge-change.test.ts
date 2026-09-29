import { mkdtemp, rm } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { afterEach, describe, expect, it, vi } from "vitest";
import { TronWorkspace } from "../workspace/tron-workspace.js";
import { KnowledgeStore, type KnowledgeChange } from "./knowledge-store.js";
import { KnowledgeChangeCoalescer, KNOWLEDGE_CHANGE_MAX_RECORD_IDS, KNOWLEDGE_CHANGE_WINDOW_MS } from "./knowledge-change.js";

const roots: string[] = [];
afterEach(async () => { vi.useRealTimers(); vi.restoreAllMocks(); await Promise.all(roots.splice(0).map(root => rm(root, { recursive: true, force: true }))); });

/** Failure modes under test: one intake item notifies several times and every
 * notification replays a client page; a notification carries a stale revision;
 * a large burst sends an unbounded identity list. */
describe("Knowledge change notifications", () => {
  it("publishes one payload per window with the union and the latest revision", () => {
    vi.useFakeTimers();
    const published: KnowledgeChange[] = [];
    const coalescer = new KnowledgeChangeCoalescer(change => published.push(change));
    coalescer.record({ stateRevision: 4, recordIds: ["a"] });
    coalescer.record({ stateRevision: 5, recordIds: ["b", "a"] });
    coalescer.record({ stateRevision: 6, recordIds: [] });
    expect(published).toEqual([]);
    vi.advanceTimersByTime(KNOWLEDGE_CHANGE_WINDOW_MS - 1);
    expect(published).toEqual([]);
    vi.advanceTimersByTime(1);
    expect(published).toEqual([{ stateRevision: 6, recordIds: ["a", "b"] }]);
    // The next window is independent and carries its own revision.
    coalescer.record({ stateRevision: 7, recordIds: ["c"] });
    vi.advanceTimersByTime(KNOWLEDGE_CHANGE_WINDOW_MS);
    expect(published).toEqual([{ stateRevision: 6, recordIds: ["a", "b"] }, { stateRevision: 7, recordIds: ["c"] }]);
  });

  it("omits an unbounded identity list instead of sending it", () => {
    vi.useFakeTimers();
    const published: KnowledgeChange[] = [];
    const coalescer = new KnowledgeChangeCoalescer(change => published.push(change), KNOWLEDGE_CHANGE_WINDOW_MS, 2);
    coalescer.record({ stateRevision: 9, recordIds: ["a", "b"] });
    coalescer.record({ stateRevision: 10, recordIds: ["c"] });
    vi.advanceTimersByTime(KNOWLEDGE_CHANGE_WINDOW_MS);
    expect(published).toEqual([{ stateRevision: 10 }]);
    expect(KNOWLEDGE_CHANGE_MAX_RECORD_IDS).toBe(64);
  });

  it("notifies the committed record set once and never on a replay or a rejected write", async () => {
    const root = await mkdtemp(join(tmpdir(), "tron-knowledge-change-")); roots.push(root);
    const changes: KnowledgeChange[] = [];
    const store = new KnowledgeStore(new TronWorkspace(root), change => changes.push(change));
    const request = { commandId: "change-notify-capture", record: { kind: "source" as const, scope: "research" as const,
      provenance: { actor: "user" as const, evidence: [] }, relations: [], content: { title: "Notified", text: "Body", captureDisposition: "partial" as const, capturedAt: "2026-01-01T00:00:00Z" } } };
    const captured = await store.captureSource(request);
    expect(changes).toEqual([{ stateRevision: 1, recordIds: [captured.record.id] }]);
    changes.length = 0;
    // A receipt replay is already committed work, not a new change.
    await store.captureSource(request);
    expect(changes).toEqual([]);
    await expect(store.captureSource({ ...request, commandId: "change-notify-stale", expectedRevision: "00000000-0000-4000-8000-000000000000" })).rejects.toThrow(/stale/);
    expect(changes).toEqual([]);
  });
});
