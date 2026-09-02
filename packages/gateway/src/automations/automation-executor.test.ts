import { describe, expect, it, vi } from "vitest";
import { GatewayAutomationExecutor } from "./automation-executor.js";
import { GatewayWorkRegistry } from "../sessions/gateway-work-registry.js";
import type { AutomationRecord, AutomationRun } from "./types.js";

function fixture() {
  const record: AutomationRecord = {
    schemaVersion: 1, id: "10000000-0000-4000-8000-000000000001", revision: 1, stateRevision: 1,
    name: "Review", activation: "enabled", createdAt: "2026-01-01T00:00:00.000Z", updatedAt: "2026-01-01T00:00:00.000Z",
    provenance: { kind: "local" }, targetSessionId: "session-one",
    trigger: { kind: "once", at: "2026-01-01T01:00:00.000Z" }, misfirePolicy: "latest", overlapPolicy: "skip",
    executionDeadlineSeconds: 3_600, action: { kind: "sessionPrompt", text: "Review" }, nextOccurrenceAt: "2026-01-01T01:00:00.000Z",
    consecutiveFailureCount: 0, history: [],
  };
  const run: AutomationRun = {
    runId: "10000000-0000-4000-8000-000000000002", occurrenceId: "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA",
    automationRevision: 1, scheduledFor: "2026-01-01T01:00:00.000Z", triggerSnapshot: record.trigger,
    actionSnapshot: record.action, state: "admitting", createdAt: "2026-01-01T01:00:00.000Z", preAdmissionAttemptCount: 0,
    operationId: "automation:10000000-0000-4000-8000-000000000002",
  };
  return { record, run };
}

describe("GatewayAutomationExecutor", () => {
  it("routes a scheduled prompt through one leased RuntimeSlot and retains its marker until acknowledgement", async () => {
    const { record, run } = fixture();
    const release = vi.fn();
    let ownership: any;
    const slot = {
      commands: () => [],
      prompt: vi.fn(async (...args: any[]) => {
        ownership = args[5];
        ownership.onAdmitted("invocation-one");
        return { operationId: ownership.operationId };
      }),
      abort: vi.fn(async () => {}),
    };
    const sessions = {
      acquireAutomationLease: vi.fn(async () => ({ slot, release })),
      clearAutomationMarker: vi.fn(async () => {}),
    };
    const work = new GatewayWorkRegistry("epoch-one", 16);
    const executor = new GatewayAutomationExecutor(sessions as any, work, undefined, "machine-one");

    const handle = await executor.start(record, run);
    expect(slot.prompt).toHaveBeenCalled();
    expect(ownership).toMatchObject({ operationId: run.operationId, origin: { kind: "gateway", ownerId: record.id } });
    expect(handle.invocationId).toBe("invocation-one");
    expect(release).not.toHaveBeenCalled();

    await ownership.onTerminal({ lifecycle: "completed", operationId: run.operationId, invocationId: "invocation-one", assistantCompletionId: "completion-one" });
    await expect(handle.completion).resolves.toMatchObject({ state: "succeeded", assistantCompletionId: "completion-one" });
    expect(work.size).toBe(1);
    await handle.acknowledgeTerminal?.();
    expect(sessions.clearAutomationMarker).toHaveBeenCalledWith(record.targetSessionId, run.operationId);
    expect(release).toHaveBeenCalledOnce();
    expect(work.size).toBe(0);
  });

  it("classifies accepted recovery without terminal evidence as unknown", async () => {
    const { record, run } = fixture();
    const sessions = {
      automationRecoveryEvidence: vi.fn(async () => ({
        marker: { operationId: run.operationId, acceptedAt: "2026-01-01T01:00:00.000Z" },
        invocation: { invocationId: "invocation-one", lifecycle: "accepted" },
      })),
    };
    const executor = new GatewayAutomationExecutor(sessions as any, new GatewayWorkRegistry(), undefined, undefined);
    await expect(executor.recover(record, run)).resolves.toEqual({
      state: "outcomeUnknown", reason: "accepted-without-terminal-evidence", invocationId: "invocation-one",
    });
  });
});
