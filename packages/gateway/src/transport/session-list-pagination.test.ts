import { describe, expect, it, vi } from "vitest";
import type { SessionSummary } from "../protocol/types.js";
import { GatewayService, type ClientContext, type GatewayServiceDependencies } from "./gateway-service.js";
import { SessionListPaginationStore } from "./session-list-pagination.js";

function summary(index: number, phase: SessionSummary["phase"] = "idle"): SessionSummary {
  return {
    id: `session-${index.toString().padStart(4, "0")}`,
    cwd: "/workspace",
    kind: "user",
    createdAt: "2026-01-01T00:00:00.000Z",
    updatedAt: `2026-01-01T00:${String(index % 60).padStart(2, "0")}:00.000Z`,
    messageCount: index,
    firstMessage: `message ${index}`,
    phase,
    summaryRevision: index,
  };
}

function pageSource(sessions: SessionSummary[], listRevision: number, generation = `generation-${listRevision}`) {
  const rows = sessions.slice();
  return {
    generation, listRevision, count: rows.length, compactByteEstimate: rows.reduce((n, row) => n + 96 + row.id.length + row.cwd.length + row.firstMessage.length, 0),
    page: async (offset: number, limit: number) => rows.slice(offset, offset + limit),
  };
}

const client = (id: string, signal?: AbortSignal): ClientContext => ({
  id,
  identity: `device:${id}`,
  isLocal: false,
  ...(signal ? { signal } : {}),
  beginSynchronization: () => "sync",
  establishSynchronization: () => {},
  completeSynchronization: () => {},
  unsubscribe: () => true,
  attachTerminal: () => {},
  detachTerminal: () => {},
  ownsTerminal: () => false,
});

