import { describe, expect, it } from "vitest";
import { HOME_NONCE_MARKER, markHomeMemoryCache } from "./home-request-policy.js";

// One failure mode the wire E2E (pi-ai's own Anthropic builder) cannot reach:
// a provider that composes its own request, as CortexKit does, prepends its
// cached prompt block to the first user message, which is Home's memory message.
// The view's first block then is not the message's first block, and a mark
// placed by position lands on the provider's block instead (#491).

type Block = { type: "text"; text: string; cache_control?: unknown };

function marks(payload: unknown): string[] {
  const found: string[] = [];
  const visit = (value: unknown, path: string) => {
    if (Array.isArray(value)) value.forEach((item, index) => visit(item, `${path}[${index}]`));
    else if (value && typeof value === "object") {
      for (const [key, field] of Object.entries(value)) key === "cache_control" ? found.push(path) : visit(field, `${path}.${key}`);
    }
  };
  visit(payload, "");
  return found;
}

function payload(prepended: Block[]) {
  const control = { type: "ephemeral", ttl: "1h" };
  const memory: Block[] = [
    ...prepended,
    { type: "text", text: "Tron Home memory: header\n0+1|user: first\n" },
    { type: "text", text: "1+1|talk: second\n" },
    { type: "text", text: "2+1|user: third\n" },
    { type: "text", text: "</chat>" },
    { type: "text", text: `${HOME_NONCE_MARKER}00000000-0000-4000-8000-000000000000` },
  ];
  return {
    system: [{ type: "text", text: "system", cache_control: control }],
    tools: [{ name: "zoom", input_schema: {}, cache_control: control }],
    messages: [
      { role: "user", content: memory },
      { role: "user", content: [{ type: "text", text: "the activation's input", cache_control: control }] },
    ],
  };
}

describe("markHomeMemoryCache", () => {
  it("marks the view's first block and its last line, wherever the view starts", () => {
    for (const prepended of [[], [{ type: "text" as const, text: "provider prompt", cache_control: { type: "ephemeral", ttl: "1h" } }]]) {
      const offset = prepended.length;
      const found = marks(markHomeMemoryCache(payload(prepended)));
      expect(found).toContain(`.messages[0].content[${offset}]`);
      expect(found).toContain(`.messages[0].content[${offset + 2}]`);
      expect(found).not.toContain(`.messages[0].content[${offset + 1}]`);
      expect(found).not.toContain(`.messages[0].content[${offset + 3}]`);
      expect(found).not.toContain(`.messages[0].content[${offset + 4}]`);
      expect(found).toContain(".messages[1].content[0]");
      expect(found.length).toBeLessThanOrEqual(4);
    }
  });
});
