export interface RecencyClock {
  wallNow(): number;
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

export class RecencyDeadlines {
  private readonly deadlines = new Map<string, number>();
  private timer: unknown;

  constructor(private readonly clock: RecencyClock) {}

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

  deadline(key: string): number | undefined {
    return this.deadlines.get(key);
  }

  remaining(key: string): number | undefined {
    const deadline = this.deadlines.get(key);
    return deadline === undefined ? undefined : Math.max(0, deadline - this.clock.monotonicNow());
  }

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
