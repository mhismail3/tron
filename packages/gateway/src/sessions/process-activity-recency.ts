import type { SessionProcessActivity } from "../protocol/types.js";
import { RecencyDeadlines, systemRecencyClock, type RecencyClock } from "./recency-deadlines.js";

export const PROCESS_ACTIVITY_RECENT_MS = 5 * 60 * 1_000;
const MAX_PROCESS_TIMESTAMP_FUTURE_SKEW_MS = 60_000;

export interface ProcessActivityExpiryFrame {
  revision: number;
  asOf: string;
  activities: SessionProcessActivity[];
  expiredProcessIds: string[];
}

export type ProcessActivityExpiryCallback = (frame: ProcessActivityExpiryFrame) => void;

const terminalStates = new Set(["completed", "failed", "stopped", "rejected", "interrupted"]);
const MAX_TERMINAL_TOMBSTONES = 2_048;

/** Gateway-owned five-minute partition for disposable process presentation.
 * Canonical history is read independently and is never removed here. */
export class ProcessActivityRecency {
  private readonly activities = new Map<string, SessionProcessActivity>();
  private readonly deadlines: RecencyDeadlines;
  /** Bounded non-presentational terminal latches prevent a late artifact from
   * resurrecting work after its five-minute row has expired. */
  private readonly terminalTombstones = new Set<string>();
  private readonly callbacks = new Set<ProcessActivityExpiryCallback>();
  private revision = 0;

  constructor(private readonly clock: RecencyClock = systemRecencyClock) {
    this.deadlines = new RecencyDeadlines(clock);
  }

  registerExpiryCallback(callback: ProcessActivityExpiryCallback): () => void {
    this.callbacks.add(callback);
    return () => this.callbacks.delete(callback);
  }

  upsert(activity: SessionProcessActivity): { activity: SessionProcessActivity; accepted: boolean } {
    // Unknown is unavailable evidence, not ambient work. Never retain it in
    // the registry-global recency owner where it has no terminal deadline.
    if (activity.lifecycle.state === "unknown" || activity.visibility === "unknown") {
      const previous = this.activities.get(activity.processId);
      return { activity: previous ? this.wire(previous) : { ...activity, visibility: "unknown" }, accepted: false };
    }
    if (this.terminalTombstones.has(activity.processId)) {
      return { activity: { ...activity, visibility: "historical" }, accepted: false };
    }
    const previous = this.activities.get(activity.processId);
    if (previous && activity.lifecycle.sequence <= previous.lifecycle.sequence) {
      return { activity: this.wire(previous), accepted: false };
    }
    if (previous && terminalStates.has(previous.lifecycle.state) && !terminalStates.has(activity.lifecycle.state)) {
      return { activity: this.wire(previous), accepted: false };
    }
    const normalized = this.normalized(activity);
    this.activities.set(activity.processId, normalized);
    const recentUntil = normalized.lifecycle.recentUntil;
    this.deadlines.admit(activity.processId, recentUntil === undefined ? undefined : Date.parse(recentUntil));
    this.revision += 1;
    this.expireDue(false); // Also installs the nearest remaining expiry timer.
    return { activity: this.wire(normalized), accepted: true };
  }

  remove(processId: string): void {
    if (!this.activities.delete(processId)) return;
    this.deadlines.delete(processId);
    this.revision += 1;
    this.schedule();
  }

  currentAndRecent(): ProcessActivityExpiryFrame {
    return this.expireDue(false);
  }

  visibility(activity: SessionProcessActivity): SessionProcessActivity["visibility"] {
    if (!terminalStates.has(activity.lifecycle.state)) {
      return activity.lifecycle.state === "unknown" ? "unknown" : "active";
    }
    const remainingMs = this.deadlines.remaining(activity.processId);
    if (remainingMs !== undefined) return remainingMs > 0 ? "recent" : "historical";
    const expiry = Date.parse(activity.lifecycle.recentUntil ?? "");
    return Number.isFinite(expiry) && expiry > this.clock.wallNow() ? "recent" : "historical";
  }

  wire(activity: SessionProcessActivity): SessionProcessActivity {
    return { ...activity, visibility: this.visibility(activity) };
  }

  private normalized(activity: SessionProcessActivity): SessionProcessActivity {
    const terminal = terminalStates.has(activity.lifecycle.state);
    const terminalAt = terminal ? activity.lifecycle.terminalAt : undefined;
    const terminalMs = terminalAt === undefined ? Number.NaN : Date.parse(terminalAt);
    const plausibleTerminal = Number.isFinite(terminalMs)
      && terminalMs <= this.clock.wallNow() + MAX_PROCESS_TIMESTAMP_FUTURE_SKEW_MS;
    // A malformed/future producer timestamp must never extend ambient
    // visibility. Give it an already-due deadline so the disposable row is
    // retired while canonical history retains the original timestamp.
    const recentUntil = plausibleTerminal
      ? new Date(terminalMs + PROCESS_ACTIVITY_RECENT_MS).toISOString()
      : terminal ? new Date(this.clock.wallNow()).toISOString() : undefined;
    return {
      ...activity,
      lifecycle: {
        ...activity.lifecycle,
        ...(terminalAt ? { terminalAt } : {}),
        ...(recentUntil ? { recentUntil } : {}),
      },
      visibility: terminal ? (recentUntil ? "recent" : "unknown") : activity.lifecycle.state === "unknown" ? "unknown" : "active",
    };
  }

  private expireDue(notify = true): ProcessActivityExpiryFrame {
    const expiredProcessIds: string[] = [];
    for (const [processId, activity] of this.activities) {
      if (this.visibility(activity) !== "historical") continue;
      this.activities.delete(processId);
      this.deadlines.delete(processId);
      if (terminalStates.has(activity.lifecycle.state)) this.latchTerminal(processId);
      expiredProcessIds.push(processId);
    }
    if (expiredProcessIds.length > 0) this.revision += 1;
    this.schedule();
    const activities = [...this.activities.values()]
      .map((activity) => this.wire(activity))
      .filter((activity) => activity.visibility === "active" || activity.visibility === "recent")
      .sort((left, right) => {
        const bucket = (value: SessionProcessActivity) => value.visibility === "active" ? 0 : 1;
        return bucket(left) - bucket(right)
          || (right.lifecycle.terminalAt ?? right.lifecycle.observedAt).localeCompare(left.lifecycle.terminalAt ?? left.lifecycle.observedAt)
          || left.processId.localeCompare(right.processId);
      });
    const frame = {
      revision: this.revision,
      asOf: new Date(this.clock.wallNow()).toISOString(),
      activities,
      expiredProcessIds,
    };
    if (notify && expiredProcessIds.length > 0) for (const callback of this.callbacks) callback(frame);
    return frame;
  }

  private latchTerminal(processId: string): void {
    this.terminalTombstones.delete(processId);
    this.terminalTombstones.add(processId);
    while (this.terminalTombstones.size > MAX_TERMINAL_TOMBSTONES) {
      const oldest = this.terminalTombstones.values().next().value as string | undefined;
      if (!oldest) break;
      this.terminalTombstones.delete(oldest);
    }
  }

  private schedule(): void {
    let nearest: number | undefined;
    for (const [processId, activity] of this.activities) {
      if (!terminalStates.has(activity.lifecycle.state)) continue;
      const deadline = this.deadlines.deadline(processId);
      if (deadline !== undefined && (nearest === undefined || deadline < nearest)) nearest = deadline;
    }
    this.deadlines.schedule(nearest, () => this.expireDue());
  }
}
