/**
 * Tron Home's request seam inside the real Gateway runtime (`RuntimeRegistry` +
 * `RuntimeSlot`), with the pinned Pi SDK, a faux provider and the real episodic
 * memory behind a deterministic faux compactor.
 *
 * This file is ALSO the pinned-SDK seam regression test. It pins the SDK
 * behaviour the seam depends on and that a reader cannot see from Tron's own
 * source:
 *
 *  - `AgentSession` installs its own `prepareRequest` projection wrapper and
 *    `transformContext` stages that run AFTER the outermost `prepareRequest`,
 *    so a digest taken at `prepareRequest` time can never match the provider
 *    request (hence the expectation is recorded in the outermost
 *    `transformContext` wrapper);
 *  - the SDK's context stage `structuredClone`s every message, so object
 *    identity is never preserved and the mutation check must compare values;
 *  - `agent.streamFunction` is the only provider-facing seam, and it is wrapped
 *    outermost by a compaction policy, so the Home guard must be innermost;
 *  - `session.prompt` appends the input's canonical entry after admission, and
 *    steering inserts entries after it, which is what makes the activation's
 *    captured leaf an exact boundary.
 *
 * Every case writes a row into `test-results/home-activation/seam-report.json`
 * and prints a one-line summary.
 *
 * Failure modes these cases exist for (written down before the code, in
 * progress.md): F1 a prior activation leaks into a request, F2 the memory view is
 * persisted, F3 the cut is taken at the last user message and loses the tool
 * loop, F4 a queued follow-up is dropped or split off, F5 an SDK retry re-expands
 * the request, F6 SDK compaction re-sends canonical history, F7 a policy refusal
 * is retried by SDK auto-retry, F8 a post-`prepareRequest` mutation reaches the
 * provider, F9 an un-admitted run is served, F10 an ordinary session is affected,
 * F11 an oversized activation reaches the provider, F12 a reload drops the
 * wrappers, F13 a settled run leaves its activation open, F14 a broken memory
 * serves a request, F15 an unbuilt line is sent instead of waiting, F16 the view
 * changes between two steps of one activation, F17 a designation in flight has no
 * seam on its first runtime, F18 an ordinary session's requests change when a
 * Home is designated.
 */
