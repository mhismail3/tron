import { existsSync } from "node:fs";
import { mkdir, mkdtemp, readFile, realpath, rm, symlink, writeFile } from "node:fs/promises";
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
const OTHER_MODEL_ID = "home-model-2";
const VIRTUAL_MODEL_ID = "home-router";
const MODEL = { provider: PROVIDER, id: MODEL_ID };
/** Long enough that a faux stream is still running when the cache warmer fires
 * (the SDK's minimum warm delay is one second), and no longer: each stream chunk is
 * paced at 300 tokens/s, so this streams for about 1.5 s. */
const SLOW_RESPONSE = "streaming reply ".repeat(120);
const LARGE_PROMPT = "context ".repeat(1_000);
const SYSTEM_SENTINEL = "HOME-SYSTEM-SENTINEL";
const APPEND_SENTINEL = "HOME-APPEND-SENTINEL";

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
  }, 30_000);
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

/** Home has no memory defaults (decision D4): a Home session serves requests only
 * once its memory is configured. Cases that need a Home run configure it here. */
async function configureHomeMemory(f: Fixture): Promise<void> {
  await f.registry.homeOwner().configureMemory({ model: MODEL });
}

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
  events: Array<{ sessionId: string; topic: string }>;
}

function openRegistry(f: {
  agentDir: string;
  tronHome: string;
  cwd: string;
  runtime: ModelRuntime;
  faux: FauxProviderHandle;
  diagnostics: Fixture["diagnostics"];
  events: Fixture["events"];
}): { registry: RuntimeRegistry; service: GatewayService } {
  const registry = new RuntimeRegistry({
    agentDir: f.agentDir,
    tronHome: f.tronHome,
    idleRuntimeMs: 60_000,
    modelRuntimeFactory: async () => f.runtime,
    trust: new TrustService(f.agentDir),
    broadcast: (sessionId, topic) => { f.events.push({ sessionId, topic }); },
    sessionSummaryChanged: () => {},
    sessionListChanged: () => {},
    // The notify module is host-owner conditional for every profile, so the
    // fixture offers its owner and the curated Home list is exercised in full.
    notifications: { enqueue: async () => "queued" } as unknown as NotificationService,
    homeDiagnostic: (diagnostic) => f.diagnostics.push(diagnostic),
    // Home's memory compactor runs on the Gateway's ModelRuntime. These cases
    // inject its summarizer so no model is ever reached for it, exactly as the
    // Gateway injects the Knowledge model for its own calls.
    homeMemorySummarizer: () => ({ summarizer: async () => fauxAssistantMessage("HOME-MEMORY-LINE") }),
  });
  registries.push(registry);
  const service = new GatewayService({
    config: { tronHome: f.tronHome } as unknown as GatewayConfig,
    modelRuntime: f.runtime,
    sessions: registry,
    home: registry.homeOwner(),
    receipts: new CommandReceiptStore(join(f.tronHome, "receipts")),
    settings: new SettingsService(f.agentDir, f.runtime),
    trust: new TrustService(f.agentDir),
  } as unknown as GatewayServiceDependencies);
  return { registry, service };
}

