import { describe, expect, it } from "vitest";
import { encodeOutboundFrame } from "./server.js";

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