import { mkdir, mkdtemp, readFile, rm, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import {
  convertToLlm, ModelRuntime, type AgentSession,
} from "@earendil-works/pi-coding-agent";
import type { AgentMessage, StreamFn } from "@earendil-works/pi-agent-core";
import { fauxAssistantMessage, fauxProvider, fauxToolCall } from "@earendil-works/pi-ai";
import { afterAll, afterEach, describe, expect, it } from "vitest";
import { TrustService } from "../admin/trust-service.js";
import type { SessionSnapshot } from "../protocol/types.js";
import type { EpisodicSummarizer } from "../episodic/episodic-contract.js";
import { HOME_MEMORY_VIEW_MARKER } from "../home/home-memory.js";
import { HOME_NONCE_MARKER, HomeRequestPolicy, type HomeRefusalReason } from "../home/home-request-policy.js";
import { RuntimeRegistry } from "./runtime-registry.js";

const PROVIDER = "tron-home-seam";
const MODEL_ID = "fixture";
const MEMORY_MODEL = { provider: "tron-home-memory", id: "compactor" };
/** The deterministic compactor's line marker: its presence in a request means the
 * frozen memory view is there, and it never echoes the message it summarizes. */
const SUMMARY_MARKER = "HOME-SUMMARY";
/** Long enough that a level-0 node needs a compactor call rather than becoming a
 * verbatim free node, so a summarized message's own text is absent from the view. */
const FILLER = "these are earlier home words ".repeat(40);
const REPORT_PATH = "test-results/home-activation/seam-report.json";
const cases: Array<Record<string, unknown>> = [];

const longInput = (marker: string): string => `${marker} ${FILLER}`;

interface CapturedRequest {
  roles: string[];
  blob: string;
}

async function waitUntil(predicate: () => boolean, timeoutMs = 10_000): Promise<void> {
  const deadline = performance.now() + timeoutMs;
  while (!predicate()) {
    if (performance.now() >= deadline) throw new Error("condition timed out");
    await new Promise((resolve) => setTimeout(resolve, 5));
  }
}

/** Records a provider request. Timestamps are zeroed so two runs of the same
 * input are byte-comparable. */
function record(context: { messages: Array<{ role: string }> }): CapturedRequest {
  return {
    roles: context.messages.map((message) => message.role),
    blob: JSON.stringify(context.messages, (key, value) => key === "timestamp" ? 0 : value),
  };
}

/** The frozen memory view one provider request carried, without its per-activation
 * nonce, so two steps of one activation can be compared byte-for-byte. */
function viewOf(request: CapturedRequest): string {
  const start = request.blob.indexOf(HOME_MEMORY_VIEW_MARKER);
  const end = request.blob.indexOf("</chat>", start);
  return start < 0 || end < 0 ? "" : request.blob.slice(start, end);
}

interface CompactorState {
  calls: number;
  entered: number;
  /** Set while the compactor parks every first attempt, so a case can observe a
   * readiness wait instead of guessing at one. */
  gate: Promise<void> | undefined;
  release: (() => void) | undefined;
}

/** A deterministic compactor: a short, bounded line that never echoes its input,
 * so a summarized message's text cannot reappear in the view. */
function deterministicSummarizer(state: CompactorState): EpisodicSummarizer {
  return async (request) => {
    state.calls += 1;
    state.entered += 1;
    const text = request.turns.map((turn) => turn.text).join("\n");
    if (request.turns.length === 1 && state.gate) await state.gate;
    if (text.includes("must end where it is cut here")) return fauxAssistantMessage(`${SUMMARY_MARKER} ${state.calls} shortened`);
    return fauxAssistantMessage(`${SUMMARY_MARKER} ${state.calls} ${"s".repeat(64)}`);
  };
}

interface FixtureOptions {
  /** Designate Tron Home through its owner before the cases prompt. */
  home?: boolean;
  /** Configure Home's memory (only with `home`). */
  memory?: boolean;
  tokenBudget?: number;
  /** What the Gateway's model resolver says about the memory's model. */
  memoryModel?: "available" | "virtual-model" | "unavailable";
  summarizer?: EpisodicSummarizer;
  settings?: Record<string, unknown>;
  retryBaseDelayMs?: number;
  contextWindow?: number;
  /** Park the compactor until the case releases it. */
  heldSummarizer?: boolean;
}

interface CapturedDiagnostic {
  sessionId?: string;
  reason?: string;
  outcome?: string;
}

async function homeFixture(label: string, options: FixtureOptions = {}) {
  const root = await mkdtemp(join(tmpdir(), `tron-home-seam-${label}-`));
  const agentDir = join(root, "agent");
  const cwd = join(root, "project");
  const tronHome = join(root, "tron");
  await Promise.all([mkdir(agentDir), mkdir(cwd)]);
  await writeFile(join(cwd, "note.txt"), "note contents\n");
  await writeFile(join(agentDir, "settings.json"), JSON.stringify({
    defaultProvider: PROVIDER,
    defaultModel: MODEL_ID,
    compaction: { enabled: false, reserveTokens: 120_000, keepRecentTokens: 13_000 },
    ...(options.retryBaseDelayMs === undefined ? {} : { retry: { enabled: true, maxRetries: 3, baseDelayMs: options.retryBaseDelayMs } }),
    ...(options.settings ?? {}),
  }));
  const compactor: CompactorState = { calls: 0, entered: 0, gate: undefined, release: undefined };
  if (options.heldSummarizer) {
    compactor.gate = new Promise<void>((resolve) => { compactor.release = resolve; });
  }
  const summarizer = options.summarizer ?? deterministicSummarizer(compactor);
  const faux = fauxProvider({
    provider: PROVIDER,
    models: [{ id: MODEL_ID, reasoning: true, ...(options.contextWindow === undefined ? {} : { contextWindow: options.contextWindow }) }],
    tokensPerSecond: 1_000_000,
    tokenSize: { min: 10, max: 10 },
  });
  const runtime = await ModelRuntime.create({ authPath: join(root, "auth.json"), modelsPath: null, refreshOnCreate: false });
  runtime.registerNativeProvider(faux.provider);
  const trust = new TrustService(agentDir);
  await trust.set(cwd, true);
  const diagnostics: CapturedDiagnostic[] = [];
  const snapshots: SessionSnapshot[] = [];
  const registry = new RuntimeRegistry({
    agentDir,
    tronHome,
    idleRuntimeMs: 60_000,
    modelRuntimeFactory: async () => runtime,
    trust,
    broadcast: (_sessionId, topic, value) => {
      if (topic === "session.snapshot") snapshots.push(value as unknown as SessionSnapshot);
    },
    sessionSummaryChanged: () => {},
    sessionListChanged: () => {},
    compactionDiagnostic: (diagnostic) => diagnostics.push(diagnostic as unknown as CapturedDiagnostic),
    // The compactor model is resolved the way Knowledge resolves its own: from
    // the Gateway's ModelRuntime. These cases inject a deterministic summarizer
    // so no provider call is ever made for the memory.
    homeMemorySummarizer: () => options.memoryModel === undefined || options.memoryModel === "available"
      ? { summarizer }
      : { refusal: options.memoryModel },
  });
  await registry.initialize();
  const modelRef = { provider: PROVIDER, id: MODEL_ID };
  let homeSessionId: string | undefined;
  if (options.home) {
    homeSessionId = (await registry.homeOwner().designate({ model: modelRef }, () => modelRef)).sessionId;
    if (options.memory) {
      await registry.homeOwner().configureMemory({ model: MEMORY_MODEL, tokenBudget: options.tokenBudget ?? 1_000_000 });
    }
  }
  const slot = homeSessionId ? await registry.acquire(homeSessionId) : await registry.create(cwd);
  if (!homeSessionId) await slot.setModel(PROVIDER, MODEL_ID);
  const session = (slot as unknown as { runtime: { session: AgentSession } }).runtime.session;
  const requests: CapturedRequest[] = [];
  const response = (blob: string) => async (context: { messages: Array<{ role: string }> }) => {
    requests.push(record(context));
    return fauxAssistantMessage(blob);
  };
  return {
    root, agentDir, cwd, tronHome, registry, slot, session, faux, requests, snapshots, diagnostics, compactor,
    homeSessionId,
    policy: () => homeSessionId === undefined ? undefined : registry.homeOwner().requestPolicyFor(homeSessionId),
    memoryStatus: () => registry.homeOwner().memoryStatus(),
    response,
    /** One more session in this registry, in its own directory under the
     * fixture, or in an existing one (`cwd`) so two sessions can share a working
     * directory and therefore a system prompt. */
    extra: async (name: string, cwd?: string) => {
      const extraCwd = cwd ?? join(root, name);
      await mkdir(extraCwd, { recursive: true });
      const extra = await registry.create(extraCwd);
      await extra.setModel(PROVIDER, MODEL_ID);
      return {
        slot: extra,
        entries: async () => readEntries(extra.sessionFile),
      };
    },
    entries: async () => readEntries(slot.sessionFile),
    jsonl: async () => (slot.sessionFile ? await readFile(slot.sessionFile, "utf8") : ""),
    record: (name: string, row: Record<string, unknown>) => { cases.push({ case: name, ...row }); },
    dispose: async () => { await registry.dispose(); await rm(root, { recursive: true, force: true }); },
  };
}

async function readEntries(path: string | undefined): Promise<Array<Record<string, never>>> {
  if (!path) return [];
  return (await readFile(path, "utf8")).trimEnd().split("\n").filter((line) => line !== "").map((line) => JSON.parse(line) as Record<string, never>);
}

const disposals: Array<() => Promise<void>> = [];
const fixtures: Array<Awaited<ReturnType<typeof homeFixture>>> = [];

afterEach(async () => {
  for (const dispose of disposals.splice(0).reverse()) await dispose();
});

afterAll(async () => {
  await mkdir(join(process.cwd(), "test-results", "home-activation"), { recursive: true });
  await writeFile(join(process.cwd(), REPORT_PATH), `${JSON.stringify({ generatedAt: new Date().toISOString(), cases }, null, 2)}\n`);
  process.stdout.write(`home-activation seam: ${cases.length} cases -> ${REPORT_PATH}\n`);
});

async function open(label: string, options: FixtureOptions = {}) {
  const item = await homeFixture(label, options);
  disposals.push(item.dispose);
  fixtures.push(item);
  return item;
}

/** Rationale for the case names: the prototype's numbering (#412) is kept, so
 * this file's rows line up with the qualification evidence it ports. */
describe.sequential("Home request seam inside the Gateway runtime", () => {
  it("C1 control: an ordinary session re-sends canonical history", async () => {
    const item = await open("c1");
    item.faux.setResponses([item.response("first activation response"), item.response("second activation response")]);
    await item.slot.prompt("C1 first activation input");
    await waitUntil(() => !item.slot.isBusy);
    await item.slot.prompt("C1 second activation input");
    await waitUntil(() => !item.slot.isBusy);
    const row = {
      providerRequests: item.requests.length,
      roleSequences: item.requests.map((request) => request.roles),
      secondIncludesPriorActivation: item.requests[1]!.blob.includes("C1 first activation input"),
      policyInstalled: item.policy() !== undefined,
    };
    item.record("C1", row);
    expect(row.providerRequests).toBe(2);
    expect(row.roleSequences).toEqual([["system", "user"], ["system", "user", "assistant", "user"]]);
    expect(row.secondIncludesPriorActivation).toBe(true);
    expect(row.policyInstalled).toBe(false);
  }, 30_000);

  it("C2 exclusion, frozen view, tool loop, persistence and fork", async () => {
    const item = await open("c2", { home: true, memory: true });
    item.faux.setResponses([item.response("prior activation response")]);
    await item.slot.prompt(longInput("C2 first activation input"));
    await waitUntil(() => !item.slot.isBusy);
    item.faux.setResponses([
      async (context) => { item.requests.push(record(context)); return fauxAssistantMessage(fauxToolCall("read", { path: "note.txt" })); },
      async (context) => { item.requests.push(record(context)); return fauxAssistantMessage("after the tool"); },
    ]);
    await item.slot.prompt(longInput("C2 second activation input"));
    await waitUntil(() => !item.slot.isBusy);
    const transformObservations = item.policy()?.transformLog() ?? [];
    const activationRequest = item.requests[1]!;
    const toolStepRequest = item.requests[2]!;
    const jsonl = await item.jsonl();
    const entries = await item.entries();
    const memoryStatus = item.memoryStatus();
    const leafBeforeFork = item.session.sessionManager.getLeafId()!;
    const fork = await item.slot.fork(leafBeforeFork);
    const forkedSession = (item.slot as unknown as { runtime: { session: AgentSession } }).runtime.session;
    const forkBlob = JSON.stringify(forkedSession.sessionManager.buildSessionProjection().messages);
    const row = {
      providerRequests: item.requests.length,
      roleSequences: item.requests.map((request) => request.roles),
      activationExcludesPriorText: !activationRequest.blob.includes("C2 first activation input"),
      activationContainsOwnInput: activationRequest.blob.includes("C2 second activation input"),
      activationContainsMemory: activationRequest.blob.includes(HOME_MEMORY_VIEW_MARKER),
      activationContainsSummary: activationRequest.blob.includes(SUMMARY_MARKER),
      toolStepContainsToolCall: toolStepRequest.blob.includes("\"toolCall\""),
      toolStepContainsToolResult: toolStepRequest.roles.includes("toolResult"),
      viewFrozenAcrossSteps: viewOf(activationRequest) !== "" && viewOf(activationRequest) === viewOf(toolStepRequest),
      nonceAbsentFromJsonl: !jsonl.includes(HOME_NONCE_MARKER),
      viewAbsentFromJsonl: !jsonl.includes(HOME_MEMORY_VIEW_MARKER) && !jsonl.includes(SUMMARY_MARKER),
      forkProfile: item.registry.homeOwner().profileFor(fork.sessionId),
      forkExcludesView: !forkBlob.includes(HOME_MEMORY_VIEW_MARKER),
      forkHasNoSeam: item.registry.homeOwner().requestPolicyFor(fork.sessionId) === undefined,
      canonicalEntryCount: entries.length,
      memory: { configured: memoryStatus.configured, open: memoryStatus.open, messages: memoryStatus.episodic?.messages ?? 0, blocked: memoryStatus.blocked ?? null },
      transformObservations,
    };
    item.record("C2", row);
    expect(row.activationExcludesPriorText).toBe(true);
    expect(row.activationContainsOwnInput).toBe(true);
    expect(row.activationContainsMemory).toBe(true);
    expect(row.activationContainsSummary).toBe(true);
    expect(row.toolStepContainsToolCall).toBe(true);
    expect(row.toolStepContainsToolResult).toBe(true);
    expect(row.viewFrozenAcrossSteps).toBe(true);
    expect(row.nonceAbsentFromJsonl).toBe(true);
    expect(row.viewAbsentFromJsonl).toBe(true);
    expect(row.forkProfile).not.toBe("home");
    expect(row.forkExcludesView).toBe(true);
    expect(row.forkHasNoSeam).toBe(true);
    // The memory covers the whole first activation by the time the second one runs.
    expect(row.memory.messages).toBeGreaterThanOrEqual(2);
  }, 30_000);

  it("C3 steering during the activation keeps the earlier tool exchange", async () => {
    const item = await open("c3", { home: true, memory: true });
    item.faux.setResponses([item.response("prior activation response")]);
    await item.slot.prompt(longInput("C3 first activation input"));
    await waitUntil(() => !item.slot.isBusy);
    let release!: () => void;
    const gate = new Promise<void>((resolve) => { release = resolve; });
    let entered = false;
    item.faux.setResponses([
      async (context) => {
        item.requests.push(record(context));
        entered = true;
        await gate;
        return fauxAssistantMessage(fauxToolCall("read", { path: "note.txt" }));
      },
      async (context) => { item.requests.push(record(context)); return fauxAssistantMessage("after steering"); },
    ]);
    const prompting = item.slot.prompt(longInput("C3 second activation input"));
    await waitUntil(() => entered);
    await item.slot.prompt("C3 steering text", [], "steer");
    release();
    await prompting;
    await waitUntil(() => !item.slot.isBusy);
    const finalRequest = item.requests.at(-1)!;
    const row = {
      providerRequests: item.requests.length,
      roleSequences: item.requests.map((request) => request.roles),
      steeringIncluded: finalRequest.blob.includes("C3 steering text"),
      earlierToolExchangePresent: finalRequest.roles.includes("toolResult") && finalRequest.blob.includes("\"toolCall\""),
      activationInputStillPresent: finalRequest.blob.includes("C3 second activation input"),
      previousActivationExcluded: !finalRequest.blob.includes("C3 first activation input"),
    };
    item.record("C3", row);
    expect(row.steeringIncluded).toBe(true);
    expect(row.earlierToolExchangePresent).toBe(true);
    expect(row.activationInputStillPresent).toBe(true);
    expect(row.previousActivationExcluded).toBe(true);
  }, 30_000);

  it("C4 a follow-up queued during the run joins the same activation", async () => {
    const item = await open("c4", { home: true, memory: true });
    item.faux.setResponses([item.response("prior activation response")]);
    await item.slot.prompt(longInput("C4 first activation input"));
    await waitUntil(() => !item.slot.isBusy);
    let release!: () => void;
    const gate = new Promise<void>((resolve) => { release = resolve; });
    let entered = false;
    item.faux.setResponses([
      async (context) => {
        item.requests.push(record(context));
        entered = true;
        await gate;
        return fauxAssistantMessage(fauxToolCall("read", { path: "note.txt" }));
      },
      async (context) => { item.requests.push(record(context)); return fauxAssistantMessage("after the tool, before the follow-up"); },
      async (context) => { item.requests.push(record(context)); return fauxAssistantMessage("answered the follow-up"); },
      async (context) => { item.requests.push(record(context)); return fauxAssistantMessage("extra"); },
    ]);
    const prompting = item.slot.prompt(longInput("C4 second activation input"));
    await waitUntil(() => entered);
    await item.slot.prompt("C4 follow-up text", [], "followUp");
    release();
    await prompting;
    await waitUntil(() => !item.slot.isBusy);
    const finalRequest = item.requests.at(-1)!;
    const row = {
      providerRequests: item.requests.length,
      roleSequences: item.requests.map((request) => request.roles),
      followUpIncluded: finalRequest.blob.includes("C4 follow-up text"),
      activationInputPresent: finalRequest.blob.includes("C4 second activation input"),
      previousActivationExcluded: !finalRequest.blob.includes("C4 first activation input"),
    };
    item.record("C4", row);
    expect(row.followUpIncluded).toBe(true);
    expect(row.activationInputPresent).toBe(true);
    expect(row.previousActivationExcluded).toBe(true);
  }, 30_000);

  it("C14 ownership transfer closes the activation before the slot goes idle", async () => {
    const item = await open("c14", { home: true, memory: true });
    item.faux.setResponses([item.response("prior activation response")]);
    await item.slot.prompt(longInput("C14 first activation input"));
    await waitUntil(() => !item.slot.isBusy);
    let release!: () => void;
    const gate = new Promise<void>((resolve) => { release = resolve; });
    let entered = false;
    item.faux.setResponses([
      async (context) => {
        item.requests.push(record(context));
        entered = true;
        await gate;
        return fauxAssistantMessage(fauxToolCall("read", { path: "note.txt" }));
      },
      async (context) => { item.requests.push(record(context)); return fauxAssistantMessage("after the tool, before the follow-up"); },
      async (context) => { item.requests.push(record(context)); return fauxAssistantMessage("answered the follow-up"); },
      async (context) => { item.requests.push(record(context)); return fauxAssistantMessage("extra"); },
    ]);
    const prompting = item.slot.prompt(longInput("C14 second activation input"));
    await waitUntil(() => entered);
    await item.slot.prompt("C14 follow-up text", [], "followUp");
    release();
    await prompting;
    await waitUntil(() => !item.slot.isBusy);
    const policy = item.policy()!;
    const openAfterFollowUp = policy.currentOperationId() ?? null;
    const idleAfterFollowUp = item.slot.snapshot().phase === "idle";
    const callsBefore = item.faux.state.callCount;
    // The un-admitted run: the SDK path an extension uses, never Tron's admission.
    await item.session.sendCustomMessage(
      { customType: "idle-turn", content: "idle extension turn", display: false },
      { triggerTurn: true },
    ).catch(() => undefined);
    await waitUntil(() => !item.slot.isBusy);
    const row = {
      openActivationAfterFollowUp: openAfterFollowUp,
      idleAfterFollowUp,
      providerRequestsAfterUnadmittedTurn: item.faux.state.callCount - callsBefore,
      refusalReasons: policy.refusalLog().map((entry) => entry.reason),
      lastRefusal: policy.refusalLog().at(-1)?.reason ?? null,
      slotPhase: item.slot.snapshot().phase,
    };
    item.record("C14", row);
    expect(row.idleAfterFollowUp).toBe(true);
    expect(row.openActivationAfterFollowUp).toBeNull();
    expect(row.providerRequestsAfterUnadmittedTurn).toBe(0);
    expect(row.lastRefusal).toBe("no-activation");
  }, 30_000);

  it("C5 SDK auto-retry keeps the activation cut", async () => {
    const item = await open("c5", { home: true, memory: true, retryBaseDelayMs: 1 });
    item.faux.setResponses([item.response("prior activation response")]);
    await item.slot.prompt(longInput("C5 first activation input"));
    await waitUntil(() => !item.slot.isBusy);
    item.faux.setResponses([
      async (context) => { item.requests.push(record(context)); return fauxAssistantMessage("", { stopReason: "error", errorMessage: "503 service unavailable" }); },
      async (context) => { item.requests.push(record(context)); return fauxAssistantMessage("recovered after retry"); },
    ]);
    await item.slot.prompt(longInput("C5 second activation input"));
    await waitUntil(() => !item.slot.isBusy);
    const last = item.requests.at(-1)!;
    const row = {
      providerRequests: item.requests.length,
      roleSequences: item.requests.map((request) => request.roles),
      retriedRequestContainsActivation: last.blob.includes("C5 second activation input"),
      retriedRequestExcludesPrior: !last.blob.includes("C5 first activation input"),
      retriedRequestContainsMemory: last.blob.includes(SUMMARY_MARKER),
      viewFrozenAcrossRetry: viewOf(item.requests[1]!) === viewOf(last),
    };
    item.record("C5", row);
    expect(row.providerRequests).toBeGreaterThanOrEqual(3);
    expect(row.retriedRequestContainsActivation).toBe(true);
    expect(row.retriedRequestExcludesPrior).toBe(true);
    expect(row.retriedRequestContainsMemory).toBe(true);
    expect(row.viewFrozenAcrossRetry).toBe(true);
  }, 30_000);

  it("C7 a blocked memory fails closed with zero further provider requests", async () => {
    // The first activation of a fresh Home legitimately sends an empty view:
    // nothing is before it. This case is about the activation AFTER the memory
    // blocked, and retry is enabled on purpose, so a refused policy error must
    // not become a provider request, a retry start, or a second error entry.
    const item = await open("c7", {
      home: true,
      memory: true,
      retryBaseDelayMs: 1,
      // A compactor that can never succeed: the memory blocks permanently, which
      // is the Home state `Home memory is blocked: ...` names.
      summarizer: async () => fauxAssistantMessage("", { stopReason: "error", errorMessage: "invalid_request_error: unsupported message" }),
    });
    item.faux.setResponses([item.response("first activation response")]);
    await item.slot.prompt(longInput("C7 first activation input"));
    await waitUntil(() => !item.slot.isBusy);
    await waitUntil(() => item.memoryStatus().blocked !== undefined);
    const requestsBefore = item.faux.state.callCount;
    const autoRetryStarts: Array<Record<string, unknown>> = [];
    item.session.subscribe((event) => {
      if (event.type === "auto_retry_start") autoRetryStarts.push(event as unknown as Record<string, unknown>);
    });
    item.faux.setResponses([async (context) => { item.requests.push(record(context)); return fauxAssistantMessage("must never be produced"); }]);
    const outcome = await item.slot.prompt(longInput("C7 activation input")).then(
      () => ({ rejected: false, message: "" }),
      (error: unknown) => ({ rejected: true, message: error instanceof Error ? `${error.name}: ${error.message}` : String(error) }),
    );
    await waitUntil(() => !item.slot.isBusy);
    const entries = await item.entries();
    const messages = entries.filter((entry) => (entry as { type?: string }).type === "message").map((entry) => (entry as { message?: Record<string, unknown> }).message!);
    const errorEntry = messages.find((message) => message.role === "assistant" && message.stopReason === "error");
    const memoryStatus = item.memoryStatus();
    const row = {
      providerRequests: item.faux.state.callCount,
      providerRequestsOfRefusedActivation: item.faux.state.callCount - requestsBefore,
      promptRejected: outcome.rejected,
      rejectionIsPolicyError: outcome.message.includes("Home request refused"),
      canonicalRoles: messages.map((message) => message.role),
      canonicalErrorEntry: errorEntry ? { role: errorEntry.role, stopReason: errorEntry.stopReason, errorMessage: errorEntry.errorMessage } : null,
      policyRefusals: item.policy()?.refusalLog().map((entry) => entry.reason) ?? [],
      memoryBlocked: memoryStatus.blocked ?? null,
      slotPhase: item.slot.snapshot().phase,
      slotOperation: item.slot.snapshot().operation?.id ?? null,
      assistantErrorEntries: messages.filter((message) => message.role === "assistant" && message.stopReason === "error").length,
      autoRetryStarts: autoRetryStarts.length,
      retryEnabled: true,
    };
    item.record("C7", row);
    expect(row.providerRequestsOfRefusedActivation).toBe(0);
    expect(row.assistantErrorEntries).toBe(1);
    expect(row.autoRetryStarts).toBe(0);
    expect(row.policyRefusals).toContain("memory-blocked");
    expect(row.memoryBlocked).toBe("permanent-failure");
    expect(row.slotPhase).toBe("idle");
    expect(row.slotOperation).toBeNull();
  }, 30_000);

  it("C7b an unconfigured memory fails closed with zero provider requests", async () => {
    const item = await open("c7b", { home: true });
    item.faux.setResponses([async (context) => { item.requests.push(record(context)); return fauxAssistantMessage("must never be produced"); }]);
    const outcome = await item.slot.prompt(longInput("C7b activation input")).then(
      () => ({ rejected: false, message: "" }),
      (error: unknown) => ({ rejected: true, message: error instanceof Error ? `${error.name}: ${error.message}` : String(error) }),
    );
    await waitUntil(() => !item.slot.isBusy);
    const row = {
      providerRequests: item.faux.state.callCount,
      refusalReason: item.policy()?.refusalLog().at(-1)?.reason ?? null,
      refusalDetail: item.policy()?.refusalLog().at(-1)?.detail ?? null,
      canonicalErrorMessages: (await item.entries())
        .filter((entry) => (entry as { type?: string }).type === "message")
        .map((entry) => (entry as { message?: { stopReason?: string; errorMessage?: string } }).message?.errorMessage)
        .filter((value) => typeof value === "string"),
      memoryStatus: item.memoryStatus(),
    };
    item.record("C7b", row);
    expect(row.providerRequests).toBe(0);
    expect(row.refusalReason).toBe("memory-not-configured");
    expect(row.memoryStatus).toEqual({ configured: false, open: false });
  }, 30_000);

  it("C7c a virtual memory model is refused at configuration", async () => {
    const item = await open("c7c", { home: true, memoryModel: "virtual-model" });
    const outcome = await item.registry.homeOwner().configureMemory({ model: MEMORY_MODEL, tokenBudget: 1_000 }).then(
      () => "accepted",
      (error: unknown) => error instanceof Error ? error.message : String(error),
    );
    item.faux.setResponses([async (context) => { item.requests.push(record(context)); return fauxAssistantMessage("must never be produced"); }]);
    await item.slot.prompt(longInput("C7c activation input"));
    await waitUntil(() => !item.slot.isBusy);
    const row = { configureOutcome: outcome, providerRequests: item.faux.state.callCount, memoryStatus: item.memoryStatus() };
    item.record("C7c", row);
    expect(outcome).toContain("virtual model");
    expect(row.providerRequests).toBe(0);
    expect(row.memoryStatus.configured).toBe(false);
  }, 30_000);

  it("C8 defense in depth: either wrapper alone still fails closed", async () => {
    // (a) The guard alone, with an activation but no prepared request.
    const guarded = await open("c8a", { home: true, memory: true });
    guarded.faux.setResponses([async (context) => { guarded.requests.push(record(context)); return fauxAssistantMessage("unexpected"); }]);
    const policy = guarded.policy()!;
    let innerStreamCalls = 0;
    const inner = ((() => { innerStreamCalls += 1; return { [Symbol.asyncIterator]: async function* () {} }; }) as unknown as StreamFn);
    const guard = policy.wrapStreamFunction(inner);
    policy.admit("c8a", guarded.session.sessionManager.getLeafId() ?? null);
    const model = guarded.faux.getModel();
    let guardOutcome = "returned";
    try {
      guard(model, { messages: [{ role: "user", content: "no activation view here" }] } as unknown as Parameters<StreamFn>[1], {} as Parameters<StreamFn>[2]);
    } catch (error) {
      guardOutcome = error instanceof Error ? error.message : String(error);
    }
    policy.settle("c8a");
    // (b) The `prepareRequest` wrapper alone, with no memory configured.
    const unconfigured = await open("c8b", { home: true });
    unconfigured.faux.setResponses([async (context) => { unconfigured.requests.push(record(context)); return fauxAssistantMessage("unexpected"); }]);
    const unconfiguredPolicy = unconfigured.policy()!;
    unconfiguredPolicy.admit("c8b", unconfigured.session.sessionManager.getLeafId() ?? null);
    const prepared = unconfiguredPolicy.wrapPrepareRequest(unconfigured.session, undefined);
    const projection = unconfigured.session.sessionManager.buildSessionProjection();
    const wrapperOutcome = await Promise.resolve(
      prepared({ context: { messages: projection.messages }, model: unconfigured.faux.getModel(), thinkingLevel: "off" }),
    ).then(() => "accepted", (error: unknown) => error instanceof Error ? error.message : String(error));
    const row = {
      guardOutcome,
      guardInnerStreamCalls: innerStreamCalls,
      guardRefusal: policy.refusalLog().at(-1)?.reason ?? null,
      wrapperOutcome,
      wrapperRefusal: unconfiguredPolicy.refusalLog().at(-1)?.reason ?? null,
      providerRequests: guarded.faux.state.callCount + unconfigured.faux.state.callCount,
    };
    guarded.record("C8", row);
    expect(row.guardRefusal).toBe("stream-nonce");
    expect(row.guardInnerStreamCalls).toBe(0);
    expect(row.wrapperRefusal).toBe("memory-not-configured");
    expect(row.providerRequests).toBe(0);
  }, 30_000);

  it("C9 an un-admitted turn is refused", async () => {
    const item = await open("c9", { home: true, memory: true });
    item.faux.setResponses([item.response("prior activation response")]);
    await item.slot.prompt(longInput("C9 first activation input"));
    await waitUntil(() => !item.slot.isBusy);
    const callsBefore = item.faux.state.callCount;
    // `sendCustomMessage(..., { triggerTurn: true })` is the SDK path an extension
    // uses: it starts a run without Tron's prompt admission.
    await item.session.sendCustomMessage(
      { customType: "idle-turn", content: "idle extension turn", display: false },
      { triggerTurn: true },
    );
    await waitUntil(() => !item.slot.isBusy);
    const entries = await item.entries();
    const messages = entries.filter((entry) => (entry as { type?: string }).type === "message").map((entry) => (entry as { message?: Record<string, unknown> }).message!);
    const row = {
      providerRequestsAfterTrigger: item.faux.state.callCount - callsBefore,
      policyRefusals: item.policy()?.refusalLog().map((entry) => entry.reason) ?? [],
      canonicalRoles: messages.map((message) => message.role),
      errorEntry: messages.findLast((message) => message.stopReason === "error")?.errorMessage ?? null,
      slotPhase: item.slot.snapshot().phase,
    };
    item.record("C9", row);
    expect(row.providerRequestsAfterTrigger).toBe(0);
    expect(row.policyRefusals).toContain("no-activation");
    expect(row.slotPhase).toBe("idle");
  }, 30_000);

  it("C11 inertness: an ordinary session in a Home registry has no seam", async () => {
    const item = await open("c11", { home: true, memory: true });
    const ordinary = await item.extra("ordinary");
    item.faux.setResponses([item.response("first activation response"), item.response("second activation response")]);
    await ordinary.slot.prompt("C11 first activation input");
    await waitUntil(() => !ordinary.slot.isBusy);
    await ordinary.slot.prompt("C11 second activation input");
    await waitUntil(() => !ordinary.slot.isBusy);
    const row = {
      providerRequests: item.requests.length,
      roleSequences: item.requests.map((request) => request.roles),
      secondIncludesPrior: item.requests[1]!.blob.includes("C11 first activation input"),
      ordinaryPolicy: item.registry.homeOwner().requestPolicyFor(ordinary.slot.id) ?? null,
    };
    item.record("C11", row);
    expect(row.ordinaryPolicy).toBeNull();
    expect(row.roleSequences).toEqual([["system", "user"], ["system", "user", "assistant", "user"]]);
    expect(row.secondIncludesPrior).toBe(true);
  }, 30_000);

  it("C12 accounting: an oversized activation never reaches the provider", async () => {
    const item = await open("c12", { home: true, memory: true, contextWindow: 120 });
    item.faux.setResponses([async (context) => { item.requests.push(record(context)); return fauxAssistantMessage("unexpected"); }]);
    const outcome = await item.slot.prompt(longInput("C12 activation input")).then(
      () => "accepted",
      (error: unknown) => error instanceof Error ? `${error.name}: ${error.message}` : String(error),
    );
    await waitUntil(() => !item.slot.isBusy);
    const row = {
      providerRequests: item.faux.state.callCount,
      outcome,
      policyRefusals: item.policy()?.refusalLog().map((entry) => entry.reason) ?? [],
      lastRefusalDetail: item.policy()?.refusalLog().at(-1)?.detail ?? null,
    };
    item.record("C12", row);
    expect(row.providerRequests).toBe(0);
    expect(row.policyRefusals).toContain("context-overflow");
  }, 30_000);

  it("C13 a runtime reload keeps both wrappers installed", async () => {
    const item = await open("c13", { home: true, memory: true });
    item.faux.setResponses([item.response("prior activation response")]);
    await item.slot.prompt(longInput("C13 first activation input"));
    await waitUntil(() => !item.slot.isBusy);
    await item.slot.reload();
    await waitUntil(() => !item.slot.isBusy);
    const requestsBefore = item.requests.length;
    item.faux.setResponses([item.response("after reload")]);
    await item.slot.prompt(longInput("C13 second activation input"));
    await waitUntil(() => !item.slot.isBusy);
    const afterReload = item.requests.slice(requestsBefore);
    const row = {
      providerRequests: item.requests.length,
      requestsAfterReload: afterReload.length,
      reloadedRequestExcludesPrior: afterReload.every((request) => !request.blob.includes("C13 first activation input")),
      reloadedRequestContainsMemory: afterReload.every((request) => request.blob.includes(HOME_MEMORY_VIEW_MARKER)),
      samePolicyAfterReload: item.policy() === item.registry.homeOwner().requestPolicyFor(item.slot.id),
    };
    item.record("C13", row);
    expect(row.requestsAfterReload).toBe(1);
    expect(row.reloadedRequestExcludesPrior).toBe(true);
    expect(row.reloadedRequestContainsMemory).toBe(true);
    expect(row.samePolicyAfterReload).toBe(true);
  }, 30_000);

  it("C16 a context handler that appends a message is refused", async () => {
    const item = await open("c16", { home: true, memory: true });
    item.faux.setResponses([item.response("prior activation response")]);
    await item.slot.prompt(longInput("C16 prior input"));
    await waitUntil(() => !item.slot.isBusy);
    const callsBefore = item.faux.state.callCount;
    const policy = item.policy()!;
    policy.admit("c16", item.session.sessionManager.getLeafId() ?? null);
    const prepared = policy.wrapPrepareRequest(item.session, undefined);
    const projection = item.session.sessionManager.buildSessionProjection();
    const update = await prepared({ context: { messages: projection.messages }, model: item.faux.getModel(), thinkingLevel: "off" });
    const messages = (update as { context: { messages: AgentMessage[] } }).context.messages;
    // Exactly the SDK's context stage: it clones, and one handler adds a message.
    const injected = { role: "user", content: "INJECTED-BY-CONTEXT-HANDLER", timestamp: Date.now() } as unknown as AgentMessage;
    const outer = async (value: AgentMessage[]) => [...value, injected];
    const outcome = await policy.wrapTransformContext(outer)(messages, undefined)
      .then(() => "accepted", (error: unknown) => error instanceof Error ? error.message : String(error));
    const refusal = policy.refusalLog().at(-1);
    policy.settle("c16");
    const row = {
      outcome,
      refusalReason: refusal?.reason ?? null,
      refusalDetail: refusal?.detail ?? null,
      providerRequestsFromRefusedPath: item.faux.state.callCount - callsBefore,
    };
    item.record("C16", row);
    expect(row.refusalReason).toBe("context-mutated");
    expect(row.providerRequestsFromRefusedPath).toBe(0);
  }, 30_000);

  it("C17 the recorded expectation is single-use for one provider stream call", async () => {
    const item = await open("c17", { home: true, memory: true });
    item.faux.setResponses([item.response("prior activation response")]);
    await item.slot.prompt(longInput("C17 prior input"));
    await waitUntil(() => !item.slot.isBusy);
    const policy = item.policy()!;
    let innerStreamCalls = 0;
    const inner = ((() => { innerStreamCalls += 1; return { [Symbol.asyncIterator]: async function* () {} }; }) as unknown as StreamFn);
    const guard = policy.wrapStreamFunction(inner);
    policy.admit("c17", item.session.sessionManager.getLeafId() ?? null);
    const prepared = policy.wrapPrepareRequest(item.session, undefined);
    const projection = item.session.sessionManager.buildSessionProjection();
    const update = await prepared({ context: { messages: projection.messages }, model: item.faux.getModel(), thinkingLevel: "off" });
    const transformed = await policy.wrapTransformContext(undefined)((update as { context: { messages: AgentMessage[] } }).context.messages, undefined);
    const llmContext = { messages: convertToLlm(transformed) } as unknown as Parameters<StreamFn>[1];
    const options = {} as Parameters<StreamFn>[2];
    let first = "returned";
    try { guard(item.faux.getModel(), llmContext, options); } catch (error) { first = error instanceof Error ? error.message : String(error); }
    let second = "returned";
    try { guard(item.faux.getModel(), llmContext, options); } catch (error) { second = error instanceof Error ? error.message : String(error); }
    const row = { firstStreamCall: first, secondStreamCall: second, secondRefusal: policy.refusalLog().at(-1)?.reason ?? null, innerStreamCalls };
    policy.settle("c17");
    item.record("C17", row);
    expect(row.firstStreamCall).toBe("returned");
    expect(row.secondRefusal).toBe("stream-replayed");
    expect(row.innerStreamCalls).toBe(1);
  }, 30_000);

  it("C18 readiness: a request waits for the memory instead of sending an unbuilt view", async () => {
    const item = await open("c18", { home: true, memory: true, heldSummarizer: true });
    item.faux.setResponses([item.response("activation one response"), item.response("activation two response")]);
    await item.slot.prompt(longInput("C18 first activation input"));
    await waitUntil(() => !item.slot.isBusy);
    // The compactor is parked inside the first node build, so the memory cannot
    // cover anything yet.
    await waitUntil(() => item.compactor.entered > 0);
    item.record("C18-wait", {
      compactorEntered: item.compactor.entered,
      viewUnbuilt: item.memoryStatus().episodic?.view.unbuilt ?? -1,
      requestsBefore: item.requests.length,
    });
    expect(item.requests.length).toBe(1);
    const second = item.slot.prompt(longInput("C18 second activation input"));
    // The activation is admitted, and Pi is running it, but no request may be
    // sent while the lines it would carry are unbuilt.
    await waitUntil(() => item.policy()?.currentOperationId() !== undefined);
    await waitUntil(() => (item.memoryStatus().episodic?.coverage.summarized ?? 0) === 0);
    const requestsWhileWaiting = item.requests.length;
    item.compactor.release?.();
    await second;
    await waitUntil(() => !item.slot.isBusy);
    const sent = item.requests.at(-1)!;
    const row = {
      requestsWhileWaiting,
      providerRequests: item.requests.length,
      sentContainsSummary: sent.blob.includes(SUMMARY_MARKER),
      sentExcludesPriorText: !sent.blob.includes("C18 first activation input"),
    };
    item.record("C18", row);
    expect(row.requestsWhileWaiting).toBe(1);
    expect(row.providerRequests).toBe(2);
    expect(row.sentContainsSummary).toBe(true);
    expect(row.sentExcludesPriorText).toBe(true);
  }, 30_000);

  it("ordinary negative control: designating Home leaves an ordinary session byte-identical", async () => {
    const item = await open("negative-control", { home: false, memory: false });
    // Two ordinary sessions in one working directory, one before and one after
    // Home is designated and its memory configured in this same registry. Their
    // first provider requests must be byte-identical: a Home designation may not
    // change what an ordinary session sends.
    const before = await item.extra("ordinary", item.cwd);
    item.faux.setResponses([item.response("before home")]);
    await before.slot.prompt("negative control input");
    await waitUntil(() => !before.slot.isBusy);
    const modelRef = { provider: PROVIDER, id: MODEL_ID };
    await item.registry.homeOwner().designate({ model: modelRef }, () => modelRef);
    await item.registry.homeOwner().configureMemory({ model: MEMORY_MODEL, tokenBudget: 1_000_000 });
    const requestsBefore = [...item.requests];
    item.requests.length = 0;
    const after = await item.extra("ordinary", item.cwd);
    item.faux.setResponses([item.response("after home")]);
    await after.slot.prompt("negative control input");
    await waitUntil(() => !after.slot.isBusy);
    const requestsAfter = [...item.requests];
    const row = {
      requestsBefore: requestsBefore.map((request) => request.roles),
      requestsAfter: requestsAfter.map((request) => request.roles),
      byteIdentical: JSON.stringify(requestsBefore) === JSON.stringify(requestsAfter),
      beforeDiffersFromAfter: requestsBefore[0]!.blob === requestsAfter[0]!.blob ? [] : [requestsBefore[0]!.blob, requestsAfter[0]!.blob],
      policyForBefore: item.registry.homeOwner().requestPolicyFor(before.slot.id) ?? null,
      policyForAfter: item.registry.homeOwner().requestPolicyFor(after.slot.id) ?? null,
      homeDesignated: (await item.registry.homeOwner().status()).enabled,
    };
    item.record("negative-control", row);
    expect(row.requestsBefore).toEqual([["system", "user"]]);
    expect(row.requestsAfter).toEqual([["system", "user"]]);
    expect(row.byteIdentical).toBe(true);
    expect(row.policyForBefore).toBeNull();
    expect(row.policyForAfter).toBeNull();
    expect(row.homeDesignated).toBe(true);
  }, 30_000);

  it("C6 an overflow error on Home never starts compaction", async () => {
    const item = await open("c6", { home: true, memory: true, settings: { compaction: { enabled: true, reserveTokens: 4_096, keepRecentTokens: 0 } } });
    item.faux.setResponses([
      async (context) => { item.requests.push(record(context)); return fauxAssistantMessage("", { stopReason: "error", errorMessage: "context_length_exceeded" }); },
      async (context) => { item.requests.push(record(context)); return fauxAssistantMessage("must never be produced"); },
    ]);
    await item.slot.prompt(longInput("C6 activation input"));
    await waitUntil(() => !item.slot.isBusy);
    const entries = await item.entries();
    const messages = entries.filter((entry) => (entry as { type?: string }).type === "message").map((entry) => (entry as { message?: Record<string, unknown> }).message!);
    const row = {
      providerRequests: item.faux.state.callCount,
      roleSequences: item.requests.map((request) => request.roles),
      compactionEntries: entries.filter((entry) => (entry as { type?: string }).type === "compaction").length,
      compactionDiagnostics: item.diagnostics.length,
      errorEntry: messages.findLast((message) => message.stopReason === "error")?.errorMessage ?? null,
      canonicalRoles: messages.map((message) => message.role),
      slotPhase: item.slot.snapshot().phase,
    };
    item.record("C6", row);
    expect(row.providerRequests).toBe(1);
    expect(row.compactionEntries).toBe(0);
    expect(row.slotPhase).toBe("idle");
  }, 30_000);

  it("C10 an ordinary session compacts while a Home session in the same registry does not", async () => {
    const item = await open("c10", {
      home: true,
      memory: true,
      settings: { compaction: { enabled: true, reserveTokens: 120_000, keepRecentTokens: 0, instructions: "Retain the API contract" } },
    });
    const ordinary = await item.extra("ordinary");
    const large = "Earlier work ".repeat(8_000);
    const summaries: string[] = [];
    item.faux.setResponses(Array.from({ length: 16 }, () => async (context: { messages: Array<{ role: string }>; systemPrompt?: string }) => {
      const blob = JSON.stringify(context.messages);
      const system = (context.messages.find((message) => message.role === "system") as { content?: unknown } | undefined)?.content;
      if (typeof system === "string" && system.includes("User-configured summary focus:")) {
        summaries.push(blob.includes("C10 home input") ? "home" : blob.includes("C10 ordinary input") ? "ordinary" : "unknown");
        return fauxAssistantMessage("Earlier work was summarized.");
      }
      return blob.length > 40_000 ? fauxAssistantMessage(large) : fauxAssistantMessage("Small response after compaction.");
    }));
    await item.slot.prompt("C10 home input");
    await waitUntil(() => !item.slot.isBusy);
    await ordinary.slot.prompt("C10 ordinary input");
    await waitUntil(() => !ordinary.slot.isBusy);
    await item.slot.prompt("C10 home follow-up input");
    await waitUntil(() => !item.slot.isBusy);
    await ordinary.slot.prompt("C10 ordinary follow-up input");
    await waitUntil(() => !ordinary.slot.isBusy);
    const homeEntries = await item.entries();
    const ordinaryEntries = await ordinary.entries();
    const row = {
      summaryRequests: summaries.length,
      summaryRequestsBySession: summaries,
      homeCompactions: homeEntries.filter((entry) => (entry as { type?: string }).type === "compaction").length,
      ordinaryCompactions: ordinaryEntries.filter((entry) => (entry as { type?: string }).type === "compaction").length,
      homeCompactionPolicyBudgets: item.slot.snapshot().compactionPolicy?.currentBudgets?.enabled ?? null,
      ordinaryCompactionPolicyBudgets: ordinary.slot.snapshot().compactionPolicy?.currentBudgets?.enabled ?? null,
      homeCompactionDiagnostics: item.diagnostics.filter((diagnostic) => diagnostic.sessionId === item.slot.id).length,
      homePolicyRefusals: item.policy()?.refusalLog().map((entry) => entry.reason) ?? [],
    };
    item.record("C10", row);
    expect(row.homeCompactions).toBe(0);
    expect(row.ordinaryCompactions).toBeGreaterThan(0);
    expect(row.summaryRequestsBySession).not.toContain("home");
    expect(row.homeCompactionPolicyBudgets).toBe(false);
    expect(row.ordinaryCompactionPolicyBudgets).toBe(true);
  }, 60_000);

  it("C15 manual compaction on a Home session is refused, never repaired", async () => {
    const item = await open("c15", {
      home: true,
      memory: true,
      settings: { compaction: { enabled: true, reserveTokens: 120_000, keepRecentTokens: 0, instructions: "Retain the API contract" } },
    });
    item.faux.setResponses([item.response("Prior work ".repeat(8_000)), item.response("must never be produced")]);
    await item.slot.prompt(longInput("C15 activation input"));
    await waitUntil(() => !item.slot.isBusy);
    const callsBefore = item.faux.state.callCount;
    const outcome = await item.slot.compact().then(() => "accepted", (error: unknown) => error instanceof Error ? `${error.name}: ${error.message}` : String(error));
    await waitUntil(() => !item.slot.isBusy);
    const entries = await item.entries();
    const row = {
      compactOutcome: outcome,
      providerRequests: item.faux.state.callCount - callsBefore,
      compactionEntries: entries.filter((entry) => (entry as { type?: string }).type === "compaction").length,
      compactionDiagnostics: item.diagnostics.length,
      policyRefusals: item.policy()?.refusalLog().map((entry) => entry.reason) as HomeRefusalReason[] | undefined ?? [],
      slotPhase: item.slot.snapshot().phase,
      operation: item.slot.snapshot().operation?.kind ?? null,
    };
    item.record("C15", row);
    expect(row.providerRequests).toBe(0);
    expect(row.compactionEntries).toBe(0);
    expect(row.slotPhase).toBe("idle");
  }, 60_000);
});
