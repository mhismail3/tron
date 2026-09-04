import { describe, expect, it, vi } from "vitest";
import { GatewayAutomationExecutor } from "./automation-executor.js";
import { GatewayWorkRegistry } from "../sessions/gateway-work-registry.js";
import type { AutomationRecord, AutomationRun } from "./types.js";

function fixture() {
  const record: AutomationRecord = {
    schemaVersion: 2, id: "10000000-0000-4000-8000-000000000001", revision: 1, stateRevision: 1,
    name: "Review", activation: "enabled", createdAt: "2026-01-01T00:00:00.000Z", updatedAt: "2026-01-01T00:00:00.000Z",
    provenance: { kind: "local" }, target: { kind: "existingSession", sessionId: "session-one" },
    trigger: { kind: "once", at: "2026-01-01T01:00:00.000Z" }, misfirePolicy: "latest", overlapPolicy: "skip",
    executionDeadlineSeconds: 3_600, action: { kind: "sessionPrompt", text: "Review" }, nextOccurrenceAt: "2026-01-01T01:00:00.000Z",
    consecutiveFailureCount: 0, history: [],
  };
  const run: AutomationRun = {
    runId: "10000000-0000-4000-8000-000000000002", occurrenceId: "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA",
    automationRevision: 1, scheduledFor: "2026-01-01T01:00:00.000Z", triggerSnapshot: record.trigger,
    actionSnapshot: record.action, targetSnapshot: record.target, executionSessionId: "session-one", state: "admitting", createdAt: "2026-01-01T01:00:00.000Z", preAdmissionAttemptCount: 0,
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
    expect(ownership).toMatchObject({
      operationId: run.operationId,
      origin: { kind: "gateway", ownerId: record.id, title: "Automation", confidence: "boundary" },
    });
    expect(handle.invocationId).toBe("invocation-one");
    expect(release).not.toHaveBeenCalled();

    await ownership.onTerminal({ lifecycle: "completed", operationId: run.operationId, invocationId: "invocation-one", assistantCompletionId: "completion-one" });
    await expect(handle.completion).resolves.toMatchObject({ state: "succeeded", assistantCompletionId: "completion-one" });
    expect(work.size).toBe(1);
    await handle.acknowledgeTerminal?.();
    expect(sessions.clearAutomationMarker).toHaveBeenCalledWith(run.executionSessionId, run.operationId);
    expect(release).toHaveBeenCalledOnce();
    expect(work.size).toBe(0);
  });

  it("creates and leases the predetermined workspace session exactly once", async () => {
    const { record, run } = fixture();
    record.target = { kind: "workspace", cwd: "/workspace", sessionPolicy: "newPerRun" };
    run.targetSnapshot = record.target;
    run.executionSessionId = "20000000-0000-4000-8000-000000000001";
    const release = vi.fn();
    let ownership: any;
    const slot = {
      commands: () => [],
      prompt: vi.fn(async (...args: any[]) => {
        ownership = args[5];
        ownership.onAdmitted("invocation-workspace");
        return { operationId: ownership.operationId };
      }),
      abort: vi.fn(async () => {}),
    };
    const sessions = {
      createAutomationSession: vi.fn(async () => ({ slot, release })),
      clearAutomationMarker: vi.fn(async () => {}),
    };
    const executor = new GatewayAutomationExecutor(
      sessions as any,
      new GatewayWorkRegistry("epoch-workspace", 16),
      undefined,
      undefined,
    );

    const handle = await executor.start(record, run);
    expect(sessions.createAutomationSession).toHaveBeenCalledWith(
      "/workspace",
      run.executionSessionId,
      run.operationId,
      record.id,
    );
    expect(slot.prompt).toHaveBeenCalledOnce();
    expect(ownership).toMatchObject({
      operationId: run.operationId,
      origin: { kind: "gateway", ownerId: record.id, title: "Automation", confidence: "boundary" },
    });
    expect(release).not.toHaveBeenCalled();
    await ownership.onTerminal({
      lifecycle: "completed",
      operationId: run.operationId,
      invocationId: "invocation-workspace",
      assistantCompletionId: "completion-workspace",
    });
    await expect(handle.completion).resolves.toMatchObject({ state: "succeeded" });
    await handle.acknowledgeTerminal?.();
    expect(release).toHaveBeenCalledOnce();
  });

  it("never replays an admitting workspace run without durable session evidence", async () => {
    const { record, run } = fixture();
    record.target = { kind: "workspace", cwd: "/workspace", sessionPolicy: "newPerRun" };
    run.targetSnapshot = record.target;
    run.executionSessionId = "20000000-0000-4000-8000-000000000002";
    const sessions = { automationRecoveryEvidence: vi.fn(async () => ({})) };
    const executor = new GatewayAutomationExecutor(
      sessions as any,
      new GatewayWorkRegistry(),
      undefined,
      undefined,
    );
    await expect(executor.recover(record, run)).resolves.toEqual({
      state: "outcomeUnknown",
      reason: "workspace-session-outcome-unknown",
    });
  });

  it("recovers a canonical completion marker even before its terminal receipt", async () => {
    const { record, run } = fixture();
    const sessions = {
      automationRecoveryEvidence: vi.fn(async () => ({
        marker: { operationId: run.operationId, acceptedAt: "2026-01-01T01:00:00.000Z", assistantCompletionId: "completion-one", assistantCompletedAt: "2026-01-01T01:01:00.000Z" },
        invocation: { invocationId: "invocation-one", lifecycle: "accepted" },
      })),
    };
    const executor = new GatewayAutomationExecutor(sessions as any, new GatewayWorkRegistry(), undefined, undefined);
    await expect(executor.recover(record, run)).resolves.toEqual({
      state: "succeeded", invocationId: "invocation-one", assistantCompletionId: "completion-one",
    });
  });

  it("preserves a durable cancellation intent when no admission evidence exists", async () => {
    const { record, run } = fixture();
    run.state = "cancelling";
    const sessions = { automationRecoveryEvidence: vi.fn(async () => ({})) };
    const executor = new GatewayAutomationExecutor(sessions as any, new GatewayWorkRegistry(), undefined, undefined);
    await expect(executor.recover(record, run)).resolves.toEqual({
      state: "cancelled", reason: "cancelled-before-admission",
    });
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
