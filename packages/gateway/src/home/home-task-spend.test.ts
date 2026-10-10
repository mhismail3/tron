import { describe, expect, it } from "vitest";
import { homeTaskSpend } from "./home-task-spend.js";

// Canonical corruption/duplicate delivery cannot be produced by a normal faux
// provider. These isolated tests protect the projection's authoritative boundary.
const entry = (id: string, input = 7) => ({ id, type: "message", message: {
  role: "assistant", provider: "test-provider", model: "test-model",
  usage: { input, output: 3, cacheRead: 2, cacheWrite: 1,
    cost: { input: 10, output: 20, cacheRead: 1, cacheWrite: 1, total: 32 } },
} });
describe("homeTaskSpend", () => {
  it("deduplicates canonical usage identities, counts all tokens and ignores unproven SDK costs", () => {
    const one = entry("entry-one");
    const spend = homeTaskSpend([one, structuredClone(one), entry("entry-two", 5)] as any);
    expect(spend).toEqual({ inputTokens: 18, outputTokens: 6, sourceDigest: expect.stringMatching(/^[a-f0-9]{64}$/u) });
    expect(homeTaskSpend([one, entry("entry-two", 5)] as any)).toEqual(spend);
  });
  it("refuses contradictory usage for the same canonical event identity", () => {
    expect(() => homeTaskSpend([entry("same", 7), entry("same", 8)] as any)).toThrow(/contradictory/i);
  });
  it.each([-1, NaN, Infinity, 1.5, Number.MAX_SAFE_INTEGER])("refuses invalid or overflowing counters %s rather than displaying false totals", input => {
    expect(() => homeTaskSpend([entry("invalid", input)] as any)).toThrow(/usage|tokens/i);
  });
});