describe("SessionListPaginationStore", () => {
  it("pages 1000 rows from one immutable revision with exact ordering and no gaps", async () => {
    const store = new SessionListPaginationStore({ secret: Buffer.alloc(32, 1) });
    const canonical = Array.from({ length: 1_000 }, (_, index) => summary(index));
    let page = await store.firstPage("phone", "user", pageSource(canonical, 41), 137);
    const received = [...page.sessions];
    canonical.splice(0, canonical.length, summary(2_000, "running"));
    while (page.nextCursor) {
      page = await store.nextPage("phone", "user", page.nextCursor, 137);
      expect(page.listRevision).toBe(41);
      received.push(...page.sessions);
    }
    expect(received.map((item) => item.id)).toEqual(
      Array.from({ length: 1_000 }, (_, index) => summary(index).id),
    );
    expect(new Set(received.map((item) => item.id)).size).toBe(1_000);
    expect(store.activeLeaseCount).toBe(0);
  });

  it("does not retain unleased generations for one-page responses", async () => {
    const store = new SessionListPaginationStore({ secret: Buffer.alloc(32, 9) });
    for (let revision = 0; revision < 100; revision += 1) {
      const page = await store.firstPage("phone", "user", pageSource([summary(revision)], revision), 10);
      expect(page.nextCursor).toBeUndefined();
    }
    expect((store as unknown as { generations: Map<string, unknown> }).generations.size).toBe(0);
  });

  it("rejects stale, wrong-client, wrong-scope, and tampered cursors", async () => {
    let now = 100;
    const store = new SessionListPaginationStore({
      now: () => now,
      leaseTTLms: 20,
      secret: Buffer.alloc(32, 2),
    });
    const first = await store.firstPage("phone", "user", pageSource([summary(0), summary(1), summary(2)], 1), 1);
    await expect(store.nextPage("tablet", "user", first.nextCursor!, 1)).rejects.toThrow(/invalid or expired/);
    await expect(store.nextPage("phone", "all", first.nextCursor!, 1)).rejects.toThrow(/invalid or expired/);
    await expect(store.nextPage("phone", "user", `${first.nextCursor!}x`, 1)).rejects.toThrow(/invalid or expired/);
    now = 120;
    await expect(store.nextPage("phone", "user", first.nextCursor!, 1)).rejects.toThrow(/invalid or expired/);
  });

  it("enforces LRU lease and materialization count bounds", async () => {
    let now = 0;
    const store = new SessionListPaginationStore({
      now: () => now,
      maxLeases: 2,
      maxSessionsPerLease: 3,
      secret: Buffer.alloc(32, 3),
    });
    const first = await store.firstPage("one", "user", pageSource([summary(0), summary(1)], 1), 1);
    now += 1;
    const second = await store.firstPage("two", "user", pageSource([summary(2), summary(3)], 2), 1);
    now += 1;
    const third = await store.firstPage("three", "user", pageSource([summary(4), summary(5)], 3), 1);
    expect(store.activeLeaseCount).toBe(2);
    await expect(store.nextPage("one", "user", first.nextCursor!, 1)).rejects.toThrow(/invalid or expired/);
    expect((await store.nextPage("two", "user", second.nextCursor!, 1)).sessions).toEqual([summary(3)]);
    expect((await store.nextPage("three", "user", third.nextCursor!, 1)).sessions).toEqual([summary(5)]);
    await expect(store.firstPage("large", "user", pageSource([summary(0), summary(1), summary(2), summary(3)], 4), 1)).rejects.toThrow(/too large/);
  });

  it("bounds retained rows across all concurrent leases", async () => {
    const store = new SessionListPaginationStore({
      maxLeases: 8,
      maxSessionsPerLease: 4,
      maxTotalSessions: 5,
      secret: Buffer.alloc(32, 4),
    });
    const first = await store.firstPage("one", "user", pageSource([summary(0), summary(1), summary(2)], 1), 1);
    const second = await store.firstPage("two", "user", pageSource([summary(3), summary(4), summary(5)], 2), 1);

    expect(store.activeLeaseCount).toBe(1);
    await expect(store.nextPage("one", "user", first.nextCursor!, 1)).rejects.toThrow(/invalid or expired/);
    expect((await store.nextPage("two", "user", second.nextCursor!, 1)).sessions).toEqual([summary(4)]);
  });

  it("bounds retained bytes and isolates each client's lease quota", async () => {
    const store = new SessionListPaginationStore({
      maxLeases: 4,
      maxLeasesPerClient: 1,
      maxBytesPerLease: 1_000,
      maxTotalBytes: 2_000,
      secret: Buffer.alloc(32, 5),
    });
    const phoneFirst = await store.firstPage("phone", "user", pageSource([summary(0), summary(1)], 1), 1);
    const tablet = await store.firstPage("tablet", "user", pageSource([summary(2), summary(3)], 2), 1);
    const phoneSecond = await store.firstPage("phone", "user", pageSource([summary(4), summary(5)], 3), 1);

    await expect(store.nextPage("phone", "user", phoneFirst.nextCursor!, 1)).rejects.toThrow(/invalid or expired/);
    expect((await store.nextPage("tablet", "user", tablet.nextCursor!, 1)).sessions).toEqual([summary(3)]);
    expect((await store.nextPage("phone", "user", phoneSecond.nextCursor!, 1)).sessions).toEqual([summary(5)]);

    const oversized = { ...summary(6), firstMessage: "x".repeat(2_000) };
    await expect(store.firstPage("large", "user", pageSource([oversized, summary(7)], 4), 1)).rejects.toThrow(/too large/);

    const abandoned = await store.firstPage("abandoned", "user", pageSource([summary(8), summary(9)], 5), 1);
    store.releaseClient("abandoned");
    await expect(store.nextPage("abandoned", "user", abandoned.nextCursor!, 1)).rejects.toThrow(/invalid or expired/);
  });

  it("rejects malformed source slices without retaining traversal state", async () => {
    const store = new SessionListPaginationStore({ secret: Buffer.alloc(32, 6) });
    const malformed = (rows: SessionSummary[]) => ({
      generation: `malformed-${rows.length}-${rows.map((row) => row.id).join("-")}`,
      listRevision: 1,
      count: 3,
      compactByteEstimate: 512,
      page: async () => rows,
    });
    await expect(store.firstPage("phone", "user", malformed([summary(0)]), 2)).rejects.toThrow(/inconsistent/);
    await expect(store.firstPage("phone", "user", malformed([summary(0), summary(1), summary(2)]), 2)).rejects.toThrow(/inconsistent/);
    await expect(store.firstPage("phone", "user", malformed([summary(0), summary(0)]), 2)).rejects.toThrow(/inconsistent/);
    await expect(store.firstPage("phone", "user", {
      ...malformed([summary(0), summary(1)]),
      generation: "rejected",
      page: async () => { throw new Error("rejected source"); },
    }, 2)).rejects.toThrow(/rejected source/);
    const wireBounded = new SessionListPaginationStore({
      secret: Buffer.alloc(32, 11), maxBytesPerLease: 1_000, maxTotalBytes: 2_000,
    });
    await expect(wireBounded.firstPage("phone", "user", {
      ...malformed([{ ...summary(0), firstMessage: "x".repeat(2_000) }, summary(1)]),
      generation: "wire-oversized",
    }, 2)).rejects.toThrow(/too large/);
    expect(wireBounded.activeLeaseCount).toBe(0);
    expect((wireBounded as unknown as { generations: Map<string, unknown> }).generations.size).toBe(0);
    expect(store.activeLeaseCount).toBe(0);
    expect((store as unknown as { generations: Map<string, unknown> }).generations.size).toBe(0);
  });

  it("fails closed when one generation key names a different source", async () => {
    const store = new SessionListPaginationStore({ secret: Buffer.alloc(32, 8) });
    const firstSource = pageSource([summary(0), summary(1)], 1, "shared");
    const first = await store.firstPage("phone", "user", firstSource, 1);
    await expect(store.firstPage("tablet", "user", pageSource([summary(0), summary(1)], 1, "shared"), 1))
      .rejects.toThrow(/generation changed/);
    expect((await store.nextPage("phone", "user", first.nextCursor!, 1)).sessions).toEqual([summary(1)]);
  });

  it("retires a lease whose later source slice violates its contract", async () => {
    const store = new SessionListPaginationStore({ secret: Buffer.alloc(32, 10) });
    const rows = [summary(0), summary(1), summary(2)];
    const source = {
      generation: "later-malformed", listRevision: 1, count: rows.length, compactByteEstimate: 512,
      page: async (offset: number, limit: number) => offset === 0 ? rows.slice(0, limit) : [],
    };
    const first = await store.firstPage("phone", "user", source, 1);
    await expect(store.nextPage("phone", "user", first.nextCursor!, 1)).rejects.toThrow(/inconsistent/);
    expect(store.activeLeaseCount).toBe(0);
  });
});

