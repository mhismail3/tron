import { describe, expect, it } from "vitest";
import { canAttachTerminal, clearRequestSynchronizations, encodeOutboundFrame, existingSessionOpenOwner, releaseOwnedSubscription, releaseSessionTerminals } from "./server.js";
import { SessionSyncBarrier } from "./session-sync.js";

describe("bounded outbound gateway frames", () => {
  it("rejects an overlapping open without replacing the current owner", () => {
    const pending = new Map([["session", "open-1"]]);
    const synchronizations = new Map<string, any>();
    expect(existingSessionOpenOwner(pending, synchronizations, "session")).toBe("open-1");
    expect(existingSessionOpenOwner(pending, synchronizations, "other")).toBeUndefined();
    pending.delete("session");
    synchronizations.set("session", { requestId: "open-1", subscriptionToken: "token-1" });
    expect(existingSessionOpenOwner(pending, synchronizations, "session")).toBe("open-1");
  });

  it("keeps completion ownership exact while independent sessions finish in either order", () => {
    const first = new SessionSyncBarrier();
    const second = new SessionSyncBarrier();
    first.begin("token-1");
    second.begin("token-2");
    first.establish({ runtimeGeneration: "generation-1", eventSequence: 1 });
    second.establish({ runtimeGeneration: "generation-2", eventSequence: 1 });
    const secondCompletion = second.commit("token-2");
    const firstCompletion = first.commit("token-1");
    expect(secondCompletion.events).toEqual([]);
    expect(firstCompletion.events).toEqual([]);
    expect(() => first.commit("token-1")).toThrow();
    expect(() => second.commit("wrong-token")).toThrow();
  });
  it("delivers maximum admitted machine identity fields in the hello frame", () => {
    const hello = {
      type: "hello",
      gatewayVersion: "1.0.0",
      piVersion: "1.0.0",
      protocolVersion: 3,
      minProtocolVersion: 3,
      machineId: "i".repeat(256),
      machineName: "n".repeat(1_024),
      capabilities: ["sessions.v1"],
    };
    const encoded = encodeOutboundFrame(hello, 1_048_576);

    expect(encoded).toBeDefined();
    expect(JSON.parse(encoded!)).toEqual(hello);
  });

  it("returns a correlated error instead of closing the socket for an oversized response", () => {
    const encoded = encodeOutboundFrame({
      type: "response",
      id: "request-1",
      ok: true,
      result: { transcript: "x".repeat(2_000) },
    }, 1_000);

    expect(encoded).toBeDefined();
    expect(JSON.parse(encoded!)).toMatchObject({
      type: "response",
      id: "request-1",
      ok: false,
      error: { code: "response_too_large" },
    });
  });

  it("clears a failed open transaction so the same session can synchronize again immediately", () => {
    const firstTimeout = setTimeout(() => {}, 60_000);
    const otherTimeout = setTimeout(() => {}, 60_000);
    const synchronizations = new Map<string, any>([
      ["session", { requestId: "failed-open", timeout: firstTimeout, subscriptionToken: "failed-token" }],
      ["other", { requestId: "other-open", timeout: otherTimeout, subscriptionToken: "other-token" }],
    ]);
    const tokens = new Map([["session", "failed-token"], ["other", "other-token"]]);
    const subscriptions = new Map([["session", "session-token"], ["other", "other-token"]]);
    const runtimeUnsubscribed: string[] = [];
    try {
      const revoked: string[] = [];
      clearRequestSynchronizations(synchronizations, "failed-open", (sessionID, synchronization) => {
        if (tokens.get(sessionID) !== synchronization.subscriptionToken) return;
        tokens.delete(sessionID);
        subscriptions.delete(sessionID);
        runtimeUnsubscribed.push(sessionID);
        revoked.push(`${sessionID}:${synchronization.subscriptionToken}`);
      });
      expect(synchronizations.has("session")).toBe(false);
      expect(synchronizations.has("other")).toBe(true);
      expect(tokens.has("session")).toBe(false);
      expect(subscriptions.has("session")).toBe(false);
      expect(runtimeUnsubscribed).toEqual(["session"]);
      expect(revoked).toEqual(["session:failed-token"]);
    } finally {
      clearTimeout(firstTimeout);
      clearTimeout(otherTimeout);
    }
  });

  it("does not revoke a newer synchronization owner during failed-open cleanup", () => {
    const timeout = setTimeout(() => {}, 60_000);
    const current = setTimeout(() => {}, 60_000);
    const synchronizations = new Map<string, any>([
      ["session", { requestId: "new-open", timeout: current, subscriptionToken: "new-token" }],
    ]);
    try {
      clearRequestSynchronizations(synchronizations, "failed-open", () => {
        throw new Error("stale cleanup must not be called for a replaced owner");
      });
      expect(synchronizations.get("session")?.subscriptionToken).toBe("new-token");
    } finally {
      clearTimeout(timeout);
      clearTimeout(current);
    }
  });

  it("ignores stale subscription closes and accepts the current owner", () => {
    const tokens = new Map([["session", "current"]]);
    let releases = 0;
    expect(releaseOwnedSubscription(tokens, "session", "stale", () => { releases += 1; })).toBe(false);
    expect(tokens.get("session")).toBe("current");
    expect(releases).toBe(0);
    expect(releaseOwnedSubscription(tokens, "session", "current", () => { releases += 1; })).toBe(true);
    expect(tokens.has("session")).toBe(false);
    expect(releases).toBe(1);
  });

  it("closing one session revokes only its terminal attachments", () => {
    const terminals = new Set(["first", "second"]);
    releaseSessionTerminals(
      terminals,
      "session-1",
      (terminalId, sessionId) => terminalId === "first" && sessionId === "session-1",
    );
    expect([...terminals]).toEqual(["second"]);
  });

  it("terminal attachment follows current subscription ownership", () => {
    const subscriptions = new Map([["session", "session-token"]]);
    const belongs = (terminalId: string, sessionId: string) => terminalId === "terminal" && sessionId === "session";
    expect(canAttachTerminal(subscriptions, "terminal", belongs)).toBe(true);

    subscriptions.delete("session");
    expect(canAttachTerminal(subscriptions, "terminal", belongs)).toBe(false);
    subscriptions.set("replacement", "replacement-token");
    expect(canAttachTerminal(subscriptions, "terminal", belongs)).toBe(false);
  });

  it("turns an oversized snapshot event into a bounded resync hint", () => {
    const encoded = encodeOutboundFrame({
      type: "event",
      topic: "session.snapshot",
      sessionId: "session-1",
      payload: { transcript: "x".repeat(2_000) },
    }, 1_000);

    expect(encoded).toBeDefined();
    expect(JSON.parse(encoded!)).toMatchObject({
      type: "event",
      topic: "transport.resyncRequired",
      sessionId: "session-1",
      payload: { reason: "oversized projection" },
    });
  });
});
