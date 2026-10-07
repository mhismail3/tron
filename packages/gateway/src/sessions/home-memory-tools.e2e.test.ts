/**
 * Tron Home's memory tools end to end: `zoom`, `date` and `memory_search`
 * registered by the real `tron-home` module, called by a faux model inside a real
 * activation on a designated Home, with the real `EpisodicMemory` behind a
 * deterministic faux compactor.
 *
 * The compactor is injected on the Gateway's ModelRuntime seam, so every request
 * this file counts is Home's own. The canonical history is built two ways, like
 * the memory's own e2e: by prompting the Home session (which is what an
 * activation is), and by planting entries on the session's own SessionManager
 * where a case needs exact control (a credential, model reasoning, an oversized
 * tool call, a context edit, a navigation).
 *
 * The retained artifact is `test-results/home-memory-tools/report.json`.
 *
 * Failure modes (progress.md, written before the code): F1 a stale projection, F2
 * reasoning/credential/oversize leakage, F3 a stale child summary instead of the
 * placeholder, F4 an address that is not a line, F5 `[omitted]`, F6 a date from
 * the wrong source or a guess, F7 search misses/bounds/hidden omissions, F8 an
 * empty or oversized query, F9 a memory that is not this Home's or is stopped,
 * F11 an unbounded tool result, F12 a varying system prompt or tool list, F14 a
 * mutated view or a refused tool-result step.
 */
import { appendFile, mkdir, mkdtemp, readFile, rm, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { waitFor } from "../../test-support/wait-for.js";
import { ModelRuntime, type AgentSession } from "@earendil-works/pi-coding-agent";
import { TronWorkspace } from "../workspace/tron-workspace.js";
import {
  fauxAssistantMessage, fauxProvider, fauxText, fauxThinking, fauxToolCall,
  type AssistantMessage, type FauxProviderHandle, type Message, type ToolCall,
} from "@earendil-works/pi-ai";
import { afterAll, afterEach, describe, expect, it } from "vitest";
import { TrustService } from "../admin/trust-service.js";
import { EPISODIC_DEFAULTS, type EpisodicMessageRecord, type EpisodicSummarizer } from "../episodic/episodic-contract.js";
import { EpisodicStore } from "../episodic/episodic-store.js";
import { HOME_MEMORY_VIEW_MARKER, type HomeMemoryUnavailableReason } from "../home/home-memory.js";
import type { HomeMemoryToolDetails } from "../home/home-memory-tools.js";
import type { HomeMemoryStatus } from "../protocol/types.js";
import { RuntimeRegistry } from "../sessions/runtime-registry.js";

const PROVIDER = "tron-home-tools";
const MODEL_ID = "chat";
const MEMORY_PROVIDER = "tron-home-tools-memory";
const MEMORY_MODEL_ID = "compactor";
const MEMORY_MODEL = { provider: MEMORY_PROVIDER, id: MEMORY_MODEL_ID };
/** A second physical memory model: a reconfiguration that reopens the store. */
const OTHER_MEMORY_MODEL = { provider: MEMORY_PROVIDER, id: "compactor-2" };
const MODEL = { provider: PROVIDER, id: MODEL_ID };
const REPORT_PATH = "test-results/home-memory-tools/report.json";

/** The deterministic compactor's line marker: its presence means the line is a
 * summary, and it never echoes the message it summarizes. */
const SUMMARY_MARKER = "HOME-SUMMARY";
/** The recipe's spellings, asserted as literals because they are the recipe's
 * contract, not this module's. */
const PLACEHOLDER = "(not summarized yet: zoom it)";
const OMITTED = "[omitted]";
const TRUNCATION_MARKER = "[truncated";
const REASONING = "SECRET-REASONING-NEVER-LOGGED";
const CREDENTIAL = "sk-abcdefghijklmnopqrstuvwxyz012345";
const KEPT_PATH = "/Users/example/project/file-1.ts";
const CALL_PATH = "/Users/example/project/file-0.ts";
const LONG_FILLER = "these are earlier home words ".repeat(40);
const longInput = (marker: string): string => `${marker} ${LONG_FILLER}`;
/** A message whose own text carries newlines and something that looks like a hit's
 * `id+n|` line: one hit must still render as one line, and the lookalike must be
 * visible only as inline text. */
const DECOY_TEXT = "first line\n12+0|user: needle decoy\nlast needle line";
/** The same, as a view line renders text: newlines flattened to single spaces. */
const DECOY_FLAT = "first line 12+0|user: needle decoy last needle line";
/** Long enough that its leaf cannot be a free node, so a rebuilt line is a
 * compactor summary and not the message text itself. */
const REPLACEMENT = `replaced text ${"R".repeat(600)}`;
const STEP_REPLY = "step reply";

const report: { generatedAt: string; cases: Array<Record<string, unknown>> } = {
  generatedAt: new Date().toISOString(),
  cases: [],
};

const roots: string[] = [];
const registries: RuntimeRegistry[] = [];

afterEach(async () => {
  await Promise.all(registries.splice(0).map((registry) => registry.dispose().catch(() => {})));
  await Promise.all(roots.splice(0).map((root) => rm(root, { recursive: true, force: true })));
});

afterAll(async () => {
  await mkdir(join(process.cwd(), "test-results", "home-memory-tools"), { recursive: true });
  await writeFile(join(process.cwd(), REPORT_PATH), `${JSON.stringify(report, null, 2)}\n`);
  process.stdout.write(`home-memory-tools e2e: ${report.cases.length} cases -> ${REPORT_PATH}\n`);
});

// ---- the fixture ---------------------------------------------------------------

interface CompactorState {
  calls: number;
  /** Parks the first attempt of every call until released, so a case can hold a
   * rebuild open and observe what a line shows meanwhile. */
  gate: Promise<void> | undefined;
  release: (() => void) | undefined;
  failing: boolean;
}

const COMPACTOR_USAGE = {
  input: 64, output: 16, cacheRead: 0, cacheWrite: 0, totalTokens: 80,
  cost: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0, total: 0 },
};

