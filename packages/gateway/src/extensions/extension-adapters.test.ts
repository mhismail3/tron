import { describe, expect, it } from "vitest";
import { adaptedToolDefinition } from "./extension-adapters.js";
import { TRON_QUESTIONNAIRE_REQUEST } from "../sessions/extension-adapter-contract.js";

const definition = (execute: (...args: any[]) => unknown) => ({
  name: "ask",
  parameters: {
    type: "object",
    properties: { question: {}, context: {}, options: {}, allowMultiple: {}, allowFreeform: {}, timeout: {} },
    required: ["question", "options"],
    additionalProperties: false,
  },
  execute,
} as any);
const extension = (source = "npm:@pi9/ask@0.4.2") => ({
  path: "/agent/node_modules/@pi9/ask/src/index.ts",
  resolvedPath: "/agent/node_modules/@pi9/ask/src/index.ts",
  sourceInfo: { path: "/agent/node_modules/@pi9/ask/src/index.ts", source, scope: "user", origin: "package" },
} as any);

function ui(answer: unknown, calls: string[] = []) {
  return {
    [TRON_QUESTIONNAIRE_REQUEST]: async (input: any) => { calls.push(JSON.stringify(input)); return answer; },
    async select(title: string, options: string[]) { calls.push(`select:${title}:${options.join("|")}`); return options[0]; },
    async input(title: string) { calls.push(`input:${title}`); return "legacy"; },
  } as any;
}

