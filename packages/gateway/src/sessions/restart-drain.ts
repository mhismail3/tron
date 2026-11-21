import type { AdministrativeDrainBlockerSummary, AdministrativeDrainSnapshot } from "../protocol/types.js";
import { core as drain, type Blocker, type Time, type Tracked } from "../core/sessions/restart-drain/facade.js";

export const DRAIN_WAIT_LOG_INTERVAL_MS = 15_000;

type DrainMode = "restart" | "stop";
interface DrainLogger {
  log(level: "info", message: string, metadata: { event: string; source: string }): void;
}
interface DrainOwner {
  waitUntilIdle(continueDrain?: (snapshot: AdministrativeDrainSnapshot) => boolean): Promise<boolean>;
  administrativeDrainSnapshot(): AdministrativeDrainSnapshot;
}

export function logDrainBlockers(logger: DrainLogger, mode: DrainMode, snapshot: AdministrativeDrainSnapshot): void {
  const blockers = snapshot.blockers.map(({ sessionId, category, method, state, ageMs, progressAt }) => ({
    ...(sessionId ? { sessionId } : {}), category, ...(method ? { method } : {}), state, ageMs: ageMs ?? null,
    ...(progressAt ? { progressAt } : {}),
  }));
  logger.log("info", `Gateway ${mode} waiting on ${snapshot.blockerCount} operation(s): ${JSON.stringify(blockers)}`, {
    event: `gateway.${mode}-drain.waiting`, source: "lifecycle",
  });
}

export async function waitForStopDrain(
  sessions: DrainOwner,
  logger: DrainLogger,
  intervalMs = DRAIN_WAIT_LOG_INTERVAL_MS,
): Promise<AdministrativeDrainSnapshot> {
  let lastWaitLogAt = Number.NEGATIVE_INFINITY;
  await sessions.waitUntilIdle((snapshot) => {
    const now = Date.now();
    if (snapshot.blockerCount > 0 && now - lastWaitLogAt >= intervalMs) {
      lastWaitLogAt = now;
      logDrainBlockers(logger, "stop", snapshot);
    }
    return true;
  });
  return sessions.administrativeDrainSnapshot();
}

type RestartDrainDecision =
  | { outcome: "completed" }
  | { outcome: "waiting" }
  | { outcome: "unresolved-owners"; owners: AdministrativeDrainBlockerSummary[] }
  | { outcome: "stalled"; blocker: AdministrativeDrainBlockerSummary; ageMs: number };

export class RestartDrainProgress {
  private tracked: { name: string; at: Extract<Tracked, { $: "Tracking" }> } | undefined;

  evaluate(snapshot: AdministrativeDrainSnapshot, nowMs: number, stallLimitMs: number): RestartDrainDecision {
    const tokens = new Map<string, number>();
    const names: string[] = [];
    const token = (value: string): number => tokens.get(value) ?? tokens.set(value, names.push(value) - 1).get(value)!;
    const blockers = snapshot.blockers.map((blocker): Blocker => ({
      id: token(blocker.id), receipt: blocker.category === "terminal-receipt-persistence",
      session: blocker.sessionId === undefined ? { $: "NoSession" } : { $: "InSession", session: token(blocker.sessionId) },
      state: blocker.state, admitted: instant(blocker.admittedAt), progress: instant(blocker.progressAt),
    }));
    const step = drain.Evaluate(snapshot.blockerCount, blockers,
      this.tracked ? { ...this.tracked.at, id: token(this.tracked.name) } : { $: "Untracked" }, nowMs, stallLimitMs);
    this.tracked = step.tracked.$ === "Tracking" ? { name: names[step.tracked.id]!, at: step.tracked } : undefined;
    const outcome = step.outcome;
    if (outcome.$ === "Completed") return { outcome: "completed" };
    if (outcome.$ === "UnresolvedOwners") return { outcome: "unresolved-owners", owners: snapshot.blockers };
    if (outcome.$ === "Waiting") return { outcome: "waiting" };
    return { outcome: "stalled", blocker: snapshot.blockers.find((blocker) => blocker.id === names[outcome.blocker])!, ageMs: outcome.age };
  }
}

function instant(value: string | undefined): Time {
  if (value === undefined) return { $: "Unset" };
  const ms = Date.parse(value);
  if (new Date(ms).toISOString() !== value) throw new RangeError(`Drain blocker time is not an ISO instant: ${JSON.stringify(value)}`);
  return { $: "At", ms };
}

export function logUnresolvedDrainOwners(
  owners: AdministrativeDrainBlockerSummary[],
  log: (sessionId: string, category: string) => void,
): void {
  for (const owner of owners) {
    if (owner.sessionId) log(owner.sessionId, owner.category);
  }
}
