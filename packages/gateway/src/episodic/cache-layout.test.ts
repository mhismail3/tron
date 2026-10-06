import { describe, expect, it } from "vitest";
import { ANTHROPIC_MAX_CACHE_BREAKPOINTS, CACHE_MARKS, cachePieces, markAnthropicPieces } from "./cache-layout.js";

// Isolated checks for the failure modes the Home cache E2E cannot enumerate
// (progress.md C2-C6, C8): every cut-point case of the splitter, and payload
// shapes the E2E's endpoint never produces (OAuth system blocks, retention
// "none", non-Anthropic payloads). The E2E (home-cache-layout.e2e.test.ts) proves
// the layout on real pi-ai payloads.

const EPHEMERAL = { type: "ephemeral" };

/** A view-like text: numbered lines of `width` characters, `count` of them. */
function lines(count: number, width = 99): string {
  return Array.from({ length: count }, (_unused, index) => `${index}+1|${"x".repeat(width)}`.slice(0, width)).join("\n") + "\n";
}

function withoutCacheControl(value: unknown): unknown {
  return JSON.parse(JSON.stringify(value, (key, field) => key === "cache_control" ? undefined : field));
}

function marks(payload: Record<string, unknown>): string[] {
  const found: string[] = [];
  const visit = (value: unknown, path: string) => {
    if (Array.isArray(value)) value.forEach((item, index) => visit(item, `${path}[${index}]`));
    else if (value && typeof value === "object") {
      for (const [key, field] of Object.entries(value)) {
        if (key === "cache_control") found.push(path);
        else visit(field, `${path}.${key}`);
      }
    }
  };
  visit(payload, "");
  return found;
}

/** The shape pi-ai's Anthropic request builder produces: marks on the system
 * block(s), the last tool and the last block of the last message. */
function anthropicPayload(options: { oauth?: boolean; memoryBlocks: string[] }): Record<string, unknown> {
  const system = options.oauth
    ? [{ type: "text", text: "identity", cache_control: EPHEMERAL }, { type: "text", text: "system", cache_control: EPHEMERAL }]
    : [{ type: "text", text: "system", cache_control: EPHEMERAL }];
  return {
    model: "m",
    system,
    tools: [{ name: "a" }, { name: "b", cache_control: EPHEMERAL }],
    messages: [
      { role: "user", content: options.memoryBlocks.map((text) => ({ type: "text", text })) },
      { role: "user", content: [{ type: "text", text: "the new message", cache_control: EPHEMERAL }] },
    ],
  };
}

describe("cachePieces", () => {
  // C3: the pieces are the text, cut only at line ends.
  it("rejoins to the exact text and cuts only after a line end", () => {
    for (const text of [lines(1_200), lines(400), lines(10), "", "no newline at all", lines(900, 37) + "tail without newline"]) {
      const pieces = cachePieces(text);
      expect(pieces.join("")).toBe(text);
      expect(pieces.every((piece) => piece.length > 0) || text === "").toBe(true);
      for (const piece of pieces.slice(0, -1)) expect(piece.endsWith("\n")).toBe(true);
    }
  });

  // The recipe's marks: the last line end before each mark, a mark past the end skipped.
  it("cuts at the last line end before each mark and skips marks past the end", () => {
    const text = lines(1_200);
    const pieces = cachePieces(text);
    let offset = 0;
    const cuts = pieces.slice(0, -1).map((piece) => (offset += piece.length));
    expect(cuts).toHaveLength(CACHE_MARKS.length);
    cuts.forEach((cut, index) => {
      expect(cut).toBeLessThanOrEqual(CACHE_MARKS[index]!);
      expect(text.slice(cut, CACHE_MARKS[index]!).includes("\n")).toBe(false);
    });
    expect(cachePieces(lines(600))).toHaveLength(2);
    expect(cachePieces(lines(100))).toHaveLength(1);
  });

  // C2: an unchanged start keeps its cuts when the text after it changes.
  it("keeps every cut whose text before it is unchanged", () => {
    const head = lines(900);
    const first = cachePieces(head + "tail one\n");
    const second = cachePieces(head.slice(0, 85_000) + "a different ending\n".repeat(2_000));
    expect(second[0]).toBe(first[0]);
    expect(second[1]).toBe(first[1]);
  });
});

describe("markAnthropicPieces", () => {
  const memory = ["piece one\n", "piece two\n", "piece three\n", "last piece\n", "nonce"];

  // C4 and C6: within the budget, with view marks and the request end kept.
  it("marks the cut pieces, keeps the request end, and never exceeds the budget", () => {
    for (const oauth of [false, true]) {
      const payload = anthropicPayload({ oauth, memoryBlocks: memory });
      const marked = markAnthropicPieces(payload, 0, 3) as Record<string, unknown>;
      const found = marks(marked);
      expect(found.length).toBeLessThanOrEqual(ANTHROPIC_MAX_CACHE_BREAKPOINTS);
      expect(found).toEqual(expect.arrayContaining([
        ".messages[0].content[0]", ".messages[0].content[1]", ".messages[0].content[2]", ".messages[1].content[0]",
      ]));
      expect(found).not.toContain(".messages[0].content[3]");
      expect(withoutCacheControl(marked)).toEqual(withoutCacheControl(payload));
    }
  });

  it("keeps the system mark when the budget allows it", () => {
    const payload = anthropicPayload({ memoryBlocks: memory });
    const found = marks(markAnthropicPieces(payload, 0, 1) as Record<string, unknown>);
    expect(found).toEqual([".system[0]", ".tools[1]", ".messages[0].content[0]", ".messages[1].content[0]"]);
  });

  // C5: no marks at all means caching is off; the layout adds none.
  it("adds nothing when the request carries no cache marks", () => {
    const payload = withoutCacheControl(anthropicPayload({ memoryBlocks: memory })) as Record<string, unknown>;
    expect(markAnthropicPieces(payload, 0, 3)).toEqual(payload);
  });

  // C8 and a malformed target: anything that is not the expected shape is left as it is.
  it("leaves other payload shapes and out-of-range targets unchanged", () => {
    const openai = { model: "m", messages: [{ role: "user", content: "text" }], prompt_cache_key: "k" };
    expect(markAnthropicPieces(openai, 0, 3)).toEqual(openai);
    const payload = anthropicPayload({ memoryBlocks: memory });
    expect(markAnthropicPieces(payload, 7, 3)).toEqual(payload);
    expect(markAnthropicPieces(payload, 0, 0)).toEqual(payload);
  });
});
