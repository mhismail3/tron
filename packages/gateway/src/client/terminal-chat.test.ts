import { describe, expect, it, vi } from "vitest";
import type { GatewayProtocolClient } from "./gateway-client.js";
import { GatewayClientError } from "./gateway-client.js";
import {
  connectResilient, describeHomeStatus, homeStatusCommand, listSessions,
  assistantText, parseHomeCommand, parseHomeModelArgument, runHomeCommand, runHomeInput,
  synchronizeTerminalSession,
} from "./terminal-chat.js";
import { waitFor } from "../../test-support/wait-for.js";

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

describe("terminal chat connection", () => {
  it("does not retry a non-retryable protocol mismatch", async () => {
    const connect = vi.fn(async () => { throw new GatewayClientError("protocol_mismatch", "unsupported", false); });
    const close = vi.fn();
    const client = { connect, close } as unknown as import("./gateway-client.js").GatewayProtocolClient;

    await expect(connectResilient(client)).rejects.toMatchObject({ code: "protocol_mismatch", retryable: false });
    expect(connect).toHaveBeenCalledTimes(1);
    expect(close).not.toHaveBeenCalled();
  });
});

describe("terminal chat synchronization", () => {
  it.each(["sync", "install"])("retires only its candidate when %s fails after open", async failure => {
    const owned = new Set(["prior-token"]);
    const closed: unknown[] = [];
    const request = vi.fn(async (method: string, params: Record<string, unknown>) => {
      if (method === "session.open") {
        owned.add("candidate-token");
        return { session: { sessionId: "next" }, syncToken: "candidate-sync", subscriptionToken: "candidate-token" };
      }
      if (method === "session.sync" && failure === "sync") throw new Error("sync failed");
      if (method === "session.close") {
        closed.push(params);
        owned.delete(params.subscriptionToken as string);
      }
      return {};
    });
    const client = { request } as unknown as Pick<GatewayProtocolClient, "request">;
    await expect(synchronizeTerminalSession(client, "next", () => {
      if (failure === "install") throw new Error("install failed");
    })).rejects.toThrow(`${failure} failed`);
    expect([...owned]).toEqual(["prior-token"]);
    expect(closed).toEqual([{ sessionId: "next", subscriptionToken: "candidate-token" }]);
  });
  it("installs the synchronized baseline before a non-blocking transient attention retry", async () => {
    const order: string[] = [];
    let releaseAttention!: () => void;
    const attentionBarrier = new Promise<void>((resolve) => { releaseAttention = resolve; });
    let attentionAttempts = 0;
    const request = vi.fn(async (method: string) => {
      order.push(method);
      if (method === "session.open") {
        return {
          session: { sessionId: "session" },
          syncToken: "sync",
          subscriptionToken: "subscription",
          completionRevision: 19,
        };
      }
      if (method === "session.sync") return { synchronized: true };
      attentionAttempts += 1;
      if (attentionAttempts === 1) {
        await attentionBarrier;
        throw new GatewayClientError("unavailable", "retry", true);
      }
      return { isUnread: false };
    });
    const client = { request } as unknown as Pick<GatewayProtocolClient, "request">;

    const synchronized = await synchronizeTerminalSession(client, "session", () => { order.push("install"); });
    expect(synchronized.completionRevision).toBe(19);
    expect(order).toEqual(["session.open", "session.sync", "install", "session.attention.read"]);
    releaseAttention();
    await waitFor(() => attentionAttempts === 2, "the retried attention read");
    expect(request.mock.calls.filter(([method]) => method === "session.attention.read"))
      .toEqual(Array(2).fill(["session.attention.read", { sessionId: "session", throughCompletionRevision: 19 }, 8_000]));
  });
});

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

