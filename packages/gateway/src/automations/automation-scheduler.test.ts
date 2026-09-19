import { mkdtemp } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { describe, expect, it, vi } from "vitest";
import { AutomationScheduler, type AutomationExecutor } from "./automation-scheduler.js";
import { AutomationStore } from "./automation-store.js";

async function eventually(assertion: () => void): Promise<void> {
  for (let attempt = 0; attempt < 200; attempt += 1) {
    try { assertion(); return; } catch { await new Promise((resolve) => setTimeout(resolve, 2)); }
  }
  assertion();
}

describe("AutomationScheduler", () => {
  it("materializes one latest occurrence and commits its terminal result", async () => {
    let now = Date.parse("2026-01-01T00:00:01Z");
    const root = await mkdtemp(join(tmpdir(), "tron-automation-scheduler-"));
    const store = new AutomationStore(root, { now: () => now });
    await store.initialize();
    const record = await store.create({
      name: "Review", activation: "enabled", target: { kind: "existingSession", sessionId: "session-one" },
      trigger: { kind: "interval", everySeconds: 300, anchorAt: "2026-01-01T00:00:00.000Z" },
      misfirePolicy: "latest", overlapPolicy: "skip", executionDeadlineSeconds: 3_600,
      action: { kind: "sessionPrompt", text: "Review" }, provenance: { kind: "local" },
    });
    now = Date.parse("2026-01-01T00:10:30Z");
    const executor: AutomationExecutor = {
      start: vi.fn(async (_definition, run) => ({
        operationId: run.operationId,
        completion: Promise.resolve({ state: "succeeded" as const, assistantCompletionId: "completion-one" }),
        cancel: vi.fn(async () => {}),
      })),
    };
    const scheduler = new AutomationScheduler(store, executor, {
      now: () => now,
      hostEpoch: "epoch-one",
      setTimer: (() => ({ unref() {} }) as unknown as NodeJS.Timeout),
      clearTimer: () => {},
    });

    scheduler.start();
    await scheduler.scan();
    await eventually(() => expect(store.get(record.id).lastRun?.state).toBe("succeeded"));

    const updated = store.get(record.id);
    expect(updated.lastRun?.scheduledFor).toBe("2026-01-01T00:10:00.000Z");
    expect(updated.nextOccurrenceAt).toBe("2026-01-01T00:15:00.000Z");
    expect(updated.currentRun).toBeUndefined();
    expect(executor.start).toHaveBeenCalledTimes(1);
  });

  it("bounds gateway-shutdown cancellation and records an unknown outcome when completion never settles", async () => {
    let now = Date.parse("2026-01-01T00:00:01Z");
    const root = await mkdtemp(join(tmpdir(), "tron-automation-shutdown-grace-"));
    const store = new AutomationStore(root, { now: () => now });
    await store.initialize();
    const record = await store.create({
      name: "Shutdown", activation: "enabled", target: { kind: "existingSession", sessionId: "session-one" },
      trigger: { kind: "interval", everySeconds: 300, anchorAt: "2026-01-01T00:00:00.000Z" },
      misfirePolicy: "latest", overlapPolicy: "skip", executionDeadlineSeconds: 3_600,
      action: { kind: "sessionPrompt", text: "Review" }, provenance: { kind: "local" },
    });
    // Only the bounded grace timers may release shutdown: the executor's cancel
    // resolves, but its completion promise never does.
    // Every bounded settle step arms its own grace; keep them all so the test can
    // release the exact windows the scheduler is waiting on.
    const timers = new Map<number, Array<() => void>>();
    const fireGrace = (): void => {
      const pending = timers.get(5_000) ?? [];
      timers.delete(5_000);
      for (const callback of pending) callback();
    };
    let cancelCalls = 0;
    const executor: AutomationExecutor = {
      start: vi.fn(async (_definition, run) => ({
        operationId: run.operationId,
        completion: new Promise<never>(() => {}),
        cancel: vi.fn(async () => { cancelCalls += 1; }),
      })),
    };
    const scheduler = new AutomationScheduler(store, executor, {
      now: () => now,
      hostEpoch: "epoch-one",
      setTimer: ((callback: () => void, delay: number) => {
        const pending = timers.get(delay) ?? [];
        pending.push(callback);
        timers.set(delay, pending);
        return { unref() {} } as unknown as NodeJS.Timeout;
      }) as never,
      clearTimer: ((timer: NodeJS.Timeout) => { void timer; }) as never,
    });

    scheduler.start();
    now = Date.parse("2026-01-01T00:10:30Z");
    await scheduler.scan();
    await eventually(() => expect(store.get(record.id).currentRun?.state).toBe("running"));

    const cancellation = scheduler.cancelActiveForShutdown();
    // Let the cooperative cancel settle first so the only remaining bound is the
    // completion grace for a completion that never arrives.
    await eventually(() => expect(cancelCalls).toBe(1));
    await new Promise((resolve) => setTimeout(resolve, 0));
    await eventually(() => expect(timers.has(5_000)).toBe(true));
    fireGrace();
    await cancellation;
    await eventually(() => expect(store.get(record.id).lastRun?.state).toBe("outcomeUnknown"));
    expect(store.get(record.id).lastRun?.reason).toBe("gateway-shutdown-settlement-timeout");

    // Disposal is bounded by the same grace rather than awaiting the completion forever.
    timers.delete(5_000);
    const disposal = scheduler.dispose();
    await eventually(() => expect(timers.has(5_000)).toBe(true));
    fireGrace();
    await expect(disposal).resolves.toBeUndefined();
  });

  it("records an unknown outcome when a cooperative cancel itself never settles during shutdown", async () => {
    let now = Date.parse("2026-01-01T00:00:01Z");
    const root = await mkdtemp(join(tmpdir(), "tron-automation-shutdown-cancel-grace-"));
    const store = new AutomationStore(root, { now: () => now });
    await store.initialize();
    const record = await store.create({
      name: "ShutdownCancel", activation: "enabled", target: { kind: "existingSession", sessionId: "session-one" },
      trigger: { kind: "interval", everySeconds: 300, anchorAt: "2026-01-01T00:00:00.000Z" },
      misfirePolicy: "latest", overlapPolicy: "skip", executionDeadlineSeconds: 3_600,
      action: { kind: "sessionPrompt", text: "Review" }, provenance: { kind: "local" },
    });
    const timers = new Map<number, Array<() => void>>();
    const fireGrace = (): void => {
      const pending = timers.get(5_000) ?? [];
      timers.delete(5_000);
      for (const callback of pending) callback();
    };
    const executor: AutomationExecutor = {
      start: vi.fn(async (_definition, run) => ({
        operationId: run.operationId,
        completion: new Promise<never>(() => {}),
        // A cancel that never resolves must not hold shutdown open.
        cancel: vi.fn(() => new Promise<void>(() => {})),
      })),
    };
    const scheduler = new AutomationScheduler(store, executor, {
      now: () => now,
      hostEpoch: "epoch-one",
      setTimer: ((callback: () => void, delay: number) => {
        const pending = timers.get(delay) ?? [];
        pending.push(callback);
        timers.set(delay, pending);
        return { unref() {} } as unknown as NodeJS.Timeout;
      }) as never,
      clearTimer: ((timer: NodeJS.Timeout) => { void timer; }) as never,
    });

    scheduler.start();
    now = Date.parse("2026-01-01T00:10:30Z");
    await scheduler.scan();
    await eventually(() => expect(store.get(record.id).currentRun?.state).toBe("running"));

    const cancellation = scheduler.cancelActiveForShutdown();
    await eventually(() => expect(timers.has(5_000)).toBe(true));
    fireGrace();
    await cancellation;
    await eventually(() => expect(store.get(record.id).lastRun?.state).toBe("outcomeUnknown"));
    expect(store.get(record.id).lastRun?.reason).toBe("gateway-shutdown-cancellation-timeout");
    expect(store.get(record.id).activation).toBe("blocked");
  });

  it("keeps a draft one-time definition draft after a successful manual run", async () => {
    const now = Date.parse("2026-01-01T00:00:00Z");
    const root = await mkdtemp(join(tmpdir(), "tron-automation-manual-draft-"));
    const store = new AutomationStore(root, { now: () => now });
    await store.initialize();
    const record = await store.create({
      name: "Draft", activation: "draft", target: { kind: "existingSession", sessionId: "session-one" },
      trigger: { kind: "once", at: "2026-01-02T00:00:00.000Z" },
      action: { kind: "sessionPrompt", text: "Review" }, provenance: { kind: "local" },
    });
    const scheduler = new AutomationScheduler(store, {
      start: async (_definition, run) => ({ operationId: run.operationId, completion: Promise.resolve({ state: "succeeded" }), cancel: async () => {} }),
    }, { now: () => now, hostEpoch: "epoch-one", setTimer: (() => ({ unref() {} }) as unknown as NodeJS.Timeout), clearTimer: () => {} });
    scheduler.start();
    await scheduler.runNow(record.id, record.revision);
    await scheduler.scan();
    await eventually(() => expect(store.get(record.id).lastRun?.state).toBe("succeeded"));
    expect(store.get(record.id).activation).toBe("draft");
  });

  it("completes a skipped one-time automation without dispatch", async () => {
    const now = Date.parse("2026-01-02T00:00:00Z");
    const root = await mkdtemp(join(tmpdir(), "tron-automation-once-skip-"));
    const store = new AutomationStore(root, { now: () => now });
    await store.initialize();
    const record = await store.create({
      name: "Expired", activation: "enabled", target: { kind: "existingSession", sessionId: "session-one" },
      trigger: { kind: "once", at: "2026-01-01T00:00:00.000Z" }, misfirePolicy: "skip",
      action: { kind: "sessionPrompt", text: "Review" }, provenance: { kind: "local" },
    });
    const start = vi.fn();
    const scheduler = new AutomationScheduler(store, { start } as unknown as AutomationExecutor, {
      now: () => now, hostEpoch: "epoch-one",
      setTimer: (() => ({ unref() {} }) as unknown as NodeJS.Timeout), clearTimer: () => {},
    });
    scheduler.start();
    await scheduler.scan();
    expect(store.get(record.id)).toMatchObject({ activation: "completed", lastRun: { state: "skipped", reason: "misfire" } });
    expect(start).not.toHaveBeenCalled();
  });

  it("reserves global and per-session capacity before asynchronous admission settles", async () => {
    let now = Date.parse("2026-01-01T00:00:01Z");
    const root = await mkdtemp(join(tmpdir(), "tron-automation-capacity-"));
    const store = new AutomationStore(root, { now: () => now });
    await store.initialize();
    for (let index = 0; index < 6; index += 1) {
      await store.create({
        name: `Review ${index}`, activation: "enabled", target: { kind: "existingSession", sessionId: `session-${index}` },
        trigger: { kind: "once", at: "2026-01-01T00:01:00.000Z" },
        action: { kind: "sessionPrompt", text: "Review" }, provenance: { kind: "local" },
      });
    }
    now = Date.parse("2026-01-01T00:01:01Z");
    let release!: () => void;
    const gate = new Promise<void>((resolve) => { release = resolve; });
    const start = vi.fn(async (_definition, run) => {
      await gate;
      return { operationId: run.operationId, completion: Promise.resolve({ state: "succeeded" as const }), cancel: async () => {} };
    });
    const scheduler = new AutomationScheduler(store, { start }, {
      now: () => now, hostEpoch: "epoch-one", maximumConcurrent: 2,
      setTimer: (() => ({ unref() {} }) as unknown as NodeJS.Timeout), clearTimer: () => {},
    });
    scheduler.start();
    await scheduler.scan();
    await eventually(() => expect(start).toHaveBeenCalledTimes(2));
    await scheduler.scan();
    expect(start).toHaveBeenCalledTimes(2);
    scheduler.beginDrain();
    release();
  });

  it("carries cancellation across the admitting-to-running handoff", async () => {
    let now = Date.parse("2026-01-01T00:00:01Z");
    const root = await mkdtemp(join(tmpdir(), "tron-automation-cancel-"));
    const store = new AutomationStore(root, { now: () => now });
    await store.initialize();
    const record = await store.create({
      name: "Review", activation: "enabled", target: { kind: "existingSession", sessionId: "session-one" },
      trigger: { kind: "once", at: "2026-01-01T00:01:00.000Z" },
      action: { kind: "sessionPrompt", text: "Review" }, provenance: { kind: "local" },
    });
    now = Date.parse("2026-01-01T00:01:01Z");
    let releaseStart!: () => void;
    const startGate = new Promise<void>((resolve) => { releaseStart = resolve; });
    let resolveCompletion!: (value: { state: "cancelled"; reason: string }) => void;
    const completion = new Promise<{ state: "cancelled"; reason: string }>((resolve) => { resolveCompletion = resolve; });
    const cancel = vi.fn(async () => { resolveCompletion({ state: "cancelled", reason: "user-cancelled" }); });
    const executor: AutomationExecutor = {
      start: vi.fn(async (_definition, run) => {
        await startGate;
        return { operationId: run.operationId, completion, cancel };
      }),
    };
    const scheduler = new AutomationScheduler(store, executor, {
      now: () => now, hostEpoch: "epoch-one",
      setTimer: (() => ({ unref() {} }) as unknown as NodeJS.Timeout), clearTimer: () => {},
    });
    scheduler.start();
    await scheduler.scan();
    await eventually(() => expect(store.get(record.id).currentRun?.state).toBe("admitting"));
    const runId = store.get(record.id).currentRun!.runId;
    const cancellation = scheduler.cancel(record.id, runId);
    await eventually(() => expect(store.get(record.id).currentRun?.state).toBe("cancelling"));
    releaseStart();

    await expect(cancellation).resolves.toMatchObject({ runId, state: "cancelled" });
    expect(cancel).toHaveBeenCalledWith("user-cancelled");
  });

  it("arms from one catalog snapshot while preserving the bounded deadline", async () => {
    const now = Date.parse("2026-01-01T00:00:00Z");
    const root = await mkdtemp(join(tmpdir(), "tron-automation-arm-"));
    const store = new AutomationStore(root, { now: () => now });
    await store.initialize();
    await store.create({
      name: "Future", activation: "enabled", target: { kind: "existingSession", sessionId: "session-one" },
      trigger: { kind: "once", at: "2026-01-01T00:10:00.000Z" },
      action: { kind: "sessionPrompt", text: "Review" }, provenance: { kind: "local" },
    });
    const snapshot = vi.spyOn(store, "snapshot");
    const setTimer = vi.fn(() => ({ unref() {} }) as unknown as NodeJS.Timeout);
    const scheduler = new AutomationScheduler(store, { start: vi.fn() } as unknown as AutomationExecutor, {
      now: () => now, hostEpoch: "epoch-one", setTimer, clearTimer: () => {},
    });

    scheduler.start();
    await scheduler.scan();

    expect(snapshot).toHaveBeenCalledTimes(3);
    expect(setTimer).toHaveBeenCalledWith(expect.any(Function), 60_000);
  });

  it("arms for the earliest retry or occurrence deadline", async () => {
    const now = Date.parse("2026-01-01T00:00:00Z");
    const root = await mkdtemp(join(tmpdir(), "tron-automation-arm-deadlines-"));
    const store = new AutomationStore(root, { now: () => now });
    await store.initialize();
    const record = await store.create({
      name: "Retry", activation: "enabled", target: { kind: "existingSession", sessionId: "session-one" },
      trigger: { kind: "once", at: "2026-01-01T00:00:50.000Z" },
      action: { kind: "sessionPrompt", text: "Review" }, provenance: { kind: "local" },
    });
    await store.mutateState(record.id, (current) => ({
      ...current,
      currentRun: {
        runId: "10000000-0000-4000-8000-000000000011",
        occurrenceId: "BBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBB",
        automationRevision: current.revision,
        scheduledFor: "2026-01-01T00:00:30.000Z",
        triggerSnapshot: current.trigger,
        actionSnapshot: current.action,
        targetSnapshot: current.target,
        executionSessionId: "session-one",
        state: "waiting",
        createdAt: "2026-01-01T00:00:00.000Z",
        retryAt: "2026-01-01T00:00:30.000Z",
        preAdmissionAttemptCount: 0,
        operationId: "automation:10000000-0000-4000-8000-000000000011",
      },
    }));
    const setTimer = vi.fn(() => ({ unref() {} }) as unknown as NodeJS.Timeout);
    const scheduler = new AutomationScheduler(store, { start: vi.fn() } as unknown as AutomationExecutor, {
      now: () => now, hostEpoch: "epoch-one", setTimer, clearTimer: () => {},
    });

    scheduler.start();
    await eventually(() => expect(setTimer).toHaveBeenCalledWith(expect.any(Function), 30_000));
  });

  it("does not replay an admitted run when recovery has no terminal proof", async () => {
    const now = Date.parse("2026-01-01T00:10:30Z");
    const root = await mkdtemp(join(tmpdir(), "tron-automation-recovery-"));
    const store = new AutomationStore(root, { now: () => now });
    await store.initialize();
    const record = await store.create({
      name: "Review", activation: "enabled", target: { kind: "existingSession", sessionId: "session-one" },
      trigger: { kind: "once", at: "2026-01-01T00:10:00.000Z" },
      action: { kind: "sessionPrompt", text: "Review" }, provenance: { kind: "local" },
    });
    const runId = "10000000-0000-4000-8000-000000000010";
    await store.mutateState(record.id, (current) => ({
      ...current,
      currentRun: {
        runId, occurrenceId: "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA", automationRevision: current.revision,
        scheduledFor: "2026-01-01T00:10:00.000Z", triggerSnapshot: current.trigger, actionSnapshot: current.action, targetSnapshot: current.target, executionSessionId: "session-one",
        state: "running", createdAt: "2026-01-01T00:10:00.000Z", startedAt: "2026-01-01T00:10:01.000Z",
        preAdmissionAttemptCount: 0, operationId: `automation:${runId}`,
      },
    }));
    const executor: AutomationExecutor = {
      start: vi.fn(async () => { throw new Error("must not start"); }),
      recover: vi.fn(async () => ({ state: "outcomeUnknown" as const, reason: "accepted-without-terminal-proof" })),
    };
    const scheduler = new AutomationScheduler(store, executor, { now: () => now, hostEpoch: "epoch-two" });

    await scheduler.recover();

    expect(store.get(record.id)).toMatchObject({ activation: "blocked", blockedReason: "outcome-unknown" });
    expect(store.get(record.id).lastRun).toMatchObject({ runId, state: "outcomeUnknown" });
    expect(executor.start).not.toHaveBeenCalled();
  });
});