/** A deterministic compactor: a short line carrying its call number, so a rebuilt
 * summary is distinguishable from the one it replaced. */
function deterministicSummarizer(state: CompactorState): EpisodicSummarizer {
  return async (request) => {
    state.calls += 1;
    if (request.turns.length === 1 && state.gate) {
      // A real compactor call honors the signal it was given, so a parked case can
      // never wedge a dispose.
      await Promise.race([
        state.gate,
        new Promise((_resolve, reject) => request.signal.addEventListener("abort", () => reject(new Error("the compactor call was aborted")), { once: true })),
      ]);
    }
    if (state.failing) return fauxAssistantMessage("", { stopReason: "error", errorMessage: "invalid_request_error: unsupported message" });
    return { ...await fauxAssistantMessage(`${SUMMARY_MARKER} ${state.calls}`), usage: COMPACTOR_USAGE };
  };
}

type HomeSlot = Awaited<ReturnType<RuntimeRegistry["acquire"]>>;

interface Fixture {
  root: string;
  tronHome: string;
  faux: FauxProviderHandle;
  runtime: ModelRuntime;
  compactor: CompactorState;
  /** Every provider request of every activation in this case, in order. */
  requests: CapturedRequest[];
  /** Every record Home's memory reported (its coded ingest failures). */
  memoryDiagnostics: Array<{ event: string; reason?: string }>;
  registry: RuntimeRegistry;
  sessionId: string;
  slot: HomeSlot;
}

function openRegistry(f: Fixture): RuntimeRegistry {
  const registry = new RuntimeRegistry({
    agentDir: join(f.root, "agent"),
    tronHome: f.tronHome,
    idleRuntimeMs: 60_000,
    modelRuntimeFactory: async () => f.runtime,
    trust: new TrustService(join(f.root, "agent")),
    broadcast: () => {},
    sessionSummaryChanged: () => {},
    sessionListChanged: () => {},
    homeMemorySummarizer: () => ({ summarizer: deterministicSummarizer(f.compactor) }),
    homeMemoryDiagnostic: (record) => f.memoryDiagnostics.push(record),
  });
  registries.push(registry);
  return registry;
}

async function fixture(label: string, options: { configure?: boolean } = {}): Promise<Fixture> {
  const root = await mkdtemp(join(tmpdir(), `tron-home-tools-${label}-`));
  roots.push(root);
  const tronHome = join(root, "tron");
  await mkdir(join(root, "agent"), { recursive: true });
  await writeFile(join(root, "agent", "settings.json"), JSON.stringify({ defaultProvider: PROVIDER, defaultModel: MODEL_ID }));
  const faux = fauxProvider({
    provider: PROVIDER,
    models: [{ id: MODEL_ID, reasoning: true }],
    tokensPerSecond: 1_000_000,
    tokenSize: { min: 10, max: 10 },
  });
  const memoryFaux = fauxProvider({ provider: MEMORY_PROVIDER, models: [{ id: MEMORY_MODEL_ID, reasoning: false }, { id: OTHER_MEMORY_MODEL.id, reasoning: false }] });
  const runtime = await ModelRuntime.create({ authPath: join(root, "auth.json"), modelsPath: null, refreshOnCreate: false });
  runtime.registerNativeProvider(faux.provider);
  runtime.registerNativeProvider(memoryFaux.provider);
  const f = {
    root, tronHome, faux, runtime,
    compactor: { calls: 0, gate: undefined, release: undefined, failing: false } as CompactorState,
    requests: [] as CapturedRequest[],
    memoryDiagnostics: [] as Array<{ event: string; reason?: string }>,
  } as Fixture;
  await attach(f, options);
  return f;
}

/** Designate Home on this installation's record, configure its memory, and hold
 * its slot. A restarted Gateway reads the record the first designation wrote, so
 * `configure: false` is the restart path: the memory opens at the first
 * activation, from the record. */
async function attach(f: Fixture, options: { configure?: boolean } = {}): Promise<void> {
  const registry = openRegistry(f);
  f.registry = registry;
  await registry.initialize();
  // A session with no live runtime is resolved from the catalog, so a restarted
  // Gateway must finish that read before it can hand the session out.
  const hasCut = (): boolean => (registry as unknown as { sessionCatalog: { hasCompleteCut(): boolean } }).sessionCatalog.hasCompleteCut();
  await waitUntil(hasCut, 30_000);
  await registry.catalog("all");
  const designation = await registry.homeOwner().designate({ model: MODEL }, () => MODEL);
  if (options.configure !== false) {
    await registry.homeOwner().configureMemory({ model: MEMORY_MODEL });
  }
  f.sessionId = designation.sessionId;
  f.slot = await registry.acquire(designation.sessionId);
}

const sessionOf = (f: Fixture): AgentSession => (f.slot as unknown as { runtime: { session: AgentSession } }).runtime.session;
const managerOf = (f: Fixture) => sessionOf(f).sessionManager;

function waitUntil(predicate: () => boolean | Promise<boolean>, timeoutMs = 12_000): Promise<void> {
  return waitFor(async () => (await predicate()) || undefined, "Home memory tool condition", { boundMs: timeoutMs });
}

async function memoryStatus(f: Fixture): Promise<HomeMemoryStatus> {
  return await f.registry.homeOwner().memoryStatus();
}

/** Every view line the memory would send is a built summary. */
async function waitForBuiltTree(f: Fixture): Promise<void> {
  await waitUntil(async () => {
    const status = await memoryStatus(f);
    return status.open && (status.episodic?.view.unbuilt ?? 1) === 0;
  });
}

// ---- reading one captured provider request -------------------------------------

interface CapturedRequest {
  roles: string[];
  /** Every message of the request, timestamps zeroed so two runs are
   * byte-comparable. */
  blob: string;
}

interface ToolObservation {
  toolName: string;
  text: string;
  details: HomeMemoryToolDetails | undefined;
  isError: boolean;
}

function record(context: { messages: Array<{ role: string }> }): CapturedRequest {
  return {
    roles: context.messages.map((message) => message.role),
    blob: JSON.stringify(context.messages, (key, value) => key === "timestamp" ? 0 : value),
  };
}

