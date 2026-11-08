import { spawnSync } from "node:child_process";
import { mkdir, realpath, writeFile } from "node:fs/promises";
import { dirname, join } from "node:path";
import { afterEach, describe, expect, it } from "vitest";
import { startLockGateway, type LockGateway } from "../../../test-support/gateway-lock-harness.js";

/**
 * Project-root resources lock (packages/gateway/docs/scenario-locks.md#locks; K-0 §7 E0e follow-up)
 * for the two session-free `projectDir` call sites `project-root-trust` does not
 * reach: the package owner (`packages.list`, `admin/package-service.ts`) and the
 * session-free extension loader behind `hooks.list`
 * (`admin/session-free-extensions.ts`). Through the real Gateway with the
 * production owners (harness option `administrativeResources`), a phone lists
 * packages and hooks for a subdirectory of a Git project whose root and
 * subdirectory each configure a package and a project extension, before and
 * after trusting the project. Both reads resolve the subdirectory to the root's
 * Project layer: the root's package and extension, never the subdirectory's.
 */

const gateways: LockGateway[] = [];
afterEach(async () => { await Promise.all(gateways.splice(0).map((gateway) => gateway.dispose())); });

function git(cwd: string, ...args: string[]): void {
  const result = spawnSync("git", ["-C", cwd, ...args], {
    encoding: "utf8",
    env: { ...process.env, GIT_CONFIG_GLOBAL: "/dev/null", GIT_CONFIG_NOSYSTEM: "1" },
  });
  if (result.status !== 0) throw new Error(`git ${args.join(" ")}: ${result.stderr}`);
}

async function write(path: string, text: string): Promise<void> {
  await mkdir(dirname(path), { recursive: true });
  await writeFile(path, text);
}

/** An extension with one tool and one event handler, named for its scope. */
const extension = (tool: string) => `
export default function (pi) {
  pi.registerTool({
    name: ${JSON.stringify(tool)}, label: ${JSON.stringify(tool)}, description: "Lock project resource",
    parameters: { type: "object", properties: {} },
    execute: async () => ({ content: [{ type: "text", text: "ok" }], details: {} }),
  });
  pi.on("tool_call", () => {});
}
`;

/** A local package that provides one extension. */
async function localPackage(directory: string, name: string, tool: string): Promise<void> {
  await write(join(directory, "package.json"), JSON.stringify({ name, version: "1.0.0", pi: { extensions: ["extensions"] } }));
  await write(join(directory, "extensions", `${name}.ts`), extension(tool));
}

describe("gateway/session-catalog project-root resources lock", () => {
  it("project-root-resources: packages and hooks listed for a subdirectory come from the project root", async () => {
    const gateway = await startLockGateway("project-root-resources", { administrativeResources: true });
    gateways.push(gateway);
    // Trust and the SDK name canonical paths; the temp root is a symlink on macOS.
    const root = await realpath(gateway.root);
    const project = join(root, "project");
    const nested = join(project, "packages", "app");
    await write(join(project, ".pi", "settings.json"), `${JSON.stringify({ packages: ["../vendor/root-package"] })}\n`);
    await localPackage(join(project, "vendor", "root-package"), "root-package", "root_package_tool");
    await write(join(project, ".pi", "extensions", "root-hooks.ts"), extension("root_project_tool"));
    await write(join(nested, ".pi", "settings.json"), `${JSON.stringify({ packages: ["../vendor/nested-package"] })}\n`);
    await localPackage(join(nested, "vendor", "nested-package"), "nested-package", "nested_package_tool");
    await write(join(nested, ".pi", "extensions", "nested-hooks.ts"), extension("nested_project_tool"));
    git(project, "init", "-q");

    const phone = await gateway.connect("phone");
    const packagesUntrusted = await phone.request("packages.list", { cwd: nested });
    const hooksUntrusted = await phone.request("hooks.list", { cwd: nested });
    const decided = await phone.request("settings.change", {
      commandId: gateway.commandId(), target: { kind: "global" }, reason: "Trust the lock project",
      changes: [{ key: "permissions.projectTrust", layer: "global", op: "set", value: true, qualifiers: { project: nested } }],
    });
    expect(decided.ok, JSON.stringify(decided)).toBe(true);
    const packagesTrusted = await phone.request("packages.list", { cwd: nested });
    const hooksTrusted = await phone.request("hooks.list", { cwd: nested });
    const hooksGlobal = await phone.request("hooks.list", {});

    for (const response of [packagesUntrusted, hooksUntrusted, packagesTrusted, hooksTrusted, hooksGlobal]) {
      expect(response.ok, JSON.stringify(response)).toBe(true);
    }
    // Untrusted: no Project packages or resources at all.
    expect(packagesUntrusted.result).toMatchObject({ packages: [], resources: { extensions: [], prompts: [], skills: [], themes: [] } });
    // Trusted: the root's package and extension, never the subdirectory's.
    const rootPackage = join(project, "vendor", "root-package");
    expect(packagesTrusted.result.packages).toEqual([{ filtered: false, installedPath: rootPackage, scope: "project", source: "../vendor/root-package",
      provides: { commands: [], prompts: [], skills: [], subagents: [], themes: [], tools: ["root_package_tool"] } }]);
    expect(packagesTrusted.result.resources.extensions.map((extension: { path: string }) => extension.path))
      .toEqual([join(project, ".pi", "extensions", "root-hooks.ts"), join(rootPackage, "extensions", "root-package.ts")]);
    // Each extension as `name scope source origin [tools] (commands) {handler×count}`.
    const hooks = (response: { result?: any }) => response.result.extensions.map((extension: { name: string; scope: string; source: string; origin: string;
      tools: string[]; commands: string[]; handlers: Array<{ event: string; count: number }> }) =>
      `${extension.name} ${extension.scope} ${extension.source} ${extension.origin} [${extension.tools.join(",")}] (${extension.commands.join(",")}) {${extension.handlers.map((handler) => `${handler.event}×${handler.count}`).join(",")}}`);
    const builtins = ["builtin:codemode temporary builtin top-level [codemode] () {}", "builtin:tool-search temporary builtin top-level [tool_search] () {}",
      "builtin:mcp temporary builtin top-level [] (mcp) {session_start×1,before_agent_start×1,tool_call×1,turn_start×1,mcp_servers_change×1,session_shutdown×1}"];
    expect(hooks(hooksUntrusted)).toEqual(builtins);
    expect(hooks(hooksTrusted)).toEqual(["root-hooks.ts project auto top-level [root_project_tool] () {tool_call×1}",
      "root-package.ts project ../vendor/root-package package [root_package_tool] () {tool_call×1}", ...builtins]);
    for (const response of [hooksUntrusted, hooksTrusted, hooksGlobal]) {
      expect(response.result).toMatchObject({ extensionLoadErrors: [], extensionLoadWarnings: [] });
      const total = response.result.extensions.length;
      expect(response.result.hookInventory).toMatchObject({ encodedBytesLimit: 262_144, textFieldsOmitted: 0, extensions: { omitted: 0, retained: total, total } });
    }
    expect(hooksTrusted.result.extensions[0]).toMatchObject({ path: join(project, ".pi", "extensions", "root-hooks.ts") });
    expect(hooks(hooksGlobal)).toEqual(builtins);
  }, 60_000);
});
