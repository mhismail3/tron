import type { AdministrativeDrainBlockerSummary, AdministrativeDrainSnapshot } from "../protocol/types.js";

/** Reports blockers from the canonical drain loop without filling the persistent log. */
export const DRAIN_WAIT_LOG_INTERVAL_MS = 15_000;

type DrainMode = "restart" | "stop";
interface DrainLogger {
  log(level: "info", message: string, metadata: { event: string; source: string }): void;
}
interface DrainOwner {
  waitUntilIdle(continueDrain?: (snapshot: AdministrativeDrainSnapshot) => boolean): Promise<boolean>;
  administrativeDrainSnapshot(): AdministrativeDrainSnapshot;
}

/** One `gateway.<mode>-drain.waiting` record naming every summarized blocker. */
export function logDrainBlockers(logger: DrainLogger, mode: DrainMode, snapshot: AdministrativeDrainSnapshot): void {
  const blockers = snapshot.blockers.map(({ sessionId, category, method, state, ageMs, progressAt }) => ({
    ...(sessionId ? { sessionId } : {}), category, ...(method ? { method } : {}), state, ageMs: ageMs ?? null,
    ...(progressAt ? { progressAt } : {}),
  }));
  logger.log("info", `Gateway ${mode} waiting on ${snapshot.blockerCount} operation(s): ${JSON.stringify(blockers)}`, {
    event: `gateway.${mode}-drain.waiting`, source: "lifecycle",
  });
}

/**
 * The intentional stop's wait: it never cuts accepted work, so unlike the restart
 * drain it has no stall bound (a stop exits 0 and nothing relaunches to recover cut
 * work). What it shares is diagnosis: while blockers remain it names them on the
 * restart drain's cadence. Resolves with the final snapshot for the caller's proof.
 */
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

/** Tracks progress only for the oldest outstanding blocker; unrelated churn is irrelevant. */
export class RestartDrainProgress {
  private tracked: { id: string; state: string; progressAt?: string; admittedAt?: string; sinceMs: number } | undefined;

  evaluate(snapshot: AdministrativeDrainSnapshot, nowMs: number, stallLimitMs: number): RestartDrainDecision {
    if (snapshot.blockerCount === 0) {
      this.tracked = undefined;
      return { outcome: "completed" };
    }
    const owners = unresolvedOwners(snapshot);
    if (owners) {
      this.tracked = undefined;
      return { outcome: "unresolved-owners", owners };
    }
    const oldest = snapshot.blockers.reduce<AdministrativeDrainBlockerSummary | undefined>((result, blocker) => {
      if (!result) return blocker;
      if (!blocker.admittedAt) return result;
      if (!result.admittedAt || blocker.admittedAt < result.admittedAt) return blocker;
      return result;
    }, undefined);
    if (!oldest) return { outcome: "waiting" };

    const signatureChanged = this.tracked?.id !== oldest.id
      || this.tracked.state !== oldest.state
      || this.tracked.progressAt !== oldest.progressAt
      || this.tracked.admittedAt !== oldest.admittedAt;
    if (signatureChanged) {
      // A blocker without a progress signal is judged from admission.
      const signalAt = oldest.progressAt ?? oldest.admittedAt;
      const signalMs = signalAt ? Date.parse(signalAt) : Number.NaN;
      this.tracked = {
        id: oldest.id,
        state: oldest.state,
        ...(oldest.progressAt ? { progressAt: oldest.progressAt } : {}),
        ...(oldest.admittedAt ? { admittedAt: oldest.admittedAt } : {}),
        sinceMs: Number.isFinite(signalMs) ? signalMs : nowMs,
      };
    }
    const tracked = this.tracked;
    if (!tracked) return { outcome: "waiting" };
    const ageMs = Math.max(0, nowMs - tracked.sinceMs);
    return ageMs >= stallLimitMs ? { outcome: "stalled", blocker: oldest, ageMs } : { outcome: "waiting" };
  }
}

export function logUnresolvedDrainOwners(
  owners: AdministrativeDrainBlockerSummary[],
  log: (sessionId: string, category: string) => void,
): void {
  for (const owner of owners) {
    if (owner.sessionId) log(owner.sessionId, owner.category);
  }
}

function unresolvedOwners(snapshot: AdministrativeDrainSnapshot): AdministrativeDrainBlockerSummary[] | undefined {
  if (snapshot.blockerCount !== snapshot.blockers.length || snapshot.blockers.length === 0) return undefined;
  const owners = snapshot.blockers.filter((blocker) =>
    blocker.category === "terminal-receipt-persistence" && blocker.state === "suspect" && blocker.sessionId,
  );
  return owners.length === snapshot.blockers.length ? owners : undefined;
}
