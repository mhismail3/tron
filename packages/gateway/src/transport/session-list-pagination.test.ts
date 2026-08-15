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

const client = (id: string): ClientContext => ({
  id,
  identity: `device:${id}`,
  isLocal: false,
  beginSynchronization: () => "sync",
  establishSynchronization: () => {},
  completeSynchronization: () => {},
  unsubscribe: () => true,
  attachTerminal: () => {},
  detachTerminal: () => {},
});

describe("SessionListPaginationStore", () => {
  it("pages 1000 rows from one immutable revision with exact ordering and no gaps", () => {
    const store = new SessionListPaginationStore({ secret: Buffer.alloc(32, 1) });
    const canonical = Array.from({ length: 1_000 }, (_, index) => summary(index));
    let page = store.firstPage("phone", "user", { sessions: canonical, listRevision: 41 }, 137);
    const received = [...page.sessions];
    canonical.splice(0, canonical.length, summary(2_000, "running"));
    while (page.nextCursor) {
      page = store.nextPage("phone", "user", page.nextCursor, 137);
      expect(page.listRevision).toBe(41);
      received.push(...page.sessions);
    }
    expect(received.map((item) => item.id)).toEqual(
      Array.from({ length: 1_000 }, (_, index) => summary(index).id),
    );
    expect(new Set(received.map((item) => item.id)).size).toBe(1_000);
    expect(store.activeLeaseCount).toBe(0);
  });

  it("rejects stale, wrong-client, wrong-scope, and tampered cursors", () => {
    let now = 100;
    const store = new SessionListPaginationStore({
      now: () => now,
      leaseTTLms: 20,
      secret: Buffer.alloc(32, 2),
    });
    const first = store.firstPage("phone", "user", {
      sessions: [summary(0), summary(1), summary(2)],
      listRevision: 1,
    }, 1);
    expect(() => store.nextPage("tablet", "user", first.nextCursor!, 1)).toThrow(/invalid or expired/);
    expect(() => store.nextPage("phone", "all", first.nextCursor!, 1)).toThrow(/invalid or expired/);
    expect(() => store.nextPage("phone", "user", `${first.nextCursor!}x`, 1)).toThrow(/invalid or expired/);
    now = 120;
    expect(() => store.nextPage("phone", "user", first.nextCursor!, 1)).toThrow(/invalid or expired/);
  });

  it("enforces LRU lease and materialization count bounds", () => {
    let now = 0;
    const store = new SessionListPaginationStore({
      now: () => now,
      maxLeases: 2,
      maxSessionsPerLease: 3,
      secret: Buffer.alloc(32, 3),
    });
    const first = store.firstPage("one", "user", { sessions: [summary(0), summary(1)], listRevision: 1 }, 1);
    now += 1;
    const second = store.firstPage("two", "user", { sessions: [summary(2), summary(3)], listRevision: 2 }, 1);
    now += 1;
    const third = store.firstPage("three", "user", { sessions: [summary(4), summary(5)], listRevision: 3 }, 1);
    expect(store.activeLeaseCount).toBe(2);
    expect(() => store.nextPage("one", "user", first.nextCursor!, 1)).toThrow(/invalid or expired/);
    expect(store.nextPage("two", "user", second.nextCursor!, 1).sessions).toEqual([summary(3)]);
    expect(store.nextPage("three", "user", third.nextCursor!, 1).sessions).toEqual([summary(5)]);
    expect(() => store.firstPage("large", "user", {
      sessions: [summary(0), summary(1), summary(2), summary(3)],
      listRevision: 4,
    }, 1)).toThrow(/too large/);
  });

  it("bounds retained rows across all concurrent leases", () => {
    const store = new SessionListPaginationStore({
      maxLeases: 8,
      maxSessionsPerLease: 4,
      maxTotalSessions: 5,
      secret: Buffer.alloc(32, 4),
    });
    const first = store.firstPage("one", "user", {
      sessions: [summary(0), summary(1), summary(2)], listRevision: 1,
    }, 1);
    const second = store.firstPage("two", "user", {
      sessions: [summary(3), summary(4), summary(5)], listRevision: 2,
    }, 1);

    expect(store.activeLeaseCount).toBe(1);
    expect(() => store.nextPage("one", "user", first.nextCursor!, 1)).toThrow(/invalid or expired/);
    expect(store.nextPage("two", "user", second.nextCursor!, 1).sessions).toEqual([summary(4)]);
  });

  it("bounds retained bytes and isolates each client's lease quota", () => {
    const store = new SessionListPaginationStore({
      maxLeases: 4,
      maxLeasesPerClient: 1,
      maxBytesPerLease: 1_000,
      maxTotalBytes: 2_000,
      secret: Buffer.alloc(32, 5),
    });
    const phoneFirst = store.firstPage("phone", "user", {
      sessions: [summary(0), summary(1)], listRevision: 1,
    }, 1);
    const tablet = store.firstPage("tablet", "user", {
      sessions: [summary(2), summary(3)], listRevision: 2,
    }, 1);
    const phoneSecond = store.firstPage("phone", "user", {
      sessions: [summary(4), summary(5)], listRevision: 3,
    }, 1);

    expect(() => store.nextPage("phone", "user", phoneFirst.nextCursor!, 1)).toThrow(/invalid or expired/);
    expect(store.nextPage("tablet", "user", tablet.nextCursor!, 1).sessions).toEqual([summary(3)]);
    expect(store.nextPage("phone", "user", phoneSecond.nextCursor!, 1).sessions).toEqual([summary(5)]);

    const oversized = { ...summary(6), firstMessage: "x".repeat(2_000) };
    expect(() => store.firstPage("large", "user", {
      sessions: [oversized, summary(7)], listRevision: 4,
    }, 1)).toThrow(/too large/);

    const abandoned = store.firstPage("abandoned", "user", {
      sessions: [summary(8), summary(9)], listRevision: 5,
    }, 1);
    store.releaseClient("abandoned");
    expect(() => store.nextPage("abandoned", "user", abandoned.nextCursor!, 1)).toThrow(/invalid or expired/);
  });
});

describe("session.list stable traversal", () => {
  it("materializes the catalog once per traversal and uses a later traversal for new truth", async () => {
    const firstCatalog = Array.from({ length: 1_000 }, (_, index) => summary(index));
    const secondCatalog = [summary(9_999, "running")];
    const catalog = vi.fn()
      .mockResolvedValueOnce({ sessions: firstCatalog, listRevision: 7 })
      .mockResolvedValueOnce({ sessions: secondCatalog, listRevision: 8 });
    const service = new GatewayService({ sessions: { catalog } } as unknown as GatewayServiceDependencies);
    let response = await service.invoke(client("phone"), "session.list", { scope: "user", limit: 500 }) as {
      sessions: SessionSummary[]; listRevision: number; nextCursor?: string;
    };
    const rows = [...response.sessions];
    expect(catalog).toHaveBeenCalledTimes(1);
    response = await service.invoke(client("phone"), "session.list", {
      scope: "user", limit: 500, cursor: response.nextCursor,
    }) as typeof response;
    rows.push(...response.sessions);
    expect(catalog).toHaveBeenCalledTimes(1);
    expect(response.listRevision).toBe(7);
    expect(rows).toHaveLength(1_000);

    const later = await service.invoke(client("phone"), "session.list", { scope: "user", limit: 500 });
    expect(catalog).toHaveBeenCalledTimes(2);
    expect(later).toEqual({ sessions: secondCatalog, listRevision: 8 });
  });
});
