import { describe, expect, it, vi } from "vitest";
import { GatewayService, type ClientContext, type GatewayServiceDependencies } from "./gateway-service.js";

const client: ClientContext = {
  id: "phone",
  identity: "device:test",
  isLocal: false,
  beginSynchronization: () => "sync",
  establishSynchronization: () => {},
  completeSynchronization: () => {},
  unsubscribe: () => true,
  attachTerminal: () => {},
  detachTerminal: () => {},
};

describe("session transcript paging", () => {
  it("returns a bounded page without creating subscription ownership", async () => {
    const transcriptPage = vi.fn(() => ({
      items: [{ id: "entry", type: "message", role: "user", text: "earlier" }],
      start: 0,
      total: 1,
    }));
    const acquire = vi.fn(async () => ({ transcriptPage }));
    const service = new GatewayService({
      sessions: { acquire },
    } as unknown as GatewayServiceDependencies);

    await expect(service.invoke(client, "session.transcript", {
      sessionId: "session",
      before: 1,
      expectedNextEntryId: "next",
    })).resolves.toEqual({
      items: [{ id: "entry", type: "message", role: "user", text: "earlier" }],
      start: 0,
      total: 1,
    });
    expect(acquire).toHaveBeenCalledWith("session");
    expect(transcriptPage).toHaveBeenCalledWith(1, "next");
  });
});
