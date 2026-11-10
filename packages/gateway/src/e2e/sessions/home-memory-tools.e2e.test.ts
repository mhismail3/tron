import { createTestRegistry, homeOwnerOf } from "../../../test-support/gateway-registry.js";
import { appendFile, mkdir, mkdtemp, readFile, rm, writeFile } from "node:fs/promises";
import { setHomeMemoryModels } from "../../../test-support/settings-dependencies.js";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { waitFor } from "../../../test-support/wait-for.js";
import { ModelRuntime, type AgentSession } from "@earendil-works/pi-coding-agent";
import { TronWorkspace } from "../../workspace/tron-workspace.js";
import {
  fauxAssistantMessage, fauxProvider, fauxText, fauxThinking, fauxToolCall,
  type AssistantMessage, type FauxProviderHandle, type Message, type ToolCall,
} from "@earendil-works/pi-ai";
import { afterAll, afterEach, describe, expect, it } from "vitest";
import { TrustService } from "../../kernel/resources/trust-service.js";
import { EPISODIC_DEFAULTS, type EpisodicMessageRecord, type EpisodicSummarizer } from "../../episodic/episodic-contract.js";
import { EpisodicStore } from "../../episodic/episodic-store.js";
import { HOME_MEMORY_VIEW_MARKER, type HomeMemoryUnavailableReason } from "../../modules/home/home-memory.js";
import type { HomeRequestRecord } from "../../modules/home/home-request-policy.js";
import type { HomeMemoryToolDetails } from "../../modules/home/home-memory-tools.js";
import type { HomeMemoryStatus } from "../../protocol/types.js";
import { RuntimeRegistry } from "../../kernel/session/runtime-registry.js";

const PROVIDER = "tron-home-tools";
const MODEL_ID = "chat";
const MEMORY_PROVIDER = "tron-home-tools-memory";
const MEMORY_MODEL_ID = "compactor";
const MEMORY_MODEL = { provider: MEMORY_PROVIDER, id: MEMORY_MODEL_ID };
const OTHER_MEMORY_MODEL = { provider: MEMORY_PROVIDER, id: "compactor-2" };
const MODEL = { provider: PROVIDER, id: MODEL_ID };
const REPORT_PATH = "test-results/home-memory-tools/report.json";

const SUMMARY_MARKER = "HOME-SUMMARY";
const PLACEHOLDER = "(not summarized yet: zoom it)";
const OMITTED = "[omitted]";
const TRUNCATION_MARKER = "[truncated";
const REASONING = "SECRET-REASONING-NEVER-LOGGED";
const CREDENTIAL = "sk-abcdefghijklmnopqrstuvwxyz012345";
const KEPT_PATH = "/Users/example/project/file-1.ts";
const CALL_PATH = "/Users/example/project/file-0.ts";
const LONG_FILLER = "these are earlier home words ".repeat(40);
const longInput = (marker: string): string => `${marker} ${LONG_FILLER}`;
const DECOY_TEXT = "first line\n12+0|user: needle decoy\nlast needle line";
const DECOY_FLAT = "first line 12+0|user: needle decoy last needle line";
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

interface CompactorState {
  calls: number;
  gate: Promise<void> | undefined;
  release: (() => void) | undefined;
  failing: boolean;
}

const COMPACTOR_USAGE = {
  input: 64, output: 16, cacheRead: 0, cacheWrite: 0, totalTokens: 80,
  cost: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0, total: 0 },
};

