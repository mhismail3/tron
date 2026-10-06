import { mkdir, mkdtemp, realpath, rm, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { ModelRuntime, type AgentSession } from "@earendil-works/pi-coding-agent";
import { fauxAssistantMessage, fauxProvider, type FauxProviderHandle } from "@earendil-works/pi-ai";
import { afterAll, afterEach, describe, expect, it } from "vitest";
import { SettingsService } from "../admin/settings-service.js";
import { TrustService } from "../admin/trust-service.js";
import type { HomeDesignation, HomeStatus } from "../protocol/types.js";
import type { GatewayConfig } from "../config.js";
import type { NotificationService } from "../notifications/notification-service.js";
import { CommandReceiptStore } from "../transport/command-receipts.js";
import { GatewayService, type ClientContext, type GatewayServiceDependencies } from "../transport/gateway-service.js";
import { RuntimeRegistry } from "./runtime-registry.js";

const PROVIDER = "tron-home-fixture";
const MODEL_ID = "home-model";
const VIRTUAL_MODEL_ID = "home-router";
const MODEL = { provider: PROVIDER, id: MODEL_ID };
/** Long enough that a faux stream is still running when the cache warmer fires
 * (the SDK's minimum warm delay is one second). */
const SLOW_RESPONSE = "streaming reply ".repeat(400);
const LARGE_PROMPT = "context ".repeat(1_000);

/** Retained, regenerable evidence for this suite. */
const report: { suite: string; cases: Array<{ name: string; outcome: "passed" | "failed"; detail?: string }> } = {
  suite: "home-designation",
  cases: [],
};

function homeCase(name: string, body: () => Promise<void>): void {
  it(name, async () => {
    try {
      await body();
      report.cases.push({ name, outcome: "passed" });
    } catch (error) {
      report.cases.push({ name, outcome: "failed", detail: error instanceof Error ? error.message : String(error) });
      throw error;
    }
  });
}

const roots: string[] = [];
const registries: RuntimeRegistry[] = [];

afterEach(async () => {
  await Promise.all(registries.splice(0).map((registry) => registry.dispose().catch(() => {})));
  await Promise.all(roots.splice(0).map((root) => rm(root, { recursive: true, force: true })));
});

afterAll(async () => {
  const directory = join(process.cwd(), "test-results", "home-designation");
  await mkdir(directory, { recursive: true });
  await writeFile(join(directory, "report.json"), `${JSON.stringify({
    ...report,
    generatedAt: new Date().toISOString(),
  }, null, 2)}\n`);
  const failed = report.cases.filter((entry) => entry.outcome === "failed").length;
  process.stdout.write(`home-designation: ${report.cases.length} cases, ${failed} failed\n`);
});

const client = { id: "terminal", identity: "device:home-designation", isLocal: false } as ClientContext;

async function waitUntil(predicate: () => boolean, timeoutMs = 5_000): Promise<void> {
  const deadline = performance.now() + timeoutMs;
  while (!predicate()) {
    if (performance.now() >= deadline) throw new Error("condition timed out");
    await new Promise((resolve) => setTimeout(resolve, 10));
  }
}

interface Fixture {
  agentDir: string;
  cwd: string;
  tronHome: string;
  faux: FauxProviderHandle;
  runtime: ModelRuntime;
  registry: RuntimeRegistry;
  service: GatewayService;
  diagnostics: Array<{ outcome: string; reason?: string }>;
}

async function fixture(label: string, options: { cacheWarming?: boolean; virtualModel?: boolean } = {}): Promise<Fixture> {
  const root = await mkdtemp(join(tmpdir(), `tron-home-${label}-`));
  roots.push(root);
  const agentDir = join(root, "agent");
  const cwd = join(root, "project");
  const tronHome = join(root, "tron");
  await Promise.all([mkdir(agentDir), mkdir(cwd)]);
  await writeFile(join(agentDir, "settings.json"), JSON.stringify({
    defaultProvider: PROVIDER,
    defaultModel: MODEL_ID,
    ...(options.cacheWarming ? { cacheWarming: "streaming" } : {}),
  }));
  const faux = fauxProvider({
    provider: PROVIDER,
    models: [{ id: MODEL_ID, cost: { input: 3, output: 15, cacheRead: 0.3, cacheWrite: 300 } }],
    // Slow enough that a long response keeps its run live across the SDK's
    // one-second minimum cache-warm delay.
    tokensPerSecond: 300,
  });
  const runtime = await ModelRuntime.create({ authPath: join(root, "auth.json"), modelsPath: null, refreshOnCreate: false });
  runtime.registerNativeProvider(faux.provider);
  if (options.virtualModel) {
    runtime.registerVirtualModel({
      provider: PROVIDER,
      id: VIRTUAL_MODEL_ID,
      name: "Fixture router",
      route: () => ({ model: runtime.getModel(PROVIDER, MODEL_ID)!, thinkingLevel: "off" }),
    });
  }
  const trust = new TrustService(agentDir);
  await trust.set(cwd, true);
  const diagnostics: Fixture["diagnostics"] = [];
  const registry = new RuntimeRegistry({
    agentDir,
    tronHome,
    idleRuntimeMs: 60_000,
    modelRuntimeFactory: async () => runtime,
    trust,
    broadcast: () => {},
    sessionSummaryChanged: () => {},
    sessionListChanged: () => {},
    // The notify module is host-owner conditional for every profile, so the
    // fixture offers its owner and the curated Home list is exercised in full.
    notifications: { enqueue: async () => "queued" } as unknown as NotificationService,
    homeDiagnostic: (diagnostic) => diagnostics.push(diagnostic),
  });
  registries.push(registry);
  await registry.initialize();
  const service = new GatewayService({
    config: { tronHome } as unknown as GatewayConfig,
    modelRuntime: runtime,
    sessions: registry,
    home: registry.homeOwner(),
    receipts: new CommandReceiptStore(join(root, "receipts")),
    settings: new SettingsService(agentDir, runtime),
    trust,
  } as unknown as GatewayServiceDependencies);
  return { agentDir, cwd, tronHome, faux, runtime, registry, service, diagnostics };
}

interface ContextEnvelope {
  activeTools: string[];
  availableTools: Array<{ name: string }>;
  extensions: Array<{ name: string }>;
  skills: { skills: unknown[] };
}

async function contextOf(slot: Awaited<ReturnType<RuntimeRegistry["acquire"]>>): Promise<ContextEnvelope> {
  return await slot.context() as unknown as ContextEnvelope;
}

function activeTools(context: ContextEnvelope): string[] {
  return [...context.activeTools].sort();
}

function extensionNames(context: ContextEnvelope): string[] {
  // Tron registers its modules inline, so Pi reports them as `<inline:name>`.
  return context.extensions.map((extension) => extension.name.replace(/^<inline:/, "").replace(/>$/, "")).sort();
}

function registeredTools(context: ContextEnvelope): string[] {
  return context.availableTools.map((tool) => tool.name).sort();
}

async function designate(f: Fixture, commandId: string): Promise<HomeDesignation> {
  return await f.service.invoke(client, "home.designate", { commandId, model: MODEL }) as unknown as HomeDesignation;
}

async function homeStatus(f: Fixture): Promise<HomeStatus> {
  return await f.service.invoke(client, "home.status", {}) as unknown as HomeStatus;
}

const HOME_EXTENSIONS = [
  "tron-ask-user", "tron-compaction-policy", "tron-context-window", "tron-display", "tron-home", "tron-notify",
];
const HOME_TOOLS = ["ask_user", "display", "notify"];

describe.sequential("Tron Home designation", () => {
  homeCase("gives a new Home the curated first runtime and leaves ordinary sessions unchanged", async () => {
    // Failure modes 12-17, 19, 21, 22.
    const f = await fixture("profile", { virtualModel: true });
    const ordinary = await f.registry.create(f.cwd);
    await ordinary.setModel(PROVIDER, MODEL_ID);
    const ordinaryContext = await contextOf(ordinary);
    expect(registeredTools(ordinaryContext)).toContain("write");
    expect(registeredTools(ordinaryContext)).toContain("bash");

    // Negative control: a registry with no Home at all. Its ordinary session
    // must load exactly what this registry's ordinary session loads.
    const control = await fixture("control");
    const controlSlot = await control.registry.create(control.cwd);
    await controlSlot.setModel(PROVIDER, MODEL_ID);
    const controlContext = await contextOf(controlSlot);
    expect(activeTools(ordinaryContext)).toEqual(activeTools(controlContext));
    expect(extensionNames(ordinaryContext)).toEqual(extensionNames(controlContext));
    expect(registeredTools(ordinaryContext)).toEqual(registeredTools(controlContext));

    expect(await homeStatus(f)).toEqual({ available: true, enabled: false, live: false });

    const designation = await designate(f, "home-designate-1");
    expect(designation.generation).toBe(1);

    // The first runtime of the new Home is already the Home profile, read from
    // the live session rather than from the record.
    const home = await f.registry.acquire(designation.sessionId);
    const homeContext = await contextOf(home);
    // The neutral directory, resolved the way the trust store resolves it.
    expect(home.cwd).toBe(await realpath(join(f.tronHome, "gateway", "home", "workspace")));
    expect(activeTools(homeContext)).toEqual(HOME_TOOLS);
    expect(registeredTools(homeContext)).toEqual(HOME_TOOLS);
    expect(extensionNames(homeContext)).toEqual(HOME_EXTENSIONS);
    expect(homeContext.skills.skills).toEqual([]);
    expect(registeredTools(homeContext).some((name) => name.startsWith("mcp__"))).toBe(false);
    for (const excluded of ["tron-core", "tron-native-capture", "tron-computer", "tron-schedule"]) {
      expect(extensionNames(homeContext)).not.toContain(excluded);
    }

    // Ordinary sessions are untouched by the designation.
    expect(activeTools(await contextOf(ordinary))).toEqual(activeTools(ordinaryContext));
    expect(extensionNames(await contextOf(ordinary))).toEqual(extensionNames(ordinaryContext));

    expect(await homeStatus(f)).toEqual({
      available: true, enabled: true, homeId: designation.homeId,
      sessionId: designation.sessionId, generation: 1, model: MODEL, live: true,
    });

    // Idempotent, and a replayed command id returns the same result.
    expect(await designate(f, "home-designate-1")).toEqual(designation);
    expect(await designate(f, "home-designate-2")).toEqual(designation);
    expect(f.diagnostics.map((diagnostic) => diagnostic.outcome)).toEqual(["designated"]);

    // Home compaction is off for this session only; the ordinary session keeps
    // the canonical budget.
    expect(home.snapshot().compactionPolicy?.currentBudgets).toMatchObject({ enabled: false });
    expect(ordinary.snapshot().compactionPolicy?.currentBudgets).toMatchObject({ enabled: true });
    expect(home.snapshot().compactionPolicy?.next.enabled).toBe(true);

    // Manual compaction is refused at admission, before the SDK would refuse it.
    await expect(home.compact()).rejects.toMatchObject({ code: "conflict" });
    expect(home.snapshot().phase).toBe("idle");

    // A virtual model is refused for Home and for the Home session, and the
    // recorded model is unchanged.
    await expect(f.service.invoke(client, "home.designate", {
      commandId: "home-designate-virtual",
      model: { provider: PROVIDER, id: VIRTUAL_MODEL_ID },
    })).rejects.toMatchObject({ code: "invalid_request" });
    await expect(home.setModel(PROVIDER, VIRTUAL_MODEL_ID)).rejects.toMatchObject({ code: "invalid_request" });
    expect(await homeStatus(f)).toMatchObject({ model: MODEL });

    // Forking the Home session yields an ordinary session.
    f.faux.setResponses([fauxAssistantMessage("home reply")]);
    await home.prompt("hello home");
    await waitUntil(() => !home.isBusy);
    const leaf = (home as unknown as { sessionManager: { getLeafId(): string | null } }).sessionManager.getLeafId();
    expect(leaf).toBeTypeOf("string");
    const forked = await home.fork(leaf!);
    expect(f.registry.homeOwner().isEnabledHome(forked.sessionId)).toBe(false);
    const forkedSlot = await f.registry.acquire(forked.sessionId);
    const forkedContext = await contextOf(forkedSlot);
    // The curated profile is keyed by session id, so the fork registers exactly
    // what the control registry's ordinary session registers, and compaction is
    // back to the canonical budget. Its *active* set is the Home loadout the
    // canonical transcript declares, which Pi replays for every chat.
    expect(registeredTools(forkedContext)).toEqual(registeredTools(controlContext));
    expect(extensionNames(forkedContext)).toEqual(extensionNames(controlContext));
    expect(activeTools(forkedContext)).toEqual(HOME_TOOLS);
    expect(forkedSlot.snapshot().compactionPolicy?.currentBudgets).toMatchObject({ enabled: true });
  });

  homeCase("disables and re-enables the same session, rebuilding the live runtime each time", async () => {
    // Failure modes 18, 20.
    const f = await fixture("lifecycle");
    f.faux.setResponses([fauxAssistantMessage("home reply")]);
    const designation = await designate(f, "home-designate-lifecycle");
    const home = await f.registry.acquire(designation.sessionId);
    expect(activeTools(await contextOf(home))).toEqual(HOME_TOOLS);

    // Busy: refused retryably, and nothing changed.
    await home.prompt("keep the runtime busy");
    expect(home.isBusy).toBe(true);
    await expect(f.service.invoke(client, "home.disable", { commandId: "home-disable-busy" }))
      .rejects.toMatchObject({ code: "busy", retryable: true });
    expect(await homeStatus(f)).toMatchObject({ enabled: true, generation: 1 });
    await waitUntil(() => !home.isBusy);

    const disabled = await f.service.invoke(client, "home.disable", { commandId: "home-disable-1" }) as unknown as HomeDesignation;
    expect(disabled).toEqual({ ...designation, generation: 2 });
    expect(await f.service.invoke(client, "home.disable", { commandId: "home-disable-2" }) as unknown as HomeDesignation)
      .toEqual(disabled);
    expect(f.diagnostics.map((diagnostic) => diagnostic.outcome)).toEqual(["designated", "refused", "disabled"]);

    // The live runtime was retired, so the next one is ordinary.
    const ordinary = await f.registry.acquire(designation.sessionId);
    const ordinaryContext = await contextOf(ordinary);
    expect(registeredTools(ordinaryContext)).toContain("write");
    expect(extensionNames(ordinaryContext)).toContain("tron-core");
    expect(ordinary.snapshot().compactionPolicy?.currentBudgets).toMatchObject({ enabled: true });

    const reenabled = await f.service.invoke(client, "home.designate", {
      commandId: "home-designate-3", model: MODEL,
    }) as unknown as HomeDesignation;
    expect(reenabled).toEqual({ ...designation, generation: 3 });
    const homeAgain = await f.registry.acquire(designation.sessionId);
    expect(activeTools(await contextOf(homeAgain))).toEqual(HOME_TOOLS);
    expect(homeAgain.snapshot().compactionPolicy?.currentBudgets).toMatchObject({ enabled: false });
  });

  homeCase("sends zero cache-warming requests for Home while an ordinary session still warms", async () => {
    // Failure modes 23 and 24. The SDK's warmer calls the model runtime directly,
    // outside every request wrapper, and its extension decision listener fails
    // open, so tron-home must be the only answer for a Home session.
    const f = await fixture("warming", { cacheWarming: true });
    // The SDK's minimum warm delay comes from the model's prompt-cache lifetime.
    const model = f.runtime.getModel(PROVIDER, MODEL_ID)!;
    (model as unknown as { promptCache: { short: number } }).promptCache = { short: 11 };
    const warmCalls: number[] = [];
    const response = (message: string) => (
      _context: unknown,
      options: { maxTokens?: number } | undefined,
    ) => {
      if (options?.maxTokens === 1) warmCalls.push(Date.now());
      return fauxAssistantMessage(message);
    };

    const designation = await designate(f, "home-designate-warming");
    const home = await f.registry.acquire(designation.sessionId);
    const homeSession = (home as unknown as { runtime: { session: AgentSession } }).runtime.session;
    // The first prompt records the usage the warm decision prices; the second is
    // still streaming when its warm timer fires.
    f.faux.setResponses([response("home reply")]);
    await home.prompt(LARGE_PROMPT);
    await waitUntil(() => !home.isBusy, 20_000);
    f.faux.setResponses(Array.from({ length: 6 }, () => response(SLOW_RESPONSE)));
    await home.prompt("warm this request");
    await waitUntil(() => homeSession.cacheWarmingStatus?.reason === "stopped by extension", 10_000);
    expect(homeSession.cacheWarmingStatus).toMatchObject({ state: "inactive", extensionOverride: true });
    expect(warmCalls).toEqual([]);
    await waitUntil(() => !home.isBusy, 30_000);

    // Control: an ordinary session in the same registry and on the same model
    // does warm, so Home's zero is the profile and not a disabled warmer.
    const ordinary = await f.registry.create(f.cwd);
    await ordinary.setModel(PROVIDER, MODEL_ID);
    f.faux.setResponses([response("ordinary reply")]);
    await ordinary.prompt(LARGE_PROMPT);
    await waitUntil(() => !ordinary.isBusy, 20_000);
    f.faux.appendResponses(Array.from({ length: 6 }, () => response(SLOW_RESPONSE)));
    await ordinary.prompt("warm this request");
    await waitUntil(() => warmCalls.length > 0, 10_000);
    expect(warmCalls.length).toBeGreaterThan(0);
    // Home still never warmed.
    expect(homeSession.cacheWarmingStatus).toMatchObject({ reason: "stopped by extension" });
    await waitUntil(() => !ordinary.isBusy, 30_000);
  });
});
