import { createTestRegistry } from "../../../test-support/gateway-registry.js";
import { mkdir, mkdtemp, realpath, rm, stat, writeFile } from "node:fs/promises";
import { createRequire } from "node:module";
import { tmpdir } from "node:os";
import { dirname, join } from "node:path";
import { performance } from "node:perf_hooks";
import { ModelRuntime } from "@earendil-works/pi-coding-agent";
import { expect, it } from "vitest";
import { TrustService } from "../resources/trust-service.js";
import { ManagedSubagents, MANAGED_SUBAGENTS_SOURCE } from "./managed-subagents.js";
import { delegatedArtifactRoot, delegatedProviderEnvironment, DELEGATED_PROVIDER_ROOT_ENV } from "./delegated-provider.js";
import type { RuntimeRegistry } from "../session/runtime-registry.js";

/** Real Gateway session starts from a fresh install root, so the closure's
 * TypeScript has never been transformed for this build. */
it("starts managed-subagent sessions from a fresh build without transforming TypeScript on the Gateway thread", async () => {
  const root = await mkdtemp(join(tmpdir(), "tron-subagent-transform-"));
  const agentDir = join(root, "agent");
  const tronHome = join(root, "tron");
  const previous = { agentDir: process.env.PI_CODING_AGENT_DIR, providerRoot: process.env[DELEGATED_PROVIDER_ROOT_ENV] };
  let registry: RuntimeRegistry | undefined;
  // The longest stretch this thread could not run a 10 ms timer, sampled across
  // every session start. Reported, not asserted: the transform count below is the oracle.
  let last = performance.now();
  let longestStallMs = 0;
  const sampler = setInterval(() => { const now = performance.now(); longestStallMs = Math.max(longestStallMs, now - last - 10); last = now; }, 10);
  try {
    const workspaces = [join(root, "first"), join(root, "second")];
    await Promise.all([mkdir(agentDir), ...workspaces.map(cwd => mkdir(cwd))]);
    await writeFile(join(agentDir, "settings.json"), "{}");
    process.env.PI_CODING_AGENT_DIR = agentDir;
    delegatedProviderEnvironment(delegatedArtifactRoot(tronHome));
    const managedSubagents = ManagedSubagents.activateForStartup(tronHome);
    // jiti requires its Babel transform only for a module it has not cached.
    // The closure's jiti and its transform belong to this fresh root alone.
    const closureRequire = createRequire(join(managedSubagents.root, "package.json"));
    const transform = join(dirname(await realpath(closureRequire.resolve("jiti/package.json"))), "dist", "babel.cjs");
    expect((await stat(transform)).isFile()).toBe(true);
    const trust = new TrustService(agentDir);
    for (const cwd of workspaces) await trust.set(cwd, true);
    registry = await createTestRegistry({
      agentDir, tronHome, managedSubagents, trust, idleRuntimeMs: 60_000,
      modelRuntimeFactory: async () => ModelRuntime.create({ modelsPath: null, refreshOnCreate: false }),
      broadcast: () => {}, sessionSummaryChanged: () => {}, sessionListChanged: () => {},
    });
    await registry.initialize();
    for (const cwd of workspaces) {
      const slot = await registry.create(cwd);
      const resources = await slot.resources() as { tools: Array<{ name: string; source?: string }> };
      expect(resources.tools.find(tool => tool.name === "subagent"), "the managed factory ran").toMatchObject({ source: MANAGED_SUBAGENTS_SOURCE });
      expect(closureRequire.cache[transform], "no Babel transform loaded on the Gateway thread").toBeUndefined();
    }
    // The build's transforms persist privately beside its verified root.
    const cache = await stat(join(dirname(managedSubagents.root), `${managedSubagents.root.split("/").at(-1)}.transform-cache`));
    expect(cache.isDirectory() && (cache.mode & 0o777)).toBe(0o700);
  } finally {
    clearInterval(sampler);
    await registry?.dispose();
    for (const [name, value] of [["PI_CODING_AGENT_DIR", previous.agentDir], [DELEGATED_PROVIDER_ROOT_ENV, previous.providerRoot]] as const) {
      if (value === undefined) delete process.env[name]; else process.env[name] = value;
    }
    const report = process.env.TRON_SUBAGENT_TRANSFORM_REPORT;
    if (report) await writeFile(report, JSON.stringify({ longestStallMs: Math.round(longestStallMs) }) + "\n");
    await rm(root, { recursive: true, force: true });
  }
}, 180_000);
