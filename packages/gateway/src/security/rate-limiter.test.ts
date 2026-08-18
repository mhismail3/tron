import { describe, expect, it } from "vitest";
import { RateLimiter } from "./rate-limiter.js";

describe("RateLimiter", () => {
  it("retains the existing exact per-key window semantics", () => {
    const limiter = new RateLimiter(2, 100, 10);
    expect(limiter.admit("address", 100)).toBe(true);
    expect(limiter.admit("address", 150)).toBe(true);
    expect(limiter.admit("address", 199)).toBe(false);
    expect(limiter.admit("address", 201)).toBe(true);
  });

  it("bounds distinct retained keys and evicts the least recently used key", () => {
    const limiter = new RateLimiter(2, 1_000, 3);
    expect(limiter.admit("a", 1)).toBe(true);
    expect(limiter.admit("b", 2)).toBe(true);
    expect(limiter.admit("c", 3)).toBe(true);
    expect(limiter.admit("a", 4)).toBe(true);
    expect(limiter.admit("d", 5)).toBe(true);
    expect(limiter.retainedKeyCount).toBe(3);

    // b was evicted rather than a, because the second a admission refreshed it.
    expect(limiter.admit("b", 6)).toBe(true);
    expect(limiter.retainedKeyCount).toBe(3);
    expect(limiter.admit("a", 7)).toBe(false);
  });

  it("periodic pruning removes expired keys without revisiting them", () => {
    const limiter = new RateLimiter(1, 10, 128, 2);
    expect(limiter.admit("expired", 0)).toBe(true);
    expect(limiter.admit("current", 20)).toBe(true);
    expect(limiter.retainedKeyCount).toBe(1);
  });
});
