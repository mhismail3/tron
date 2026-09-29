/**
 * G-13's startup budget: this process's own start, process start to the record
 * that says it is serving (`gateway.listening`, the end of `startupCheckpoint`'s
 * steps).
 *
 * It is deliberately not the whole wait a restarting client sees: a client
 * counts from its own socket's close, which comes before this process's
 * predecessor has finished shutting down. `scripts/tron-profile-gateway` reads
 * this record (its `durationMs` and `counts.budgetMs`, so the constant lives
 * here only) and judges the restart case's criterion on its own close →
 * listening span. Set from the measured `gateway.startup-step` records: about 1 s
 * on a quiet host and 4.0–4.6 s on the qualification catalog under load.
 */
export const STARTUP_LISTEN_BUDGET_MS = 5_000;

export interface StartupStepTiming {
  readonly step: string;
  readonly durationMs: number;
}

export interface StartupBudget {
  readonly listeningMs: number;
  readonly withinBudget: boolean;
  readonly overBudgetMs: number;
  /** The step that owns most of the start time: what a missed budget was caused by. */
  readonly slowestStep: string;
  readonly slowestStepMs: number;
}

/** The budget verdict for one start. `listeningAtMs` is measured from the
 * process time origin, which is where the startup steps are measured from too:
 * the steps are gapless, so their sum is this same span. */
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
