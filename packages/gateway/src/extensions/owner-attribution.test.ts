import { mkdtemp, rm } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { DefaultResourceLoader, ExtensionRunner, SettingsManager } from "@earendil-works/pi-coding-agent";
import { describe, expect, it } from "vitest";
import { attributeExtensions, attributedCommandOwner, attributedToolOwner, currentExtensionOwner, extensionOwnerFor, trustedExtensionOriginKind } from "./owner-attribution.js";
import { createTronAskUserExtension, TRON_ASK_USER_INLINE_PATH } from "./tron-ask-user-extension.js";

function fakeExtension(path: string, source = "project") {
  return {
    path, resolvedPath: path,
    sourceInfo: { path, source, scope: "project", origin: "top-level" },
    handlers: new Map(), tools: new Map(), commands: new Map(), shortcuts: new Map(),
    messageRenderers: new Map(), entryRenderers: new Map(), flags: new Map(),
  };
}

function titledExtension(path: string, options: { resolvedPath?: string; baseDir?: string; source?: string } = {}) {
  const resolvedPath = options.resolvedPath ?? path;
  return {
    path, resolvedPath,
    sourceInfo: {
      path, source: options.source ?? "project", scope: "project", origin: "top-level",
      ...(options.baseDir === undefined ? {} : { baseDir: options.baseDir }),
    },
    handlers: new Map(), tools: new Map(), commands: new Map(), shortcuts: new Map(),
    messageRenderers: new Map(), entryRenderers: new Map(), flags: new Map(),
  } as any;
}

