import { describe, expect, it } from "vitest";
import { canAttachTerminal, clearRequestSynchronizations, encodeOutboundFrame, releaseOwnedSubscription, releaseSessionTerminals } from "./server.js";

describe("bounded outbound gateway frames", () => {
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
      ["session", { requestId: "failed-open", timeout: firstTimeout }],
      ["other", { requestId: "other-open", timeout: otherTimeout }],
    ]);
    try {
      clearRequestSynchronizations(synchronizations, "failed-open");
      expect(synchronizations.has("session")).toBe(false);
      expect(synchronizations.has("other")).toBe(true);
    } finally {
      clearTimeout(firstTimeout);
      clearTimeout(otherTimeout);
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
    const subscriptions = new Set(["session"]);
    const belongs = (terminalId: string, sessionId: string) => terminalId === "terminal" && sessionId === "session";
    expect(canAttachTerminal(subscriptions, "terminal", belongs)).toBe(true);

    subscriptions.delete("session");
    expect(canAttachTerminal(subscriptions, "terminal", belongs)).toBe(false);
    subscriptions.add("replacement");
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