describe("terminal chat Home commands", () => {
  it("routes only /home lines to the Home commands", () => {
    expect(parseHomeCommand("hello")).toBeUndefined();
    expect(parseHomeCommand("/homework")).toBeUndefined();
    expect(parseHomeCommand("/home")).toEqual({ kind: "status" });
    expect(parseHomeCommand("/home status")).toEqual({ kind: "status" });
    expect(parseHomeCommand("/home disable")).toEqual({ kind: "disable" });
    expect(parseHomeCommand("/home designate")).toEqual({ kind: "designate" });
    expect(parseHomeCommand("/home designate anthropic/claude-sonnet-4-5"))
      .toEqual({ kind: "designate", model: { provider: "anthropic", id: "claude-sonnet-4-5" } });
    // An unknown subcommand prints usage instead of reaching the model.
    expect(parseHomeCommand("/home please")).toEqual({ kind: "usage" });
    expect(() => parseHomeCommand("/home designate anthropic")).toThrow(/provider\/id/);

    // The memory commands: a fixed shape and a fixed model spelling; no budget (#493).
    expect(parseHomeCommand("/home resume")).toEqual({ kind: "resume" });
    expect(parseHomeCommand("/home context")).toEqual({ kind: "context" });
    expect(parseHomeCommand("/home memory anthropic/claude-haiku-4-5")).toEqual({
      kind: "memory", model: { provider: "anthropic", id: "claude-haiku-4-5" },
    });
    expect(parseHomeCommand("/home memory")).toEqual({ kind: "usage" });
    expect(parseHomeCommand("/home memory anthropic/claude-haiku-4-5 5000")).toEqual({ kind: "usage" });
    expect(() => parseHomeCommand("/home memory anthropic")).toThrow(/provider\/id/);
  });

  it("renders the typed status phase, activation, readiness, memory and recovery", async () => {
    const status = {
      available: true, enabled: true, homeId: "home", sessionId: "session", generation: 1,
      live: true, sessionPresent: true,
      phase: "blocked" as const,
      activation: { available: true as const, activationStartEntryId: "entry-1", activationOpen: false, lastRefusalReason: "memory-blocked" },
      readiness: { ready: false, gaps: ["memory-blocked"] },
      memory: { configured: true, open: true, blocked: "permanent-failure" },
      recovery: { action: "resume-memory" as const, reason: "permanent-failure" },
    };
    const request = vi.fn(async () => status);
    const client = { request } as unknown as Pick<GatewayProtocolClient, "request">;

    const described = await homeStatusCommand(client);
    expect(request).toHaveBeenCalledExactlyOnceWith("home.status", {});
    expect(described).toContain("session");
    expect(described).toContain("blocked");
    expect(described).toContain("entry-1");
    expect(described).toContain("permanent-failure");
    expect(described).toContain("resume-memory");
    const awaiting = describeHomeStatus({
      ...status,
      activation: { available: true, activationStartEntryId: null, activationOpen: true },
    });
    expect(awaiting).toContain("awaiting request preparation");
    expect(awaiting).not.toContain("refused before it prepared a request");

    // Each state is distinguishable from the projection alone.
    const base = { activation: { available: false } as const, readiness: { ready: false, gaps: [] }, recovery: { action: "none" as const }, memory: { configured: false, open: false } };
    expect(describeHomeStatus({ ...base, phase: "unavailable", available: false, reason: "unreadable", enabled: false, live: false, sessionPresent: false }))
      .toContain("unreadable");
    expect(describeHomeStatus({ ...base, phase: "undesignated", available: true, enabled: false, live: false, sessionPresent: false }))
      .not.toEqual(describeHomeStatus({ ...base, phase: "ready", available: true, enabled: true, homeId: "home", sessionId: "session", generation: 1, live: true, sessionPresent: true }));
  });

  it("keeps a malformed command inside the per-command error boundary", async () => {
    const stderr = vi.spyOn(process.stderr, "write").mockImplementation(() => true);
    try {
      await expect(runHomeInput({ request: vi.fn() } as unknown as Pick<GatewayProtocolClient, "request">, "/home memory anthropic"))
        .resolves.toBe(true);
      expect(stderr).toHaveBeenCalledWith(expect.stringContaining("Usage: /home"));
      expect(stderr).toHaveBeenCalledWith(expect.stringContaining("provider/id"));
    } finally {
      stderr.mockRestore();
    }
  });

  it("renders assistant refusal text when the canonical message has no content", () => {
    const snapshot = {
      transcript: [{ kind: "message", role: "assistant", content: [], errorMessage: "Home memory is not configured" }],
    } as unknown as import("../protocol/types.js").SessionSnapshot;
    expect(assistantText(snapshot)).toBe("Home memory is not configured");
  });

  it("prints usage for a bad argument and reports a failed command without ending the chat", async () => {
    const stdout = vi.spyOn(process.stdout, "write").mockImplementation(() => true);
    const stderr = vi.spyOn(process.stderr, "write").mockImplementation(() => true);
    try {
      await runHomeCommand({ request: vi.fn() } as unknown as Pick<GatewayProtocolClient, "request">, { kind: "usage" });
      expect(stderr).toHaveBeenCalledWith(expect.stringContaining("/home memory"));

      const failing = { request: vi.fn(async () => { throw new GatewayClientError("unavailable", "the Gateway is draining", true); }) } as unknown as Pick<GatewayProtocolClient, "request">;
      await runHomeCommand(failing, { kind: "resume" });
      expect(stderr).toHaveBeenLastCalledWith(expect.stringContaining("draining"));
      expect(stdout).not.toHaveBeenCalled();
    } finally {
      stdout.mockRestore();
      stderr.mockRestore();
    }
  });

  it("names the model as provider/id and refuses a malformed argument", () => {
    expect(parseHomeModelArgument("anthropic/claude-sonnet-4-5")).toEqual({ provider: "anthropic", id: "claude-sonnet-4-5" });
    expect(() => parseHomeModelArgument("anthropic")).toThrow(/provider\/id/);
    expect(() => parseHomeModelArgument("/model")).toThrow(/provider\/id/);
  });
});
