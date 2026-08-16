import { describe, expect, it, vi } from "vitest";
import type { GatewayProtocolClient } from "./gateway-client.js";
import { listSessions } from "./terminal-chat.js";

function session(id: string, extra: Record<string, unknown> = {}) {
  return { id, cwd: "/workspace", firstMessage: id, ...extra };
}

function clientWithPages(pages: unknown[]): Pick<GatewayProtocolClient, "request"> & { request: ReturnType<typeof vi.fn> } {
  const request = vi.fn(async () => {
    const page = pages.shift();
    if (page === undefined) throw new Error("unexpected extra page request");
    return page;
  });
  return { request } as unknown as Pick<GatewayProtocolClient, "request"> & { request: ReturnType<typeof vi.fn> };
}

describe("terminal chat session catalog", () => {
  it("collects one immutable bounded traversal", async () => {
    const client = clientWithPages([
      { sessions: [session("first")], nextCursor: "next", listRevision: 1 },
      { sessions: [session("second")], listRevision: 1 },
    ]);

    await expect(listSessions(client, { pageSize: 1 })).resolves.toEqual([
      session("first"), session("second"),
    ]);
    expect(client.request).toHaveBeenCalledTimes(2);
    expect(client.request.mock.calls).toEqual([
      ["session.list", { cursor: null, limit: 1 }],
      ["session.list", { cursor: "next", limit: 1 }],
    ]);
  });

  it("restarts mixed revisions once and retains only the fresh traversal", async () => {
    const client = clientWithPages([
      { sessions: [session("stale")], nextCursor: "stale-next", listRevision: 1 },
      { sessions: [session("mixed")], listRevision: 2 },
      { sessions: [session("fresh")], listRevision: 2 },
    ]);

    await expect(listSessions(client, { pageSize: 1 })).resolves.toEqual([session("fresh")]);
    expect(client.request).toHaveBeenCalledTimes(3);
  });

  it("fails after one mixed-revision restart instead of recursing indefinitely", async () => {
    const client = clientWithPages([
      { sessions: [session("one")], nextCursor: "one", listRevision: 1 },
      { sessions: [session("two")], listRevision: 2 },
      { sessions: [session("three")], nextCursor: "three", listRevision: 3 },
      { sessions: [session("four")], listRevision: 4 },
    ]);

    await expect(listSessions(client, { pageSize: 1 })).rejects.toThrow(/changed repeatedly/);
    expect(client.request).toHaveBeenCalledTimes(4);
  });

  it("rejects cursor cycles, duplicate identities, and retained-byte overflow", async () => {
    const cycling = clientWithPages([
      { sessions: [session("one")], nextCursor: "same", listRevision: 1 },
      { sessions: [session("two")], nextCursor: "same", listRevision: 1 },
    ]);
    await expect(listSessions(cycling, { pageSize: 1 })).rejects.toThrow(/cursor stalled/);

    const duplicate = clientWithPages([{
      sessions: [session("same"), session("same")], listRevision: 1,
    }]);
    await expect(listSessions(duplicate)).rejects.toThrow(/ambiguous/);

    const oversized = clientWithPages([{
      sessions: [session("large", { firstMessage: "x".repeat(100) })], listRevision: 1,
    }]);
    await expect(listSessions(oversized, { maximumBytes: 32 })).rejects.toThrow(/capacity/);
  });

  it("rejects malformed and overlong pages before publication", async () => {
    const malformed = clientWithPages([{ sessions: "not-an-array", listRevision: 1 }]);
    await expect(listSessions(malformed)).rejects.toThrow(/malformed/);

    const overlong = clientWithPages([{
      sessions: [session("one"), session("two")], listRevision: 1,
    }]);
    await expect(listSessions(overlong, { pageSize: 1 })).rejects.toThrow(/malformed/);
  });
});
