import { describe, expect, it } from "vitest";
import { normalizePublicDisplayURL } from "../display/display-contract.js";
import { RateLimiter } from "./rate-limiter.js";

describe("public host guard (security/public-host block)", () => {
  it("refuses every listed private, reserved and documentation address, IPv4-mapped IPv6 included, and admits public ones", () => {
    const refused = ["0.1.2.3", "10.0.0.1", "100.64.0.1", "100.127.255.255", "127.0.0.1", "169.254.169.254", "172.16.0.1", "172.31.255.255",
      "192.0.0.1", "192.0.2.1", "192.168.1.1", "198.18.0.1", "198.19.255.255", "198.51.100.7", "203.0.113.9", "224.0.0.1", "255.255.255.255",
      "[::]", "[::1]", "[fc00::1]", "[fd12::1]", "[fe80::1]", "[ff02::1]", "[2001:db8::1]", "[::ffff:127.0.0.1]", "[::ffff:8.8.8.8]",
      "[::ffff:a9fe:a9fe]", "[64:ff9b::808:808]", "[::127.0.0.1]", "[4000::1]", "[1fff:ffff::]"];
    const admitted = ["1.1.1.1", "8.8.8.8", "100.63.255.255", "100.128.0.0", "169.253.0.1", "172.15.0.1", "172.32.0.1", "192.1.0.1",
      "198.17.0.1", "198.20.0.1", "198.51.101.1", "203.0.114.1", "223.255.255.255", "[2606:4700::1111]", "[2001:db9::1]", "[2a00:1450::1]", "[2000::]"];
    for (const host of refused) expect(normalizePublicDisplayURL(`https://${host}/page`), host).toBeUndefined();
    for (const host of admitted) expect(normalizePublicDisplayURL(`https://${host}/page`), host).toBe(`https://${host}/page`);
  });

  it("admits at most the maximum per key in any window and never lets a stale key block", () => {
    const limiter = new RateLimiter(3, 1_000, 8, 1_000);
    const admits = (key: string, now: number) => limiter.admit(key, now);
    expect([0, 100, 200, 300, 999].map(now => admits("a", now))).toEqual([true, true, true, false, false]);
    expect(admits("b", 999)).toBe(true);
    expect([1_000, 1_099, 1_100, 1_101].map(now => admits("a", now))).toEqual([true, false, true, false]);
    expect([5_000, 5_001, 5_002].map(now => admits("a", now))).toEqual([true, true, true]);
  });

  it("evicts the least recently used key at the key cap and sweeps only keys with no attempt left in the window", () => {
    const limiter = new RateLimiter(1, 1_000, 2, 2);
    expect([limiter.admit("x", 0), limiter.admit("y", 0), limiter.admit("z", 0)]).toEqual([true, true, true]);
    expect(limiter.retainedKeyCount).toBe(2);
    expect(limiter.admit("x", 10)).toBe(true);
    expect(limiter.admit("y", 10)).toBe(true);
    expect(limiter.retainedKeyCount).toBe(2);
    expect(limiter.admit("y", 500)).toBe(false);
    expect(limiter.admit("z", 1_005)).toBe(true);
    expect(limiter.retainedKeyCount).toBe(2);
    expect(limiter.admit("y", 1_006)).toBe(false);
    expect(limiter.admit("y", 3_000)).toBe(true);
    expect(limiter.admit("y", 3_001)).toBe(false);
    expect(limiter.retainedKeyCount).toBe(1);
  });
});
