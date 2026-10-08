import { afterEach, describe, expect, it, vi } from "vitest";
import { OwnedSessionDispatch, OWNED_OPERATION_DEADLINE_MS } from "./owned-session-dispatch.js";

afterEach(() => vi.useRealTimers());

describe("OwnedSessionDispatch", () => {
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
