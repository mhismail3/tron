/**
 * Tron Home end to end: the real `EpisodicMemory` behind Home's request seam,
 * driven through the Gateway RPC surface, with a deterministic faux compactor and
 * a faux provider.
 *
 * The compactor is injected on the Gateway's ModelRuntime seam (the same seam the
 * Gateway uses to resolve the Knowledge model), so every provider request in this
 * file is Home's own: the memory's summaries never reach the faux provider's
 * stream. That keeps the counts meaningful — "zero provider requests" is about
 * the activation, not about a compactor the test happens to script.
 *
 * The retained artifact is `test-results/home-activation/report.json`.
 */
import { mkdir, mkdtemp, readFile, rm, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { ModelRuntime, type AgentSession } from "@earendil-works/pi-coding-agent";
import { fauxAssistantMessage, fauxProvider, fauxToolCall, type FauxProviderHandle } from "@earendil-works/pi-ai";
import { afterAll, afterEach, describe, expect, it } from "vitest";
import { SettingsService } from "../admin/settings-service.js";
import { TrustService } from "../admin/trust-service.js";
import type { EpisodicSummarizer } from "../episodic/episodic-contract.js";
import { HOME_MEMORY_VIEW_MARKER } from "../home/home-memory.js";
import { HOME_NONCE_MARKER } from "../home/home-request-policy.js";
import type { HomeContextProjection, HomeMemoryStatus, HomeStatus } from "../protocol/types.js";
import type { GatewayConfig } from "../config.js";
import { CommandReceiptStore } from "../transport/command-receipts.js";
import { GatewayService, type ClientContext, type GatewayServiceDependencies } from "../transport/gateway-service.js";
import { RuntimeRegistry } from "../sessions/runtime-registry.js";

const PROVIDER = "tron-home-e2e";
const MODEL_ID = "chat";
const MEMORY_PROVIDER = "tron-home-e2e-memory";
const MEMORY_MODEL_ID = "compactor";
const MEMORY_MODEL = { provider: MEMORY_PROVIDER, id: MEMORY_MODEL_ID };
const VIRTUAL_MODEL_ID = "router";
const MODEL = { provider: PROVIDER, id: MODEL_ID };
const SUMMARY_MARKER = "HOME-SUMMARY";
const FILLER = "these are earlier home words ".repeat(40);
const REPORT_PATH = "test-results/home-activation/report.json";

/** Rows this file records, in order. */
const report: { generatedAt: string; cases: Array<Record<string, unknown>> } = {
  generatedAt: new Date().toISOString(),
  cases: [],
};

const longInput = (marker: string): string => `${marker} ${FILLER}`;
const client = { id: "terminal", identity: "device:home-activation", isLocal: false } as ClientContext;

interface CompactorState {
  calls: number;
  entered: number;
  gate: Promise<void> | undefined;
  release: (() => void) | undefined;
}

/** Provider usage a faux compactor reply reports, so Home's spend is measured
 * (a reply with no usage spends nothing, and the budget would be untested). */
const COMPACTOR_USAGE = {
  input: 64, output: 16, cacheRead: 0, cacheWrite: 0, totalTokens: 80,
  cost: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0, total: 0 },
};

/** A short, bounded line that never echoes its input, so a summarized message's
 * own text cannot reappear in the view. */
function deterministicSummarizer(state: CompactorState): EpisodicSummarizer {
  return async (request) => {
    state.calls += 1;
    state.entered += 1;
    const text = request.turns.map((turn) => turn.text).join("\n");
    if (request.turns.length === 1 && state.gate) await state.gate;
    const line = text.includes("must end where it is cut here")
      ? `${SUMMARY_MARKER} ${state.calls} shortened`
      : `${SUMMARY_MARKER} ${state.calls} ${"s".repeat(64)}`;
    return { ...await fauxAssistantMessage(line), usage: COMPACTOR_USAGE };
  };
}

async function waitUntil(predicate: () => boolean, timeoutMs = 15_000): Promise<void> {
  const deadline = performance.now() + timeoutMs;
  while (!predicate()) {
    if (performance.now() >= deadline) throw new Error("condition timed out");
    await new Promise((resolve) => setTimeout(resolve, 10));
  }
}

