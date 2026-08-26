import type { SessionProcessActivity } from "../protocol/types.js";

export const PROCESS_ACTIVITY_RECENT_MS = 5 * 60 * 1_000;

export interface ProcessActivityClock {
  wallNow(): number;
  monotonicNow(): number;
  setTimeout(callback: () => void, delayMs: number): unknown;
  clearTimeout(handle: unknown): void;
}

export const systemProcessActivityClock: ProcessActivityClock = {
  wallNow: () => Date.now(),
  monotonicNow: () => typeof performance !== "undefined" ? performance.now() : Date.now(),
  setTimeout: (callback, delayMs) => setTimeout(callback, delayMs),
  clearTimeout: (handle) => clearTimeout(handle as ReturnType<typeof setTimeout>),
};

export interface ProcessActivityExpiryFrame {
  revision: number;
  asOf: string;
  activities: SessionProcessActivity[];
  expiredProcessIds: string[];
}

export type ProcessActivityExpiryCallback = (frame: ProcessActivityExpiryFrame) => void;

const terminalStates = new Set(["completed", "failed", "stopped", "rejected", "interrupted"]);

/** Gateway-owned five-minute partition for disposable process presentation.
 * Canonical history is read independently and is never removed here. */
export class ProcessActivityRecency {
  private readonly activities = new Map<string, SessionProcessActivity>();
  private readonly monotonicDeadlines = new Map<string, number>();
  private readonly callbacks = new Set<ProcessActivityExpiryCallback>();
  private expiryTimer: unknown;
  private revision = 0;

  constructor(private readonly clock: ProcessActivityClock = systemProcessActivityClock) {}

  registerExpiryCallback(callback: ProcessActivityExpiryCallback): () => void {
    this.callbacks.add(callback);
    return () => this.callbacks.delete(callback);
  }

  upsert(activity: SessionProcessActivity): { activity: SessionProcessActivity; accepted: boolean } {
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
    const expiry = recentUntil === undefined ? Number.NaN : Date.parse(recentUntil);
    if (Number.isFinite(expiry)) {
      this.monotonicDeadlines.set(
        activity.processId,
        this.clock.monotonicNow() + Math.max(0, expiry - this.clock.wallNow()),
      );
    } else {
      this.monotonicDeadlines.delete(activity.processId);
    }
    this.revision += 1;
    this.expireDue(false);
    this.schedule();
    return { activity: this.wire(normalized), accepted: true };
  }

  remove(processId: string): void {
    if (!this.activities.delete(processId)) return;
    this.monotonicDeadlines.delete(processId);
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
    const deadline = this.monotonicDeadlines.get(activity.processId);
    if (deadline !== undefined) return deadline > this.clock.monotonicNow() ? "recent" : "historical";
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
    const recentUntil = Number.isFinite(terminalMs)
      ? new Date(terminalMs + PROCESS_ACTIVITY_RECENT_MS).toISOString()
      : undefined;
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
      this.monotonicDeadlines.delete(processId);
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

  private schedule(): void {
    if (this.expiryTimer !== undefined) this.clock.clearTimeout(this.expiryTimer);
    let nearest: number | undefined;
    for (const [processId, activity] of this.activities) {
      if (!terminalStates.has(activity.lifecycle.state)) continue;
      const deadline = this.monotonicDeadlines.get(processId);
      if (deadline !== undefined && (nearest === undefined || deadline < nearest)) nearest = deadline;
    }
    if (nearest === undefined) {
      this.expiryTimer = undefined;
      return;
    }
    this.expiryTimer = this.clock.setTimeout(() => {
      this.expiryTimer = undefined;
      this.expireDue();
    }, Math.max(0, nearest - this.clock.monotonicNow()));
  }
}
