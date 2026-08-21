import type { ExtensionRunActivity, ExtensionRunVisibility } from "../protocol/types.js";

export const EXTENSION_ACTIVITY_RECENT_MS = 15 * 60 * 1_000;

export interface ExtensionActivityClock {
  wallNow(): number;
  /** Retained for clock fakes and callers that already provide a monotonic clock.
   * Recency admission deliberately uses wall-clock lifecycle facts so restart
   * remaining time is reconstructed from `recentUntil - wallNow`. */
  monotonicNow(): number;
  setTimeout(callback: () => void, delayMs: number): unknown;
  clearTimeout(handle: unknown): void;
}

export const systemExtensionActivityClock: ExtensionActivityClock = {
  wallNow: () => Date.now(),
  monotonicNow: () => typeof performance !== "undefined" ? performance.now() : Date.now(),
  setTimeout: (callback, delayMs) => setTimeout(callback, delayMs),
  clearTimeout: (handle) => clearTimeout(handle as ReturnType<typeof setTimeout>),
};

export interface ActivityVisibility {
  visibility: ExtensionRunVisibility;
  remainingMs: number;
  terminalAt?: string;
  recentUntil?: string;
  /** Internal admission fact; never serialized on the wire. */
  accepted?: boolean;
}

export interface ActivityExpiryFrame {
  revision: number;
  asOf: string;
  activities: ExtensionRunActivity[];
  expiredActivityIds: string[];
}

export type ExtensionActivityExpiryCallback = (frame: ActivityExpiryFrame) => void;

/** Gateway-owned current/recent partition. Recency is a bounded scheduling
 * projection; canonical history is never removed here. */
export class ExtensionActivityRecency {
  private readonly activities = new Map<string, ExtensionRunActivity>();
  /** In-memory monotonic deadlines are reconstructed from persisted
   * recentUntil-wallNow on admission, including after restart. */
  private readonly monotonicDeadlines = new Map<string, number>();
  private readonly expiryCallbacks = new Set<ExtensionActivityExpiryCallback>();
  private expiryTimer: unknown;
  private timerDeadline: number | undefined;
  private revision = 0;

  constructor(private readonly clock: ExtensionActivityClock = systemExtensionActivityClock) {}

  get liveRevision(): number { return this.revision; }

  /** Registers the owning RuntimeSlot's expiry callback. */
  registerExpiryCallback(callback: ExtensionActivityExpiryCallback): () => void {
    this.expiryCallbacks.add(callback);
    return () => this.expiryCallbacks.delete(callback);
  }

  upsert(activity: ExtensionRunActivity): ActivityVisibility {
    const key = activity.activityId ?? activity.id;
    const existing = this.activities.get(key);
    // Terminal latches and sequence ordering are Gateway-owned. Producer
    // timestamps are not allowed to resurrect or replace a newer projection.
    if (existing?.lifecycle?.sequence !== undefined && activity.lifecycle?.sequence !== undefined
      && activity.lifecycle.sequence <= existing.lifecycle.sequence) {
      return { ...this.visibility(existing), accepted: false };
    }
    if (existing?.lifecycle && ["completed", "failed", "stopped", "rejected"].includes(existing.lifecycle.state)
      && activity.lifecycle && !["completed", "failed", "stopped", "rejected"].includes(activity.lifecycle.state)) {
      return { ...this.visibility(existing), accepted: false };
    }
    this.activities.set(key, activity);
    const recentUntil = activity.lifecycle?.recentUntil;
    const recentUntilMs = recentUntil === undefined ? Number.NaN : Date.parse(recentUntil);
    if (Number.isFinite(recentUntilMs)) {
      this.monotonicDeadlines.set(key, this.clock.monotonicNow() + Math.max(0, recentUntilMs - this.clock.wallNow()));
    } else {
      this.monotonicDeadlines.delete(key);
    }
    this.revision += 1;
    this.expireDue(false);
    this.scheduleNearestExpiry();
    return { ...this.visibility(activity), accepted: true };
  }

  remove(activityId: string): void {
    if (!this.activities.delete(activityId)) return;
    this.monotonicDeadlines.delete(activityId);
    this.revision += 1;
    this.scheduleNearestExpiry();
  }

