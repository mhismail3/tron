import { describe, expect, it, vi } from "vitest";
import { GatewayService, type ClientContext, type GatewayServiceDependencies } from "./gateway-service.js";

const client = { id: "phone", identity: "device:fixture", isLocal: false,
  isSubscribed: (session: string) => session === "session", isRevoked: () => false } as unknown as ClientContext;

describe("session history dispatch", () => {
  it("admits only subscribed session reads and validates exact cursor/runtime parameters", async () => {
    const history = vi.fn(() => ({ nodes: [], totalEntries: 0, runtimeGeneration: "runtime" }));
    const historyDetail = vi.fn(() => ({ text: "complete" }));
    const sessions = { isSubscribed: (_client: string, session: string) => session === "session",
      acquire: vi.fn(async () => ({ history, historyDetail })) };
    const service = new GatewayService({ config: { machineId: "fixture", machineName: "Fixture", tronHome: "/fixture" }, sessions } as unknown as GatewayServiceDependencies);
    await service.invoke(client, "session.history.list", { sessionId: "session", runtimeGeneration: "runtime", cursor: { ordinal: 100, entryId: "entry", direction: "older" } });
    expect(history).toHaveBeenCalledWith("runtime", { ordinal: 100, entryId: "entry", direction: "older" });
    await service.invoke(client, "session.history.entry", { sessionId: "session", runtimeGeneration: "runtime", entryId: "entry", offset: 24_000 });
    expect(historyDetail).toHaveBeenCalledWith("runtime", "entry", 24_000);
    await expect(service.invoke(client, "session.history.list", { sessionId: "other", runtimeGeneration: "runtime" })).rejects.toThrow();
    await expect(service.invoke(client, "session.history.list", { sessionId: "session" })).rejects.toThrow();
    await expect(service.invoke(client, "session.history.entry", { sessionId: "session", runtimeGeneration: "runtime", entryId: "entry", offset: -1 })).rejects.toThrow();
    await expect(service.invoke(client, "session.history.list", { sessionId: "session", runtimeGeneration: "runtime", cursor: { ordinal: 100, entryId: "entry", direction: "invalid" } })).rejects.toThrow();
    expect(history).toHaveBeenCalledTimes(1);
    expect(historyDetail).toHaveBeenCalledTimes(1);
  });
});
