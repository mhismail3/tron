import { performance } from "node:perf_hooks";

/** Lateness at which a timer counts as having fired after an event-loop stall. */
const STALL_MS = 100;

/**
 * A deadline for work that runs outside this event loop (a child process, the
 * fs threadpool). Node runs due timers before the I/O callbacks that were
 * already completed while the loop was blocked, so a plain timer that fires
 * after a long synchronous stretch (an extension transform, a GC pause) would
 * expire work that had in fact finished. A timer that fires late by at least
 * `STALL_MS` re-arms for that lateness instead, so the work's completion is
 * delivered first; work still unsettled then expires. The extension is bounded
 * by the window itself, so stalls can at most double the wall-clock bound.
 */
export class StallTolerantDeadline {
  private timer: NodeJS.Timeout | undefined;
  private extendedMs = 0;
  private hasExpired = false;

  constructor(private readonly windowMs: number, private readonly onExpire: () => void) {
    this.arm(windowMs);
  }

  get expired(): boolean {
    return this.hasExpired;
  }

  cancel(): void {
    if (this.timer) clearTimeout(this.timer);
    this.timer = undefined;
  }

  private arm(waitMs: number): void {
    const scheduledAt = performance.now();
    this.timer = setTimeout(() => {
      this.timer = undefined;
      const lateMs = performance.now() - scheduledAt - waitMs;
      const extensionMs = Math.min(lateMs, this.windowMs - this.extendedMs);
      if (lateMs >= STALL_MS && extensionMs > 0) {
        this.extendedMs += extensionMs;
        this.arm(extensionMs);
        return;
      }
      this.hasExpired = true;
      this.onExpire();
    }, waitMs);
  }
}
