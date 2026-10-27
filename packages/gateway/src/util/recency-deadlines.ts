/** Clock and expiry-timer ownership shared by the process and extension
 * recency owners. Each owner keeps its own partition rules, state set and
 * tombstone policy; only the deadline bookkeeping is common. */
export interface RecencyClock {
  wallNow(): number;
  /** Retained for clock fakes and callers that already provide a monotonic clock.
   * Recency admission deliberately uses wall-clock lifecycle facts so restart
   * remaining time is reconstructed from `recentUntil - wallNow`. */
  monotonicNow(): number;
  setTimeout(callback: () => void, delayMs: number): unknown;
  clearTimeout(handle: unknown): void;
}

export const systemRecencyClock: RecencyClock = {
  wallNow: () => Date.now(),
  monotonicNow: () => typeof performance !== "undefined" ? performance.now() : Date.now(),
  setTimeout: (callback, delayMs) => setTimeout(callback, delayMs),
  clearTimeout: (handle) => clearTimeout(handle as ReturnType<typeof setTimeout>),
};

/** Monotonic expiry deadlines plus the single nearest-expiry timer of one
 * recency owner. In-memory deadlines are reconstructed from the persisted
 * `recentUntil - wallNow` at admission, including after restart, so a later
 * wall-clock jump cannot move an already scheduled expiry. */
export class RecencyDeadlines {
  private readonly deadlines = new Map<string, number>();
  private timer: unknown;

  constructor(private readonly clock: RecencyClock) {}

  /** Admits the persisted wall-clock `recentUntil` of one row. An absent or
   * unparseable instant leaves the row without an expiry. */
  admit(key: string, recentUntilMs: number | undefined): void {
    if (recentUntilMs === undefined || !Number.isFinite(recentUntilMs)) {
      this.deadlines.delete(key);
      return;
    }
    this.deadlines.set(key, this.clock.monotonicNow() + Math.max(0, recentUntilMs - this.clock.wallNow()));
  }

  delete(key: string): void {
    this.deadlines.delete(key);
  }

  /** The monotonic deadline of one row, or undefined without one. */
  deadline(key: string): number | undefined {
    return this.deadlines.get(key);
  }

  /** Monotonic milliseconds left for one row, or undefined without a deadline. */
  remaining(key: string): number | undefined {
    const deadline = this.deadlines.get(key);
    return deadline === undefined ? undefined : Math.max(0, deadline - this.clock.monotonicNow());
  }

  /** Reinstalls the one timer that expires the nearest row. The owner decides
   * which rows are expiring and passes their earliest deadline. */
  schedule(nearestDeadline: number | undefined, onExpiry: () => void): void {
    if (this.timer !== undefined) this.clock.clearTimeout(this.timer);
    this.timer = undefined;
    if (nearestDeadline === undefined) return;
    this.timer = this.clock.setTimeout(() => {
      this.timer = undefined;
      onExpiry();
    }, Math.max(0, nearestDeadline - this.clock.monotonicNow()));
  }
}