interface CapturedRequest {
  roles: string[];
  blob: string;
}

function record(context: { messages: Array<{ role: string }> }): CapturedRequest {
  return {
    roles: context.messages.map((message) => message.role),
    blob: JSON.stringify(context.messages, (key, value) => key === "timestamp" ? 0 : value),
  };
}

/** The frozen view one request carried, without its per-activation nonce. */
function viewOf(request: CapturedRequest): string {
  const start = request.blob.indexOf(HOME_MEMORY_VIEW_MARKER);
  const end = request.blob.indexOf("</chat>", start);
  return start < 0 || end < 0 ? "" : request.blob.slice(start, end);
}

const roots: string[] = [];
const registries: RuntimeRegistry[] = [];
const disposals: Array<() => Promise<void>> = [];

afterEach(async () => {
  for (const dispose of disposals.splice(0).reverse()) await dispose();
});

afterAll(async () => {
  await mkdir(join(process.cwd(), "test-results", "home-activation"), { recursive: true });
  await writeFile(join(process.cwd(), REPORT_PATH), `${JSON.stringify(report, null, 2)}\n`);
  process.stdout.write(`home-activation e2e: ${report.cases.length} cases -> ${REPORT_PATH}\n`);
});

interface Fixture {
  root: string;
  agentDir: string;
  tronHome: string;
  faux: FauxProviderHandle;
  runtime: ModelRuntime;
  registry: RuntimeRegistry;
  service: GatewayService;
  compactor: CompactorState;
  summarizer: EpisodicSummarizer;
  openChatProvider: () => FauxProviderHandle;
}