describe("explicit @pi9/ask extension adapter", () => {
  it("fails closed for same-named project tools", async () => {
    let invoked = false;
    const original = definition(async () => { invoked = true; return "original"; });
    const result = adaptedToolDefinition(extension("project"), "ask", original);
    expect(result).toBe(original);
    await expect(result.execute("id", {}, undefined, undefined, {} as any)).resolves.toBe("original");
    expect(invoked).toBe(true);
  });

  it("matches the canonical unversioned npm package identity", () => {
    const original = definition(async () => "original");
    expect(adaptedToolDefinition(extension("npm:@pi9/ask"), "ask", original)).not.toBe(original);
  });

  it("fails closed when the public parameter schema is incomplete", () => {
    const malformed = definition(async () => "original");
    (malformed as any).parameters.required = ["question"];
    expect(adaptedToolDefinition(extension(), "ask", malformed)).toBe(malformed);
  });

  it("scripts the original single-select RPC sequence after a structured answer", async () => {
    const calls: string[] = [];
    const original = definition(async (_id: string, _params: unknown, _signal: unknown, _update: unknown, ctx: any) => {
      const selected = await ctx.ui.select("Question", ["1. Yes", "2. No"]);
      const comment = await ctx.ui.input(`Comment for ${selected}`);
      return { selected, comment };
    });
    const adapted = adaptedToolDefinition(extension(), "ask", original);
    const result = await adapted.execute("id", {
      question: "Question", options: [{ label: "Yes" }, { label: "No", description: "Not now" }],
    }, undefined, undefined, { ui: ui({ selections: [{ option: 1, comment: "because" }] }, calls) } as any);
    expect(result).toEqual({ selected: "2. No", comment: "because" });
    expect(calls[0]).toContain('"allowMultiple":false');
  });

  it("emits one exact non-blocking presentation callback with the canonical tool call id", async () => {
    const presented: string[] = [];
    const original = definition(async (_id: string, _params: unknown, _signal: unknown, _update: unknown, ctx: any) =>
      ctx.ui.select("Question", ["1. One"]));
    const adapted = adaptedToolDefinition(extension(), "ask", original, {
      askPresented: async ({ toolCallId }) => { presented.push(toolCallId); throw new Error("push unavailable"); },
    });
    await expect(adapted.execute("ask-call-1", { question: "Question", options: [{ label: "One" }] }, undefined, undefined,
      { ui: ui("1. One") } as any)).resolves.toBe("1. One");
    await new Promise((resolve) => setTimeout(resolve, 0));
    expect(presented).toEqual(["ask-call-1"]);
  });

  it("passes a legacy primitive answer through without scripting", async () => {
    const original = definition(async (_id: string, _params: unknown, _signal: unknown, _update: unknown, ctx: any) => ({
      selected: await ctx.ui.select("Question", ["1. One"]),
      comment: await ctx.ui.input("Comment"),
    }));
    const adapted = adaptedToolDefinition(extension(), "ask", original);
    const result = await adapted.execute("id", { question: "Question", options: [{ label: "One" }] }, undefined, undefined,
      { ui: ui("1. One") } as any);
    expect(result).toEqual({ selected: "1. One", comment: "legacy" });
  });

  it("keeps the old iOS freeform select/input sequence intact", async () => {
    const original = definition(async (_id: string, _params: unknown, _signal: unknown, _update: unknown, ctx: any) => ({
      selected: await ctx.ui.select("Question", ["1. One", "2. Type a response…"]),
      freeform: await ctx.ui.input("Question"),
    }));
    const adapted = adaptedToolDefinition(extension(), "ask", original);
    const result = await adapted.execute("id", { question: "Question", options: [{ label: "One" }] }, undefined, undefined,
      { ui: { [TRON_QUESTIONNAIRE_REQUEST]: async () => "2. Type a response…", async input() { return "legacy freeform"; } } } as any);
    expect(result).toEqual({ selected: "2. Type a response…", freeform: "legacy freeform" });
  });

  it("projects the exact first select primitive and normalizes Ask fields", async () => {
    const calls: any[] = [];
    const original = definition(async (_id: string, _params: unknown, _signal: unknown, _update: unknown, ctx: any) => ctx.ui.select("  Question  ", ["1. One", "2. Two", "3. Type a response…"]));
    const adapted = adaptedToolDefinition(extension(), "ask", original);
    const result = await adapted.execute("id", {
      question: "  Question  ", context: "  Context  ", options: [{ label: " One ", description: " desc ", preview: "  **preview**  " }],
    }, undefined, undefined, { ui: { [TRON_QUESTIONNAIRE_REQUEST]: async (input: any) => { calls.push(input); return "1. One"; } } } as any);
    expect(result).toBe("1. One");
    expect(calls[0]).toMatchObject({ method: "select", primitiveOptions: ["1. One", "2. Two", "3. Type a response…"], question: "Question", context: "Context" });
    expect(calls[0].options[0]).toEqual({ label: "One", description: "desc", preview: "  **preview**  " });
  });

  it("projects multi-select as the exact first input primitive and preserves legacy fallback", async () => {
    const calls: any[] = [];
    let primitiveInput: [string, string | undefined] | undefined;
    const original = definition(async (_id: string, _params: unknown, _signal: unknown, _update: unknown, ctx: any) => {
      const first = await ctx.ui.input("Prompt\n\nEnter numbers:", "placeholder");
      primitiveInput = [first, await ctx.ui.input("Comment", "comment-placeholder")];
      return primitiveInput;
    });
    const adapted = adaptedToolDefinition(extension(), "ask", original);
    const result = await adapted.execute("id", { question: "Question", allowMultiple: true, allowFreeform: false, options: [{ label: "One" }] }, undefined, undefined,
      { ui: { [TRON_QUESTIONNAIRE_REQUEST]: async (input: any) => { calls.push(input); return "1"; }, async input(title: string, placeholder?: string) { return `${title}|${placeholder ?? ""}`; } } } as any);
    expect(result).toEqual(["1", "Comment|comment-placeholder"]);
    expect(calls[0]).toMatchObject({ method: "input", placeholder: "placeholder" });
    expect(calls[0].primitiveOptions).toBeUndefined();
    expect(primitiveInput).toEqual(["1", "Comment|comment-placeholder"]);
  });

  it("aborts before scripted follow-ups instead of returning success", async () => {
    const controller = new AbortController();
    const original = definition(async (_id: string, _params: unknown, _signal: unknown, _update: unknown, ctx: any) => ({
      selected: await ctx.ui.select("Question", ["1. One"]),
      comment: await ctx.ui.input("Comment"),
    }));
    const adapted = adaptedToolDefinition(extension(), "ask", original);
    const result = await adapted.execute("id", { question: "Question", options: [{ label: "One" }] }, controller.signal, undefined,
      { ui: { [TRON_QUESTIONNAIRE_REQUEST]: async () => { controller.abort(); return { selections: [{ option: 0, comment: "late" }] }; } } } as any);
    expect(result).toEqual({ selected: undefined, comment: undefined });
  });

  it("honors the dialog deadline signal before scripted follow-ups", async () => {
    const deadline = new AbortController();
    const original = definition(async (_id: string, _params: unknown, _signal: unknown, _update: unknown, ctx: any) => {
      const selected = await ctx.ui.select("Question", ["1. One"], { signal: deadline.signal });
      deadline.abort();
      return { selected, comment: await ctx.ui.input("Comment", undefined, { signal: deadline.signal }) };
    });
    const adapted = adaptedToolDefinition(extension(), "ask", original);
    const result = await adapted.execute("id", { question: "Question", options: [{ label: "One" }] }, undefined, undefined,
      { ui: { [TRON_QUESTIONNAIRE_REQUEST]: async () => ({ selections: [{ option: 0, comment: "late" }] }) } } as any);
    expect(result).toEqual({ selected: "1. One", comment: undefined });
  });

  it("keeps comments aligned when multi-select freeform is disabled and sorts indices", async () => {
    const original = definition(async (_id: string, _params: unknown, _signal: unknown, _update: unknown, ctx: any) => ({
      selections: await ctx.ui.input("Choose"),
      commentOne: await ctx.ui.input("Comment one"),
      commentTwo: await ctx.ui.input("Comment two"),
    }));
    const adapted = adaptedToolDefinition(extension(), "ask", original);
    const result = await adapted.execute("id", {
      question: "Question", allowMultiple: true, allowFreeform: false,
      options: [{ label: "One" }, { label: "Two" }],
    }, undefined, undefined, { ui: { [TRON_QUESTIONNAIRE_REQUEST]: async () => ({ selections: [{ option: 1, comment: " two " }, { option: 0, comment: " one " }] }) } } as any);
    expect(result).toEqual({ selections: "1,2", commentOne: "one", commentTwo: "two" });
  });

  it("scripts multi-select indices, freeform, and comments", async () => {
    const original = definition(async (_id: string, _params: unknown, _signal: unknown, _update: unknown, ctx: any) => ({
      selections: await ctx.ui.input("Choose"),
      freeform: await ctx.ui.input("Additional"),
      comment: await ctx.ui.input("Comment"),
    }));
    const adapted = adaptedToolDefinition(extension(), "ask", original);
    const result = await adapted.execute("id", {
      question: "Question", allowMultiple: true, options: [{ label: "One" }, { label: "Two" }],
    }, undefined, undefined, { ui: ui({ selections: [{ option: 0 }, { option: 1, comment: "why" }], freeform: "custom" }) } as any);
    expect(result).toEqual({ selections: "1,2", freeform: "custom", comment: "" });
  });
});
