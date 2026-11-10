export const STARTUP_LISTEN_BUDGET_MS = 5_000;

export interface StartupStepTiming {
  readonly step: string;
  readonly durationMs: number;
}

interface StartupBudget {
  readonly listeningMs: number;
  readonly withinBudget: boolean;
  readonly overBudgetMs: number;
  readonly slowestStep: string;
  readonly slowestStepMs: number;
}

export function startupBudget(listeningAtMs: number, steps: readonly StartupStepTiming[]): StartupBudget {
  let slowest: StartupStepTiming | undefined;
  for (const step of steps) {
    if (slowest === undefined || step.durationMs > slowest.durationMs) slowest = step;
  }
  return {
    listeningMs: listeningAtMs,
    withinBudget: listeningAtMs <= STARTUP_LISTEN_BUDGET_MS,
    overBudgetMs: Math.max(0, Math.round(listeningAtMs - STARTUP_LISTEN_BUDGET_MS)),
    slowestStep: slowest?.step ?? "none",
    slowestStepMs: Math.round(slowest?.durationMs ?? 0),
  };
}