function openRegistry(f: Fixture): void {
  const registry = new RuntimeRegistry({
    agentDir: f.agentDir,
    tronHome: f.tronHome,
    idleRuntimeMs: 60_000,
    modelRuntimeFactory: async () => f.runtime,
    trust: new TrustService(f.agentDir),
    broadcast: () => {},
    sessionSummaryChanged: () => {},
    sessionListChanged: () => {},
    homeMemorySummarizer: () => ({ summarizer: f.summarizer }),
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
  f.registry = registry;
  f.service = service;
}

async function fixture(label: string, options: { summarizer?: EpisodicSummarizer; tokenBudget?: number; virtualModel?: boolean } = {}): Promise<Fixture> {
  const root = await mkdtemp(join(tmpdir(), `tron-home-e2e-${label}-`));
  roots.push(root);
  const agentDir = join(root, "agent");
  const tronHome = join(root, "tron");
  await mkdir(agentDir, { recursive: true });
  await writeFile(join(agentDir, "settings.json"), JSON.stringify({ defaultProvider: PROVIDER, defaultModel: MODEL_ID }));
  const faux = fauxProvider({
    provider: PROVIDER,
    models: [{ id: MODEL_ID, reasoning: true }],
    tokensPerSecond: 1_000_000,
    tokenSize: { min: 10, max: 10 },
  });
  const memoryFaux = fauxProvider({ provider: MEMORY_PROVIDER, models: [{ id: MEMORY_MODEL_ID, reasoning: false }] });
  const runtime = await ModelRuntime.create({ authPath: join(root, "auth.json"), modelsPath: null, refreshOnCreate: false });
  runtime.registerNativeProvider(faux.provider);
  runtime.registerNativeProvider(memoryFaux.provider);
  if (options.virtualModel) {
    runtime.registerVirtualModel({
      provider: MEMORY_PROVIDER,
      id: VIRTUAL_MODEL_ID,
      name: "Fixture router",
      route: () => ({ model: runtime.getModel(MEMORY_PROVIDER, MEMORY_MODEL_ID)!, thinkingLevel: "off" }),
    });
  }
  const compactor: CompactorState = { calls: 0, entered: 0, gate: undefined, release: undefined };
  const f: Fixture = {
    root, agentDir, tronHome, faux, runtime, compactor,
    summarizer: options.summarizer ?? deterministicSummarizer(compactor),
    registry: undefined!, service: undefined!,
    openChatProvider: () => faux,
  };
  openRegistry(f);
  await f.registry.initialize();
  return f;
}

/** Dispose the Gateway and open a new one over the same installation: the same
 * thing a Gateway restart does. */
async function restart(f: Fixture): Promise<void> {
  await f.registry.dispose();
  registries.splice(registries.indexOf(f.registry), 1);
  openRegistry(f);
  await f.registry.initialize();
  // A restarted Gateway has to read its catalog before it can resolve a session
  // that no live runtime holds.
  const cut = () => (f.registry as unknown as { sessionCatalog: { hasCompleteCut(): boolean } }).sessionCatalog.hasCompleteCut();
  await waitUntil(() => cut(), 20_000);
  await f.registry.catalog("all");
}

/** Designate Home through the service, configure its memory, and return its slot. */
async function designateHome(
  f: Fixture,
  commandId: string,
  options: { configure?: boolean; tokenBudget?: number } = {},
): Promise<Awaited<ReturnType<RuntimeRegistry["acquire"]>>> {
  await f.service.invoke(client, "home.designate", { commandId, model: MODEL });
  if (options.configure !== false) {
    await f.service.invoke(client, "home.configureMemory", {
      commandId: `${commandId}-memory`,
      model: MEMORY_MODEL,
      tokenBudget: options.tokenBudget ?? 1_000_000,
    });
  }
  const status = await f.service.invoke(client, "home.status", {}) as unknown as HomeStatus;
  return await f.registry.acquire(status.sessionId!);
}

const sessionOf = (slot: { runtime: unknown }): AgentSession => (slot as unknown as { runtime: { session: AgentSession } }).runtime.session;
const responsesOf = (f: Fixture, requests: CapturedRequest[]) => (blob: string) => async (context: { messages: Array<{ role: string }> }) => {
  requests.push(record(context));
  return fauxAssistantMessage(blob);
};

async function sessionJsonl(slot: Awaited<ReturnType<RuntimeRegistry["acquire"]>>): Promise<string> {
  return slot.sessionFile ? await readFile(slot.sessionFile, "utf8").catch(() => "") : "";
}

async function canonicalMessages(slot: Awaited<ReturnType<RuntimeRegistry["acquire"]>>): Promise<Array<Record<string, unknown>>> {
  const jsonl = await sessionJsonl(slot);
  return jsonl.trimEnd().split("\n").filter((line) => line !== "").map((line) => JSON.parse(line) as Record<string, never>)
    .filter((entry) => (entry as { type?: string }).type === "message")
    .map((entry) => (entry as { message?: Record<string, unknown> }).message!);
}

describe.sequential("Tron Home activations end to end", () => {
  it("runs activation two on the view of activation one, frozen across its tool loop", async () => {
    const f = await fixture("view");
    disposals.push(async () => { await f.registry.dispose(); await rm(f.root, { recursive: true, force: true }); });
    const requests: CapturedRequest[] = [];
    const slot = await designateHome(f, "e2e-designate-view");
    // Both of activation one's messages are long enough to need a summary: a
    // short message is its own view line, word for word (gist §3), so only a
    // summarized message proves the native body is gone.
    f.faux.setResponses([responsesOf(f, requests)(longInput("activation one response"))]);
    await slot.prompt(longInput("activation one input"));
    await waitUntil(() => !slot.isBusy);
    // Activation one's leaves are built before activation two starts.
    await waitUntil(() => (f.registry.homeOwner().memoryStatus().episodic?.coverage.summarized ?? 0) >= 2);
    f.faux.setResponses([
      async (context) => { requests.push(record(context)); return fauxAssistantMessage(fauxToolCall("read", { path: "note.txt" })); },
      async (context) => { requests.push(record(context)); return fauxAssistantMessage("after the tool"); },
    ]);
    await slot.prompt(longInput("activation two input"));
    await waitUntil(() => !slot.isBusy);
    const second = requests[1]!;
    const third = requests[2]!;
    const jsonl = await sessionJsonl(slot);
    const status = await f.service.invoke(client, "home.status", {}) as unknown as HomeStatus;
    const context = await f.service.invoke(client, "home.context", {}) as unknown as HomeContextProjection;
    const memory: HomeMemoryStatus = status.memory;
    const row = {
      providerRequests: requests.length,
      roleSequences: requests.map((request) => request.roles),
      secondRequestContainsSummary: second.blob.includes(SUMMARY_MARKER),
      secondRequestExcludesPriorText: !second.blob.includes("activation one input"),
      secondRequestExcludesPriorReply: !second.blob.includes("activation one response"),
      priorReplyWasSummarized: second.blob.includes(SUMMARY_MARKER),
      viewFrozenAcrossToolLoop: viewOf(second) !== "" && viewOf(second) === viewOf(third),
      activationCarriedNoPriorCanonicalMessages: second.roles.filter((role) => role === "user").length === 2,
      transcriptHasNoViewText: !jsonl.includes(HOME_MEMORY_VIEW_MARKER) && !jsonl.includes(SUMMARY_MARKER) && !jsonl.includes(HOME_NONCE_MARKER),
      memory: {
        configured: memory.configured,
        open: memory.open,
        messages: memory.episodic?.messages ?? 0,
        summarized: memory.episodic?.coverage.summarized ?? 0,
        viewBytes: memory.episodic?.view.bytes ?? 0,
        tokensUsed: memory.episodic?.tokens.used ?? 0,
      },
      context,
      canonicalRoles: (await canonicalMessages(slot)).map((message) => message.role),
    };
    report.cases.push({ case: "view", ...row });
    expect(row.secondRequestContainsSummary).toBe(true);
    expect(row.secondRequestExcludesPriorText).toBe(true);
    expect(row.secondRequestExcludesPriorReply).toBe(true);
    expect(row.viewFrozenAcrossToolLoop).toBe(true);
    expect(row.transcriptHasNoViewText).toBe(true);
    expect(row.memory.summarized).toBeGreaterThanOrEqual(2);
    expect(row.memory.tokensUsed).toBeGreaterThan(0);
    expect(context.available).toBe(true);
    if (context.available) {
      expect(typeof context.activationStartEntryId).toBe("string");
      expect(context.viewLines).toBeGreaterThan(0);
      expect(context.viewBytes).toBeGreaterThan(0);
      expect(context.effectiveTokens).toBeGreaterThan(0);
      expect(context.contextWindow).toBeGreaterThan(0);
      expect(context.activationOpen).toBe(false);
    }
    // The frozen view's text is never part of this projection.
    expect(JSON.stringify(context)).not.toContain(SUMMARY_MARKER);
  }, 60_000);

  it("waits for the lines it will send before serving an activation", async () => {
    const f = await fixture("wait");
    disposals.push(async () => { await f.registry.dispose(); await rm(f.root, { recursive: true, force: true }); });
    const requests: CapturedRequest[] = [];
    const slot = await designateHome(f, "e2e-designate-wait");
    // The compactor parks on its first attempt, so activation one's leaves stay
    // unbuilt and activation two cannot send anything.
    f.compactor.gate = new Promise<void>((resolve) => { f.compactor.release = resolve; });
    f.faux.setResponses([responsesOf(f, requests)(longInput("wait activation one reply"))]);
    await slot.prompt(longInput("wait activation one"));
    await waitUntil(() => !slot.isBusy);
    await waitUntil(() => f.compactor.entered > 0);
    expect(requests.length).toBe(1);
    f.faux.setResponses([responsesOf(f, requests)("wait activation two reply")]);
    const second = slot.prompt(longInput("wait activation two"));
    await waitUntil(() => (f.registry.homeOwner().requestPolicyFor(slot.id)?.currentOperationId() ?? undefined) !== undefined);
    const waiting = requests.length;
    const unbuiltWhileWaiting = f.registry.homeOwner().memoryStatus().episodic?.view.unbuilt ?? 0;
    f.compactor.release?.();
    await second;
    await waitUntil(() => !slot.isBusy);
    const row = {
      requestsWhileWaiting: waiting,
      unbuiltWhileWaiting,
      providerRequests: requests.length,
      viewSummarized: requests[1]?.blob.includes(SUMMARY_MARKER) ?? false,
      viewExcludesPriorText: !(requests[1]?.blob.includes("wait activation one") ?? true),
      refusalReasons: f.registry.homeOwner().requestPolicyFor(slot.id)?.refusalLog().map((entry) => entry.reason) ?? [],
    };
    report.cases.push({ case: "wait", ...row });
    expect(row.requestsWhileWaiting).toBe(1);
    expect(row.unbuiltWhileWaiting).toBeGreaterThan(0);
    expect(row.providerRequests).toBe(2);
    expect(row.viewSummarized).toBe(true);
    expect(row.viewExcludesPriorText).toBe(true);
  }, 60_000);

  it("treats a Stop during that wait as a refusal, with the input left unanswered", async () => {
    const f = await fixture("stop");
    disposals.push(async () => { await f.registry.dispose(); await rm(f.root, { recursive: true, force: true }); });
    const requests: CapturedRequest[] = [];
    const slot = await designateHome(f, "e2e-designate-stop");
    f.compactor.gate = new Promise<void>((resolve) => { f.compactor.release = resolve; });
    f.faux.setResponses([responsesOf(f, requests)("stop activation one reply")]);
    await slot.prompt(longInput("stop activation one"));
    await waitUntil(() => !slot.isBusy);
    await waitUntil(() => f.compactor.entered > 0);
    const requestsBefore = requests.length;
    f.faux.setResponses([responsesOf(f, requests)("must never be produced")]);
    const second = slot.prompt(longInput("stop activation two"));
    await waitUntil(() => (f.registry.homeOwner().requestPolicyFor(slot.id)?.currentOperationId() ?? undefined) !== undefined);
    await slot.abort("agent");
    const outcome = await second.then(() => "resolved", (error: unknown) => error instanceof Error ? `${error.name}: ${error.message}` : String(error));
    await waitUntil(() => !slot.isBusy);
    const messages = await canonicalMessages(slot);
    const row = {
      outcome,
      providerRequestsOfStoppedActivation: requests.length - requestsBefore,
      // Message content is a string or parts, so the whole entry is searched.
      inputStayedInLog: messages.some((message) => JSON.stringify(message).includes("stop activation two")),
      // A stopped activation is never answered: no completed assistant turn
      // follows the input it never took (gist §7).
      answeredAfterInput: messages.some((message, index) => message.role === "assistant"
        && message.stopReason === "stop"
        && messages.slice(0, index).some((earlier) => JSON.stringify(earlier).includes("stop activation two"))),
      refusalReasons: f.registry.homeOwner().requestPolicyFor(slot.id)?.refusalLog().map((entry) => entry.reason) ?? [],
      canonicalRoles: messages.map((message) => message.role),
      slotPhase: slot.snapshot().phase,
    };
    report.cases.push({ case: "stop", ...row });
    // The parked compactor is a test promise, not an abortable model call, so it
    // is released before the fixture disposes the memory its pump is inside.
    f.compactor.release?.();
    expect(row.providerRequestsOfStoppedActivation).toBe(0);
    expect(row.inputStayedInLog).toBe(true);
    expect(row.answeredAfterInput).toBe(false);
    expect(row.slotPhase).toBe("idle");
  }, 60_000);

  it("refuses an unconfigured memory, then serves the next activation once configured", async () => {
    const f = await fixture("configure");
    disposals.push(async () => { await f.registry.dispose(); await rm(f.root, { recursive: true, force: true }); });
    const requests: CapturedRequest[] = [];
    const slot = await designateHome(f, "e2e-designate-configure", { configure: false });
    const unconfigured = await f.service.invoke(client, "home.status", {}) as unknown as HomeStatus;
    f.faux.setResponses([responsesOf(f, requests)("must never be produced")]);
    await slot.prompt(longInput("unconfigured activation input"));
    await waitUntil(() => !slot.isBusy);
    const refused = await canonicalMessages(slot);
    const refusals = f.registry.homeOwner().requestPolicyFor(slot.id)?.refusalLog().map((entry) => entry.reason) ?? [];
    const context = await f.service.invoke(client, "home.context", {}) as unknown as HomeContextProjection;

    await f.service.invoke(client, "home.configureMemory", {
      commandId: "e2e-configure-memory",
      model: MEMORY_MODEL,
      tokenBudget: 100_000,
    });
    f.faux.setResponses([responsesOf(f, requests)("configured activation response")]);
    await slot.prompt(longInput("configured activation input"));
    await waitUntil(() => !slot.isBusy);
    const status = await f.service.invoke(client, "home.status", {}) as unknown as HomeStatus;
    const row = {
      unconfiguredMemory: unconfigured.memory,
      providerRequestsWhileUnconfigured: requests.filter((request) => request.blob.includes("unconfigured activation input")).length,
      refusalReasons: refusals,
      refusalEntry: refused.findLast((message) => message.stopReason === "error")?.errorMessage ?? null,
      contextWhileUnconfigured: context,
      configuredProviderRequests: requests.filter((request) => request.blob.includes("configured activation input")).length,
      configured: status.memory,
    };
    report.cases.push({ case: "configure", ...row });
    expect(row.unconfiguredMemory).toEqual({ configured: false, open: false });
    expect(row.providerRequestsWhileUnconfigured).toBe(0);
    expect(row.refusalReasons).toContain("memory-not-configured");
    expect(context).toEqual({ available: false });
    expect(row.configuredProviderRequests).toBe(1);
    expect(row.configured.configured).toBe(true);
    expect(row.configured.open).toBe(true);
  }, 60_000);

  it("admits a memory configuration only for a physical model and a bounded budget", async () => {
    const f = await fixture("configure-validation", { virtualModel: true });
    disposals.push(async () => { await f.registry.dispose(); await rm(f.root, { recursive: true, force: true }); });
    await f.service.invoke(client, "home.designate", { commandId: "e2e-designate-validation", model: MODEL });
    const attempt = (params: Record<string, unknown>): Promise<string> => f.service.invoke(client, "home.configureMemory", params)
      .then(() => "accepted", (error: unknown) => (error as { code?: string }).code ?? "failed");
    const outcomes = {
      unregisteredModel: await attempt({ commandId: "configure-validation-1", model: { provider: MEMORY_PROVIDER, id: "missing" }, tokenBudget: 1_000 }),
      virtualModel: await attempt({ commandId: "configure-validation-2", model: { provider: MEMORY_PROVIDER, id: VIRTUAL_MODEL_ID }, tokenBudget: 1_000 }),
      zeroBudget: await attempt({ commandId: "configure-validation-3", model: MEMORY_MODEL, tokenBudget: 0 }),
      fractionalBudget: await attempt({ commandId: "configure-validation-4", model: MEMORY_MODEL, tokenBudget: 1.5 }),
      oversizedBudget: await attempt({ commandId: "configure-validation-5", model: MEMORY_MODEL, tokenBudget: 100_000_001 }),
      unknownField: await attempt({ commandId: "configure-validation-6", model: MEMORY_MODEL, tokenBudget: 1_000, extra: true }),
      missingModel: await attempt({ commandId: "configure-validation-7", tokenBudget: 1_000 }),
    };
    const status = await f.service.invoke(client, "home.status", {}) as unknown as HomeStatus;
    const accepted = await f.service.invoke(client, "home.configureMemory", { commandId: "configure-validation-8", model: MEMORY_MODEL, tokenBudget: 1_000 })
      .then(() => "accepted", (error: unknown) => (error as { code?: string }).code ?? "failed");
    const after = await f.service.invoke(client, "home.status", {}) as unknown as HomeStatus;
    report.cases.push({ case: "configure-validation", outcomes, memoryAfterRefusals: status.memory, accepted, memoryAfterAccept: after.memory });
    expect(outcomes).toEqual({
      unregisteredModel: "not_found",
      virtualModel: "invalid_request",
      zeroBudget: "invalid_request",
      fractionalBudget: "invalid_request",
      oversizedBudget: "invalid_request",
      unknownField: "invalid_request",
      missingModel: "invalid_request",
    });
    expect(status.memory).toEqual({ configured: false, open: false });
    expect(accepted).toBe("accepted");
    expect(after.memory).toMatchObject({ configured: true, open: false, model: MEMORY_MODEL, tokenBudget: 1_000 });
  }, 60_000);

  it("refuses a blocked memory with zero provider requests and reports the blocked reason", async () => {
    const f = await fixture("blocked", {
      summarizer: async () => fauxAssistantMessage("", { stopReason: "error", errorMessage: "invalid_request_error: unsupported message" }),
    });
    disposals.push(async () => { await f.registry.dispose(); await rm(f.root, { recursive: true, force: true }); });
    const requests: CapturedRequest[] = [];
    const slot = await designateHome(f, "e2e-designate-blocked");
    f.faux.setResponses([responsesOf(f, requests)("first activation response")]);
    await slot.prompt(longInput("blocked activation one"));
    await waitUntil(() => !slot.isBusy);
    await waitUntil(() => f.registry.homeOwner().memoryStatus().blocked !== undefined);
    const requestsBefore = requests.length;
    f.faux.setResponses([responsesOf(f, requests)("must never be produced")]);
    await slot.prompt(longInput("blocked activation two"));
    await waitUntil(() => !slot.isBusy);
    const status = await f.service.invoke(client, "home.status", {}) as unknown as HomeStatus;
    const refusals = f.registry.homeOwner().requestPolicyFor(slot.id)?.refusalLog().map((entry) => entry.reason) ?? [];
    const row = {
      providerRequestsOfRefusedActivation: requests.length - requestsBefore,
      refusalReasons: refusals,
      blocked: status.memory.blocked,
      episodicBlocked: status.memory.episodic?.blocked ?? null,
    };
    report.cases.push({ case: "blocked", ...row });
    expect(row.providerRequestsOfRefusedActivation).toBe(0);
    expect(row.refusalReasons).toContain("memory-blocked");
    expect(row.blocked).toBe("permanent-failure");
  }, 60_000);

  it("keeps Home's token spend across a Gateway restart", async () => {
    const f = await fixture("restart", { tokenBudget: 1_000_000 });
    disposals.push(async () => { await f.registry.dispose(); await rm(f.root, { recursive: true, force: true }); });
    const requests: CapturedRequest[] = [];
    const slot = await designateHome(f, "e2e-designate-restart");
    f.faux.setResponses([responsesOf(f, requests)("first activation response")]);
    await slot.prompt(longInput("restart activation one"));
    await waitUntil(() => !slot.isBusy);
    await waitUntil(() => (f.registry.homeOwner().memoryStatus().episodic?.tokens.used ?? 0) > 0);
    const before = f.registry.homeOwner().memoryStatus();
    const beforeUsed = before.episodic?.tokens.used ?? 0;
    const callsBefore = f.compactor.calls;

    await restart(f);
    // The restarted Gateway has no memory open until an activation asks for one,
    // which is also when the record's model and budget are applied again.
    const reopened = await f.registry.acquire(slot.id);
    f.faux.setResponses([responsesOf(f, requests)("after restart response")]);
    await reopened.prompt(longInput("restart activation two"));
    await waitUntil(() => !reopened.isBusy);
    const after = f.registry.homeOwner().memoryStatus();
    const row = {
      usedBeforeRestart: beforeUsed,
      usedAfterRestart: after.episodic?.tokens.used ?? 0,
      compactorCallsBeforeRestart: callsBefore,
      summarySentAfterRestart: requests.at(-1)?.blob.includes(SUMMARY_MARKER) ?? false,
      // The restarted memory must not re-spend its budget rebuilding what it
      // already built: the tree is durable and only the new message is summarized.
      compactorCallsAfterRestart: f.compactor.calls - callsBefore,
    };
    report.cases.push({ case: "restart", ...row });
    expect(row.usedAfterRestart).toBeGreaterThanOrEqual(row.usedBeforeRestart);
    expect(row.summarySentAfterRestart).toBe(true);
    // Only the new message needed summarizing: the tree was durable, so the
    // restarted memory re-spent nothing on what it had already built.
    expect(row.compactorCallsAfterRestart).toBeLessThanOrEqual(2);
  }, 90_000);
});
