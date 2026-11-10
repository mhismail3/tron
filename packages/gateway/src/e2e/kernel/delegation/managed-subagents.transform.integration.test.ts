import { createTestRegistry } from "../../../../test-support/gateway-registry.js";
import { chmod, mkdir, mkdtemp, readdir, realpath, rm, stat, writeFile } from "node:fs/promises";
import { createRequire } from "node:module";
import { tmpdir } from "node:os";
import { dirname, join } from "node:path";
import { performance } from "node:perf_hooks";
import { ModelRuntime } from "@earendil-works/pi-coding-agent";
import { expect, it } from "vitest";
import { TrustService } from "../../../kernel/resources/trust-service.js";
import { ManagedSubagents, MANAGED_SUBAGENTS_SOURCE } from "../../../kernel/delegation/managed-subagents.js";
import { delegatedArtifactRoot, delegatedProviderEnvironment, DELEGATED_PROVIDER_ROOT_ENV } from "../../../kernel/delegation/delegated-provider.js";
import type { RuntimeRegistry } from "../../../kernel/session/runtime-registry.js";

it("starts managed-subagent sessions from a fresh build without transforming TypeScript on the Gateway thread", async () => {
  const root = await mkdtemp(join(tmpdir(), "tron-subagent-transform-"));
  const agentDir = join(root, "agent");
  const tronHome = join(root, "tron");
  const previous = { agentDir: process.env.PI_CODING_AGENT_DIR, providerRoot: process.env[DELEGATED_PROVIDER_ROOT_ENV] };
  let registry: RuntimeRegistry | undefined;
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
    const cache = await stat(join(tronHome, "internal", "pi-subagents-transform-cache", managedSubagents.root.split("/").at(-1)!));
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

it("refuses a managed load whose transforms could not be prepared instead of transforming on the Gateway thread", async () => {
  const root = await mkdtemp(join(tmpdir(), "tron-subagent-transform-refusal-"));
  const tronHome = join(root, "tron");
  const previous = process.env[DELEGATED_PROVIDER_ROOT_ENV];
  const cache = join(tronHome, "internal", "pi-subagents-transform-cache");
  try {
    delegatedProviderEnvironment(delegatedArtifactRoot(tronHome));
    const managedSubagents = ManagedSubagents.activateForStartup(tronHome);
    const closureRequire = createRequire(join(managedSubagents.root, "package.json"));
    const transform = join(dirname(await realpath(closureRequire.resolve("jiti/package.json"))), "dist", "babel.cjs");
    const buildCache = join(cache, managedSubagents.root.split("/").at(-1)!);
    await mkdir(buildCache, { recursive: true, mode: 0o700 });
    await chmod(buildCache, 0o500);
    await expect(managedSubagents.loadDiscovery()).rejects.toMatchObject({ code: "busy", retryable: true });
    expect(closureRequire.cache[transform], "no Babel transform loaded on the Gateway thread").toBeUndefined();
    await chmod(buildCache, 0o700);
    await expect(managedSubagents.loadDiscovery()).resolves.toMatchObject({ discoverAgentsAll: expect.any(Function) });
    expect(closureRequire.cache[transform]).toBeUndefined();
  } finally {
    await chmod(join(cache), 0o700).catch(() => {});
    if (previous === undefined) delete process.env[DELEGATED_PROVIDER_ROOT_ENV]; else process.env[DELEGATED_PROVIDER_ROOT_ENV] = previous;
    await rm(root, { recursive: true, force: true });
  }
}, 180_000);

it("prepares only the catalog's own module graph for a discovery read, not the whole build a session needs", async () => {
  const root = await mkdtemp(join(tmpdir(), "tron-subagent-transform-discovery-"));
  const tronHome = join(root, "tron");
  const previous = process.env[DELEGATED_PROVIDER_ROOT_ENV];
  try {
    delegatedProviderEnvironment(delegatedArtifactRoot(tronHome));
    const managedSubagents = ManagedSubagents.activateForStartup(tronHome);
    const closureRequire = createRequire(join(managedSubagents.root, "package.json"));
    const transform = join(dirname(await realpath(closureRequire.resolve("jiti/package.json"))), "dist", "babel.cjs");
    const buildCache = join(tronHome, "internal", "pi-subagents-transform-cache", managedSubagents.root.split("/").at(-1)!);
    await expect(managedSubagents.loadDiscovery()).resolves.toMatchObject({ discoverAgentsAll: expect.any(Function) });
    const discoveryTransforms = (await readdir(buildCache)).length;
    expect(discoveryTransforms).toBeGreaterThan(0);
    expect(closureRequire.cache[transform], "no Babel transform loaded on the Gateway thread").toBeUndefined();
    const registration = await managedSubagents.requireChildExtensions("discovery-scope-session", []);
    registration.dispose();
    expect((await readdir(buildCache)).length, "the session load needed transforms discovery did not wait for").toBeGreaterThan(discoveryTransforms);
    expect(closureRequire.cache[transform], "no Babel transform loaded on the Gateway thread").toBeUndefined();
  } finally {
    if (previous === undefined) delete process.env[DELEGATED_PROVIDER_ROOT_ENV]; else process.env[DELEGATED_PROVIDER_ROOT_ENV] = previous;
    await rm(root, { recursive: true, force: true });
  }
}, 180_000);
