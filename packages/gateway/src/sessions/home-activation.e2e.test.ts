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
import { mkdir, mkdtemp, readFile, readdir, realpath, rm, symlink, writeFile } from "node:fs/promises";
import { spawn } from "node:child_process";
import { statSync } from "node:fs";
import { once } from "node:events";
import WebSocket from "ws";
import { createRequire } from "node:module";
import { pathToFileURL } from "node:url";
import { tmpdir } from "node:os";
import { dirname, join } from "node:path";
import { ModelRuntime, AgentSession, SessionManager } from "@earendil-works/pi-coding-agent";
import { fauxAssistantMessage, fauxProvider, fauxToolCall, type FauxProviderHandle } from "@earendil-works/pi-ai";
import { afterAll, afterEach, describe, expect, it, vi } from "vitest";

const admissionLimits = vi.hoisted(() => ({ bytes: 200 * 1_024 * 1_024, entries: 100_000 }));
vi.mock("../home/home-chapter-state.js", async importOriginal => ({
  ...await importOriginal<typeof import("../home/home-chapter-state.js")>(),
  get HOME_HARD_BYTES() { return admissionLimits.bytes; },
  get HOME_HARD_ENTRIES() { return admissionLimits.entries; },
}));

const runtimeServices = vi.hoisted(() => ({ hold: undefined as undefined | (() => Promise<void>) }));
vi.mock("@earendil-works/pi-coding-agent", async importOriginal => {
  const actual = await importOriginal<typeof import("@earendil-works/pi-coding-agent")>();
  return {
    ...actual,
    createAgentSessionServices: async (...args: Parameters<typeof actual.createAgentSessionServices>) => {
      const hold = runtimeServices.hold;
      runtimeServices.hold = undefined;
      await hold?.();
      return actual.createAgentSessionServices(...args);
    },
  };
});

const materializationScan = vi.hoisted(() => ({ hold: undefined as undefined | (() => Promise<void>) }));
vi.mock("../home/home-session-recovery.js", async importOriginal => {
  const actual = await importOriginal<typeof import("../home/home-session-recovery.js")>();
  return {
    ...actual,
    scanReservedHomeSession: async (...args: Parameters<typeof actual.scanReservedHomeSession>) => {
      const result = await actual.scanReservedHomeSession(...args);
      const hold = materializationScan.hold;
      materializationScan.hold = undefined;
      await hold?.();
      return result;
    },
  };
});
import { awaitsWithin, waitFor } from "../../test-support/wait-for.js";
import { SettingsService } from "../admin/settings-service.js";
import { TrustService } from "../admin/trust-service.js";
import type { EpisodicSummarizer } from "../episodic/episodic-contract.js";
import { EpisodicMemory } from "../episodic/episodic-memory.js";
import * as homeSource from "../episodic/home-source.js";
import type { HomeRecord } from "../home/home-owner.js";
import { HOME_MEMORY_VIEW_MARKER } from "../home/home-memory.js";
import { scanReservedHomeSession } from "../home/home-session-recovery.js";
import { HOME_NONCE_MARKER, type HomeRequestRecord } from "../home/home-request-policy.js";
import type { HomeContextProjection, HomeMemoryStatus, HomeStatus, HomeMemoryPage, HomeMemoryEvidencePage } from "../protocol/types.js";
import type { GatewayConfig } from "../config.js";
import { CommandReceiptStore } from "../transport/command-receipts.js";
import { DeviceStore } from "../security/device-store.js";
import { GatewayServer } from "../transport/server.js";
import { GatewayService, type ClientContext, type GatewayServiceDependencies } from "../transport/gateway-service.js";
import { RuntimeRegistry } from "../sessions/runtime-registry.js";
import { RuntimeSlot } from "../sessions/runtime-slot.js";
import { invocationReceipts } from "../sessions/invocation-receipts.js";
import { logHomeDiagnostic } from "../home/home-diagnostic.js";
import { GatewayLogger } from "../transport/logger.js";

const PROVIDER = "tron-home-e2e";
const MODEL_ID = "chat";
const OTHER_MODEL_ID = "chat-2";
const MEMORY_PROVIDER = "tron-home-e2e-memory";
const MEMORY_MODEL_ID = "compactor";
const MEMORY_MODEL = { provider: MEMORY_PROVIDER, id: MEMORY_MODEL_ID };
/** A second physical memory model: a reconfiguration that reopens the store. */
const OTHER_MEMORY_MODEL = { provider: MEMORY_PROVIDER, id: "compactor-2" };
const VIRTUAL_MODEL_ID = "router";
const MODEL = { provider: PROVIDER, id: MODEL_ID };
const OTHER_MODEL = { provider: PROVIDER, id: OTHER_MODEL_ID };
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

// Threshold fixtures must not alter chapter limits while the previous turn's
// quiescence callback still owns sealing. Hold that callback to prove the cut.
async function prepareThresholdFixture(f: Awaited<ReturnType<typeof fixture>>, slot: RuntimeSlot, text: string): Promise<void> {
  const owner = f.registry.homeOwner();
  const quiescent = owner.chapterQuiescent.bind(owner);
  let release!: () => void;
  let held = false;
  const gate = new Promise<void>(resolve => { release = resolve; });
  const hook = vi.spyOn(owner, "chapterQuiescent").mockImplementationOnce(async id => {
    held = true;
    await gate;
    await quiescent(id);
  });
  let ready = false;
  let readiness: Promise<unknown> | undefined;
  try {
    await slot.prompt(text);
    await waitFor(() => held && !slot.isBusy, "threshold fixture quiescence");
    readiness = waitFor(() => slot.snapshot().configurationBlocker === null, "threshold fixture configuration readiness").then(() => { ready = true; });
    await awaitsWithin(new Promise<void>(resolve => setImmediate(resolve)), "threshold readiness observation turn");
    expect(ready, "threshold mutation must wait for chapter quiescence").toBe(false);
  } finally {
    release();
    hook.mockRestore();
    await readiness;
  }
}

