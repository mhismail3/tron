import { describe, expect, it } from "vitest";
import { canAttachTerminal, clearRequestSynchronizations, existingSessionOpenOwner, heartbeatTimerDelay, HttpTransportAdmission, releaseSessionTerminals, shouldTerminateHeartbeat } from "./server.js";
import { SessionSyncBarrier } from "./session-sync.js";

describe("bounded outbound gateway frames", () => {
  it("bounds HTTP requests globally and per identity with exact idempotent release", () => {
    const admission = new HttpTransportAdmission(2, 1);
    const connection = {};
    const first = admission.admit("fixture", connection);
    const second = admission.admit("fixture", connection);
    expect(first).toBeDefined();
    expect(second).toBeDefined();
    expect(admission.admit("fixture", connection)).toBeUndefined();

    first!.identify("device-a");
    expect(() => second!.identify("device-a")).toThrow("HTTP request capacity");
    second!.identify("device-b");
    first!.release();
    first!.release();
    expect(admission.snapshot()).toMatchObject({ activeRequests: 1, identities: 1 });
    const replacement = admission.admit("fixture", connection);
    expect(replacement).toBeDefined();
    replacement!.identify("device-a");
    replacement!.release();
    second!.release();
    expect(admission.snapshot()).toMatchObject({ activeRequests: 0, identities: 0 });
  });

  it("tolerates two unanswered heartbeat rounds before retiring a client", () => {
    expect(shouldTerminateHeartbeat(0)).toBe(false);
    expect(shouldTerminateHeartbeat(1)).toBe(false);
    expect(shouldTerminateHeartbeat(2)).toBe(false);
    expect(shouldTerminateHeartbeat(3)).toBe(true);
    expect(heartbeatTimerDelay(25_000)).toBe(0);
    expect(heartbeatTimerDelay(61_250)).toBe(36_250);
  });

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
});
