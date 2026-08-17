import { CURSOR_MARKER, visibleWidth } from "@earendil-works/pi-tui";
import { describe, expect, it } from "vitest";
import { boundedExtensionFrame, parseExtensionFrame } from "./frame-parser.js";

function codes(result: ReturnType<typeof parseExtensionFrame>): string[] {
  return result.diagnostics.map(({ code }) => code);
}

describe("parseExtensionFrame", () => {
  it("projects allowlisted SGR attributes and concrete ANSI/256/truecolor values", () => {
    const result = parseExtensionFrame([
      "plain \u001b[1;2;3;4;7;9;31;104mstyled\u001b[22;23;24;27;29;39;49m reset",
      "\u001b[38;5;196;48;2;1;2;3mcolors",
    ]);

    expect(result.ok).toBe(true);
    expect(result.frame.plainText).toBe("plain styled reset\ncolors");
    expect(result.frame.lines[0]?.runs).toEqual([
      { text: "plain ", style: {} },
      { text: "styled", style: { bold: true, dim: true, italic: true, underline: true, inverse: true, strike: true, foreground: "#800000", background: "#0000ff" } },
      { text: " reset", style: {} },
    ]);
    expect(result.frame.lines[1]?.runs).toEqual([
      { text: "colors", style: { foreground: "#ff0000", background: "#010203" } },
    ]);
  });

  it("resets styles at every logical line", () => {
    const result = parseExtensionFrame(["\u001b[1;32mgreen", "plain"]);
    expect(result.frame.lines[0]?.runs[0]?.style).toEqual({ bold: true, foreground: "#008000" });
    expect(result.frame.lines[1]?.runs[0]?.style).toEqual({});
  });

  it("keeps only safe OSC 8 links and removes all other OSC payloads", () => {
    const result = parseExtensionFrame([
      "\u001b]8;;https://example.com/a\u0007safe\u001b]8;;\u0007 " +
      "\u001b]8;;javascript:alert(1)\u0007bad\u001b]8;;\u0007 " +
      "\u001b]52;c;Y2xpcGJvYXJk\u0007end",
      "\u001b]8;;mailto:test@example.com\u001b\\mail\u001b]8;;\u001b\\",
    ]);
    expect(result.frame.plainText).toBe("safe bad end\nmail");
    expect(result.frame.lines[0]?.runs[0]?.style.link).toBe("https://example.com/a");
    expect(result.frame.lines[0]?.runs.some((run) => run.style.link?.startsWith("javascript:"))).toBe(false);
    expect(result.frame.lines[1]?.runs[0]?.style.link).toBe("mailto:test@example.com");
    expect(codes(result)).toEqual(expect.arrayContaining(["unsafe-link-stripped", "unsafe-control-stripped"]));
  });

  it("strips cursor/device/window, clipboard, title, DCS/APC/PM, image, C0 and C1 controls", () => {
    const malicious = [
      "start",
      "\u001b[2J", // cursor/screen CSI
      "\u001b]0;stolen title\u0007",
      "\u001b]52;c;Y2xpcA==\u001b\\",
      "\u001bPprivate\u0007still dcs\u001b\\",
      "\u001b(B",
      "\u001b_private apc\u0007",
      "\u001b^private pm\u001b\\",
      "\u001b_Gf=100;image-data\u001b\\",
      "\u009dhidden c1 osc\u009c",
      "\u009b2J",
      "\u0000\u0008\u007f",
      "end",
    ].join("");
    const result = parseExtensionFrame([malicious]);
    expect(result.ok).toBe(true);
    expect(result.frame.plainText).toBe("startend");
    expect(result.frame.plainText).not.toMatch(/[\u0000-\u001f\u007f-\u009f]/);
    expect(codes(result)).toContain("unsafe-control-stripped");
  });

  it("strips CURSOR_MARKER and derives the projected cursor position", () => {
    const result = parseExtensionFrame(["first", `界a${CURSOR_MARKER}bc`]);
    expect(result.frame.plainText).toBe("first\n界abc");
    expect(result.frame.cursor).toEqual({ row: 1, column: 3 });
  });

  it("bounds standalone diagnostic text by grapheme and display-cell width", () => {
    const source = `界👨‍👩‍👧‍👦e\u0301\u001b]8;;https://example.com\u0007linked\u001b]8;;\u0007`;
    const frame = boundedExtensionFrame(source, 5);
    expect(visibleWidth(frame.plainText)).toBeLessThanOrEqual(5);
    expect(frame.plainText).toBe(frame.lines[0]?.runs.map((run) => run.text).join());
    expect(frame.plainText).not.toMatch(/[\u0000-\u001f\u007f-\u009f]/);
  });

  it("normalizes tabs and clamps without splitting grapheme clusters", () => {
    const family = "👨‍👩‍👧‍👦";
    const result = parseExtensionFrame([`A${family}B`, "e\u0301\tX"], { maxColumns: 3 });
    expect(result.frame.lines[0]?.plainText).toBe(`A${family}`);
    expect(visibleWidth(result.frame.lines[0]?.plainText ?? "")).toBe(3);
    expect(result.frame.lines[1]?.plainText).toBe("é  ");
    expect(codes(result)).toContain("line-clamped");
  });

  it("accounts for complete graphemes across SGR boundaries and parses omitted/colon parameters", () => {
    const family = `👨\u001b[31m‍👩\u001b[0m‍👧‍👦`;
    const keycap = `1\u001b[32m️\u001b[0m⃣`;
    const combined = `e\u001b[1ḿ`;
    const result = parseExtensionFrame([
      `${family}${keycap}${combined}`,
      `\u001b[1;;31mreset-bold`,
      `\u001b[38:2::1:2:3;48:5:196mcolon`,
    ], { maxColumns: 5 });
    expect(result.frame.lines[0]?.plainText).toBe("👨‍👩‍👧‍👦1️⃣é");
    expect(visibleWidth(result.frame.lines[0]?.plainText ?? "")).toBeLessThanOrEqual(5);
    expect(result.frame.lines[1]?.runs[0]?.style).toEqual({ foreground: "#800000" });
    expect(result.frame.lines[2]?.runs[0]?.style).toEqual({ foreground: "#010203", background: "#ff0000" });
  });

  it("fails transactionally with a readable fallback at line, source, run, and frame bounds", () => {
    const tooManyLines = parseExtensionFrame(["a", "b"], { maxLines: 1 });
    const tooMuchSource = parseExtensionFrame(["x".repeat(300)], { maxSourceBytes: 256 });
    const tooManyRuns = parseExtensionFrame(["\u001b[31ma\u001b[32mb\u001b[33mc"], { maxRuns: 2 });
    const tooLargeFrame = parseExtensionFrame(["界".repeat(80)], { maxFrameBytes: 256 });

    for (const result of [tooManyLines, tooMuchSource, tooManyRuns, tooLargeFrame]) {
      expect(result.ok).toBe(false);
      expect(result.frame.plainText).toBe("[Extension component unavailable]");
      expect(result.frame.lines).toHaveLength(1);
    }
    expect(codes(tooManyLines)).toContain("line-limit-exceeded");
    expect(codes(tooMuchSource)).toContain("source-limit-exceeded");
    expect(codes(tooManyRuns)).toContain("run-limit-exceeded");
    expect(codes(tooLargeFrame)).toContain("frame-limit-exceeded");

    const narrowFallback = parseExtensionFrame(["a", "b"], { maxLines: 1, maxColumns: 1 });
    expect(visibleWidth(narrowFallback.frame.plainText)).toBeLessThanOrEqual(1);
  });

  it("fails closed on unterminated terminal strings", () => {
    const result = parseExtensionFrame(["visible\u001b]52;c;secret and more"]);
    expect(result.frame.plainText).toBe("visible");
    expect(codes(result)).toContain("unsafe-control-stripped");
  });

  it("never exposes controls under deterministic hostile fuzz", () => {
    let seed = 0x5eed1234;
    const next = () => {
      seed = (Math.imul(seed, 1_664_525) + 1_013_904_223) >>> 0;
      return seed;
    };
    const controls = ["\u001b[999A", "\u001b]52;c;clip\u0007", "\u001bPdata\u001b\\", "\u001b_Gx\u0007", "\u009b2J", "\u0000", "\t"];
    for (let iteration = 0; iteration < 100; iteration += 1) {
      let source = "";
      for (let index = 0; index < 40; index += 1) {
        source += next() % 3 === 0 ? controls[next() % controls.length] : String.fromCodePoint(0x20 + (next() % 0x5f));
      }
      const result = parseExtensionFrame([source], { maxColumns: 32 });
      expect(result.frame.plainText).not.toMatch(/[\u0000-\u001f\u007f-\u009f]/);
      expect(visibleWidth(result.frame.plainText)).toBeLessThanOrEqual(32);
      expect(() => JSON.stringify(result.frame)).not.toThrow();
    }
  });
});
