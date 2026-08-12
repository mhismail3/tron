export class RateLimiter {
  private readonly attempts = new Map<string, number[]>();

  constructor(
    private readonly maximum: number,
    private readonly windowMs: number,
  ) {}

  admit(key: string, now = Date.now()): boolean {
    const cutoff = now - this.windowMs;
    const recent = (this.attempts.get(key) ?? []).filter((timestamp) => timestamp > cutoff);
    if (recent.length >= this.maximum) {
      this.attempts.set(key, recent);
      return false;
    }
    recent.push(now);
    this.attempts.set(key, recent);
    return true;
  }
}