describe("session.list stable traversal", () => {
  it("leases a page source and hydrates only requested slices", async () => {
    const store = new SessionListPaginationStore({ secret: Buffer.alloc(32, 7) });
    const rows = Array.from({ length: 25_000 }, (_, index) => summary(index));
    let hydrated = 0;
    const page = vi.fn(async (offset: number, limit: number) => {
      const selected = rows.slice(offset, offset + limit);
      hydrated += selected.length;
      return selected;
    });
    const source = { generation: "25k", listRevision: 3, count: rows.length, compactByteEstimate: 1000, page };
    const first = await store.firstPage("phone", "user", source, 100);
    expect(first.sessions).toHaveLength(100);
    expect(hydrated).toBe(100);
    expect(page).toHaveBeenCalledTimes(1);
    const second = await store.nextPage("phone", "user", first.nextCursor!, 100);
    expect(second.sessions).toHaveLength(100);
    expect(hydrated).toBe(200);
    expect(page).toHaveBeenCalledTimes(2);
  });

  it("releases a disconnected client's wait without cancelling shared catalog materialization", async () => {
    let resolveSource!: (value: ReturnType<typeof pageSource>) => void;
    const materialization = new Promise<ReturnType<typeof pageSource>>((resolve) => { resolveSource = resolve; });
    const pageSourceRead = vi.fn(() => materialization);
    const service = new GatewayService({ sessions: { pageSource: pageSourceRead } } as unknown as GatewayServiceDependencies);
    const controller = new AbortController();
    const listing = service.invoke(client("phone", controller.signal), "session.list", { scope: "user", limit: 100 });
    controller.abort();
    await expect(listing).rejects.toMatchObject({ code: "busy", retryable: true });
    resolveSource(pageSource([summary(1)], 1));
    await expect(materialization).resolves.toMatchObject({ listRevision: 1 });
    expect(pageSourceRead).toHaveBeenCalledTimes(1);
  });

  it("materializes the catalog once per traversal and uses a later traversal for new truth", async () => {
    const firstCatalog = Array.from({ length: 1_000 }, (_, index) => summary(index));
    const secondCatalog = [summary(9_999, "running")];
    const source = (sessions: SessionSummary[], revision: number, generation: string) => ({
      sessions, listRevision: revision, generation, count: sessions.length,
      compactByteEstimate: sessions.reduce((total, row) => total + 96 + row.id.length + row.cwd.length + row.firstMessage.length, 0),
      page: async (offset: number, limit: number) => sessions.slice(offset, offset + limit),
    });
    const pageSource = vi.fn()
      .mockResolvedValueOnce(source(firstCatalog, 7, "generation-7"))
      .mockResolvedValueOnce(source(secondCatalog, 8, "generation-8"));
    const service = new GatewayService({ sessions: { pageSource } } as unknown as GatewayServiceDependencies);
    let response = await service.invoke(client("phone"), "session.list", { scope: "user", limit: 500 }) as {
      sessions: SessionSummary[]; listRevision: number; nextCursor?: string;
    };
    const rows = [...response.sessions];
    expect(pageSource).toHaveBeenCalledTimes(1);
    response = await service.invoke(client("phone"), "session.list", {
      scope: "user", limit: 500, cursor: response.nextCursor,
    }) as typeof response;
    rows.push(...response.sessions);
    expect(pageSource).toHaveBeenCalledTimes(1);
    expect(response.listRevision).toBe(7);
    expect(rows).toHaveLength(1_000);

    const later = await service.invoke(client("phone"), "session.list", { scope: "user", limit: 500 });
    expect(pageSource).toHaveBeenCalledTimes(2);
    expect(later).toEqual({ sessions: secondCatalog, listRevision: 8 });
  });
});
