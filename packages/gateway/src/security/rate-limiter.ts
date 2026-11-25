import { core as publicHost } from "../core/security/public-host/facade.js";

export class RateLimiter {
  private readonly attempts = new Map<string, readonly number[]>();
  private admissions = 0;

  constructor(
    private readonly maximum: number,
    private readonly windowMs: number,
    private readonly maximumKeys = 4_096,
    private readonly sweepInterval = 64,
  ) {
    if (maximum < 1 || windowMs < 1 || maximumKeys < 1 || sweepInterval < 1) {
      throw new Error("Rate limiter bounds must be positive");
    }
  }

  get retainedKeyCount(): number {
    return this.attempts.size;
  }

  admit(key: string, now = Date.now()): boolean {
    this.admissions += 1;
    if (this.admissions % this.sweepInterval === 0) this.prune(now);

    const { admitted, recent } = publicHost.Admit(this.attempts.get(key) ?? [], now, this.windowMs, this.maximum);

    this.attempts.delete(key);
    if (this.attempts.size >= this.maximumKeys) {
      const oldest = this.attempts.keys().next().value;
      if (oldest !== undefined) this.attempts.delete(oldest);
    }
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
