import { mkdtemp } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { describe, expect, it, vi } from "vitest";
import { AutomationScheduler, type AutomationExecutor } from "./automation-scheduler.js";
import { AutomationStore } from "./automation-store.js";

async function eventually(assertion: () => void): Promise<void> {
  for (let attempt = 0; attempt < 50; attempt += 1) {
    try { assertion(); return; } catch { await new Promise((resolve) => setTimeout(resolve, 0)); }
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
      name: "Review", activation: "enabled", targetSessionId: "session-one",
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

  it("does not replay an admitted run when recovery has no terminal proof", async () => {
    const now = Date.parse("2026-01-01T00:10:30Z");
    const root = await mkdtemp(join(tmpdir(), "tron-automation-recovery-"));
    const store = new AutomationStore(root, { now: () => now });
    await store.initialize();
    const record = await store.create({
      name: "Review", activation: "enabled", targetSessionId: "session-one",
      trigger: { kind: "once", at: "2026-01-01T00:10:00.000Z" },
      action: { kind: "sessionPrompt", text: "Review" }, provenance: { kind: "local" },
    });
    const runId = "10000000-0000-4000-8000-000000000010";
    await store.mutateState(record.id, (current) => ({
      ...current,
      currentRun: {
        runId, occurrenceId: "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA", automationRevision: current.revision,
        scheduledFor: "2026-01-01T00:10:00.000Z", triggerSnapshot: current.trigger, actionSnapshot: current.action,
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