function tool(name: string) {
  return { definition: { name, execute: async () => ({ content: [] }) } };
}

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

  it.each(["display", "native_capture"])("rejects project tools that collide with Tron's reserved %s capability", (tool) => {
    const extension = {
      path: `/project/${tool}.ts`, resolvedPath: `/project/${tool}.ts`,
      sourceInfo: { path: `/project/${tool}.ts`, source: "project", scope: "project", origin: "top-level" },
      handlers: new Map(), tools: new Map([[tool, { definition: { execute: async () => ({ content: [] }) } }]]),
      commands: new Map(), shortcuts: new Map(), messageRenderers: new Map(), entryRenderers: new Map(),
    };
    expect(() => attributeExtensions({ extensions: [extension as any], errors: [], runtime: {} as any })).toThrow(`${tool} tool name is reserved`);
  });

  it("resolves finalized package provenance for callbacks and tool/command lookups", async () => {
    const seen: Array<ReturnType<typeof currentExtensionOwner>> = [];
    const capture = async () => {
      await new Promise<void>((resolve) => setTimeout(resolve, 0));
      seen.push(currentExtensionOwner());
      return { content: [] };
    };
    const extension = {
      path: "/packages/subagents/index.ts", resolvedPath: "/packages/subagents/index.ts",
      sourceInfo: { path: "/packages/subagents/index.ts", source: "local", scope: "user", origin: "top-level" },
      handlers: new Map([["session_start", [capture]]]),
      tools: new Map([["subagent", { definition: { execute: capture } }]]),
      commands: new Map([["review", { handler: capture }]]),
      shortcuts: new Map(), messageRenderers: new Map(), entryRenderers: new Map(),
    };
    const result = attributeExtensions({ extensions: [extension as any], errors: [], runtime: {} as any });
    // Mirrors the SDK's post-override assignment, not a second extension load.
    extension.sourceInfo = { ...extension.sourceInfo, source: "npm:pi-subagents" };
    const tool = result.extensions[0]!.tools.get("subagent")!;
    const command = result.extensions[0]!.commands.get("review")!;
    await result.extensions[0]!.handlers.get("session_start")![0]!();
    await tool.definition.execute("id", {}, undefined, undefined, {} as any);
    await command.handler("", {} as any);
    expect(seen).toHaveLength(3);
    expect(seen.every((owner) => owner?.source === "npm:pi-subagents")).toBe(true);
    expect(attributedToolOwner(tool)).toEqual(seen[0]);
    expect(attributedCommandOwner(command)).toEqual(seen[0]);
    expect(trustedExtensionOriginKind(seen[0]!)).toBe("subagent");
    expect(currentExtensionOwner()).toBeUndefined();
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

  it("names a project extension by its own file, not its container directory", async () => {
    // Every project extension lives in `.pi/extensions/`, so a container-derived
    // title gave every one of them the same user-visible label.
    const root = "/Users/example/workspace";
    for (const [file, expected] of [["tool.ts", "Tool"], ["subagents.ts", "Subagents"], ["tool", "Tool"]] as const) {
      const extension = titledExtension(`${root}/.pi/extensions/${file}`, { baseDir: `${root}/.pi` });
      expect(extensionOwnerFor(extension).title).toBe(expected);
    }
    // Two different project extensions must never share one title.
    const first = titledExtension(`${root}/.pi/extensions/alpha.ts`, { baseDir: `${root}/.pi` });
    const second = titledExtension(`${root}/.pi/extensions/beta.ts`, { baseDir: `${root}/.pi` });
    expect(extensionOwnerFor(first).title).not.toBe(extensionOwnerFor(second).title);
    // A container-only name is honest rather than misleading.
    expect(extensionOwnerFor(titledExtension(`${root}/.pi/extensions/index.ts`, { baseDir: `${root}/.pi` })).title).toBe("Extension");
  });

  it("keeps installed package titles and disambiguates generic entry directories", async () => {
    // A specific entry directory still wins, so installed labels do not change.
    expect(extensionOwnerFor(titledExtension(
      "/agent/npm/node_modules/pi-subagents/index.ts",
      { baseDir: "/agent/npm/node_modules/pi-subagents", source: "npm:pi-subagents" },
    )).title).toBe("Pi Subagents");
    expect(extensionOwnerFor(titledExtension(
      "/agent/git/pi-agent-browser-native/dist/extensions/agent-browser/index.js",
      { baseDir: "/agent/git/pi-agent-browser-native/dist/extensions/agent-browser", source: "npm:pi-agent-browser-native" },
    )).title).toBe("Agent Browser");
    // A package whose entry sits in a generic directory uses its package name
    // instead of colliding with every other package shaped the same way.
    expect(extensionOwnerFor(titledExtension(
      "/agent/npm/node_modules/@mocito/pi-goal/extensions/index.ts",
      { baseDir: "/agent/npm/node_modules/@mocito/pi-goal/extensions", source: "npm:@mocito/pi-goal" },
    )).title).toBe("Pi Goal");
  });

  it("attributes a shared handler function separately for each extension", async () => {
    // Two extensions can legitimately share one helper module's function. Each
    // must still receive its own attributed wrapper rather than inheriting the
    // first extension's identity.
    const seen: Array<ReturnType<typeof currentExtensionOwner>> = [];
    const shared = async () => { seen.push(currentExtensionOwner()); };
    const first = fakeExtension("/extensions/first.ts", "package-one");
    const second = fakeExtension("/extensions/second.ts", "package-two");
    attributeExtensions({ extensions: [first as any, second as any], errors: [], runtime: {} as any });
    for (const extension of [first, second]) {
      const list = extension.handlers.get("session_start") ?? [];
      list.push(shared);
      extension.handlers.set("session_start", list);
    }
    await first.handlers.get("session_start")![0]!({}, {} as any);
    await second.handlers.get("session_start")![0]!({}, {} as any);
    expect(seen).toHaveLength(2);
    expect(seen[0]?.source).toBe("package-one");
    expect(seen[1]?.source).toBe("package-two");
    expect(seen[0]?.id).not.toBe(seen[1]?.id);
  });

  it("admits tools registered after load through the same boundary", async () => {
    const extension = fakeExtension("/extensions/late.ts");
    attributeExtensions({ extensions: [extension as any], errors: [], runtime: {} as any });
    // This is exactly what the SDK's registerTool() does after load.
    extension.tools.set("late_tool", tool("late_tool") as any);
    const admitted = extension.tools.get("late_tool")!;
    expect(attributedToolOwner(admitted)).toMatchObject({ source: "project" });
    await admitted.definition.execute();
    expect(attributedCommandOwner).toBeTypeOf("function");
  });

  it("rejects reserved first-party tool names registered after load", () => {
    const extension = fakeExtension("/extensions/late-hostile.ts");
    const firstParty = fakeExtension(TRON_ASK_USER_INLINE_PATH);
    firstParty.tools.set("ask_user", tool("ask_user") as any);
    attributeExtensions({ extensions: [extension as any, firstParty as any], errors: [], runtime: {} as any }, undefined, { requireTronAskUser: true });
    for (const name of ["bash", "notify", "display", "native_capture", "computer"]) {
      expect(() => extension.tools.set(name, tool(name) as any)).toThrow(/reserved/);
      expect(extension.tools.has(name)).toBe(false);
    }
    expect(() => extension.tools.set("ask_user", tool("ask_user") as any)).toThrow(/ask_user tool name is reserved/);
    expect(extension.tools.has("ask_user")).toBe(false);
  });

  it("keeps a reserved name available to its exact first-party inline owner after load", () => {
    const firstParty = fakeExtension("<inline:tron-notify>");
    attributeExtensions({ extensions: [firstParty as any], errors: [], runtime: {} as any });
    expect(() => firstParty.tools.set("notify", tool("notify") as any)).not.toThrow();
    expect(firstParty.tools.has("notify")).toBe(true);
  });

  it("does not double-wrap a handler registered repeatedly", async () => {
    const seen: Array<ReturnType<typeof currentExtensionOwner>> = [];
    const handler = async () => { seen.push(currentExtensionOwner()); };
    const extension = fakeExtension("/extensions/repeat.ts");
    attributeExtensions({ extensions: [extension as any], errors: [], runtime: {} as any });
    // `on()` re-sets the whole list for the event each time it is called.
    for (let index = 0; index < 3; index += 1) {
      const list = extension.handlers.get("session_start") ?? [];
      list.push(handler);
      extension.handlers.set("session_start", list);
    }
    const stored = extension.handlers.get("session_start")!;
    expect(stored).toHaveLength(3);
    for (const registered of stored) await registered({}, {} as any);
    // One invocation per registration, each inside the owner context.
    expect(seen).toHaveLength(3);
    expect(seen.every((owner) => owner?.source === "project")).toBe(true);
  });

  it("attributes a tool registered during session_start and refuses a late reserved name", async () => {
    const root = await mkdtemp(join(tmpdir(), "tron-admission-"));
    try {
      const lateFailures: string[] = [];
      const loader = new DefaultResourceLoader({
        cwd: root, agentDir: root, settingsManager: SettingsManager.inMemory(),
        noExtensions: true, noSkills: true, noPromptTemplates: true, noThemes: true, noContextFiles: true,
        extensionFactories: [{
          name: "late-registration",
          factory(pi: any) {
            pi.on("session_start", async () => {
              pi.registerTool({ name: "late_probe", description: "probe", parameters: { type: "object", properties: {} } });
              for (const reserved of ["bash", "ask_user"]) {
                try { pi.registerTool({ name: reserved, description: "hostile", parameters: { type: "object", properties: {} } }); }
                catch (error) { lateFailures.push((error as Error).message); }
              }
            });
          },
        }, { name: "tron-ask-user", factory: createTronAskUserExtension() }],
        extensionsOverride(base) { return attributeExtensions(base, undefined, { requireTronAskUser: true }); },
      });
      await loader.reload();
      const loaded = loader.getExtensions();
      const foreign = loaded.extensions.find((extension) => extension.path === "<inline:late-registration>")!;
      for (const handler of foreign.handlers.get("session_start") ?? []) await handler({}, {} as any);

      // A non-reserved late tool is admitted with its real owner.
      expect(attributedToolOwner(foreign.tools.get("late_probe"))).toMatchObject({ source: "inline" });
      // Reserved late registrations fail closed and are never stored.
      expect(foreign.tools.has("bash")).toBe(false);
      expect(foreign.tools.has("ask_user")).toBe(false);
      expect(lateFailures).toHaveLength(2);
      // Tron's first-party capability still owns the tool name. Pi selects the
      // first registration per name in load order, where packages precede
      // inline extensions, so an admitted foreign late tool would win here.
      const runner = new ExtensionRunner(loaded.extensions, loaded.runtime, root, {} as any, {} as any);
      const winner = runner.getAllRegisteredTools().find((registered) => registered.definition.name === "ask_user");
      expect(winner).toBe(loaded.extensions.find((extension) => extension.path === TRON_ASK_USER_INLINE_PATH)!.tools.get("ask_user"));
    } finally {
      await rm(root, { recursive: true, force: true });
    }
  });
});
