import { mkdir, mkdtemp, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { afterEach, describe, expect, it } from "vitest";
import { RuntimeRegistry } from "../sessions/runtime-registry.js";
import { HookResources } from "./hook-resources.js";
import { TrustService } from "./trust-service.js";

/** The same project extension must project identically for a live session and
 * for the session-free hook read, so iOS can decode one shape. */
describe.sequential("hook listing against a live session's resources", () => {
  const previousAgentDir = process.env.PI_CODING_AGENT_DIR;
  const registries: RuntimeRegistry[] = [];

  afterEach(async () => {
    await Promise.all(registries.splice(0).map((registry) => registry.dispose()));
    if (previousAgentDir === undefined) delete process.env.PI_CODING_AGENT_DIR;
    else process.env.PI_CODING_AGENT_DIR = previousAgentDir;
  });

  it("projects the same extension row as session.resources", async () => {
    const root = await mkdtemp(join(tmpdir(), "tron-hook-parity-"));
    const agentDir = join(root, "agent");
    const cwd = join(root, "workspace");
    await Promise.all([mkdir(agentDir), mkdir(join(cwd, ".pi", "extensions"), { recursive: true })]);
    await writeFile(join(cwd, ".pi", "extensions", "project-probe.ts"), `export default function (pi) {\n  pi.registerTool({ name: "project_probe", label: "Project probe", description: "Probe", parameters: { type: "object", properties: {} }, execute: async () => ({ content: [{ type: "text", text: "ok" }] }) });\n  pi.on("session_start", () => {});\n  pi.on("tool_call", () => {});\n}\n`);
    process.env.PI_CODING_AGENT_DIR = agentDir;
    const trust = new TrustService(agentDir);
    await trust.set(cwd, true);
    const registry = new RuntimeRegistry({
      agentDir,
      tronHome: join(root, "tron"),
      idleRuntimeMs: 60_000,
      trust,
      broadcast: () => {},
      sessionSummaryChanged: () => {},
      sessionListChanged: () => {},
    });
    registries.push(registry);
    await registry.initialize();
    const slot = await registry.create(cwd);

    const liveResources = await slot.resources() as any;
    const sessionRow = liveResources.extensions.find((extension: any) => extension.name === "project-probe.ts");
    expect(sessionRow).toBeDefined();

    const projection = await new HookResources(agentDir, trust).list(cwd);
    expect(projection.extensions).toEqual(liveResources.extensions.filter((extension: any) =>
      extension.source === "builtin" || extension.name === "project-probe.ts"));
    expect(projection.extensionLoadErrors).toEqual([]);
    expect(projection.extensionLoadWarnings).toEqual([]);
    expect(projection.hookInventory.extensions).toEqual({ total: 4, retained: 4, omitted: 0 });
    expect(projection.hookInventory.handlerEvents.retained).toBe(projection.hookInventory.handlerEvents.total);
    expect(projection.hookInventory.handlerEvents.omitted).toBe(0);
  });
});