async function waitUntil(predicate: () => boolean | Promise<boolean>, timeoutMs = 12_000): Promise<void> {
  await waitFor(async () => (await predicate()) || undefined, "Home activation condition", { boundMs: timeoutMs });
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
  runtimeServices.hold = undefined;
  materializationScan.hold = undefined;
  admissionLimits.bytes = 200 * 1_024 * 1_024;
  admissionLimits.entries = 100_000;
  vi.restoreAllMocks();
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
  receipts: CommandReceiptStore;
  server?: GatewayServer;
  compactor: CompactorState;
  summarizer: EpisodicSummarizer;
  /** Every record the seam reported (activation sizes and refusals). */
  requestRecords: HomeRequestRecord[];
  /** Every record Home's memory reported. */
  memoryDiagnostics: Array<{ event: string; reason?: string }>;
  homeDiagnostics: Array<Record<string, unknown>>;
  homeLogger: GatewayLogger;
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
    homeDiagnostic: (record) => { f.homeDiagnostics.push(record); logHomeDiagnostic(f.homeLogger, record); },
  });
  registries.push(registry);
  const receipts = new CommandReceiptStore(join(f.tronHome, "receipts"));
  const service = new GatewayService({
    config: { tronHome: f.tronHome } as unknown as GatewayConfig,
    modelRuntime: f.runtime,
    sessions: registry,
    home: registry.homeOwner(),
    receipts,
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
  f.receipts = receipts;
}

async function fixture(label: string, options: { summarizer?: EpisodicSummarizer; virtualModel?: boolean; contextWindow?: number; aliasedRoot?: boolean } = {}): Promise<Fixture> {
  const root = await mkdtemp(join(tmpdir(), `tron-home-e2e-${label}-`));
  roots.push(root);
  const agentDir = join(root, "agent");
  if (options.aliasedRoot) await symlink(await realpath(root), join(root, "alias"), "dir");
  const tronHome = join(root, ...(options.aliasedRoot ? ["alias", "tron"] : ["tron"]));
  await mkdir(agentDir, { recursive: true });
  await writeFile(join(agentDir, "settings.json"), JSON.stringify({ defaultProvider: PROVIDER, defaultModel: MODEL_ID }));
  const faux = fauxProvider({
    provider: PROVIDER,
    models: [
      { id: MODEL_ID, reasoning: true, ...(options.contextWindow ? { contextWindow: options.contextWindow } : {}) },
      { id: OTHER_MODEL_ID, reasoning: true },
    ],
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
    homeDiagnostics: [],
    homeLogger: new GatewayLogger(join(root, "home-signals.jsonl")),
    registry: undefined!, service: undefined!, receipts: undefined!,
    openChatProvider: () => faux,
  };
  openRegistry(f);
  await f.registry.initialize();
  return f;
}

/** Dispose the Gateway and open a new one over the same installation: the same
 * thing a Gateway restart does. */
async function restart(f: Fixture): Promise<void> {
  f.service.dispose();
  await f.receipts.dispose();
  await f.registry.dispose();
  const registeredIndex = registries.indexOf(f.registry);
  if (registeredIndex >= 0) registries.splice(registeredIndex, 1);
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

/** The memory store's state document keyed by Home's stable logical identity. */
function memoryStatePath(f: Fixture, homeId: string): string {
  return join(f.tronHome, "workspace", "state", "episodic", homeId, "state.json");
}

async function homeMemoryStateId(f: Fixture): Promise<string> {
  return (JSON.parse(await readFile(join(f.tronHome, "gateway", "home", "home.json"), "utf8")) as HomeRecord).homeId;
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

describe("Tron Home activations end to end", () => {
  it("reopens and searches the exact Home file when its cwd came through a symlink alias", async () => {
    const f = await fixture("aliased-cwd", { aliasedRoot: true });
    disposals.push(async () => { await f.registry.dispose(); await rm(f.root, { recursive: true, force: true }); });
    const slot = await designateHome(f, "aliased-home");
    f.faux.setResponses([fauxAssistantMessage("the violet lighthouse")]);
    await slot.prompt("remember the violet lighthouse");
    await waitUntil(() => slot.snapshot().configurationBlocker === null);
    const path = await realpath(slot.sessionFile!);
    const bytes = await readFile(path, "utf8");
    await restart(f);
    const cut = await f.registry.readSearchCut(slot.id);
    expect(JSON.stringify(cut.entries)).toContain("the violet lighthouse");
    const reopened = await f.registry.acquire(slot.id);
    expect(await realpath(reopened.sessionFile!)).toBe(path);
    expect(await readFile(path, "utf8")).toBe(bytes);
    expect(f.faux.state.callCount).toBe(1);
    report.cases.push({ case: "aliased-cwd-cold-open-search", exactPathRetained: true,
      bytesUnchanged: true, providerReplay: false });
  });
  it.each(["claim", "scan", "path", "pre-flush"] as const)(
    "keeps distinct joined Home commands and duplicate receipts exact at %s",
    async cut => {
      const f = await fixture(`joined-${cut}`);
      disposals.push(async () => {
        f.service.dispose();
        await f.receipts.dispose();
        await f.registry.dispose();
        await rm(f.root, { recursive: true, force: true });
      });
      const oldSlot = await designateHome(f, `joined-${cut}-designate`);
      f.faux.setResponses([fauxAssistantMessage("initial chapter reply")]);
      await oldSlot.prompt("canonical initial chapter input");
      await waitUntil(() => oldSlot.snapshot().configurationBlocker === null);
      const initialProviderCalls = f.faux.state.callCount;
      expect(initialProviderCalls).toBe(1);
      const owner = f.registry.homeOwner();
      const port = (owner as unknown as {
        options: { sessions: { chapterMetrics: (id: string) => Promise<{ bytes: number; entries: number; quiescent: boolean }> } };
      }).options.sessions;
      const measurement = vi.spyOn(port, "chapterMetrics").mockResolvedValue({ bytes: 24 * 1_024 * 1_024 + 1, entries: 3, quiescent: true });
      await owner.chapterQuiescent(oldSlot.id);
      measurement.mockRestore();
      const binding = owner.routeBinding();
      expect(owner.reservedChapter(binding.physicalSessionId)?.state).toBe("reserved");
      let reached!: () => void;
      let release!: () => void;
      const started = new Promise<void>(resolve => { reached = resolve; });
      const held = new Promise<void>(resolve => { release = resolve; });
      const hold = async () => { reached(); await held; };
      const claimReservedChapter = owner.claimReservedChapter.bind(owner);
      const claims = vi.spyOn(owner, "claimReservedChapter");
      if (cut === "scan") materializationScan.hold = hold;
      else if (cut === "claim") {
        const original = claimReservedChapter;
        vi.spyOn(owner, "claimReservedChapter").mockImplementationOnce(async (...args) => {
          const result = await original(...args); await hold(); return result;
        });
      } else if (cut === "path") {
        const original = owner.recordReservedChapterPath.bind(owner);
        vi.spyOn(owner, "recordReservedChapterPath").mockImplementationOnce(async (...args) => {
          await original(...args); await hold();
        });
      } else {
        const prototype = RuntimeSlot.prototype as unknown as {
          persistInvocationReceipt: (...args: unknown[]) => Promise<void>;
        };
        const original = prototype.persistInvocationReceipt;
        vi.spyOn(prototype, "persistInvocationReceipt").mockImplementationOnce(async function (this: RuntimeSlot, ...args) {
          await hold(); await original.apply(this, args);
        });
      }
      const constructions = vi.spyOn(RuntimeSlot, "create");
      let releaseTerminal!: () => void;
      const terminalGate = new Promise<void>(resolve => { releaseTerminal = resolve; });
      const originalMaterialize = f.registry.materializeReservedHome.bind(f.registry);
      let contenders = 0;
      const materializations = vi.spyOn(f.registry, "materializeReservedHome").mockImplementation(async id => {
        const joinedTerminal = ++contenders === 2;
        const slot = await originalMaterialize(id);
        // One ordering lets both joined inputs be admitted: construction is still
        // shared, while terminal input waits for the first operation to settle.
        if (cut === "path" && joinedTerminal) await terminalGate;
        return slot;
      });
      const submissions = vi.spyOn(AgentSession.prototype, "prompt");
      let releaseProvider!: () => void;
      const providerGate = new Promise<void>(resolve => { releaseProvider = resolve; });
      f.faux.setResponses([async () => { await providerGate; return fauxAssistantMessage("joined reply"); }]);
      const commands = [
        { commandId: `joined-${cut}-user-command`, text: `distinct user input ${cut}` },
        { commandId: `joined-${cut}-terminal-command`, text: `distinct terminal input ${cut}` },
      ];
      const terminal = { ...client, id: "second-terminal", identity: "device:joined-terminal" } as ClientContext;
      const invoke = (index: number) => f.service.invoke(index ? terminal : client, "home.prompt", commands[index]!);
      const first = invoke(0);
      void first.catch(() => {});
      let second: ReturnType<typeof invoke> | undefined;
      let duplicate: ReturnType<typeof invoke> | undefined;
      try {
        await waitUntil(() => materializations.mock.calls.length === 1);
        await awaitsWithin(started, `${cut} construction barrier`);
        second = invoke(1);
        duplicate = invoke(0);
        void second.catch(() => {}); void duplicate.catch(() => {});
        await waitUntil(() => materializations.mock.calls.length === 2);
        release();
        if (cut === "path") {
          const accepted = await first as { operationId: string };
          releaseProvider();
          const sharedSlot = await f.registry.acquire(binding.physicalSessionId);
          await waitUntil(() => invocationReceipts(sharedSlot.sessionManager.getBranch(), sharedSlot.id).some(receipt =>
            receipt.receiptKind === "terminal" && receipt.operationId === accepted.operationId));
          releaseTerminal();
        }
        const outcomes = await Promise.allSettled([first, second]);
        const accepted = outcomes.flatMap((outcome, index) => outcome.status === "fulfilled" ? [index] : []);
        expect(claims).toHaveBeenCalledTimes(1);
        expect(constructions).toHaveBeenCalledTimes(1);
        expect(accepted).toEqual(cut === "path" ? [0, 1] : [0]);
        const slot = await f.registry.acquire(binding.physicalSessionId);
        expect(slot.id).toBe(binding.physicalSessionId);
        for (const [index, outcome] of outcomes.entries()) {
          const sdkInputs = submissions.mock.calls.filter(([text]) => text === commands[index]!.text);
          expect(sdkInputs).toHaveLength(outcome.status === "fulfilled" ? 1 : 0);
          if (outcome.status === "fulfilled") expect(outcome.value).toMatchObject({ sessionId: binding.physicalSessionId });
          else expect(outcome.reason).toMatchObject({ code: "busy" });
        }
        await expect(duplicate).resolves.toEqual((outcomes[0] as PromiseFulfilledResult<unknown>).value);
        releaseProvider();
        await waitUntil(() => slot.snapshot().configurationBlocker === null);
        const bytes = await sessionJsonl(slot);
        for (const [index, outcome] of outcomes.entries()) {
          const messages = (await canonicalMessages(slot)).filter(message => message.role === "user" && JSON.stringify(message.content).includes(commands[index]!.text));
          expect(messages).toHaveLength(outcome.status === "fulfilled" ? 1 : 0);
        }
        const files = (await readdir(dirname(slot.sessionFile!))).filter(name => name.endsWith(".jsonl"));
        const matching = await Promise.all(files.map(async name => {
          const header = JSON.parse((await readFile(join(dirname(slot.sessionFile!), name), "utf8")).split("\n")[0]!);
          return header.id === slot.id;
        }));
        expect(matching.filter(Boolean)).toHaveLength(1);
        for (const index of accepted) {
          await expect(invoke(index)).resolves.toEqual((outcomes[index] as PromiseFulfilledResult<unknown>).value);
          await expect(f.receipts.status(index ? terminal.identity : client.identity, "home.prompt", commands[index]!.commandId))
            .resolves.toMatchObject({ status: "completed", result: (outcomes[index] as PromiseFulfilledResult<unknown>).value });
        }
        const receiptDirectory = join(f.tronHome, "receipts", "gateway", "command-receipts");
        const receipts = await Promise.all((await readdir(receiptDirectory)).filter(name => name.endsWith(".json"))
          .map(async name => JSON.parse(await readFile(join(receiptDirectory, name), "utf8"))));
        for (const [index, command] of commands.entries()) {
          const exact = receipts.filter(receipt => receipt.method === "home.prompt" && receipt.commandId === command.commandId);
          expect(exact).toHaveLength(accepted.includes(index) ? 1 : 0);
          if (exact[0]) expect(exact[0].binding).toEqual(binding);
        }
        expect(await sessionJsonl(slot)).toBe(bytes);
        expect(f.faux.state.callCount - initialProviderCalls).toBe(accepted.length);
        report.cases.push({ case: "joined-home-submission", barrier: cut, accepted: accepted.length,
          refused: outcomes.length - accepted.length, materializers: constructions.mock.calls.length,
          canonicalFiles: 1, replayed: false, thresholdSetup: "injected soft rollover only" });
      } finally {
        release(); releaseProvider(); releaseTerminal();
        await Promise.allSettled([first, ...(second ? [second] : []), ...(duplicate ? [duplicate] : [])]);
      }
    },
  );
  it("replays the exact completed Home target after rollover and disable without resolving or dispatching again", async () => {
    const f = await fixture("receipt-exact-replay");
    disposals.push(async () => { f.service.dispose(); await f.receipts.dispose(); await f.registry.dispose(); await rm(f.root, { recursive: true, force: true }); });
    const slot = await designateHome(f, "e2e-home-receipt-designate");
    f.faux.setResponses([fauxAssistantMessage("original receipt reply")]);
    const params = { commandId: "home-receipt-exact-command", text: "receipt-only-secret-marker" };
    const accepted = await f.service.invoke(client, "home.prompt", params);
    await waitUntil(() => slot.snapshot().configurationBlocker === null);
    // Drain the early-response completion write before reconstructing the receipt owner.
    await f.receipts.dispose();
    const before = await sessionJsonl(slot);
    const calls = f.faux.state.callCount;
    const owner = f.registry.homeOwner() as unknown as {
      options: { sessions: { chapterMetrics?: (sessionId: string) => Promise<{ bytes: number; entries: number; quiescent: boolean }> } };
    };
    owner.options.sessions.chapterMetrics = async () => ({ bytes: 0, entries: 50_001, quiescent: true });
    await f.registry.homeOwner().chapterQuiescent(slot.id);
    await f.registry.homeOwner().disable();
    // A new durable receipt owner is enough to prove replay does not depend on volatile lanes.
    const receipts = new CommandReceiptStore(join(f.tronHome, "receipts"));
    const replayCategories: string[] = [];
    try {
      const replay = await receipts.execute(client.identity, "home.prompt", params.commandId,
        async () => { throw new Error("completed receipt dispatched again"); }, {
          resolveBinding: () => { throw new Error("completed receipt resolved the disabled successor"); },
          onRouteBound: category => replayCategories.push(category),
        });
      expect(replay).toEqual(accepted);
      expect(replayCategories).toEqual(["replay"]);
      expect(f.homeDiagnostics.filter(record => record.outcome === "route-bound")).toEqual([
        { outcome: "route-bound", category: "fresh" },
      ]);
      expect(await sessionJsonl(slot)).toBe(before);
      expect(f.faux.state.callCount).toBe(calls);
      report.cases.push({ case: "exact-home-receipt-replay", originalTargetRetained: true,
        replayProviderCalls: f.faux.state.callCount - calls, categories: ["fresh", ...replayCategories] });
    } finally { await receipts.dispose(); }
  });

  it("keeps Home signals private through recovery, refusal, replay and an owner fence", async () => {
    const f = await fixture("diagnostic-privacy");
    disposals.push(async () => { f.service.dispose(); await f.receipts.dispose(); await f.registry.dispose(); await rm(f.root, { recursive: true, force: true }); });
    const slot = await designateHome(f, "e2e-privacy-designate-command");
    const secret = "HOME-PRIVATE-TRANSCRIPT-MARKER";
    f.faux.setResponses([fauxAssistantMessage(secret)]);
    const params = { commandId: "privacy-original-command", text: secret };
    await f.service.invoke(client, "home.prompt", params);
    await waitUntil(() => slot.snapshot().configurationBlocker === null);
    await f.service.invoke(client, "home.prompt", params);
    const owner = f.registry.homeOwner() as unknown as {
      unavailable?: string;
      options: { sessions: { chapterMetrics?: (sessionId: string) => Promise<{ bytes: number; entries: number; quiescent: boolean }> } };
    };
    owner.options.sessions.chapterMetrics = async id => ({ bytes: 0, entries: id === slot.id ? 100_000 : 3, quiescent: true });
    f.faux.setResponses([fauxAssistantMessage("privacy successor reply")]);
    const successor = await f.service.invoke(client, "home.prompt", { commandId: "privacy-successor-command", text: secret }) as unknown as { sessionId: string };
    const next = await f.registry.acquire(successor.sessionId);
    await waitUntil(() => next.snapshot().configurationBlocker === null);
    // Simulate the owner-facing explanation from a failed storage/reload seam;
    // it is useful to clients, but never safe as a diagnostic reason enum.
    owner.unavailable = `${secret} ${f.root} ${slot.id}`;
    try { await expect(f.service.invoke(client, "home.open", {})).rejects.toMatchObject({ code: "conflict" }); }
    finally { owner.unavailable = undefined; }
    const signals = new GatewayLogger(join(f.root, "home-signals.jsonl")).recent(100);
    expect(signals.some(record => record.event === "home.route-bound" && record.category === "replay")).toBe(true);
    expect(signals.some(record => record.event === "home.chapter-recovery" && record.reason === "absent")).toBe(true);
    expect(signals.some(record => record.event === "home.chapter-refused" && record.reason === "hard-entries")).toBe(true);
    const approved = new Set(["timestamp", "level", "message", "process", "event", "source", "reason", "category", "chapterOrdinal",
      "boundary", "crossingBytes", "crossingEntries", "settledBytes", "settledEntries", "operation"]);
    for (const signal of signals) expect(Object.keys(signal).every(key => approved.has(key))).toBe(true);
    const encoded = JSON.stringify(signals);
    for (const privateValue of [secret, f.root, slot.id, successor.sessionId, params.commandId, client.identity]) {
      expect(encoded).not.toContain(privateValue);
    }
    expect(signals.some(record => record.event === "home.unavailable" && record.reason === "owner-fenced")).toBe(true);
    report.cases.push({ case: "home-diagnostic-privacy", events: [...new Set(signals.map(record => record.event))],
      privateValuesAbsent: true, recovery: "absent", routeCategories: ["fresh", "replay"] });
  });

  it("exports Home through a temporary artifact without targeting its chapter file", async () => {
    const f = await fixture("export-destination");
    disposals.push(async () => { await f.registry.dispose(); await rm(f.root, { recursive: true, force: true }); });
    const slot = await designateHome(f, "e2e-home-export-destination");
    f.faux.setResponses([fauxAssistantMessage("Home export source")]);
    await slot.prompt("create a canonical Home chapter entry");
    await waitUntil(() => slot.snapshot().configurationBlocker === null);
    const chapterPath = slot.sessionFile!;
    const before = await readFile(chapterPath);
    await f.registry.initializeBlobStorage();

    const artifact = await slot.export("jsonl");
    const lease = await f.registry.acquireBlob(artifact.blobId);
    let exported = Buffer.alloc(0);
    try {
      for await (const chunk of lease.stream) exported = Buffer.concat([exported, Buffer.from(chunk)]);
    } finally {
      await lease.release();
    }

    expect(artifact.name).toMatch(/\.jsonl$/);
    expect(exported).toEqual(before);
    expect(await readFile(chapterPath)).toEqual(before);
    report.cases.push({ case: "home-export-destination", sourceUnchanged: true, destinationIsChapter: false });
  });

  it.each([
    ["canonical bytes", 24 * 1_024 * 1_024 + 1, 3],
    ["canonical entries", 0, 50_001],
  ])("seals lazily after the soft %s threshold at a quiescent boundary", async (_label, bytes, entries) => {
    const f = await fixture(`soft-threshold-${_label.replaceAll(" ", "-")}`);
    disposals.push(async () => { await f.registry.dispose(); await rm(f.root, { recursive: true, force: true }); });
    const slot = await designateHome(f, `e2e-soft-threshold-${bytes}-${entries}`);
    const owner = f.registry.homeOwner() as unknown as {
      options: { sessions: { chapterMetrics?: (sessionId: string) => Promise<{ bytes: number; entries: number; quiescent: boolean }> } };
      chapterQuiescent(sessionId: string): Promise<void>;
    };
    owner.options.sessions.chapterMetrics = async () => ({ bytes, entries, quiescent: true });
    f.faux.setResponses([fauxAssistantMessage("soft threshold crossed")]);
    await slot.prompt("cross the soft Home threshold");
    await waitUntil(async () => {
      const record = JSON.parse(await readFile(join(f.tronHome, "gateway", "home", "home.json"), "utf8")) as HomeRecord;
      return record.chapters.length === 2;
    });
    const stored = JSON.parse(await readFile(join(f.tronHome, "gateway", "home", "home.json"), "utf8")) as HomeRecord;
    expect(stored.chapters).toHaveLength(2);
    expect(stored.chapters[0]).toMatchObject({ state: "sealed", sizeAtSeal: bytes, entriesAtSeal: entries });
    expect(stored.chapters[1]).toMatchObject({ state: "reserved", ordinal: 2 });
    expect(stored.bindingRevision).toBe(1);
    // Lazy rollover: threshold crossing seals and reserves metadata only.
    expect((await f.registry.catalog("all")).sessions.map(session => session.id)).not.toContain(stored.chapters[1]!.sessionId);
    report.cases.push({ case: "soft-rollover", trigger: _label, oldState: stored.chapters[0]!.state, successorState: stored.chapters[1]!.state, successorMaterialized: false });
  });

  it.each(["hard bytes", "hard entries"] as const)("rolls Home admission over before effects at the %s threshold", async boundary => {
    const f = await fixture(`hard-boundary-${boundary.replaceAll(" ", "-")}`);
    disposals.push(async () => { f.service.dispose(); await f.receipts.dispose(); await f.registry.dispose(); await rm(f.root, { recursive: true, force: true }); });
    const slot = await designateHome(f, `e2e-hard-boundary-${boundary.replaceAll(" ", "-")}`);
    const owner = f.registry.homeOwner() as unknown as {
      options: { sessions: { chapterMetrics?: (sessionId: string) => Promise<{ bytes: number; entries: number; quiescent: boolean }> } };
    };
    const hardBytes = 200 * 1_024 * 1_024;
    const hardEntries = 100_000;
    owner.options.sessions.chapterMetrics = async () => ({
      bytes: boundary === "hard bytes" ? hardBytes : 3,
      entries: boundary === "hard entries" ? hardEntries : 3,
      quiescent: true,
    });
    let providerCalls = 0;
    f.faux.setResponses([async () => { providerCalls += 1; return fauxAssistantMessage("successor chapter response"); }]);
    const accepted = await f.service.invoke(client, "home.prompt", {
      commandId: `hard-admission-${boundary.replaceAll(" ", "-")}`,
      text: "must dispatch only after the hard-limit rollover",
    }) as unknown as { sessionId: string; operationId: string };
    expect(accepted.sessionId).not.toBe(slot.id);
    const stored = JSON.parse(await readFile(join(f.tronHome, "gateway", "home", "home.json"), "utf8")) as HomeRecord;
    expect(stored.chapters).toHaveLength(2);
    expect(stored.chapters[0]).toMatchObject({
      state: "sealed",
      ...(boundary === "hard bytes" ? { sizeAtSeal: hardBytes } : { entriesAtSeal: hardEntries }),
    });
    expect(stored.chapters[1]).toMatchObject({ sessionId: accepted.sessionId, ordinal: 2 });
    expect(providerCalls).toBe(0);
    expect(f.homeDiagnostics.filter(record => record.outcome === "chapter-refused")).toEqual([
      { outcome: "chapter-refused", chapterOrdinal: 1, reason: boundary === "hard bytes" ? "hard-bytes" : "hard-entries" },
    ]);
    expect(f.homeDiagnostics.some(record => record.outcome === "chapter-limit-stop")).toBe(false);
    report.cases.push({ case: "hard-admission-signal", boundary: boundary === "hard bytes" ? "hard-bytes" : "hard-entries",
      metricsInjected: true, refusalBeforeEffects: true, successorTarget: true });
  });

  it.each(["bytes", "entries"] as const)("measures cold canonical %s before logical hard admission", async boundary => {
    const f = await fixture(`cold-hard-${boundary}`);
    disposals.push(async () => { f.service.dispose(); await f.receipts.dispose(); await f.registry.dispose(); await rm(f.root, { recursive: true, force: true }); });
    const slot = await designateHome(f, `cold-hard-${boundary}`);
    f.faux.setResponses([fauxAssistantMessage("initial canonical flush")]);
    await prepareThresholdFixture(f, slot, "initialize cold threshold evidence");
    admissionLimits.bytes = 64 * 1_024;
    admissionLimits.entries = boundary === "entries" ? 100 : 100_000;
    for (let index = 0; index < 100 && (boundary === "bytes" ? statSync(slot.sessionFile!).size < admissionLimits.bytes : slot.canonicalEntryCount < admissionLimits.entries); index += 1) {
      slot.sessionManager.appendCustomEntry("admission-fixture", { padding: boundary === "bytes" ? "x".repeat(4_096) : "x" });
    }
    const path = slot.sessionFile!;
    const bytes = await readFile(path);
    const entries = slot.canonicalEntryCount;
    await restart(f);
    f.faux.setResponses([fauxAssistantMessage("cold successor")]);
    const accepted = await f.service.invoke(client, "home.prompt", { commandId: `cold-hard-next-${boundary}`, text: "continue cold Home" }) as unknown as { sessionId: string };
    expect(accepted.sessionId === slot.id).toBe(false);
    expect(await readFile(path)).toEqual(bytes);
    expect(f.homeDiagnostics.some(record => record.outcome === "chapter-refused" && record.reason === `hard-${boundary}`)).toBe(true);
    report.cases.push({ case: "cold-canonical-hard-admission", boundary, bytes: bytes.length, entries,
      hardBytes: admissionLimits.bytes, hardEntries: admissionLimits.entries, metricsInjected: false, successorTarget: true, predecessorUnchanged: true });
  });

  it.each(["bytes", "entries"] as const)("refuses physical prompt effects at real canonical hard %s", async boundary => {
    const f = await fixture(`physical-hard-${boundary}`);
    disposals.push(async () => { f.service.dispose(); await f.receipts.dispose(); await f.registry.dispose(); await rm(f.root, { recursive: true, force: true }); });
    const slot = await designateHome(f, `physical-hard-${boundary}`);
    f.faux.setResponses([fauxAssistantMessage("initial canonical flush")]);
    await prepareThresholdFixture(f, slot, "initialize physical threshold evidence");
    admissionLimits.bytes = 64 * 1_024;
    admissionLimits.entries = boundary === "entries" ? 100 : 100_000;
    for (let index = 0; index < 100 && (boundary === "bytes" ? statSync(slot.sessionFile!).size < admissionLimits.bytes : slot.canonicalEntryCount < admissionLimits.entries); index += 1) {
      slot.sessionManager.appendCustomEntry("admission-fixture", { padding: boundary === "bytes" ? "x".repeat(4_096) : "x" });
    }
    const bytes = await readFile(slot.sessionFile!);
    const calls = f.faux.state.callCount;
    f.faux.setResponses([fauxAssistantMessage("must not run")]);
    const physicalClient = { ...client, isSubscribed: (id: string) => id === slot.id } as ClientContext;
    await expect(f.service.invoke(physicalClient, "session.prompt", { sessionId: slot.id, commandId: `physical-hard-next-${boundary}`, text: "must refuse without redirect" }))
      .rejects.toMatchObject({ code: "conflict", details: { reason: `hard-${boundary}` } });
    expect(await readFile(slot.sessionFile!)).toEqual(bytes);
    expect(f.faux.state.callCount).toBe(calls);
    report.cases.push({ case: "physical-canonical-hard-admission", boundary, bytes: bytes.length, entries: slot.canonicalEntryCount,
      metricsInjected: false, providerCallsAdded: 0, canonicalEffectsAdded: 0, redirected: false });
  });

  it.each(["settings", "archive"] as const)("revalidates physical Home admission after the %s await before canonical effects", async boundary => {
    const f = await fixture(`admission-await-${boundary}`);
    disposals.push(async () => { f.service.dispose(); await f.receipts.dispose(); await f.registry.dispose(); await rm(f.root, { recursive: true, force: true }); });
    const slot = await designateHome(f, `admission-await-${boundary}`);
    f.faux.setResponses([fauxAssistantMessage("initial canonical flush")]);
    await prepareThresholdFixture(f, slot, "initialize await threshold evidence");
    admissionLimits.bytes = 64 * 1_024;
    let release!: () => void;
    const gate = new Promise<void>(resolve => { release = resolve; });
    let entered = false;
    const hold = async () => { entered = true; await gate; };
    const dependencies = slot as unknown as { dependencies: { beforeRunAdmission(): Promise<void> } };
    const held = boundary === "settings"
      ? vi.spyOn(sessionOf(slot).settingsManager, "flush").mockImplementation(hold)
      : vi.spyOn(dependencies.dependencies, "beforeRunAdmission").mockImplementation(hold);
    f.faux.setResponses([fauxAssistantMessage("must not run")]);
    const running = slot.prompt("wait and then refuse before effects");
    void running.catch(() => {});
    let bytes!: Buffer;
    try {
      await waitUntil(() => entered);
      for (let index = 0; index < 20 && statSync(slot.sessionFile!).size < admissionLimits.bytes; index += 1) {
        slot.sessionManager.appendCustomEntry("await-fixture", { padding: "x".repeat(4_096) });
      }
      bytes = await readFile(slot.sessionFile!);
    } finally { release(); }
    await expect(running).rejects.toMatchObject({ code: "conflict", details: { reason: "hard-bytes" } });
    held.mockRestore();
    expect(await readFile(slot.sessionFile!)).toEqual(bytes);
    expect(f.faux.state.callCount).toBe(1);
    report.cases.push({ case: "physical-admission-await", boundary, metricsInjected: false,
      canonicalEffectsAdded: 0, providerCallsAdded: 0 });
  });

  it.each(["completion-first", "abort-first"] as const)("records successful assistant crossings as chapter-limit with %s settlement", async ordering => {
    const f = await fixture(`successful-crossing-${ordering}`);
    disposals.push(async () => { f.service.dispose(); await f.receipts.dispose(); await f.registry.dispose(); await rm(f.root, { recursive: true, force: true }); });
    const slot = await designateHome(f, `successful-crossing-${ordering}`);
    f.faux.setResponses([fauxAssistantMessage("initial canonical flush")]);
    await prepareThresholdFixture(f, slot, "initialize successful threshold evidence");
    admissionLimits.bytes = 64 * 1_024;
    // Canonical custom entries bring the chapter near the byte boundary without
    // crossing it; only the provider's finalized successful message crosses.
    for (let index = 0; index < 20 && statSync(slot.sessionFile!).size < 40 * 1_024; index += 1) {
      slot.sessionManager.appendCustomEntry("response-fixture", { padding: "x".repeat(4_096) });
    }
    const before = statSync(slot.sessionFile!).size;
    expect(before).toBeLessThan(admissionLimits.bytes);
    // Both abort and agent settlement persist through this owner; the wrapper
    // now only adds terminal notification and is not the completion boundary.
    const internal = slot as unknown as { persistInvocationTerminal(...args: unknown[]): Promise<unknown> };
    const terminalize = internal.persistInvocationTerminal.bind(slot);
    let release!: () => void;
    const gate = new Promise<void>(resolve => { release = resolve; });
    let losingObserverEntered = false;
    const held = vi.spyOn(internal, "persistInvocationTerminal").mockImplementation(async (...args) => {
      const abortObserver = args[2] === "chapter-limit";
      if (abortObserver === (ordering === "completion-first")) {
        losingObserverEntered = true;
        await gate;
      }
      return terminalize(...args);
    });
    f.faux.setResponses([fauxAssistantMessage("successful response ".repeat(2_048))]);
    const running = slot.prompt("cross only on the successful response");
    void running.catch(() => {});
    try {
      await waitUntil(() => losingObserverEntered);
      await waitUntil(() => invocationReceipts(slot.sessionManager.getBranch(), slot.id)
        .filter(receipt => receipt.receiptKind === "terminal").length === 2);
      expect(invocationReceipts(slot.sessionManager.getBranch(), slot.id).filter(receipt => receipt.receiptKind === "terminal").at(-1))
        .toMatchObject({ lifecycle: "interrupted", errorCode: "chapter-limit" });
    } finally { release(); held.mockRestore(); }
    await running;
    await waitUntil(() => slot.snapshot().configurationBlocker === null && f.homeDiagnostics.some(record => record.outcome === "chapter-limit-stop"));
    const lastTerminal = invocationReceipts(slot.sessionManager.getBranch(), slot.id).filter(receipt => receipt.receiptKind === "terminal").at(-1)!;
    expect(lastTerminal).toMatchObject({ lifecycle: "interrupted", errorCode: "chapter-limit" });
    expect(slot.sessionManager.getBranch().some(entry => entry.type === "message" && entry.message.role === "assistant"
      && entry.message.stopReason === "stop" && JSON.stringify(entry.message.content).includes("successful response"))).toBe(true);
    expect(f.faux.state.callCount).toBe(2);
    report.cases.push({ case: "successful-response-hard-crossing", ordering, beforeBytes: before, settledBytes: statSync(slot.sessionFile!).size,
      hardBytes: admissionLimits.bytes, metricsInjected: false, providerCallsAdded: 1, lifecycle: lastTerminal.lifecycle, reason: lastTerminal.errorCode });
  });

  it("stops a real canonical input crossing before provider dispatch", async () => {
    const f = await fixture("real-input-crossing");
    disposals.push(async () => { f.service.dispose(); await f.receipts.dispose(); await f.registry.dispose(); await rm(f.root, { recursive: true, force: true }); });
    const slot = await designateHome(f, "real-input-crossing");
    f.faux.setResponses([fauxAssistantMessage("initial canonical flush")]);
    await prepareThresholdFixture(f, slot, "initialize input crossing evidence");
    admissionLimits.bytes = 64 * 1_024;
    const before = statSync(slot.sessionFile!).size;
    f.faux.setResponses([fauxAssistantMessage("must not reach provider")]);
    await slot.prompt("input crossing ".repeat(5_000));
    await waitUntil(() => slot.snapshot().configurationBlocker === null);
    expect(f.faux.state.callCount).toBe(1);
    await waitUntil(() => f.homeDiagnostics.some(record => record.outcome === "chapter-limit-stop"));
    expect(invocationReceipts(slot.sessionManager.getBranch(), slot.id).filter(receipt => receipt.receiptKind === "terminal").at(-1))
      .toMatchObject({ lifecycle: "interrupted", errorCode: "chapter-limit" });
    report.cases.push({ case: "real-input-hard-crossing", beforeBytes: before, settledBytes: statSync(slot.sessionFile!).size,
      hardBytes: admissionLimits.bytes, metricsInjected: false, providerCallsAdded: 0, reason: "chapter-limit" });
  });

  it("continues in a successor after a real hard-byte stop retains an oversized chapter", async () => {
    const f = await fixture("real-byte-stop-successor");
    disposals.push(async () => { f.service.dispose(); await f.receipts.dispose(); await f.registry.dispose(); await rm(f.root, { recursive: true, force: true }); });
    const slot = await designateHome(f, "real-byte-stop-home");
    f.faux.setResponses([fauxAssistantMessage("initial canonical flush")]);
    await prepareThresholdFixture(f, slot, "initialize canonical evidence");
    let release!: () => void;
    const gate = new Promise<void>(resolve => { release = resolve; });
    let entered = false;
    f.faux.setResponses([async () => { entered = true; await gate; return fauxAssistantMessage("abort settlement"); }]);
    const running = slot.prompt("stop this operation at the byte limit");
    void running.catch(() => {});
    try {
      await waitUntil(() => entered);
      const padding = "x".repeat(1_024 * 1_024);
      // Real canonical SDK appends cross the byte boundary while the provider is
      // running; no metric getter is substituted and no append is suppressed.
      for (let index = 0; index < 201 && statSync(slot.sessionFile!).size < 200 * 1_024 * 1_024; index += 1) {
        slot.sessionManager.appendCustomEntry("byte-stop-fixture", { padding: index === 190 ? padding.repeat(11) : padding });
      }
    } finally { release(); }
    await running;
    await waitUntil(() => slot.snapshot().configurationBlocker === null);
    const before = statSync(slot.sessionFile!).size;
    expect(before).toBeGreaterThan(200 * 1_024 * 1_024);
    await expect(scanReservedHomeSession({ directory: dirname(slot.sessionFile!), expectedPath: slot.sessionFile!, sessionId: slot.id }))
      .resolves.toEqual({ action: "blocked" });
    expect(f.homeDiagnostics.filter(record => record.outcome === "chapter-limit-stop"))
      .toMatchObject([{ boundary: "hard-bytes" }]);
    expect(invocationReceipts(slot.sessionManager.getBranch(), slot.id)
      .find(receipt => receipt.receiptKind === "terminal" && receipt.errorCode === "chapter-limit")).toBeDefined();
    f.faux.setResponses([async context => {
      expect(JSON.stringify(context.messages)).toContain("initialize canonical evidence");
      return fauxAssistantMessage("successor continues");
    }]);
    const accepted = await f.service.invoke(client, "home.prompt", { commandId: "real-byte-stop-next", text: "continue after the stopped chapter" }) as unknown as { sessionId: string; operationId: string };
    expect(accepted.sessionId).not.toBe(slot.id);
    const ledger = JSON.parse(await readFile(join(f.tronHome, "gateway", "home", "home.json"), "utf8")) as HomeRecord;
    expect(ledger.chapters[0]).toMatchObject({ state: "sealed", sizeAtSeal: before });
    const successor = await f.registry.acquire(accepted.sessionId);
    await waitUntil(() => successor.snapshot().configurationBlocker === null && successor.sessionManager.getBranch().some(entry => entry.type === "message"
      && entry.message.role === "assistant" && JSON.stringify(entry.message.content).includes("successor continues")));
    expect(successor.sessionManager.getBranch().some(entry => entry.type === "message"
      && entry.message.role === "user" && JSON.stringify(entry.message.content).includes("continue after the stopped chapter"))).toBe(true);
    expect(f.faux.state.callCount).toBe(3);
    expect(statSync(slot.sessionFile!).size).toBe(before);
    const stop = f.homeDiagnostics.find(record => record.outcome === "chapter-limit-stop")!;
    report.cases.push({ case: "real-byte-stop-successor", metricsInjected: false, retainedBytes: before,
      crossingBytes: stop.crossingBytes, settledBytes: stop.settledBytes, boundary: stop.boundary,
      predecessorSealed: true, predecessorUnchanged: true, crossingEntryOver8MiB: true, successorPrompted: true, priorMemoryPresent: true });
  }, 30_000);

  it("refuses a cyclic cold Home file before SDK construction", async () => {
    const f = await fixture("cyclic-cold-home");
    disposals.push(async () => { f.service.dispose(); await f.receipts.dispose(); await f.registry.dispose(); await rm(f.root, { recursive: true, force: true }); });
    const slot = await designateHome(f, "cyclic-cold-home");
    f.faux.setResponses([fauxAssistantMessage("initial canonical flush")]);
    await slot.prompt("initialize canonical evidence");
    const path = slot.sessionFile!;
    await restart(f);
    const original = await readFile(path, "utf8");
    const malformed = original + JSON.stringify({ type: "thinking_level_change", id: "cycle", parentId: "cycle",
      timestamp: "2026-10-07T00:00:00.000Z", thinkingLevel: "off" }) + "\n";
    await writeFile(path, malformed);
    // Do not let the negative control enter Pi's unbounded parent traversal.
    const open = vi.spyOn(SessionManager, "open").mockImplementation(() => { throw new Error("unsafe SDK construction reached"); });
    await expect(f.registry.acquire(slot.id)).rejects.toThrow(/uncertain canonical evidence/);
    expect(open).not.toHaveBeenCalled();
    expect(await readFile(path, "utf8")).toBe(malformed);
    report.cases.push({ case: "cyclic-cold-home", sdkConstructions: 0, canonicalPreserved: true });
  });

  it("stops one running Home operation on its first canonical hard-entry crossing and retains its writes", async () => {
    const f = await fixture("hard-running-crossing");
    disposals.push(async () => { f.service.dispose(); await f.receipts.dispose(); await f.registry.dispose(); await rm(f.root, { recursive: true, force: true }); });
    const slot = await designateHome(f, "e2e-hard-running-crossing");
    f.faux.setResponses([fauxAssistantMessage("initial canonical flush")]);
    await prepareThresholdFixture(f, slot, "initialize entry crossing evidence");
    admissionLimits.entries = 100;
    for (let index = 0; index < 100 && slot.canonicalEntryCount < 90; index += 1) {
      slot.sessionManager.appendCustomEntry("entry-crossing-fixture", { padding: "x" });
    }
    let release!: () => void;
    const gate = new Promise<void>(resolve => { release = resolve; });
    let providerCalls = 0;
    f.faux.setResponses([async () => { providerCalls += 1; await gate; return fauxAssistantMessage("settlement response retained"); }]);
    const running = slot.prompt("cross while running");
    void running.catch(() => {});
    try {
      await waitUntil(() => providerCalls === 1);
      for (let index = 0; index < 100 && slot.canonicalEntryCount < admissionLimits.entries; index += 1) {
        slot.sessionManager.appendCustomEntry("entry-crossing-fixture", { padding: "x" });
      }
    } finally { release(); }
    await running;
    await waitUntil(() => slot.snapshot().configurationBlocker === null && f.homeDiagnostics.some(record => record.outcome === "chapter-limit-stop"));
    const stopped = f.homeDiagnostics.filter(record => record.outcome === "chapter-limit-stop");
    const branch = slot.sessionManager.getBranch();
    const canonical = (await readFile(slot.sessionFile!, "utf8")).trimEnd().split("\n").map(line => JSON.parse(line));
    expect(stopped).toHaveLength(1);
    expect(stopped[0]).toMatchObject({ boundary: "hard-entries", crossingEntries: 100 });
    expect(stopped[0]!.settledEntries).toBeGreaterThanOrEqual(100);
    expect(branch).toEqual(canonical.slice(1));
    expect(invocationReceipts(branch, slot.id).filter(receipt => receipt.receiptKind === "terminal").at(-1)?.errorCode).toBe("chapter-limit");
    expect(providerCalls).toBe(1);
    expect(f.homeDiagnostics.some(record => record.outcome === "chapter-refused" && record.reason === "hard-entries")).toBe(false);
    const persisted = new GatewayLogger(join(f.root, "home-signals.jsonl")).recent(100)
      .filter(record => record.event === "home.chapter-limit-stop");
    expect(persisted).toHaveLength(1);
    expect(persisted[0]).toMatchObject({ level: "warning", chapterOrdinal: 1, boundary: "hard-entries",
      crossingBytes: stopped[0]!.crossingBytes, crossingEntries: 100,
      settledBytes: stopped[0]!.settledBytes, settledEntries: stopped[0]!.settledEntries });
    report.cases.push({ case: "persisted-home-running-stop", canonicalMatchesSdk: true, metricsInjected: false,
      hardEntries: admissionLimits.entries, crossingEntries: 100, settledEntries: stopped[0]!.settledEntries,
      providerCallsAdded: providerCalls, signalRetainedOnReload: true });
  });

  it.each([
    ["attention", "mutation-first"], ["attention", "seal-first"],
    ["archive", "mutation-first"], ["archive", "seal-first"],
    ["delete", "mutation-first"], ["delete", "seal-first"],
  ] as const)("serializes Registry %s and Home seal in %s order", async (kind, order) => {
    const f = await fixture(`${kind}-${order}`);
    disposals.push(async () => { await f.registry.dispose(); await rm(f.root, { recursive: true, force: true }); });
    const slot = await designateHome(f, `${kind}-${order}-home`);
    f.faux.setResponses([fauxAssistantMessage("canonical race evidence")]);
    await slot.prompt("initialize race evidence");
    await waitUntil(() => slot.snapshot().configurationBlocker === null);
    const path = slot.sessionFile!;
    const bytes = await readFile(path, "utf8");
    const registry = f.registry as unknown as {
      resolveAttentionAdmission(sessionId: string): Promise<unknown>;
      catalogMembership(sessionId: string): Promise<unknown>;
      sessionMutations: Map<string, Promise<void>>;
    };
    const owner = f.registry.homeOwner() as unknown as {
      options: { sessions: { chapterMetrics: (id: string) => Promise<{ bytes: number; entries: number; quiescent: boolean }> } };
      writeLocked(record: HomeRecord): Promise<void>;
    };
    owner.options.sessions.chapterMetrics = async () => ({ bytes: 24 * 1_024 * 1_024 + 1, entries: 3, quiescent: true });
    let entered!: () => void;
    let release!: () => void;
    const reached = new Promise<void>(resolve => { entered = resolve; });
    const gate = new Promise<void>(resolve => { release = resolve; });
    const events: string[] = [];
    const write = owner.writeLocked.bind(owner);
    vi.spyOn(owner, "writeLocked").mockImplementation(async record => {
      if (record.chapters[0]!.state === "sealed") {
        events.push("seal-commit");
        if (order === "seal-first") { entered(); await gate; }
      }
      await write(record);
    });
    if (order === "mutation-first") {
      const seam = kind === "attention" ? "resolveAttentionAdmission" : "catalogMembership";
      const resolve = registry[seam].bind(registry);
      vi.spyOn(registry, seam).mockImplementation(async id => {
        entered();
        await gate;
        return resolve(id);
      });
    }
    const mutate = () => (kind === "attention" ? f.registry.setAttention(slot.id, true)
      : kind === "archive" ? f.registry.setArchived(slot.id, true) : f.registry.delete(slot.id))
      .then(() => { events.push("mutation-settled"); return "accepted"; }, error => {
        events.push("mutation-refused"); return (error as { code?: string }).code;
      });
    let mutation: ReturnType<typeof mutate> | undefined;
    let seal: Promise<void> | undefined;
    try {
      if (order === "mutation-first") {
        mutation = mutate();
        await awaitsWithin(reached, "admitted mutation barrier");
        seal = f.registry.homeOwner().chapterQuiescent(slot.id);
        // The serializer must still be waiting behind admitted mutation work.
        // This microtask cut joins enqueue, not a filesystem scheduling sleep.
        await Promise.resolve();
        expect(events).toEqual([]);
        release();
        expect(await awaitsWithin(mutation, "mutation settlement")).toBe("accepted");
        await awaitsWithin(seal, "seal after mutation");
        expect(events).toEqual(["mutation-settled", "seal-commit"]);
      } else {
        seal = f.registry.homeOwner().chapterQuiescent(slot.id);
        await awaitsWithin(reached, "seal commit barrier");
        mutation = mutate();
        release();
        await awaitsWithin(seal, "seal settlement");
        expect(await awaitsWithin(mutation, "mutation after seal")).toBe("conflict");
        expect(events).toEqual(["seal-commit", "mutation-refused"]);
      }
      expect(f.registry.homeOwner().chapterStateFor(slot.id).sealed).toBe(true);
      if (kind !== "delete" || order === "seal-first") expect(await readFile(path, "utf8")).toBe(bytes);
      else await expect(readFile(path)).rejects.toMatchObject({ code: "ENOENT" });
      expect(registry.sessionMutations.has(slot.id)).toBe(false);
      report.cases.push({ case: `registry-${kind}-${order}`, events, serializerRetired: true });
    } finally {
      release();
      await Promise.allSettled([...(mutation ? [mutation] : []), ...(seal ? [seal] : [])]);
    }
  });

  it("retires a failed Registry mutation and admits the next exact-session mutation", async () => {
    const f = await fixture("mutation-failure");
    disposals.push(async () => { await f.registry.dispose(); await rm(f.root, { recursive: true, force: true }); });
    const slot = await designateHome(f, "mutation-failure-home");
    const registry = f.registry as unknown as {
      resolveAttentionAdmission(id: string): Promise<unknown>;
      sessionMutations: Map<string, Promise<void>>;
    };
    vi.spyOn(registry, "resolveAttentionAdmission").mockRejectedValueOnce(new Error("fixture admission failure"));
    const failed = f.registry.setAttention(slot.id, true);
    const next = f.registry.setAttention(slot.id, true);
    await expect(failed).rejects.toThrow("fixture admission failure");
    await next;
    expect(f.registry.attentionProjection(slot.id).isUnread).toBe(true);
    expect(registry.sessionMutations.has(slot.id)).toBe(false);
    report.cases.push({ case: "registry-mutation-failure-recovery", unread: true, serializerRetired: true });
  });

  it("recovers a durable reservation after restart and routes the next activation to one successor", async () => {
    const f = await fixture("reserved-crash-recovery");
    disposals.push(async () => { await f.registry.dispose(); await rm(f.root, { recursive: true, force: true }); });
    const oldSlot = await designateHome(f, "e2e-reservation-crash-designate");
    f.faux.setResponses([fauxAssistantMessage("recovered successor reply")]);
    await oldSlot.prompt("BEFORE-ROLLOVER-FACT: the lighthouse is blue");
    await waitUntil(() => oldSlot.snapshot().configurationBlocker === null);
    const owner = f.registry.homeOwner() as unknown as {
      options: { sessions: { chapterMetrics?: (sessionId: string) => Promise<{ bytes: number; entries: number; quiescent: boolean }> } };
      chapterQuiescent(sessionId: string): Promise<void>;
    };
    owner.options.sessions.chapterMetrics = async () => ({ bytes: 24 * 1_024 * 1_024 + 1, entries: 3, quiescent: true });
    await owner.chapterQuiescent(oldSlot.id);
    const current = JSON.parse(await readFile(join(f.tronHome, "gateway", "home", "home.json"), "utf8")) as HomeRecord;
    const reservedId = current.chapters.at(-1)!.sessionId;
    expect(current.chapters.at(-1)).toMatchObject({ state: "reserved", ordinal: 2 });
    await f.registry.dispose();
    const registeredIndex = registries.indexOf(f.registry);
    if (registeredIndex >= 0) registries.splice(registeredIndex, 1);
    openRegistry(f);
    await f.registry.initialize();
    const catalogCut = () => (f.registry as unknown as { sessionCatalog: { hasCompleteCut(): boolean } }).sessionCatalog.hasCompleteCut();
    await waitUntil(() => catalogCut(), 20_000);
    const recoveredCatalog = await f.registry.catalog("all");
    expect(recoveredCatalog.sessions.map(session => session.id)).toContain(oldSlot.id);

    const opened = await f.service.invoke(client, "home.open", {}) as unknown as {
      homeId: string; bindingRevision: number; sessionId: string;
    };
    expect(opened).toMatchObject({ homeId: current.homeId, bindingRevision: current.bindingRevision + 1, sessionId: reservedId, chapterState: "reserved" });
    expect((await f.registry.catalog("all")).sessions.map(session => session.id)).not.toContain(reservedId);
    f.faux.setResponses([fauxAssistantMessage("after reservation recovery")]);
    const accepted = await f.service.invoke(client, "home.prompt", {
      commandId: "e2e-home-prompt-after-reservation", text: "AFTER-ROLLOVER-FACT: the bell rings twice",
    }) as unknown as { sessionId: string; operationId: string };
    await waitUntil(async () => {
      const status = await f.service.invoke(client, "home.status", {}) as unknown as HomeStatus;
      return status.sessionId === reservedId && (status.phase === "active" || status.phase === "ready");
    }, 30_000);
    expect(accepted.sessionId).toBe(reservedId);
    expect(accepted.operationId).toBeTypeOf("string");
    const status = await f.service.invoke(client, "home.status", {}) as unknown as HomeStatus;
    expect(status).toMatchObject({ sessionId: reservedId, bindingRevision: current.bindingRevision + 1 });
  });

  it("preserves and blocks a recorded materialization path that is absent after restart", async () => {
    const f = await fixture("recorded-home-path-absent");
    disposals.push(async () => { await f.registry.dispose(); await rm(f.root, { recursive: true, force: true }); });
    await designateHome(f, "e2e-recorded-path-absent");
    const registry = f.registry as unknown as {
      homeOwner(): { writeLocked(record: HomeRecord): Promise<void> };
      sessionDirectoryFor(cwd: string): string;
      home: { homeWorkspacePath(): string };
      materializeReservedHome(sessionId: string): Promise<unknown>;
    };
    const owner = f.registry.homeOwner() as unknown as { writeLocked(record: HomeRecord): Promise<void> };
    const current = JSON.parse(await readFile(join(f.tronHome, "gateway", "home", "home.json"), "utf8")) as HomeRecord;
    const active = current.chapters[0]!;
    const reservedId = "recorded-path-absent-session";
    const expectedPath = join(registry.sessionDirectoryFor(registry.home.homeWorkspacePath()), "missing-recorded-path.jsonl");
    await owner.writeLocked({
      ...current,
      chapters: [
        { ...active, state: "sealed", sealedAt: new Date().toISOString() },
        { sessionId: reservedId, ordinal: 2, state: "materializing", activationStarted: false, createdAt: new Date().toISOString(), attemptId: "old-attempt", expectedPath },
      ],
    });

    await expect(f.registry.materializeReservedHome(reservedId)).rejects.toMatchObject({ code: "conflict" });
    await expect(readFile(expectedPath)).rejects.toMatchObject({ code: "ENOENT" });
    const recovered = JSON.parse(await readFile(join(f.tronHome, "gateway", "home", "home.json"), "utf8")) as HomeRecord;
    expect(recovered.chapters.at(-1)).toMatchObject({ state: "materializing", expectedPath });
  });

  it.each([
    ["reserved", false], ["reserved", true], ["cold", false], ["cold", true],
  ] as const)("owns in-flight %s construction while transitioning enabled to %s", async (construction, enabled) => {
    const f = await fixture(`profile-construction-${construction}-${enabled}`);
    disposals.push(async () => { f.service.dispose(); await f.receipts.dispose(); await f.registry.dispose(); await rm(f.root, { recursive: true, force: true }); });
    const active = await designateHome(f, `profile-flight-${construction}-${enabled}`);
    f.faux.setResponses([fauxAssistantMessage("profile construction baseline")]);
    await active.prompt("profile construction baseline input");
    await waitUntil(() => active.snapshot().configurationBlocker === null);
    let sessionId = active.id;
    if (construction === "reserved") {
      const owner = f.registry.homeOwner();
      const port = (owner as unknown as { options: { sessions: { chapterMetrics: (id: string) => Promise<unknown> } } }).options.sessions;
      const metrics = vi.spyOn(port, "chapterMetrics").mockResolvedValue({ bytes: 24 * 1_024 * 1_024 + 1, entries: 3, quiescent: true });
      await owner.chapterQuiescent(active.id);
      metrics.mockRestore();
      sessionId = owner.routeBinding().physicalSessionId;
    }
    if (enabled) await f.registry.homeOwner().disable();
    if (construction === "cold") await restart(f);
    let reached!: () => void;
    let release!: () => void;
    const entered = new Promise<void>(resolve => { reached = resolve; });
    const held = new Promise<void>(resolve => { release = resolve; });
    runtimeServices.hold = async () => { reached(); await held; };
    const flight = construction === "reserved" ? f.registry.materializeReservedHome(sessionId) : f.registry.acquire(sessionId);
    void flight.catch(() => {});
    let transition: Promise<unknown> | undefined;
    try {
      await awaitsWithin(entered, "latched runtime profile before services");
      const owner = f.registry.homeOwner() as unknown as {
        writeLocked: (record: HomeRecord) => Promise<void>;
        options: { sessions: { replaceRuntimeForProfile: (id: string, commit: () => Promise<void>) => Promise<void> } };
      };
      let transitionReached!: () => void;
      const changing = new Promise<void>(resolve => { transitionReached = resolve; });
      const originalPort = owner.options.sessions.replaceRuntimeForProfile;
      vi.spyOn(owner.options.sessions, "replaceRuntimeForProfile").mockImplementation((...args) => {
        const result = originalPort(...args); transitionReached(); return result;
      });
      // The unfixed disable bypasses Registry entirely for an unpublished
      // reservation. Observe that old commit cut too, without rescuing it.
      const originalWrite = owner.writeLocked.bind(owner);
      vi.spyOn(owner, "writeLocked").mockImplementation(record => {
        const result = originalWrite(record); transitionReached(); return result;
      });
      transition = enabled
        ? f.registry.homeOwner().designate({ model: OTHER_MODEL }, () => MODEL)
        : f.registry.homeOwner().disable();
      void transition.catch(() => {});
      await awaitsWithin(changing, "profile transition owner entered");
      release();
      const slot = await awaitsWithin(flight, "profile construction completion");
      await awaitsWithin(transition, "profile transition completion");
      const profile = (slot as unknown as { liveProfile: () => string }).liveProfile();
      expect(profile).toBe(enabled ? "home" : "ordinary");
      expect(f.registry.homeOwner().profileFor(slot.id)).toBe(profile);
      expect(await f.registry.acquire(sessionId)).toBe(slot);
      if (enabled) expect(slot.snapshot().model).toMatchObject(OTHER_MODEL);
      report.cases.push({ case: "in-flight-profile-transition", construction, enabled, publishedProfile: profile, exactIdentity: slot.id === sessionId });
    } finally {
      release();
      await Promise.allSettled([flight, ...(transition ? [transition] : [])]);
    }
  }, 30_000);

  it("settles a failed Home construction before committing disable", async () => {
    const f = await fixture("failed-profile-construction");
    disposals.push(async () => { f.service.dispose(); await f.receipts.dispose(); await f.registry.dispose(); await rm(f.root, { recursive: true, force: true }); });
    const active = await designateHome(f, "failed-profile-flight");
    const owner = f.registry.homeOwner();
    const port = (owner as unknown as { options: { sessions: { chapterMetrics: (id: string) => Promise<unknown> } } }).options.sessions;
    const metrics = vi.spyOn(port, "chapterMetrics").mockResolvedValue({ bytes: 24 * 1_024 * 1_024 + 1, entries: 3, quiescent: true });
    await owner.chapterQuiescent(active.id);
    metrics.mockRestore();
    const sessionId = owner.routeBinding().physicalSessionId;
    let reached!: () => void;
    let release!: () => void;
    const entered = new Promise<void>(resolve => { reached = resolve; });
    const held = new Promise<void>(resolve => { release = resolve; });
    runtimeServices.hold = async () => { reached(); await held; throw new Error("fixture service construction failed"); };
    const flight = f.registry.materializeReservedHome(sessionId);
    void flight.catch(() => {});
    let transition: Promise<unknown> | undefined;
    try {
      await awaitsWithin(entered, "failed construction barrier");
      transition = owner.disable();
      void transition.catch(() => {});
      release();
      await expect(flight).rejects.toThrow("fixture service construction failed");
      await awaitsWithin(transition, "disable after failed construction");
      expect((await owner.status()).enabled).toBe(false);
      expect((f.registry as unknown as { slots: Map<string, RuntimeSlot> }).slots.has(sessionId)).toBe(false);
      report.cases.push({ case: "failed-profile-construction", enabled: false, staleRuntimePublished: false });
    } finally {
      release();
      await Promise.allSettled([flight, ...(transition ? [transition] : [])]);
    }
  }, 30_000);

  it.each(["reserved", "materializing"] as const)("rebuilds a live runtime when re-enabling a pending %s chapter", async state => {
    const f = await fixture(`reenable-pending-${state}`);
    disposals.push(async () => { await f.registry.dispose(); await rm(f.root, { recursive: true, force: true }); });
    const active = await designateHome(f, `e2e-reenable-${state}`);
    const pending = await f.registry.create(f.agentDir);
    const owner = f.registry.homeOwner() as unknown as { writeLocked(record: HomeRecord): Promise<void> };
    const current = JSON.parse(await readFile(join(f.tronHome, "gateway", "home", "home.json"), "utf8")) as HomeRecord;
    const attemptId = "attempt-reenable";
    const expectedPath = pending.sessionFile!;
    await owner.writeLocked({
      ...current,
      chapters: [
        { ...current.chapters[0]!, state: "sealed", sealedAt: new Date().toISOString() },
        {
          sessionId: pending.id, ordinal: 2, state, activationStarted: false, createdAt: new Date().toISOString(),
          ...(state === "materializing" ? { attemptId, expectedPath } : {}),
        },
      ],
    });
    await f.registry.homeOwner().disable();
    const afterDisable = pending.snapshot().revision;
    const designation = await f.registry.homeOwner().designate({ model: OTHER_MODEL }, () => ({ provider: "faux", id: "test" }));
    expect(designation).toMatchObject({ sessionId: pending.id });
    expect(pending.snapshot().revision).toBeGreaterThan(afterDisable);
    expect(pending.snapshot().model).toMatchObject(OTHER_MODEL);
    const stored = JSON.parse(await readFile(join(f.tronHome, "gateway", "home", "home.json"), "utf8")) as HomeRecord;
    expect(stored.model).toEqual(OTHER_MODEL);
    expect(stored.chapters.map(chapter => [chapter.sessionId, chapter.state])).toEqual([
      [active.id, "sealed"], [pending.id, state],
    ]);
    if (state === "materializing") {
      expect(stored.chapters.at(-1)).toMatchObject({ attemptId, expectedPath });
    }
    report.cases.push({ case: "re-enable-pending-reservation", state, preservedSessionId: pending.id, runtimeRevisionAdvanced: pending.snapshot().revision > afterDisable });
  });

  it("keeps one homeId memory stream continuous across a crash and physical chapter boundary", async () => {
    const f = await fixture("chapter-memory-continuity");
    disposals.push(async () => { await f.registry.dispose(); await rm(f.root, { recursive: true, force: true }); });
    const oldSlot = await designateHome(f, "e2e-memory-chapter-designate");
    const beforeRequests: CapturedRequest[] = [];
    f.faux.setResponses([responsesOf(f, beforeRequests)("before chapter response")]);
    await oldSlot.prompt("CONTINUITY-FACT: the brass key is under the red bowl");
    await waitUntil(() => oldSlot.snapshot().configurationBlocker === null);
    const owner = f.registry.homeOwner() as unknown as {
      options: { sessions: { chapterMetrics?: (sessionId: string) => Promise<{ bytes: number; entries: number; quiescent: boolean }> } };
      chapterQuiescent(sessionId: string): Promise<void>;
    };
    owner.options.sessions.chapterMetrics = async () => ({ bytes: 24 * 1_024 * 1_024 + 1, entries: 3, quiescent: true });
    await owner.chapterQuiescent(oldSlot.id);
    const current = JSON.parse(await readFile(join(f.tronHome, "gateway", "home", "home.json"), "utf8")) as HomeRecord;
    const reservedId = current.chapters.at(-1)!.sessionId;
    expect(current.chapters.at(-1)).toMatchObject({ state: "reserved", ordinal: 2 });
    await f.registry.dispose();
    const registeredIndex = registries.indexOf(f.registry);
    if (registeredIndex >= 0) registries.splice(registeredIndex, 1);
    openRegistry(f);
    await f.registry.initialize();
    const catalogCut = () => (f.registry as unknown as { sessionCatalog: { hasCompleteCut(): boolean } }).sessionCatalog.hasCompleteCut();
    await waitUntil(() => catalogCut(), 20_000);
    const recoveredCatalog = await f.registry.catalog("all");
    expect(recoveredCatalog.sessions.map(session => session.id)).toContain(oldSlot.id);
    const afterRequests: CapturedRequest[] = [];
    f.faux.setResponses([responsesOf(f, afterRequests)("after chapter response")]);
    await f.service.invoke(client, "home.prompt", {
      commandId: "e2e-home-prompt-after-rollover", text: "Where is the brass key?",
    });
    await waitUntil(() => afterRequests.length === 1, 30_000);
    expect(viewOf(afterRequests[0]!)).toContain("CONTINUITY-FACT");
    const after = await f.service.invoke(client, "home.status", {}) as unknown as HomeStatus;
    expect(after).toMatchObject({ homeId: current.homeId, sessionId: reservedId });
    expect(beforeRequests).toHaveLength(1);
  });

  describe("memory browser contract", () => {
    async function browserFixture(label: string) {
      const f = await fixture(`browser-${label}`);
      disposals.push(async () => { f.service.dispose(); await f.receipts.dispose(); await f.registry.dispose(); await rm(f.root, { recursive: true, force: true }); });
      const old = await designateHome(f, `browser-${label}-designate`);
      f.faux.setResponses([fauxAssistantMessage("first chapter reply")]);
      await old.prompt("first chapter fact");
      await waitUntil(() => !old.isBusy);
      await f.service.invoke(client, "home.pauseMemory", { commandId: `browser-${label}-pause` });
      const owner = f.registry.homeOwner() as unknown as {
        options: { sessions: { chapterMetrics?: (id: string) => Promise<{ bytes: number; entries: number; quiescent: boolean }> } };
        chapterQuiescent(id: string): Promise<void>;
      };
      const metrics = owner.options.sessions.chapterMetrics!;
      owner.options.sessions.chapterMetrics = async () => ({ bytes: 24 * 1_024 * 1_024 + 1, entries: 3, quiescent: true });
      try { await owner.chapterQuiescent(old.id); } finally { owner.options.sessions.chapterMetrics = metrics; }
      // Logical Home materializes the next chapter, but paused memory refuses dispatch.
      await f.service.invoke(client, "home.prompt", { commandId: `browser-${label}-next`, text: "second chapter fact" });
      const status = await f.service.invoke(client, "home.status", {}) as unknown as HomeStatus;
      const current = await f.registry.acquire(status.sessionId!);
      await waitUntil(async () => !current.isBusy &&
        (await f.service.invoke(client, "home.status", {}) as unknown as HomeStatus).chapter?.recoveryDecision === "none");
      const canonical = `head Bearer fixture-token-123456789 ${"💡canonical body ".repeat(4000)} tail`;
      const entryId = current.sessionManager.appendMessage({ role: "toolResult", toolCallId: "browser-call", toolName: "read",
        content: [{ type: "text", text: canonical }], isError: false, timestamp: Date.now() });
      return { f, old, current, canonical, entryId };
    }
    const page = async (f: Fixture, params: Record<string, unknown> = {}) =>
      await f.service.invoke(client, "home.memory.page", params) as unknown as HomeMemoryPage;

    it("bounds and replays pages across chapters, separating projection from exact canonical evidence", async () => {
      const { f, old, current, canonical, entryId } = await browserFixture("pages");
      const before = [await readFile(old.sessionFile!, "utf8"), await readFile(current.sessionFile!, "utf8")];
      const first = await page(f, { limit: 2 });
      expect(first.nextCursor).toBeDefined();
      const continuationBeforeRestart = await page(f, { limit: 2, cursor: first.nextCursor });
      const items = [...first.items];
      let next = first.nextCursor;
      for (let step = 0; next && step < 30; step += 1) {
        const result = await page(f, { limit: 2, cursor: next });
        expect(await page(f, { limit: 2, cursor: next })).toEqual(result);
        expect(result.items.length).toBeLessThanOrEqual(2);
        expect(Buffer.byteLength(JSON.stringify(result))).toBeLessThanOrEqual(128 * 1024);
        expect(result.revision).toBe(first.revision);
        items.push(...result.items); next = result.nextCursor;
      }
      expect(next).toBeUndefined();
      expect(new Set(items.map(item => item.index)).size).toBe(items.length);
      expect(items).toHaveLength(first.totalItems);
      expect(new Set(items.map(item => item.evidence.sessionId))).toEqual(new Set([old.id, current.id]));
      const projected = items.find(item => item.evidence.entryId === entryId)!;
      expect(projected).toMatchObject({ kind: "echo", attribution: "tool", projection: { format: "memory-projection" } });
      expect(projected.timestamp).toEqual(expect.any(String));
      expect(projected.projection.omissions).toEqual(expect.arrayContaining(["credentials", "capped", "browser-cap"]));
      expect(projected.projection.text).not.toContain("fixture-token");
      expect(projected.projection.text.length).toBeLessThanOrEqual(4096);
      let exact = "";
      let offset = 0;
      for (let step = 0; step < 30; step += 1) {
        const evidence = await f.service.invoke(client, "home.memory.evidence", { evidence: projected.evidence, offset }) as unknown as HomeMemoryEvidencePage;
        expect(evidence.format).toBe("canonical-history");
        expect(evidence.evidence).toEqual(projected.evidence);
        expect(evidence.text.length).toBeLessThanOrEqual(24 * 1024);
        exact += evidence.text;
        if (evidence.nextOffset === undefined) break;
        offset = evidence.nextOffset;
      }
      expect(exact).toBe(canonical);
      await expect(f.service.invoke(client, "home.memory.evidence", { evidence: projected.evidence, offset: canonical.length + 1 })).rejects.toMatchObject({ code: "invalid_request" });
      await expect(page(f, { limit: 1, cursor: first.nextCursor })).rejects.toMatchObject({ code: "invalid_request" });
      const outOfRange = Buffer.from(JSON.stringify({ revision: first.revision, offset: first.totalItems + 1, limit: 2 })).toString("base64url");
      await expect(page(f, { limit: 2, cursor: outOfRange })).rejects.toMatchObject({ code: "conflict" });
      for (const invalid of [ { ...projected.evidence, sessionId: old.id }, { ...projected.evidence, entryId: "missing" },
        { ...projected.evidence, sourceDigest: "0".repeat(64) } ]) {
        await expect(f.service.invoke(client, "home.memory.evidence", { evidence: invalid })).rejects.toMatchObject({ code: "conflict" });
      }
      expect([await readFile(old.sessionFile!, "utf8"), await readFile(current.sessionFile!, "utf8")]).toEqual(before);
      await restart(f);
      expect(await page(f, { limit: 2 })).toEqual(first);
      expect(await page(f, { limit: 2, cursor: first.nextCursor })).toEqual(continuationBeforeRestart);
      report.cases.push({ case: "memory-browser-pages-and-evidence", chapters: 2, items: items.length,
        projectionOmissions: projected.projection.omissions, exactCharacters: exact.length, canonicalUnchanged: true });
    });

    it("invalidates continuation on append and context edit, and refuses partial source failure", async () => {
      const { f, old, current, entryId } = await browserFixture("invalidation");
      const first = await page(f, { limit: 1 });
      current.sessionManager.appendContextEdit(entryId, { content: [{ type: "text", text: "edited projection" }] });
      await expect(page(f, { limit: 1, cursor: first.nextCursor })).rejects.toMatchObject({ code: "conflict", details: { reason: "home-memory-revision-changed" } });
      const edited = await page(f, { limit: 50 });
      const item = edited.items.find(candidate => candidate.evidence.entryId === entryId)!;
      expect(item.projection.text).toContain("edited projection");
      expect(item.projection.omissions).toContain("context-edit");
      const continued = await page(f, { limit: 1 });
      current.sessionManager.appendMessage({ role: "user", content: "new appended evidence", timestamp: Date.now() });
      await expect(page(f, { limit: 1, cursor: continued.nextCursor })).rejects.toMatchObject({ code: "conflict" });
      current.sessionManager.appendContextEdit(entryId, null);
      const omitted = (await page(f, { limit: 50 })).items.find(candidate => candidate.evidence.entryId === entryId)!;
      expect(omitted).toMatchObject({ index: item.index, projection: { omitted: true, text: "[omitted]" } });
      expect(omitted.projection.omissions).toContain("context-edit");
      // Evidence stays canonical even after a projected context edit/exclusion.
      const evidence = await f.service.invoke(client, "home.memory.evidence", { evidence: item.evidence }) as unknown as HomeMemoryEvidencePage;
      expect(evidence.text).toContain("fixture-token");
      await rm(current.sessionFile!);
      for (const [method, params] of [["home.memory.page", {}], ["home.memory.evidence", { evidence: first.items[0]!.evidence }]] as const) {
        const error = await f.service.invoke(client, method, params).then(() => undefined, error => error);
        expect(error).toMatchObject({ code: "busy", diagnosticReason: "home-memory-source-unavailable" });
        expect(error.details).toEqual({ reason: "home-memory-source-unavailable" });
        expect(error.message).not.toContain(".jsonl");
      }
      report.cases.push({ case: "memory-browser-revision-and-source-failure", editsInvalidate: true, appendInvalidates: true, partialSuccess: false });
    });

    it("revises evidence identity and date when canonical bytes change without changing projected text", async () => {
      const { f, current, entryId, canonical } = await browserFixture("canonical-revision");
      await f.service.invoke(client, "home.resumeMemory", { commandId: "browser-canonical-build" });
      await waitUntil(async () => {
        const status = await f.service.invoke(client, "home.status", {}) as unknown as HomeStatus;
        return status.memory.episodic?.pump.busy === 0 && status.memory.episodic?.view.unbuilt === 0;
      });
      await f.service.invoke(client, "home.pauseMemory", { commandId: "browser-canonical-freeze" });
      const calls = f.compactor.calls;
      const first = await page(f, { limit: 50 });
      const original = first.items.find(item => item.evidence.entryId === entryId)!;
      expect(original.summary).not.toBeNull();
      const lines = (await readFile(current.sessionFile!, "utf8")).trimEnd().split("\n");
      const timestamp = "2024-01-01T12:00:00.000Z";
      await writeFile(current.sessionFile!, lines.map(line => {
        const entry = JSON.parse(line);
        return entry.id === entryId ? JSON.stringify({ ...entry, timestamp }) : line;
      }).join("\n") + "\n");
      const revised = await page(f, { limit: 50 });
      const updated = revised.items.find(item => item.evidence.entryId === entryId)!;
      expect(updated.projection.text).toBe(original.projection.text);
      expect(updated.timestamp).toBe(timestamp);
      expect(updated.evidence.sourceDigest).not.toBe(original.evidence.sourceDigest);
      expect(revised.revision).not.toBe(first.revision);
      await expect(f.service.invoke(client, "home.memory.evidence", { evidence: original.evidence })).rejects.toMatchObject({ code: "conflict" });
      expect((await f.service.invoke(client, "home.memory.evidence", { evidence: updated.evidence }) as unknown as HomeMemoryEvidencePage).metadata.timestamp).toBe(timestamp);
      current.sessionManager.appendContextEdit(entryId, { content: [{ type: "text", text: canonical }] });
      const sameTextEdited = (await page(f, { limit: 50 })).items.find(item => item.evidence.entryId === entryId)!;
      expect(sameTextEdited.projection.text).toBe(updated.projection.text);
      expect(sameTextEdited.projection.omissions).toContain("context-edit");
      expect(sameTextEdited.summary).toEqual(original.summary);
      await f.service.invoke(client, "home.resumeMemory", { commandId: "browser-canonical-resume" });
      await waitUntil(async () => {
        const status = await f.service.invoke(client, "home.status", {}) as unknown as HomeStatus;
        return status.memory.episodic?.pump.busy === 0 && status.memory.episodic?.view.unbuilt === 0;
      });
      expect(f.compactor.calls).toBe(calls);
      report.cases.push({ case: "memory-browser-canonical-only-revision", updatedDateAndDigest: true, sameTextEditAttributed: true, summaryRetained: true });
    });

    it("enforces encoded byte bounds without losing rows containing JSON escapes", async () => {
      const { f, current } = await browserFixture("byte-bound");
      for (let index = 0; index < 60; index += 1) {
        current.sessionManager.appendMessage({ role: "user", content: `row ${index}: ${"\u0001".repeat(5000)}`, timestamp: Date.now() });
      }
      let result = await page(f, { limit: 50 });
      const count = result.totalItems;
      const indexes = new Set<number>();
      let byteLimited = false;
      for (let step = 0; step < 100; step += 1) {
        expect(Buffer.byteLength(JSON.stringify(result))).toBeLessThanOrEqual(128 * 1024);
        expect(result.items.length).toBeLessThanOrEqual(50);
        for (const item of result.items) { expect(indexes.has(item.index)).toBe(false); indexes.add(item.index); }
        if (!result.nextCursor) break;
        byteLimited ||= result.items.length < 50;
        result = await page(f, { limit: 50, cursor: result.nextCursor });
      }
      expect(result.nextCursor).toBeUndefined();
      expect(indexes.size).toBe(count);
      expect(byteLimited).toBe(true);
      report.cases.push({ case: "memory-browser-byte-bound", rows: count, escapedText: true, byteLimited });
    });

    it("invalidates placeholders when summaries settle without replaying a prompt", async () => {
      const { f } = await browserFixture("summaries");
      f.compactor.gate = new Promise<void>(resolve => { f.compactor.release = resolve; });
      try {
        const initial = await page(f, { limit: 1 });
        await f.service.invoke(client, "home.resumeMemory", { commandId: "browser-summaries-resume" });
        await waitUntil(async () => {
          const status = await f.service.invoke(client, "home.status", {}) as unknown as HomeStatus;
          const memory = status.memory.episodic;
          return f.compactor.entered > 0 && memory !== undefined
            && memory.coverage.summarized + memory.pump.busy === memory.coverage.admitted;
        });
        const pending = await page(f, { limit: 1 });
        f.compactor.release?.();
        await waitUntil(async () => {
          const status = await f.service.invoke(client, "home.status", {}) as unknown as HomeStatus;
          return status.memory.episodic?.pump.busy === 0 && status.memory.episodic?.view.unbuilt === 0;
        });
        await expect(page(f, { limit: 1, cursor: pending.nextCursor })).rejects.toMatchObject({ code: "conflict" });
        const built = await page(f, { limit: 50 });
        expect(built.revision).not.toBe(initial.revision);
        expect(built.items.some(item => item.summary?.text.includes(SUMMARY_MARKER))).toBe(true);
        expect(f.faux.state.callCount).toBe(1);
        report.cases.push({ case: "memory-browser-summary-settlement", revisionChanged: true, providerReplay: false });
      } finally { f.compactor.release?.(); }
    });

    it("refuses publication when a summary settles during canonical proof, and retires cancelled reads", async () => {
      const { f } = await browserFixture("read-fence");
      f.compactor.gate = new Promise<void>(resolve => { f.compactor.release = resolve; });
      await f.service.invoke(client, "home.resumeMemory", { commandId: "browser-read-fence-resume" });
      await waitUntil(() => f.compactor.entered > 0);
      let releaseProof!: () => void;
      const gate = new Promise<void>(resolve => { releaseProof = resolve; });
      const original = homeSource.readCanonicalHomeIndex;
      let entered = false;
      const spy = vi.spyOn(homeSource, "readCanonicalHomeIndex").mockImplementation(async function* (...args) {
        yield* original(...args);
        entered = true;
        await gate;
      });
      const reading = page(f, { limit: 1 }).then(value => ({ value, error: undefined }), error => ({ value: undefined, error }));
      try {
        await waitUntil(() => entered);
        const queuedController = new AbortController();
        const queued = f.service.invoke({ ...client, signal: queuedController.signal }, "home.memory.page", {})
          .then(() => undefined, error => error);
        // The first read keeps its proof gate. Cancellation must remove this
        // queued read without waiting for that unrelated request to settle.
        queuedController.abort();
        expect(await awaitsWithin(queued, "cancelled queued browser read")).toBeDefined();
        f.compactor.release?.();
        await waitUntil(async () => {
          const status = await f.service.invoke(client, "home.status", {}) as unknown as HomeStatus;
          return status.memory.episodic?.pump.busy === 0;
        });
        releaseProof();
        expect((await reading).error).toMatchObject({ code: "conflict", diagnosticReason: "home-memory-revision-changed" });
      } finally { releaseProof(); f.compactor.release?.(); await reading; spy.mockRestore(); }
      const controller = new AbortController();
      controller.abort();
      await expect(f.service.invoke({ ...client, signal: controller.signal }, "home.memory.page", {})).rejects.toBeDefined();
      expect((await page(f)).items.length).toBeGreaterThan(0);
      report.cases.push({ case: "memory-browser-read-fence", stalePublication: false, cancelledReadRetired: true });
    });

    it("reads a disabled Home after restart without starting compactor or chat work", async () => {
      const f = await fixture("browser-disabled");
      disposals.push(async () => { f.service.dispose(); await f.receipts.dispose(); await f.registry.dispose(); await rm(f.root, { recursive: true, force: true }); });
      const slot = await designateHome(f, "browser-disabled-designate");
      f.faux.setResponses([fauxAssistantMessage("baseline reply")]);
      await slot.prompt("baseline input");
      await waitUntil(() => !slot.isBusy);
      await f.service.invoke(client, "home.disable", { commandId: "browser-disabled-disable" });
      slot.sessionManager.appendMessage({ role: "user", content: "unbuilt input ".repeat(500), timestamp: Date.now() });
      await restart(f);
      const calls = f.compactor.calls;
      const result = await page(f, { limit: 50 });
      await new Promise<void>(resolve => setImmediate(resolve));
      expect(f.compactor.calls).toBe(calls);
      expect(f.faux.state.callCount).toBe(1);
      expect(result.items.some(item => item.projection.text.includes("unbuilt input") && item.summary === null)).toBe(true);
      const status = await f.service.invoke(client, "home.status", {}) as unknown as HomeStatus;
      expect(status).toMatchObject({ enabled: false, memory: { episodic: { pump: { busy: 0 } } } });
      report.cases.push({ case: "memory-browser-disabled-restart", noCompactorAdmission: true, noChatReplay: true });
    });

    it("cancels both real browser RPCs over the wire and logs only coded evidence failures", async () => {
      const { f } = await browserFixture("wire-cancel");
      const first = await page(f);
      const devices = new DeviceStore(join(f.root, "browser-device"), "browser-fixture");
      await devices.initialize();
      const enrollment = await devices.ensureEnrollment();
      const paired = await devices.pair(enrollment.code, "browser fixture");
      const records: Array<Record<string, unknown>> = [];
      const server = new GatewayServer({
        host: "127.0.0.1", port: 0, maxFrameBytes: 1024 * 1024,
        devices, sessions: f.registry, service: f.service, uploads: {} as never,
        auth: { detachClient: () => {}, cancelOwner: () => {} } as never,
        logger: { log: (_level: string, _message: string, fields: Record<string, unknown>) => { records.push(fields); } } as never,
        disposableReadDeadlinesMs: new Map(), // Only explicit cancellation owns this held read.
      });
      const releases: Array<() => void> = [];
      let socket: WebSocket | undefined;
      disposals.push(async () => { for (const release of releases) release(); socket?.terminate(); await server.close(); });
      await server.listen();
      const port = (server as unknown as { server: { address(): { port: number } } }).server.address().port;
      socket = new WebSocket(`ws://127.0.0.1:${port}/v1/socket`, { headers: { authorization: `Bearer ${paired.token}` } });
      const frames: Array<Record<string, any>> = [];
      socket.on("message", raw => { frames.push(JSON.parse(raw.toString())); });
      await awaitsWithin(once(socket, "open"), "browser wire connection");
      socket.send(JSON.stringify({ type: "hello", protocolVersion: (f.service.info() as unknown as { protocolVersion: number }).protocolVersion }));
      await waitUntil(() => frames.some(frame => frame.type === "hello"));
      const original = homeSource.readCanonicalHomeIndex;
      let started = 0;
      const spy = vi.spyOn(homeSource, "readCanonicalHomeIndex").mockImplementation(async function* (...args) {
        yield* original(...args); // Proof uses real sources; only its completion is gated.
        const signal = args[3]!;
        await new Promise<void>((resolve, reject) => {
          releases.push(resolve);
          const aborted = () => { signal.removeEventListener("abort", aborted); reject(signal.reason); };
          signal.addEventListener("abort", aborted, { once: true });
          releases[releases.length - 1] = () => { signal.removeEventListener("abort", aborted); resolve(); };
          started += 1;
        });
      });
      try {
        for (const [index, method] of ["home.memory.page", "home.memory.evidence"].entries()) {
          const id = `browser-cancel-${index}`;
          socket.send(JSON.stringify({ type: "request", id, method,
            params: method === "home.memory.page" ? {} : { evidence: first.items[0]!.evidence } }));
          await waitUntil(() => started === index + 1);
          socket.send(JSON.stringify({ type: "cancel", id }));
          await waitUntil(() => records.some(record => record.event === "rpc.cancelled" && record.requestID === id));
          expect(frames.some(frame => frame.id === id)).toBe(false);
        }
      } finally { for (const release of releases) release(); spy.mockRestore(); }
      const wrong = { ...first.items[0]!.evidence, sourceDigest: "0".repeat(64) };
      socket.send(JSON.stringify({ type: "request", id: "wrong-evidence", method: "home.memory.evidence", params: { evidence: wrong } }));
      await waitUntil(() => frames.some(frame => frame.id === "wrong-evidence"));
      expect(frames.find(frame => frame.id === "wrong-evidence")!.error).toMatchObject({ code: "conflict" });
      expect(records.find(record => record.event === "rpc.error" && record.requestID === "wrong-evidence"))
        .toMatchObject({ method: "home.memory.evidence", reason: "home-memory-revision-changed" });
      const logged = JSON.stringify(records);
      expect(logged).not.toContain(wrong.entryId);
      expect(logged).not.toContain(wrong.sourceDigest);
      expect(logged).not.toContain("first chapter fact");
      report.cases.push({ case: "memory-browser-wire-cancel-and-diagnostic", methodsCancelled: 2, payloadLogged: false });
    });

    it("rejects malformed bounds, continuation and evidence identity at RPC admission", async () => {
      const f = await fixture("browser-malformed");
      disposals.push(async () => { f.service.dispose(); await f.receipts.dispose(); await f.registry.dispose(); await rm(f.root, { recursive: true, force: true }); });
      for (const params of [{ limit: 0 }, { limit: 51 }, { limit: 1.5 }, { limit: "2" }, { cursor: "invalid" },
        { cursor: "x".repeat(1025) }, { limit: 2, unknown: true }]) {
        await expect(f.service.invoke(client, "home.memory.page", params)).rejects.toMatchObject({ code: "invalid_request" });
      }
      for (const params of [{}, { evidence: {} }, { evidence: { index: -1 } }, { evidence: null },
        { evidence: {}, offset: -1 }, { evidence: {}, offset: 0.5 }, { evidence: {}, extra: true }]) {
        await expect(f.service.invoke(client, "home.memory.evidence", params)).rejects.toMatchObject({ code: "invalid_request" });
      }
      report.cases.push({ case: "memory-browser-malformed-input", rejected: 14 });
    });
  });

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
      await waitUntil(() => slot.snapshot().configurationBlocker === null, 60_000);
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

  describe("memory pause contract", () => {
    async function pausedFixture(label: string) {
      const f = await fixture(`pause-${label}`);
      disposals.push(async () => {
        f.compactor.release?.();
        f.service.dispose();
        await f.receipts.dispose();
        await f.registry.dispose();
        await rm(f.root, { recursive: true, force: true });
      });
      const slot = await designateHome(f, `pause-designate-${label}`);
      return { f, slot };
    }
    const pause = (f: Fixture, commandId = "pause-command") => f.service.invoke(client, "home.pauseMemory", { commandId });
    const resume = (f: Fixture, commandId = "resume-command") => f.service.invoke(client, "home.resumeMemory", { commandId });

    it("persists pause through configuration, profile transitions and restart without replaying input", async () => {
      const { f, slot } = await pausedFixture("idle");
      f.faux.setResponses([fauxAssistantMessage("pause durable baseline")]);
      await slot.prompt("pause baseline canonical flush");
      await waitUntil(() => !slot.isBusy);
      await pause(f);
      expect(await f.service.invoke(client, "home.status", {})).toMatchObject({
        phase: "paused", readiness: { ready: false, gaps: ["memory-paused"] },
        recovery: { action: "resume-memory" }, memory: { paused: true },
      });
      await f.service.invoke(client, "home.configureMemory", { commandId: "pause-configure", model: OTHER_MEMORY_MODEL });
      await f.registry.homeOwner().disable();
      await f.registry.homeOwner().designate({}, () => MODEL);
      await restart(f);
      expect(await f.service.invoke(client, "home.status", {})).toMatchObject({ memory: { paused: true, open: false } });
      const reopened = await f.registry.acquire(slot.id);
      f.faux.setResponses([fauxAssistantMessage("must not be dispatched")]);
      await f.service.invoke(client, "home.prompt", { commandId: "pause-input", text: "pause input retained and explicitly refused" });
      await waitUntil(() => !reopened.isBusy);
      expect(f.faux.state.callCount).toBe(1);
      expect(await sessionJsonl(reopened)).toContain("pause input retained and explicitly refused");
      expect(f.registry.homeOwner().contextStatus()).toMatchObject({ lastRefusalReason: "memory-paused" });
      await resume(f);
      expect(await f.service.invoke(client, "home.status", {})).toMatchObject({ memory: { paused: false } });
      expect(f.faux.state.callCount).toBe(1);
      const record = JSON.parse(await readFile(join(f.tronHome, "gateway", "home", "home.json"), "utf8"));
      expect(record.memory.paused).toBeUndefined();
      report.cases.push({ case: "pause-idle-restart-input", inputRetained: true, explicitRefusal: true, automaticReplay: false });
    }, 60_000);

    it("resumes an idle pause before any canonical file exists", async () => {
      const { f } = await pausedFixture("no-source");
      await pause(f);
      await expect(resume(f)).resolves.toMatchObject({ configured: true, open: false, paused: false });
      expect(f.compactor.calls).toBe(0);
      report.cases.push({ case: "pause-no-source", resumedWithoutStore: true });
    });

    it("lets an activation with a frozen view finish its tool loop while paused", async () => {
      const { f, slot } = await pausedFixture("active");
      let release!: () => void;
      const gate = new Promise<void>(resolve => { release = resolve; });
      let entered = false;
      const requests: CapturedRequest[] = [];
      f.faux.setResponses([
        async context => { requests.push(record(context)); entered = true; await gate; return fauxAssistantMessage(fauxToolCall("read", { path: "note.txt" })); },
        responsesOf(f, requests)("finished while memory paused"),
      ]);
      const running = slot.prompt("pause active input");
      try {
        await waitUntil(() => entered);
        await pause(f);
        expect(slot.isBusy).toBe(true);
      } finally { release(); }
      await running;
      await waitUntil(() => !slot.isBusy);
      expect(requests).toHaveLength(2);
      expect(viewOf(requests[1]!)).toBe(viewOf(requests[0]!));
      expect(await sessionJsonl(slot)).toContain("finished while memory paused");
      expect(f.registry.homeOwner().contextStatus()).not.toHaveProperty("lastRefusalReason");
      report.cases.push({ case: "pause-frozen-activation", toolLoopCompleted: true, viewUnchanged: true });
    }, 60_000);

    it.each(["before-settlement", "after-restart"] as const)("releases a readiness wait and resumes %s without duplicate summarization", async ordering => {
      const { f, slot } = await pausedFixture("wait-pump");
      f.compactor.gate = new Promise<void>(resolve => { f.compactor.release = resolve; });
      f.faux.setResponses([fauxAssistantMessage(longInput("pause first reply"))]);
      await slot.prompt(longInput("pause first input"));
      await waitUntil(() => !slot.isBusy && f.compactor.entered > 0);
      let waitingForMemory = false;
      const whenReady = EpisodicMemory.prototype.whenReady;
      vi.spyOn(EpisodicMemory.prototype, "whenReady").mockImplementation(function (cut, options) {
        if (cut > 0) waitingForMemory = true;
        return whenReady.call(this, cut, options);
      });
      const waiting = slot.prompt("pause readiness input");
      await waitUntil(() => waitingForMemory);
      await pause(f);
      await awaitsWithin(waiting, "pause readiness settlement");
      await waitUntil(() => !slot.isBusy);
      expect(f.registry.homeOwner().contextStatus()).toMatchObject({ lastRefusalReason: "memory-paused" });
      expect(f.faux.state.callCount).toBe(1);
      if (ordering === "before-settlement") await resume(f);
      f.compactor.release?.();
      await waitUntil(async () => (await f.registry.homeOwner().memoryStatus()).episodic?.pump.busy === 0);
      if (ordering === "after-restart") {
        expect(f.compactor.calls).toBe(1);
        expect((await f.registry.homeOwner().memoryStatus()).episodic?.coverage.summarized).toBe(1);
        await restart(f);
        await resume(f);
      }
      await waitUntil(async () => ((await f.registry.homeOwner().memoryStatus()).episodic?.view.unbuilt ?? 1) === 0);
      // Only the long first input and reply require compactor calls; the committed input leaf is not rebuilt.
      expect(f.compactor.calls).toBe(2);
      expect(f.faux.state.callCount).toBe(1);
      report.cases.push({ case: "pause-wait-pump-restart", ordering, waitRefused: true, committedLeafRetained: true, totalCompactorCalls: f.compactor.calls });
    }, 60_000);

    it.each(["before-effect", "after-effect"] as const)("keeps a pause receipt unresolved across the %s crash boundary", async boundary => {
      const { f } = await pausedFixture(boundary);
      const store = f.receipts as unknown as { writeReceipt(path: string, receipt: { status: string }): Promise<void> };
      const write = store.writeReceipt.bind(store);
      const fault = vi.spyOn(store, "writeReceipt").mockImplementation(async (path, receipt) => {
        if (boundary === "before-effect" && receipt.status === "pending") {
          await write(path, receipt);
          throw new Error("simulated process exit after pending publication");
        }
        if (boundary === "after-effect" && receipt.status === "completed") throw new Error("simulated process exit before completion publication");
        return write(path, receipt);
      });
      try { await expect(pause(f)).rejects.toThrow("simulated process exit"); }
      finally { fault.mockRestore(); }
      await restart(f);
      expect(await f.receipts.status(client.identity, "home.pauseMemory", "pause-command")).toMatchObject({ status: "pending" });
      expect(await f.service.invoke(client, "home.status", {})).toMatchObject({ memory: { paused: boundary === "after-effect" } });
      await expect(pause(f)).rejects.toMatchObject({ code: "conflict", details: { outcomeUnknown: true } });
      report.cases.push({ case: "pause-receipt-crash-cut", boundary, receipt: "pending", effectObserved: boundary === "after-effect" });
    }, 60_000);

    it("replays completed pause receipts without repeating effect and reports sanitized control outcomes", async () => {
      const { f } = await pausedFixture("receipt");
      const accepted = await pause(f);
      await expect(pause(f)).resolves.toEqual(accepted);
      await resume(f);
      await expect(pause(f)).resolves.toEqual(accepted);
      expect(await f.service.invoke(client, "home.status", {})).toMatchObject({ memory: { paused: false } });
      await expect(resume(f, "resume-not-stopped")).rejects.toMatchObject({ code: "conflict" });
      const signals = f.homeLogger.recent(100).filter(row => row.event === "home.client-control");
      expect(new GatewayLogger(join(f.root, "home-signals.jsonl")).recent(100).filter(row => row.event === "home.client-control")).toEqual(signals);
      expect(signals.filter(row => row.operation === "pauseMemory")).toHaveLength(1);
      expect(signals.filter(row => row.operation === "resumeMemory")).toHaveLength(2);
      expect(signals.some(row => row.level === "warning" && row.reason === "conflict")).toBe(true);
      expect(JSON.stringify(signals)).not.toContain("pause-command");
      expect(JSON.stringify(signals)).not.toContain(MEMORY_MODEL_ID);
      report.cases.push({ case: "pause-receipt-replay-signal", effectRepeated: false, sanitizedSignals: signals.length });
    }, 60_000);
  });

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
    await waitUntil(() => slot.snapshot().configurationBlocker === null);
    // Activation one's leaves are built before activation two starts.
    await waitUntil(async () => ((await f.registry.homeOwner().memoryStatus()).episodic?.coverage.summarized ?? 0) >= 2);
    f.faux.setResponses([
      async (context) => { requests.push(record(context)); return fauxAssistantMessage(fauxToolCall("read", { path: "note.txt" })); },
      async (context) => { requests.push(record(context)); return fauxAssistantMessage("after the tool"); },
    ]);
    await slot.prompt(longInput("activation two input"));
    await waitUntil(() => slot.snapshot().configurationBlocker === null);
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
    await waitUntil(() => slot.snapshot().configurationBlocker === null);
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
    await waitUntil(() => slot.snapshot().configurationBlocker === null);
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
    await waitUntil(() => slot.snapshot().configurationBlocker === null);
    await waitUntil(() => f.compactor.entered > 0);
    const requestsBefore = requests.length;
    f.faux.setResponses([responsesOf(f, requests)("must never be produced")]);
    const second = slot.prompt(longInput("stop activation two"));
    await waitUntil(() => (f.registry.homeOwner().requestPolicyFor(slot.id)?.currentOperationId() ?? undefined) !== undefined);
    await slot.abort("agent");
    const outcome = await second.then(() => "resolved", (error: unknown) => error instanceof Error ? `${error.name}: ${error.message}` : String(error));
    await waitUntil(() => slot.snapshot().configurationBlocker === null);
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
    await waitUntil(() => slot.snapshot().configurationBlocker === null);
    const refused = await canonicalMessages(slot);
    const refusals = f.registry.homeOwner().requestPolicyFor(slot.id)?.refusalLog().map((entry) => entry.reason) ?? [];
    const context = await f.service.invoke(client, "home.context", {}) as unknown as HomeContextProjection;

    await f.service.invoke(client, "home.configureMemory", {
      commandId: "e2e-configure-memory",
      model: MEMORY_MODEL,
    });
    f.faux.setResponses([responsesOf(f, requests)("configured activation response")]);
    await slot.prompt(longInput("configured activation input"));
    await waitUntil(() => slot.snapshot().configurationBlocker === null);
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
    expect(row.unconfiguredMemory).toEqual({ configured: false, open: false, paused: false });
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

  it.each(["rollover", "failed-sync", "handled-input"] as const)("owns exact Home attachments in a real terminal child: %s", async mode => {
    const f = await fixture(`terminal-attachments-${mode}`);
    disposals.push(async () => {
      await f.server?.close();
      f.server = undefined;
      f.service.dispose();
      await f.receipts.dispose();
      await f.registry.dispose();
      await rm(f.root, { recursive: true, force: true });
    });
    const cwd = join(f.root, "workspace");
    if (mode === "handled-input") {
      const extensionDir = join(cwd, ".pi", "extensions");
      await mkdir(extensionDir, { recursive: true });
      await writeFile(join(extensionDir, "handled.ts"), `export default function (pi) {
        pi.on("input", (event) => event.text === "handled-input" ? { action: "handled" } : undefined);
      }\n`);
      await new TrustService(f.agentDir).set(cwd, true);
    }
    const initial = mode === "handled-input"
      ? await f.registry.create(cwd) : await designateHome(f, `terminal-attachments-${mode}`);
    f.faux.setResponses([fauxAssistantMessage("attachment fixture initialized")]);
    await initial.prompt("initialize attachment evidence");
    await waitUntil(() => initial.snapshot().configurationBlocker === null);
    const devices = new DeviceStore(f.tronHome, "fixture-terminal-attachments");
    await devices.initialize();
    const opened: Array<{ sessionId: string; subscriptionToken: string; phase: string }> = [];
    const closed: Array<{ sessionId: string; subscriptionToken: string; closed: boolean }> = [];
    const accepted: Array<{ sessionId: string; operationId: string }> = [];
    const settlementCuts: Array<{ operationId: string; phase: string; busy: boolean }> = [];
    const historyReads: Array<{ method: string; sessionId: string; entryId?: string }> = [];
    const recoveredCommands: unknown[] = [];
    const prompts: string[] = [];
    const invoke = f.service.invoke.bind(f.service);
    let disconnectOnce = mode === "rollover";
    let failSync = false;
    let disconnectRollover = mode === "rollover";
    let rolloverCommandId: string | undefined;
    let reconnectCommandId: string | undefined;
    let pendingStatusReads = 0;
    let releaseReceipt!: () => void;
    const receiptGate = new Promise<void>(resolve => { releaseReceipt = resolve; });
    const receiptWriter = f.receipts as unknown as { writeReceipt: (path: string, value: unknown, mode?: number) => Promise<void> };
    const writeReceipt = receiptWriter.writeReceipt.bind(receiptWriter);
    vi.spyOn(receiptWriter, "writeReceipt").mockImplementation(async (path, value, mode) => {
      const receipt = value as { commandId: string; status: string };
      if (receipt.commandId === reconnectCommandId && receipt.status === "completed") await receiptGate;
      await writeReceipt(path, value, mode);
    });
    let settleDuringSync: { entered: () => boolean; release: () => void } | undefined;
    let releaseQuiescent!: () => void;
    const quiescentGate = new Promise<void>(resolve => { releaseQuiescent = resolve; });
    let quiescentHeld = false;
    const owner = f.registry.homeOwner();
    const chapterQuiescent = owner.chapterQuiescent.bind(owner);
    vi.spyOn(owner, "chapterQuiescent").mockImplementation(async id => {
      if (prompts.at(-1) === "same-chapter-settled") {
        quiescentHeld = true;
        await quiescentGate;
      }
      await chapterQuiescent(id);
    });
    f.service.invoke = async (context, method, params) => {
      if (method === "home.prompt" && (params as { text: string }).text === "reconnect-settled") {
        reconnectCommandId = (params as { commandId: string }).commandId;
      }
      if (method === "home.prompt" && (params as { text: string }).text === "rollover-0") {
        rolloverCommandId = (params as { commandId: string }).commandId;
      }
      if (method === "session.open" && prompts.at(-1) === "rollover-0"
        && (params as { sessionId: string }).sessionId === initial.id) {
        // Reconnect must recover acceptance while the successor is still held,
        // not accidentally observe a pending command receipt and skip the race.
        await waitFor(async () => (await f.receipts.status(context.identity, "home.prompt", rolloverCommandId!)).status === "completed",
          "rollover acceptance receipt before reconnect baseline");
      }
      if (method === "session.sync" && failSync) throw new Error("fixture candidate synchronization failed");
      if (method === "session.sync" && prompts.at(-1) === "rollover-1"
        && (params as { sessionId: string }).sessionId === accepted.at(-1)?.sessionId && settleDuringSync) {
        await waitUntil(settleDuringSync.entered);
        const operation = accepted.at(-1)!;
        const slot = await f.registry.acquire(operation.sessionId);
        // Public SDK canonical appends model context arriving during the run.
        // These real rows page out its user binding; snapshots stay unmodified.
        for (let row = 0; row < 10; row += 1) {
          slot.sessionManager.appendCustomMessageEntry("fixture-context", "x".repeat(64_000), true);
        }
        settleDuringSync.release();
        await waitUntil(() => invocationReceipts(slot.sessionManager.getBranch(), slot.id).some(receipt =>
          receipt.operationId === operation.operationId && receipt.receiptKind === "terminal" && receipt.lifecycle === "completed")
          && slot.snapshot().configurationBlocker === null);
      }
      const result = await invoke(context, method, params);
      if (method === "command.status") {
        recoveredCommands.push(result);
        if ((params as { commandId: string }).commandId === reconnectCommandId && (result as { status: string }).status === "pending") {
          pendingStatusReads += 1;
          if (pendingStatusReads === 2) releaseReceipt();
        }
      }
      if (method.startsWith("session.history.")) historyReads.push({ method, ...(params as { sessionId: string; entryId?: string }) });
      if (method === "session.open") {
        const envelope = result as unknown as { session: { sessionId: string; phase: string }; subscriptionToken: string };
        opened.push({ sessionId: envelope.session.sessionId, subscriptionToken: envelope.subscriptionToken, phase: envelope.session.phase });
      }
      if (method === "session.close") closed.push({ ...(params as { sessionId: string; subscriptionToken: string }), ...(result as { closed: boolean }) });
      if (method === "home.prompt" || method === "session.prompt") {
        prompts.push((params as { text: string }).text);
        const operation = { ...(result as unknown as { sessionId: string; operationId: string }),
          sessionId: (result as { sessionId?: string }).sessionId ?? (params as { sessionId: string }).sessionId };
        accepted.push(operation);
        const slot = await f.registry.acquire(operation.sessionId);
        if ((params as { text: string }).text === "rollover-0" && disconnectRollover) {
          disconnectRollover = false;
          const connection = (server as unknown as { clients: Map<string, { socket: import("ws").WebSocket }> }).clients.get(context.id)!;
          connection.socket.terminate();
          return result;
        }
        if (["running-operation", "rollover-0", "rollover-1"].includes((params as { text: string }).text)) return result;
        // The accepted command's response arrives after its actual settlement.
        // This exercises both event-before-response and terminal-baseline transfer.
        const connection = (server as unknown as { clients: Map<string, { socket: import("ws").WebSocket }> }).clients.get(context.id);
        if (!connection) throw new Error("terminal connection missing at accepted-response cut");
        await waitUntil(() => invocationReceipts(slot.sessionManager.getBranch(), slot.id).some(receipt =>
          receipt.operationId === operation.operationId && receipt.receiptKind === "terminal" && receipt.lifecycle === "completed"));
        if ((params as { text: string }).text === "same-chapter-settled") {
          await waitUntil(() => quiescentHeld);
          expect(slot.isBusy).toBe(false);
          expect(slot.snapshot().phase).toBe("running");
        }
        settlementCuts.push({ operationId: operation.operationId, phase: slot.snapshot().phase, busy: slot.isBusy });
        // Publication owns the sequence: rebroadcasting snapshot() directly can
        // reuse a consumed sequence and hide newly terminal receipt evidence.
        slot.publishSnapshot();
        // A ping/pong cut proves the terminal has consumed preceding snapshot
        // frames before this response, without a scheduling sleep.
        const consumed = once(connection.socket, "pong");
        connection.socket.ping();
        await awaitsWithin(consumed, "terminal consumed the settled snapshot");
        if (disconnectOnce) {
          disconnectOnce = false;
          connection.socket.terminate();
        }
      }
      return result;
    };
    const server = new GatewayServer({
      host: "127.0.0.1", port: 0, maxFrameBytes: 1_048_576,
      devices, sessions: f.registry, service: f.service,
      uploads: { removeSession: async () => {} } as never,
      auth: { cancelOwner: () => {}, detachClient: () => {} } as never,
      logger: { log: () => {} } as never,
    });
    f.server = server;
    await server.listen();
    const port = (server as unknown as { server: { address(): { port: number } } }).server.address().port;
    const preload = pathToFileURL(join(process.cwd(), "test-support/home-ledger-crash-preload.mjs")).href;
    const terminal = spawn(process.execPath, ["--experimental-transform-types", "--import", preload,
      join(process.cwd(), "src/client/terminal-chat.ts"), ...(mode === "handled-input" ? ["--session", initial.id] : [])], {
      cwd: process.cwd(), env: { ...process.env, TRON_DATA_DIR: f.tronHome,
        TRON_GATEWAY_HOST: "127.0.0.1", TRON_GATEWAY_PORT: String(port) }, stdio: ["pipe", "pipe", "pipe"],
    });
    let stdout = "";
    let stderr = "";
    terminal.stdout.setEncoding("utf8").on("data", (chunk: string) => { stdout += chunk; });
    terminal.stderr.setEncoding("utf8").on("data", (chunk: string) => { stderr += chunk; });
    const exit = once(terminal, "close");
    const promptCount = () => stdout.match(/you>/gu)?.length ?? 0;
    const scrub = (value: string) => value.replaceAll(`/private${f.root}`, "<fixture>").replaceAll(f.root, "<fixture>");
    const awaitPrompt = async (count: number) => {
      await waitUntil(() => promptCount() >= count, 8_000).catch(() => {
        throw new Error(`terminal settlement did not return prompt ${count}; cuts=${JSON.stringify(settlementCuts)} quiescentHeld=${quiescentHeld} opened=${JSON.stringify(opened)} commands=${JSON.stringify(recoveredCommands)} stdout=${scrub(stdout)} stderr=${scrub(stderr)}`);
      });
    };
    const roll = async (id: string) => {
      const port = (f.registry.homeOwner() as unknown as {
        options: { sessions: { chapterMetrics: (id: string) => Promise<{ bytes: number; entries: number; quiescent: boolean }> } };
      }).options.sessions;
      const metrics = vi.spyOn(port, "chapterMetrics").mockResolvedValue({ bytes: 24 * 1_024 * 1_024 + 1, entries: 3, quiescent: true });
      try { await f.registry.homeOwner().chapterQuiescent(id); } finally { metrics.mockRestore(); }
    };
    const send = (input: string) => {
      f.faux.setResponses([fauxAssistantMessage(`REPLY-${input}`)]);
      terminal.stdin.write(`${input}\n`);
    };
    try {
      await awaitPrompt(1);
      if (mode === "handled-input") {
        terminal.stdin.write("handled-input\n");
        await awaitPrompt(2);
        const handled = accepted.at(-1)!;
        expect(initial.snapshot().transcript.some(item => item.semantic?.operationId === handled.operationId)).toBe(false);
        expect(invocationReceipts(initial.sessionManager.getBranch(), initial.id).some(receipt =>
          receipt.operationId === handled.operationId && receipt.receiptKind === "terminal" && receipt.lifecycle === "completed")).toBe(true);
        expect(historyReads.at(-1)).toMatchObject({ method: "session.history.entry", sessionId: initial.id });
        expect(f.faux.state.callCount).toBe(1);
        terminal.stdin.write("/quit\n");
        await awaitsWithin(exit, "handled terminal attachment exit");
        expect(terminal.exitCode).toBe(0);
      } else if (mode === "failed-sync") {
        await roll(initial.id);
        failSync = true;
        send("failed-transfer");
        await awaitsWithin(exit, "failed terminal transfer exit", 10_000);
        expect(terminal.exitCode).toBe(1);
        expect(opened).toHaveLength(2);
        expect(closed.map(({ sessionId, subscriptionToken }) => ({ sessionId, subscriptionToken }))).toEqual([
          { sessionId: opened[1]!.sessionId, subscriptionToken: opened[1]!.subscriptionToken },
          { sessionId: opened[0]!.sessionId, subscriptionToken: opened[0]!.subscriptionToken },
        ]);
        expect(closed.every(item => item.closed)).toBe(true);
      } else {
        send("reconnect-settled");
        await awaitPrompt(2);
        expect(stderr).toContain("[Tron synchronized]");
        send("same-chapter-settled");
        await awaitPrompt(3);
        releaseQuiescent();
        let releaseProvider!: () => void;
        let providerEntered = false;
        const providerGate = new Promise<void>(resolve => { releaseProvider = resolve; });
        f.faux.setResponses([async () => {
          providerEntered = true;
          await providerGate;
          return fauxAssistantMessage("REPLY-running-operation");
        }]);
        try {
          terminal.stdin.write("running-operation\n");
          await waitUntil(() => providerEntered);
          const connection = [...(server as unknown as { clients: Map<string, { socket: import("ws").WebSocket }> }).clients.values()][0]!;
          const consumed = once(connection.socket, "pong");
          connection.socket.ping();
          await awaitsWithin(consumed, "terminal consumed the running admission");
          expect(initial.snapshot().phase).not.toBe("idle");
          expect(promptCount()).toBe(3);
        } finally { releaseProvider(); }
        await awaitPrompt(4);
        let current = initial.id;
        for (let rollover = 0; rollover < 2; rollover += 1) {
          await roll(current);
          let releaseRollover!: () => void;
          const rolloverGate = new Promise<void>(resolve => { releaseRollover = resolve; });
          let rolloverEntered = false;
          f.faux.setResponses([async () => {
            rolloverEntered = true;
            await rolloverGate;
            return fauxAssistantMessage(`REPLY-rollover-${rollover}`);
          }]);
          if (rollover === 1) settleDuringSync = { entered: () => rolloverEntered, release: releaseRollover };
          try {
            terminal.stdin.write(`rollover-${rollover}\n`);
            await waitUntil(() => rolloverEntered).catch(error => {
              throw new Error(`rollover-${rollover} provider admission failed: ${String(error)} stdout=${scrub(stdout)} stderr=${scrub(stderr)}`);
            });
            await waitFor(() => closed.some(item => item.sessionId === current), `outgoing terminal retirement: ${scrub(stderr)}`);
            const connection = [...(server as unknown as { clients: Map<string, { socket: import("ws").WebSocket }> }).clients.values()][0]!;
            const consumed = once(connection.socket, "pong");
            connection.socket.ping();
            await awaitsWithin(consumed, "terminal consumed successor admission after transfer");
            if (rollover === 0) expect(promptCount()).toBe(4);
          } finally { settleDuringSync = undefined; releaseRollover(); }
          await awaitPrompt(5 + rollover);
          const next = accepted.at(-1)!.sessionId;
          if (rollover === 1) {
            const slot = await f.registry.acquire(next);
            expect(slot.snapshot().transcript.some(item => item.semantic?.operationId === accepted.at(-1)!.operationId)).toBe(false);
            expect(historyReads.filter(read => read.sessionId === next).map(read => read.method))
              .toEqual(["session.history.list", "session.history.entry"]);
          }
          expect(next).not.toBe(current);
          const previous = opened.findLast(item => item.sessionId === current)!;
          expect(closed.at(-1)).toEqual({ sessionId: current, subscriptionToken: previous.subscriptionToken, closed: true });
          // Real idle eviction after outgoing attachment retirement. The current
          // subscribed chapter stays live; no production protection is bypassed.
          (f.registry as unknown as { options: { idleRuntimeMs: number } }).options.idleRuntimeMs = 0;
          const liveSlots = (f.registry as unknown as { slots: Map<string, RuntimeSlot> }).slots;
          await waitUntil(async () => {
            await (f.registry as unknown as { evictIdle(): Promise<void> }).evictIdle();
            return !liveSlots.has(current);
          }).catch(() => {
            const old = liveSlots.get(current);
            const subscribers = (f.registry as unknown as { subscribers: Map<string, Set<string>> }).subscribers;
            throw new Error(`outgoing eviction stalled: busy=${old?.isBusy} protected=${old?.isEvictionProtected} subscribers=${JSON.stringify([...(subscribers.get(current) ?? [])])} touched=${old?.touchedAt} now=${Date.now()} stderr=${scrub(stderr)}`);
          });
          expect(liveSlots.has(current)).toBe(false);
          expect(liveSlots.has(next)).toBe(true);
          current = next;
        }
        terminal.stdin.write("/quit\n");
        await awaitsWithin(exit, "terminal attachment exit", 10_000);
        expect(terminal.exitCode).toBe(0);
        expect(closed.at(-1)).toEqual({ sessionId: current, subscriptionToken: opened.at(-1)!.subscriptionToken, closed: true });
        expect(prompts).toEqual(["reconnect-settled", "same-chapter-settled", "running-operation", "rollover-0", "rollover-1"]);
        expect(f.faux.state.callCount).toBe(6);
        expect(pendingStatusReads).toBe(2);
        expect(stderr).not.toContain("reason=event-gap");
        expect(stderr.match(/\[Tron disconnected; reconnecting…\]/gu), scrub(stderr)).toHaveLength(2);
        for (const input of prompts) expect(stdout.match(new RegExp(`REPLY-${input}`, "gu"))).toHaveLength(1);
        expect(opened.filter(item => accepted.slice(-2).some(operation => operation.sessionId === item.sessionId))
          .every(item => item.phase === "running")).toBe(true);
      }
      const artifact = { mode, exitCode: terminal.exitCode, opened, closed, accepted, settlementCuts, historyReads, recoveredCommands, pendingStatusReads,
        submittedInputs: prompts, stdout: scrub(stdout), stderr: scrub(stderr), injectedSoftMetrics: true,
        responseBeforeRunningEvents: mode === "rollover" };
      const directory = join(process.cwd(), "test-results", "terminal-chat-home");
      await mkdir(directory, { recursive: true });
      await writeFile(join(directory, `attachments-${mode}.json`), `${JSON.stringify(artifact, null, 2)}\n`);
      report.cases.push({ case: `terminal-attachments-${mode}`, exitCode: terminal.exitCode,
        attachments: opened.length, retiredTokens: closed.length, submittedInputs: prompts, injectedSoftMetrics: true });
    } finally {
      releaseReceipt();
      releaseQuiescent();
      if (terminal.exitCode === null && terminal.signalCode === null) terminal.kill("SIGKILL");
      await awaitsWithin(exit, "owned terminal cleanup");
      terminal.stdin.destroy();
      await server.close();
      f.server = undefined;
    }
  }, 45_000);

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
    let holdSecondSnapshots = false;
    let releaseSecondResponse!: () => void;
    const secondResponseGate = new Promise<void>(resolve => { releaseSecondResponse = resolve; });
    const invoke = f.service.invoke.bind(f.service);
    (f.service as unknown as { invoke: typeof f.service.invoke }).invoke = async (context, method, params) => {
      methods.push(method);
      const second = method === "session.prompt" && (params as { text?: string }).text === "refusal two";
      if (second) holdSecondSnapshots = true;
      const result = await invoke(context, method, params);
      if (second) {
        await waitUntil(() => invocationReceipts(slot.sessionManager.getBranch(), slot.id).some(receipt =>
          receipt.receiptKind === "terminal" && receipt.operationId === (result as { operationId: string }).operationId));
        // Suppress presentation events and force authoritative resync while
        // the accepted response is still pending. That snapshot owns refusal 2.
        broadcast(slot.id, "transport.resyncRequired", {});
        await secondResponseGate;
        holdSecondSnapshots = false;
      }
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
    const broadcast = server.broadcastSession.bind(server);
    server.broadcastSession = (id, topic, payload) => {
      if (!holdSecondSnapshots) broadcast(id, topic, payload);
    };
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
    const terminalExit = once(terminal, "close") as Promise<[number | null, NodeJS.Signals | null]>;
    let exitTimer: NodeJS.Timeout | undefined;
    let serverClosed = false;
    terminal.stdout.setEncoding("utf8").on("data", (chunk: string) => { stdout += chunk; });
    terminal.stderr.setEncoding("utf8").on("data", (chunk: string) => { stderr += chunk; });
    try {
      await waitUntil(() => stdout.includes(`Attached to Tron session ${slot.id}`), 20_000);
      terminal.stdin.write("refusal one\n");
      await waitUntil(() => (stdout.match(/Home memory is not configured/gu)?.length ?? 0) >= 1, 10_000).catch(() => { throw new Error(`missing first refusal; stdout=${scrub(stdout)} stderr=${scrub(stderr)}`); });
      await waitUntil(() => (stdout.match(/you>/gu)?.length ?? 0) >= 2, 10_000);
      const syncsBefore = stderr.match(/Tron synchronized/gu)?.length ?? 0;
      terminal.stdin.write("refusal two\n");
      await waitUntil(() => (stderr.match(/Tron synchronized/gu)?.length ?? 0) > syncsBefore, 10_000);
      await waitUntil(() => (stdout.match(/Home memory is not configured/gu)?.length ?? 0) >= 2, 2_000).catch(() => { throw new Error(`missing second refusal; stdout=${scrub(stdout)} stderr=${scrub(stderr)}`); });
      releaseSecondResponse();
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
      await f.service.invoke(client, "home.configureMemory", { commandId: "terminal-configure-memory", model: MEMORY_MODEL });
      const requests: CapturedRequest[] = [];
      f.faux.setResponses([responsesOf(f, requests)("TERMINAL-STREAMED-REPLY")]);
      terminal.stdin.write("ordinary reply\n");
      await waitUntil(() => (stdout.match(/TERMINAL-STREAMED-REPLY/gu)?.length ?? 0) >= 1, 10_000);
      await waitUntil(() => (stdout.match(/you>/gu)?.length ?? 0) >= 7, 10_000);
      expect(stdout.match(/TERMINAL-STREAMED-REPLY/gu)).toHaveLength(1);
      terminal.stdin.write("/home status\n");
      await waitUntil(() => stdout.includes("pump busy:") || stdout.includes("summarized"), 10_000).catch(() => { throw new Error(`missing configured memory detail; stdout=${scrub(stdout)} stderr=${scrub(stderr)}`); });
      await waitUntil(() => (stdout.match(/you>/gu)?.length ?? 0) >= 8, 10_000);
      terminal.stdin.write("/quit\n");
      await waitUntil(() => methods.includes("session.close:completed"), 5_000);
      await server.close();
      serverClosed = true;
      f.server = undefined;
      terminal.stdin.destroy();
      const [code, signal] = await Promise.race([
        terminalExit,
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
        assertions: {
          refusalCount, repeatedRefusalCount,
          malformedUsage: (stderr.match(/Usage: \/home/gu)?.length ?? 0) >= 2 && stderr.includes("provider/id"),
          statusReturned: stdout.includes("configure-memory"),
          streamedReplyOnce: stdout.match(/TERMINAL-STREAMED-REPLY/gu)?.length === 1,
          configuredMemoryDetail: stdout.includes("summarized") || stdout.includes("pump busy:"),
        },
      };
      await mkdir(join(process.cwd(), "test-results", "terminal-chat-home"), { recursive: true });
      await writeFile(join(process.cwd(), "test-results", "terminal-chat-home", "transcript.json"), `${JSON.stringify(artifact, null, 2)}\n`);
      expect(scrub(stderr)).not.toContain("tron-chat:");
      expect(code).toBe(0);
      expect(signal).toBeNull();
      expect(artifact.assertions.repeatedRefusalCount).toBeGreaterThanOrEqual(2);
      expect(artifact.assertions.malformedUsage).toBe(true);
      expect(artifact.assertions.statusReturned).toBe(true);
      expect(artifact.assertions.streamedReplyOnce).toBe(true);
      expect(artifact.assertions.configuredMemoryDetail).toBe(true);
      report.cases.push({ case: "terminal-subprocess", exitCode: code, repeatedRefusalCount: artifact.assertions.repeatedRefusalCount, malformedUsage: artifact.assertions.malformedUsage, statusReturned: artifact.assertions.statusReturned, streamedReplyOnce: artifact.assertions.streamedReplyOnce, configuredMemoryDetail: artifact.assertions.configuredMemoryDetail });
    } finally {
      releaseSecondResponse();
      if (exitTimer) clearTimeout(exitTimer);
      if (terminal.exitCode === null && terminal.signalCode === null) terminal.kill("SIGKILL");
      await awaitsWithin(terminalExit, "owned terminal cleanup");
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
    await waitUntil(() => slot.snapshot().configurationBlocker === null);

    // The Gateway that a transient outage blocked: the memory's own durable state
    // is exactly what a restart hands over.
    await restart(f);
    const memoryId = await homeMemoryStateId(f);
    const state = await readMemoryState(f, memoryId);
    expect(state).toBeDefined();
    await writeMemoryState(f, memoryId, { ...state!, blocked: { reason: "retries-exhausted" } });

    const reopened = await f.registry.acquire(slot.id);
    f.faux.setResponses([responsesOf(f, requests)(longInput("transient response two"))]);
    await reopened.prompt(longInput("transient activation two"));
    await waitUntil(() => reopened.snapshot().configurationBlocker === null);
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
    await waitUntil(() => slot.snapshot().configurationBlocker === null);
    await waitUntil(async () => (await f.registry.homeOwner().memoryStatus()).blocked === "permanent-failure");
    const blocked = (await f.registry.homeOwner().memoryStatus()).blocked;
    expect(await f.service.invoke(client, "home.status", {})).toMatchObject({
      phase: "blocked", readiness: { ready: false, gaps: ["memory-permanent-failure"] },
      recovery: { action: "resume-memory", reason: "permanent-failure" },
    });

    f.faux.setResponses([responsesOf(f, requests)("must never be produced")]);
    await slot.prompt(longInput("resume activation two"));
    await waitUntil(() => slot.snapshot().configurationBlocker === null);
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
    await waitUntil(() => slot.snapshot().configurationBlocker === null);
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
    await waitUntil(() => slot.snapshot().configurationBlocker === null);
    await waitUntil(async () => ((await f.registry.homeOwner().memoryStatus()).spentTokens ?? 0) > 0);
    const spentOnFirstSession = (await f.registry.homeOwner().memoryStatus()).spentTokens ?? 0;

    const disabled = await f.service.invoke(client, "home.disable", { commandId: "e2e-lifecycle-disable" });
    const afterDisable = await f.service.invoke(client, "home.status", {}) as unknown as HomeStatus;
    expect(afterDisable).toMatchObject({ phase: "disabled", readiness: { ready: false, gaps: ["disabled"] }, recovery: { action: "designate" } });
    const reEnabled = await f.service.invoke(client, "home.designate", { commandId: "e2e-lifecycle-enable", model: MODEL });
    f.faux.setResponses([responsesOf(f, requests)(longInput("lifecycle reply two"))]);
    const sameSession = await f.registry.acquire((reEnabled as unknown as { sessionId: string }).sessionId);
    await sameSession.prompt(longInput("lifecycle activation two"));
    await waitUntil(() => sameSession.snapshot().configurationBlocker === null);
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
    expect(row.spendOnNewSession).toBeGreaterThanOrEqual(row.spentOnFirstSession);
    expect(row.spentOnFirstSession).toBeGreaterThan(0);

    // The new physical chapter opens the same Home memory namespace (#483), so
    // the stable Home identity retains configuration and spend across recovery.
    const freshSlot = await f.registry.acquire(reDesignated.sessionId);
    f.faux.setResponses([responsesOf(f, requests)(longInput("lifecycle reply three"))]);
    await freshSlot.prompt(longInput("lifecycle activation three"));
    await waitUntil(() => freshSlot.snapshot().configurationBlocker === null);
    const context = await f.service.invoke(client, "home.context", {}) as unknown as { lastRefusalReason?: string; lastRefusalDetail?: string };
    expect(context.lastRefusalReason, context.lastRefusalDetail).toBe("memory-blocked");
    expect(context.lastRefusalDetail).toContain("Sealed Home chapter");
    const blockedMemory = await f.registry.homeOwner().memoryStatus();
    expect(blockedMemory.blocked).toBe("source-unavailable");
    expect(blockedMemory.spentTokens).toBeGreaterThanOrEqual(row.spentOnFirstSession);
    report.cases.push({ case: "missing-sealed-source-blocked", priorProjectionRetained: true, blocked: blockedMemory.blocked });
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
    await waitUntil(() => slot.snapshot().configurationBlocker === null);
    await waitUntil(async () => ((await f.registry.homeOwner().memoryStatus()).spentTokens ?? 0) >= 1_000_000_000);
    await slot.prompt(longInput("costly activation two"));
    await waitUntil(() => slot.snapshot().configurationBlocker === null);
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
    await waitUntil(() => slot.snapshot().configurationBlocker === null);
    await waitUntil(() => f.compactor.entered > 0);
    f.faux.setResponses([responsesOf(f, requests)("disable wait reply two")]);
    const second = slot.prompt(longInput("disable wait activation two"));
    await waitUntil(() => (f.registry.homeOwner().requestPolicyFor(slot.id)?.currentOperationId() ?? undefined) !== undefined);
    const disabled = await f.service.invoke(client, "home.disable", { commandId: "e2e-disable-busy" })
      .then(() => "accepted", (error: unknown) => (error as { code?: string }).code ?? "failed");
    f.compactor.release?.();
    await second;
    await waitUntil(() => slot.snapshot().configurationBlocker === null);
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
    await waitUntil(() => slot.snapshot().configurationBlocker === null);
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
    await waitUntil(() => slot.snapshot().configurationBlocker === null);
    // Whatever that race did to the waiting activation, the memory is usable and
    // open exactly once: the next activation is served with the new model.
    f.faux.setResponses([responsesOf(f, requests)(longInput("race reply three"))]);
    await slot.prompt(longInput("race activation three"));
    await waitUntil(() => slot.snapshot().configurationBlocker === null);
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
    await waitUntil(() => slot.snapshot().configurationBlocker === null);
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
    await waitUntil(() => slot.snapshot().configurationBlocker === null);
    await waitUntil(async () => ((await f.registry.homeOwner().memoryStatus()).episodic?.tokens.used ?? 0) > 0);

    await restart(f);
    // The store the restart closed: its own document is what the status must
    // report, because the reopened memory has not opened it yet.
    const memoryId = await homeMemoryStateId(f);
    const persisted = await readMemoryState(f, memoryId);
    expect(persisted).toBeDefined();
    const closed = await f.service.invoke(client, "home.status", {}) as unknown as HomeStatus;
    await writeMemoryState(f, memoryId, { ...persisted!, blocked: { reason: "source-unavailable", detail: "canonical session is unreadable" } });
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
    expect(status.memory).toEqual({ configured: false, open: false, paused: false });
    expect(accepted).toBe("accepted");
    expect(after.memory).toEqual({ configured: true, open: false, model: MEMORY_MODEL, paused: false });
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
    await waitUntil(() => slot.snapshot().configurationBlocker === null);
    await waitUntil(async () => (await f.registry.homeOwner().memoryStatus()).blocked !== undefined);
    const requestsBefore = requests.length;
    f.faux.setResponses([responsesOf(f, requests)("must never be produced")]);
    await slot.prompt(longInput("blocked activation two"));
    await waitUntil(() => slot.snapshot().configurationBlocker === null);
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
    await waitUntil(() => slot.snapshot().configurationBlocker === null);
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
    await waitUntil(() => reopened.snapshot().configurationBlocker === null);
    const after = await f.registry.homeOwner().memoryStatus();
    const persisted = await readMemoryState(f, await homeMemoryStateId(f));
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
