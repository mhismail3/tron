import { core as publicHost } from "../core/security/public-host/facade.js";

export class RateLimiter {
  private readonly attempts = new Map<string, readonly number[]>();

  constructor(
    private readonly maximum: number,
    private readonly windowMs: number,
    private readonly maximumKeys = 4_096,
  ) {
    if (maximum < 1 || windowMs < 1 || maximumKeys < 1) throw new Error("Rate limiter bounds must be positive");
  }

  admit(key: string, now = Date.now()): boolean {
    const kept = this.attempts.get(key);
    if (!kept && this.attempts.size >= this.maximumKeys) {
      this.prune(now);
      if (this.attempts.size >= this.maximumKeys) return false;
    }
    const { admitted, recent } = publicHost.Admit(kept ?? [], now, this.windowMs, this.maximum);
    this.attempts.set(key, recent);
    return admitted;
  }

  private prune(now: number): void {
    for (const [key, timestamps] of this.attempts) {
      const recent = publicHost.Recent(timestamps, now, this.windowMs);
      if (recent.length === 0) this.attempts.delete(key);
      else this.attempts.set(key, recent);
    }
  }
}