function deterministicSummarizer(state: CompactorState): EpisodicSummarizer {
  return async (request) => {
    state.calls += 1;
    if (request.turns.length === 1 && state.gate) {
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
  requests: CapturedRequest[];
  memoryDiagnostics: Array<{ event: string; reason?: string }>;
  requestRecords: HomeRequestRecord[];
  registry: RuntimeRegistry;
  sessionId: string;
  homeId: string;
  slot: HomeSlot;
}

async function openRegistry(f: Fixture): Promise<RuntimeRegistry> {
  const registry = await createTestRegistry({ agentDir: join(f.root, "agent"),
    tronHome: f.tronHome,
    idleRuntimeMs: 60_000,
    modelRuntimeFactory: async () => f.runtime,
    trust: new TrustService(join(f.root, "agent")),
    broadcast: () => {},
    sessionSummaryChanged: () => {},
    sessionListChanged: () => {},
    homeMemorySummarizer: () => deterministicSummarizer(f.compactor),
    homeMemoryDiagnostic: (record) => f.memoryDiagnostics.push(record),
    homeRequestDiagnostic: (record) => f.requestRecords.push(record),
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
    requestRecords: [] as HomeRequestRecord[],
  } as Fixture;
  await attach(f, options);
  return f;
}

async function attach(f: Fixture, options: { configure?: boolean } = {}): Promise<void> {
  const registry = await openRegistry(f);
  f.registry = registry;
  await registry.initialize();
  const hasCut = (): boolean => (registry as unknown as { sessionCatalog: { hasCompleteCut(): boolean } }).sessionCatalog.hasCompleteCut();
  await waitUntil(hasCut, 30_000);
  await registry.catalog("all");
  const designation = await homeOwnerOf(registry).designate({ model: MODEL }, () => MODEL);
  if (options.configure !== false) {
    await setHomeMemoryModels(registry, [MEMORY_MODEL]);
    await homeOwnerOf(registry).readMemoryView({ limit: 1 }).catch(() => undefined);
  }
  f.sessionId = designation.sessionId;
  f.homeId = designation.homeId;
  f.slot = await registry.acquire(designation.sessionId);
}

const sessionOf = (f: Fixture): AgentSession => (f.slot as unknown as { runtime: { session: AgentSession } }).runtime.session;
const managerOf = (f: Fixture) => sessionOf(f).sessionManager;

function waitUntil(predicate: () => boolean | Promise<boolean>, timeoutMs = 12_000): Promise<void> {
  return waitFor(async () => (await predicate()) || undefined, "Home memory tool condition", { boundMs: timeoutMs });
}

async function memoryStatus(f: Fixture): Promise<HomeMemoryStatus> {
  return await homeOwnerOf(f.registry).memoryStatus();
}

async function waitForBuiltTree(f: Fixture): Promise<void> {
  await waitUntil(async () => {
    const status = await memoryStatus(f);
    return status.open && (status.episodic?.view.unbuilt ?? 1) === 0;
  });
}

interface CapturedRequest {
  roles: string[];
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

function viewOf(request: CapturedRequest): string {
  const start = request.blob.indexOf(HOME_MEMORY_VIEW_MARKER);
  const end = request.blob.indexOf("</chat>", start);
  return start < 0 || end < 0 ? "" : request.blob.slice(start, end);
}

function systemOf(request: CapturedRequest): string {
  return JSON.stringify(messagesOf(request).filter((message) => message.role === "system"));
}

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

interface Step {
  name: string;
  args: ToolCall["arguments"];
  before?: () => void | Promise<void>;
}

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
  await waitUntil(() => f.requests.length >= before + steps.length + 1);
  await waitUntil(() => f.slot.snapshot().configurationBlocker === null);
  const activation = f.requests.slice(before);
  expect(activation.length, "one request per step, plus the closing reply").toBe(steps.length + 1);
  return activation.at(-1)!;
}

async function toolAnswers(f: Fixture, input: string, steps: Step[]): Promise<ToolObservation[]> {
  const answers = toolResultsOf(await runActivation(f, input, steps));
  expect(answers.length, "each scripted tool call must have executed").toBe(steps.length);
  return answers;
}

async function prompt(f: Fixture, input: string, reply: string): Promise<void> {
  f.faux.setResponses([async (context: { messages: Array<{ role: string }> }) => { f.requests.push(record(context)); return fauxAssistantMessage(reply); }]);
  await f.slot.prompt(input);
  await waitUntil(() => f.slot.snapshot().configurationBlocker === null);
}

const ok = (answer: ToolObservation): string => {
  expect(answer.details?.status, `${answer.toolName} must answer, not refuse: ${answer.text}`).toBe("ok");
  return answer.text;
};

const unavailable = (answer: ToolObservation, reason: HomeMemoryUnavailableReason): string => {
  expect(answer.isError).toBe(false);
  expect(answer.details).toEqual({ status: "unavailable", reason });
  return answer.text;
};

interface CanonicalEntry { id: string; timestamp: string; type: string; message?: Record<string, unknown> }

async function canonicalEntries(f: Fixture): Promise<CanonicalEntry[]> {
  const jsonl = f.slot.sessionFile ? await readFile(f.slot.sessionFile, "utf8").catch(() => "") : "";
  return jsonl.trimEnd().split("\n").filter((line) => line !== "").map((line) => JSON.parse(line) as CanonicalEntry);
}

async function entryForMessageText(f: Fixture, text: string): Promise<CanonicalEntry> {
  const entries = (await canonicalEntries(f)).filter((entry) => entry.type === "message");
  const found = entries.find((entry) => JSON.stringify(entry.message).includes(text));
  expect(found, `no canonical entry holds ${text}`).toBeDefined();
  return found!;
}

const userMessage = (text: string): Message => ({ role: "user", content: text, timestamp: Date.now() });

async function durableNodeText(f: Fixture, level: number, index: number): Promise<string | undefined> {
  const path = join(f.tronHome, "workspace", "state", "episodic", f.homeId, "nodes.jsonl");
  const lines = (await readFile(path, "utf8")).trimEnd().split("\n").filter((line) => line !== "");
  const records = lines.map((line) => JSON.parse(line) as Record<string, unknown>);
  const latest = records.filter((record) => record.level === level && record.index === index && typeof record.text === "string").at(-1);
  return typeof latest?.text === "string" ? latest.text : undefined;
}

function expectedDateText(entry: CanonicalEntry): string {
  const at = new Date(entry.timestamp);
  const pad = (part: number): string => String(part).padStart(2, "0");
  const offset = -at.getTimezoneOffset();
  const minutes = Math.abs(offset);
  return `${at.getFullYear()}-${pad(at.getMonth() + 1)}-${pad(at.getDate())}`
    + ` ${pad(at.getHours())}:${pad(at.getMinutes())}:${pad(at.getSeconds())}`
    + ` ${offset < 0 ? "-" : "+"}${pad(Math.floor(minutes / 60))}:${pad(minutes % 60)}`;
}

const refusalsOf = (f: Fixture) => f.requestRecords.flatMap(record => record.event === "refused" ? [record.reason] : []);

async function persistedCatalog(f: Fixture): Promise<EpisodicMessageRecord[]> {
  const workspace = (f.registry as unknown as { workspace: TronWorkspace }).workspace;
  const store = new EpisodicStore(workspace, f.homeId, EPISODIC_DEFAULTS.maxStoreLineBytes);
  return [...(await store.read()).messages.values()];
}

describe("Tron Home memory tools end to end", { concurrent: false }, () => {
  it("opens a line into its two children, gives a message whole, and refuses an address that is not a line", async () => {
    const f = await fixture("zoom");
    await prompt(f, "zoom-m0", "reply-r0");
    await prompt(f, "zoom-m2", "reply-r2");
    await prompt(f, "zoom-m4", "reply-r4");
    await waitUntil(async () => ((await memoryStatus(f)).episodic?.nodes.byLevel ?? []).some((entry) => entry.level >= 2));
    const firstActivationSystem = systemOf(f.requests[0]!);

    const answers = await toolAnswers(f, "tools", [
      { name: "zoom", args: { id: 0, n: 4 } },
      { name: "zoom", args: { id: 0, n: 2 } },
      { name: "zoom", args: { id: 2, n: 1 } },
      { name: "zoom", args: { id: 1, n: 2 } },
      { name: "zoom", args: { id: 0, n: 3 } },
      { name: "zoom", args: { id: 0, n: 1024 } },
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
      dateDetails: answers[11]!.details,
      expectedDateDetails: { status: "ok", date: { id: 2, at: new Date(entry.timestamp).toISOString() } },
      zoomDetails: answers[0]!.details,
      unknownDate: answers[12]!.text,
      viewFrozen: toolRequests.every((request) => viewOf(request) !== "" && viewOf(request) === viewOf(toolRequests[0]!)),
      viewLines: (viewOf(toolRequests[0]!).match(/\\n/gu) ?? []).length + 1,
      systemMessages: messagesOf(toolRequests[0]!).filter((message) => message.role === "system").length,
      systemCarriesToolList: systemOf(toolRequests[0]!).includes("memory_search"),
      systemCarriesOperatingContext: systemOf(toolRequests[0]!).includes("## Tron Home"),
      systemIdentical: toolRequests.every((request) => systemOf(request) === firstActivationSystem),
      preambleKinds: viewOf(toolRequests[0]!).includes("talk (your replies and tool calls)"),
      preambleNavigation: viewOf(toolRequests[0]!).includes("zoom(id, n) opens line id+n"),
      refusals: refusalsOf(f),
      toolResultMessages: (f.requests.at(-1)?.roles ?? []).filter((role) => role === "toolResult").length,
    };
    report.cases.push({ case: "zoom", ...row });
    expect(row.children).toBe("0+2|summary: user: zoom-m0 talk: reply-r0\n2+2|summary: user: zoom-m2 talk: reply-r2");
    expect(row.halves).toBe("0+1|user: zoom-m0\n1+1|talk: reply-r0");
    expect(row.message).toBe("2+0|user: zoom-m2");
    expect(row.misaligned).toBe("No line 1+2.");
    expect(row.notPowerOfTwo).toBe("No line 0+3.");
    expect(row.pastTheEnd).toBe("No line 0+1024.");
    expect(row.date).toBe(row.expectedDate);
    expect(row.dateDetails).toEqual(row.expectedDateDetails);
    expect(row.zoomDetails).toEqual({ status: "ok" });
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
    expect(row.refusals).toEqual([]);
    expect(row.toolResultMessages).toBe(13);
  }, 120_000);

  it("gives a message's projected text: no reasoning, credentials redacted, paths kept, bounded", async () => {
    const f = await fixture("projected");
    await prompt(f, "start", "a reply");
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
        before: () => { managerOf(f).appendContextEdit(target.id, { content: REPLACEMENT }); },
      },
      { name: "zoom", args: { id: 0, n: 1 } },
    ]);
    const revoked = ok(answers[0]!).split("\n");
    const row = {
      revokedLine: revoked[0],
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
    expect(row.parkedCalls).toBeGreaterThan(0);
    expect(row.blocked).toBeNull();

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
    expect(row.search).toBe('memory_search "keep two" in messages [0, 4): 0 match(es), 0 shown, 2 [omitted], 0 capped.');
  }, 120_000);

  it("reports search hits, its bounds, and what the range could not search", async () => {
    const f = await fixture("search");
    await prompt(f, "alpha needle one", "bravo");
    const manager = managerOf(f);
    manager.appendMessage(userMessage("charlie needle two"));
    manager.appendMessage(fauxAssistantMessage([fauxToolCall("display", { document: "d".repeat(31_000) })]));
    manager.appendMessage(userMessage("echo needle three"));
    manager.appendMessage(userMessage(`longneedle ${"L".repeat(400)}`));
    manager.appendMessage(userMessage(DECOY_TEXT));
    const bulk = Array.from({ length: 21 }, (_unused, index) => manager.appendMessage(userMessage(`bulkbatch ${index}`)));
    manager.appendMessage(userMessage("to be dropped"));
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
      longSnippetBounded: hits.some((line) => line.startsWith("5+0|user: longneedle") && line.length - "5+0|user: ".length <= 300),
      emptyOutcome: empty.details,
      emptyText: empty.text,
      oversizedOutcome: oversized.details,
      oversizedText: oversized.text,
      needleDetails: answers[0]!.details,
      bulkDetails: answers[2]!.details,
    };
    report.cases.push({ case: "search", ...row });
    expect(row.header).toBe('memory_search "needle" in messages [0, 7): 5 match(es), 5 shown, 0 [omitted], 1 capped.');
    expect(row.upperCaseHeader).toBe('memory_search "NEEDLE" in messages [0, 7): 5 match(es), 5 shown, 0 [omitted], 1 capped.');
    expect(row.hitLines.map((line) => line.split("|")[0])).toEqual(["0+0", "2+0", "4+0", "5+0", "6+0"]);
    expect(row.resultLines).toBe(6);
    expect(row.decoyLine).toBe(`6+0|user: ${DECOY_FLAT}`);
    expect(row.decoyLine ?? "").not.toContain("\n");
    expect(row.longSnippetBounded).toBe(true);
    expect(row.bulkHeader).toBe('memory_search "bulkbatch" in messages [0, 32): 21 match(es), 20 shown, 3 [omitted], 1 capped.');
    expect(row.bulkShown).toBe(20);
    expect(row.omittedHeader).toBe('memory_search "omitted" in messages [0, 32): 0 match(es), 0 shown, 3 [omitted], 1 capped.');
    expect(row.omittedHits).toEqual([]);
    expect(row.needleDetails).toEqual({ status: "ok", search: { query: "needle", from: 0, to: 7, matches: 5, shown: 5, omitted: 0, capped: 1 } });
    expect(row.bulkDetails).toEqual({ status: "ok", search: { query: "bulkbatch", from: 0, to: 32, matches: 21, shown: 20, omitted: 3, capped: 1 } });
    expect(row.emptyOutcome).toEqual({ status: "invalid-arguments" });
    expect(row.emptyText).toBe("memory_search needs a query of 1 to 200 characters.");
    expect(row.oversizedOutcome).toEqual({ status: "invalid-arguments" });
    expect(row.oversizedText).toBe(row.emptyText);
  }, 120_000);

  it("refuses a new activation when the memory has stopped", async () => {
    const f = await fixture("blocked");
    await prompt(f, longInput("blocked first"), "reply-r0");
    await waitForBuiltTree(f);
    f.compactor.failing = true;
    const first = await entryForMessageText(f, longInput("blocked first"));
    managerOf(f).appendContextEdit(first.id, { content: longInput("changed blocked first") });
    homeOwnerOf(f.registry).noteEntriesCommitted(f.sessionId);
    await waitUntil(async () => (await memoryStatus(f)).blocked === "permanent-failure");
    const requestsBefore = f.requests.length;
    await f.slot.prompt(longInput("blocked second"));
    await waitUntil(() => refusalsOf(f).includes("memory-blocked"));
    const row = { blocked: (await memoryStatus(f)).blocked ?? null, providerRequests: f.requests.length - requestsBefore };
    report.cases.push({ case: "blocked", ...row });
    expect(row.blocked).toBe("permanent-failure");
    expect(row.providerRequests).toBe(0);
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

  async function navigatedHome(label: string): Promise<Fixture> {
    const f = await fixture(label);
    await prompt(f, "first text", "reply-r0");
    managerOf(f).appendMessage(userMessage("no date on this record"));
    await prompt(f, "ingest them", "reply-r1");
    await waitUntil(async () => ((await memoryStatus(f)).episodic?.messages ?? 0) === 5);
    const firstMessage = await entryForMessageText(f, "first text");
    managerOf(f).branch(firstMessage.id);
    return f;
  }

  async function rewriteCatalog(f: Fixture, rewrite: (record: Record<string, unknown>) => void): Promise<void> {
    await f.registry.dispose();
    registries.splice(registries.indexOf(f.registry), 1);
    const workspace = new TronWorkspace(f.tronHome);
    await workspace.initialize();
    try {
      const store = new EpisodicStore(workspace, f.homeId, EPISODIC_DEFAULTS.maxStoreLineBytes);
      const snapshot = await store.read();
      if (!snapshot.state) throw new Error("Catalog fixture has no persisted store state");
      const messages = [...snapshot.messages.values()].map((record) => {
        const rewritten: Record<string, unknown> = { ...record };
        rewrite(rewritten);
        return rewritten as unknown as EpisodicMessageRecord;
      });
      await store.checkpoint({ messages, nodes: snapshot.nodes.values(), state: snapshot.state, watermark: snapshot.highestRevision });
    } finally { await workspace.dispose(); }
  }

  it("refuses a Home catalog missing instants rather than inventing a date", async () => {
    const f = await navigatedHome("missing-instants");
    await rewriteCatalog(f, (record) => { delete record.timestamp; });
    await attach(f, { configure: false });
    await setHomeMemoryModels(f.registry, [MEMORY_MODEL]);
    await expect(homeOwnerOf(f.registry).readMemoryView({ limit: 1 })).rejects.toThrow(/unavailable/);
    const status = await memoryStatus(f);
    const access = homeOwnerOf(f.registry).memoryToolsFor(f.sessionId)!;
    const answers = [await access.zoom(0, 1), await access.date(0), await access.date(2)];
    report.cases.push({ case: "home-missing-instants", open: status.open, answers, refusals: refusalsOf(f) });
    expect(status.open).toBe(false);
    for (const answer of answers) {
      expect(answer.outcome).toBe("unavailable");
      expect(answer.outcome === "unavailable" ? answer.reason : undefined).toBe("memory-unavailable");
    }
  }, 180_000);

  it("answers timestamp-unavailable for an instant it cannot read, and keeps the memory open", async () => {
    const f = await navigatedHome("unreadable-instant");
    await rewriteCatalog(f, (record) => { record.timestamp = "not a date"; });
    await attach(f);
    const status = await memoryStatus(f);
    const access = homeOwnerOf(f.registry).memoryToolsFor(f.sessionId)!;
    const answers = [await access.zoom(0, 1), await access.date(0), await access.date(2)];
    report.cases.push({ case: "home-unreadable-instants", open: status.open, answers });
    expect(status.open).toBe(true);
    expect(answers[0]).toMatchObject({ outcome: "ok", text: "0+0|user: first text" });
    for (const answer of answers.slice(1)) expect(answer).toMatchObject({ outcome: "unavailable", reason: "timestamp-unavailable" });
  }, 180_000);

  it("never reaches a memory for a session that is not the enabled Home", async () => {
    const f = await fixture("foreign");
    const owner = homeOwnerOf(f.registry);
    const home = owner.memoryToolsFor(f.sessionId);
    report.cases.push({ case: "foreign", foreign: owner.memoryToolsFor("some-other-session") ?? null, home: home ? "accessor" : null });
    expect(owner.memoryToolsFor("some-other-session")).toBeUndefined();
    expect(home).toBeDefined();
    expect(home!.zoom).toBeTypeOf("function");
  }, 60_000);

  it("answers memory-not-configured through the owner for a designated but unconfigured Home", async () => {
    const f = await fixture("unconfigured", { configure: false });
    const status = await memoryStatus(f);
    const access = homeOwnerOf(f.registry).memoryToolsFor(f.sessionId)!;
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
    const oversized = `{"type":"message","id":"oversized-entry","parentId":${JSON.stringify(managerOf(f).getLeafId())},"timestamp":${JSON.stringify(new Date().toISOString())},"message":{"role":"user","content":"${"x".repeat(EPISODIC_DEFAULTS.maxSourceLineBytes + 1)}","timestamp":${Date.now()}}}`;

    f.faux.setResponses([
      async (context: { messages: Array<{ role: string }> }) => {
        f.requests.push(record(context));
        await appendFile(sessionFile, `${oversized}\n`);
        return fauxAssistantMessage([
          fauxToolCall("zoom", { id: 0, n: 1 }),
          fauxToolCall("date", { id: 0 }),
          fauxToolCall("memory_search", { query: "blocked", to: 2 }),
        ]);
      },
      async (context: { messages: Array<{ role: string }> }) => { f.requests.push(record(context)); return fauxAssistantMessage("done"); },
    ]);
    await f.slot.prompt("tools");
    await waitUntil(() => f.slot.snapshot().configurationBlocker === null);
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
          for (let index = 0; index < 200; index += 1) managerOf(f).appendMessage(userMessage(`bulk ${index}`));
          homeOwnerOf(f.registry).noteEntriesCommitted(f.sessionId);
          reconfigured = await setHomeMemoryModels(f.registry, [OTHER_MEMORY_MODEL])
            .then(() => homeOwnerOf(f.registry).readMemoryView({ limit: 1 }))
            .then(() => "accepted", (error: unknown) => (error as { code?: string }).code ?? "failed");
          catalogAfterReconfigure = await persistedCatalog(f);
          modelAfterReconfigure = (await memoryStatus(f)).models;
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
    expect(row.commitIngestedBeforeReopen).toBe(true);
    expect(row.modelAfterReconfigure).toEqual([`${OTHER_MEMORY_MODEL.provider}/${OTHER_MEMORY_MODEL.id}`]);
    expect(row.toolAnswer).toEqual({ status: "ok" });
    expect(ok(answers[0]!)).toBe("0+0|user: race start");
    expect(row.ingestDiagnostics).toEqual([]);
    expect(row.refusals).toEqual([]);
  }, 180_000);
});
