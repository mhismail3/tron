import { ProcessTranscriptLeaseStore } from "../transport/process-transcript-leases.js";
import { DEFAULT_MAX_LIVE_RUNTIMES } from "../config.js";
import { randomUUID } from "node:crypto";
import { spawn } from "node:child_process";
import { performance as nodePerformance } from "node:perf_hooks";
import { sealBrowserToolReference } from "../display/browser-tool-reference.js";
import type { DisplayArtifactStore } from "../display/display-artifact-store.js";
import * as fsPromises from "node:fs/promises";
import { appendFileSync, existsSync } from "node:fs";
import { appendFile, copyFile, mkdtemp, mkdir, readFile, readdir, realpath, rename, rm, symlink, truncate, writeFile } from "node:fs/promises";
import { homedir, tmpdir } from "node:os";
import { basename, dirname, join, relative, resolve } from "node:path";
import { AsyncLocalStorage } from "node:async_hooks";
import { fileURLToPath } from "node:url";
import { ModelRuntime, SessionManager } from "@earendil-works/pi-coding-agent";
import { contentText, fauxAssistantMessage, fauxProvider, fauxToolCall, type ImageContent, type TranscriptContext } from "@earendil-works/pi-ai";
import { afterAll, afterEach, describe, expect, it, onTestFinished, vi } from "vitest";
import { TrustService } from "../admin/trust-service.js";
import { SessionListPaginationStore } from "../transport/session-list-pagination.js";
import { admitsAutomationAction } from "../automations/automation-contract.js";
import { GatewayAutomationExecutor } from "../automations/automation-executor.js";
import { OwnedSessionDispatch, OWNED_OPERATION_DEADLINE_MS } from "./owned-session-dispatch.js";
import type { AutomationExecutionHandle } from "../automations/automation-scheduler.js";
import type { AutomationRecord, AutomationRun } from "../automations/types.js";
import type { NotificationService } from "../notifications/notification-service.js";
import type { ExtensionRunActivity, ExtensionToolOrigin, SessionSummaryUpdate } from "../protocol/types.js";
import { GatewayWorkRegistry, type GatewayWorkHandle } from "./gateway-work-registry.js";
import { RequestSpan, runInRequestSpan, stage } from "../transport/request-span.js";
import type { ResourceRecorder } from "../transport/stall-diagnostics.js";
import { CatalogDiscovery, DEFAULT_CATALOG_DISCOVERY_LIMITS, buildCatalogSessionInfo, type CatalogSessionInfo } from "./catalog-discovery.js";
import { CatalogMetadataIndex } from "./catalog-metadata-index.js";
import { CATALOG_EVENT_DEBOUNCE_MS, type SessionCatalog, type SessionCatalogOptions, type SessionCatalogReconcileOutcome, type SessionCatalogWatchRequest } from "./session-catalog.js";
import { INVOCATION_RECEIPT_TYPE, makeInvocationReceipt } from "./invocation-receipts.js";
import { EXTENSION_ACTIVITY_RECEIPT_TYPE, MAX_EXTENSION_HISTORY_BYTES, type ExtensionActivityReceipt } from "./extension-activity-history.js";
import {
  HEAP_REFUSAL_RETRY_AFTER_MS,
  LIVE_RUNTIME_HEAP_ESTIMATE_FACTOR,
  RuntimeRegistry,
  type CapacityShedRecord,
  type ExtensionArtifactDiscoveryCounts,
  type RuntimeLifecycleRecord,
} from "./runtime-registry.js";
import { RuntimeSlot } from "./runtime-slot.js";
import { invocationReceipts } from "./invocation-receipts.js";
import { KnowledgeStore } from "../knowledge/knowledge-store.js";
import { KnowledgeService } from "../knowledge/knowledge-service.js";
import { observationEntriesDigest, type KnowledgeObservationService } from "../knowledge/knowledge-observation.js";
import { RunMarkerCompletionConflictError, type RunMarkerStore } from "./run-markers.js";
import { toolSegmentId } from "./projection.js";
import { AutomationService } from "../automations/automation-service.js";
import { pngDimensions } from "../../test-fixtures/pi-sdk/computer-use-image.js";
import { syntheticPng } from "../../test-fixtures/synthetic-image.js";
import { waitFor } from "../../test-support/wait-for.js";

/** Test-owned producer for one deterministic status.json replacement.
 *
 * `openOwnedExtensionArtifact` (runtime-slot) opens the artifact and then
 * verifies that the inode it opened is the one it stats; a producer that
 * atomically renames a new file over `status.json` in that window makes the
 * read lose, which is the race "retries a status.json read that raced an atomic
 * replacement" is about. Racing a real producer loop for that window made the
 * case load-dependent (#430: its sample-size guard was a speed budget), so the
 * `open` wrapper below performs exactly one real write+rename inside that
 * window instead. `vi.mock` factories are hoisted, so their state lives here. */
const statusJsonReplace = vi.hoisted(() => ({
  /** Armed only by the case that injects the replacement. */
  armed: false,
  /** Real replacements performed, and the reads they made lose. */
  replacements: 0,
  losses: 0,
  payload: "",
  statusPath: "",
  tempPath: "",
  /** True only inside the read-with-retry invocation under observation. */
  insideRetryInvocation: (): boolean => false,
}));

vi.mock("node:fs/promises", async (importOriginal) => {
  const actual = await importOriginal<typeof import("node:fs/promises")>();
  return {
    ...actual,
    open: async (path: Parameters<typeof actual.open>[0], ...rest: unknown[]) => {
      const handle = await (actual.open as unknown as (target: unknown, ...args: unknown[]) => Promise<unknown>)(path, ...rest);
      if (statusJsonReplace.armed && statusJsonReplace.losses === 0
        && statusJsonReplace.insideRetryInvocation() && String(path) === statusJsonReplace.statusPath) {
        statusJsonReplace.losses += 1;
        await actual.writeFile(statusJsonReplace.tempPath, statusJsonReplace.payload);
        await actual.rename(statusJsonReplace.tempPath, statusJsonReplace.statusPath);
        statusJsonReplace.replacements += 1;
      }
      return handle;
    },
  };
});

async function collectStream(stream: NodeJS.ReadableStream): Promise<Buffer> {
  const chunks: Buffer[] = [];
  for await (const value of stream) chunks.push(Buffer.isBuffer(value) ? value : Buffer.from(value));
  return Buffer.concat(chunks);
}

/** A snapshot is built and broadcast only for a subscriber, so a test that reads
 * published snapshots has to be one. */
function subscribeAudience(registry: RuntimeRegistry, sessionId: string): void {
  registry.subscribe("test-audience", sessionId);
}

/** The catalog owner's whole-folder walk: the one seam that re-derives
 * membership from the folder. A read must add none — G-1c moved every reader
 * onto the owner's rows, and the O-5 counter counts walks here. */
function catalogWalks(): { count: () => number; restore: () => void } {
  const walk = vi.spyOn(CatalogDiscovery.prototype, "catalogStructureEvidence");
  return { count: () => walk.mock.calls.length, restore: () => walk.mockRestore() };
}

/** Every canonical file whose header the registry read while installed. The
 * commit fence may read the file it admits, and nothing else. */
function catalogHeaderReads(): { paths: () => string[]; restore: () => void } {
  const reads = vi.spyOn(CatalogDiscovery.prototype, "readCatalogHeader");
  return { paths: () => reads.mock.calls.map(([path]) => String(path)), restore: () => reads.mockRestore() };
}

/** Passes `discoverExtensionArtifactsUntil` may run before it stops on its own.
 * It only stops the loop: the caller's pass assertion is the bound, so a lagging
 * routing is reported as a pass count instead of a hang. It sits well above the
 * one pass the production code implies for the cases that assert a count. */
const DISCOVERY_PASS_LIMIT = 8;

/** Registry discovery is a bounded single owner: a call that arrives while a
 * pass is in flight returns without discovering anything, and the next scheduled
 * pass is up to 750 ms away. A test that asserts on an artifact must run a pass
 * of its own instead of treating the awaited call as a barrier; `settled` names
 * the state that pass must publish (T-1). This helper runs only its own passes
 * and reports how many, so a caller can assert the pass count the production code
 * implies instead of a wall-clock budget (epic #400): a loaded host stretches a
 * pass, which used to report a pass that was merely slow as one that would never
 * settle (T-6).
 *
 * `passLimit` only stops the loop; the caller's assertion is the bound. A pass
 * that never settles reports its own label at the shared hang bound. */
async function discoverExtensionArtifactsUntil(
  registry: RuntimeRegistry,
  settled: () => boolean = () => true,
  passLimit = DISCOVERY_PASS_LIMIT,
): Promise<number> {
  const state = registry as unknown as { artifactDiscoveryInFlight: boolean };
  let passes = 0;
  await waitFor(async () => {
    // A pass that is already in flight returns without discovering anything; let
    // it finish first (on the shared poll), so every pass counted here is one
    // this call ran, and a caller's pass assertion is about its own passes.
    if (state.artifactDiscoveryInFlight) return false;
    await (registry as unknown as { discoverExtensionArtifacts: () => Promise<void> }).discoverExtensionArtifacts();
    passes += 1;
    return settled() || passes >= passLimit;
  }, "extension artifact discovery to settle");
  return passes;
}

/** Initialize a registry and wait for the catalog owner's first published cut.
 * A read that lands before that cut refuses retryably (G-1c), and no reader
 * walks the folder any more, so a test lets the owner publish one first. */
async function initializeRegistry(
  registry: RuntimeRegistry,
  phaseObserver?: (phase: "catalog-warming" | "attention-recovery") => void,
): Promise<void> {
  await registry.initialize(phaseObserver);
  await catalogOwner(registry).whenPublished();
}

/** A test that writes canonical files itself is an external writer: the folder
 * watcher observes it, but no reader polls for it. Forcing one owner reconcile
 * is the deterministic equivalent of waiting the watcher out, and settling the
 * owner then makes its rows and the durable document current without waiting
 * out the persist debounce. */
async function settleCatalog(registry: RuntimeRegistry): Promise<void> {
  await catalogOwner(registry).reconcile();
  await catalogOwner(registry).settled();
}

/** The registry's catalog owner: the index every read path serves from (G-1c). */
function catalogOwner(registry: RuntimeRegistry): SessionCatalog {
  return (registry as unknown as { sessionCatalog: SessionCatalog }).sessionCatalog;
}

describe.sequential("RuntimeRegistry with the pinned agent runtime", () => {
  const previousAgentDir = process.env.PI_CODING_AGENT_DIR;
  const registries: RuntimeRegistry[] = [];
  const syntheticTranscriptSizes = new Map<string, number>();
  const ownedDeadlineReportCases: Array<Record<string, unknown>> = [];

  async function coldFixture(label: string, options: {
    nested?: boolean;
    name?: string;
    maximumLiveRuntimes?: number;
    catalogDiscoveryLimits?: { maximumHeaderBytes: number };
    workRegistry?: GatewayWorkRegistry;
    phaseObserver?: (phase: "catalog-warming" | "attention-recovery") => void;
    sessionListChanged?: () => void;
    catalogIndexFailure?: (stage: "save" | "rebuild" | "append", durationMs: number) => void;
    catalogReconciled?: (reconciled: SessionCatalogReconcileOutcome) => void;
    artifactDiscoveryTruncated?: (counts: ExtensionArtifactDiscoveryCounts) => void;
    runtimeDisposeTimeout?: (graceMs: number) => void;
    /** Admit one explicit delegated artifact root, as the production cutover
     * does, so ambient discovery scans exactly that root. */
    delegatedRoot?: string;
    beforeInitialize?: (sessionFile: string, registry: RuntimeRegistry) => Promise<void>;
    notifications?: NotificationService;
    resources?: ResourceRecorder;
    runtimeLifecycleRecord?: (record: RuntimeLifecycleRecord) => void;
    heapSample?: () => { usedBytes: number; limitBytes: number };
    capacityShedRecord?: (record: CapacityShedRecord) => void;
  } = {}) {
    const root = await mkdtemp(join(tmpdir(), `tron-cold-acquire-${label}-`));
    const agentDir = join(root, "agent");
    const cwd = join(root, "workspace");
    const sessionDirectory = options.nested
      ? join(agentDir, "sessions", "workspace", "child")
      : join(agentDir, "sessions", "workspace");
    await Promise.all([mkdir(sessionDirectory, { recursive: true }), mkdir(cwd, { recursive: true })]);
    process.env.PI_CODING_AGENT_DIR = agentDir;
    const manager = SessionManager.create(cwd, sessionDirectory);
    manager.appendMessage(fauxAssistantMessage(`cold acquisition ${label}`));
    if (options.name) manager.appendSessionInfo(options.name);
    const runtimeFactory = vi.fn(async () => ModelRuntime.create({ modelsPath: null, refreshOnCreate: false }));
    const events: Array<{ topic: string; payload: any }> = [];
    const summaries: SessionSummaryUpdate[] = [];
    const delegatedRoot = options.delegatedRoot;
    const registry = new RuntimeRegistry({
      agentDir,
      tronHome: join(root, "tron"),
      idleRuntimeMs: 60_000,
      maximumLiveRuntimes: options.maximumLiveRuntimes,
      catalogDiscoveryLimits: options.catalogDiscoveryLimits,
      workRegistry: options.workRegistry,
      modelRuntimeFactory: runtimeFactory,
      ...(delegatedRoot ? { delegatedArtifactRoot: delegatedRoot } : {}),
      ...(options.artifactDiscoveryTruncated ? { artifactDiscoveryTruncated: options.artifactDiscoveryTruncated } : {}),
      trust: new TrustService(agentDir),
      broadcast: (_sessionId, topic, payload) => events.push({ topic, payload }),
      sessionSummaryChanged: (summary) => summaries.push(summary),
      sessionListChanged: options.sessionListChanged ?? (() => {}),
      ...(options.notifications ? { notifications: options.notifications } : {}),
      ...(options.catalogIndexFailure ? { catalogIndexFailure: options.catalogIndexFailure } : {}),
      ...(options.catalogReconciled ? { catalogReconciled: options.catalogReconciled } : {}),
      ...(options.runtimeDisposeTimeout ? { runtimeDisposeTimeout: options.runtimeDisposeTimeout } : {}),
      ...(options.resources ? { resources: options.resources } : {}),
      ...(options.runtimeLifecycleRecord ? { runtimeLifecycleRecord: options.runtimeLifecycleRecord } : {}),
      ...(options.heapSample ? { heapSample: options.heapSample } : {}),
      ...(options.capacityShedRecord ? { capacityShedRecord: options.capacityShedRecord } : {}),
    });
    registries.push(registry);
    if (options.beforeInitialize) await options.beforeInitialize(manager.getSessionFile()!, registry);
    await initializeRegistry(registry, options.phaseObserver);
    await registry.recoverCanonicalAttention();
    return {
      root,
      delegatedRoot,
      agentDir,
      cwd,
      manager,
      registry,
      runtimeFactory,
      events,
      summaries,
      sessionFile: manager.getSessionFile()!,
    };
  }

  async function startOwnedOperation(slot: RuntimeSlot, registry: RuntimeRegistry, prompt: string) {
    const operationId = `task:deadline:${randomUUID()}`;
    let finish!: (value: unknown) => void;
    const completion = new Promise<unknown>((resolve) => { finish = resolve; });
    await slot.prompt(prompt, [], undefined, {
      text: prompt, attachmentEnvelope: "", attachmentCount: 0,
    }, undefined, {
      operationId,
      origin: { kind: "gateway", ownerId: "home-task-test", title: "Home task", confidence: "boundary" },
      onTerminal: (terminal) => { finish(terminal); },
    });
    return {
      operationId,
      handle: {
        operationId,
        completion,
        cancel: async () => slot.abort("agent", operationId),
        acknowledgeTerminal: async () => registry.clearOwnedOperationMarker(slot.id, operationId),
      },
    };
  }

  async function ownedDeadlineFixture(label: string, faux: ReturnType<typeof fauxProvider>) {
    const root = await mkdtemp(join(tmpdir(), `tron-owned-deadline-${label}-`));
    const agentDir = join(root, "agent");
    const cwd = join(root, "workspace");
    await Promise.all([mkdir(agentDir), mkdir(cwd)]);
    process.env.PI_CODING_AGENT_DIR = agentDir;
    const registry = new RuntimeRegistry({
      agentDir, tronHome: join(root, "tron"), idleRuntimeMs: 60_000,
      modelRuntimeFactory: async () => {
        const runtime = await ModelRuntime.create({ modelsPath: null, refreshOnCreate: false });
        runtime.registerNativeProvider(faux.provider);
        return runtime;
      },
      trust: new TrustService(agentDir), broadcast: () => {},
      sessionSummaryChanged: () => {}, sessionListChanged: () => {},
    });
    registries.push(registry);
    await initializeRegistry(registry);
    const slot = await registry.create(cwd);
    const model = faux.getModel();
    await slot.setModel(model.provider, model.id);
    return { root, cwd, registry, slot };
  }

  /** An admitted provider root with the private mode and canonical path the
   * slot's artifact policy requires; the caller removes `delegated.root`. */
  async function delegatedFixtureRoot(label: string): Promise<{ root: string; delegatedRoot: string }> {
    const root = await realpath(await mkdtemp(join(tmpdir(), `tron-delegated-${label}-`)));
    const delegatedRoot = join(root, "delegated");
    await mkdir(delegatedRoot, { recursive: true, mode: 0o700 });
    return { root, delegatedRoot };
  }

  afterAll(async () => {
    if (ownedDeadlineReportCases.length === 0) return;
    const directory = join(process.cwd(), "test-results", "owned-session-deadline");
    await mkdir(directory, { recursive: true });
    await writeFile(join(directory, "report.json"), `${JSON.stringify({
      cases: ownedDeadlineReportCases,
      generatedAt: new Date().toISOString(),
    }, null, 2)}\n`);
  });

  afterEach(async () => {
    try {
      const transcripts = [...syntheticTranscriptSizes];
      await Promise.all(transcripts.map(([path, size]) => truncate(path, size)));
      for (const [path, size] of transcripts) {
        expect((await fsPromises.stat(path)).size).toBe(size);
      }
      syntheticTranscriptSizes.clear();
    } finally {
      await Promise.all(registries.splice(0).map((registry) => registry.dispose()));
      if (previousAgentDir === undefined) delete process.env.PI_CODING_AGENT_DIR;
      else process.env.PI_CODING_AGENT_DIR = previousAgentDir;
    }
  });

  it("rejects malformed or incomplete cold JSONL before branch projection", async () => {
    const fixture = await coldFixture("strict-search-jsonl");
    const admitted = await (fixture.registry as any).catalogSnapshot("user");
    await appendFile(fixture.sessionFile, "{}\\n");
    vi.spyOn(fixture.registry as any, "catalogSnapshot").mockResolvedValue(admitted);
    await expect(fixture.registry.readSearchCut(fixture.manager.getSessionId())).rejects.toMatchObject({ code: "invalid_request" });
    await appendFile(fixture.sessionFile, "{}");
    await expect(fixture.registry.readSearchCut(fixture.manager.getSessionId())).rejects.toMatchObject({ code: "invalid_request" });
  });

  it("fences canonical history reads to the exact live runtime", async () => {
    const fixture = await coldFixture("canonical-history");
    try {
      const entry = fixture.manager.appendMessage({ role: "user", content: "Full selected message", timestamp: 1 });
      const slot = await fixture.registry.acquire(fixture.manager.getSessionId());
      const runtime = slot.snapshot().runtimeGeneration;
      // Acquiring the SDK runtime can append model/thinking metadata after the prompt.
      expect(slot.history(runtime).nodes.find(node => node.id === entry)).toMatchObject({ role: "user", preview: "Full selected message" });
      expect(slot.historyDetail(runtime, entry, 0).text).toBe("Full selected message");
      expect(() => slot.history("retired-runtime")).toThrow(/runtime changed/);
      expect(() => slot.historyDetail("retired-runtime", entry, 0)).toThrow(/runtime changed/);
    } finally {
      await fixture.registry.dispose();
      registries.splice(registries.indexOf(fixture.registry), 1);
      await rm(fixture.root, { recursive: true, force: true });
    }
  });

  it("pages canonical extension receipts through the live session history owner", async () => {
    const fixture = await coldFixture("extension-history-pages");
    try {
      const sessionId = fixture.manager.getSessionId();
      const receipt: ExtensionActivityReceipt = {
        version: 1, activityId: "activity", sessionId, toolCallId: "tool", source: "extension", state: "completed",
        startedAt: "2026-01-01T00:00:00.000Z", terminalAt: "2026-01-01T00:00:01.000Z", observedAt: "2026-01-01T00:00:01.000Z",
        summary: { children: Array.from({ length: 64 }, (_, index) => ({
          id: String(index).padEnd(256, "i"), label: "λ".repeat(128),
          producerId: "p".repeat(256), sessionOwnerId: "s".repeat(256), childSessionRef: "r".repeat(256),
          state: "completed", attention: "none",
        })) },
      };
      for (let index = 0; index < 5; index += 1) {
        fixture.manager.appendCustomEntry(EXTENSION_ACTIVITY_RECEIPT_TYPE, { ...receipt, activityId: `activity-${index}` });
      }
      // All fixture writes precede acquisition by the sole live runtime.
      const slot = await fixture.registry.acquire(sessionId);
      const ids: string[] = [];
      let cursor: string | undefined;
      for (let pageIndex = 0; pageIndex < 5; pageIndex += 1) {
        const page = slot.extensionActivityHistory(cursor, 50);
        expect(page.omissions).toBeUndefined();
        expect(page.activities.length).toBeGreaterThan(0);
        expect(Buffer.byteLength(JSON.stringify(page.activities))).toBeLessThanOrEqual(MAX_EXTENSION_HISTORY_BYTES);
        for (const row of page.activities) {
          ids.push(row.activityId!);
          expect(slot.extensionActivityDetail(row.activityId!, page.historyRevision)).toEqual(row);
        }
        cursor = page.nextCursor;
        if (!cursor) break;
      }
      expect(cursor).toBeUndefined();
      expect(ids).toEqual(["activity-4", "activity-3", "activity-2", "activity-1", "activity-0"]);
    } finally {
      await fixture.registry.dispose();
      registries.splice(registries.indexOf(fixture.registry), 1);
      await rm(fixture.root, { recursive: true, force: true });
    }
  });

  it("publishes startup phases in catalog-before-attention order", async () => {
    const phases: string[] = [];
    await coldFixture("startup-phases", {
      phaseObserver: (phase) => phases.push(phase),
    });
    expect(phases).toEqual(["catalog-warming", "attention-recovery"]);
  });

  it("charges a queued request for the registry lane wait and keeps its admitted work on its own span", async () => {
    const fixture = await coldFixture("span-lane-contention");
    let now = 0;
    const clock = vi.spyOn(nodePerformance, "now").mockImplementation(() => now);
    try {
      const lane = (fixture.registry as unknown as {
        mutex: { run<T>(operation: () => Promise<T> | T): Promise<T> };
      }).mutex;
      const holder = new RequestSpan();
      const waiter = new RequestSpan();
      let entered!: () => void;
      const admitted = new Promise<void>((resolve) => { entered = resolve; });
      let release!: () => void;
      const held = new Promise<void>((resolve) => { release = resolve; });
      const holding = runInRequestSpan(holder, () => lane.run(async () => {
        entered();
        await held;
        await stage("holder.work", () => { now += 10; return Promise.resolve(); });
      }));
      await admitted;
      // Queued behind the holder: its own span has to carry both the wait for
      // the lane and the work the lane then admits within its async context.
      const waiting = runInRequestSpan(waiter, () => lane.run(async () => {
        await stage("waiter.work", () => { now += 5; return Promise.resolve(); });
      }));
      now += 40;
      release();
      await Promise.all([holding, waiting]);

      // The wait covers the holder's 40 ms hold plus the 10 ms of work it did
      // before releasing; the holder was admitted immediately, so 0 ms is
      // dropped rather than named.
      expect(holder.breakdown(50)!.stages).toBe("holder.work=10ms");
      const queued = waiter.breakdown(55)!;
      expect(queued.stages).toBe("registry.mutex=50ms;waiter.work=5ms");
      expect(queued.unaccountedMs).toBe(0);
    } finally {
      clock.mockRestore();
      await fixture.registry.dispose();
      registries.splice(registries.indexOf(fixture.registry), 1);
      await rm(fixture.root, { recursive: true, force: true });
    }
  });

  it("owns one exact live session for a workspace Automation operation", async () => {
    const changed = vi.fn();
    const fixture = await coldFixture("automation-exact-session", { sessionListChanged: changed, maximumLiveRuntimes: 1 });
    const sessionId = "20000000-0000-4000-8000-000000000010";
    const operationId = "automation:20000000-0000-4000-8000-000000000011";
    const automationId = "20000000-0000-4000-8000-000000000013";

    const first = await fixture.registry.createAutomationSession(
      fixture.cwd,
      sessionId,
      operationId,
      automationId,
    );
    expect(first.slot.id).toBe(sessionId);
    expect((await fixture.registry.list("user")).find((session) => session.id === sessionId))
      .toMatchObject({ creationOrigin: { kind: "automation", automationId } });
    // Replaying the exact owner at capacity must not evict that owner first.
    (first.slot as unknown as { sessionManager: SessionManager }).sessionManager
      .appendMessage(fauxAssistantMessage("persisted automation"));
    first.release();
    const second = await fixture.registry.createAutomationSession(
      fixture.cwd,
      sessionId,
      operationId,
      automationId,
    );
    expect(second.slot === first.slot).toBe(true);
    await expect(fixture.registry.createAutomationSession(
      fixture.cwd,
      sessionId,
      "automation:20000000-0000-4000-8000-000000000012",
      automationId,
    )).rejects.toMatchObject({ code: "conflict" });

    second.release();
    expect(changed).toHaveBeenCalled();
  });

  it("recovers Automation session creation origin from the first canonical invocation binding", async () => {
    const fixture = await coldFixture("automation-cold-origin");
    const sessionId = "20000000-0000-4000-8000-000000000020";
    const automationId = "20000000-0000-4000-8000-000000000021";
    const invocationId = "20000000-0000-4000-8000-000000000022";
    const operationId = "automation:20000000-0000-4000-8000-000000000023";
    const generated = SessionManager.create(fixture.cwd, dirname(fixture.sessionFile), { id: sessionId });
    generated.appendCustomEntry(INVOCATION_RECEIPT_TYPE, makeInvocationReceipt({
      version: 1, receiptId: `start:${invocationId}`, receiptKind: "start", invocationId,
      operationId, sessionId, source: "plain", lifecycle: "staged",
      origin: { kind: "gateway", ownerId: automationId, title: "Automation", confidence: "boundary" },
      sequence: 1, createdAt: "2026-01-01T00:00:00.000Z",
    }));
    generated.appendCustomEntry(INVOCATION_RECEIPT_TYPE, makeInvocationReceipt({
      version: 1, receiptId: `accepted:${invocationId}`, receiptKind: "transition", invocationId,
      operationId, sessionId, source: "plain", lifecycle: "accepted",
      sequence: 2, createdAt: "2026-01-01T00:00:00.100Z",
    }));
    const user = generated.appendMessage({ role: "user", content: "scheduled prompt", timestamp: 1 });
    generated.appendCustomEntry(INVOCATION_RECEIPT_TYPE, makeInvocationReceipt({
      version: 1, receiptId: `binding:${invocationId}`, receiptKind: "binding", invocationId,
      operationId, sessionId, source: "plain", canonicalEntryId: user,
      sequence: 3, createdAt: "2026-01-01T00:00:00.200Z",
    }));
    generated.appendMessage(fauxAssistantMessage("completed Automation response"));
    generated.appendCustomEntry(INVOCATION_RECEIPT_TYPE, makeInvocationReceipt({
      version: 1, receiptId: `terminal:${invocationId}`, receiptKind: "terminal", invocationId,
      operationId, sessionId, source: "plain", lifecycle: "completed",
      sequence: 4, createdAt: "2026-01-01T00:00:00.300Z",
    }));

    await fixture.registry.dispose();
    registries.splice(registries.indexOf(fixture.registry), 1);
    const cold = new RuntimeRegistry({
      agentDir: fixture.agentDir,
      tronHome: join(fixture.root, "tron-cold"),
      idleRuntimeMs: 60_000,
      workRegistry: new GatewayWorkRegistry(),
      modelRuntimeFactory: async () => ModelRuntime.create({ modelsPath: null, refreshOnCreate: false }),
      trust: new TrustService(fixture.agentDir),
      broadcast: () => {},
      sessionSummaryChanged: () => {},
      sessionListChanged: () => {},
    });
    registries.push(cold);
    await initializeRegistry(cold);

    expect((await cold.list("user")).find((session) => session.id === sessionId))
      .toMatchObject({ creationOrigin: { kind: "automation", automationId } });
    // A user-scoped cut intentionally omits delegated metadata and is not an
    // all-scope durable-index candidate. An administrative read establishes the
    // complete sidecar used by the restart half of this regression.
    await cold.list("all");
    const indexPath = join(fixture.root, "tron-cold", "gateway", "catalog-metadata-v2.json");
    await settleCatalog(cold);
    expect(existsSync(indexPath)).toBe(true);
    await cold.dispose();
    registries.splice(registries.indexOf(cold), 1);

    const indexed = new RuntimeRegistry({
      agentDir: fixture.agentDir,
      tronHome: join(fixture.root, "tron-cold"),
      idleRuntimeMs: 60_000,
      workRegistry: new GatewayWorkRegistry(),
      modelRuntimeFactory: async () => ModelRuntime.create({ modelsPath: null, refreshOnCreate: false }),
      trust: new TrustService(fixture.agentDir),
      broadcast: () => {},
      sessionSummaryChanged: () => {},
      sessionListChanged: () => {},
    });
    registries.push(indexed);
    await initializeRegistry(indexed);
    // Settle the owner's own startup pass, so what the spy sees belongs to the
    // read under test.
    await settleCatalog(indexed);
    const walks = catalogWalks();
    expect((await indexed.list("user")).find((session) => session.id === sessionId))
      .toMatchObject({ creationOrigin: { kind: "automation", automationId } });
    // The origin comes from the owner's row; the read adds no walk.
    expect(walks.count()).toBe(0);
    walks.restore();
  });

  it("admits a page source after in-flight live summary churn", async () => {
    const fixture = await coldFixture("page-source-summary-churn");
    const internals = fixture.registry as unknown as {
      materializeCatalogSnapshot: () => Promise<unknown>;
      publishRevisionedSummary: (summary: SessionSummaryUpdate) => void;
    };
    const original = internals.materializeCatalogSnapshot.bind(fixture.registry);
    let entered!: () => void;
    let release!: () => void;
    const captured = new Promise<void>((resolve) => { entered = resolve; });
    const gate = new Promise<void>((resolve) => { release = resolve; });
    const materialize = vi.spyOn(internals, "materializeCatalogSnapshot").mockImplementation(async () => {
      const result = await original();
      entered();
      await gate;
      return result;
    });
    try {
      const listing = fixture.registry.pageSource("user");
      await captured;
      internals.publishRevisionedSummary({
        sessionId: fixture.manager.getSessionId(),
        summaryRevision: 1,
        phase: "running",
        updatedAt: new Date().toISOString(),
        messageCount: 1,
        firstMessage: "cold acquisition page-source-summary-churn",
        completionRevision: 0,
        attentionRevision: 0,
        isUnread: false,
      });
      release();
      const source = await listing;
      await expect(source.page(0, 1)).resolves.toMatchObject([
        expect.objectContaining({ id: fixture.manager.getSessionId(), phase: "running" }),
      ]);
    } finally {
      release();
      materialize.mockRestore();
    }
  });

  it("builds page sources without full catalog projection and captures overlays per generation", async () => {
    const fixture = await coldFixture("page-source");
    const catalog = vi.spyOn(fixture.registry, "catalog");
    const firstSource = await fixture.registry.pageSource("user");
    const firstPage = await firstSource.page(0, 25_000);
    expect(catalog).not.toHaveBeenCalled();
    expect(firstPage).toHaveLength(1);
    expect(firstPage[0]).toMatchObject({ id: fixture.manager.getSessionId(), kind: "user", cwd: fixture.cwd });
    expect(firstPage[0]!.isUnread).toBe(false);
    await fixture.registry.setAttention(fixture.manager.getSessionId(), true);
    const secondSource = await fixture.registry.pageSource("user");
    expect(secondSource.generation).not.toBe(firstSource.generation);
    expect((await secondSource.page(0, 1))[0]!.isUnread).toBe(true);
  });

  it("rejects read-only child access without an exact live parent process owner", async () => {
    const fixture = await coldFixture("readonly-unowned", { nested: true, name: "subagent-worker" });
    const sessionId = fixture.manager.getSessionId();
    await expect(fixture.registry.resolveReadOnlySubagentPath(
      sessionId,
      await realpath(fixture.sessionFile),
      "missing-parent",
      "missing-process",
      "missing-run",
    )).rejects.toMatchObject({ code: "not_found" });
    expect(fixture.runtimeFactory).not.toHaveBeenCalled();
  });

  it("latches foreground-open and foreground-close completion dispositions at canonical admission", async () => {
    const root = await mkdtemp(join(tmpdir(), "tron-agent-observed-completion-"));
    const agentDir = join(root, "agent");
    const cwd = join(root, "workspace");
    await Promise.all([mkdir(agentDir), mkdir(cwd)]);
    const runtime = await ModelRuntime.create({ modelsPath: null, refreshOnCreate: false });
    let releaseHiddenCompletion!: () => void;
    const hiddenCompletionBarrier = new Promise<void>((resolve) => { releaseHiddenCompletion = resolve; });
    const faux = fauxProvider({ provider: "tron-agent-observed-completion", tokensPerSecond: 10_000 });
    faux.setResponses([
      fauxAssistantMessage("observed response"),
      async () => {
        await hiddenCompletionBarrier;
        return fauxAssistantMessage("hidden response");
      },
    ]);
    runtime.registerNativeProvider(faux.provider);
    const enqueue = vi.fn(async () => "queued" as const);
    const suppressAutomatic = vi.fn(async () => "suppressed" as const);
    const registry = new RuntimeRegistry({
      agentDir,
      tronHome: join(root, "tron"),
      idleRuntimeMs: 60_000,
      modelRuntimeFactory: async () => runtime,
      trust: new TrustService(agentDir),
      broadcast: () => {},
      sessionSummaryChanged: () => {},
      sessionListChanged: () => {},
      machineId: "machine-observed-test",
      notifications: { enqueue, suppressAutomatic, markSessionInboxRead: vi.fn(async () => {}) } as unknown as NotificationService,
    });
    registries.push(registry);
    await initializeRegistry(registry);
    const slot = await registry.create(cwd);
    const model = faux.getModel();
    await slot.setModel(model.provider, model.id);
    registry.subscribe("visible-phone", slot.id);
    registry.setPresentationVisibility({
      clientId: "visible-phone",
      sessionId: slot.id,
      subscriptionToken: "visible-subscription",
      revision: 1,
      visible: true,
    });

    await slot.prompt("finish while visible");
    await waitFor(() => !slot.isBusy, "the slot to go idle");
    await waitFor(() => registry.attentionProjection(slot.id).completionRevision === 1, "the first completion revision");
    expect(registry.attentionProjection(slot.id)).toMatchObject({ completionRevision: 1, isUnread: false });
    await waitFor(() => suppressAutomatic.mock.calls.length > 0, "the suppressed automatic title refresh");
    expect(enqueue).not.toHaveBeenCalled();
    expect(suppressAutomatic).toHaveBeenCalledWith({
      sessionId: slot.id,
      sourceId: expect.any(String),
      kind: "agent_finished",
    });

    enqueue.mockClear();
    suppressAutomatic.mockClear();
    await slot.prompt("finish after presentation closes");
    await waitFor(() => slot.isBusy, "the slot to take work");
    registry.setPresentationVisibility({
      clientId: "visible-phone",
      sessionId: slot.id,
      subscriptionToken: "visible-subscription",
      revision: 2,
      visible: false,
    });
    releaseHiddenCompletion();
    await waitFor(() => !slot.isBusy, "the slot to go idle");
    await waitFor(() => registry.attentionProjection(slot.id).completionRevision === 2, "the second completion revision");
    expect(registry.attentionProjection(slot.id)).toMatchObject({ completionRevision: 2, isUnread: true });
    await waitFor(() => enqueue.mock.calls.length > 0, "the enqueued title refresh");
    expect(enqueue).toHaveBeenCalledWith(expect.objectContaining({
      sessionId: slot.id,
      kind: "agent_finished",
      sourceId: expect.any(String),
    }));
    expect(suppressAutomatic).not.toHaveBeenCalled();
  });

  it("recovers a canonical successful completion missed before restart", async () => {
    const fixture = await coldFixture("attention-restart");
    expect(fixture.registry.attentionProjection(fixture.manager.getSessionId()).isUnread).toBe(false);
    // Simulate the crash window: accepted work retained its marker and Pi's
    // successful terminal leaf committed after the persisted reconciliation
    // cursor, but attention admission/marker cleanup did not.
    const markerStore = (fixture.registry as unknown as {
      markers: {
        mark: (sessionId: string, operationId: string) => Promise<void>;
        markAssistantCompletion: (
          sessionId: string,
          operationId: string,
          completionId: string,
          completedAt: string,
        ) => Promise<void>;
      };
    }).markers;
    const sessionId = fixture.manager.getSessionId();
    await markerStore.mark(sessionId, "crashed-operation");
    fixture.manager.appendMessage(fauxAssistantMessage("completed immediately before crash"));
    const completion = fixture.manager.getLeafEntry()!;
    await markerStore.markAssistantCompletion(
      sessionId,
      "crashed-operation",
      completion.id,
      completion.timestamp,
    );
    await fixture.registry.dispose();

    const restarted = new RuntimeRegistry({
      agentDir: fixture.agentDir,
      tronHome: join(fixture.root, "tron"),
      idleRuntimeMs: 60_000,
      modelRuntimeFactory: async () => ModelRuntime.create({ modelsPath: null, refreshOnCreate: false }),
      trust: new TrustService(fixture.agentDir),
      broadcast: () => {},
      sessionSummaryChanged: () => {},
      sessionListChanged: () => {},
    });
    registries.push(restarted);
    await initializeRegistry(restarted);
    await restarted.recoverCanonicalAttention();
    expect(restarted.attentionProjection(fixture.manager.getSessionId()))
      .toMatchObject({ completionRevision: 1, isUnread: true });
    expect((await restarted.catalog("all")).sessions.find((row) => row.id === fixture.manager.getSessionId()))
      .toMatchObject({ phase: "idle", isUnread: true });
  });

  it("does not infer a completion from an unstamped accepted marker after restart", async () => {
    const fixture = await coldFixture("attention-unstamped-marker");
    const sessionId = fixture.manager.getSessionId();
    const markerStore = (fixture.registry as unknown as {
      markers: { mark: (sessionId: string, operationId: string) => Promise<void> };
    }).markers;
    await markerStore.mark(sessionId, "accepted-without-stamp");
    fixture.manager.appendMessage(fauxAssistantMessage("unowned successful leaf"));
    await fixture.registry.dispose();

    const restarted = new RuntimeRegistry({
      agentDir: fixture.agentDir,
      tronHome: join(fixture.root, "tron"),
      idleRuntimeMs: 60_000,
      modelRuntimeFactory: async () => ModelRuntime.create({ modelsPath: null, refreshOnCreate: false }),
      trust: new TrustService(fixture.agentDir),
      broadcast: () => {},
      sessionSummaryChanged: () => {},
      sessionListChanged: () => {},
    });
    registries.push(restarted);
    await initializeRegistry(restarted);
    expect(restarted.attentionProjection(sessionId)).toEqual({
      completionRevision: 0,
      attentionRevision: 0,
      isUnread: false,
    });
  });

  it("recovers the exact stamped completion off-leaf and never infers later markerless completions", async () => {
    const fixture = await coldFixture("attention-exact-marker");
    const sessionId = fixture.manager.getSessionId();
    const markerStore = (fixture.registry as unknown as {
      markers: {
        mark: (sessionId: string, operationId: string) => Promise<void>;
        markAssistantCompletion: (
          sessionId: string,
          operationId: string,
          completionId: string,
          completedAt: string,
        ) => Promise<void>;
      };
    }).markers;
    await markerStore.mark(sessionId, "stamped-operation");
    fixture.manager.appendMessage(fauxAssistantMessage("owned completion"));
    const owned = fixture.manager.getLeafEntry()!;
    await markerStore.markAssistantCompletion(sessionId, "stamped-operation", owned.id, owned.timestamp);
    fixture.manager.appendMessage(fauxAssistantMessage("newer markerless completion"));
    await fixture.registry.dispose();

    const restarted = new RuntimeRegistry({
      agentDir: fixture.agentDir,
      tronHome: join(fixture.root, "tron"),
      idleRuntimeMs: 60_000,
      modelRuntimeFactory: async () => ModelRuntime.create({ modelsPath: null, refreshOnCreate: false }),
      trust: new TrustService(fixture.agentDir),
      broadcast: () => {},
      sessionSummaryChanged: () => {},
      sessionListChanged: () => {},
    });
    registries.push(restarted);
    await initializeRegistry(restarted);
    await restarted.recoverCanonicalAttention();
    expect(restarted.attentionProjection(sessionId)).toMatchObject({ completionRevision: 1, isUnread: true });

    await restarted.dispose();
    fixture.manager.appendMessage(fauxAssistantMessage("still markerless"));
    const secondRestart = new RuntimeRegistry({
      agentDir: fixture.agentDir,
      tronHome: join(fixture.root, "tron"),
      idleRuntimeMs: 60_000,
      modelRuntimeFactory: async () => ModelRuntime.create({ modelsPath: null, refreshOnCreate: false }),
      trust: new TrustService(fixture.agentDir),
      broadcast: () => {},
      sessionSummaryChanged: () => {},
      sessionListChanged: () => {},
    });
    registries.push(secondRestart);
    await initializeRegistry(secondRestart);
    expect(secondRestart.attentionProjection(sessionId).completionRevision).toBe(1);
  });

  it("resolves attention membership without materializing the full catalog", async () => {
    const fixture = await coldFixture("attention-scoped-resolution");
    // Requirement: acknowledging attention resolves membership through the
    // bounded acquisition, never the full row projection. That no heavy read
    // happened is only observable by spying on the projection entry point.
    const catalog = vi.spyOn(fixture.registry, "catalog");
    const projection = await fixture.registry.setAttention(fixture.manager.getSessionId(), true);
    expect(projection.isUnread).toBe(true);
    expect(catalog).not.toHaveBeenCalled();
  });

  it("excludes only the deleting RPC owner while preserving live child-work deletion safety", async () => {
    const fixture = await coldFixture("delete-own-rpc-work", { workRegistry: new GatewayWorkRegistry() });
    const session = await fixture.registry.create(fixture.cwd);
    const works = fixture.registry.administrativeWorkRegistry;
    const deleteRPC = works.begin({
      kind: "rpc-mutation", method: "session.delete", sessionId: session.id, hostEpoch: works.runtimeEpoch,
    });
    const child = works.begin({ kind: "foreground-agent-operation", sessionId: session.id, hostEpoch: works.runtimeEpoch });
    try {
      await expect(fixture.registry.delete(session.id, deleteRPC.token)).rejects.toMatchObject({ code: "busy", diagnosticReason: "session_operation_busy" });
    } finally { child.settle(); }
    await expect(fixture.registry.delete(session.id, deleteRPC.token)).resolves.toBeUndefined();
    deleteRPC.settle();
    expect((await fixture.registry.catalog("user")).sessions.some(entry => entry.id === session.id)).toBe(false);
  });

  it("acknowledges attention for a live persisted session without walking catalog headers", async () => {
    const fixture = await coldFixture("attention-live-owner");
    const sessionId = fixture.manager.getSessionId();
    const slot = await fixture.registry.acquire(sessionId);
    expect(slot.persistedSessionFile).toBeDefined();
    // Requirement: an exact live runtime owner is itself the membership proof,
    // so acknowledging attention must not walk catalog headers. The absent walk
    // is visible only at the structure-evidence seam.
    const evidence = vi.spyOn(fixture.registry as any, "catalogStructureEvidence");
    await expect(fixture.registry.setAttention(sessionId, true)).resolves.toMatchObject({ isUnread: true });
    await expect(fixture.registry.setAttention(sessionId, false, 0)).resolves.toMatchObject({ isUnread: false });
    expect(evidence).not.toHaveBeenCalled();

    // Once the runtime owner is gone, membership again requires catalog proof.
    await fixture.registry.delete(sessionId);
    await expect(fixture.registry.setAttention(sessionId, true)).rejects.toMatchObject({ code: "not_found" });
  });

  it("merges a suspended attention write into latest summary facts and cannot race deletion", async () => {
    const fixture = await coldFixture("attention-races");
    const sessionId = fixture.manager.getSessionId();
    const internals = fixture.registry as unknown as {
      attention: { set: (id: string, unread: boolean, through?: number) => Promise<unknown> };
      latestSummaries: Map<string, SessionSummaryUpdate>;
    };
    const originalSet = internals.attention.set.bind(internals.attention);
    let entered!: () => void;
    let release!: () => void;
    const enteredBarrier = new Promise<void>((resolve) => { entered = resolve; });
    const writeBarrier = new Promise<void>((resolve) => { release = resolve; });
    vi.spyOn(internals.attention, "set").mockImplementation(async (id, unread, through) => {
      entered();
      await writeBarrier;
      return originalSet(id, unread, through);
    });

    const setting = fixture.registry.setAttention(sessionId, true, 0);
    await enteredBarrier;
    const catalogSummary = (await fixture.registry.catalog("all")).sessions.find((row) => row.id === sessionId)!;
    internals.latestSummaries.set(sessionId, {
      sessionId,
      phase: "running",
      updatedAt: catalogSummary.updatedAt,
      messageCount: 99,
      firstMessage: catalogSummary.firstMessage,
      summaryRevision: 41,
    });
    expect(internals.latestSummaries.get(sessionId)).toMatchObject({ phase: "running", messageCount: 99 });
    const deleting = fixture.registry.delete(sessionId);
    release();
    await setting;
    expect(internals.latestSummaries.get(sessionId)).toMatchObject({ phase: "running", messageCount: 99, isUnread: true });
    await deleting;
    expect(fixture.registry.attentionProjection(sessionId)).toEqual({
      completionRevision: 0,
      attentionRevision: 0,
      isUnread: false,
    });
    expect((await fixture.registry.catalog("all")).sessions.find((row) => row.id === sessionId)).toBeUndefined();
  });

  it("never holds the attention lane while deletion waits for the slot lane", async () => {
    const fixture = await coldFixture("attention-delete-rekey-order");
    const sessionId = fixture.manager.getSessionId();
    const slot = await fixture.registry.acquire(sessionId);
    const originalDispose = slot.dispose.bind(slot);
    let enteredDispose!: () => void;
    let releaseDispose!: () => void;
    const disposeEntered = new Promise<void>((resolve) => { enteredDispose = resolve; });
    const disposeBarrier = new Promise<void>((resolve) => { releaseDispose = resolve; });
    vi.spyOn(slot, "dispose").mockImplementation(async () => {
      enteredDispose();
      await disposeBarrier;
      return originalDispose();
    });

    const deleting = fixture.registry.delete(sessionId);
    await disposeEntered;
    // Requirement (lock order): a rekey racing a deletion must fail closed with
    // busy instead of holding the attention lane while the deletion waits on
    // the slot lane. The private hook is the only rekey driver that does not
    // itself queue behind that slot lane.
    const hooks = (fixture.registry as unknown as { hooks: () => {
      rekey: (
        previousId: string,
        nextId: string,
        slot: typeof slot,
        disposition: "preserve",
        commit: () => void,
      ) => Promise<void>;
    } }).hooks();
    await expect(hooks.rekey(sessionId, "replacement", slot, "preserve", () => {}))
      .rejects.toMatchObject({ code: "busy" });
    releaseDispose();
    await deleting;
  });

  it("projects empty live sessions until deletion, persistence, eviction, or restart", async () => {
    // Requirement: an empty live session is a catalog row only while its exact
    // slot exists, and retirement drops the row and both halves of its
    // revisioned summary together. Idle eviction runs on a 60s interval, so the
    // private trigger and the retained summary maps are the only way to reach
    // that transition without a real-time sleep.
    const root = await mkdtemp(join(tmpdir(), "tron-live-empty-catalog-"));
    const agentDir = join(root, "agent");
    const cwd = join(root, "workspace");
    await Promise.all([mkdir(agentDir), mkdir(cwd)]);
    let listChanges = 0;
    const registry = new RuntimeRegistry({
      agentDir,
      tronHome: join(root, "tron"),
      idleRuntimeMs: 1,
      modelRuntimeFactory: async () => ModelRuntime.create({ modelsPath: null, refreshOnCreate: false }),
      trust: new TrustService(agentDir),
      broadcast: () => {},
      sessionSummaryChanged: () => {},
      sessionListChanged: () => { listChanges += 1; },
    });
    registries.push(registry);
    await initializeRegistry(registry);
    const initial = await registry.catalog("user");

    const deletedSlot = await registry.create(cwd);
    const afterCreate = await registry.catalog("user");
    expect(afterCreate.listRevision).toBe(initial.listRevision + 1);
    expect(listChanges).toBe(1);
    expect(afterCreate.sessions).toEqual([expect.objectContaining({
      id: deletedSlot.id,
      cwd: deletedSlot.cwd,
      kind: "user",
      messageCount: 0,
      firstMessage: "",
      phase: "idle",
    })]);
    expect(afterCreate.sessions[0]?.createdAt).toBe(deletedSlot.catalogCreatedAt);
    expect((await registry.catalog("user")).sessions[0]?.createdAt)
      .toBe(afterCreate.sessions[0]?.createdAt);
    expect(await registry.acquire(deletedSlot.id)).toBe(deletedSlot);

    await registry.delete(deletedSlot.id);
    expect((await registry.catalog("user")).sessions).toEqual([]);
    expect(listChanges).toBe(2);

    const persistedSlot = await registry.create(cwd);
    const persistedManager = (persistedSlot as unknown as { sessionManager: SessionManager }).sessionManager;
    persistedManager.appendMessage(fauxAssistantMessage("persisted catalog row"));
    expect(persistedSlot.persistedSessionFile).toBeDefined();
    // The slot's own persist reaches the row through the owner's commit point.
    // Applying it here is deterministic where polling the row is not: the hook
    // that fires it is covered by "resolves a list, a cold open and a hot
    // re-acquire from the owner's rows without a walk", and a loaded host can
    // starve a 5 s poll.
    await catalogOwner(registry).refresh(persistedSlot.persistedSessionFile!);
    const afterPersistence = await registry.catalog("user");
    expect(afterPersistence.sessions.filter((session) => session.id === persistedSlot.id)).toHaveLength(1);
    const ownership = registry as unknown as {
      summaryRevisions: Map<string, number>;
      latestSummaries: Map<string, SessionSummaryUpdate>;
      evictIdle: () => Promise<void>;
    };
    expect(ownership.summaryRevisions.has(persistedSlot.id)).toBe(true);
    expect(ownership.latestSummaries.has(persistedSlot.id)).toBe(true);
    const persistedRevision = ownership.summaryRevisions.get(persistedSlot.id);
    const persistedChanges = listChanges;
    (persistedSlot as unknown as { lastTouchedAt: number }).lastTouchedAt = 0;
    await ownership.evictIdle();
    expect(listChanges).toBe(persistedChanges);
    expect(ownership.summaryRevisions.get(persistedSlot.id)).toBe(persistedRevision);
    expect(ownership.latestSummaries.has(persistedSlot.id)).toBe(true);
    expect((await registry.catalog("user")).sessions.map((session) => session.id)).toContain(persistedSlot.id);

    const evictedSlot = await registry.create(cwd);
    const beforeEviction = await registry.catalog("user");
    const changesBeforeEviction = listChanges;
    expect(ownership.summaryRevisions.has(evictedSlot.id)).toBe(true);
    expect(ownership.latestSummaries.has(evictedSlot.id)).toBe(true);
    (evictedSlot as unknown as { lastTouchedAt: number }).lastTouchedAt = 0;
    await ownership.evictIdle();
    const afterEviction = await registry.catalog("user");
    expect(afterEviction.sessions.map((session) => session.id)).not.toContain(evictedSlot.id);
    expect(afterEviction.listRevision).toBeGreaterThan(beforeEviction.listRevision);
    expect(listChanges).toBe(changesBeforeEviction + 1);
    expect(ownership.summaryRevisions.has(evictedSlot.id)).toBe(false);
    expect(ownership.latestSummaries.has(evictedSlot.id)).toBe(false);

    const fresh = new RuntimeRegistry({
      agentDir,
      tronHome: join(root, "fresh-tron"),
      idleRuntimeMs: 60_000,
      trust: new TrustService(agentDir),
      broadcast: () => {},
      sessionSummaryChanged: () => {},
      sessionListChanged: () => {},
    });
    registries.push(fresh);
    await initializeRegistry(fresh);
    const freshIDs = (await fresh.catalog("user")).sessions.map((session) => session.id);
    expect(freshIDs).toContain(persistedSlot.id);
    expect(freshIDs).not.toContain(evictedSlot.id);
  });

  it("fails closed when a canonical file collides with a live-only slot", async () => {
    const root = await mkdtemp(join(tmpdir(), "tron-live-empty-collision-"));
    const agentDir = join(root, "agent");
    const cwd = join(root, "workspace");
    await Promise.all([mkdir(agentDir), mkdir(cwd)]);
    const registry = new RuntimeRegistry({
      agentDir,
      tronHome: join(root, "tron"),
      idleRuntimeMs: 60_000,
      modelRuntimeFactory: async () => ModelRuntime.create({ modelsPath: null, refreshOnCreate: false }),
      trust: new TrustService(agentDir),
      broadcast: () => {},
      sessionSummaryChanged: () => {},
      sessionListChanged: () => {},
    });
    registries.push(registry);
    await initializeRegistry(registry);
    const baseline = await registry.catalog("all");
    const slot = await registry.create(cwd);
    const beforeCollision = await registry.catalog("all");
    expect(beforeCollision.listRevision).toBe(baseline.listRevision + 1);
    expect(beforeCollision.sessions.map((session) => session.id)).toContain(slot.id);
    expect(slot.persistedSessionFile).toBeUndefined();

    const collisionDirectory = join(agentDir, "sessions", "collision");
    await mkdir(collisionDirectory, { recursive: true });
    const timestamp = new Date().toISOString();
    await writeFile(join(collisionDirectory, "claim.jsonl"), [
      JSON.stringify({ type: "session", version: 3, id: slot.id, timestamp, cwd }),
      JSON.stringify({
        type: "message",
        id: randomUUID().slice(0, 8),
        parentId: null,
        timestamp,
        message: { role: "user", content: "colliding canonical claimant", timestamp: Date.now() },
      }),
    ].join("\n") + "\n");

    await settleCatalog(registry);
    const afterCollision = await registry.catalog("all");
    expect(afterCollision.sessions.map((session) => session.id)).not.toContain(slot.id);
    expect(afterCollision.listRevision).toBeGreaterThan(beforeCollision.listRevision);
    await expect(registry.acquire(slot.id)).rejects.toMatchObject({ code: "conflict" });
  });

  it("publishes the first prompt as the live session title before the agent settles", async () => {
    const root = await mkdtemp(join(tmpdir(), "tron-live-session-title-"));
    const agentDir = join(root, "agent");
    const cwd = join(root, "workspace");
    await Promise.all([mkdir(agentDir), mkdir(cwd)]);
    const runtime = await ModelRuntime.create({ modelsPath: null, refreshOnCreate: false });
    const faux = fauxProvider({ provider: "tron-live-session-title", tokensPerSecond: 10_000 });
    let releaseResponse!: () => void;
    const responseBarrier = new Promise<void>((resolve) => { releaseResponse = resolve; });
    faux.setResponses([async () => {
      await responseBarrier;
      return fauxAssistantMessage("title published");
    }]);
    runtime.registerNativeProvider(faux.provider);
    const summaries: SessionSummaryUpdate[] = [];
    const registry = new RuntimeRegistry({
      agentDir,
      tronHome: join(root, "tron"),
      idleRuntimeMs: 60_000,
      modelRuntimeFactory: async () => runtime,
      trust: new TrustService(agentDir),
      broadcast: () => {},
      sessionSummaryChanged: (summary) => summaries.push(summary),
      sessionListChanged: () => {},
    });
    registries.push(registry);
    await initializeRegistry(registry);
    const slot = await registry.create(cwd);
    const model = faux.getModel();
    await slot.setModel(model.provider, model.id);

    await slot.prompt("Update this title immediately");
    try {
      await waitFor(() => summaries.some((summary) => summary.firstMessage === "Update this title immediately"), "the immediate title summary");

      expect(slot.isBusy).toBe(true);
      expect(summaries.at(-1)).toMatchObject({
        phase: "running",
        messageCount: 1,
        firstMessage: "Update this title immediately",
      });
      expect((await registry.catalog("user")).sessions.find((summary) => summary.id === slot.id)).toMatchObject({
        messageCount: 1,
        firstMessage: "Update this title immediately",
      });
    } finally {
      releaseResponse();
    }
    await waitFor(() => !slot.isBusy, "the slot to go idle");
    expect(summaries.at(-1)).toMatchObject({
      phase: "idle",
      messageCount: 2,
      firstMessage: "Update this title immediately",
    });
  });

  it("folds summary facts from appended entries and rebuilds when the entry set is replaced", async () => {
    // Failure modes (G-11): a fold that stops at its first boundary misses
    // later appends, and a replaced session file (branch switch, re-open)
    // keeps the previous file's messageCount/firstMessage.
    const fixture = await coldFixture("summary-fold");
    try {
      const slot = await fixture.registry.acquire(fixture.manager.getSessionId());
      const manager = (slot as unknown as { sessionManager: SessionManager }).sessionManager;
      await waitFor(() => fixture.summaries.length > 0, "the first session summary");
      const before = fixture.summaries.at(-1)!;
      const beforeAt = Date.parse(before.updatedAt);

      manager.appendMessage({ role: "user", content: "folded prompt", timestamp: beforeAt + 1_000 });
      await slot.rename("fold one");
      await waitFor(() => fixture.summaries.at(-1)!.messageCount === before.messageCount + 1, "the summary after one message");
      expect(fixture.summaries.at(-1)).toMatchObject({
        firstMessage: "folded prompt",
        updatedAt: new Date(beforeAt + 1_000).toISOString(),
      });

      manager.appendMessage({ role: "user", content: "second prompt", timestamp: beforeAt + 2_000 });
      await slot.rename("fold two");
      await waitFor(() => fixture.summaries.at(-1)!.messageCount === before.messageCount + 2, "the summary after two messages");
      expect(fixture.summaries.at(-1)).toMatchObject({
        firstMessage: "folded prompt",
        updatedAt: new Date(beforeAt + 2_000).toISOString(),
      });

      const replacementDirectory = join(fixture.root, "replacement-sessions");
      await mkdir(replacementDirectory, { recursive: true });
      const replacement = SessionManager.create(fixture.cwd, replacementDirectory);
      replacement.appendMessage({ role: "user", content: "replacement prompt", timestamp: beforeAt + 5_000 });
      // Pi persists a session file only once it holds an assistant message.
      replacement.appendMessage(fauxAssistantMessage("replacement answer"));
      manager.setSessionFile(replacement.getSessionFile()!);
      await slot.rename("fold three");
      await waitFor(() => fixture.summaries.at(-1)!.firstMessage === "replacement prompt", "the summary of the replacement prompt");
      expect(fixture.summaries.at(-1)).toMatchObject({
        messageCount: 2,
        updatedAt: new Date(beforeAt + 5_000).toISOString(),
      });
    } finally {
      await fixture.registry.dispose();
      registries.splice(registries.indexOf(fixture.registry), 1);
      await rm(fixture.root, { recursive: true, force: true });
    }
  });

  it("never rebroadcasts a snapshot already covered by an immediate publication", async () => {
    // Failure mode: an event schedules the 20 ms coalesced snapshot, then an
    // immediate publication (run settlement, prompt admission) broadcasts that
    // state and the stale timer later broadcasts the identical state again.
    const root = await mkdtemp(join(tmpdir(), "tron-duplicate-snapshot-"));
    const agentDir = join(root, "agent");
    const cwd = join(root, "workspace");
    await Promise.all([mkdir(agentDir), mkdir(cwd)]);
    const runtime = await ModelRuntime.create({ modelsPath: null, refreshOnCreate: false });
    const faux = fauxProvider({ provider: "tron-duplicate-snapshot", tokensPerSecond: 400 });
    faux.setResponses([fauxAssistantMessage("streamed reply ".repeat(12))]);
    runtime.registerNativeProvider(faux.provider);
    const snapshots: any[] = [];
    const configurationEvents: any[] = [];
    const registry = new RuntimeRegistry({
      agentDir,
      tronHome: join(root, "tron"),
      idleRuntimeMs: 60_000,
      modelRuntimeFactory: async () => runtime,
      trust: new TrustService(agentDir),
      broadcast: (_id, topic, payload) => {
        if (topic === "session.snapshot") snapshots.push(payload);
        if (topic === "session.configuration") configurationEvents.push(payload);
      },
      sessionSummaryChanged: () => {},
      sessionListChanged: () => {},
    });
    registries.push(registry);
    await initializeRegistry(registry);
    const slot = await registry.create(cwd);
    subscribeAudience(registry, slot.id);
    const model = faux.getModel();
    await slot.setModel(model.provider, model.id);
    const state = ({ eventSequence: _sequence, ...rest }: any) => JSON.stringify(rest);

    const before = snapshots.length;
    const receipt = await slot.prompt("duplicate snapshot owner");
    // A client that opens mid-admission installs the current snapshot, then
    // applies only later sequences, exactly like the phone reducer.
    const midAdmission = slot.snapshot();
    await waitFor(() => !slot.isBusy, "the slot to go idle");
    // Outlive any coalescing window still pending after settlement.
    await new Promise((resolve) => setTimeout(resolve, 60));

    const published = snapshots.slice(before);
    for (let index = 1; index < published.length; index += 1) {
      expect(state(published[index]), `snapshot ${published[index].eventSequence} repeats its predecessor`)
        .not.toBe(state(published[index - 1]));
    }
    const final = slot.snapshot();
    expect(final.phase).toBe("idle");
    expect(final.pendingPrompt).toBeUndefined();
    expect(final.transcript.find((item: any) => item.role === "user")?.presentationId).toBe(receipt.operationId);
    // Both an early subscriber and the mid-admission subscriber converge on
    // the owner's settled state.
    const projected = (snapshot: any) => configurationEvents
      .filter(event => event.runtimeGeneration === snapshot.runtimeGeneration && event.eventSequence > snapshot.eventSequence)
      .reduce((current, event) => ({ ...current, configurationBlocker: event.data.configurationBlocker }), snapshot);
    expect(state(projected(published.at(-1)))).toBe(state(final));
    const lateSubscriberFrames = published.filter((snapshot) => snapshot.eventSequence > midAdmission.eventSequence);
    expect(lateSubscriberFrames.length).toBeGreaterThan(0);
    expect(state(projected(lateSubscriberFrames.at(-1)))).toBe(state(final));
  });

  it("keeps row-summary revisions separate and lists phase without transcript snapshots", async () => {
    const root = await mkdtemp(join(tmpdir(), "tron-catalog-summary-revision-"));
    const agentDir = join(root, "agent");
    const cwd = join(root, "workspace");
    await Promise.all([mkdir(agentDir), mkdir(cwd)]);
    const runtime = await ModelRuntime.create({ modelsPath: null, refreshOnCreate: false });
    const faux = fauxProvider({ provider: "tron-catalog-boundary", tokensPerSecond: 10_000 });
    faux.setResponses([fauxAssistantMessage("catalog ready")]);
    runtime.registerNativeProvider(faux.provider);
    const summaries: SessionSummaryUpdate[] = [];
    let listChanges = 0;
    const registry = new RuntimeRegistry({
      agentDir,
      tronHome: join(root, "tron"),
      idleRuntimeMs: 60_000,
      modelRuntimeFactory: async () => runtime,
      trust: new TrustService(agentDir),
      broadcast: () => {},
      sessionSummaryChanged: (summary) => summaries.push(summary),
      sessionListChanged: () => { listChanges += 1; },
    });
    registries.push(registry);
    await initializeRegistry(registry);
    const slot = await registry.create(cwd);
    const model = faux.getModel();
    await slot.setModel(model.provider, model.id);
    await slot.prompt(`catalog boundary ${"x".repeat(5_000)}`);
    await waitFor(() => !slot.isBusy, "the slot to go idle");
    await slot.rename(`catalog-${"n".repeat(5_000)}`);
    const before = await registry.catalog("user");
    const snapshot = vi.spyOn(slot, "snapshot");
    const structuralChangesBeforeSummary = listChanges;

    slot.publishSnapshot();
    snapshot.mockClear();
    const after = await registry.catalog("user");

    expect(summaries.at(-1)?.summaryRevision).toBeGreaterThan(0);
    expect(Buffer.byteLength(summaries.at(-1)?.firstMessage ?? "")).toBeLessThanOrEqual(1_024);
    expect(Buffer.byteLength(summaries.at(-1)?.name ?? "")).toBeLessThanOrEqual(1_024);
    expect(after.listRevision).toBe(before.listRevision);
    expect(listChanges).toBe(structuralChangesBeforeSummary);
    expect(after.sessions[0]?.phase).toBe(slot.catalogPhase);
    // Runtime-owned deferred publication may legitimately call snapshot(sequence)
    // here; catalog listing must never call the former zero-argument full snapshot.
    expect(snapshot.mock.calls.filter((arguments_) => arguments_.length === 0)).toHaveLength(0);
  });

  it("bounds recursive catalog directories and streamed entries before materialization", async () => {
    const root = await mkdtemp(join(tmpdir(), "tron-catalog-discovery-bounds-"));
    const agentDir = join(root, "agent");
    const catalog = join(agentDir, "sessions");
    await Promise.all([
      mkdir(join(catalog, "first"), { recursive: true }),
      mkdir(join(catalog, "second"), { recursive: true }),
    ]);
    // The discovery budgets bound the owner's whole-folder pass. A catalog over
    // one of them reports a failed pass and publishes nothing, so a read refuses
    // retryably instead of serving a cut that saw only part of the folder.
    const bounded = async (
      label: string,
      maximumDirectories: number,
      maximumEntries: number,
      maximumTraversalBytes = 8 * 1_024 * 1_024,
    ) => {
      const reconciled: SessionCatalogReconcileOutcome[] = [];
      const registry = new RuntimeRegistry({
        agentDir,
        tronHome: join(root, `tron-${label}`),
        idleRuntimeMs: 60_000,
        trust: new TrustService(agentDir),
        broadcast: () => {},
        sessionSummaryChanged: () => {},
        sessionListChanged: () => {},
        catalogDiscoveryLimits: { maximumDirectories, maximumEntries, maximumTraversalBytes },
        catalogReconciled: (outcome) => reconciled.push(outcome),
      });
      registries.push(registry);
      const owner = catalogOwner(registry);
      await registry.initialize();
      await owner.whenReconciled();
      return { registry, reconciled };
    };

    for (const over of [
      await bounded("directories", 2, 2),
      await bounded("entries", 3, 1),
      await bounded("bytes", 3, 2, 1),
    ]) {
      expect(over.reconciled.at(-1)?.outcome).toBe("failed");
      expect(over.reconciled.at(-1)?.files).toBe(0);
      expect(catalogOwner(over.registry).hasCompleteCut()).toBe(false);
      await expect(over.registry.catalog("all")).rejects.toMatchObject({ code: "busy", retryable: true });
    }

    const withinBudget = await bounded("within", 3, 2);
    expect(withinBudget.reconciled.at(-1)?.outcome).toBe("reconciled");
    await expect(withinBudget.registry.catalog("all")).resolves.toMatchObject({ sessions: [] });
  });

  it("ignores JSONL symlinks outside the canonical catalog root", async () => {
    const fixture = await coldFixture("catalog-file-symlink");
    const external = join(fixture.root, "external-session.jsonl");
    const outside = SessionManager.create(fixture.cwd, join(fixture.root, "outside"));
    outside.appendMessage(fauxAssistantMessage("outside catalog fixture"));
    await copyFile(outside.getSessionFile()!, external);
    const alias = join(fixture.agentDir, "sessions", "workspace", "outside.jsonl");
    await symlink(external, alias);

    const listed = await fixture.registry.catalog("all");
    expect(listed.sessions.map((session) => session.id)).not.toContain(outside.getSessionId());
  });

  it("keeps public catalog identity stable when the same folders are enumerated in another order", async () => {
    const fixture = await coldFixture("catalog-walk-order");
    const catalogRoot = join(fixture.agentDir, "sessions");
    const folderNames = ["walk-a", "walk-b", "walk-c"];
    const managers = folderNames.map((name) => {
      const directory = join(catalogRoot, name);
      return SessionManager.create(fixture.cwd, directory);
    });
    for (const manager of managers) manager.appendMessage(fauxAssistantMessage("stable catalog fixture"));

    const before = await fixture.registry.catalog("all");
    const beforeIDs = before.sessions.map((session) => session.id).sort();
    const holding = join(fixture.root, "walk-order-holding");
    await mkdir(holding);
    for (const name of folderNames) await rename(join(catalogRoot, name), join(holding, name));
    for (const name of [...folderNames].reverse()) await rename(join(holding, name), join(catalogRoot, name));

    const after = await fixture.registry.catalog("all");
    expect(after.listRevision).toBe(before.listRevision);
    expect(after.sessions.map((session) => session.id).sort()).toEqual(beforeIDs);
  });

  it("owns nested SDK session directories within its bounded directory budget", async () => {
    const root = await mkdtemp(join(tmpdir(), "tron-catalog-direct-sdk-listing-"));
    const agentDir = join(root, "agent");
    const catalog = join(agentDir, "sessions");
    const child = join(catalog, "child");
    await Promise.all([mkdir(catalog, { recursive: true }), mkdir(child, { recursive: true })]);
    const directSession = SessionManager.create(root, catalog);
    const childSession = SessionManager.create(root, child);
    directSession.appendMessage(fauxAssistantMessage("direct catalog fixture"));
    childSession.appendMessage(fauxAssistantMessage("child catalog fixture"));

    // Requirement: the pinned SDK lists one directory at a time, so recursion belongs
    // to the registry; the catalog must still yield both nested sessions inside its
    // bounded directory budget.
    expect((await SessionManager.listAll(catalog)).map((session) => session.id)).toEqual([
      directSession.getSessionId(),
    ]);
    expect((await SessionManager.listAll(child)).map((session) => session.id)).toEqual([
      childSession.getSessionId(),
    ]);

    const registry = new RuntimeRegistry({
      agentDir,
      tronHome: join(root, "tron"),
      idleRuntimeMs: 60_000,
      trust: new TrustService(agentDir),
      broadcast: () => {},
      sessionSummaryChanged: () => {},
      sessionListChanged: () => {},
      catalogDiscoveryLimits: { maximumDirectories: 2, maximumSessions: 2 },
    });
    registries.push(registry);
    await initializeRegistry(registry);
    expect((await registry.catalog("all")).sessions.map((session) => session.id).sort()).toEqual([
      childSession.getSessionId(), directSession.getSessionId(),
    ].sort());
  });

  it("bounds cold catalog previews without changing canonical prompts or names", async () => {
    const fixture = await coldFixture("large-catalog-preview");
    const prompt = "😀漢字".repeat(5_000);
    const name = "Long session 😀 ".repeat(1_000);
    fixture.manager.appendMessage({ role: "user", content: prompt, timestamp: Date.now() });
    fixture.manager.appendSessionInfo(name);
    // This test writes the canonical file itself: index it before reading.
    await settleCatalog(fixture.registry);
    const before = await readFile(fixture.sessionFile, "utf8");
    const row = (await fixture.registry.catalog("all")).sessions[0]!;
    expect(Buffer.byteLength(row.firstMessage)).toBeLessThanOrEqual(1_024);
    expect(Buffer.byteLength(row.name!)).toBeLessThanOrEqual(1_024);
    expect(row.firstMessage.endsWith("…")).toBe(true);
    expect(row.firstMessage).not.toContain("\uFFFD");
    expect(prompt.startsWith(row.firstMessage.slice(0, -1))).toBe(true);
    expect(await readFile(fixture.sessionFile, "utf8")).toBe(before);
    expect(before).toContain(prompt);
    expect(before).toContain(name.trim());
  });

  it("initializes storage without requiring catalog presentation metadata", async () => {
    const fixture = await coldFixture("storage-without-catalog-preview");
    const store = (fixture.registry as unknown as { displayArtifacts: DisplayArtifactStore }).displayArtifacts;
    await store.initialize();
    await writeFile(join(fixture.cwd, "retained.txt"), "retained display artifact");
    const display = await store.ingest(fixture.cwd, "retained.txt", fixture.manager.getSessionId());
    // A membership cut no in-process reconcile completed cannot authorize orphan
    // removal: the maintenance read refuses retryably and the artifact stays.
    const evidence = vi.spyOn(CatalogDiscovery.prototype, "catalogStructureEvidence")
      .mockImplementation(async () => ({
        digest: "incomplete", factsDigest: "incomplete", identitiesByPath: new Map(),
        complete: false, unprovenPaths: new Set(), unstableCanonicalFiles: false,
      }));
    try {
      await catalogOwner(fixture.registry).reconcile();
      await expect(fixture.registry.sessionIDsForStorageMaintenance())
        .rejects.toMatchObject({ code: "busy", retryable: true });
      await expect(fixture.registry.maintainDisplayArtifacts()).rejects.toMatchObject({ code: "busy" });
    } finally {
      evidence.mockRestore();
    }
    await expect(fixture.registry.initializeBlobStorage()).resolves.toBeUndefined();
    const displayLease = await store.acquire(display.id, fixture.manager.getSessionId());
    try {
      expect((await collectStream(displayLease.stream)).toString()).toBe("retained display artifact");
    } finally { await displayLease.release(); }
    // Only a subsequent successful membership cut can authorize orphan removal.
    const membership = vi.spyOn(fixture.registry, "sessionIDsForStorageMaintenance").mockResolvedValueOnce(new Set());
    await fixture.registry.maintainDisplayArtifacts();
    membership.mockRestore();
    await expect(store.acquire(display.id, fixture.manager.getSessionId())).rejects.toMatchObject({ code: "not_found" });
    // Storage and an exact canonical session remain usable even when the
    // aggregate presentation catalog cannot be materialized.
    const slot = await fixture.registry.acquire(fixture.manager.getSessionId());
    const artifact = await slot.export("jsonl");
    const lease = await fixture.registry.acquireBlob(artifact.blobId);
    try {
      expect((await collectStream(lease.stream)).toString()).toContain("storage-without-catalog-preview");
    } finally { await lease.release(); }
  });

  it.each(["exact", "duplicate", "unprovable", "changed"])("recovers pending Knowledge observations from %s header evidence after the owner's cut", async (mode) => {
    const fixture = await coldFixture("knowledge-header-recovery", {
      catalogDiscoveryLimits: { maximumRetainedBytes: 1 },
    });
    const sessionId = fixture.manager.getSessionId();
    const invocationId = randomUUID();
    const common = { version: 1 as const, invocationId, operationId: randomUUID(), sessionId,
      source: "plain" as const, createdAt: "2026-01-01T00:00:00.000Z" };
    fixture.manager.appendCustomEntry(INVOCATION_RECEIPT_TYPE, makeInvocationReceipt({ ...common,
      receiptId: randomUUID(), receiptKind: "start", sequence: 1, lifecycle: "staged",
      origin: { kind: "user", title: "User", confidence: "boundary" },
    }));
    const entryId = fixture.manager.appendMessage({ role: "user", content: "Retain this exact observation", timestamp: Date.now() });
    fixture.manager.appendCustomEntry(INVOCATION_RECEIPT_TYPE, makeInvocationReceipt({ ...common,
      receiptId: randomUUID(), receiptKind: "terminal", sequence: 2, lifecycle: "completed",
    }));
    const entries = fixture.manager.getBranch().filter(entry => entry.id === entryId);
    const store = new KnowledgeStore(fixture.registry.knowledgeWorkspace());
    const initial = await store.config();
    const config = await store.configure("enable-recovery-session", {
      ...initial, eligibility: { ...initial.eligibility, sessionIds: [sessionId] },
    });
    await store.setCoverage({ commandId: "seed-recovery-cut", expectedConfigRevision: config.revision,
      coverage: { id: "recovery-cut", disposition: "pending", groupRevisionIds: [], range: {
        sessionId, fromEntryId: entryId, toEntryId: entryId, entryIds: [entryId],
        entryDigest: observationEntriesDigest(entries), invocationIds: [invocationId],
      } },
    });
    const admit = vi.fn();
    fixture.registry.setKnowledgeService(new KnowledgeService(store, { admit } as unknown as KnowledgeObservationService));
    await fixture.registry.initializeBlobStorage();
    if (mode === "duplicate") await copyFile(fixture.sessionFile, join(dirname(fixture.sessionFile), "duplicate.jsonl"));
    // An unprovable neighbour is not membership evidence for itself and does not
    // blind the cut (G-1c); the recovery still resolves this session's exact row.
    // An unprovable neighbour (a header-less file) leaves the cut's membership
    // unknown, so recovery defers instead of marking a coverage unavailable.
    if (mode === "unprovable") await writeFile(join(dirname(fixture.sessionFile), "unprovable.jsonl"), "");
    if (mode === "changed") {
      const open = SessionManager.open;
      vi.spyOn(SessionManager, "open").mockImplementation((...args) => {
        const manager = open(...args);
        appendFileSync(fixture.sessionFile, "\n");
        return manager;
      });
    }
    // The canonical appends above are this test's own writes: settle the owner so
    // the recovery reads its current row instead of racing the folder watcher.
    await settleCatalog(fixture.registry);
    const unavailable = vi.spyOn(store, "setCoverage");
    await fixture.registry.recoverKnowledgeObservation();
    if (mode === "exact") {
      expect(admit).toHaveBeenCalledExactlyOnceWith({ sessionId, entries, outcome: "completed", invocationId, invocationIds: [invocationId] });
      expect(unavailable).not.toHaveBeenCalled();
    } else {
      expect(admit).not.toHaveBeenCalled();
      if (mode === "duplicate") expect(unavailable).toHaveBeenCalledWith(expect.objectContaining({
        coverage: expect.objectContaining({ disposition: "unavailable", reason: "canonical-session-identity-ambiguous" }),
      }));
      else {
        expect(unavailable).not.toHaveBeenCalled();
        expect(await store.pendingObservationCoverage()).toHaveLength(1);
      }
    }
    expect(fixture.runtimeFactory).not.toHaveBeenCalled();
  });

  it("bounds discovered session count and bytes before normalization", async () => {
    const root = await mkdtemp(join(tmpdir(), "tron-catalog-materialization-bounds-"));
    const agentDir = join(root, "agent");
    await mkdir(join(agentDir, "sessions"), { recursive: true });
    const now = new Date("2026-01-01T00:00:00Z");
    const infos = ["first", "second"].map((id) => ({
      id,
      path: join(agentDir, "sessions", `${id}.jsonl`),
      cwd: root,
      created: now,
      modified: now,
      messageCount: 0,
      firstMessage: id,
    }));
    await Promise.all(infos.map((info) => writeFile(info.path, `${JSON.stringify({
      type: "session", version: 3, id: info.id, timestamp: now.toISOString(), cwd: root,
    })}\n`)));
    // A session-count budget the folder exceeds fails the owner's pass, so no cut
    // is published and a read refuses retryably instead of serving a partial one.
    const bounded = async (label: string, maximumSessions: number) => {
      const reconciled: SessionCatalogReconcileOutcome[] = [];
      const registry = new RuntimeRegistry({
        agentDir,
        tronHome: join(root, `tron-${label}`),
        idleRuntimeMs: 60_000,
        trust: new TrustService(agentDir),
        broadcast: () => {},
        sessionSummaryChanged: () => {},
        sessionListChanged: () => {},
        catalogDiscoveryLimits: { maximumSessions, normalizationConcurrency: 1 },
        catalogReconciled: (outcome) => reconciled.push(outcome),
      });
      registries.push(registry);
      const owner = catalogOwner(registry);
      await registry.initialize();
      await owner.whenReconciled();
      return { registry, reconciled, owner };
    };

    const tooSmall = await bounded("sessions-1", 1);
    expect(tooSmall.reconciled.at(-1)).toMatchObject({ outcome: "failed" });
    expect(tooSmall.owner.hasCompleteCut()).toBe(false);
    await expect(tooSmall.registry.catalog("all")).rejects.toMatchObject({ code: "busy", retryable: true });

    const enough = await bounded("sessions-2", 2);
    expect(enough.reconciled.at(-1)).toMatchObject({ outcome: "reconciled" });
    await expect(enough.registry.catalog("all")).resolves.toMatchObject({
      sessions: [{ id: "first" }, { id: "second" }],
    });
  });

  it("caps canonical session path normalization concurrency", async () => {
    const root = await mkdtemp(join(tmpdir(), "tron-catalog-normalization-concurrency-"));
    const agentDir = join(root, "agent");
    await mkdir(join(agentDir, "sessions"), { recursive: true });
    const now = new Date("2026-01-01T00:00:00Z");
    // The parent sorts last, so the pass's first header batch is two children
    // and both normalize at once.
    const parentPath = join(agentDir, "sessions", "z-parent.jsonl");
    await writeFile(parentPath, `${JSON.stringify({
      type: "session", version: 3, id: "parent", timestamp: now.toISOString(), cwd: root,
    })}\n`);
    // Each child names its parent, so the header phase resolves six parent paths
    // through `canonicalSessionPath` while the pass is bounded at 2.
    const infos = Array.from({ length: 6 }, (_, index) => ({
      id: `session-${index}`,
      path: join(agentDir, "sessions", `session-${index}.jsonl`),
    }));
    await Promise.all(infos.map((info) => writeFile(info.path, `${JSON.stringify({
      type: "session", version: 3, id: info.id, timestamp: now.toISOString(), cwd: root, parentSession: parentPath,
    })}\n`)));
    const reconciled: SessionCatalogReconcileOutcome[] = [];
    const registry = new RuntimeRegistry({
      agentDir,
      tronHome: join(root, "tron"),
      idleRuntimeMs: 60_000,
      trust: new TrustService(agentDir),
      broadcast: () => {},
      sessionSummaryChanged: () => {},
      sessionListChanged: () => {},
      catalogDiscoveryLimits: { normalizationConcurrency: 2 },
      catalogReconciled: (outcome) => reconciled.push(outcome),
    });
    registries.push(registry);
    const internals = registry as unknown as {
      canonicalSessionPath: (path: string) => Promise<string>;
    };
    let active = 0;
    let maximumActive = 0;
    const canonicalize = vi.spyOn(internals, "canonicalSessionPath").mockImplementation(async (path) => {
      active += 1;
      maximumActive = Math.max(maximumActive, active);
      // Hold each call briefly so overlapping work is observable without ever
      // blocking the owner's lane.
      await new Promise((resolve) => setTimeout(resolve, 5));
      active -= 1;
      return resolve(path);
    });

    try {
      const owner = catalogOwner(registry);
      await registry.initialize();
      // The first pass populates the durable rows, so the pass under measurement
      // reuses them and its only normalizations are the header phase's own.
      await owner.whenReconciled();
      await owner.settled();
      maximumActive = 0;

      await owner.reconcile();
      // The header phase resolves parent paths in batches of the configured
      // width: two are in flight, never more.
      expect(maximumActive).toBe(2);
      expect(reconciled.at(-1)?.outcome).toBe("reconciled");
      expect(reconciled.at(-1)?.files).toBe(infos.length + 1);
      expect((await registry.catalog("all")).sessions.map((session) => session.id).sort())
        .toEqual([...infos.map((info) => info.id), "parent"].sort());
    } finally {
      canonicalize.mockRestore();
    }
  });

  it("resolves a list, a cold open and a hot re-acquire from the owner's rows without a walk", async () => {
    const fixture = await coldFixture("reuse");
    await settleCatalog(fixture.registry);
    const walks = catalogWalks();
    const before = walks.count();

    const catalog = await fixture.registry.catalog("user");
    expect(catalog.sessions.map((session) => session.id)).toContain(fixture.manager.getSessionId());
    fixture.manager.appendMessage(fauxAssistantMessage("ordinary append after catalog"));
    // The Gateway-owned append reaches its row at the owner's commit point.
    await settleCatalog(fixture.registry);
    const readsFrom = walks.count();
    expect((await fixture.registry.acquire(fixture.manager.getSessionId())).id).toBe(fixture.manager.getSessionId());
    expect(fixture.runtimeFactory).toHaveBeenCalledTimes(1);
    // A hot slot resolves against the same rows.
    expect((await fixture.registry.acquire(fixture.manager.getSessionId())).id).toBe(fixture.manager.getSessionId());
    expect(walks.count()).toBe(readsFrom);
    walks.restore();
  });

  it("reuses an on-disk catalog across a second registry without a body scan and advances one appended row", async () => {
    const fixture = await coldFixture("restart-index");
    const secondDirectory = join(fixture.agentDir, "sessions", "second");
    await mkdir(secondDirectory, { recursive: true });
    const secondManager = SessionManager.create(fixture.cwd, secondDirectory);
    secondManager.appendMessage(fauxAssistantMessage("unchanged canonical body"));
    fixture.manager.appendMessage(fauxAssistantMessage("initial canonical body"));
    await fixture.registry.catalog("all");
    const indexPath = join(fixture.root, "tron", "gateway", "catalog-metadata-v2.json");
    await settleCatalog(fixture.registry);
    expect(existsSync(indexPath)).toBe(true);
    await fixture.registry.dispose();
    const restarted = new RuntimeRegistry({
      agentDir: fixture.agentDir,
      tronHome: join(fixture.root, "tron"),
      idleRuntimeMs: 60_000,
      modelRuntimeFactory: async () => ModelRuntime.create({ modelsPath: null, refreshOnCreate: false }),
      trust: new TrustService(fixture.agentDir),
      broadcast: () => {},
      sessionSummaryChanged: () => {},
      sessionListChanged: () => {},
    });
    registries.push(restarted);
    await initializeRegistry(restarted);
    await settleCatalog(restarted);
    const walks = catalogWalks();
    const before = walks.count();
    const append = vi.spyOn(CatalogMetadataIndex.prototype, "append");
    try {
      const unchanged = await restarted.catalog("all");
      expect(unchanged.sessions.find((session) => session.id === fixture.manager.getSessionId())?.messageCount).toBe(2);
      expect(unchanged.sessions.find((session) => session.id === secondManager.getSessionId())?.messageCount).toBe(1);
      // An external append advances one row from its own tail; the reader cut
      // neither walks the folder nor re-parses a transcript.
      fixture.manager.appendMessage(fauxAssistantMessage("external append after restart"));
      await settleCatalog(restarted);
      const readsFrom = walks.count();
      const updated = await restarted.catalog("all");
      expect(append.mock.calls.length).toBeGreaterThan(0);
      expect(updated.sessions.find((session) => session.id === fixture.manager.getSessionId())?.messageCount).toBe(3);
      expect(updated.sessions.find((session) => session.id === secondManager.getSessionId())?.messageCount).toBe(1);
      expect(walks.count()).toBe(readsFrom);
    } finally {
      append.mockRestore();
      walks.restore();
    }
  });

  it("writes the durable catalog document from its owner, not from a reader cut", async () => {
    const fixture = await coldFixture("owner-only-index-writer");
    // The owner's own cut is what reaches the document; nothing else may write
    // it, because a reader materialization parses its own summaries for the
    // in-memory cut and their counts and sizes are not the ones the owner
    // stamped. Those rows would hand the next startup content it must distrust.
    await settleCatalog(fixture.registry);
    const indexPath = join(fixture.root, "tron", "gateway", "catalog-metadata-v2.json");
    expect(existsSync(indexPath)).toBe(true);
    // With no document to load, the next read takes the full canonical
    // materialization path — the one that used to persist a second copy.
    await rm(indexPath, { force: true });
    (fixture.registry as unknown as { catalogStructuralIndex: unknown }).catalogStructuralIndex = undefined;
    const save = vi.spyOn(CatalogMetadataIndex.prototype, "save");
    try {
      await fixture.registry.catalog("all");
      // The reader-path write this case guards was fire-and-forget: it reached
      // `save` only after awaiting one summary per row, so an assertion taken
      // the moment `catalog()` returns cannot observe it and would pass against
      // the very bug the case names. Flush that deferred chain first.
      await new Promise((resolve) => setTimeout(resolve, 250));
      expect(save).not.toHaveBeenCalled();
      // And the document the read removed is still gone, not rewritten a moment
      // later by a caller other than its owner.
      expect(existsSync(indexPath)).toBe(false);
    } finally {
      save.mockRestore();
    }
  });

    it("rejects an unowned append that races durable-index reconciliation", async () => {
    const fixture = await coldFixture("unowned-index-append-race");
    await fixture.registry.catalog("all");
    const indexPath = join(fixture.root, "tron", "gateway", "catalog-metadata-v2.json");
    await settleCatalog(fixture.registry);
    expect(existsSync(indexPath)).toBe(true);
    // A restart is how a reader reaches the durable index with no in-memory cut.
    // The append is injected inside reconciliation because no public caller can
    // schedule work between the index read and its post-read evidence cut.
    await fixture.registry.dispose();
    const restarted = new RuntimeRegistry({
      agentDir: fixture.agentDir,
      tronHome: join(fixture.root, "tron"),
      idleRuntimeMs: 60_000,
      modelRuntimeFactory: async () => ModelRuntime.create({ modelsPath: null, refreshOnCreate: false }),
      trust: new TrustService(fixture.agentDir),
      broadcast: () => {},
      sessionSummaryChanged: () => {},
      sessionListChanged: () => {},
    });
    registries.push(restarted);
    await initializeRegistry(restarted);
    // The catalog owner reconciles behind the listener. Settle it so the
    // injected append lands in the reader's reconciliation, which this case is
    // about, rather than in background maintenance.
    await settleCatalog(restarted);
    const reconcile = vi.spyOn(CatalogMetadataIndex.prototype, "reconcile");
    try {
      // The indexed row is one message stale and its file is not runtime-owned,
      // so the owner's next cut must re-read it: the published row carries the
      // appended body instead of the index's message count.
      fixture.manager.appendMessage(fauxAssistantMessage("unowned append during index reconciliation"));
      await settleCatalog(restarted);
      expect(reconcile).toHaveBeenCalled();
      const listed = await restarted.catalog("all");
      expect(listed.sessions.find((session) => session.id === fixture.manager.getSessionId()))
        .toMatchObject({ messageCount: 2 });
    } finally {
      reconcile.mockRestore();
    }
  });

      it("keeps the last provable row when an unowned canonical file ends in a partial line", async () => {
    const fixture = await coldFixture("partial-final-line");
    const before = (await fixture.registry.catalog("all")).sessions
      .find((session) => session.id === fixture.manager.getSessionId())!;
    await appendFile(fixture.sessionFile, "{\"type\":\"message\"");
    await settleCatalog(fixture.registry);
    const walks = catalogWalks();
    const at = walks.count();
    const after = (await fixture.registry.catalog("all")).sessions
      .find((session) => session.id === fixture.manager.getSessionId())!;
    // A partial tail is not membership evidence: the row keeps the counts of the
    // exact prefix it proved, and the read neither walks nor refuses.
    expect(after.messageCount).toBe(before.messageCount);
    expect(walks.count()).toBe(at);
    walks.restore();
  });

    it("invalidates connected catalogs when cold attention has no live summary", async () => {
    const listChanged = vi.fn();
    const fixture = await coldFixture("cold-attention", { sessionListChanged: listChanged });
    const before = listChanged.mock.calls.length;
    const unread = await fixture.registry.setAttention(fixture.manager.getSessionId(), true);
    expect(unread.isUnread).toBe(true);
    expect(listChanged.mock.calls.length).toBe(before + 1);
  });

  it("converges empty create/list/delete while live summaries churn", async () => {
    const fixture = await coldFixture("create-list-delete-churn");
    const live = await fixture.registry.create(fixture.cwd);
    const internals = fixture.registry as unknown as {
      publishRevisionedSummary: (summary: SessionSummaryUpdate) => void;
    };
    for (let revision = 1; revision <= 8; revision += 1) {
      internals.publishRevisionedSummary({
        sessionId: live.id,
        summaryRevision: revision,
        phase: "running",
        updatedAt: new Date().toISOString(),
        messageCount: revision,
        firstMessage: "created live session",
        completionRevision: 0,
        attentionRevision: 0,
        isUnread: false,
      });
    }
    expect((await fixture.registry.catalog("user")).sessions.map((session) => session.id)).toContain(live.id);
    await fixture.registry.delete(live.id);
    expect((await fixture.registry.catalog("user")).sessions.map((session) => session.id)).not.toContain(live.id);
  });

  it("admits unread and read attention for an empty live-only session", async () => {
    const fixture = await coldFixture("live-only-attention");
    const live = await fixture.registry.create(fixture.cwd);
    const unread = await fixture.registry.setAttention(live.id, true);
    expect(unread.isUnread).toBe(true);
    const read = await fixture.registry.setAttention(live.id, false, unread.completionRevision);
    expect(read.isUnread).toBe(false);
  });

  it("quarantines a disk claimant that collides with an empty live-only session", async () => {
    const fixture = await coldFixture("live-only-attention-collision");
    const live = await fixture.registry.create(fixture.cwd);
    const collisionDirectory = join(fixture.agentDir, "sessions", "collision");
    await mkdir(collisionDirectory, { recursive: true });
    const collision = SessionManager.create(fixture.cwd, collisionDirectory, { id: live.id });
    collision.appendMessage(fauxAssistantMessage("collision"));
    // The claimant is an external writer: index it, then the ID is ambiguous.
    await settleCatalog(fixture.registry);
    await expect(fixture.registry.setAttention(live.id, true)).rejects.toMatchObject({ code: "conflict" });
  });

  it("rechecks a live-only attention target when a disk claimant appears at the commit boundary", async () => {
    const fixture = await coldFixture("live-only-attention-race");
    const live = await fixture.registry.create(fixture.cwd);
    const internals = fixture.registry as unknown as {
      attentionLiveOnlyStillAdmitted: (sessionId: string) => Promise<boolean>;
    };
    const original = internals.attentionLiveOnlyStillAdmitted.bind(fixture.registry);
    let entered!: () => void;
    let release!: () => void;
    const reachedCommitBoundary = new Promise<void>((resolve) => { entered = resolve; });
    const gate = new Promise<void>((resolve) => { release = resolve; });
    const finalAdmission = vi.spyOn(internals, "attentionLiveOnlyStillAdmitted")
      .mockImplementation(async (sessionId) => {
        entered();
        await gate;
        return original(sessionId);
      });

    try {
      const update = fixture.registry.setAttention(live.id, true);
      await reachedCommitBoundary;
      const collisionDirectory = join(fixture.agentDir, "sessions", "late-collision");
      await mkdir(collisionDirectory, { recursive: true });
      const collision = SessionManager.create(fixture.cwd, collisionDirectory, { id: live.id });
      collision.appendMessage(fauxAssistantMessage("late collision"));
      // The fence is the index at commit, not a walk: the claimant has to be
      // indexed for the boundary to see it, and it still rejects the update.
      await settleCatalog(fixture.registry);
      release();
      await expect(update).rejects.toMatchObject({ code: "conflict" });
      expect(fixture.registry.attentionProjection(live.id).isUnread).toBe(false);
    } finally {
      release();
      finalAdmission.mockRestore();
    }
  });

  // G-1c/B1: a file the scan read a header for but could not prove, with no
  // stored row to keep, is unknown membership. Publishing that cut would report
  // the session as absent and let every destructive caller drop its records and
  // artifacts for a file that is still there (review probe-prune.mjs).
  it("keeps the records of an unprovable session that has no stored row", async () => {
    const fixture = await coldFixture("unproven-no-row");
    const sessionId = fixture.manager.getSessionId();
    await settleCatalog(fixture.registry);
    await fixture.registry.setArchived(sessionId, true);
    await settleCatalog(fixture.registry);
    expect(fixture.registry.isArchived(sessionId)).toBe(true);
    await fixture.registry.dispose();
    registries.splice(registries.indexOf(fixture.registry), 1);
    // The durable document is what would otherwise keep a row: drop it, then
    // leave the transcript mid-append so no row can be rebuilt from the file.
    await rm(join(fixture.root, "tron", "gateway", "catalog-metadata-v2.json"), { force: true });
    const completeBytes = (await fsPromises.stat(fixture.sessionFile)).size;
    await appendFile(fixture.sessionFile, '{"type":"message"');

    const reconciled: SessionCatalogReconcileOutcome[] = [];
    const restarted = new RuntimeRegistry({
      agentDir: fixture.agentDir,
      tronHome: join(fixture.root, "tron"),
      idleRuntimeMs: 60_000,
      trust: new TrustService(fixture.agentDir),
      broadcast: () => {},
      sessionSummaryChanged: () => {},
      sessionListChanged: () => {},
      catalogReconciled: (outcome) => reconciled.push(outcome),
    });
    registries.push(restarted);
    await restarted.initialize();
    const owner = catalogOwner(restarted);
    await owner.whenReconciled();

    // The pass proves nothing about that file, so it is not a complete cut: its
    // rows are served, and no destructive caller and no "this session is gone"
    // answer is authorized.
    expect(reconciled.at(-1)).toMatchObject({ outcome: "incomplete" });
    expect(reconciled.at(-1)!.unproven).toBeGreaterThan(0);
    expect(owner.hasReconciledCut()).toBe(false);
    expect(owner.hasUnknownMembership()).toBe(true);
    expect(owner.unprovenSessionIds().has(sessionId)).toBe(true);
    // Startup recovery keeps the record, maintenance refuses, and acquire refuses
    // retryably instead of reporting the session as absent. The row cannot be
    // built from a torn file, so the session is missing from the list until a
    // pass can prove it — its records and artifacts are what must survive.
    await restarted.recoverCanonicalAttention();
    expect(restarted.isArchived(sessionId)).toBe(true);
    await expect(restarted.sessionIDsForStorageMaintenance())
      .rejects.toMatchObject({ code: "busy", retryable: true });
    expect((await restarted.list("all")).map((session) => session.id)).not.toContain(sessionId);
    await expect(restarted.acquire(sessionId)).rejects.toMatchObject({ code: "busy", retryable: true, diagnosticReason: "catalog_not_ready" });
    await expect(restarted.delete(sessionId)).rejects.toMatchObject({ code: "busy", retryable: true });

    // The torn append is rolled back, which proves the file again: the cut
    // publishes and the session is still the archived session it was.
    await truncate(fixture.sessionFile, completeBytes);
    await settleCatalog(restarted);
    expect(owner.hasReconciledCut()).toBe(true);
    expect(restarted.isArchived(sessionId)).toBe(true);
    expect((await restarted.list("all")).find((session) => session.id === sessionId)?.archivedAt).toBeDefined();
    expect((await restarted.sessionIDsForStorageMaintenance()).has(sessionId)).toBe(true);
    expect((await restarted.acquire(sessionId)).id).toBe(sessionId);
  });

  // G-1c/B2: automations.initialize() runs right after sessions.initialize(),
  // which starts the catalog owner and returns before its first cut. Admission
  // and recovery must wait for that cut instead of failing startup with a
  // retryable busy (review probe-automation.mjs).
  it.each([false, true])("admits an existing-session automation while the first cut runs (durable index: %s)", async (withDocument) => {
    const root = await mkdtemp(join(tmpdir(), "tron-automation-startup-"));
    const agentDir = join(root, "agent");
    const cwd = join(root, "workspace");
    const sessionDirectory = join(agentDir, "sessions", "workspace");
    await Promise.all([mkdir(sessionDirectory, { recursive: true }), mkdir(cwd, { recursive: true })]);
    process.env.PI_CODING_AGENT_DIR = agentDir;
    let target = "";
    for (let index = 0; index < 200; index += 1) {
      const manager = SessionManager.create(cwd, sessionDirectory);
      manager.appendMessage(fauxAssistantMessage("x".repeat(2_000)));
      target ||= manager.getSessionId();
    }
    const make = () => new RuntimeRegistry({
      agentDir,
      tronHome: join(root, "tron"),
      idleRuntimeMs: 60_000,
      trust: new TrustService(agentDir),
      broadcast: () => {},
      sessionSummaryChanged: () => {},
      sessionListChanged: () => {},
    });
    if (withDocument) {
      const seeded = make();
      registries.push(seeded);
      await initializeRegistry(seeded);
      await settleCatalog(seeded);
      await seeded.dispose();
      registries.splice(registries.indexOf(seeded), 1);
    }

    const registry = make();
    registries.push(registry);
    const blocked: Array<[string, string]> = [];
    const store = {
      initialize: async () => {},
      snapshot: () => [{
        id: "automation-startup", activation: "active",
        target: { kind: "existingSession", sessionId: target },
      }],
      blockTarget: async (sessionId: string, reason: string) => { blocked.push([sessionId, reason]); },
    };
    const scheduler = { recover: async () => {}, start: () => {} };
    await registry.initialize();
    const service = new AutomationService(
      store as never,
      scheduler as never,
      registry,
    );
    await expect(service.initialize()).resolves.toBeUndefined();
    expect(blocked).toEqual([]);
  });

  it("keeps the published rows through an incomplete pass and authorizes nothing destructive", async () => {
    const fixture = await coldFixture("incomplete-index-evidence");
    await settleCatalog(fixture.registry);
    const published = (await fixture.registry.catalog("all")).sessions.map((session) => session.id);
    const catalog = catalogOwner(fixture.registry);
    const evidence = vi.spyOn(CatalogDiscovery.prototype, "catalogStructureEvidence")
      .mockImplementation(async () => ({
        digest: "incomplete", factsDigest: "incomplete", identitiesByPath: new Map(),
        complete: false, unprovenPaths: new Set(), unstableCanonicalFiles: false,
      }));
    try {
      await catalog.reconcile();
    } finally {
      evidence.mockRestore();
    }
    // An incomplete traversal publishes nothing: the rows the last complete cut
    // produced stay, and no destructive caller may act on them.
    expect((await fixture.registry.catalog("all")).sessions.map((session) => session.id)).toEqual(published);
    expect(catalog.hasReconciledCut()).toBe(false);
    await expect(fixture.registry.sessionIDsForStorageMaintenance())
      .rejects.toMatchObject({ code: "busy", retryable: true });
  });

  it("reclaims reloadable idle runtimes under pressure while protecting visible sessions and drafts", async () => {
    const fixture = await coldFixture("idle-capacity-reclamation", { maximumLiveRuntimes: 3 });
    const first = await fixture.registry.acquire(fixture.manager.getSessionId());
    fixture.registry.subscribe("phone", first.id);
    const secondManager = SessionManager.create(fixture.cwd, dirname(fixture.sessionFile));
    secondManager.appendMessage(fauxAssistantMessage("reloadable idle"));
    await settleCatalog(fixture.registry);
    const second = await fixture.registry.acquire(secondManager.getSessionId());
    const draft = await fixture.registry.create(fixture.cwd);
    const thirdManager = SessionManager.create(fixture.cwd, dirname(fixture.sessionFile));
    thirdManager.appendMessage(fauxAssistantMessage("new visible selection"));
    await settleCatalog(fixture.registry);
    const third = await fixture.registry.acquire(thirdManager.getSessionId());
    expect(second.isDisposed).toBe(true);
    expect(first.isDisposed).toBe(false);
    expect(draft.isDisposed).toBe(false);
    expect(third.id).toBe(thirdManager.getSessionId());
    const retain = third.retainLease();
    try { await expect(fixture.registry.acquire(secondManager.getSessionId())).rejects.toMatchObject({ code: "busy" }); }
    finally { retain(); }
    const reopened = await fixture.registry.acquire(secondManager.getSessionId());
    expect(reopened).not.toBe(second);
    expect(JSON.stringify(reopened.snapshot().transcript)).toContain("reloadable idle");
    expect(third.isDisposed).toBe(true);
    expect(draft.isDisposed).toBe(false);
  });

  it("deduplicates same-session starts and starts distinct sessions concurrently", async () => {
    const root = await mkdtemp(join(tmpdir(), "tron-concurrent-cold-starts-"));
    const agentDir = join(root, "agent");
    const cwd = join(root, "workspace");
    const sessionDirectory = join(agentDir, "sessions", "workspace");
    await Promise.all([mkdir(sessionDirectory, { recursive: true }), mkdir(cwd, { recursive: true })]);
    process.env.PI_CODING_AGENT_DIR = agentDir;
    const firstManager = SessionManager.create(cwd, sessionDirectory);
    firstManager.appendMessage(fauxAssistantMessage("first cold start"));
    const secondManager = SessionManager.create(cwd, sessionDirectory);
    secondManager.appendMessage(fauxAssistantMessage("second cold start"));
    let entered = 0;
    let release!: () => void;
    const gate = new Promise<void>((resolve) => { release = resolve; });
    const runtimeFactory = vi.fn(async () => {
      entered += 1;
      await gate;
      return ModelRuntime.create({ modelsPath: null, refreshOnCreate: false });
    });
    const registry = new RuntimeRegistry({
      agentDir,
      tronHome: join(root, "tron"),
      idleRuntimeMs: 60_000,
      maximumLiveRuntimes: 2,
      modelRuntimeFactory: runtimeFactory,
      trust: new TrustService(agentDir),
      broadcast: () => {},
      sessionSummaryChanged: () => {},
      sessionListChanged: () => {},
    });
    registries.push(registry);
    await initializeRegistry(registry);
    await registry.catalog("all");

    const first = registry.acquire(firstManager.getSessionId());
    const duplicate = registry.acquire(firstManager.getSessionId());
    const second = registry.acquire(secondManager.getSessionId());
    await waitFor(() => entered === 2, "both slots to enter");
    expect(runtimeFactory).toHaveBeenCalledTimes(2);
    await expect(registry.create(cwd)).rejects.toMatchObject({ code: "busy", retryable: true });
    expect(runtimeFactory).toHaveBeenCalledTimes(2);
    release();
    const [firstSlot, duplicateSlot, secondSlot] = await Promise.all([first, duplicate, second]);
    expect(duplicateSlot).toBe(firstSlot);
    expect(secondSlot.id).toBe(secondManager.getSessionId());
  });

  it("reads only the admitted file's own header when a cold open has no cached admission", async () => {
    const fixture = await coldFixture("uncached");
    await settleCatalog(fixture.registry);
    const walks = catalogWalks();
    const before = walks.count();
    const headers = catalogHeaderReads();
    try {
      expect((await fixture.registry.acquire(fixture.manager.getSessionId())).id).toBe(fixture.manager.getSessionId());
      expect(fixture.runtimeFactory).toHaveBeenCalledTimes(1);
      // Membership is the owner's row; the open reads no other file and walks
      // nothing.
      expect(walks.count()).toBe(before);
      expect(headers.paths().length).toBeGreaterThan(0);
      expect(new Set(headers.paths().map((path) => basename(path)))).toEqual(new Set([basename(fixture.sessionFile)]));
    } finally {
      walks.restore();
      headers.restore();
    }
  });

  it("ignores jsonl-named directories during lightweight acquisition", async () => {
    const fixture = await coldFixture("jsonl-directory");
    await mkdir(join(fixture.agentDir, "sessions", "unrelated.jsonl"));
    await settleCatalog(fixture.registry);
    const walks = catalogWalks();
    const before = walks.count();
    try {
      expect((await fixture.registry.acquire(fixture.manager.getSessionId())).id)
        .toBe(fixture.manager.getSessionId());
      // A directory whose name ends in .jsonl is no row, and the open walks
      // nothing to decide that.
      expect((await fixture.registry.catalog("all")).sessions.map((session) => session.id))
        .toEqual([fixture.manager.getSessionId()]);
      expect(walks.count()).toBe(before);
    } finally {
      walks.restore();
    }
  });

  it("keeps an unprovable artifact out of the index without blinding the cut", async () => {
    const reconciled: SessionCatalogReconcileOutcome[] = [];
    const fixture = await coldFixture("ignored-artifacts", { catalogReconciled: (outcome) => reconciled.push(outcome) });
    const artifactDirectory = join(fixture.agentDir, "sessions", "workspace", "subagent-artifacts");
    await mkdir(artifactDirectory, { recursive: true });
    await writeFile(join(artifactDirectory, "worker.jsonl"), `${JSON.stringify({ recordType: "message", text: "diagnostic" })}\n`);
    reconciled.length = 0;
    await settleCatalog(fixture.registry);

    const listed = await fixture.registry.catalog("all");
    expect(listed.sessions.map((session) => session.id)).toEqual([fixture.manager.getSessionId()]);
    // A producer's artifact folder is ignored by the owner's traversal, so the
    // pass still reconciles and adds no row for it.
    expect(reconciled.at(-1)).toMatchObject({ outcome: "reconciled" });

    const walks = catalogWalks();
    const before = walks.count();
    try {
      expect((await fixture.registry.catalog("all")).sessions.map((session) => session.id))
        .toEqual([fixture.manager.getSessionId()]);
      expect(walks.count()).toBe(before);
    } finally {
      walks.restore();
    }
  });

    it("keeps an unrelated malformed header out of the cut without a fallback scan", async () => {
    const reconciled: SessionCatalogReconcileOutcome[] = [];
    const fixture = await coldFixture("malformed-fallback", { catalogReconciled: (outcome) => reconciled.push(outcome) });
    const unrelated = join(fixture.agentDir, "sessions", "unrelated");
    await mkdir(unrelated, { recursive: true });
    await writeFile(join(unrelated, "malformed.jsonl"), `${"x".repeat(70_000)}\n`);
    reconciled.length = 0;
    await settleCatalog(fixture.registry);
    const walks = catalogWalks();
    try {
      expect((await fixture.registry.acquire(fixture.manager.getSessionId())).id)
        .toBe(fixture.manager.getSessionId());
      // The unreadable neighbour is unproven: it neither forces a second
      // discovery pass nor removes the admitted session from the cut, and its
      // unknown membership keeps every destructive caller off this cut.
      expect(reconciled.at(-1)).toMatchObject({ outcome: "incomplete" });
      expect(reconciled.at(-1)!.unproven).toBeGreaterThan(0);
      expect(catalogOwner(fixture.registry).hasReconciledCut()).toBe(false);
      expect((await fixture.registry.catalog("all")).sessions.map((session) => session.id))
        .toEqual([fixture.manager.getSessionId()]);
      expect(walks.count()).toBe(0);
    } finally {
      walks.restore();
    }
  });

    it("invalidates reusable acquisition when a duplicate or removal changes canonical membership", async () => {
    const duplicateFixture = await coldFixture("duplicate-membership");
    await settleCatalog(duplicateFixture.registry);
    const duplicateDirectory = join(duplicateFixture.agentDir, "sessions", "duplicate");
    await mkdir(duplicateDirectory, { recursive: true });
    await copyFile(
      duplicateFixture.sessionFile,
      join(duplicateDirectory, "duplicate.jsonl"),
    );
    await settleCatalog(duplicateFixture.registry);
    // One ID, two canonical files: neither may be resolved, so the list omits
    // the ID entirely.
    expect((await duplicateFixture.registry.catalog("all")).sessions).toHaveLength(0);

    await expect(duplicateFixture.registry.acquire(duplicateFixture.manager.getSessionId())).rejects.toMatchObject({
      code: "conflict",
    });
    expect(duplicateFixture.runtimeFactory).not.toHaveBeenCalled();
    await rm(join(duplicateDirectory, "duplicate.jsonl"));
    await settleCatalog(duplicateFixture.registry);
    expect((await duplicateFixture.registry.acquire(duplicateFixture.manager.getSessionId())).id)
      .toBe(duplicateFixture.manager.getSessionId());
    const duplicateAgain = join(duplicateDirectory, "duplicate-again.jsonl");
    await copyFile(duplicateFixture.sessionFile, duplicateAgain);
    await settleCatalog(duplicateFixture.registry);
    await expect(duplicateFixture.registry.acquire(duplicateFixture.manager.getSessionId())).rejects.toMatchObject({
      code: "conflict",
    });
    await rm(duplicateAgain);
    await settleCatalog(duplicateFixture.registry);
    expect((await duplicateFixture.registry.acquire(duplicateFixture.manager.getSessionId())).id)
      .toBe(duplicateFixture.manager.getSessionId());

    const removedFixture = await coldFixture("removed-membership");
    await settleCatalog(removedFixture.registry);
    await rm(removedFixture.sessionFile);
    await settleCatalog(removedFixture.registry);

    await expect(removedFixture.registry.acquire(removedFixture.manager.getSessionId())).rejects.toMatchObject({
      code: "not_found",
    });
    expect(removedFixture.runtimeFactory).not.toHaveBeenCalled();
  });

  it("recognizes only the exact delegated-session producer topology", async () => {
    const fixture = await coldFixture("delegated-topology");
    const root = join(fixture.agentDir, "sessions", "topology");
    const timestamp = new Date().toISOString();
    const header = (id: string, parentSession?: string) => `${JSON.stringify({
      type: "session", version: 3, id, timestamp, cwd: fixture.cwd,
      ...(parentSession ? { parentSession } : {}),
    })}\n`;
    const parent = join(root, "parent.jsonl");
    const topLevelParented = join(root, "ordinary-fork.jsonl");
    const fork = join(root, "parent", "forks", "fork.jsonl");
    const fresh = join(root, "parent", "worker", "run-0", "session.jsonl");
    const interrupted = join(root, "parent", "reviewer", "run-1", "session.jsonl");
    const contradictory = join(root, "parent", "worker", "run-2", "session.jsonl");
    const extraDepthRun = join(root, "parent", "worker", "run-3", "extra", "session.jsonl");
    const extraDepthFork = join(root, "parent", "forks", "extra", "fork.jsonl");
    const wrongRunBasename = join(root, "parent", "worker", "run-4", "child.jsonl");
    const arbitraryDeep = join(root, "parent", "arbitrary", "deep", "session.jsonl");
    await Promise.all([...new Set([parent, fork, fresh, interrupted, contradictory,
      extraDepthRun, extraDepthFork, wrongRunBasename, arbitraryDeep, topLevelParented]
      .map((path) => dirname(path)))].map((directory) => mkdir(directory, { recursive: true })));
    await Promise.all([
      writeFile(parent, header("parent")),
      writeFile(topLevelParented, header("ordinary", parent)),
      writeFile(fork, header("fork", parent)),
      writeFile(fresh, header("fresh")),
      writeFile(interrupted, header("interrupted")),
      writeFile(contradictory, header("contradictory", topLevelParented)),
      writeFile(extraDepthRun, header("extra-run")),
      writeFile(extraDepthFork, header("extra-fork", parent)),
      writeFile(wrongRunBasename, header("wrong-basename")),
      writeFile(arbitraryDeep, header("deep")),
    ]);

    // Requirement: only the exact pi-subagents reserved layouts beneath the
    // canonical catalog are delegated sessions; any neighbouring depth or
    // basename stays an ordinary user session, and a contradictory parent
    // header keeps the reserved child immutable without publishing a row.
    await settleCatalog(fixture.registry);
    const rows = new Map((await fixture.registry.catalog("all")).sessions.map((row) => [row.id, row]));
    expect(rows.get("fork")).toMatchObject({ kind: "subagent", parentSessionId: "parent" });
    expect(rows.get("fresh")).toMatchObject({ kind: "subagent" });
    expect(rows.get("fresh")?.parentSessionId).toBeUndefined();
    expect(rows.get("interrupted")?.kind).toBe("subagent");
    for (const id of ["extra-run", "extra-fork", "wrong-basename", "deep", "ordinary"]) {
      expect(rows.get(id)?.kind).toBe("user");
    }
    expect(rows.has("contradictory")).toBe(false);
    expect(existsSync(contradictory)).toBe(true);
    await expect(fixture.registry.acquire("contradictory")).rejects.toMatchObject({ code: "conflict" });
    await expect(fixture.registry.delete("contradictory")).rejects.toMatchObject({ code: "conflict" });
  });

  it("does not infer delegated identity from names, titles, or generic depth", async () => {
    const nestedFixture = await coldFixture("nested-user", { nested: true });
    expect((await nestedFixture.registry.catalog("all")).sessions.find(
      (session) => session.id === nestedFixture.manager.getSessionId(),
    )?.kind).toBe("user");
    expect((await nestedFixture.registry.acquire(nestedFixture.manager.getSessionId())).id)
      .toBe(nestedFixture.manager.getSessionId());

    const namedFixture = await coldFixture("named-user", { name: "subagent-catalog-child" });
    expect((await namedFixture.registry.acquire(namedFixture.manager.getSessionId())).id)
      .toBe(namedFixture.manager.getSessionId());

    const renamedFixture = await coldFixture("renamed-user");
    const beforeRename = await renamedFixture.registry.catalog("all");
    renamedFixture.manager.appendSessionInfo("subagent-renamed-after-catalog");
    expect((await renamedFixture.registry.catalog("all")).listRevision).toBe(beforeRename.listRevision);
    expect((await renamedFixture.registry.acquire(renamedFixture.manager.getSessionId())).id)
      .toBe(renamedFixture.manager.getSessionId());
  });

  it("rejects identity, cwd, or duplicate mutation before runtime creation", async () => {
    for (const field of ["id", "cwd"] as const) {
      const fixture = await coldFixture(`${field}-race`);
      await fixture.registry.catalog("all");
      const replacementCwd = join(fixture.root, "replacement-workspace");
      await mkdir(replacementCwd);
      const internals = fixture.registry as unknown as {
        catalogAcquisition: () => Promise<unknown>;
      };
      const original = internals.catalogAcquisition.bind(fixture.registry);
      const admission = vi.spyOn(internals, "catalogAcquisition").mockImplementation(async () => {
        const acquired = await original();
        // The file changes after admission and before the commit fence, which
        // re-reads this exact file's header.
        const lines = (await readFile(fixture.sessionFile, "utf8")).split("\n");
        const header = JSON.parse(lines[0]!) as Record<string, unknown>;
        lines[0] = JSON.stringify({
          ...header,
          [field]: field === "id" ? "replacement-session-id" : replacementCwd,
        });
        await writeFile(fixture.sessionFile, lines.join("\n"));
        return acquired;
      });

      try {
        await expect(fixture.registry.acquire(fixture.manager.getSessionId())).rejects.toMatchObject({
          code: "conflict",
        });
        expect(fixture.runtimeFactory).not.toHaveBeenCalled();
      } finally {
        admission.mockRestore();
      }
    }

    // A duplicate claimant that the owner has indexed makes the ID ambiguous, and
    // no acquisition may create a runtime for it.
    const duplicateFixture = await coldFixture("duplicate-race");
    await settleCatalog(duplicateFixture.registry);
    const duplicateDirectory = join(duplicateFixture.agentDir, "sessions", "duplicate-gap");
    await mkdir(duplicateDirectory, { recursive: true });
    await copyFile(duplicateFixture.sessionFile, join(duplicateDirectory, "duplicate.jsonl"));
    await settleCatalog(duplicateFixture.registry);
    await expect(duplicateFixture.registry.acquire(duplicateFixture.manager.getSessionId()))
      .rejects.toMatchObject({ code: "conflict" });
    expect(duplicateFixture.runtimeFactory).not.toHaveBeenCalled();
  });

  it("opens a cold session while unrelated catalog files appear in the admission gap", async () => {
    const fixture = await coldFixture("unrelated-open-churn");
    await fixture.registry.catalog("all");
    const internals = fixture.registry as unknown as { catalogAcquisition: () => Promise<unknown> };
    const original = internals.catalogAcquisition.bind(fixture.registry);
    const admission = vi.spyOn(internals, "catalogAcquisition").mockImplementation(async () => {
      const acquired = await original();
      // An active parent's subagent writes a new delegated child, and another
      // client creates an unrelated session, before this open validates.
      const childDirectory = join(fixture.agentDir, "sessions", "active-parent", "worker", "run-0");
      await mkdir(childDirectory, { recursive: true });
      await writeFile(join(fixture.agentDir, "sessions", "active-parent.jsonl"), `${JSON.stringify({
        type: "session", version: 3, id: "active-parent", timestamp: new Date().toISOString(), cwd: fixture.cwd,
      })}\n`);
      await writeFile(join(childDirectory, "session.jsonl"), `${JSON.stringify({
        type: "session", version: 3, id: "active-child", timestamp: new Date().toISOString(), cwd: fixture.cwd,
      })}\n`);
      return acquired;
    });
    try {
      expect((await fixture.registry.acquire(fixture.manager.getSessionId())).id).toBe(fixture.manager.getSessionId());
      expect(fixture.runtimeFactory).toHaveBeenCalledTimes(1);
    } finally {
      admission.mockRestore();
    }
  });

  it("does not follow a session path replaced by a symlink during delete", async () => {
    const fixture = await coldFixture("delete-symlink-race");
    await settleCatalog(fixture.registry);
    const moved = `${fixture.sessionFile}.moved`;
    const external = join(fixture.root, "external.jsonl");
    const externalContent = `${JSON.stringify({
      type: "session", version: 3, id: fixture.manager.getSessionId(),
      timestamp: new Date().toISOString(), cwd: fixture.cwd,
    })}\n`;
    await writeFile(external, externalContent);
    // The path is a symlink by the time the deletion commits: its own stat is the
    // fence that refuses to follow it, and the aliased file is untouched.
    await rename(fixture.sessionFile, moved);
    await symlink(external, fixture.sessionFile);

    await expect(fixture.registry.delete(fixture.manager.getSessionId())).rejects.toMatchObject({
      code: "conflict",
    });
    expect(await readFile(external, "utf8")).toBe(externalContent);
    expect(existsSync(moved)).toBe(true);
  });

  it("revalidates parent creation, duplicate identity, and topology changes in the delete gap", async () => {
    for (const mutation of ["parent", "duplicate", "topology"] as const) {
      const fixture = await coldFixture(`delete-catalog-gap-${mutation}`);
      await settleCatalog(fixture.registry);
      const mutationDirectory = join(fixture.agentDir, "sessions", `delete-gap-${mutation}`);
      const movedFile = join(mutationDirectory, "owner", "worker", "run-0", "session.jsonl");
      const internals = fixture.registry as unknown as {
        removeCanonicalCatalogFile: (...arguments_: any[]) => Promise<void>;
      };
      const original = internals.removeCanonicalCatalogFile.bind(fixture.registry);
      vi.spyOn(internals, "removeCanonicalCatalogFile").mockImplementation(async (...arguments_) => {
        await mkdir(mutationDirectory, { recursive: true });
        if (mutation === "parent") {
          await writeFile(join(mutationDirectory, "new-parent.jsonl"), `${JSON.stringify({
            type: "session", version: 3, id: "new-parent", timestamp: new Date().toISOString(), cwd: fixture.cwd,
          })}\n`);
        } else if (mutation === "duplicate") {
          await copyFile(fixture.sessionFile, join(mutationDirectory, "duplicate.jsonl"));
          // A claimant the owner has indexed is an ambiguity the commit sees.
          await settleCatalog(fixture.registry);
        } else {
          await mkdir(dirname(movedFile), { recursive: true });
          await rename(fixture.sessionFile, movedFile);
        }
        return original(...arguments_);
      });

      if (mutation === "parent") {
        // A new unrelated parent file is not evidence about this session, so the
        // deletion still commits: the index, not a whole-tree scan, is the
        // membership authority.
        await fixture.registry.delete(fixture.manager.getSessionId());
        expect(existsSync(fixture.sessionFile)).toBe(false);
      } else {
        await expect(fixture.registry.delete(fixture.manager.getSessionId())).rejects.toMatchObject({
          code: mutation === "duplicate" ? "conflict" : "not_found",
        });
        expect(existsSync(mutation === "topology" ? movedFile : fixture.sessionFile)).toBe(true);
      }
    }
  });

  it("retains persisted, ambiguous, and live-only artifact owners without reading transcript metadata", async () => {
    const fixture = await coldFixture("maintenance-header-membership");
    const parentFile = fixture.manager.getSessionFile()!;
    const forks = join(dirname(parentFile), basename(parentFile, ".jsonl"), "forks");
    await mkdir(forks, { recursive: true });
    const child = SessionManager.forkFrom(parentFile, fixture.cwd, forks);
    child.appendMessage(fauxAssistantMessage("child"));
    // A complete line the index can prove, so this case measures membership
    // rather than an in-progress append (its unprovable-neighbour half uses the
    // header-less file below).
    await appendFile(child.getSessionFile()!, '{"type":"message"}\n');
    await copyFile(parentFile, join(forks, "ambiguous.jsonl"));
    const live = await fixture.registry.create(fixture.cwd);
    await settleCatalog(fixture.registry);
    const walks = catalogWalks();
    const before = walks.count();
    try {
      // Membership is the index and the live slots: the maintenance read parses
      // no transcript and walks nothing.
      const ids = await fixture.registry.sessionIDsForStorageMaintenance();
      expect([...ids].sort()).toEqual([fixture.manager.getSessionId(), child.getSessionId(), live.id].sort());
      expect(walks.count()).toBe(before);
      // An unprovable neighbour adds no row and removes none: its membership is
      // unknown, so the maintenance read refuses retryably rather than reporting
      // any owner as gone.
      await writeFile(join(dirname(parentFile), "incomplete-header.jsonl"), "{}");
      await settleCatalog(fixture.registry);
      await expect(fixture.registry.sessionIDsForStorageMaintenance())
        .rejects.toMatchObject({ code: "busy", retryable: true });
      expect(walks.count()).toBeGreaterThan(before);
    } finally { walks.restore(); }
  });

      it("scans only canonical user metadata for a user catalog and reserves all-scope indexing", async () => {
    const fixture = await coldFixture("user-metadata-cut");
    const parentFile = fixture.manager.getSessionFile()!;
    const forksDirectory = join(dirname(parentFile), basename(parentFile, ".jsonl"), "forks");
    await mkdir(forksDirectory, { recursive: true });
    const child = SessionManager.forkFrom(parentFile, fixture.cwd, forksDirectory);
    child.appendMessage(fauxAssistantMessage("delegated body that user catalog must not materialize"));

    await settleCatalog(fixture.registry);
    const walks = catalogWalks();
    const before = walks.count();
    try {
      // A user cut resolves only the non-delegated rows; the all-scope cut
      // resolves the delegated child too, from the same owner rows.
      const user = await fixture.registry.catalog("user");
      expect(user.sessions.map((session) => session.id)).toEqual([fixture.manager.getSessionId()]);
      const all = await fixture.registry.catalog("all");
      expect(all.sessions.map((session) => session.id)).toEqual(
        expect.arrayContaining([fixture.manager.getSessionId(), child.getSessionId()]),
      );
      expect(walks.count()).toBe(before);
    } finally {
      walks.restore();
    }
  });

        it("publishes child reference availability only after exact binding becomes authoritative", async () => {
    const fixture = await coldFixture("binding-availability");
    const slot = await fixture.registry.acquire(fixture.manager.getSessionId());
    const timestamp = new Date().toISOString();
    const activity: ExtensionRunActivity = {
      id: "tool", toolCallId: "tool", runId: "run", source: { source: "project", owner: { id: "extension:pi-subagents", title: "Subagents", source: "project" } }, title: "Subagents", mode: "asynchronous",
      status: "running", startedAt: timestamp, updatedAt: timestamp,
      lifecycle: { version: 1, state: "running", attention: "none", sequence: 1, observedAt: timestamp },
      children: [
        { id: "worker", producerId: "worker", label: "worker", status: "running", lifecycle: "running", childSessionRef: "child" },
        { id: "other", producerId: "other", label: "other", status: "running", lifecycle: "running", childSessionRef: "child" },
      ],
    };
    const internals = slot as any;
    internals.syncSubagentProcesses(activity);
    const waiting = slot.snapshot().processActivities!.find(row => row.title === "worker")!;
    expect(waiting.childSessionRef).toBeUndefined();
    activity.children.pop();
    activity.lifecycle!.sequence = 2;
    internals.syncSubagentProcesses(activity);
    const ready = slot.snapshot().processActivities!.find(row => row.processId === waiting.processId)!;
    expect(ready.childSessionRef).toBe("child");
    expect(slot.processChildSessionBinding(ready.processId)).toMatchObject({ ref: "child", producerId: "worker" });
  });

    it("uses complete headers to quarantine user IDs duplicated by delegated files", async () => {
    const fixture = await coldFixture("user-duplicate-delegated");
    const parentFile = fixture.manager.getSessionFile()!;
    const forksDirectory = join(dirname(parentFile), basename(parentFile, ".jsonl"), "forks");
    await mkdir(forksDirectory, { recursive: true });
    const duplicatePath = join(forksDirectory, "duplicate.jsonl");
    await copyFile(parentFile, duplicatePath);

    await settleCatalog(fixture.registry);
    const user = await fixture.registry.catalog("user");
    expect(user.sessions.find((session) => session.id === fixture.manager.getSessionId())).toBeUndefined();
    const allDuplicate = await fixture.registry.catalog("all");
    expect(allDuplicate.sessions.find((session) => session.id === fixture.manager.getSessionId())).toBeUndefined();
    await expect(fixture.registry.acquire(fixture.manager.getSessionId()))
      .rejects.toMatchObject({ code: "conflict" });

    await rm(duplicatePath);
    const child = SessionManager.forkFrom(parentFile, fixture.cwd, forksDirectory);
    child.appendMessage(fauxAssistantMessage("contradictory delegated header"));
    const childFile = child.getSessionFile()!;
    const childLines = (await readFile(childFile, "utf8")).split("\n");
    childLines[0] = JSON.stringify({ ...JSON.parse(childLines[0]!), parentSession: join(fixture.agentDir, "sessions", "not-the-parent.jsonl") });
    await writeFile(childFile, childLines.join("\n"));
    // Both files above are this test's own writes: index them before reading.
    await settleCatalog(fixture.registry);

    const repairedUser = await fixture.registry.catalog("user");
    expect(repairedUser.sessions.map((session) => session.id)).toContain(fixture.manager.getSessionId());
    const all = await fixture.registry.catalog("all");
    expect(all.sessions.map((session) => session.id)).not.toContain(child.getSessionId());
  });

  it("retains user catalog and search admission while parallel delegated sessions append", async () => {
    const fixture = await coldFixture("user-index-parallel-children");
    const parentFile = fixture.manager.getSessionFile()!;
    const forks = join(dirname(parentFile), basename(parentFile, ".jsonl"), "forks");
    await mkdir(forks, { recursive: true });
    const children = Array.from({ length: 3 }, () => SessionManager.forkFrom(parentFile, fixture.cwd, forks));
    children.forEach(child => child.appendMessage(fauxAssistantMessage("child starts")));
    const parentID = fixture.manager.getSessionId();
    const walks = catalogWalks();
    const before = walks.count();
    try {
      expect((await fixture.registry.catalog("user")).sessions.map(row => row.id)).toEqual([parentID]);
      children.forEach(child => child.appendMessage(fauxAssistantMessage("parallel child progress")));
      // The children are external writers; index them, then the user cut must
      // still resolve the parent and a live-only session without a walk.
      await settleCatalog(fixture.registry);
      const live = await fixture.registry.create(fixture.cwd);
      const results = await Promise.all([
        fixture.registry.catalog("user"), fixture.registry.catalog("user"), fixture.registry.readSearchCut(parentID),
      ]);
      for (const result of results.slice(0, 2) as Awaited<ReturnType<RuntimeRegistry["catalog"]>>[]) {
        expect(result.sessions.map(row => row.id)).toEqual(expect.arrayContaining([parentID, live.id]));
        expect(result.sessions).toHaveLength(2);
      }
      expect(results[2]).toMatchObject({ summary: { id: parentID } });
      const settled = walks.count();
      // A partial acceleration must never hide children from administration.
      const all = await fixture.registry.catalog("all");
      expect(all.sessions.map(row => row.id)).toEqual(expect.arrayContaining(children.map(child => child.getSessionId())));
      expect(walks.count()).toBe(settled);
      expect(settled).toBeGreaterThan(before);
    } finally { walks.restore(); }
  });

  it("refreshes user metadata and duplicate quarantine after a scoped cut is warm", async () => {
    const fixture = await coldFixture("scoped-index-refresh");
    const parentFile = fixture.manager.getSessionFile()!;
    const forks = join(dirname(parentFile), basename(parentFile, ".jsonl"), "forks");
    await mkdir(forks, { recursive: true });
    const child = SessionManager.forkFrom(parentFile, fixture.cwd, forks);
    child.appendMessage(fauxAssistantMessage("child"));
    const parentID = fixture.manager.getSessionId();
    await settleCatalog(fixture.registry);
    const initialPage = await fixture.registry.pageSource("user");
    fixture.manager.appendSessionInfo("Updated canonical name");
    // The rename is this test's own write: index it, then the page source must be
    // a different projection of a different row.
    await settleCatalog(fixture.registry);
    const refreshedPage = await fixture.registry.pageSource("user");
    expect(refreshedPage).not.toBe(initialPage);
    expect((await refreshedPage.page(0, 500)).find(row => row.id === parentID)?.name).toBe("Updated canonical name");
    await copyFile(parentFile, join(forks, "duplicate.jsonl"));
    await settleCatalog(fixture.registry);
    expect((await fixture.registry.catalog("user")).sessions.some(row => row.id === parentID)).toBe(false);
    await expect(fixture.registry.acquire(parentID)).rejects.toMatchObject({ code: "conflict" });
  });

  it("advances user catalog identity when canonical membership changes beside delegated rows", async () => {
    const fixture = await coldFixture("user-membership-revision");
    const parentFile = fixture.manager.getSessionFile()!;
    const forksDirectory = join(dirname(parentFile), basename(parentFile, ".jsonl"), "forks");
    await mkdir(forksDirectory, { recursive: true });
    const child = SessionManager.forkFrom(parentFile, fixture.cwd, forksDirectory);
    child.appendMessage(fauxAssistantMessage("delegated membership fixture"));

    await settleCatalog(fixture.registry);
    const initial = await fixture.registry.pageSource("user");
    const secondDirectory = join(fixture.agentDir, "sessions", "second");
    await mkdir(secondDirectory, { recursive: true });
    const second = SessionManager.create(fixture.cwd, secondDirectory);
    second.appendMessage(fauxAssistantMessage("new canonical user session"));
    await settleCatalog(fixture.registry);
    const added = await fixture.registry.pageSource("user");
    expect(added.generation).not.toBe(initial.generation);
    expect((await fixture.registry.catalog("user")).sessions.map((session) => session.id))
      .toContain(second.getSessionId());

    await rm(second.getSessionFile()!);
    await settleCatalog(fixture.registry);
    const removed = await fixture.registry.pageSource("user");
    expect(removed.generation).not.toBe(added.generation);
    expect((await fixture.registry.catalog("user")).sessions.map((session) => session.id))
      .not.toContain(second.getSessionId());
  });

  it("reports files over the header budget as unproven and refuses an over-budget acquisition retryably", async () => {
    const fixture = await coldFixture("header-bound");
    const reconciled: SessionCatalogReconcileOutcome[] = [];
    const headerRegistry = new RuntimeRegistry({
      agentDir: fixture.agentDir,
      tronHome: join(fixture.root, "tron-header-bound"),
      idleRuntimeMs: 60_000,
      trust: new TrustService(fixture.agentDir),
      broadcast: () => {},
      sessionSummaryChanged: () => {},
      sessionListChanged: () => {},
      catalogDiscoveryLimits: { maximumHeaderBytes: 1 },
      catalogReconciled: (outcome) => reconciled.push(outcome),
    });
    registries.push(headerRegistry);
    const walks = catalogWalks();
    try {
      await headerRegistry.initialize();
      await catalogOwner(headerRegistry).whenReconciled();
      // The per-file header budget cannot prove this file, so no row is added for
      // it and the pass still reports a complete traversal (G-1c).
      expect(reconciled.at(-1)).toMatchObject({ outcome: "incomplete" });
      expect(reconciled.at(-1)!.unproven).toBe(1);
      expect((await headerRegistry.catalog("all")).sessions).toEqual([]);
      // The read serves the owner's cut and walks nothing.
      const settled = walks.count();
      expect((await headerRegistry.catalog("all")).sessions).toEqual([]);
      expect(walks.count()).toBe(settled);
    } finally {
      walks.restore();
    }

    const admissionRegistry = new RuntimeRegistry({
      agentDir: fixture.agentDir,
      tronHome: join(fixture.root, "tron-admission-bound"),
      idleRuntimeMs: 60_000,
      trust: new TrustService(fixture.agentDir),
      broadcast: () => {},
      sessionSummaryChanged: () => {},
      sessionListChanged: () => {},
      catalogDiscoveryLimits: { maximumAcquisitionBytes: 1 },
    });
    registries.push(admissionRegistry);
    await admissionRegistry.initialize();
    await catalogOwner(admissionRegistry).whenReconciled();
    // The identity-retention budget cannot hold any row, so every file is
    // unproven: the acquisition refuses retryably instead of reporting the
    // session as absent.
    expect((await admissionRegistry.catalog("all")).sessions).toEqual([]);
    await expect(admissionRegistry.acquire(fixture.manager.getSessionId()))
      .rejects.toMatchObject({ code: "busy", retryable: true, diagnosticReason: "catalog_not_ready" });
  });

  it("admits scaled short headers within the aggregate validation budget", async () => {
    const root = await mkdtemp(join(tmpdir(), "tron-catalog-short-header-budget-"));
    const agentDir = join(root, "agent");
    const directory = join(agentDir, "sessions", "workspace");
    const cwd = join(root, "workspace");
    const count = 64;
    await Promise.all([mkdir(directory, { recursive: true }), mkdir(cwd)]);
    await Promise.all(Array.from({ length: count }, (_, index) => writeFile(
      join(directory, `session-${index}.jsonl`),
      `${JSON.stringify({
        type: "session",
        version: 3,
        id: `session-${index}`,
        timestamp: "2026-01-01T00:00:00.000Z",
        cwd,
      })}\n${"x".repeat(4_096)}\n`,
    )));
    const registry = new RuntimeRegistry({
      agentDir,
      tronHome: join(root, "tron"),
      idleRuntimeMs: 60_000,
      trust: new TrustService(agentDir),
      broadcast: () => {},
      sessionSummaryChanged: () => {},
      sessionListChanged: () => {},
      catalogDiscoveryLimits: {
        maximumSessions: count,
        maximumHeaderBytes: count * 512,
        normalizationConcurrency: 4,
      },
    });
    registries.push(registry);
    const original = CatalogDiscovery.prototype.readCatalogHeader;
    let active = 0;
    let maximumActive = 0;
    let releaseResolve!: () => void;
    let capacityResolve!: () => void;
    const release = new Promise<void>((resolve) => { releaseResolve = resolve; });
    const capacity = new Promise<void>((resolve) => { capacityResolve = resolve; });
    const headers = vi.spyOn(CatalogDiscovery.prototype, "readCatalogHeader").mockImplementation(
      async function (this: CatalogDiscovery, ...arguments_: Parameters<CatalogDiscovery["readCatalogHeader"]>) {
        active += 1;
        maximumActive = Math.max(maximumActive, active);
        if (maximumActive === 4) capacityResolve();
        await release;
        try { return await original.apply(this, arguments_); }
        finally { active -= 1; }
      },
    );

    const discovery = new CatalogDiscovery({
      limits: {
        ...DEFAULT_CATALOG_DISCOVERY_LIMITS,
        maximumSessions: count,
        maximumHeaderBytes: count * 512,
        normalizationConcurrency: 4,
      },
      catalogDirectory: () => directory,
      catalogCapacityExceeded: () => { throw new Error("scaled catalog bound exceeded"); },
      isLiveRuntimeOwnedPath: () => false,
      canonicalSessionPath: (path) => realpath(path),
      delegatedTopologyParentPath: () => undefined,
    });
    const evidence = discovery.catalogStructureEvidence();
    await capacity;
    expect(maximumActive).toBe(4);
    releaseResolve();
    expect((await evidence).identitiesByPath.size).toBe(count);
    expect(headers).toHaveBeenCalledTimes(count);
    headers.mockRestore();
    await initializeRegistry(registry);
    expect((await registry.catalog("all")).sessions).toHaveLength(count);
  });

  it("keeps a child mutation-protected when its parent ID is duplicated", async () => {
    const root = await mkdtemp(join(tmpdir(), "tron-catalog-duplicate-parent-"));
    const agentDir = join(root, "agent");
    const directory = join(agentDir, "sessions", "workspace");
    const duplicateDirectory = join(agentDir, "sessions", "duplicate-workspace");
    const cwd = join(root, "workspace");
    await Promise.all([
      mkdir(directory, { recursive: true }),
      mkdir(duplicateDirectory, { recursive: true }),
      mkdir(cwd),
    ]);
    const timestamp = new Date().toISOString();
    const parentId = "ambiguous-parent";
    const parentFile = join(directory, `${parentId}.jsonl`);
    const header = `${JSON.stringify({ type: "session", version: 3, id: parentId, timestamp, cwd })}\n`;
    await Promise.all([
      writeFile(parentFile, header),
      writeFile(join(duplicateDirectory, "duplicate.jsonl"), header),
    ]);
    const childDirectory = join(directory, parentId, "worker", "run-0");
    await mkdir(childDirectory, { recursive: true });
    const childId = "child-of-ambiguous-parent";
    await writeFile(join(childDirectory, "session.jsonl"), `${JSON.stringify({
      type: "session", version: 3, id: childId, timestamp, cwd,
    })}\n`);
    const registry = new RuntimeRegistry({
      agentDir,
      tronHome: join(root, "tron"),
      idleRuntimeMs: 60_000,
      trust: new TrustService(agentDir),
      broadcast: () => {},
      sessionSummaryChanged: () => {},
      sessionListChanged: () => {},
    });
    registries.push(registry);

    await initializeRegistry(registry);
    await settleCatalog(registry);
    const all = await registry.catalog("all");
    expect(all.sessions.map((session) => session.id)).not.toContain(parentId);
    expect(all.sessions.find((session) => session.id === childId)).toMatchObject({ kind: "subagent" });
    await expect(registry.acquire(childId)).rejects.toMatchObject({ code: "conflict" });
    await expect(registry.delete(childId)).rejects.toMatchObject({ code: "conflict" });
  });

  it("omits a reserved child with a contradictory parent header without making it mutable", async () => {
    const root = await mkdtemp(join(tmpdir(), "tron-catalog-contradictory-header-"));
    const agentDir = join(root, "agent");
    const directory = join(agentDir, "sessions", "workspace");
    const cwd = join(root, "workspace");
    await Promise.all([mkdir(directory, { recursive: true }), mkdir(cwd)]);
    const timestamp = new Date().toISOString();
    const parentId = "expected-parent";
    const parentFile = join(directory, `${parentId}.jsonl`);
    const otherParentFile = join(directory, "other-parent.jsonl");
    await Promise.all([
      writeFile(parentFile, `${JSON.stringify({ type: "session", version: 3, id: parentId, timestamp, cwd })}\n`),
      writeFile(otherParentFile, `${JSON.stringify({
        type: "session", version: 3, id: "other-parent", timestamp, cwd,
      })}\n`),
    ]);
    const childDirectory = join(directory, parentId, "worker", "run-0");
    await mkdir(childDirectory, { recursive: true });
    const childId = "contradictory-child";
    const childFile = join(childDirectory, "session.jsonl");
    await writeFile(childFile, `${JSON.stringify({
      type: "session", version: 3, id: childId, timestamp, cwd, parentSession: otherParentFile,
    })}\n`);
    const registry = new RuntimeRegistry({
      agentDir,
      tronHome: join(root, "tron"),
      idleRuntimeMs: 60_000,
      trust: new TrustService(agentDir),
      broadcast: () => {},
      sessionSummaryChanged: () => {},
      sessionListChanged: () => {},
    });
    registries.push(registry);

    await initializeRegistry(registry);
    await settleCatalog(registry);
    expect((await registry.catalog("all")).sessions.map((session) => session.id)).not.toContain(childId);
    const acquisition = await (registry as unknown as {
      catalogAcquisition: () => Promise<{
        entriesByID: ReadonlyMap<string, { structuralSubagent: boolean }>;
      }>;
    }).catalogAcquisition();
    expect(acquisition.entriesByID.get(childId)?.structuralSubagent).toBe(true);
    await expect(registry.acquire(childId)).rejects.toMatchObject({ code: "conflict" });
    await expect(registry.delete(childId)).rejects.toMatchObject({ code: "conflict" });
    expect(existsSync(childFile)).toBe(true);
  });

  it("keeps a reserved child delegated after its parent is deleted and ignores later title metadata", async () => {
    const root = await mkdtemp(join(tmpdir(), "tron-catalog-parent-deleted-"));
    const agentDir = join(root, "agent");
    const directory = join(agentDir, "sessions", "workspace");
    const cwd = join(root, "workspace");
    await Promise.all([mkdir(directory, { recursive: true }), mkdir(cwd)]);
    const timestamp = new Date().toISOString();
    const parentId = "deleted-parent";
    const parentFile = join(directory, `${parentId}.jsonl`);
    await writeFile(parentFile, `${JSON.stringify({
      type: "session", version: 3, id: parentId, timestamp, cwd,
    })}\n`);
    const childDirectory = join(directory, parentId, "worker", "run-0");
    await mkdir(childDirectory, { recursive: true });
    const childId = "interrupted-before-title";
    const childFile = join(childDirectory, "session.jsonl");
    await writeFile(childFile, `${JSON.stringify({
      type: "session", version: 3, id: childId, timestamp, cwd,
    })}\n`);
    const registry = new RuntimeRegistry({
      agentDir,
      tronHome: join(root, "tron"),
      idleRuntimeMs: 60_000,
      trust: new TrustService(agentDir),
      broadcast: () => {},
      sessionSummaryChanged: () => {},
      sessionListChanged: () => {},
    });
    registries.push(registry);

    await initializeRegistry(registry);
    await settleCatalog(registry);
    expect((await registry.catalog("all")).sessions.find((session) => session.id === childId)?.kind)
      .toBe("subagent");
    await rm(parentFile);
    const withoutParent = await registry.catalog("all");
    expect(withoutParent.sessions.find((session) => session.id === childId)?.kind).toBe("subagent");
    await writeFile(childFile, `${await readFile(childFile, "utf8")}${JSON.stringify({
      type: "session_info", id: "late-title", parentId: null, timestamp,
      name: "ordinary title",
    })}\n`);
    const afterTitle = await registry.catalog("all");
    expect(afterTitle.listRevision).toBe(withoutParent.listRevision);
    expect(afterTitle.sessions.find((session) => session.id === childId)?.kind).toBe("subagent");
    await expect(registry.acquire(childId)).rejects.toMatchObject({ code: "conflict" });
    await expect(registry.delete(childId)).rejects.toMatchObject({ code: "conflict" });
  });

  it("classifies a 1,541-file catalog using positive topology only", async () => {
    const root = await mkdtemp(join(tmpdir(), "tron-catalog-topology-scale-"));
    const agentDir = join(root, "agent");
    const directory = join(agentDir, "sessions", "workspace");
    const cwd = join(root, "workspace");
    await Promise.all([mkdir(directory, { recursive: true }), mkdir(cwd)]);
    const timestamp = new Date().toISOString();
    const parentId = "scale-parent";
    const parentFile = join(directory, `${parentId}.jsonl`);
    const incidentId = "incident-top-level-parented";
    await Promise.all([
      writeFile(parentFile, `${JSON.stringify({ type: "session", version: 3, id: parentId, timestamp, cwd })}\n`),
      writeFile(join(directory, `${incidentId}.jsonl`), `${JSON.stringify({
        type: "session", version: 3, id: incidentId, timestamp, cwd, parentSession: parentFile,
      })}\n`),
      ...Array.from({ length: 1_538 }, (_, index) => writeFile(
        join(directory, `ordinary-${String(index).padStart(4, "0")}.jsonl`),
        `${JSON.stringify({ type: "session", version: 3, id: `ordinary-${index}`, timestamp, cwd })}\n`,
      )),
    ]);
    const childDirectory = join(directory, parentId, "worker", "run-0");
    await mkdir(childDirectory, { recursive: true });
    const childId = "scale-interrupted-child";
    await writeFile(join(childDirectory, "session.jsonl"), `${JSON.stringify({
      type: "session", version: 3, id: childId, timestamp, cwd,
    })}\n`);
    const registry = new RuntimeRegistry({
      agentDir,
      tronHome: join(root, "tron"),
      idleRuntimeMs: 60_000,
      trust: new TrustService(agentDir),
      broadcast: () => {},
      sessionSummaryChanged: () => {},
      sessionListChanged: () => {},
    });
    registries.push(registry);

    await initializeRegistry(registry);
    await settleCatalog(registry);
    const all = await registry.catalog("all");
    expect(all.sessions).toHaveLength(1_541);
    expect(all.sessions.find((session) => session.id === childId)?.kind).toBe("subagent");
    expect(all.sessions.find((session) => session.id === incidentId)?.kind).toBe("user");
    expect((await registry.list("user")).map((session) => session.id)).not.toContain(childId);
  }, 30_000);

  it("closes the catalog header handle when the tail probe fails", async () => {
    const fixture = await coldFixture("header-read-failure");
    const probePath = join(fixture.root, "isolated-header.jsonl");
    await copyFile(fixture.manager.getSessionFile()!, probePath);
    const handle = await fsPromises.open(probePath, "r");
    const identity = await handle.stat();
    const originalRead = handle.read;
    const failure = new Error("injected tail read failure");
    let failedHandle: typeof handle | undefined;
    const read = vi.spyOn(Object.getPrototypeOf(handle), "read").mockImplementation(async function (this: typeof handle, ...args: any[]) {
      const current = await this.stat();
      if (current.dev === identity.dev && current.ino === identity.ino) {
        failedHandle = this;
        throw failure;
      }
      return originalRead.apply(this, args as any);
    });
    const internals = fixture.registry as unknown as {
      readCatalogHeader: (path: string, maximumBytes: number, reserve: () => boolean, refund: () => void) => Promise<unknown>;
    };
    try {
      await expect(internals.readCatalogHeader(probePath, 1024, () => true, () => {}))
        .rejects.toBe(failure);
      expect(failedHandle).toBeDefined();
      await expect(failedHandle!.stat()).rejects.toMatchObject({ code: "EBADF" });
    } finally {
      read.mockRestore();
      await handle.close();
      await failedHandle?.close();
      await rm(fixture.root, { recursive: true, force: true });
    }
  });

  it("reserves a deterministic aggregate header-read budget across concurrent readers", async () => {
    const root = await mkdtemp(join(tmpdir(), "tron-catalog-strict-header-budget-"));
    const agentDir = join(root, "agent");
    const directory = join(agentDir, "sessions", "workspace");
    const cwd = join(root, "workspace");
    await Promise.all([mkdir(directory, { recursive: true }), mkdir(cwd)]);
    await Promise.all(Array.from({ length: 8 }, (_, index) => writeFile(
      join(directory, `session-${index}.jsonl`),
      `${JSON.stringify({
        type: "session",
        id: `session-${index}`,
        cwd: index < 4 ? "/x" : "x".repeat(200),
      })}\n${"x".repeat(4_096)}\n`,
    )));
    const registry = new RuntimeRegistry({
      agentDir,
      tronHome: join(root, "tron"),
      idleRuntimeMs: 60_000,
      trust: new TrustService(agentDir),
      broadcast: () => {},
      sessionSummaryChanged: () => {},
      sessionListChanged: () => {},
      catalogDiscoveryLimits: {
        maximumHeaderBytes: 2 * 512,
        normalizationConcurrency: 4,
      },
    });
    registries.push(registry);
    const internals = registry as unknown as {
      catalogStructureEvidence: () => Promise<{
        complete: boolean;
        digest: string;
        identitiesByPath: ReadonlyMap<string, unknown>;
      }>;
    };

    const first = await internals.catalogStructureEvidence();
    const second = await internals.catalogStructureEvidence();
    // The traversal covered the folder; the files whose header exceeded the
    // aggregate budget are unproven instead of blinding the whole cut (G-1c).
    expect(first.complete).toBe(true);
    expect(first.unprovenPaths.size).toBeGreaterThan(0);
    expect(first.identitiesByPath.size).toBe(4);
    expect([...first.identitiesByPath.keys()]).toEqual([...second.identitiesByPath.keys()]);
    expect(first.digest).toBe(second.digest);
  });

    it("orders history by parsed recency while active heartbeats keep stable positions", async () => {
    const root = await mkdtemp(join(tmpdir(), "tron-catalog-time-precision-"));
    const agentDir = join(root, "agent");
    const cwd = join(root, "workspace");
    const sessionDirectory = join(agentDir, "sessions", "workspace");
    await Promise.all([mkdir(sessionDirectory, { recursive: true }), mkdir(cwd)]);
    process.env.PI_CODING_AGENT_DIR = agentDir;
    const whole = SessionManager.create(cwd, sessionDirectory);
    whole.appendMessage(fauxAssistantMessage("whole"));
    const fraction = SessionManager.create(cwd, sessionDirectory);
    fraction.appendMessage(fauxAssistantMessage("fraction"));
    const registry = new RuntimeRegistry({
      agentDir,
      tronHome: join(root, "tron"),
      idleRuntimeMs: 60_000,
      trust: new TrustService(agentDir),
      broadcast: () => {},
      sessionSummaryChanged: () => {},
      sessionListChanged: () => {},
    });
    registries.push(registry);
    await initializeRegistry(registry);
    const internals = registry as unknown as {
      latestSummaries: Map<string, SessionSummaryUpdate>;
      publishRevisionedSummary: (summary: SessionSummaryUpdate) => void;
    };
    const summary = (sessionId: string, updatedAt: string): SessionSummaryUpdate => ({
      sessionId,
      summaryRevision: 1,
      phase: "idle",
      updatedAt,
      messageCount: 1,
      firstMessage: "",
      completionRevision: 0,
      attentionRevision: 0,
      isUnread: false,
    });
    internals.latestSummaries.set(whole.getSessionId(), summary(whole.getSessionId(), "2026-01-01T00:00:00Z"));
    internals.latestSummaries.set(fraction.getSessionId(), summary(fraction.getSessionId(), "2026-01-01T00:00:00.900Z"));

    const catalog = await registry.catalog("user");
    expect(catalog.sessions.map((session) => session.id).slice(0, 2)).toEqual([
      fraction.getSessionId(),
      whole.getSessionId(),
    ]);

    internals.publishRevisionedSummary({
      ...summary(whole.getSessionId(), "2026-01-01T00:10:00Z"),
      phase: "running",
      activeSince: "2026-01-01T00:02:00Z",
    });
    internals.publishRevisionedSummary({
      ...summary(fraction.getSessionId(), "2026-01-01T00:20:00Z"),
      phase: "running",
      activeSince: "2026-01-01T00:01:00Z",
    });
    const activeCatalog = await registry.catalog("user");
    expect(activeCatalog.sessions.map((session) => session.id).slice(0, 2)).toEqual([
      whole.getSessionId(),
      fraction.getSessionId(),
    ]);

    internals.publishRevisionedSummary({
      ...summary(fraction.getSessionId(), "2026-01-01T00:30:00Z"),
      phase: "running",
      activeSince: "2026-01-01T00:01:00Z",
    });
    const heartbeatCatalog = await registry.catalog("user");
    expect(heartbeatCatalog.sessions.map((session) => session.id).slice(0, 2)).toEqual([
      whole.getSessionId(),
      fraction.getSessionId(),
    ]);
  });

    it("matches a full scan after create, rename, fork and delete in the catalog index", async () => {
    const root = await mkdtemp(join(tmpdir(), "tron-catalog-index-mutations-"));
    const agentDir = join(root, "agent");
    const cwd = join(root, "workspace");
    const sessions = join(agentDir, "sessions");
    await Promise.all([mkdir(sessions, { recursive: true }), mkdir(cwd)]);
    const runtime = await ModelRuntime.create({ modelsPath: null, refreshOnCreate: false });
    const faux = fauxProvider({ provider: "tron-catalog-index", tokensPerSecond: 10_000 });
    faux.setResponses([fauxAssistantMessage("catalog index ready"), fauxAssistantMessage("catalog index forked")]);
    runtime.registerNativeProvider(faux.provider);
    const registry = new RuntimeRegistry({
      agentDir,
      tronHome: join(root, "tron"),
      idleRuntimeMs: 60_000,
      modelRuntimeFactory: async () => runtime,
      trust: new TrustService(agentDir),
      broadcast: () => {},
      sessionSummaryChanged: () => {},
      sessionListChanged: () => {},
    });
    registries.push(registry);
    await initializeRegistry(registry);
    const catalog = (registry as unknown as { sessionCatalog: SessionCatalog }).sessionCatalog;
    const catalogRoot = await realpath(sessions);
    // The comparison is the Gateway's own walk of the folder plus one read of
    // every canonical file, never the index's rows, so an index row is checked
    // against the file it was built from.
    const discovery = new CatalogDiscovery({
      limits: DEFAULT_CATALOG_DISCOVERY_LIMITS,
      catalogDirectory: () => catalogRoot,
      catalogCapacityExceeded: () => { throw new Error("catalog capacity exceeded"); },
      isLiveRuntimeOwnedPath: () => false,
      canonicalSessionPath: (path) => realpath(path).catch(() => path),
      delegatedTopologyParentPath: () => undefined,
    });
    const compareToFullScan = async (label: string) => {
      const walked = await discovery.catalogStructureEvidence();
      const scanned = (await Promise.all(
        [...walked.identitiesByPath.keys()].map(async (path) => {
          const info = await buildCatalogSessionInfo(path);
          if (!info) return null;
          return {
            ...info,
            path: await realpath(info.path),
            ...(info.parentSessionPath ? { parentSessionPath: await realpath(info.parentSessionPath) } : {}),
          };
        }),
      )).filter((info): info is CatalogSessionInfo => info !== null);
      const rows = catalog.rows();
      expect(rows.map((row) => row.path), `${label}: paths`).toEqual(scanned.map((session) => session.path));
      expect(rows.map((row) => [
        row.id,
        resolve(row.cwd),
        row.parentSessionPath === undefined ? undefined : resolve(row.parentSessionPath),
        row.name,
        row.firstMessage,
        row.messageCount,
        row.createdAt,
        row.updatedAt,
      ]), `${label}: metadata`).toEqual(scanned.map((session) => [
        session.id,
        resolve(session.cwd),
        session.parentSessionPath === undefined ? undefined : resolve(session.parentSessionPath),
        session.name,
        session.firstMessage,
        session.messageCount,
        session.created.toISOString(),
        session.modified.toISOString(),
      ]));
      for (const row of rows) {
        const stats = await fsPromises.lstat(row.path);
        expect([row.fileIdentity, row.size, row.eofOffset], `${label}: file facts`)
          .toEqual([`${stats.dev}:${stats.ino}`, stats.size, stats.size]);
      }
    };

    // create: a fresh session persists its first canonical entry.
    const live = await registry.create(cwd);
    const model = faux.getModel();
    await live.setModel(model.provider, model.id);
    await live.prompt("catalog index create");
    await waitFor(() => !live.isBusy, "the live slot to go idle");
    await catalog.settled();
    await compareToFullScan("create");
    expect(catalog.rows().map((row) => row.id)).toContain(live.id);

    // rename: the session name the dashboard shows.
    await live.rename("catalog index renamed");
    await catalog.settled();
    await compareToFullScan("rename");
    expect(catalog.row(await realpath(live.sessionFile!))?.name).toBe("catalog index renamed");

    // fork: the replacement identity persists its own canonical file.
    const forkedId = live.snapshot().runtimeGeneration;
    const userEntry = live.history(forkedId).nodes.find((node) => node.role === "user");
    expect(userEntry?.id).toBeTruthy();
    const forked = await live.fork(userEntry!.id, "at");
    // Pi reserves the forked session's path; its first entry persists the file.
    await live.prompt("catalog index fork entry");
    await waitFor(() => !live.isBusy, "the live slot to go idle");
    await catalog.settled();
    await compareToFullScan("fork");
    expect(catalog.rows().map((row) => row.id)).toContain(forked.sessionId);
    expect([...catalog.duplicateSessionIds()]).toEqual([]);

    // delete: the deleted session's canonical file is gone.
    await registry.delete(forked.sessionId);
    await catalog.settled();
    await compareToFullScan("delete");
    expect(catalog.rows().some((row) => row.id === forked.sessionId)).toBe(false);
  });

  it("fails closed when multiple canonical files claim one session ID", async () => {
    const root = await mkdtemp(join(tmpdir(), "tron-catalog-duplicate-id-"));
    const agentDir = join(root, "agent");
    const cwd = join(root, "workspace");
    await Promise.all([mkdir(agentDir), mkdir(cwd)]);
    const runtime = await ModelRuntime.create({ modelsPath: null, refreshOnCreate: false });
    const faux = fauxProvider({ provider: "tron-duplicate-session-id", tokensPerSecond: 10_000 });
    faux.setResponses([fauxAssistantMessage("persisted")]);
    runtime.registerNativeProvider(faux.provider);
    const registry = new RuntimeRegistry({
      agentDir,
      tronHome: join(root, "tron"),
      idleRuntimeMs: 60_000,
      modelRuntimeFactory: async () => runtime,
      trust: new TrustService(agentDir),
      broadcast: () => {},
      sessionSummaryChanged: () => {},
      sessionListChanged: () => {},
    });
    registries.push(registry);
    await initializeRegistry(registry);
    const slot = await registry.create(cwd);
    const model = faux.getModel();
    await slot.setModel(model.provider, model.id);
    await slot.prompt("persist duplicate ownership fixture");
    await waitFor(() => !slot.isBusy, "the slot to go idle");
    await settleCatalog(registry);
    const duplicatePath = join(agentDir, "sessions", "duplicate", `${slot.id}.jsonl`);
    await mkdir(dirname(duplicatePath), { recursive: true });
    await copyFile(slot.persistedSessionFile!, duplicatePath);
    await settleCatalog(registry);

    // The cut is keyed by canonical path, so enumeration order cannot move it, and
    // an ID two files claim resolves to neither.
    const conflicted = await registry.catalog("all");
    expect(conflicted.sessions.find((session) => session.id === slot.id)).toBeUndefined();
    const reordered = await registry.catalog("all");
    expect(reordered.listRevision).toBe(conflicted.listRevision);
    expect(reordered.sessions.find((session) => session.id === slot.id)).toBeUndefined();
    // Both runtime acquisition and deletion fail closed against the current
    // canonical duplicate rather than trusting a stale projected row.
    await expect(registry.acquire(slot.id)).rejects.toMatchObject({ code: "conflict" });
    await expect(registry.delete(slot.id)).rejects.toMatchObject({ code: "conflict" });
    await rm(duplicatePath);
    await settleCatalog(registry);

    const repaired = await registry.catalog("all");
    expect(repaired.sessions.filter((session) => session.id === slot.id)).toHaveLength(1);
    expect((await registry.acquire(slot.id)).id).toBe(slot.id);
  });

  it("keeps 128 parallel parent runs discoverable through child churn and repeated client reentry", async () => {
    const root = await mkdtemp(join(tmpdir(), "tron-scale-qualification-"));
    const agentDir = join(root, "agent");
    const projects = Array.from({ length: 8 }, (_, index) => join(root, `project-${index}`));
    await Promise.all(projects.map(cwd => mkdir(cwd, { recursive: true })));
    process.env.PI_CODING_AGENT_DIR = agentDir;
    const managers: SessionManager[] = [];
    const children: SessionManager[] = [];
    for (let index = 0; index < 128; index++) {
      const cwd = projects[index % projects.length]!;
      const directory = join(agentDir, "sessions", `project-${index % projects.length}`);
      await mkdir(directory, { recursive: true });
      const manager = SessionManager.create(cwd, directory);
      manager.appendMessage(fauxAssistantMessage(`parent-${index}`));
      managers.push(manager);
      const forks = join(directory, basename(manager.getSessionFile()!, ".jsonl"), "forks");
      await mkdir(forks, { recursive: true });
      for (let child = 0; child < 3; child++) {
        const fork = SessionManager.forkFrom(manager.getSessionFile()!, cwd, forks);
        fork.appendMessage(fauxAssistantMessage(`child-${index}-${child}`));
        children.push(fork);
      }
    }
    let release!: () => void;
    const barrier = new Promise<void>(resolve => { release = resolve; });
    const faux = fauxProvider({ provider: "tron-scale-test", tokensPerSecond: 100_000 });
    faux.setResponses(managers.map((_, index) => async () => { await barrier; return fauxAssistantMessage(`complete-${index}`); }));
    const runtimeFactory = vi.fn(async () => {
      const runtime = await ModelRuntime.create({ modelsPath: null, refreshOnCreate: false });
      runtime.registerNativeProvider(faux.provider);
      return runtime;
    });
    const registry = new RuntimeRegistry({ agentDir, tronHome: join(root, "tron"), idleRuntimeMs: 60_000,
      maximumLiveRuntimes: DEFAULT_MAX_LIVE_RUNTIMES, modelRuntimeFactory: runtimeFactory,
      trust: new TrustService(agentDir), broadcast: () => {}, sessionSummaryChanged: () => {}, sessionListChanged: () => {} });
    registries.push(registry);
    let acquisitions: Promise<unknown>[] = [];
    try {
      await initializeRegistry(registry);
      acquisitions = managers.flatMap(manager => [registry.acquire(manager.getSessionId()), registry.acquire(manager.getSessionId())]);
      const acquired = await Promise.all(acquisitions) as Awaited<ReturnType<RuntimeRegistry["acquire"]>>[];
      const slots = acquired.filter((_, index) => index % 2 === 0);
      for (let index = 0; index < slots.length; index++) expect(acquired[index * 2 + 1]).toBe(slots[index]);
      const model = faux.getModel();
      await Promise.all(slots.map(async (slot, index) => { await slot.setModel(model.provider, model.id); await slot.prompt(`work-${index}`); }));
      await waitFor(() => faux.state.callCount === 128, "all 128 slots to reach the model");
      expect(registry.activeSessionIds()).toHaveLength(128);
      const expected = managers.map(manager => manager.getSessionId()).sort();
      for (let wave = 0; wave < 3; wave++) {
        for (const child of children) child.appendMessage(fauxAssistantMessage(`progress-${wave}`));
        registry.unsubscribeClient("phone");
        const catalogs = await Promise.all(Array.from({ length: 8 }, () => registry.catalog("user")));
        for (const catalog of catalogs) expect(catalog.sessions.map(row => row.id).sort()).toEqual(expected);
        for (let index = 0; index < slots.length; index++) {
          const slot = slots[(index + wave) % slots.length]!;
          registry.subscribe("phone", slot.id);
          expect(await registry.acquire(slot.id)).toBe(slot);
          expect(slot.snapshot().sessionId).toBe(slot.id);
          registry.unsubscribeClient("phone");
        }
        expect(registry.activeSessionIds()).toHaveLength(128);
        expect(runtimeFactory).toHaveBeenCalledTimes(128);
      }
      release();
      await registry.waitUntilIdle();
      expect(registry.activeSessionIds()).toHaveLength(0);
      for (const slot of slots) expect(slot.snapshot().transcript.some(item => JSON.stringify(item).includes("complete-"))).toBe(true);
    } finally {
      release(); await Promise.allSettled(acquisitions); await registry.dispose();
      await rm(root, { recursive: true, force: true });
    }
  }, 60_000);

  it("runs distinct sessions concurrently and keeps a run alive after its client disconnects", async () => {
    const root = await mkdtemp(join(tmpdir(), "tron-runtime-integration-"));
    const agentDir = join(root, "agent");
    const tronHome = join(root, "tron");
    const firstCwd = join(root, "first");
    const secondCwd = join(root, "second");
    await Promise.all([mkdir(agentDir), mkdir(tronHome), mkdir(firstCwd), mkdir(secondCwd)]);
    process.env.PI_CODING_AGENT_DIR = agentDir;

    const faux = fauxProvider({ provider: "tron-test", tokensPerSecond: 10_000 });
    const runtimes: ModelRuntime[] = [];
    const summaryUpdates: SessionSummaryUpdate[] = [];
    const createModels = async () => {
      const runtime = await ModelRuntime.create({ modelsPath: null, refreshOnCreate: false });
      runtime.registerNativeProvider(faux.provider);
      runtimes.push(runtime);
      return runtime;
    };
    faux.setResponses([
      async () => { await new Promise((resolve) => setTimeout(resolve, 150)); return fauxAssistantMessage("first complete"); },
      async () => { await new Promise((resolve) => setTimeout(resolve, 150)); return fauxAssistantMessage("second complete"); },
    ]);

    const registry = new RuntimeRegistry({
      agentDir,
      tronHome,
      idleRuntimeMs: 60_000,
      modelRuntimeFactory: createModels,
      trust: new TrustService(agentDir),
      broadcast: () => {},
      sessionSummaryChanged: (summary) => summaryUpdates.push(summary),
      sessionListChanged: () => {},
    });
    registries.push(registry);
    await initializeRegistry(registry);

    const [first, second] = await Promise.all([registry.create(firstCwd), registry.create(secondCwd)]);
    expect(first.modelRuntime).not.toBe(second.modelRuntime);
    expect(runtimes).toHaveLength(2);
    const model = faux.getModel();
    await Promise.all([first.setModel(model.provider, model.id), second.setModel(model.provider, model.id)]);
    registry.subscribe("phone", first.id);
    registry.subscribe("phone", second.id);

    await Promise.all([first.prompt("one"), second.prompt("two")]);
    await waitFor(() => first.isBusy && second.isBusy && faux.state.callCount === 2, "both slots running their first turn");
    expect(faux.state.callCount).toBe(2);
    expect(summaryUpdates).toEqual(expect.arrayContaining([
      expect.objectContaining({
        sessionId: first.id, phase: "running", foregroundPhase: "running", hasActiveSubagents: false,
      }),
      expect.objectContaining({
        sessionId: second.id, phase: "running", foregroundPhase: "running", hasActiveSubagents: false,
      }),
    ]));
    const beforeHeartbeat = summaryUpdates.findLast((update) => update.sessionId === first.id)!;
    expect(beforeHeartbeat.activeSince).toBeDefined();
    await new Promise((resolve) => setTimeout(resolve, 2));
    (first as unknown as { publishActivityHeartbeat: () => void }).publishActivityHeartbeat();
    const afterHeartbeat = summaryUpdates.findLast((update) => update.sessionId === first.id)!;
    expect(Date.parse(afterHeartbeat.updatedAt)).toBeGreaterThan(Date.parse(beforeHeartbeat.updatedAt));
    expect(afterHeartbeat.activeSince).toBe(beforeHeartbeat.activeSince);

    registry.unsubscribeClient("phone");
    expect(first.isBusy).toBe(true);
    expect(second.isBusy).toBe(true);
    let drainCompleted = false;
    const drain = registry.waitUntilIdle().then(() => { drainCompleted = true; });
    await new Promise((resolve) => setTimeout(resolve, 30));
    expect(drainCompleted).toBe(false);

    await waitFor(() => !first.isBusy && !second.isBusy, "both slots to go idle");
    await drain;
    expect(drainCompleted).toBe(true);
    const hasCompletion = (slot: typeof first) => slot.snapshot().transcript.some(
      (item) => item.kind === "message" && item.role === "assistant" && item.content.some(
        (part) => part.type === "text" && part.text.includes("complete"),
      ),
    );
    expect(hasCompletion(first)).toBe(true);
    expect(hasCompletion(second)).toBe(true);
    expect(summaryUpdates.filter((update) => update.phase === "idle").map((update) => update.sessionId)).toEqual(
      expect.arrayContaining([first.id, second.id]),
    );
    expect(summaryUpdates.filter((update) => update.phase === "idle").every(
      (update) => update.activeSince === undefined,
    )).toBe(true);
  });

  it("lets accepted follow-up queue work execute naturally during administrative drain", async () => {
    const root = await mkdtemp(join(tmpdir(), "tron-restart-queue-drain-"));
    const agentDir = join(root, "agent");
    const cwd = join(root, "workspace");
    await Promise.all([mkdir(agentDir), mkdir(cwd)]);
    let releaseFirst!: () => void;
    const firstBarrier = new Promise<void>((resolve) => { releaseFirst = resolve; });
    const faux = fauxProvider({ provider: "tron-queue-drain", tokensPerSecond: 10_000 });
    faux.setResponses([
      async () => { await firstBarrier; return fauxAssistantMessage("first"); },
      fauxAssistantMessage("queued complete"),
    ]);
    const registry = new RuntimeRegistry({
      agentDir, tronHome: join(root, "tron"), idleRuntimeMs: 60_000,
      modelRuntimeFactory: async () => {
        const runtime = await ModelRuntime.create({ modelsPath: null, refreshOnCreate: false });
        runtime.registerNativeProvider(faux.provider);
        return runtime;
      },
      trust: new TrustService(agentDir), broadcast: () => {},
      sessionSummaryChanged: () => {}, sessionListChanged: () => {},
    });
    registries.push(registry);
    await initializeRegistry(registry);
    const slot = await registry.create(cwd);
    const model = faux.getModel();
    await slot.setModel(model.provider, model.id);
    await slot.prompt("first");
    await waitFor(() => slot.isBusy, "the slot to take work");
    const queued = await slot.prompt("accepted follow up", [], "followUp");
    expect(slot.snapshot().queuedItems).toMatchObject([{ id: queued.operationId, behavior: "followUp" }]);
    let drained = false;
    const drain = registry.waitUntilIdle().then(() => { drained = true; });
    await new Promise((resolve) => setTimeout(resolve, 25));
    expect(drained).toBe(false);
    expect(slot.snapshot().queuedItems).toHaveLength(1);
    releaseFirst();
    await waitFor(() => faux.state.callCount === 2, "the second model call");
    await drain;
    expect(drained).toBe(true);
    expect(slot.snapshot().queuedItems).toEqual([]);
    expect(slot.snapshot().transcript.some((item) => item.kind === "message" && item.role === "assistant"
      && item.content.some((part) => part.type === "text" && part.text.includes("queued complete")))).toBe(true);
  });

  it("settles foreground completion without a second derived token", async () => {
    const root = await mkdtemp(join(tmpdir(), "tron-completion-capacity-"));
    const agentDir = join(root, "agent");
    const cwd = join(root, "workspace");
    await Promise.all([mkdir(agentDir), mkdir(cwd)]);
    let releaseResponse!: () => void;
    const responseBarrier = new Promise<void>((resolve) => { releaseResponse = resolve; });
    const faux = fauxProvider({ provider: "tron-completion-capacity", tokensPerSecond: 10_000 });
    faux.setResponses([async () => { await responseBarrier; return fauxAssistantMessage("complete"); }]);
    const workRegistry = new GatewayWorkRegistry("epoch", 4);
    const registry = new RuntimeRegistry({
      agentDir, tronHome: join(root, "tron"), idleRuntimeMs: 60_000, workRegistry,
      modelRuntimeFactory: async () => {
        const runtime = await ModelRuntime.create({ modelsPath: null, refreshOnCreate: false });
        runtime.registerNativeProvider(faux.provider);
        return runtime;
      },
      trust: new TrustService(agentDir), broadcast: () => {},
      sessionSummaryChanged: () => {}, sessionListChanged: () => {},
    });
    registries.push(registry);
    await initializeRegistry(registry);
    const slot = await registry.create(cwd);
    const model = faux.getModel();
    await slot.setModel(model.provider, model.id);
    await slot.prompt("finish while derived capacity is full");
    await waitFor(() => slot.catalogPhase === "running", "the catalog phase to run");
    const derived = [0, 1].map(() => workRegistry.beginDerived({
      kind: "administrative-provider-package-operation",
      hostEpoch: workRegistry.runtimeEpoch,
    }));

    releaseResponse();
    await waitFor(() => slot.catalogPhase === "idle", "the catalog phase to go idle");
    expect(workRegistry.facts().filter((fact) => fact.sessionId === slot.id)).toEqual([]);
    for (const owner of derived) owner.settle();
  });

  it("includes runtime creation admitted before administrative drain", async () => {
    const root = await mkdtemp(join(tmpdir(), "tron-restart-create-drain-"));
    const agentDir = join(root, "agent");
    const cwd = join(root, "workspace");
    await Promise.all([mkdir(agentDir), mkdir(cwd)]);

    const trust = new TrustService(agentDir);
    const resolveTrust = trust.requireResolved.bind(trust);
    let markTrustEntered!: () => void;
    const trustEntered = new Promise<void>((resolve) => { markTrustEntered = resolve; });
    let releaseTrust!: () => void;
    const trustBarrier = new Promise<void>((resolve) => { releaseTrust = resolve; });
    vi.spyOn(trust, "requireResolved").mockImplementation(async (input) => {
      markTrustEntered();
      await trustBarrier;
      return resolveTrust(input);
    });
    const registry = new RuntimeRegistry({
      agentDir,
      tronHome: join(root, "tron"),
      idleRuntimeMs: 60_000,
      modelRuntimeFactory: async () => ModelRuntime.create({ modelsPath: null, refreshOnCreate: false }),
      trust,
      broadcast: () => {},
      sessionSummaryChanged: () => {},
      sessionListChanged: () => {},
    });
    registries.push(registry);
    await initializeRegistry(registry);

    const creating = registry.create(cwd);
    await trustEntered;
    expect(registry.drainBusySessionCount()).toBe(1);
    const initialDrain = registry.beginAdministrativeDrain();
    expect(initialDrain).toMatchObject({
      phase: "preparing",
      blockerCount: 1,
      blockerCounts: { "slot-admission": 1 },
      omittedCount: 0,
      suspectProjectionCount: 0,
    });
    expect(initialDrain.blockers).toHaveLength(1);
    expect(initialDrain.blockers[0]?.id).toMatch(/^blocker-[0-9a-f]{20}$/u);
    expect(JSON.stringify(initialDrain)).not.toContain(cwd);
    const repeatedDrain = registry.beginAdministrativeDrain();
    expect(repeatedDrain.drainId).toBe(initialDrain.drainId);
    expect(repeatedDrain.revision).toBeGreaterThanOrEqual(initialDrain.revision);
    let drainSettled = false;
    const drain = registry.waitUntilIdle().then(() => { drainSettled = true; });
    await new Promise((resolve) => setTimeout(resolve, 25));
    expect(drainSettled).toBe(false);
    expect(registry.drainBusySessionCount()).toBe(1);
    await expect(registry.create(cwd)).rejects.toMatchObject({ code: "busy", retryable: true });

    releaseTrust();
    const slot = await creating;
    await drain;
    expect(drainSettled).toBe(true);
    expect(slot.isDrainBusy).toBe(false);
    await expect(slot.prompt("post-cutoff prompt")).rejects.toMatchObject({ code: "busy" });
    expect(slot.snapshot().queuedItems).toEqual([]);
    expect(registry.administrativeDrainSnapshot()).toMatchObject({ phase: "complete", blockerCount: 0 });
  });

  it("publishes detached extension work as current dashboard activity", async () => {
    const fixture = await coldFixture("detached-dashboard-activity");
    const slot = await fixture.registry.acquire(fixture.manager.getSessionId());
    const beforeActivity = await fixture.registry.catalog("user");
    const internal = slot as unknown as {
      extensionActivities: Map<string, ExtensionRunActivity>;
      upsertExtensionActivity: (activity: ExtensionRunActivity) => unknown;
      phase: SessionSummaryUpdate["phase"];
      publishSnapshot: () => void;
      publishExtensionActivity: (activity: ExtensionRunActivity) => void;
      publishActivityHeartbeat: () => void;
      extensionActivityAsOf: string;
    };
    const startedAt = new Date(Date.now() - 2_000).toISOString();
    const running: ExtensionRunActivity = {
      id: "async-tool",
      activityId: "async-activity",
      runId: "async-run",
      toolCallId: "async-tool",
      source: { source: "pi-subagents" },
      title: "Pi Subagents",
      mode: "asynchronous",
      status: "running",
      startedAt,
      updatedAt: startedAt,
      children: [],
      lifecycle: {
        version: 1,
        state: "running",
        attention: "none",
        sequence: 1,
        observedAt: startedAt,
      },
    };
    internal.phase = "running";
    internal.publishSnapshot();
    expect(fixture.summaries.at(-1)).toMatchObject({
      sessionId: slot.id,
      phase: "running",
      foregroundPhase: "running",
      hasActiveSubagents: false,
    });

    internal.extensionActivities.set(running.toolCallId, running);
    internal.upsertExtensionActivity(running);
    internal.publishExtensionActivity(running);
    expect(fixture.summaries.at(-1)).toMatchObject({
      sessionId: slot.id,
      phase: "running",
      foregroundPhase: "running",
      hasActiveSubagents: true,
    });

    // Parent settlement does not change aggregate phase while detached work is
    // active. The shallow foreground fact must still publish the visual-state
    // transition to every dashboard.
    internal.phase = "idle";
    internal.publishSnapshot();
    const active = fixture.summaries.at(-1)!;
    expect(active).toMatchObject({
      sessionId: slot.id,
      phase: "running",
      foregroundPhase: "idle",
      hasActiveSubagents: true,
    });
    expect(active.activeSince).toBeDefined();
    expect(Date.parse(active.updatedAt)).toBeGreaterThan(Date.parse(startedAt));
    await new Promise((resolve) => setTimeout(resolve, 2));
    internal.publishActivityHeartbeat();
    const heartbeat = fixture.summaries.at(-1)!;
    expect(Date.parse(heartbeat.updatedAt)).toBeGreaterThan(Date.parse(active.updatedAt));
    expect(heartbeat.activeSince).toBe(active.activeSince);
    const activeCatalog = await fixture.registry.catalog("user");
    expect(activeCatalog.listRevision).toBe(beforeActivity.listRevision);
    expect(activeCatalog.sessions[0]).toMatchObject({
      id: slot.id,
      phase: "running",
      foregroundPhase: "idle",
      hasActiveSubagents: true,
      updatedAt: heartbeat.updatedAt,
      activeSince: active.activeSince,
    });

    const terminalAt = new Date().toISOString();
    const completed: ExtensionRunActivity = {
      ...running,
      status: "completed",
      updatedAt: terminalAt,
      completedAt: terminalAt,
      lifecycle: {
        version: 1,
        state: "completed",
        attention: "none",
        sequence: 2,
        observedAt: terminalAt,
        terminalAt,
        recentUntil: new Date(Date.parse(terminalAt) + 900_000).toISOString(),
      },
    };
    internal.extensionActivities.set(completed.toolCallId, completed);
    internal.upsertExtensionActivity(completed);
    internal.publishExtensionActivity(completed);
    expect(fixture.summaries.at(-1)).toMatchObject({
      sessionId: slot.id,
      phase: "idle",
      foregroundPhase: "idle",
      hasActiveSubagents: false,
    });
    expect(fixture.summaries.at(-1)!.activeSince).toBeUndefined();
    expect(Date.parse(fixture.summaries.at(-1)!.updatedAt))
      .toBeGreaterThanOrEqual(Date.parse(heartbeat.updatedAt));

    // A cold artifact reconciliation may publish terminal history with a fresh
    // projection as-of time. That observation must not impersonate new work.
    const settledRecency = fixture.summaries.at(-1)!.updatedAt;
    internal.extensionActivityAsOf = new Date(Date.parse(settledRecency) + 60_000).toISOString();
    const staleTerminal = {
      ...completed,
      updatedAt: startedAt,
      lifecycle: {
        ...completed.lifecycle!,
        observedAt: startedAt,
        terminalAt: startedAt,
        recentUntil: startedAt,
      },
    };
    internal.publishExtensionActivity(staleTerminal);
    expect(fixture.summaries.at(-1)!.updatedAt).toBe(settledRecency);
    internal.publishActivityHeartbeat();
    expect(fixture.summaries.at(-1)!.updatedAt).toBe(settledRecency);
  });

  it.each(["complete", "failed"] as const)("reconciles an exact-owned historical %s artifact during administrative drain", async (terminalState) => {
    const fixture = await coldFixture("historical-terminal-drain");
    const slot = await fixture.registry.acquire(fixture.manager.getSessionId());
    const runId = "historical-terminal-run";
    const toolCallId = "historical-terminal-tool";
    const asyncDir = join(fixture.cwd, ".pi", "subagents", "async-subagent-runs", runId);
    await mkdir(asyncDir, { recursive: true });
    const startedAt = new Date(Date.now() - 5_000).toISOString();
    const internal = slot as unknown as {
      extensionActivities: Map<string, ExtensionRunActivity>;
      extensionRunOwnership: Map<string, { toolCallId: string; asyncDir?: string; terminal: boolean }>;
    };
    internal.extensionActivities.set(toolCallId, {
      id: toolCallId,
      activityId: "historical-terminal-activity",
      runId,
      toolCallId,
      source: { source: "pi-subagents" },
      title: "Pi Subagents",
      status: "running",
      startedAt,
      updatedAt: startedAt,
      children: [],
      lifecycle: {
        version: 1,
        state: "running",
        attention: "none",
        sequence: 1,
        observedAt: startedAt,
      },
    });
    internal.extensionRunOwnership.set(runId, { toolCallId, asyncDir, terminal: false });
    const registryInternal = fixture.registry as unknown as { artifactDiscoveryTimer?: NodeJS.Timeout };
    if (registryInternal.artifactDiscoveryTimer) clearInterval(registryInternal.artifactDiscoveryTimer);
    registryInternal.artifactDiscoveryTimer = undefined;
    await writeFile(join(asyncDir, "status.json"), JSON.stringify({
      runId,
      state: "running",
      startedAt: Date.parse(startedAt),
      lastUpdate: Date.now(),
    }));

    const receiptManager = (slot as unknown as {
      runtime: { session: { sessionManager: SessionManager } };
    }).runtime.session.sessionManager;
    const receiptAppend = terminalState === "complete"
      ? vi.spyOn(receiptManager, "appendCustomEntry").mockImplementationOnce(() => {
          throw new Error("injected receipt persistence failure");
        })
      : undefined;
    expect(slot.isDrainBusy).toBe(true);
    let drainSettled = false;
    const drain = fixture.registry.waitUntilIdle().then(() => { drainSettled = true; });
    await new Promise((resolve) => setTimeout(resolve, 25));
    (slot as unknown as { stopExtensionActivityWatcher: (id: string) => void })
      .stopExtensionActivityWatcher(toolCallId);
    expect(drainSettled).toBe(false);

    const endedAt = Date.now();
    await writeFile(join(asyncDir, "status.json"), JSON.stringify({
      // Deployed sessions may outlive the producer version that launched them.
      // pi-subagents persists after recording completion, so lastUpdate normally
      // follows endedAt. A later direct drain pass must reconcile this evidence
      // without watcher delivery or ambient discovery.
      runId,
      state: terminalState,
      startedAt: Date.parse(startedAt),
      endedAt,
      lastUpdate: endedAt + 1,
    }));

    await drain;
    expect(slot.isDrainBusy).toBe(false);
    expect(slot.snapshot().extensionActivities).toMatchObject([{
      toolCallId,
      status: terminalState === "failed" ? "failed" : "completed",
      lifecycle: { state: terminalState === "failed" ? "failed" : "completed" },
    }]);
    if (receiptAppend) expect(receiptAppend.mock.calls.length).toBeGreaterThanOrEqual(2);
  });

  it("drains an exact-owned paused workflow only after observed process-terminal proof", async () => {
    const fixture = await coldFixture("paused-process-terminal-drain");
    const slot = await fixture.registry.acquire(fixture.manager.getSessionId());
    const runId = "paused-process-terminal-run";
    const toolCallId = "paused-process-terminal-tool";
    const asyncDir = join(fixture.cwd, ".pi", "subagents", "async-subagent-runs", runId);
    await mkdir(asyncDir, { recursive: true });
    const started = Date.now() - 5_000;
    const internal = slot as unknown as {
      extensionActivities: Map<string, ExtensionRunActivity>;
      extensionRunOwnership: Map<string, {
        toolCallId: string; asyncDir?: string; terminal: boolean; pausedProcessQuiescentAt?: string;
      }>;
      stopExtensionActivityWatcher: (id: string) => void;
    };
    internal.extensionActivities.set(toolCallId, {
      id: toolCallId,
      activityId: "paused-process-terminal-activity",
      runId,
      toolCallId,
      source: { source: "pi-subagents" },
      title: "Pi Subagents",
      status: "running",
      startedAt: new Date(started).toISOString(),
      updatedAt: new Date(started + 1_000).toISOString(),
      children: [],
      lifecycle: {
        version: 1,
        state: "paused",
        attention: "needsAttention",
        sequence: 1,
        observedAt: new Date(started + 1_000).toISOString(),
      },
    });
    internal.extensionRunOwnership.set(runId, { toolCallId, asyncDir, terminal: false });
    await Promise.all([
      writeFile(join(asyncDir, "status.json"), JSON.stringify({
        lifecycleProjection: {
          version: 1, runId, generatedAt: started + 1_001,
          caps: { maxRuns: 1, maxChildrenPerNode: 8, maxDepth: 3, maxStringLength: 160, maxSerializedBytes: 30_720 },
          omitted: { runs: 0, children: 0, byteLimitExceeded: false },
          root: { id: runId, kind: "workflow", label: "paused workflow", state: "paused", startedAt: started, updatedAt: started + 1_001, endedAt: started + 1_000 },
        },
        lifecycleArtifactVersion: 3, runId, state: "paused", startedAt: started, endedAt: started + 1_000, lastUpdate: started + 1_001,
      })),
      writeFile(join(asyncDir, "process-terminal.json"), JSON.stringify({
        version: 1,
        state: "pending",
        runId,
        runnerProcessInstanceId: "runner-instance",
      })),
    ]);

    const drain = fixture.registry.waitUntilIdle();
    let drained = false;
    void drain.then(() => { drained = true; });
    await new Promise((resolve) => setTimeout(resolve, 50));
    internal.stopExtensionActivityWatcher(toolCallId);
    expect(drained).toBe(false);
    expect(fixture.registry.administrativeDrainSnapshot()).toMatchObject({
      phase: "waiting",
      blockerCount: 1,
      blockerCounts: { "detached-extension-run": 1 },
    });

    await writeFile(join(asyncDir, "process-terminal.json"), JSON.stringify({
      version: 1,
      state: "observed",
      runId,
      runnerProcessInstanceId: "runner-instance",
      observedAt: started + 1_500,
      instances: [{
        kind: "runner",
        processInstanceId: "runner-instance",
        closeObservedAt: started + 1_500,
        exitCode: 0,
        signal: null,
      }],
      resumeDisposition: "resumable",
    }));
    await slot.discoverExtensionArtifact(asyncDir);
    expect(internal.extensionRunOwnership.get(runId)?.pausedProcessQuiescentAt)
      .toBe(new Date(started + 1_500).toISOString());

    await drain;
    expect(slot.isDrainBusy).toBe(false);
    expect(fixture.registry.administrativeDrainSnapshot()).toMatchObject({
      phase: "complete", blockerCount: 0, suspectProjectionCount: 0,
    });
    expect(slot.snapshot().extensionActivities).toMatchObject([{
      toolCallId,
      status: "running",
      lifecycle: { state: "paused" },
    }]);
  });

  it.each(["recovered", "live-source", "foreign-owner", "unobserved-process"] as const)("admits exact auto-recovery handoff: %s", async (scenario) => {
    const fixture = await coldFixture("recovered-replacement-settlement");
    const slot = await fixture.registry.acquire(fixture.manager.getSessionId());
    const manager = (slot as unknown as { runtime: { session: { sessionManager: SessionManager } } }).runtime.session.sessionManager;
    const sourceRunId = "recovered-source-run";
    const replacementRunId = "recovered-replacement-run";
    const sourceToolCallId = "recovered-source-tool";
    const recoveryToolCallId = "recovered-steering-tool";
    const sourceDir = join(fixture.cwd, ".pi", "subagents", "async-subagent-runs", sourceRunId);
    const replacementDir = join(fixture.cwd, ".pi", "subagents", "async-subagent-runs", replacementRunId);
    await mkdir(sourceDir, { recursive: true });
    await mkdir(replacementDir, { recursive: true });
    const providerOrigin = { source: "pi-subagents", owner: { id: "installed-provider" } };
    vi.spyOn(slot as unknown as { subagentExtensionOrigin: () => typeof providerOrigin }, "subagentExtensionOrigin")
      .mockReturnValue(providerOrigin);
    vi.spyOn(slot as unknown as { extensionToolOrigin: (name: string) => typeof providerOrigin | undefined }, "extensionToolOrigin")
      .mockReturnValue(scenario === "foreign-owner" ? { ...providerOrigin, owner: { id: "project-impostor" } } : providerOrigin);
    manager.appendMessage({
      role: "toolResult", toolCallId: sourceToolCallId, toolName: "subagent",
      content: [{ type: "text", text: "launched" }],
      details: { runId: sourceRunId, asyncId: sourceRunId, asyncDir: sourceDir, mode: "single", results: [] },
      isError: false, timestamp: Date.now(),
    });
    manager.appendMessage({
      role: "toolResult", toolCallId: recoveryToolCallId, toolName: "subagent",
      content: [{ type: "text", text: "recovered" }],
      details: {
        mode: "management", results: [],
        steering: {
          state: "recovered", deliveryStatus: "delivered", sourceRunId, replacementRunId,
          targets: [{ index: 0, state: "recovered", replacementRunId }],
        },
      },
      isError: false, timestamp: Date.now(),
    });
    const internal = slot as unknown as {
      extensionActivities: Map<string, ExtensionRunActivity>;
      extensionRunOwnership: Map<string, { toolCallId: string; asyncDir?: string; terminal: boolean; pausedProcessQuiescentAt?: string }>;
      canonicalExtensionRunFacts: () => Map<string, unknown>;
    };
    const started = Date.now() - 5_000;
    const recoveredAt = started + 3_000;
    internal.extensionActivities.set(sourceToolCallId, {
      id: sourceToolCallId, activityId: "recovered-source-activity", runId: sourceRunId, toolCallId: sourceToolCallId,
      source: { source: "pi-subagents" }, title: "Pi Subagents", status: "running",
      startedAt: new Date(started).toISOString(), updatedAt: new Date(started + 1_000).toISOString(), children: [],
      lifecycle: { version: 1, state: "paused", attention: "needsAttention", sequence: 1, observedAt: new Date(started + 1_000).toISOString() },
    });
    internal.extensionRunOwnership.set(sourceRunId, { toolCallId: sourceToolCallId, asyncDir: sourceDir, terminal: false });
    await writeFile(join(sourceDir, "status.json"), JSON.stringify({
      lifecycleArtifactVersion: 3, runId: sourceRunId, state: scenario === "live-source" ? "running" : "paused", startedAt: started, endedAt: started + 1_000, lastUpdate: started + 2_000,
      steps: [{ index: 0, agent: "worker", status: "paused" }],
      steering: { recent: [{ targets: [{ state: "recovered", replacementRunId, recoveredAt }] }] },
    }));
    await writeFile(join(sourceDir, "process-terminal.json"), JSON.stringify({
      version: 1, state: scenario === "unobserved-process" ? "pending" : "observed", runId: sourceRunId, runnerProcessInstanceId: "source-runner", observedAt: started + 1_500,
      instances: [{ kind: "runner", processInstanceId: "source-runner", closeObservedAt: started + 1_500, exitCode: 0, signal: null }],
    }));
    await writeFile(join(replacementDir, "status.json"), JSON.stringify({
      lifecycleArtifactVersion: 3, runId: replacementRunId, state: "running", startedAt: recoveredAt + 1, lastUpdate: recoveredAt + 2,
    }));

    await slot.discoverExtensionArtifact(sourceDir);
    await slot.discoverExtensionArtifact(replacementDir);
    if (scenario !== "recovered") {
      expect(slot.snapshot().extensionActivities.find((item) => item.runId === sourceRunId)?.status).toBe("running");
      if (scenario === "foreign-owner") {
        expect(slot.snapshot().extensionActivities.some((item) => item.runId === replacementRunId)).toBe(false);
      }
      return;
    }
    const drain = fixture.registry.waitUntilIdle();
    expect(slot.snapshot().extensionActivities).toEqual(expect.arrayContaining([
      expect.objectContaining({ toolCallId: sourceToolCallId, status: "completed", lifecycle: expect.objectContaining({ state: "stopped" }) }),
      expect.objectContaining({ runId: replacementRunId, status: "running", lifecycle: expect.objectContaining({ state: "running" }) }),
    ]));
    expect(slot.isDrainBusy).toBe(true);

    const finished = Date.now();
    await writeFile(join(replacementDir, "status.json"), JSON.stringify({
      lifecycleArtifactVersion: 3, runId: replacementRunId, state: "complete", startedAt: recoveredAt + 1,
      lastUpdate: finished, endedAt: finished,
    }));
    await slot.discoverExtensionArtifact(replacementDir);
    await drain;
    expect(slot.isDrainBusy).toBe(false);
    expect(slot.snapshot().extensionActivities).toEqual(expect.arrayContaining([
      expect.objectContaining({ toolCallId: sourceToolCallId, status: "completed", lifecycle: expect.objectContaining({ state: "stopped" }) }),
      expect.objectContaining({ runId: replacementRunId, status: "completed", lifecycle: expect.objectContaining({ state: "completed" }) }),
    ]));
    expect(slot.snapshot().processOverview.activeCount).toBe(0);
    // A delayed original artifact cannot resurrect the retired execution.
    await writeFile(join(sourceDir, "status.json"), JSON.stringify({
      lifecycleArtifactVersion: 3, runId: sourceRunId, state: "running", startedAt: started, lastUpdate: Date.now(),
    }));
    await slot.discoverExtensionArtifact(sourceDir);
    expect(slot.snapshot().extensionActivities.find((item) => item.runId === sourceRunId)?.lifecycle?.state).toBe("stopped");
    expect(slot.isDrainBusy).toBe(false);
  });

  it("does not retain unwatched async launcher acknowledgements as running work", async () => {
    const fixture = await coldFixture("unwatched-async-launcher");
    const slot = await fixture.registry.acquire(fixture.manager.getSessionId());
    const update = (slot as unknown as {
      updateExtensionActivity: (
        toolCallId: string, toolName: string, origin: ExtensionToolOrigin,
        status: "running" | "completed" | "failed", startedAt: string,
        updatedAt: string, value: unknown, completedAt?: string, durationMs?: number,
      ) => ExtensionRunActivity | undefined;
      extensionActivityWatchers: Map<string, unknown>;
    });
    const now = new Date().toISOString();
    const origin: ExtensionToolOrigin = { source: "project" };

    const idOnly = update.updateExtensionActivity(
      "id-only-tool", "subagent", origin, "completed", now, now,
      { details: { asyncId: "id-only-run", mode: "async" } }, now, 44,
    );
    expect(idOnly?.status).toBe("completed");
    expect(update.extensionActivityWatchers.has("id-only-tool")).toBe(false);

    const rejectedDirectory = update.updateExtensionActivity(
      "rejected-dir-tool", "subagent", origin, "completed", now, now,
      { details: { asyncId: "rejected-dir-run", mode: "async", asyncDir: "/tmp/not-owned-by-this-session" } }, now, 44,
    );
    expect(rejectedDirectory?.status).toBe("completed");
    expect(update.extensionActivityWatchers.has("rejected-dir-tool")).toBe(false);

    await fixture.registry.waitUntilIdle();
    expect(slot.isDrainBusy).toBe(false);
    expect(slot.snapshot().processActivities ?? []).toEqual([]);
  });

  it("admits exact pi-subagents foreground progress beside asynchronous work and settles it independently", async () => {
    const fixture = await coldFixture("foreground-subagent-progress");
    const slot = await fixture.registry.acquire(fixture.manager.getSessionId());
    const owner = { id: "extension:pi-subagents", title: "Subagents", source: "project" };
    const origin: ExtensionToolOrigin = { source: "project", owner };
    const internal = slot as unknown as {
      subagentExtensionOrigin: () => ExtensionToolOrigin;
      updateExtensionActivity: (
        toolCallId: string, toolName: string, origin: ExtensionToolOrigin,
        status: "running" | "completed" | "failed", startedAt: string,
        updatedAt: string, value: unknown, completedAt?: string, durationMs?: number,
      ) => ExtensionRunActivity | undefined;
      syncSubagentProcesses: (activity: ExtensionRunActivity) => void;
    };
    vi.spyOn(internal, "subagentExtensionOrigin").mockReturnValue(origin);
    const startedAt = new Date(Date.now() - 1_000).toISOString();
    const runningAt = new Date().toISOString();
    const progress = {
      details: {
        mode: "single",
        results: [{
          index: 0, agent: "reviewer", task: "Review",
          progress: { index: 0, agent: "reviewer", status: "running", currentTool: "read", toolCount: 2, durationMs: 1_000 },
        }],
        progress: [{ index: 0, agent: "reviewer", status: "running", currentTool: "read", toolCount: 2, durationMs: 1_000 }],
      },
    };

    expect(internal.updateExtensionActivity(
      "sync-tool", "subagent", origin, "running", startedAt, runningAt, progress, undefined, 1_000,
    )).toMatchObject({ toolCallId: "sync-tool", status: "running" });
    expect(slot.snapshot().processActivities).toEqual([expect.objectContaining({
      executionMode: "synchronous",
      title: "reviewer",
      visibility: "active",
      currentTool: "read",
      lifecycle: expect.objectContaining({ state: "running" }),
    })]);

    internal.syncSubagentProcesses({
      id: "async-tool", activityId: "async-activity", runId: "async-root", toolCallId: "async-tool",
      source: origin, title: "Subagent", mode: "asynchronous", status: "running", startedAt, updatedAt: runningAt,
      children: [{
        id: "async-child", producerId: "async-child", label: "worker",
        status: "running", lifecycle: "running", currentTool: "bash",
      }],
      lifecycle: { version: 1, state: "running", attention: "none", sequence: 1, observedAt: runningAt },
    });
    expect(slot.snapshot().processActivities).toEqual(expect.arrayContaining([
      expect.objectContaining({ executionMode: "synchronous", title: "reviewer", visibility: "active" }),
      expect.objectContaining({ executionMode: "asynchronous", title: "worker", visibility: "active" }),
    ]));

    const unrelatedOwner: ExtensionToolOrigin = {
      source: "project",
      owner: { id: "extension:other", title: "Other", source: "project" },
    };
    expect(internal.updateExtensionActivity(
      "other-tool", "subagent", unrelatedOwner, "running", startedAt, runningAt, progress,
    )).toBeUndefined();

    const completedAt = new Date().toISOString();
    const terminal = {
      details: {
        mode: "single",
        runId: "sync-root",
        results: [{
          index: 0, agent: "reviewer", task: "Review", exitCode: 0, finalOutput: "Complete",
          progress: { index: 0, agent: "reviewer", status: "completed", toolCount: 3, durationMs: 1_200 },
        }],
      },
    };
    expect(internal.updateExtensionActivity(
      "sync-tool", "subagent", origin, "completed", startedAt, completedAt, terminal, completedAt, 1_200,
    )).toMatchObject({ toolCallId: "sync-tool", status: "completed", runId: "sync-root" });
    expect(slot.snapshot().processActivities).toEqual(expect.arrayContaining([
      expect.objectContaining({
        executionMode: "synchronous", title: "reviewer", visibility: "recent",
        lifecycle: expect.objectContaining({ state: "completed" }),
      }),
      expect.objectContaining({
        executionMode: "asynchronous", title: "worker", visibility: "active",
        lifecycle: expect.objectContaining({ state: "running" }),
      }),
    ]));
  });

  it("keeps process overview active while an async workflow child awaits producer identity", async () => {
    const fixture = await coldFixture("async-workflow-root-visibility");
    const slot = await fixture.registry.acquire(fixture.manager.getSessionId());
    const internal = slot as unknown as {
      syncSubagentProcesses: (activity: ExtensionRunActivity) => void;
      publishProcessesForToolCall: (toolCallId: string) => void;
    };
    const startedAt = new Date(Date.now() - 1_000).toISOString();
    const runningAt = new Date().toISOString();
    const base = {
      id: "async-tool", activityId: "async-activity", runId: "workflow-run", toolCallId: "async-tool",
      source: { source: "pi-subagents" }, title: "Pi Subagents", mode: "asynchronous",
      startedAt, updatedAt: runningAt,
    } satisfies Partial<ExtensionRunActivity>;
    internal.syncSubagentProcesses({
      ...base,
      status: "running",
      children: [{ id: "single-async", label: "worker", status: "running", lifecycle: "running" }],
      lifecycle: { version: 1, state: "running", attention: "none", sequence: 1, observedAt: runningAt },
    } as ExtensionRunActivity);
    internal.publishProcessesForToolCall("async-tool");
    expect(slot.snapshot()).toMatchObject({
      processOverview: { visibility: "active", activeCount: 1, recentCount: 0 },
      processActivities: [expect.objectContaining({
        title: "Subagent", runId: "workflow-run", visibility: "active", childCount: 1,
      })],
    });

    fixture.events.splice(0);
    const completedAt = new Date().toISOString();
    const terminalLifecycle = {
      version: 1 as const, state: "completed" as const, attention: "none" as const, sequence: 2,
      observedAt: completedAt, terminalAt: completedAt,
      recentUntil: new Date(Date.parse(completedAt) + 900_000).toISOString(),
    };
    internal.syncSubagentProcesses({
      ...base,
      status: "completed",
      completedAt,
      children: [{ id: "single-async", label: "worker", status: "completed", lifecycle: "completed" }],
      lifecycle: terminalLifecycle,
    } as ExtensionRunActivity);
    internal.publishProcessesForToolCall("async-tool");
    const terminalRoot = slot.snapshot().processActivities?.[0];
    expect(slot.snapshot()).toMatchObject({
      processOverview: { visibility: "recent", activeCount: 0, recentCount: 1 },
      processActivities: [expect.objectContaining({ title: "Subagent", visibility: "recent" })],
    });
    expect(fixture.events.find((event) => event.topic === "session.processActivity")?.payload.data)
      .not.toHaveProperty("removedProcessIds");

    // A later terminal enrichment with exact child identity replaces the root
    // atomically rather than retaining a duplicate recent workflow row.
    fixture.events.splice(0);
    internal.syncSubagentProcesses({
      ...base,
      status: "completed",
      completedAt,
      children: [{
        id: "child-run", producerId: "child-run", label: "worker",
        status: "completed", lifecycle: "completed", childSessionRef: "child-session",
      }],
      lifecycle: { ...terminalLifecycle, sequence: 3 },
    } as ExtensionRunActivity);
    internal.publishProcessesForToolCall("async-tool");
    expect(slot.snapshot()).toMatchObject({
      processOverview: { visibility: "recent", activeCount: 0, recentCount: 1 },
      processActivities: [expect.objectContaining({ title: "worker", visibility: "recent" })],
    });
    expect(slot.snapshot().processActivities?.[0]?.processId).not.toBe(terminalRoot?.processId);
    expect(fixture.events.find((event) => event.topic === "session.processActivity")?.payload.data)
      .toMatchObject({ removedProcessIds: [terminalRoot?.processId] });
  });

  it("never reports a canonical receipt as durable when Pi only staged it in memory", async () => {
    // Reproduces the pinned SDK ordering: `_appendEntry` inserts the entry into
    // the live branch and then `_persist` fails, so the receipt exists in memory
    // while the JSONL lacks it. Gateway must report an unknown outcome for that
    // exact identity instead of announcing durable success from memory.
    const fixture = await coldFixture("canonical-receipt-staged-only");
    const slot = await fixture.registry.acquire(fixture.manager.getSessionId());
    const internal = slot as unknown as {
      runtime: { session: { sessionManager: SessionManager; abort: () => Promise<void> } };
      persistCanonicalCustomEntry: (customType: string, data: unknown, identity: string) => Promise<void>;
      durableWrites: Map<string, unknown>;
    };
    const manager = internal.runtime.session.sessionManager;
    const sessionFile = manager.getSessionFile()!;
    const receipt = makeInvocationReceipt({
      version: 1, receiptId: "staged-only-receipt", receiptKind: "start",
      invocationId: "staged-invocation", operationId: "staged-operation", sessionId: slot.id,
      source: "plain", lifecycle: "staged", origin: { kind: "user", confidence: "boundary" },
      sequence: 1, createdAt: "2026-01-01T00:00:00.000Z",
    });
    const staged = (): boolean => manager.getBranch().some((entry) =>
      entry.type === "custom" && (entry.data as { receiptId?: unknown })?.receiptId === "staged-only-receipt");

    // Make the owned JSONL append fail without disturbing the live branch.
    const aside = `${sessionFile}.aside`;
    await rename(sessionFile, aside);
    await mkdir(sessionFile);
    try {
      await expect(internal.persistCanonicalCustomEntry(INVOCATION_RECEIPT_TYPE, receipt, "staged-only-receipt"))
        .rejects.toMatchObject({ details: { outcomeUnknown: true } });
      expect(staged()).toBe(true);
      // The staged entry is not durability evidence: a repeat attempt must not
      // report success from the live branch alone.
      await expect(internal.persistCanonicalCustomEntry(INVOCATION_RECEIPT_TYPE, receipt, "staged-only-receipt"))
        .rejects.toMatchObject({ details: { outcomeUnknown: true } });
    } finally {
      await rm(sessionFile, { recursive: true, force: true });
      await rename(aside, sessionFile);
    }
    expect(await readFile(sessionFile, "utf8")).not.toContain("staged-only-receipt");

    try {
      expect(slot.isBusy).toBe(true);
      expect(slot.isEvictionProtected).toBe(true);
      expect(slot.isDrainBusy).toBe(true);
      expect(slot.administrativeDrainBlockers()).toContainEqual(expect.objectContaining({ category: "terminal-receipt-persistence", state: "suspect" }));
      await expect(slot.prompt("must not execute")).rejects.toMatchObject({ details: { outcomeUnknown: true } });
      await expect(slot.dispose()).rejects.toMatchObject({ details: { outcomeUnknown: true } });
      const stop = vi.spyOn(internal.runtime.session, "abort");
      await slot.abort();
      expect(stop).toHaveBeenCalledOnce();
      expect(slot.isDrainBusy).toBe(true);
      stop.mockRestore();
      await expect(internal.persistCanonicalCustomEntry(INVOCATION_RECEIPT_TYPE, { receiptId: "healthy-receipt", version: 1 }, "healthy-receipt"))
        .rejects.toMatchObject({ details: { outcomeUnknown: true } });
      expect(await readFile(sessionFile, "utf8")).not.toContain("healthy-receipt");
    } finally {
      // Test-only release of the deliberately poisoned fixture for teardown.
      // Production has no bypass: the SDK must supply verified recovery first.
      internal.durableWrites.clear();
    }
  });

  it("retains the exact extension receipt owner when Pi stages its terminal receipt but disk append fails", async () => {
    const workRegistry = new GatewayWorkRegistry();
    const fixture = await coldFixture("extension-staged-receipt", { workRegistry });
    const slot = await fixture.registry.acquire(fixture.manager.getSessionId());
    const internal = slot as unknown as {
      runtime: { session: { sessionManager: SessionManager } };
      claimExtensionReceiptOwnership: (id: string) => GatewayWorkHandle;
      releaseExtensionReceiptOwnership: (id: string, owner: GatewayWorkHandle) => void;
      appendExtensionActivityReceipt: (activity: ExtensionRunActivity) => Promise<void>;
      durableWrites: Map<string, unknown>;
    };
    const activity: ExtensionRunActivity = {
      id: "staged-extension", activityId: "staged-extension", toolCallId: "tool-staged-extension",
      source: { source: "pi-subagents" }, title: "Fixture", status: "completed", children: [],
      startedAt: "2026-01-01T00:00:00.000Z", updatedAt: "2026-01-01T00:00:01.000Z",
      lifecycle: { version: 1, state: "completed", attention: "none", sequence: 1, observedAt: "2026-01-01T00:00:01.000Z" },
    };
    const owner = internal.claimExtensionReceiptOwnership(activity.id);
    const file = internal.runtime.session.sessionManager.getSessionFile()!;
    const aside = `${file}.aside`;
    await rename(file, aside);
    await mkdir(file);
    try {
      await expect(internal.appendExtensionActivityReceipt(activity)).rejects.toMatchObject({ details: { outcomeUnknown: true } });
      expect(workRegistry.facts().some(fact => fact.token === owner.token)).toBe(true);
      expect(slot.isEvictionProtected).toBe(true);
      expect(slot.isDrainBusy).toBe(true);
      await expect(slot.disposeIf(() => true)).rejects.toMatchObject({ details: { outcomeUnknown: true } });
      await expect(internal.appendExtensionActivityReceipt(activity)).rejects.toMatchObject({ details: { outcomeUnknown: true } });
      expect(await readFile(aside, "utf8")).not.toContain("staged-extension");
    } finally {
      await rm(file, { recursive: true, force: true });
      await rename(aside, file);
      internal.durableWrites.clear(); // test-only disposal of the faulted runtime
      internal.releaseExtensionReceiptOwnership(activity.id, owner);
    }
  });

  it.each(["rejecting", "stalled"])("bounds the %s persistence waiter without releasing its unresolved owner", async (failure) => {
    const fixture = await coldFixture(`ownership-write-${failure}`);
    const slot = await fixture.registry.acquire(fixture.manager.getSessionId());
    const internal = slot as unknown as {
      retryDurableWrite: (key: string, operation: () => Promise<void>) => Promise<void>;
      durableWrites: Map<string, unknown>;
    };
    let finish!: () => void;
    const stalled = new Promise<void>(resolve => { finish = resolve; });
    let attempts = 0;
    vi.useFakeTimers();
    const clock = vi.spyOn(nodePerformance, "now").mockImplementation(() => Date.now());
    try {
      const operation = async () => {
        attempts += 1;
        if (failure === "stalled") return stalled;
        throw new Error("synthetic storage failure");
      };
      const pending = internal.retryDurableWrite("test:storage-fault", operation);
      const rejected = expect(pending).rejects.toMatchObject({ details: { outcomeUnknown: true } });
      await vi.advanceTimersByTimeAsync(20_000);
      await rejected;
      if (failure === "stalled") expect(attempts).toBe(1);
      else expect(attempts).toBeGreaterThan(1);
      expect(slot.isEvictionProtected).toBe(true);
      expect(slot.isDrainBusy).toBe(true);
      await expect(slot.prompt("must remain fenced")).rejects.toMatchObject({ details: { outcomeUnknown: true } });
      await expect(slot.dispose()).rejects.toMatchObject({ details: { outcomeUnknown: true } });
      finish();
      await stalled;
      await vi.advanceTimersByTimeAsync(1_000);
      // A late physical completion cannot resume the abandoned dependent work.
      expect(slot.isDrainBusy).toBe(true);
      await expect(internal.retryDurableWrite("test:storage-fault", operation)).rejects.toMatchObject({ details: { outcomeUnknown: true } });
    } finally {
      finish();
      clock.mockRestore();
      vi.useRealTimers();
      internal.durableWrites.clear(); // test-only teardown of synthetic blocked owner
    }
  });

  it("claims receipt ownership before watcher-driven terminal projection", async () => {
    const fixture = await coldFixture("watcher-terminal-receipt");
    const slot = await fixture.registry.acquire(fixture.manager.getSessionId());
    const runId = "watcher-terminal-run";
    const toolCallId = "watcher-terminal-tool";
    const activityId = "watcher-terminal-activity";
    const asyncDir = join(fixture.cwd, ".pi", "subagents", "async-subagent-runs", runId);
    await mkdir(asyncDir, { recursive: true });
    const startedAt = new Date(Date.now() - 1_000).toISOString();
    const internal = slot as unknown as {
      extensionActivities: Map<string, ExtensionRunActivity>;
      extensionRunOwnership: Map<string, { toolCallId: string; asyncDir?: string; terminal: boolean }>;
      refreshExtensionActivityFromArtifact: (toolCallId: string, asyncDir: string) => Promise<void>;
      runtime: { session: { sessionManager: SessionManager } };
    };
    internal.extensionActivities.set(toolCallId, {
      id: toolCallId, activityId, runId, toolCallId,
      source: { source: "pi-subagents" }, title: "Pi Subagents", status: "running",
      startedAt, updatedAt: startedAt, children: [],
      lifecycle: { version: 1, state: "running", attention: "none", sequence: 1, observedAt: startedAt },
    });
    internal.extensionRunOwnership.set(runId, { toolCallId, asyncDir, terminal: false });
    const receiptAppend = vi.spyOn(internal.runtime.session.sessionManager, "appendCustomEntry")
      .mockImplementationOnce(() => { throw new Error("injected receipt persistence failure"); });
    const endedAt = Date.now();
    await writeFile(join(asyncDir, "status.json"), JSON.stringify({
      runId, state: "complete", startedAt: Date.parse(startedAt), endedAt, lastUpdate: endedAt + 1,
    }));

    await internal.refreshExtensionActivityFromArtifact(toolCallId, asyncDir);
    expect(slot.snapshot().extensionActivities).toMatchObject([{ toolCallId, status: "completed" }]);
    await fixture.registry.waitUntilIdle();
    expect(receiptAppend.mock.calls.length).toBeGreaterThanOrEqual(2);
  });

  it("retries an initial atomic async status replacement before projecting activity", async () => {
    const fixture = await coldFixture("async-status-initial-retry");
    const slot = await fixture.registry.acquire(fixture.manager.getSessionId());
    const runId = "retry-run";
    const toolCallId = "retry-tool";
    const asyncDir = join(fixture.cwd, ".pi", "subagents", "async-subagent-runs", runId);
    await mkdir(asyncDir, { recursive: true });
    const startedAt = new Date(Date.now() - 1_000).toISOString();
    const internal = slot as unknown as {
      extensionActivities: Map<string, ExtensionRunActivity>;
      extensionRunOwnership: Map<string, { toolCallId: string; asyncDir?: string; terminal: boolean }>;
      readExtensionStatusArtifact: (asyncDir: string) => Promise<Record<string, unknown> | undefined>;
      startExtensionActivityWatcher: (toolCallId: string, asyncDir: string) => void;
    };
    internal.extensionActivities.set(toolCallId, {
      id: toolCallId, activityId: "retry-activity", runId, toolCallId,
      source: { source: "project", owner: { id: "extension:pi-subagents", title: "Subagents", source: "project" } }, title: "Subagents", mode: "asynchronous", status: "running",
      startedAt, updatedAt: startedAt, children: [],
      lifecycle: { version: 1, state: "running", attention: "none", sequence: 1, observedAt: startedAt },
    });
    internal.extensionRunOwnership.set(runId, { toolCallId, asyncDir, terminal: false });
    const canonicalAsyncDir = await realpath(asyncDir);
    const originalRead = internal.readExtensionStatusArtifact.bind(slot);
    let missingReadCompleted = false;
    internal.readExtensionStatusArtifact = async (directory) => {
      const status = await originalRead(directory);
      if (directory === canonicalAsyncDir && status === undefined) missingReadCompleted = true;
      return status;
    };
    internal.startExtensionActivityWatcher(toolCallId, asyncDir);
    try {
      await waitFor(() => missingReadCompleted, "the missing-artifact read");
      const pendingStatus = join(asyncDir, "status.json.pending");
      await writeFile(pendingStatus, JSON.stringify({
        lifecycleArtifactVersion: 3,
        runId,
        state: "running",
        startedAt: Date.parse(startedAt),
        lastUpdate: Date.now(),
        mode: "workflow",
        // The artifact itself is authoritative running evidence even before a
        // workflow publishes its first child step.
        steps: [],
      }));
      await rename(pendingStatus, join(asyncDir, "status.json"));
      await waitFor(() => (slot.snapshot().processActivities?.length ?? 0) === 1, "the first process activity");
      expect(slot.snapshot().processActivities?.[0]).toMatchObject({
        kind: "subagent",
        runId,
        executionMode: "asynchronous",
        visibility: "active",
      });
      expect(slot.snapshot().processOverview).toMatchObject({ visibility: "active", activeCount: 1 });
    } finally {
      const endedAt = Date.now();
      const completedStatus = join(asyncDir, "status.json.pending");
      await writeFile(completedStatus, JSON.stringify({
        lifecycleArtifactVersion: 3,
        runId,
        state: "complete",
        startedAt: Date.parse(startedAt),
        lastUpdate: endedAt,
        endedAt,
        mode: "workflow",
        steps: [],
      }));
      await rename(completedStatus, join(asyncDir, "status.json"));
      await waitFor(() => slot.snapshot().extensionActivities?.some((activity) =>
        activity.toolCallId === toolCallId && activity.status === "completed") === true, "the completed extension activity");
      await fixture.registry.waitUntilIdle();
    }
  });

  it("retires a stale active process when its exact status artifact stays missing", async () => {
    const fixture = await coldFixture("async-status-permanently-missing");
    const slot = await fixture.registry.acquire(fixture.manager.getSessionId());
    const runId = "missing-run";
    const toolCallId = "missing-tool";
    const asyncDir = join(fixture.cwd, ".pi", "subagents", "async-subagent-runs", runId);
    await mkdir(asyncDir, { recursive: true });
    const startedAt = new Date(Date.now() - 60_000).toISOString();
    const activity: ExtensionRunActivity = {
      id: toolCallId, activityId: "missing-activity", runId, toolCallId,
      source: { source: "project", owner: { id: "extension:pi-subagents", title: "Subagents", source: "project" } }, title: "Subagents", mode: "asynchronous", status: "running",
      startedAt, updatedAt: startedAt,
      children: [{ id: "child", producerId: "child", label: "worker", status: "running", lifecycle: "running" }],
      lifecycle: { version: 1, state: "running", attention: "none", sequence: 1, observedAt: startedAt },
    };
    const internal = slot as unknown as {
      extensionActivities: Map<string, ExtensionRunActivity>;
      extensionRunOwnership: Map<string, { toolCallId: string; asyncDir?: string; terminal: boolean }>;
      extensionArtifactMissingSince: Map<string, number>;
      syncSubagentProcesses: (activity: ExtensionRunActivity) => void;
      ownedExtensionArtifactDirectories: () => string[];
      observeMissingExtensionArtifact: (toolCallId: string) => void;
    };
    internal.extensionActivities.set(toolCallId, activity);
    internal.extensionRunOwnership.set(runId, { toolCallId, asyncDir, terminal: false });
    internal.extensionArtifactMissingSince.set(toolCallId, Date.now() - 31_000);
    internal.syncSubagentProcesses(activity);
    expect(slot.snapshot().processOverview).toMatchObject({ visibility: "active", activeCount: 1 });
    expect(internal.ownedExtensionArtifactDirectories()).toContain(await realpath(asyncDir));

    internal.observeMissingExtensionArtifact(toolCallId);

    expect(slot.snapshot().processActivities ?? []).toEqual([]);
    expect(slot.snapshot().processOverview).toMatchObject({ visibility: "hidden", activeCount: 0 });
    expect(internal.extensionActivities.get(toolCallId)?.lifecycle?.state).toBe("unknown");
  });

  it("retries a live child binding when the canonical session appears after status publication", async () => {
    const fixture = await coldFixture("delayed-live-child-session");
    const slot = await fixture.registry.acquire(fixture.manager.getSessionId());
    const rootRunId = "delayed-workflow-root";
    const childRunId = "delayed-workflow-child";
    const toolCallId = "delayed-workflow-tool";
    const asyncDir = join(fixture.cwd, ".pi", "subagents", "async-subagent-runs", rootRunId);
    const parentFile = slot.sessionFile!;
    const childDirectory = join(dirname(parentFile), basename(parentFile, ".jsonl"), childRunId, "run-0");
    const childFile = join(childDirectory, "session.jsonl");
    await Promise.all([mkdir(asyncDir, { recursive: true }), mkdir(childDirectory, { recursive: true })]);
    const started = Date.now() - 1_000;
    const startedAt = new Date(started).toISOString();
    await writeFile(join(asyncDir, "status.json"), JSON.stringify({
      lifecycleArtifactVersion: 3,
      runId: rootRunId,
      state: "running",
      startedAt: started,
      lastUpdate: started + 500,
      mode: "workflow",
      steps: [{
        workflowKey: "delayed-child",
        runId: childRunId,
        agent: "worker",
        status: "running",
        sessionFile: childFile,
      }],
    }));
    const internal = slot as unknown as {
      extensionActivities: Map<string, ExtensionRunActivity>;
      extensionRunOwnership: Map<string, { toolCallId: string; asyncDir?: string; terminal: boolean }>;
      startExtensionActivityWatcher: (toolCallId: string, asyncDir: string) => void;
    };
    internal.extensionActivities.set(toolCallId, {
      id: toolCallId, activityId: "delayed-workflow-activity", runId: rootRunId, toolCallId,
      source: { source: "project", owner: { id: "extension:pi-subagents", title: "Subagents", source: "project" } }, title: "Subagents", mode: "asynchronous", status: "running",
      startedAt, updatedAt: startedAt, children: [],
      lifecycle: { version: 1, state: "running", attention: "none", sequence: 1, observedAt: startedAt },
    });
    internal.extensionRunOwnership.set(rootRunId, { toolCallId, asyncDir, terminal: false });
    internal.startExtensionActivityWatcher(toolCallId, asyncDir);
    await waitFor(() => slot.snapshot().processActivities?.some((activity) =>
      activity.kind === "subagent" && activity.childSessionRef === undefined) === true, "the subagent activity without a child reference");

    const childManager = SessionManager.create(fixture.cwd, childDirectory, { id: "delayed-child-session" });
    childManager.appendMessage(fauxAssistantMessage("published after artifact status"));
    await rename(childManager.getSessionFile()!, childFile);

    await waitFor(() => slot.snapshot().processActivities?.some((activity) =>
      activity.kind === "subagent" && activity.childSessionRef === "delayed-child-session") === true, "the delayed subagent child reference");
    const process = slot.snapshot().processActivities?.find((activity) => activity.kind === "subagent");
    expect(process).toMatchObject({ childSessionRef: "delayed-child-session", visibility: "active" });
    expect(slot.processChildSessionBinding(process!.processId)).toMatchObject({
      ref: "delayed-child-session",
      producerId: "delayed-child",
      sessionOwnerId: childRunId,
      runId: rootRunId,
    });
  });

  it("admits the exact fresh child path for read-only process viewing", async () => {
    const fixture = await coldFixture("validated-child-session");
    const slot = await fixture.registry.acquire(fixture.manager.getSessionId());
    const runId = "validated-child-run";
    const toolCallId = "validated-child-tool";
    const activityId = "validated-child-activity";
    const asyncDir = join(fixture.cwd, ".pi", "subagents", "async-subagent-runs", runId);
    const parentFile = slot.sessionFile!;
    const childProducerId = "step:0";
    const childDirectory = join(dirname(parentFile), basename(parentFile, ".jsonl"), runId, "run-0");
    await Promise.all([mkdir(asyncDir, { recursive: true }), mkdir(childDirectory, { recursive: true })]);
    // Match the current producer: the root run reserves the fresh session
    // directory while the stable artifact step owns the child process row.
    const childManager = SessionManager.create(fixture.cwd, childDirectory, {
      id: "validated-child-session",
    });
    childManager.appendMessage(fauxAssistantMessage("child transcript"));
    const generatedChildFile = childManager.getSessionFile()!;
    const childFile = join(childDirectory, "session.jsonl");
    await rename(generatedChildFile, childFile);
    const startedAt = new Date(Date.now() - 1_000).toISOString();
    const internal = slot as unknown as {
      extensionActivities: Map<string, ExtensionRunActivity>;
      extensionRunOwnership: Map<string, { toolCallId: string; asyncDir?: string; terminal: boolean }>;
      refreshExtensionActivityFromArtifact: (toolCallId: string, asyncDir: string) => Promise<void>;
    };
    internal.extensionActivities.set(toolCallId, {
      id: toolCallId, activityId, runId, toolCallId,
      source: { source: "project", owner: { id: "extension:pi-subagents", title: "Subagents", source: "project" } }, title: "Subagents", mode: "asynchronous", status: "running",
      startedAt, updatedAt: startedAt, children: [],
      lifecycle: { version: 1, state: "running", attention: "none", sequence: 1, observedAt: startedAt },
    });
    internal.extensionRunOwnership.set(runId, { toolCallId, asyncDir, terminal: false });
    await writeFile(join(asyncDir, "status.json"), JSON.stringify({
      runId,
      state: "running",
      startedAt: Date.parse(startedAt),
      lastUpdate: Date.now(),
      mode: "workflow",
      steps: [{ agent: "worker", status: "running", sessionFile: childFile }],
    }));
    await internal.refreshExtensionActivityFromArtifact(toolCallId, asyncDir);
    const activeSnapshot = slot.snapshot();
    const activeProcess = activeSnapshot.processActivities?.find((activity) => activity.kind === "subagent");
    expect(activeSnapshot.extensionActivities?.[0]?.lifecycle).toMatchObject({
      state: "running",
      visibility: "current",
    });
    expect(activeSnapshot.extensionActivities?.[0]?.lifecycle).not.toHaveProperty("remainingMs");
    expect(activeProcess).toMatchObject({
      title: "worker",
      childSessionRef: "validated-child-session",
      executionMode: "asynchronous",
      visibility: "active",
      lifecycle: { state: "running" },
    });

    // Pi reloads configured npm packages through their resolved local path in
    // production. Controller authority follows the exact installed owner ID,
    // not the mutable `source` display label.
    const localOwner = {
      id: "extension:installed-subagent", title: "Pi Subagents", source: "local",
    };
    const controllerOrigin = { source: "local", owner: localOwner };
    const controllerExecute = vi.fn(async (..._arguments: unknown[]) => ({
      content: [{ type: "text", text: "stopped" }], details: {},
    }));
    const abortInternals = slot as unknown as {
      extensionToolOrigin: (toolName: string) => ExtensionToolOrigin | undefined;
      subagentExtensionOrigin: () => ExtensionToolOrigin;
      runtime: { session: { extensionRunner: { getToolDefinition: (toolName: string) => unknown } } };
    };
    const toolOrigin = vi.spyOn(abortInternals, "extensionToolOrigin").mockReturnValue(controllerOrigin);
    const installedOrigin = vi.spyOn(abortInternals, "subagentExtensionOrigin").mockReturnValue(controllerOrigin);
    const toolDefinition = vi.spyOn(abortInternals.runtime.session.extensionRunner, "getToolDefinition")
      .mockReturnValue({ execute: controllerExecute });
    expect(slot.processSubagentAbortAuthority(activeProcess!.processId, runId)).toEqual({});
    await slot.abortSubagentProcess(activeProcess!.processId, runId);
    expect(controllerExecute.mock.calls[0]?.[1]).toEqual({
      action: "stop", id: runId, childId: childProducerId,
    });
    toolOrigin.mockRestore();
    installedOrigin.mockRestore();
    toolDefinition.mockRestore();

    const endedAt = Date.now();
    await writeFile(join(asyncDir, "status.json"), JSON.stringify({
      runId,
      state: "complete",
      startedAt: Date.parse(startedAt),
      endedAt,
      lastUpdate: endedAt + 1,
      mode: "workflow",
      steps: [{ agent: "worker", status: "completed", sessionFile: childFile }],
    }));

    await internal.refreshExtensionActivityFromArtifact(toolCallId, asyncDir);
    const process = slot.snapshot().processActivities?.find((activity) => activity.kind === "subagent");
    expect(process).toMatchObject({
      title: "worker",
      childSessionRef: "validated-child-session",
      executionMode: "asynchronous",
    });
    expect(JSON.stringify(process)).not.toContain(childFile);
    expect(slot.processChildSessionPath(process!.processId)).toEqual({
      ref: "validated-child-session",
      producerId: childProducerId,
      runId,
      path: await realpath(childFile),
    });
    const admission = await fixture.registry.resolveReadOnlySubagentPath(
      "validated-child-session", await realpath(childFile), slot.id, process!.processId, runId,
    );
    const page = await fixture.registry.readOnlySubagentTranscriptPage(
      "validated-child-session", admission.path, slot.id, process!.processId, runId,
      undefined, undefined, admission.fileIdentity,
    );
    expect(page.total).toBeGreaterThan(0);
    expect(page.revision).toMatch(/^[a-f0-9]{32}$/u);
    expect(fixture.runtimeFactory).toHaveBeenCalledTimes(1);

    // Ownership reads only the immutable session header, so an in-progress
    // canonical append cannot transiently become an identity change. Page
    // projection still waits for that JSONL entry's terminating newline.
    const existingLines = (await readFile(childFile, "utf8")).trimEnd().split("\n");
    const parentId = (JSON.parse(existingLines.at(-1)!) as { id: string }).id;
    const appendedEntry = JSON.stringify({
      type: "message",
      id: "live-child-append",
      parentId,
      timestamp: new Date().toISOString(),
      message: fauxAssistantMessage("live appended transcript"),
    });
    await appendFile(childFile, appendedEntry);
    await expect(fixture.registry.resolveReadOnlySubagentPath(
      "validated-child-session", admission.path, slot.id, process!.processId, runId,
    )).resolves.toMatchObject({ path: admission.path, fileIdentity: admission.fileIdentity });
    await expect(fixture.registry.readOnlySubagentTranscriptPage(
      "validated-child-session", admission.path, slot.id, process!.processId, runId,
      undefined, undefined, admission.fileIdentity,
    )).rejects.toMatchObject({ code: "busy", retryable: true });
    await appendFile(childFile, "\n");
    await expect(fixture.registry.readOnlySubagentTranscriptPage(
      "validated-child-session", admission.path, slot.id, process!.processId, runId,
      undefined, undefined, admission.fileIdentity,
    )).resolves.toMatchObject({ fileIdentity: admission.fileIdentity });

    await expect(fixture.registry.resolveReadOnlySubagentPath(
      "validated-child-session", admission.path, slot.id, "wrong-process", runId,
    )).rejects.toMatchObject({ code: "not_found" });
    await waitFor(() => slot.processHistory(undefined, 25, { kind: "subagent" }).activities.length === 1, "the subagent history entry");
    expect(slot.processHistory(undefined, 25, { kind: "subagent" }).activities[0])
      .toMatchObject({ childSessionRef: "validated-child-session" });
    // Historical opening must derive its exact binding from the canonical
    // receipt rather than an unbounded runtime cache.
    (slot as unknown as { childSessionBindings: Map<string, unknown> }).childSessionBindings.clear();
    expect(slot.processChildSessionBinding(process!.processId)).toMatchObject({
      ref: "validated-child-session", producerId: childProducerId, sessionOwnerId: runId, runId,
    });

    const replacement = `${childFile}.replacement`;
    await writeFile(replacement, await readFile(childFile));
    await rm(childFile);
    await rename(replacement, childFile);
    await expect(fixture.registry.readOnlySubagentTranscriptPage(
      "validated-child-session", admission.path, slot.id, process!.processId, runId,
      undefined, undefined, admission.fileIdentity,
    )).rejects.toMatchObject({ code: "conflict", retryable: true });
  });

  it("binds a live async single child through its exact recovery root owner", async () => {
    const fixture = await coldFixture("validated-async-single-recovery-owner");
    const slot = await fixture.registry.acquire(fixture.manager.getSessionId());
    const parentFile = slot.sessionFile!;
    const asyncRunId = "async-single-run";
    const rootRunId = "parent-root-run";
    const toolCallId = "async-single-tool";
    const asyncDir = join(fixture.cwd, ".pi", "subagents", "async-subagent-runs", asyncRunId);
    const childDirectory = join(dirname(parentFile), basename(parentFile, ".jsonl"), rootRunId, "run-0");
    await Promise.all([mkdir(asyncDir, { recursive: true }), mkdir(childDirectory, { recursive: true })]);
    const childManager = SessionManager.create(fixture.cwd, childDirectory, { id: "async-single-child-session" });
    childManager.appendMessage(fauxAssistantMessage("live async single transcript"));
    const childFile = join(childDirectory, "session.jsonl");
    await rename(childManager.getSessionFile()!, childFile);
    const started = Date.now() - 1_000;
    const startedAt = new Date(started).toISOString();
    const internal = slot as unknown as {
      extensionActivities: Map<string, ExtensionRunActivity>;
      extensionRunOwnership: Map<string, { toolCallId: string; asyncDir?: string; terminal: boolean }>;
      refreshExtensionActivityFromArtifact: (toolCallId: string, asyncDir: string) => Promise<void>;
    };
    internal.extensionActivities.set(toolCallId, {
      id: toolCallId, activityId: "async-single-activity", runId: asyncRunId, toolCallId,
      source: { source: "project", owner: { id: "extension:pi-subagents", title: "Subagents", source: "project" } }, title: "Subagents", mode: "asynchronous", status: "running",
      startedAt, updatedAt: startedAt, children: [],
      lifecycle: { version: 1, state: "running", attention: "none", sequence: 1, observedAt: startedAt },
    });
    internal.extensionRunOwnership.set(asyncRunId, { toolCallId, asyncDir, terminal: false });
    const statusPath = join(asyncDir, "status.json");
    const descriptorPath = join(asyncDir, "recovery-descriptor.json");
    await writeFile(statusPath, JSON.stringify({
      lifecycleArtifactVersion: 3,
      runId: asyncRunId,
      state: "running",
      startedAt: started,
      lastUpdate: started + 500,
      mode: "single",
      // A raw status field cannot nominate the fresh path owner; only the
      // matching private descriptor may produce Gateway-attested evidence.
      steps: [{ agent: "worker", status: "running", sessionFile: childFile, sessionOwnerId: rootRunId }],
    }));
    await writeFile(descriptorPath, JSON.stringify({
      version: 1,
      sourceRunId: "foreign-async-run",
      sessionFile: childFile,
      runFanoutBudget: { version: 1, rootRunId, directory: "/private/opaque", limit: 64 },
    }));
    await internal.refreshExtensionActivityFromArtifact(toolCallId, asyncDir);
    const unbound = slot.snapshot().processActivities?.find((activity) => activity.kind === "subagent");
    expect(unbound).toMatchObject({ source: "delegatedAgent", visibility: "active" });
    expect(unbound).not.toHaveProperty("childSessionRef");
    expect(slot.processChildSessionBinding(unbound!.processId)).toBeUndefined();

    // The descriptor is private producer evidence: its exact source run,
    // session file, and fan-out root must agree before the path owner is used.
    await writeFile(descriptorPath, JSON.stringify({
      version: 1,
      sourceRunId: asyncRunId,
      sessionFile: childFile,
      runFanoutBudget: { version: 1, rootRunId, directory: "/private/opaque", limit: 64 },
    }));
    await writeFile(statusPath, JSON.stringify({
      lifecycleArtifactVersion: 3,
      runId: asyncRunId,
      state: "running",
      startedAt: started,
      lastUpdate: started + 700,
      mode: "single",
      steps: [{ agent: "worker", status: "running", sessionFile: childFile }],
    }));
    await internal.refreshExtensionActivityFromArtifact(toolCallId, asyncDir);

    const bound = slot.snapshot().processActivities?.find((activity) => activity.kind === "subagent");
    expect(bound).toMatchObject({
      processId: unbound!.processId,
      childSessionRef: "async-single-child-session",
      visibility: "active",
    });
    expect(slot.processChildSessionBinding(bound!.processId)).toMatchObject({
      ref: "async-single-child-session",
      producerId: "step:0",
      sessionOwnerId: rootRunId,
      runId: asyncRunId,
    });
    expect((await fixture.registry.readOnlySubagentTranscriptPage(
      "async-single-child-session", await realpath(childFile), slot.id, bound!.processId, asyncRunId,
    )).total).toBeGreaterThan(0);
  });

  it("separates a workflow producer identity from its fresh child-run path owner", async () => {
    const fixture = await coldFixture("validated-workflow-child-owner");
    const slot = await fixture.registry.acquire(fixture.manager.getSessionId());
    const parentFile = slot.sessionFile!;
    const rootRunId = "workflow-root";
    const childRunId = "workflow-child-run";
    const producerId = "workflow-key";
    const childDirectory = join(dirname(parentFile), basename(parentFile, ".jsonl"), childRunId, "run-0");
    await mkdir(childDirectory, { recursive: true });
    const childManager = SessionManager.create(fixture.cwd, childDirectory, { id: "workflow-child-session" });
    childManager.appendMessage(fauxAssistantMessage("workflow child transcript"));
    const childFile = join(childDirectory, "session.jsonl");
    await rename(childManager.getSessionFile()!, childFile);
    const startedAt = new Date(Date.now() - 1_000).toISOString();
    const activity: ExtensionRunActivity = {
      id: "workflow-tool", activityId: "workflow-activity", runId: rootRunId, toolCallId: "workflow-tool",
      source: { source: "project", owner: { id: "extension:pi-subagents", title: "Subagents", source: "project" } }, title: "Subagents", mode: "asynchronous", mode: "workflow", status: "running",
      startedAt, updatedAt: startedAt,
      children: [{ id: producerId, producerId, label: "worker", status: "running", lifecycle: "running" }],
      lifecycle: { version: 1, state: "running", attention: "none", sequence: 1, observedAt: startedAt },
    };
    const internal = slot as unknown as {
      attachChildSessionReferences: (activity: ExtensionRunActivity, value: unknown, strategy: "piArtifact") => ExtensionRunActivity;
      syncSubagentProcesses: (activity: ExtensionRunActivity) => void;
    };
    const attached = internal.attachChildSessionReferences(activity, {
      runId: rootRunId,
      steps: [{ workflowKey: producerId, runId: childRunId, agent: "worker", status: "running", sessionFile: childFile }],
    }, "piArtifact");
    internal.syncSubagentProcesses(attached);
    const process = slot.snapshot().processActivities?.find((candidate) => candidate.kind === "subagent");
    expect(process).toMatchObject({ childSessionRef: "workflow-child-session" });
    expect(slot.processChildSessionBinding(process!.processId)).toMatchObject({
      ref: "workflow-child-session", producerId, sessionOwnerId: childRunId, runId: rootRunId,
    });
    expect((await fixture.registry.readOnlySubagentTranscriptPage(
      "workflow-child-session", await realpath(childFile), slot.id, process!.processId, rootRunId,
    )).total).toBeGreaterThan(0);
  });

  it("fails closed when one child session ref has conflicting process producers", async () => {
    const fixture = await coldFixture("ambiguous-child-producers");
    const slot = await fixture.registry.acquire(fixture.manager.getSessionId());
    const startedAt = new Date(Date.now() - 1_000).toISOString();
    const activity: ExtensionRunActivity = {
      id: "ambiguous-tool", activityId: "ambiguous-activity", runId: "ambiguous-run", toolCallId: "ambiguous-tool",
      source: { source: "project", owner: { id: "extension:pi-subagents", title: "Subagents", source: "project" } }, title: "Subagents", mode: "asynchronous", mode: "workflow", status: "running",
      startedAt, updatedAt: startedAt,
      children: ["first", "second"].map((producerId) => ({
        id: producerId, producerId, label: producerId, status: "running" as const,
        lifecycle: "running" as const, childSessionRef: "same-child-session",
      })),
      lifecycle: { version: 1, state: "running", attention: "none", sequence: 1, observedAt: startedAt },
    };
    const internal = slot as unknown as { syncSubagentProcesses: (activity: ExtensionRunActivity) => void };
    internal.syncSubagentProcesses(activity);
    const processes = slot.snapshot().processActivities?.filter((candidate) => candidate.kind === "subagent") ?? [];
    expect(processes).toHaveLength(2);
    expect(processes.every((process) => slot.processChildSessionBinding(process.processId) === undefined)).toBe(true);
  });

  it("admits a fork-context transcript only from its artifact child identity and mounted parent", async () => {
    const fixture = await coldFixture("validated-fork-context");
    const slot = await fixture.registry.acquire(fixture.manager.getSessionId());
    const parentFile = slot.sessionFile!;
    const forksDirectory = join(dirname(parentFile), basename(parentFile, ".jsonl"), "forks");
    const asyncDir = join(fixture.cwd, ".pi", "subagents", "async-subagent-runs", "fork-run");
    await Promise.all([mkdir(forksDirectory, { recursive: true }), mkdir(asyncDir, { recursive: true })]);
    const fork = SessionManager.forkFrom(parentFile, fixture.cwd, forksDirectory);
    const firstChildEntry = fork.appendMessage(fauxAssistantMessage("fork transcript"));
    const forkFile = fork.getSessionFile()!;
    const artifactChildId = "artifact-fork-child";
    const startedAt = new Date(Date.now() - 1_000).toISOString();
    const internal = slot as unknown as {
      extensionActivities: Map<string, ExtensionRunActivity>;
      extensionRunOwnership: Map<string, { toolCallId: string; asyncDir?: string; terminal: boolean }>;
      refreshExtensionActivityFromArtifact: (toolCallId: string, asyncDir: string) => Promise<void>;
    };
    internal.extensionActivities.set("fork-tool", {
      id: "fork-tool", activityId: "fork-activity", runId: "fork-run", toolCallId: "fork-tool",
      source: { source: "project", owner: { id: "extension:pi-subagents", title: "Subagents", source: "project" } }, title: "Subagents", mode: "asynchronous", status: "running",
      startedAt, updatedAt: startedAt, children: [],
      lifecycle: { version: 1, state: "running", attention: "none", sequence: 1, observedAt: startedAt },
    });
    internal.extensionRunOwnership.set("fork-run", { toolCallId: "fork-tool", asyncDir, terminal: false });
    await writeFile(join(asyncDir, "status.json"), JSON.stringify({
      runId: "fork-run", state: "running", startedAt: Date.parse(startedAt), lastUpdate: Date.now(),
      mode: "workflow",
      steps: [{ runId: artifactChildId, agent: "filename-must-not-bind", status: "running", sessionFile: forkFile }],
    }));

    await internal.refreshExtensionActivityFromArtifact("fork-tool", asyncDir);
    const process = slot.snapshot().processActivities?.find((activity) => activity.kind === "subagent");
    expect(process).toMatchObject({ childSessionRef: fork.getSessionId() });
    expect(slot.processChildSessionPath(process!.processId)).toEqual({
      ref: fork.getSessionId(), producerId: artifactChildId, runId: "fork-run", path: await realpath(forkFile),
    });
    const admission = await fixture.registry.resolveReadOnlySubagentPath(
      fork.getSessionId(), await realpath(forkFile), slot.id, process!.processId, "fork-run",
    );
    const projected = await fixture.registry.readOnlySubagentTranscriptPage(
      fork.getSessionId(), admission.path, slot.id, process!.processId, "fork-run",
    );
    expect(projected.total).toBeGreaterThan(0);
    expect(projected.forkBoundary).toMatchObject({
      kind: "subagentFork", inheritedAnchorId: expect.any(String), gapOrdinal: 2,
    });
  });

  it("binds the canonical single-run fork step before and after terminal persistence", async () => {
    const fixture = await coldFixture("validated-single-fork-context");
    const slot = await fixture.registry.acquire(fixture.manager.getSessionId());
    const parentFile = slot.sessionFile!;
    const forksDirectory = join(dirname(parentFile), basename(parentFile, ".jsonl"), "forks");
    const asyncDir = join(fixture.cwd, ".pi", "subagents", "async-subagent-runs", "single-run");
    await Promise.all([mkdir(forksDirectory, { recursive: true }), mkdir(asyncDir, { recursive: true })]);
    const fork = SessionManager.forkFrom(parentFile, fixture.cwd, forksDirectory);
    fork.appendMessage(fauxAssistantMessage("single fork transcript"));
    const forkFile = fork.getSessionFile()!;
    const started = Date.now() - 1_000;
    const startedAt = new Date(started).toISOString();
    const internal = slot as unknown as {
      extensionActivities: Map<string, ExtensionRunActivity>;
      extensionRunOwnership: Map<string, { toolCallId: string; asyncDir?: string; terminal: boolean }>;
      refreshExtensionActivityFromArtifact: (toolCallId: string, asyncDir: string) => Promise<void>;
    };
    internal.extensionActivities.set("single-tool", {
      id: "single-tool", activityId: "single-activity", runId: "single-run", toolCallId: "single-tool",
      source: { source: "project", owner: { id: "extension:pi-subagents", title: "Subagents", source: "project" } }, title: "Subagents", mode: "asynchronous", status: "running",
      startedAt, updatedAt: startedAt, children: [],
      lifecycle: { version: 1, state: "running", attention: "none", sequence: 1, observedAt: startedAt },
    });
    internal.extensionRunOwnership.set("single-run", { toolCallId: "single-tool", asyncDir, terminal: false });
    const statusPath = join(asyncDir, "status.json");
    await writeFile(statusPath, JSON.stringify({
      runId: "single-run", state: "running", startedAt: started, lastUpdate: started + 500,
      mode: "single",
      steps: [{ agent: "worker", status: "running", sessionFile: forkFile }],
    }));

    await internal.refreshExtensionActivityFromArtifact("single-tool", asyncDir);
    const active = slot.snapshot().processActivities?.find((activity) => activity.kind === "subagent");
    expect(active).toMatchObject({ source: "delegatedAgent", childSessionRef: fork.getSessionId(), visibility: "active" });
    expect(slot.processChildSessionPath(active!.processId)).toEqual({
      ref: fork.getSessionId(), producerId: "step:0", runId: "single-run", path: await realpath(forkFile),
    });

    await writeFile(statusPath, JSON.stringify({
      runId: "single-run", state: "complete", startedAt: started, endedAt: started + 700, lastUpdate: started + 800,
      mode: "single",
      steps: [{ agent: "worker", status: "complete", sessionFile: forkFile }],
    }));
    await internal.refreshExtensionActivityFromArtifact("single-tool", asyncDir);
    const recent = slot.snapshot().processActivities?.find((activity) => activity.kind === "subagent");
    expect(recent).toMatchObject({
      processId: active!.processId,
      source: "delegatedAgent",
      childSessionRef: fork.getSessionId(),
      visibility: "recent",
      lifecycle: { state: "completed" },
    });
    expect((await fixture.registry.readOnlySubagentTranscriptPage(
      fork.getSessionId(), (await realpath(forkFile)), slot.id, recent!.processId, "single-run",
    )).total).toBeGreaterThan(0);
  });

  it("rejects wrong-parent, unbound, and extra-depth fork or fresh child paths", async () => {
    const fixture = await coldFixture("rejected-child-shapes");
    const slot = await fixture.registry.acquire(fixture.manager.getSessionId());
    const parentFile = slot.sessionFile!;
    const childRoot = join(dirname(parentFile), basename(parentFile, ".jsonl"));
    const forksDirectory = join(childRoot, "forks");
    const otherParent = SessionManager.create(fixture.cwd, dirname(parentFile), { id: "other-fork-parent" });
    otherParent.appendMessage(fauxAssistantMessage("other parent"));
    await mkdir(forksDirectory, { recursive: true });
    const wrongParentFork = SessionManager.forkFrom(otherParent.getSessionFile()!, fixture.cwd, forksDirectory);
    wrongParentFork.appendMessage(fauxAssistantMessage("wrong parent fork"));
    const validParentFork = SessionManager.forkFrom(parentFile, fixture.cwd, forksDirectory);
    validParentFork.appendMessage(fauxAssistantMessage("unbound fork"));
    const extraForkDirectory = join(forksDirectory, "extra");
    await mkdir(extraForkDirectory, { recursive: true });
    const extraDepthFork = SessionManager.forkFrom(parentFile, fixture.cwd, extraForkDirectory);
    extraDepthFork.appendMessage(fauxAssistantMessage("extra fork"));
    const extraRunDirectory = join(childRoot, "fresh-child", "run-0", "extra");
    await mkdir(extraRunDirectory, { recursive: true });
    const extraDepthRun = SessionManager.create(fixture.cwd, extraRunDirectory, {
      id: "extra-depth-run", parentSession: parentFile,
    });
    extraDepthRun.appendMessage(fauxAssistantMessage("extra run"));
    const extraDepthRunFile = join(extraRunDirectory, "session.jsonl");
    await rename(extraDepthRun.getSessionFile()!, extraDepthRunFile);
    const startedAt = new Date().toISOString();
    const activity: ExtensionRunActivity = {
      id: "tool", activityId: "activity", runId: "expected-run", toolCallId: "tool",
      source: { source: "project", owner: { id: "extension:pi-subagents", title: "Subagents", source: "project" } }, title: "Subagents", mode: "asynchronous", status: "running",
      startedAt, updatedAt: startedAt,
      children: [{ id: "artifact-child", label: "worker", status: "running" }],
      lifecycle: { version: 1, state: "running", attention: "none", sequence: 1, observedAt: startedAt },
    };
    const attach = (slot as unknown as {
      attachChildSessionReferences: (activity: ExtensionRunActivity, value: unknown) => ExtensionRunActivity;
    }).attachChildSessionReferences.bind(slot);
    const child = (sessionFile: string, producerId = "artifact-child", includeProducer = true) => attach({
      ...activity, children: [{ id: producerId, label: "worker", status: "running" }],
    }, {
      runId: "expected-run",
      results: [{ ...(includeProducer ? { runId: producerId } : {}), agent: producerId, sessionFile }],
    }).children[0]?.childSessionRef;

    expect(child(wrongParentFork.getSessionFile()!)).toBeUndefined();
    expect(child(validParentFork.getSessionFile()!, "artifact-child", false)).toBeUndefined();
    expect(child(extraDepthFork.getSessionFile()!)).toBeUndefined();
    expect(child(extraDepthRunFile, "fresh-child")).toBeUndefined();
  });

  it("fails closed for foreign or wrong-run child-session evidence", async () => {
    const fixture = await coldFixture("rejected-child-session");
    const slot = await fixture.registry.acquire(fixture.manager.getSessionId());
    const unrelatedDirectory = join(fixture.agentDir, "sessions", "workspace", "unrelated");
    await mkdir(unrelatedDirectory, { recursive: true });
    const unrelated = SessionManager.create(fixture.cwd, unrelatedDirectory, { id: "unrelated-child" });
    unrelated.appendMessage(fauxAssistantMessage("not this run"));
    const startedAt = new Date().toISOString();
    const activity: ExtensionRunActivity = {
      id: "tool", activityId: "activity", runId: "expected-run", toolCallId: "tool",
      source: { source: "project", owner: { id: "extension:pi-subagents", title: "Subagents", source: "project" } }, title: "Subagents", mode: "asynchronous", status: "running",
      startedAt, updatedAt: startedAt,
      children: [{ id: "child-run", label: "worker", status: "running" }],
      lifecycle: { version: 1, state: "running", attention: "none", sequence: 1, observedAt: startedAt },
    };
    const attach = (slot as unknown as {
      attachChildSessionReferences: (activity: ExtensionRunActivity, value: unknown) => ExtensionRunActivity;
    }).attachChildSessionReferences.bind(slot);
    const foreign = attach(activity, {
      runId: "expected-run",
      results: [{ runId: "child-run", sessionFile: unrelated.getSessionFile() }],
    });
    expect(foreign.children[0]?.childSessionRef).toBeUndefined();
    const wrongRun = attach(activity, {
      runId: "forged-run",
      results: [{ runId: "child-run", sessionFile: unrelated.getSessionFile() }],
    });
    expect(wrongRun.children[0]?.childSessionRef).toBeUndefined();

    const parentFile = slot.sessionFile!;
    const oversizedDirectory = join(dirname(parentFile), basename(parentFile, ".jsonl"), "expected-run", "run-0");
    await mkdir(oversizedDirectory, { recursive: true });
    const oversizedFile = join(oversizedDirectory, "session.jsonl");
    await writeFile(oversizedFile, `${JSON.stringify({ type: "session", version: 3, id: "oversized-child", timestamp: startedAt, cwd: fixture.cwd })}${" ".repeat(70 * 1_024)}\n`);
    const oversized = attach(activity, {
      runId: "expected-run",
      results: [{ runId: "child-run", sessionFile: oversizedFile }],
    });
    expect(oversized.children[0]?.childSessionRef).toBeUndefined();

    const missingParentDirectory = join(dirname(parentFile), basename(parentFile, ".jsonl"), "child-run", "run-missing-parent");
    await mkdir(missingParentDirectory, { recursive: true });
    const missingParent = SessionManager.create(fixture.cwd, missingParentDirectory, { id: "missing-parent-child" });
    missingParent.appendSessionInfo("subagent-worker");
    const missingParentResult = attach(activity, {
      runId: "expected-run",
      results: [{ runId: "child-run", sessionFile: missingParent.getSessionFile() }],
    });
    expect(missingParentResult.children[0]?.childSessionRef).toBeUndefined();

    const ordinaryDirectory = join(dirname(parentFile), basename(parentFile, ".jsonl"), "expected-run", "run-ordinary");
    await mkdir(ordinaryDirectory, { recursive: true });
    const ordinary = SessionManager.create(fixture.cwd, ordinaryDirectory, {
      id: "ordinary-child",
      parentSession: parentFile,
    });
    ordinary.appendSessionInfo("ordinary-worker");
    const ordinaryResult = attach(activity, {
      runId: "expected-run",
      results: [{ runId: "child-run", sessionFile: ordinary.getSessionFile() }],
    });
    expect(ordinaryResult.children[0]?.childSessionRef).toBeUndefined();
  });

  it("rejects canonical artifact paths outside the exact project run root", async () => {
    const fixture = await coldFixture("artifact-path-containment");
    const slot = await fixture.registry.acquire(fixture.manager.getSessionId());
    const parent = join(fixture.cwd, ".pi", "subagents");
    const sibling = join(parent, "sibling");
    await mkdir(sibling, { recursive: true });
    const allowed = (slot as unknown as { extensionArtifactPathAllowed: (path: string) => boolean })
      .extensionArtifactPathAllowed.bind(slot);
    expect(allowed(parent)).toBe(false);
    expect(allowed(sibling)).toBe(false);
  });

  it("retains nonterminal artifact authority until receipt capacity is available", async () => {
    const workRegistry = new GatewayWorkRegistry("epoch", 2);
    const fixture = await coldFixture("artifact-receipt-capacity", { workRegistry });
    const slot = await fixture.registry.acquire(fixture.manager.getSessionId());
    const runId = "capacity-run";
    const toolCallId = "capacity-tool";
    const activityId = "capacity-activity";
    const asyncDir = join(fixture.cwd, ".pi", "subagents", "async-subagent-runs", runId);
    await mkdir(asyncDir, { recursive: true });
    const startedAt = new Date(Date.now() - 1_000).toISOString();
    const internal = slot as unknown as {
      extensionActivities: Map<string, ExtensionRunActivity>;
      extensionRunOwnership: Map<string, { toolCallId: string; asyncDir?: string; terminal: boolean }>;
    };
    internal.extensionActivities.set(toolCallId, {
      id: toolCallId, activityId, runId, toolCallId,
      source: { source: "pi-subagents" }, title: "Pi Subagents", status: "running",
      startedAt, updatedAt: startedAt, children: [],
      lifecycle: { version: 1, state: "running", attention: "none", sequence: 1, observedAt: startedAt },
    });
    internal.extensionRunOwnership.set(runId, { toolCallId, asyncDir, terminal: false });
    expect(workRegistry.facts().filter((fact) => fact.sessionId === slot.id)).toEqual([]);
    const capacityOwner = workRegistry.beginDerived({
      kind: "administrative-provider-package-operation",
      hostEpoch: workRegistry.runtimeEpoch,
    });
    const endedAt = Date.now();
    await writeFile(join(asyncDir, "status.json"), JSON.stringify({
      runId, state: "complete", startedAt: Date.parse(startedAt), endedAt, lastUpdate: endedAt + 1,
    }));

    await slot.reconcileOwnedExtensionArtifactsForDrain();
    expect(slot.snapshot().extensionActivities).toMatchObject([{ lifecycle: { state: "running" } }]);
    expect(slot.administrativeDrainBlockers()).toHaveLength(1);

    capacityOwner.settle();
    await slot.reconcileOwnedExtensionArtifactsForDrain();
    await waitFor(() => slot.snapshot().extensionActivities[0]?.lifecycle?.state === "completed", "the first extension activity to complete");
    expect(slot.administrativeDrainBlockers()).toEqual([]);
    await waitFor(() => workRegistry.size === 0, "the work registry to drain");
  });

  it("does not treat terminal attention presentation as drain work", async () => {
    const fixture = await coldFixture("terminal-attention-presentation");
    const slot = await fixture.registry.acquire(fixture.manager.getSessionId());
    const observedAt = new Date().toISOString();
    const internal = slot as unknown as { extensionActivities: Map<string, ExtensionRunActivity> };
    internal.extensionActivities.set("terminal-tool", {
      id: "terminal-tool", activityId: "terminal-activity", runId: "terminal-run", toolCallId: "terminal-tool",
      source: { source: "pi-subagents" }, title: "Pi Subagents", status: "failed",
      startedAt: observedAt, updatedAt: observedAt, children: [],
      lifecycle: {
        version: 1, state: "failed", attention: "needsAttention", sequence: 1,
        observedAt, terminalAt: observedAt,
      },
    });

    expect(slot.administrativeDrainBlockers()).toEqual([]);
    expect(slot.isDrainBusy).toBe(false);
  });

  it("keeps genuinely running exact-owned artifact work blocking across clock advances", async () => {
    const fixture = await coldFixture("running-artifact-clock");
    const slot = await fixture.registry.acquire(fixture.manager.getSessionId());
    const startedAt = new Date().toISOString();
    const internal = slot as unknown as { extensionActivities: Map<string, ExtensionRunActivity> };
    internal.extensionActivities.set("running-tool", {
      id: "running-tool", activityId: "running-activity", runId: "running-run", toolCallId: "running-tool",
      source: { source: "pi-subagents" }, title: "Pi Subagents", status: "running",
      startedAt, updatedAt: startedAt, children: [],
      lifecycle: { version: 1, state: "running", attention: "none", sequence: 1, observedAt: startedAt },
    });
    vi.useFakeTimers();
    try {
      vi.setSystemTime(new Date(Date.now() + 365 * 24 * 60 * 60_000));
      await vi.advanceTimersByTimeAsync(365 * 24 * 60 * 60_000);
      expect(slot.isDrainBusy).toBe(true);
    } finally {
      vi.useRealTimers();
    }
  });

  it("rate-limits artifact rejection warnings behind opaque owner identities", async () => {
    const fixture = await coldFixture("artifact-warning-redaction");
    const slot = await fixture.registry.acquire(fixture.manager.getSessionId());
    const warnings: Array<{ reason: string; owner: string }> = [];
    const internal = slot as unknown as {
      dependencies: { extensionArtifactWarning?: (warning: { reason: string; owner: string }) => void };
      warnExtensionArtifact: (reason: "ownership-mismatch", owner: string) => void;
    };
    internal.dependencies.extensionArtifactWarning = (warning) => warnings.push(warning);
    internal.warnExtensionArtifact("ownership-mismatch", "/private/project/run-with-output");
    internal.warnExtensionArtifact("ownership-mismatch", "/private/project/run-with-output");
    expect(warnings).toEqual([{ reason: "ownership-mismatch", owner: expect.stringMatching(/^[0-9a-f]{24}$/u) }]);
    expect(JSON.stringify(warnings)).not.toContain("private");
    expect(JSON.stringify(warnings)).not.toContain("output");
  });

  it.each(["missing directory", "malformed status", "foreign header", "watcher error", "temporary status absence"] as const)(
    "keeps root admission and observation independent of child %s", async (failure) => {
      const fixture = await coldFixture("optional-child-detail");
      try {
        const slot = await fixture.registry.acquire(fixture.manager.getSessionId());
        const runId = "optional-root";
        const toolCallId = "optional-tool";
        const childRun = "optional-child";
        const artifactRoot = join(await realpath(fixture.cwd), ".pi", "subagents", "async-subagent-runs");
        const asyncDir = join(artifactRoot, runId);
        const childDir = join(artifactRoot, childRun);
        const childSessionDir = join(dirname(slot.sessionFile!), basename(slot.sessionFile!, ".jsonl"), childRun, "run-0");
        await mkdir(childSessionDir, { recursive: true });
        const manager = SessionManager.create(fixture.cwd, childSessionDir, { id: "optional-child-session" });
        manager.appendMessage(fauxAssistantMessage("Child transcript"));
        const childFile = join(childSessionDir, "session.jsonl");
        await rename(manager.getSessionFile()!, childFile);
        await mkdir(asyncDir, { recursive: true });
        // Derive the workflow/child documents from the producer capture, retaining
        // its real header and lifecycle shape rather than mocking the read owner.
        const captured = JSON.parse(await readFile(join(dirname(fileURLToPath(import.meta.url)), "fixtures", "frozen-real-active.json"), "utf8"));
        const started = captured.startedAt as number;
        const edge = { agent: "worker", label: "Worker", status: "running", async: true, runId: childRun,
          workflowKey: "worker", sessionOwnerId: childRun, sessionFile: childFile };
        const document = (id: string, mode: string, steps: unknown[], update: number) => ({
          lifecycleProjection: { ...captured.lifecycleProjection, runId: id, toolCallId, sessionId: slot.sessionFile,
            generatedAt: update, omitted: { runs: 0, children: 0, byteLimitExceeded: false },
            root: { id, kind: mode === "workflow" ? "workflow" : "subagent", label: "Root", state: "running", startedAt: started, updatedAt: update, children: [] } },
          runId: id, toolCallId, sessionId: slot.sessionFile, mode, state: "running", startedAt: started, lastUpdate: update, steps,
        });
        const root = document(runId, "workflow", [edge], started + 5_000);
        const child = { ...document(childRun, "single", [{ agent: "worker", sessionFile: childFile, status: "running", model: "fixture/child", toolCount: 3 }], started + 5_000),
          parentWorkflowRunId: runId, workflowKey: "worker", sessionOwnerId: childRun };
        const replace = async (directory: string, value: unknown) => {
          await mkdir(directory, { recursive: true });
          const temp = join(directory, "replacement.json");
          await writeFile(temp, typeof value === "string" ? value : JSON.stringify(value));
          await rename(temp, join(directory, "status.json"));
        };
        const internal = slot as unknown as {
          extensionActivityWatchers: Map<string, { watcher: import("node:fs").FSWatcher; children: Map<string, import("node:fs").FSWatcher> }>;
          extensionActivities: Map<string, ExtensionRunActivity>;
          extensionRunOwnership: Map<string, { toolCallId: string; asyncDir: string; terminal: boolean }>;
        };
        try {
          // Seed the same admitted launcher boundary as the producer-capture fixture.
          internal.extensionActivities.set(toolCallId, { id: toolCallId, runId, toolCallId,
            source: { source: "pi-subagents" }, title: "Subagents", status: "running", children: [],
            startedAt: new Date(started).toISOString(), updatedAt: new Date(started).toISOString(),
            lifecycle: { version: 1, state: "running", attention: "none", sequence: 1, observedAt: new Date(started).toISOString() } });
          internal.extensionRunOwnership.set(runId, { toolCallId, asyncDir, terminal: false });
          // Canonical launch evidence, not optional child detail, admits the root.
          const runtimeManager = (slot as unknown as { runtime: { session: { sessionManager: SessionManager } } }).runtime.session.sessionManager;
          runtimeManager.appendMessage({ role: "toolResult", toolName: "subagent", toolCallId, content: [{ type: "text", text: "Workflow started" }],
            details: { runId, asyncId: runId, asyncDir, mode: "workflow", state: "running" }, isError: false, timestamp: started });
          const activity = () => internal.extensionActivities.get(toolCallId);
          const partial = () => activity()?.lifecycleOmissions?.children;
          if (failure !== "missing directory") await replace(childDir, child);
          await replace(asyncDir, root);
          expect(await slot.discoverExtensionArtifact(asyncDir), "root artifact admission").toBe("accepted");
          expect(activity(), "root admitted on its own evidence").toMatchObject({ runId, status: "running", updatedAt: new Date(started + 5_000).toISOString() });
          expect(internal.extensionActivityWatchers.has(toolCallId), "root watcher started").toBe(true);
          if (failure !== "missing directory") expect(activity()?.children[0], "reciprocal fixture detail").toMatchObject({ model: "fixture/child" });
          await waitFor(() => internal.extensionActivityWatchers.get(toolCallId)?.children.has(childDir) === true, "root edge owns subscription");
          if (failure === "missing directory") {
            expect(partial()).toBe(1);
          } else {
            await waitFor(() => activity()?.children[0]?.model === "fixture/child", "initial optional detail hydrated");
            if (failure === "malformed status") await replace(childDir, "{malformed");
            if (failure === "foreign header") await replace(childDir, { ...child,
              lifecycleProjection: { ...child.lifecycleProjection, sessionId: "/foreign/parent.jsonl" },
              steps: [{ ...child.steps[0], model: "FORGED_MODEL" }] });
            if (failure === "temporary status absence") await rm(join(childDir, "status.json"));
            if (failure === "watcher error") {
              const rootWatcher = internal.extensionActivityWatchers.get(toolCallId)!.watcher;
              internal.extensionActivityWatchers.get(toolCallId)!.children.get(childDir)!.emit("error", new Error("Injected child observation failure"));
              expect(internal.extensionActivityWatchers.get(toolCallId)?.watcher, "child error preserves the same root observer").toBe(rootWatcher);
            }
            const updated = { ...root, lastUpdate: started + 10_000,
              lifecycleProjection: { ...root.lifecycleProjection, generatedAt: started + 10_000, root: { ...root.lifecycleProjection.root, updatedAt: started + 10_000 } } };
            await replace(asyncDir, updated);
            await waitFor(() => activity()?.updatedAt === new Date(started + 10_000).toISOString(), "root watcher publishes despite child failure");
            expect(internal.extensionActivityWatchers.get(toolCallId)?.children.has(childDir), "unchanged edge stays subscribed").toBe(true);
            expect(await slot.discoverExtensionArtifact(asyncDir), "optional detail never rejects discovery").toBe("accepted");
            if (failure !== "watcher error") expect(partial()).toBe(1);
            expect(JSON.stringify(activity())).not.toContain("FORGED_MODEL");
          }
          expect(internal.extensionActivityWatchers.has(toolCallId), "child failure cannot retire root").toBe(true);
          // No discovery or root write: the child edge observation alone must wake
          // hydration after a missing directory, invalid document or absent status.
          await replace(childDir, { ...child, steps: [{ ...child.steps[0], model: "fixture/recovered", toolCount: 4 }] });
          await waitFor(() => activity()?.children[0]?.model === "fixture/recovered", "child-only write hydrates detail");
          expect(partial() ?? 0).toBe(0);
          expect(slot.snapshot().processActivities).toEqual(expect.arrayContaining([expect.objectContaining({ model: "fixture/recovered", toolCount: 4 })]));
          // Retire subscriptions only on authoritative edge removal/root disposal.
          await replace(asyncDir, { ...root, steps: [] });
          await waitFor(() => internal.extensionActivityWatchers.get(toolCallId)?.children.size === 0, "root edge removal retires observation");
        } finally {
          // This fixture owns synthetic running evidence, not a provider process.
          // Always settle it before the registry's drain-aware cleanup, even when
          // an assertion fails against the unfixed optional-detail reader.
          await replace(asyncDir, { ...root, state: "completed", endedAt: started + 20_000, lastUpdate: started + 20_000, steps: [],
            lifecycleProjection: { ...root.lifecycleProjection, root: { ...root.lifecycleProjection.root, state: "complete", endedAt: started + 20_000, updatedAt: started + 20_000 } } });
          await slot.discoverExtensionArtifact(asyncDir);
        }
        expect(internal.extensionActivityWatchers.size).toBe(0);
      } finally {
        await fixture.registry.dispose().finally(() => rm(fixture.root, { recursive: true, force: true }));
      }
    }, 15_000,
  );

  it("discovers real producer-serialized lifecycle headers without parsing oversized reports", async () => {
    const fixture = await coldFixture("embedded-lifecycle-header");
    const slot = await fixture.registry.acquire(fixture.manager.getSessionId());
    const runId = "frozen-real-run";
    const toolCallId = "frozen-real-tool";
    const asyncDir = join(fixture.cwd, ".pi", "subagents", "async-subagent-runs", runId);
    const parentFile = slot.sessionFile!;
    const childRoot = join(dirname(parentFile), basename(parentFile, ".jsonl"), runId);
    const makeChildSession = async (runName: string, id: string): Promise<string> => {
      const childDirectory = join(childRoot, runName);
      await mkdir(childDirectory, { recursive: true });
      const manager = SessionManager.create(fixture.cwd, childDirectory, { id });
      manager.appendMessage(fauxAssistantMessage(`${runName} transcript`));
      const generated = manager.getSessionFile()!;
      const childFile = join(childDirectory, "session.jsonl");
      await rename(generated, childFile);
      return childFile;
    };
    const childFile = await makeChildSession("run-0", "frozen-child-session");
    const nestedFile = await makeChildSession("run-1", "frozen-nested-session");
    await mkdir(asyncDir, { recursive: true });
    const fixturePath = (name: "active" | "terminal") => join(dirname(fileURLToPath(import.meta.url)), "fixtures", `frozen-real-${name}.json`);
    const loadFixture = async (name: "active" | "terminal"): Promise<string> => {
      const parsed = JSON.parse(await readFile(fixturePath(name), "utf8")) as {
        lifecycleProjection: { sessionId?: string };
      };
      // The frozen producer capture uses a placeholder owner; bind it to this
      // fixture's exact canonical parent session before exercising admission.
      parsed.lifecycleProjection.sessionId = slot.sessionFile;
      return JSON.stringify(parsed)
        .replaceAll("/tmp/frozen-real-child/session.jsonl", childFile)
        .replaceAll("/tmp/frozen-real-nested/session.jsonl", nestedFile);
    };
    const internal = slot as unknown as {
      extensionActivities: Map<string, ExtensionRunActivity>;
      extensionRunOwnership: Map<string, { toolCallId: string; asyncDir?: string; terminal: boolean }>;
    };
    const started = 1_700_000_000_000;
    internal.extensionActivities.set(toolCallId, {
      id: toolCallId, activityId: "frozen-real-activity", runId, toolCallId,
      source: { source: "pi-subagents" }, title: "Pi Subagents", status: "running",
      startedAt: new Date(started).toISOString(), updatedAt: new Date(started).toISOString(), children: [],
      lifecycle: { version: 1, state: "running", attention: "none", sequence: 1, observedAt: new Date(started).toISOString() },
    });
    internal.extensionRunOwnership.set(runId, { toolCallId, asyncDir, terminal: false });
    await writeFile(join(asyncDir, "status.json"), await loadFixture("active"));
    await slot.discoverExtensionArtifact(asyncDir);
    const active = slot.snapshot().extensionActivities?.find((activity) => activity.toolCallId === toolCallId)!;
    expect(active).toMatchObject({ status: "running", lifecycle: { state: "running" } });
    expect(active.children).toEqual(expect.arrayContaining([
      expect.objectContaining({ currentTool: "bash", toolCount: 3, childSessionRef: "frozen-child-session", children: expect.arrayContaining([expect.objectContaining({ currentTool: "read", childSessionRef: "frozen-nested-session" })]) }),
      expect.objectContaining({ hostStep: expect.objectContaining({ provider: "github", role: "checks" }) }),
    ]));
    expect(active).not.toHaveProperty("output");
    expect(JSON.stringify(active)).not.toContain("x".repeat(1_024));
    expect(slot.snapshot().processActivities).toEqual(expect.arrayContaining([expect.objectContaining({ childSessionRef: "frozen-child-session", currentTool: "bash" })]));
    expect(slot.snapshot().processOverview.extensionChildOmissions).toMatchObject({ children: 34, byteLimitExceeded: true });

    // A legacy status payload may contain a presentation-shaped
    // `lifecycleProjection`, but that key is not proof that its sessionOwnerId
    // was emitted by the admitted status header. A forged owner must not make
    // a child outside this run's reserved path admissible.
    const foreignDirectory = join(dirname(parentFile), basename(parentFile, ".jsonl"), "forged-owner", "run-0");
    await mkdir(foreignDirectory, { recursive: true });
    const foreignManager = SessionManager.create(fixture.cwd, foreignDirectory, { id: "forged-child-session" });
    foreignManager.appendMessage(fauxAssistantMessage("forged owner transcript"));
    const foreignFile = join(foreignDirectory, "session.jsonl");
    await rename(foreignManager.getSessionFile()!, foreignFile);
    await writeFile(join(asyncDir, "status.json"), JSON.stringify({
      lifecycleArtifactVersion: 3,
      lifecycleProjection: { presentationOnly: true },
      runId,
      state: "running",
      startedAt: started,
      lastUpdate: started + 6_000,
      mode: "workflow",
      steps: [{ runId: "forged-child", sessionOwnerId: "forged-owner", agent: "forged", status: "running", sessionFile: foreignFile }],
    }));
    await slot.discoverExtensionArtifact(asyncDir);
    const forged = slot.snapshot().extensionActivities?.find((activity) => activity.toolCallId === toolCallId)!;
    expect(forged.children[0]?.childSessionRef).toBeUndefined();
    expect(slot.snapshot().processActivities?.some((activity) => activity.childSessionRef === "forged-child-session")).toBe(false);

    await writeFile(join(asyncDir, "status.json"), await loadFixture("terminal"));
    await slot.discoverExtensionArtifact(asyncDir);
    const terminal = slot.snapshot().extensionActivities?.find((activity) => activity.toolCallId === toolCallId)!;
    expect(terminal).toMatchObject({ status: "completed", lifecycle: { state: "completed" }, completedAt: new Date(1_700_000_010_000).toISOString() });
  });

  it("rejects foreign producer session headers before live or reconstructed activity admission", async () => {
    const fixture = await coldFixture("foreign-producer-session-header");
    const runId = "packed-producer-owned-session-run";
    const toolCallId = "packed-producer-owned-session-tool";
    const asyncDir = join(fixture.cwd, ".pi", "subagents", "async-subagent-runs", runId);
    await mkdir(asyncDir, { recursive: true });
    const slot = await fixture.registry.acquire(fixture.manager.getSessionId());
    const fixtureDirectory = join(dirname(fileURLToPath(import.meta.url)), "fixtures");
    const loadHeader = async (name: string): Promise<Record<string, unknown>> => {
      const parsed = JSON.parse(await readFile(join(fixtureDirectory, name), "utf8")) as { lifecycleProjection: Record<string, unknown> };
      return structuredClone(parsed.lifecycleProjection);
    };
    // These compact first-property headers were serialized by writeAsyncStatusAtomic
    // from packed pi-subagents d3bd36e5c1767c807615151922192554fef36ec3.
    const ownedHeader = await loadHeader("packed-producer-owned-lifecycle-header.json");
    ownedHeader.sessionId = slot.sessionFile;
    const foreignHeader = await loadHeader("packed-producer-foreign-lifecycle-header.json");
    const foreignTerminalHeader = await loadHeader("packed-producer-foreign-terminal-lifecycle-header.json");
    expect(foreignHeader).toMatchObject({ runId, toolCallId, sessionId: "foreign-parent-session", root: { children: expect.arrayContaining([expect.objectContaining({ id: "step-a", state: "failed" })]) } });
    expect(foreignTerminalHeader).toMatchObject({ runId, toolCallId, sessionId: "foreign-parent-session", root: { state: "complete", endedAt: expect.any(Number) } });

    const writeHeader = async (projection: Record<string, unknown>) => {
      await writeFile(join(asyncDir, "status.json"), JSON.stringify({
        lifecycleProjection: projection,
        error: "oversized workflow report " + "x".repeat(300 * 1_024),
      }));
      expect((await readFile(join(asyncDir, "status.json"))).byteLength).toBeGreaterThan(256 * 1_024);
    };
    const runtimeManager = (slot as unknown as { runtime: { session: { sessionManager: SessionManager } } }).runtime.session.sessionManager;
    runtimeManager.appendMessage({
      role: "toolResult", toolCallId, toolName: "subagent", content: [{ type: "text", text: "launched" }],
      details: { runId, asyncId: runId, asyncDir, mode: "workflow", state: "running" },
      isError: false, timestamp: Date.now(),
    });
    vi.spyOn(slot as unknown as { extensionToolOrigin: (name: string) => { source: string } | undefined }, "extensionToolOrigin")
      .mockReturnValue({ source: "pi-subagents" });

    const warnings: Array<{ reason: string; owner: string }> = [];
    (slot as unknown as { dependencies: { extensionArtifactWarning?: (warning: { reason: string; owner: string }) => void } })
      .dependencies.extensionArtifactWarning = (warning) => warnings.push(warning);
    await writeHeader(ownedHeader);
    await slot.discoverExtensionArtifact(asyncDir);
    const admitted = slot.snapshot().extensionActivities?.find((activity) => activity.toolCallId === toolCallId)!;
    expect(admitted).toMatchObject({ status: "running", children: expect.arrayContaining([
      expect.objectContaining({ id: "step-a", status: "completed" }),
      expect.objectContaining({ id: "step-c", status: "running" }),
    ]) });

    // Exact run/tool/path bindings do not authorize this producer header's foreign session.
    await writeHeader(foreignHeader);
    await slot.discoverExtensionArtifact(asyncDir);
    const afterForeign = slot.snapshot().extensionActivities?.find((activity) => activity.toolCallId === toolCallId)!;
    expect(afterForeign.children.find((child) => child.id === "step-a")?.status).toBe("completed");
    expect(warnings).toContainEqual(expect.objectContaining({ reason: "ownership-mismatch" }));
    await writeHeader(foreignTerminalHeader);
    await slot.discoverExtensionArtifact(asyncDir);
    expect(slot.snapshot().extensionActivities?.find((activity) => activity.toolCallId === toolCallId)?.status).toBe("running");
    const receiptCount = async (sessionFile: string) => (await readFile(sessionFile, "utf8"))
      .trimEnd().split("\n").map((line) => JSON.parse(line) as Record<string, unknown>)
      .filter((entry) => entry.type === "custom" && entry.customType === EXTENSION_ACTIVITY_RECEIPT_TYPE).length;
    expect(await receiptCount(slot.sessionFile!)).toBe(0);

    // A cold reconstructed slot must reject the same foreign terminal header before
    // it can synthesize a child or append a terminal parent receipt.
    await fixture.registry.dispose();
    const recoveredRegistry = new RuntimeRegistry({
      agentDir: fixture.agentDir, tronHome: join(fixture.root, "tron"), idleRuntimeMs: 60_000,
      trust: new TrustService(fixture.agentDir), broadcast: () => {},
      sessionSummaryChanged: () => {}, sessionListChanged: () => {},
    });
    registries.push(recoveredRegistry);
    await initializeRegistry(recoveredRegistry);
    const recoveredSlot = await recoveredRegistry.acquire(slot.id);
    vi.spyOn(recoveredSlot as unknown as { extensionToolOrigin: (name: string) => { source: string } | undefined }, "extensionToolOrigin")
      .mockReturnValue({ source: "pi-subagents" });
    await discoverExtensionArtifactsUntil(recoveredRegistry);
    await recoveredSlot.discoverExtensionArtifact(asyncDir);
    const coldForeign = recoveredSlot.snapshot().extensionActivities?.find((activity) => activity.runId === runId);
    expect(coldForeign?.status).not.toBe("completed");
    expect(coldForeign?.children.some((child) => child.id === "step-a" && child.status === "completed")).not.toBe(true);
    expect(await receiptCount(recoveredSlot.sessionFile!)).toBe(0);

    await writeHeader(ownedHeader);
    await discoverExtensionArtifactsUntil(recoveredRegistry);
    expect(recoveredSlot.snapshot().extensionActivities?.find((activity) => activity.toolCallId === toolCallId)).toMatchObject({
      status: "running", children: expect.arrayContaining([expect.objectContaining({ id: "step-a", status: "completed" })]),
    });
    expect(await receiptCount(recoveredSlot.sessionFile!)).toBe(0);
  });

  it("discovers oversized active lifecycle headers on the registered path and after runtime reconstruction", async () => {
    const fixture = await coldFixture("oversized-active-lifecycle-discovery");
    const runId = "oversized-active-workflow";
    const toolCallId = "oversized-active-tool";
    const asyncDir = join(fixture.cwd, ".pi", "subagents", "async-subagent-runs", runId);
    await mkdir(asyncDir, { recursive: true });
    const slot = await fixture.registry.acquire(fixture.manager.getSessionId());
    const now = Date.now();
    const root = {
      id: runId, kind: "workflow", label: "large workflow", state: "running",
      startedAt: now - 10_000, updatedAt: now,
      children: [
        { id: "step-a", kind: "step", label: "A", state: "complete", startedAt: now - 9_000, updatedAt: now - 5_000, endedAt: now - 5_000 },
        { id: "step-b", kind: "step", label: "B", state: "complete", startedAt: now - 8_000, updatedAt: now - 4_000, endedAt: now - 4_000 },
        { id: "step-c", kind: "step", label: "C", state: "running", startedAt: now - 3_000, updatedAt: now },
      ],
    };
    const projection = () => ({
      version: 1, runId, toolCallId, sessionId: slot.sessionFile, generatedAt: root.updatedAt,
      caps: { maxRuns: 1, maxChildrenPerNode: 8, maxDepth: 3, maxStringLength: 160, maxSerializedBytes: 30_720 },
      omitted: { runs: 0, children: 0, byteLimitExceeded: false }, root: structuredClone(root),
    });
    const statusPath = join(asyncDir, "status.json");
    const writeModern = async () => writeFile(statusPath, JSON.stringify({
      lifecycleProjection: projection(), lifecycleArtifactVersion: 3, runId, state: root.state,
      startedAt: root.startedAt, lastUpdate: root.updatedAt,
      steps: [{ report: "x".repeat(300 * 1_024) }],
    }));
    const runtimeManager = (slot as unknown as { runtime: { session: { sessionManager: SessionManager } } }).runtime.session.sessionManager;
    runtimeManager.appendMessage({
      role: "toolResult", toolCallId, toolName: "subagent", content: [{ type: "text", text: "launched" }],
      details: { runId, asyncId: runId, asyncDir, mode: "workflow", state: "running" },
      isError: false, timestamp: now,
    });
    vi.spyOn(slot as unknown as { extensionToolOrigin: (name: string) => { source: string } | undefined }, "extensionToolOrigin")
      .mockReturnValue({ source: "pi-subagents" });
    await writeModern();
    await discoverExtensionArtifactsUntil(fixture.registry, () => {
      const activity = (slot.snapshot().extensionActivities ?? []).find((candidate) => candidate.toolCallId === toolCallId);
      return activity?.status === "running"
        && activity.children.some((child) => child.id === "step-c" && child.status === "running");
    });
    expect((slot.snapshot().extensionActivities ?? []).find((activity) => activity.toolCallId === toolCallId)).toMatchObject({
      status: "running", children: expect.arrayContaining([
        expect.objectContaining({ id: "step-a", status: "completed" }),
        expect.objectContaining({ id: "step-b", status: "completed" }),
        expect.objectContaining({ id: "step-c", status: "running" }),
      ]),
    });
    expect(slot.snapshot().processOverview.extensionChildOmissions).toMatchObject({ byteLimitExceeded: true });
    expect((await readFile(statusPath)).byteLength).toBeGreaterThan(256 * 1_024);

    const foreignProjection = projection();
    foreignProjection.sessionId = "another-session";
    await writeFile(statusPath, JSON.stringify({ lifecycleProjection: foreignProjection, steps: [{ report: "x".repeat(300 * 1_024) }] }));
    await slot.discoverExtensionArtifact(asyncDir);
    expect((slot.snapshot().extensionActivities ?? []).find((activity) => activity.toolCallId === toolCallId)?.status).toBe("running");
    await writeFile(statusPath, `{"lifecycleProjection":${"x".repeat(300 * 1_024)}`);
    await slot.discoverExtensionArtifact(asyncDir);
    expect((slot.snapshot().extensionActivities ?? []).find((activity) => activity.toolCallId === toolCallId)?.status).toBe("running");
    await writeModern();

    // Known-bad control: the old headerless oversized artifact cannot refresh;
    // after the existing missing grace it hides the live activity as unknown.
    const slotState = slot as unknown as {
      extensionArtifactMissingSince: Map<string, number>;
      extensionActivities: Map<string, ExtensionRunActivity>;
      stopExtensionActivityWatcher: (id: string) => void;
      dependencies: { extensionArtifactWarning?: (warning: { reason: string; owner: string }) => void };
    };
    slotState.stopExtensionActivityWatcher(toolCallId);
    await writeFile(statusPath, JSON.stringify({
      runId, state: "running", startedAt: root.startedAt, lastUpdate: root.updatedAt,
      steps: [{ report: "x".repeat(300 * 1_024) }],
    }));
    const artifactWarnings: Array<{ reason: string; owner: string }> = [];
    slotState.dependencies.extensionArtifactWarning = (warning) => artifactWarnings.push(warning);
    slotState.extensionArtifactMissingSince.set(toolCallId, Date.now() - 31_000);
    await slot.discoverExtensionArtifact(asyncDir);
    expect(artifactWarnings).toMatchObject([{ reason: "oversized-artifact" }]);
    expect(artifactWarnings).not.toMatchObject([{ reason: "artifact-replacement-in-progress" }]);
    expect(slotState.extensionActivities.get(toolCallId)?.lifecycle?.state).toBe("unknown");
    expect((slot.snapshot().extensionActivities ?? []).some((activity) => activity.toolCallId === toolCallId)).toBe(false);

    // Reconstruct the Gateway runtime and verify bounded-header ambient discovery
    // re-admits the same canonical owner without parsing its large report body.
    await fixture.registry.dispose();
    await writeModern();
    const recoveredRegistry = new RuntimeRegistry({
      agentDir: fixture.agentDir, tronHome: join(fixture.root, "tron"), idleRuntimeMs: 60_000,
      trust: new TrustService(fixture.agentDir), broadcast: () => {},
      sessionSummaryChanged: () => {}, sessionListChanged: () => {},
    });
    registries.push(recoveredRegistry);
    await initializeRegistry(recoveredRegistry);
    const recoveredSlot = await recoveredRegistry.acquire(slot.id);
    vi.spyOn(recoveredSlot as unknown as { extensionToolOrigin: (name: string) => { source: string } | undefined }, "extensionToolOrigin")
      .mockReturnValue({ source: "pi-subagents" });
    await discoverExtensionArtifactsUntil(recoveredRegistry, () => {
      const activity = (recoveredSlot.snapshot().extensionActivities ?? []).find((candidate) => candidate.toolCallId === toolCallId);
      return activity?.status === "running"
        && activity.children.some((child) => child.id === "step-c" && child.status === "running");
    });
    expect((recoveredSlot.snapshot().extensionActivities ?? []).find((activity) => activity.toolCallId === toolCallId)).toMatchObject({
      status: "running", children: expect.arrayContaining([
        expect.objectContaining({ id: "step-a", status: "completed" }),
        expect.objectContaining({ id: "step-b", status: "completed" }),
        expect.objectContaining({ id: "step-c", status: "running" }),
      ]),
    });

    root.state = "complete";
    root.updatedAt = Date.now();
    Object.assign(root, { endedAt: root.updatedAt });
    await writeFile(statusPath, JSON.stringify({
      lifecycleProjection: projection(), lifecycleArtifactVersion: 3, runId, state: "complete",
      startedAt: root.startedAt, endedAt: root.updatedAt, lastUpdate: root.updatedAt,
      steps: [{ report: "x".repeat(300 * 1_024) }],
    }));
    await recoveredSlot.discoverExtensionArtifact(asyncDir);
    await recoveredRegistry.waitUntilIdle();
    expect((recoveredSlot.snapshot().extensionActivities ?? []).find((activity) => activity.toolCallId === toolCallId)?.status).toBe("completed");
    const canonical = (await readFile(slot.sessionFile!, "utf8")).trimEnd().split("\n")
      .map((line) => JSON.parse(line) as Record<string, unknown>);
    expect(canonical.filter((entry) => entry.type === "custom" && entry.customType === EXTENSION_ACTIVITY_RECEIPT_TYPE)).toHaveLength(1);
  });

  it("reconciles an exact-owned oversized terminal artifact from bounded event evidence", async () => {
    const fixture = await coldFixture("oversized-terminal-drain");
    const slot = await fixture.registry.acquire(fixture.manager.getSessionId());
    const runId = "oversized-terminal-run";
    const toolCallId = "oversized-terminal-tool";
    const asyncDir = join(fixture.cwd, ".pi", "subagents", "async-subagent-runs", runId);
    await mkdir(asyncDir, { recursive: true });
    const started = Date.now() - 5_000;
    const ended = Date.now() - 1_000;
    const startedAt = new Date(started).toISOString();
    const internal = slot as unknown as {
      extensionActivities: Map<string, ExtensionRunActivity>;
      extensionRunOwnership: Map<string, { toolCallId: string; asyncDir?: string; terminal: boolean }>;
    };
    internal.extensionActivities.set(toolCallId, {
      id: toolCallId,
      activityId: "oversized-terminal-activity",
      runId,
      toolCallId,
      source: { source: "pi-subagents" },
      title: "Pi Subagents",
      status: "running",
      startedAt,
      updatedAt: startedAt,
      children: [],
      lifecycle: {
        version: 1,
        state: "running",
        attention: "none",
        sequence: 1,
        observedAt: startedAt,
      },
    });
    internal.extensionRunOwnership.set(runId, { toolCallId, asyncDir, terminal: false });
    const status = JSON.stringify({
      runId,
      state: "complete",
      startedAt: started,
      lastUpdate: ended + 1,
      steps: [{ output: "x".repeat(300 * 1_024) }],
      endedAt: ended,
    });
    const completedEvent = JSON.stringify({
      ts: ended + 2,
      runId,
      type: "subagent.workflow.completed",
      state: "complete",
    });
    const foreignDir = join(fixture.cwd, ".pi", "subagents", "async-subagent-runs", "foreign-oversized-run");
    await mkdir(foreignDir);
    await writeFile(join(foreignDir, "status.json"), status);
    await symlink(join(foreignDir, "status.json"), join(asyncDir, "status.json"));
    await writeFile(join(asyncDir, "events.jsonl"), `${completedEvent}\n`);

    await slot.discoverExtensionArtifact(asyncDir);
    expect(slot.isDrainBusy).toBe(true);

    await rm(join(asyncDir, "status.json"));
    await writeFile(join(asyncDir, "status.json"), status);
    await writeFile(join(foreignDir, "events.jsonl"), `${completedEvent}\n`);
    await rm(join(asyncDir, "events.jsonl"));
    await symlink(join(foreignDir, "events.jsonl"), join(asyncDir, "events.jsonl"));
    await slot.discoverExtensionArtifact(asyncDir);
    expect(slot.isDrainBusy).toBe(true);

    await rm(join(asyncDir, "events.jsonl"));
    await writeFile(join(asyncDir, "events.jsonl"), `${completedEvent}\n${JSON.stringify({
      ts: ended + 3,
      runId,
      type: "subagent.workflow.completed",
      state: "failed",
    })}\n`);
    await slot.discoverExtensionArtifact(asyncDir);
    expect(slot.isDrainBusy).toBe(true);

    await writeFile(join(asyncDir, "events.jsonl"), `${JSON.stringify({
      ts: ended + 4,
      runId,
      type: "subagent.workflow.completed",
      state: "complete",
    })}\n`);
    await fixture.registry.waitUntilIdle();
    expect(slot.isDrainBusy).toBe(false);
    expect(slot.snapshot().extensionActivities).toMatchObject([{
      toolCallId,
      status: "completed",
      lifecycle: { state: "completed" },
    }]);
  });

  it("reconciles an exact-owned active artifact before the bounded ambient scan", async () => {
    const fixture = await coldFixture("artifact-priority-scan");
    const runId = "late-active-run";
    const toolCallId = "late-active-tool";
    const slot = await fixture.registry.acquire(fixture.manager.getSessionId());
    const projectRoot = join(fixture.cwd, ".pi", "subagents", "async-subagent-runs");
    await mkdir(projectRoot, { recursive: true });
    // The slot attributes the artifact through this session's canonical JSONL.
    const manager = (slot as unknown as { runtime: { session: { sessionManager: SessionManager } } })
      .runtime.session.sessionManager;
    manager.appendMessage({
      role: "toolResult",
      toolCallId,
      toolName: "subagent",
      content: [{ type: "text", text: "launched" }],
      details: { runId, asyncDir: join(projectRoot, runId), state: "running" },
      isError: false,
      timestamp: Date.now(),
    });
    await Promise.all(Array.from({ length: 1_025 }, (_, index) => mkdir(join(projectRoot, `early-${String(index).padStart(4, "0")}`))));
    const activeDir = join(projectRoot, runId);
    await mkdir(activeDir);
    const now = Date.now();
    await writeFile(join(activeDir, "status.json"), JSON.stringify({
      lifecycleArtifactVersion: 3,
      runId,
      state: "running",
      startedAt: now - 1_000,
      lastUpdate: now,
    }));
    vi.spyOn(slot as unknown as { extensionToolOrigin: (name: string) => { source: string } | undefined }, "extensionToolOrigin")
      .mockReturnValue({ source: "pi-subagents" });

    const discovered = vi.spyOn(slot, "discoverExtensionArtifact");
    await discoverExtensionArtifactsUntil(fixture.registry, () => discovered.mock.calls.length > 0);
    expect(discovered.mock.calls[0]?.[0]).toMatch(/async-subagent-runs[\\/]late-active-run$/u);
  });

  it("examines every ambient artifact within a bounded number of passes and reports a stopped pass", async () => {
    const stopped: ExtensionArtifactDiscoveryCounts[] = [];
    // The whole root exists before the registry does, so every pass — including
    // the one `initialize` starts — walks the same artifact set: a pass that
    // exhausts its read budget always reports the same counts.
    const delegated = await delegatedFixtureRoot("ambient-change-gate");
    // One pass reads at most MAX_EXTENSION_DISCOVERY_WORK (1,024) artifacts whose
    // identity changed, so this root always stops a pass short of its last entries.
    const artifactCount = 1_100;
    const startedAt = Date.now();
    const runsRoot = join(delegated.delegatedRoot, "async-subagent-runs");
    const runDirectories = Array.from({ length: artifactCount }, (_unused, index) => ({
      asyncDir: join(runsRoot, `run-${String(index).padStart(4, "0")}`),
      runId: `run-${String(index).padStart(4, "0")}`,
    }));
    const writeStatus = async (run: { asyncDir: string; runId: string }, lastUpdate: number) => {
      await writeFile(join(run.asyncDir, "status.json"), JSON.stringify({
        lifecycleArtifactVersion: 3, runId: run.runId, state: "running", startedAt, lastUpdate,
      }));
    };
    // The whole root has to exist before the registry does. Writing the 1,100 run
    // directories concurrently instead of one await at a time keeps this
    // fixture's own cost inside the test's hang bound: the serial version spent
    // 2,200 event-loop round trips before the case could start, and on a loaded
    // host that alone pushed the test past its 15 s bound (2026-10-06).
    await Promise.all(runDirectories.map(async (run) => {
      await mkdir(run.asyncDir, { recursive: true });
      await writeStatus(run, startedAt);
    }));
    const fixture = await coldFixture("ambient-change-gate", {
      delegatedRoot: delegated.delegatedRoot,
      artifactDiscoveryTruncated: (counts) => stopped.push(counts),
    });
    const slot = await fixture.registry.acquire(fixture.manager.getSessionId());
    const routed = vi.spyOn(slot, "discoverExtensionArtifact");

    await discoverExtensionArtifactsUntil(fixture.registry);
    // The first pass stops at the read budget after 1,025 entries and reads
    // 1,024 of them. The next reaches the end of the root, reading only the 76
    // entries the first could not: no artifact here belongs to a live slot, so
    // no candidate is deferred work and nothing further is reported.
    expect(stopped).toEqual([{ entries: 1_025, statusReads: 1_024, work: 0, dropped: 0 }]);
    expect(routed.mock.calls).toEqual([]);

    // The unchanged root repeats the same stop, and a repeat inside its episode
    // is not recorded again.
    await discoverExtensionArtifactsUntil(fixture.registry);
    expect(stopped).toHaveLength(1);

    // A second live slot halves the pass's per-root routing budget, so a pass
    // that read every entry could not offer all 1,100 candidates. The last run
    // in the walk order is the one this slot can attribute: it is still offered,
    // because the candidates the slot cannot attribute never spend that budget
    // and are never reported as deferred work (G-8d).
    const second = SessionManager.create(fixture.cwd, dirname(fixture.sessionFile));
    second.appendMessage(fauxAssistantMessage("second ambient slot"));
    await settleCatalog(fixture.registry);
    await fixture.registry.acquire(second.getSessionId());
    vi.spyOn(slot as unknown as { extensionToolOrigin: (name: string) => { source: string } | undefined }, "extensionToolOrigin")
      .mockReturnValue({ source: "pi-subagents" });
    const late = runDirectories[artifactCount - 1]!;
    (slot as unknown as { runtime: { session: { sessionManager: SessionManager } } }).runtime.session.sessionManager.appendMessage({
      role: "toolResult", toolCallId: `${late.runId}-tool`, toolName: "subagent",
      content: [{ type: "text", text: "launched" }],
      details: { runId: late.runId, asyncDir: late.asyncDir, state: "running" }, isError: false, timestamp: Date.now(),
    });
    // The run must be offered by the first pass this call runs. Everything the
    // pass needs is already derived: the root was walked above, so every
    // unchanged artifact fact is cached by identity and the walk reaches the end
    // of the root without spending the `MAX_EXTENSION_DISCOVERY_WORK` read
    // budget; the per-root routing budget (`rootBudget`, the remaining work split
    // across the roots and live slots — 512 at most for one root and two slots)
    // is an upper bound, and candidates no live slot can attribute are filtered
    // out before that slice, so the late run is the only candidate left to
    // offer. A second pass means attribution or routing regressed, which is the
    // bound this case's title claims.
    const passes = await discoverExtensionArtifactsUntil(fixture.registry, () => routed.mock.calls.some(([asyncDir]) => asyncDir === late.asyncDir));
    expect(passes, "the pass that offers the newly attributed run").toBe(1);
    expect(new Set(routed.mock.calls.map(([asyncDir]) => asyncDir))).toEqual(new Set([late.asyncDir]));
    expect(stopped).toHaveLength(1);
    await rm(delegated.root, { recursive: true, force: true });
  });

  it("offers a run known only from the session log again after a claim the slot could not take", async () => {
    // A run after a Gateway restart: the saved session log names it, no live
    // ownership binding exists until an artifact is accepted, and its finished
    // status.json never changes again. An offer the slot could not decide is not
    // a delivered artifact, so the next pass must offer the same bytes again.
    const delegated = await delegatedFixtureRoot("ambient-claim-retry");
    const completedAt = Date.now() - 1_000;
    const fixture = await coldFixture("ambient-claim-retry", { delegatedRoot: delegated.delegatedRoot });
    const runId = "claim-retry-run";
    const toolCallId = "claim-retry-tool";
    const asyncDir = join(delegated.delegatedRoot, "async-subagent-runs", runId);
    await mkdir(asyncDir, { recursive: true });
    await writeFile(join(asyncDir, "status.json"), JSON.stringify({
      lifecycleArtifactVersion: 3, runId, state: "complete",
      startedAt: completedAt - 60_000, lastUpdate: completedAt, endedAt: completedAt,
    }));
    const slot = await fixture.registry.acquire(fixture.manager.getSessionId());
    vi.spyOn(slot as unknown as { extensionToolOrigin: (name: string) => { source: string } | undefined }, "extensionToolOrigin")
      .mockReturnValue({ source: "pi-subagents" });
    (slot as unknown as { runtime: { session: { sessionManager: SessionManager } } }).runtime.session.sessionManager.appendMessage({
      role: "toolResult", toolCallId, toolName: "subagent", content: [{ type: "text", text: "launched" }],
      details: { runId, asyncDir, state: "running" }, isError: false, timestamp: Date.now(),
    });
    // The Gateway work registry is full for one offer: the terminal receipt
    // claim is refused, exactly as a busy Gateway refuses it in production.
    const claim = vi.spyOn(slot as unknown as { claimExtensionReceiptOwnership: (activityId: string) => unknown }, "claimExtensionReceiptOwnership");
    claim.mockReturnValueOnce(undefined);
    const offered = vi.spyOn(slot, "discoverExtensionArtifact");
    const projected = () => slot.snapshot().extensionActivities?.find((activity) => activity.toolCallId === toolCallId);

    await discoverExtensionArtifactsUntil(fixture.registry, () => projected() !== undefined);
    expect(projected()).toMatchObject({ status: "completed", runId });
    expect(offered.mock.calls.length).toBeGreaterThanOrEqual(2);
    await rm(delegated.root, { recursive: true, force: true });
  });

  it("does not reopen an unchanged ambient artifact for a live slot", async () => {
    const delegated = await delegatedFixtureRoot("ambient-steady-state");
    const startedAt = Date.now();
    const runsRoot = join(delegated.delegatedRoot, "async-subagent-runs");
    await mkdir(runsRoot, { recursive: true });
    const finishedStatus = (runId: string) => JSON.stringify({
      lifecycleArtifactVersion: 3, runId, state: "complete",
      startedAt: startedAt - 120_000, lastUpdate: startedAt - 120_000, endedAt: startedAt - 120_000,
    });
    const fixture = await coldFixture("ambient-steady-state", { delegatedRoot: delegated.delegatedRoot });
    const slot = await fixture.registry.acquire(fixture.manager.getSessionId());
    vi.spyOn(slot as unknown as { extensionToolOrigin: (name: string) => { source: string } | undefined }, "extensionToolOrigin")
      .mockReturnValue({ source: "pi-subagents" });
    const finishedRunId = "owned-finished-run";
    const liveRunId = "owned-live-run";
    const finishedDir = join(runsRoot, finishedRunId);
    const liveDir = join(runsRoot, liveRunId);
    for (const runId of [finishedRunId, liveRunId]) await mkdir(join(runsRoot, runId), { recursive: true });
    await writeFile(join(finishedDir, "status.json"), finishedStatus(finishedRunId));
    await writeFile(join(liveDir, "status.json"), JSON.stringify({
      lifecycleArtifactVersion: 3, runId: liveRunId, state: "running",
      startedAt: startedAt - 60_000, lastUpdate: startedAt - 1_000,
    }));
    const manager = (slot as unknown as { runtime: { session: { sessionManager: SessionManager } } }).runtime.session.sessionManager;
    for (const [runId, asyncDir] of [[finishedRunId, finishedDir], [liveRunId, liveDir]] as const) {
      manager.appendMessage({
        role: "toolResult", toolCallId: `${runId}-tool`, toolName: "subagent",
        content: [{ type: "text", text: "launched" }],
        details: { runId, asyncDir, state: "running" }, isError: false, timestamp: Date.now(),
      });
    }
    const routed = vi.spyOn(slot, "discoverExtensionArtifact");

    // Only the two runs this slot can attribute are offered.
    await discoverExtensionArtifactsUntil(fixture.registry, () => routed.mock.calls.length >= 2);
    expect(new Set(routed.mock.calls.map(([asyncDir]) => asyncDir))).toEqual(new Set([finishedDir, liveDir]));

    // A pass over the unchanged root offers the finished artifact to nobody: it
    // already reached this slot, and the live one is refreshed by its exact
    // binding.
    routed.mockClear();
    await discoverExtensionArtifactsUntil(fixture.registry);
    expect(new Set(routed.mock.calls.map(([asyncDir]) => asyncDir))).toEqual(new Set([liveDir]));

    // A changed artifact is offered again, even when its exact binding is terminal.
    await writeFile(join(finishedDir, "status.json"), JSON.stringify({
      lifecycleArtifactVersion: 3, runId: finishedRunId, state: "complete",
      startedAt: startedAt - 120_000, lastUpdate: startedAt + 1_000, endedAt: startedAt + 1_000,
    }));
    await discoverExtensionArtifactsUntil(fixture.registry, () => routed.mock.calls.some(([asyncDir]) => asyncDir === finishedDir));
    expect(routed.mock.calls.some(([asyncDir]) => asyncDir === finishedDir)).toBe(true);
    await rm(delegated.root, { recursive: true, force: true });
  });

  it("retries a status.json read that raced an atomic replacement instead of rejecting it", async () => {
    const delegated = await delegatedFixtureRoot("artifact-atomic-replace");
    const fixture = await coldFixture("artifact-atomic-replace", { delegatedRoot: delegated.delegatedRoot });
    const runId = "atomic-replace-run";
    const toolCallId = "atomic-replace-tool";
    const asyncDir = join(delegated.delegatedRoot, "async-subagent-runs", runId);
    await mkdir(asyncDir, { recursive: true });
    const slot = await fixture.registry.acquire(fixture.manager.getSessionId());
    // The registry's own 750 ms pass can offer this same artifact, which would put
    // a second retry invocation inside the injected window; this case is about the
    // slot's retry path, so it owns the cadence and makes one read the only one.
    const registryInternal = fixture.registry as unknown as { artifactDiscoveryTimer?: NodeJS.Timeout };
    if (registryInternal.artifactDiscoveryTimer) clearInterval(registryInternal.artifactDiscoveryTimer);
    registryInternal.artifactDiscoveryTimer = undefined;
    vi.spyOn(slot as unknown as { extensionToolOrigin: (name: string) => { source: string } | undefined }, "extensionToolOrigin")
      .mockReturnValue({ source: "pi-subagents" });
    (slot as unknown as { runtime: { session: { sessionManager: SessionManager } } }).runtime.session.sessionManager.appendMessage({
      role: "toolResult", toolCallId, toolName: "subagent", content: [{ type: "text", text: "launched" }],
      details: { runId, asyncDir, state: "running" }, isError: false, timestamp: Date.now(),
    });
    const payload = JSON.stringify({
      lifecycleArtifactVersion: 3, runId, state: "running",
      startedAt: Date.now() - 1_000, lastUpdate: Date.now(),
    });
    const statusPath = join(asyncDir, "status.json");
    await writeFile(statusPath, payload);
    const warnings: Array<{ reason: string }> = [];
    (slot as unknown as { dependencies: { extensionArtifactWarning?: (warning: { reason: string }) => void } })
      .dependencies.extensionArtifactWarning = (warning) => warnings.push(warning);
    await slot.discoverExtensionArtifact(asyncDir);
    const projected = () => slot.snapshot().extensionActivities?.find((activity) => activity.toolCallId === toolCallId);
    expect(projected()).toMatchObject({ status: "running" });

    // A producer replaces an active run's status.json by an atomic rename, so a
    // read can open one inode and stat another. `openOwnedExtensionArtifact`
    // verifies that the inode it opened is the one it stats, and the discovery
    // lane used to report the first losing read as a rejected artifact.
    //
    // The loss is injected, not raced for: the file-scoped `open` wrapper above
    // performs exactly one real write+rename between this path's own open and its
    // verifying stat, so the read it is inside loses by construction. Host
    // scheduling, the fs threadpool and any load on the machine can therefore no
    // longer decide whether the case observes its event — the old sample guard
    // (`passes > 100`) was the speed budget that let them (#430). Only the
    // test-owned producer is deterministic here; the spies below only observe.
    const slotInternals = slot as unknown as {
      readExtensionStatusArtifact: (asyncDir: string) => Promise<Record<string, unknown> | undefined>;
      readExtensionStatusArtifactWithReplacementRetry: (asyncDir: string) => Promise<Record<string, unknown> | undefined>;
    };
    const readOnce = slotInternals.readExtensionStatusArtifact.bind(slot);
    const readWithRetry = slotInternals.readExtensionStatusArtifactWithReplacementRetry.bind(slot);
    // The watcher lane reads the same file through the same inner method
    // (`refreshExtensionActivityFromArtifact`), so a read count taken across the
    // retry path's wall-clock window would count its reads too. Scoping the count
    // to the retry invocation's own async context keeps the observation exact:
    // more than one read inside it is this path retrying a read that lost the
    // race with the producer's rename.
    const retryInvocation = new AsyncLocalStorage<{ reads: number }>();
    statusJsonReplace.insideRetryInvocation = () => retryInvocation.getStore() !== undefined;
    let retriedLosingReads = 0;
    vi.spyOn(slotInternals, "readExtensionStatusArtifact").mockImplementation(async (directory: string) => {
      const invocation = retryInvocation.getStore();
      if (invocation) invocation.reads += 1;
      return readOnce(directory);
    });
    vi.spyOn(slotInternals, "readExtensionStatusArtifactWithReplacementRetry")
      .mockImplementation((directory: string) => retryInvocation.run({ reads: 0 }, async () => {
        const invocation = retryInvocation.getStore()!;
        try {
          return await readWithRetry(directory);
        } finally {
          if (invocation.reads > 1) retriedLosingReads += 1;
        }
      }));
    const canonicalAsyncDir = await realpath(asyncDir);
    statusJsonReplace.armed = true;
    statusJsonReplace.losses = 0;
    statusJsonReplace.replacements = 0;
    statusJsonReplace.payload = payload;
    statusJsonReplace.statusPath = join(canonicalAsyncDir, "status.json");
    statusJsonReplace.tempPath = join(canonicalAsyncDir, "status.tmp");
    try {
      // One read; the product's retry path runs because the injected replace made
      // that read lose, and its second read succeeds.
      await slot.discoverExtensionArtifact(asyncDir);
    } finally {
      statusJsonReplace.armed = false;
      statusJsonReplace.insideRetryInvocation = () => false;
    }
    expect(statusJsonReplace.replacements, "the injected replace").toBe(1);
    expect(retriedLosingReads, "the read that lost the race and was retried").toBe(1);
    expect(warnings.filter((warning) => warning.reason === "artifact-replacement-in-progress")).toEqual([]);
    expect(projected()).toMatchObject({ status: "running", runId });
    await rm(delegated.root, { recursive: true, force: true });
  });

  it("reconciles the launch owner after a supervisor reply references the same run", async () => {
    const fixture = await coldFixture("supervisor-reply-ownership");
    const slot = await fixture.registry.acquire(fixture.manager.getSessionId());
    const manager = (slot as unknown as { runtime: { session: { sessionManager: SessionManager } } }).runtime.session.sessionManager;
    const runId = "supervisor-target-run";
    const toolCallId = "subagent-launch-call";
    const asyncDir = join(fixture.cwd, ".pi", "subagents", "async-subagent-runs", runId);
    await mkdir(asyncDir, { recursive: true });
    vi.spyOn(slot as unknown as { extensionToolOrigin: (name: string) => { source: string } | undefined }, "extensionToolOrigin")
      .mockReturnValue({ source: "pi-subagents" });
    manager.appendMessage({
      role: "toolResult", toolCallId, toolName: "subagent",
      content: [{ type: "text", text: "launched" }],
      details: { runId, asyncId: runId, asyncDir, mode: "single", results: [] },
      isError: false, timestamp: Date.now(),
    });
    const startedAt = Date.now() - 1_000;
    await writeFile(join(asyncDir, "status.json"), JSON.stringify({
      lifecycleArtifactVersion: 3, runId, state: "running", startedAt, lastUpdate: Date.now(),
    }));
    const internal = slot as unknown as {
      extensionActivities: Map<string, ExtensionRunActivity>;
      extensionRunOwnership: Map<string, { toolCallId: string; asyncDir?: string; terminal: boolean }>;
      updateExtensionActivity: (...args: unknown[]) => unknown;
    };
    const started = new Date(startedAt).toISOString();
    internal.extensionActivities.set(toolCallId, {
      id: toolCallId, activityId: "supervisor-launch-activity", runId, toolCallId,
      source: { source: "pi-subagents" }, title: "worker", status: "running",
      startedAt: started, updatedAt: started, children: [],
      lifecycle: { version: 1, state: "running", attention: "none", sequence: 1, observedAt: started },
    });
    internal.extensionRunOwnership.set(runId, { toolCallId, asyncDir, terminal: false });
    expect(slot.isDrainBusy).toBe(true);

    // This is the native supervisor's actual receipt shape. Its runId is a
    // reference, not another launch, and must not poison canonical ownership.
    const reply = { content: [{ type: "text" as const, text: "Replied" }], details: { replyTo: "request-1", runId, agent: "worker" } };
    manager.appendMessage({
      role: "toolResult", toolCallId: "supervisor-reply-call", toolName: "subagent_supervisor",
      ...reply, isError: false, timestamp: Date.now(),
    });
    const now = new Date().toISOString();
    expect(internal.updateExtensionActivity("supervisor-reply-call", "subagent_supervisor",
      { source: "pi-subagents" }, "completed", now, now, reply, now)).toBeUndefined();

    await writeFile(join(asyncDir, "status.json"), JSON.stringify({
      lifecycleArtifactVersion: 3, runId, state: "complete", startedAt, lastUpdate: Date.now(), endedAt: Date.now(),
    }));
    await slot.discoverExtensionArtifact(asyncDir);
    expect(slot.snapshot().extensionActivities).toMatchObject([{ toolCallId, lifecycle: { state: "completed" } }]);
    expect(slot.snapshot().extensionActivities).toHaveLength(1);
    await fixture.registry.waitUntilIdle();
    expect(slot.isDrainBusy).toBe(false);
  });

  it("fails closed on a stale running artifact after canonical completion", async () => {
    const fixture = await coldFixture("stale-subagent-artifact");
    fixture.manager.appendMessage({
      role: "toolResult",
      toolCallId: "stale-tool-call",
      toolName: "subagent",
      content: [{ type: "text", text: "acknowledged" }],
      details: { runId: "stale-run", state: "completed" },
      isError: false,
      timestamp: Date.now(),
    });
    fixture.manager.appendMessage({
      role: "toolResult",
      toolCallId: "unbound-historical-tool-call",
      toolName: "subagent",
      content: [{ type: "text", text: "launched" }],
      details: { runId: "unbound-historical-run", state: "running" },
      isError: false,
      timestamp: Date.now(),
    });
    const slot = await fixture.registry.acquire(fixture.manager.getSessionId());
    const asyncDir = join(fixture.cwd, ".pi", "subagents", "async-subagent-runs", "stale-run");
    await mkdir(asyncDir, { recursive: true });
    await writeFile(join(asyncDir, "status.json"), JSON.stringify({
      lifecycleArtifactVersion: 3,
      runId: "stale-run",
      cwd: fixture.cwd,
      sessionId: slot.id,
      state: "running",
      startedAt: Date.now() - 1_000,
      lastUpdate: Date.now(),
    }));
    const internal = slot as unknown as { refreshSubagentActivityFromArtifact: (path: string) => Promise<void> };
    await internal.refreshSubagentActivityFromArtifact(asyncDir);
    expect(slot.snapshot().extensionActivities ?? []).toEqual([]);

    const projectRoot = join(fixture.cwd, ".pi", "subagents", "async-subagent-runs");
    const unboundHistoricalDir = join(projectRoot, "unbound-historical-run");
    await mkdir(unboundHistoricalDir, { recursive: true });
    await writeFile(join(unboundHistoricalDir, "status.json"), JSON.stringify({
      runId: "unbound-historical-run",
      state: "complete",
      startedAt: Date.now() - 1_000,
      lastUpdate: Date.now(),
      endedAt: Date.now(),
    }));
    await internal.refreshSubagentActivityFromArtifact(unboundHistoricalDir);
    expect(slot.snapshot().extensionActivities ?? []).toEqual([]);

    const pathPolicy = slot as unknown as { extensionArtifactPathAllowed: (path: string) => boolean };
    expect(pathPolicy.extensionArtifactPathAllowed(projectRoot)).toBe(false);
    expect(pathPolicy.extensionArtifactPathAllowed(`${projectRoot}/.`)).toBe(false);
    expect(pathPolicy.extensionArtifactPathAllowed(`${projectRoot}/../escape`)).toBe(false);

    // A non-extension tool result carrying an arbitrary runId is not ownership
    // evidence, even when the artifact claims this exact session and cwd.
    fixture.manager.appendMessage({
      role: "toolResult",
      toolCallId: "ordinary-tool-call",
      toolName: "read",
      content: [{ type: "text", text: "ordinary" }],
      details: { runId: "ordinary-run", state: "completed" },
      isError: false,
      timestamp: Date.now(),
    });
    const ordinaryDir = join(projectRoot, "ordinary-run");
    await mkdir(ordinaryDir, { recursive: true });
    await writeFile(join(ordinaryDir, "status.json"), JSON.stringify({
      lifecycleArtifactVersion: 3,
      runId: "ordinary-run",
      cwd: fixture.cwd,
      sessionId: slot.id,
      state: "running",
      startedAt: Date.now() - 1_000,
      lastUpdate: Date.now(),
    }));
    await internal.refreshSubagentActivityFromArtifact(ordinaryDir);
    expect(slot.snapshot().extensionActivities ?? []).toEqual([]);
  });

  it("binds artifact refresh to the canonical run directory and keeps admission time authoritative", async () => {
    const fixture = await coldFixture("artifact-binding-integrity");
    for (const duplicateToolCallId of ["canonical-first", "canonical-second"]) {
      fixture.manager.appendMessage({
        role: "toolResult",
        toolCallId: duplicateToolCallId,
        toolName: "subagent",
        content: [{ type: "text", text: "duplicate" }],
        details: { runId: "duplicate-canonical-run", state: "running" },
        isError: false,
        timestamp: Date.now(),
      });
    }
    const slot = await fixture.registry.acquire(fixture.manager.getSessionId());
    const runId = "bound-run";
    const toolCallId = "real-tool-call";
    const asyncDir = join(fixture.cwd, ".pi", "subagents", "async-subagent-runs", runId);
    await mkdir(asyncDir, { recursive: true });
    const activityStartedAt = new Date(Date.now() - 5_000).toISOString();
    const artifactCompletedAt = new Date(Date.now() - 1_000).toISOString();
    const activity: ExtensionRunActivity = {
      id: toolCallId,
      runId,
      toolCallId,
      source: { source: "pi-subagents" },
      title: "Pi Subagents",
      status: "running",
      startedAt: activityStartedAt,
      updatedAt: activityStartedAt,
      children: [],
    };
    const internal = slot as unknown as {
      extensionActivities: Map<string, ExtensionRunActivity>;
      extensionRunOwnership: Map<string, { toolCallId: string; asyncDir?: string; terminal: boolean }>;
      refreshSubagentActivityFromArtifact: (path: string) => Promise<void>;
      refreshExtensionActivityFromArtifact: (toolCallId: string, path: string) => Promise<void>;
      bindExtensionRunOwnership: (runId: string, binding: { toolCallId: string; asyncDir?: string; terminal: boolean }) => boolean;
      canonicalExtensionRunFacts: () => Map<string, { toolCallId?: string; terminal: boolean; ambiguous: boolean }>;
    };
    internal.extensionActivities.set(toolCallId, activity);
    internal.extensionRunOwnership.set(runId, { toolCallId, asyncDir, terminal: false });
    const admissionWindowStartedAt = Date.now();
    await writeFile(join(asyncDir, "status.json"), JSON.stringify({
      lifecycleArtifactVersion: 3,
      runId,
      state: "completed",
      startedAt: Date.parse(activity.startedAt),
      lastUpdate: Date.parse(artifactCompletedAt),
      endedAt: Date.parse(artifactCompletedAt),
    }));
    await internal.refreshSubagentActivityFromArtifact(asyncDir);
    const admitted = slot.snapshot().extensionActivities?.find((candidate) => candidate.toolCallId === toolCallId);
    expect(admitted).toMatchObject({
      toolCallId,
      status: "completed",
      completedAt: artifactCompletedAt,
    });
    // Terminal time is the Gateway's admission instant, never the producer's
    // earlier `endedAt`. The registry's artifact discovery pass also re-reads
    // this owned directory every 750 ms and may admit first, so the oracle is
    // the admission window rather than this call's own observation (#406).
    const terminalAt = Date.parse(admitted?.lifecycle?.terminalAt ?? "");
    expect(terminalAt).toBeGreaterThanOrEqual(admissionWindowStartedAt);
    expect(terminalAt).toBeLessThanOrEqual(Date.parse(admitted?.lifecycle?.observedAt ?? ""));
    // A later observation of the same terminal artifact keeps that instant.
    await new Promise((resolve) => setTimeout(resolve, 2));
    await internal.refreshSubagentActivityFromArtifact(asyncDir);
    const reobserved = slot.snapshot().extensionActivities?.find((candidate) => candidate.toolCallId === toolCallId);
    expect(reobserved?.lifecycle?.terminalAt).toBe(admitted?.lifecycle?.terminalAt);

    const foreignDir = join(fixture.cwd, ".pi", "subagents", "async-subagent-runs", "foreign-run");
    await mkdir(foreignDir, { recursive: true });
    await writeFile(join(foreignDir, "status.json"), JSON.stringify({
      lifecycleArtifactVersion: 3,
      runId,
      state: "running",
      startedAt: Date.parse(activity.startedAt),
      lastUpdate: Date.parse("2026-01-01T00:00:05.000Z"),
    }));
    await internal.refreshSubagentActivityFromArtifact(foreignDir);
    await internal.refreshExtensionActivityFromArtifact(toolCallId, foreignDir);
    expect(slot.snapshot().extensionActivities).toMatchObject([{
      toolCallId,
      status: "completed",
      completedAt: artifactCompletedAt,
    }]);
    const afterForeign = slot.snapshot().extensionActivities?.find((candidate) => candidate.toolCallId === toolCallId);
    expect(afterForeign?.lifecycle?.terminalAt).toBe(admitted?.lifecycle?.terminalAt);

    expect(internal.bindExtensionRunOwnership(runId, {
      toolCallId: "second-real-tool-call",
      asyncDir: foreignDir,
      terminal: false,
    })).toBe(false);
    expect(internal.extensionRunOwnership.get(runId)?.toolCallId).toBe(toolCallId);

    vi.spyOn(slot as unknown as { extensionToolOrigin: (name: string) => { source: string } | undefined }, "extensionToolOrigin")
      .mockReturnValue({ source: "pi-subagents" });
    const duplicateFact = internal.canonicalExtensionRunFacts().get("duplicate-canonical-run");
    expect(duplicateFact?.toolCallId).toBeUndefined();
    expect(duplicateFact?.ambiguous).toBe(true);
  });

  it("applies the per-model prompt image profile once before canonical history", async () => {
    const root = await mkdtemp(join(tmpdir(), "tron-prompt-image-bound-"));
    const agentDir = join(root, "agent");
    const cwd = join(root, "workspace");
    await Promise.all([mkdir(agentDir), mkdir(cwd)]);
    const trust = new TrustService(agentDir);
    await trust.set(cwd, true);
    const faux = fauxProvider({ provider: "tron-prompt-image-bound", tokensPerSecond: 10_000 });
    faux.setResponses([fauxAssistantMessage("complete")]);
    const runtime = await ModelRuntime.create({ modelsPath: null, refreshOnCreate: false });
    runtime.registerNativeProvider(faux.provider);
    const registry = new RuntimeRegistry({
      agentDir, tronHome: join(root, "tron"), idleRuntimeMs: 60_000, trust,
      modelRuntimeFactory: async () => runtime,
      broadcast: () => {}, sessionSummaryChanged: () => {}, sessionListChanged: () => {},
    });
    registries.push(registry);
    await initializeRegistry(registry);
    const slot = await registry.create(cwd);
    const model = faux.getModel();
    model.inputLimits = { images: { resize: { maxWidth: 1_000, maxHeight: 1_000 } } };
    await slot.setModel(model.provider, model.id);

    // Pi applies the active model's profile once before the attachment enters
    // canonical history. Gateway must not pre-resize it with a second profile.
    const screenshot: ImageContent = { type: "image", mimeType: "image/png", data: syntheticPng(1320, 2868).toString("base64") };
    const originalData = screenshot.data;
    await slot.prompt("Look at this screenshot", [screenshot]);
    expect(screenshot.data).toBe(originalData);
    await waitFor(() => !slot.isBusy, "the slot to go idle");

    const entries = (await readFile(slot.sessionFile!, "utf8"))
      .trimEnd().split("\n").map(line => JSON.parse(line) as any);
    const recorded = entries.find(entry => entry.type === "message" && entry.message?.role === "user")
      ?.message.content.find((part: any) => part.type === "image") as ImageContent | undefined;
    expect(recorded).toBeDefined();
    expect(recorded!.data).not.toBe(screenshot.data);
    const dimensions = pngDimensions(recorded!);
    expect(Math.max(dimensions.width, dimensions.height)).toBe(1_000);
  });

  it("admits multiline plain prompts without duplicating their body into invocation receipts", async () => {
    const root = await mkdtemp(join(tmpdir(), "tron-multiline-prompt-receipt-"));
    const agentDir = join(root, "agent");
    const cwd = join(root, "workspace");
    await Promise.all([mkdir(agentDir), mkdir(cwd)]);
    const trust = new TrustService(agentDir);
    await trust.set(cwd, true);
    const faux = fauxProvider({ provider: "tron-multiline-prompt", tokensPerSecond: 10_000 });
    faux.setResponses([fauxAssistantMessage("complete")]);
    const runtime = await ModelRuntime.create({ modelsPath: null, refreshOnCreate: false });
    runtime.registerNativeProvider(faux.provider);
    const registry = new RuntimeRegistry({
      agentDir, tronHome: join(root, "tron"), idleRuntimeMs: 60_000, trust,
      modelRuntimeFactory: async () => runtime,
      broadcast: () => {}, sessionSummaryChanged: () => {}, sessionListChanged: () => {},
    });
    registries.push(registry);
    await initializeRegistry(registry);
    const slot = await registry.create(cwd);
    const model = faux.getModel();
    await slot.setModel(model.provider, model.id);

    const prompt = "first line\nsecond line";
    await expect(slot.prompt(prompt)).resolves.toEqual({ operationId: expect.any(String) });
    await waitFor(() => !slot.isBusy, "the slot to go idle");

    const entries = (await readFile(slot.sessionFile!, "utf8"))
      .trimEnd().split("\n").map(line => JSON.parse(line) as any);
    const startReceipt = entries.find(entry => entry.type === "custom"
      && entry.customType === INVOCATION_RECEIPT_TYPE
      && entry.data?.receiptKind === "start");
    expect(startReceipt?.data).toMatchObject({ source: "plain", lifecycle: "staged" });
    expect(startReceipt?.data).not.toHaveProperty("arguments");
    expect(entries.some(entry => entry.type === "message" && entry.message?.role === "user"
      && entry.message.content?.some((part: any) => part.type === "text" && part.text === prompt))).toBe(true);
  });

  it("keeps the Gateway alive when extension timers emit oversized or JSON-dense widgets", async () => {
    const root = await mkdtemp(join(tmpdir(), "tron-rpc-oversized-widget-"));
    const agentDir = join(root, "agent");
    const cwd = join(root, "workspace");
    const extensionDir = join(cwd, ".pi", "extensions");
    await mkdir(extensionDir, { recursive: true });
    await writeFile(join(extensionDir, "oversized-widget.ts"), `export default function (pi) {
      pi.on("session_start", (_event, ctx) => {
        setImmediate(() => {
          ctx.ui.setWidget("async-status", ["PI_SUBAGENT_ASYNC_JSON:" + "x".repeat(1_024)]);
          ctx.ui.setWidget("async-status", ["PI_SUBAGENT_ASYNC_JSON:" + '\"x\",'.repeat(115)]);
          ctx.ui.setStatus("oversized-widget-callback", "completed");
        });
      });
    }\n`);
    const trust = new TrustService(agentDir);
    await trust.set(cwd, true);
    const registry = new RuntimeRegistry({
      agentDir, tronHome: join(root, "tron"), idleRuntimeMs: 60_000, trust,
      broadcast: () => {}, sessionSummaryChanged: () => {}, sessionListChanged: () => {},
    });
    registries.push(registry);
    await initializeRegistry(registry);
    const slot = await registry.create(cwd);
    await waitFor(() => slot.snapshot().extensionPresentation.semanticState.statuses["oversized-widget-callback"] === "completed", "the oversized widget callback to complete");
    expect(slot.snapshot().extensionPresentation.semanticState.widgets).toEqual([]);
  });

  it("projects retained component widgets through the RPC-bound host without enabling TUI mode", async () => {
    const root = await mkdtemp(join(tmpdir(), "tron-rpc-factory-dormant-"));
    const agentDir = join(root, "agent");
    const cwd = join(root, "workspace");
    const extensionDir = join(cwd, ".pi", "extensions");
    await mkdir(extensionDir, { recursive: true });
    await writeFile(join(extensionDir, "rpc-factory.ts"), `export default function (pi) {
      let invoked = false;
      pi.on("session_start", async (_event, ctx) => {
        ctx.ui.setStatus("context-has-ui", ctx.hasUI ? "true" : "false");
        ctx.ui.setStatus("context-mode", ctx.mode);
        ctx.ui.setWidget("factory", () => ({
          render: () => ["must mount"], invalidate: () => {}
        }));
        try {
          await ctx.ui.custom(() => {
            invoked = true;
            return { render: () => ["must not invoke"], invalidate: () => {} };
          });
        } catch {
          ctx.ui.setStatus("custom-deferred", invoked ? "invoked" : "not-invoked");
        }
      });
    }\n`);
    const trust = new TrustService(agentDir);
    await trust.set(cwd, true);
    const registry = new RuntimeRegistry({
      agentDir, tronHome: join(root, "tron"), idleRuntimeMs: 60_000, trust,
      broadcast: () => {}, sessionSummaryChanged: () => {}, sessionListChanged: () => {},
    });
    registries.push(registry);
    await initializeRegistry(registry);
    const slot = await registry.create(cwd);
    const internal = slot as unknown as { extensionHost: { isTuiStarted: boolean; mountedComponentCount: number } };
    await waitFor(() => internal.extensionHost.mountedComponentCount === 1, "the mounted extension component");
    expect(internal.extensionHost.isTuiStarted).toBe(true);
    const snapshot = slot.snapshot();
    expect(snapshot.extensionPresentation.semanticState.statuses).toMatchObject({
      "context-has-ui": "true", "context-mode": "rpc", "custom-deferred": "not-invoked",
    });
    expect(snapshot.extensionPresentation.semanticState.widgets).toEqual([]);
    expect(snapshot.extensionPresentation.surfaces).toEqual(expect.arrayContaining([
      expect.objectContaining({ id: "widget:ZmFjdG9yeQ", kind: "widget", placement: "aboveEditor", inputMode: "none" }),
    ]));
  });

  it("keeps ask-style semantic selection on the RPC interaction path", async () => {
    const root = await mkdtemp(join(tmpdir(), "tron-rpc-semantic-ask-"));
    const agentDir = join(root, "agent");
    const cwd = join(root, "workspace");
    const extensionDir = join(cwd, ".pi", "extensions");
    await mkdir(extensionDir, { recursive: true });
    await writeFile(join(extensionDir, "semantic-ask.ts"), `export default function (pi) {
      pi.registerCommand("semantic-ask", { handler: async (_args, ctx) => {
        const answer = await ctx.ui.select("Choose a path", ["Keep", "Change"]);
        ctx.ui.setStatus("answer", answer ?? "Cancelled");
      }});
    }\n`);
    const trust = new TrustService(agentDir);
    await trust.set(cwd, true);
    const summaries: SessionSummaryUpdate[] = [];
    const userInputRequired = vi.fn(async () => {});
    const registry = new RuntimeRegistry({
      agentDir, tronHome: join(root, "tron"), idleRuntimeMs: 60_000, trust,
      broadcast: () => {}, sessionSummaryChanged: (summary) => summaries.push(summary), sessionListChanged: () => {},
      machineId: "machine-input-test",
      notifications: { userInputRequired, markSessionInboxRead: vi.fn(async () => {}) } as unknown as NotificationService,
    });
    registries.push(registry);
    await initializeRegistry(registry);
    const slot = await registry.create(cwd);
    const command = slot.prompt("/semantic-ask");
    await waitFor(() => slot.snapshot().extensionPresentation.pendingInteractions.length === 1, "the pending interaction");
    const pending = slot.snapshot().extensionPresentation.pendingInteractions[0]!;
    expect(pending.method).toBe("select");
    expect(pending.options).toEqual(["Keep", "Change"]);
    expect(userInputRequired).toHaveBeenCalledWith({
      sessionId: slot.id,
      interactionId: pending.id,
      machineId: "machine-input-test",
      observed: false,
    });
    expect(summaries.at(-1)?.waitingForUser).toBe(true);
    expect((await registry.list()).find((session) => session.id === slot.id)?.waitingForUser).toBe(true);
    const internal = slot as unknown as { respondToInteraction: (id: string, epoch: string, revision: number, value: unknown, cancelled: boolean) => void };
    internal.respondToInteraction(pending.id, pending.hostEpoch, pending.presentationRevision, "Keep", false);
    expect(summaries.at(-1)?.waitingForUser).toBe(false);
    expect((await registry.list()).find((session) => session.id === slot.id)?.waitingForUser).toBe(false);
    await command;
    expect(slot.snapshot().extensionPresentation.semanticState.statuses.answer).toBe("Keep");

    registry.subscribe("visible-phone", slot.id);
    registry.setPresentationVisibility({
      clientId: "visible-phone",
      sessionId: slot.id,
      subscriptionToken: "visible-subscription",
      revision: 1,
      visible: true,
    });
    const visibleCommand = slot.prompt("/semantic-ask");
    await waitFor(() => slot.snapshot().extensionPresentation.pendingInteractions.length === 1, "the pending interaction");
    const visiblePending = slot.snapshot().extensionPresentation.pendingInteractions[0]!;
    expect(userInputRequired).toHaveBeenLastCalledWith({
      sessionId: slot.id,
      interactionId: visiblePending.id,
      machineId: "machine-input-test",
      observed: true,
    });
    internal.respondToInteraction(
      visiblePending.id,
      visiblePending.hostEpoch,
      visiblePending.presentationRevision,
      "Change",
      false,
    );
    await visibleCommand;
  });

  it("rotates and retires semantic epochs on direct, command, and trust reload paths", async () => {
    const root = await mkdtemp(join(tmpdir(), "tron-semantic-epoch-reload-"));
    const agentDir = join(root, "agent");
    const cwd = join(root, "workspace");
    const extensionDir = join(cwd, ".pi", "extensions");
    await Promise.all([mkdir(agentDir), mkdir(extensionDir, { recursive: true })]);
    await writeFile(join(extensionDir, "reload.ts"), `export default function (pi) {
      pi.on("session_start", (_event, ctx) => ctx.ui.setStatus("epoch", "started"));
      pi.registerCommand("reload-host", { handler: async (_args, ctx) => ctx.reload() });
    }\n`);
    const trust = new TrustService(agentDir);
    await trust.set(cwd, true);
    const registry = new RuntimeRegistry({
      agentDir, tronHome: join(root, "tron"), idleRuntimeMs: 60_000, trust,
      broadcast: () => {}, sessionSummaryChanged: () => {}, sessionListChanged: () => {},
    });
    registries.push(registry);
    await initializeRegistry(registry);
    const slot = await registry.create(cwd);
    const internal = slot as unknown as { ui: { context(): { confirm(title: string, message: string): Promise<boolean>; setStatus(key: string, text: string): void } } };
    const oldContext = internal.ui.context();
    const firstEpoch = slot.snapshot().extensionPresentation.hostEpoch;

    await slot.reload();
    const secondEpoch = slot.snapshot().extensionPresentation.hostEpoch;
    expect(secondEpoch).not.toBe(firstEpoch);
    expect(() => oldContext.setStatus("late", "old callback")).not.toThrow();
    expect(slot.snapshot().extensionPresentation.semanticState.statuses.late).toBeUndefined();

    const pending = internal.ui.context().confirm("Pending", "Retire me");
    // Attach rejection observation before the command retires the epoch.
    const retiredPending = expect(pending).rejects.toMatchObject({ code: "cancelled" });
    await slot.prompt("/reload-host");
    await retiredPending;
    const thirdEpoch = slot.snapshot().extensionPresentation.hostEpoch;
    expect(thirdEpoch).not.toBe(secondEpoch);
    await registry.reloadProject(cwd, true);
    expect(slot.snapshot().extensionPresentation.hostEpoch).not.toBe(thirdEpoch);
  });

  it("orders context-edit settlement callbacks before terminal ownership and feeds the next provider request", async () => {
    const root = await mkdtemp(join(tmpdir(), "tron-context-edit-settlement-"));
    const agentDir = join(root, "agent");
    const cwd = join(root, "workspace");
    await Promise.all([mkdir(agentDir), mkdir(join(cwd, ".pi", "extensions"), { recursive: true })]);
    await writeFile(join(cwd, ".pi", "extensions", "context-edit-boundary.ts"), `
export default function (pi) {
  pi.on("turn_end", (_event, ctx) => {
    const target = ctx.sessionManager.getBranch().find(entry => entry.type === "message" && entry.message.role === "user");
    return { entries: [
      { type: "context_edit", targetId: target.id, replacement: { content: "replacement from turn_end" } },
      { type: "custom", customType: "context-edit-order", data: { stage: "turn_end" } },
    ] };
  });
  pi.on("agent_before_settle", () => ({ entries: [
    { type: "custom", customType: "context-edit-order", data: { stage: "agent_before_settle" } },
  ] }));
  pi.on("agent_settled", () => {
    pi.appendEntry("context-edit-order", { stage: "agent_settled" });
  });
}
`);
    const faux = fauxProvider({ provider: "tron-context-edit-settlement", tokensPerSecond: 10_000 });
    const contexts: TranscriptContext[] = [];
    faux.setResponses([
      (context) => { contexts.push(context); return fauxAssistantMessage("first completed"); },
      (context) => { contexts.push(context); return fauxAssistantMessage("second completed"); },
    ]);
    const modelRuntimeFactory = async () => {
      const runtime = await ModelRuntime.create({ modelsPath: null, refreshOnCreate: false });
      runtime.registerNativeProvider(faux.provider);
      return runtime;
    };
    const trust = new TrustService(agentDir);
    await trust.set(cwd, true);
    const registry = new RuntimeRegistry({
      agentDir, tronHome: join(root, "tron"), idleRuntimeMs: 60_000, modelRuntimeFactory, trust,
      broadcast: () => {}, sessionSummaryChanged: () => {}, sessionListChanged: () => {},
    });
    registries.push(registry);
    await initializeRegistry(registry);
    const slot = await registry.create(cwd);
    await slot.setModel(faux.getModel().provider, faux.getModel().id);
    await slot.prompt("original request");
    await waitFor(() => !slot.isBusy, "the slot to go idle");
    const branch = (slot as unknown as { sessionManager: SessionManager }).sessionManager.getBranch();
    const order = branch.filter(entry => entry.type === "custom" && entry.customType === "context-edit-order")
      .map(entry => {
        if (entry.type !== "custom") throw new Error("Unexpected non-custom order entry");
        return (entry.data as { stage: string }).stage;
      });
    expect(order).toEqual(["turn_end", "agent_before_settle", "agent_settled"]);
    expect(branch.some(entry => entry.type === "context_edit" && entry.replacement.content === "replacement from turn_end")).toBe(true);
    await waitFor(() => registry.attentionProjection(slot.id).completionRevision === 1, "the first completion revision");
    expect(registry.attentionProjection(slot.id)).toMatchObject({ completionRevision: 1 });

    await slot.prompt("follow-up");
    await waitFor(() => !slot.isBusy, "the slot to go idle");
    expect(contexts).toHaveLength(2);
    expect(contexts[1]!.messages.filter(message => message.role === "user").map(message =>
      message.role === "user" ? contentText(message.content) : "")).toEqual([
      "replacement from turn_end", "follow-up",
    ]);
    await waitFor(() => registry.attentionProjection(slot.id).completionRevision === 2, "the second completion revision");
    expect(registry.attentionProjection(slot.id)).toMatchObject({ completionRevision: 2 });
  });

  it("serializes chained extension continuation ownership through a transient attention failure", async () => {
    const root = await mkdtemp(join(tmpdir(), "tron-settlement-overlap-"));
    const agentDir = join(root, "agent");
    const cwd = join(root, "workspace");
    await Promise.all([
      mkdir(agentDir),
      mkdir(join(cwd, ".pi", "extensions"), { recursive: true }),
    ]);
    await writeFile(join(cwd, ".pi", "extensions", "continuation.ts"), `
let remaining = 3;
export default function (pi) {
  pi.on("agent_settled", () => {
    if (remaining === 0) return;
    const sequence = 4 - remaining;
    remaining -= 1;
    pi.sendMessage({ customType: "test-continuation", content: \`continue-\${sequence}\`, display: false }, { triggerTurn: true });
  });
}
`);

    const faux = fauxProvider({ provider: "tron-settlement-overlap", tokensPerSecond: 10_000 });
    const createModels = async () => {
      const runtime = await ModelRuntime.create({ modelsPath: null, refreshOnCreate: false });
      runtime.registerNativeProvider(faux.provider);
      return runtime;
    };
    faux.setResponses([
      fauxAssistantMessage("first complete"),
      async () => {
        await new Promise((resolve) => setTimeout(resolve, 250));
        return fauxAssistantMessage("continuation one complete");
      },
      fauxAssistantMessage("continuation two complete"),
      async () => {
        await new Promise((resolve) => setTimeout(resolve, 250));
        return fauxAssistantMessage("continuation three complete");
      },
    ]);
    const snapshots: Array<{ phase: string; operation?: unknown }> = [];
    const trust = new TrustService(agentDir);
    await trust.set(cwd, true);
    const registry = new RuntimeRegistry({
      agentDir,
      tronHome: join(root, "tron"),
      idleRuntimeMs: 60_000,
      modelRuntimeFactory: createModels,
      trust,
      broadcast: (_sessionId, topic, payload) => {
        if (topic === "session.snapshot") snapshots.push(payload as { phase: string; operation?: unknown });
      },
      sessionSummaryChanged: () => {},
      sessionListChanged: () => {},
    });
    registries.push(registry);
    await initializeRegistry(registry);
    const slot = await registry.create(cwd);
    expect(slot.sessionFile?.startsWith(join(agentDir, "sessions"))).toBe(true);
    subscribeAudience(registry, slot.id);
    const model = faux.getModel();
    await slot.setModel(model.provider, model.id);
    const internals = registry as unknown as {
      attention: { complete: (sessionId: string, completionId: string) => Promise<unknown> };
      markers: {
        reassertAssistantCompletion: (
          sessionId: string, operationId: string, completionId: string, completedAt: string,
        ) => Promise<void>;
      };
    };
    const attention = internals.attention;
    const completionStamps = vi.spyOn(internals.markers, "reassertAssistantCompletion");
    const originalComplete = attention.complete.bind(attention);
    const complete = vi.spyOn(attention, "complete")
      .mockRejectedValueOnce(new Error("injected overlapping attention failure"))
      .mockImplementation(originalComplete);
    await slot.prompt("start");

    await waitFor(() => faux.state.callCount === 4, "the fourth model call");
    expect(slot.snapshot()).toMatchObject({ phase: "running", operation: { kind: "prompt" } });
    const continuationSnapshotIndex = snapshots.length;
    await new Promise((resolve) => setTimeout(resolve, 50));
    expect(snapshots.slice(continuationSnapshotIndex).every((snapshot) => snapshot.phase === "running" && snapshot.operation)).toBe(true);
    await waitFor(() => !slot.isBusy, "the slot to go idle");
    const settled = slot.snapshot();
    expect(settled).toMatchObject({ phase: "idle" });
    // Producer-hidden continuation context is model input but not ordinary
    // transcript UI. Its canonical receipt remains available in the branch.
    expect(settled.transcript.find((item) => item.kind === "customMessage")).toBeUndefined();
    expect(settled.transcript.some((item) =>
      item.role === "user"
        && item.semantic?.invocationId !== undefined
        && item.semantic.lifecycle === "completed")).toBe(true);
    expect(registry.attentionProjection(slot.id).completionRevision).toBe(4);
    const completionIds = complete.mock.calls.map(([, completionId]) => completionId);
    expect(completionIds).toHaveLength(5);
    expect(completionIds[0]).toBe(completionIds[1]);
    expect(new Set(completionIds.slice(1)).size).toBe(4);
    const stampedOperationIds = completionStamps.mock.calls.map(([, operationId]) => operationId);
    expect(stampedOperationIds).toHaveLength(4);
    expect(new Set(stampedOperationIds).size).toBe(4);
    expect(snapshots.some((snapshot) => snapshot.phase === "running" && snapshot.operation)).toBe(true);
  });

  it("does not retry permanent marker completion conflicts", async () => {
    const fixture = await coldFixture("permanent-marker-invariant");
    const slot = await fixture.registry.acquire(fixture.manager.getSessionId());
    const retry = (slot as unknown as {
      retryDurableWrite: (key: string, operation: () => Promise<void>) => Promise<void>;
    }).retryDurableWrite.bind(slot);
    const operation = vi.fn(async () => {
      throw new RunMarkerCompletionConflictError("injected permanent ownership conflict");
    });

    await expect(retry("marker:test", operation)).rejects.toThrow("injected permanent ownership conflict");
    expect(operation).toHaveBeenCalledOnce();
    expect(fixture.events.filter((event) => event.topic === "session.operationFailed")).toEqual([]);
  });

  it("recovers ordered continuation completions after the attention head repeatedly fails and restart", async () => {
    const root = await mkdtemp(join(tmpdir(), "tron-settlement-crash-durable-"));
    const agentDir = join(root, "agent");
    const cwd = join(root, "workspace");
    await Promise.all([
      mkdir(agentDir),
      mkdir(join(cwd, ".pi", "extensions"), { recursive: true }),
    ]);
    await writeFile(join(cwd, ".pi", "extensions", "continuation.ts"), `
let triggered = false;
export default function (pi) {
  pi.on("agent_settled", () => {
    if (triggered) return;
    triggered = true;
    pi.sendMessage({ customType: "test-continuation", content: "continue", display: false }, { triggerTurn: true });
  });
}
`);
    const faux = fauxProvider({ provider: "tron-settlement-crash-durable", tokensPerSecond: 10_000 });
    faux.setResponses([
      fauxAssistantMessage("completion A"),
      fauxAssistantMessage("completion B"),
    ]);
    const createModels = async () => {
      const runtime = await ModelRuntime.create({ modelsPath: null, refreshOnCreate: false });
      runtime.registerNativeProvider(faux.provider);
      return runtime;
    };
    const trust = new TrustService(agentDir);
    await trust.set(cwd, true);
    const tronHome = join(root, "tron");
    const registry = new RuntimeRegistry({
      agentDir, tronHome, idleRuntimeMs: 60_000, modelRuntimeFactory: createModels, trust,
      broadcast: () => {}, sessionSummaryChanged: () => {}, sessionListChanged: () => {},
    });
    registries.push(registry);
    await initializeRegistry(registry);
    const slot = await registry.create(cwd);
    const model = faux.getModel();
    await slot.setModel(model.provider, model.id);
    const internals = registry as unknown as {
      attention: { complete: (sessionId: string, completionId: string) => Promise<unknown> };
      markers: {
        evidenceFor: (sessionId: string) => Promise<Array<{ assistantCompletionId?: string }>>;
        reassertAssistantCompletion: (
          sessionId: string, operationId: string, completionId: string, completedAt: string,
        ) => Promise<void>;
      };
    };
    vi.spyOn(internals.attention, "complete").mockRejectedValue(new Error("injected persistent attention failure"));
    const originalStamp = internals.markers.reassertAssistantCompletion.bind(internals.markers);
    let secondStampEntered!: () => void;
    let releaseSecondStamp!: () => void;
    const secondStampEntry = new Promise<void>((resolve) => { secondStampEntered = resolve; });
    const secondStampBarrier = new Promise<void>((resolve) => { releaseSecondStamp = resolve; });
    let stampCount = 0;
    vi.spyOn(internals.markers, "reassertAssistantCompletion").mockImplementation(async (...arguments_) => {
      stampCount += 1;
      if (stampCount === 2) {
        secondStampEntered();
        await secondStampBarrier;
      }
      await originalStamp(...arguments_);
    });

    await slot.prompt("start");
    await secondStampEntry;
    await waitFor(() => slot.snapshot().phase === "interrupted", "the interrupted phase");
    const blockedQueue = (slot as unknown as { completionOwnershipQueue: unknown[] }).completionOwnershipQueue;
    expect(blockedQueue).toHaveLength(1);
    let disposalSettled = false;
    const disposal = registry.dispose().finally(() => { disposalSettled = true; });
    await new Promise((resolve) => setTimeout(resolve, 25));
    expect(disposalSettled).toBe(false);
    releaseSecondStamp();
    await disposal;

    const durableCompletionIds = (await internals.markers.evidenceFor(slot.id))
      .map((marker) => marker.assistantCompletionId)
      .filter((id): id is string => id !== undefined);
    expect(durableCompletionIds).toHaveLength(2);
    expect(new Set(durableCompletionIds).size).toBe(2);
    const restarted = new RuntimeRegistry({
      agentDir, tronHome, idleRuntimeMs: 60_000, modelRuntimeFactory: createModels,
      trust: new TrustService(agentDir),
      broadcast: () => {}, sessionSummaryChanged: () => {}, sessionListChanged: () => {},
    });
    registries.push(restarted);
    const restartedAttention = (restarted as unknown as {
      attention: { complete: (sessionId: string, completionId: string) => Promise<unknown> };
    }).attention;
    const recovered = vi.spyOn(restartedAttention, "complete");
    await initializeRegistry(restarted);
    await restarted.recoverCanonicalAttention();

    expect(recovered.mock.calls.map(([, completionId]) => completionId)).toEqual(durableCompletionIds);
    expect(restarted.attentionProjection(slot.id)).toMatchObject({ completionRevision: 2, isUnread: true });
  });

  it("measures real prompt snapshot burst without dropping ordered lifecycle frames", async () => {
    const root = await mkdtemp(join(tmpdir(), "tron-snapshot-burst-"));
    const agentDir = join(root, "agent");
    const cwd = join(root, "workspace");
    const sessionDirectory = join(agentDir, "sessions", "workspace");
    await mkdir(sessionDirectory, { recursive: true });
    await mkdir(cwd, { recursive: true });
    process.env.PI_CODING_AGENT_DIR = agentDir;
    const manager = SessionManager.create(cwd, sessionDirectory);
    for (let index = 0; index < 160; index += 1) {
      manager.appendMessage(fauxAssistantMessage(`history-${index} ${"x".repeat(3_600)}`));
    }
    const runtime = await ModelRuntime.create({ modelsPath: null, refreshOnCreate: false });
    const faux = fauxProvider({ provider: "tron-snapshot-burst", tokensPerSecond: 10_000 });
    faux.setResponses([fauxAssistantMessage("prompt response")]);
    runtime.registerNativeProvider(faux.provider);
    const events: Array<{ topic: string; payload: any; at: number }> = [];
    const registry = new RuntimeRegistry({
      agentDir, tronHome: join(root, "tron"), idleRuntimeMs: 60_000,
      modelRuntimeFactory: async () => runtime,
      trust: new TrustService(agentDir), broadcast: (_id, topic, payload) => events.push({ topic, payload, at: Date.now() }),
      sessionSummaryChanged: () => {}, sessionListChanged: () => {},
    });
    registries.push(registry);
    await initializeRegistry(registry);
    const slot = await registry.acquire(manager.getSessionId());
    subscribeAudience(registry, slot.id);
    const model = faux.getModel();
    await slot.setModel(model.provider, model.id);
    const before = events.length;
    const receipt = await slot.prompt("accepted snapshot burst");
    await waitFor(() => !slot.isBusy, "the slot to go idle");
    const snapshots = events.slice(before).filter((event) => event.topic === "session.snapshot");
    const sizes = snapshots.map((event) => Buffer.byteLength(JSON.stringify(event.payload)));
    expect(sizes.some((size) => size >= 400 * 1_024)).toBe(true);
    const sequences = events.slice(before)
      .map((event) => event.payload.eventSequence)
      .filter((value) => typeof value === "number");
    for (let index = 1; index < sequences.length; index += 1) {
      expect(sequences[index]).toBe(sequences[index - 1]! + 1);
    }
    // Deterministic paused-consumer oracle: hold every ordered frame until
    // the owner has finished the accepted prompt. This proves the complete
    // serialized burst exceeds the 2 MiB connection budget independently of
    // CI scheduling. A resumed consumer can then dequeue the same frames in
    // order; no frame is silently removed by this fixture.
    const pausedQueue = events.slice(before).map((event) => Buffer.byteLength(JSON.stringify({
      type: "event", topic: event.topic, sessionId: slot.id, payload: event.payload,
    })));
    const pausedBytes = pausedQueue.reduce((total, bytes) => total + bytes, 0);
    expect(pausedBytes).toBeGreaterThan(2 * 1_024 * 1_024);
    let resumedBytes = pausedBytes;
    for (const bytes of pausedQueue) resumedBytes -= bytes;
    expect(resumedBytes).toBe(0);
    expect(slot.snapshot().transcript.some((item) => item.kind === "message" && item.presentationId === receipt.operationId)).toBe(true);
    // The owner emits complete snapshots for distinct lifecycle revisions; no
    // safe frame can be subtracted here without a receiver rebaseline contract.
    expect(snapshots.every((event) => event.payload.sessionId === slot.id)).toBe(true);
  });

  it("keeps a large streamed write visible through snapshot recovery and canonical handoff", async () => {
    const root = await mkdtemp(join(tmpdir(), "tron-large-streamed-write-"));
    const agentDir = join(root, "agent");
    const cwd = join(root, "workspace");
    await Promise.all([mkdir(agentDir), mkdir(cwd)]);
    process.env.PI_CODING_AGENT_DIR = agentDir;
    const content = "Report line 🦌\\n".repeat(3_000);
    const path = join(cwd, "report.txt");
    // The write's 51 KB of arguments are what the live frame has to survive, so
    // they stay; the chunk size only keeps the provider's per-chunk timer yield
    // from spending seconds of wall clock (3,188 chunks at 100k tokens/s) on a
    // case that asserts nothing about pacing.
    const faux = fauxProvider({ provider: "tron-large-streamed-write", tokensPerSecond: 100_000, tokenSize: { min: 32, max: 32 } });
    faux.setResponses([
      fauxAssistantMessage([
        { type: "text", text: "Here is the summary before the report." },
        fauxToolCall("write", { path, content }, { id: "call-large-write" }),
      ], { stopReason: "toolUse" }),
      fauxAssistantMessage("Report saved."),
    ]);
    const runtime = await ModelRuntime.create({ modelsPath: null, refreshOnCreate: false });
    runtime.registerNativeProvider(faux.provider);
    const events: Array<{ topic: string; payload: any }> = [];
    const liveSnapshots: Array<{ progress: any; streaming: any }> = [];
    let currentSlot: Awaited<ReturnType<RuntimeRegistry["create"]>> | undefined;
    const registry = new RuntimeRegistry({
      agentDir, tronHome: join(root, "tron"), idleRuntimeMs: 60_000,
      modelRuntimeFactory: async () => runtime, trust: new TrustService(agentDir),
      broadcast: (_id, topic, payload) => {
        events.push({ topic, payload });
        if (topic === "session.progress" && currentSlot) {
          liveSnapshots.push({ progress: (payload as any).data?.message, streaming: currentSlot.snapshot().streaming });
        }
      },
      sessionSummaryChanged: () => {}, sessionListChanged: () => {},
    });
    registries.push(registry);
    await initializeRegistry(registry);
    const slot = await registry.create(cwd);
    currentSlot = slot;
    // A test that reads published progress frames has to be a subscriber (G-3a).
    subscribeAudience(registry, slot.id);
    const model = faux.getModel();
    await slot.setModel(model.provider, model.id);
    await slot.prompt("Write a report");
    await waitFor(() => !slot.isBusy, "the slot to go idle");

    const declarations = liveSnapshots.filter(({ progress }) => progress?.content?.some(
      (part: any) => part.toolCallId === "call-large-write" && part.arguments?.truncated === true,
    ));
    expect(declarations.length).toBeGreaterThan(0);
    for (const { progress, streaming } of declarations) {
      expect(Buffer.byteLength(JSON.stringify(progress))).toBeLessThanOrEqual(24_000);
      expect(progress.content).toContainEqual(expect.objectContaining({ type: "text", text: "Here is the summary before the report." }));
      expect(streaming).toEqual(progress);
    }
    const finalized = events.findIndex(event => event.topic === "session.progress"
      && event.payload.data?.message?.content?.some((part: any) => part.toolCallId === "call-large-write" && part.groupFinalized));
    const running = events.findIndex(event => event.topic === "session.toolProgress"
      && event.payload.data?.toolCallId === "call-large-write" && event.payload.data?.status === "running");
    expect(finalized).toBeGreaterThanOrEqual(0);
    expect(running).toBeGreaterThan(finalized);
    expect(await readFile(path, "utf8")).toBe(content);
    const settled = slot.snapshot();
    expect(settled.streaming).toBeUndefined();
    const calls = settled.transcript.flatMap(item => item.kind === "message" ? item.content : [])
      .filter(part => part.type === "toolCall" && part.toolCallId === "call-large-write");
    expect(calls).toHaveLength(1);
    expect(calls[0]).toMatchObject({ arguments: { path, content }, groupFinalized: true });
    const declaration = declarations.at(-1)!.progress;
    expect(settled.transcript.some(item => item.presentationId === declaration.presentationId)).toBe(true);
  });

  it("coalesces streaming progress frames while keeping the event stream contiguous and complete", async () => {
    const root = await mkdtemp(join(tmpdir(), "tron-streaming-coalesce-"));
    const agentDir = join(root, "agent");
    const cwd = join(root, "workspace");
    await Promise.all([mkdir(agentDir), mkdir(cwd)]);
    process.env.PI_CODING_AGENT_DIR = agentDir;

    // Deterministic 4-character chunks at 100 tokens/second stream ~240 SDK
    // updates over ~2.4 seconds. Uncoalesced, every update would republish the
    // cumulative message to each subscriber.
    const text = "streaming chunk ".repeat(60);
    const faux = fauxProvider({ provider: "tron-streaming-coalesce", tokensPerSecond: 100, tokenSize: { min: 1, max: 1 } });
    const createModels = async () => {
      const runtime = await ModelRuntime.create({ modelsPath: null, refreshOnCreate: false });
      runtime.registerNativeProvider(faux.provider);
      return runtime;
    };
    faux.setResponses([fauxAssistantMessage(text)]);
    const events: Array<{ topic: string; at: number; payload: { eventSequence?: number; data?: any } }> = [];
    const registry = new RuntimeRegistry({
      agentDir,
      tronHome: join(root, "tron"),
      idleRuntimeMs: 60_000,
      modelRuntimeFactory: createModels,
      trust: new TrustService(agentDir),
      broadcast: (_sessionId, topic, payload) => events.push({
        topic,
        at: nodePerformance.now(),
        payload: payload as { eventSequence?: number; data?: any },
      }),
      sessionSummaryChanged: () => {},
      sessionListChanged: () => {},
    });
    registries.push(registry);
    await initializeRegistry(registry);
    const slot = await registry.create(cwd);
    subscribeAudience(registry, slot.id);
    const model = faux.getModel();
    await slot.setModel(model.provider, model.id);
    const promptReceipt = await slot.prompt("stream");
    await waitFor(() => !slot.isBusy, "the slot to go idle");
    expect(slot.snapshot().pendingPrompt).toBeUndefined();
    const canonicalUser = slot.snapshot().transcript.find((item) => item.role === "user");
    expect(canonicalUser).toMatchObject({ presentationId: promptReceipt.operationId });

    const progress = events.filter((event) => event.topic === "session.progress");
    expect(progress.length).toBeGreaterThanOrEqual(2);

    // Throttle cadence: while updates keep arriving, at most one frame per
    // 150 ms window. A frame published immediately before a snapshot is that
    // state transition's ordering flush, and the last frame is message_end's
    // finalized declaration; neither is paced. The window starts when the
    // timer is armed, just before the leading frame's projection, so a slow
    // projection shortens the measured gap; a leading edge re-firing right
    // after each trailing flush would instead land within a few milliseconds.
    const cadence = progress.filter((event, index) => {
      if (index === progress.length - 1) return false;
      return events[events.indexOf(event) + 1]?.topic !== "session.snapshot";
    });
    expect(cadence.length).toBeGreaterThanOrEqual(5);
    for (let index = 1; index < cadence.length; index += 1) {
      expect(cadence[index]!.at - cadence[index - 1]!.at).toBeGreaterThanOrEqual(100);
    }
    // A paced frame always carries the newest cumulative text, so frames never
    // regress to an older message.
    const progressTextLengths = progress.map((event) => (event.payload.data?.message?.content ?? [])
      .filter((part: any) => part.type === "text")
      .reduce((length: number, part: any) => length + part.text.length, 0));
    for (let index = 1; index < progressTextLengths.length; index += 1) {
      expect(progressTextLengths[index]).toBeGreaterThanOrEqual(progressTextLengths[index - 1]!);
    }

    // Coalescing must never reorder or gap the sequenced event stream.
    const sequenced = events.filter((event) => typeof event.payload.eventSequence === "number");
    for (let index = 1; index < sequenced.length; index += 1) {
      expect(sequenced[index]!.payload.eventSequence).toBe(sequenced[index - 1]!.payload.eventSequence! + 1);
    }

    // The last live frame carries the complete cumulative message and the
    // settled canonical transcript keeps the full text.
    const progressMessages = progress.map((event) => event.payload.data?.message).filter(Boolean);
    const lastMessage = progressMessages.at(-1)!;
    const lastText = (lastMessage.content ?? []).filter((part: any) => part.type === "text").map((part: any) => part.text).join("");
    expect(lastText.trimEnd().endsWith("streaming chunk")).toBe(true);
    expect(new Set(progressMessages.map((message) => message.presentationId)).size).toBe(1);
    expect(new Set(progressMessages.map((message) => message.parentId)).size).toBe(1);
    expect(new Set(progressMessages.map((message) => message.timestamp)).size).toBe(1);
    expect(lastMessage.content.map((part: any) => part.ordinal)).toEqual([0]);
    const finalSnapshot = slot.snapshot();
    expect(finalSnapshot.streaming).toBeUndefined();
    const assistant = finalSnapshot.transcript.find(
      (item) => item.kind === "message" && item.role === "assistant",
    );
    expect(assistant).toMatchObject({ presentationId: lastMessage.presentationId });
    const transcriptText = finalSnapshot.transcript
      .filter((item) => item.kind === "message")
      .flatMap((item) => item.kind === "message" ? item.content : [])
      .filter((part) => part.type === "text")
      .map((part) => part.type === "text" ? part.text : "")
      .join("");
    expect(transcriptText).toContain(text.trimEnd());
  });

  // G-3a: the progress frame is the whole cumulative streaming message
  // re-projected and serialized on every flush window, so an unsubscribed
  // session must pay for none of it. The subscriber record is the slot's whole
  // audience fact, the same one `publishSnapshot` reads.
  it("projects no streaming progress for a session with no subscriber and resumes it on subscribe", async () => {
    const root = await mkdtemp(join(tmpdir(), "tron-streaming-unwatched-"));
    const agentDir = join(root, "agent");
    const cwd = join(root, "workspace");
    await Promise.all([mkdir(agentDir), mkdir(cwd)]);
    process.env.PI_CODING_AGENT_DIR = agentDir;

    // Deterministic 1-token chunks at 100 tokens/second: the first half streams
    // with no subscriber, the second with one, and both cross several 150 ms
    // flush windows.
    const unwatched = "unwatched chunk ".repeat(20);
    const watched = "watched chunk ".repeat(20);
    const faux = fauxProvider({ provider: "tron-streaming-unwatched", tokensPerSecond: 100, tokenSize: { min: 1, max: 1 } });
    const createModels = async () => {
      const runtime = await ModelRuntime.create({ modelsPath: null, refreshOnCreate: false });
      runtime.registerNativeProvider(faux.provider);
      return runtime;
    };
    faux.setResponses([fauxAssistantMessage(unwatched), fauxAssistantMessage(watched)]);
    const events: Array<{ topic: string; payload: { data?: any } }> = [];
    const registry = new RuntimeRegistry({
      agentDir,
      tronHome: join(root, "tron"),
      idleRuntimeMs: 60_000,
      modelRuntimeFactory: createModels,
      trust: new TrustService(agentDir),
      broadcast: (_sessionId, topic, payload) => events.push({ topic, payload: payload as { data?: any } }),
      sessionSummaryChanged: () => {},
      sessionListChanged: () => {},
    });
    registries.push(registry);
    await initializeRegistry(registry);
    const slot = await registry.create(cwd);
    const model = faux.getModel();
    await slot.setModel(model.provider, model.id);

    const unwatchedPrompt = slot.prompt("stream unobserved");
    await waitFor(() => slot.snapshot().streaming !== undefined, "the streaming projection");
    await unwatchedPrompt;
    await waitFor(() => !slot.isBusy, "the slot to go idle");
    // The response streamed to completion (its canonical message is settled),
    // so the absent frames are the rule and not a stream that never ran.
    expect(slot.snapshot().transcript.some((item) => item.kind === "message"
      && item.role === "assistant" && item.content.some((part) => part.type === "text" && part.text.includes(unwatched.trimEnd())))).toBe(true);
    expect(events.filter((event) => event.topic === "session.progress")).toHaveLength(0);

    subscribeAudience(registry, slot.id);
    await slot.prompt("stream observed");
    await waitFor(() => !slot.isBusy, "the slot to go idle");
    const frames = events.filter((event) => event.topic === "session.progress");
    expect(frames.length).toBeGreaterThanOrEqual(2);
    const lastFrame = frames.at(-1)!.payload.data.message;
    expect(lastFrame.content
      .filter((part: any) => part.type === "text")
      .map((part: any) => part.text)
      .join("").trimEnd()).toBe(watched.trimEnd());
    // Nothing from the unobserved stream leaks into the observed one.
    expect(JSON.stringify(frames)).not.toContain("unwatched chunk");
  });

  it.each(["message_start", "message_end"] as const)(
    "keeps one presentation identity through an async %s extension hook",
    async (hook) => {
      const root = await mkdtemp(join(tmpdir(), `tron-streaming-${hook}-`));
      const agentDir = join(root, "agent");
      const cwd = join(root, "workspace");
      const extensionDir = join(cwd, ".pi", "extensions");
      const entered = join(root, "entered");
      const release = join(root, "release");
      await Promise.all([mkdir(agentDir), mkdir(extensionDir, { recursive: true })]);
      process.env.PI_CODING_AGENT_DIR = agentDir;
      await writeFile(join(extensionDir, "streaming-hook.ts"), `
        import { existsSync, writeFileSync } from "node:fs";
        export default function (pi) {
          pi.on(${JSON.stringify(hook)}, async (event) => {
            if (event.message?.role !== "assistant") return;
            writeFileSync(${JSON.stringify(entered)}, "entered");
            while (!existsSync(${JSON.stringify(release)})) {
              await new Promise((resolve) => setTimeout(resolve, 5));
            }
          });
        }
      `);
      const trust = new TrustService(agentDir);
      await trust.set(cwd, true);
      const faux = fauxProvider({ provider: `tron-streaming-${hook}`, tokensPerSecond: 20, tokenSize: { min: 1, max: 1 } });
      const createModels = async () => {
        const runtime = await ModelRuntime.create({ modelsPath: null, refreshOnCreate: false });
        runtime.registerNativeProvider(faux.provider);
        return runtime;
      };
      faux.setResponses([fauxAssistantMessage("stable identity")]);
      const registry = new RuntimeRegistry({
        agentDir,
        tronHome: join(root, "tron"),
        idleRuntimeMs: 60_000,
        modelRuntimeFactory: createModels,
        trust,
        broadcast: () => {},
        sessionSummaryChanged: () => {},
        sessionListChanged: () => {},
      });
      registries.push(registry);
      await initializeRegistry(registry);
      const slot = await registry.create(cwd);
      const model = faux.getModel();
      await slot.setModel(model.provider, model.id);

      const prompt = slot.prompt("stream");
      await waitFor(() => existsSync(entered), "the entered marker file");
      const during = slot.snapshot().streaming;
      expect(during).toMatchObject({ role: "assistant" });
      if (during?.kind !== "message") throw new Error("expected live assistant");
      if (hook === "message_end") {
        expect(slot.snapshot().transcript.some((item) => item.kind === "message" && item.role === "assistant")).toBe(false);
      }
      await writeFile(release, "release");
      await prompt;
      await waitFor(() => !slot.isBusy, "the slot to go idle");

      const finalSnapshot = slot.snapshot();
      expect(finalSnapshot.streaming).toBeUndefined();
      const canonical = finalSnapshot.transcript.find(
        (item) => item.kind === "message" && item.role === "assistant",
      );
      expect(canonical).toMatchObject({
        id: expect.not.stringMatching(/^streaming$/),
        presentationId: during.presentationId,
      });
      if (canonical?.kind !== "message") throw new Error("expected canonical assistant");
      expect(canonical.content.slice(0, during.content.length).map(
        (part) => ({ id: part.id, ordinal: part.ordinal }),
      )).toEqual(during.content.map((part) => ({ id: part.id, ordinal: part.ordinal })));
    },
    15_000,
  );

  it("keeps async input preflight alive and settles accepted handled input exactly once", async () => {
    const root = await mkdtemp(join(tmpdir(), "tron-input-handled-preflight-"));
    const agentDir = join(root, "agent");
    const cwd = join(root, "workspace");
    const extensionDir = join(cwd, ".pi", "extensions");
    await Promise.all([mkdir(agentDir), mkdir(extensionDir, { recursive: true })]);
    await writeFile(join(extensionDir, "handled.ts"), `export default function (pi) {
      pi.on("input", async () => {
        await new Promise((resolve) => setTimeout(resolve, 200));
        return { action: "handled" };
      });
    }\n`);
    const trust = new TrustService(agentDir);
    await trust.set(cwd, true);
    const registry = new RuntimeRegistry({
      agentDir, tronHome: join(root, "tron"), idleRuntimeMs: 60_000, trust,
      broadcast: () => {}, sessionSummaryChanged: () => {}, sessionListChanged: () => {},
    });
    registries.push(registry);
    await initializeRegistry(registry);
    const slot = await registry.create(cwd);
    const prompting = slot.prompt("handled without agent");
    await waitFor(() => slot.isBusy, "the slot to take work");
    await expect(slot.dispose()).rejects.toMatchObject({ code: "busy" });
    const admitted = await prompting;
    expect(admitted).toMatchObject({ operationId: expect.any(String) });
    await waitFor(() => !slot.isBusy, "the slot to go idle");
    expect(slot.snapshot()).toMatchObject({ phase: "idle" });
    expect(slot.snapshot().operation).toBeUndefined();
    const entries = (slot as any).runtime.session.sessionManager.getEntries() as any[];
    const receipts = entries.filter(entry =>
      entry.customType === INVOCATION_RECEIPT_TYPE
        && entry.data?.operationId === admitted.operationId,
    ).map(entry => entry.data);
    expect(receipts.map(receipt => receipt.receiptKind)).toEqual(["start", "transition", "terminal"]);
    expect(receipts.at(-1)).toMatchObject({ lifecycle: "completed" });
    const markerStore = (registry as unknown as { markers: { interruptedSessionIds(): Promise<Set<string>> } }).markers;
    expect((await markerStore.interruptedSessionIds()).has(slot.id)).toBe(false);
  });

  it("permits the exact delayed prompt accepted before the drain cutoff", async () => {
    const root = await mkdtemp(join(tmpdir(), "tron-drain-delayed-preflight-"));
    const agentDir = join(root, "agent");
    const cwd = join(root, "workspace");
    const extensionDir = join(cwd, ".pi", "extensions");
    await Promise.all([mkdir(agentDir), mkdir(extensionDir, { recursive: true })]);
    await writeFile(join(extensionDir, "delay.ts"), `export default function (pi) {
      pi.on("input", async () => { await new Promise((resolve) => setTimeout(resolve, 150)); });
    }\n`);
    const trust = new TrustService(agentDir);
    await trust.set(cwd, true);
    const faux = fauxProvider({ provider: "tron-drain-delayed-preflight", tokensPerSecond: 10_000 });
    faux.setResponses([fauxAssistantMessage("accepted after delayed preflight")]);
    const runtime = await ModelRuntime.create({ modelsPath: null, refreshOnCreate: false });
    runtime.registerNativeProvider(faux.provider);
    const failures: unknown[] = [];
    const registry = new RuntimeRegistry({
      agentDir, tronHome: join(root, "tron"), idleRuntimeMs: 60_000, trust,
      modelRuntimeFactory: async () => runtime,
      broadcast: (_id, topic, payload) => { if (topic === "session.operationFailed") failures.push(payload); },
      sessionSummaryChanged: () => {}, sessionListChanged: () => {},
    });
    registries.push(registry);
    await initializeRegistry(registry);
    const slot = await registry.create(cwd);
    const model = faux.getModel();
    await slot.setModel(model.provider, model.id);
    const prompt = slot.prompt("accepted before cutoff");
    await waitFor(() => slot.isBusy, "the slot to take work");
    const drain = registry.waitUntilIdle();
    await expect(prompt).resolves.toMatchObject({ operationId: expect.any(String) });
    await drain;
    expect(faux.state.callCount).toBe(1);
    expect(failures).toEqual([]);
    expect(slot.snapshot()).toMatchObject({ phase: "idle" });
  });

  it("cuts off extension auto-continuations during administrative drain", async () => {
    const root = await mkdtemp(join(tmpdir(), "tron-drain-continuation-cutoff-"));
    const agentDir = join(root, "agent");
    const cwd = join(root, "workspace");
    const extensionDir = join(cwd, ".pi", "extensions");
    await Promise.all([mkdir(agentDir), mkdir(extensionDir, { recursive: true })]);
    await writeFile(join(extensionDir, "continue.ts"), `let sent = false;
      export default function (pi) {
        pi.on("agent_settled", () => {
          if (sent) return;
          sent = true;
          pi.sendMessage({ customType: "after-cutoff", content: "continue", display: false }, { triggerTurn: true });
        });
      }\n`);
    const trust = new TrustService(agentDir);
    await trust.set(cwd, true);
    const faux = fauxProvider({ provider: "tron-drain-cutoff", tokensPerSecond: 10_000 });
    faux.setResponses([
      async () => { await new Promise((resolve) => setTimeout(resolve, 150)); return fauxAssistantMessage("first"); },
      fauxAssistantMessage("must be aborted"),
    ]);
    const runtime = await ModelRuntime.create({ modelsPath: null, refreshOnCreate: false });
    runtime.registerNativeProvider(faux.provider);
    const failures: unknown[] = [];
    const registry = new RuntimeRegistry({
      agentDir, tronHome: join(root, "tron"), idleRuntimeMs: 60_000, trust,
      modelRuntimeFactory: async () => runtime,
      broadcast: (_id, topic, payload) => { if (topic === "session.operationFailed") failures.push(payload); },
      sessionSummaryChanged: () => {}, sessionListChanged: () => {},
    });
    registries.push(registry);
    await initializeRegistry(registry);
    const slot = await registry.create(cwd);
    const model = faux.getModel();
    await slot.setModel(model.provider, model.id);
    await slot.prompt("start");
    await waitFor(() => slot.catalogPhase === "running", "the catalog phase to run");
    await registry.waitUntilIdle();
    expect(slot.isDrainBusy).toBe(false);
    expect(failures).not.toEqual([]);
  });

  it("uses runtime preflight as the sole prompt-admission outcome", async () => {
    const root = await mkdtemp(join(tmpdir(), "tron-prompt-preflight-"));
    const agentDir = join(root, "agent");
    const cwd = join(root, "workspace");
    await Promise.all([mkdir(agentDir), mkdir(cwd)]);
    const runtime = await ModelRuntime.create({ modelsPath: null, refreshOnCreate: false });
    const registry = new RuntimeRegistry({
      agentDir,
      tronHome: join(root, "tron"),
      idleRuntimeMs: 60_000,
      modelRuntimeFactory: async () => runtime,
      trust: new TrustService(agentDir),
      broadcast: () => {},
      sessionSummaryChanged: () => {},
      sessionListChanged: () => {},
    });
    registries.push(registry);
    await initializeRegistry(registry);
    const slot = await registry.create(cwd);
    const session = (slot as unknown as {
      runtime: { session: { prompt: (
        text: string,
        options?: { preflightResult?: (disposition: "handled" | "queued" | "started") => void },
      ) => Promise<void> } };
    }).runtime.session;
    let startedResolve!: () => void;
    const started = new Promise<void>((resolve) => { startedResolve = resolve; });
    vi.spyOn(session, "prompt").mockImplementationOnce(async (_text, options) => {
      startedResolve();
      await new Promise((resolve) => setTimeout(resolve, 6_000));
      options?.preflightResult?.("started");
    });

    vi.useFakeTimers();
    try {
      const attachment = {
        id: "upload:00000000-0000-4000-8000-000000000001",
        name: "notes.txt", mimeType: "text/plain", size: 4,
      };
      const prompting = slot.prompt("delayed preflight", [], undefined, {
        text: "delayed preflight",
        attachmentEnvelope: '<attachment name="notes.txt" />',
        attachmentCount: 1,
        photoCount: 0,
        fileAttachmentCount: 1,
        attachments: [attachment],
      });
      await started;
      expect(slot.snapshot().pendingPrompt).toMatchObject({
        id: expect.any(String),
        text: "delayed preflight",
        attachmentCount: 1,
        attachments: [attachment],
      });
      await vi.advanceTimersByTimeAsync(6_000);
      await expect(prompting).resolves.toMatchObject({ operationId: expect.any(String) });
    } finally {
      vi.useRealTimers();
    }
  });

  it("rejects a stale stop receipt before it can abort a newer operation", async () => {
    const fixture = await coldFixture("stale-operation-abort");
    const slot = await fixture.registry.acquire(fixture.manager.getSessionId());
    const internal = slot as unknown as {
      operation?: { id: string; kind: "prompt"; startedAt: string };
    };
    internal.operation = {
      id: "newer-operation", kind: "prompt", startedAt: new Date().toISOString(),
    };

    await expect(slot.abort("agent", "older-operation")).rejects.toMatchObject({
      code: "conflict",
      retryable: true,
    });
    expect(internal.operation?.id).toBe("newer-operation");
  });

  it("holds steering behind compaction even while Pi reports broad streaming", async () => {
    const fixture = await coldFixture("compaction-steer-admission");
    const slot = await fixture.registry.acquire(fixture.manager.getSessionId());
    const internal = slot as unknown as {
      phase: "compacting" | "running";
      activeOperationId?: string;
      operation?: { id?: string; kind: "compaction"; startedAt: string };
      publishSnapshot: () => void;
      runtime: { session: {
        readonly isStreaming: boolean;
        prompt: (text: string, options?: {
          streamingBehavior?: "steer" | "followUp";
          preflightResult?: (disposition: "handled" | "queued" | "started") => void;
        }) => Promise<void>;
        getSteeringMessages: () => readonly string[];
      } };
    };
    internal.phase = "compacting";
    internal.operation = {
      id: "compaction-operation", kind: "compaction", startedAt: new Date().toISOString(),
    };
    vi.spyOn(internal.runtime.session, "isStreaming", "get").mockReturnValue(true);
    internal.activeOperationId = "prior-agent-operation";
    const compactingSnapshot = slot.snapshot();
    // The Gateway queues compaction-time input itself; no Agent tool segment
    // is live while the summary runs.
    expect(compactingSnapshot.acceptsQueuedPrompts).toBe(true);
    expect(compactingSnapshot.activeToolSegmentId).toBeUndefined();
    internal.activeOperationId = undefined;
    let queued = false;
    vi.spyOn(internal.runtime.session, "getSteeringMessages")
      .mockImplementation(() => queued ? ["after compaction"] : []);
    let invoked = false;
    vi.spyOn(internal.runtime.session, "prompt").mockImplementationOnce(async (_text, options) => {
      invoked = true;
      expect(options?.streamingBehavior).toBe("steer");
      queued = true;
      options?.preflightResult?.("started");
    });

    const prompting = slot.prompt("after compaction", [], "steer");
    await Promise.resolve();
    expect(invoked).toBe(false);
    internal.phase = "running";
    internal.operation = undefined;
    internal.publishSnapshot();

    const { operationId } = await prompting;
    await waitFor(() => invoked, "the invocation");
    await waitFor(() => slot.snapshot().queuedItems.length === 1 && queued, "the queued prompt");
    expect(slot.snapshot().queuedItems).toEqual([
      expect.objectContaining({ id: operationId, behavior: "steer", text: "after compaction" }),
    ]);
  });

  it("preserves a successor operation and abort intent across compaction_end", async () => {
    const fixture = await coldFixture("compaction-successor-ownership");
    const slot = await fixture.registry.acquire(fixture.manager.getSessionId());
    const internal = slot as unknown as {
      phase: "running" | "compacting";
      activeOperationId?: string;
      operation?: { id?: string; kind: "prompt" | "compaction"; startedAt: string };
      abortedOperations: Set<string>;
      onEvent: (event: unknown) => void;
      runtime: { session: { readonly isStreaming: boolean } };
    };
    const streaming = vi.spyOn(internal.runtime.session, "isStreaming", "get").mockReturnValue(true);
    internal.phase = "running";
    internal.activeOperationId = "original-operation";
    internal.operation = { id: "original-operation", kind: "prompt", startedAt: new Date().toISOString() };

    internal.onEvent({ type: "compaction_start", reason: "threshold" });
    const compactionID = internal.operation?.id;
    expect(internal.operation?.kind).toBe("compaction");
    expect(compactionID).toBeDefined();
    internal.abortedOperations.add(compactionID!);

    internal.operation = { id: "successor-operation", kind: "prompt", startedAt: new Date().toISOString() };
    internal.activeOperationId = "successor-operation";
    internal.phase = "running";
    internal.abortedOperations.add("successor-operation");
    internal.onEvent({ type: "compaction_end", reason: "threshold", result: undefined, aborted: false, willRetry: false });

    expect(slot.snapshot()).toMatchObject({
      phase: "running",
      operation: { id: "successor-operation", kind: "prompt" },
    });
    expect(internal.abortedOperations.has(compactionID!)).toBe(false);
    expect(internal.abortedOperations.has("successor-operation")).toBe(true);
    streaming.mockRestore();
  });

  it("leaves a successor running when manual compaction settles after an awaited failure", async () => {
    const fixture = await coldFixture("manual-compaction-successor-cleanup");
    const slot = await fixture.registry.acquire(fixture.manager.getSessionId());
    const internal = slot as unknown as {
      phase: "idle" | "running" | "compacting";
      operation?: { id?: string; kind: "prompt" | "compaction"; startedAt: string };
      abortedOperations: Set<string>;
      runtime: { session: { compact: (instructions?: string) => Promise<unknown> } };
    };
    vi.spyOn(internal.runtime.session, "compact").mockImplementation(async () => {
      const compactionID = internal.operation?.id;
      expect(internal.operation?.kind).toBe("compaction");
      if (compactionID) internal.abortedOperations.add(compactionID);
      internal.operation = { id: "manual-successor", kind: "prompt", startedAt: new Date().toISOString() };
      internal.phase = "running";
      internal.abortedOperations.add("manual-successor");
      throw new Error("manual compaction failed after successor start");
    });

    await expect(slot.compact()).rejects.toThrow("manual compaction failed after successor start");
    expect(slot.snapshot()).toMatchObject({
      phase: "running",
      operation: { id: "manual-successor", kind: "prompt" },
    });
    expect(internal.abortedOperations.has("manual-successor")).toBe(true);
  });

  it("rotates provisional tool segment authority across automatic compaction", async () => {
    const fixture = await coldFixture("compaction-tool-segment-boundary");
    const slot = await fixture.registry.acquire(fixture.manager.getSessionId());
    const internal = slot as unknown as {
      phase: "running" | "compacting";
      activeOperationId?: string;
      activeToolSegmentOwnerId?: string;
      onEvent: (event: unknown) => void;
      runtime: { session: { readonly isStreaming: boolean } };
    };
    const streaming = vi.spyOn(internal.runtime.session, "isStreaming", "get").mockReturnValue(true);
    internal.phase = "running";
    internal.activeOperationId = "operation-before-compaction";
    internal.activeToolSegmentOwnerId = "operation-before-compaction";
    const beforeSegment = slot.snapshot().activeToolSegmentId;
    expect(beforeSegment).toBe(toolSegmentId("operation-before-compaction"));

    internal.onEvent({ type: "compaction_start", reason: "threshold" });
    // Compaction-time input is Gateway-queued, yet no Agent segment is live.
    expect(slot.snapshot()).toMatchObject({
      phase: "compacting",
      acceptsQueuedPrompts: true,
    });
    expect(slot.snapshot().activeToolSegmentId).toBeUndefined();

    internal.onEvent({
      type: "compaction_end",
      reason: "threshold",
      result: undefined,
      aborted: false,
      willRetry: false,
    });
    const provisionalSegment = slot.snapshot().activeToolSegmentId;
    expect(provisionalSegment).toMatch(/^tool-segment:/);
    expect(provisionalSegment).not.toBe(beforeSegment);

    const assistant = fauxAssistantMessage([
      fauxToolCall("read", { path: "README.md" }, { id: "call-after-compaction" }),
    ], { stopReason: "toolUse" });
    internal.onEvent({ type: "message_start", message: assistant });
    const assistantSegment = slot.snapshot().activeToolSegmentId;
    expect(assistantSegment).toMatch(/^tool-segment:/);
    expect(assistantSegment).not.toBe(provisionalSegment);
    internal.onEvent({ type: "message_end", message: assistant });
    internal.onEvent({
      type: "tool_execution_start",
      toolCallId: "call-after-compaction",
      toolName: "read",
      args: { path: "README.md" },
    });
    expect(slot.snapshot().toolExecutions).toEqual([
      expect.objectContaining({
        toolCallId: "call-after-compaction",
        toolSegmentId: assistantSegment,
      }),
    ]);
    streaming.mockRestore();
  });

  it.each(["successful append", "pre-staging append failure"])(
    "retires completion observations after queued successful operations settle (%s)", async (appendOutcome) => {
    const root = await mkdtemp(join(tmpdir(), "tron-completion-observation-retirement-"));
    const agentDir = join(root, "agent");
    const cwd = join(root, "workspace");
    await Promise.all([mkdir(agentDir), mkdir(cwd)]);
    let releaseInitial!: () => void;
    let releaseFollowUp!: () => void;
    let releaseAttention!: () => void;
    let followUpStarted!: () => void;
    const initialBarrier = new Promise<void>((resolve) => { releaseInitial = resolve; });
    const followUpBarrier = new Promise<void>((resolve) => { releaseFollowUp = resolve; });
    const attentionBarrier = new Promise<void>((resolve) => { releaseAttention = resolve; });
    const followUpStart = new Promise<void>((resolve) => { followUpStarted = resolve; });
    onTestFinished(async () => {
      releaseInitial();
      releaseFollowUp();
      releaseAttention();
      await rm(root, { recursive: true, force: true });
    });
    const faux = fauxProvider({ provider: "tron-completion-observation-retirement", tokensPerSecond: 10_000 });
    faux.setResponses([
      async () => {
        await initialBarrier;
        return fauxAssistantMessage("initial complete");
      },
      async () => {
        followUpStarted();
        await followUpBarrier;
        return fauxAssistantMessage("follow-up complete");
      },
    ]);
    const runtime = await ModelRuntime.create({ modelsPath: null, refreshOnCreate: false });
    runtime.registerNativeProvider(faux.provider);
    const registry = new RuntimeRegistry({
      agentDir,
      tronHome: join(root, "tron"),
      idleRuntimeMs: 60_000,
      modelRuntimeFactory: async () => runtime,
      trust: new TrustService(agentDir),
      broadcast: () => {},
      sessionSummaryChanged: () => {},
      sessionListChanged: () => {},
    });
    registries.push(registry);
    await initializeRegistry(registry);
    const slot = await registry.create(cwd);
    const model = faux.getModel();
    await slot.setModel(model.provider, model.id);

    const attention = (registry as unknown as {
      attention: { complete: (sessionId: string, completionId: string) => Promise<unknown> };
    }).attention;
    const originalComplete = attention.complete.bind(attention);
    vi.spyOn(attention, "complete").mockImplementation(async (...args) => {
      await attentionBarrier;
      return originalComplete(...args);
    });
    // This lifecycle-only record has no public projection. Inspect private
    // state rather than adding a production accessor for the regression.
    const slotInternals = slot as unknown as { operationObservations: Map<string, unknown> };

    const initial = slot.prompt("initial");
    await waitFor(() => slot.snapshot().phase === "running", "the initial run");
    const initialOperationId = slot.snapshot().operation?.id;
    expect(initialOperationId).toBeTruthy();
    const queued = await slot.prompt("queued follow-up", [], "followUp");
    const manager = (slot as unknown as { runtime: { session: { sessionManager: SessionManager } } }).runtime.session.sessionManager;
    const append = manager.appendCustomEntry.bind(manager);
    let failed = false;
    const receiptAppend = vi.spyOn(manager, "appendCustomEntry").mockImplementation((customType, data) => {
      const receipt = data as { receiptKind?: unknown; operationId?: unknown } | undefined;
      if (appendOutcome === "pre-staging append failure" && !failed && customType === INVOCATION_RECEIPT_TYPE
        && receipt?.receiptKind === "terminal" && receipt?.operationId === initialOperationId) {
        failed = true;
        throw new Error("injected pre-staging terminal receipt failure");
      }
      return append(customType, data);
    });
    releaseInitial();
    try {
      await followUpStart;
      // Canonical receipt ordering cannot depend on the delayed attention store:
      // ownership transfer settles the predecessor before the next input appends.
      const entries = slot.canonicalSessionEntries();
      const completionIndex = entries.findIndex(entry => entry.type === "message"
        && entry.message.role === "assistant" && contentText(entry.message.content).includes("initial complete"));
      expect(completionIndex).toBeGreaterThanOrEqual(0);
      const followUpIndex = entries.findIndex(entry => entry.type === "message" && entry.message.role === "user"
        && contentText(entry.message.content).includes("queued follow-up"));
      if (appendOutcome === "pre-staging append failure") expect(failed).toBe(true);
      // Transfer ends the predecessor, not completion admission. The next
      // canonical input must wait even when its receipt needs a bounded retry.
      expect(entries[completionIndex + 1]).toMatchObject({
        type: "custom",
        customType: INVOCATION_RECEIPT_TYPE,
        data: { receiptKind: "terminal", operationId: initialOperationId, lifecycle: "completed" },
      });
      expect(followUpIndex).toBeGreaterThan(completionIndex + 1);
    } catch (error) {
      releaseAttention();
      throw error;
    } finally {
      releaseFollowUp();
    }
    await waitFor(() => faux.state.callCount === 2, "both successful model responses");
    await initial;
    releaseAttention();
    await waitFor(() => !slot.isBusy, "both operations to settle");

    receiptAppend.mockRestore();
    const persisted = (await readFile(manager.getSessionFile()!, "utf8")).trim().split("\n")
      .map(line => JSON.parse(line));
    const terminalEntries = persisted.filter(entry => entry.type === "custom" && entry.customType === INVOCATION_RECEIPT_TYPE
      && entry.data?.receiptKind === "terminal" && entry.data?.operationId === initialOperationId);
    expect(terminalEntries).toHaveLength(1);
    expect(terminalEntries[0].data).toMatchObject({ lifecycle: "completed" });
    expect(slotInternals.operationObservations.has(initialOperationId!)).toBe(false);
    expect(slotInternals.operationObservations.has(queued.operationId)).toBe(false);
    expect(slotInternals.operationObservations.size).toBe(0);
  });

  it("retires a steered operation observation when a successful queued follow-up takes ownership", async () => {
    const root = await mkdtemp(join(tmpdir(), "tron-steering-follow-up-observation-retirement-"));
    onTestFinished(() => rm(root, { recursive: true, force: true }));
    const agentDir = join(root, "agent");
    const cwd = join(root, "workspace");
    await Promise.all([mkdir(agentDir), mkdir(cwd)]);
    let releaseInitial!: () => void;
    let releaseSteering!: () => void;
    let initialStarted!: () => void;
    let steeringStarted!: () => void;
    let followUpStarted!: () => void;
    const initialBarrier = new Promise<void>((resolve) => { releaseInitial = resolve; });
    const steeringBarrier = new Promise<void>((resolve) => { releaseSteering = resolve; });
    const initialStart = new Promise<void>((resolve) => { initialStarted = resolve; });
    const steeringStart = new Promise<void>((resolve) => { steeringStarted = resolve; });
    const followUpStart = new Promise<void>((resolve) => { followUpStarted = resolve; });
    onTestFinished(() => {
      releaseInitial();
      releaseSteering();
    });
    const faux = fauxProvider({ provider: "tron-steering-follow-up-observation-retirement", tokensPerSecond: 10_000 });
    faux.setResponses([
      async () => {
        initialStarted();
        await initialBarrier;
        return fauxAssistantMessage("initial complete");
      },
      async () => {
        steeringStarted();
        await steeringBarrier;
        return fauxAssistantMessage("steering complete");
      },
      async () => {
        followUpStarted();
        return fauxAssistantMessage("follow-up complete");
      },
    ]);
    const runtime = await ModelRuntime.create({ modelsPath: null, refreshOnCreate: false });
    runtime.registerNativeProvider(faux.provider);
    const registry = new RuntimeRegistry({
      agentDir,
      tronHome: join(root, "tron"),
      idleRuntimeMs: 60_000,
      modelRuntimeFactory: async () => runtime,
      trust: new TrustService(agentDir),
      broadcast: () => {},
      sessionSummaryChanged: () => {},
      sessionListChanged: () => {},
    });
    registries.push(registry);
    const admissions: any[] = [];
    registry.setKnowledgeService(new KnowledgeService(new KnowledgeStore(registry.knowledgeWorkspace()), {
      admit(cut: any) { admissions.push(structuredClone(cut)); },
      dispose() {},
    } as any));
    await initializeRegistry(registry);
    const slot = await registry.create(cwd);
    const model = faux.getModel();
    await slot.setModel(model.provider, model.id);
    const slotInternals = slot as unknown as { operationObservations: Map<string, unknown> };

    const initial = slot.prompt("initial");
    await waitFor(() => slot.snapshot().phase === "running", "the initial run");
    const initialOperationId = slot.snapshot().operation?.id;
    expect(initialOperationId).toBeTruthy();
    // The steer must arrive after the first model call has started. A steer
    // accepted before that call is folded into its context and no steering turn
    // runs, which is what the phase poll alone allowed under load.
    await initialStart;
    const steer = await slot.prompt("steer during foreground run", [], "steer");
    releaseInitial();
    await steeringStart;
    const initialCompletion = slot.canonicalSessionEntries().find(entry =>
      entry.type === "message" && entry.message.role === "assistant"
        && contentText(entry.message.content).includes("initial complete"));
    expect(initialCompletion?.type).toBe("message");
    await waitFor(() => admissions.some(cut => cut.completionId === initialCompletion!.id), "the initial completion observation");
    expect(slotInternals.operationObservations.has(initialOperationId!)).toBe(true);

    const queuedFollowUp = await slot.prompt("queued successful follow-up", [], "followUp");
    releaseSteering();
    await followUpStart;
    await waitFor(() => !slot.isBusy, "the steering and queued follow-up to settle");
    await initial;

    const steeringCompletion = slot.canonicalSessionEntries().find(entry =>
      entry.type === "message" && entry.message.role === "assistant"
        && contentText(entry.message.content).includes("steering complete"));
    const followUpCompletion = slot.canonicalSessionEntries().find(entry =>
      entry.type === "message" && entry.message.role === "assistant"
        && contentText(entry.message.content).includes("follow-up complete"));
    expect(steeringCompletion?.type).toBe("message");
    expect(followUpCompletion?.type).toBe("message");
    await waitFor(() => admissions.some(cut => cut.completionId === followUpCompletion!.id), "the follow-up completion observation");
    const initialCut = admissions.filter(cut => cut.completionId === initialCompletion!.id);
    const steeringCut = admissions.filter(cut => cut.completionId === steeringCompletion!.id);
    const followUpCut = admissions.filter(cut => cut.completionId === followUpCompletion!.id);
    expect(initialCut).toHaveLength(1);
    expect(steeringCut).toHaveLength(1);
    expect(followUpCut).toHaveLength(1);
    expect(initialCut[0].entries.some((entry: any) => entry.type === "message"
      && entry.message.role === "assistant" && contentText(entry.message.content).includes("initial complete"))).toBe(true);
    expect(steeringCut[0].entries.some((entry: any) => entry.type === "message"
      && entry.message.role === "assistant" && contentText(entry.message.content).includes("steering complete"))).toBe(true);
    expect(steeringCut[0].entries.some((entry: any) => entry.type === "message"
      && entry.message.role === "assistant" && contentText(entry.message.content).includes("initial complete"))).toBe(false);
    expect(followUpCut[0].entries.some((entry: any) => entry.type === "message"
      && entry.message.role === "assistant" && contentText(entry.message.content).includes("follow-up complete"))).toBe(true);
    expect(admissions.filter(cut => [initialCompletion!.id, steeringCompletion!.id, followUpCompletion!.id]
      .includes(cut.completionId))).toHaveLength(3);
    expect(slotInternals.operationObservations.has(initialOperationId!)).toBe(false);
    expect(slotInternals.operationObservations.has(steer.operationId)).toBe(false);
    expect(slotInternals.operationObservations.has(queuedFollowUp.operationId)).toBe(false);
    expect(slotInternals.operationObservations.size).toBe(0);
  });

  it("settles a reply before the queued follow-up runs so steering remains admissible", async () => {
    const root = await mkdtemp(join(tmpdir(), "tron-follow-up-steering-settlement-"));
    const agentDir = join(root, "agent");
    const cwd = join(root, "workspace");
    await Promise.all([mkdir(agentDir), mkdir(cwd)]);
    let releaseInitial!: () => void;
    let releaseFollowUp!: () => void;
    let followUpStarted!: () => void;
    const initialBarrier = new Promise<void>((resolve) => { releaseInitial = resolve; });
    const followUpBarrier = new Promise<void>((resolve) => { releaseFollowUp = resolve; });
    onTestFinished(() => releaseFollowUp());
    const followUpStart = new Promise<void>((resolve) => { followUpStarted = resolve; });
    const faux = fauxProvider({ provider: "tron-follow-up-steering-settlement", tokensPerSecond: 10_000 });
    faux.setResponses([
      async () => {
        await initialBarrier;
        return fauxAssistantMessage("initial complete");
      },
      async () => {
        followUpStarted();
        await followUpBarrier;
        return fauxAssistantMessage("follow-up complete");
      },
      fauxAssistantMessage("steering complete"),
    ]);
    const runtime = await ModelRuntime.create({ modelsPath: null, refreshOnCreate: false });
    runtime.registerNativeProvider(faux.provider);
    const registry = new RuntimeRegistry({
      agentDir,
      tronHome: join(root, "tron"),
      idleRuntimeMs: 60_000,
      modelRuntimeFactory: async () => runtime,
      trust: new TrustService(agentDir),
      broadcast: () => {},
      sessionSummaryChanged: () => {},
      sessionListChanged: () => {},
    });
    registries.push(registry);
    await initializeRegistry(registry);
    const slot = await registry.create(cwd);
    const model = faux.getModel();
    await slot.setModel(model.provider, model.id);

    const initial = slot.prompt("initial");
    await waitFor(() => slot.snapshot().phase === "running", "the initial run");
    const initialOperationId = slot.snapshot().operation?.id;
    expect(initialOperationId).toBeTruthy();
    const queuedFollowUp = await slot.prompt("queued follow-up", [], "followUp");
    releaseInitial();
    await followUpStart;

    let steer: { operationId: string };
    try {
      steer = await slot.prompt("steer during follow-up", [], "steer");
      expect(steer.operationId).toBeTruthy();
      expect(slot.snapshot().queuedItems).toEqual([
        expect.objectContaining({ id: steer.operationId, behavior: "steer" }),
      ]);
      await waitFor(() => invocationReceipts(slot.canonicalSessionEntries(), slot.id).some(receipt =>
        receipt.operationId === initialOperationId && receipt.receiptKind === "terminal" && receipt.lifecycle === "completed"),
      "the initial terminal receipt while the follow-up is active");
    } finally {
      releaseFollowUp();
    }
    await initial;
    await waitFor(() => !slot.isBusy, "the follow-up and accepted steer to settle");
    const entries = (await readFile(slot.sessionFile!, "utf8"))
      .trimEnd().split("\n").map(line => JSON.parse(line) as any);
    const queuedReceipt = entries
      .filter(entry => entry.customType === INVOCATION_RECEIPT_TYPE && entry.data?.operationId === queuedFollowUp.operationId)
      .map(entry => entry.data);
    expect(queuedReceipt.at(-1)).toMatchObject({ receiptKind: "terminal", lifecycle: "completed" });
    const steerReceipt = entries
      .filter(entry => entry.customType === INVOCATION_RECEIPT_TYPE && entry.data?.operationId === steer.operationId)
      .map(entry => entry.data);
    expect(steerReceipt.at(-1)).toMatchObject({ receiptKind: "terminal", lifecycle: "completed" });
    const artifactPath = join(process.cwd(), "test-results", "runtime-slot-follow-up-steering.json");
    await mkdir(dirname(artifactPath), { recursive: true });
    await writeFile(artifactPath, `${JSON.stringify({
      test: "queued follow-up then steer",
      transcript: entries.filter(entry => entry.type === "message"
        && (entry.message.role === "user" || entry.message.role === "assistant"))
        .map(entry => ({ role: entry.message.role, content: entry.message.content, stopReason: entry.message.stopReason })),
      receipts: entries.filter(entry => entry.customType === INVOCATION_RECEIPT_TYPE
        && [queuedFollowUp.operationId, steer.operationId].includes(entry.data?.operationId))
        .map(entry => entry.data),
    }, null, 2)}\n`);
  });

  it("orders a prompt behind a genuinely pending attention commit", async () => {
    const root = await mkdtemp(join(tmpdir(), "tron-attention-admission-order-"));
    const agentDir = join(root, "agent");
    const cwd = join(root, "workspace");
    await Promise.all([mkdir(agentDir), mkdir(cwd)]);
    let secondResponseStarted!: () => void;
    let attentionStarted!: () => void;
    let releaseAttention!: () => void;
    const secondStarted = new Promise<void>((resolve) => { secondResponseStarted = resolve; });
    const attentionEntered = new Promise<void>((resolve) => { attentionStarted = resolve; });
    const attentionBarrier = new Promise<void>((resolve) => { releaseAttention = resolve; });
    onTestFinished(() => releaseAttention());
    const faux = fauxProvider({ provider: "tron-attention-admission-order", tokensPerSecond: 10_000 });
    faux.setResponses([
      fauxAssistantMessage("first complete"),
      async () => {
        secondResponseStarted();
        return fauxAssistantMessage("second complete");
      },
    ]);
    const runtime = await ModelRuntime.create({ modelsPath: null, refreshOnCreate: false });
    runtime.registerNativeProvider(faux.provider);
    const registry = new RuntimeRegistry({
      agentDir,
      tronHome: join(root, "tron"),
      idleRuntimeMs: 60_000,
      modelRuntimeFactory: async () => runtime,
      trust: new TrustService(agentDir),
      broadcast: () => {},
      sessionSummaryChanged: () => {},
      sessionListChanged: () => {},
    });
    registries.push(registry);
    await initializeRegistry(registry);
    const slot = await registry.create(cwd);
    const model = faux.getModel();
    await slot.setModel(model.provider, model.id);
    const originalAttention = slot.hooks.assistantResponseCompleted.bind(slot.hooks);
    slot.hooks.assistantResponseCompleted = async (...args: any[]) => {
      attentionStarted();
      await attentionBarrier;
      return originalAttention(...args);
    };

    await slot.prompt("first");
    await attentionEntered;
    let secondSettled = false;
    const second = slot.prompt("ordered second", [], "steer").then(result => {
      secondSettled = true;
      return result;
    });
    await new Promise<void>((resolve) => setTimeout(resolve, 0));
    expect(secondSettled, "the newer command waits for the durable attention commit").toBe(false);
    releaseAttention();
    const accepted = await second;
    expect(accepted.operationId).toBeTruthy();
    await secondStarted;
    await waitFor(() => !slot.isBusy, "the second response and its settlement");
  });

  it("names the exact pending completion and age when attention blocks prompt admission", async () => {
    const fixture = await coldFixture("attention-pending-diagnostic");
    const slot = await fixture.registry.acquire(fixture.manager.getSessionId());
    const completion = {
      id: "canonical-completion-id",
      completedAt: new Date(Date.now() - 2_000).toISOString(),
      operationId: "pending-operation-id",
    };
    const rejectedBarrier = Promise.reject(new Error("injected blocked completion"));
    void rejectedBarrier.catch(() => {});
    const internal = slot as unknown as {
      attentionBarrier: Promise<void>;
      pendingAssistantCompletion: typeof completion;
    };
    internal.pendingAssistantCompletion = completion;
    internal.attentionBarrier = rejectedBarrier;

    const error = await slot.prompt("new prompt").then(() => undefined, value => value);
    expect(error).toMatchObject({
      code: "busy",
      diagnosticReason: "attention-pending",
      details: { reason: "attention-pending", operationId: "pending-operation-id", ageMs: expect.any(Number) },
    });
    expect(fixture.events.find(event => event.topic === "session.diagnostic")?.payload.data).toMatchObject({
      code: "attention-pending",
      operationId: "pending-operation-id",
      ageMs: expect.any(Number),
    });
  });

  it("binds duplicate consumed steering to each exact queue operation", async () => {
    const root = await mkdtemp(join(tmpdir(), "tron-steering-ownership-"));
    const agentDir = join(root, "agent");
    const cwd = join(root, "workspace");
    await Promise.all([mkdir(agentDir), mkdir(cwd)]);
    let releaseResponse!: () => void;
    let releaseSteeringResponse!: () => void;
    let steeringResponseStarted!: () => void;
    const responseBarrier = new Promise<void>((resolve) => { releaseResponse = resolve; });
    const steeringResponseBarrier = new Promise<void>((resolve) => { releaseSteeringResponse = resolve; });
    const steeringStarted = new Promise<void>((resolve) => { steeringResponseStarted = resolve; });
    const faux = fauxProvider({ provider: "tron-steering-ownership", tokensPerSecond: 10_000 });
    faux.setResponses([
      async () => {
        await responseBarrier;
        return fauxAssistantMessage("initial complete");
      },
      async () => {
        steeringResponseStarted();
        await steeringResponseBarrier;
        return fauxAssistantMessage("steering complete");
      },
    ]);
    const runtime = await ModelRuntime.create({ modelsPath: null, refreshOnCreate: false });
    runtime.registerNativeProvider(faux.provider);
    const registry = new RuntimeRegistry({
      agentDir,
      tronHome: join(root, "tron"),
      idleRuntimeMs: 60_000,
      modelRuntimeFactory: async () => runtime,
      trust: new TrustService(agentDir),
      broadcast: () => {},
      sessionSummaryChanged: () => {},
      sessionListChanged: () => {},
    });
    registries.push(registry);
    const admissions: any[] = [];
    registry.setKnowledgeService(new KnowledgeService(new KnowledgeStore(registry.knowledgeWorkspace()), {
      admit(cut: any) { admissions.push(structuredClone(cut)); },
      dispose() {},
    } as any));
    await initializeRegistry(registry);
    const slot = await registry.create(cwd);
    const model = faux.getModel();
    await slot.setModel(model.provider, model.id);

    const initial = slot.prompt("initial");
    await waitFor(() => slot.snapshot().phase === "running", "the running phase");
    const queued = await slot.prompt("steer me", [], "steer", {
      text: "steer me",
      attachmentEnvelope: "",
      attachmentCount: 0,
    });
    const duplicate = await slot.prompt("steer me", [], "steer", {
      text: "steer me",
      attachmentEnvelope: "",
      attachmentCount: 0,
    });
    expect(slot.snapshot().queuedItems).toEqual([
      expect.objectContaining({ id: queued.operationId, behavior: "steer", text: "steer me" }),
      expect.objectContaining({ id: duplicate.operationId, behavior: "steer", text: "steer me" }),
    ]);

    releaseResponse();
    await waitFor(() => [queued.operationId, duplicate.operationId].some(operationId =>
      slot.snapshot().transcript.some(item =>
        item.kind === "message" && item.role === "user" && item.presentationId === operationId,
      ),
    ), "one queued prompt projected");
    const steeringSnapshot = slot.snapshot();
    const consumedSteeringIDs = steeringSnapshot.transcript.flatMap((item) =>
      item.kind === "message" && item.role === "user"
        && [queued.operationId, duplicate.operationId].includes(item.presentationId ?? "")
        ? [item.presentationId!] : [],
    );
    expect(consumedSteeringIDs.length).toBeGreaterThan(0);
    expect(steeringSnapshot.activeToolSegmentId).toBe(toolSegmentId(consumedSteeringIDs.at(-1)!));
    await steeringStarted;
    const canonicalBeforeSteeringResponse = slot.canonicalSessionEntries();
    const firstCompletion = canonicalBeforeSteeringResponse.find(entry =>
      entry.type === "message" && entry.message.role === "assistant"
        && contentText(entry.message.content).includes("initial complete"));
    expect(firstCompletion?.type).toBe("message");
    await waitFor(() => admissions.some(cut => cut.completionId === firstCompletion!.id), "the first completion cut while the steering response is held");
    const firstCut = admissions.find(cut => cut.completionId === firstCompletion!.id)!;
    expect(firstCut.entries.some((entry: any) => entry.message?.role === "assistant"
      && contentText(entry.message.content).includes("initial complete"))).toBe(true);
    releaseSteeringResponse();
    await initial;
    await waitFor(() => [queued.operationId, duplicate.operationId].every(operationId =>
      slot.snapshot().transcript.some(item =>
        item.kind === "message" && item.role === "user" && item.presentationId === operationId,
      ),
    ), "both queued prompts projected");
    await waitFor(() => !slot.isBusy, "the slot to go idle");

    const entries = (await readFile(slot.sessionFile!, "utf8"))
      .trimEnd().split("\n").map(line => JSON.parse(line) as any);
    for (const operationId of [queued.operationId, duplicate.operationId]) {
      const receipts = entries
        .filter(entry => entry.customType === INVOCATION_RECEIPT_TYPE && entry.data?.operationId === operationId)
        .map(entry => entry.data);
      expect(receipts.map(receipt => receipt.receiptKind)).toEqual(["start", "transition", "binding", "terminal"]);
      expect(receipts.at(-1)).toMatchObject({ lifecycle: "completed" });
    }
    const finalCompletion = slot.canonicalSessionEntries().find(entry =>
      entry.type === "message" && entry.message.role === "assistant"
        && contentText(entry.message.content).includes("steering complete"));
    expect(finalCompletion?.type).toBe("message");
    await waitFor(() => admissions.some(cut => cut.completionId === finalCompletion!.id), "the final same-run completion cut");
    const finalCut = admissions.find(cut => cut.completionId === finalCompletion!.id)!;
    const observedMessages = finalCut.entries
      .filter((entry: any) => entry.type === "message")
      .map((entry: any) => `${entry.message.role}: ${contentText(entry.message.content)}`)
      .join("\n");
    expect(observedMessages).toContain("user: steer me");
    expect(observedMessages).toContain("steering complete");
    expect(observedMessages).not.toContain("initial complete");
    expect(admissions.filter(cut => cut.completionId === firstCompletion!.id)).toHaveLength(1);
    expect(admissions.filter(cut => cut.completionId === finalCompletion!.id)).toHaveLength(1);
    expect(slot.snapshot().queuedItems).toEqual([]);
  });

  it("reclassifies queued intent when Pi becomes idle inside an async input hook", async () => {
    const root = await mkdtemp(join(tmpdir(), "tron-queue-disposition-race-"));
    const agentDir = join(root, "agent");
    const cwd = join(root, "workspace");
    const extensionDir = join(cwd, ".pi", "extensions");
    const entered = join(root, "input-entered");
    const releaseInput = join(root, "release-input");
    await Promise.all([mkdir(agentDir), mkdir(extensionDir, { recursive: true })]);
    await writeFile(join(extensionDir, "delay-queued-input.ts"), `
      import { existsSync, writeFileSync } from "node:fs";
      export default function (pi) {
        pi.on("input", async (event) => {
          if (event.text !== "became ordinary") return;
          writeFileSync(${JSON.stringify(entered)}, "entered");
          while (!existsSync(${JSON.stringify(releaseInput)})) {
            await new Promise((resolve) => setTimeout(resolve, 5));
          }
        });
      }\n`);
    const trust = new TrustService(agentDir);
    await trust.set(cwd, true);
    let releaseResponse!: () => void;
    const responseBarrier = new Promise<void>((resolve) => { releaseResponse = resolve; });
    const faux = fauxProvider({ provider: "tron-queue-disposition-race", tokensPerSecond: 10_000 });
    faux.setResponses([
      async () => {
        await responseBarrier;
        return fauxAssistantMessage("initial complete");
      },
      fauxAssistantMessage("ordinary complete"),
    ]);
    const runtime = await ModelRuntime.create({ modelsPath: null, refreshOnCreate: false });
    runtime.registerNativeProvider(faux.provider);
    const registry = new RuntimeRegistry({
      agentDir,
      tronHome: join(root, "tron"),
      idleRuntimeMs: 60_000,
      modelRuntimeFactory: async () => runtime,
      trust,
      broadcast: () => {},
      sessionSummaryChanged: () => {},
      sessionListChanged: () => {},
    });
    registries.push(registry);
    await initializeRegistry(registry);
    const slot = await registry.create(cwd);
    const model = faux.getModel();
    await slot.setModel(model.provider, model.id);

    await slot.prompt("initial");
    await waitFor(() => slot.snapshot().acceptsQueuedPrompts, "the slot to accept queued prompts");
    const prompting = slot.prompt("became ordinary", [], "steer");
    await waitFor(() => existsSync(entered), "the entered marker file");
    releaseResponse();
    await waitFor(() => !slot.snapshot().acceptsQueuedPrompts, "the slot to stop accepting queued prompts");
    await writeFile(releaseInput, "release");

    const admitted = await prompting;
    await waitFor(() => slot.snapshot().transcript.some(item =>
      item.kind === "message" && item.role === "user" && item.presentationId === admitted.operationId,
    ), "the admitted prompt in the transcript");
    expect(slot.snapshot().queuedItems).toEqual([]);
    expect(slot.snapshot().pendingPrompt).toBeUndefined();
    const entries = (await readFile(slot.sessionFile!, "utf8"))
      .trimEnd().split("\n").map(line => JSON.parse(line) as any);
    const receipts = entries
      .filter(entry => entry.customType === INVOCATION_RECEIPT_TYPE && entry.data?.operationId === admitted.operationId)
      .map(entry => entry.data);
    expect(receipts.find(receipt => receipt.receiptKind === "transition")).toMatchObject({ lifecycle: "accepted" });
    expect(receipts.find(receipt => receipt.receiptKind === "binding")).toBeDefined();
    await waitFor(() => !slot.isBusy, "the slot to go idle");
  }, 15_000);

  it("settles a queued admission when the Pi call rejects before queue evidence", async () => {
    const fixture = await coldFixture("queue-disposition-rejection");
    const slot = await fixture.registry.acquire(fixture.manager.getSessionId());
    const internal = slot as unknown as {
      phase: "running" | "idle";
      activeOperationId?: string;
      operation?: { id?: string; kind: "prompt"; startedAt: string };
      pendingQueueAdmission?: unknown;
      runtime: { session: {
        readonly isStreaming: boolean;
        prompt: (text: string, options?: {
          streamingBehavior?: "steer" | "followUp";
          preflightResult?: (disposition: "handled" | "queued" | "started") => void;
        }) => Promise<void>;
        getSteeringMessages: () => readonly string[];
      } };
    };
    internal.phase = "running";
    internal.activeOperationId = "existing-operation";
    internal.operation = {
      id: "existing-operation", kind: "prompt", startedAt: new Date().toISOString(),
    };
    vi.spyOn(internal.runtime.session, "isStreaming", "get").mockReturnValue(true);
    vi.spyOn(internal.runtime.session, "getSteeringMessages").mockReturnValue([]);
    vi.spyOn(internal.runtime.session, "prompt").mockImplementationOnce(async (_text, options) => {
      expect(options?.streamingBehavior).toBe("steer");
      options?.preflightResult?.("started");
      throw new Error("queue admission failed");
    });

    await expect(slot.prompt("never queued", [], "steer")).rejects.toThrow("queue admission failed");
    expect(internal.pendingQueueAdmission).toBeUndefined();
    const entries = (await readFile(slot.sessionFile!, "utf8"))
      .trimEnd().split("\n").map(line => JSON.parse(line) as any);
    const starts = entries.filter(entry =>
      entry.customType === INVOCATION_RECEIPT_TYPE && entry.data?.receiptKind === "start",
    );
    const operationId = starts.at(-1)?.data.operationId;
    expect(operationId).toEqual(expect.any(String));
    expect(entries.find(entry =>
      entry.customType === INVOCATION_RECEIPT_TYPE
        && entry.data?.operationId === operationId
        && entry.data?.receiptKind === "terminal",
    )?.data).toMatchObject({ lifecycle: "failed", errorCode: "runtime-prompt-failed" });

    // The synthetic foreground owner belongs only to this test fixture.
    internal.phase = "idle";
    internal.activeOperationId = undefined;
    internal.operation = undefined;
  });

  it("fails an accepted prompt that rejects before creating agent or canonical work", async () => {
    const fixture = await coldFixture("accepted-prompt-rejection");
    const slot = await fixture.registry.acquire(fixture.manager.getSessionId());
    const session = (slot as unknown as {
      runtime: { session: { prompt: (
        text: string,
        options?: { preflightResult?: (disposition: "handled" | "queued" | "started") => void },
      ) => Promise<void> } };
    }).runtime.session;
    vi.spyOn(session, "prompt").mockImplementationOnce(async (_text, options) => {
      options?.preflightResult?.("started");
      throw new Error("accepted prompt failed");
    });

    const admitted = await slot.prompt("fails after acceptance");
    await waitFor(() => !slot.isBusy, "the slot to go idle");
    const entries = (slot as any).runtime.session.sessionManager.getEntries() as any[];
    const receipts = entries.filter(entry =>
      entry.customType === INVOCATION_RECEIPT_TYPE
        && entry.data?.operationId === admitted.operationId,
    ).map(entry => entry.data);
    expect(receipts.map(receipt => receipt.receiptKind)).toEqual(["start", "transition", "terminal"]);
    expect(receipts.at(-1)).toMatchObject({ lifecycle: "failed", errorCode: "runtime-prompt-failed" });
    expect(fixture.events).toContainEqual(expect.objectContaining({
      topic: "session.operationFailed",
      payload: expect.objectContaining({
        data: expect.objectContaining({ operationId: admitted.operationId }),
      }),
    }));
    expect(slot.snapshot()).toMatchObject({ phase: "idle" });
    expect(slot.snapshot().operation).toBeUndefined();
  });

  it("keeps ordinary prompt admission behind the Gateway settlement transition", async () => {
    const fixture = await coldFixture("prompt-settlement-admission");
    const slot = await fixture.registry.acquire(fixture.manager.getSessionId());
    const internal = slot as unknown as {
      phase: "running" | "idle";
      activeOperationId?: string;
      operation?: { id?: string; kind: "prompt"; startedAt: string };
      publishSnapshot: () => void;
      runtime: { session: { prompt: (
        text: string,
        options?: { preflightResult?: (disposition: "handled" | "queued" | "started") => void },
      ) => Promise<void> } };
    };
    internal.phase = "running";
    internal.activeOperationId = "settling-operation";
    internal.operation = {
      id: "settling-operation", kind: "prompt", startedAt: new Date().toISOString(),
    };
    let invoked = false;
    vi.spyOn(internal.runtime.session, "prompt").mockImplementationOnce(async (_text, options) => {
      invoked = true;
      options?.preflightResult?.("started");
    });

    const prompting = slot.prompt("after settlement");
    await Promise.resolve();
    expect(invoked).toBe(false);
    internal.phase = "idle";
    internal.activeOperationId = undefined;
    internal.operation = undefined;
    internal.publishSnapshot();

    await expect(prompting).resolves.toMatchObject({ operationId: expect.any(String) });
    expect(invoked).toBe(true);
  });

  it("does not retire a newer pending prompt for an older user message callback", async () => {
    const fixture = await coldFixture("pending-prompt-object-ownership");
    const slot = await fixture.registry.acquire(fixture.manager.getSessionId());
    const internal = slot as unknown as {
      pendingPrompt?: {
        id: string; createdAt: string; text: string; attachmentCount: number;
      };
      pendingPromptMessage?: unknown;
      onEvent: (event: unknown) => void;
    };
    const older = { role: "user", content: "same", timestamp: Date.now() };
    const newer = { role: "user", content: "same", timestamp: Date.now() + 1 };
    internal.pendingPrompt = {
      id: "older-operation", createdAt: new Date().toISOString(),
      text: "same", attachmentCount: 0,
    };
    internal.onEvent({ type: "message_start", message: older });
    internal.pendingPrompt = {
      id: "newer-operation", createdAt: new Date().toISOString(),
      text: "same", attachmentCount: 0,
    };
    internal.pendingPromptMessage = undefined;
    internal.onEvent({ type: "message_start", message: newer });
    internal.onEvent({ type: "message_end", message: older });
    expect(internal.pendingPrompt?.id).toBe("newer-operation");
    expect(internal.pendingPromptMessage).toBe(newer);
  });

  it("authorizes display artifacts only from the exact active canonical branch", async () => {
    const fixture = await coldFixture("active-display-artifact-branch");
    await fixture.registry.initializeBlobStorage();
    const store = (fixture.registry as unknown as { displayArtifacts: {
      ingest: (cwd: string, path: string, sessionID: string) => Promise<{
        id: string; name: string; mimeType: string; size: number; kind: string;
      }>;
    } }).displayArtifacts;
    const png = Buffer.concat([
      Buffer.from([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a]),
      Buffer.from("payload"),
    ]);
    await writeFile(join(fixture.cwd, "abandoned.png"), png);
    await writeFile(join(fixture.cwd, "active.png"), Buffer.concat([png, Buffer.from("active")]));
    const abandoned = await store.ingest(fixture.cwd, "abandoned.png", fixture.manager.getSessionId());
    const active = await store.ingest(fixture.cwd, "active.png", fixture.manager.getSessionId());
    fixture.manager.appendMessage({ role: "user", content: "root prompt", timestamp: Date.now() });
    const rootEntry = fixture.manager.getEntries().at(-1)!;
    const result = (toolCallId: string, artifact: typeof active) => ({
      role: "toolResult" as const,
      toolCallId,
      toolName: "display",
      isError: false,
      timestamp: Date.now(),
      content: [{ type: "text" as const, text: "Displayed." }],
      details: { display: {
        schema: "tron.display.v1",
        displayId: `${toolCallId}-display`,
        revision: 1,
        title: "Preview",
        altText: "Preview image.",
        kind: "image",
        presentation: { requestedSurface: "sheet", inlineTapAction: "sheet" },
        eligibleSurfaces: ["sheet", "inline", "floating"],
        fallbackText: "Preview image.",
        artifact: {
          id: artifact.id,
          name: artifact.name,
          mimeType: artifact.mimeType,
          size: artifact.size,
          kind: artifact.kind,
        },
      } },
    });
    fixture.manager.appendMessage(result("abandoned", abandoned));
    fixture.manager.branch(rootEntry.id);
    fixture.manager.appendMessage(result("active", active));

    const slot = await fixture.registry.acquire(fixture.manager.getSessionId());
    expect(slot.displayArtifactIDs()).toEqual([active.id]);
    expect(slot.referencesDisplayArtifact(abandoned.id)).toBe(false);
    expect(slot.referencesDisplayArtifact(active.id)).toBe(true);
    await expect(fixture.registry.acquireDisplayArtifact(
      fixture.manager.getSessionId(),
      abandoned.id,
    )).rejects.toMatchObject({ code: "not_found" });
    const lease = await fixture.registry.acquireDisplayArtifact(
      fixture.manager.getSessionId(),
      active.id,
    );
    expect(await collectStream(lease.stream)).toEqual(Buffer.concat([png, Buffer.from("active")]));
    await lease.release();
  });

  it.each(["browser_live", "native_live"])("authorizes %s views only from admitted display results on the exact canonical branch", async (kind) => {
    const fixture = await coldFixture("active-live-display-branch");
    fixture.manager.appendMessage({ role: "user", content: "root", timestamp: Date.now() });
    const root = fixture.manager.getEntries().at(-1)!;
    const result = (viewId: string, toolName = "display") => ({
      role: "toolResult" as const, toolCallId: viewId, toolName, isError: false, timestamp: Date.now(),
      content: [{ type: "text" as const, text: "Displayed" }],
      details: { display: { schema: "tron.display.v1", displayId: viewId, revision: 1,
        title: "Window", altText: "Window", kind,
        presentation: { requestedSurface: "sheet", inlineTapAction: "sheet" },
        eligibleSurfaces: ["sheet", "floating"], fallbackText: "Unavailable",
        liveView: { schema: kind === "native_live" ? "tron.native-live-view.v1" : "tron.browser-live-view.v1", viewId, generation: "generation",
          title: "Browser", fallbackText: "Unavailable" } } },
    });
    fixture.manager.appendMessage(result("abandoned"));
    fixture.manager.branch(root.id);
    fixture.manager.appendMessage(result("spoof", "other-tool"));
    fixture.manager.appendMessage(result("active"));
    const slot = await fixture.registry.acquire(fixture.manager.getSessionId());
    expect(slot.referencesBrowserLiveView("abandoned", "generation")).toBe(false);
    expect(slot.referencesBrowserLiveView("spoof", "generation")).toBe(false);
    expect(slot.referencesBrowserLiveView("active", "wrong-generation")).toBe(false);
    expect(slot.referencesBrowserLiveView("active", "generation")).toBe(true);
    expect(fixture.registry.authorizeBrowserLiveView(fixture.manager.getSessionId(), "active", "generation")).toBe(true);
  });

  it("authorizes provider-bound browser actions only on their admitted call and canonical branch", async () => {
    const fixture = await coldFixture("browser-action-branch");
    fixture.manager.appendMessage({ role: "user", content: "root", timestamp: Date.now() });
    const root = fixture.manager.getEntries().at(-1)!;
    const result = (id: string, sessionId = fixture.manager.getSessionId()) => ({
      role: "toolResult" as const, toolCallId: id, toolName: "agent_browser", isError: false, timestamp: Date.now(),
      content: [{ type: "text" as const, text: "clicked" }],
      details: { tronBrowserReference: sealBrowserToolReference(sessionId, id, {
        schema: "tron.browser-live-view.v1", viewId: id, generation: "generation", title: "Browser", fallbackText: "Unavailable",
      }, true) },
    });
    fixture.manager.appendMessage(result("abandoned"));
    fixture.manager.branch(root.id);
    fixture.manager.appendMessage({ ...result("copied"), toolCallId: "wrong-call" });
    fixture.manager.appendMessage(result("wrong-session", "other-session"));
    fixture.manager.appendMessage(result("active"));
    const slot = await fixture.registry.acquire(fixture.manager.getSessionId());
    for (const id of ["abandoned", "copied", "wrong-session"]) {
      expect(slot.referencesBrowserLiveView(id, "generation")).toBe(false);
    }
    expect(slot.referencesBrowserLiveView("active", "generation")).toBe(true);
    expect(slot.referencesBrowserLiveView("active", "wrong-generation")).toBe(false);
    const transcript = slot.snapshot().transcript;
    const projected = (callId: string) => transcript.find(item => item.kind === "message" && item.toolCallId === callId);
    expect(projected("active")).toHaveProperty("display.kind", "browser_live");
    expect(projected("wrong-session")).not.toHaveProperty("display");
    expect(projected("wrong-call")).not.toHaveProperty("display");
  });

  it("exports the complete canonical JSONL tree including abandoned branches", async () => {
    const fixture = await coldFixture("complete-jsonl-export");
    await fixture.registry.initializeBlobStorage();
    fixture.manager.appendMessage({ role: "user", content: "root prompt", timestamp: Date.now() });
    const rootEntry = fixture.manager.getEntries().at(-1)!;
    fixture.manager.appendMessage(fauxAssistantMessage("abandoned branch response"));
    const abandonedEntry = fixture.manager.getEntries().at(-1)!;
    fixture.manager.branch(rootEntry.id);
    fixture.manager.appendMessage(fauxAssistantMessage("active branch response"));
    const activeEntry = fixture.manager.getEntries().at(-1)!;

    const slot = await fixture.registry.acquire(fixture.manager.getSessionId());
    const artifact = await slot.export("jsonl");
    const lease = await fixture.registry.acquireBlob(artifact.blobId);
    let exported = "";
    try {
      for await (const chunk of lease.stream) exported += Buffer.from(chunk).toString("utf8");
    } finally {
      await lease.release();
    }

    const lines = exported.trimEnd().split("\n").map((line) => JSON.parse(line) as {
      id?: string;
      parentId?: string | null;
    });
    expect(lines.some((entry) => entry.id === abandonedEntry.id && entry.parentId === rootEntry.id)).toBe(true);
    expect(lines.some((entry) => entry.id === activeEntry.id && entry.parentId === rootEntry.id)).toBe(true);
    expect(exported).toContain("abandoned branch response");
    expect(exported).toContain("active branch response");
  });

  it("round-trips canonical context edits through Gateway JSONL export/import without a chat row", async () => {
    const fixture = await coldFixture("context-edit-jsonl-roundtrip");
    await fixture.registry.initializeBlobStorage();
    const prompt = fixture.manager.appendMessage({ role: "user", content: "Original authored prompt", timestamp: Date.now() });
    const edit = fixture.manager.appendContextEdit(prompt, { content: "Replacement model context" });
    const slot = await fixture.registry.acquire(fixture.manager.getSessionId());
    const exportedArtifact = await slot.export("jsonl");
    const lease = await fixture.registry.acquireBlob(exportedArtifact.blobId);
    let exported = "";
    try {
      for await (const chunk of lease.stream) exported += Buffer.from(chunk).toString("utf8");
    } finally {
      await lease.release();
    }
    const records = exported.trimEnd().split("\n").map(line => JSON.parse(line) as Record<string, unknown>);
    expect(records.some(entry => entry.type === "context_edit" && entry.id === edit
      && (entry.replacement as { content?: string })?.content === "Replacement model context")).toBe(true);
    const importPath = join(fixture.root, "context-edit-export.jsonl");
    await writeFile(importPath, exported);
    const sourceId = slot.id;
    const sourceEntries = fixture.manager.getBranch().map(entry => ({ id: entry.id, parentId: entry.parentId }));
    const imported = await fixture.registry.importFromJsonl(importPath, fixture.cwd);
    const importedAgain = await fixture.registry.importFromJsonl(importPath, fixture.cwd);
    expect(imported.id).not.toBe(sourceId);
    expect(importedAgain.id).not.toBe(sourceId);
    expect(importedAgain.id).not.toBe(imported.id);
    expect((await fixture.registry.acquire(sourceId)).id).toBe(sourceId);
    for (const importedSlot of [imported, importedAgain]) {
      const manager = (importedSlot as unknown as { sessionManager: SessionManager }).sessionManager;
      expect(manager.getBranch().some(entry => entry.type === "context_edit" && entry.targetId === prompt)).toBe(true);
      expect(manager.getBranch().slice(0, sourceEntries.length).map(entry => ({ id: entry.id, parentId: entry.parentId }))).toEqual(sourceEntries);
      expect(manager.buildSessionContext().messages.filter(message => message.role === "user").map(message =>
        message.role === "user" ? message.content : "")).toEqual(["Replacement model context"]);
      expect(importedSlot.snapshot().transcript.filter(item => item.role === "user")).toMatchObject([
        { content: [{ type: "text", text: "Original authored prompt" }] },
      ]);
      expect(importedSlot.snapshot().transcript.some(item => item.id === edit)).toBe(false);
    }
    const sessionRoot = join(fixture.agentDir, "sessions");
    const beforeFailure = (await readdir(sessionRoot, { recursive: true })).sort();
    vi.spyOn(fixture.registry as any, "dependencies").mockImplementationOnce(() => {
      throw new Error("injected import runtime setup failure");
    });
    await expect(fixture.registry.importFromJsonl(importPath, fixture.cwd)).rejects.toThrow("injected import runtime setup failure");
    expect((await readdir(sessionRoot, { recursive: true })).sort()).toEqual(beforeFailure);

    const importedFiles = [imported, importedAgain].map(importedSlot => importedSlot.sessionFile!);
    await Promise.all([imported.dispose(), importedAgain.dispose()]);
    await rm(importPath);
    for (const importedFile of importedFiles) {
      const reopened = SessionManager.open(importedFile, dirname(importedFile), fixture.cwd);
      expect(reopened.getHeader().parentSession).toBe(importPath);
      expect(reopened.buildSessionContext().messages.filter(message => message.role === "user").map(message =>
        message.role === "user" ? message.content : "")).toEqual(["Replacement model context"]);
      expect(reopened.getBranch().some(entry => entry.type === "context_edit" && entry.targetId === prompt)).toBe(true);
    }
  });

  it("exports a committed JSONL cut while the live session phase is running", async () => {
    const fixture = await coldFixture("active-jsonl-export");
    await fixture.registry.initializeBlobStorage();
    fixture.manager.appendMessage({ role: "user", content: "committed before export", timestamp: Date.now() });
    fixture.manager.appendMessage(fauxAssistantMessage("committed response"));
    const slot = await fixture.registry.acquire(fixture.manager.getSessionId());
    const internal = slot as unknown as { phase: "running" | "idle" };
    internal.phase = "running";
    try {
      const artifact = await slot.export("jsonl");
      expect(artifact.size).toBeGreaterThan(0);
      const lease = await fixture.registry.acquireBlob(artifact.blobId);
      let exported = "";
      try {
        for await (const chunk of lease.stream) exported += Buffer.from(chunk).toString("utf8");
      } finally {
        await lease.release();
      }
      expect(exported).toContain("committed before export");
      expect(exported).toContain("committed response");
      expect(exported.endsWith("\n")).toBe(true);
    } finally {
      internal.phase = "idle";
    }
  });

  it("fails closed instead of projecting over an existing empty canonical file", async () => {
    const fixture = await coldFixture("empty-canonical-export");
    await fixture.registry.initializeBlobStorage();
    const source = fixture.manager.getSessionFile();
    expect(source).toBeDefined();
    const slot = await fixture.registry.acquire(fixture.manager.getSessionId());
    await writeFile(source!, "");
    await expect(slot.export("jsonl")).rejects.toMatchObject({
      code: "conflict",
      message: expect.stringContaining("empty"),
    });
  });

  it("renders HTML from an immutable cut without requiring the live session to become idle", async () => {
    const fixture = await coldFixture("active-html-export");
    await fixture.registry.initializeBlobStorage();
    const branchRoot = fixture.manager.getEntries().at(-1)!;
    fixture.manager.appendMessage(fauxAssistantMessage("abandoned html branch"));
    fixture.manager.branch(branchRoot.id);
    fixture.manager.appendMessage({ role: "user", content: "html snapshot marker", timestamp: Date.now() });
    fixture.manager.appendMessage({ role: "custom_message", customType: "hidden-export-marker", content: "hidden custom export marker", display: false, timestamp: Date.now() });
    fixture.manager.appendMessage(fauxAssistantMessage("html snapshot response"));
    const slot = await fixture.registry.acquire(fixture.manager.getSessionId());
    const internal = slot as unknown as { phase: "running" | "idle" };
    internal.phase = "running";
    try {
      const artifact = await slot.export("html");
      expect(artifact.mimeType).toContain("text/html");
      const lease = await fixture.registry.acquireBlob(artifact.blobId);
      let exported = "";
      try {
        for await (const chunk of lease.stream) exported += Buffer.from(chunk).toString("utf8");
      } finally {
        await lease.release();
      }
      expect(exported).toContain("<!DOCTYPE html>");
      expect(Buffer.byteLength(exported)).toBe(artifact.size);
      const encoded = exported.match(/<script id="session-data" type="application\/json">([^<]+)<\/script>/)?.[1];
      expect(encoded).toBeDefined();
      const sessionData = Buffer.from(encoded!, "base64").toString("utf8");
      expect(sessionData).toContain("html snapshot marker");
      expect(sessionData).toContain("html snapshot response");
      expect(sessionData).toContain("hidden custom export marker");
      expect(exported).toContain("const hidden = entry.display === false");
      expect(exported).toContain("hook-message-hidden");
      expect(exported).toContain("Hidden in terminal");
      expect(sessionData).not.toContain("abandoned html branch");
      const artifactPath = join(process.cwd(), "test-results", "pi-sdk-099-html-export.json");
      await mkdir(dirname(artifactPath), { recursive: true });
      await writeFile(artifactPath, `${JSON.stringify({ format: "html", mimeType: artifact.mimeType, size: artifact.size, visibleMarkers: ["html snapshot marker", "html snapshot response"], hiddenMarkerRenderedHidden: exported.includes('class="hook-message hook-message-hidden"'), abandonedBranchOmitted: !sessionData.includes("abandoned html branch") }, null, 2)}\n`);
    } finally {
      internal.phase = "idle";
    }
  }, 30_000);

  it("keeps session exports independent from the 25 MiB transient media item limit", async () => {
    const fixture = await coldFixture("large-jsonl-export");
    await fixture.registry.initializeBlobStorage();
    fixture.manager.appendCustomEntry("large-export-fixture", {
      payload: "x".repeat(26 * 1_024 * 1_024),
    });
    const slot = await fixture.registry.acquire(fixture.manager.getSessionId());
    const artifact = await slot.export("jsonl");
    expect(artifact.size).toBeGreaterThan(25 * 1_024 * 1_024);
    const lease = await fixture.registry.acquireBlob(artifact.blobId);
    let bytes = 0;
    try {
      for await (const chunk of lease.stream) bytes += Buffer.byteLength(chunk);
    } finally {
      await lease.release();
    }
    expect(bytes).toBe(artifact.size);
  }, 30_000);

  it("routes virtual models across resume, fork, retry and compaction in a RuntimeRegistry session", async () => {
    const fixture = await coldFixture("virtual-model-lifecycle");
    const provider = "tron-p99-virtual-lifecycle";
    await mkdir(join(fixture.cwd, ".pi", "extensions"), { recursive: true });
    await writeFile(join(fixture.cwd, ".pi", "extensions", "virtual-router.ts"), `
      export default function (pi) {
        pi.registerVirtualModel({
          provider: ${JSON.stringify(provider)}, id: "router", name: "Fixture router", contextWindow: 1,
          route(request, ctx) {
            const routeCount = request.state?.routeCount ?? 0;
            const useWide = request.reason === "direct" || Boolean(request.failed) || routeCount % 2 === 1;
            const physical = ctx.modelRegistry.find(${JSON.stringify(provider)}, useWide ? "wide" : "small");
            return { model: physical, thinkingLevel: useWide ? "high" : "low",
              state: { routeCount: routeCount + 1, lastReason: request.reason, lastModel: physical.id, failed: Boolean(request.failed) } };
          },
        });
      }
    `);
    await new TrustService(fixture.agentDir).set(fixture.cwd, true);
    await writeFile(join(fixture.agentDir, "settings.json"), JSON.stringify({ retry: { enabled: true, maxRetries: 2, baseDelayMs: 1 }, compaction: { enabled: false, keepRecentTokens: 1 } }));
    const faux = fauxProvider({ provider, tokensPerSecond: 10_000, models: [
      { id: "small", name: "Small physical", reasoning: true, input: ["text"], contextWindow: 4096, maxTokens: 1024, cost: { input: 1, output: 2, cacheRead: 0, cacheWrite: 0 } },
      { id: "wide", name: "Wide physical", reasoning: true, input: ["text"], contextWindow: 16384, maxTokens: 2048, cost: { input: 3, output: 4, cacheRead: 0, cacheWrite: 0 } },
    ] });
    const responseModels: string[] = [];
    const response = (text: string) => (_context: unknown, _options: unknown, _state: unknown, model: any) => {
      responseModels.push(model.id);
      return fauxAssistantMessage(text, { provider: model.provider, model: model.id });
    };
    faux.setResponses([
      fauxAssistantMessage("", { stopReason: "error", errorMessage: "fetch failed" }),
      response("retried on physical wide"),
      response("continued on physical small"),
      response("alternate physical wide"),
      response("compact summary on physical wide"),
      response("after compaction on virtual"),
      ...Array.from({ length: 5 }, (_, index) => response(`post-compaction continuation ${index + 1}`)),
    ]);
    const modelRuntime = await ModelRuntime.create({ modelsPath: null, refreshOnCreate: false });
    modelRuntime.registerNativeProvider(faux.provider);
    fixture.runtimeFactory.mockResolvedValue(modelRuntime);
    let slot = await fixture.registry.acquire(fixture.manager.getSessionId());
    await slot.setModel(provider, "router");
    await slot.prompt("trigger automatic retry");
    await waitFor(() => !slot!.isBusy, "the slot to go idle");
    const retried = slot.snapshot().transcript.filter((item) => item.kind === "message" && item.role === "assistant");
    expect(retried.at(-1)).toMatchObject({ provider, modelId: "wide", thinkingLevel: "high" });
    expect(faux.state.callCount).toBe(2);

    const branchEntries = slot.runtime.session.sessionManager.getBranch();
    expect(branchEntries.some((entry: any) => entry.type === "custom" && entry.customType === "pi.virtual-model-state")).toBe(true);
    const userEntry = slot.history(slot.snapshot().runtimeGeneration).nodes.find((node: any) => node.role === "user");
    expect(userEntry).toBeDefined();
    await fixture.registry.dispose();
    registries.splice(registries.indexOf(fixture.registry), 1);
    const resumedRegistry = new RuntimeRegistry({
      agentDir: fixture.agentDir, tronHome: join(fixture.root, "tron"), idleRuntimeMs: 60_000,
      modelRuntimeFactory: async () => { const runtime = await ModelRuntime.create({ modelsPath: null, refreshOnCreate: false }); runtime.registerNativeProvider(faux.provider); return runtime; },
      trust: new TrustService(fixture.agentDir), broadcast: () => {}, sessionSummaryChanged: () => {}, sessionListChanged: () => {},
    });
    registries.push(resumedRegistry);
    await initializeRegistry(resumedRegistry);
    slot = await resumedRegistry.acquire(fixture.manager.getSessionId());
    expect(slot.runtime.session.model?.id).toBe("router");
    expect(slot.snapshot().transcript.some((item) => item.kind === "message" && item.role === "assistant" && item.provider === provider && item.modelId === "wide" && item.thinkingLevel === "high")).toBe(true);
    expect(slot.runtime.session.sessionManager.getBranch().some((entry: any) => entry.type === "custom" && entry.customType === "pi.virtual-model-state")).toBe(true);
    const restoredState = slot.runtime.session.sessionManager.getBranch().filter((entry: any) => entry.type === "custom" && entry.customType === "pi.virtual-model-state");
    expect(restoredState.length).toBeGreaterThan(0);
    expect(restoredState.at(-1)).toMatchObject({ data: { state: { routeCount: 2, lastReason: "retry", lastModel: "wide", failed: true } } });

    const forkPoint = slot.runtime.session.sessionManager.getLeafId();
    const fork = await slot.fork(forkPoint!, "at");
    const forkSlot = await resumedRegistry.acquire(fork.sessionId);
    const forkRouterState = forkSlot.runtime.session.sessionManager.getBranch().filter((entry: any) => entry.type === "custom" && entry.customType === "pi.virtual-model-state");
    expect(forkRouterState.at(-1)?.data).toEqual(restoredState.at(-1)?.data);
    await forkSlot.prompt("fork continues through router");
    await waitFor(() => !forkSlot.isBusy, "the forked slot to go idle");
    expect(forkSlot.snapshot().transcript.filter((item) => item.kind === "message" && item.role === "assistant").at(-1)).toMatchObject({ provider, modelId: "small", thinkingLevel: "low" });

    await slot.setModel(provider, "router");
    await slot.prompt(`route to the alternate physical model ${"context ".repeat(5000)}`);
    await waitFor(() => !slot.isBusy, "the slot to go idle");
    expect(slot.snapshot().transcript.filter((item) => item.kind === "message" && item.role === "assistant").at(-1)).toMatchObject({ provider, modelId: "wide", thinkingLevel: "high" });
    expect(slot.snapshot().contextUsage?.contextWindow).toBe(16384);
    await slot.compact("keep the router selection");
    await slot.prompt("after compaction");
    await waitFor(() => !slot.isBusy, "the slot to go idle");
    expect(slot.runtime.session.model?.id).toBe("router");
    const postCompactionAssistant = slot.snapshot().transcript.filter((item) => item.kind === "message" && item.role === "assistant").at(-1);
    expect(postCompactionAssistant).toMatchObject({ provider, modelId: responseModels.at(-1), stopReason: "stop" });
    expect(responseModels.slice(0, 4)).toEqual(["wide", "small", "wide", "wide"]);
    expect(responseModels.length).toBeGreaterThan(4);
    expect(slot.snapshot().contextUsage?.contextWindow).toBe(4096);
    const artifactPath = join(process.cwd(), "test-results", "pi-sdk-099-virtual-lifecycle.json");
    await mkdir(join(process.cwd(), "test-results"), { recursive: true });
    await writeFile(artifactPath, `${JSON.stringify({ selectedModel: slot.runtime.session.model?.id, retry: { calls: faux.state.callCount, assistant: retried.at(-1), persistedState: restoredState.at(-1)?.data }, resumed: { model: "router", stateEntries: restoredState.length }, fork: { sessionId: fork.sessionId, routerState: forkRouterState.at(-1)?.data }, responseModels, routedRows: slot.snapshot().transcript.filter((item) => item.kind === "message" && item.role === "assistant"), contextUsage: slot.snapshot().contextUsage, compacted: slot.snapshot().transcript.some((item) => item.kind === "compaction") }, null, 2)}\n`);
  }, 60_000);

  it("projects resumed retry attempts as running before their assistant response completes", async () => {
    const fixture = await coldFixture("retry-resumption");
    await writeFile(join(fixture.agentDir, "settings.json"), JSON.stringify({
      retry: { enabled: true, maxRetries: 3, baseDelayMs: 1 },
    }));
    const faux = fauxProvider({ provider: "tron-retry-resumption", tokensPerSecond: 10_000 });
    let releaseResponse!: () => void;
    const responseBarrier = new Promise<void>((resolve) => { releaseResponse = resolve; });
    let resumed = false;
    faux.setResponses([
      fauxAssistantMessage("", { stopReason: "error", errorMessage: "fetch failed" }),
      async () => {
        resumed = true;
        await responseBarrier;
        return fauxAssistantMessage("Continued successfully");
      },
    ]);
    const runtime = await ModelRuntime.create({ modelsPath: null, refreshOnCreate: false });
    runtime.registerNativeProvider(faux.provider);
    fixture.runtimeFactory.mockResolvedValue(runtime);
    const slot = await fixture.registry.acquire(fixture.manager.getSessionId());
    subscribeAudience(fixture.registry, slot.id);
    const model = faux.getModel();
    await slot.setModel(model.provider, model.id);
    try {
      await slot.prompt("Exercise one transient provider failure");
      await waitFor(() => resumed, "the resumed turn");
      expect(faux.state.callCount).toBe(2);
      expect(fixture.events.some(({ topic, payload }) => topic === "session.snapshot"
        && payload.phase === "retrying" && payload.retry?.attempt === 1)).toBe(true);
      // The real pinned SDK emits agent_start from agent.continue(). The
      // attempt metadata remains until message_end; it is not waiting state.
      const resumedSnapshot = slot.snapshot();
      expect(resumedSnapshot.phase).toBe("running");
      expect(resumedSnapshot.retry).toMatchObject({ source: "agent", attempt: 1 });
      // A fresh open uses this same authority, rather than reconstructing
      // retry waiting from the still-present attempt metadata.
      expect((await fixture.registry.acquire(slot.id)).snapshot().phase).toBe("running");
    } finally {
      releaseResponse();
    }
    await waitFor(() => slot.snapshot().phase === "idle", "the idle phase");
    expect(slot.snapshot().retry).toBeUndefined();
  });

  it("drains branch summarization through exact SDK settlement", async () => {
    const { manager, registry } = await coldFixture("branch-summary-drain");
    const slot = await registry.acquire(manager.getSessionId());
    let release!: () => void;
    const barrier = new Promise<void>((resolve) => { release = resolve; });
    const session = (slot as unknown as {
      runtime: { session: { navigateTree: (...arguments_: unknown[]) => Promise<{ cancelled: boolean }> } };
    }).runtime.session;
    const navigate = vi.spyOn(session, "navigateTree").mockImplementation(async () => {
      await barrier;
      return { cancelled: false };
    });
    const navigating = slot.navigate("target", { summarize: true });
    await waitFor(() => navigate.mock.calls.length === 1, "the navigation");
    let drained = false;
    const drain = registry.waitUntilIdle().then(() => { drained = true; });
    await new Promise((resolve) => setTimeout(resolve, 25));
    expect(drained).toBe(false);
    release();
    await navigating;
    await drain;
    expect(drained).toBe(true);
  });

  it("drains extension resource reload through exact loader settlement", async () => {
    const { manager, registry } = await coldFixture("resource-reload-drain");
    const slot = await registry.acquire(manager.getSessionId());
    let release!: () => void;
    const barrier = new Promise<void>((resolve) => { release = resolve; });
    const loader = (slot as unknown as {
      runtime: { session: { resourceLoader: { reload: (...arguments_: unknown[]) => Promise<void> } } };
    }).runtime.session.resourceLoader;
    const reload = vi.spyOn(loader, "reload").mockImplementation(async () => { await barrier; });
    const reloading = slot.reload();
    await waitFor(() => reload.mock.calls.length === 1, "the reload");
    let drained = false;
    const drain = registry.waitUntilIdle().then(() => { drained = true; });
    await new Promise((resolve) => setTimeout(resolve, 25));
    expect(drained).toBe(false);
    release();
    await reloading;
    await drain;
    expect(drained).toBe(true);
  });

  it("clears branch-summary operation state when tree navigation rejects or is cancelled", async () => {
    const root = await mkdtemp(join(tmpdir(), "tron-navigation-cleanup-"));
    const agentDir = join(root, "agent");
    const cwd = join(root, "workspace");
    await Promise.all([mkdir(agentDir), mkdir(cwd)]);
    const runtime = await ModelRuntime.create({ modelsPath: null, refreshOnCreate: false });
    const snapshots: Array<{ phase: string; operation?: { kind: string }; retry?: unknown }> = [];
    const registry = new RuntimeRegistry({
      agentDir,
      tronHome: join(root, "tron"),
      idleRuntimeMs: 60_000,
      modelRuntimeFactory: async () => runtime,
      trust: new TrustService(agentDir),
      broadcast: (_sessionId, topic, payload) => {
        if (topic === "session.snapshot") snapshots.push(payload as { phase: string; operation?: { kind: string }; retry?: unknown });
      },
      sessionSummaryChanged: () => {},
      sessionListChanged: () => {},
    });
    registries.push(registry);
    await initializeRegistry(registry);
    const slot = await registry.create(cwd);
    subscribeAudience(registry, slot.id);
    const session = (slot as unknown as {
      runtime: { session: { navigateTree: (targetId: string, options: unknown) => Promise<{ cancelled: boolean }> } };
    }).runtime.session;
    const navigate = vi.spyOn(session, "navigateTree");

    navigate.mockRejectedValueOnce(new Error("navigation failed"));
    await expect(slot.navigate("target", { summarize: true })).rejects.toThrow("navigation failed");
    expect(slot.snapshot()).toMatchObject({ phase: "idle" });
    expect(slot.snapshot().operation).toBeUndefined();
    expect(slot.snapshot().retry).toBeUndefined();

    navigate.mockResolvedValueOnce({ cancelled: true });
    await expect(slot.navigate("target", { summarize: true })).rejects.toMatchObject({ code: "cancelled" });
    expect(slot.snapshot().operation).toBeUndefined();
    expect(slot.snapshot().retry).toBeUndefined();
    // A snapshot is published only for a subscriber, so an empty recording would
    // make the last assertion below pass without reading a publication at all.
    expect(snapshots.length).toBeGreaterThan(0);
    expect(snapshots.at(-1)?.operation).toBeUndefined();
  });

  it("persists fast foreground skill and prompt bindings without operation failures", async () => {
    const root = await mkdtemp(join(tmpdir(), "tron-skill-binding-receipt-"));
    const agentDir = join(root, "agent");
    const cwd = join(root, "workspace");
    await Promise.all([
      mkdir(join(agentDir, "skills", "review"), { recursive: true }),
      mkdir(join(agentDir, "prompts"), { recursive: true }),
      mkdir(cwd),
    ]);
    await Promise.all([
      writeFile(join(agentDir, "skills", "review", "SKILL.md"),
        "---\nname: review\ndescription: Review carefully\n---\nReview the requested change.\n"),
      writeFile(join(agentDir, "prompts", "summarize.md"),
        "---\ndescription: Summarize carefully\n---\nSummarize $ARGUMENTS\n"),
    ]);
    const failures: unknown[] = [];
    const snapshots: any[] = [];
    const faux = fauxProvider({ provider: "tron-skill-binding", tokensPerSecond: 10_000 });
    faux.setResponses([fauxAssistantMessage("skill complete"), fauxAssistantMessage("prompt complete")]);
    const runtime = await ModelRuntime.create({ modelsPath: null, refreshOnCreate: false });
    runtime.registerNativeProvider(faux.provider);
    const registry = new RuntimeRegistry({
      agentDir, tronHome: join(root, "tron"), idleRuntimeMs: 60_000,
      modelRuntimeFactory: async () => runtime, trust: new TrustService(agentDir),
      broadcast: (_sessionId, topic, payload) => {
        if (topic === "session.operationFailed") failures.push(payload);
        if (topic === "session.snapshot") snapshots.push(payload);
      },
      sessionSummaryChanged: () => {}, sessionListChanged: () => {},
    });
    registries.push(registry);
    await initializeRegistry(registry);
    const slot = await registry.create(cwd);
    subscribeAudience(registry, slot.id);
    const model = faux.getModel();
    await slot.setModel(model.provider, model.id);
    await expect(slot.prompt("/skill:review configurations", [], undefined, {
      text: "configurations",
      resourceInvocation: { source: "skill", name: "review", arguments: "configurations" },
      attachmentEnvelope: "", attachmentCount: 0,
    })).resolves.toEqual({ operationId: expect.any(String) });
    await waitFor(() => !slot.isBusy, "the slot to go idle");
    const entries = (await readFile(slot.sessionFile!, "utf8")).trimEnd().split("\n").map(line => JSON.parse(line) as any);
    let receipts = entries.filter(entry => entry.customType === INVOCATION_RECEIPT_TYPE).map(entry => entry.data);
    expect(receipts.map(receipt => receipt.receiptKind)).toEqual(["start", "transition", "binding", "terminal"]);
    expect(receipts.find(receipt => receipt.receiptKind === "binding")).not.toHaveProperty("name");
    expect(snapshots.some(snapshot => snapshot.pendingPrompt?.resourceInvocation?.name === "review")).toBe(true);
    expect(slot.snapshot().transcript.some(item => item.semantic?.resourceInvocation?.name === "review")).toBe(true);

    await expect(slot.prompt("/summarize configurations", [], undefined, {
      text: "configurations",
      resourceInvocation: { source: "prompt", name: "summarize", arguments: "configurations" },
      attachmentEnvelope: "", attachmentCount: 0,
    })).resolves.toEqual({ operationId: expect.any(String) });
    await waitFor(() => !slot.isBusy, "the slot to go idle");
    const allEntries = (await readFile(slot.sessionFile!, "utf8")).trimEnd().split("\n").map(line => JSON.parse(line) as any);
    receipts = allEntries.filter(entry => entry.customType === INVOCATION_RECEIPT_TYPE).map(entry => entry.data);
    const promptReceipts = receipts.filter(receipt => receipt.source === "prompt");
    expect(promptReceipts.map(receipt => receipt.receiptKind)).toEqual(["start", "transition", "binding", "terminal"]);
    expect(promptReceipts.find(receipt => receipt.receiptKind === "binding")).not.toHaveProperty("name");
    expect(slot.snapshot().transcript.some(item => item.semantic?.resourceInvocation?.name === "summarize")).toBe(true);
    expect(failures).toEqual([]);
  });

  it("records interruption intent before fast SDK settlement", async () => {
    const root = await mkdtemp(join(tmpdir(), "tron-abort-invocation-"));
    const agentDir = join(root, "agent");
    const cwd = join(root, "workspace");
    await Promise.all([mkdir(agentDir), mkdir(cwd)]);
    let release!: () => void;
    const responseBarrier = new Promise<void>((resolve) => { release = resolve; });
    let agentEntered!: () => void;
    const agentAdmitted = new Promise<void>((resolve) => { agentEntered = resolve; });
    const faux = fauxProvider({ provider: "tron-abort-invocation", tokensPerSecond: 10_000 });
    faux.setResponses([async () => { agentEntered(); await responseBarrier; return fauxAssistantMessage("should not complete"); }]);
    const runtime = await ModelRuntime.create({ modelsPath: null, refreshOnCreate: false });
    runtime.registerNativeProvider(faux.provider);
    const registry = new RuntimeRegistry({
      agentDir, tronHome: join(root, "tron"), idleRuntimeMs: 60_000,
      modelRuntimeFactory: async () => runtime, trust: new TrustService(agentDir),
      broadcast: () => {}, sessionSummaryChanged: () => {}, sessionListChanged: () => {},
    });
    registries.push(registry);
    await initializeRegistry(registry);
    const slot = await registry.create(cwd);
    const model = faux.getModel();
    await slot.setModel(model.provider, model.id);
    const prompt = slot.prompt("interrupt me");
    // Stop only after the SDK admitted the run; see the failed-Stop case below.
    await agentAdmitted;
    const aborting = slot.abort("agent");
    release();
    await aborting;
    await expect(prompt).resolves.toEqual({ operationId: expect.any(String) });
    await waitFor(() => !slot.isBusy, "the slot to go idle");
    const entries = (await readFile(slot.sessionFile!, "utf8")).trimEnd().split("\n").map(line => JSON.parse(line) as any);
    const terminal = entries.find(entry => entry.customType === INVOCATION_RECEIPT_TYPE && entry.data?.receiptKind === "terminal");
    expect(terminal?.data).toMatchObject({ lifecycle: "interrupted" });
  });

  it("keeps main's interrupted receipt when a Stop fails and the run then completes on its own", async () => {
    const root = await mkdtemp(join(tmpdir(), "tron-abort-failed-stop-"));
    const agentDir = join(root, "agent");
    const cwd = join(root, "workspace");
    await Promise.all([mkdir(agentDir), mkdir(cwd)]);
    let release!: () => void;
    const responseBarrier = new Promise<void>((resolve) => { release = resolve; });
    let agentEntered!: () => void;
    const agentAdmitted = new Promise<void>((resolve) => { agentEntered = resolve; });
    const faux = fauxProvider({ provider: "tron-abort-failed-stop", tokensPerSecond: 10_000 });
    faux.setResponses([async () => { agentEntered(); await responseBarrier; return fauxAssistantMessage("completed on its own"); }]);
    const runtime = await ModelRuntime.create({ modelsPath: null, refreshOnCreate: false });
    runtime.registerNativeProvider(faux.provider);
    const registry = new RuntimeRegistry({
      agentDir, tronHome: join(root, "tron"), idleRuntimeMs: 60_000,
      modelRuntimeFactory: async () => runtime, trust: new TrustService(agentDir),
      broadcast: () => {}, sessionSummaryChanged: () => {}, sessionListChanged: () => {},
    });
    registries.push(registry);
    await initializeRegistry(registry);
    const slot = await registry.create(cwd);
    const model = faux.getModel();
    await slot.setModel(model.provider, model.id);
    const prompt = slot.prompt("finish on its own");
    // `isBusy` turns true at slot admission, before the SDK admits the run; a Stop
    // in that window revokes the prompt and never reaches `session.abort`.
    await agentAdmitted;
    const session = (slot as unknown as { runtime: { session: { abort(): Promise<void> } } }).runtime.session;
    const sdkAbort = session.abort.bind(session);
    session.abort = async () => { throw new Error("abort refused"); };
    try {
      await expect(slot.abort("agent")).rejects.toThrow(/did not stop/);
    } finally {
      session.abort = sdkAbort;
    }
    release();
    await prompt;
    await waitFor(() => !slot.isBusy, "the slot to go idle");
    const entries = (await readFile(slot.sessionFile!, "utf8")).trimEnd().split("\n").map(line => JSON.parse(line) as any);
    const terminals = entries.filter(entry => entry.customType === INVOCATION_RECEIPT_TYPE && entry.data?.receiptKind === "terminal");
    // The user Stop intent outlives the failed attempt. This matches main, which
    // records the same receipt; whether a failed Stop should instead record
    // completed is a separate main-branch decision.
    expect(terminals).toHaveLength(1);
    expect(terminals[0]?.data).toMatchObject({ lifecycle: "interrupted", errorCode: "user-abort" });
  });

  it("records a completed receipt for a Stop that arrives after a natural completion", async () => {
    const root = await mkdtemp(join(tmpdir(), "tron-abort-after-completion-"));
    const agentDir = join(root, "agent");
    const cwd = join(root, "workspace");
    await Promise.all([mkdir(agentDir), mkdir(cwd)]);
    const faux = fauxProvider({ provider: "tron-abort-after-completion", tokensPerSecond: 10_000 });
    faux.setResponses([fauxAssistantMessage("finished before Stop")]);
    const runtime = await ModelRuntime.create({ modelsPath: null, refreshOnCreate: false });
    runtime.registerNativeProvider(faux.provider);
    const registry = new RuntimeRegistry({
      agentDir, tronHome: join(root, "tron"), idleRuntimeMs: 60_000,
      modelRuntimeFactory: async () => runtime, trust: new TrustService(agentDir),
      broadcast: () => {}, sessionSummaryChanged: () => {}, sessionListChanged: () => {},
    });
    registries.push(registry);
    await initializeRegistry(registry);
    const slot = await registry.create(cwd);
    const model = faux.getModel();
    await slot.setModel(model.provider, model.id);
    const { operationId } = await slot.prompt("finish first");
    await waitFor(() => !slot.isBusy, "the slot to go idle");
    await slot.abort("agent");
    const entries = (await readFile(slot.sessionFile!, "utf8")).trimEnd().split("\n").map(line => JSON.parse(line) as any);
    const terminals = entries.filter(entry => entry.customType === INVOCATION_RECEIPT_TYPE && entry.data?.receiptKind === "terminal" && entry.data.operationId === operationId);
    expect(terminals).toHaveLength(1);
    expect(terminals[0]?.data).toMatchObject({ lifecycle: "completed" });
    expect(terminals[0]?.data).not.toHaveProperty("errorCode");
  });

  it("projects and atomically manages multiple queued messages by stable identity", async () => {
    const root = await mkdtemp(join(tmpdir(), "tron-queue-management-"));
    const agentDir = join(root, "agent");
    const cwd = join(root, "workspace");
    const skillDir = join(agentDir, "skills", "review");
    const extensionDir = join(cwd, ".pi", "extensions");
    await Promise.all([mkdir(skillDir, { recursive: true }), mkdir(extensionDir, { recursive: true })]);
    await writeFile(join(extensionDir, "handled-queue.ts"), `export default function (pi) {
      pi.on("input", (event) => event.text === "handled during rebuild" ? { action: "handled" } : undefined);
    }\n`);
    await writeFile(
      join(skillDir, "SKILL.md"),
      "---\nname: review\ndescription: Review carefully\n---\nReview the requested change.\n",
    );

    let releaseResponse!: () => void;
    const responseBarrier = new Promise<void>((resolve) => { releaseResponse = resolve; });
    const faux = fauxProvider({ provider: "tron-queue-management", tokensPerSecond: 10_000 });
    faux.setResponses([
      async () => {
        await responseBarrier;
        return fauxAssistantMessage("initial complete");
      },
      fauxAssistantMessage("queued complete"),
      fauxAssistantMessage("follow-up complete"),
    ]);
    const createModels = async () => {
      const runtime = await ModelRuntime.create({ modelsPath: null, refreshOnCreate: false });
      runtime.registerNativeProvider(faux.provider);
      return runtime;
    };
    const trust = new TrustService(agentDir);
    await trust.set(cwd, true);
    const registry = new RuntimeRegistry({
      agentDir,
      tronHome: join(root, "tron"),
      idleRuntimeMs: 60_000,
      modelRuntimeFactory: createModels,
      trust,
      broadcast: () => {},
      sessionSummaryChanged: () => {},
      sessionListChanged: () => {},
    });
    registries.push(registry);
    await initializeRegistry(registry);
    const slot = await registry.create(cwd);
    const model = faux.getModel();
    await slot.setModel(model.provider, model.id);
    await slot.prompt("start");
    await waitFor(() => slot.isBusy, "the slot to take work");

    const oversizedDescriptors = Array.from({ length: 11 }, (_, index) => ({
      id: `upload-${index}`, name: `file-${index}.txt`, mimeType: "text/plain", size: 1,
    }));
    await expect(slot.prompt("invalid", [], "steer", {
      text: "invalid",
      attachmentEnvelope: "",
      attachmentCount: oversizedDescriptors.length,
      attachments: oversizedDescriptors,
    })).rejects.toMatchObject({ code: "invalid_request" });

    const attachment = {
      id: "upload:00000000-0000-4000-8000-000000000001",
      name: "notes.txt", mimeType: "text/plain", size: 4,
    };
    await slot.prompt("first steer", [], "steer", {
      text: "first steer",
      attachmentEnvelope: '<attachment name="notes.txt" />',
      attachmentCount: 1,
      photoCount: 0,
      fileAttachmentCount: 1,
      attachments: [attachment],
    });
    await slot.prompt("first steer", [], "steer", {
      text: "first steer",
      attachmentEnvelope: "",
      attachmentCount: 0,
    });
    await slot.prompt("later follow-up", [], "followUp", {
      text: "later follow-up",
      attachmentEnvelope: "",
      attachmentCount: 0,
    });
    await slot.prompt("/skill:review queued skill", [], "steer", {
      text: "queued skill",
      resourceInvocation: { source: "skill", name: "review", arguments: "queued skill" },
      attachmentEnvelope: "",
      attachmentCount: 0,
    });
    const queued = slot.snapshot();
    expect(queued.queuedItems).toHaveLength(4);
    expect(queued.queuedItems.map((item) => item.behavior)).toEqual(["steer", "steer", "steer", "followUp"]);
    expect(queued.queuedItems.map((item) => item.text)).toEqual([
      "first steer", "first steer", "queued skill", "later follow-up",
    ]);
    expect(new Set(queued.queuedItems.map((item) => item.id)).size).toBe(4);
    expect(queued.queuedItems[0]?.attachments).toEqual([attachment]);

    const [first, duplicate, skill, followUp] = queued.queuedItems;
    const replaced = await slot.replaceQueue(queued.queueRevision, [
      { id: duplicate!.id, behavior: "steer", text: duplicate!.text },
      { id: followUp!.id, behavior: "steer", text: "edited and earlier" },
      { id: first!.id, behavior: "followUp", text: first!.text },
      { id: skill!.id, behavior: "followUp", text: "edited skill" },
    ]);
    expect(replaced.items.map(({ id, behavior, text }) => ({ id, behavior, text }))).toEqual([
      { id: duplicate!.id, behavior: "steer", text: "first steer" },
      { id: followUp!.id, behavior: "steer", text: "edited and earlier" },
      { id: first!.id, behavior: "followUp", text: "first steer" },
      { id: skill!.id, behavior: "followUp", text: "edited skill" },
    ]);
    expect(replaced.items[2]?.attachments).toEqual([attachment]);
    expect(replaced.items[3]?.resourceInvocation).toEqual({
      source: "skill", name: "review", arguments: "edited skill",
    });
    const afterEditEntries = (slot as any).runtime.session.sessionManager.getEntries() as any[];
    const skillInvocationReceipts = afterEditEntries.filter(entry => entry.customType === INVOCATION_RECEIPT_TYPE
      && entry.data?.operationId === skill!.id).map(entry => entry.data);
    expect(skillInvocationReceipts.filter(receipt => receipt.receiptKind === "start")
      .map(receipt => receipt.arguments)).toEqual(["queued skill", "edited skill"]);
    expect(skillInvocationReceipts.some(receipt => receipt.receiptKind === "terminal"
      && receipt.lifecycle === "interrupted" && receipt.errorCode === "queue-edited")).toBe(true);
    const queuedRuntime = (slot as unknown as {
      runtime: { session: { getFollowUpMessages(): readonly string[] } };
    }).runtime.session.getFollowUpMessages();
    expect(queuedRuntime.some(
      (text) => text.startsWith('<skill name="review"') && text.endsWith("edited skill"),
    )).toBe(true);
    await expect(slot.replaceQueue(queued.queueRevision, [])).rejects.toMatchObject({ code: "conflict" });

    const handledReplacement = await slot.replaceQueue(replaced.queueRevision, [
      { ...replaced.items[1]!, text: "handled during rebuild" },
      replaced.items[0]!,
    ]);
    expect(handledReplacement.items.map(({ id }) => id)).toEqual([duplicate!.id]);
    const afterHandledRebuild = (slot as any).runtime.session.sessionManager.getEntries() as any[];
    expect(afterHandledRebuild.some(entry => entry.customType === INVOCATION_RECEIPT_TYPE
      && entry.data?.operationId === followUp!.id
      && entry.data?.receiptKind === "terminal"
      && entry.data?.lifecycle === "completed")).toBe(true);
    expect(afterHandledRebuild.some(entry => entry.customType === INVOCATION_RECEIPT_TYPE
      && entry.data?.operationId === skill!.id
      && entry.data?.receiptKind === "terminal"
      && entry.data?.lifecycle === "interrupted")).toBe(true);

    await slot.clearQueue();
    expect(slot.snapshot().queuedItems).toEqual([]);
    const afterClearEntries = (slot as any).runtime.session.sessionManager.getEntries() as any[];
    expect(afterClearEntries.some(entry => entry.customType === INVOCATION_RECEIPT_TYPE
      && entry.data?.operationId === duplicate!.id
      && entry.data?.receiptKind === "terminal"
      && entry.data?.lifecycle === "interrupted"
      && entry.data?.errorCode === "queue-cleared")).toBe(true);
    await expect(slot.replaceQueue(handledReplacement.queueRevision, []))
      .rejects.toMatchObject({ code: "conflict" });

    releaseResponse();
    await waitFor(() => !slot.isBusy, "the slot to go idle");
  });

  it("queues one manual compaction behind an active run and keeps its receipt pending", async () => {
    const root = await mkdtemp(join(tmpdir(), "tron-queued-compaction-"));
    const agentDir = join(root, "agent");
    const cwd = join(root, "workspace");
    await Promise.all([mkdir(agentDir), mkdir(cwd)]);

    let releaseResponse!: () => void;
    const responseBarrier = new Promise<void>((resolve) => { releaseResponse = resolve; });
    let releaseCompaction!: () => void;
    const compactionBarrier = new Promise<void>((resolve) => { releaseCompaction = resolve; });
    const faux = fauxProvider({ provider: "tron-queued-compaction", tokensPerSecond: 10_000 });
    faux.setResponses([async () => {
      await responseBarrier;
      return fauxAssistantMessage("run complete");
    }]);
    const createModels = async () => {
      const runtime = await ModelRuntime.create({ modelsPath: null, refreshOnCreate: false });
      runtime.registerNativeProvider(faux.provider);
      return runtime;
    };
    const registry = new RuntimeRegistry({
      agentDir,
      tronHome: join(root, "tron"),
      idleRuntimeMs: 60_000,
      modelRuntimeFactory: createModels,
      trust: new TrustService(agentDir),
      broadcast: () => {},
      sessionSummaryChanged: () => {},
      sessionListChanged: () => {},
    });
    registries.push(registry);
    await initializeRegistry(registry);
    const slot = await registry.create(cwd);
    const model = faux.getModel();
    await slot.setModel(model.provider, model.id);
    const session = (slot as unknown as {
      runtime: { session: { compact: (instructions?: string) => Promise<unknown> } };
    }).runtime.session;
    const compact = vi.spyOn(session, "compact").mockImplementation(async () => {
      await compactionBarrier;
      return {};
    });
    let releaseMarker!: () => void;
    const markerBarrier = new Promise<void>((resolve) => { releaseMarker = resolve; });
    const markerStore = (slot as unknown as { dependencies: { markers: RunMarkerStore } }).dependencies.markers;
    const originalClear = markerStore.clear.bind(markerStore);
    let promptOperationId: string;
    const clearMarker = vi.spyOn(markerStore, "clear").mockImplementation(async (sessionId, operationId) => {
      if (operationId !== promptOperationId) await markerBarrier;
      await originalClear(sessionId, operationId);
    });

    promptOperationId = (await slot.prompt("start")).operationId;
    await waitFor(() => slot.isBusy, "the slot to take work");
    const queuedCompaction = slot.compact("Preserve exact decisions");
    await waitFor(() => slot.snapshot().compactionQueued === true, "the queued compaction");

    expect(slot.snapshot()).toMatchObject({
      phase: "running",
      compactionQueued: true,
      automaticCompactionEnabled: true,
    });
    expect(registry.activeSessionIds()).toContain(slot.id);
    await expect(slot.compact()).rejects.toMatchObject({
      code: "busy",
      message: "A manual compaction is already pending for this session",
    });
    expect(compact).not.toHaveBeenCalled();

    releaseResponse();
    await waitFor(() => compact.mock.calls.length === 1, "the compaction call");
    expect(compact).toHaveBeenCalledWith("Preserve exact decisions");
    expect(slot.snapshot()).toMatchObject({ phase: "compacting", compactionQueued: false });
    expect(registry.activeSessionIds()).toContain(slot.id);

    let queuedSettled = false;
    void queuedCompaction.then(() => { queuedSettled = true; }, () => {});
    releaseCompaction();
    await waitFor(() => clearMarker.mock.calls.some(([, id]) => id !== promptOperationId), "a marker clear for another operation");
    await Promise.resolve();
    expect(queuedSettled).toBe(false);
    expect(registry.activeSessionIds()).toContain(slot.id);
    releaseMarker();
    await expect(queuedCompaction).resolves.toEqual({ queued: true });
    await waitFor(() => !slot.isBusy, "the slot to go idle");
    expect(slot.snapshot()).toMatchObject({ phase: "idle", compactionQueued: false });
    expect(registry.activeSessionIds()).not.toContain(slot.id);
    expect(await markerStore.evidenceFor(slot.id)).toEqual([]);
  });

  it("reasserts exact marker ownership when cleanup races terminal completion stamping", async () => {
    const root = await mkdtemp(join(tmpdir(), "tron-terminal-marker-race-"));
    const agentDir = join(root, "agent");
    const cwd = join(root, "workspace");
    await Promise.all([mkdir(agentDir), mkdir(cwd)]);
    let releaseResponse!: () => void;
    const responseBarrier = new Promise<void>((resolve) => { releaseResponse = resolve; });
    const faux = fauxProvider({ provider: "tron-terminal-marker-race", tokensPerSecond: 10_000 });
    faux.setResponses([
      async () => { await responseBarrier; return fauxAssistantMessage("first completion"); },
      fauxAssistantMessage("next completion"),
    ]);
    const registry = new RuntimeRegistry({
      agentDir,
      tronHome: join(root, "tron"),
      idleRuntimeMs: 60_000,
      modelRuntimeFactory: async () => {
        const runtime = await ModelRuntime.create({ modelsPath: null, refreshOnCreate: false });
        runtime.registerNativeProvider(faux.provider);
        return runtime;
      },
      trust: new TrustService(agentDir),
      broadcast: () => {},
      sessionSummaryChanged: () => {},
      sessionListChanged: () => {},
    });
    registries.push(registry);
    await initializeRegistry(registry);
    const slot = await registry.create(cwd);
    const model = faux.getModel();
    await slot.setModel(model.provider, model.id);

    const first = await slot.prompt("first");
    await waitFor(() => slot.snapshot().phase === "running", "the running phase");
    const markers = (slot as unknown as {
      dependencies: {
        markers: {
          clear: (sessionId: string, operationId?: string) => Promise<void>;
          evidenceFor: (sessionId: string) => Promise<Array<{ operationId: string }>>;
        };
      };
    }).dependencies.markers;
    await markers.clear(slot.id, first.operationId);
    expect(await markers.evidenceFor(slot.id)).toEqual([]);

    releaseResponse();
    await waitFor(() => registry.attentionProjection(slot.id).completionRevision === 1, "the first completion revision");
    await waitFor(() => slot.snapshot().phase === "idle", "the idle phase");
    await expect(slot.reconcileAttention()).resolves.toBeUndefined();
    expect(await markers.evidenceFor(slot.id)).toEqual([]);

    await expect(slot.prompt("next", [], "steer")).resolves.toEqual({
      operationId: expect.any(String),
    });
    const drain = registry.waitUntilIdle();
    await waitFor(() => registry.attentionProjection(slot.id).completionRevision === 2, "the second completion revision");
    await drain;
    expect(slot.snapshot().phase).toBe("idle");
    expect(registry.administrativeDrainSnapshot()).toMatchObject({ phase: "complete", blockerCount: 0 });
  });

  it("settles a failed completion owner so the next prompt can proceed", async () => {
    const root = await mkdtemp(join(tmpdir(), "tron-attention-settlement-failure-"));
    const agentDir = join(root, "agent");
    const cwd = join(root, "workspace");
    await Promise.all([mkdir(agentDir), mkdir(cwd)]);
    const faux = fauxProvider({ provider: "tron-attention-failure", tokensPerSecond: 10_000 });
    faux.setResponses([
      fauxAssistantMessage("first completion"),
      fauxAssistantMessage("must not be admitted"),
    ]);
    const registry = new RuntimeRegistry({
      agentDir,
      tronHome: join(root, "tron"),
      idleRuntimeMs: 60_000,
      modelRuntimeFactory: async () => {
        const runtime = await ModelRuntime.create({ modelsPath: null, refreshOnCreate: false });
        runtime.registerNativeProvider(faux.provider);
        return runtime;
      },
      trust: new TrustService(agentDir),
      broadcast: () => {},
      sessionSummaryChanged: () => {},
      sessionListChanged: () => {},
    });
    registries.push(registry);
    await initializeRegistry(registry);
    const slot = await registry.create(cwd);
    const model = faux.getModel();
    await slot.setModel(model.provider, model.id);
    const attention = (registry as unknown as {
      attention: { complete: (sessionId: string, completionId: string) => Promise<unknown> };
    }).attention;
    const complete = vi.spyOn(attention, "complete").mockRejectedValue(new Error("attention persistence failed"));

    await slot.prompt("first");
    await waitFor(() => slot.snapshot().phase === "interrupted", "the interrupted phase");
    expect(complete).toHaveBeenCalledTimes(3);
    await expect(slot.prompt("second")).resolves.toMatchObject({ operationId: expect.any(String) });
    expect(complete.mock.calls.map(([, completionId]) => completionId))
      .toEqual(Array(3).fill(complete.mock.calls[0]![1]));

    complete.mockRestore();
    await slot.reconcileAttention();
    await waitFor(() => slot.snapshot().phase === "idle", "the idle phase");
    expect(registry.attentionProjection(slot.id)).toMatchObject({ completionRevision: 2, isUnread: true });
  });

  it("cleans up queued manual compaction state when canonical compaction fails", async () => {
    const root = await mkdtemp(join(tmpdir(), "tron-queued-compaction-failure-"));
    const agentDir = join(root, "agent");
    const cwd = join(root, "workspace");
    await Promise.all([mkdir(agentDir), mkdir(cwd)]);

    let releaseResponse!: () => void;
    const responseBarrier = new Promise<void>((resolve) => { releaseResponse = resolve; });
    const faux = fauxProvider({ provider: "tron-queued-compaction-failure", tokensPerSecond: 10_000 });
    faux.setResponses([async () => {
      await responseBarrier;
      return fauxAssistantMessage("run complete");
    }]);
    const createModels = async () => {
      const runtime = await ModelRuntime.create({ modelsPath: null, refreshOnCreate: false });
      runtime.registerNativeProvider(faux.provider);
      return runtime;
    };
    const registry = new RuntimeRegistry({
      agentDir,
      tronHome: join(root, "tron"),
      idleRuntimeMs: 60_000,
      modelRuntimeFactory: createModels,
      trust: new TrustService(agentDir),
      broadcast: () => {},
      sessionSummaryChanged: () => {},
      sessionListChanged: () => {},
    });
    registries.push(registry);
    await initializeRegistry(registry);
    const slot = await registry.create(cwd);
    const model = faux.getModel();
    await slot.setModel(model.provider, model.id);
    const session = (slot as unknown as {
      runtime: { session: { compact: (instructions?: string) => Promise<unknown> } };
    }).runtime.session;
    vi.spyOn(session, "compact").mockRejectedValue(new Error("manual compaction failed"));

    await slot.prompt("start");
    await waitFor(() => slot.isBusy, "the slot to take work");
    const queuedCompaction = slot.compact();
    const failure = expect(queuedCompaction).rejects.toThrow("manual compaction failed");
    await waitFor(() => slot.snapshot().compactionQueued === true, "the queued compaction");
    releaseResponse();
    await failure;
    await waitFor(() => !slot.isBusy, "the slot to go idle");
    expect(slot.snapshot()).toMatchObject({ phase: "idle", compactionQueued: false });
    expect(slot.snapshot().operation).toBeUndefined();
  });

  it("keeps queued compaction owned while transient marker removal retries", async () => {
    const root = await mkdtemp(join(tmpdir(), "tron-compaction-marker-failure-"));
    const agentDir = join(root, "agent");
    const cwd = join(root, "workspace");
    await Promise.all([mkdir(agentDir), mkdir(cwd)]);
    let releaseResponse!: () => void;
    const responseBarrier = new Promise<void>((resolve) => { releaseResponse = resolve; });
    const faux = fauxProvider({ provider: "tron-compaction-marker-failure", tokensPerSecond: 10_000 });
    faux.setResponses([async () => {
      await responseBarrier;
      return fauxAssistantMessage("run complete");
    }]);
    const registry = new RuntimeRegistry({
      agentDir,
      tronHome: join(root, "tron"),
      idleRuntimeMs: 60_000,
      modelRuntimeFactory: async () => {
        const runtime = await ModelRuntime.create({ modelsPath: null, refreshOnCreate: false });
        runtime.registerNativeProvider(faux.provider);
        return runtime;
      },
      trust: new TrustService(agentDir),
      broadcast: () => {},
      sessionSummaryChanged: () => {},
      sessionListChanged: () => {},
    });
    registries.push(registry);
    await initializeRegistry(registry);
    const slot = await registry.create(cwd);
    const model = faux.getModel();
    await slot.setModel(model.provider, model.id);
    const session = (slot as unknown as {
      runtime: { session: { compact: (instructions?: string) => Promise<unknown> } };
    }).runtime.session;
    vi.spyOn(session, "compact").mockResolvedValue({});
    const markerStore = (slot as unknown as { dependencies: { markers: RunMarkerStore } }).dependencies.markers;
    const originalClear = markerStore.clear.bind(markerStore);
    let promptOperationId: string;
    let maintenanceAttempts = 0;
    const clearMarker = vi.spyOn(markerStore, "clear").mockImplementation(async (sessionId, operationId) => {
      if (operationId !== promptOperationId && ++maintenanceAttempts === 1) throw new Error("marker removal failed");
      await originalClear(sessionId, operationId);
    });

    promptOperationId = (await slot.prompt("start")).operationId;
    await waitFor(() => slot.isBusy, "the slot to take work");
    const queuedCompaction = slot.compact();
    await waitFor(() => slot.snapshot().compactionQueued === true, "the queued compaction");
    releaseResponse();
    await expect(queuedCompaction).resolves.toEqual({ queued: true });
    expect(maintenanceAttempts).toBe(2);
    expect(clearMarker.mock.calls.every(([, id]) => id !== undefined)).toBe(true);
    expect(await markerStore.evidenceFor(slot.id)).toEqual([]);
    expect(slot.snapshot()).toMatchObject({ phase: "idle", compactionQueued: false });
    expect(slot.snapshot().operation).toBeUndefined();
    clearMarker.mockRestore();
  });

  it("admits only one direct manual compaction and retains the claim through completion", async () => {
    const root = await mkdtemp(join(tmpdir(), "tron-direct-compaction-"));
    const agentDir = join(root, "agent");
    const cwd = join(root, "workspace");
    await Promise.all([mkdir(agentDir), mkdir(cwd)]);
    const registry = new RuntimeRegistry({
      agentDir,
      tronHome: join(root, "tron"),
      idleRuntimeMs: 60_000,
      modelRuntimeFactory: async () => ModelRuntime.create({ modelsPath: null, refreshOnCreate: false }),
      trust: new TrustService(agentDir),
      broadcast: () => {},
      sessionSummaryChanged: () => {},
      sessionListChanged: () => {},
    });
    registries.push(registry);
    await initializeRegistry(registry);
    const slot = await registry.create(cwd);
    let releaseCompaction!: () => void;
    const barrier = new Promise<void>((resolve) => { releaseCompaction = resolve; });
    const session = (slot as unknown as {
      runtime: { session: { compact: (instructions?: string) => Promise<unknown> } };
    }).runtime.session;
    const compact = vi.spyOn(session, "compact").mockImplementation(async () => {
      await barrier;
      return {};
    });
    const markerStore = (slot as unknown as {
      dependencies: { markers: { clear: (sessionId: string, operationId?: string) => Promise<void> } };
    }).dependencies.markers;
    const clearMarker = vi.spyOn(markerStore, "clear").mockRejectedValueOnce(new Error("transient clear failure"));

    const first = slot.compact("Keep decisions");
    await waitFor(() => slot.snapshot().phase === "compacting", "the compacting phase");
    expect(registry.activeSessionIds()).toContain(slot.id);
    await expect(slot.compact()).rejects.toMatchObject({
      code: "busy",
      message: "A manual compaction is already pending for this session",
    });
    expect(compact).toHaveBeenCalledTimes(1);
    const markerPath = join(root, "tron", "gateway", "runtime-markers", `${slot.id}.json`);
    expect(JSON.parse(await readFile(markerPath, "utf8")).operations).toHaveLength(1);

    releaseCompaction();
    await expect(first).resolves.toEqual({ queued: false });
    expect(clearMarker.mock.calls.length).toBeGreaterThanOrEqual(2);
    await waitFor(() => !slot.isBusy, "the slot to go idle");
    expect(slot.snapshot()).toMatchObject({ phase: "idle", compactionQueued: false });
  });

  it("publishes one authoritative compaction snapshot including a hook-appended suffix", async () => {
    const root = await mkdtemp(join(tmpdir(), "tron-compaction-delta-"));
    const agentDir = join(root, "agent");
    const cwd = join(root, "workspace");
    await Promise.all([mkdir(agentDir), mkdir(cwd)]);
    const broadcasts: Array<{ sessionId: string; topic: string; payload: unknown }> = [];
    const registry = new RuntimeRegistry({
      agentDir,
      tronHome: join(root, "tron"),
      idleRuntimeMs: 60_000,
      modelRuntimeFactory: async () => ModelRuntime.create({ modelsPath: null, refreshOnCreate: false }),
      trust: new TrustService(agentDir),
      broadcast: (sessionId, topic, payload) => broadcasts.push({ sessionId, topic, payload }),
      sessionSummaryChanged: () => {},
      sessionListChanged: () => {},
    });
    registries.push(registry);
    await initializeRegistry(registry);
    const slot = await registry.create(cwd);
    subscribeAudience(registry, slot.id);
    const runtime = (slot as unknown as {
      runtime: { session: { sessionManager: SessionManager } };
      onEvent: (event: unknown) => void;
    });
    const firstKeptEntryId = runtime.runtime.session.sessionManager.appendMessage(
      fauxAssistantMessage("canonical history")
    );
    const summary = "Preserved exact decisions";
    const tokensBefore = 12_345;
    const compactionId = runtime.runtime.session.sessionManager.appendCompaction(
      summary,
      firstKeptEntryId,
      tokensBefore
    );
    runtime.runtime.session.sessionManager.appendLabelChange(
      compactionId,
      "hook appended after compaction"
    );

    runtime.onEvent({
      type: "compaction_end",
      reason: "manual",
      result: { summary, firstKeptEntryId, tokensBefore },
      aborted: false,
      willRetry: true,
    });

    expect(broadcasts.some((event) => event.topic === "session.compaction")).toBe(false);
    const completion = broadcasts.filter((event) => event.topic === "session.snapshot").at(-1);
    const payload = completion?.payload as {
      eventSequence?: number;
      phase?: string;
      leafEntryId?: string;
      transcript?: Array<{ id: string; kind: string }>;
    } | undefined;
    expect(completion?.sessionId).toBe(slot.id);
    expect(payload).toMatchObject({
      eventSequence: expect.any(Number),
      phase: "idle",
      leafEntryId: expect.any(String),
    });
    expect(payload?.transcript).toEqual(expect.arrayContaining([
      expect.objectContaining({ id: compactionId, kind: "compaction" }),
      expect.objectContaining({ id: payload?.leafEntryId, kind: "label" }),
    ]));
  });

  it("restores a pre-prompt operation in the authoritative compaction completion frame", async () => {
    const root = await mkdtemp(join(tmpdir(), "tron-preprompt-compaction-frame-"));
    const agentDir = join(root, "agent");
    const cwd = join(root, "workspace");
    await Promise.all([mkdir(agentDir), mkdir(cwd)]);
    const broadcasts: Array<{ topic: string; payload: any }> = [];
    const registry = new RuntimeRegistry({
      agentDir, tronHome: join(root, "tron"), idleRuntimeMs: 60_000,
      modelRuntimeFactory: async () => ModelRuntime.create({ modelsPath: null, refreshOnCreate: false }),
      trust: new TrustService(agentDir),
      broadcast: (_sessionId, topic, payload) => broadcasts.push({ topic, payload }),
      sessionSummaryChanged: () => {}, sessionListChanged: () => {},
    });
    registries.push(registry);
    await initializeRegistry(registry);
    const slot = await registry.create(cwd);
    subscribeAudience(registry, slot.id);
    const internal = slot as unknown as {
      runtime: { session: { sessionManager: SessionManager } };
      pendingPrompt: { id: string; createdAt: string; text: string; attachmentCount: number };
      phase: string;
      operation: unknown;
      compactionOperation: unknown;
      onEvent: (event: unknown) => void;
    };
    const parent = internal.runtime.session.sessionManager.appendMessage(
      fauxAssistantMessage("history")
    );
    const compaction = internal.runtime.session.sessionManager.appendCompaction(
      "summary", parent, 4_096
    );
    internal.runtime.session.sessionManager.appendLabelChange(compaction, "hook suffix");
    internal.pendingPrompt = {
      id: "pending-operation", createdAt: "2026-01-01T00:00:00.000Z",
      text: "continue", attachmentCount: 0,
    };
    internal.phase = "compacting";
    internal.operation = { kind: "compaction" };
    internal.compactionOperation = internal.operation;
    internal.onEvent({
      type: "compaction_end", reason: "threshold",
      result: { summary: "summary", firstKeptEntryId: parent, tokensBefore: 4_096 },
      aborted: false, willRetry: false,
    });
    const completion = broadcasts.filter((event) => event.topic === "session.snapshot").at(-1)?.payload;
    expect(completion).toMatchObject({
      phase: "running",
      operation: { id: "pending-operation", kind: "prompt", startedAt: "2026-01-01T00:00:00.000Z" },
      pendingPrompt: { id: "pending-operation" },
    });
    expect(completion.leafEntryId).not.toBe(compaction);
  });

  it("cleans up a failed direct manual compaction claim", async () => {
    const root = await mkdtemp(join(tmpdir(), "tron-direct-compaction-failure-"));
    const agentDir = join(root, "agent");
    const cwd = join(root, "workspace");
    await Promise.all([mkdir(agentDir), mkdir(cwd)]);
    const registry = new RuntimeRegistry({
      agentDir,
      tronHome: join(root, "tron"),
      idleRuntimeMs: 60_000,
      modelRuntimeFactory: async () => ModelRuntime.create({ modelsPath: null, refreshOnCreate: false }),
      trust: new TrustService(agentDir),
      broadcast: () => {},
      sessionSummaryChanged: () => {},
      sessionListChanged: () => {},
    });
    registries.push(registry);
    await initializeRegistry(registry);
    const slot = await registry.create(cwd);
    const session = (slot as unknown as {
      runtime: { session: { compact: (instructions?: string) => Promise<unknown> } };
    }).runtime.session;
    const compact = vi.spyOn(session, "compact")
      .mockRejectedValueOnce(new Error("direct compaction failed"))
      .mockResolvedValueOnce({});

    await expect(slot.compact()).rejects.toThrow("direct compaction failed");
    expect(slot.snapshot()).toMatchObject({ phase: "idle", compactionQueued: false });
    expect(slot.snapshot().operation).toBeUndefined();
    await expect(slot.compact()).resolves.toEqual({ queued: false });
    expect(compact).toHaveBeenCalledTimes(2);
  });

  it("defers queued compaction when a newer prompt enters preflight before handoff", async () => {
    const root = await mkdtemp(join(tmpdir(), "tron-compaction-handoff-race-"));
    const agentDir = join(root, "agent");
    const cwd = join(root, "workspace");
    await Promise.all([mkdir(agentDir), mkdir(cwd)]);
    let releaseFirst!: () => void;
    let releaseSecond!: () => void;
    const firstBarrier = new Promise<void>((resolve) => { releaseFirst = resolve; });
    const secondBarrier = new Promise<void>((resolve) => { releaseSecond = resolve; });
    const faux = fauxProvider({ provider: "tron-compaction-handoff-race", tokensPerSecond: 10_000 });
    faux.setResponses([
      async () => { await firstBarrier; return fauxAssistantMessage("first complete"); },
      async () => { await secondBarrier; return fauxAssistantMessage("second complete"); },
    ]);
    const registry = new RuntimeRegistry({
      agentDir,
      tronHome: join(root, "tron"),
      idleRuntimeMs: 60_000,
      modelRuntimeFactory: async () => {
        const runtime = await ModelRuntime.create({ modelsPath: null, refreshOnCreate: false });
        runtime.registerNativeProvider(faux.provider);
        return runtime;
      },
      trust: new TrustService(agentDir),
      broadcast: () => {},
      sessionSummaryChanged: () => {},
      sessionListChanged: () => {},
    });
    registries.push(registry);
    await initializeRegistry(registry);
    const slot = await registry.create(cwd);
    const model = faux.getModel();
    await slot.setModel(model.provider, model.id);
    const runtimeSession = (slot as unknown as {
      runtime: { session: {
        compact: (instructions?: string) => Promise<unknown>;
        isStreaming: boolean;
      } };
    }).runtime.session;
    const compact = vi.spyOn(runtimeSession, "compact").mockResolvedValue({});
    const lane = (slot as unknown as {
      lane: { run<T>(operation: () => Promise<T> | T): Promise<T> };
    }).lane;

    await slot.prompt("first");
    await waitFor(() => runtimeSession.isStreaming, "the runtime to start streaming");
    const queuedCompaction = slot.compact();
    await waitFor(() => slot.snapshot().compactionQueued === true, "the queued compaction");

    let releaseLane!: () => void;
    let laneEntered!: () => void;
    const laneWasEntered = new Promise<void>((resolve) => { laneEntered = resolve; });
    const laneBarrier = new Promise<void>((resolve) => { releaseLane = resolve; });
    const blocker = lane.run(async () => {
      laneEntered();
      await laneBarrier;
    });
    await laneWasEntered;
    const newerPrompt = slot.prompt("newer");
    releaseFirst();
    await waitFor(() => !runtimeSession.isStreaming, "the runtime to stop streaming");
    releaseLane();
    await blocker;
    await newerPrompt;
    await waitFor(() => runtimeSession.isStreaming, "the runtime to start streaming");
    await lane.run(() => {});
    expect(compact).not.toHaveBeenCalled();
    expect(slot.snapshot().compactionQueued).toBe(true);

    releaseSecond();
    await waitFor(() => compact.mock.calls.length === 1, "the compaction call");
    await expect(queuedCompaction).resolves.toEqual({ queued: true });
    await waitFor(() => !slot.isBusy, "the slot to go idle");
    const markers = (slot as unknown as { dependencies: { markers: RunMarkerStore } }).dependencies.markers;
    expect(await markers.evidenceFor(slot.id)).toEqual([]);
  });

  it("cancels pending compaction and drains its runtime during registry shutdown", async () => {
    const root = await mkdtemp(join(tmpdir(), "tron-queued-compaction-shutdown-"));
    const agentDir = join(root, "agent");
    const cwd = join(root, "workspace");
    await Promise.all([mkdir(agentDir), mkdir(cwd)]);
    let releaseResponse!: () => void;
    const responseBarrier = new Promise<void>((resolve) => { releaseResponse = resolve; });
    const faux = fauxProvider({ provider: "tron-queued-compaction-shutdown", tokensPerSecond: 10_000 });
    faux.setResponses([async () => {
      await responseBarrier;
      return fauxAssistantMessage("run complete");
    }]);
    const registry = new RuntimeRegistry({
      agentDir,
      tronHome: join(root, "tron"),
      idleRuntimeMs: 60_000,
      modelRuntimeFactory: async () => {
        const runtime = await ModelRuntime.create({ modelsPath: null, refreshOnCreate: false });
        runtime.registerNativeProvider(faux.provider);
        return runtime;
      },
      trust: new TrustService(agentDir),
      broadcast: () => {},
      sessionSummaryChanged: () => {},
      sessionListChanged: () => {},
    });
    registries.push(registry);
    await initializeRegistry(registry);
    const slot = await registry.create(cwd);
    const model = faux.getModel();
    await slot.setModel(model.provider, model.id);
    const session = (slot as unknown as {
      runtime: { session: { compact: (instructions?: string) => Promise<unknown> } };
    }).runtime.session;
    const compact = vi.spyOn(session, "compact").mockResolvedValue({});

    await slot.prompt("start");
    await waitFor(() => slot.isBusy, "the slot to take work");
    const queuedCompaction = slot.compact();
    const queuedOutcome = queuedCompaction.then(
      () => ({ status: "fulfilled" as const }),
      (error: unknown) => ({ status: "rejected" as const, error }),
    );
    await waitFor(() => slot.snapshot().compactionQueued === true, "the queued compaction");
    const shutdown = registry.dispose();
    releaseResponse();

    const outcome = await queuedOutcome;
    expect(outcome).toMatchObject({ status: "rejected", error: { code: "cancelled" } });
    await shutdown;
    expect(compact).not.toHaveBeenCalled();
    expect(registry.activeSessionIds()).toEqual([]);
    const index = registries.indexOf(registry);
    if (index >= 0) registries.splice(index, 1);
  });

  it("aborts and drains an in-flight direct compaction during registry shutdown", async () => {
    const root = await mkdtemp(join(tmpdir(), "tron-direct-compaction-shutdown-"));
    const agentDir = join(root, "agent");
    const cwd = join(root, "workspace");
    await Promise.all([mkdir(agentDir), mkdir(cwd)]);
    const registry = new RuntimeRegistry({
      agentDir,
      tronHome: join(root, "tron"),
      idleRuntimeMs: 60_000,
      modelRuntimeFactory: async () => ModelRuntime.create({ modelsPath: null, refreshOnCreate: false }),
      trust: new TrustService(agentDir),
      broadcast: () => {},
      sessionSummaryChanged: () => {},
      sessionListChanged: () => {},
    });
    registries.push(registry);
    await initializeRegistry(registry);
    const slot = await registry.create(cwd);
    let releaseCompaction!: () => void;
    const compactionBarrier = new Promise<void>((resolve) => { releaseCompaction = resolve; });
    const session = (slot as unknown as {
      runtime: { session: {
        compact: (instructions?: string) => Promise<unknown>;
        abortCompaction: () => void;
      } };
    }).runtime.session;
    vi.spyOn(session, "compact").mockImplementation(async () => {
      await compactionBarrier;
      return {};
    });
    const originalAbort = session.abortCompaction.bind(session);
    const abortCompaction = vi.spyOn(session, "abortCompaction").mockImplementation(() => {
      originalAbort();
      releaseCompaction();
    });

    const compaction = slot.compact();
    await waitFor(() => slot.snapshot().phase === "compacting", "the compacting phase");
    const shutdown = registry.dispose();
    await expect(compaction).resolves.toEqual({ queued: false });
    await shutdown;
    expect(abortCompaction).toHaveBeenCalled();
    expect(registry.activeSessionIds()).toEqual([]);
    const index = registries.indexOf(registry);
    if (index >= 0) registries.splice(index, 1);
  });

  it("closes global slot admission before draining an already-entered creation", async () => {
    const root = await mkdtemp(join(tmpdir(), "tron-registry-admission-shutdown-"));
    const agentDir = join(root, "agent");
    const cwd = join(root, "workspace");
    await Promise.all([mkdir(agentDir), mkdir(cwd)]);
    let factoryEntered!: () => void;
    let releaseFactory!: () => void;
    const factoryWasEntered = new Promise<void>((resolve) => { factoryEntered = resolve; });
    const factoryBarrier = new Promise<void>((resolve) => { releaseFactory = resolve; });
    const registry = new RuntimeRegistry({
      agentDir,
      tronHome: join(root, "tron"),
      idleRuntimeMs: 60_000,
      modelRuntimeFactory: async () => {
        factoryEntered();
        await factoryBarrier;
        return ModelRuntime.create({ modelsPath: null, refreshOnCreate: false });
      },
      trust: new TrustService(agentDir),
      broadcast: () => {},
      sessionSummaryChanged: () => {},
      sessionListChanged: () => {},
    });
    registries.push(registry);
    await initializeRegistry(registry);

    const creating = registry.create(cwd);
    await factoryWasEntered;
    let shutdownFinished = false;
    const shutdown = registry.dispose().then(() => { shutdownFinished = true; });
    await Promise.resolve();
    expect(shutdownFinished).toBe(false);
    await expect(registry.create(cwd)).rejects.toMatchObject({
      code: "conflict",
      message: "Session runtime registry is shutting down",
    });

    releaseFactory();
    const created = await creating;
    await shutdown;
    expect(shutdownFinished).toBe(true);
    expect(registry.activeSessionIds()).toEqual([]);
    expect((registry as unknown as { slots: Map<string, unknown> }).slots.size).toBe(0);
    await expect(registry.acquire(created.id)).rejects.toMatchObject({ code: "conflict" });
    const index = registries.indexOf(registry);
    if (index >= 0) registries.splice(index, 1);
  });

  it("preserves the admitted run marker when global shutdown forces interruption", async () => {
    const root = await mkdtemp(join(tmpdir(), "tron-forced-shutdown-marker-"));
    const agentDir = join(root, "agent");
    const cwd = join(root, "workspace");
    await Promise.all([mkdir(agentDir), mkdir(cwd)]);
    const faux = fauxProvider({ provider: "tron-forced-marker", tokensPerSecond: 10_000 });
    faux.setResponses([
      async () => { await new Promise((resolve) => setTimeout(resolve, 250)); return fauxAssistantMessage("late"); },
    ]);
    const runtime = await ModelRuntime.create({ modelsPath: null, refreshOnCreate: false });
    runtime.registerNativeProvider(faux.provider);
    const registry = new RuntimeRegistry({
      agentDir, tronHome: join(root, "tron"), idleRuntimeMs: 60_000,
      modelRuntimeFactory: async () => runtime, trust: new TrustService(agentDir),
      broadcast: () => {}, sessionSummaryChanged: () => {}, sessionListChanged: () => {},
    });
    registries.push(registry);
    await initializeRegistry(registry);
    const slot = await registry.create(cwd);
    const model = faux.getModel();
    await slot.setModel(model.provider, model.id);
    await slot.prompt("accepted work");
    await waitFor(() => slot.catalogPhase === "running", "the catalog phase to run");
    const sessionID = slot.id;
    await slot.shutdown();
    const markerStore = (registry as unknown as { markers: { interruptedSessionIds(): Promise<Set<string>> } }).markers;
    expect((await markerStore.interruptedSessionIds()).has(sessionID)).toBe(true);
  });

  it("does not tear down blob ownership before every captured slot drains", async () => {
    const root = await mkdtemp(join(tmpdir(), "tron-registry-blob-drain-order-"));
    const agentDir = join(root, "agent");
    const cwd = join(root, "workspace");
    await Promise.all([mkdir(agentDir), mkdir(cwd)]);
    const registry = new RuntimeRegistry({
      agentDir,
      tronHome: join(root, "tron"),
      idleRuntimeMs: 60_000,
      modelRuntimeFactory: async () => ModelRuntime.create({ modelsPath: null, refreshOnCreate: false }),
      trust: new TrustService(agentDir),
      broadcast: () => {},
      sessionSummaryChanged: () => {},
      sessionListChanged: () => {},
    });
    registries.push(registry);
    await initializeRegistry(registry);
    const slot = await registry.create(cwd);

    let shutdownEntered!: () => void;
    let releaseShutdown!: () => void;
    const shutdownWasEntered = new Promise<void>((resolve) => { shutdownEntered = resolve; });
    const shutdownBarrier = new Promise<void>((resolve) => { releaseShutdown = resolve; });
    const originalShutdown = slot.shutdown.bind(slot);
    let slotDrained = false;
    vi.spyOn(slot, "shutdown").mockImplementation(async () => {
      shutdownEntered();
      await shutdownBarrier;
      await originalShutdown();
      slotDrained = true;
    });
    const blobs = (registry as unknown as { blobs: { dispose: () => Promise<void> } }).blobs;
    const originalBlobDispose = blobs.dispose.bind(blobs);
    let blobDisposeStarted = false;
    vi.spyOn(blobs, "dispose").mockImplementation(async () => {
      blobDisposeStarted = true;
      expect(slotDrained).toBe(true);
      await originalBlobDispose();
    });

    const shutdown = registry.dispose();
    await shutdownWasEntered;
    expect(blobDisposeStarted).toBe(false);
    releaseShutdown();
    await shutdown;
    expect(slotDrained).toBe(true);
    expect(blobDisposeStarted).toBe(true);
    const index = registries.indexOf(registry);
    if (index >= 0) registries.splice(index, 1);
  });

  it("omits a terminal runtime overlay when its canonical result is outside the bounded tail", async () => {
    const fixture = await coldFixture("canonical-tool-ownership-backstop");
    fixture.manager.appendMessage({
      role: "toolResult",
      toolCallId: "canonical-old",
      toolName: "read",
      content: [{ type: "text", text: "canonical result" }],
      isError: true,
      timestamp: Date.now(),
    });
    const slot = await fixture.registry.acquire(fixture.manager.getSessionId());
    const internal = slot as unknown as {
      toolExecutions: Map<string, unknown>;
      toolMetadata: Map<string, unknown>;
      toolStartedAtMonotonicMs: Map<string, number>;
      activeOperationId?: string;
      activeToolSegmentOwnerId?: string;
      onEvent: (event: unknown) => void;
      runtime: { session: { readonly isStreaming: boolean } };
    };
    internal.toolExecutions.set("canonical-old", {
      toolCallId: "canonical-old", toolName: "read", order: 0, status: "running",
      arguments: null, isError: false, startedAt: new Date(0).toISOString(),
      updatedAt: new Date(0).toISOString(), lastProgressAt: new Date(0).toISOString(),
      progressSequence: 1,
    });
    const startedAt = new Date(Date.now() - 1_500).toISOString();
    const metadata = {
      startedAt,
      durationMs: 1_500,
      lastProgressAt: startedAt,
      progressSequence: 3,
      toolSegmentId: "tool-segment:retained",
      groupId: "tool-group:retained",
      groupIndex: 0,
      groupCount: 1,
      groupFinalized: true,
    };
    internal.toolMetadata.set("canonical-old", metadata);
    internal.toolStartedAtMonotonicMs.set("canonical-old", performance.now() - 1_500);
    // The full-branch backstop removes the live row even before the lifecycle
    // handoff reaches this slot; ownership does not depend on the bounded
    // transcript page containing the result.
    expect(slot.snapshot().toolExecutions).toEqual([]);
    const streaming = vi.spyOn(internal.runtime.session, "isStreaming", "get").mockReturnValue(true);
    // The handoff removes the live row immediately while preserving the
    // metadata map for canonical enrichment. A later terminal callback cannot
    // re-admit the exact ID.
    internal.onEvent({
      type: "message_end",
      message: {
        role: "toolResult", toolCallId: "canonical-old", toolName: "read",
        content: [{ type: "text", text: "canonical result" }], isError: true,
        timestamp: Date.now(),
      },
    });
    await Promise.resolve();
    expect(internal.toolExecutions.has("canonical-old")).toBe(false);
    expect(internal.toolMetadata.get("canonical-old")).toMatchObject({
      startedAt,
      durationMs: expect.any(Number),
      progressSequence: 3,
      toolSegmentId: "tool-segment:retained",
      groupId: "tool-group:retained",
    });
    const handoffDurationMs = (internal.toolMetadata.get("canonical-old") as { durationMs: number }).durationMs;
    expect(handoffDurationMs).toBeGreaterThanOrEqual(1_500);
    expect(internal.toolStartedAtMonotonicMs.has("canonical-old")).toBe(true);
    // A continuation clears old-run monotonic starts before a compatibility
    // terminal callback can arrive. The retained handoff sample must not grow
    // to callback-arrival wall time in that ordering.
    internal.toolStartedAtMonotonicMs.delete("canonical-old");
    internal.onEvent({
      type: "tool_execution_end", toolCallId: "canonical-old", toolName: "read",
      result: { content: [{ type: "text", text: "late terminal" }] }, isError: true,
    });
    expect(internal.toolExecutions.has("canonical-old")).toBe(false);
    expect(internal.toolMetadata.get("canonical-old")).toMatchObject({
      startedAt,
      completedAt: expect.any(String),
      durationMs: expect.any(Number),
      progressSequence: 4,
      toolSegmentId: "tool-segment:retained",
      groupId: "tool-group:retained",
      groupIndex: 0,
      groupCount: 1,
      groupFinalized: true,
    });
    expect((internal.toolMetadata.get("canonical-old") as { durationMs: number }).durationMs)
      .toBe(handoffDurationMs);
    expect(internal.toolStartedAtMonotonicMs.has("canonical-old")).toBe(false);
    expect(slot.snapshot().toolExecutions).toEqual([]);

    const silentStartedAt = new Date().toISOString();
    internal.toolExecutions.set("silent-running", {
      toolCallId: "silent-running", toolName: "bash", order: 1, status: "running",
      arguments: null, isError: false, startedAt: silentStartedAt,
      updatedAt: silentStartedAt, lastProgressAt: silentStartedAt,
      durationMs: 0, progressSequence: 1,
    });
    internal.toolStartedAtMonotonicMs.set("silent-running", performance.now() - 500);
    expect(slot.snapshot().toolExecutions.find((tool) => tool.toolCallId === "silent-running")?.durationMs)
      .toBeGreaterThanOrEqual(450);
    internal.toolExecutions.delete("silent-running");
    internal.toolStartedAtMonotonicMs.delete("silent-running");

    const notPersisted = {
      toolCallId: "not-persisted", toolName: "read", order: 1, status: "completed",
      arguments: null, isError: false, startedAt: new Date(0).toISOString(),
      updatedAt: new Date(0).toISOString(), lastProgressAt: new Date(0).toISOString(),
      progressSequence: 1,
    };
    internal.toolExecutions.set("not-persisted", notPersisted);
    internal.onEvent({
      type: "message_end",
      message: {
        role: "toolResult", toolCallId: "not-persisted", toolName: "read",
        content: [{ type: "text", text: "append failed" }], isError: false,
        timestamp: Date.now(),
      },
    });
    await Promise.resolve();
    expect(internal.toolExecutions.get("not-persisted")).toEqual(notPersisted);
    internal.toolExecutions.delete("not-persisted");

    internal.toolMetadata.set("reused-after-interruption", {
      startedAt: new Date(0).toISOString(), completedAt: new Date(1_000).toISOString(),
      durationMs: 1_000, lastProgressAt: new Date(1_000).toISOString(), progressSequence: 9,
      toolSegmentId: "tool-segment:stale", groupId: "tool-group:stale",
      groupIndex: 0, groupCount: 1, groupFinalized: true,
    });
    internal.activeOperationId = "fresh-operation";
    internal.activeToolSegmentOwnerId = "fresh-operation";
    internal.onEvent({
      type: "tool_execution_start", toolCallId: "reused-after-interruption",
      toolName: "read", args: { path: "fresh" },
    });
    expect(internal.toolMetadata.get("reused-after-interruption")).toMatchObject({
      startedAt: expect.not.stringContaining("1970-01-01"),
      durationMs: expect.any(Number),
      progressSequence: 1,
      toolSegmentId: "tool-segment:\"fresh-operation\"",
    });
    expect(internal.toolMetadata.get("reused-after-interruption")).not.toMatchObject({
      completedAt: expect.anything(), groupId: "tool-group:stale",
    });
    internal.toolExecutions.delete("reused-after-interruption");
    internal.toolMetadata.delete("reused-after-interruption");
    internal.toolStartedAtMonotonicMs.delete("reused-after-interruption");
    internal.activeOperationId = undefined;
    internal.activeToolSegmentOwnerId = undefined;
    streaming.mockRestore();
  });

  it("aborts the exact foreground bash tree even when the client reports a stale bash kind", async () => {
    if (process.platform === "win32") return;
    const root = await mkdtemp(join(tmpdir(), "tron-foreground-bash-abort-"));
    const agentDir = join(root, "agent");
    const sessionDir = join(root, "sessions");
    const cwd = join(root, "workspace");
    await Promise.all([mkdir(agentDir), mkdir(sessionDir), mkdir(cwd)]);
    await writeFile(join(agentDir, "settings.json"), JSON.stringify({ sessionDir }));

    const detachedPidPath = join(cwd, "detached.pid");
    const childProgram = "setInterval(() => {}, 1000)";
    const parentProgram = [
      "const { spawn } = require('node:child_process');",
      "const { writeFileSync } = require('node:fs');",
      `const child = spawn(${JSON.stringify(process.execPath)}, ['-e', ${JSON.stringify(childProgram)}], { detached: true, stdio: 'ignore' });`,
      `writeFileSync(${JSON.stringify(detachedPidPath)}, String(child.pid));`,
      "setInterval(() => {}, 1000);",
    ].join(" ");
    const command = `${JSON.stringify(process.execPath)} -e ${JSON.stringify(parentProgram)}`;
    const faux = fauxProvider({ provider: "tron-foreground-bash-abort", tokensPerSecond: 10_000 });
    faux.setResponses([
      fauxAssistantMessage([fauxToolCall("bash", { command }, { id: "call-owned-bash" })], { stopReason: "toolUse" }),
    ]);
    const registry = new RuntimeRegistry({
      agentDir,
      tronHome: join(root, "tron"),
      idleRuntimeMs: 60_000,
      modelRuntimeFactory: async () => {
        const runtime = await ModelRuntime.create({ modelsPath: null, refreshOnCreate: false });
        runtime.registerNativeProvider(faux.provider);
        return runtime;
      },
      trust: new TrustService(agentDir),
      broadcast: () => {},
      sessionSummaryChanged: () => {},
      sessionListChanged: () => {},
    });
    registries.push(registry);
    await initializeRegistry(registry);
    const slot = await registry.create(cwd);
    const model = faux.getModel();
    await slot.setModel(model.provider, model.id);

    const prompting = slot.prompt("run the owned command");
    await waitFor(() => existsSync(detachedPidPath), "the detached process id file");
    const detachedPid = Number(await readFile(detachedPidPath, "utf8"));
    expect(() => process.kill(detachedPid, 0)).not.toThrow();
    const operationId = slot.snapshot().operation?.id;
    expect(operationId).toBeDefined();

    // Mobile derives this advisory kind from a snapshot. A stale `.bash`
    // classification must not bypass the agent run or exact process owner.
    await slot.abort("bash", operationId);
    await expect(prompting).resolves.toMatchObject({ operationId });
    await waitFor(() => {
      try { process.kill(detachedPid, 0); return false; }
      catch { return true; }
    }, "the detached process to exit");
    expect(slot.snapshot().toolExecutions).toEqual([]);
  });

  it.each(["no-effect", "successful-read"] as const)("deadline-stops endless %s turns without losing canonical usage or allowing later effects", async (scenario) => {
      let fixture: Awaited<ReturnType<typeof ownedDeadlineFixture>> | undefined;
      let owned: Awaited<ReturnType<typeof startOwnedOperation>> | undefined;
      try {
        const faux = fauxProvider({ provider: `tron-owned-deadline-${scenario}`, tokensPerSecond: 10_000 });
        fixture = await ownedDeadlineFixture(`loop-${scenario}`, faux);
        const readPath = join(fixture.cwd, "readable.txt");
        await writeFile(readPath, "canonical read payload\n");
        let turns = 0;
        const MAX_SIMULATED_TURNS = 256;
        const response = () => {
          turns += 1;
          if (turns < MAX_SIMULATED_TURNS) faux.appendResponses([response]);
          return fauxAssistantMessage([
            fauxToolCall("read", { path: scenario === "no-effect" ? join(fixture!.cwd, "missing.txt") : readPath }, { id: `read-${turns}` }),
          ], { stopReason: "toolUse" });
        };
        faux.setResponses([response]);
        owned = await startOwnedOperation(fixture.slot, fixture.registry, "continue until stopped");
        const { operationId, handle } = owned;
        await waitFor(() => turns >= 3, `${scenario} provider turns`);
        const beforeUsage = (fixture.slot as any).runtime.session.sessionManager.getBranch()
          .filter((entry: any) => entry.type === "message" && entry.message?.role === "assistant")
          .reduce((total: number, entry: any) => total + (entry.message.usage?.input ?? 0) + (entry.message.usage?.output ?? 0), 0);
        expect(beforeUsage).toBeGreaterThan(0);
        const diagnostics: unknown[] = [];
        const dispatch = new OwnedSessionDispatch(fixture.registry, { diagnostic: (record) => diagnostics.push(record) });
        vi.useFakeTimers();
        const stopped = dispatch.enforceDeadline(handle as any);
        await vi.advanceTimersByTimeAsync(OWNED_OPERATION_DEADLINE_MS);
        const outcome = await stopped;
        vi.useRealTimers();
        expect(outcome).toMatchObject({ state: "deadline-stopped", terminal: { lifecycle: "interrupted" } });
        expect(diagnostics).toMatchObject([{ event: "owned-operation.deadline-stop", cancelAndJoin: "joined" }]);
        const turnsAtStop = turns;
        const entriesAtStop = (fixture.slot as any).runtime.session.sessionManager.getBranch().length;
        await new Promise((resolve) => setTimeout(resolve, 50));
        expect(turns).toBe(turnsAtStop);
        expect((fixture.slot as any).runtime.session.sessionManager.getBranch()).toHaveLength(entriesAtStop);
        const afterUsage = (fixture.slot as any).runtime.session.sessionManager.getBranch()
          .filter((entry: any) => entry.type === "message" && entry.message?.role === "assistant")
          .reduce((total: number, entry: any) => total + (entry.message.usage?.input ?? 0) + (entry.message.usage?.output ?? 0), 0);
        expect(afterUsage).toBeGreaterThanOrEqual(beforeUsage);
        expect(afterUsage).toBeGreaterThan(0);
        await new Promise((resolve) => setTimeout(resolve, 50));
        const usageAfterQuiescence = (fixture.slot as any).runtime.session.sessionManager.getBranch()
          .filter((entry: any) => entry.type === "message" && entry.message?.role === "assistant")
          .reduce((total: number, entry: any) => total + (entry.message.usage?.input ?? 0) + (entry.message.usage?.output ?? 0), 0);
        expect(usageAfterQuiescence).toBe(afterUsage);
        expect(fixture.slot.snapshot().operation?.id).not.toBe(operationId);
        ownedDeadlineReportCases.push({
          scenario, terminal: "deadline-stopped", turnsAtStop, usageTokens: afterUsage,
          noFurtherTurns: turns === turnsAtStop, noFurtherCanonicalEntries: entriesAtStop === (fixture.slot as any).runtime.session.sessionManager.getBranch().length,
        });
      } finally {
        vi.useRealTimers();
        if (fixture && owned && fixture.slot.isBusy) await owned.handle.cancel().catch(() => {});
        if (fixture) {
          await fixture.registry.dispose();
          const index = registries.indexOf(fixture.registry);
          if (index >= 0) registries.splice(index, 1);
          await rm(fixture.root, { recursive: true, force: true });
        }
      }
  }, 30_000);

  it("deadline-cancels a faux provider request blocked in flight", async () => {
    let requestStarted!: () => void;
    const started = new Promise<void>((resolve) => { requestStarted = resolve; });
    let providerAborted = false;
    const faux = fauxProvider({ provider: "tron-owned-deadline-blocked", tokensPerSecond: 10_000 });
    faux.setResponses([(_context, options) => new Promise((_resolve, reject) => {
      requestStarted();
      options?.signal?.addEventListener("abort", () => {
        providerAborted = true;
        reject(new Error("blocked faux request aborted"));
      }, { once: true });
    })]);
    const fixture = await ownedDeadlineFixture("blocked-provider", faux);
    let owned: Awaited<ReturnType<typeof startOwnedOperation>> | undefined;
    try {
      owned = await startOwnedOperation(fixture.slot, fixture.registry, "wait for blocked provider");
      const { handle } = owned;
      await started;
      const dispatch = new OwnedSessionDispatch(fixture.registry);
      vi.useFakeTimers();
      const stopped = dispatch.enforceDeadline(handle as any);
      await vi.advanceTimersByTimeAsync(OWNED_OPERATION_DEADLINE_MS);
      await expect(stopped).resolves.toMatchObject({ state: "deadline-stopped" });
      vi.useRealTimers();
      expect(providerAborted).toBe(true);
      expect(fixture.slot.isBusy).toBe(false);
      ownedDeadlineReportCases.push({ scenario: "blocked-provider", terminal: "deadline-stopped", providerAborted, slotIdle: !fixture.slot.isBusy });
    } finally {
      vi.useRealTimers();
      if (owned && fixture.slot.isBusy) await owned.handle.cancel().catch(() => {});
      await fixture.registry.dispose();
      const index = registries.indexOf(fixture.registry);
      if (index >= 0) registries.splice(index, 1);
      await rm(fixture.root, { recursive: true, force: true });
    }
  }, 30_000);

  it.skipIf(process.platform === "win32")("deadline-cancels and joins an operation-owned foreground bash process", async () => {
    const faux = fauxProvider({ provider: "tron-owned-deadline-foreground", tokensPerSecond: 10_000 });
    const fixture = await ownedDeadlineFixture("foreground-bash", faux);
    let owned: Awaited<ReturnType<typeof startOwnedOperation>> | undefined;
    const pidPath = join(fixture.cwd, "sleep.pid");
    faux.setResponses([fauxAssistantMessage([
      fauxToolCall("bash", { command: `sleep 120 & echo $! > ${JSON.stringify(pidPath)}; wait` }, { id: "owned-sleep" }),
    ], { stopReason: "toolUse" })]);
    try {
      owned = await startOwnedOperation(fixture.slot, fixture.registry, "run foreground process");
      const { handle } = owned;
      await waitFor(() => existsSync(pidPath), "the operation-owned sleep PID file");
      const pid = Number(await readFile(pidPath, "utf8"));
      expect(() => process.kill(pid, 0)).not.toThrow();
      const dispatch = new OwnedSessionDispatch(fixture.registry);
      vi.useFakeTimers();
      const stopped = dispatch.enforceDeadline(handle as any);
      await vi.advanceTimersByTimeAsync(OWNED_OPERATION_DEADLINE_MS);
      await expect(stopped).resolves.toMatchObject({ state: "deadline-stopped" });
      vi.useRealTimers();
      expect(() => process.kill(pid, 0)).toThrow();
      expect(fixture.slot.isBusy).toBe(false);
      ownedDeadlineReportCases.push({ scenario: "foreground-process", terminal: "deadline-stopped", childJoined: true, slotIdle: !fixture.slot.isBusy });
    } finally {
      vi.useRealTimers();
      if (owned && fixture.slot.isBusy) await owned.handle.cancel().catch(() => {});
      await fixture.registry.dispose();
      const index = registries.indexOf(fixture.registry);
      if (index >= 0) registries.splice(index, 1);
      await rm(fixture.root, { recursive: true, force: true });
    }
  }, 30_000);

  it("projects stable ordinals for parallel tools from start through completion", async () => {
    const root = await mkdtemp(join(tmpdir(), "tron-tool-order-integration-"));
    const agentDir = join(root, "agent");
    const sessionDir = join(root, "sessions");
    const cwd = join(root, "workspace");
    await Promise.all([mkdir(agentDir), mkdir(sessionDir), mkdir(cwd)]);
    await writeFile(join(agentDir, "settings.json"), JSON.stringify({ sessionDir }));

    const faux = fauxProvider({ provider: "tron-tool-order", tokensPerSecond: 10_000 });
    const createModels = async () => {
      const runtime = await ModelRuntime.create({ modelsPath: null, refreshOnCreate: false });
      runtime.registerNativeProvider(faux.provider);
      return runtime;
    };
    faux.setResponses([
      fauxAssistantMessage([
        fauxToolCall("read", { path: join(cwd, "one.txt") }, { id: "call-read" }),
        fauxToolCall("bash", { command: "printf start; sleep 0.35; printf end" }, { id: "call-bash" }),
      ], { stopReason: "toolUse" }),
      fauxAssistantMessage("finished"),
    ]);
    await writeFile(join(cwd, "one.txt"), "one\n");
    const events: Array<{ topic: string; payload: any }> = [];
    const registry = new RuntimeRegistry({
      agentDir,
      tronHome: join(root, "tron"),
      idleRuntimeMs: 60_000,
      modelRuntimeFactory: createModels,
      trust: new TrustService(agentDir),
      broadcast: (_sessionId, topic, payload) => events.push({ topic, payload }),
      sessionSummaryChanged: () => {},
      sessionListChanged: () => {},
    });
    registries.push(registry);
    await initializeRegistry(registry);
    const slot = await registry.create(cwd);
    subscribeAudience(registry, slot.id);
    const model = faux.getModel();
    await slot.setModel(model.provider, model.id);
    const prompting = slot.prompt("run tools");
    await waitFor(() => slot.snapshot().toolExecutions.some((tool) => tool.status === "running"), "a running tool execution");
    const activeSnapshot = slot.snapshot();
    expect(activeSnapshot.activeToolSegmentId).toBeDefined();
    expect(activeSnapshot.acceptsQueuedPrompts).toBe(true);
    expect(activeSnapshot.toolExecutions.every(
      (tool) => tool.toolSegmentId === activeSnapshot.activeToolSegmentId,
    )).toBe(true);
    await prompting;
    await waitFor(() => !slot.isBusy, "the slot to go idle");
    expect(slot.snapshot().activeToolSegmentId).toBeUndefined();
    await waitFor(() => registry.attentionProjection(slot.id).isUnread, "the unread attention mark");
    expect(registry.attentionProjection(slot.id).completionRevision).toBe(1);

    const progress = events
      .filter((event) => event.topic === "session.toolProgress")
      .map((event) => event.payload.data as {
        toolCallId: string;
        order: number;
        status: string;
        output?: string;
        progressSequence: number;
        durationMs?: number;
        completedAt?: string;
        toolSegmentId?: string;
        groupId?: string;
        groupIndex?: number;
        groupCount?: number;
        groupFinalized?: boolean;
      });
    const finalizedProgressIndex = events.findIndex((event) => {
      if (event.topic !== "session.progress") return false;
      const message = event.payload.data?.message;
      const calls = message?.content?.filter((part: any) => part.type === "toolCall") ?? [];
      return calls.length === 2 && calls.every((part: any) => part.groupFinalized === true);
    });
    const firstToolProgressIndex = events.findIndex((event) => event.topic === "session.toolProgress");
    expect(finalizedProgressIndex).toBeGreaterThanOrEqual(0);
    expect(firstToolProgressIndex).toBeGreaterThan(finalizedProgressIndex);

    const firstRunning = new Map<string, number>();
    for (const event of progress) {
      if (event.status === "running" && !firstRunning.has(event.toolCallId)) firstRunning.set(event.toolCallId, event.order);
    }
    expect(firstRunning).toEqual(new Map([["call-read", 0], ["call-bash", 1]]));
    const finalOrder = new Map(progress.map((event) => [event.toolCallId, event.order]));
    expect(finalOrder).toEqual(new Map([["call-read", 0], ["call-bash", 1]]));
    const grouped = progress.filter((event) => event.groupFinalized === true);
    expect(grouped.length).toBeGreaterThanOrEqual(2);
    expect(new Set(grouped.map((event) => event.groupId)).size).toBe(1);
    expect(new Set(grouped.map((event) => event.toolSegmentId)).size).toBe(1);
    expect(grouped.every((event) => event.toolSegmentId?.startsWith("tool-segment:") === true)).toBe(true);
    expect(new Set(grouped.map((event) => event.groupCount))).toEqual(new Set([2]));
    expect(new Map(grouped.map((event) => [event.toolCallId, event.groupIndex])))
      .toEqual(new Map([["call-read", 0], ["call-bash", 1]]));
    const bashProgress = progress.filter((event) => event.toolCallId === "call-bash");
    expect(bashProgress.some((event) => event.status === "running" && event.output?.includes("start"))).toBe(true);
    const runningDurations = bashProgress
      .filter((event) => event.status === "running")
      .map((event) => event.durationMs);
    expect(runningDurations.length).toBeGreaterThan(0);
    expect(runningDurations.every((duration) => typeof duration === "number" && duration >= 0)).toBe(true);
    expect(runningDurations).toEqual([...runningDurations].sort((left, right) => left! - right!));
    expect(bashProgress.at(-1)).toMatchObject({ status: "completed", output: "startend" });
    expect(bashProgress.at(-1)!.progressSequence).toBeGreaterThan(2);
    expect(bashProgress.at(-1)!.durationMs).toBeGreaterThanOrEqual(300);
    expect(bashProgress.at(-1)!.completedAt).toBeTypeOf("string");
    expect(events.filter((event) => event.topic === "session.processActivity")).toEqual([]);
    const activeSnapshots = events
      .filter((event) => event.topic === "session.snapshot")
      .map((event) => (event.payload?.data ?? event.payload) as {
        phase?: string;
        transcript?: Array<{ kind?: string; role?: string; toolCallId?: string }>;
        toolExecutions?: Array<{ toolCallId: string }>;
      })
      .filter((snapshot) => snapshot.phase === "running");
    // A sibling remains authoritative while one call transfers from terminal
    // runtime evidence to its canonical toolResult. There must be no active
    // snapshot in which the settled call is absent from both sources.
    expect(activeSnapshots.some((snapshot) => {
      const runtimeRead = snapshot.toolExecutions?.some((tool) => tool.toolCallId === "call-read");
      const runtimeBash = snapshot.toolExecutions?.some((tool) => tool.toolCallId === "call-bash");
      return runtimeRead === true && runtimeBash === true;
    })).toBe(true);
    expect(activeSnapshots.some((snapshot) => {
      const canonicalRead = snapshot.transcript?.some((item) =>
        item.kind === "message" && item.role === "toolResult" && item.toolCallId === "call-read");
      const canonicalBash = snapshot.transcript?.some((item) =>
        item.kind === "message" && item.role === "toolResult" && item.toolCallId === "call-bash");
      return canonicalRead === true && canonicalBash === true;
    })).toBe(true);
    const snapshotsAfterAdmission = activeSnapshots.filter((snapshot) => {
      const canonicalRead = snapshot.transcript?.some((item) =>
        item.kind === "message" && item.role === "toolResult" && item.toolCallId === "call-read");
      const runtimeRead = snapshot.toolExecutions?.some((tool) => tool.toolCallId === "call-read");
      return canonicalRead === true || runtimeRead === true;
    });
    expect(snapshotsAfterAdmission.length).toBeGreaterThan(0);
    expect(snapshotsAfterAdmission.every((snapshot) => {
      const canonicalRead = snapshot.transcript?.some((item) =>
        item.kind === "message" && item.role === "toolResult" && item.toolCallId === "call-read");
      const runtimeRead = snapshot.toolExecutions?.some((tool) => tool.toolCallId === "call-read");
      return canonicalRead === true || runtimeRead === true;
    })).toBe(true);
    expect(activeSnapshots.every((snapshot) => {
      const canonicalIDs = new Set((snapshot.transcript ?? [])
        .filter((item) => item.kind === "message" && item.role === "toolResult")
        .map((item) => item.toolCallId)
        .filter((id): id is string => typeof id === "string"));
      return !(snapshot.toolExecutions ?? []).some((tool) => canonicalIDs.has(tool.toolCallId));
    })).toBe(true);
    const settled = slot.snapshot();
    expect(settled.toolExecutions).toEqual([]);
    expect(settled.processOverview).toMatchObject({ visibility: "hidden", activeCount: 0, recentCount: 0 });
    expect(settled.processActivities ?? []).toEqual([]);
    expect(slot.processHistory(undefined, 25, { kind: "command" }).activities).toEqual([]);
    const canonicalAssistant = settled.transcript.find((item) => item.kind === "message" && item.role === "assistant");
    const canonicalCalls = canonicalAssistant?.kind === "message"
      ? canonicalAssistant.content.filter((part) => part.type === "toolCall")
      : [];
    expect(canonicalCalls).toHaveLength(2);
    expect(canonicalCalls.every((part) => part.type === "toolCall" && part.groupFinalized === true)).toBe(true);
    expect(new Set(canonicalCalls.flatMap((part) => part.type === "toolCall" ? [part.groupId] : [])).size).toBe(1);
    const canonicalSegmentIDs = new Set(canonicalCalls.flatMap((part) =>
      part.type === "toolCall" ? [part.toolSegmentId] : []
    ));
    expect(canonicalSegmentIDs.size).toBe(1);
    expect(canonicalSegmentIDs).toEqual(new Set(grouped.map((event) => event.toolSegmentId)));
    expect(settled.transcript.find((item) => item.kind === "message" && item.role === "toolResult" && item.toolCallId === "call-bash"))
      .toMatchObject({ durationMs: expect.any(Number), startedAt: expect.any(String), completedAt: expect.any(String) });
    expect(slot.sessionFile?.startsWith(sessionDir)).toBe(true);
  });

  it("projects codemode nested calls live and after a cold reload", async () => {
    const root = await mkdtemp(join(tmpdir(), "tron-nested-tools-e2e-"));
    const agentDir = join(root, "agent");
    const sessionDir = join(root, "sessions");
    const cwd = join(root, "workspace");
    const extensions = join(cwd, ".pi", "extensions");
    // Recursive extension setup owns its parent too; a simultaneous plain
    // mkdir(cwd) races that creation and can fail before the journey begins.
    await Promise.all([
      mkdir(agentDir), mkdir(sessionDir), mkdir(extensions, { recursive: true }),
    ]);
    await writeFile(join(agentDir, "settings.json"), JSON.stringify({ sessionDir, defaultTools: ["+codemode"] }));
    const sdkUrl = import.meta.resolve("@earendil-works/pi-coding-agent");
    await Promise.all([
      writeFile(join(extensions, "codemode.ts"), `import { createCodemodeExtension } from ${JSON.stringify(sdkUrl)}; export default createCodemodeExtension({ mode: "on" });\n`),
      writeFile(join(extensions, "failing-tool.ts"), `export default function (pi) { pi.registerTool({ name: "test_fail", label: "Fail fixture", description: "Fails without throwing", parameters: { type: "object", properties: {} }, execute: async () => ({ content: [{ type: "text", text: "expected failure" }], details: {}, usage: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0, totalTokens: 0, cost: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0, total: 0.125 } }, isError: true }) }); }\n`),
      writeFile(join(cwd, "read-me.txt"), "faux-provider nested read\n"),
    ]);
    const trust = new TrustService(agentDir);
    await trust.set(cwd, true);
    const faux = fauxProvider({ provider: "tron-nested-tools", tokensPerSecond: 10_000 });
    const createModels = async () => {
      const runtime = await ModelRuntime.create({ modelsPath: null, refreshOnCreate: false });
      runtime.registerNativeProvider(faux.provider);
      return runtime;
    };
    const script = `const results = await Promise.all([\n      tools.read({ path: "read-me.txt" }),\n      tools.bash({ command: "sleep 0.2; printf nested-bash" }),\n      tools.test_fail({}).catch((error) => String(error)),\n    ]); return results.map((result) => text(result)).join("\\n");`;
    faux.setResponses([
      fauxAssistantMessage([fauxToolCall("codemode", { code: script }, { id: "codemode-parent" })], { stopReason: "toolUse" }),
      fauxAssistantMessage([fauxToolCall("test_fail", {}, { id: "top-level-fail" })], { stopReason: "toolUse" }),
      fauxAssistantMessage("done"),
    ]);
    const events: Array<{ topic: string; payload: any }> = [];
    const makeRegistry = () => new RuntimeRegistry({
      agentDir, tronHome: join(root, "tron"), idleRuntimeMs: 60_000,
      modelRuntimeFactory: createModels, trust,
      broadcast: (_sessionId, topic, payload) => events.push({ topic, payload }),
      sessionSummaryChanged: () => {}, sessionListChanged: () => {},
    });
    let registry = makeRegistry();
    registries.push(registry);
    await initializeRegistry(registry);
    let slot = await registry.create(cwd);
    subscribeAudience(registry, slot.id);
    const model = faux.getModel();
    await slot.setModel(model.provider, model.id);
    const prompting = slot.prompt("run nested tools");
    await waitFor(() => slot.snapshot().toolExecutions.some((tool) =>
      tool.toolCallId === "codemode-parent" && (tool.nestedCalls?.calls.length ?? 0) === 3), "the codemode parent's nested calls");
    const live = slot.snapshot();
    const liveParent = live.toolExecutions.find((tool) => tool.toolCallId === "codemode-parent");
    expect(liveParent?.nestedCalls?.calls.map((call) => call.toolName).sort()).toEqual(["bash", "read", "test_fail"]);
    expect(live.toolExecutions.map((tool) => tool.toolCallId)).toEqual(["codemode-parent"]);
    await prompting;
    await waitFor(() => !slot.isBusy, "the slot to go idle");
    const settled = slot.snapshot();
    const canonicalParent = settled.transcript.find((item) =>
      item.kind === "message" && item.role === "toolResult" && item.toolCallId === "codemode-parent");
    expect(canonicalParent).toMatchObject({
      kind: "message", role: "toolResult", isError: false,
      usage: { cost: { total: 0.125 } },
      nestedCalls: { complete: true, calls: [
        { id: "codemode-parent/1", toolName: "read", status: "completed" },
        { id: "codemode-parent/2", toolName: "bash", status: "completed" },
        { id: "codemode-parent/3", toolName: "test_fail", status: "failed" },
      ] },
    });
    expect(settled.stats.cost).toBeGreaterThanOrEqual(0.125);
    expect(settled.transcript.find((item) =>
      item.kind === "message" && item.role === "toolResult" && item.toolCallId === "top-level-fail"))
      .toMatchObject({ isError: true });
    expect(events.some((event) => event.topic === "session.toolProgress"
      && event.payload.data?.toolCallId === "top-level-fail"
      && event.payload.data?.status === "failed")).toBe(true);
    const liveSnapshot = JSON.parse(JSON.stringify(live));
    await registry.dispose();
    registry = makeRegistry();
    registries.push(registry);
    await initializeRegistry(registry);
    slot = await registry.acquire(slot.id);
    const reloaded = slot.snapshot();
    const reloadedParent = reloaded.transcript.find((item) =>
      item.kind === "message" && item.role === "toolResult" && item.toolCallId === "codemode-parent");
    expect(reloadedParent).toMatchObject({
      role: "toolResult",
      nestedCalls: { complete: true, calls: [
        { id: "codemode-parent/1", status: "completed" },
        { id: "codemode-parent/2", status: "completed" },
        { id: "codemode-parent/3", status: "failed" },
      ] },
    });
    expect(reloaded.toolExecutions).toEqual([]);
    const artifactPath = join(process.cwd(), "test-results", "pi-sdk-099-nested-calls.json");
    await mkdir(dirname(artifactPath), { recursive: true });
    await writeFile(artifactPath, `${JSON.stringify({ live: liveSnapshot, reloaded: reloadedParent }, null, 2)}\n`);
  });

  it("projects every nested call Pi records, live and after a cold reload, within one argument budget", async () => {
    // Failure modes: the Gateway drops calls Pi kept (it projected only the
    // first 32 of Pi's 256), so a long script's call list is cut short; or a
    // long list of calls with large arguments makes every live frame unbounded.
    const root = await mkdtemp(join(tmpdir(), "tron-nested-call-list-e2e-"));
    const agentDir = join(root, "agent");
    const sessionDir = join(root, "sessions");
    const cwd = join(root, "workspace");
    const extensions = join(cwd, ".pi", "extensions");
    await Promise.all([mkdir(agentDir), mkdir(sessionDir), mkdir(extensions, { recursive: true })]);
    await writeFile(join(agentDir, "settings.json"), JSON.stringify({ sessionDir, defaultTools: ["+codemode"] }));
    const sdkUrl = import.meta.resolve("@earendil-works/pi-coding-agent");
    await Promise.all([
      writeFile(join(extensions, "codemode.ts"), `import { createCodemodeExtension } from ${JSON.stringify(sdkUrl)}; export default createCodemodeExtension({ mode: "on" });\n`),
      writeFile(join(extensions, "echo-tool.ts"), `export default function (pi) { pi.registerTool({ name: "test_echo", label: "Echo fixture", description: "Returns ok", parameters: { type: "object", properties: { note: { type: "string" } } }, execute: async () => ({ content: [{ type: "text", text: "ok" }], details: {} }) }); }\n`),
    ]);
    const trust = new TrustService(agentDir);
    await trust.set(cwd, true);
    const faux = fauxProvider({ provider: "tron-nested-call-list", tokensPerSecond: 10_000 });
    const createModels = async () => {
      const runtime = await ModelRuntime.create({ modelsPath: null, refreshOnCreate: false });
      runtime.registerNativeProvider(faux.provider);
      return runtime;
    };
    // 48 small calls, then 40 calls whose ~900-byte arguments pass the
    // per-call bound but together exceed the 32 KiB argument budget.
    const script = `for (let i = 0; i < 48; i++) await tools.test_echo({ note: "small " + i });\n`
      + `for (let i = 0; i < 40; i++) await tools.test_echo({ note: "x".repeat(900) + i });\nreturn "done";`;
    faux.setResponses([
      fauxAssistantMessage([fauxToolCall("codemode", { code: script }, { id: "codemode-list" })], { stopReason: "toolUse" }),
      fauxAssistantMessage("done"),
    ]);
    const liveFrames: Array<{ calls: Array<{ arguments?: unknown }>; complete: boolean }> = [];
    const makeRegistry = () => new RuntimeRegistry({
      agentDir, tronHome: join(root, "tron"), idleRuntimeMs: 60_000, modelRuntimeFactory: createModels, trust,
      broadcast: (_sessionId, topic, payload: any) => {
        if (topic === "session.toolProgress" && payload.data?.toolCallId === "codemode-list" && payload.data.nestedCalls) {
          liveFrames.push(payload.data.nestedCalls);
        }
      },
      sessionSummaryChanged: () => {}, sessionListChanged: () => {},
    });
    let registry = makeRegistry();
    registries.push(registry);
    await initializeRegistry(registry);
    let slot = await registry.create(cwd);
    subscribeAudience(registry, slot.id);
    const model = faux.getModel();
    await slot.setModel(model.provider, model.id);
    await slot.prompt("run many nested calls");
    await waitFor(() => !slot.isBusy, "the slot to go idle");

    const argumentBytes = (calls: Array<{ arguments?: unknown }>) =>
      calls.reduce((total, call) => total + (call.arguments === undefined ? 0 : Buffer.byteLength(JSON.stringify(call.arguments))), 0);
    const largestLive = liveFrames.reduce((most, frame) => frame.calls.length > most.calls.length ? frame : most, liveFrames[0]!);
    expect(largestLive.calls).toHaveLength(88);
    expect(liveFrames.every((frame) => argumentBytes(frame.calls) <= 32 * 1024)).toBe(true);
    const parentOf = (snapshot: ReturnType<typeof slot.snapshot>) => snapshot.transcript.find((item) =>
      item.kind === "message" && item.role === "toolResult" && item.toolCallId === "codemode-list");
    const canonical = parentOf(slot.snapshot());
    const canonicalCalls = canonical?.kind === "message" ? canonical.nestedCalls?.calls ?? [] : [];
    expect(canonicalCalls).toHaveLength(88);
    expect(canonicalCalls.slice(0, 48).every((call) => call.arguments !== undefined)).toBe(true);
    expect(argumentBytes(canonicalCalls)).toBeLessThanOrEqual(32 * 1024);
    expect(canonicalCalls.some((call) => call.arguments === undefined && typeof call.argumentsBytes === "number")).toBe(true);

    await registry.dispose();
    registry = makeRegistry();
    registries.push(registry);
    await initializeRegistry(registry);
    slot = await registry.acquire(slot.id);
    const reloaded = parentOf(slot.snapshot());
    const reloadedCalls = reloaded?.kind === "message" ? reloaded.nestedCalls?.calls ?? [] : [];
    expect(reloadedCalls.map((call) => call.id)).toEqual(canonicalCalls.map((call) => call.id));
  });

  it("returns Pi structured bash output through nested codemode calls", async () => {
    const root = await mkdtemp(join(tmpdir(), "tron-codemode-bash-output-e2e-"));
    const agentDir = join(root, "agent");
    const sessionDir = join(root, "sessions");
    const cwd = join(root, "workspace");
    const extensions = join(cwd, ".pi", "extensions");
    await Promise.all([
      mkdir(agentDir), mkdir(sessionDir), mkdir(extensions, { recursive: true }),
    ]);
    await writeFile(join(agentDir, "settings.json"), JSON.stringify({ sessionDir, defaultTools: ["+codemode"] }));
    const sdkUrl = import.meta.resolve("@earendil-works/pi-coding-agent");
    await writeFile(join(extensions, "codemode.ts"), `import { createCodemodeExtension } from ${JSON.stringify(sdkUrl)}; export default createCodemodeExtension({ mode: "on" });\n`);
    const faux = fauxProvider({ provider: "tron-codemode-bash-output", tokensPerSecond: 10_000 });
    const createModels = async () => {
      const runtime = await ModelRuntime.create({ modelsPath: null, refreshOnCreate: false });
      runtime.registerNativeProvider(faux.provider);
      return runtime;
    };
    const script = [
      'const large = await tools.bash({ command: "yes x | head -c 1100000" });',
      'const empty = await tools.bash({ command: "true" });',
      'const failed = await tools.bash({ command: "printf failed-output; exit 7" }).catch((error) => ({ error: String(error) }));',
      'return JSON.stringify({ large: { outputLength: large.output.length, truncated: large.truncated, full_output_path: large.full_output_path, exit_code: large.exit_code, wall_time_seconds: large.wall_time_seconds }, empty, failed });',
    ].join("\n");
    faux.setResponses([
      fauxAssistantMessage([fauxToolCall("codemode", { code: script }, { id: "codemode-bash-output" })], { stopReason: "toolUse" }),
      fauxAssistantMessage("done"),
    ]);
    const trust = new TrustService(agentDir);
    await trust.set(cwd, true);
    const registry = new RuntimeRegistry({
      agentDir, tronHome: join(root, "tron"), idleRuntimeMs: 60_000,
      modelRuntimeFactory: createModels, trust,
      broadcast: () => {}, sessionSummaryChanged: () => {}, sessionListChanged: () => {},
    });
    registries.push(registry);
    await initializeRegistry(registry);
    const slot = await registry.create(cwd);
    const model = faux.getModel();
    await slot.setModel(model.provider, model.id);
    await slot.prompt("inspect structured bash results");
    await waitFor(() => !slot.isBusy, "the slot to go idle");
    const parent = slot.snapshot().transcript.find((item) =>
      item.kind === "message" && item.role === "toolResult" && item.toolCallId === "codemode-bash-output");
    expect(parent).toMatchObject({
      role: "toolResult",
      nestedCalls: { complete: true, calls: [
        { toolName: "bash", status: "completed" },
        { toolName: "bash", status: "completed" },
        { toolName: "bash", status: "failed" },
      ] },
    });
    const parentText = parent?.kind === "message" ? contentText(parent.content) : "";
    const outputMarker = "Output:\n";
    const structured = JSON.parse(parentText.slice(parentText.indexOf(outputMarker) + outputMarker.length)) as {
      large: { outputLength: number; truncated: boolean; full_output_path?: string; exit_code: number; wall_time_seconds: number };
      empty: { output: string; truncated: boolean; exit_code: number; wall_time_seconds: number };
      failed: { output: string; truncated: boolean; exit_code: number; wall_time_seconds: number };
    };
    expect(structured.large.outputLength).toBeGreaterThan(1_048_576);
    expect(structured.large).toMatchObject({ truncated: true, exit_code: 0 });
    expect(structured.large.full_output_path).toBeTypeOf("string");
    expect(structured.large.wall_time_seconds).toBeGreaterThanOrEqual(0);
    expect(structured.empty).toMatchObject({ output: "", truncated: false, exit_code: 0 });
    expect(structured.empty.wall_time_seconds).toBeGreaterThanOrEqual(0);
    expect(structured.failed).toMatchObject({ output: "failed-output", truncated: false, exit_code: 7 });
    expect(structured.failed.wall_time_seconds).toBeGreaterThanOrEqual(0);
    const artifactPath = join(process.cwd(), "test-results", "pi-sdk-099-bash-structured-output.json");
    await mkdir(dirname(artifactPath), { recursive: true });
    await writeFile(artifactPath, `${JSON.stringify({ structured, parent }, null, 2)}\n`);
  });

  it("aborts a nested codemode bash process tree", async () => {
    if (process.platform === "win32") return;
    const root = await mkdtemp(join(tmpdir(), "tron-codemode-bash-abort-e2e-"));
    const agentDir = join(root, "agent");
    const sessionDir = join(root, "sessions");
    const cwd = join(root, "workspace");
    const extensions = join(cwd, ".pi", "extensions");
    await Promise.all([
      mkdir(agentDir), mkdir(sessionDir), mkdir(extensions, { recursive: true }),
    ]);
    await writeFile(join(agentDir, "settings.json"), JSON.stringify({ sessionDir, defaultTools: ["+codemode"] }));
    const sdkUrl = import.meta.resolve("@earendil-works/pi-coding-agent");
    await writeFile(join(extensions, "codemode.ts"), `import { createCodemodeExtension } from ${JSON.stringify(sdkUrl)}; export default createCodemodeExtension({ mode: "on" });\n`);
    const pidPath = join(cwd, "nested.pid");
    const childProgram = "setInterval(() => {}, 1000)";
    const commandProgram = [
      "const { spawn } = require('node:child_process');",
      "const { writeFileSync } = require('node:fs');",
      `const child = spawn(${JSON.stringify(process.execPath)}, ['-e', ${JSON.stringify(childProgram)}], { detached: true, stdio: 'ignore' });`,
      `writeFileSync(${JSON.stringify(pidPath)}, String(child.pid));`,
      "setInterval(() => {}, 1000);",
    ].join(" ");
    const command = `${JSON.stringify(process.execPath)} -e ${JSON.stringify(commandProgram)}`;
    const faux = fauxProvider({ provider: "tron-codemode-bash-abort", tokensPerSecond: 10_000 });
    faux.setResponses([fauxAssistantMessage([fauxToolCall(
      "codemode", { code: `await tools.bash({ command: ${JSON.stringify(command)} }); return "unexpected";` }, { id: "codemode-bash-abort" },
    )], { stopReason: "toolUse" })]);
    const trust = new TrustService(agentDir);
    await trust.set(cwd, true);
    const registry = new RuntimeRegistry({
      agentDir, tronHome: join(root, "tron"), idleRuntimeMs: 60_000,
      modelRuntimeFactory: async () => {
        const runtime = await ModelRuntime.create({ modelsPath: null, refreshOnCreate: false });
        runtime.registerNativeProvider(faux.provider);
        return runtime;
      },
      trust, broadcast: () => {},
      sessionSummaryChanged: () => {}, sessionListChanged: () => {},
    });
    registries.push(registry);
    await initializeRegistry(registry);
    const slot = await registry.create(cwd);
    const model = faux.getModel();
    await slot.setModel(model.provider, model.id);
    const prompting = slot.prompt("run nested process");
    await waitFor(() => existsSync(pidPath), "the process id file");
    const childPid = Number(await readFile(pidPath, "utf8"));
    expect(() => process.kill(childPid, 0)).not.toThrow();
    const operationId = slot.snapshot().operation?.id;
    expect(operationId).toBeDefined();
    await slot.abort("codemode", operationId);
    await expect(prompting).resolves.toMatchObject({ operationId });
    await waitFor(() => {
      try { process.kill(childPid, 0); return false; }
      catch { return true; }
    }, "the child process to exit");
    expect(slot.snapshot().toolExecutions).toEqual([]);
  });

  it("connects Pi MCP stdio and streamable HTTP fixtures and exposes resources through composed built-ins", async () => {
    const root = await mkdtemp(join(tmpdir(), "tron-pi-mcp-fixture-e2e-"));
    const agentDir = join(root, "agent");
    const sessionDir = join(root, "sessions");
    const cwd = join(root, "workspace");
    await Promise.all([mkdir(agentDir, { recursive: true }), mkdir(sessionDir, { recursive: true }), mkdir(cwd, { recursive: true })]);
    const fixtureScript = resolve(process.cwd(), "test-fixtures/pi-sdk/mcp-jsonrpc-fixture.mjs");
    const stdioState = join(root, "stdio-state.json");
    const stdioPidFile = join(root, "stdio.pid");
    const stdioChildPidFile = join(root, "stdio-child.pid");
    const httpState = join(root, "http-state.json");
    const httpPortFile = join(root, "http.port");
    const codeState = join(root, "code-state.json");
    const deferredState = join(root, "deferred-state.json");
    const codePidFile = join(root, "code.pid");
    const deferredPidFile = join(root, "deferred.pid");
    const tools = [{ name: "echo", description: "Echo searchable fixture input", inputSchema: { type: "object", properties: { value: { type: "string" } } } }];
    await Promise.all([writeFile(stdioState, JSON.stringify({ tools })), writeFile(httpState, JSON.stringify({ tools })), writeFile(codeState, JSON.stringify({ tools })), writeFile(deferredState, JSON.stringify({ tools }))]);
    const httpProcess = spawn(process.execPath, [fixtureScript, "http", httpState, httpPortFile], { stdio: "ignore" });
    // Registered as a test hook, not only in `finally`: a body vitest abandons
    // at its timeout never reaches `finally`, which orphaned this server (#406).
    onTestFinished(async () => {
      if (httpProcess.exitCode !== null || httpProcess.signalCode !== null) return;
      const exited = new Promise<void>((resolve) => httpProcess.once("exit", () => resolve()));
      httpProcess.kill("SIGTERM");
      await exited;
    });
    const priorAgentDir = process.env.PI_CODING_AGENT_DIR;
    try {
      await waitFor(() => existsSync(httpPortFile), "the HTTP port file");
      const port = Number(await readFile(httpPortFile, "utf8"));
      await writeFile(join(agentDir, "mcp.json"), JSON.stringify({ mcpServers: {
        stdio: { command: process.execPath, args: [fixtureScript, "stdio", stdioState, stdioPidFile, stdioChildPidFile], exposure: "direct" },
        http: { url: `http://127.0.0.1:${port}/mcp`, headers: { Authorization: "Bearer fixture" }, exposure: "direct" },
        code: { command: process.execPath, args: [fixtureScript, "stdio", codeState, codePidFile], exposure: "codemode" },
        search: { command: process.execPath, args: [fixtureScript, "stdio", deferredState, deferredPidFile], exposure: "deferred" },
      } }));
      process.env.PI_CODING_AGENT_DIR = agentDir;
      const faux = fauxProvider({ provider: "tron-pi-mcp-fixture", tokensPerSecond: 10_000 });
      faux.setResponses([
        fauxAssistantMessage([
          fauxToolCall("mcp__stdio__echo", { value: "stdio" }, { id: "mcp-stdio-call" }),
          fauxToolCall("mcp__http__echo", { value: "http" }, { id: "mcp-http-call" }),
          fauxToolCall("list_mcp_resources", { server: "stdio" }, { id: "mcp-resource-list" }),
          fauxToolCall("read_mcp_resource", { server: "stdio", uri: "fixture://one" }, { id: "mcp-resource-read" }),
          fauxToolCall("codemode", { code: 'return text(await tools.mcp__code__echo({ value: "codemode" }));' }, { id: "mcp-codemode-call" }),
        ], { stopReason: "toolUse" }),
        fauxAssistantMessage([fauxToolCall("tool_search", { query: "searchable fixture input" }, { id: "mcp-tool-search" })], { stopReason: "toolUse" }),
        fauxAssistantMessage([fauxToolCall("mcp__search__echo", { value: "deferred" }, { id: "mcp-deferred-call" })], { stopReason: "toolUse" }),
        fauxAssistantMessage("fixture MCP tools completed"),
        fauxAssistantMessage([fauxToolCall("mcp__stdio__added", { value: "changed" }, { id: "mcp-list-changed-call" })], { stopReason: "toolUse" }),
        fauxAssistantMessage("fixture MCP list changed"),
        fauxAssistantMessage([fauxToolCall("mcp__stdio__added", { value: "reconnected" }, { id: "mcp-lazy-reconnect-call" })], { stopReason: "toolUse" }),
        fauxAssistantMessage("fixture MCP reconnected"),
      ]);
      const modelRuntimeFactory = async () => {
        const runtime = await ModelRuntime.create({ modelsPath: null, refreshOnCreate: false });
        runtime.registerNativeProvider(faux.provider);
        return runtime;
      };
      const registry = new RuntimeRegistry({
        agentDir, tronHome: join(root, "tron"), idleRuntimeMs: 60_000, modelRuntimeFactory,
        trust: new TrustService(agentDir), broadcast: () => {}, sessionSummaryChanged: () => {}, sessionListChanged: () => {},
      });
      registries.push(registry);
      await initializeRegistry(registry);
      const slot = await registry.create(cwd);
      const model = faux.getModel();
      await slot.setModel(model.provider, model.id);
      // The faux model names tools unconditionally, unlike a real model whose
      // catalog is supplied at dispatch. Join actual asynchronous registration
      // before issuing those calls; runtime creation alone is not MCP readiness.
      await waitFor(() => {
        const tools = (slot as any).runtime.session.getAllTools() as Array<{ name: string; exposure?: string }>;
        return ["mcp__stdio__echo", "mcp__http__echo"].every(name =>
          tools.some(tool => tool.name === name && tool.exposure === "direct"));
      }, "the direct MCP tools");
      await slot.prompt("call MCP fixtures and resource tools");
      await waitFor(() => !slot.isBusy, "the slot to go idle");
      const transcript = slot.snapshot().transcript;
      for (const [id, text] of [
        ["mcp-stdio-call", "fixture:echo:{\"value\":\"stdio\"}"],
        ["mcp-http-call", "fixture:echo:{\"value\":\"http\"}"],
        ["mcp-resource-list", "fixture://one"],
        ["mcp-resource-read", "fixture resource body"],
        ["mcp-codemode-call", "fixture:echo:"],
        ["mcp-deferred-call", "fixture:echo:{\"value\":\"deferred\"}"],
      ]) {
        const result = transcript.find((item) => item.kind === "message" && item.role === "toolResult" && item.toolCallId === id);
        expect(result?.content?.map((block) => block.type === "text" ? block.text : "").join("\\n")).toContain(text);
      }
      const stdioPid = Number(await readFile(stdioPidFile, "utf8"));
      const stdioChildPid = Number(await readFile(stdioChildPidFile, "utf8"));
      await writeFile(stdioState, JSON.stringify({ tools: [{ ...tools[0], name: "added", description: "Changed fixture tool" }] }));
      await waitFor(() => {
        const tools = (slot as any).runtime.session.getAllTools() as Array<{ name: string; exposure?: string }>;
        return tools.some((tool) => tool.name === "mcp__stdio__added" && tool.exposure === "direct")
          && tools.some((tool) => tool.name === "mcp__stdio__echo" && tool.exposure === "hidden");
      }, "the refreshed MCP tool exposure");
      await slot.prompt("call the newly listed MCP tool");
      await waitFor(() => !slot.isBusy, "the slot to go idle");
      const addedResult = slot.snapshot().transcript.find((item) => item.kind === "message" && item.role === "toolResult" && item.toolCallId === "mcp-list-changed-call");
      expect(addedResult?.content?.map((block) => block.type === "text" ? block.text : "").join("\\n")).toContain("fixture:added");
      process.kill(-stdioPid, "SIGKILL");
      await waitFor(() => {
        try { process.kill(stdioPid, 0); return false; } catch (error) { return (error as NodeJS.ErrnoException).code === "ESRCH"; }
      }, "the stdio MCP process to exit");
      await slot.prompt("retry after the MCP server crash");
      await waitFor(() => !slot.isBusy, "the slot to go idle");
      const reconnectedPid = Number(await readFile(stdioPidFile, "utf8"));
      const reconnectedChildPid = Number(await readFile(stdioChildPidFile, "utf8"));
      expect(reconnectedPid).not.toBe(stdioPid);
      const codePid = Number(await readFile(codePidFile, "utf8"));
      const deferredPid = Number(await readFile(deferredPidFile, "utf8"));
      const allResults = slot.snapshot().transcript.filter((item) => item.kind === "message" && item.role === "toolResult");
      expect([stdioPid, codePid, deferredPid, stdioChildPid, reconnectedPid, reconnectedChildPid].every(Number.isInteger)).toBe(true);
      await registry.dispose();
      registries.splice(registries.indexOf(registry), 1);
      await waitFor(() => [stdioPid, codePid, deferredPid, stdioChildPid, reconnectedPid, reconnectedChildPid].every((pid) => {
        try { process.kill(pid, 0); return false; } catch (error) { return (error as NodeJS.ErrnoException).code === "ESRCH"; }
      }), "the MCP processes to exit");
      const artifactPath = join(process.cwd(), "test-results", "pi-sdk-099-mcp-fixtures.json");
      await mkdir(dirname(artifactPath), { recursive: true });
      await writeFile(artifactPath, `${JSON.stringify({ transport: ["stdio", "streamable-http"], exposure: ["direct", "codemode", "deferred"], transcript: allResults }, null, 2)}\n`);
    } finally {
      if (priorAgentDir === undefined) delete process.env.PI_CODING_AGENT_DIR;
      else process.env.PI_CODING_AGENT_DIR = priorAgentDir;
      await rm(root, { recursive: true, force: true });
    }
  });

  it("loads project MCP config only after TrustService authorizes the workspace", async () => {
    const root = await mkdtemp(join(tmpdir(), "tron-pi-mcp-project-trust-"));
    const agentDir = join(root, "agent");
    const sessionDir = join(agentDir, "sessions", "workspace");
    const cwd = join(root, "workspace");
    const projectConfigDir = join(cwd, ".pi");
    const pidFile = join(root, "project-server.pid");
    const childPidFile = join(root, "project-server-child.pid");
    const statePath = join(root, "project-state.json");
    const fixtureScript = resolve(process.cwd(), "test-fixtures/pi-sdk/mcp-jsonrpc-fixture.mjs");
    await Promise.all([mkdir(agentDir, { recursive: true }), mkdir(sessionDir, { recursive: true }), mkdir(projectConfigDir, { recursive: true }), writeFile(statePath, JSON.stringify({ tools: [{ name: "project_echo", description: "Trusted project fixture", inputSchema: { type: "object", properties: {} } }] }))]);
    await writeFile(join(agentDir, "mcp.json"), JSON.stringify({ mcpServers: {} }));
    await writeFile(join(projectConfigDir, "mcp.json"), JSON.stringify({ mcpServers: {
      project_fixture: { command: process.execPath, args: [fixtureScript, "stdio", statePath, pidFile, childPidFile], exposure: "direct" },
    } }));
    const priorAgentDir = process.env.PI_CODING_AGENT_DIR;
    process.env.PI_CODING_AGENT_DIR = agentDir;
    const trust = new TrustService(agentDir);
    await trust.set(cwd, false);
    const faux = fauxProvider({ provider: "tron-pi-mcp-project-trust", tokensPerSecond: 10_000 });
    faux.setResponses([
      fauxAssistantMessage("untrusted project ignored"),
      fauxAssistantMessage([fauxToolCall("mcp__project_fixture__project_echo", {}, { id: "trusted-project-call" })], { stopReason: "toolUse" }),
      fauxAssistantMessage("trusted project tool completed"),
    ]);
    const modelRuntimeFactory = async () => {
      const runtime = await ModelRuntime.create({ modelsPath: null, refreshOnCreate: false });
      runtime.registerNativeProvider(faux.provider);
      return runtime;
    };
    const makeRegistry = () => new RuntimeRegistry({
      agentDir, tronHome: join(root, "tron"), idleRuntimeMs: 60_000, maximumLiveRuntimes: 1,
      modelRuntimeFactory, trust, broadcast: () => {}, sessionSummaryChanged: () => {}, sessionListChanged: () => {},
    });
    let registry = makeRegistry();
    registries.push(registry);
    try {
      await initializeRegistry(registry);
      let slot = await registry.create(cwd);
      const model = faux.getModel();
      await slot.setModel(model.provider, model.id);
      await slot.prompt("load an untrusted project");
      await waitFor(() => !slot.isBusy, "the slot to go idle");
      expect(existsSync(pidFile)).toBe(false);
      expect((slot as any).runtime.session.getAllTools().some((tool: { name: string }) => tool.name === "mcp__project_fixture__project_echo")).toBe(false);
      const sessionId = slot.id;
      await registry.dispose();
      registries.splice(registries.indexOf(registry), 1);
      await trust.set(cwd, true);
      registry = makeRegistry();
      registries.push(registry);
      await initializeRegistry(registry);
      slot = await registry.acquire(sessionId);
      await slot.setModel(model.provider, model.id);
      await slot.prompt("load trusted project MCP");
      await waitFor(() => !slot.isBusy && existsSync(pidFile), "the idle slot and its process id file");
      const trustedResult = slot.snapshot().transcript.find((item) => item.kind === "message" && item.role === "toolResult" && item.toolCallId === "trusted-project-call");
      expect(trustedResult?.content?.map((block) => block.type === "text" ? block.text : "").join("\\n")).toContain("fixture:project_echo");
      const processId = Number(await readFile(pidFile, "utf8"));
      const childProcessId = Number(await readFile(childPidFile, "utf8"));
      const secondCwd = join(root, "second-workspace");
      await mkdir(secondCwd, { recursive: true });
      await registry.create(secondCwd);
      await waitFor(() => {
        try { process.kill(processId, 0); return false; } catch (error) { return (error as NodeJS.ErrnoException).code === "ESRCH"; }
      }, "the process to exit");
      await waitFor(() => {
        try { process.kill(childProcessId, 0); return false; } catch (error) { return (error as NodeJS.ErrnoException).code === "ESRCH"; }
      }, "the child process to exit");
      await registry.dispose();
      registries.splice(registries.indexOf(registry), 1);
      await waitFor(() => {
        try { process.kill(processId, 0); return false; } catch (error) { return (error as NodeJS.ErrnoException).code === "ESRCH"; }
      }, "the process to exit");
      const artifactPath = join(process.cwd(), "test-results", "pi-sdk-099-mcp-project-trust.json");
      await mkdir(dirname(artifactPath), { recursive: true });
      await writeFile(artifactPath, `${JSON.stringify({ untrustedProjectServerStarted: false, trustedProjectServerCalled: true, capacityEvictedProcessGroupTerminated: true }, null, 2)}\n`);
    } finally {
      await registry.dispose().catch(() => {});
      const index = registries.indexOf(registry);
      if (index >= 0) registries.splice(index, 1);
      if (priorAgentDir === undefined) delete process.env.PI_CODING_AGENT_DIR;
      else process.env.PI_CODING_AGENT_DIR = priorAgentDir;
      await rm(root, { recursive: true, force: true });
    }
  });

  it("stops sleeping and tool-looping codemode scripts and drains active codemode work", async () => {
    const root = await mkdtemp(join(tmpdir(), "tron-pi-codemode-stop-"));
    const agentDir = join(root, "agent");
    const cwd = join(root, "workspace");
    const extensionDir = join(cwd, ".pi", "extensions");
    await Promise.all([mkdir(agentDir, { recursive: true }), mkdir(extensionDir, { recursive: true })]);
    const holdExtension = `export default function (pi) {
      pi.registerTool({ name: "hold", label: "Hold", description: "Wait until cancelled or its deadline", parameters: { type: "object", properties: { ms: { type: "number" } }, required: ["ms"] }, execute: async (_id, args) => {
        await new Promise((resolve) => setTimeout(resolve, args.ms));
        return { content: [{ type: "text", text: "released" }] };
      } });
    }`;
    const sdkUrl = import.meta.resolve("@earendil-works/pi-coding-agent");
    await Promise.all([
      writeFile(join(agentDir, "settings.json"), JSON.stringify({ defaultTools: ["+codemode"] })),
      writeFile(join(extensionDir, "codemode.ts"), `import { createCodemodeExtension } from ${JSON.stringify(sdkUrl)}; export default createCodemodeExtension({ mode: "on" });\n`),
      writeFile(join(extensionDir, "hold.ts"), `${holdExtension}\n`),
    ]);
    const trust = new TrustService(agentDir);
    await trust.set(cwd, true);
    const faux = fauxProvider({ provider: "tron-pi-codemode-stop", tokensPerSecond: 10_000 });
    const call = (id: string, code: string) => fauxAssistantMessage([fauxToolCall("codemode", { code }, { id })], { stopReason: "toolUse" });
    faux.setResponses([
      call("codemode-sleep", 'await new Promise(resolve => setTimeout(resolve, 30_000)); return "late";'),
      call("codemode-loop", 'while (true) await tools.hold({ ms: 250 });'),
      call("codemode-drain", 'await tools.hold({ ms: 400 }); return "drained";'),
      fauxAssistantMessage("drain completed"),
    ]);
    const modelRuntimeFactory = async () => {
      const runtime = await ModelRuntime.create({ modelsPath: null, refreshOnCreate: false });
      runtime.registerNativeProvider(faux.provider);
      return runtime;
    };
    const registry = new RuntimeRegistry({
      agentDir, tronHome: join(root, "tron"), idleRuntimeMs: 60_000, modelRuntimeFactory, trust,
      broadcast: () => {}, sessionSummaryChanged: () => {}, sessionListChanged: () => {},
    });
    registries.push(registry);
    try {
      await initializeRegistry(registry);
      const slot = await registry.create(cwd);
      const model = faux.getModel();
      await slot.setModel(model.provider, model.id);
      const sleepPrompt = slot.prompt("run sleeping codemode script");
      await waitFor(() => slot.snapshot().toolExecutions.some((tool) => tool.toolCallId === "codemode-sleep"), "the codemode sleep tool");
      await slot.abort("agent");
      await sleepPrompt;
      await waitFor(() => !slot.isBusy, "the slot to go idle");
      expect(slot.snapshot().transcript.find((item) => item.kind === "message" && item.role === "toolResult" && item.toolCallId === "codemode-sleep")).toMatchObject({ isError: true });
      const loopPrompt = slot.prompt("run tool-looping codemode script");
      await waitFor(() => slot.snapshot().toolExecutions.some((tool) => tool.toolCallId === "codemode-loop" && (tool.nestedCalls?.calls.length ?? 0) > 0), "the codemode loop's nested calls").catch(() => { throw new Error(`codemode loop did not call tools: ${JSON.stringify(slot.snapshot().transcript.slice(-6))}`); });
      await slot.abort("agent");
      await loopPrompt;
      await waitFor(() => !slot.isBusy, "the slot to go idle");
      const stoppedLoop = slot.snapshot().transcript.find((item) => item.kind === "message" && item.role === "toolResult" && item.toolCallId === "codemode-loop");
      expect(stoppedLoop).toMatchObject({ isError: true, nestedCalls: { calls: [expect.objectContaining({ toolName: "hold" })] } });
      const drainPrompt = slot.prompt("run codemode under administrative drain");
      await waitFor(() => slot.snapshot().toolExecutions.some((tool) => tool.toolCallId === "codemode-drain"), "the codemode drain tool");
      let drained = false;
      const drain = registry.waitUntilIdle().then(() => { drained = true; });
      await new Promise((resolve) => setTimeout(resolve, 50));
      expect(drained).toBe(false);
      await drainPrompt;
      await drain;
      expect(drained).toBe(true);
      expect(faux.state.callCount).toBeGreaterThanOrEqual(3);
      const artifactPath = join(process.cwd(), "test-results", "pi-sdk-099-codemode-stop-drain.json");
      await mkdir(dirname(artifactPath), { recursive: true });
      await writeFile(artifactPath, `${JSON.stringify({ stopped: ["sleeping-script", "tool-loop"], drainWaitedFor: true, settled: slot.snapshot().transcript.filter((item) => item.kind === "message" && item.role === "toolResult" && item.toolName === "codemode").map((item) => ({ toolCallId: item.toolCallId, isError: item.isError })) }, null, 2)}\n`);
    } finally {
      await registry.dispose();
      const index = registries.indexOf(registry);
      if (index >= 0) registries.splice(index, 1);
      await rm(root, { recursive: true, force: true });
    }
  });

  it("keeps one tool display segment across tool-only agent continuations", async () => {
    const root = await mkdtemp(join(tmpdir(), "tron-tool-segment-continuation-"));
    const agentDir = join(root, "agent");
    const sessionDir = join(root, "sessions");
    const cwd = join(root, "workspace");
    await Promise.all([mkdir(agentDir), mkdir(sessionDir), mkdir(cwd)]);
    await writeFile(join(agentDir, "settings.json"), JSON.stringify({ sessionDir }));
    await writeFile(join(cwd, "one.txt"), "one\n");
    await writeFile(join(cwd, "two.txt"), "two\n");

    const faux = fauxProvider({ provider: "tron-tool-segment-continuation", tokensPerSecond: 10_000 });
    faux.setResponses([
      fauxAssistantMessage([
        fauxToolCall("read", { path: join(cwd, "one.txt") }, { id: "call-one" }),
      ], { stopReason: "toolUse" }),
      fauxAssistantMessage([
        fauxToolCall("read", { path: join(cwd, "two.txt") }, { id: "call-two" }),
      ], { stopReason: "toolUse" }),
      fauxAssistantMessage("finished"),
    ]);
    const createModels = async () => {
      const runtime = await ModelRuntime.create({ modelsPath: null, refreshOnCreate: false });
      runtime.registerNativeProvider(faux.provider);
      return runtime;
    };
    const progress: Array<{ toolCallId: string; toolSegmentId?: string }> = [];
    const registry = new RuntimeRegistry({
      agentDir,
      tronHome: join(root, "tron"),
      idleRuntimeMs: 60_000,
      modelRuntimeFactory: createModels,
      trust: new TrustService(agentDir),
      broadcast: (_sessionId, topic, payload) => {
        if (topic === "session.toolProgress") progress.push(payload.data);
      },
      sessionSummaryChanged: () => {},
      sessionListChanged: () => {},
    });
    registries.push(registry);
    await initializeRegistry(registry);
    const slot = await registry.create(cwd);
    const model = faux.getModel();
    await slot.setModel(model.provider, model.id);
    await slot.prompt("run sequential tools");
    await waitFor(() => !slot.isBusy, "the slot to go idle");

    const segmentByCall = new Map(progress.map(event => [event.toolCallId, event.toolSegmentId]));
    expect(segmentByCall.get("call-one")).toMatch(/^tool-segment:/);
    expect(segmentByCall.get("call-two")).toBe(segmentByCall.get("call-one"));
    const canonicalSegments = slot.snapshot().transcript.flatMap(item =>
      item.kind === "message" && item.role === "assistant"
        ? item.content.flatMap(part => part.type === "toolCall" ? [part.toolSegmentId] : [])
        : []
    );
    expect(new Set(canonicalSegments)).toEqual(new Set([segmentByCall.get("call-one")]));
  });

  it("rotates tool segment authority across a visible assistant barrier before new tool progress", async () => {
    const root = await mkdtemp(join(tmpdir(), "tron-tool-segment-visible-barrier-"));
    const agentDir = join(root, "agent");
    const sessionDir = join(root, "sessions");
    const cwd = join(root, "workspace");
    await Promise.all([mkdir(agentDir), mkdir(sessionDir), mkdir(cwd)]);
    await writeFile(join(agentDir, "settings.json"), JSON.stringify({ sessionDir }));
    await Promise.all([
      writeFile(join(cwd, "one.txt"), "one\n"),
      writeFile(join(cwd, "two.txt"), "two\n"),
    ]);

    const faux = fauxProvider({ provider: "tron-tool-segment-visible-barrier", tokensPerSecond: 10_000 });
    faux.setResponses([
      fauxAssistantMessage([
        fauxToolCall("read", { path: join(cwd, "one.txt") }, { id: "call-before-barrier" }),
        { type: "text", text: "Visible checkpoint" },
      ], { stopReason: "toolUse" }),
      fauxAssistantMessage([
        fauxToolCall("read", { path: join(cwd, "two.txt") }, { id: "call-after-barrier" }),
      ], { stopReason: "toolUse" }),
      fauxAssistantMessage("finished"),
    ]);
    const events: Array<{ topic: string; payload: any }> = [];
    const registry = new RuntimeRegistry({
      agentDir,
      tronHome: join(root, "tron"),
      idleRuntimeMs: 60_000,
      modelRuntimeFactory: async () => {
        const runtime = await ModelRuntime.create({ modelsPath: null, refreshOnCreate: false });
        runtime.registerNativeProvider(faux.provider);
        return runtime;
      },
      trust: new TrustService(agentDir),
      broadcast: (_sessionId, topic, payload) => events.push({ topic, payload }),
      sessionSummaryChanged: () => {},
      sessionListChanged: () => {},
    });
    registries.push(registry);
    await initializeRegistry(registry);
    const slot = await registry.create(cwd);
    subscribeAudience(registry, slot.id);
    const model = faux.getModel();
    await slot.setModel(model.provider, model.id);
    await slot.prompt("run tools around a visible barrier");
    await waitFor(() => !slot.isBusy, "the slot to go idle");

    const toolProgress = events
      .filter((event) => event.topic === "session.toolProgress")
      .map((event) => event.payload.data as { toolCallId: string; toolSegmentId?: string });
    const segmentByCall = new Map(toolProgress.map((event) => [event.toolCallId, event.toolSegmentId]));
    const beforeSegment = segmentByCall.get("call-before-barrier");
    const afterSegment = segmentByCall.get("call-after-barrier");
    expect(beforeSegment).toMatch(/^tool-segment:/);
    expect(afterSegment).toMatch(/^tool-segment:/);
    expect(afterSegment).not.toBe(beforeSegment);

    const canonicalSegmentByCall = new Map(slot.snapshot().transcript.flatMap((item) =>
      item.kind === "message" && item.role === "assistant"
        ? item.content.flatMap((part) => part.type === "toolCall"
          ? [[part.toolCallId, part.toolSegmentId] as const]
          : [])
        : []
    ));
    expect(canonicalSegmentByCall.get("call-before-barrier")).toBe(beforeSegment);
    expect(canonicalSegmentByCall.get("call-after-barrier")).toBe(afterSegment);

    const afterProgressIndex = events.findIndex((event) =>
      event.topic === "session.toolProgress"
        && event.payload.data?.toolCallId === "call-after-barrier"
    );
    const precedingAuthorityIndex = events.findLastIndex((event, index) => {
      if (index >= afterProgressIndex || event.topic !== "session.snapshot") return false;
      const snapshot = event.payload?.data ?? event.payload;
      return snapshot.activeToolSegmentId === afterSegment;
    });
    expect(afterProgressIndex).toBeGreaterThanOrEqual(0);
    expect(precedingAuthorityIndex).toBeGreaterThanOrEqual(0);
    expect(precedingAuthorityIndex).toBeLessThan(afterProgressIndex);
  });

  it("rotates tool segment authority at a visible custom-message barrier", async () => {
    const root = await mkdtemp(join(tmpdir(), "tron-tool-segment-custom-barrier-"));
    const agentDir = join(root, "agent");
    const cwd = join(root, "workspace");
    const extensionDir = join(cwd, ".pi", "extensions");
    await Promise.all([mkdir(agentDir), mkdir(extensionDir, { recursive: true })]);
    await writeFile(join(extensionDir, "visible-barrier.ts"), `
let sent = false;
export default function (pi) {
  pi.on("turn_end", () => {
    if (sent) return;
    sent = true;
    pi.sendMessage({ customType: "visible-boundary", content: "Visible extension input", display: true }, { triggerTurn: true });
  });
}
`);
    await Promise.all([
      writeFile(join(cwd, "one.txt"), "one\n"),
      writeFile(join(cwd, "two.txt"), "two\n"),
    ]);
    const trust = new TrustService(agentDir);
    await trust.set(cwd, true);
    const faux = fauxProvider({ provider: "tron-tool-segment-custom-barrier", tokensPerSecond: 10_000 });
    faux.setResponses([
      fauxAssistantMessage([
        fauxToolCall("read", { path: join(cwd, "one.txt") }, { id: "call-before-custom" }),
      ], { stopReason: "toolUse" }),
      fauxAssistantMessage([
        fauxToolCall("read", { path: join(cwd, "two.txt") }, { id: "call-after-custom" }),
      ], { stopReason: "toolUse" }),
      fauxAssistantMessage("finished"),
    ]);
    const progress: Array<{ toolCallId: string; toolSegmentId?: string }> = [];
    const registry = new RuntimeRegistry({
      agentDir,
      tronHome: join(root, "tron"),
      idleRuntimeMs: 60_000,
      modelRuntimeFactory: async () => {
        const runtime = await ModelRuntime.create({ modelsPath: null, refreshOnCreate: false });
        runtime.registerNativeProvider(faux.provider);
        return runtime;
      },
      trust,
      broadcast: (_sessionId, topic, payload) => {
        if (topic === "session.toolProgress") progress.push(payload.data);
      },
      sessionSummaryChanged: () => {},
      sessionListChanged: () => {},
    });
    registries.push(registry);
    await initializeRegistry(registry);
    const slot = await registry.create(cwd);
    const model = faux.getModel();
    await slot.setModel(model.provider, model.id);
    await slot.prompt("run tools around visible extension input");
    await waitFor(() => !slot.isBusy, "the slot to go idle");

    const segmentByCall = new Map(progress.map((event) => [event.toolCallId, event.toolSegmentId]));
    const beforeSegment = segmentByCall.get("call-before-custom");
    const afterSegment = segmentByCall.get("call-after-custom");
    expect(beforeSegment).toMatch(/^tool-segment:/);
    expect(afterSegment).toMatch(/^tool-segment:/);
    expect(afterSegment).not.toBe(beforeSegment);
    const snapshot = slot.snapshot();
    expect(snapshot.transcript.some((item) => item.kind === "customMessage")).toBe(true);
    const canonicalSegmentByCall = new Map(snapshot.transcript.flatMap((item) =>
      item.kind === "message" && item.role === "assistant"
        ? item.content.flatMap((part) => part.type === "toolCall"
          ? [[part.toolCallId, part.toolSegmentId] as const]
          : [])
        : []
    ));
    expect(canonicalSegmentByCall.get("call-before-custom")).toBe(beforeSegment);
    expect(canonicalSegmentByCall.get("call-after-custom")).toBe(afterSegment);
  });

  it("permits one delayed agent start owned by an accepted extension command during drain", async () => {
    const root = await mkdtemp(join(tmpdir(), "tron-drain-extension-command-start-"));
    const agentDir = join(root, "agent");
    const cwd = join(root, "workspace");
    const extensionDir = join(cwd, ".pi", "extensions");
    await Promise.all([mkdir(agentDir), mkdir(extensionDir, { recursive: true })]);
    await writeFile(join(extensionDir, "command.ts"), `export default function (pi) {
      pi.registerCommand("start-after-confirm", { handler: async (_args, ctx) => {
        if (await ctx.ui.confirm("Start", "Continue?")) {
          pi.sendMessage({ customType: "confirmed", content: "continue", display: false }, { triggerTurn: true });
        }
      }});
    }\n`);
    const trust = new TrustService(agentDir);
    await trust.set(cwd, true);
    const faux = fauxProvider({ provider: "tron-drain-extension-command-start", tokensPerSecond: 10_000 });
    faux.setResponses([fauxAssistantMessage("command continuation complete")]);
    const runtime = await ModelRuntime.create({ modelsPath: null, refreshOnCreate: false });
    runtime.registerNativeProvider(faux.provider);
    const failures: unknown[] = [];
    const registry = new RuntimeRegistry({
      agentDir, tronHome: join(root, "tron"), idleRuntimeMs: 60_000, trust,
      modelRuntimeFactory: async () => runtime,
      broadcast: (_id, topic, payload) => { if (topic === "session.operationFailed") failures.push(payload); },
      sessionSummaryChanged: () => {}, sessionListChanged: () => {},
    });
    registries.push(registry);
    await initializeRegistry(registry);
    const slot = await registry.create(cwd);
    const model = faux.getModel();
    await slot.setModel(model.provider, model.id);
    const command = slot.prompt("/start-after-confirm");
    await waitFor(() => slot.snapshot().extensionPresentation.pendingInteractions.length === 1, "the pending interaction");
    const pending = slot.snapshot().extensionPresentation.pendingInteractions[0]!;
    const drain = registry.waitUntilIdle();
    slot.respondToInteraction(pending.id, pending.hostEpoch, pending.presentationRevision, true, false);
    await command;
    await drain;
    expect(faux.state.callCount).toBe(1);
    expect(failures).toEqual([]);
    expect(slot.snapshot()).toMatchObject({ phase: "idle" });
  });

  it("retires a command-triggered foreground owner when the turn has no successful assistant completion", async () => {
    const root = await mkdtemp(join(tmpdir(), "tron-failed-command-turn-drain-"));
    const agentDir = join(root, "agent");
    const cwd = join(root, "workspace");
    const extensionDir = join(cwd, ".pi", "extensions");
    await Promise.all([mkdir(agentDir), mkdir(extensionDir, { recursive: true })]);
    await writeFile(join(extensionDir, "failed-turn.ts"), `export default function (pi) {
      pi.registerCommand("start-failed-turn", { handler: async (_args, ctx) => {
        pi.sendMessage({ customType: "failed-turn", content: "continue", display: false }, { triggerTurn: true });
      }});
    }\n`);
    const trust = new TrustService(agentDir);
    await trust.set(cwd, true);
    const faux = fauxProvider({ provider: "tron-failed-command-turn", tokensPerSecond: 10_000 });
    faux.setResponses([{
      ...fauxAssistantMessage("provider failed"),
      stopReason: "error",
      errorMessage: "injected provider failure",
    }]);
    const runtime = await ModelRuntime.create({ modelsPath: null, refreshOnCreate: false });
    runtime.registerNativeProvider(faux.provider);
    const workRegistry = new GatewayWorkRegistry("failed-command-turn-epoch");
    const derivedAdmissions = vi.spyOn(workRegistry, "beginDerived");
    const registry = new RuntimeRegistry({
      agentDir, tronHome: join(root, "tron"), idleRuntimeMs: 60_000, trust, workRegistry,
      modelRuntimeFactory: async () => runtime,
      broadcast: () => {}, sessionSummaryChanged: () => {}, sessionListChanged: () => {},
    });
    registries.push(registry);
    await initializeRegistry(registry);
    const slot = await registry.create(cwd);
    const model = faux.getModel();
    await slot.setModel(model.provider, model.id);

    await slot.prompt("/start-failed-turn").catch(() => {});
    await waitFor(() => slot.catalogPhase === "idle" || slot.catalogPhase === "interrupted", "the catalog phase to settle");
    await waitFor(() => workRegistry.size === 0, "the work registry to drain");
    expect(faux.state.callCount).toBeGreaterThan(0);
    expect(derivedAdmissions.mock.calls.some(([admission]) =>
      admission.kind === "foreground-agent-operation"
    )).toBe(true);
    const markerPath = join(root, "tron", "gateway", "runtime-markers", `${slot.id}.json`);
    if (existsSync(markerPath)) {
      const marker = JSON.parse(await readFile(markerPath, "utf8")) as { operations: unknown[] };
      expect(marker.operations).toEqual([]);
    }
    await registry.waitUntilIdle();
    expect(registry.administrativeDrainSnapshot()).toMatchObject({
      phase: "complete", blockerCount: 0, suspectProjectionCount: 0,
    });
  });

  it("classifies and reconciles an unrepresented foreground token during drain", async () => {
    const fixture = await coldFixture("orphaned-foreground-drain");
    const slot = await fixture.registry.acquire(fixture.manager.getSessionId());
    const internal = slot as unknown as {
      pendingPrompt?: { id: string; createdAt: string; text: string; attachmentCount: number };
      beginDerivedOperationWork: (operationId: string, kind: "foreground-agent-operation") => unknown;
      runtime: { session: { readonly isStreaming: boolean } };
      dependencies: { markers: { mark: (sessionId: string, operationId: string) => Promise<void> } };
    };
    internal.beginDerivedOperationWork("orphaned-operation", "foreground-agent-operation");
    internal.pendingPrompt = {
      id: "orphaned-operation",
      createdAt: new Date().toISOString(),
      text: "stale provisional prompt",
      attachmentCount: 0,
    };
    await internal.dependencies.markers.mark(slot.id, "orphaned-operation");
    const streaming = vi.spyOn(internal.runtime.session, "isStreaming", "get").mockReturnValue(true);

    const admitted = fixture.registry.beginAdministrativeDrain();
    expect(admitted).toMatchObject({
      blockerCount: 1,
      suspectProjectionCount: 0,
      blockers: [expect.objectContaining({
        category: "foreground-agent-operation", state: "active",
      })],
    });
    streaming.mockRestore();
    expect(fixture.registry.administrativeDrainSnapshot()).toMatchObject({
      blockerCount: 1,
      suspectProjectionCount: 1,
      blockers: [expect.objectContaining({
        category: "foreground-agent-operation", state: "suspect",
      })],
    });
    await fixture.registry.waitUntilIdle();
    expect(fixture.registry.administrativeDrainSnapshot()).toMatchObject({
      phase: "complete", blockerCount: 0, suspectProjectionCount: 0,
    });
    expect(slot.snapshot().pendingPrompt).toBeUndefined();
    const markerPath = join(fixture.root, "tron", "gateway", "runtime-markers", `${slot.id}.json`);
    if (existsSync(markerPath)) {
      const marker = JSON.parse(await readFile(markerPath, "utf8")) as { operations: unknown[] };
      expect(marker.operations).toEqual([]);
    }
  });

  it("reasserts ownership restored while orphan marker cleanup yields", async () => {
    const fixture = await coldFixture("orphan-marker-race");
    const slot = await fixture.registry.acquire(fixture.manager.getSessionId());
    const internal = slot as unknown as {
      phase: "idle" | "running";
      activeOperationId?: string;
      operation?: { id?: string; kind: "prompt"; startedAt: string };
      beginDerivedOperationWork: (operationId: string, kind: "foreground-agent-operation") => unknown;
      dependencies: { markers: {
        mark: (sessionId: string, operationId: string) => Promise<void>;
        clear: (sessionId: string, operationId?: string) => Promise<void>;
        evidenceFor: (sessionId: string) => Promise<Array<{ operationId: string }>>;
      } };
    };
    internal.beginDerivedOperationWork("racing-operation", "foreground-agent-operation");
    await internal.dependencies.markers.mark(slot.id, "racing-operation");
    const mark = vi.spyOn(internal.dependencies.markers, "mark");
    const originalClear = internal.dependencies.markers.clear.bind(internal.dependencies.markers);
    let releaseClear!: () => void;
    const clearBarrier = new Promise<void>((resolve) => { releaseClear = resolve; });
    const clear = vi.spyOn(internal.dependencies.markers, "clear")
      .mockImplementationOnce(async () => clearBarrier)
      .mockImplementation(originalClear);

    const drain = fixture.registry.waitUntilIdle();
    await waitFor(() => clear.mock.calls.length === 1, "the marker clear");
    internal.phase = "running";
    internal.activeOperationId = "racing-operation";
    internal.operation = {
      id: "racing-operation", kind: "prompt", startedAt: new Date().toISOString(),
    };
    releaseClear();
    await waitFor(() => mark.mock.calls.length === 1, "the marker write");
    await expect(internal.dependencies.markers.evidenceFor(slot.id)).resolves.toEqual([
      expect.objectContaining({ operationId: "racing-operation" }),
    ]);

    internal.phase = "idle";
    internal.activeOperationId = undefined;
    internal.operation = undefined;
    await drain;
    expect(clear.mock.calls.length).toBeGreaterThanOrEqual(2);
    await expect(internal.dependencies.markers.evidenceFor(slot.id)).resolves.toEqual([]);
  });

  it("fails a drain instead of waiting forever on foreground work without a captured slot", async () => {
    const workRegistry = new GatewayWorkRegistry("missing-slot-drain-epoch");
    const fixture = await coldFixture("missing-slot-drain", { workRegistry });
    const stranded = workRegistry.begin({
      kind: "foreground-agent-operation",
      sessionId: "missing-slot",
      hostEpoch: "missing-slot-drain-epoch",
    });

    await expect(fixture.registry.waitUntilIdle()).rejects.toThrow(
      /foreground ownership without a captured runtime slot/u,
    );
    expect(fixture.registry.administrativeDrainSnapshot()).toMatchObject({
      phase: "failed", blockerCount: 1, suspectProjectionCount: 1,
    });
    stranded.settle();
  });

  it("does not treat an ownerless late agent settlement as all-marker authority", async () => {
    const fixture = await coldFixture("ownerless-late-settlement");
    const slot = await fixture.registry.acquire(fixture.manager.getSessionId());
    const internal = slot as unknown as {
      pendingExtensionCommand?: { id: string; kind: "command"; startedAt: string };
      onEvent: (event: { type: "agent_settled" }) => void;
      dependencies: { markers: {
        mark: (sessionId: string, operationId: string) => Promise<void>;
        evidenceFor: (sessionId: string) => Promise<Array<{ operationId: string }>>;
      } };
    };
    internal.pendingExtensionCommand = {
      id: "command-owner", kind: "command", startedAt: new Date().toISOString(),
    };
    await internal.dependencies.markers.mark(slot.id, "other-owner-one");
    await internal.dependencies.markers.mark(slot.id, "other-owner-two");

    internal.onEvent({ type: "agent_settled" });

    await expect(internal.dependencies.markers.evidenceFor(slot.id)).resolves.toEqual([
      expect.objectContaining({ operationId: "other-owner-one" }),
      expect.objectContaining({ operationId: "other-owner-two" }),
    ]);
  });

  it("retires an exact provisional prompt projection even after its work token already settled", async () => {
    const fixture = await coldFixture("settled-provisional-prompt");
    const slot = await fixture.registry.acquire(fixture.manager.getSessionId());
    const internal = slot as unknown as {
      pendingPrompt?: {
        id: string; createdAt: string; text: string; attachmentCount: number;
      };
      settleOperationWork: (operationId: string) => void;
    };
    internal.pendingPrompt = {
      id: "settled-operation",
      createdAt: new Date().toISOString(),
      text: "settled prompt",
      attachmentCount: 0,
    };

    internal.settleOperationWork("settled-operation");

    expect(slot.snapshot().pendingPrompt).toBeUndefined();
  });

  it("admits exact extension commands while streaming without hiding the foreground run", async () => {
    const root = await mkdtemp(join(tmpdir(), "tron-streaming-extension-command-"));
    const agentDir = join(root, "agent");
    const cwd = join(root, "workspace");
    const extensionDir = join(cwd, ".pi", "extensions");
    await Promise.all([mkdir(agentDir), mkdir(extensionDir, { recursive: true })]);
    await writeFile(join(extensionDir, "stream-command.ts"), `export default function (pi) {
      pi.registerCommand("during-stream", {
        description: "Wait for native confirmation",
        handler: async (_args, ctx) => {
          if (await ctx.ui.confirm("Streaming command", "Continue?")) ctx.ui.setStatus("stream-command", "accepted");
        },
      });
    }\n`);
    const trust = new TrustService(agentDir);
    await trust.set(cwd, true);
    const faux = fauxProvider({ provider: "tron-stream-command", tokensPerSecond: 1 });
    faux.setResponses([fauxAssistantMessage("streaming ".repeat(100))]);
    const runtime = await ModelRuntime.create({ modelsPath: null, refreshOnCreate: false });
    runtime.registerNativeProvider(faux.provider);
    const registry = new RuntimeRegistry({
      agentDir, tronHome: join(root, "tron"), idleRuntimeMs: 60_000, trust,
      modelRuntimeFactory: async () => runtime,
      broadcast: () => {}, sessionSummaryChanged: () => {}, sessionListChanged: () => {},
    });
    registries.push(registry);
    await initializeRegistry(registry);
    const slot = await registry.create(cwd);
    const model = faux.getModel();
    await slot.setModel(model.provider, model.id);
    await slot.prompt("start foreground streaming");
    await waitFor(() => slot.catalogPhase === "running", "the catalog phase to run");

    const markerDependencies = (slot as unknown as {
      dependencies: { markers: { mark: (sessionId: string, operationId: string) => Promise<void> } };
    }).dependencies.markers;
    const failedMarker = vi.spyOn(markerDependencies, "mark").mockRejectedValueOnce(new Error("injected marker failure"));
    const recoveredCommand = slot.prompt("/during-stream");
    await waitFor(() => slot.snapshot().extensionPresentation.pendingInteractions.length === 1, "the pending interaction");
    const recoveredPending = slot.snapshot().extensionPresentation.pendingInteractions[0]!;
    slot.respondToInteraction(recoveredPending.id, recoveredPending.hostEpoch, recoveredPending.presentationRevision, false, true);
    await expect(recoveredCommand).resolves.toEqual({ operationId: expect.any(String) });
    await waitFor(() => (slot as any).pendingExtensionCommand === undefined, "the pending extension command to clear");
    expect(failedMarker.mock.calls.length).toBeGreaterThanOrEqual(2);
    failedMarker.mockRestore();

    let resolveAdmission!: (result: { operationId: string }) => void;
    const admission = new Promise<{ operationId: string }>((resolve) => { resolveAdmission = resolve; });
    const command = slot.prompt(
      "/during-stream",
      [],
      undefined,
      undefined,
      resolveAdmission,
    );
    await expect(admission).resolves.toEqual({ operationId: expect.any(String) });
    await waitFor(() => slot.snapshot().extensionPresentation.pendingInteractions.length === 1, "the pending interaction");
    const pending = slot.snapshot().extensionPresentation.pendingInteractions[0]!;
    const during = slot.snapshot();
    expect(during.phase).toBe("running");
    expect(during.operation?.kind).toBe("prompt");
    expect((slot as any).pendingExtensionCommand?.kind).toBe("command");
    const marker = JSON.parse(await readFile(join(root, "tron", "gateway", "runtime-markers", `${slot.id}.json`), "utf8")) as {
      operations: Array<{ operationId: string }>;
    };
    expect(marker.operations.map((operation) => operation.operationId)).toContain((slot as any).pendingExtensionCommand?.id);
    let drainSettled = false;
    const drain = registry.waitUntilIdle().then(() => { drainSettled = true; });
    await new Promise((resolve) => setTimeout(resolve, 25));
    expect(drainSettled).toBe(false);
    slot.respondToInteraction(pending.id, pending.hostEpoch, pending.presentationRevision, true, false);
    await expect(command).resolves.toEqual({ operationId: expect.any(String) });
    await waitFor(() => (slot as any).pendingExtensionCommand === undefined, "the pending extension command to clear");
    expect(slot.snapshot().extensionPresentation.semanticState.statuses["stream-command"]).toBe("accepted");
    let releaseMarkerClear!: () => void;
    const markerClearBarrier = new Promise<void>((resolve) => { releaseMarkerClear = resolve; });
    const markerStore = (slot as unknown as {
      dependencies: { markers: { clear: (sessionId: string, operationId?: string) => Promise<void> } };
    }).dependencies.markers;
    const originalClear = markerStore.clear.bind(markerStore);
    const markerClear = vi.spyOn(markerStore, "clear").mockImplementationOnce(async () => markerClearBarrier);
    const aborting = slot.abort();
    await waitFor(() => markerClear.mock.calls.length === 1, "the marker clear");
    await new Promise((resolve) => setTimeout(resolve, 25));
    expect(drainSettled).toBe(false);
    markerClear.mockImplementation(originalClear);
    releaseMarkerClear();
    await aborting;
    await waitFor(() => slot.catalogPhase === "idle", "the catalog phase to go idle");
    await drain;
    expect(drainSettled).toBe(true);
  });

  it("rejects scheduled plain-text extension commands before effects or retained operation ownership", async () => {
    const fixture = await coldFixture("scheduled-literal-command");
    const { registry, root, cwd, agentDir } = fixture;
    let handle: AutomationExecutionHandle | undefined;
    try {
      const extensionDir = join(cwd, ".pi", "extensions");
      const sentinel = join(root, "command-effect.txt");
      await mkdir(extensionDir, { recursive: true });
      await writeFile(join(extensionDir, "owned-command.ts"), `import { writeFile } from "node:fs/promises";
        export default function (pi) {
          pi.registerCommand("owned-command", {
            handler: async () => { await writeFile(${JSON.stringify(sentinel)}, "executed"); },
          });
        }\n`);
      await new TrustService(agentDir).set(cwd, true);
      const slot = await registry.acquire(fixture.manager.getSessionId());
      expect(slot.commands()).toContainEqual(expect.objectContaining({ name: "owned-command", source: "extension" }));
      const action = { kind: "sessionPrompt" as const, text: "/owned-command argument" };
      expect(admitsAutomationAction(action)).toBe(true);
      const record: AutomationRecord = {
        schemaVersion: 2, id: "10000000-0000-4000-8000-000000000001", revision: 1, stateRevision: 1,
        name: "Scheduled prompt", activation: "enabled", createdAt: "2026-01-01T00:00:00.000Z", updatedAt: "2026-01-01T00:00:00.000Z",
        provenance: { kind: "local" }, target: { kind: "existingSession", sessionId: slot.id },
        trigger: { kind: "once", at: "2026-01-01T01:00:00.000Z" }, misfirePolicy: "latest", overlapPolicy: "skip",
        executionDeadlineSeconds: 3_600, action, nextOccurrenceAt: "2026-01-01T01:00:00.000Z",
        consecutiveFailureCount: 0, history: [],
      };
      const run: AutomationRun = {
        runId: "10000000-0000-4000-8000-000000000002", occurrenceId: "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA",
        automationRevision: 1, scheduledFor: "2026-01-01T01:00:00.000Z", triggerSnapshot: record.trigger,
        actionSnapshot: action, targetSnapshot: record.target, executionSessionId: slot.id, state: "admitting",
        createdAt: "2026-01-01T01:00:00.000Z", preAdmissionAttemptCount: 0,
        operationId: "automation:10000000-0000-4000-8000-000000000002",
      };
      const work = registry.administrativeWorkRegistry;
      const executor = new GatewayAutomationExecutor(registry, work, undefined, undefined);
      await expect.soft(executor.start(record, run).then((admitted) => { handle = admitted; return admitted; }))
        .rejects.toMatchObject({ retryable: false, reason: "agent-admission-rejected" });
      expect.soft(existsSync(sentinel)).toBe(false);
      expect.soft(work.size).toBe(0);
      expect.soft(slot.isEvictionProtected).toBe(false);
      expect((await registry.ownedOperationRecoveryEvidence(slot.id, run.operationId!)).marker).toBeUndefined();

      // The same installed command remains available to an explicit user.
      await slot.prompt(action.text);
      expect(await readFile(sentinel, "utf8")).toBe("executed");
      expect(work.size).toBe(0);
    } finally {
      // A broken admission still belongs only to this fixture: release its
      // returned handle before disposing the synthetic runtime and files.
      await handle?.acknowledgeTerminal?.();
      await registry.dispose();
      registries.splice(registries.indexOf(registry), 1);
      await rm(root, { recursive: true, force: true });
    }
  });

  it("persists extension notifications as centered non-context rows with exact command provenance", async () => {
    const root = await mkdtemp(join(tmpdir(), "tron-extension-command-notification-"));
    const agentDir = join(root, "agent");
    const cwd = join(root, "workspace");
    const extensionDir = join(cwd, ".pi", "extensions");
    await Promise.all([mkdir(agentDir), mkdir(extensionDir, { recursive: true })]);
    await writeFile(join(extensionDir, "notify-command.ts"), `export default function (pi) {
      pi.registerCommand("notify-command", {
        handler: async (_args, ctx) => {
          ctx.ui.notify("Goal created.", "info");
          pi.sendMessage({
            customType: "goal-event",
            content: "Goal created.",
            display: true,
            details: { goal: { objective: "count to 20", status: "active" } },
          });
          pi.sendMessage({
            customType: "goal-audit",
            content: "Goal receipt stored.",
            display: true,
          });
        },
      });
    }\n`);
    const trust = new TrustService(agentDir);
    await trust.set(cwd, true);
    const registry = new RuntimeRegistry({
      agentDir,
      tronHome: join(root, "tron"),
      idleRuntimeMs: 60_000,
      trust,
      broadcast: () => {},
      sessionSummaryChanged: () => {},
      sessionListChanged: () => {},
    });
    registries.push(registry);
    await initializeRegistry(registry);
    const slot = await registry.create(cwd);

    await expect(slot.prompt("/notify-command count to 20")).resolves.toEqual({ operationId: expect.any(String) });
    await waitFor(() => slot.snapshot().transcript.some(item =>
      item.kind === "customEntry" && item.semantic?.kind === "status"), "the status entry in the transcript");
    await waitFor(() => slot.snapshot().transcript.filter(item =>
      item.kind === "customMessage" && item.semantic?.origin.kind === "extension").length === 2, "both extension messages in the transcript");
    const snapshot = slot.snapshot();
    const command = snapshot.transcript.find(item => item.semantic?.kind === "command");
    const commandOwnerID = command?.semantic?.origin.ownerId;
    expect(command).toMatchObject({
      semantic: {
        direction: "ambientStatus",
        contextEffect: "none",
        lifecycle: "completed",
        origin: { kind: "extension", ownerId: expect.any(String) },
      },
    });
    expect(snapshot.transcript.find(item =>
      item.kind === "customEntry" && item.semantic?.kind === "status")).toMatchObject({
      kind: "customEntry",
      data: expect.objectContaining({ message: "Goal created.", tone: "info" }),
      semantic: {
        direction: "ambientStatus",
        contextEffect: "none",
        origin: expect.objectContaining({ kind: "extension", ownerId: commandOwnerID }),
      },
    });
    const customMessages = snapshot.transcript.filter(item => item.kind === "customMessage");
    expect(customMessages).toHaveLength(2);
    expect(customMessages[0]).toMatchObject({
      details: { goal: { objective: "count to 20", status: "active" } },
      semantic: {
        direction: "inboundContext",
        contextEffect: "modelInput",
        delivery: "stored",
        origin: expect.objectContaining({ kind: "extension", ownerId: commandOwnerID }),
      },
    });
    expect(customMessages[1]).toMatchObject({
      semantic: {
        direction: "inboundContext",
        contextEffect: "modelInput",
        delivery: "stored",
        origin: expect.objectContaining({ kind: "extension", ownerId: commandOwnerID }),
      },
    });
  });

  it("records a caught extension-command handler error as a failed canonical invocation", async () => {
    const root = await mkdtemp(join(tmpdir(), "tron-extension-command-failure-"));
    const agentDir = join(root, "agent");
    const cwd = join(root, "workspace");
    const extensionDir = join(cwd, ".pi", "extensions");
    await Promise.all([mkdir(agentDir), mkdir(extensionDir, { recursive: true })]);
    await writeFile(join(extensionDir, "failing-command.ts"), `export default function (pi) {
      pi.registerCommand("fail-command", {
        description: "Fail deterministically",
        handler: async () => { throw new Error("expected command failure"); },
      });
    }\n`);
    const trust = new TrustService(agentDir);
    await trust.set(cwd, true);
    const registry = new RuntimeRegistry({
      agentDir,
      tronHome: join(root, "tron"),
      idleRuntimeMs: 60_000,
      trust,
      broadcast: () => {},
      sessionSummaryChanged: () => {},
      sessionListChanged: () => {},
    });
    registries.push(registry);
    await initializeRegistry(registry);
    const slot = await registry.create(cwd);

    await expect(slot.prompt("/fail-command")).resolves.toEqual({ operationId: expect.any(String) });
    await waitFor(() => (slot as any).pendingExtensionCommand === undefined, "the pending extension command to clear");
    const command = slot.snapshot().transcript.find(item => item.semantic?.kind === "command");
    expect(command).toMatchObject({
      semantic: {
        lifecycle: "failed",
        resourceInvocation: { source: "extension", name: "fail-command" },
      },
    });
  });

  it("keeps exact extension-shutdown ownership through a failed close retry", async () => {
    const fixture = await coldFixture("extension-shutdown-retry");
    const slot = await fixture.registry.acquire(fixture.manager.getSessionId());
    const runtime = (slot as unknown as { runtime: { dispose: () => Promise<void> } }).runtime;
    const originalDispose = runtime.dispose.bind(runtime);
    const dispose = vi.spyOn(runtime, "dispose")
      .mockRejectedValueOnce(new Error("injected shutdown failure"))
      .mockImplementationOnce(originalDispose);

    (slot as unknown as { requestExtensionShutdown: () => void }).requestExtensionShutdown();
    await waitFor(() => dispose.mock.calls.length === 1, "the disposal");
    expect(fixture.registry.administrativeWorkRegistry.facts()).toMatchObject([{
      kind: "extension-command-prompt-ui",
      sessionId: slot.id,
    }]);
    await waitFor(() => dispose.mock.calls.length === 2, "the second disposal");
    await waitFor(() => fixture.registry.administrativeWorkRegistry.size === 0, "the administrative work registry to drain");
    expect(slot.isDisposed).toBe(true);
  });

  it("retries registry disposal after a transient slot failure without duplicating shared cleanup", async () => {
    const fixture = await coldFixture("registry-dispose-retry");
    const slot = await fixture.registry.acquire(fixture.manager.getSessionId());
    const originalShutdown = slot.shutdown.bind(slot);
    const shutdown = vi.spyOn(slot, "shutdown")
      .mockRejectedValueOnce(new Error("injected slot shutdown failure"))
      .mockImplementation(originalShutdown);
    const internals = fixture.registry as unknown as {
      blobs: { dispose: () => Promise<void> };
      exports: { dispose: () => Promise<void> };
      workspace: { dispose: () => Promise<void> };
      slots: Map<string, unknown>;
    };
    const disposeCalls = {
      blobs: 0,
      exports: 0,
      workspace: 0,
    };
    for (const [name, store] of Object.entries({
      blobs: internals.blobs,
      exports: internals.exports,
      workspace: internals.workspace,
    }) as Array<[keyof typeof disposeCalls, { dispose: () => Promise<void> }]>) {
      const originalDispose = store.dispose.bind(store);
      vi.spyOn(store, "dispose").mockImplementation(async () => {
        disposeCalls[name] += 1;
        await originalDispose();
      });
    }

    const first = fixture.registry.dispose();
    const concurrent = fixture.registry.dispose();
    await expect(first).rejects.toThrow("One or more session runtimes failed");
    await expect(concurrent).rejects.toThrow("One or more session runtimes failed");
    expect(shutdown).toHaveBeenCalledTimes(1);
    expect(internals.slots.get(slot.id)).toBe(slot);
    await fixture.registry.dispose();
    expect(shutdown).toHaveBeenCalledTimes(2);
    expect(internals.slots.has(slot.id)).toBe(false);
    expect(disposeCalls).toEqual({ blobs: 1, exports: 1, workspace: 1 });
  });

  it("retries only failed shared-store disposal after partial cleanup", async () => {
    const fixture = await coldFixture("registry-shared-dispose-retry");
    const internals = fixture.registry as unknown as {
      blobs: { dispose: () => Promise<void> };
      exports: { dispose: () => Promise<void> };
      workspace: { dispose: () => Promise<void> };
    };
    const originalBlobDispose = internals.blobs.dispose.bind(internals.blobs);
    const originalExportsDispose = internals.exports.dispose.bind(internals.exports);
    const originalWorkspaceDispose = internals.workspace.dispose.bind(internals.workspace);
    const blobs = vi.spyOn(internals.blobs, "dispose")
      .mockRejectedValueOnce(new Error("injected blob cleanup failure"))
      .mockImplementation(originalBlobDispose);
    const exports = vi.spyOn(internals.exports, "dispose").mockImplementation(originalExportsDispose);
    const workspace = vi.spyOn(internals.workspace, "dispose").mockImplementation(originalWorkspaceDispose);

    await expect(fixture.registry.dispose()).rejects.toThrow("injected blob cleanup failure");
    expect(blobs).toHaveBeenCalledTimes(1);
    expect(exports).toHaveBeenCalledTimes(1);
    expect(workspace).toHaveBeenCalledTimes(1);
    await fixture.registry.dispose();
    expect(blobs).toHaveBeenCalledTimes(2);
    expect(exports).toHaveBeenCalledTimes(1);
    expect(workspace).toHaveBeenCalledTimes(1);
  });

  // G-1c/review minor 2: the close commit point queues the row, so a reopen can
  // land between a slot leaving `slots` and its row reaching the index. The row
  // build is held open here to make that window deterministic: membership must
  // wait for the queued change instead of answering not_found, because a session
  // must never become unopenable because its runtime closed.
  it("reopens a session whose runtime closed before its index row landed", async () => {
    const fixture = await coldFixture("close-before-row");
    // Every row build is held open, so the persisted session below has no index
    // row at the moment its slot closes. That makes the window the intermittent
    // merge-gate failure landed in deterministic.
    const build = CatalogMetadataIndex.prototype.entryFromSummary;
    let release!: () => void;
    const gate = new Promise<void>((resolve) => { release = resolve; });
    const held = vi.spyOn(CatalogMetadataIndex.prototype, "entryFromSummary").mockImplementation(async function (
      this: CatalogMetadataIndex,
      ...arguments_: Parameters<CatalogMetadataIndex["entryFromSummary"]>
    ) {
      await gate;
      return build.apply(this, arguments_);
    });
    try {
      const created = await fixture.registry.create(fixture.cwd);
      const manager = (created as unknown as { sessionManager: SessionManager }).sessionManager;
      manager.appendMessage(fauxAssistantMessage("persisted before extension close"));
      const persisted = (created as unknown as { session: () => void });
      // `publishSnapshot` is what a real close path observes as the persisted
      // commit; the row it queues cannot land while the build is held.
      created.publishSnapshot();
      await waitFor(() => created.persistedSessionFile !== undefined, "the persisted session file");
      await waitFor(() => (fixture.registry as unknown as { latestSummaries: Map<string, unknown> }).latestSummaries.has(created.id), "the latest summary for the created session");
      expect(catalogOwner(fixture.registry).rows().some((row) => row.id === created.id)).toBe(false);

      (created as unknown as { requestExtensionShutdown: () => void }).requestExtensionShutdown();
      await waitFor(() => created.isDisposed
        && !(fixture.registry as unknown as { slots: Map<string, unknown> }).slots.has(created.id), "the disposed session to leave the slot map");
      // The reopen lands in that window: it must wait for the queued row rather
      // than report the session as gone.
      const reopening = fixture.registry.acquire(created.id);
      await new Promise((resolve) => setTimeout(resolve, 25));
      release();
      const reopened = await reopening;
      expect(reopened.id).toBe(created.id);
      expect(JSON.stringify(reopened.snapshot().transcript)).toContain("persisted before extension close");
    } finally {
      release();
      held.mockRestore();
    }
  });

  it("scopes extension shutdown to the owning runtime slot", async () => {
    const root = await mkdtemp(join(tmpdir(), "tron-extension-scoped-shutdown-"));
    const agentDir = join(root, "agent");
    const closingCwd = join(root, "closing");
    const otherCwd = join(root, "other");
    const extensionDir = join(closingCwd, ".pi", "extensions");
    await Promise.all([mkdir(agentDir), mkdir(extensionDir, { recursive: true }), mkdir(otherCwd)]);
    await writeFile(join(extensionDir, "shutdown.ts"), `export default function (pi) {
      pi.on("session_shutdown", async (_event, ctx) => {
        await new Promise((resolve) => setTimeout(resolve, 50));
        ctx.ui.setStatus("shutdown", "complete");
        ctx.ui.notify("Shutdown complete.", "info");
      });
      pi.registerCommand("close-owning-session", { handler: async (_args, ctx) => ctx.shutdown() });
    }\n`);
    const trust = new TrustService(agentDir);
    await trust.set(closingCwd, true);
    const shutdownTopics: string[] = [];
    let listChanges = 0;
    const registry = new RuntimeRegistry({
      agentDir, tronHome: join(root, "tron"), idleRuntimeMs: 60_000, trust,
      broadcast: (_sessionID, topic) => shutdownTopics.push(topic),
      sessionSummaryChanged: () => {},
      sessionListChanged: () => { listChanges += 1; },
    });
    registries.push(registry);
    await initializeRegistry(registry);
    const closing = await registry.create(closingCwd);
    const other = await registry.create(otherCwd);
    const closingID = closing.id;
    const ownership = registry as unknown as {
      slots: Map<string, unknown>;
      summaryRevisions: Map<string, number>;
      latestSummaries: Map<string, SessionSummaryUpdate>;
    };
    expect(closing.persistedSessionFile).toBeUndefined();
    expect(ownership.summaryRevisions.has(closingID)).toBe(true);
    expect(ownership.latestSummaries.has(closingID)).toBe(true);

    await closing.prompt("/close-owning-session");
    await waitFor(() => !ownership.slots.has(closingID), "the closing session to leave the slot map");
    expect(() => other.context()).not.toThrow();
    expect(ownership.summaryRevisions.has(closingID)).toBe(false);
    expect(ownership.latestSummaries.has(closingID)).toBe(false);
    await expect(registry.acquire(closingID)).rejects.toMatchObject({ code: "not_found" });
    const shutdownStatusIndex = shutdownTopics.lastIndexOf("session.extensionPresentation");
    const closedIndex = shutdownTopics.lastIndexOf("session.closed");
    expect(shutdownStatusIndex).toBeGreaterThanOrEqual(0);
    expect(closedIndex).toBeGreaterThan(shutdownStatusIndex);

    const persisted = await registry.create(closingCwd);
    const persistedManager = (persisted as unknown as { sessionManager: SessionManager }).sessionManager;
    persistedManager.appendMessage(fauxAssistantMessage("persisted before extension close"));
    persisted.publishSnapshot();
    expect(persisted.persistedSessionFile).toBeDefined();
    const persistedID = persisted.id;
    const revisionBeforeClose = ownership.summaryRevisions.get(persistedID)!;
    const structuralChangesBeforeClose = listChanges;

    await persisted.prompt("/close-owning-session");
    await waitFor(() => !ownership.slots.has(persistedID), "the persisted session to leave the slot map");
    expect(listChanges).toBe(structuralChangesBeforeClose);
    expect(ownership.summaryRevisions.get(persistedID)).toBeGreaterThanOrEqual(revisionBeforeClose);
    expect(ownership.latestSummaries.get(persistedID)).toMatchObject({
      sessionId: persistedID,
      phase: "idle",
      summaryRevision: ownership.summaryRevisions.get(persistedID),
    });
    const reopened = await registry.acquire(persistedID);
    expect(reopened.snapshot().transcript.find(item =>
      item.kind === "customEntry" && item.semantic?.kind === "status"
        && item.data !== undefined && !Array.isArray(item.data)
        && typeof item.data === "object" && item.data !== null
        && item.data.message === "Shutdown complete.")).toMatchObject({
      data: expect.objectContaining({ message: "Shutdown complete." }),
      semantic: { direction: "ambientStatus", contextEffect: "none" },
    });
  });

  it("isolates same-named providers registered by concurrent project extensions", async () => {
    const root = await mkdtemp(join(tmpdir(), "tron-provider-isolation-"));
    const agentDir = join(root, "agent");
    const firstCwd = join(root, "first");
    const secondCwd = join(root, "second");
    await Promise.all([
      mkdir(agentDir),
      mkdir(join(firstCwd, ".pi", "extensions"), { recursive: true }),
      mkdir(join(secondCwd, ".pi", "extensions"), { recursive: true }),
    ]);
    const extension = (name: string) => `export default function (pi) { pi.registerProvider("project-provider", { baseUrl: "https://provider.invalid", apiKey: "fixture", api: "openai-completions", models: [{ id: "model", name: ${JSON.stringify(name)}, reasoning: false, input: ["text"], cost: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0 }, contextWindow: 4096, maxTokens: 1024 }] }); }\n`;
    await Promise.all([
      writeFile(join(firstCwd, ".pi", "extensions", "provider.ts"), extension("First Project Model")),
      writeFile(join(secondCwd, ".pi", "extensions", "provider.ts"), extension("Second Project Model")),
    ]);
    const trust = new TrustService(agentDir);
    await Promise.all([trust.set(firstCwd, true), trust.set(secondCwd, true)]);
    const registry = new RuntimeRegistry({
      agentDir,
      tronHome: join(root, "tron"),
      idleRuntimeMs: 60_000,
      trust,
      broadcast: () => {},
      sessionSummaryChanged: () => {},
      sessionListChanged: () => {},
    });
    registries.push(registry);
    await initializeRegistry(registry);

    const [first, second] = await Promise.all([registry.create(firstCwd), registry.create(secondCwd)]);
    expect(first.modelRuntime).not.toBe(second.modelRuntime);
    expect(first.modelRuntime.getModel("project-provider", "model")?.name).toBe("First Project Model");
    expect(second.modelRuntime.getModel("project-provider", "model")?.name).toBe("Second Project Model");
  });

  it("projects the canonical latest cache hit rate used by the terminal footer", async () => {
    const root = await mkdtemp(join(tmpdir(), "tron-cache-rate-integration-"));
    const agentDir = join(root, "agent");
    const sessionDir = join(root, "sessions");
    const cwd = join(root, "workspace");
    await Promise.all([mkdir(agentDir), mkdir(sessionDir), mkdir(cwd)]);
    await writeFile(join(agentDir, "settings.json"), JSON.stringify({ sessionDir }));
    const faux = fauxProvider({ provider: "tron-cache-rate", tokensPerSecond: 10_000 });
    const createModels = async () => {
      const runtime = await ModelRuntime.create({ modelsPath: null, refreshOnCreate: false });
      runtime.registerNativeProvider(faux.provider);
      return runtime;
    };
    faux.setResponses([fauxAssistantMessage("cached")]);
    const registry = new RuntimeRegistry({
      agentDir,
      tronHome: join(root, "tron"),
      idleRuntimeMs: 60_000,
      modelRuntimeFactory: createModels,
      trust: new TrustService(agentDir),
      broadcast: () => {},
      sessionSummaryChanged: () => {},
      sessionListChanged: () => {},
    });
    registries.push(registry);
    await initializeRegistry(registry);
    const slot = await registry.create(cwd);
    expect(slot.sessionFile?.startsWith(sessionDir)).toBe(true);
    const model = faux.getModel();
    await slot.setModel(model.provider, model.id);
    await slot.prompt("cache stats");
    await waitFor(() => !slot.isBusy, "the slot to go idle");

    const snapshot = slot.snapshot();
    const assistant = snapshot.transcript.find((item) => item.role === "assistant");
    const usage = (assistant as any)?.usage as { input?: number; cacheRead?: number; cacheWrite?: number } | undefined;
    const promptTokens = (usage?.input ?? 0) + (usage?.cacheRead ?? 0) + (usage?.cacheWrite ?? 0);
    const expected = promptTokens > 0 ? ((usage?.cacheRead ?? 0) / promptTokens) * 100 : undefined;
    expect(snapshot.stats.latestCacheHitRate).toBe(expected);
  });

  it("projects readable metadata for project resources", async () => {
    const root = await mkdtemp(join(tmpdir(), "tron-resources-integration-"));
    const agentDir = join(root, "agent");
    const cwd = join(root, "workspace");
    const pi = join(cwd, ".pi");
    await Promise.all([
      mkdir(agentDir),
      mkdir(join(pi, "extensions"), { recursive: true }),
      mkdir(join(pi, "prompts"), { recursive: true }),
      mkdir(join(pi, "skills", "review"), { recursive: true }),
    ]);
    const cwdAlias = join(root, "workspace-alias");
    await symlink(cwd, cwdAlias);
    await Promise.all([
      writeFile(join(pi, "extensions", "tool.ts"), `export default function (pi) { pi.on("session_start", () => {}); pi.registerTool({ name: "project_echo", label: "Project echo", description: "Echo project text", parameters: { type: "object", properties: { text: { type: "string" } }, required: ["text"] }, execute: async (_id, params) => ({ content: [{ type: "text", text: params.text }], details: {} }) }); }\n`),
      writeFile(join(pi, "prompts", "review.md"), `---\ndescription: Review the current change\n---\nReview $ARGUMENTS\n`),
      writeFile(join(pi, "skills", "review", "SKILL.md"), `---\nname: review-skill\ndescription: Inspect a code change\n---\nReview carefully.\n`),
    ]);
    const trust = new TrustService(agentDir);
    await trust.set(cwd, true);
    const resourceEvents: string[] = [];
    const registry = new RuntimeRegistry({
      agentDir,
      tronHome: join(root, "tron"),
      idleRuntimeMs: 60_000,
      trust,
      broadcast: (_sessionId, topic) => { resourceEvents.push(topic); },
      sessionSummaryChanged: () => {},
      sessionListChanged: () => {},
    });
    registries.push(registry);
    await initializeRegistry(registry);

    const slot = await registry.create(cwd);
    const resources = await slot.resources() as any;
    // The inventory is the complete display-safe registration view for every
    // loaded extension: this project extension plus Tron's own inline
    // capabilities. Assert the accounting contract rather than a fixed count,
    // which changes whenever Tron adds or removes a first-party capability;
    // the exact per-extension rows are asserted below.
    const inventory = resources.hookInventory;
    for (const key of ["extensions", "handlerEvents", "loadErrors"] as const) {
      expect(inventory[key].retained + inventory[key].omitted).toBe(inventory[key].total);
      expect(inventory[key].omitted).toBe(0);
    }
    expect(inventory.extensions.total).toBeGreaterThanOrEqual(2);
    expect(inventory.handlerEvents.total).toBeGreaterThanOrEqual(1);
    expect(inventory.encodedBytes).toBeGreaterThan(0);
    expect(inventory.encodedBytes).toBeLessThanOrEqual(inventory.encodedBytesLimit);
    expect(resources.extensions).toEqual(expect.arrayContaining([
      expect.objectContaining({
        name: "tool.ts",
        scope: "project",
        tools: ["project_echo"],
        handlers: [{ event: "session_start", count: 1 }],
      }),
    ]));
    expect(resources.prompts.prompts).toEqual(expect.arrayContaining([
      expect.objectContaining({ name: "review", description: "Review the current change", scope: "project" }),
    ]));
    expect(resources.skills.skills).toEqual(expect.arrayContaining([
      expect.objectContaining({ name: "review-skill", description: "Inspect a code change", scope: "project" }),
    ]));
    expect(resources.tools).toEqual(expect.arrayContaining([
      expect.objectContaining({
        name: "project_echo", label: "Project echo",
        description: "Echo project text", scope: "project",
      }),
    ]));

    resourceEvents.length = 0;
    await registry.reloadProject(cwd, false, false);
    await expect(slot.resources()).rejects.toThrow("Project trust is being reconfigured");
    expect(() => slot.modelRuntime).toThrow("Project trust is being reconfigured");
    expect(() => slot.sessionEnvironment()).toThrow("Project trust is being reconfigured");
    expect(() => slot.respondToInteraction("pending", "host", 0, null, true)).toThrow("Project trust is being reconfigured");
    await expect(registry.create(cwd)).rejects.toMatchObject({ code: "busy", retryable: true });
    await expect(registry.create(cwdAlias)).rejects.toMatchObject({ code: "busy", retryable: true });
    await expect(trust.inspect(cwd)).resolves.toMatchObject({ savedDecision: true });
    expect(resourceEvents).not.toContain("session.resourcesChanged");
    await trust.set(cwd, false);
    await registry.commitProjectReload(cwd);
    const untrusted = await slot.resources() as any;
    expect(untrusted.tools).not.toEqual(expect.arrayContaining([
      expect.objectContaining({ name: "project_echo" }),
    ]));
    expect(resourceEvents).toContain("session.resourcesChanged");
  });

  /** A real runtime slot whose project, user and settings-listed package
   * resources exercise every distribution branch, with pi-subagents absent. */
  async function distributionFixture(): Promise<any> {
    const root = await mkdtemp(join(tmpdir(), "tron-resource-distribution-"));
    const agentDir = join(root, "agent");
    const cwd = join(root, "workspace");
    const pi = join(cwd, ".pi");
    const packageRoot = join(root, "vendor-subagent-package");
    await Promise.all([
      mkdir(join(agentDir, "skills", "user-skill"), { recursive: true }),
      mkdir(join(pi, "extensions"), { recursive: true }),
      mkdir(join(pi, "prompts"), { recursive: true }),
      mkdir(join(pi, "skills", "review"), { recursive: true }),
      mkdir(join(packageRoot, "extensions"), { recursive: true }),
    ]);
    // A settings-listed local package resolves with Pi's `package` origin, the
    // same shape an npm-installed tool carries, without installing anything.
    await writeFile(join(agentDir, "settings.json"), JSON.stringify({ packages: [packageRoot] }));
    await Promise.all([
      writeFile(join(agentDir, "skills", "user-skill", "SKILL.md"), `---\nname: user-skill\ndescription: A user skill\n---\nUse it.\n`),
      writeFile(join(pi, "extensions", "tool.ts"), `export default function (pi) { pi.registerTool({ name: "project_echo", label: "Project echo", description: "Echo project text", parameters: { type: "object", properties: {} }, execute: async () => ({ content: [{ type: "text", text: "ok" }], details: {} }) }); }\n`),
      writeFile(join(pi, "prompts", "review.md"), `---\ndescription: Review the current change\n---\nReview $ARGUMENTS\n`),
      writeFile(join(pi, "skills", "review", "SKILL.md"), `---\nname: review-skill\ndescription: Inspect a code change\n---\nReview carefully.\n`),
      writeFile(join(packageRoot, "extensions", "package-tool.ts"), `export default function (pi) { pi.registerTool({ name: "package_echo", label: "Package echo", description: "Echo packaged text", parameters: { type: "object", properties: {} }, execute: async () => ({ content: [{ type: "text", text: "ok" }], details: {} }) }); }\n`),
    ]);
    const trust = new TrustService(agentDir);
    await trust.set(cwd, true);
    const registry = new RuntimeRegistry({
      agentDir,
      tronHome: join(root, "tron"),
      idleRuntimeMs: 60_000,
      trust,
      broadcast: () => {},
      sessionSummaryChanged: () => {},
      sessionListChanged: () => {},
    });
    registries.push(registry);
    await initializeRegistry(registry);
    return registry.create(cwd);
  }

  it("tags every available resource with its distribution", async () => {
    const slot = await distributionFixture();
    const resources = await slot.resources() as any;
    const tool = (name: string) => resources.tools.find((candidate: any) => candidate.name === name);

    // External: a settings-listed package's tool carries Pi's package origin.
    expect(tool("package_echo")).toMatchObject({ distribution: "external" });
    // Module: an inline Tron extension factory tool.
    expect(tool("ask_user")).toMatchObject({ distribution: "module" });
    // Local: a project extension's tool.
    expect(tool("project_echo")).toMatchObject({ distribution: "local" });
    // Pi built-ins carry no tag at all.
    expect(Object.prototype.hasOwnProperty.call(tool("read"), "distribution")).toBe(false);
    expect(Object.prototype.hasOwnProperty.call(tool("bash"), "distribution")).toBe(false);

    expect(resources.skills.skills).toEqual(expect.arrayContaining([
      expect.objectContaining({ name: "user-skill", scope: "user", distribution: "local" }),
      expect.objectContaining({ name: "review-skill", scope: "project", distribution: "local" }),
    ]));
    expect(resources.prompts.prompts).toEqual(expect.arrayContaining([
      expect.objectContaining({ name: "review", scope: "project", distribution: "local" }),
    ]));

    // Commands keep Pi's resourceOrigin and gain the separate distribution tag.
    const promptCommand = resources.commands.find((candidate: any) => candidate.source === "prompt" && candidate.name === "review");
    expect(promptCommand).toMatchObject({ resourceOrigin: "top-level", distribution: "local" });
    const skillCommand = resources.commands.find((candidate: any) => candidate.source === "skill" && candidate.name === "skill:user-skill");
    expect(skillCommand).toMatchObject({ resourceOrigin: "top-level", distribution: "local" });
  });

  it("fails soft for subagents when pi-subagents is absent", async () => {
    const slot = await distributionFixture();
    const resources = await slot.resources() as any;
    // Discovery must not take down the whole response.
    expect(resources.subagents).toEqual([]);
    expect(typeof resources.subagentDiagnostics).toBe("string");
  });

  it("persists the first invocation receipt with the first user message across runtime teardown", async () => {
    const root = await mkdtemp(join(tmpdir(), "tron-first-message-receipt-"));
    const agentDir = join(root, "agent");
    const cwd = join(root, "workspace");
    await Promise.all([mkdir(agentDir), mkdir(cwd)]);
    const trust = new TrustService(agentDir);
    await trust.set(cwd, true);
    const faux = fauxProvider({ provider: "tron-first-message-receipt", tokensPerSecond: 10_000 });
    faux.setResponses([fauxAssistantMessage("first response")]);
    const createRuntime = async () => {
      const runtime = await ModelRuntime.create({ modelsPath: null, refreshOnCreate: false });
      runtime.registerNativeProvider(faux.provider);
      return runtime;
    };
    const createRegistry = async () => {
      const registry = new RuntimeRegistry({
        agentDir,
        tronHome: join(root, "tron"),
        idleRuntimeMs: 60_000,
        modelRuntimeFactory: createRuntime,
        trust,
        broadcast: () => {},
        sessionSummaryChanged: () => {},
        sessionListChanged: () => {},
      });
      registries.push(registry);
      await initializeRegistry(registry);
      return registry;
    };
    let registry: RuntimeRegistry | undefined;
    try {
      registry = await createRegistry();
      const slot = await registry.create(cwd);
      const model = faux.getModel();
      await slot.setModel(model.provider, model.id);
      const admitted = await slot.prompt("persist the first turn");
      await waitFor(() => !slot.isBusy, "the slot to go idle");
      const sessionFile = slot.sessionFile!;
      const entries = (await readFile(sessionFile, "utf8"))
        .trimEnd().split("\n").map(line => JSON.parse(line) as Record<string, any>);
      expect(entries.some(entry => entry.type === "message" && entry.message?.role === "user"
        && entry.message.content?.some((part: { text?: string }) => part.text === "persist the first turn"))).toBe(true);
      const firstReceipt = entries.find(entry => entry.type === "custom"
        && entry.customType === INVOCATION_RECEIPT_TYPE
        && entry.data?.operationId === admitted.operationId
        && entry.data?.receiptKind === "start");
      expect(firstReceipt).toBeDefined();

      // Runtime teardown/reopen exercises the canonical persistence boundary,
      // not just the old slot's in-memory SessionManager branch.
      await registry.dispose();
      registries.splice(registries.indexOf(registry), 1);
      registry = await createRegistry();
      expect((await registry.list()).map(session => session.id)).toContain(slot.id);
      const reopened = await registry.acquire(slot.id);
      const reopenedEntries = (await readFile(reopened.sessionFile!, "utf8"))
        .trimEnd().split("\n").map(line => JSON.parse(line) as Record<string, any>);
      expect(reopenedEntries).toContainEqual(firstReceipt);
      expect(reopened.snapshot().transcript.some(item => item.role === "user"
        && JSON.stringify(item).includes("persist the first turn"))).toBe(true);
    } finally {
      if (registry) {
        await registry.dispose();
        registries.splice(registries.indexOf(registry), 1);
      }
      await rm(root, { recursive: true, force: true });
    }
  });

  it("rekeys the owning slot when a completed session is forked", async () => {
    const root = await mkdtemp(join(tmpdir(), "tron-runtime-fork-"));
    const agentDir = join(root, "agent");
    const cwd = join(root, "workspace");
    await Promise.all([mkdir(agentDir), mkdir(cwd)]);
    process.env.PI_CODING_AGENT_DIR = agentDir;

    const faux = fauxProvider({ provider: "tron-fork", tokensPerSecond: 10_000 });
    const createModels = async () => {
      const runtime = await ModelRuntime.create({ modelsPath: null, refreshOnCreate: false });
      runtime.registerNativeProvider(faux.provider);
      return runtime;
    };
    faux.setResponses([fauxAssistantMessage("done")]);
    const rekeys: Array<[string, string]> = [];
    const registry = new RuntimeRegistry({
      agentDir,
      tronHome: join(root, "tron"),
      idleRuntimeMs: 60_000,
      modelRuntimeFactory: createModels,
      trust: new TrustService(agentDir),
      broadcast: () => {},
      sessionSummaryChanged: () => {},
      sessionListChanged: () => {},
      sessionRekeyed: (previousId, nextId) => {
        rekeys.push([previousId, nextId]);
        throw new Error("injected post-commit observer failure");
      },
    });
    registries.push(registry);
    await initializeRegistry(registry);
    const slot = await registry.create(cwd);
    const model = faux.getModel();
    await slot.setModel(model.provider, model.id);
    await slot.prompt("fork this");
    await waitFor(() => !slot.isBusy, "the slot to go idle");
    const original = slot.id;
    expect(registry.attentionProjection(original).isUnread).toBe(true);
    const userEntry = slot.snapshot().transcript.find((item) => item.role === "user");
    const assistantEntry = slot.snapshot().transcript.find((item) => item.role === "assistant");
    expect(userEntry).toBeDefined();
    expect(assistantEntry).toBeDefined();
    registry.subscribe("fork-subscriber", original);
    const internals = registry as unknown as {
      attention: { assertAbsent: (sessionId: string) => Promise<void> };
      slots: Map<string, typeof slot>;
      latestSummaries: Map<string, SessionSummaryUpdate>;
    };
    const parentPath = (slot as unknown as { sessionManager: SessionManager }).sessionManager.getSessionFile()!;
    const parentBytes = await readFile(parentPath);
    const forkDirectory = join(dirname(parentPath), basename(parentPath, ".jsonl"), "forks");
    const forkListingBefore = existsSync(forkDirectory)
      ? (await readdir(forkDirectory)).filter((name) => name.endsWith(".jsonl")).sort()
      : [];
    const assertAbsent = vi.spyOn(internals.attention, "assertAbsent")
      .mockRejectedValueOnce(new Error("injected attention prepare failure"));
    // Retaining the assistant makes Pi materialize the candidate fork before
    // registry rekey admission. A rejected pre-commit hook must roll that file
    // back rather than leaking an orphan catalog row.
    await expect(slot.fork(assistantEntry!.id, "at")).rejects.toThrow("injected attention prepare failure");
    expect(slot.id).toBe(original);
    expect((await registry.list()).map((session) => session.id)).toEqual([original]);
    expect(internals.slots.get(original)).toBe(slot);
    expect([...internals.slots.values()].filter((candidate) => candidate === slot)).toHaveLength(1);
    expect(registry.isSubscribed("fork-subscriber", original)).toBe(true);
    expect(internals.latestSummaries.get(original)?.sessionId).toBe(original);
    expect(registry.attentionProjection(original).isUnread).toBe(true);
    expect(await readFile(parentPath)).toEqual(parentBytes);
    const forkListingAfter = existsSync(forkDirectory)
      ? (await readdir(forkDirectory)).filter((name) => name.endsWith(".jsonl")).sort()
      : [];
    expect(forkListingAfter).toEqual(forkListingBefore);
    assertAbsent.mockRestore();

    const fork = await slot.fork(userEntry!.id, "at");
    expect(fork.sessionId).not.toBe(original);
    expect(rekeys).toEqual([[original, fork.sessionId]]);
    expect(registry.attentionProjection(original).isUnread).toBe(true);
    expect(registry.attentionProjection(fork.sessionId)).toEqual({
      completionRevision: 0,
      attentionRevision: 0,
      isUnread: false,
    });
    expect((await registry.acquire(fork.sessionId)).id).toBe(fork.sessionId);

    // Pi 0.99 materializes a fork as soon as its retained first user entry is
    // appended, so catalog identity now comes from the canonical file.
    expect(slot.persistedSessionFile).toBeDefined();
    const forkHeader = JSON.parse((await readFile(slot.persistedSessionFile!, "utf8")).split("\n", 1)[0]!) as {
      parentSession?: string;
    };
    expect(forkHeader.parentSession).toBe(parentPath);
    expect(slot.snapshot().transcript.filter((item) => item.role === "user")).toEqual([
      expect.objectContaining({
        kind: "message",
        role: "user",
        content: [expect.objectContaining({ type: "text", text: "fork this" })],
      }),
    ]);
    const catalog = await registry.list();
    expect(catalog.find((session) => session.id === original)).toMatchObject({ kind: "user" });
    expect(catalog.find((session) => session.id === fork.sessionId)).toMatchObject({
      kind: "user",
      firstMessage: "fork this",
      messageCount: 1,
    });

    // The retained prompt-only fork must carry one boundary through both
    // snapshot/page seams after Pi materializes its first user entry.
    const prePromptBoundary = slot.snapshot().forkBoundary;
    expect(prePromptBoundary).toMatchObject({
      kind: "sessionFork", inheritedAnchorId: userEntry!.id, gapOrdinal: expect.any(Number),
    });
    expect(slot.transcriptPage().forkBoundary).toEqual(prePromptBoundary);

    // The first child completion materializes Pi's reserved JSONL. Catalog
    // authority must cross from the live parent ID to the canonical header/path
    // without losing identity, classification, or retained history.
    faux.setResponses([fauxAssistantMessage("continued")]);
    await slot.prompt("continue here");
    await waitFor(() => !slot.isBusy, "the slot to go idle");
    expect(slot.persistedSessionFile).toBeDefined();
    const boundary = slot.snapshot().forkBoundary;
    expect(boundary).toEqual(prePromptBoundary);
    expect(slot.transcriptPage().forkBoundary).toEqual(boundary);
    expect(slot.snapshot().transcript.filter((item) => item.role === "user" || item.role === "assistant")).toEqual([
      expect.objectContaining({ role: "user", content: [expect.objectContaining({ text: "fork this" })] }),
      expect.objectContaining({ role: "user", content: [expect.objectContaining({ text: "continue here" })] }),
      expect.objectContaining({ role: "assistant", content: [expect.objectContaining({ text: "continued" })] }),
    ]);
    expect((await registry.list()).find((session) => session.id === fork.sessionId)).toMatchObject({
      kind: "user",
      parentSessionId: original,
      firstMessage: "fork this",
      messageCount: 3,
    });
    await slot.dispose();
    expect((await registry.list()).find((session) => session.id === fork.sessionId)).toMatchObject({
      kind: "user",
      parentSessionId: original,
      firstMessage: "fork this",
      messageCount: 3,
    });
    const reopenedCatalog = await registry.list();
    expect(reopenedCatalog.find((session) => session.id === fork.sessionId)).toMatchObject({
      kind: "user",
      parentSessionId: original,
      firstMessage: "fork this",
      messageCount: 3,
    });
    const reopened = await registry.acquire(fork.sessionId);
    expect(reopened.snapshot().forkBoundary).toEqual(boundary);
    const transcriptBeforeParentRemoval = reopened.snapshot().transcript;
    await reopened.dispose();
    await rm(parentPath);
    const withoutParent = await registry.acquire(fork.sessionId);
    expect(withoutParent.snapshot().forkBoundary).toBeUndefined();
    expect(withoutParent.snapshot().transcript).toEqual(transcriptBeforeParentRemoval);
  });

  it("moves notification inbox rows only for a migrated session identity", async () => {
    const rekeys: Array<[string, string]> = [];
    const notifications = {
      rekeySession: async (previousId: string, nextId: string) => {
        rekeys.push([previousId, nextId]);
        return true;
      },
    } as unknown as NotificationService;
    const { manager, registry } = await coldFixture("notification-rekey", { notifications });
    const sessionId = manager.getSessionId();
    const slot = await registry.acquire(sessionId);
    // The private hook is the only rekey driver that does not itself need a
    // provider run; every other path is covered by its own focused case.
    const hooks = (registry as unknown as { hooks: () => {
      rekey: (previousId: string, nextId: string, slot: unknown, disposition: string, commit: () => void) => Promise<void>;
    } }).hooks();
    let commits = 0;
    await hooks.rekey(sessionId, "migrated-session", slot, "migrate", () => { commits += 1; });
    expect(commits).toBe(1);
    expect(rekeys).toEqual([[sessionId, "migrated-session"]]);
    // A reset rebind (a fork or a new session) starts a distinct identity: the
    // previous identity keeps the alerts it produced.
    await hooks.rekey("migrated-session", "reset-session", slot, "reset", () => { commits += 1; });
    expect(commits).toBe(2);
    expect(rekeys).toEqual([[sessionId, "migrated-session"]]);
  });

  it("rejects imports when live runtime capacity is full", async () => {
    const { root, cwd, registry } = await coldFixture("import-capacity", { maximumLiveRuntimes: 1 });
    await registry.create(cwd);

    await expect(registry.importFromJsonl(join(root, "import.jsonl"), cwd)).rejects.toMatchObject({
      code: "busy",
      retryable: true,
    });
  });

  it("admits direct Bash after proving idle without tripping on its own work token", async () => {
    const { manager, registry } = await coldFixture("bash-work-registry");
    const slot = await registry.acquire(manager.getSessionId());
    const internal = slot as unknown as {
      runtime: { session: { executeBash: (...arguments_: unknown[]) => Promise<unknown> } };
      activityHeartbeat?: NodeJS.Timeout;
    };
    const session = internal.runtime.session;
    let releaseBash!: () => void;
    const bashBarrier = new Promise<void>((resolve) => { releaseBash = resolve; });
    const execute = vi.spyOn(session, "executeBash").mockImplementation(async () => {
      await bashBarrier;
      return { output: "ok" };
    });
    const markerStore = (slot as unknown as {
      dependencies: { markers: { clear: (sessionId: string, operationId?: string) => Promise<void> } };
    }).dependencies.markers;
    const clearMarker = vi.spyOn(markerStore, "clear").mockRejectedValueOnce(new Error("transient clear failure"));

    const bash = slot.executeBash("printf ok", true);
    await waitFor(() => execute.mock.calls.length === 1, "the tool execution");
    expect(internal.activityHeartbeat).toBeDefined();
    expect(slot.snapshot().processActivities ?? []).toEqual([]);
    const markerPath = join((registry as unknown as { options: { tronHome: string } }).options.tronHome,
      "gateway", "runtime-markers", `${slot.id}.json`);
    expect(JSON.parse(await readFile(markerPath, "utf8")).operations).toHaveLength(1);
    let drained = false;
    const drain = registry.waitUntilIdle().then(() => { drained = true; });
    await new Promise((resolve) => setTimeout(resolve, 25));
    expect(drained).toBe(false);
    releaseBash();
    await expect(bash).resolves.toEqual({ output: "ok" });
    await drain;
    expect(clearMarker.mock.calls.length).toBeGreaterThanOrEqual(2);
    expect(execute).toHaveBeenCalledTimes(1);
    expect(registry.administrativeWorkRegistry.size).toBe(0);
    expect(internal.activityHeartbeat).toBeUndefined();
    expect(slot.snapshot()).toMatchObject({ phase: "idle" });
    expect(slot.snapshot().processActivities ?? []).toEqual([]);
  });

  it("filters Gateway-private environment from a real session Bash command", async () => {
    const { manager, registry } = await coldFixture("bash-command-environment");
    const slot = await registry.acquire(manager.getSessionId());
    const names = ["PI_SUBAGENTS_TEMP_ROOT", "PI_CODING_AGENT_DIR", "PI_SESSION_FILE", "PI_SUBAGENT_PARENT_SESSION", "TRON_GATEWAY_SUPERVISED", "TRON_GATEWAY_PAYLOAD_ROOT"] as const;
    const previous = new Map(names.map(name => [name, process.env[name]]));
    process.env.PI_SUBAGENTS_TEMP_ROOT = join(homedir(), ".tron", "internal", "subagents");
    process.env.PI_CODING_AGENT_DIR = join(homedir(), ".tron", "agent");
    process.env.PI_SESSION_FILE = join(homedir(), ".tron", "sessions", "private.jsonl");
    process.env.PI_SUBAGENT_PARENT_SESSION = "supervision-parent";
    process.env.TRON_GATEWAY_SUPERVISED = "1";
    process.env.TRON_GATEWAY_PAYLOAD_ROOT = join(homedir(), ".tron", "payload");
    try {
      await slot.executeBash("env | sort", true);
      const bash = slot.snapshot().transcript.find((item) => item.kind === "bash");
      expect(bash).toMatchObject({ kind: "bash" });
      if (!bash || bash.kind !== "bash") throw new Error("expected canonical Bash projection");
      expect(bash.output).toContain(`PI_SESSION_ID=${manager.getSessionId()}`);
      for (const name of names) expect(bash.output).not.toContain(`${name}=`);
      // PATH may legitimately locate Pi's managed agent tools under the live home;
      // no other variable may name a path inside a Tron home.
      const nonPath = bash.output.split("\n").filter((line) => !line.startsWith("PATH=")).join("\n");
      expect(nonPath).not.toContain(`${homedir()}/.tron/`);
      expect(nonPath).not.toContain(`${homedir()}/.tron-dev/`);
    } finally {
      for (const [name, value] of previous) {
        if (value === undefined) delete process.env[name];
        else process.env[name] = value;
      }
    }
  });

  it("retains exact direct Bash timing for canonical projection", async () => {
    const { manager, registry } = await coldFixture("bash-canonical-timing");
    const slot = await registry.acquire(manager.getSessionId());

    await slot.executeBash("printf ok", true);

    const bash = slot.snapshot().transcript.find((item) => item.kind === "bash");
    expect(bash).toMatchObject({
      kind: "bash",
      command: "printf ok",
      output: "ok",
      startedAt: expect.any(String),
      completedAt: expect.any(String),
      durationMs: expect.any(Number),
    });
    if (!bash || bash.kind !== "bash") throw new Error("expected canonical Bash projection");
    expect(bash.durationMs).toBeGreaterThanOrEqual(0);
  });

  it("does not commit idle eviction while canonical receipt persistence is unsettled", async () => {
    const { manager, registry } = await coldFixture("idle-eviction-receipt-barrier");
    const sessionId = manager.getSessionId();
    const slot = await registry.acquire(sessionId);
    vi.spyOn(slot, "touchedAt", "get").mockReturnValue(0);

    let settleReceipt!: () => void;
    const receipt = new Promise<void>((resolve) => { settleReceipt = resolve; });
    const internals = slot as unknown as { pendingReceiptWrites: Set<Promise<void>> };
    internals.pendingReceiptWrites.add(receipt);

    const eviction = (registry as unknown as { evictIdle: () => Promise<void> }).evictIdle();
    const outcome = await Promise.race([
      eviction.then(() => "settled" as const),
      new Promise<"blocked">((resolve) => setTimeout(() => resolve("blocked"), 100)),
    ]);
    settleReceipt();
    internals.pendingReceiptWrites.delete(receipt);
    await eviction;

    expect(outcome).toBe("settled");
    expect(await registry.acquire(sessionId)).toBe(slot);
    expect(slot.isDisposed).toBe(false);
  });

  it("force-invalidates an extension runtime whose idle-eviction shutdown never settles", async () => {
    // The registry's own option, so the test drives the production failure path;
    // a throwing recorder must not become another disposal barrier.
    const timedOut = vi.fn(() => { throw new Error("instrumentation failed"); });
    const { manager, registry } = await coldFixture("idle-eviction-shutdown-timeout", { runtimeDisposeTimeout: timedOut });
    const sessionId = manager.getSessionId();
    const slot = await registry.acquire(sessionId);
    vi.spyOn(slot, "touchedAt", "get").mockReturnValue(0);

    const internals = slot as unknown as {
      runtime: { dispose: () => Promise<void>; session: { dispose: () => void } };
    };
    const gracefulDispose = vi.spyOn(internals.runtime, "dispose")
      .mockImplementation(() => new Promise<void>(() => {}));
    const forceDispose = vi.spyOn(internals.runtime.session, "dispose");

    const eviction = (registry as unknown as { evictIdle: () => Promise<void> }).evictIdle();
    await waitFor(() => gracefulDispose.mock.calls.length === 1, "the graceful disposal");
    let acquisitionSettled = false;
    const acquisition = registry.acquire(sessionId).finally(() => { acquisitionSettled = true; });
    await new Promise((resolve) => setTimeout(resolve, 20));
    expect(acquisitionSettled).toBe(false);

    await eviction;
    const reopened = await acquisition;
    expect(timedOut).toHaveBeenCalledWith(5_000);
    expect(forceDispose).toHaveBeenCalledOnce();
    expect(slot.isDisposed).toBe(true);
    expect(reopened).not.toBe(slot);
    expect(reopened.id).toBe(sessionId);
  });

  it("keeps overlapping completed and queued failed observation cuts tied to their invocations", async () => {
    const root = await mkdtemp(join(tmpdir(), "tron-runtime-knowledge-overlap-"));
    const agentDir = join(root, "agent");
    const cwd = join(root, "project");
    await Promise.all([mkdir(agentDir), mkdir(cwd)]);
    process.env.PI_CODING_AGENT_DIR = agentDir;
    await writeFile(join(agentDir, "settings.json"), JSON.stringify({ retry: { enabled: false }, compaction: { enabled: false } }));
    const barrier = () => { let release!: () => void; const promise = new Promise<void>(resolve => { release = resolve; }); return { promise, release, resolve: release }; };
    const modelStarted = barrier();
    const releaseModel = barrier();
    const attentionEntered = barrier();
    const followUpStarted = barrier();
    const releaseFollowUpFailure = barrier();
    const faux = fauxProvider({ provider: "tron-knowledge-overlap", tokensPerSecond: 100_000 });
    faux.setResponses([
      async () => { modelStarted.resolve(); await releaseModel.promise; return fauxAssistantMessage("SYNTHETIC_EARLIER_RESPONSE"); },
      async () => {
        followUpStarted.resolve();
        await releaseFollowUpFailure.promise;
        return fauxAssistantMessage("SYNTHETIC_FOLLOWUP_FAILURE", { stopReason: "error", errorMessage: "synthetic controlled failure" });
      },
    ]);
    const admissions: any[] = [];
    const registry = new RuntimeRegistry({
      agentDir, tronHome: join(root, "tron"), idleRuntimeMs: 60_000,
      modelRuntimeFactory: async () => { const runtime = await ModelRuntime.create({ modelsPath: null, refreshOnCreate: false }); runtime.registerNativeProvider(faux.provider); return runtime; },
      trust: new TrustService(agentDir), broadcast: () => {}, sessionSummaryChanged: () => {}, sessionListChanged: () => {},
    });
    registries.push(registry);
    registry.setKnowledgeService(new KnowledgeService(new KnowledgeStore(registry.knowledgeWorkspace()), { admit(cut: any) { admissions.push(structuredClone(cut)); }, dispose() {} } as any));
    await initializeRegistry(registry);
    const slot = await registry.create(cwd);
    const selectedModel = faux.getModel();
    await slot.setModel(selectedModel.provider, selectedModel.id);
    const originalAttention = slot.hooks.assistantResponseCompleted.bind(slot.hooks);
    slot.hooks.assistantResponseCompleted = async (...args: any[]) => { attentionEntered.resolve(); return originalAttention(...args); };
    let initial: { operationId: string };
    let queued: { operationId: string };
    try {
      initial = await slot.prompt("SYNTHETIC_INITIAL_TASK");
      await modelStarted.promise;
      queued = await slot.prompt("SYNTHETIC_QUEUED_TASK", [], "followUp");
      releaseModel.resolve();
      await followUpStarted.promise;
      await attentionEntered.promise;
      await waitFor(() => admissions.some(cut => cut.completionId !== undefined), "the earlier completion cut while the follow-up is blocked");
      expect(admissions.find(cut => cut.completionId !== undefined)?.invocationId).toBe(
        invocationReceipts(slot.canonicalSessionEntries(), slot.id).find(receipt => receipt.operationId === initial.operationId && receipt.receiptKind === "terminal")?.invocationId,
      );
      releaseFollowUpFailure.resolve();
      await waitFor(() => invocationReceipts(slot.canonicalSessionEntries(), slot.id).some(receipt => receipt.operationId === queued.operationId && receipt.receiptKind === "terminal" && receipt.lifecycle === "failed"), "the failed receipt for the queued prompt");
    } finally {
      releaseModel.resolve();
      releaseFollowUpFailure.resolve();
    }
    await waitFor(() => !slot.isBusy && !slot.isDrainBusy, "the slot to go idle after the failed operation");
    const terminals = invocationReceipts(slot.canonicalSessionEntries(), slot.id).filter(receipt => receipt.receiptKind === "terminal");
    const firstReceipt = terminals.find(receipt => receipt.operationId === initial.operationId);
    const nextReceipt = terminals.find(receipt => receipt.operationId === queued.operationId);
    expect(firstReceipt?.lifecycle).toBe("completed");
    expect(nextReceipt?.lifecycle).toBe("failed");
    const first = admissions.find(cut => cut.completionId !== undefined);
    expect(first, "earlier canonical completion must have its own admitted cut").toBeDefined();
    expect(first.invocationId).toBe(firstReceipt!.invocationId);
    expect(first.outcome).toBe(firstReceipt!.lifecycle);
    expect(first.entries.some((entry: any) => entry.message?.role === "user" && JSON.stringify(entry.message.content).includes("SYNTHETIC_QUEUED_TASK"))).toBe(false);
    const next = admissions.find(cut => cut.invocationId === nextReceipt!.invocationId);
    expect(next, "queued failed invocation needs its own exact admission").toBeDefined();
    expect(next.outcome).toBe("failed");
    expect(next.entries).not.toHaveLength(0);
    expect(next.entries.some((entry: any) => entry.message?.role === "user" && JSON.stringify(entry.message.content).includes("SYNTHETIC_QUEUED_TASK"))).toBe(true);
    expect(faux.state.callCount).toBe(2);
  });

  it("cancels an idle eviction when a selected slot is acquired or subscribed before disposal", async () => {
    const { manager, registry } = await coldFixture("idle-eviction-acquire-subscribe");
    const sessionId = manager.getSessionId();
    const slot = await registry.acquire(sessionId);
    vi.spyOn(slot, "touchedAt", "get").mockReturnValue(0);

    let releaseLane!: () => void;
    let laneEntered!: () => void;
    const laneHeld = new Promise<void>((resolve) => { releaseLane = resolve; });
    const laneEnteredPromise = new Promise<void>((resolve) => { laneEntered = resolve; });
    const lane = (slot as unknown as { lane: { run: (operation: () => Promise<void>) => Promise<void> } }).lane;
    const blockedLane = lane.run(async () => {
      laneEntered();
      await laneHeld;
    });
    await laneEnteredPromise;

    const eviction = (registry as unknown as { evictIdle: () => Promise<void> }).evictIdle();
    await waitFor(() => (registry as unknown as { idleEvictions: Map<string, { slot: unknown }> }).idleEvictions.get(sessionId)?.slot === slot, "the idle eviction of the exact slot");

    const [acquired] = await Promise.all([
      registry.acquire(sessionId),
      Promise.resolve().then(() => registry.subscribe("race-client", sessionId)),
    ]);
    releaseLane();
    await Promise.all([blockedLane, eviction]);

    expect(acquired).toBe(slot);
    expect(await registry.acquire(sessionId)).toBe(slot);
    expect(registry.isSubscribed("race-client", sessionId)).toBe(true);
  });

  /** Every counter the resource sampler takes from the registry, as the registry
   * would report them; one object per fixture keeps the recorder shape in one
   * place. `recordSnapshotBuild` is not here: it is the transport's own method on
   * `ResourceSampler`, because only the transport counts recipient sockets. */
  function resourceRecorder() {
    return {
      recordTopicFrame: vi.fn(),
      recordCatalogWalk: vi.fn(),
      recordOutboundBytes: vi.fn(),
      recordRuntimeLoaded: vi.fn(),
      recordRuntimeEvicted: vi.fn(),
    };
  }

  // The registry is the only owner of live runtimes and of the subscriber set,
  // so it has to answer the resource sample and count its own transitions.
  it("answers the resource sample with live runtimes, their audience and their transitions", async () => {
    const recorded = resourceRecorder();
    const fixture = await coldFixture("resource-inventory", { resources: recorded });
    const slot = await fixture.registry.acquire(fixture.manager.getSessionId());
    expect(recorded.recordRuntimeLoaded).toHaveBeenCalledTimes(1);
    expect(recorded.recordRuntimeEvicted).not.toHaveBeenCalled();

    const snapshot = vi.spyOn(slot, "snapshot");
    fixture.registry.subscribe("phone", slot.id);
    const withSubscriber = fixture.events.length;
    slot.publishSnapshot();
    expect(snapshot).toHaveBeenCalledTimes(1);
    expect(fixture.events.slice(withSubscriber).some(({ topic }) => topic === "session.snapshot")).toBe(true);

    const inventory = await fixture.registry.resourceInventory();
    expect(inventory).toHaveLength(1);
    expect(inventory[0]).toMatchObject({ sessionId: slot.id, subscribers: 1 });
    expect((inventory[0] as { bytes: number }).bytes).toBeGreaterThan(0);

    // The subscriber set is the slot's only audience fact: with nobody left to
    // receive a snapshot a state change still reaches the dashboard as a summary
    // and projects no transcript at all.
    fixture.registry.unsubscribe("phone", slot.id);
    const published = fixture.events.length;
    const summaries = fixture.summaries.length;
    await slot.rename("SYNTHETIC_RENAME_WITHOUT_AN_AUDIENCE");
    expect(snapshot).toHaveBeenCalledTimes(1);
    expect(fixture.events.slice(published).some(({ topic }) => topic === "session.snapshot")).toBe(false);
    expect(fixture.summaries.length).toBeGreaterThan(summaries);
    expect(fixture.summaries.at(-1)).toMatchObject({ sessionId: slot.id, name: "SYNTHETIC_RENAME_WITHOUT_AN_AUDIENCE" });

    await slot.dispose();
    expect(recorded.recordRuntimeEvicted).toHaveBeenCalledTimes(1);
  });

  /** One collected `runtime.loaded`/`runtime.evicted` record, as the registry's
   * log seam receives it. */
  function runtimeLifecycleRecords() {
    const records: RuntimeLifecycleRecord[] = [];
    return { records, record: (record: RuntimeLifecycleRecord) => records.push(record) };
  }

  const mebibyte = 1_024 * 1_024;

  /** Grows a canonical transcript to a real `bytes` size with a sparse truncate
   * and leaves it on a complete line, as a written transcript is: the header
   * reader treats a file whose final byte is not a newline as an append still in
   * progress. */
  async function resizeSyntheticTranscript(path: string, bytes: number): Promise<void> {
    if (!syntheticTranscriptSizes.has(path)) {
      syntheticTranscriptSizes.set(path, (await fsPromises.stat(path)).size);
    }
    await truncate(path, bytes);
  }

  async function growTranscript(path: string, bytes: number): Promise<void> {
    await resizeSyntheticTranscript(path, bytes - 1);
    await appendFile(path, "\n");
  }

  // Failure mode: the smallest idle runtime is retired when the largest would
  // have been enough, so extra sessions lose their state. The small session is
  // acquired first, so it is also the least recently touched and first in
  // `slots` order: a smallest-first, iteration-order or least-recently-used pass
  // all retire it, and only largest-first retires the large one. The sizes are
  // real (a sparse `truncate` of the live transcript), so the pass reads what
  // production supplies.
  it("retires the largest idle runtime first when the byte budget cannot hold an opening session", async () => {
    const fixture = await coldFixture("byte-budget-largest-first");
    const small = SessionManager.create(fixture.cwd, dirname(fixture.sessionFile));
    small.appendMessage(fauxAssistantMessage("small idle transcript"));
    const large = SessionManager.create(fixture.cwd, dirname(fixture.sessionFile));
    large.appendMessage(fauxAssistantMessage("large idle transcript"));
    await settleCatalog(fixture.registry);
    await fixture.registry.catalog("all");
    const smallSlot = await fixture.registry.acquire(small.getSessionId());
    const largeSlot = await fixture.registry.acquire(large.getSessionId());
    // A live runtime grown to two budgets' worth of estimated heap, as a long run
    // does; the opening session starts near empty, so only retiring the large one
    // fits. A sparse truncate costs no disk.
    await growTranscript(largeSlot.sessionFile!, 800 * mebibyte);

    const opened = await fixture.registry.acquire(fixture.manager.getSessionId());
    expect(largeSlot.isDisposed).toBe(true);
    expect(smallSlot.isDisposed).toBe(false);
    // Exactly one runtime was retired: the largest one reclaims enough on its own.
    const live = await fixture.registry.resourceInventory();
    expect(live.map((entry) => entry.sessionId).sort()).toEqual([opened.id, smallSlot.id].sort());
  });

  // Failure mode: two opens of the same session at once charge that session
  // twice — once as the start already reserved for it and again as the opening
  // charge — so the pass retires idle runtimes for room the first open had
  // already taken, and the second open then only waits for it. The second pass is
  // held until the first open has reserved and resumed once it has read its
  // inventory, which is the window that double charge lived in.
  it("does not retire idle runtimes for a second open of the session the byte budget already charged", async () => {
    const fixture = await coldFixture("byte-budget-same-session");
    const idle = SessionManager.create(fixture.cwd, dirname(fixture.sessionFile));
    idle.appendMessage(fauxAssistantMessage("idle transcript"));
    const target = SessionManager.create(fixture.cwd, dirname(fixture.sessionFile));
    target.appendMessage(fauxAssistantMessage("target transcript"));
    await settleCatalog(fixture.registry);
    await fixture.registry.catalog("all");
    const idleSlot = await fixture.registry.acquire(idle.getSessionId());
    // 470 MiB is 1,410 MiB of estimated heap and the 30 MiB target is 90 MiB, so
    // the two fit together (1,500 MiB of the 1,536 MiB budget); charging the
    // target's reservation and its opening charge (1,590 MiB) is what would
    // retire the idle runtime.
    await growTranscript(idleSlot.sessionFile!, 470 * mebibyte);
    await growTranscript(target.getSessionFile()!, 30 * mebibyte);

    const inventory = fixture.registry.resourceInventory.bind(fixture.registry);
    let targetReserved = () => {};
    const reserved = new Promise<void>((resolve) => { targetReserved = resolve; });
    let resumeOpen = () => {};
    const openResumed = new Promise<void>((resolve) => { resumeOpen = resolve; });
    const realCreate = RuntimeSlot.create.bind(RuntimeSlot);
    vi.spyOn(RuntimeSlot, "create").mockImplementation(async (...args) => {
      // This is the first open, past its reservation and before its publication,
      // so the reservation stays held across the second open's byte pass.
      targetReserved();
      await openResumed;
      return await realCreate(...args);
    });
    let passes = 0;
    vi.spyOn(fixture.registry, "resourceInventory").mockImplementation(async () => {
      passes += 1;
      const waitsForTheFirstOpen = passes > 1;
      if (waitsForTheFirstOpen) await reserved;
      const snapshot = await inventory();
      if (waitsForTheFirstOpen) resumeOpen();
      return snapshot;
    });

    const first = fixture.registry.acquire(target.getSessionId());
    const second = fixture.registry.acquire(target.getSessionId());
    const [firstSlot, secondSlot] = await Promise.all([first, second]);
    expect(secondSlot).toBe(firstSlot);
    expect(idleSlot.isDisposed).toBe(false);
  });

  // Failure mode: an opening session whose bytes fit nowhere is refused on the
  // budget, so a loaded session it cannot reclaim makes every later open of a
  // non-empty transcript unopenable. The byte budget is eviction pressure, not a
  // gate: the admission is served, its load record names the over-budget state,
  // and the idle runtime that could not make it fit is not retired for nothing.
  it("admits an opening session the byte budget cannot fit and names the over-budget load", async () => {
    const lifecycle = runtimeLifecycleRecords();
    const fixture = await coldFixture("byte-budget-over-budget", { runtimeLifecycleRecord: lifecycle.record });
    const firstProtected = SessionManager.create(fixture.cwd, dirname(fixture.sessionFile));
    firstProtected.appendMessage(fauxAssistantMessage("first protected transcript"));
    const secondProtected = SessionManager.create(fixture.cwd, dirname(fixture.sessionFile));
    secondProtected.appendMessage(fauxAssistantMessage("second protected transcript"));
    const idle = SessionManager.create(fixture.cwd, dirname(fixture.sessionFile));
    idle.appendMessage(fauxAssistantMessage("idle transcript"));
    const waiting = SessionManager.create(fixture.cwd, dirname(fixture.sessionFile));
    waiting.appendMessage(fauxAssistantMessage("waiting transcript"));
    await settleCatalog(fixture.registry);
    await fixture.registry.catalog("all");
    const firstSlot = await fixture.registry.acquire(firstProtected.getSessionId());
    const secondSlot = await fixture.registry.acquire(secondProtected.getSessionId());
    fixture.registry.subscribe("phone", firstSlot.id);
    fixture.registry.subscribe("phone", secondSlot.id);
    const idleSlot = await fixture.registry.acquire(idle.getSessionId());
    // 300 + 250 MiB of protected transcript is 1,650 MiB of estimated heap: over
    // the 1,536 MiB budget with nothing else loaded, so no retirement can bring
    // this admission under it. The 15 MiB idle runtime is the only retireable
    // candidate and is smaller than that excess, so the pass retires nothing and
    // serves the (tiny) waiting session over budget.
    await growTranscript(firstSlot.sessionFile!, 300 * mebibyte);
    await growTranscript(secondSlot.sessionFile!, 250 * mebibyte);
    await growTranscript(idleSlot.sessionFile!, 5 * mebibyte);
    const loadedBefore = lifecycle.records.filter((record) => record.event === "runtime.loaded").length;

    const opened = await fixture.registry.acquire(waiting.getSessionId());
    expect(opened.id).toBe(waiting.getSessionId());
    expect(firstSlot.isDisposed).toBe(false);
    expect(secondSlot.isDisposed).toBe(false);
    expect(idleSlot.isDisposed).toBe(false);
    const loaded = lifecycle.records.filter((record) => record.event === "runtime.loaded");
    expect(loaded).toHaveLength(loadedBefore + 1);
    expect(loaded.at(-1)).toMatchObject({
      sessionId: waiting.getSessionId(),
      reason: "open",
      overBudget: true,
    });
    expect(loaded.at(-1)!.transcriptBytes).toBeGreaterThan(0);
  });

  // The byte budget charges a session that has not written a transcript yet
  // nothing, and creating one is not gated by it: the protected set here is over
  // the budget on its own, so this is the worst case for that decision.
  it("admits a session with no transcript yet beside a protected set already over the budget", async () => {
    const fixture = await coldFixture("byte-budget-zero-charge");
    const protectedSession = SessionManager.create(fixture.cwd, dirname(fixture.sessionFile));
    protectedSession.appendMessage(fauxAssistantMessage("protected transcript"));
    await settleCatalog(fixture.registry);
    await fixture.registry.catalog("all");
    const protectedSlot = await fixture.registry.acquire(protectedSession.getSessionId());
    fixture.registry.subscribe("phone", protectedSlot.id);
    // 800 MiB is 2,400 MiB of estimated heap: over the whole budget on its own.
    await growTranscript(protectedSlot.sessionFile!, 800 * mebibyte);

    const created = await fixture.registry.create(fixture.cwd);
    expect(protectedSlot.isDisposed).toBe(false);
    expect((await fixture.registry.resourceInventory()).map((entry) => entry.sessionId)).toContain(created.id);
  });

  // Failure mode: a session larger than the whole budget retires every idle
  // runtime and can then never open, pure collateral damage with no retry that
  // can succeed. 600 MiB is 1,800 MiB of estimated heap, over the 1,536 MiB
  // budget on its own, so the pass must retire nothing for it; the refusal below
  // is the append fence, not the budget.
  it("does not retire another session for a runtime larger than the whole byte budget", async () => {
    const fixture = await coldFixture("byte-budget-oversize");
    const idle = SessionManager.create(fixture.cwd, dirname(fixture.sessionFile));
    idle.appendMessage(fauxAssistantMessage("idle transcript"));
    const oversize = SessionManager.create(fixture.cwd, dirname(fixture.sessionFile));
    oversize.appendMessage(fauxAssistantMessage("oversize transcript"));
    await settleCatalog(fixture.registry);
    await fixture.registry.catalog("all");
    const idleSlot = await fixture.registry.acquire(idle.getSessionId());
    // Sparse, so the file is 600 MiB without writing it. The admission stops on
    // the append fence this tail trips, which is as far as a fixture can carry an
    // oversize session without a real 512 MiB+ parseable transcript.
    await resizeSyntheticTranscript(oversize.getSessionFile()!, 600 * mebibyte);

    await expect(fixture.registry.acquire(oversize.getSessionId())).rejects.toMatchObject({
      code: "busy",
      message: "Session append is still in progress",
    });
    expect(idleSlot.isDisposed).toBe(false);
  });

  // Failure mode: the transitions are counted but never named, so an incident
  // cannot tell which session's runtime was loaded or evicted, what the byte
  // budget charged it, or why it went away. The eviction names the bytes the pass
  // itself measured, not the charge the load published with.
  it("records runtime.loaded and runtime.evicted with the reason and the bytes the budget charged", async () => {
    const lifecycle = runtimeLifecycleRecords();
    const fixture = await coldFixture("runtime-lifecycle-records", { runtimeLifecycleRecord: lifecycle.record });
    const idle = SessionManager.create(fixture.cwd, dirname(fixture.sessionFile));
    idle.appendMessage(fauxAssistantMessage("idle transcript"));
    await settleCatalog(fixture.registry);
    await fixture.registry.catalog("all");
    const idleSlot = await fixture.registry.acquire(idle.getSessionId());
    // The runtime grows from a few KB to 800 MiB (2,400 MiB of estimated heap)
    // after it was published, so an eviction record that carried the load's charge
    // would name a few KB.
    await growTranscript(idleSlot.sessionFile!, 800 * mebibyte);

    const loaded = lifecycle.records.find((record) => record.event === "runtime.loaded");
    expect(loaded).toMatchObject({ sessionId: idleSlot.id, reason: "open" });
    expect(loaded!.transcriptBytes).toBeGreaterThan(0);
    expect(loaded!.estimatedHeapBytes).toBe(loaded!.transcriptBytes * LIVE_RUNTIME_HEAP_ESTIMATE_FACTOR);

    await fixture.registry.acquire(fixture.manager.getSessionId());
    const evicted = lifecycle.records.find((record) => record.event === "runtime.evicted");
    expect(evicted).toMatchObject({ sessionId: idleSlot.id, reason: "bytes" });
    expect(evicted!.transcriptBytes).toBe(800 * mebibyte);
    expect(evicted!.estimatedHeapBytes).toBe(800 * mebibyte * LIVE_RUNTIME_HEAP_ESTIMATE_FACTOR);
  });

  // Failure mode: a slot disposed outside the registry is recorded as the
  // extension-requested close this path never observed, so the reason points at
  // the wrong owner and hides that the disposal happened earlier.
  it("records a slot disposed outside the registry as disposed, not closed", async () => {
    const lifecycle = runtimeLifecycleRecords();
    const fixture = await coldFixture("runtime-eviction-disposed", { runtimeLifecycleRecord: lifecycle.record });
    const sessionId = fixture.manager.getSessionId();
    const disposed = await fixture.registry.acquire(sessionId);
    await disposed.dispose();

    const reacquired = await fixture.registry.acquire(sessionId);
    expect(reacquired.isDisposed).toBe(false);
    expect(lifecycle.records.find((record) => record.event === "runtime.evicted")).toMatchObject({
      sessionId,
      reason: "disposed",
    });
  });

  // The transport owns subscription lifetime: it subscribes a client before
  // installing that client's synchronization barrier and unsubscribes it on
  // close, revoke or session close. An extension-requested shutdown is not an
  // unsubscribe, so a client still watching the session keeps its audience and
  // the re-acquired slot publishes snapshots to it again.
  it("keeps a transported subscription across a closed slot and snapshots the re-acquired session", async () => {
    const fixture = await coldFixture("closed-slot-subscription");
    const sessionId = fixture.manager.getSessionId();
    const slot = await fixture.registry.acquire(sessionId);
    fixture.registry.subscribe("phone", sessionId);

    (slot as unknown as { requestExtensionShutdown: () => void }).requestExtensionShutdown();
    // `session.closed` is emitted in the same synchronous block as the slot's
    // close hook, so observing it means the registry's close handling has run.
    await waitFor(() => fixture.events.some(({ topic }) => topic === "session.closed"), "the session closed event");
    await waitFor(() => slot.isDisposed, "the slot disposal");
    expect(fixture.registry.isSubscribed("phone", sessionId)).toBe(true);

    const reacquired = await fixture.registry.acquire(sessionId);
    const published = fixture.events.length;
    reacquired.publishSnapshot();
    expect(fixture.events.slice(published).some(({ topic }) => topic === "session.snapshot")).toBe(true);
  });

  // A start that is retired before the registry publishes it was never a live
  // runtime: counting its disposal as an eviction would let `runtimesEvicted`
  // exceed loads and write an info record for a retried `catalog_changed` open.
  it("does not count an eviction for a start that was never published", async () => {
    const recorded = resourceRecorder();
    const fixture = await coldFixture("unpublished-start", { resources: recorded });
    const internals = fixture.registry as unknown as {
      dependencies: () => Parameters<typeof RuntimeSlot.create>[1];
      hooks: () => Parameters<typeof RuntimeSlot.create>[2];
    };
    const slot = await RuntimeSlot.create(fixture.manager, internals.dependencies(), internals.hooks(), false);
    expect(recorded.recordRuntimeLoaded).not.toHaveBeenCalled();

    await slot.dispose();
    expect(recorded.recordRuntimeEvicted).not.toHaveBeenCalled();
  });

  // G-1c: the request path joins the owner's cut, so the record shows no
  // request-path walk at all while the owner's own walks stay background work.
  it("counts no request-path walk while the reader joins the owner's cut", async () => {
    const recorded = resourceRecorder();
    const fixture = await coldFixture("request-path-walk", { resources: recorded });
    // Settle the catalog owner before the request: its own background reconcile
    // must not interleave and be misattributed as request-path work, so every
    // walk in the request's window is the request's own.
    await settleCatalog(fixture.registry);
    const backgroundWalks = recorded.recordCatalogWalk.mock.calls.length;

    await runInRequestSpan(new RequestSpan(), () => fixture.registry.delete(fixture.manager.getSessionId()));

    const requestWalks = recorded.recordCatalogWalk.mock.calls.slice(backgroundWalks);
    expect(requestWalks).toEqual([]);
    expect(recorded.recordCatalogWalk.mock.calls.every((call) => call[2] === false)).toBe(true);

    // The same walk with no request waiting on it is background work.
    const evidenceSeam = fixture.registry as unknown as { catalogStructureEvidence: () => Promise<unknown> };
    await evidenceSeam.catalogStructureEvidence();
    expect(recorded.recordCatalogWalk).toHaveBeenLastCalledWith(expect.any(Number), expect.any(Number), false);
  });

  // G-1b: a writer the Gateway does not own (a subagent child, a copied file)
  // reaches its catalog row through the folder watcher, so external writers add
  // no request-path walks to the criterion this file measures above.
  it("publishes an external append to a catalog row without a walk", async () => {
    const recorded = resourceRecorder();
    let watchRequest: SessionCatalogWatchRequest | undefined;
    const fixture = await coldFixture("external-append", {
      resources: recorded,
      beforeInitialize: async (_sessionFile, registry) => {
        // Inject at the catalog's existing backend seam before it starts; the
        // registry keeps its production discovery/index/row publication owners.
        (catalogOwner(registry) as unknown as { watchCatalog: SessionCatalogOptions["watchCatalog"] }).watchCatalog = (request) => {
          watchRequest = request;
          return { close: () => {} };
        };
      },
    });
    onTestFinished(() => rm(fixture.root, { recursive: true, force: true }));
    const catalog = catalogOwner(fixture.registry);
    await catalog.settled();

    const child = join(await realpath(join(fixture.agentDir, "sessions")),
      "workspace", "parent", "producer", "run-1", "session.jsonl");
    await mkdir(dirname(child), { recursive: true });
    await writeFile(child, `${JSON.stringify({
      type: "session", version: 3, id: "id-child", timestamp: "2026-09-27T00:00:00.000Z", cwd: fixture.cwd,
    })}\n`);
    expect(watchRequest?.root).toBe(await realpath(join(fixture.agentDir, "sessions")));
    const deliverHint = async (): Promise<void> => {
      // Advance only the owner's debounce. No FSEvents delivery or latency is
      // part of the oracle; the serial lane is the row-publication barrier.
      vi.useFakeTimers({ toFake: ["setTimeout", "clearTimeout"] });
      try {
        watchRequest!.onEvent(relative(watchRequest!.root, child));
        await vi.advanceTimersByTimeAsync(CATALOG_EVENT_DEBOUNCE_MS);
        await catalog.awaitQueuedChanges();
      } finally {
        vi.useRealTimers();
      }
    };
    await deliverHint();
    expect(catalog.row(child)?.id).toBe("id-child");
    expect(catalog.row(child)?.delegated).toBe(true);

    const walksBeforeAppend = recorded.recordCatalogWalk.mock.calls.length;
    await appendFile(child, `${JSON.stringify({
      type: "message", id: "m1", timestamp: Date.parse("2026-09-27T00:00:01.000Z"), message: { role: "user", content: "external" },
    })}\n`);
    await deliverHint();

    // The watcher's hint, not a walk, publishes the canonical append facts.
    expect(catalog.row(child)?.messageCount).toBe(1);
    expect(catalog.row(child)?.size).toBe((await fsPromises.stat(child)).size);
    expect(recorded.recordCatalogWalk.mock.calls.length).toBe(walksBeforeAppend);
  });

  // Failure mode (G-12): a cold runtime load that queues behind the concurrency
  // cap keeps loading for a client that already left, so a transcript nobody
  // waits for is parsed into the live set.
  it("queues cold runtime loads and drops a queued one whose client disconnects", async () => {
    const fixture = await coldFixture("cold-load-queue");
    const directory = dirname(fixture.sessionFile);
    const queued = SessionManager.create(fixture.cwd, directory, { id: "40000000-0000-4000-8000-000000000002" });
    queued.appendMessage(fauxAssistantMessage("queued cold load"));
    const abandonedSession = SessionManager.create(fixture.cwd, directory, { id: "40000000-0000-4000-8000-000000000003" });
    abandonedSession.appendMessage(fauxAssistantMessage("abandoned cold load"));
    await settleCatalog(fixture.registry);
    const loads: string[] = [];
    // The loader is held to queue real cold loads, so no earlier case's spy on
    // `RuntimeSlot.create` may still be installed.
    vi.restoreAllMocks();
    const releaseLoads: Array<() => void> = [];
    const realCreate = RuntimeSlot.create.bind(RuntimeSlot);
    vi.spyOn(RuntimeSlot, "create").mockImplementation(async (...args) => {
      loads.push(args[0].getSessionId());
      await new Promise<void>((resolve) => { releaseLoads.push(resolve); });
      return await realCreate(...args);
    });

    const first = fixture.registry.acquire(fixture.manager.getSessionId());
    const second = fixture.registry.acquire(queued.getSessionId());
    await waitFor(() => loads.length === 2, "the second catalog load");
    const controller = new AbortController();
    const abandoned = fixture.registry.acquire(abandonedSession.getSessionId(), controller.signal);
    // The third waits for one of the two places instead of loading beside them.
    await new Promise((resolve) => setTimeout(resolve, 50));
    expect(loads).toHaveLength(2);
    controller.abort(new Error("the client left"));
    await expect(abandoned).rejects.toThrow("the client left");
    for (const release of releaseLoads.splice(0)) release();
    await Promise.all([first, second]);
    // Which of two concurrently admitted loads reaches the loader first is I/O
    // order, not a contract; what this case owns is that only those two started.
    expect([...loads].sort()).toEqual([fixture.manager.getSessionId(), queued.getSessionId()].sort());
  });

  // Failure mode (G-12): one requester leaving ends the shared cold load for
  // everyone waiting on it, so a phone that reconnected on a new socket while the
  // retired connection's open was still queued gets a non-busy `cancelled` and
  // does not retry (`C-6`).
  it("keeps a queued cold load for the waiters that are still there when one leaves", async () => {
    const fixture = await coldFixture("cold-load-shared");
    const directory = dirname(fixture.sessionFile);
    const shared = SessionManager.create(fixture.cwd, directory, { id: "40000000-0000-4000-8000-000000000004" });
    shared.appendMessage(fauxAssistantMessage("shared cold load"));
    const filler = SessionManager.create(fixture.cwd, directory, { id: "40000000-0000-4000-8000-000000000005" });
    filler.appendMessage(fauxAssistantMessage("filler cold load"));
    const other = SessionManager.create(fixture.cwd, directory, { id: "40000000-0000-4000-8000-000000000006" });
    other.appendMessage(fauxAssistantMessage("other cold load"));
    await settleCatalog(fixture.registry);
    const loads: string[] = [];
    vi.restoreAllMocks();
    const releaseLoads: Array<() => void> = [];
    const realCreate = RuntimeSlot.create.bind(RuntimeSlot);
    vi.spyOn(RuntimeSlot, "create").mockImplementation(async (...args) => {
      loads.push(args[0].getSessionId());
      await new Promise<void>((resolve) => { releaseLoads.push(resolve); });
      return await realCreate(...args);
    });
    const tick = (): Promise<void> => new Promise((resolve) => setTimeout(resolve, 50));

    // Two loads hold both places, so the shared session's start queues behind
    // them and the waiters of that one start are what this case counts.
    const held = [fixture.registry.acquire(fixture.manager.getSessionId()), fixture.registry.acquire(filler.getSessionId())];
    await waitFor(() => loads.length === 2, "the second catalog load");
    const firstLeaving = new AbortController();
    const secondLeaving = new AbortController();
    const firstWaiter = fixture.registry.acquire(shared.getSessionId(), firstLeaving.signal);
    const secondWaiter = fixture.registry.acquire(shared.getSessionId(), secondLeaving.signal);
    await tick();
    expect(loads).toHaveLength(2);

    // The first requester's connection retires while the second still waits: the
    // queued load is still the second requester's answer, so it stays queued.
    firstLeaving.abort(new Error("the first connection left"));
    await tick();
    expect(loads).toHaveLength(2);

    // The last waiter leaves: now the queued load has no audience and is dropped
    // before it parses anything.
    secondLeaving.abort(new Error("the second connection left"));
    await expect(secondWaiter).rejects.toThrow("the second connection left");
    await expect(firstWaiter).rejects.toThrow("the second connection left");

    // The place a held load releases is handed to the waiter queued for it, and
    // the gate still counts the place the other held load occupies: a later
    // arrival queues rather than loading beside it.
    const thirdLeaving = new AbortController();
    const thirdWaiter = fixture.registry.acquire(shared.getSessionId(), thirdLeaving.signal);
    await tick();
    expect(loads).toHaveLength(2);
    releaseLoads.shift()!();
    await waitFor(() => loads.length === 3, "the third catalog load");
    expect(loads[2]).toBe(shared.getSessionId());
    const otherWaiter = fixture.registry.acquire(other.getSessionId());
    await tick();
    expect(loads).toHaveLength(3);

    for (let pass = 0; pass < 8 && loads.length < 4; pass += 1) {
      for (const release of releaseLoads.splice(0)) release();
      await tick();
    }
    for (const release of releaseLoads.splice(0)) release();
    await Promise.all([...held, thirdWaiter, otherWaiter]);
    // The two held loads started first in whatever order the loader reached
    // them; the queued one is third because the place it waited for was handed
    // to it, and the fourth followed it.
    expect([...loads].sort()).toEqual([
      fixture.manager.getSessionId(),
      filler.getSessionId(),
      shared.getSessionId(),
      other.getSessionId(),
    ].sort());
  });

  // Failure mode (G-12): heap pressure retires a runtime that has an audience, or
  // the refusal it should make instead never happens and the load takes the
  // process to the limit.
  it("reclaims the largest idle runtime under heap pressure and refuses a cold load when only a protected one is left", async () => {
    // The fixture loads real runtimes; an earlier case's spy on the loader would
    // never settle for this one.
    vi.restoreAllMocks();
    const mebibyte = 1_024 * 1_024;
    const records: RuntimeLifecycleRecord[] = [];
    const sheds: CapacityShedRecord[] = [];
    // A sample that never changes on eviction, like the process's own:
    // `heapUsed` does not fall until V8 collects, so only the registry's
    // accounting of what it retired can end the pass. A sample that dropped on
    // eviction hid the pass retiring every idle runtime for one load.
    let heapUsedBytes = 100 * mebibyte;
    const fixture = await coldFixture("heap-pressure", {
      heapSample: () => ({ usedBytes: heapUsedBytes, limitBytes: 1_000 * mebibyte }),
      runtimeLifecycleRecord: (record) => records.push(record),
      capacityShedRecord: (record) => sheds.push(record),
    });
    const directory = dirname(fixture.sessionFile);
    const large = SessionManager.create(fixture.cwd, directory, { id: "40000000-0000-4000-8000-000000000010" });
    large.appendMessage(fauxAssistantMessage("large idle runtime"));
    const survivor = SessionManager.create(fixture.cwd, directory, { id: "40000000-0000-4000-8000-000000000013" });
    survivor.appendMessage(fauxAssistantMessage("idle runtime the pass must leave alone"));
    const target = SessionManager.create(fixture.cwd, directory, { id: "40000000-0000-4000-8000-000000000011" });
    target.appendMessage(fauxAssistantMessage("refused cold load"));
    await settleCatalog(fixture.registry);
    const protectedSlot = await fixture.registry.acquire(fixture.manager.getSessionId());
    const largeSlot = await fixture.registry.acquire(large.getSessionId());
    const survivorSlot = await fixture.registry.acquire(survivor.getSessionId());
    // The protected runtime is the one that must survive every pass.
    subscribeAudience(fixture.registry, fixture.manager.getSessionId());
    await growTranscript(protectedSlot.sessionFile!, 4 * mebibyte);
    await growTranscript(largeSlot.sessionFile!, 100 * mebibyte);
    await growTranscript(survivorSlot.sessionFile!, 10 * mebibyte);

    // 900 MiB of 1,000, held there: the largest idle runtime's own 300 MiB
    // estimate (`LIVE_RUNTIME_HEAP_ESTIMATE_FACTOR` x 100 MiB) takes the
    // projection under `HEAP_EVICTION_SHARE`, so the pass stops after one
    // retirement — the second idle runtime keeps its state — and admits.
    heapUsedBytes = 900 * mebibyte;
    const admitted = await fixture.registry.acquire(target.getSessionId());
    expect(admitted.id).toBe(target.getSessionId());
    // The largest idle runtime gave the memory back; the protected one and the
    // runtime the pass no longer needed did not.
    expect(records.filter((record) => record.event === "runtime.evicted").map((record) => [record.sessionId, record.reason])).toEqual([
      [large.getSessionId(), "heap"],
    ]);
    expect(largeSlot.isDisposed).toBe(true);
    expect(survivorSlot.isDisposed).toBe(false);
    expect(protectedSlot.isDisposed).toBe(false);

    // The one idle runtime left cannot take the projection under
    // `HEAP_REFUSAL_SHARE` and the protected runtime is never retired, so the
    // load is refused instead of pushing the process to its limit.
    const another = SessionManager.create(fixture.cwd, directory, { id: "40000000-0000-4000-8000-000000000012" });
    another.appendMessage(fauxAssistantMessage("second refused cold load"));
    await settleCatalog(fixture.registry);
    await expect(fixture.registry.acquire(another.getSessionId())).rejects.toMatchObject({
      code: "busy",
      details: { retryAfterMs: HEAP_REFUSAL_RETRY_AFTER_MS },
    });
    expect(records.filter((record) => record.event === "runtime.evicted").map((record) => [record.sessionId, record.reason])).toEqual([
      [large.getSessionId(), "heap"],
      [survivor.getSessionId(), "heap"],
      // The runtime the first load published is idle now too, and reclaiming it
      // still leaves the projection above the refusal share.
      [target.getSessionId(), "heap"],
    ]);
    expect(sheds).toEqual([{
      reason: "heap",
      admission: "open",
      heapUsedBytes: 900 * mebibyte,
      heapLimitBytes: 1_000 * mebibyte,
      retryAfterMs: HEAP_REFUSAL_RETRY_AFTER_MS,
    }]);
    expect(protectedSlot.isDisposed).toBe(false);
  });
});
