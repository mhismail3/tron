import { afterEach, describe, expect, it, vi } from "vitest";
import { GatewayService, type ClientContext, type GatewayServiceDependencies } from "./gateway-service.js";
import { GatewayWorkRegistry } from "../sessions/gateway-work-registry.js";

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
  isSubscribed: () => true, isRevoked: () => false, revokeDevice: () => {},
};

function drain(blockerCount = 0) {
  return {
    drainId: "drain-1", revision: 1, phase: blockerCount > 0 ? "preparing" : "idle",
    blockerCount, blockerCounts: blockerCount > 0 ? { "foreground-agent-operation": blockerCount } : {},
    blockers: [], omittedCount: 0, suspectProjectionCount: 0,
  } as const;
}

import { RestartArmUncertainError } from "../lifecycle/restart-watchdog.js";

function service(options: {
  activeSessions?: string[];
  activeTerminals?: string[];
  requestRestart?: () => void;
  armRestartWatchdog?: () => Promise<number>;
  beginRestartCancellation?: () => void;
  executeReceipt?: GatewayServiceDependencies["receipts"]["execute"];
  workRegistry?: GatewayWorkRegistry;
  rename?: (name: string) => Promise<void>;
  upsertGrant?: (input: unknown) => Promise<unknown>;
} = {}) {
  const snapshot = drain((options.activeSessions ?? []).length);
  const dependencies = {
    sessions: {
      activeSessionIds: () => options.activeSessions ?? [],
      beginAdministrativeDrain: () => {
        options.workRegistry?.beginDrain();
        return snapshot;
      },
      administrativeDrainSnapshot: () => snapshot,
      acquire: async () => ({ rename: options.rename ?? (async () => {}) }),
    },
    terminals: {
      activeTerminalIds: () => options.activeTerminals ?? [],
      beginRestartDrain: () => true,
    },
    receipts: { execute: options.executeReceipt ?? (async (_identity: string, _method: string, _commandId: string, operation: () => Promise<unknown>) => operation()) },
    devices: { hasDevice: async () => true },
    notifications: {
      upsertGrant: options.upsertGrant ?? (async () => ({})),
      removeDevice: async () => true,
    },
    requestRestart: options.requestRestart ?? (() => {}),
    armRestartWatchdog: options.armRestartWatchdog ?? (async () => Date.now() + 15_000),
    ...(options.beginRestartCancellation ? { beginRestartCancellation: options.beginRestartCancellation } : {}),
    ...(options.workRegistry ? { workRegistry: options.workRegistry } : {}),
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

  it("accepts restart with an active terminal and leaves interruption to its owner", async () => {
    vi.stubEnv("TRON_GATEWAY_SUPERVISED", "1");
    vi.useFakeTimers();
    const requestRestart = vi.fn();
    const gateway = service({ activeTerminals: ["terminal-1"], requestRestart });
    await expect(gateway.invoke(client, "gateway.restart", { commandId: "restart-command" }))
      .resolves.toMatchObject({ activeSessionIds: [] });
    await vi.advanceTimersByTimeAsync(100);
    expect(requestRestart).toHaveBeenCalledTimes(1);
  });

  it("schedules one restart despite active agents and freezes new mutations", async () => {
    vi.stubEnv("TRON_GATEWAY_SUPERVISED", "1");
    vi.useFakeTimers();
    const requestRestart = vi.fn();
    const gateway = service({ activeSessions: ["session-1"], requestRestart });

    await expect(gateway.invoke(client, "gateway.restart", { commandId: "restart-command" })).resolves.toEqual({
      restartDeadline: Date.now() + 15_000,
      restarting: false,
      scheduled: true,
      activeSessionIds: ["session-1"],
      drainId: "drain-1",
      drainRevision: 1,
      drain: drain(1),
    });
    for (const method of ["settings.update", "session.attention.set", "gateway.update.config", "gateway.update", "gateway.rollback"]) {
      await expect(gateway.invoke(client, method, {})).rejects.toMatchObject({ code: "busy" });
    }
    await expect(gateway.invoke(client, "gateway.restart", { commandId: "restart-command-2" }))
      .rejects.toMatchObject({ code: "busy" });

    await expect(gateway.invoke(client, "gateway.drain.status", {})).resolves.toEqual(drain(1));
    await expect(gateway.invoke(client, "gateway.drain.status", { path: "/private/value" }))
      .rejects.toMatchObject({ code: "invalid_request" });

    await vi.runAllTimersAsync();
    expect(requestRestart).toHaveBeenCalledTimes(1);
  });

  it("does not self-deadlock when restart receipt ownership closes admission", async () => {
    vi.stubEnv("TRON_GATEWAY_SUPERVISED", "1");
    vi.useFakeTimers();
    const registry = new GatewayWorkRegistry("epoch", 8);
    const requestRestart = vi.fn();
    const gateway = service({ workRegistry: registry, requestRestart });
    await expect(gateway.invoke(client, "gateway.restart", { commandId: "restart-command" }))
      .resolves.toMatchObject({ drainId: "drain-1" });
    expect(registry.size).toBe(0);
    await vi.advanceTimersByTimeAsync(100);
    expect(requestRestart).toHaveBeenCalledTimes(1);
  });

  it("still progresses an accepted drain after the completed receipt write attempt fails", async () => {
    vi.stubEnv("TRON_GATEWAY_SUPERVISED", "1");
    vi.useFakeTimers();
    const requestRestart = vi.fn();
    const gateway = service({
      requestRestart,
      executeReceipt: async (_identity, _method, _commandId, operation) => {
        await operation();
        throw new Error("injected completed receipt failure");
      },
    });

    await expect(gateway.invoke(client, "gateway.restart", { commandId: "restart-command" }))
      .rejects.toThrow("injected completed receipt failure");
    await vi.advanceTimersByTimeAsync(100);
    expect(requestRestart).toHaveBeenCalledTimes(1);
  });

  it("closes terminal admission before a dispatched terminal.open resumes", async () => {
    vi.stubEnv("TRON_GATEWAY_SUPERVISED", "1");
    vi.useFakeTimers();
    let releaseSlot!: () => void;
    const slotBarrier = new Promise<void>((resolve) => { releaseSlot = resolve; });
    let gateClosed = false;
    const spawn = vi.fn(() => {
      if (gateClosed) throw Object.assign(new Error("Gateway restart is not accepting terminal sessions"), { code: "busy" });
      return { id: "terminal", sessionId: "session", cwd: "/tmp", createdAt: "now", sequence: 0 };
    });
    const snapshot = drain(0);
    const dependencies = {
      sessions: {
        isSubscribed: () => true,
        retainLiveSession: () => () => {},
        acquire: async () => {
          await slotBarrier;
          return { id: "session", cwd: "/tmp", sessionEnvironment: () => ({}) };
        },
        activeSessionIds: () => [],
        beginAdministrativeDrain: () => snapshot,
        administrativeDrainSnapshot: () => snapshot,
      },
      terminals: {
        beginRestartDrain: () => { gateClosed = true; return true; },
        open: spawn,
        attach: () => ({ terminal: {}, chunks: [], reset: false }),
      },
      receipts: { execute: async (_identity: string, _method: string, _commandId: string, operation: () => Promise<unknown>) => operation() },
      requestRestart: () => {},
      armRestartWatchdog: async () => Date.now() + 15_000,
    } as unknown as GatewayServiceDependencies;
    const gateway = new GatewayService(dependencies);
    const opening = gateway.invoke(client, "terminal.open", { sessionId: "session", commandId: "terminal-open-command" });
    await Promise.resolve();
    await gateway.invoke(client, "gateway.restart", { commandId: "restart-command" });
    releaseSlot();
    await expect(opening).rejects.toMatchObject({ code: "busy" });
    expect(spawn).toHaveBeenCalledTimes(1);
  });

  it("holds non-restart mutation ownership through its completed receipt write", async () => {
    const registry = new GatewayWorkRegistry("epoch", 8);
    let releaseReceipt!: () => void;
    const receiptBarrier = new Promise<void>((resolve) => { releaseReceipt = resolve; });
    let renamed!: () => void;
    const renameStarted = new Promise<void>((resolve) => { renamed = resolve; });
    const gateway = service({
      workRegistry: registry,
      rename: async () => { renamed(); },
      executeReceipt: async (_identity, _method, _commandId, operation) => {
        const result = await operation();
        await receiptBarrier;
        return result;
      },
    });

    const mutation = gateway.invoke(client, "session.rename", {
      sessionId: "session-1", name: "Renamed", commandId: "rename-command",
    });
    await renameStarted;
    registry.beginDrain();
    let settled = false;
    const drain = registry.waitUntilSettled().then(() => { settled = true; });
    await Promise.resolve();
    expect(settled).toBe(false);
    releaseReceipt();
    await mutation;
    await drain;
    expect(settled).toBe(true);
  });

  it("owns mobile mutations before they wait in the per-device lane", async () => {
    const registry = new GatewayWorkRegistry("epoch", 8);
    let releaseFirst!: () => void;
    const firstBarrier = new Promise<void>((resolve) => { releaseFirst = resolve; });
    let calls = 0;
    const gateway = service({
      workRegistry: registry,
      upsertGrant: async () => {
        calls += 1;
        if (calls === 1) await firstBarrier;
        return {};
      },
    });
    const params = (commandId: string) => ({
      commandId,
      installationId: "installation-123",
      grantId: `grant-${commandId}`,
      secret: "s".repeat(43),
      previewsEnabled: false,
      relayOrigin: "https://push.example.test",
    });

    const first = gateway.invoke(client, "push.registration.upsert", params("command-one"));
    await vi.waitFor(() => expect(calls).toBe(1));
    const second = gateway.invoke(client, "push.registration.upsert", params("command-two"));
    await vi.waitFor(() => expect(registry.size).toBe(2));
    registry.beginDrain();
    releaseFirst();

    await expect(Promise.all([first, second])).resolves.toHaveLength(2);
    expect(calls).toBe(2);
    expect(registry.size).toBe(0);
  });

  it("arms the fallback before cancellation and still schedules after cancellation throws", async () => {
    vi.stubEnv("TRON_GATEWAY_SUPERVISED", "1");
    vi.useFakeTimers();
    const calls: string[] = [];
    const requestRestart = vi.fn();
    const gateway = service({
      requestRestart,
      armRestartWatchdog: async () => { calls.push("armed"); return Date.now() + 15_000; },
      beginRestartCancellation: () => {
        calls.push("cancel");
        throw new Error("cleanup failed");
      },
    });
    await expect(gateway.invoke(client, "gateway.restart", { commandId: "cleanup-failure" }))
      .rejects.toThrow("cleanup failed");
    expect(calls).toEqual(["armed", "cancel"]);
    await vi.advanceTimersByTimeAsync(100);
    expect(requestRestart).toHaveBeenCalledTimes(1);
  });

  it("rejects failed native arming without entering cancellation or claiming accepted restart", async () => {
    vi.stubEnv("TRON_GATEWAY_SUPERVISED", "1");
    vi.useFakeTimers();
    const requestRestart = vi.fn();
    const beginRestartCancellation = vi.fn();
    const gateway = service({ requestRestart, beginRestartCancellation, armRestartWatchdog: async () => { throw new Error("Native restart authority is unavailable"); } });
    await expect(gateway.invoke(client, "gateway.restart", { commandId: "watchdog-failure" })).rejects.toThrow("authority is unavailable");
    await vi.advanceTimersByTimeAsync(100);
    expect(requestRestart).not.toHaveBeenCalled();
    expect(beginRestartCancellation).not.toHaveBeenCalled();
  });

  it("keeps lost native acknowledgement uncertain and cannot arm or schedule twice", async () => {
    vi.stubEnv("TRON_GATEWAY_SUPERVISED", "1");
    const arm = vi.fn(async () => { throw new RestartArmUncertainError("acknowledgement lost after submission"); });
    const requestRestart = vi.fn();
    const cancel = vi.fn();
    const gateway = service({ armRestartWatchdog: arm, requestRestart, beginRestartCancellation: cancel });
    await expect(gateway.invoke(client, "gateway.restart", { commandId: "lost-ack" })).rejects.toMatchObject({ details: { outcomeUnknown: true } });
    await expect(gateway.invoke(client, "gateway.restart", { commandId: "different-id" })).rejects.toMatchObject({ code: "busy" });
    expect(arm).toHaveBeenCalledTimes(1);
    expect(requestRestart).not.toHaveBeenCalled();
    expect(cancel).not.toHaveBeenCalled();
  });

  it("does not schedule replacement before the completed receipt write attempt settles", async () => {
    vi.stubEnv("TRON_GATEWAY_SUPERVISED", "1");
    vi.useFakeTimers();
    const requestRestart = vi.fn();
    const armRestartWatchdog = vi.fn(async () => Date.now() + 15_000);
    let releaseReceipt!: () => void;
    const receiptBarrier = new Promise<void>((resolve) => { releaseReceipt = resolve; });
    const gateway = service({
      requestRestart,
      armRestartWatchdog,
      executeReceipt: async (_identity, _method, _commandId, operation) => {
        const result = await operation();
        await receiptBarrier;
        return result;
      },
    });

    const restarting = gateway.invoke(client, "gateway.restart", { commandId: "restart-command" });
    // Admission includes an actual device-lease filesystem read. Observe the
    // arm event instead of assuming one fake-timer turn completes that I/O.
    await vi.waitFor(() => expect(armRestartWatchdog).toHaveBeenCalledTimes(1));
    await vi.advanceTimersByTimeAsync(250);
    expect(requestRestart).not.toHaveBeenCalled();
    releaseReceipt();
    await restarting;
    await vi.advanceTimersByTimeAsync(100);
    expect(requestRestart).toHaveBeenCalledTimes(1);
  });
});
