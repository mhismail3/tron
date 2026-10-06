import { mkdir, mkdtemp, readdir, readFile, rm, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { ModelRuntime } from "@earendil-works/pi-coding-agent";
import { fauxAssistantMessage, fauxProvider, getCurrentTools } from "@earendil-works/pi-ai";
import { afterEach, describe, expect, it } from "vitest";
import { TrustService } from "../admin/trust-service.js";
import { RuntimeRegistry } from "./runtime-registry.js";
import { waitFor } from "../../test-support/wait-for.js";

const registries: RuntimeRegistry[] = [];
const roots: string[] = [];
afterEach(async () => {
  await Promise.all(registries.splice(0).map((registry) => registry.dispose().catch(() => {})));
  await Promise.all(roots.splice(0).map((root) => rm(root, { recursive: true, force: true })));
});

async function activeTools(slot: Awaited<ReturnType<RuntimeRegistry["acquire"]>>): Promise<string[]> {
  const context = await slot.context() as { activeTools: string[] };
  return [...context.activeTools].sort();
}

/** The loadout the canonical transcript declares, replayed the way Pi replays it. */
async function transcriptTools(sessionDir: string): Promise<string[]> {
  const files: string[] = [];
  for (const entry of await readdir(sessionDir, { recursive: true })) {
    if (String(entry).endsWith(".jsonl")) files.push(join(sessionDir, String(entry)));
  }
  expect(files).toHaveLength(1);
  const messages = (await readFile(files[0]!, "utf8")).trim().split("\n")
    .map((line) => JSON.parse(line) as { type: string; message?: { role: string } })
    .flatMap((entry) => entry.type === "message" && entry.message ? [entry.message] : []);
  return getCurrentTools(messages).map((tool) => tool.name).sort();
}

describe("per-chat tool loadout", () => {
  it("survives the chat's runtime being recreated, and the next prompt keeps it", async () => {
    // Failure modes: a tool the chat enabled (codemode) or a default it
    // disabled (write) is reset to the configured defaults when the runtime is
    // recreated (idle eviction or Gateway restart both rebuild it from the
    // transcript), and the next prompt then persists the defaults, making the
    // loss permanent. A new chat must still start with the defaults.
    const root = await mkdtemp(join(tmpdir(), "tron-tool-loadout-"));
    roots.push(root);
    const agentDir = join(root, "agent");
    const sessionDir = join(root, "sessions");
    const cwd = join(root, "workspace");
    await Promise.all([mkdir(agentDir, { recursive: true }), mkdir(sessionDir, { recursive: true }), mkdir(cwd, { recursive: true })]);
    await writeFile(join(agentDir, "settings.json"), JSON.stringify({ sessionDir }));
    const trust = new TrustService(agentDir);
    await trust.set(cwd, true);
    const faux = fauxProvider({ provider: "tron-tool-loadout", tokensPerSecond: 10_000 });
    faux.setResponses([fauxAssistantMessage("first"), fauxAssistantMessage("second")]);
    const modelRuntimeFactory = async () => {
      const runtime = await ModelRuntime.create({ modelsPath: null, refreshOnCreate: false });
      runtime.registerNativeProvider(faux.provider);
      return runtime;
    };
    const createRegistry = () => {
      const registry = new RuntimeRegistry({
        agentDir, tronHome: join(root, "tron"), idleRuntimeMs: 60_000, modelRuntimeFactory, trust,
        broadcast: () => {}, sessionSummaryChanged: () => {}, sessionListChanged: () => {},
      });
      registries.push(registry);
      return registry;
    };

    const registry = createRegistry();
    await registry.initialize();
    const slot = await registry.create(cwd);
    const model = faux.getModel();
    await slot.setModel(model.provider, model.id);
    const defaults = await activeTools(slot);
    expect(defaults).toContain("write");
    expect(defaults).not.toContain("codemode");
    const chosen = [...defaults.filter((name) => name !== "write"), "codemode"].sort();
    await slot.setTools(chosen);
    await slot.prompt("record the loadout");
    await waitFor(() => !slot.isBusy, "the slot to go idle");
    expect(await transcriptTools(sessionDir)).toEqual(chosen);

    await registry.dispose();
    registries.splice(registries.indexOf(registry), 1);
    const reopened = createRegistry();
    await reopened.initialize();
    await waitFor(() => (reopened as unknown as { sessionCatalog: { hasCompleteCut(): boolean } }).sessionCatalog.hasCompleteCut(), "the catalog's complete cut");
    await reopened.catalog("all");
    const reloaded = await reopened.acquire(slot.id);
    expect(await activeTools(reloaded)).toEqual(chosen);

    await reloaded.prompt("keep the loadout");
    await waitFor(() => !reloaded.isBusy, "the reloaded slot to go idle");
    expect(await transcriptTools(sessionDir)).toEqual(chosen);

    const fresh = await reopened.create(cwd);
    expect(await activeTools(fresh)).toEqual(defaults);
  });
});
