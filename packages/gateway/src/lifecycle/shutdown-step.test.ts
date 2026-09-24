import { describe, expect, it } from "vitest";
import { shutdownStep } from "./shutdown-step.js";

describe("shutdownStep", () => {
  it("records the awaited operation duration with the controlled clock", async () => {
    let clock = 10;
    const records: Array<{ step: string; durationMs: number }> = [];
    const result = await shutdownStep("transport-close", async () => {
      clock = 26;
      return "closed";
    }, (step, durationMs) => records.push({ step, durationMs }), () => clock);
    expect(result).toBe("closed");
    expect(records).toEqual([{ step: "transport-close", durationMs: 16 }]);

    // Negative control: a synchronous operation has zero elapsed time, not the awaited duration.
    clock = 50;
    const control: number[] = [];
    await shutdownStep("dispose", async () => undefined, (_step, durationMs) => control.push(durationMs), () => clock);
    expect(control).toEqual([0]);
  });

  it("records elapsed time when a shutdown operation rejects", async () => {
    let clock = 4;
    const records: Array<{ step: string; durationMs: number }> = [];
    const operation = shutdownStep("search-close", async () => {
      clock = 9;
      throw new Error("close failed");
    }, (step, durationMs) => records.push({ step, durationMs }), () => clock);
    await expect(operation).rejects.toThrow("close failed");
    expect(records).toEqual([{ step: "search-close", durationMs: 5 }]);

    // Negative control: success emits the same step record rather than hiding healthy work.
    clock = 20;
    const control: string[] = [];
    await shutdownStep("sessions-dispose", async () => undefined, step => control.push(step), () => clock);
    expect(control).toEqual(["sessions-dispose"]);
  });
});
