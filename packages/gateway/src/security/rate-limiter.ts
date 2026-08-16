export class RateLimiter {
  private readonly attempts = new Map<string, number[]>();
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

    const cutoff = now - this.windowMs;
    const recent = (this.attempts.get(key) ?? []).filter((timestamp) => timestamp > cutoff);
    const admitted = recent.length < this.maximum;
    if (admitted) recent.push(now);

    // Map insertion order is the deterministic LRU. Every presented key is
    // touched, including a rejected key that still owns a live window.
    this.attempts.delete(key);
    if (!this.attempts.has(key) && this.attempts.size >= this.maximumKeys) {
      const oldest = this.attempts.keys().next().value;
      if (oldest !== undefined) this.attempts.delete(oldest);
    }
    this.attempts.set(key, recent);
    return admitted;
  }

  private prune(now: number): void {
    const cutoff = now - this.windowMs;
    for (const [key, timestamps] of this.attempts) {
      const recent = timestamps.filter((timestamp) => timestamp > cutoff);
      if (recent.length === 0) this.attempts.delete(key);
      else this.attempts.set(key, recent);
    }
  }
}
