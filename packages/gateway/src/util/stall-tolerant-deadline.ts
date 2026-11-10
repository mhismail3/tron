import { performance } from "node:perf_hooks";

const STALL_MS = 100;

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
