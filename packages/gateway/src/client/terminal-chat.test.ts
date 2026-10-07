import { describe, expect, it, vi } from "vitest";
import type { GatewayProtocolClient } from "./gateway-client.js";
import { GatewayClientError } from "./gateway-client.js";
import { afterEach } from "vitest";
import {
  configureHomeMemory, connectResilient, designateHome, describeHomeContext, describeHomeMemory,
  describeHomeStatus, disableHome, homeContextCommand, homeStatusCommand, listSessions,
  parseHomeCommand, parseHomeModelArgument, resumeHomeMemory, runHomeCommand,
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

  it("reads home.status and reports what the Gateway returned", async () => {
    const request = vi.fn(async () => ({ available: true, enabled: true, homeId: "home", sessionId: "session", generation: 1, live: true }));
    const client = { request } as unknown as Pick<GatewayProtocolClient, "request">;

    const described = await homeStatusCommand(client);
    expect(request).toHaveBeenCalledExactlyOnceWith("home.status", {});
    expect(described).toContain("session");

    // Each state is distinguishable from the projection alone.
    expect(describeHomeStatus({ available: false, reason: "unreadable", enabled: false, live: false, sessionPresent: false }))
      .toContain("unreadable");
    expect(describeHomeStatus({ available: true, enabled: false, live: false, sessionPresent: false }))
      .not.toEqual(describeHomeStatus({ available: true, enabled: true, homeId: "home", sessionId: "session", generation: 1, live: true, sessionPresent: true }));
  });

  it("sends the two mutations with a command id and reports the new generation", async () => {
    const request = vi.fn(async (_method: string, _params: Record<string, unknown>) => ({ homeId: "home", sessionId: "session", generation: 2 }));
    const client = { request } as unknown as Pick<GatewayProtocolClient, "request">;

    const designated = await designateHome(client, { provider: "anthropic", id: "claude-sonnet-4-5" });
    expect(request).toHaveBeenLastCalledWith("home.designate", {
      commandId: expect.any(String), model: { provider: "anthropic", id: "claude-sonnet-4-5" },
    });
    expect(designated).toContain("session");

    await designateHome(client);
    expect(request).toHaveBeenLastCalledWith("home.designate", { commandId: expect.any(String) });

    const disabled = await disableHome(client);
    expect(request).toHaveBeenLastCalledWith("home.disable", { commandId: expect.any(String) });
    expect(disabled).toContain("session");
  });

  it("configures Home's memory with the model it was given", async () => {
    const model = { provider: "anthropic", id: "claude-haiku-4-5" };
    const request = vi.fn(async (_method: string, _params: Record<string, unknown>) => ({
      configured: true, open: false, model,
    }));
    const client = { request } as unknown as Pick<GatewayProtocolClient, "request">;

    const described = await configureHomeMemory(client, model);
    expect(request).toHaveBeenLastCalledWith("home.configureMemory", { commandId: expect.any(String), model });
    expect(described).toContain(model.id);
    expect(described).not.toContain("budget");

    // The state the projection reports is what makes each outcome distinguishable:
    // an open store with a spend, a blocked one with its reason, and none at all.
    expect(describeHomeMemory({ configured: true, open: true, model, spentTokens: 1_200 }))
      .toContain("1200");
    expect(describeHomeMemory({ configured: true, open: false, model, blocked: "permanent-failure" }))
      .toContain("permanent-failure");
    expect(describeHomeMemory({ configured: false, open: false })).toContain("not configured");
  });

  it("resumes Home's memory and reports the state it left", async () => {
    const model = { provider: "anthropic", id: "claude-haiku-4-5" };
    const request = vi.fn(async () => ({
      configured: true, open: true, model, spentTokens: 900,
    }));
    const client = { request } as unknown as Pick<GatewayProtocolClient, "request">;

    const before = describeHomeMemory({ configured: true, open: false, model, blocked: "retries-exhausted" });
    const after = await resumeHomeMemory(client);
    expect(request).toHaveBeenLastCalledWith("home.resumeMemory", { commandId: expect.any(String) });
    expect(before).toContain("retries-exhausted");
    expect(after).not.toContain("blocked");
    expect(after).toContain("900");
  });

  it("reads the request context and prints its bounded fields", async () => {
    const request = vi.fn(async () => ({
      available: true, activationStartEntryId: "entry-2", activationOpen: false,
      viewLines: 7, viewBytes: 500, effectiveTokens: 2_197, contextWindow: 128_000,
      lastRefusalReason: "context-overflow", lastRefusalDetail: "effective 2197 tokens leave no head-room",
    }));
    const client = { request } as unknown as Pick<GatewayProtocolClient, "request">;

    const described = await homeContextCommand(client);
    expect(request).toHaveBeenCalledExactlyOnceWith("home.context", {});
    expect(described).toContain("entry-2");
    expect(described).toContain("7");
    expect(described).toContain("128000");
    expect(described).toContain("context-overflow");

    // An activation refused before it prepared a request has its reason and no
    // sizes, and a Home that never ran one says so rather than inventing numbers.
    const refused = describeHomeContext({ available: true, activationStartEntryId: "entry-3", activationOpen: false, lastRefusalReason: "memory-not-configured" });
    expect(refused).toContain("memory-not-configured");
    expect(refused).not.toContain("view lines");
    expect(describeHomeContext({ available: true, activationStartEntryId: null, activationOpen: true, viewLines: 0, viewBytes: 0, effectiveTokens: 0, contextWindow: 0 }))
      .toContain("open");
    expect(describeHomeContext({ available: false })).toContain("no activation");
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