async function fixture(label: string, options: { cacheWarming?: boolean; virtualModel?: boolean; symlinkHome?: boolean } = {}): Promise<Fixture> {
  const root = await mkdtemp(join(tmpdir(), `tron-home-${label}-`));
  roots.push(root);
  const agentDir = join(root, "agent");
  const cwd = join(root, "project");
  const tronHome = join(root, options.symlinkHome ? "tron-link" : "tron");
  await Promise.all([mkdir(agentDir), mkdir(cwd)]);
  if (options.symlinkHome) {
    const actualTronHome = join(root, "tron-real");
    await mkdir(actualTronHome);
    await symlink(actualTronHome, tronHome);
  }
  await writeFile(join(agentDir, "settings.json"), JSON.stringify({
    defaultProvider: PROVIDER,
    defaultModel: MODEL_ID,
    ...(options.cacheWarming ? { cacheWarming: "streaming" } : {}),
  }));
  const faux = fauxProvider({
    provider: PROVIDER,
    models: [
      { id: MODEL_ID, cost: { input: 3, output: 15, cacheRead: 0.3, cacheWrite: 300 } },
      { id: OTHER_MODEL_ID, cost: { input: 3, output: 15, cacheRead: 0.3, cacheWrite: 300 } },
    ],
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
  const events: Fixture["events"] = [];
  const f: Fixture = { agentDir, cwd, tronHome, faux, runtime, diagnostics, events, registry: undefined!, service: undefined! };
  const opened = openRegistry(f);
  f.registry = opened.registry;
  f.service = opened.service;
  await f.registry.initialize();
  // Gateway startup retires abandoned task identities after its listener serves (gateway-main).
  await f.registry.recoverHomeTasks();
  return f;
}

/** Dispose the Gateway and open a new one over the same installation: the same
 * thing a Gateway restart does. */
/** Wait for the restarted Gateway's first catalog cut, so membership reads are
 * proven rather than merely unavailable. */
async function waitForCatalog(f: Fixture): Promise<void> {
  const deadline = performance.now() + 15_000;
  const cut = () => (f.registry as unknown as { sessionCatalog: { hasCompleteCut(): boolean } }).sessionCatalog.hasCompleteCut();
  while (!cut()) {
    if (performance.now() >= deadline) throw new Error("catalog cut timed out");
    await new Promise((resolve) => setTimeout(resolve, 10));
  }
  await f.registry.catalog("all");
}

async function reopen(f: Fixture): Promise<void> {
  await f.registry.dispose();
  registries.splice(registries.indexOf(f.registry), 1);
  const opened = openRegistry(f);
  f.registry = opened.registry;
  f.service = opened.service;
  await f.registry.initialize();
  await f.registry.recoverHomeTasks();
}

interface ContextEnvelope {
  activeTools: string[];
  availableTools: Array<{ name: string }>;
  extensions: Array<{ name: string }>;
  skills: { skills: unknown[] };
  systemPrompt: string;
  instructions: { text: string };
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

async function designate(f: Fixture, commandId: string, model: { provider: string; id: string } | null = MODEL): Promise<HomeDesignation> {
  return await f.service.invoke(client, "home.designate", {
    commandId,
    ...(model ? { model } : {}),
  }) as unknown as HomeDesignation;
}

async function homeStatus(f: Fixture): Promise<HomeStatus> {
  return await f.service.invoke(client, "home.status", {}) as unknown as HomeStatus;
}

const HOME_EXTENSIONS = [
  "tron-ask-user", "tron-compaction-policy", "tron-context-window", "tron-display", "tron-home", "tron-home-research", "tron-notify",
];
/** The curated Home profile's executable tool set: the allowlist, sorted the way
 * the assertions read it. */
const HOME_TOOLS = [
  "ask_user", "date", "delegate", "display", "knowledge", "memory_search", "notify",
  "profile", "read_file", "session_search", "task", "web_fetch", "web_search", "zoom",
];

describe("Tron Home designation", () => {
  homeCase("refuses a different model for an enabled Home and keeps matching designations idempotent", async () => {
    const f = await fixture("enabled-model-designate");
    const original = await designate(f, "home-designate-enabled-model");
    const home = await f.registry.acquire(original.sessionId);
    const before = await homeStatus(f);
    const runtimeModel = home.snapshot().model;

    await expect(f.service.invoke(client, "home.designate", {
      commandId: "home-designate-enabled-different-model",
      model: { provider: PROVIDER, id: OTHER_MODEL_ID },
    })).rejects.toMatchObject({
      code: "conflict",
      message: expect.stringContaining("session.setModel"),
    });
    expect(await homeStatus(f)).toEqual(before);
    expect(home.snapshot().model).toEqual(runtimeModel);
    expect(f.diagnostics).toEqual([
      { outcome: "designated" },
      { outcome: "refused", reason: "model-change-requires-session-set-model" },
    ]);

    const sameModel = await designate(f, "home-designate-enabled-same-model", MODEL);
    expect(sameModel).toEqual(original);
    expect(await designate(f, "home-designate-enabled-same-model", MODEL)).toEqual(original);

    const noModel = await designate(f, "home-designate-enabled-no-model", null);
    expect(noModel).toEqual(original);
    expect(await designate(f, "home-designate-enabled-no-model", null)).toEqual(original);
    expect(await homeStatus(f)).toEqual(before);
    expect(home.snapshot().model).toEqual(runtimeModel);
  });

  homeCase("refuses a former Home after record corruption without blocking ordinary provider requests", async () => {
    const f = await fixture("corrupt-record", { symlinkHome: true });
    const designation = await designate(f, "home-designate-corrupt-record");
    const home = await f.registry.acquire(designation.sessionId);
    await f.service.invoke(client, "home.disable", { commandId: "home-disable-before-corruption" });
    await home.setModel(PROVIDER, MODEL_ID);
    f.faux.setResponses([fauxAssistantMessage("before corruption")]);
    await home.prompt("establish the session transcript");
    await waitUntil(() => f.faux.state.callCount === 1);
    await waitUntil(() => home.snapshot().configurationBlocker === null);
    const requestsBeforeCorruption = f.faux.state.callCount;
    expect(requestsBeforeCorruption).toBe(1);

    await writeFile(join(f.tronHome, "gateway", "home", "home.json"), "{broken", { mode: 0o600 });
    await reopen(f);
    await waitForCatalog(f);
    let admissionError: unknown;
    try {
      const admitted = await f.registry.acquire(designation.sessionId);
      // Negative-control path: without the guard the former Home is an ordinary
      // runtime and sends its canonical transcript to the provider.
      f.faux.setResponses([fauxAssistantMessage("unprotected Home request")]);
      await admitted.prompt("must not reach provider after corruption");
      await waitUntil(() => f.faux.state.callCount === requestsBeforeCorruption + 1);
      await waitUntil(() => admitted.snapshot().configurationBlocker === null);
    } catch (error) {
      admissionError = error;
    }
    if (!admissionError) expect(f.faux.state.callCount).toBe(requestsBeforeCorruption + 1);
    expect(admissionError).toMatchObject({ code: "conflict" });
    expect(f.faux.state.callCount).toBe(requestsBeforeCorruption);

    const ordinary = await f.registry.create(f.cwd);
    await ordinary.setModel(PROVIDER, MODEL_ID);
    f.faux.setResponses([fauxAssistantMessage("ordinary remains available")]);
    await ordinary.prompt("ordinary control");
    await waitUntil(() => f.faux.state.callCount === requestsBeforeCorruption + 1);
    await waitUntil(() => ordinary.snapshot().configurationBlocker === null);
    expect(f.faux.state.callCount).toBe(requestsBeforeCorruption + 1);
  });

  homeCase("gives a new Home the curated first runtime and leaves ordinary sessions unchanged", async () => {
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

    expect(await homeStatus(f)).toEqual({
      available: true, enabled: false, live: false, sessionPresent: false, taskRecovery: { available: true },
      memory: { configured: false, open: false, paused: false },
      // Derived by HomeOwner.status (#505): an undesignated Home names its one recovery action.
      phase: "undesignated", activation: { available: false },
      readiness: { ready: false, gaps: ["not-designated"] }, recovery: { action: "designate" },
    });

    // The default-model branch: no model named means this Gateway's default.
    const designation = await designate(f, "home-designate-1", null);
    expect(designation.generation).toBe(1);
    expect((await homeStatus(f)).model).toEqual(MODEL);

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

    expect(await homeStatus(f)).toMatchObject({
      available: true, enabled: true, homeId: designation.homeId,
      sessionId: designation.sessionId, bindingRevision: 1, generation: 1, model: MODEL, live: true, sessionPresent: true,
      // Home has no memory defaults: until `home.configureMemory`, the
      // projection says so, every activation refuses, and status names the fix.
      memory: { configured: false, open: false, paused: false },
      phase: "blocked", activation: { available: false },
      readiness: { ready: false, gaps: ["memory-not-configured"] }, recovery: { action: "configure-memory" },
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

    // An active Home slot cannot be rekeyed by a fork. Configure memory so
    // the source has a real canonical turn rather than an admission refusal.
    await configureHomeMemory(f);
    f.faux.setResponses([fauxAssistantMessage("home reply")]);
    await home.prompt("hello home");
    await waitUntil(() => home.snapshot().configurationBlocker === null);
    const leaf = (home as unknown as { sessionManager: { getLeafId(): string | null } }).sessionManager.getLeafId();
    expect(leaf).toBeTypeOf("string");
    await expect(home.fork(leaf!)).rejects.toMatchObject({
      code: "conflict", details: { reason: "home-identity-replacement", sessionId: home.id },
    });
    expect(await f.registry.acquire(designation.sessionId)).toBe(home);
    expect(home.snapshot().compactionPolicy?.currentBudgets).toMatchObject({ enabled: false });
  });

  homeCase("excludes the agent directory's SYSTEM.md and APPEND_SYSTEM.md from Home", async () => {
    // The curated profile drops the agent-directory system prompt files
    // too, and an ordinary session in the same installation still loads them.
    const f = await fixture("systemprompt");
    await writeFile(join(f.agentDir, "SYSTEM.md"), `${SYSTEM_SENTINEL}\n`);
    await writeFile(join(f.agentDir, "APPEND_SYSTEM.md"), `${APPEND_SENTINEL}\n`);

    const ordinary = await f.registry.create(f.cwd);
    await ordinary.setModel(PROVIDER, MODEL_ID);
    const ordinaryContext = await contextOf(ordinary);
    expect(ordinaryContext.instructions.text).toContain(SYSTEM_SENTINEL);
    expect(ordinaryContext.instructions.text).toContain(APPEND_SENTINEL);

    const designation = await designate(f, "home-designate-systemprompt");
    const homeContext = await contextOf(await f.registry.acquire(designation.sessionId));
    expect(homeContext.systemPrompt).not.toContain(SYSTEM_SENTINEL);
    expect(homeContext.systemPrompt).not.toContain(APPEND_SENTINEL);
    expect(homeContext.instructions.text).not.toContain(SYSTEM_SENTINEL);
    expect(homeContext.instructions.text).not.toContain(APPEND_SENTINEL);
  });

  homeCase("refuses a profile change while the session is running, deterministically", async () => {
    // The run is held open by a response that waits for this test, so the
    // refusal is not a race with a timed-out stream.
    const f = await fixture("busy");
    let release!: () => void;
    const held = new Promise<void>((resolve) => { release = resolve; });
    f.faux.setResponses([async () => {
      await held;
      return fauxAssistantMessage("released");
    }]);

    const designation = await designate(f, "home-designate-busy");
    await configureHomeMemory(f);
    const home = await f.registry.acquire(designation.sessionId);
    await home.prompt("hold the run open");
    await waitUntil(() => home.isBusy);

    await expect(f.service.invoke(client, "home.disable", { commandId: "home-disable-busy" }))
      .rejects.toMatchObject({ code: "busy", retryable: true });
    expect(await homeStatus(f)).toMatchObject({ enabled: true, generation: 1, sessionId: designation.sessionId });

    release();
    await waitUntil(() => home.snapshot().configurationBlocker === null, 20_000);
    const disabled = await f.service.invoke(client, "home.disable", { commandId: "home-disable-after-busy" }) as unknown as HomeDesignation;
    expect(disabled).toEqual({ ...designation, generation: 2 });
    expect(f.diagnostics.map((diagnostic) => diagnostic.outcome)).toEqual(["designated", "client-control", "refused", "disabled"]);
  });

  homeCase("replaces the live runtime in place, keeping the slot, its subscribers and the session", async () => {
    // A profile change never retires the slot, so the session (which
    // may never have been written) and its subscribers survive.
    const f = await fixture("lifecycle");
    const designation = await designate(f, "home-designate-lifecycle");
    const home = await f.registry.acquire(designation.sessionId);
    expect(activeTools(await contextOf(home))).toEqual(HOME_TOOLS);
    // Never prompted, so nothing has been written for it yet.
    expect(home.sessionFile).toBeTypeOf("string");
    expect(existsSync(home.sessionFile!)).toBe(false);

    f.registry.subscribe("test-audience", designation.sessionId);
    const before = home.snapshot();

    const disabled = await f.service.invoke(client, "home.disable", { commandId: "home-disable-1" }) as unknown as HomeDesignation;
    expect(disabled).toEqual({ ...designation, generation: 2 });
    expect(await f.service.invoke(client, "home.disable", { commandId: "home-disable-2" }) as unknown as HomeDesignation)
      .toEqual(disabled);

    // The same slot object, still live, still unpersisted, and now ordinary.
    expect(await f.registry.acquire(designation.sessionId)).toBe(home);
    // The never-written session is still here: the replacement reused it rather
    // than retiring the slot.
    expect(existsSync(home.sessionFile!)).toBe(false);
    expect(home.snapshot().revision).toBeGreaterThan(before.revision);
    const ordinaryContext = await contextOf(home);
    expect(registeredTools(ordinaryContext)).toContain("write");
    expect(extensionNames(ordinaryContext)).toContain("tron-core");
    expect(home.snapshot().compactionPolicy?.currentBudgets).toMatchObject({ enabled: true });
    expect(await homeStatus(f)).toMatchObject({ enabled: false, live: true, sessionPresent: true });
    // The replacement published to the session's subscribers, which the slot
    // never dropped: it reuses the same session identity.
    const published = f.events.filter((event) => event.sessionId === designation.sessionId).map((event) => event.topic);
    expect(published).toContain("session.resourcesChanged");
    expect(published).toContain("session.snapshot");
    f.registry.unsubscribe("test-audience", designation.sessionId);

    // A command id replayed after the disable still returns its original result.
    expect(await designate(f, "home-designate-lifecycle")).toEqual(designation);

    const reenabled = await f.service.invoke(client, "home.designate", {
      commandId: "home-designate-3", model: MODEL,
    }) as unknown as HomeDesignation;
    expect(reenabled).toEqual({ ...designation, generation: 3 });
    expect(await f.registry.acquire(designation.sessionId)).toBe(home);
    expect(activeTools(await contextOf(home))).toEqual(HOME_TOOLS);
    expect(home.snapshot().compactionPolicy?.currentBudgets).toMatchObject({ enabled: false });
  });

  homeCase("keeps the transcript's declared loadout across a profile change, and setTools restores the tools", async () => {
    // The disable does not rewrite the chat's declared loadout, so the
    // ACTIVE set stays Home's until the user changes it.
    const f = await fixture("loadout");
    f.faux.setResponses([fauxAssistantMessage("home reply")]);
    const designation = await designate(f, "home-designate-loadout");
    const home = await f.registry.acquire(designation.sessionId);
    await home.prompt("record the loadout");
    await waitUntil(() => home.snapshot().configurationBlocker === null);

    const ordinary = await f.registry.create(f.cwd);
    await ordinary.setModel(PROVIDER, MODEL_ID);
    const ordinaryActive = activeTools(await contextOf(ordinary));

    await f.service.invoke(client, "home.disable", { commandId: "home-disable-loadout" });
    const context = await contextOf(home);
    // An ordinary profile registers the ordinary tools, so the declared Home
    // loadout activates only that part of it; the memory tools are gone with the
    // Home-only module.
    expect(activeTools(context)).toEqual(HOME_TOOLS.filter((name) => registeredTools(context).includes(name)));
    expect(activeTools(context)).not.toContain("zoom");
    expect(registeredTools(context)).toEqual(registeredTools(await contextOf(ordinary)));
    await home.setTools(ordinaryActive);
    expect(activeTools(await contextOf(home))).toEqual(ordinaryActive);
  });

  homeCase("mints a fresh Home session when the recorded session is gone", async () => {
    // Designate and disable before any prompt, then restart the Gateway. The
    // never-written session is gone from the catalog, so the record is dangling.
    const f = await fixture("dangling");
    const designation = await designate(f, "home-designate-dangling");
    expect(f.registry.homeOwner().profileFor(designation.sessionId)).toBe("home");
    await f.service.invoke(client, "home.disable", { commandId: "home-disable-dangling" });
    await reopen(f);
    // Let the restarted Gateway finish its first catalog cut, so membership is
    // proven rather than merely unavailable.
    await waitForCatalog(f);

    expect(await homeStatus(f)).toMatchObject({
      available: true, enabled: false, sessionId: designation.sessionId, generation: 2,
      live: false, sessionPresent: false,
    });

    const fresh = await designate(f, "home-designate-fresh");
    expect(fresh).toEqual({ homeId: designation.homeId, sessionId: expect.any(String), generation: 3 });
    expect(fresh.sessionId).not.toBe(designation.sessionId);
    const home = await f.registry.acquire(fresh.sessionId);
    expect(activeTools(await contextOf(home))).toEqual(HOME_TOOLS);
    expect(await homeStatus(f)).toMatchObject({ enabled: true, sessionId: fresh.sessionId, live: true, sessionPresent: true });
  });

  homeCase("refuses a virtual model in the Home record on cold acquisition", async () => {
    const f = await fixture("model-virtual-record", { virtualModel: true });
    const designation = await designate(f, "home-designate-virtual-record");
    const home = await f.registry.acquire(designation.sessionId);
    await f.service.invoke(client, "home.disable", { commandId: "home-disable-virtual-record" });
    await home.setModel(PROVIDER, VIRTUAL_MODEL_ID);
    f.faux.setResponses([fauxAssistantMessage("persist virtual transcript")]);
    await home.prompt("persist disabled transcript");
    await waitUntil(() => home.snapshot().configurationBlocker === null);

    const recordPath = join(f.tronHome, "gateway", "home", "home.json");
    const record = JSON.parse(await readFile(recordPath, "utf8")) as { model: { provider: string; id: string } };
    record.model = { provider: PROVIDER, id: VIRTUAL_MODEL_ID };
    await writeFile(recordPath, `${JSON.stringify(record)}\n`, { mode: 0o600 });
    expect(JSON.parse(await readFile(recordPath, "utf8")).model).toEqual({ provider: PROVIDER, id: VIRTUAL_MODEL_ID });
    await reopen(f);
    await waitForCatalog(f);
    expect((await homeStatus(f)).model).toEqual({ provider: PROVIDER, id: VIRTUAL_MODEL_ID });
    await designate(f, "home-reenable-virtual-record", null);
    expect((await homeStatus(f)).model).toEqual({ provider: PROVIDER, id: VIRTUAL_MODEL_ID });

    const requestsBeforeAcquire = f.faux.state.callCount;
    await expect(f.registry.acquire(designation.sessionId)).rejects.toMatchObject({ code: "conflict" });
    expect(f.faux.state.callCount).toBe(requestsBeforeAcquire);
  });

  homeCase("restores the recorded model when re-enabling an unloaded Home", async () => {
    const f = await fixture("model-unloaded", { virtualModel: true });
    const designation = await designate(f, "home-designate-model-unloaded");
    const home = await f.registry.acquire(designation.sessionId);
    await f.service.invoke(client, "home.disable", { commandId: "home-disable-model-unloaded" });
    await home.setModel(PROVIDER, VIRTUAL_MODEL_ID);
    expect(home.snapshot().model).toMatchObject({ id: VIRTUAL_MODEL_ID });
    expect((await homeStatus(f)).model).toEqual(MODEL);
    f.faux.setResponses([fauxAssistantMessage("persist disabled transcript")]);
    await home.prompt("persist the disabled session");
    await waitUntil(() => home.snapshot().configurationBlocker === null);

    await reopen(f);
    await waitForCatalog(f);
    expect((await homeStatus(f)).live).toBe(false);
    await designate(f, "home-reenable-model-unloaded");
    const restored = await f.registry.acquire(designation.sessionId);
    expect(restored.snapshot().model).toMatchObject({ provider: PROVIDER, id: MODEL_ID });
    expect((await homeStatus(f)).model).toEqual(MODEL);
  });

  homeCase("applies the recorded physical model when re-enabling a Home whose session moved on", async () => {
    // The model is resolved at re-enable (the request's, else the
    // record's), and the live session is brought back to it.
    const f = await fixture("model", { virtualModel: true });
    const designation = await designate(f, "home-designate-model");
    const home = await f.registry.acquire(designation.sessionId);
    await f.service.invoke(client, "home.disable", { commandId: "home-disable-model" });

    // An ordinary session may take a virtual model; Home must not.
    await home.setModel(PROVIDER, VIRTUAL_MODEL_ID);
    expect(home.snapshot().model).toMatchObject({ id: VIRTUAL_MODEL_ID });
    expect((await homeStatus(f)).model).toEqual(MODEL);

    const reenabled = await designate(f, "home-designate-model-again");
    expect(reenabled.generation).toBe(3);
    expect(await f.registry.acquire(designation.sessionId)).toBe(home);
    expect(home.snapshot().model).toMatchObject({ id: MODEL_ID });
    expect(activeTools(await contextOf(home))).toEqual(HOME_TOOLS);
    expect((await homeStatus(f)).model).toEqual(MODEL);

    // A model applied to the enabled Home is the record's model from then on.
    await home.setModel(PROVIDER, OTHER_MODEL_ID);
    expect((await homeStatus(f)).model).toEqual({ provider: PROVIDER, id: OTHER_MODEL_ID });
    await expect(f.service.invoke(client, "home.designate", {
      commandId: "home-designate-model-virtual",
      model: { provider: PROVIDER, id: VIRTUAL_MODEL_ID },
    })).rejects.toMatchObject({ code: "invalid_request" });
  });

  homeCase("sends zero cache-warming requests for Home while an ordinary session still warms", async () => {
    // The SDK's warmer calls the model runtime directly,
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
    await configureHomeMemory(f);
    const home = await f.registry.acquire(designation.sessionId);
    const homeSession = (home as unknown as { runtime: { session: AgentSession } }).runtime.session;
    // The first prompt records the usage the warm decision prices; the second is
    // still streaming when its warm timer fires.
    f.faux.setResponses([response("home reply")]);
    await home.prompt(LARGE_PROMPT);
    await waitUntil(() => home.snapshot().configurationBlocker === null, 20_000);
    f.faux.setResponses(Array.from({ length: 6 }, () => response(SLOW_RESPONSE)));
    await home.prompt("warm this request");
    await waitUntil(() => homeSession.cacheWarmingStatus?.reason === "stopped by extension", 10_000);
    expect(homeSession.cacheWarmingStatus).toMatchObject({ state: "inactive", extensionOverride: true });
    expect(warmCalls).toEqual([]);
    await waitUntil(() => home.snapshot().configurationBlocker === null, 30_000);

    // Control: an ordinary session in the same registry and on the same model
    // does warm, so Home's zero is the profile and not a disabled warmer.
    const ordinary = await f.registry.create(f.cwd);
    await ordinary.setModel(PROVIDER, MODEL_ID);
    f.faux.setResponses([response("ordinary reply")]);
    await ordinary.prompt(LARGE_PROMPT);
    await waitUntil(() => ordinary.snapshot().configurationBlocker === null, 20_000);
    f.faux.appendResponses(Array.from({ length: 6 }, () => response(SLOW_RESPONSE)));
    await ordinary.prompt("warm this request");
    await waitUntil(() => warmCalls.length > 0, 10_000);
    expect(warmCalls.length).toBeGreaterThan(0);
    // Home still never warmed.
    expect(homeSession.cacheWarmingStatus).toMatchObject({ reason: "stopped by extension" });
    await waitUntil(() => ordinary.snapshot().configurationBlocker === null, 30_000);
  });
});
