import { describe, expect, it } from "vitest";
import { STARTUP_LISTEN_BUDGET_MS, startupBudget } from "./startup-budget.js";

describe("startupBudget", () => {
  it("names the step that owns most of a start inside the budget", () => {
    const budget = startupBudget(1_200, [
      { step: "modules", durationMs: 400 },
      { step: "global-provider-resources", durationMs: 700 },
      { step: "automation-recovery", durationMs: 100 },
    ]);
    expect(budget.withinBudget).toBe(true);
    expect(budget.overBudgetMs).toBe(0);
    expect(budget.slowestStep).toBe("global-provider-resources");
    expect(budget.slowestStepMs).toBe(700);
  });

  it("reports the overrun and the slowest step when the budget is missed", () => {
    const budget = startupBudget(STARTUP_LISTEN_BUDGET_MS + 2_400, [
      { step: "modules", durationMs: 4_460 },
      { step: "automation-recovery", durationMs: 900 },
    ]);
    expect(budget.withinBudget).toBe(false);
    expect(budget.overBudgetMs).toBe(2_400);
    expect(budget.slowestStep).toBe("modules");
    expect(budget.slowestStepMs).toBe(4_460);
  });

  it("judges the whole start, not the last step", () => {
    // A start whose steps sum well over the budget still misses it when the
    // step that ends the sequence is short: the budget is this process's start
    // to listening, so the whole sequence is judged, not its last step. (A
    // restarting client waits longer still: the profiler adds the predecessor's
    // shutdown to this span before it judges G-13's criterion.)
    const budget = startupBudget(7_000, [
      { step: "modules", durationMs: 4_000 },
      { step: "session-registry", durationMs: 2_900 },
      { step: "listener-bind", durationMs: 100 },
    ]);
    expect(budget.withinBudget).toBe(false);
    expect(budget.overBudgetMs).toBe(2_000);
  });

  it("names no step for a start that reported none", () => {
    const budget = startupBudget(10, []);
    expect(budget.withinBudget).toBe(true);
    expect(budget.slowestStep).toBe("none");
    expect(budget.slowestStepMs).toBe(0);
  });
});