function messagesOf(request: CapturedRequest): Array<Record<string, unknown>> {
  return JSON.parse(request.blob) as Array<Record<string, unknown>>;
}

/** The frozen memory view one request carried, without its per-activation nonce. */
function viewOf(request: CapturedRequest): string {
  const start = request.blob.indexOf(HOME_MEMORY_VIEW_MARKER);
  const end = request.blob.indexOf("</chat>", start);
  return start < 0 || end < 0 ? "" : request.blob.slice(start, end);
}

/** The head of the cached prefix: the system prompt and the declared tool list. */
function systemOf(request: CapturedRequest): string {
  return JSON.stringify(messagesOf(request).filter((message) => message.role === "system"));
}

/** Every tool result the request carried, in order: the activation's own tail
 * accumulates them, and no other activation's results are in this request. */
function toolResultsOf(request: CapturedRequest): ToolObservation[] {
  return messagesOf(request)
    .filter((message) => message.role === "toolResult")
    .map((message) => ({
      toolName: String(message.toolName),
      text: (Array.isArray(message.content) ? message.content : []).map((part) => String((part as { text?: unknown }).text ?? "")).join(""),
      details: message.details as HomeMemoryToolDetails | undefined,
      isError: message.isError === true,
    }));
}

// ---- driving activations -------------------------------------------------------

/** One scripted model step: a tool call, and where a case mutates the canonical
 * session mid-activation (before the tool it then calls runs). */
interface Step {
  name: string;
  args: ToolCall["arguments"];
  before?: () => void | Promise<void>;
}

/** Run one activation: one model step per tool call, then a closing reply. */
async function runActivation(f: Fixture, input: string, steps: Step[]): Promise<CapturedRequest> {
  f.faux.setResponses([
    ...steps.map((step) => async (context: { messages: Array<{ role: string }> }) => {
      f.requests.push(record(context));
      await step.before?.();
      return fauxAssistantMessage(fauxToolCall(step.name, step.args));
    }),
    async (context: { messages: Array<{ role: string }> }) => { f.requests.push(record(context)); return fauxAssistantMessage(`${STEP_REPLY} ${steps.length}`); },
  ]);
  const before = f.requests.length;
  await f.slot.prompt(input);
  await waitUntil(() => !f.slot.isBusy);
  const activation = f.requests.slice(before);
  expect(activation.length, "one request per step, plus the closing reply").toBe(steps.length + 1);
  return activation.at(-1)!;
}

/** The tool answers of one activation, in the order the model asked for them. */
async function toolAnswers(f: Fixture, input: string, steps: Step[]): Promise<ToolObservation[]> {
  const answers = toolResultsOf(await runActivation(f, input, steps));
  expect(answers.length, "each scripted tool call must have executed").toBe(steps.length);
  return answers;
}

/** One plain activation with no tool call: how a case plants conversational
 * history. */
async function prompt(f: Fixture, input: string, reply: string): Promise<void> {
  f.faux.setResponses([async (context: { messages: Array<{ role: string }> }) => { f.requests.push(record(context)); return fauxAssistantMessage(reply); }]);
  await f.slot.prompt(input);
  await waitUntil(() => !f.slot.isBusy);
}

const ok = (answer: ToolObservation): string => {
  expect(answer.details, `${answer.toolName} must answer, not refuse: ${answer.text}`).toEqual({ status: "ok" });
  return answer.text;
};

const unavailable = (answer: ToolObservation, reason: HomeMemoryUnavailableReason): string => {
  expect(answer.isError).toBe(false);
  expect(answer.details).toEqual({ status: "unavailable", reason });
  return answer.text;
};

// ---- canonical history helpers -------------------------------------------------

interface CanonicalEntry { id: string; timestamp: string; type: string; message?: Record<string, unknown> }

async function canonicalEntries(f: Fixture): Promise<CanonicalEntry[]> {
  const jsonl = f.slot.sessionFile ? await readFile(f.slot.sessionFile, "utf8").catch(() => "") : "";
  return jsonl.trimEnd().split("\n").filter((line) => line !== "").map((line) => JSON.parse(line) as CanonicalEntry);
}

/** The canonical entry one message text was written as. Message entries of the
 * branch, in order, are the memory's messages. */
async function entryForMessageText(f: Fixture, text: string): Promise<CanonicalEntry> {
  const entries = (await canonicalEntries(f)).filter((entry) => entry.type === "message");
  const found = entries.find((entry) => JSON.stringify(entry.message).includes(text));
  expect(found, `no canonical entry holds ${text}`).toBeDefined();
  return found!;
}

const userMessage = (text: string): Message => ({ role: "user", content: text, timestamp: Date.now() });

/** The text one durable node record holds for an address, read from the store the
 * memory wrote: the independent oracle for "what the line said before". */
async function durableNodeText(f: Fixture, level: number, index: number): Promise<string | undefined> {
  const path = join(f.tronHome, "workspace", "state", "episodic", f.sessionId, "nodes.jsonl");
  const lines = (await readFile(path, "utf8")).trimEnd().split("\n").filter((line) => line !== "");
  const records = lines.map((line) => JSON.parse(line) as Record<string, unknown>);
  const latest = records.filter((record) => record.level === level && record.index === index && typeof record.text === "string").at(-1);
  return typeof latest?.text === "string" ? latest.text : undefined;
}

/** The date tool's answer for one canonical instant, rendered the way this
 * machine reads it, computed here from the instant's own local fields. */
function expectedDateText(entry: CanonicalEntry): string {
  const at = new Date(entry.timestamp);
  const pad = (part: number): string => String(part).padStart(2, "0");
  const offset = -at.getTimezoneOffset();
  const minutes = Math.abs(offset);
  return `${at.getFullYear()}-${pad(at.getMonth() + 1)}-${pad(at.getDate())}`
    + ` ${pad(at.getHours())}:${pad(at.getMinutes())}:${pad(at.getSeconds())}`
    + ` ${offset < 0 ? "-" : "+"}${pad(Math.floor(minutes / 60))}:${pad(minutes % 60)}`;
}

