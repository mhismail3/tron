import type { AdministrativeDrainBlockerSummary, AdministrativeDrainSnapshot } from "../protocol/types.js";

export type RestartDrainDecision =
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
