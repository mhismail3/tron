import { mkdtemp, rm } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { afterEach, describe, expect, it, vi } from "vitest";
import { CommandReceiptStore } from "./command-receipts.js";
import { GatewayService, type ClientContext, type GatewayServiceDependencies } from "./gateway-service.js";
import { GatewayWorkRegistry } from "../sessions/gateway-work-registry.js";
import { waitFor } from "../../test-support/wait-for.js";

const client: ClientContext = {
  id: "phone",
  identity: "device:test",
  isLocal: false,
  beginSynchronization: () => "sync",
  establishSynchronization: () => {},
  completeSynchronization: () => {},
  setPresentationVisibility: () => ({ visible: true, revision: 1 }),
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
  requestStop?: () => void;
  executeReceipt?: GatewayServiceDependencies["receipts"]["execute"];
  receipts?: GatewayServiceDependencies["receipts"];
  workRegistry?: GatewayWorkRegistry;
  rename?: (name: string) => Promise<void>;
  upsertGrant?: (input: unknown) => Promise<unknown>;
  cancelWaitingLogins?: () => void;
} = {}) {
  const snapshot = drain((options.activeSessions ?? []).length);
  let drainStarted = false;
  const dependencies = {
    sessions: {
      get isAdministrativeDrainStarted() { return drainStarted; },
      activeSessionIds: () => options.activeSessions ?? [],
      beginAdministrativeDrain: () => {
        drainStarted = true;
        options.workRegistry?.beginDrain();
        return snapshot;
      },
      administrativeDrainSnapshot: () => drainStarted ? snapshot : { ...snapshot, phase: "idle" },
      acquire: async () => ({ rename: options.rename ?? (async () => {}) }),
    },
    terminals: {
      activeTerminalIds: () => options.activeTerminals ?? [],
      beginRestartDrain: () => (options.activeTerminals ?? []).length === 0,
    },
    receipts: options.receipts ?? { execute: options.executeReceipt ?? (async (_identity: string, _method: string, _commandId: string, operation: () => Promise<unknown>) => operation()) },
    auth: { cancelWaitingForRestart: options.cancelWaitingLogins ?? (() => {}) },
    devices: { hasDevice: async () => true },
    notifications: {
      upsertGrant: options.upsertGrant ?? (async () => ({})),
      // Stub for the receipt-free identical-registration pre-check: this fake
      // stores nothing, so no registration is ever already current.
      registrationIsCurrent: async () => false,
      removeDevice: async () => true,
    },
    requestRestart: options.requestRestart ?? (() => {}),
    requestStop: options.requestStop ?? (() => {}),
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

  it("lets an idempotent restartNow command escalate an active drain immediately", async () => {
    vi.stubEnv("TRON_GATEWAY_SUPERVISED", "1");
    const requestRestart = vi.fn();
    const gateway = service({ activeSessions: ["session-1"], requestRestart });
    await gateway.invoke(client, "gateway.restart", { commandId: "restart-command" });

    await expect(gateway.invoke(client, "gateway.restart", { commandId: "restart-now-command", restartNow: true }))
      .resolves.toMatchObject({ scheduled: true, restartNow: true, drain: drain(1) });
    expect(requestRestart).toHaveBeenCalledWith(true);
  });

  it("admits Restart Now after the drain has closed ordinary work admission", async () => {
    vi.stubEnv("TRON_GATEWAY_SUPERVISED", "1");
    vi.useFakeTimers();
    const registry = new GatewayWorkRegistry("epoch", 8);
    const requestRestart = vi.fn();
    const gateway = service({ activeSessions: ["session-1"], workRegistry: registry, requestRestart });
    await gateway.invoke(client, "gateway.restart", { commandId: "restart-command" });
    expect(registry.isAdmissionOpen).toBe(false);

    await expect(gateway.invoke(client, "gateway.restart", { commandId: "restart-now-command", restartNow: true }))
      .resolves.toMatchObject({ scheduled: true, restartNow: true });
    expect(requestRestart).toHaveBeenCalledWith(true);
    expect(registry.size).toBe(0);
  });

  it("admits a receipt-backed request as an rpc-mutation naming its method and session", async () => {
    const registry = new GatewayWorkRegistry("epoch", 8);
    let finishRename!: () => void;
    const gateway = service({ workRegistry: registry, rename: () => new Promise<void>((resolve) => { finishRename = resolve; }) });
    const pending = gateway.invoke(client, "session.rename", { commandId: "rename-command", sessionId: "session-1", name: "Renamed" });
    await waitFor(() => typeof finishRename === "function", "the rename to be pending");
    expect(registry.facts()).toEqual([
      expect.objectContaining({ kind: "rpc-mutation", method: "session.rename", sessionId: "session-1" }),
    ]);
    finishRename();
    await pending;
    expect(registry.size).toBe(0);
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
    const cancelWaitingLogins = vi.fn();
    const gateway = service({ activeSessions: ["session-1"], requestRestart, cancelWaitingLogins });

    await expect(gateway.invoke(client, "gateway.restart", { commandId: "restart-command" })).resolves.toEqual({
      restarting: false,
      scheduled: true,
      activeSessionIds: ["session-1"],
      drainId: "drain-1",
      drainRevision: 1,
      drain: drain(1),
    });
    expect(cancelWaitingLogins).toHaveBeenCalledTimes(1);
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
      auth: { cancelWaitingForRestart: () => {} },
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
    await waitFor(() => calls === 1, "the first registration call");
    const second = gateway.invoke(client, "push.registration.upsert", params("command-two"));
    await waitFor(() => registry.size === 2, "both registered mutations");
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

describe("Gateway administrative stop", () => {
  it("fails closed when the Gateway is not externally supervised", async () => {
    vi.stubEnv("TRON_GATEWAY_SUPERVISED", "0");
    await expect(service().invoke(client, "gateway.stop", { commandId: "stop-command" }))
      .rejects.toMatchObject({ code: "unsupported" });
  });

  it("refuses a stop while a terminal PTY is alive", async () => {
    vi.stubEnv("TRON_GATEWAY_SUPERVISED", "1");
    await expect(service({ activeTerminals: ["terminal-1"] }).invoke(client, "gateway.stop", { commandId: "stop-command" }))
      .rejects.toMatchObject({ code: "busy" });
  });

  it("replays the completed stop receipt without repeating process retirement", async () => {
    vi.stubEnv("TRON_GATEWAY_SUPERVISED", "1");
    const root = await mkdtemp(join(tmpdir(), "gateway-stop-receipt-"));
    const receipts = new CommandReceiptStore(root);
    const registry = new GatewayWorkRegistry("epoch", 8);
    let retirementEpoch = 0;
    const gateway = service({
      receipts, workRegistry: registry,
      requestStop: () => { retirementEpoch += 1; },
    });
    try {
      const first = await gateway.invoke(client, "gateway.stop", { commandId: "stop-command" });
      const retry = await gateway.invoke(client, "gateway.stop", { commandId: "stop-command" });
      expect(retry).toEqual(first);
      await waitFor(() => retirementEpoch === 1, "the process owner to receive the accepted stop");
      expect(retirementEpoch).toBe(1);
      expect(registry.isAdmissionOpen).toBe(false);
      expect(registry.size).toBe(0);
    } finally {
      await receipts.dispose();
      await rm(root, { recursive: true, force: true });
    }
  });

  it("closes ordinary mutation admission while an accepted mutation and its receipt settle", async () => {
    vi.stubEnv("TRON_GATEWAY_SUPERVISED", "1");
    const registry = new GatewayWorkRegistry("epoch", 8);
    let releaseRename!: () => void;
    const renameBarrier = new Promise<void>((resolve) => { releaseRename = resolve; });
    let renameCount = 0;
    let stopReceiptSettled = false;
    let drainSettled = false;
    let stopObservedSettledReceipt = false;
    const gateway = service({
      activeSessions: ["session-1"], workRegistry: registry,
      rename: async () => { renameCount += 1; await renameBarrier; },
      requestStop: () => {
        void registry.waitUntilSettled().then(() => {
          drainSettled = true;
          stopObservedSettledReceipt = stopReceiptSettled;
        });
      },
      executeReceipt: async (_identity, method, _commandId, operation) => {
        const result = await operation();
        if (method === "gateway.stop") stopReceiptSettled = true;
        return result;
      },
    });

    const accepted = gateway.invoke(client, "session.rename", {
      commandId: "rename-command", sessionId: "session-1", name: "Renamed",
    });
    await waitFor(() => renameCount === 1, "accepted rename to enter its mutation owner");
    const stopping = gateway.invoke(client, "gateway.stop", { commandId: "stop-command" });
    await waitFor(() => !registry.isAdmissionOpen, "the administrative drain admission cutoff");
    await expect(gateway.invoke(client, "session.rename", {
      commandId: "late-rename-command", sessionId: "session-1", name: "Late",
    })).rejects.toMatchObject({ code: "busy" });

    releaseRename();
    await accepted;
    await expect(stopping).resolves.toMatchObject({
      stopping: false, scheduled: true, activeSessionIds: ["session-1"], drainId: "drain-1",
    });
    expect(renameCount).toBe(1);
    await waitFor(() => drainSettled, "the process owner to observe all owned work settle");
    expect(stopReceiptSettled).toBe(true);
    expect(stopObservedSettledReceipt).toBe(true);
    expect(registry.size).toBe(0);
  });
});
