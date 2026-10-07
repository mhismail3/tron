import { afterEach, describe, expect, it, vi } from "vitest";
import { OwnedSessionDispatch, OWNED_OPERATION_DEADLINE_MS } from "./owned-session-dispatch.js";

afterEach(() => vi.useRealTimers());

describe("OwnedSessionDispatch", () => {
  it("keeps lease, recovery evidence and acknowledgement at the shared runtime owner", async () => {
    const lease = { slot: {}, release: vi.fn() };
    const runtime = {
      acquireAutomationLease: vi.fn(async () => lease),
      automationRecoveryEvidence: vi.fn(async () => ({ marker: { operationId: "op-1" } })),
      clearAutomationMarker: vi.fn(async () => {}),
    };
    const dispatch = new OwnedSessionDispatch(runtime as any);
    await expect(dispatch.lease("session-1")).resolves.toBe(lease);
    await expect(dispatch.recoveryEvidence("session-1", "op-1")).resolves.toEqual({ marker: { operationId: "op-1" } });
    await dispatch.acknowledge("session-1", "op-1", lease);
    expect(runtime.clearAutomationMarker).toHaveBeenCalledWith("session-1", "op-1");
    expect(lease.release).toHaveBeenCalledOnce();
  });

  it("has no automation prefix or completed-to-success mapping in its neutral completion view", async () => {
    const dispatch = new OwnedSessionDispatch({} as any);
    const handle = {
      operationId: "task:op-1",
      completion: Promise.resolve({ state: "completed" }),
      cancel: vi.fn(async () => {}),
      acknowledgeTerminal: vi.fn(async () => {}),
    };
    await expect(dispatch.observe(handle as any)).resolves.toEqual({ state: "completed" });
    expect(handle.cancel).not.toHaveBeenCalled();
    expect(handle.acknowledgeTerminal).not.toHaveBeenCalled();
  });

  it("stops a deadline-bound operation, joins terminal completion, acknowledges, and emits bounded evidence once", async () => {
    vi.useFakeTimers();
    const signals: unknown[] = [];
    let finish!: (result: unknown) => void;
    const completion = new Promise((resolve) => { finish = resolve; });
    const handle = {
      operationId: "task:blocked",
      completion,
      cancel: vi.fn(async () => { finish({ state: "interrupted" }); }),
      acknowledgeTerminal: vi.fn(async () => {}),
    };
    const dispatch = new OwnedSessionDispatch({} as any, { diagnostic: (record) => signals.push(record) });
    const observed = dispatch.enforceDeadline(handle as any);
    await vi.advanceTimersByTimeAsync(OWNED_OPERATION_DEADLINE_MS);
    await expect(observed).resolves.toMatchObject({ state: "deadline-stopped", terminal: { state: "interrupted" } });
    expect(handle.cancel).toHaveBeenCalledOnce();
    expect(handle.acknowledgeTerminal).toHaveBeenCalledOnce();
    expect(signals).toHaveLength(1);
    expect(signals[0]).toMatchObject({ event: "owned-operation.deadline-stop", cancelAndJoin: "joined" });
  });
});
