import type { ExtensionRunActivity, ExtensionRunVisibility } from "../protocol/types.js";
import { RecencyDeadlines, systemRecencyClock, type RecencyClock } from "./recency-deadlines.js";


export interface ActivityVisibility {
  visibility: ExtensionRunVisibility;
  remainingMs?: number;
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
  private readonly deadlines: RecencyDeadlines;
  private readonly expiryCallbacks = new Set<ExtensionActivityExpiryCallback>();
  private revision = 0;

  constructor(private readonly clock: RecencyClock = systemRecencyClock) {
    this.deadlines = new RecencyDeadlines(clock);
  }

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
    this.deadlines.admit(key, recentUntil === undefined ? undefined : Date.parse(recentUntil));
    this.revision += 1;
    this.expireDue(false); // Also installs the nearest remaining expiry timer.
    return { ...this.visibility(activity), accepted: true };
  }

  remove(activityId: string): void {
    if (!this.activities.delete(activityId)) return;
    this.deadlines.delete(activityId);
    this.revision += 1;
    this.scheduleNearestExpiry();
  }

  visibility(activity: ExtensionRunActivity, wallNow = this.clock.wallNow()): ActivityVisibility {
    const lifecycle = activity.lifecycle;
    const terminalAt = lifecycle?.terminalAt;
    const recentUntil = lifecycle?.recentUntil;
    if (!terminalAt && (!lifecycle || !["completed", "failed", "stopped", "rejected"].includes(lifecycle.state))) {
      return { visibility: lifecycle?.state === "unknown" ? "unknown" : "current" };
    }
    const terminalMs = terminalAt === undefined ? Number.NaN : Date.parse(terminalAt);
    const expiryMs = recentUntil === undefined ? Number.NaN : Date.parse(recentUntil);
    if (!Number.isFinite(terminalMs) || !Number.isFinite(expiryMs) || expiryMs <= terminalMs) {
      return { visibility: "unknown", ...(terminalAt ? { terminalAt } : {}), ...(recentUntil ? { recentUntil } : {}) };
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
      this.deadlines.delete(key);
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
    let nearest: number | undefined;
    const now = this.clock.wallNow();
    for (const [key, activity] of this.activities) {
      const visibility = this.scheduledVisibility(key, activity, now);
      if (visibility.visibility !== "recent") continue;
      const deadline = this.deadlines.deadline(key);
      if (deadline !== undefined && (nearest === undefined || deadline < nearest)) nearest = deadline;
    }
    this.deadlines.schedule(nearest, () => this.expireDue());
  }

  private scheduledVisibility(key: string, activity: ExtensionRunActivity, wallNow: number): ActivityVisibility {
    const remainingMs = this.deadlines.remaining(key);
    if (remainingMs === undefined) return this.visibility(activity, wallNow);
    const lifecycle = activity.lifecycle;
    const terminalAt = lifecycle?.terminalAt;
    const recentUntil = lifecycle?.recentUntil;
    return {
      visibility: remainingMs > 0 ? "recent" : "historical",
      remainingMs,
      ...(terminalAt ? { terminalAt } : {}),
      ...(recentUntil ? { recentUntil } : {}),
    };
  }
}
