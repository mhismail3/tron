import { existsSync } from "node:fs";
import { mkdir, mkdtemp, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { describe, expect, it } from "vitest";
import { GatewayWorkRegistry } from "../sessions/gateway-work-registry.js";
import { HookResources } from "./hook-resources.js";
import { TrustService } from "./trust-service.js";

/** A loadable extension: one tool plus a session_start side effect. The side
 * effect proves whether anything actually ran a session. */
function extensionSource(tool: string, marker: string): string {
  return `import { writeFileSync } from "node:fs";\nexport default function (pi) {\n  pi.registerTool({ name: "${tool}", label: "${tool}", description: "Probe", parameters: { type: "object", properties: {} }, execute: async () => ({ content: [{ type: "text", text: "ok" }] }) });\n  pi.on("session_start", async () => { writeFileSync(${JSON.stringify(marker)}, "started"); });\n}\n`;
}

async function fixture() {
  const root = await mkdtemp(join(tmpdir(), "tron-hook-resources-"));
  const agentDir = join(root, "agent");
  const cwd = join(root, "project");
  await Promise.all([
    mkdir(join(agentDir, "extensions"), { recursive: true }),
    mkdir(join(cwd, ".pi", "extensions"), { recursive: true }),
  ]);
  const marker = join(root, "session-started");
  await Promise.all([
    writeFile(join(agentDir, "extensions", "global-probe.ts"), extensionSource("global_probe", marker)),
    writeFile(join(cwd, ".pi", "extensions", "project-probe.ts"), extensionSource("project_probe", marker)),
  ]);
  const trust = new TrustService(agentDir);
  const workRegistry = new GatewayWorkRegistry();
  return {
    root,
    cwd,
    marker,
    trust,
    workRegistry,
    hookResources: new HookResources(agentDir, trust, workRegistry),
  };
}

describe("session-free hook listing", () => {
  it("lists only user-scope hooks while the project is untrusted", async () => {
    const value = await fixture();
    const projection = await value.hookResources.list(value.cwd);
    expect(projection.extensions.map((extension: any) => extension.name)).toEqual(["global-probe.ts"]);
    expect(projection.extensions[0]).toMatchObject({ scope: "user", source: "auto", tools: ["global_probe"] });
    expect(projection.hookInventory.extensions.total).toBe(1);
    expect(value.marker).toBeDefined();
  });

  it("loads project extensions once the project is trusted, without running a session", async () => {
    const value = await fixture();
    await value.trust.set(value.cwd, true);
    const projection = await value.hookResources.list(value.cwd);
    const names = projection.extensions.map((extension: any) => extension.name);
    expect(names).toEqual(expect.arrayContaining(["global-probe.ts", "project-probe.ts"]));
    expect(projection.extensions).toEqual(expect.arrayContaining([
      expect.objectContaining({
        name: "project-probe.ts",
        scope: "project",
        source: "auto",
        tools: ["project_probe"],
        handlers: [{ event: "session_start", count: 1 }],
      }),
    ]));
    // The handler was loaded, so the projection can report it, but nothing ran it.
    expect(existsSync(value.marker)).toBe(false);
    expect(value.workRegistry.size).toBe(0);
  });

  it("reports global hooks only when no project scope is requested", async () => {
    const value = await fixture();
    await value.trust.set(value.cwd, true);
    const projection = await value.hookResources.list();
    expect(projection.extensions.map((extension: any) => extension.name)).toEqual(["global-probe.ts"]);
  });

  it("returns exactly the session.resources hook fields within their envelope", async () => {
    const value = await fixture();
    const projection = await value.hookResources.list(value.cwd);
    expect(Object.keys(projection).sort()).toEqual(["extensionLoadErrors", "extensions", "hookInventory"]);
    expect(projection.hookInventory.encodedBytes).toBeLessThanOrEqual(projection.hookInventory.encodedBytesLimit);
    expect(projection.hookInventory.encodedBytes).toBeGreaterThan(0);
  });

  it("reports an unloadable extension as a load error rather than a hook row", async () => {
    const value = await fixture();
    await value.trust.set(value.cwd, true);
    await writeFile(join(value.cwd, ".pi", "extensions", "broken.ts"), "export default function () { throw new Error(\"broken probe\"); }\n");
    const projection = await value.hookResources.list(value.cwd);
    expect(projection.extensions.map((extension: any) => extension.name)).not.toContain("broken.ts");
    expect(projection.extensionLoadErrors).toHaveLength(1);
    expect(projection.extensionLoadErrors[0]!.path).toContain("broken.ts");
    expect(projection.hookInventory.loadErrors.total).toBe(1);
  });

  it("rejects a project scope that does not exist", async () => {
    const value = await fixture();
    await expect(value.hookResources.list(join(value.root, "missing"))).rejects.toMatchObject({ code: "invalid_request" });
    expect(value.workRegistry.size).toBe(0);
  });
});
