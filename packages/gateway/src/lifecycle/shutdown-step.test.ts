import { afterEach, describe, expect, it, vi } from "vitest";
import { shutdownStep } from "./shutdown-step.js";

describe("shutdownStep", () => {
  // The step duration is measured with `performance.now()`, so the test fakes
  // that clock instead of the production code taking an injected one.
  afterEach(() => { vi.useRealTimers(); });

  it("records the awaited operation duration", async () => {
    vi.useFakeTimers({ toFake: ["performance"] });
    const records: Array<{ step: string; durationMs: number }> = [];
    const result = await shutdownStep("transport-close", async () => {
      vi.advanceTimersByTime(16);
      return "closed";
    }, (step, durationMs) => records.push({ step, durationMs }));
    expect(result).toBe("closed");
    expect(records).toEqual([{ step: "transport-close", durationMs: 16 }]);

    // Negative control: a synchronous operation has zero elapsed time, not the awaited duration.
    const control: number[] = [];
    await shutdownStep("dispose", async () => undefined, (_step, durationMs) => control.push(durationMs));
    expect(control).toEqual([0]);
  });

  it("records elapsed time when a shutdown operation rejects", async () => {
    vi.useFakeTimers({ toFake: ["performance"] });
    const records: Array<{ step: string; durationMs: number }> = [];
    const operation = shutdownStep("search-close", async () => {
      vi.advanceTimersByTime(5);
      throw new Error("close failed");
    }, (step, durationMs) => records.push({ step, durationMs }));
    await expect(operation).rejects.toThrow("close failed");
    expect(records).toEqual([{ step: "search-close", durationMs: 5 }]);

    // Negative control: success emits the same step record rather than hiding healthy work.
    const control: string[] = [];
    await shutdownStep("sessions-dispose", async () => undefined, step => control.push(step));
    expect(control).toEqual(["sessions-dispose"]);
  });
});
