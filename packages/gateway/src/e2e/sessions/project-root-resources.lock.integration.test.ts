import { spawnSync } from "node:child_process";
import { mkdir, realpath, writeFile } from "node:fs/promises";
import { dirname, join } from "node:path";
import { afterEach, describe, expect, it } from "vitest";
import { startLockGateway, type LockGateway } from "../../../test-support/gateway-lock-harness.js";

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

async function localPackage(directory: string, name: string, tool: string): Promise<void> {
  await write(join(directory, "package.json"), JSON.stringify({ name, version: "1.0.0", pi: { extensions: ["extensions"] } }));
  await write(join(directory, "extensions", `${name}.ts`), extension(tool));
}

describe("gateway/session-catalog project-root resources lock", () => {
  it("project-root-resources: packages listed for a subdirectory come from the project root", async () => {
    const gateway = await startLockGateway("project-root-resources", { administrativeResources: true });
    gateways.push(gateway);
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
    const decided = await phone.request("settings.change", {
      commandId: gateway.commandId(), target: { kind: "global" }, reason: "Trust the lock project",
      changes: [{ key: "permissions.projectTrust", layer: "global", op: "set", value: true, qualifiers: { project: nested } }],
    });
    expect(decided.ok, JSON.stringify(decided)).toBe(true);
    const packagesTrusted = await phone.request("packages.list", { cwd: nested });

    for (const response of [packagesUntrusted, packagesTrusted]) {
      expect(response.ok, JSON.stringify(response)).toBe(true);
    }
    expect(packagesUntrusted.result).toMatchObject({ packages: [], resources: { extensions: [], prompts: [], skills: [], themes: [] } });
    const rootPackage = join(project, "vendor", "root-package");
    expect(packagesTrusted.result.packages).toEqual([{ filtered: false, installedPath: rootPackage, scope: "project", source: "../vendor/root-package",
      provides: { commands: [], prompts: [], skills: [], subagents: [], themes: [], tools: ["root_package_tool"] } }]);
    expect(packagesTrusted.result.resources.extensions.map((extension: { path: string }) => extension.path))
      .toEqual([join(project, ".pi", "extensions", "root-hooks.ts"), join(rootPackage, "extensions", "root-package.ts")]);
  }, 60_000);
});
