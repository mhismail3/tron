/**
 * G-13's startup budget: process start to the record that says the Gateway is
 * serving (`gateway.listening`, the end of `startupCheckpoint`'s steps).
 *
 * Set from the measured `gateway.startup-step` records: about 1 s on a quiet
 * host and 4.0–4.6 s on the qualification catalog under load. A restart's
 * clients retry about 2 s and again about 5.4 s after their own socket closes
 * (the phone's `ReconnectDelayPolicy`), so a start slower than this budget
 * costs a whole backoff step and misses the restart criterion of every client
 * reconnecting within 10 s.
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