  visibility(activity: ExtensionRunActivity, wallNow = this.clock.wallNow()): ActivityVisibility {
    const lifecycle = activity.lifecycle;
    const terminalAt = lifecycle?.terminalAt;
    const recentUntil = lifecycle?.recentUntil;
    if (!terminalAt && (!lifecycle || !["completed", "failed", "stopped", "rejected"].includes(lifecycle.state))) {
      return { visibility: lifecycle?.state === "unknown" ? "unknown" : "current", remainingMs: 0 };
    }
    const terminalMs = terminalAt === undefined ? Number.NaN : Date.parse(terminalAt);
    const expiryMs = recentUntil === undefined ? Number.NaN : Date.parse(recentUntil);
    if (!Number.isFinite(terminalMs) || !Number.isFinite(expiryMs) || expiryMs <= terminalMs) {
      return { visibility: "unknown", remainingMs: 0, ...(terminalAt ? { terminalAt } : {}), ...(recentUntil ? { recentUntil } : {}) };
    }
    const remainingMs = Math.max(0, expiryMs - wallNow);
    return {
      visibility: remainingMs > 0 ? "recent" : "historical",
      remainingMs,
      ...(terminalAt ? { terminalAt } : {}),
      ...(recentUntil ? { recentUntil } : {}),
    };
  }

  currentAndRecent(): ActivityExpiryFrame {
    return this.expireDue();
  }

  /** Removes all terminal entries whose persisted wall-clock deadline has
   * arrived, then invokes RuntimeSlot callbacks with the authoritative frame. */
  expireDue(notify = true): ActivityExpiryFrame {
    const now = this.clock.wallNow();
    const expiredActivityIds: string[] = [];
    for (const [key, activity] of this.activities) {
      const visibility = this.scheduledVisibility(key, activity, now);
      if (visibility.visibility !== "historical") continue;
      this.activities.delete(key);
      this.monotonicDeadlines.delete(key);
      expiredActivityIds.push(key);
    }
    if (expiredActivityIds.length > 0) this.revision += 1;
    this.scheduleNearestExpiry();
    const frame = this.currentAndRecentFrame(now, expiredActivityIds);
    if (notify && expiredActivityIds.length > 0) {
      for (const callback of this.expiryCallbacks) callback(frame);
    }
    return frame;
  }

  private currentAndRecentFrame(now: number, expiredActivityIds: string[]): ActivityExpiryFrame {
    const current: ExtensionRunActivity[] = [];
    const recent: ExtensionRunActivity[] = [];
    for (const [key, activity] of this.activities) {
      const bucket = this.scheduledVisibility(key, activity, now).visibility;
      if (bucket === "current") current.push(activity);
      else if (bucket === "recent") recent.push(activity);
    }
    const byUpdatedAt = (left: ExtensionRunActivity, right: ExtensionRunActivity) => right.updatedAt.localeCompare(left.updatedAt);
    current.sort(byUpdatedAt);
    recent.sort(byUpdatedAt);
    return { revision: this.revision, asOf: new Date(now).toISOString(), activities: [...current, ...recent], expiredActivityIds };
  }

  private scheduleNearestExpiry(): void {
    if (this.expiryTimer !== undefined) this.clock.clearTimeout(this.expiryTimer);
    let nearest: number | undefined;
    const now = this.clock.wallNow();
    for (const [key, activity] of this.activities) {
      const visibility = this.scheduledVisibility(key, activity, now);
      if (visibility.visibility !== "recent") continue;
      const deadline = this.monotonicDeadlines.get(key);
      if (deadline !== undefined && (nearest === undefined || deadline < nearest)) nearest = deadline;
    }
    if (nearest === undefined) {
      this.expiryTimer = undefined;
      this.timerDeadline = undefined;
      return;
    }
    // Persisted deadlines are wall-clock facts. Once admitted (including after
    // restart), convert the remaining wall time to a monotonic deadline so a
    // later wall-clock jump cannot move an already scheduled expiry.
    const remainingMs = Math.max(0, nearest - this.clock.monotonicNow());
    this.timerDeadline = nearest;
    this.expiryTimer = this.clock.setTimeout(() => {
      this.expiryTimer = undefined;
      this.timerDeadline = undefined;
      this.expireDue();
    }, remainingMs);
  }

  private scheduledVisibility(key: string, activity: ExtensionRunActivity, wallNow: number): ActivityVisibility {
    const deadline = this.monotonicDeadlines.get(key);
    if (deadline === undefined) return this.visibility(activity, wallNow);
    const lifecycle = activity.lifecycle;
    const terminalAt = lifecycle?.terminalAt;
    const recentUntil = lifecycle?.recentUntil;
    const remainingMs = Math.max(0, deadline - this.clock.monotonicNow());
    return {
      visibility: remainingMs > 0 ? "recent" : "historical",
      remainingMs,
      ...(terminalAt ? { terminalAt } : {}),
      ...(recentUntil ? { recentUntil } : {}),
    };
  }
}
