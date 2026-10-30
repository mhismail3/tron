import { reviewedRequest } from "../../test-support/native-change.js";
import { spawnSync } from "node:child_process";
import { mkdir, realpath, writeFile } from "node:fs/promises";
import { dirname, join } from "node:path";
import { afterEach, describe, expect, it } from "vitest";
import { startLockGateway, type LockGateway } from "../../test-support/gateway-lock-harness.js";
import { compareWithGolden, lockPaths, lockUpdateRequested, normalizeTraceValue, type TraceValue } from "../../test-support/scenario-lock.js";

/**
 * Project-root resources lock (restructure plan §6.4, V3; K-0 §7 E0e follow-up)
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

const MODULE = "gateway/session-catalog";
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
    const decided = await reviewedRequest(phone, "settings.change", {
      commandId: gateway.commandId(), target: { kind: "global" }, reason: "Trust the lock project",
      changes: [{ key: "permissions.projectTrust", layer: "global", op: "set", value: true, qualifiers: { project: nested } }],
    }, () => gateway.commandId());
    expect(decided.ok, JSON.stringify(decided)).toBe(true);
    const packagesTrusted = await phone.request("packages.list", { cwd: nested });
    const hooksTrusted = await phone.request("hooks.list", { cwd: nested });
    const hooksGlobal = await phone.request("hooks.list", {});

    const recorded = gateway.record();
    const trace = {
      lock: "project-root-resources",
      // Responses are recorded once, under `observed`.
      requests: recorded.exchanges.map((entry) => { const { response: _response, ...request } = entry as Record<string, TraceValue>; return request; }),
      // The hook inventory's encoded size counts the host's temp paths, so it is blinded.
      observed: normalizeTraceValue(JSON.parse(JSON.stringify({ packagesUntrusted, hooksUntrusted, packagesTrusted, hooksTrusted, hooksGlobal }),
        (key, value: unknown) => key === "encodedBytes" ? "<bytes>" : value) as TraceValue, gateway.normalization),
    };
    await compareWithGolden({
      module: MODULE, ...lockPaths(import.meta.url, trace.lock), trace, update: lockUpdateRequested(MODULE),
      validate: () => {
        for (const response of [packagesUntrusted, hooksUntrusted, packagesTrusted, hooksTrusted, hooksGlobal]) {
          expect(response.ok, JSON.stringify(response)).toBe(true);
        }
        const packages = JSON.stringify(packagesTrusted.result);
        expect(packages).toContain("root-package");
        expect(packages).toContain("root_package_tool");
        expect(packages).not.toContain("nested-package");
        const hooks = JSON.stringify(hooksTrusted.result);
        expect(hooks).toContain("root-hooks.ts");
        expect(hooks).toContain("root-package");
        expect(hooks).not.toContain("nested");
        expect(JSON.stringify(hooksUntrusted.result)).not.toContain("root-hooks.ts");
        expect(JSON.stringify(hooksGlobal.result)).not.toContain("root-hooks.ts");
      },
    });
  }, 60_000);
});
