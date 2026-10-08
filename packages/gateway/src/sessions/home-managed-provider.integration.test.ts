import { mkdir, mkdtemp, readFile, rm, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { dirname, join } from "node:path";
import { ModelRuntime } from "@earendil-works/pi-coding-agent";
import { fauxAssistantMessage, fauxProvider } from "@earendil-works/pi-ai";
import { expect, it } from "vitest";
import { TrustService } from "../admin/trust-service.js";
import { delegatedArtifactRoot, delegatedProviderEnvironment, DELEGATED_PROVIDER_ROOT_ENV } from "./delegated-provider.js";
import { ManagedSubagents } from "./managed-subagents.js";
import { RuntimeRegistry } from "./runtime-registry.js";
import type { RuntimeSlot } from "./runtime-slot.js";
import { waitFor } from "../../test-support/wait-for.js";

// Failure modes: managed loader/admission leaks into Home, or its resource read
// still discovers external agents. Exercise real profile owners and SDK reloads.
it("keeps managed subagents ordinary-only across Home profile replacement and restart", async () => {
  const root = await mkdtemp(join(tmpdir(), "tron-home-managed-profile-"));
  const agentDir = join(root, "agent");
  const cwd = join(root, "project");
  const tronHome = join(root, "tron");
  const environment = ["PI_CODING_AGENT_DIR", DELEGATED_PROVIDER_ROOT_ENV, "PI_SUBAGENTS_PI_CODING_AGENT_PACKAGE_ROOT"];
  const previous = environment.map(name => process.env[name]);
  const reportPath = process.env.TRON_HOME_MANAGED_REPORT ?? join(process.cwd(), "test-results", "home-managed-provider.integration.json");
  const transitions: string[] = [];
  let registry: RuntimeRegistry | undefined;
  let passed = false;
  try {
    await Promise.all([mkdir(agentDir), mkdir(cwd)]);
    process.env.PI_CODING_AGENT_DIR = agentDir;
    delete process.env.PI_SUBAGENTS_PI_CODING_AGENT_PACKAGE_ROOT;
    delegatedProviderEnvironment(delegatedArtifactRoot(tronHome));
    const faux = fauxProvider({ provider: "tron-home-managed-profile", tokensPerSecond: 10_000 });
    const { provider, id } = faux.getModel();
    const model = { provider, id };
    await writeFile(join(agentDir, "settings.json"), JSON.stringify({ defaultProvider: model.provider, defaultModel: model.id }));
    const managedSubagents = ManagedSubagents.activateForStartup(tronHome);
    const openRegistry = async () => {
      const trust = new TrustService(agentDir);
      await trust.set(cwd, true);
      const next = new RuntimeRegistry({
        agentDir, tronHome, managedSubagents, trust, idleRuntimeMs: 60_000,
        modelRuntimeFactory: async () => {
          const runtime = await ModelRuntime.create({ authPath: join(root, "auth.json"), modelsPath: null, refreshOnCreate: false });
          runtime.registerNativeProvider(faux.provider);
          return runtime;
        },
        homeMemorySummarizer: () => ({ summarizer: async () => fauxAssistantMessage("memory line") }),
        broadcast: () => {}, sessionSummaryChanged: () => {}, sessionListChanged: () => {},
      });
      registry = next;
      await next.initialize();
      return next;
    };
    const assertProfile = async (slot: RuntimeSlot, profile: "ordinary" | "home", transition: string) => {
      const context = await slot.context() as unknown as {
        availableTools: Array<{ name: string }>;
        extensions: Array<{ name: string }>;
      };
      const resources = await slot.resources() as unknown as { subagents: Array<{ name: string }>; subagentDiagnostics?: string };
      const names = context.availableTools.map(tool => tool.name);
      if (profile === "home") {
        expect(names.sort()).toEqual(["ask_user", "date", "delegate", "display", "memory_search", "task", "zoom"]);
        // The executable allowlist alone can hide tools from a loaded provider;
        // Home must exclude the extension itself, not merely hide its tools.
        expect(context.extensions.map(extension => extension.name.replace(/^<inline:/, "").replace(/>$/, "")).sort())
          .toEqual(["tron-ask-user", "tron-compaction-policy", "tron-context-window", "tron-display", "tron-home"]);
        expect(resources.subagents).toEqual([]);
      } else {
        expect(names).toContain("subagent");
        expect(names).toContain("subagent_supervisor");
        expect(resources.subagents.some(agent => agent.name === "researcher")).toBe(true);
      }
      expect(resources.subagentDiagnostics).toBeUndefined();
      transitions.push(transition);
    };
    const first = await openRegistry();
    const ordinary = await first.create(cwd);
    await assertProfile(ordinary, "ordinary", "ordinary-create");
    const designation = await first.homeOwner().designate({ model }, () => model);
    const home = await first.acquire(designation.sessionId);
    await assertProfile(home, "home", "home-first-runtime");
    await home.reload(false, true, true);
    await assertProfile(home, "home", "home-reload");
    await first.homeOwner().configureMemory({ model });
    faux.setResponses([fauxAssistantMessage("persisted Home reply")]);
    await home.prompt("Persist this Home chapter for cold acquisition");
    await waitFor(() => !home.isBusy, "Home persisted turn");
    expect(await readFile(home.sessionFile!, "utf8")).toContain("persisted Home reply");
    await first.homeOwner().disable();
    expect(await first.acquire(designation.sessionId)).toBe(home);
    await assertProfile(home, "ordinary", "home-disable");
    await first.homeOwner().designate({ model }, () => model);
    expect(await first.acquire(designation.sessionId)).toBe(home);
    await assertProfile(home, "home", "home-reenable");
    await assertProfile(ordinary, "ordinary", "ordinary-after-designation");
    await first.dispose();
    registry = undefined;
    const restarted = await openRegistry();
    await waitFor(() => (restarted as unknown as { sessionCatalog: { hasCompleteCut(): boolean } }).sessionCatalog.hasCompleteCut(), "restart catalog cut", 15_000);
    await assertProfile(await restarted.acquire(designation.sessionId), "home", "home-cold-acquire");
    passed = true;
  } finally {
    try { await registry?.dispose(); }
    finally {
      environment.forEach((name, index) => {
        if (previous[index] === undefined) delete process.env[name];
        else process.env[name] = previous[index];
      });
      await rm(root, { recursive: true, force: true });
      await mkdir(dirname(reportPath), { recursive: true });
      await writeFile(reportPath, `${JSON.stringify({ passed, transitions }, null, 2)}\n`);
    }
  }
}, 60_000);
