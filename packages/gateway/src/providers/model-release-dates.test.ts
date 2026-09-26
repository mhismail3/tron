import { readFileSync } from "node:fs";
import { describe, expect, it } from "vitest";
import { modelReleaseDate } from "./model-release-dates.js";

// Failure modes guarded here: a regenerated snapshot that keeps a coarse
// `YYYY-MM` value would silently break the picker's Latest ordering, and an
// alias entry that names a provider absent from the snapshot would drop the
// dates of every model a platform such as OpenAI Codex re-exports.
const SNAPSHOT = JSON.parse(readFileSync(new URL("./model-release-dates.json", import.meta.url), "utf8")) as Record<string, string>;
const ALIASES = JSON.parse(readFileSync(new URL("./model-release-date-aliases.json", import.meta.url), "utf8")) as Record<string, string>;

describe("model release dates", () => {
  it("snapshots only day-precision release dates keyed by vendor provider and model", () => {
    const entries = Object.entries(SNAPSHOT);
    expect(entries.length).toBeGreaterThan(0);
    for (const [key, value] of entries) {
      expect(key).toMatch(/^[^/]+\/.+$/);
      expect(value).toMatch(/^\d{4}-\d{2}-\d{2}$/);
      expect(Number.isFinite(Date.parse(value))).toBe(true);
    }
  });

  it("resolves every aliased provider to its vendor's dates", () => {
    for (const [source, target] of Object.entries(ALIASES)) {
      const targetEntries = Object.entries(SNAPSHOT).filter(([key]) => key.startsWith(`${target}/`));
      expect(targetEntries.length).toBeGreaterThan(0);
      for (const [key, value] of targetEntries) {
        expect(modelReleaseDate(source, key.slice(target.length + 1))).toBe(value);
      }
    }
  });

  it("leaves unknown and unaliased models undated", () => {
    expect(modelReleaseDate("custom", "no-such-model")).toBeUndefined();
    expect(modelReleaseDate("anthropic", "no-such-model")).toBeUndefined();
    expect(modelReleaseDate("openai-codex", "no-such-model")).toBeUndefined();
  });
});
