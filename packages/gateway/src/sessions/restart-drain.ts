import type { AdministrativeDrainBlockerSummary, AdministrativeDrainSnapshot } from "../protocol/types.js";

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

    const progressAt = oldest.sessionId === undefined ? oldest.progressAt : snapshot.blockers
      .filter((blocker) => blocker.sessionId === oldest.sessionId)
      .reduce<string | undefined>((latest, blocker) =>
        blocker.progressAt && (!latest || blocker.progressAt > latest) ? blocker.progressAt : latest, undefined);
    const signatureChanged = this.tracked?.id !== oldest.id
      || this.tracked.state !== oldest.state
      || this.tracked.progressAt !== progressAt
      || this.tracked.admittedAt !== oldest.admittedAt;
    if (signatureChanged) {
      const signalAt = progressAt ?? oldest.admittedAt;
      const signalMs = signalAt ? Date.parse(signalAt) : Number.NaN;
      this.tracked = {
        id: oldest.id,
        state: oldest.state,
        ...(progressAt ? { progressAt } : {}),
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
