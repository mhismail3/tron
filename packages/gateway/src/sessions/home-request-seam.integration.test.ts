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
 * C16/C17 register a real SDK context handler through a test-only factory spy.
 * No production injection hook is needed.
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
import { existsSync } from "node:fs";
import { mkdir, mkdtemp, readFile, rm, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { dirname, join } from "node:path";
import {
  convertToLlm, ModelRuntime, type AgentSession, type ExtensionFactory,
} from "@earendil-works/pi-coding-agent";
import type { AgentMessage, StreamFn } from "@earendil-works/pi-agent-core";
import { fauxAssistantMessage, fauxProvider, fauxToolCall } from "@earendil-works/pi-ai";
import { afterAll, afterEach, describe, expect, it, vi } from "vitest";
import { TrustService } from "../admin/trust-service.js";
import type { SessionSnapshot } from "../protocol/types.js";
import type { EpisodicSummarizer } from "../episodic/episodic-contract.js";
import { HOME_MEMORY_VIEW_MARKER } from "../home/home-memory.js";
import type { HomeRecord } from "../home/home-owner.js";
import { HOME_NONCE_MARKER, HomeRequestPolicy, type HomeRefusalReason } from "../home/home-request-policy.js";
import * as tronModules from "../extensions/tron-modules.js";
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

async function waitUntil(predicate: () => boolean | Promise<boolean>, timeoutMs = 10_000): Promise<void> {
  const deadline = performance.now() + timeoutMs;
  while (!(await predicate())) {
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
  extension?: ExtensionFactory;
  /** Configure Home's memory (only with `home`). */
  memory?: boolean;
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
  if (options.extension) {
    const original = tronModules.homeModuleFactories;
    const spy = vi.spyOn(tronModules, "homeModuleFactories").mockImplementation((host) => [
      ...original(host), { name: "qualification", factory: options.extension! },
    ]);
    disposals.push(async () => { spy.mockRestore(); });
  }
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
      await registry.homeOwner().configureMemory({ model: MEMORY_MODEL });
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
    memoryStatus: async () => await registry.homeOwner().memoryStatus(),
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
  it("single-flights a reserved Home materialization and records its path before returning", async () => {
    const item = await open("reserved-materialization-single-flight", { home: true });
    const owner = item.registry.homeOwner() as unknown as {
      writeLocked(record: HomeRecord): Promise<void>;
      claimReservedChapter(sessionId: string, attemptId: string): Promise<unknown>;
    };
    const current = JSON.parse(await readFile(join(item.tronHome, "gateway", "home", "home.json"), "utf8")) as HomeRecord;
    const reservedId = "reserved-successor";
    await owner.writeLocked({
      ...current,
      chapters: [
        { ...current.chapters[0]!, state: "sealed", sealedAt: new Date().toISOString() },
        { sessionId: reservedId, ordinal: 2, state: "reserved", createdAt: new Date().toISOString() },
      ],
    });

    let releaseClaim!: () => void;
    let enteredClaim!: () => void;
    const claimEntered = new Promise<void>(resolve => { enteredClaim = resolve; });
    const claimGate = new Promise<void>(resolve => { releaseClaim = resolve; });
    const originalClaim = owner.claimReservedChapter.bind(owner);
    let claims = 0;
    owner.claimReservedChapter = async (sessionId, attemptId) => {
      claims += 1;
      enteredClaim();
      await claimGate;
      return originalClaim(sessionId, attemptId);
    };

    const first = item.registry.materializeReservedHome(reservedId);
    await claimEntered;
    const second = item.registry.materializeReservedHome(reservedId);
    releaseClaim();
    const [firstSlot, secondSlot] = await Promise.all([first, second]);
    expect(claims).toBe(1);
    expect(secondSlot).toBe(firstSlot);
    const stored = JSON.parse(await readFile(join(item.tronHome, "gateway", "home", "home.json"), "utf8")) as HomeRecord;
    expect(stored.chapters[1]).toMatchObject({
      sessionId: reservedId, state: "materializing", attemptId: expect.any(String),
      expectedPath: firstSlot.sessionFile,
    });
    expect(firstSlot.sessionFile).toBeTruthy();
    expect(existsSync(firstSlot.sessionFile!)).toBe(false);
    expect(item.faux.state.callCount).toBe(0);

    // A contender arriving after the shared construction promise resolves, but
    // before the first canonical flush, must still join the live owner.
    const afterReturn = await item.registry.materializeReservedHome(reservedId);
    const afterReturnRecord = JSON.parse(await readFile(join(item.tronHome, "gateway", "home", "home.json"), "utf8")) as HomeRecord;
    expect(afterReturn).toBe(firstSlot);
    expect(afterReturn.sessionFile).toBe(firstSlot.sessionFile);
    expect(afterReturnRecord.chapters[1]).toMatchObject({
      state: "materializing", attemptId: stored.chapters[1]!.attemptId,
      expectedPath: stored.chapters[1]!.expectedPath,
    });
    const home = item.registry.homeOwner() as unknown as { writeLocked(record: HomeRecord): Promise<void> };
    const authoritative = JSON.parse(await readFile(join(item.tronHome, "gateway", "home", "home.json"), "utf8")) as HomeRecord;
    for (const mismatch of [
      { attemptId: "different-attempt", expectedPath: stored.chapters[1]!.expectedPath },
      { attemptId: stored.chapters[1]!.attemptId, expectedPath: `${stored.chapters[1]!.expectedPath}.other` },
    ]) {
      await home.writeLocked({
        ...authoritative,
        chapters: authoritative.chapters.map((entry, index) => index === 1 ? { ...entry, ...mismatch } : entry),
      });
      await expect(firstSlot.prompt("mismatched slot authority"))
        .rejects.toMatchObject({ details: { reason: "sealed-chapter" } });
      expect(existsSync(firstSlot.sessionFile!)).toBe(false);
    }
    await home.writeLocked(authoritative);
    item.faux.setResponses([item.response("first reserved response")]);
    await firstSlot.prompt("first reserved prompt without operation permit");
    await waitUntil(() => !firstSlot.isBusy);
    expect(existsSync(firstSlot.sessionFile!)).toBe(true);
    expect(firstSlot.canonicalSessionEntries().some(entry => entry.type === "message" && entry.message.role === "user"))
      .toBe(true);
    cases.push({ case: "reservation-owner-through-first-flush", firstPathPreserved: true, contenderJoined: true, firstAppendAuthorizedBySlot: true });
  });

  it("blocks Registry materialization on uncertain scan evidence without creating a runtime", async () => {
    const item = await open("reserved-materialization-scan-block", { home: true });
    const owner = item.registry.homeOwner() as unknown as { writeLocked(record: HomeRecord): Promise<void> };
    const current = JSON.parse(await readFile(join(item.tronHome, "gateway", "home", "home.json"), "utf8")) as HomeRecord;
    const reservedId = "reserved-scan-block";
    await owner.writeLocked({
      ...current,
      chapters: [
        { ...current.chapters[0]!, state: "sealed", sealedAt: new Date().toISOString() },
        { sessionId: reservedId, ordinal: 2, state: "reserved", createdAt: new Date().toISOString() },
      ],
    });
    const unknownPath = join(dirname(item.slot.sessionFile!), "unreadable-candidate.jsonl");
    const unknownBytes = "{partial";
    await writeFile(unknownPath, unknownBytes);

    await expect(item.registry.materializeReservedHome(reservedId)).rejects.toMatchObject({ code: "conflict" });
    expect(await readFile(unknownPath, "utf8")).toBe(unknownBytes);
    expect(item.faux.state.callCount).toBe(0);
    expect(await item.registry.homeOwner().status()).toMatchObject({ sessionId: reservedId, live: false });
  });

  it("does not publish or dispatch when the durable expected-path barrier fails", async () => {
    const item = await open("reserved-materialization-path-failure", { home: true });
    const owner = item.registry.homeOwner() as unknown as {
      writeLocked(record: HomeRecord): Promise<void>;
      recordReservedChapterPath(sessionId: string, attemptId: string, path: string): Promise<void>;
    };
    const current = JSON.parse(await readFile(join(item.tronHome, "gateway", "home", "home.json"), "utf8")) as HomeRecord;
    const reservedId = "reserved-path-failure";
    await owner.writeLocked({
      ...current,
      chapters: [
        { ...current.chapters[0]!, state: "sealed", sealedAt: new Date().toISOString() },
        { sessionId: reservedId, ordinal: 2, state: "reserved", createdAt: new Date().toISOString() },
      ],
    });
    const refused = owner.recordReservedChapterPath.bind(owner);
    owner.recordReservedChapterPath = async () => { throw new Error("injected path persistence failure"); };

    await expect(item.registry.materializeReservedHome(reservedId)).rejects.toThrow("injected path persistence failure");
    owner.recordReservedChapterPath = refused;
    expect(item.faux.state.callCount).toBe(0);
    expect(await item.registry.homeOwner().status()).toMatchObject({ sessionId: reservedId, live: false });
  });

  it("continues refusing sealed physical mutations after Home is disabled", async () => {
    const item = await open("disabled-sealed-chapter", { home: true });
    item.faux.setResponses([item.response("canonical baseline")]);
    await item.slot.prompt("canonical baseline input");
    await waitUntil(() => !item.slot.isBusy);
    await item.registry.homeOwner().disable();
    const owner = item.registry.homeOwner() as unknown as { writeLocked(record: HomeRecord): Promise<void> };
    const current = JSON.parse(await readFile(join(item.tronHome, "gateway", "home", "home.json"), "utf8")) as HomeRecord;
    await owner.writeLocked({
      ...current,
      chapters: [
        ...current.chapters.map(chapter => chapter.sessionId === item.slot.id
          ? { ...chapter, state: "sealed" as const, sealedAt: new Date().toISOString() }
          : chapter),
        { sessionId: "reserved-successor", ordinal: current.chapters.length + 1, state: "reserved", createdAt: new Date().toISOString() },
      ],
    });
    expect(item.registry.homeOwner().profileFor(item.slot.id)).toBe("ordinary");
    expect(item.registry.homeOwner().chapterStateFor(item.slot.id)).toMatchObject({ sessionId: item.slot.id, sealed: true, ordinal: 1 });
    const oldBytes = await item.jsonl();
    await item.registry.dispose();

    const coldModelRuntime = await ModelRuntime.create({ authPath: join(item.root, "auth.json"), modelsPath: null, refreshOnCreate: false });
    coldModelRuntime.registerNativeProvider(item.faux.provider);
    const coldRegistry = new RuntimeRegistry({
      agentDir: item.agentDir,
      tronHome: item.tronHome,
      idleRuntimeMs: 60_000,
      modelRuntimeFactory: async () => coldModelRuntime,
      trust: new TrustService(item.agentDir),
      broadcast: () => {},
      sessionSummaryChanged: () => {},
      sessionListChanged: () => {},
      homeMemorySummarizer: () => ({ summarizer: async () => "summary" }),
    });
    disposals.push(() => coldRegistry.dispose());
    await coldRegistry.initialize();
    await coldRegistry.recoverCanonicalAttention();
    const coldSlot = await coldRegistry.acquire(item.slot.id);
    const coldSession = (coldSlot as unknown as { runtime: { session: AgentSession } }).runtime.session;
    expect(coldRegistry.homeOwner().profileFor(item.slot.id)).toBe("ordinary");
    const entries = coldSession.sessionManager.getEntries();
    const leaf = coldSession.sessionManager.getLeafId();
    const bytes = await readFile(coldSlot.sessionFile!, "utf8");
    await expect(coldSlot.setThinking("low")).rejects.toMatchObject({
      code: "conflict", details: { reason: "sealed-chapter", sessionId: item.slot.id },
    });
    expect(coldSession.sessionManager.getEntries()).toEqual(entries);
    expect(coldSession.sessionManager.getLeafId()).toBe(leaf);
    expect(await readFile(coldSlot.sessionFile!, "utf8")).toBe(bytes);
    expect(bytes).toBe(oldBytes);
    item.record("disabled-sealed-chapter", { profile: "ordinary", refused: true, bytesUnchanged: true });
  });

  it("refuses sealed Slot mutation paths before changing SDK state or the canonical file", async () => {
    const item = await open("sealed-mutation-paths", { home: true });
    item.faux.setResponses([item.response("canonical baseline")]);
    await item.slot.prompt("canonical baseline input");
    await waitUntil(() => !item.slot.isBusy);

    const runtime = item.slot as unknown as {
      dependencies: { homeChapterState?: (sessionId: string) => { sessionId: string; sealed: boolean } };
      runtime: { session: AgentSession };
    };
    runtime.dependencies.homeChapterState = (sessionId) => ({ sessionId, sealed: true });
    const owner = item.registry.homeOwner() as unknown as {
      chapterStateFor: (sessionId: string) => { sessionId: string; sealed: boolean };
    };
    owner.chapterStateFor = runtime.dependencies.homeChapterState;
    const manager = item.session.sessionManager;
    const originalEntries = manager.getEntries();
    const originalLeaf = manager.getLeafId();
    const originalFile = await item.jsonl();
    const originalRequestCount = item.requests.length;
    const actions = (item.slot as unknown as { commandActions: () => Record<string, (...args: unknown[]) => unknown> }).commandActions();
    const extensionMutation = (name: string, ...arguments_: unknown[]) => async () => {
      await actions[name]!(...arguments_);
    };
    const sealedRefusal = { code: "conflict", details: { reason: "sealed-chapter", sessionId: item.slot.id } };
    const mutationPaths: Array<[string, () => Promise<unknown>]> = [
      ["prompt", () => item.slot.prompt("sealed input")],
      ["steer", () => item.slot.prompt("sealed steering input", [], "steer")],
      ["follow-up", () => item.slot.prompt("sealed follow-up input", [], "followUp")],
      ["setModel", () => item.slot.setModel(PROVIDER, MODEL_ID)],
      ["setContextWindow", () => item.slot.setContextWindow(PROVIDER, MODEL_ID, 8_000, -1, "stale")],
      ["setThinking", () => item.slot.setThinking("off")],
      ["setTools", () => item.slot.setTools(["ask_user"])],
      ["rename", () => item.slot.rename("sealed rename")],
      ["setLabel", () => item.slot.setLabel(originalLeaf!, "sealed label")],
      ["fork", () => item.slot.fork(originalLeaf!)],
      ["navigate", () => item.slot.navigate(originalLeaf!, { summarize: false })],
      ["reload", () => item.slot.reload()],
      ["extension newSession", extensionMutation("newSession")],
      ["extension fork", extensionMutation("fork", originalLeaf)],
      ["extension navigateTree", extensionMutation("navigateTree", originalLeaf, {})],
      ["extension switchSession", extensionMutation("switchSession", "unused", {})],
      ["extension reload", extensionMutation("reload")],
      ["bash", () => item.slot.executeBash("echo sealed", false)],
      ["archive lane", () => item.slot.commitArchiveWhileIdle(undefined, async () => undefined)],
      ["attention", () => item.registry.setAttention(item.slot.id, true)],
      ["archive", () => item.registry.setArchived(item.slot.id, true)],
      ["delete", () => item.registry.delete(item.slot.id)],
    ];

    for (const [name, mutation] of mutationPaths) {
      const refusal = await mutation().then(() => undefined, (error: unknown) => error);
      expect(refusal, `${name} was not refused`).toMatchObject(sealedRefusal);
      expect(manager.getEntries(), `${name} changed live SDK entries`).toEqual(originalEntries);
      expect(manager.getLeafId(), `${name} changed the live leaf`).toBe(originalLeaf);
      expect(await item.jsonl(), `${name} changed canonical file bytes`).toBe(originalFile);
    }
    expect(item.requests).toHaveLength(originalRequestCount);
  }, 30_000);

  it("refuses a sealed first activation before the SDK first flush can materialize a file", async () => {
    const item = await open("sealed-first-flush", { home: true, memory: true });
    item.faux.setResponses([item.response("unexpected sealed mutation response")]);
    const runtime = item.slot as unknown as {
      dependencies: { homeChapterState?: (sessionId: string) => { sessionId: string; sealed: boolean } };
      runtime: { session: AgentSession };
    };
    runtime.dependencies.homeChapterState = (sessionId) => ({ sessionId, sealed: true });
    const manager = item.session.sessionManager;
    const originalEntries = manager.getEntries();
    const originalLeaf = manager.getLeafId();
    const originalSessionFile = item.slot.sessionFile;
    const originalRequestCount = item.requests.length;
    const fileBefore = originalSessionFile
      ? await readFile(originalSessionFile, "utf8").catch((error: NodeJS.ErrnoException) => error.code === "ENOENT" ? undefined : Promise.reject(error))
      : undefined;

    await expect(item.slot.prompt("must not materialize sealed Home")).rejects.toMatchObject({
      code: "conflict",
      details: { reason: "sealed-chapter", sessionId: item.slot.id },
    });
    expect(manager.getEntries()).toEqual(originalEntries);
    expect(manager.getLeafId()).toBe(originalLeaf);
    expect(item.slot.sessionFile).toBe(originalSessionFile);
    expect(item.requests).toHaveLength(originalRequestCount);
    if (originalSessionFile) {
      const fileAfter = await readFile(originalSessionFile, "utf8").catch((error: NodeJS.ErrnoException) => error.code === "ENOENT" ? undefined : Promise.reject(error));
      expect(fileAfter).toBe(fileBefore);
    }
  }, 30_000);

  it("keeps a pre-append sealed custom-entry refusal out of the uncertain-write fence", async () => {
    const item = await open("sealed-custom-entry", { home: true });
    item.faux.setResponses([item.response("canonical baseline")]);
    await item.slot.prompt("canonical baseline input");
    await waitUntil(() => !item.slot.isBusy);

    const runtime = item.slot as unknown as {
      dependencies: { homeChapterState?: (sessionId: string) => { sessionId: string; sealed: boolean } };
      persistCanonicalCustomEntry(type: string, data: Record<string, unknown>, identity: string): Promise<void>;
      hasBlockedOwnershipWrite: boolean;
      durableWrites: Map<string, unknown>;
    };
    runtime.dependencies.homeChapterState = (sessionId) => ({ sessionId, sealed: true });
    const manager = item.session.sessionManager;
    const originalEntries = manager.getEntries();
    const originalLeaf = manager.getLeafId();
    const originalFile = await item.jsonl();

    vi.useFakeTimers();
    try {
      const write = runtime.persistCanonicalCustomEntry("test.sealed-entry", { receiptId: "sealed-receipt" }, "sealed-receipt");
      await vi.advanceTimersByTimeAsync(20_001);
      await expect(write).rejects.toMatchObject({
        code: "conflict",
        details: { reason: "sealed-chapter", sessionId: item.slot.id },
      });
      expect(runtime.hasBlockedOwnershipWrite).toBe(false);
      expect(manager.getEntries()).toEqual(originalEntries);
      expect(manager.getLeafId()).toBe(originalLeaf);
      expect(await item.jsonl()).toBe(originalFile);
    } finally {
      runtime.durableWrites.clear();
      vi.useRealTimers();
    }
  }, 30_000);

  it("fences a custom entry that fails after the SDK has staged it", async () => {
    const item = await open("staged-custom-entry-failure", { home: true });
    item.faux.setResponses([item.response("canonical baseline")]);
    await item.slot.prompt("canonical baseline input");
    await waitUntil(() => !item.slot.isBusy);

    const runtime = item.slot as unknown as {
      dependencies: { homeChapterState?: (sessionId: string) => { sessionId: string; sealed: boolean } };
      persistCanonicalCustomEntry(type: string, data: Record<string, unknown>, identity: string): Promise<void>;
      hasBlockedOwnershipWrite: boolean;
      durableWrites: Map<string, unknown>;
    };
    runtime.dependencies.homeChapterState = (sessionId) => ({ sessionId, sealed: false });
    const manager = item.session.sessionManager;
    const append = manager.appendCustomEntry.bind(manager);
    const appendAttempt = vi.spyOn(manager, "appendCustomEntry").mockImplementation((...arguments_) => {
      append(...arguments_);
      throw new Error("injected failure after SDK staging");
    });
    try {
      await expect(runtime.persistCanonicalCustomEntry(
        "test.staged-entry", { receiptId: "staged-receipt" }, "staged-receipt",
      )).rejects.toMatchObject({ details: { outcomeUnknown: true } });
      expect(appendAttempt).toHaveBeenCalledTimes(1);
      expect(manager.getBranch().filter((entry) => entry.type === "custom" && entry.customType === "test.staged-entry")).toHaveLength(1);
      expect(runtime.hasBlockedOwnershipWrite).toBe(true);
      await expect(item.slot.prompt("must remain fenced")).rejects.toMatchObject({ details: { outcomeUnknown: true } });
    } finally {
      appendAttempt.mockRestore();
      // This isolated fixture intentionally poisons one runtime. Remove its
      // unresolved owner only so the test runner can dispose its temporary tree;
      // production recovery remains an authoritative reopen, never this reset.
      runtime.durableWrites.clear();
    }
  }, 30_000);

  // F1: Pi's supported image replacement must not look like a context mutation.
  // Disable resizing here to isolate the settings-aware converter at the guard.
  it("C21 image conversion follows live session settings without rebuilding", async () => {
    const item = await open("c21", { home: true, memory: true, settings: { images: { blockImages: true, autoResize: false } } });
    const image = { type: "image" as const, mimeType: "image/png", data: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII=" };
    item.faux.setResponses([item.response("blocked image response"), item.response("visible image response")]);
    for (const blocked of [true, false]) {
      item.session.settingsManager.setBlockImages(blocked);
      const text = `C21 image input blocked=${blocked}`;
      const before = item.requests.length;
      await item.slot.prompt(text, [image]);
      await waitUntil(() => !item.slot.isBusy);
      const requests = item.requests.slice(before);
      item.record("C21", { autoResize: false, blocked, requests, refusals: item.policy()!.refusalLog() });
      expect(requests).toHaveLength(1);
      const messages = JSON.parse(requests[0]!.blob) as Array<{ role: string; content: unknown }>;
      const input = messages.find((message) => message.role === "user" && JSON.stringify(message.content).includes(text));
      expect(input?.content).toEqual([
        { type: "text", text },
        blocked ? { type: "text", text: "Image reading is disabled." } : image,
      ]);
    }
  }, 30_000);

  // F2: accepting the SDK converter must not authorize arbitrary stream edits.
  it("C22 arbitrary message mutation after context conversion is refused", async () => {
    const item = await open("c22", { home: true, memory: true });
    item.faux.setResponses([item.response("prior activation response")]);
    await item.slot.prompt(longInput("C22 prior input"));
    await waitUntil(() => !item.slot.isBusy);
    const policy = item.policy()!;
    policy.admit("c22", null);
    const prepared = policy.wrapPrepareRequest(item.session, undefined);
    const projection = item.session.sessionManager.buildSessionProjection();
    const update = await prepared({ context: { messages: projection.messages }, model: item.faux.getModel(), thinkingLevel: "off" });
    const transformed = await policy.wrapTransformContext(undefined, item.session.agent.convertToLlm)((update as { context: { messages: AgentMessage[] } }).context.messages, undefined);
    const messages = convertToLlm(transformed);
    const input = messages.find((message) => message.role === "user" && JSON.stringify(message.content).includes("C22 prior input"))!;
    input.content = [{ type: "text", text: "C22 mutated input" }];
    let innerCalls = 0;
    const inner = (() => {
      innerCalls += 1;
      return { [Symbol.asyncIterator]: async function* () {} };
    }) as unknown as StreamFn;
    const guard = policy.wrapStreamFunction(inner);
    let outcome = "returned";
    try {
      guard(item.faux.getModel(), { messages } as unknown as Parameters<StreamFn>[1], {} as Parameters<StreamFn>[2]);
    } catch (error) {
      outcome = error instanceof Error ? error.message : String(error);
    }
    const row = { outcome, refusal: policy.refusalLog().at(-1)?.reason, innerCalls };
    item.record("C22", row);
    expect(row.refusal).toBe("stream-digest");
    expect(row.innerCalls).toBe(0);
    policy.settle("c22");
  }, 30_000);

  // F4: the default SDK image path must preserve Pi's result for both Home and
  // an ordinary session.
  it("C23 default image handling matches an ordinary session for both block states", async () => {
    const item = await open("c23", { home: true, memory: true });
    const ordinary = await item.extra("ordinary");
    const ordinarySession = (ordinary.slot as unknown as { runtime: { session: AgentSession } }).runtime.session;
    const image = { type: "image" as const, mimeType: "image/png", data: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII=" };
    const cases = [] as Array<Record<string, unknown>>;
    for (const blocked of [true, false]) {
      item.session.settingsManager.setBlockImages(blocked);
      ordinarySession.settingsManager.setBlockImages(blocked);
      const text = `C23 default image input blocked=${blocked}`;
      const homeStart = item.requests.length;
      item.faux.setResponses([item.response("home response")]);
      await item.slot.prompt(text, [image]);
      await waitUntil(() => !item.slot.isBusy);
      const homeRequests = item.requests.slice(homeStart);
      expect(homeRequests).toHaveLength(1);
      const homeRequest = homeRequests.at(-1);
      const ordinaryStart = item.requests.length;
      item.faux.setResponses([item.response("ordinary response")]);
      await ordinary.slot.prompt(text, [image]);
      await waitUntil(() => !ordinary.slot.isBusy);
      const ordinaryRequests = item.requests.slice(ordinaryStart);
      expect(ordinaryRequests).toHaveLength(1);
      const ordinaryRequest = ordinaryRequests.at(-1);
      const userContent = (request: CapturedRequest | undefined) => {
        const messages = JSON.parse(request?.blob ?? "[]") as Array<{ role: string; content: unknown }>;
        return messages.find((message) => message.role === "user" && JSON.stringify(message.content).includes(text))?.content;
      };
      const homeContent = userContent(homeRequest);
      const ordinaryContent = userContent(ordinaryRequest);
      expect(homeContent).toBeDefined();
      expect(ordinaryContent).toBeDefined();
      const serializedHomeContent = JSON.stringify(homeContent);
      if (blocked) {
        expect(serializedHomeContent).toContain("Image reading is disabled.");
      } else {
        expect(serializedHomeContent).toContain('"type":"image"');
        expect(serializedHomeContent).toContain(image.data);
      }
      cases.push({ blocked, homeContent, ordinaryContent, equal: JSON.stringify(homeContent) === JSON.stringify(ordinaryContent) });
    }
    const row = { cases };
    item.record("C23", row);
    expect(cases).toHaveLength(2);
    expect(cases.every((entry) => entry.equal === true)).toBe(true);
  }, 30_000);

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
    const memoryStatus = await item.memoryStatus();
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
    // The SDK's context stage clones every message, so the fidelity check's
    // identity comparison is a fallback in practice: the header says so, and this
    // is where the claim is observed rather than inferred.
    expect(transformObservations.length).toBeGreaterThan(0);
    expect(transformObservations.every((observation) => observation.identity === false)).toBe(true);
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
      refusals: item.policy()?.refusalLog().map((entry) => `${entry.reason}: ${entry.detail}`) ?? [],
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
    await waitUntil(async () => (await item.memoryStatus()).blocked !== undefined);
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
    const memoryStatus = await item.memoryStatus();
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
      memoryStatus: await item.memoryStatus(),
    };
    item.record("C7b", row);
    expect(row.providerRequests).toBe(0);
    expect(row.refusalReason).toBe("memory-not-configured");
    expect(row.memoryStatus).toEqual({ configured: false, open: false });
  }, 30_000);

  it("C7c a virtual memory model is refused at configuration", async () => {
    const item = await open("c7c", { home: true, memoryModel: "virtual-model" });
    const outcome = await item.registry.homeOwner().configureMemory({ model: MEMORY_MODEL }).then(
      () => "accepted",
      (error: unknown) => error instanceof Error ? error.message : String(error),
    );
    item.faux.setResponses([async (context) => { item.requests.push(record(context)); return fauxAssistantMessage("must never be produced"); }]);
    await item.slot.prompt(longInput("C7c activation input"));
    await waitUntil(() => !item.slot.isBusy);
    const row = { configureOutcome: outcome, providerRequests: item.faux.state.callCount, memoryStatus: await item.memoryStatus() };
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

  it("C16 a real SDK context handler mutation is refused before streaming", async () => {
    let contextCalls = 0;
    const item = await open("c16", { home: true, memory: true, extension: (pi) => {
      pi.on("context", (event) => {
        contextCalls += 1;
        return { messages: [...event.messages, { role: "user", content: "INJECTED-BY-CONTEXT-HANDLER", timestamp: 0 }] };
      });
    } });
    item.faux.setResponses([item.response("must not reach provider")]);
    await item.slot.prompt("C16 input");
    await waitUntil(() => !item.slot.isBusy);
    const row = { contextCalls, providerCalls: item.faux.state.callCount, refusal: item.policy()!.refusalLog().at(-1)?.reason };
    item.record("C16", row);
    expect(contextCalls).toBe(1);
    expect(row.refusal).toBe("context-mutated");
    expect(row.providerCalls).toBe(0);
  }, 30_000);

  it("C17 a real stream consumes the SDK context pass exactly once", async () => {
    let contextCalls = 0;
    const item = await open("c17", { home: true, memory: true, extension: (pi) => {
      pi.on("context", () => { contextCalls += 1; });
    } });
    const stream = item.session.agent.streamFunction;
    let releaseProvider: (() => void) | undefined;
    const providerGate = new Promise<void>((resolve) => { releaseProvider = resolve; });
    let replay: Promise<string> | undefined;
    item.session.agent.streamFunction = (...args) => {
      const result = stream(...args);
      const providerCallsBefore = item.faux.state.callCount;
      // Let the first lazy stream pass Home's innermost guard and enter the
      // provider, then replay while its response is parked and this activation
      // is still live. Otherwise lazy-stream start order or settlement could
      // make the replay win the race or observe no activation.
      replay = waitUntil(() => item.faux.state.callCount > providerCallsBefore)
        .then(() => stream(...args))
        .then((value) => value.result())
        .then((message) => message.errorMessage ?? "accepted", String)
        .finally(() => releaseProvider?.());
      return result;
    };
    item.faux.setResponses([async (context) => {
      await providerGate;
      return item.response("real stream response")(context);
    }]);
    await item.slot.prompt("C17 input");
    await waitUntil(() => !item.slot.isBusy);
    const row = { contextCalls, replay: await replay, calls: item.faux.state.callCount, refusal: item.policy()!.refusalLog().at(-1)?.reason };
    item.record("C17", row);
    expect(contextCalls).toBe(1);
    expect(row.refusal).toBe("stream-replayed");
    expect(row.replay).toContain("Home request refused");
    expect(row.calls).toBe(1);
    expect(await item.jsonl()).toContain("real stream response");
  }, 30_000);

  it("Home structurally omits MCP because Pi 1.0.4 non-MCP allowlists do not exclude it", async () => {
    const item = await open("mcp", { home: true, memory: true });
    const ordinary = await item.extra("ordinary-mcp");
    const homeExtensions = item.session.resourceLoader.getExtensions().extensions.map((extension) => extension.path);
    const context = await ordinary.slot.context() as unknown as { extensions: Array<{ name: string }> };
    const ordinaryExtensions = context.extensions.map((extension) => extension.name);
    // Test the runtime registration boundary: an empty mcp__ tool set would be
    // inconclusive when the ordinary runtime has no configured MCP server.
    item.record("MCP", { homeExtensions, ordinaryExtensions });
    expect(ordinaryExtensions).toContain("builtin:mcp");
    expect(homeExtensions).not.toContain("builtin:mcp");
  }, 30_000);

  it("D3 assistant tool call is durable before the SDK executes the tool", async () => {
    let persisted: unknown[] = [];
    let toolCalls = 0;
    const item = await open("d3", { home: true, memory: true, extension: (pi) => {
      pi.on("tool_call", async (_event, ctx) => {
        toolCalls += 1;
        persisted = await readEntries(ctx.sessionManager.getSessionFile());
      });
    } });
    item.faux.setResponses([
      async () => fauxAssistantMessage(fauxToolCall("date", { id: 0 })),
      item.response("after date"),
    ]);
    await item.slot.prompt("D3 use date");
    await waitUntil(() => !item.slot.isBusy);
    const messages = (persisted as Array<{ message?: { role: string; content: unknown } }>).flatMap((entry) => entry.message ?? []);
    item.record("D3", { toolCalls, rolesAtToolCall: messages.map((m) => m.role) });
    expect(toolCalls).toBe(1);
    expect(messages.at(-1)?.role).toBe("assistant");
    expect(JSON.stringify(messages.at(-1)?.content)).toContain('"name":"date"');
    expect(messages.some((m) => m.role === "toolResult")).toBe(false);
  }, 30_000);

  it("usage measures canonical history rather than Home's reduced request", async () => {
    let tokens = 0;
    let request = "";
    const item = await open("usage", { home: true, memory: true, extension: (pi) => {
      pi.on("context", (event, ctx) => {
        tokens = ctx.getContextUsage()?.tokens ?? 0;
        request = JSON.stringify(event.messages);
      });
    } });
    // No assistant usage exists: Pi must estimate the canonical projection,
    // including this historical entry that Home excludes from this activation.
    item.session.sessionManager.appendMessage({ role: "user", content: "CANONICAL-ONLY " + "x".repeat(100_000), timestamp: 0 });
    item.faux.setResponses([item.response("usage response")]);
    await item.slot.prompt("usage current input");
    await waitUntil(() => !item.slot.isBusy);
    item.record("usage", { tokens, requestBytes: request.length });
    expect(item.faux.state.callCount).toBe(1);
    expect(request).not.toContain("CANONICAL-ONLY");
    expect(tokens).toBeGreaterThan(25_000);
    expect(request.length).toBeLessThan(30_000);
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
      viewUnbuilt: (await item.memoryStatus()).episodic?.view.unbuilt ?? -1,
      requestsBefore: item.requests.length,
    });
    expect(item.requests.length).toBe(1);
    const second = item.slot.prompt(longInput("C18 second activation input"));
    // The activation is admitted, and Pi is running it, but no request may be
    // sent while the lines it would carry are unbuilt.
    await waitUntil(() => item.policy()?.currentOperationId() !== undefined);
    await waitUntil(async () => ((await item.memoryStatus()).episodic?.coverage.summarized ?? 0) === 0);
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

  it("C19 refuses a request that is not the projection without spending the memory wait", async () => {
    // The projection, and the proof that the request is exactly it, come before
    // the memory wait: a request some other `prepareRequest` rewrite changed is a
    // refusal, not something to spend a multi-second wait on. The discriminator is
    // the wait itself — the compactor is parked, so a refusal that happened after
    // the wait could never be observed here — and the record of whether the wait
    // was even entered.
    const item = await open("c19", { home: true, memory: true, heldSummarizer: true });
    item.faux.setResponses([item.response("C19 prior reply")]);
    await item.slot.prompt(longInput("C19 prior activation"));
    await waitUntil(() => !item.slot.isBusy);
    await waitUntil(() => item.compactor.entered > 0);
    const enteredBefore = item.compactor.entered;

    const policy = item.policy()!;
    policy.admit("c19", item.session.sessionManager.getLeafId() ?? null);
    const prepared = policy.wrapPrepareRequest(item.session, undefined);
    const projection = item.session.sessionManager.buildSessionProjection();
    const extra = { role: "user", content: "NOT-THE-PROJECTION", timestamp: 0 } as unknown as AgentMessage;
    const outcome = await Promise.resolve(
      prepared({ context: { messages: [...projection.messages, extra] }, model: item.faux.getModel(), thinkingLevel: "off" }, undefined),
    ).then(() => "accepted", (error: unknown) => `refused: ${error instanceof Error ? error.message : String(error)}`);
    const row = {
      outcome,
      refusalReason: policy.refusalLog().at(-1)?.reason ?? null,
      enteredDuringRefusal: item.compactor.entered - enteredBefore,
    };
    policy.settle("c19");
    item.compactor.release?.();
    item.record("C19", row);
    expect(row.outcome).toContain("refused");
    expect(row.refusalReason).toBe("projection-mismatch");
    // No wait was entered: the refusal is decided before it.
    expect(row.enteredDuringRefusal).toBe(0);
  }, 15_000);

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
    await item.registry.homeOwner().configureMemory({ model: MEMORY_MODEL });
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
