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
 * Retained artifacts are `test-results/home-activation/report.json` and
 * `test-results/terminal-chat-home/transcript.json`.
 */
import { mkdir, mkdtemp, readFile, rm, writeFile } from "node:fs/promises";
import { spawn } from "node:child_process";
import { once } from "node:events";
import { createRequire } from "node:module";
import { pathToFileURL } from "node:url";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { ModelRuntime, type AgentSession } from "@earendil-works/pi-coding-agent";
import { fauxAssistantMessage, fauxProvider, fauxToolCall, type FauxProviderHandle } from "@earendil-works/pi-ai";
import { afterAll, afterEach, describe, expect, it } from "vitest";
import { SettingsService } from "../admin/settings-service.js";
import { TrustService } from "../admin/trust-service.js";
import type { EpisodicSummarizer } from "../episodic/episodic-contract.js";
import { HOME_MEMORY_VIEW_MARKER } from "../home/home-memory.js";
import { HOME_NONCE_MARKER, type HomeRequestRecord } from "../home/home-request-policy.js";
import type { HomeContextProjection, HomeMemoryStatus, HomeStatus } from "../protocol/types.js";
import type { GatewayConfig } from "../config.js";
import { CommandReceiptStore } from "../transport/command-receipts.js";
import { DeviceStore } from "../security/device-store.js";
import { GatewayServer } from "../transport/server.js";
import { GatewayService, type ClientContext, type GatewayServiceDependencies } from "../transport/gateway-service.js";
import { RuntimeRegistry } from "../sessions/runtime-registry.js";

const PROVIDER = "tron-home-e2e";
const MODEL_ID = "chat";
const MEMORY_PROVIDER = "tron-home-e2e-memory";
const MEMORY_MODEL_ID = "compactor";
const MEMORY_MODEL = { provider: MEMORY_PROVIDER, id: MEMORY_MODEL_ID };
/** A second physical memory model: a reconfiguration that reopens the store. */
const OTHER_MEMORY_MODEL = { provider: MEMORY_PROVIDER, id: "compactor-2" };
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
const client = {
  id: "terminal",
  identity: "device:home-activation",
  isLocal: false,
  unsubscribe: () => {},
} as unknown as ClientContext;

interface CompactorState {
  calls: number;
  entered: number;
  gate: Promise<void> | undefined;
  release: (() => void) | undefined;
  /** Flipped by a case that needs the cause of a block to be gone (or present)
   * before the next attempt. */
  failing: boolean;
  /** #493 S2: replies report this many tokens, far beyond what one summary earns. */
  runawayUsage?: number;
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
    if (request.turns.length === 1 && state.gate) {
      // A real compactor call honors the signal it was given, so a test that
      // holds one must not be able to wedge a dispose (or a reconfiguration).
      await Promise.race([
        state.gate,
        new Promise((_resolve, reject) => request.signal.addEventListener("abort", () => reject(new Error("the compactor call was aborted")), { once: true })),
      ]);
    }
    // A permanent provider refusal: the memory blocks rather than retrying, and
    // the cause is the model, which a resume or a different model addresses.
    if (state.failing) return fauxAssistantMessage("", { stopReason: "error", errorMessage: "invalid_request_error: unsupported message" });
    const line = text.includes("must end where it is cut here")
      ? `${SUMMARY_MARKER} ${state.calls} shortened`
      : `${SUMMARY_MARKER} ${state.calls} ${"s".repeat(64)}`;
    return { ...await fauxAssistantMessage(line), usage: state.runawayUsage
      ? { ...COMPACTOR_USAGE, totalTokens: state.runawayUsage }
      : COMPACTOR_USAGE };
  };
}

async function waitUntil(predicate: () => boolean | Promise<boolean>, timeoutMs = 15_000): Promise<void> {
  const deadline = performance.now() + timeoutMs;
  while (!(await predicate())) {
    if (performance.now() >= deadline) throw new Error("condition timed out");
    await new Promise((resolve) => setTimeout(resolve, 10));
  }
}

interface CapturedRequest {
  roles: string[];
  blob: string;
  /** The memory message's text blocks before the nonce, joined: the view as the model reads it. */
  view: string;
  /** Every message but the memory message. */
  outside: string;
}

function record(context: { messages: Array<{ role: string; content?: unknown }> }): CapturedRequest {
  const json = (messages: unknown) => JSON.stringify(messages, (key, value) => key === "timestamp" ? 0 : value);
  const texts = (message: { content?: unknown }) => Array.isArray(message.content)
    ? (message.content as Array<{ type?: string; text?: string }>).filter((part) => part.type === "text").map((part) => part.text ?? "") : [];
  const memory = context.messages.find((message) => texts(message)[0]?.startsWith(HOME_MEMORY_VIEW_MARKER));
  return {
    roles: context.messages.map((message) => message.role),
    blob: json(context.messages),
    // The view spans several text blocks (#491); they rejoin to the view text.
    view: memory ? texts(memory).slice(0, -1).join("") : "",
    outside: json(context.messages.filter((message) => message !== memory)),
  };
}

/** The frozen view one request carried, without its per-activation nonce. */
function viewOf(request: CapturedRequest): string {
  return request.view;
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
  server?: GatewayServer;
  compactor: CompactorState;
  summarizer: EpisodicSummarizer;
  /** Every record the seam reported (activation sizes and refusals). */
  requestRecords: HomeRequestRecord[];
  /** Every record Home's memory reported. */
  memoryDiagnostics: Array<{ event: string; reason?: string }>;
  openChatProvider: () => FauxProviderHandle;
}

function openRegistry(f: Fixture): void {
  const registry = new RuntimeRegistry({
    agentDir: f.agentDir,
    tronHome: f.tronHome,
    idleRuntimeMs: 60_000,
    modelRuntimeFactory: async () => f.runtime,
    trust: new TrustService(f.agentDir),
    broadcast: (sessionId, topic, payload) => f.server?.broadcastSession(sessionId, topic, payload as never),
    sessionSummaryChanged: () => {},
    sessionListChanged: () => {},
    homeMemorySummarizer: () => ({ summarizer: f.summarizer }),
    homeRequestDiagnostic: (record) => f.requestRecords.push(record),
    homeMemoryDiagnostic: (record) => f.memoryDiagnostics.push(record),
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
    sessionDeleted: () => {},
    uploads: {
      acquire: async () => ({ release: () => {} }),
      materialize: async () => ({ envelope: "", images: [], attachments: [], photoCount: 0, fileAttachmentCount: 0 }),
      removeSession: async () => {},
    },
  } as unknown as GatewayServiceDependencies);
  f.registry = registry;
  f.service = service;
}

