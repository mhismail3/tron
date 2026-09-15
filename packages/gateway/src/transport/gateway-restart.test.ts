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

function service(options: {
  activeSessions?: string[];
  activeTerminals?: string[];
  requestRestart?: () => void;
  requestShutdown?: () => void;
  updateService?: GatewayServiceDependencies["updateService"];
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
      beginAdministrativeDrain: () => (options.activeTerminals ?? []).length === 0,
    },
    receipts: { execute: options.executeReceipt ?? (async (_identity: string, _method: string, _commandId: string, operation: () => Promise<unknown>) => operation()) },
    devices: { hasDevice: async () => true },
    notifications: {
      upsertGrant: options.upsertGrant ?? (async () => ({})),
      removeDevice: async () => true,
    },
    requestRestart: options.requestRestart ?? (() => {}),
    ...(options.requestShutdown ? { requestShutdown: options.requestShutdown } : {}),
    ...(options.updateService ? { updateService: options.updateService } : {}),
    ...(options.workRegistry ? { workRegistry: options.workRegistry } : {}),
  } as unknown as GatewayServiceDependencies;
  return new GatewayService(dependencies);
}

afterEach(() => {
  vi.useRealTimers();
  vi.unstubAllEnvs();
});

describe("Gateway administrative lifecycle", () => {
  it("shutdown is local-only and requires non-relaunching supervision", async () => {
    vi.stubEnv("TRON_GATEWAY_SUPERVISED", "1");
    const stop = vi.fn(), gateway = service({ requestShutdown: stop });
    await expect(gateway.invoke(client, "gateway.shutdown", { commandId: "shutdown-command" })).rejects.toMatchObject({ code: "auth_required" });
    await expect(gateway.invoke({ ...client, isLocal: true }, "gateway.shutdown", { commandId: "shutdown-command" })).rejects.toMatchObject({ code: "unsupported" });
    expect(stop).not.toHaveBeenCalled();
  });
  it("shutdown acknowledges its drain, seals new work, and never schedules a restart", async () => {
    vi.stubEnv("TRON_GATEWAY_SUPERVISED", "1"); vi.stubEnv("TRON_GATEWAY_EXIT_POLICY", "stop-on-success"); vi.useFakeTimers();
    const stop = vi.fn(), restart = vi.fn();
    const gateway = service({ activeSessions: ["session-1"], requestShutdown: stop, requestRestart: restart });
    const local = { ...client, isLocal: true };
    await expect(gateway.invoke(local, "gateway.shutdown", { commandId: "shutdown-command" })).resolves.toMatchObject({ stopping: true, scheduled: true, activeSessionIds: ["session-1"] });
    await expect(gateway.invoke(local, "gateway.restart", { commandId: "restart-command" })).rejects.toMatchObject({ code: "busy" });
    await expect(gateway.invoke(local, "settings.update", {})).rejects.toMatchObject({ code: "busy" });
    expect(stop).not.toHaveBeenCalled(); await vi.advanceTimersByTimeAsync(100);
    expect(stop).toHaveBeenCalledOnce(); expect(restart).not.toHaveBeenCalled();
  });
  it("receipt-write failure cannot undo an already accepted shutdown", async () => {
    vi.stubEnv("TRON_GATEWAY_SUPERVISED", "1"); vi.stubEnv("TRON_GATEWAY_EXIT_POLICY", "stop-on-success"); vi.useFakeTimers();
    const stop = vi.fn();
    const gateway = service({ requestShutdown: stop, executeReceipt: async (_owner, _method, _id, operation) => { await operation(); throw new Error("receipt write failed"); } });
    await expect(gateway.invoke({ ...client, isLocal: true }, "gateway.shutdown", { commandId: "shutdown-command" })).rejects.toThrow("receipt write failed");
    await vi.advanceTimersByTimeAsync(100); expect(stop).toHaveBeenCalledOnce();
  });
  it("accepted update startup cannot race a restart through stale progress", async () => {
    vi.stubEnv("TRON_GATEWAY_SUPERVISED", "1"); vi.stubEnv("TRON_GATEWAY_EXIT_POLICY", "stop-on-success"); vi.useFakeTimers();
    let release!: () => void;
    const gate = new Promise<void>(resolve => { release = resolve; });
    let status = { state: "ready", commandId: null as string | null };
    const update = vi.fn(async () => { await gate; return { accepted: true }; });
    const restart = vi.fn(), gateway = service({ requestRestart: restart, updateService: { isUsable: true, channel: "stable", status: async () => status, update } as never });
    const changing = gateway.invoke(client, "gateway.update", { commandId: "update-command", mode: "source" });
    await vi.waitFor(() => expect(update).toHaveBeenCalled());
    const restarting = gateway.invoke(client, "gateway.restart", { commandId: "restart-command" });
    release(); await changing;
    await expect(restarting).rejects.toMatchObject({ code: "busy" });
    expect(restart).not.toHaveBeenCalled();
  });

  it("admits only the authenticated updater's exact restart during a status projection gap", async () => {
    vi.stubEnv("TRON_GATEWAY_SUPERVISED", "1"); vi.stubEnv("TRON_GATEWAY_EXIT_POLICY", "stop-on-success"); vi.useFakeTimers();
    let release!: () => void;
    const gate = new Promise<void>(resolve => { release = resolve; });
    const update = vi.fn(async () => { await gate; return { accepted: true }; });
    const requestRestart = vi.fn();
    const requestShutdown = vi.fn();
    const gateway = service({
      requestRestart,
      requestShutdown,
      updateService: {
        isUsable: true,
        channel: "stable",
        // The detached helper has accepted the update, but its first progress
        // write has not reached the Gateway status projection yet.
        status: async () => ({ state: "unknown", commandId: null }),
        update,
      } as never,
    });
    const changing = gateway.invoke(client, "gateway.update", { commandId: "update-command", mode: "source" });
    await vi.waitFor(() => expect(update).toHaveBeenCalled());
    release(); await changing;

    await expect(gateway.invoke({ ...client, isLocal: true }, "gateway.restart", { commandId: "different-command" }))
      .rejects.toMatchObject({ code: "busy" });
    await expect(gateway.invoke(client, "gateway.restart", { commandId: "update-command" }))
      .rejects.toMatchObject({ code: "busy" });
    await expect(gateway.invoke({ ...client, isLocal: true }, "gateway.shutdown", { commandId: "update-command" }))
      .rejects.toMatchObject({ code: "busy" });
    await expect(gateway.invoke({ ...client, isLocal: true }, "gateway.restart", { commandId: "update-command" }))
      .resolves.toMatchObject({ scheduled: false });
    await vi.advanceTimersByTimeAsync(100);
    expect(requestRestart).toHaveBeenCalledOnce();
  });

  it("admits the exact authenticated restart handoff after rollback acceptance", async () => {
    vi.stubEnv("TRON_GATEWAY_SUPERVISED", "1"); vi.useFakeTimers();
    const rollback = vi.fn(async () => ({ accepted: true }));
    const requestRestart = vi.fn();
    const gateway = service({
      requestRestart,
      updateService: {
        isUsable: true,
        channel: "stable",
        status: async () => ({ state: "unknown", commandId: null }),
        rollback,
      } as never,
    });
    await gateway.invoke(client, "gateway.rollback", { commandId: "rollback-command" });
    await expect(gateway.invoke({ ...client, isLocal: true }, "gateway.restart", { commandId: "rollback-command" }))
      .resolves.toMatchObject({ scheduled: false });
    await vi.advanceTimersByTimeAsync(100);
    expect(rollback).toHaveBeenCalledOnce();
    expect(requestRestart).toHaveBeenCalledOnce();
  });

  it("accepted update startup cannot race a shutdown through stale progress", async () => {
    vi.stubEnv("TRON_GATEWAY_SUPERVISED", "1"); vi.stubEnv("TRON_GATEWAY_EXIT_POLICY", "stop-on-success"); vi.useFakeTimers();
    let release!: () => void;
    const gate = new Promise<void>(resolve => { release = resolve; });
    let status = { state: "ready", commandId: null as string | null };
    const update = vi.fn(async () => { await gate; return { accepted: true }; });
    const stop = vi.fn(), gateway = service({ requestShutdown: stop, updateService: { isUsable: true, channel: "stable", status: async () => status, update } as never });
    const local = { ...client, isLocal: true };
    const changing = gateway.invoke(local, "gateway.update", { commandId: "update-command", mode: "source" });
    await vi.waitFor(() => expect(update).toHaveBeenCalled());
    const quitting = gateway.invoke(local, "gateway.shutdown", { commandId: "shutdown-command" });
    const refused = expect(quitting).rejects.toMatchObject({ code: "busy" });
    release(); await changing; await refused; expect(stop).not.toHaveBeenCalled();
    status = { state: "failure", commandId: "update-command" };
    await gateway.invoke(local, "gateway.shutdown", { commandId: "shutdown-retry" });
    await vi.advanceTimersByTimeAsync(100); expect(stop).toHaveBeenCalledOnce();
  });
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
        beginAdministrativeDrain: () => { gateClosed = true; return true; },
        open: spawn,
        attach: () => ({ terminal: {}, chunks: [], reset: false }),
      },
      receipts: { execute: async (_identity: string, _method: string, _commandId: string, operation: () => Promise<unknown>) => operation() },
      requestRestart: () => {},
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

  it("does not schedule replacement before the completed receipt write attempt settles", async () => {
    vi.stubEnv("TRON_GATEWAY_SUPERVISED", "1");
    vi.useFakeTimers();
    const requestRestart = vi.fn();
    let releaseReceipt!: () => void;
    const receiptBarrier = new Promise<void>((resolve) => { releaseReceipt = resolve; });
    const gateway = service({
      requestRestart,
      executeReceipt: async (_identity, _method, _commandId, operation) => {
        const result = await operation();
        await receiptBarrier;
        return result;
      },
    });

    const restarting = gateway.invoke(client, "gateway.restart", { commandId: "restart-command" });
    await vi.advanceTimersByTimeAsync(250);
    expect(requestRestart).not.toHaveBeenCalled();
    releaseReceipt();
    await restarting;
    await vi.advanceTimersByTimeAsync(100);
    expect(requestRestart).toHaveBeenCalledTimes(1);
  });
});
