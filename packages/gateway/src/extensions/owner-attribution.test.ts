import { describe, expect, it } from "vitest";
import { attributeExtensions, currentExtensionOwner } from "./owner-attribution.js";

describe("extension owner attribution", () => {
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
    const extension = {
      path: "/extensions/subagents.ts", resolvedPath: "/extensions/subagents.ts",
      sourceInfo: { path: "/extensions/subagents.ts", source: "project", scope: "project", origin: "top-level" },
      handlers: new Map([["session_start", [handler]]]), tools: new Map([["subagent", { definition: { execute } }]]),
      commands: new Map(), shortcuts: new Map(), messageRenderers: new Map(), entryRenderers: new Map(),
    };
    const result = attributeExtensions({ extensions: [extension as any], errors: [], runtime: {} as any });
    await result.extensions[0]!.handlers.get("session_start")![0]!();
    await result.extensions[0]!.tools.get("subagent")!.definition.execute("id", {}, undefined, undefined, {} as any);
    expect(seen).toEqual([
      { id: "/extensions/subagents.ts", title: "Subagents", source: "project" },
      { id: "/extensions/subagents.ts", title: "Subagents", source: "project" },
      { id: "/extensions/subagents.ts", title: "Subagents", source: "project" },
    ]);
    expect(currentExtensionOwner()).toBeUndefined();
  });
});
