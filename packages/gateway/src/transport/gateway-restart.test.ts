import { afterEach, describe, expect, it, vi } from "vitest";
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
  ownsTerminal: () => false,
};

function service(options: { activeSessions?: string[]; activeTerminals?: string[]; requestRestart?: () => void } = {}) {
  const dependencies = {
    sessions: { activeSessionIds: () => options.activeSessions ?? [] },
    terminals: { activeTerminalIds: () => options.activeTerminals ?? [] },
    receipts: { execute: async (_identity: string, _method: string, _commandId: string, operation: () => Promise<unknown>) => operation() },
    requestRestart: options.requestRestart ?? (() => {}),
  } as unknown as GatewayServiceDependencies;
  return new GatewayService(dependencies);
}

afterEach(() => {
  vi.useRealTimers();
  vi.unstubAllEnvs();
});

describe("Gateway administrative restart", () => {
  it("fails closed when the Gateway is not externally supervised", async () => {
    vi.stubEnv("TRON_GATEWAY_SUPERVISED", "0");
    const gateway = service();
    await expect(gateway.invoke(client, "gateway.restart", { commandId: "restart-command" }))
      .rejects.toMatchObject({ code: "unsupported" });
  });

  it("refuses process replacement while a terminal PTY is alive", async () => {
    vi.stubEnv("TRON_GATEWAY_SUPERVISED", "1");
    const gateway = service({ activeTerminals: ["terminal-1"] });
    await expect(gateway.invoke(client, "gateway.restart", { commandId: "restart-command" }))
      .rejects.toMatchObject({ code: "busy" });
  });

  it("schedules one restart after active agents settle and freezes new mutations", async () => {
    vi.stubEnv("TRON_GATEWAY_SUPERVISED", "1");
    vi.useFakeTimers();
    const requestRestart = vi.fn();
    const gateway = service({ activeSessions: ["session-1"], requestRestart });

    await expect(gateway.invoke(client, "gateway.restart", { commandId: "restart-command" })).resolves.toEqual({
      restarting: false,
      scheduled: true,
      activeSessionIds: ["session-1"],
    });
    await expect(gateway.invoke(client, "settings.update", {})).rejects.toMatchObject({ code: "busy" });
    await expect(gateway.invoke(client, "gateway.restart", { commandId: "restart-command-2" })).resolves.toMatchObject({ scheduled: true });

    await vi.runAllTimersAsync();
    expect(requestRestart).toHaveBeenCalledTimes(1);
  });
});