const refusalsOf = (f: Fixture) => f.registry.homeOwner().requestPolicyFor(f.sessionId)?.refusalLog().map((entry) => entry.reason) ?? [];

/** Read persisted catalog entries through the active store, including a checkpoint
 * and any remaining append tail. */
async function persistedCatalog(f: Fixture): Promise<EpisodicMessageRecord[]> {
  // Reuse Home's initialized workspace. Store reads are read-only and do not
  // reserve another opener or reclaim its active checkpoint artifacts.
  const workspace = (f.registry as unknown as { workspace: TronWorkspace }).workspace;
  const store = new EpisodicStore(workspace, f.sessionId, EPISODIC_DEFAULTS.maxStoreLineBytes);
  return [...(await store.read()).messages.values()];
}

async function catalogTimestampFlags(f: Fixture, maxIndex: number): Promise<Array<{ index: unknown; omitted: unknown; timestamp: boolean }>> {
  return (await persistedCatalog(f))
    .filter((entry) => entry.index <= maxIndex)
    .map((entry) => ({ index: entry.index, omitted: entry.omitted, timestamp: entry.timestamp !== undefined }));
}

describe.sequential("Tron Home memory tools end to end", () => {
  it("opens a line into its two children, gives a message whole, and refuses an address that is not a line", async () => {
    const f = await fixture("zoom");
    await prompt(f, "zoom-m0", "reply-r0");
    await prompt(f, "zoom-m2", "reply-r2");
    await prompt(f, "zoom-m4", "reply-r4");
    // Six short messages are a tree of free nodes: every merge is its children's
    // own text, so the expected lines are exact, not inferred.
    await waitUntil(async () => ((await memoryStatus(f)).episodic?.nodes.byLevel ?? []).some((entry) => entry.level >= 2));
    const firstActivationSystem = systemOf(f.requests[0]!);

    const answers = await toolAnswers(f, "tools", [
      { name: "zoom", args: { id: 0, n: 4 } },
      { name: "zoom", args: { id: 0, n: 2 } },
      { name: "zoom", args: { id: 2, n: 1 } },
      { name: "zoom", args: { id: 1, n: 2 } },
      { name: "zoom", args: { id: 0, n: 3 } },
      { name: "zoom", args: { id: 0, n: 1024 } },
      // Every invalid argument reaches the memory's own refusal, including the
      // ones a schema bound would have rejected first.
      { name: "zoom", args: { id: 0, n: 0 } },
      { name: "zoom", args: { id: -1, n: 2 } },
      { name: "zoom", args: { id: 1.5, n: 2 } },
      { name: "zoom", args: { id: 0, n: 1.5 } },
      { name: "zoom", args: { id: 2.5, n: 1 } },
      { name: "date", args: { id: 2 } },
      { name: "date", args: { id: 999 } },
    ]);
    const entry = await entryForMessageText(f, "zoom-m2");
    const toolRequests = f.requests.slice(f.requests.length - 14);
    const row = {
      children: ok(answers[0]!),
      halves: ok(answers[1]!),
      message: ok(answers[2]!),
      misaligned: answers[3]!.text,
      notPowerOfTwo: answers[4]!.text,
      pastTheEnd: answers[5]!.text,
      zeroN: answers[6]!.text,
      negativeId: answers[7]!.text,
      fractionalId: answers[8]!.text,
      fractionalN: answers[9]!.text,
      fractionalIdOne: answers[10]!.text,
      date: ok(answers[11]!),
      expectedDate: `2+0|${expectedDateText(entry)}`,
      unknownDate: answers[12]!.text,
      // The frozen view must not move under the tool loop, and the head of the
      // cached prefix (system prompt plus tool list) must not move across
      // activations.
      viewFrozen: toolRequests.every((request) => viewOf(request) !== "" && viewOf(request) === viewOf(toolRequests[0]!)),
      // The view's own newlines are escaped in the captured JSON, so the line
      // count is the escapes plus the one unterminated line.
      viewLines: (viewOf(toolRequests[0]!).match(/\\n/gu) ?? []).length + 1,
      // The head of the cached prefix must be a real system message that carries
      // the tool list and Home's operating context, and it must not move.
      systemMessages: messagesOf(toolRequests[0]!).filter((message) => message.role === "system").length,
      systemCarriesToolList: systemOf(toolRequests[0]!).includes("memory_search"),
      systemCarriesOperatingContext: systemOf(toolRequests[0]!).includes("## Tron Home"),
      systemIdentical: toolRequests.every((request) => systemOf(request) === firstActivationSystem),
      // What the model reads about the view: the kinds it will see tagged, and how
      // to navigate a line.
      preambleKinds: viewOf(toolRequests[0]!).includes("talk (your replies and tool calls)"),
      preambleNavigation: viewOf(toolRequests[0]!).includes("zoom(id, n) opens line id+n"),
      refusals: refusalsOf(f),
      toolResultMessages: (f.requests.at(-1)?.roles ?? []).filter((role) => role === "toolResult").length,
    };
    report.cases.push({ case: "zoom", ...row });
    expect(row.children).toBe("0+2|user: zoom-m0 talk: reply-r0\n2+2|user: zoom-m2 talk: reply-r2");
    expect(row.halves).toBe("0+1|user: zoom-m0\n1+1|talk: reply-r0");
    expect(row.message).toBe("2+0|user: zoom-m2");
    expect(row.misaligned).toBe("No line 1+2.");
    expect(row.notPowerOfTwo).toBe("No line 0+3.");
    expect(row.pastTheEnd).toBe("No line 0+1024.");
    expect(row.date).toBe(row.expectedDate);
    expect(row.unknownDate).toBe("No line 999+1.");
    expect(row.zeroN).toBe("No line 0+0.");
    expect(row.negativeId).toBe("No line -1+2.");
    expect(row.fractionalId).toBe("No line 1.5+2.");
    expect(row.fractionalN).toBe("No line 0+1.5.");
    expect(row.fractionalIdOne).toBe("No line 2.5+1.");
    expect(row.viewFrozen).toBe(true);
    expect(row.viewLines).toBeGreaterThan(1);
    expect(row.systemMessages).toBe(1);
    expect(row.systemCarriesToolList).toBe(true);
    expect(row.systemCarriesOperatingContext).toBe(true);
    expect(row.systemIdentical).toBe(true);
    expect(row.preambleKinds).toBe(true);
    expect(row.preambleNavigation).toBe(true);
    // A tool loop is a mutation risk and a replay risk: either would appear here.
    expect(row.refusals).toEqual([]);
    expect(row.toolResultMessages).toBe(13);
  }, 120_000);

  it("gives a message's projected text: no reasoning, credentials redacted, paths kept, bounded", async () => {
    const f = await fixture("projected");
    await prompt(f, "start", "a reply");
    // Planted on the session's own manager, so the reasoning and the tool call are
    // exactly the canonical shapes the projection must filter.
    managerOf(f).appendMessage(userMessage(`paste ${CREDENTIAL} ${KEPT_PATH} ${"p".repeat(40_000)}`));
    managerOf(f).appendMessage(fauxAssistantMessage([fauxText("the reply text"), fauxThinking(REASONING), fauxToolCall("read_file", { path: CALL_PATH })]));

    const answers = await toolAnswers(f, "tools", [
      { name: "zoom", args: { id: 2, n: 1 } },
      { name: "zoom", args: { id: 3, n: 1 } },
    ]);
    const pasted = ok(answers[0]!);
    const reply = ok(answers[1]!);
    const row = {
      pastedChars: pasted.length,
      pastedHead: pasted.slice(0, 48),
      credentialRedacted: pasted.includes("[REDACTED]") && !pasted.includes(CREDENTIAL),
      pathKept: pasted.includes(KEPT_PATH),
      bounded: pasted.includes(TRUNCATION_MARKER) && pasted.length < 30_000 + 64,
      reasoningExcluded: !reply.includes(REASONING),
      replyTextKept: reply.includes("the reply text"),
      callKept: reply.includes(`[call read_file {"path":"${CALL_PATH}"}]`),
    };
    report.cases.push({ case: "projected", ...row });
    expect(row.credentialRedacted).toBe(true);
    expect(row.pathKept).toBe(true);
    expect(row.bounded).toBe(true);
    expect(row.reasoningExcluded).toBe(true);
    expect(row.replyTextKept).toBe(true);
    expect(row.callKept).toBe(true);
  }, 120_000);

  it("shows a revoked child as the placeholder, and its rebuilt summary once rebuilt", async () => {
    const f = await fixture("edit");
    await prompt(f, longInput("edit target"), "reply-r0");
    await waitForBuiltTree(f);
    const before = await durableNodeText(f, 0, 0);
    expect(before).toContain(SUMMARY_MARKER);
    const target = await entryForMessageText(f, "edit target");
    const callsBefore = f.compactor.calls;
    f.compactor.gate = new Promise<void>((resolve) => { f.compactor.release = resolve; });

    const answers = await toolAnswers(f, longInput("edit activation"), [
      {
        name: "zoom",
        args: { id: 0, n: 2 },
        // Committed inside the activation, after its readiness wait: this is what a
        // context edit does to a summarized line while Home is working.
        before: () => { managerOf(f).appendContextEdit(target.id, { content: REPLACEMENT }); },
      },
      { name: "zoom", args: { id: 0, n: 1 } },
    ]);
    const revoked = ok(answers[0]!).split("\n");
    const row = {
      revokedLine: revoked[0],
      // The line that held the old summary must now be the placeholder: a live
      // node's text can never be served for a revoked node.
      placeholderNotStale: revoked[0] === `0+1|${PLACEHOLDER}` && revoked[0] !== `0+1|${before!.replace(/\n+/gu, " ")}`,
      oldLeafText: before,
      siblingLine: revoked[1],
      editedMessage: ok(answers[1]!),
      parkedCalls: f.compactor.calls - callsBefore,
      blocked: (await memoryStatus(f)).blocked ?? null,
    };
    report.cases.push({ case: "edit", ...row });
    expect(row.revokedLine).toBe(`0+1|${PLACEHOLDER}`);
    expect(row.placeholderNotStale).toBe(true);
    expect(row.editedMessage).toContain("0+0|user: replaced text");
    // The rebuild is held open by the parked compactor, so the placeholder is not
    // a race with a fast summary.
    expect(row.parkedCalls).toBeGreaterThan(0);
    expect(row.blocked).toBeNull();

    // Release the rebuild: the same line becomes the fresh summary, never the text
    // it held before.
    f.compactor.release?.();
    f.compactor.gate = undefined;
    await waitForBuiltTree(f);
    const rebuilt = ok((await toolAnswers(f, "after the rebuild", [{ name: "zoom", args: { id: 0, n: 2 } }]))[0]!).split("\n");
    report.cases.push({ case: "edit-rebuilt", revokedLine: row.revokedLine, rebuiltLine: rebuilt[0], durable: await durableNodeText(f, 0, 0) });
    expect(rebuilt[0]).toContain(SUMMARY_MARKER);
    expect(rebuilt[0]).not.toBe(`0+1|${before!.replace(/\n+/gu, " ")}`);
  }, 120_000);

  it("shows an off-branch message as [omitted]", async () => {
    const f = await fixture("branch");
    await prompt(f, "keep one", "reply-r0");
    const keptLeaf = managerOf(f).getLeafId()!;
    await prompt(f, "keep two", "reply-r1");
    // Navigate back to the first reply: the second turn is off the branch now.
    managerOf(f).branch(keptLeaf);

    const answers = await toolAnswers(f, "after the navigation", [
      { name: "zoom", args: { id: 2, n: 1 } },
      { name: "zoom", args: { id: 3, n: 1 } },
      { name: "memory_search", args: { query: "keep two", to: 4 } },
    ]);
    const row = {
      prompt: ok(answers[0]!),
      reply: ok(answers[1]!),
      search: ok(answers[2]!),
    };
    report.cases.push({ case: "branch", ...row });
    expect(row.prompt).toBe(`2+0|user: ${OMITTED}`);
    expect(row.reply).toBe(`3+0|talk: ${OMITTED}`);
    // The off-branch text is gone from the catalog, so the search cannot find it
    // and says how much of the range it could not search.
    expect(row.search).toBe('memory_search "keep two" in messages [0, 4): 0 match(es), 0 shown, 2 [omitted], 0 capped.');
  }, 120_000);

  it("reports search hits, its bounds, and what the range could not search", async () => {
    const f = await fixture("search");
    await prompt(f, "alpha needle one", "bravo");
    const manager = managerOf(f);
    manager.appendMessage(userMessage("charlie needle two"));
    // An oversized tool call: the projection caps its arguments and records the cap
    // as an omission the search must report.
    manager.appendMessage(fauxAssistantMessage([fauxToolCall("display", { document: "d".repeat(31_000) })]));
    manager.appendMessage(userMessage("echo needle three"));
    manager.appendMessage(userMessage(`longneedle ${"L".repeat(400)}`));
    // A message whose own text carries newlines and something that looks like a
    // hit's `id+n|` line: the snippet must still be one line per hit.
    manager.appendMessage(userMessage(DECOY_TEXT));
    const bulk = Array.from({ length: 21 }, (_unused, index) => manager.appendMessage(userMessage(`bulkbatch ${index}`)));
    manager.appendMessage(userMessage("to be dropped"));
    // Ingest all of it, then navigate back to the last bulk message: what is
    // already indexed stays at its index as `[omitted]`, which is a slot the
    // search must count rather than silently skip.
    await prompt(f, "ingest them", "reply-r1");
    await waitUntil(async () => ((await memoryStatus(f)).episodic?.messages ?? 0) === 31);
    manager.branch(bulk.at(-1)!);

    const answers = await toolAnswers(f, "tools", [
      { name: "memory_search", args: { query: "needle", from: 0, to: 7 } },
      { name: "memory_search", args: { query: "NEEDLE", from: 0, to: 7 } },
      { name: "memory_search", args: { query: "bulkbatch", from: 0, to: 32 } },
      { name: "memory_search", args: { query: "omitted", from: 0, to: 32 } },
      { name: "memory_search", args: { query: "" } },
      { name: "memory_search", args: { query: "n".repeat(201) } },
    ]);
    const needleResult = ok(answers[0]!);
    const hits = needleResult.split("\n");
    const upper = ok(answers[1]!).split("\n");
    const bulkHits = ok(answers[2]!).split("\n");
    const omittedResult = ok(answers[3]!);
    const empty = answers[4]!;
    const oversized = answers[5]!;
    const row = {
      header: hits[0],
      hitLines: hits.slice(1),
      resultLines: hits.length,
      decoyLine: hits.find((line) => line.startsWith("6+0|")),
      upperCaseHeader: upper[0],
      firstHitChars: hits[1]?.length ?? 0,
      bulkHeader: bulkHits[0],
      bulkShown: bulkHits.length - 1,
      omittedHeader: omittedResult.split("\n")[0],
      omittedHits: omittedResult.split("\n").slice(1),
      // A hit's snippet is bounded, however long the message that holds it.
      longSnippetBounded: hits.some((line) => line.startsWith("5+0|user: longneedle") && line.length - "5+0|user: ".length <= 300),
      emptyOutcome: empty.details,
      emptyText: empty.text,
      oversizedOutcome: oversized.details,
      oversizedText: oversized.text,
    };
    report.cases.push({ case: "search", ...row });
    // Indices 0, 2, 4, 5 and 6 hold "needle" (5 inside a 400-character message, 6
    // across its newlines); index 3 is capped; indices 28-30 are off the branch and
    // `[omitted]`.
    expect(row.header).toBe('memory_search "needle" in messages [0, 7): 5 match(es), 5 shown, 0 [omitted], 1 capped.');
    expect(row.upperCaseHeader).toBe('memory_search "NEEDLE" in messages [0, 7): 5 match(es), 5 shown, 0 [omitted], 1 capped.');
    expect(row.hitLines.map((line) => line.split("|")[0])).toEqual(["0+0", "2+0", "4+0", "5+0", "6+0"]);
    // One line per hit, whatever the message's own newlines were.
    expect(row.resultLines).toBe(6);
    expect(row.decoyLine).toBe(`6+0|user: ${DECOY_FLAT}`);
    expect(row.decoyLine ?? "").not.toContain("\n");
    expect(row.longSnippetBounded).toBe(true);
    expect(row.bulkHeader).toBe('memory_search "bulkbatch" in messages [0, 32): 21 match(es), 20 shown, 3 [omitted], 1 capped.');
    expect(row.bulkShown).toBe(20);
    // An omitted message holds no searchable text: the `[omitted]` placeholder is
    // counted in the header and never reported as a hit.
    expect(row.omittedHeader).toBe('memory_search "omitted" in messages [0, 32): 0 match(es), 0 shown, 3 [omitted], 1 capped.');
    expect(row.omittedHits).toEqual([]);
    expect(row.emptyOutcome).toEqual({ status: "invalid-arguments" });
    expect(row.emptyText).toBe("memory_search needs a query of 1 to 200 characters.");
    expect(row.oversizedOutcome).toEqual({ status: "invalid-arguments" });
    expect(row.oversizedText).toBe(row.emptyText);
  }, 120_000);

  it("answers a typed unavailable result for a stopped memory", async () => {
    const f = await fixture("blocked");
    await prompt(f, longInput("blocked first"), "reply-r0");
    await waitForBuiltTree(f);
    // The next activation's own input needs a summary, and that compactor call
    // fails permanently: the memory stops while the activation is already served.
    f.compactor.failing = true;

    const answers = await toolAnswers(f, longInput("blocked second"), [
      {
        name: "zoom",
        args: { id: 0, n: 1 },
        before: () => waitUntil(async () => (await memoryStatus(f)).blocked === "permanent-failure"),
      },
      { name: "date", args: { id: 0 } },
      { name: "memory_search", args: { query: "blocked", to: 2 } },
    ]);
    const texts = answers.map((answer) => unavailable(answer, "memory-blocked"));
    const row = { blocked: (await memoryStatus(f)).blocked ?? null, texts, providerRequests: f.requests.length };
    report.cases.push({ case: "blocked", ...row });
    expect(row.blocked).toBe("permanent-failure");
    for (const text of row.texts) expect(text).toContain("stopped");
    // The activation that was already served still ran its whole tool loop: the
    // memory stopped its pump, not the turn.
    expect(row.providerRequests).toBeGreaterThan(2);
  }, 120_000);

  it("shows an edit committed between activations, not the text the view carried", async () => {
    const f = await fixture("fresh");
    await prompt(f, "original text", "reply-r0");
    await waitForBuiltTree(f);
    const target = await entryForMessageText(f, "original text");
    managerOf(f).appendContextEdit(target.id, { content: "the latest text" });

    const answers = await toolAnswers(f, "tools", [
      { name: "zoom", args: { id: 0, n: 1 } },
      { name: "date", args: { id: 0 } },
    ]);
    const row = {
      zoom: ok(answers[0]!),
      date: ok(answers[1]!),
      expectedDate: `0+0|${expectedDateText(target)}`,
      blocked: (await memoryStatus(f)).blocked ?? null,
    };
    report.cases.push({ case: "fresh", ...row });
    expect(row.zoom).toBe("0+0|user: the latest text");
    expect(row.zoom).not.toContain("original text");
    expect(row.date).toBe(row.expectedDate);
    expect(row.blocked).toBeNull();
  }, 120_000);

  it("answers a date for a catalog record written before the field existed", async () => {
    const f = await fixture("legacy");
    await prompt(f, "first text", "reply-r0");
    const planted = managerOf(f).appendMessage(userMessage("no date on this record"));
    // Ingest it, so the navigation below leaves an indexed message off the branch
    // rather than an entry the memory never held.
    await prompt(f, "ingest them", "reply-r1");
    await waitUntil(async () => ((await memoryStatus(f)).episodic?.messages ?? 0) === 5);
    const plantedEntry = (await canonicalEntries(f)).find((entry) => entry.id === planted)!;
    // The first *projected* message, not the session's first message entry: the
    // session's own system message is a message entry too and holds no slot.
    const firstMessage = await entryForMessageText(f, "first text");
    // Persist the off-branch selection before reopening memory, so the fixture
    // starts from a complete canonical session snapshot rather than racing the
    // live source reader against SessionManager's navigation write.
    managerOf(f).branch(firstMessage.id);
    // A record written by a build before the optional `timestamp` existed: remove
    // only that field, then publish it through the supported checkpoint API.
    await f.registry.dispose();
    registries.splice(registries.indexOf(f.registry), 1);
    const workspace = new TronWorkspace(f.tronHome);
    await workspace.initialize();
    try {
      const store = new EpisodicStore(workspace, f.sessionId, EPISODIC_DEFAULTS.maxStoreLineBytes);
      const snapshot = await store.read();
      if (!snapshot.state) throw new Error("Legacy timestamp fixture has no persisted store state");
      const legacyMessages = [...snapshot.messages.values()].map((record) => {
        const legacy = { ...record };
        delete legacy.timestamp;
        return legacy;
      });
      await store.checkpoint({
        messages: legacyMessages,
        nodes: snapshot.nodes.values(),
        state: snapshot.state,
        watermark: snapshot.highestRevision,
      });
    } finally { await workspace.dispose(); }

    // The store is read from disk again, as a Gateway restart does, so the memory
    // loads those records as its catalog.
    await attach(f, { configure: false });
    const status = await memoryStatus(f);
    // One message stays on the branch the reader follows; the others leave it,
    // so the source has to prove an instant for a record that is no longer on the
    // branch.

    const answers = await toolAnswers(f, "tools", [
      { name: "date", args: { id: 0 } },
      { name: "date", args: { id: 2 } },
      { name: "zoom", args: { id: 0, n: 1 } },
    ]);
    const row = {
      openBefore: status.open,
      date: ok(answers[0]!),
      expectedDate: `0+0|${expectedDateText(firstMessage)}`,
      // The read is by entry id over every parsed entry, not only the branch, so a
      // record that left the branch still answers its own entry's instant.
      offBranchDate: ok(answers[1]!),
      expectedOffBranchDate: `2+0|${expectedDateText(plantedEntry)}`,
      zoom: ok(answers[2]!),
      records: await catalogTimestampFlags(f, 4),
      // Nothing re-read the field into the catalog: both answers came from the
      // source.
      timestampsStillAbsent: (await catalogTimestampFlags(f, 4)).every((entry) => entry.timestamp === false),
      refusals: refusalsOf(f),
    };
    report.cases.push({ case: "legacy", ...row });
    expect(row.openBefore).toBe(false);
    expect(row.timestampsStillAbsent).toBe(true);
    expect(row.date).toBe(row.expectedDate);
    expect(row.offBranchDate).toBe(row.expectedOffBranchDate);
    expect(row.zoom).toBe("0+0|user: first text");
    expect(row.refusals).toEqual([]);

    // The one thing the source cannot prove: an entry the file no longer holds at
    // all. The record keeps its index as `[omitted]`, and the instant is gone with
    // the line.
    const canonical = await readFile(f.slot.sessionFile!, "utf8");
    await writeFile(f.slot.sessionFile!, canonical.split("\n").filter((line) => line !== "" && (JSON.parse(line) as { id?: string }).id !== plantedEntry.id).join("\n") + "\n");
    await f.registry.dispose();
    registries.splice(registries.indexOf(f.registry), 1);
    await attach(f, { configure: false });
    const gone = await toolAnswers(f, "tools", [{ name: "date", args: { id: 2 } }]);
    report.cases.push({ case: "legacy-entry-gone", date: gone[0]!.text, details: gone[0]!.details });
    expect(unavailable(gone[0]!, "timestamp-unavailable")).toContain("no longer available");
  }, 180_000);

  it("never reaches a memory for a session that is not the enabled Home", async () => {
    // A session that is not Home never has these tools registered, so the
    // accessor is the only place this state is reachable: the real owner, asked
    // for a foreign session id, answers with no memory at all.
    const f = await fixture("foreign");
    const owner = f.registry.homeOwner();
    const home = owner.memoryToolsFor(f.sessionId);
    report.cases.push({ case: "foreign", foreign: owner.memoryToolsFor("some-other-session") ?? null, home: home ? "accessor" : null });
    expect(owner.memoryToolsFor("some-other-session")).toBeUndefined();
    expect(home).toBeDefined();
    expect(home!.zoom).toBeTypeOf("function");
  }, 60_000);

  it("answers memory-not-configured through the owner for a designated but unconfigured Home", async () => {
    // The owner maps a session id to a memory, and a designated Home without a
    // configured memory has none: every tool says so through the owner's own
    // accessor, before any activation could exist.
    const f = await fixture("unconfigured", { configure: false });
    const status = await memoryStatus(f);
    const access = f.registry.homeOwner().memoryToolsFor(f.sessionId)!;
    const answers = [await access.zoom(0, 1), await access.date(0), await access.search("anything", undefined, undefined)];
    report.cases.push({ case: "unconfigured", configured: status.configured, open: status.open, answers });
    expect(status.configured).toBe(false);
    expect(status.open).toBe(false);
    for (const answer of answers) {
      expect(answer.outcome).toBe("unavailable");
      expect(answer.outcome === "unavailable" ? answer.reason : undefined).toBe("memory-not-configured");
    }
  }, 60_000);

  it("answers memory-blocked when the commit it ingests cannot be read", async () => {
    const f = await fixture("unreadable");
    await prompt(f, "blocked first", "reply-r0");
    await waitForBuiltTree(f);
    const sessionFile = f.slot.sessionFile!;
    // A canonical line over the reader's per-line bound, committed mid-activation:
    // the memory stops with `source-unavailable` while the ingest runs, which it
    // reports by state rather than by throwing where the tool calls it.
    const oversized = `{"type":"message","id":"oversized-entry","parentId":${JSON.stringify(managerOf(f).getLeafId())},"timestamp":${JSON.stringify(new Date().toISOString())},"message":{"role":"user","content":"${"x".repeat(16 * 1_024 * 1_024 + 1)}","timestamp":${Date.now()}}}`;

    f.faux.setResponses([
      async (context: { messages: Array<{ role: string }> }) => {
        f.requests.push(record(context));
        await appendFile(sessionFile, `${oversized}\n`);
        // All three tools, in one step: the first ingest stops the memory, and the
        // other two must report the same state rather than read the old catalog.
        return fauxAssistantMessage([
          fauxToolCall("zoom", { id: 0, n: 1 }),
          fauxToolCall("date", { id: 0 }),
          fauxToolCall("memory_search", { query: "blocked", to: 2 }),
        ]);
      },
      async (context: { messages: Array<{ role: string }> }) => { f.requests.push(record(context)); return fauxAssistantMessage("done"); },
    ]);
    await f.slot.prompt("tools");
    await waitUntil(() => !f.slot.isBusy);
    const answers = toolResultsOf(f.requests.at(-1)!);
    const row = {
      blocked: (await memoryStatus(f)).blocked ?? null,
      answers: answers.map((answer) => ({ details: answer.details, text: answer.text })),
      staleTextServed: answers.some((answer) => answer.text.includes("blocked first")),
    };
    report.cases.push({ case: "unreadable", ...row });
    expect(row.blocked).toBe("source-unavailable");
    expect(answers.length).toBe(3);
    for (const answer of answers) {
      expect(answer.details).toEqual({ status: "unavailable", reason: "memory-blocked" });
      expect(answer.text).toContain("stopped");
    }
    expect(row.staleTextServed).toBe(false);
  }, 180_000);

  it("reconfigures the memory while a commit is still ingesting it", async () => {
    const f = await fixture("race");
    await prompt(f, "race start", "reply-r0");
    await waitForBuiltTree(f);
    let reconfigured = "not attempted";
    let catalogAfterReconfigure: EpisodicMessageRecord[] = [];
    let modelAfterReconfigure: unknown;

    const answers = await toolAnswers(f, "race tools", [
      {
        name: "zoom",
        args: { id: 0, n: 1 },
        before: async () => {
          // A backlog the *commit* below owes: one catalog append and fsync each, so
          // the reconfiguration closes and reopens a store that is still being
          // written.
          for (let index = 0; index < 200; index += 1) managerOf(f).appendMessage(userMessage(`bulk ${index}`));
          f.registry.homeOwner().noteEntriesCommitted(f.sessionId);
          reconfigured = await f.registry.homeOwner().configureMemory({ model: OTHER_MEMORY_MODEL })
            .then(() => "accepted", (error: unknown) => (error as { code?: string }).code ?? "failed");
          // Read the store the reconfiguration reopened, before anything else
          // touches it.
          catalogAfterReconfigure = await persistedCatalog(f);
          modelAfterReconfigure = (await memoryStatus(f)).model;
        },
      },
    ]);
    const row = {
      reconfigured,
      commitIngestedBeforeReopen: catalogAfterReconfigure.some((record) => record.text.includes("bulk 199")),
      recordsAfterReconfigure: catalogAfterReconfigure.length,
      modelAfterReconfigure,
      toolAnswer: answers[0]!.details,
      ingestDiagnostics: f.memoryDiagnostics.filter((record) => record.event === "home.memory-ingest"),
      refusals: refusalsOf(f),
    };
    report.cases.push({ case: "race", ...row });
    expect(row.reconfigured).toBe("accepted");
    // The close waited for the ingest it closed over: the store it reopened holds
    // every record that commit owed, so no second opener was admitted over a store
    // that was still being written, and no record was written after the close.
    expect(row.commitIngestedBeforeReopen).toBe(true);
    expect(row.modelAfterReconfigure).toEqual(OTHER_MEMORY_MODEL);
    expect(row.toolAnswer).toEqual({ status: "ok" });
    expect(ok(answers[0]!)).toBe("0+0|user: race start");
    expect(row.ingestDiagnostics).toEqual([]);
    expect(row.refusals).toEqual([]);
  }, 180_000);
});
