/**
 * Manage Home → Memory at a real Home's scale (#940): three chapters, 1200+
 * messages and tens of megabytes of canonical JSONL, built through the real
 * RuntimeRegistry and Gateway RPC surface with a faux compactor.
 *
 * The browser's reads are disposable and the Gateway cancels them after
 * DISPOSABLE_READ_DEADLINE_MS (5000 ms). This journey measures the CPU work of the
 * first page, paging, a chapter scope, a part (zoom) and an evidence read, and proves the
 * answers equal the ones a read that proves all history from its first byte gives.
 *
 * Retained artifact: `test-results/home-memory-browser-scale/report.json`, including the last browser phase and safe failure category when a read refuses.
 */
import { mkdir, mkdtemp, rm, stat, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { performance } from "node:perf_hooks";
import { ModelRuntime } from "@earendil-works/pi-coding-agent";
import { fauxAssistantMessage, fauxProvider } from "@earendil-works/pi-ai";
import { afterAll, describe, expect, it } from "vitest";
import { homeMemoryChange } from "../../test-support/chat-settings-change.js";
import { settingsDependencies } from "../../test-support/settings-dependencies.js";
import { waitFor } from "../../test-support/wait-for.js";
import { TrustService } from "../admin/trust-service.js";
import type { EpisodicSummarizer } from "../episodic/episodic-contract.js";
import { HomeSourceProofs } from "../episodic/home-source.js";
import type { HomeMemoryEvidencePage, HomeMemoryView, HomeStatus } from "../protocol/types.js";
import type { GatewayConfig } from "../config.js";
import { CommandReceiptStore } from "../transport/command-receipts.js";
import { GatewayService, type ClientContext, type GatewayServiceDependencies } from "../transport/gateway-service.js";
import { RuntimeRegistry } from "./runtime-registry.js";

const PROVIDER = "tron-home-scale";
const MODEL = { provider: PROVIDER, id: "chat" };
const MEMORY_MODEL = { provider: `${PROVIDER}-memory`, id: "compactor" };
const REPORT_PATH = "test-results/home-memory-browser-scale/report.json";
/** The Gateway's disposable-read deadline (transport/server.ts). */
const DEADLINE_MS = 5_000;
/** Each warm browser read must answer within a fifth of the deadline. */
const BUDGET_MS = DEADLINE_MS / 5;
const CHAPTERS = 3;
/** Appended per chapter; with each chapter's opening prompt/reply, 1200+ messages. */
const MESSAGES_PER_CHAPTER = 405;
const client = { id: "scale", identity: "device:home-scale", isLocal: false, unsubscribe: () => {} } as unknown as ClientContext;

const report: Record<string, unknown> = { generatedAt: new Date().toISOString() };
let currentStage = "setup";
function markStage(stage: string): void {
  currentStage = stage;
  report.stage = stage;
}
afterAll(async () => {
  await mkdir(join(process.cwd(), "test-results", "home-memory-browser-scale"), { recursive: true });
  await writeFile(join(process.cwd(), REPORT_PATH), `${JSON.stringify(report, null, 2)}\n`);
});

/** Summaries near the node bound, like a real Home's. */
const summarizer: EpisodicSummarizer = async request => fauxAssistantMessage(
  `SCALE-SUMMARY ${request.turns.length} ${"recalled detail about earlier Home work ".repeat(11)}`.slice(0, 480));

interface Gateway { registry: RuntimeRegistry; service: GatewayService; receipts: CommandReceiptStore }

function openGateway(root: string, runtime: ModelRuntime): Gateway {
  const agentDir = join(root, "agent");
  const tronHome = join(root, "tron");
  const registry = new RuntimeRegistry({
    agentDir, tronHome, idleRuntimeMs: 600_000,
    modelRuntimeFactory: async () => runtime,
    trust: new TrustService(agentDir),
    broadcast: () => {}, sessionSummaryChanged: () => {}, sessionListChanged: () => {},
    homeMemorySummarizer: () => ({ summarizer }),
  });
  const receipts = new CommandReceiptStore(join(tronHome, "receipts"));
  const service = new GatewayService({
    config: { tronHome } as unknown as GatewayConfig,
    modelRuntime: runtime, sessions: registry, home: registry.homeOwner(), receipts, broadcast: () => {},
    ...settingsDependencies({ agentDir, tronHome, trust: new TrustService(agentDir), modelRuntime: runtime, sessions: registry, home: () => registry.homeOwner() }),
    trust: new TrustService(agentDir), sessionDeleted: () => {},
    uploads: { acquire: async () => ({ release: () => {} }), materialize: async () => ({ envelope: "", images: [], attachments: [], photoCount: 0, fileAttachmentCount: 0 }), removeSession: async () => {} },
  } as unknown as GatewayServiceDependencies);
  return { registry, service, receipts };
}

async function closeGateway(gateway: Gateway): Promise<void> {
  await gateway.service.dispose();
  await gateway.receipts.dispose();
  await gateway.registry.dispose();
}

const status = async (g: Gateway) => await g.service.invoke(client, "home.status", {}) as unknown as HomeStatus;
const view = async (g: Gateway, params: Record<string, unknown>) => await g.service.invoke(client, "home.memory.view", params) as unknown as HomeMemoryView;

/** A read's cost is the CPU time the Gateway's thread spends answering it. That is
 * the read's own work: host load deschedules the thread and stretches wall time, but
 * not this, so the budget and the warm-versus-full-proof ratio judge the read rather
 * than the host (#1051). Memory is frozen before the timed reads, so nothing else
 * runs on this thread meanwhile. */
async function timedRead<T>(read: () => Promise<T>): Promise<{ value: T; ms: number }> {
  const cpu = process.threadCpuUsage();
  const value = await read();
  const used = process.threadCpuUsage(cpu);
  return { value, ms: Math.round((used.user + used.system) / 100) / 10 };
}

/** Deterministic, varied canonical content: a real Home's tool results dominate its bytes. */
function appendHistory(slot: Awaited<ReturnType<RuntimeRegistry["acquire"]>>, chapter: number): void {
  for (let index = 0; index < MESSAGES_PER_CHAPTER; index += 1) {
    const tag = `c${chapter}-m${index}`;
    const at = Date.now();
    if (index % 3 === 0) {
      slot.sessionManager.appendMessage({ role: "user", content: `${tag} please look at item ${index} ${"and then report back ".repeat(20)}`, timestamp: at });
    } else if (index % 3 === 1) {
      slot.sessionManager.appendMessage({ ...fauxAssistantMessage(`${tag} here is what I found ${"careful reasoning about the result ".repeat(60)}`), timestamp: at });
    } else {
      slot.sessionManager.appendMessage({ role: "toolResult", toolCallId: `call-${tag}`, toolName: "read",
        content: [{ type: "text", text: `${tag} ${`line ${index} of a long file with content `.repeat(4_500)}` }], isError: false, timestamp: at });
    }
  }
}

describe("Home memory browser at scale", () => {
  it("answers first page, paging, chapter scope, zoom and evidence well under the read deadline", { timeout: 600_000 }, async () => {
    const root = await mkdtemp(join(tmpdir(), "tron-home-scale-"));
    const agentDir = join(root, "agent");
    await mkdir(agentDir, { recursive: true });
    await writeFile(join(agentDir, "settings.json"), JSON.stringify({ defaultProvider: PROVIDER, defaultModel: MODEL.id }));
    const faux = fauxProvider({ provider: PROVIDER, models: [{ id: MODEL.id, reasoning: true }], tokensPerSecond: 1_000_000, tokenSize: { min: 10, max: 10 } });
    const memoryFaux = fauxProvider({ provider: MEMORY_MODEL.provider, models: [{ id: MEMORY_MODEL.id, reasoning: false }] });
    const runtime = await ModelRuntime.create({ authPath: join(root, "auth.json"), modelsPath: null, refreshOnCreate: false });
    runtime.registerNativeProvider(faux.provider);
    runtime.registerNativeProvider(memoryFaux.provider);
    let g = openGateway(root, runtime);
    try {
      await g.registry.initialize();
      const buildStarted = performance.now();
      await g.service.invoke(client, "home.designate", { commandId: "scale-designate", model: MODEL });
      await g.service.invoke(client, "settings.change", homeMemoryChange({ commandId: "scale-memory", model: MEMORY_MODEL }));
      const chapterIds: string[] = [];
      for (let chapter = 1; chapter <= CHAPTERS; chapter += 1) {
        if (chapter === 1) {
          const slot = await g.registry.acquire((await status(g)).sessionId!);
          faux.setResponses([fauxAssistantMessage("first chapter reply")]);
          await slot.prompt("first chapter opening");
          await waitFor(() => !slot.isBusy || undefined, "first chapter turn");
          await g.service.invoke(client, "home.pauseMemory", { commandId: "scale-pause" });
        } else {
          // Seal the previous chapter as the size rollover would; paused memory
          // still materializes the next chapter without dispatching a turn.
          const owner = g.registry.homeOwner() as unknown as {
            options: { sessions: { chapterMetrics: (id: string) => Promise<{ bytes: number; entries: number; quiescent: boolean }> } };
            chapterQuiescent(id: string): Promise<void>;
          };
          const metrics = owner.options.sessions.chapterMetrics;
          owner.options.sessions.chapterMetrics = async () => ({ bytes: 24 * 1_024 * 1_024 + 1, entries: 3, quiescent: true });
          try { await owner.chapterQuiescent(chapterIds.at(-1)!); } finally { owner.options.sessions.chapterMetrics = metrics; }
          await g.service.invoke(client, "home.prompt", { commandId: `scale-open-${chapter}`, text: `chapter ${chapter} opening` });
          await waitFor(async () => (await status(g)).chapter?.recoveryDecision === "none" || undefined, `chapter ${chapter} materialized`);
        }
        const slot = await g.registry.acquire((await status(g)).sessionId!);
        await waitFor(() => !slot.isBusy || undefined, `chapter ${chapter} idle`);
        appendHistory(slot, chapter);
        chapterIds.push(slot.id);
      }
      expect(new Set(chapterIds).size).toBe(CHAPTERS);
      await g.service.invoke(client, "home.resumeMemory", { commandId: "scale-resume" });
      await waitFor(async () => {
        const episodic = (await status(g)).memory.episodic;
        return (episodic && episodic.pump.busy === 0 && episodic.view.unbuilt === 0) || undefined;
      }, "summaries built", { boundMs: 480_000 });
      await g.service.invoke(client, "home.pauseMemory", { commandId: "scale-freeze" });
      const sourceBytes = (await Promise.all(chapterIds.map(async id => (await stat((await g.registry.acquire(id)).sessionFile!)).size))).reduce((a, b) => a + b, 0);
      const buildMs = Math.round(performance.now() - buildStarted);

      // ---- timed reads, as the browser issues them --------------------------------
      // `fresh` drops the owner's chapter proofs before each read: every read then
      // proves all of Home's history from its first byte, as before #940.
      const reads = async (gateway: Gateway, fresh = false, label = "read") => {
        const timed = async <T>(stage: string, read: () => Promise<T>) => {
          markStage(stage);
          if (fresh) (gateway.registry.homeOwner() as unknown as { memory: { proofs: HomeSourceProofs } }).memory.proofs = new HomeSourceProofs();
          try {
            const result = await timedRead(read);
            report.lastCompletedStage = currentStage;
            return result;
          } catch (error) {
            report.failedStage = currentStage;
            const candidate = error as { code?: unknown; details?: { reason?: unknown; cause?: unknown } };
            report.failedCode = candidate.code;
            report.failedReason = candidate.details?.reason;
            report.failedCause = candidate.details?.cause;
            throw error;
          }
        };
        const first = await timed(`${label}: first page`, () => view(gateway, { limit: 30 }));
        const pages = [first.value];
        const pageMs = [first.ms];
        for (let next = first.value.nextCursor; next && pages.length < 6;) {
          const page = await timed(`${label}: continuation ${pages.length + 1}`, () => view(gateway, { limit: 30, cursor: next }));
          pages.push(page.value); pageMs.push(page.ms); next = page.value.nextCursor;
        }
        const chapter = await timed(`${label}: chapter scope`, () => view(gateway, { limit: 30, sessionId: chapterIds[1] }));
        const zoomLine = pages.flatMap(page => page.lines).find(line => line.span >= 2)!;
        const part = await timed(`${label}: zoom part`, () => view(gateway, { part: { start: zoomLine.start, span: zoomLine.span } }));
        const item = pages.flatMap(page => page.lines).find(line => line.item)!.item!;
        const evidence = await timed(`${label}: evidence`, async () => await gateway.service.invoke(client, "home.memory.evidence", { evidence: item.evidence, offset: 0 }) as unknown as HomeMemoryEvidencePage);
        return {
          values: { pages, chapter: chapter.value, part: part.value, evidence: evidence.value },
          ms: { firstPage: first.ms, pages: pageMs, chapter: chapter.ms, part: part.ms, evidence: evidence.ms },
        };
      };
      const warm = await reads(g, false, "warm"); // Ingested already; this is the browser's steady state.
      const again = await reads(g, false, "repeat");         // Repeat: identical answers, steady-state timings.
      expect(again.values).toEqual(warm.values);

      const beforeRestart = warm.values.pages;
      expect(beforeRestart).toHaveLength(6);
      expect(beforeRestart.flatMap(page => page.lines).some(line => line.start === 1120 && line.span === 2)).toBe(true);

      // A real Gateway close/reopen reloads the durable episodic journal and
      // folds the persisted summaries into its view again. Keep the old cursor
      // and compare all six pages, including the known 1120+2 decomposition.
      markStage("close old Gateway");
      await closeGateway(g);
      markStage("open restarted Gateway");
      g = openGateway(root, runtime);
      await g.registry.initialize();
      const afterRestart = await reads(g, false, "after restart");
      const afterPages = afterRestart.values.pages;
      expect(afterPages).toHaveLength(6);
      const beforeParts = beforeRestart.flatMap(page => page.lines).map(({ start, span }) => [start, span]);
      const afterParts = afterPages.flatMap(page => page.lines).map(({ start, span }) => [start, span]);
      const decompositionChanged = JSON.stringify(beforeParts) !== JSON.stringify(afterParts);
      expect(afterPages.flatMap(page => page.lines).some(line => line.start === 1120 && line.span === 1)).toBe(true);
      expect(afterPages.flatMap(page => page.lines).some(line => line.start === 1121 && line.span === 1)).toBe(true);
      expect(afterPages[0]!.revision === beforeRestart[0]!.revision).toBe(!decompositionChanged);
      if (decompositionChanged) {
        markStage("verify stale pre-restart cursor refusal");
        await expect(view(g, { limit: 30, cursor: beforeRestart[0]!.nextCursor })).rejects.toMatchObject({ code: "conflict" });
      } else {
        markStage("verify unchanged cursor continuation");
        const continued = await view(g, { limit: 30, cursor: beforeRestart[0]!.nextCursor });
        expect(continued).toEqual(beforeRestart[1]);
      }

      const first = afterRestart.values.pages[0]!;
      expect(first.totalMessages).toBeGreaterThanOrEqual(1200);
      expect(first.lines.length).toBeGreaterThan(0);
      expect(first.lines.map(line => line.start)).toEqual([...first.lines.map(line => line.start)].sort((a, b) => b - a));
      expect(first.lines.some(line => line.text?.includes("SCALE-SUMMARY"))).toBe(true);
      expect(warm.values.chapter.lines.every(line => !line.item || line.item.evidence.sessionId === chapterIds[1])).toBe(true);
      expect(warm.values.chapter.totalMessages).toBeLessThan(first.totalMessages);
      expect(warm.values.part.lines).toHaveLength(2);

      // ---- old path: every read proves all chapters from their first byte ------
      const full = await reads(g, true, "cold full proof after restart");
      expect(full.values).toEqual(afterRestart.values);

      // A cold proof the deadline cancels still completes for the retry (Reload).
      (g.registry.homeOwner() as unknown as { memory: { proofs: HomeSourceProofs } }).memory.proofs = new HomeSourceProofs();
      markStage("cancelled cold proof request");
      const cancelled = new AbortController();
      const shed = g.service.invoke({ ...client, signal: cancelled.signal }, "home.memory.view", { limit: 30 }).then(() => undefined, error => error);
      setTimeout(() => cancelled.abort(new Error("deadline")), 5);
      expect(await shed).toBeDefined();
      markStage("retry after cancelled cold proof");
      const retry = await timedRead(() => view(g, { limit: 30 }));
      expect(retry.value).toEqual(first);
      const afterRetry = await timedRead(() => view(g, { limit: 30 }));

      // A live turn appends to the active chapter: reads extend its proof by the
      // new bytes only. Navigation is not an append and re-proves the chapter.
      const dropProofs = () => { (g.registry.homeOwner() as unknown as { memory: { proofs: HomeSourceProofs } }).memory.proofs = new HomeSourceProofs(); };
      const active = await g.registry.acquire(chapterIds[2]!);
      for (let index = 0; index < 4; index += 1) {
        active.sessionManager.appendMessage({ role: "user", content: `live turn input ${index} ${"while the browser is open ".repeat(30)}`, timestamp: Date.now() });
      }
      markStage("view after live append");
      const appended = await timedRead(() => view(g, { limit: 30 }));
      expect(appended.value.totalMessages).toBe(first.totalMessages + 4);
      dropProofs();
      markStage("reprove after append");
      expect(await view(g, { limit: 30 })).toEqual(appended.value);
      const branchFrom = first.lines.flatMap(line => line.item ? [line.item] : []).find(item => item.evidence.sessionId === chapterIds[2])!;
      active.sessionManager.branch(branchFrom.evidence.entryId);
      active.sessionManager.appendMessage({ role: "user", content: "a navigated branch", timestamp: Date.now() });
      markStage("view after session navigation");
      const navigated = await view(g, { limit: 30 });
      expect(navigated.lines.some(line => line.item?.projection.omitted)).toBe(true);
      dropProofs();
      markStage("reprove after navigation");
      expect(await view(g, { limit: 30 })).toEqual(navigated);

      // A start without its durable catalog document (the first start after an upgrade, or
      // a corrupt document) publishes its first catalog cut only after reconciling the
      // folder. A browser read that arrives first must wait for that cut: it read the
      // missing cut as a sealed chapter with no file and refused the read (#968).
      const beforeColdCatalog = await view(g, { limit: 30 });
      markStage("close for a restart without the catalog document");
      await closeGateway(g);
      await rm(join(root, "tron", "gateway", "catalog-metadata-v2.json"));
      g = openGateway(root, runtime);
      await g.registry.initialize();
      const cutBeforeRead = (g.registry as unknown as { sessionCatalog: { hasCompleteCut(): boolean } }).sessionCatalog.hasCompleteCut();
      markStage("restart without the catalog document: first page");
      const coldCatalog = await view(g, { limit: 30 });
      report.coldCatalogRestart = { cutBeforeRead };
      expect(coldCatalog.totalMessages).toBe(beforeColdCatalog.totalMessages);
      expect(coldCatalog.lines.map(line => line.start)).toEqual(beforeColdCatalog.lines.map(line => line.start));

      const steady = [again.ms.firstPage, ...again.ms.pages, again.ms.chapter, again.ms.part, again.ms.evidence, afterRetry.ms, appended.ms];
      Object.assign(report, {
        chapters: CHAPTERS, totalMessages: first.totalMessages, sourceBytes, buildMs,
        restart: { beforeRevision: beforeRestart[0]!.revision, afterRevision: afterPages[0]!.revision,
          decompositionChanged, pagesCompared: beforeRestart.length, oldCursorRejected: decompositionChanged },
        budgetMs: BUDGET_MS, deadlineMs: DEADLINE_MS, readCost: "Gateway thread CPU ms per read",
        firstReads: warm.ms, steady: again.ms, fullProofPerRead: full.ms, retryAfterCancelledColdProof: retry.ms, afterLiveAppend: appended.ms, steadyMaxMs: Math.max(...steady),
      });
      process.stdout.write(`home-memory-browser-scale: ${JSON.stringify(report)}\n`);
      for (const ms of steady) expect(ms).toBeLessThan(BUDGET_MS);
      // Load-independent scaling check, both sides measured in this run: a warm read
      // must not cost what proving all history costs (the pre-#940 per-read cost).
      const median = (values: number[]) => [...values].sort((x, y) => x - y)[Math.floor(values.length / 2)]!;
      const fullProof = [full.ms.firstPage, ...full.ms.pages, full.ms.chapter, full.ms.part, full.ms.evidence];
      expect(median(steady) * 10).toBeLessThan(median(fullProof));
    } catch (error) {
      const candidate = error as { code?: unknown; details?: { reason?: unknown; cause?: unknown } };
      report.failure = {
        stage: currentStage,
        type: error instanceof Error ? error.constructor.name : typeof error,
        ...(candidate.code !== undefined ? { code: candidate.code } : {}),
        ...(candidate.details?.reason !== undefined ? { reason: candidate.details.reason } : {}),
        ...(candidate.details?.cause !== undefined ? { cause: candidate.details.cause } : {}),
      };
      throw error;
    } finally {
      await closeGateway(g).catch(() => {});
      await rm(root, { recursive: true, force: true });
    }
  });
});
