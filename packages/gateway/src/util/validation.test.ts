import { describe, expect, it } from "vitest";
import { text } from "./validation.js";

describe("bounded text validation", () => {
  it("admits empty and whitespace editor payloads without trimming them", () => {
    expect(text("", "text")).toBe("");
    expect(text("  \n\t", "text")).toBe("  \n\t");
  });

  it("keeps the byte/count bound explicit", () => {
    expect(() => text("123456", "text", 5)).toThrow("text is too long");
  });
});
