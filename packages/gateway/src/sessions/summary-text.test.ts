import { describe, expect, it } from "vitest";
import { boundedSummaryText } from "./summary-text.js";

describe("boundedSummaryText", () => {
  it("preserves empty and exactly bounded previews", () => {
    expect(boundedSummaryText("")).toBe("");
    expect(boundedSummaryText("😀".repeat(256))).toBe("😀".repeat(256));
    expect(boundedSummaryText("a".repeat(1_024))).toBe("a".repeat(1_024));
  });

  it("cuts at code-point boundaries and preserves a literal replacement character", () => {
    expect(boundedSummaryText("a".repeat(1_018) + "\uFFFD" + "tail")).toBe("a".repeat(1_018) + "\uFFFD…");
    expect(boundedSummaryText("😀".repeat(257))).toBe("😀".repeat(255) + "…");
    expect(boundedSummaryText("😀".repeat(100), 256)).toBe("😀".repeat(63) + "…");
  });
});
