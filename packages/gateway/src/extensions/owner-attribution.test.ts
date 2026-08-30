import { describe, expect, it } from "vitest";
import { attributeExtensions, attributedCommandOwner, attributedToolOwner, currentExtensionOwner } from "./owner-attribution.js";

describe("extension owner attribution", () => {
  it("rejects extension tools that collide with the canonical assistant bash tool", () => {
    const extension = {
      path: "/project/bash.ts", resolvedPath: "/project/bash.ts",
      sourceInfo: { path: "/project/bash.ts", source: "project", scope: "project", origin: "top-level" },
      handlers: new Map(), tools: new Map([["bash", { definition: { execute: async () => ({ content: [] }) } }]]),
      commands: new Map(), shortcuts: new Map(), messageRenderers: new Map(), entryRenderers: new Map(),
    };
    expect(() => attributeExtensions({ extensions: [extension as any], errors: [], runtime: {} as any })).toThrow(/bash tool name is reserved/);
  });

  it("rejects project tools that collide with Tron's reserved notify capability", () => {
    const extension = {
      path: "/project/notify.ts", resolvedPath: "/project/notify.ts",
      sourceInfo: { path: "/project/notify.ts", source: "project", scope: "project", origin: "top-level" },
      handlers: new Map(), tools: new Map([["notify", { definition: { execute: async () => ({ content: [] }) } }]]),
      commands: new Map(), shortcuts: new Map(), messageRenderers: new Map(), entryRenderers: new Map(),
    };
    expect(() => attributeExtensions({ extensions: [extension as any], errors: [], runtime: {} as any })).toThrow(/reserved/);
  });

  it("keeps handler and deferred tool callbacks inside the loaded owner", async () => {
    const seen: Array<unknown> = [];
    const handler = async () => {
      seen.push(currentExtensionOwner());
      await new Promise<void>((resolve) => setTimeout(resolve, 0));
      seen.push(currentExtensionOwner());
    };
    const execute = async () => {
      seen.push(currentExtensionOwner());
      return { content: [], details: {} };
    };
    const command = async () => { seen.push(currentExtensionOwner()); };
    const extension = {
      path: "/extensions/subagents.ts", resolvedPath: "/extensions/subagents.ts",
      sourceInfo: { path: "/extensions/subagents.ts", source: "project", scope: "project", origin: "top-level" },
      handlers: new Map([["session_start", [handler]]]), tools: new Map([["subagent", { definition: { execute } }]]),
      commands: new Map([["review", { handler: command }]]), shortcuts: new Map(), messageRenderers: new Map(), entryRenderers: new Map(),
    };
    const result = attributeExtensions({ extensions: [extension as any], errors: [], runtime: {} as any });
    await result.extensions[0]!.handlers.get("session_start")![0]!();
    const attributedTool = result.extensions[0]!.tools.get("subagent")!;
    const attributedCommand = result.extensions[0]!.commands.get("review")!;
    await attributedTool.definition.execute("id", {}, undefined, undefined, {} as any);
    await attributedCommand.handler("", {} as any);
    expect(seen).toHaveLength(4);
    expect(seen.every((owner) => (owner as { id: string }).id === (seen[0] as { id: string }).id)).toBe(true);
    expect(seen.every((owner) => (owner as { id: string }).id.startsWith("extension:"))).toBe(true);
    expect(JSON.stringify(seen)).not.toContain("/extensions/subagents.ts");
    expect(seen.every((owner) => (owner as { title: string; source: string }).title === "Subagents"
      && (owner as { source: string }).source === "project")).toBe(true);
    expect(attributedToolOwner(attributedTool)).toEqual(seen[0]);
    expect(attributedCommandOwner(attributedCommand)).toEqual(seen[0]);
    expect(currentExtensionOwner()).toBeUndefined();
  });
});
