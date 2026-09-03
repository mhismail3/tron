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
