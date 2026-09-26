import { mkdir, mkdtemp } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { afterEach, describe, expect, it } from "vitest";
import { TrustService } from "../admin/trust-service.js";
import { RuntimeRegistry } from "./runtime-registry.js";
import { TRON_MODULES } from "../extensions/tron-modules.js";

/** The registered module names of one real session, without the SDK's inline path form. */
function inlineModuleNames(resources: Record<string, any>): string[] {
  return resources.extensions
    .filter((extension: any) => extension.source === "inline")
    .map((extension: any) => String(extension.name).replace(/^<inline:/, "").replace(/>$/, ""))
    .filter((name: string) => !name.startsWith("tron-mcp-"));
}

describe.sequential("RuntimeSlot Tron module registration", () => {
  const previousAgentDir = process.env.PI_CODING_AGENT_DIR;
  const registries: RuntimeRegistry[] = [];

  afterEach(async () => {
    await Promise.all(registries.splice(0).map((registry) => registry.dispose()));
    if (previousAgentDir === undefined) delete process.env.PI_CODING_AGENT_DIR;
    else process.env.PI_CODING_AGENT_DIR = previousAgentDir;
  });

  it("registers only defined Tron modules, in definition order", async () => {
    const root = await mkdtemp(join(tmpdir(), "tron-module-registration-"));
    const agentDir = join(root, "agent");
    const cwd = join(root, "workspace");
    await Promise.all([mkdir(agentDir), mkdir(cwd)]);
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
    const registered = inlineModuleNames(slot.resources() as Record<string, any>);
    const definitionNames = TRON_MODULES.map((tronModule) => tronModule.name);
    const undefinedModules = registered.filter((name) => !definitionNames.includes(name));
    // A module the runtime registers but the definition does not is exactly the drift
    // `modules.list` would report wrongly; a name is the whole identity here.
    expect(undefinedModules).toEqual([]);
    const positions = registered.map((name) => definitionNames.indexOf(name));
    expect(positions).toEqual([...positions].sort((left, right) => left - right));
    expect(registered).toEqual(expect.arrayContaining([
      "tron-context-window",
      "tron-compaction-policy",
      "tron-core",
      "tron-ask-user",
      "tron-display",
    ]));
    // This host injects no live-view, automation or notification owner, so the
    // definition's owner-gated modules stay out. tron-computer follows the host platform.
    for (const name of ["tron-native-capture", "tron-schedule", "tron-notify"]) {
      expect(registered).not.toContain(name);
    }
    expect(registered.includes("tron-computer")).toBe(process.platform === "darwin");
  });
});