async function fixture(label: string, options: { summarizer?: EpisodicSummarizer; virtualModel?: boolean; contextWindow?: number } = {}): Promise<Fixture> {
  const root = await mkdtemp(join(tmpdir(), `tron-home-e2e-${label}-`));
  roots.push(root);
  const agentDir = join(root, "agent");
  const tronHome = join(root, "tron");
  await mkdir(agentDir, { recursive: true });
  await writeFile(join(agentDir, "settings.json"), JSON.stringify({ defaultProvider: PROVIDER, defaultModel: MODEL_ID }));
  const faux = fauxProvider({
    provider: PROVIDER,
    models: [{ id: MODEL_ID, reasoning: true, ...(options.contextWindow ? { contextWindow: options.contextWindow } : {}) }],
    tokensPerSecond: 1_000_000,
    tokenSize: { min: 10, max: 10 },
  });
  const memoryFaux = fauxProvider({ provider: MEMORY_PROVIDER, models: [{ id: MEMORY_MODEL_ID, reasoning: false }, { id: OTHER_MEMORY_MODEL.id, reasoning: false }] });
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
  const compactor: CompactorState = { calls: 0, entered: 0, gate: undefined, release: undefined, failing: false };
  const f: Fixture = {
    root, agentDir, tronHome, faux, runtime, compactor,
    summarizer: options.summarizer ?? deterministicSummarizer(compactor),
    requestRecords: [],
    memoryDiagnostics: [],
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
  options: { configure?: boolean } = {},
): Promise<Awaited<ReturnType<RuntimeRegistry["acquire"]>>> {
  await f.service.invoke(client, "home.designate", { commandId, model: MODEL });
  if (options.configure !== false) {
    await f.service.invoke(client, "home.configureMemory", {
      commandId: `${commandId}-memory`,
      model: MEMORY_MODEL,
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

/** The memory store's state document for one session, as the memory persists it
 * (and as a restart restores it). */
function memoryStatePath(f: Fixture, sessionId: string): string {
  return join(f.tronHome, "workspace", "state", "episodic", sessionId, "state.json");
}

async function readMemoryState(f: Fixture, sessionId: string): Promise<Record<string, unknown> | undefined> {
  try {
    return JSON.parse(await readFile(memoryStatePath(f, sessionId), "utf8")) as Record<string, unknown>;
  } catch {
    return undefined;
  }
}

async function writeMemoryState(f: Fixture, sessionId: string, state: Record<string, unknown>): Promise<void> {
  await writeFile(memoryStatePath(f, sessionId), `${JSON.stringify(state, null, 2)}\n`, { mode: 0o600 });
}

async function canonicalMessages(slot: Awaited<ReturnType<RuntimeRegistry["acquire"]>>): Promise<Array<Record<string, unknown>>> {
  const jsonl = await sessionJsonl(slot);
  return jsonl.trimEnd().split("\n").filter((line) => line !== "").map((line) => JSON.parse(line) as Record<string, never>)
    .filter((entry) => (entry as { type?: string }).type === "message")
    .map((entry) => (entry as { message?: Record<string, unknown> }).message!);
}

describe.sequential("Tron Home activations end to end", () => {
  // progress.md C12 (#466), the property Home exists for: the full history grows
  // to several model windows while every request stays bounded, carries no
  // earlier activation's native messages, and its view still covers message 0.
  it("keeps every request bounded while the full history grows to several model windows", async () => {
    const WINDOW = 64_000;
    const f = await fixture("windows", { contextWindow: WINDOW });
    disposals.push(async () => { await f.registry.dispose(); await rm(f.root, { recursive: true, force: true }); });
    const slot = await designateHome(f, "e2e-designate-windows");
    const reply = (turn: number) => `REPLY-${turn}-MARK ` + "long assistant output line ".repeat(1_500);
    const turns: Array<{ chars: number; carriesEarlier: boolean; coversZero: boolean }> = [];
    for (let turn = 0; turn < 20; turn += 1) {
      const requests: CapturedRequest[] = [];
      f.faux.setResponses([responsesOf(f, requests)(reply(turn))]);
      await slot.prompt(`INPUT-${turn}-MARK please continue`);
      await waitUntil(() => !slot.isBusy, 60_000);
      expect(requests).toHaveLength(1);
      const view = viewOf(requests[0]!);
      // Short inputs are verbatim view lines (gist §3); only text outside the
      // view would be a resent native message, and replies are never verbatim.
      const outside = requests[0]!.outside;
      let carriesEarlier = false;
      for (let earlier = 0; earlier < turn; earlier += 1) {
        if (outside.includes(`INPUT-${earlier}-MARK`) || requests[0]!.blob.includes(`REPLY-${earlier}-MARK`)) carriesEarlier = true;
      }
      const lines = view.split("\n").filter((line) => /^\d+\+\d+\|/u.test(line));
      turns.push({ chars: requests[0]!.blob.length, carriesEarlier, coversZero: turn === 0 || lines.some((line) => line.startsWith("0+")) });
    }
    const history = (await canonicalMessages(slot)).reduce((sum, message) => sum + JSON.stringify(message.content ?? "").length, 0);
    const row = {
      window: WINDOW, historyTokens: Math.ceil(history / 4), maxRequestChars: Math.max(...turns.map((t) => t.chars)),
      anyCarriedEarlier: turns.some((t) => t.carriesEarlier), viewsCoverZero: turns.every((t) => t.coversZero),
      refusals: f.requestRecords.filter((record) => record.event === "refused").length,
    };
    report.cases.push({ case: "several-windows", ...row });
    // The control: the full history really is several windows long.
    expect(row.historyTokens).toBeGreaterThan(WINDOW * 2);
    expect(row.anyCarriedEarlier).toBe(false);
    expect(row.viewsCoverZero).toBe(true);
    expect(row.refusals).toBe(0);
    // Every request, estimated at four characters a token, is a small fraction of the window.
    expect(row.maxRequestChars / 4).toBeLessThan(WINDOW / 4);
  }, 300_000);

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
    await waitUntil(async () => ((await f.registry.homeOwner().memoryStatus()).episodic?.coverage.summarized ?? 0) >= 2);
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
    expect(await f.service.invoke(client, "home.status", {})).toMatchObject({
      phase: "active", readiness: { ready: true, gaps: [] }, recovery: { action: "none" },
      activation: { available: true, activationOpen: true },
    });
    const unbuiltWhileWaiting = (await f.registry.homeOwner().memoryStatus()).episodic?.view.unbuilt ?? 0;
    f.compactor.release?.();
    await second;
    await waitUntil(() => !slot.isBusy);
    const activations = f.requestRecords.filter((record) => record.event === "activation");
    const row = {
      requestsWhileWaiting: waiting,
      unbuiltWhileWaiting,
      providerRequests: requests.length,
      viewSummarized: requests[1]?.blob.includes(SUMMARY_MARKER) ?? false,
      viewExcludesPriorText: !(requests[1]?.blob.includes("wait activation one") ?? true),
      activationWaitedMs: activations.map((record) => record.event === "activation" ? record.waitedMs : -1),
      refusalReasons: f.registry.homeOwner().requestPolicyFor(slot.id)?.refusalLog().map((entry) => entry.reason) ?? [],
    };
    report.cases.push({ case: "wait", ...row });
    expect(row.requestsWhileWaiting).toBe(1);
    expect(row.unbuiltWhileWaiting).toBeGreaterThan(0);
    expect(row.providerRequests).toBe(2);
    expect(row.viewSummarized).toBe(true);
    expect(row.viewExcludesPriorText).toBe(true);
    // The wait is the activation's own record, in milliseconds: the first
    // activation found nothing to wait for, the second waited for its lines.
    expect(row.activationWaitedMs[0]).toBe(0);
    expect(row.activationWaitedMs[1]).toBeGreaterThan(0);
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
    expect(unconfigured).toMatchObject({
      phase: "blocked", readiness: { ready: false, gaps: ["memory-not-configured"] },
      recovery: { action: "configure-memory" }, activation: { available: false },
    });
    f.faux.setResponses([responsesOf(f, requests)("must never be produced")]);
    await slot.prompt(longInput("unconfigured activation input"));
    await waitUntil(() => !slot.isBusy);
    const refused = await canonicalMessages(slot);
    const refusals = f.registry.homeOwner().requestPolicyFor(slot.id)?.refusalLog().map((entry) => entry.reason) ?? [];
    const context = await f.service.invoke(client, "home.context", {}) as unknown as HomeContextProjection;

    await f.service.invoke(client, "home.configureMemory", {
      commandId: "e2e-configure-memory",
      model: MEMORY_MODEL,
    });
    f.faux.setResponses([responsesOf(f, requests)("configured activation response")]);
    await slot.prompt(longInput("configured activation input"));
    await waitUntil(() => !slot.isBusy);
    const status = await f.service.invoke(client, "home.status", {}) as unknown as HomeStatus;
    expect(status).toMatchObject({ phase: "ready", readiness: { ready: true, gaps: [] }, recovery: { action: "none" }, activation: { available: true, activationOpen: false } });
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
    // The refusal is the activation's own evidence, even though it never
    // prepared a request.
    expect(context.available).toBe(true);
    expect(context.available ? context.lastRefusalReason : undefined).toBe("memory-not-configured");
    expect(row.configuredProviderRequests).toBe(1);
    expect(row.configured.configured).toBe(true);
    expect(row.configured.open).toBe(true);
  }, 60_000);

  it("shows Gateway refusals in the terminal and keeps its prompt after invalid input", async () => {
    const f = await fixture("terminal-subprocess");
    const slot = await designateHome(f, "e2e-terminal-subprocess", { configure: false });
    const devices = new DeviceStore(f.tronHome, "fixture-terminal-machine");
    await devices.initialize();
    const uploads = {
      acquire: async () => ({ release: () => {} }),
      materialize: async () => ({ envelope: "", images: [], attachments: [], photoCount: 0, fileAttachmentCount: 0 }),
      removeSession: async () => {},
    };
    const methods: string[] = [];
    const invoke = f.service.invoke.bind(f.service);
    (f.service as unknown as { invoke: typeof f.service.invoke }).invoke = async (context, method, params) => {
      methods.push(method);
      const result = await invoke(context, method, params);
      if (method === "session.close") methods.push("session.close:completed");
      return result;
    };
    const server = new GatewayServer({
      host: "127.0.0.1", port: 0, maxFrameBytes: 1_048_576,
      devices, sessions: f.registry, service: f.service, uploads: uploads as never,
      auth: { cancelOwner: () => {}, detachClient: () => {} } as never,
      logger: { log: () => {} } as never,
    });
    f.server = server;
    await server.listen();
    const port = (server as unknown as { server: { address(): { port: number } } }).server.address().port;
    const testRoot = join(f.root, "terminal-client");
    await mkdir(testRoot, { recursive: true });
    const typescript = createRequire(import.meta.url).resolve("typescript");
    const loaderPath = join(testRoot, "typescript-loader.mjs");
    await writeFile(loaderPath, `import ts from ${JSON.stringify(pathToFileURL(typescript).href)};\nimport { readFile } from "node:fs/promises";\nexport async function resolve(specifier, context, nextResolve) {\n  try { return await nextResolve(specifier, context); } catch (error) {\n    if (specifier.endsWith(".js") && (error?.code === "ERR_MODULE_NOT_FOUND" || error?.code === "ERR_UNSUPPORTED_DIR_IMPORT")) return nextResolve(specifier.slice(0, -3) + ".ts", context);\n    throw error;\n  }\n}\nexport async function load(url, context, nextLoad) {\n  if (url.endsWith(".ts")) { const source = await readFile(new URL(url), "utf8"); return { format: "module", shortCircuit: true, source: ts.transpileModule(source, { compilerOptions: { module: ts.ModuleKind.ESNext, target: ts.ScriptTarget.ES2022 } }).outputText }; }\n  return nextLoad(url, context);\n}\n`);

    const terminal = spawn(process.execPath, [
      "--experimental-loader", loaderPath, join(process.cwd(), "src/client/terminal-chat.ts"),
      "--session", slot.id,
    ], {
      cwd: process.cwd(),
      env: {
        ...process.env,
        TRON_DATA_DIR: f.tronHome,
        TRON_GATEWAY_HOST: "127.0.0.1",
        TRON_GATEWAY_PORT: String(port),
      },
      stdio: ["pipe", "pipe", "pipe"],
    });
    let stdout = "";
    let stderr = "";
    const scrub = (value: string) => value.replaceAll(`/private${f.root}`, "<fixture>").replaceAll(f.root, "<fixture>");
    let exitTimer: NodeJS.Timeout | undefined;
    let serverClosed = false;
    terminal.stdout.setEncoding("utf8").on("data", (chunk: string) => { stdout += chunk; });
    terminal.stderr.setEncoding("utf8").on("data", (chunk: string) => { stderr += chunk; });
    try {
      await waitUntil(() => stdout.includes(`Attached to Tron session ${slot.id}`), 20_000);
      terminal.stdin.write("refusal one\n");
      await waitUntil(() => (stdout.match(/Home memory is not configured/gu)?.length ?? 0) >= 1, 10_000).catch(() => { throw new Error(`missing first refusal; stdout=${scrub(stdout)} stderr=${scrub(stderr)}`); });
      terminal.stdin.write("refusal two\n");
      await waitUntil(() => (stdout.match(/Home memory is not configured/gu)?.length ?? 0) >= 2, 10_000).catch(() => { throw new Error(`missing second refusal; stdout=${scrub(stdout)} stderr=${scrub(stderr)}`); });
      const repeatedRefusalCount = stdout.match(/Home memory is not configured/gu)?.length ?? 0;
      await waitUntil(() => (stdout.match(/you>/gu)?.length ?? 0) >= 3, 10_000);
      terminal.stdin.write("/home memory anthropic\n");
      await waitUntil(() => stderr.includes("Usage: /home"), 10_000).catch(() => { throw new Error(`missing usage; stdout=${scrub(stdout)} stderr=${scrub(stderr)}`); });
      await waitUntil(() => (stdout.match(/you>/gu)?.length ?? 0) >= 4, 10_000);
      terminal.stdin.write("/home designate anthropic\n");
      await waitUntil(() => (stderr.match(/Usage: \/home/gu)?.length ?? 0) >= 2, 10_000);
      await waitUntil(() => (stdout.match(/you>/gu)?.length ?? 0) >= 5, 10_000);
      terminal.stdin.write("/home status\n");
      await waitUntil(() => stdout.includes("configure-memory"), 10_000).catch(() => { throw new Error(`missing status; stdout=${scrub(stdout)} stderr=${scrub(stderr)}`); });
      await waitUntil(() => (stdout.match(/you>/gu)?.length ?? 0) >= 6, 10_000);
      terminal.stdin.write("/quit\n");
      await waitUntil(() => methods.includes("session.close:completed"), 5_000);
      await server.close();
      serverClosed = true;
      f.server = undefined;
      terminal.stdin.destroy();
      const closed = once(terminal, "close") as Promise<[number | null, NodeJS.Signals | null]>;
      const [code, signal] = await Promise.race([
        closed,
        new Promise<never>((_, reject) => { exitTimer = setTimeout(() => reject(new Error(`terminal client did not exit; methods=${methods.join(",")} stdout=${scrub(stdout)} stderr=${scrub(stderr)}`)), 10_000); }),
      ]);
      if (exitTimer) clearTimeout(exitTimer);
      await server.close();
      serverClosed = true;
      f.server = undefined;
      const refusalCount = stdout.match(/Home memory is not configured/gu)?.length ?? 0;
      const artifact = {
        exitCode: code,
        signal,
        stdout: scrub(stdout),
        stderr: scrub(stderr),
        assertions: { refusalCount, repeatedRefusalCount, malformedUsage: (stderr.match(/Usage: \/home/gu)?.length ?? 0) >= 2 && stderr.includes("provider/id"), statusReturned: stdout.includes("configure-memory") },
      };
      await mkdir(join(process.cwd(), "test-results", "terminal-chat-home"), { recursive: true });
      await writeFile(join(process.cwd(), "test-results", "terminal-chat-home", "transcript.json"), `${JSON.stringify(artifact, null, 2)}\n`);
      expect(scrub(stderr)).not.toContain("tron-chat:");
      expect(code).toBe(0);
      expect(signal).toBeNull();
      expect(artifact.assertions.repeatedRefusalCount).toBeGreaterThanOrEqual(2);
      expect(artifact.assertions.malformedUsage).toBe(true);
      expect(artifact.assertions.statusReturned).toBe(true);
      report.cases.push({ case: "terminal-subprocess", exitCode: code, repeatedRefusalCount: artifact.assertions.repeatedRefusalCount, malformedUsage: artifact.assertions.malformedUsage, statusReturned: artifact.assertions.statusReturned });
    } finally {
      if (exitTimer) clearTimeout(exitTimer);
      if (terminal.exitCode === null && terminal.signalCode === null) {
        const stopped = once(terminal, "close");
        terminal.kill("SIGTERM");
        await stopped;
      }
      if (!serverClosed) await server.close();
      f.server = undefined;
      await f.registry.dispose();
      await rm(f.root, { recursive: true, force: true });
    }
  }, 90_000);

  it("resumes a retries-exhausted block once on the next activation", async () => {
    // A transient outage leaves a `retries-exhausted` block behind. The cause is
    // time, so the next activation re-arms the bounded retries by itself and is
    // served; a block that recurs during its wait would be refused by the wait.
    const f = await fixture("resume-transient");
    disposals.push(async () => { await f.registry.dispose(); await rm(f.root, { recursive: true, force: true }); });
    const requests: CapturedRequest[] = [];
    const slot = await designateHome(f, "e2e-designate-transient");
    f.faux.setResponses([responsesOf(f, requests)(longInput("transient response one"))]);
    await slot.prompt(longInput("transient activation one"));
    await waitUntil(() => !slot.isBusy);

    // The Gateway that a transient outage blocked: the memory's own durable state
    // is exactly what a restart hands over.
    await restart(f);
    const state = await readMemoryState(f, slot.id);
    expect(state).toBeDefined();
    await writeMemoryState(f, slot.id, { ...state!, blocked: { reason: "retries-exhausted" } });

    const reopened = await f.registry.acquire(slot.id);
    f.faux.setResponses([responsesOf(f, requests)(longInput("transient response two"))]);
    await reopened.prompt(longInput("transient activation two"));
    await waitUntil(() => !reopened.isBusy);
    const status = await f.service.invoke(client, "home.status", {}) as unknown as HomeStatus;
    const refusals = f.registry.homeOwner().requestPolicyFor(slot.id)?.refusalLog().map((entry) => entry.reason) ?? [];
    const row = {
      providerRequests: requests.filter((request) => request.blob.includes("transient activation two")).length,
      viewSummarized: requests.at(-1)?.blob.includes(SUMMARY_MARKER) ?? false,
      refusedWithBlock: refusals.includes("memory-blocked"),
      blockedAfter: status.memory.blocked,
      open: status.memory.open,
    };
    report.cases.push({ case: "resume-transient", ...row });
    expect(row.providerRequests).toBe(1);
    expect(row.viewSummarized).toBe(true);
    expect(row.refusedWithBlock).toBe(false);
    expect(row.blockedAfter).toBeUndefined();
  }, 90_000);

  it("resumes a permanent failure through home.resumeMemory", async () => {
    // A model that refused a whole batch stays the cause until it is fixed, so
    // the operator states it and `home.resumeMemory` clears the block.
    const f = await fixture("resume-memory");
    disposals.push(async () => { await f.registry.dispose(); await rm(f.root, { recursive: true, force: true }); });
    const requests: CapturedRequest[] = [];
    const slot = await designateHome(f, "e2e-designate-resume");
    f.compactor.failing = true;
    f.faux.setResponses([responsesOf(f, requests)(longInput("resume response one"))]);
    await slot.prompt(longInput("resume activation one"));
    await waitUntil(() => !slot.isBusy);
    await waitUntil(async () => (await f.registry.homeOwner().memoryStatus()).blocked === "permanent-failure");
    const blocked = (await f.registry.homeOwner().memoryStatus()).blocked;
    expect(await f.service.invoke(client, "home.status", {})).toMatchObject({
      phase: "blocked", readiness: { ready: false, gaps: ["memory-permanent-failure"] },
      recovery: { action: "resume-memory", reason: "permanent-failure" },
    });

    f.faux.setResponses([responsesOf(f, requests)("must never be produced")]);
    await slot.prompt(longInput("resume activation two"));
    await waitUntil(() => !slot.isBusy);
    const refusals = f.registry.homeOwner().requestPolicyFor(slot.id)?.refusalLog().map((entry) => entry.reason) ?? [];

    // The cause is gone; the operator says so.
    f.compactor.failing = false;
    const resumed = await f.service.invoke(client, "home.resumeMemory", { commandId: "e2e-resume-memory" })
      .then(() => "accepted", (error: unknown) => (error as { code?: string }).code ?? "failed");
    const afterResume = await f.service.invoke(client, "home.status", {}) as unknown as HomeStatus;
    expect(afterResume).toMatchObject({ phase: "ready", readiness: { ready: true, gaps: [] }, recovery: { action: "none" } });
    const requestsBefore = requests.length;
    f.faux.setResponses([responsesOf(f, requests)(longInput("resume response three"))]);
    await slot.prompt(longInput("resume activation three"));
    await waitUntil(() => !slot.isBusy);
    const row = {
      blockedBefore: blocked,
      refusedWithBlock: refusals.includes("memory-blocked"),
      resumed,
      blockedAfterResume: afterResume.memory.blocked,
      providerRequestsAfterResume: requests.length - requestsBefore,
    };
    report.cases.push({ case: "resume-memory", ...row });
    expect(row.blockedBefore).toBe("permanent-failure");
    expect(row.refusedWithBlock).toBe(true);
    expect(row.resumed).toBe("accepted");
    expect(row.blockedAfterResume).toBeUndefined();
    expect(row.providerRequestsAfterResume).toBe(1);
  }, 90_000);

  it("keeps the memory configuration across disable, re-enable and a fresh-session designation", async () => {
    // The configuration is the user's decision about *how* Home remembers, so it
    // survives a disable, a re-enable and a replacement session. The spend does
    // not: the store is keyed by session id, so a new session starts its own.
    const f = await fixture("lifecycle");
    disposals.push(async () => { await f.registry.dispose(); await rm(f.root, { recursive: true, force: true }); });
    const requests: CapturedRequest[] = [];
    const slot = await designateHome(f, "e2e-designate-lifecycle");
    f.faux.setResponses([responsesOf(f, requests)(longInput("lifecycle reply one"))]);
    await slot.prompt(longInput("lifecycle activation one"));
    await waitUntil(() => !slot.isBusy);
    await waitUntil(async () => ((await f.registry.homeOwner().memoryStatus()).spentTokens ?? 0) > 0);
    const spentOnFirstSession = (await f.registry.homeOwner().memoryStatus()).spentTokens ?? 0;

    const disabled = await f.service.invoke(client, "home.disable", { commandId: "e2e-lifecycle-disable" });
    const afterDisable = await f.service.invoke(client, "home.status", {}) as unknown as HomeStatus;
    expect(afterDisable).toMatchObject({ phase: "disabled", readiness: { ready: false, gaps: ["disabled"] }, recovery: { action: "designate" } });
    const reEnabled = await f.service.invoke(client, "home.designate", { commandId: "e2e-lifecycle-enable", model: MODEL });
    f.faux.setResponses([responsesOf(f, requests)(longInput("lifecycle reply two"))]);
    const sameSession = await f.registry.acquire((reEnabled as unknown as { sessionId: string }).sessionId);
    await sameSession.prompt(longInput("lifecycle activation two"));
    await waitUntil(() => !sameSession.isBusy);
    const afterEnable = await f.service.invoke(client, "home.status", {}) as unknown as HomeStatus;
    expect(afterEnable).toMatchObject({ phase: "ready", readiness: { ready: true, gaps: [] }, recovery: { action: "none" } });

    // A replacement session: the recorded one is deleted, so the next
    // designation creates a fresh one.
    await f.service.invoke(client, "session.delete", { commandId: "e2e-lifecycle-delete", sessionId: sameSession.id });
    await waitUntil(async () => (await f.service.invoke(client, "home.status", {}) as unknown as HomeStatus).sessionPresent === false);
    expect(await f.service.invoke(client, "home.status", {})).toMatchObject({
      phase: "missing-session", readiness: { ready: false, gaps: ["session-missing"] },
      recovery: { action: "designate", reason: "Home session is missing" },
    });
    const reDesignated = await f.service.invoke(client, "home.designate", { commandId: "e2e-lifecycle-fresh", model: MODEL }) as unknown as { sessionId: string };
    const fresh = await f.service.invoke(client, "home.status", {}) as unknown as HomeStatus;
    const row = {
      disabled: (disabled as unknown as { generation: number }).generation,
      configuredWhileDisabled: afterDisable.memory.configured,
      spendWhileDisabled: afterDisable.memory.spentTokens,
      spentOnFirstSession,
      reEnabledSessionSame: reDesignated !== undefined && afterEnable.sessionId === sameSession.id,
      modelAfterEnable: afterEnable.memory.model,
      newSessionDiffers: reDesignated.sessionId !== sameSession.id,
      configuredOnNewSession: fresh.memory.configured,
      modelOnNewSession: fresh.memory.model,
      spendOnNewSession: fresh.memory.spentTokens ?? 0,
    };
    report.cases.push({ case: "lifecycle", ...row });
    expect(row.configuredWhileDisabled).toBe(true);
    expect(row.spendWhileDisabled).toBeGreaterThanOrEqual(0);
    expect(row.modelAfterEnable).toEqual(MEMORY_MODEL);
    expect(row.newSessionDiffers).toBe(true);
    expect(row.configuredOnNewSession).toBe(true);
    expect(row.modelOnNewSession).toEqual(MEMORY_MODEL);
    expect(row.spendOnNewSession).toBe(0);
    expect(row.spentOnFirstSession).toBeGreaterThan(0);

    // The new session's memory opens and builds (#483). Its namespace was never
    // created, which is not lost state, even though the first session's store
    // set the workspace's episodic marker.
    const freshSlot = await f.registry.acquire(reDesignated.sessionId);
    f.faux.setResponses([responsesOf(f, requests)(longInput("lifecycle reply three"))]);
    await freshSlot.prompt(longInput("lifecycle activation three"));
    await waitUntil(() => !freshSlot.isBusy);
    const context = await f.service.invoke(client, "home.context", {}) as unknown as { lastRefusalReason?: string; lastRefusalDetail?: string };
    expect(context.lastRefusalReason, context.lastRefusalDetail).toBeUndefined();
    await waitUntil(async () => ((await f.registry.homeOwner().memoryStatus()).spentTokens ?? 0) > 0);
  }, 120_000);

  // #493: there is no budget to manage, and the memory is never stopped by what
  // its summaries cost: spend is bounded by construction, and only reported.
  it("keeps serving with no budget, however much its summaries cost", async () => {
    const f = await fixture("no-budget");
    disposals.push(async () => { await f.registry.dispose(); await rm(f.root, { recursive: true, force: true }); });
    const requests: CapturedRequest[] = [];
    const slot = await designateHome(f, "e2e-designate-no-budget");
    f.faux.setResponses([responsesOf(f, requests)("first activation response"), responsesOf(f, requests)("second activation response")]);
    // Activation one's summaries report a cost far beyond any former budget.
    f.compactor.runawayUsage = 1_000_000_000;
    await slot.prompt(longInput("costly activation one"));
    await waitUntil(() => !slot.isBusy);
    await waitUntil(async () => ((await f.registry.homeOwner().memoryStatus()).spentTokens ?? 0) >= 1_000_000_000);
    await slot.prompt(longInput("costly activation two"));
    await waitUntil(() => !slot.isBusy);
    await waitUntil(async () => (await f.registry.homeOwner().memoryStatus()).episodic?.view.unbuilt === 0);
    const after = await f.registry.homeOwner().memoryStatus();
    const row = {
      secondServed: requests.some((request) => request.blob.includes("costly activation two")),
      blocked: after.blocked ?? null,
      blocks: f.memoryDiagnostics.filter((record) => record.event === "episodic.node-blocked").map((record) => record.reason),
      spent: after.spentTokens ?? 0,
    };
    report.cases.push({ case: "no-budget", ...row });
    expect(row.secondServed).toBe(true);
    expect(row.blocked).toBeNull();
    expect(row.blocks).toEqual([]);
    expect(row.spent).toBeGreaterThanOrEqual(2_000_000_000);
  }, 90_000);

  it("refuses a disable while an activation waits, and that activation completes", async () => {
    // Home's memory must survive a refused disable: the session keeps running and
    // the activation waiting for its view is the thing being protected.
    const f = await fixture("disable-wait");
    disposals.push(async () => { await f.registry.dispose(); await rm(f.root, { recursive: true, force: true }); });
    const requests: CapturedRequest[] = [];
    const slot = await designateHome(f, "e2e-designate-disable-wait");
    f.compactor.gate = new Promise<void>((resolve) => { f.compactor.release = resolve; });
    f.faux.setResponses([responsesOf(f, requests)(longInput("disable wait reply one"))]);
    await slot.prompt(longInput("disable wait activation one"));
    await waitUntil(() => !slot.isBusy);
    await waitUntil(() => f.compactor.entered > 0);
    f.faux.setResponses([responsesOf(f, requests)("disable wait reply two")]);
    const second = slot.prompt(longInput("disable wait activation two"));
    await waitUntil(() => (f.registry.homeOwner().requestPolicyFor(slot.id)?.currentOperationId() ?? undefined) !== undefined);
    const disabled = await f.service.invoke(client, "home.disable", { commandId: "e2e-disable-busy" })
      .then(() => "accepted", (error: unknown) => (error as { code?: string }).code ?? "failed");
    f.compactor.release?.();
    await second;
    await waitUntil(() => !slot.isBusy);
    const status = await f.service.invoke(client, "home.status", {}) as unknown as HomeStatus;
    const row = {
      disableOutcome: disabled,
      enabledAfter: status.enabled,
      providerRequests: requests.length,
      waitingActivationServed: requests.some((request) => request.blob.includes("disable wait activation two")),
      waitingViewSummarized: requests.at(-1)?.blob.includes(SUMMARY_MARKER) ?? false,
      refusals: f.registry.homeOwner().requestPolicyFor(slot.id)?.refusalLog().map((entry) => entry.reason) ?? [],
    };
    report.cases.push({ case: "disable-wait", ...row });
    expect(row.disableOutcome).toBe("busy");
    expect(row.enabledAfter).toBe(true);
    expect(row.waitingActivationServed).toBe(true);
    expect(row.waitingViewSummarized).toBe(true);
    expect(row.refusals).not.toContain("memory-view-failed");
  }, 90_000);

  it("configures the memory while an activation waits without opening the store twice", async () => {
    const f = await fixture("configure-race");
    disposals.push(async () => { await f.registry.dispose(); await rm(f.root, { recursive: true, force: true }); });
    const requests: CapturedRequest[] = [];
    const slot = await designateHome(f, "e2e-designate-race");
    f.compactor.gate = new Promise<void>((resolve) => { f.compactor.release = resolve; });
    f.faux.setResponses([responsesOf(f, requests)(longInput("race reply one"))]);
    await slot.prompt(longInput("race activation one"));
    await waitUntil(() => !slot.isBusy);
    await waitUntil(() => f.compactor.entered > 0);
    f.faux.setResponses([responsesOf(f, requests)("race reply two")]);
    const second = slot.prompt(longInput("race activation two"));
    await waitUntil(() => (f.registry.homeOwner().requestPolicyFor(slot.id)?.currentOperationId() ?? undefined) !== undefined);
    // The operator's change lands while the activation is inside its first step.
    const configured = await f.service.invoke(client, "home.configureMemory", {
      commandId: "e2e-configure-race", model: OTHER_MEMORY_MODEL,
    }).then(() => "accepted", (error: unknown) => (error as { message?: string }).message ?? "failed");
    f.compactor.release?.();
    await second.catch(() => undefined);
    await waitUntil(() => !slot.isBusy);
    // Whatever that race did to the waiting activation, the memory is usable and
    // open exactly once: the next activation is served with the new model.
    f.faux.setResponses([responsesOf(f, requests)(longInput("race reply three"))]);
    await slot.prompt(longInput("race activation three"));
    await waitUntil(() => !slot.isBusy);
    const status = await f.service.invoke(client, "home.status", {}) as unknown as HomeStatus;
    const refusals = f.registry.homeOwner().requestPolicyFor(slot.id)?.refusalLog() ?? [];
    const row = {
      configured,
      open: status.memory.open,
      model: status.memory.model,
      thirdActivationServed: requests.some((request) => request.blob.includes("race activation three")),
      alreadyOpenRefusal: refusals.some((entry) => entry.reason === "memory-view-failed" && entry.detail.includes("already open")),
      ingestRecords: f.memoryDiagnostics.filter((record) => record.event === "home.memory-ingest").length,
    };
    report.cases.push({ case: "configure-race", ...row });
    expect(row.configured).toBe("accepted");
    expect(row.open).toBe(true);
    expect(row.model).toEqual(OTHER_MEMORY_MODEL);
    expect(row.thirdActivationServed).toBe(true);
    expect(row.alreadyOpenRefusal).toBe(false);
    expect(row.ingestRecords).toBe(0);
  }, 90_000);

  it("reports a refusal through home.context before any request was prepared", async () => {
    const f = await fixture("context-refusal");
    disposals.push(async () => { await f.registry.dispose(); await rm(f.root, { recursive: true, force: true }); });
    const requests: CapturedRequest[] = [];
    const slot = await designateHome(f, "e2e-designate-context", { configure: false });
    f.faux.setResponses([responsesOf(f, requests)("must never be produced")]);
    await slot.prompt(longInput("context refusal input"));
    await waitUntil(() => !slot.isBusy);
    const context = await f.service.invoke(client, "home.context", {}) as unknown as HomeContextProjection;
    const row = { context };
    report.cases.push({ case: "context-refusal", ...row });
    expect(context.available).toBe(true);
    if (context.available) {
      // The activation's own start entry and refusal, and no sizes at all: it
      // never prepared a request, so no other activation's sizes may appear.
      expect(typeof context.activationStartEntryId).toBe("string");
      expect(context.activationOpen).toBe(false);
      expect(context.lastRefusalReason).toBe("memory-not-configured");
      expect(context.viewLines).toBeUndefined();
      expect(context.viewBytes).toBeUndefined();
      expect(context.effectiveTokens).toBeUndefined();
      expect(context.contextWindow).toBeUndefined();
    }
  }, 60_000);

  it("reports the persisted block and spend while the store is closed", async () => {
    const f = await fixture("status-persisted");
    disposals.push(async () => { await f.registry.dispose(); await rm(f.root, { recursive: true, force: true }); });
    const requests: CapturedRequest[] = [];
    const slot = await designateHome(f, "e2e-designate-status");
    f.faux.setResponses([responsesOf(f, requests)(longInput("status reply"))]);
    await slot.prompt(longInput("status activation"));
    await waitUntil(() => !slot.isBusy);
    await waitUntil(async () => ((await f.registry.homeOwner().memoryStatus()).episodic?.tokens.used ?? 0) > 0);

    await restart(f);
    // The store the restart closed: its own document is what the status must
    // report, because the reopened memory has not opened it yet.
    const persisted = await readMemoryState(f, slot.id);
    expect(persisted).toBeDefined();
    const closed = await f.service.invoke(client, "home.status", {}) as unknown as HomeStatus;
    await writeMemoryState(f, slot.id, { ...persisted!, blocked: { reason: "source-unavailable", detail: "canonical session is unreadable" } });
    const blocked = await f.service.invoke(client, "home.status", {}) as unknown as HomeStatus;
    const row = {
      openWhenClosed: closed.memory.open,
      spentTokensWhenClosed: closed.memory.spentTokens,
      persistedSpend: persisted!.spend,
      blockedWhenClosed: blocked.memory.blocked,
      blockedReasonLeakedPath: JSON.stringify(blocked.memory).includes("/"),
    };
    report.cases.push({ case: "status-persisted", ...row });
    expect(row.openWhenClosed).toBe(false);
    expect(row.persistedSpend).toBeGreaterThan(0);
    expect(row.spentTokensWhenClosed).toBe(row.persistedSpend);
    expect(row.blockedWhenClosed).toBe("source-unavailable");
    expect(row.blockedReasonLeakedPath).toBe(false);
  }, 90_000);

  // #493 S6: a memory configuration is a physical model and nothing else.
  it("admits a memory configuration only for a physical model, with no budget", async () => {
    const f = await fixture("configure-validation", { virtualModel: true });
    disposals.push(async () => { await f.registry.dispose(); await rm(f.root, { recursive: true, force: true }); });
    await f.service.invoke(client, "home.designate", { commandId: "e2e-designate-validation", model: MODEL });
    const attempt = (params: Record<string, unknown>): Promise<string> => f.service.invoke(client, "home.configureMemory", params)
      .then(() => "accepted", (error: unknown) => (error as { code?: string }).code ?? "failed");
    const outcomes = {
      unregisteredModel: await attempt({ commandId: "configure-validation-1", model: { provider: MEMORY_PROVIDER, id: "missing" } }),
      virtualModel: await attempt({ commandId: "configure-validation-2", model: { provider: MEMORY_PROVIDER, id: VIRTUAL_MODEL_ID } }),
      tokenBudget: await attempt({ commandId: "configure-validation-3", model: MEMORY_MODEL, tokenBudget: 1_000 }),
      unknownField: await attempt({ commandId: "configure-validation-4", model: MEMORY_MODEL, extra: true }),
      missingModel: await attempt({ commandId: "configure-validation-5" }),
    };
    const status = await f.service.invoke(client, "home.status", {}) as unknown as HomeStatus;
    const accepted = await f.service.invoke(client, "home.configureMemory", { commandId: "configure-validation-6", model: MEMORY_MODEL })
      .then(() => "accepted", (error: unknown) => (error as { code?: string }).code ?? "failed");
    const after = await f.service.invoke(client, "home.status", {}) as unknown as HomeStatus;
    report.cases.push({ case: "configure-validation", outcomes, memoryAfterRefusals: status.memory, accepted, memoryAfterAccept: after.memory });
    expect(outcomes).toEqual({
      unregisteredModel: "not_found",
      virtualModel: "invalid_request",
      tokenBudget: "invalid_request",
      unknownField: "invalid_request",
      missingModel: "invalid_request",
    });
    expect(status.memory).toEqual({ configured: false, open: false });
    expect(accepted).toBe("accepted");
    expect(after.memory).toEqual({ configured: true, open: false, model: MEMORY_MODEL });
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
    await waitUntil(async () => (await f.registry.homeOwner().memoryStatus()).blocked !== undefined);
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
    const f = await fixture("restart");
    disposals.push(async () => { await f.registry.dispose(); await rm(f.root, { recursive: true, force: true }); });
    const requests: CapturedRequest[] = [];
    const slot = await designateHome(f, "e2e-designate-restart");
    f.faux.setResponses([responsesOf(f, requests)("first activation response")]);
    await slot.prompt(longInput("restart activation one"));
    await waitUntil(() => !slot.isBusy);
    await waitUntil(async () => ((await f.registry.homeOwner().memoryStatus()).episodic?.tokens.used ?? 0) > 0);
    const before = await f.registry.homeOwner().memoryStatus();
    const beforeUsed = before.episodic?.tokens.used ?? 0;
    const callsBefore = f.compactor.calls;

    await restart(f);
    // The restarted Gateway has no memory open until an activation asks for one,
    // which is also when the record's model is applied again.
    const reopened = await f.registry.acquire(slot.id);
    f.faux.setResponses([responsesOf(f, requests)("after restart response")]);
    await reopened.prompt(longInput("restart activation two"));
    await waitUntil(() => !reopened.isBusy);
    const after = await f.registry.homeOwner().memoryStatus();
    const persisted = await readMemoryState(f, slot.id);
    const row = {
      usedBeforeRestart: beforeUsed,
      usedAfterRestart: after.episodic?.tokens.used ?? 0,
      persistedSpend: persisted?.spend ?? -1,
      compactorCallsBeforeRestart: callsBefore,
      summarySentAfterRestart: requests.at(-1)?.blob.includes(SUMMARY_MARKER) ?? false,
      // The restarted memory must not re-spend its budget rebuilding what it
      // already built: the tree is durable and only the new message is summarized.
      compactorCallsAfterRestart: f.compactor.calls - callsBefore,
    };
    report.cases.push({ case: "restart", ...row });
    // Strictly greater: a reset-and-re-earn would also satisfy >=, and the
    // persisted document is the value a future restart restores.
    expect(row.usedAfterRestart).toBeGreaterThan(row.usedBeforeRestart);
    expect(row.usedAfterRestart).toBe(row.persistedSpend);
    expect(row.summarySentAfterRestart).toBe(true);
    // Only the new message needed summarizing: the tree was durable, so the
    // restarted memory re-spent nothing on what it had already built.
    expect(row.compactorCallsAfterRestart).toBeLessThanOrEqual(2);
  }, 90_000);
});
