import { describe, expect, it } from "vitest";
import { createTronChildBootstrapExtension, TRON_CHILD_BOOTSTRAP_PROMPT_ENV } from "./tron-child-bootstrap-extension.js";

describe("Tron child bootstrap extension", () => {
  it("adds only the admitted prompt/context and registers no Gateway tools", async () => {
    let handler: ((event: { systemPrompt: string }) => unknown) | undefined;
    const tools: string[] = [];
    const pi = {
      on: (_event: string, callback: (event: { systemPrompt: string }) => unknown) => { handler = callback; },
      registerTool: (tool: { name: string }) => tools.push(tool.name),
    } as any;
    const previous = process.env[TRON_CHILD_BOOTSTRAP_PROMPT_ENV];
    process.env[TRON_CHILD_BOOTSTRAP_PROMPT_ENV] = "Tron child context: synthetic workspace";
    try {
      createTronChildBootstrapExtension()(pi);
      const result = await handler!({ systemPrompt: "base" }) as { systemPrompt: string };
      expect(result.systemPrompt).toContain("Tron child context: synthetic workspace");
      expect(tools).toEqual([]);
    } finally {
      if (previous === undefined) delete process.env[TRON_CHILD_BOOTSTRAP_PROMPT_ENV];
      else process.env[TRON_CHILD_BOOTSTRAP_PROMPT_ENV] = previous;
    }
  });
});
