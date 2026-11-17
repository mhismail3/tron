import type { RunPersistence } from "../../kernel/run/run-persistence.js";
import * as fsPromises from "node:fs/promises";
import { appendFile, mkdir, readFile, realpath, rename, rm, truncate, writeFile } from "node:fs/promises";
import { homedir } from "node:os";
import { dirname, join, relative, resolve } from "node:path";
import { SessionManager } from "@earendil-works/pi-coding-agent";
import { fauxAssistantMessage } from "@earendil-works/pi-ai";
import { afterEach, describe, expect, it, onTestFinished, vi } from "vitest";
import { RequestSpan, runInRequestSpan } from "../../util/request-span.js";
import { CATALOG_EVENT_DEBOUNCE_MS, type SessionCatalogOptions, type SessionCatalogWatchRequest } from "../../sessions/session-catalog.js";
import {
  HEAP_REFUSAL_RETRY_AFTER_MS,
  LIVE_RUNTIME_HEAP_ESTIMATE_FACTOR,
  RuntimeRegistry,
  type CapacityShedRecord,
  type RuntimeLifecycleRecord,
} from "../../kernel/session/runtime-registry.js";
import { RuntimeSlot } from "../../kernel/run/runtime-slot.js";
import { waitFor } from "../../../test-support/wait-for.js";
import { catalogOwner, createColdRegistryFixture, settleCatalog } from "../../../test-support/runtime-registry-fixture.js";
function subscribeAudience(registry: RuntimeRegistry, sessionId: string): void {
  registry.subscribe("test-audience", sessionId);
}

describe("RuntimeRegistry with the pinned agent runtime", { concurrent: false }, () => {
  const previousAgentDir = process.env.PI_CODING_AGENT_DIR;
  const registries: RuntimeRegistry[] = [];
  const syntheticTranscriptSizes = new Map<string, number>();

  const coldFixture = createColdRegistryFixture.bind(undefined, registries);

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
      vi.restoreAllMocks();
      if (previousAgentDir === undefined) delete process.env.PI_CODING_AGENT_DIR;
      else process.env.PI_CODING_AGENT_DIR = previousAgentDir;
    }
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
      "state", "runtime-markers", `${slot.id}.json`);
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
    process.env.PI_SUBAGENTS_TEMP_ROOT = join(homedir(), ".tron", "state", "subagents");
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
    const internals = slot as unknown as { runPersistence: RunPersistence };
    internals.runPersistence.pendingReceiptWrites.add(receipt);

    const eviction = (registry as unknown as { evictIdle: () => Promise<void> }).evictIdle();
    const outcome = await Promise.race([
      eviction.then(() => "settled" as const),
      new Promise<"blocked">((resolve) => setTimeout(() => resolve("blocked"), 100)),
    ]);
    settleReceipt();
    internals.runPersistence.pendingReceiptWrites.delete(receipt);
    await eviction;

    expect(outcome).toBe("settled");
    expect(await registry.acquire(sessionId)).toBe(slot);
    expect(slot.isDisposed).toBe(false);
  });

  it("force-invalidates an extension runtime whose idle-eviction shutdown never settles", async () => {
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

  function resourceRecorder() {
    return {
      recordTopicFrame: vi.fn(),
      recordCatalogWalk: vi.fn(),
      recordOutboundBytes: vi.fn(),
      recordRuntimeLoaded: vi.fn(),
      recordRuntimeEvicted: vi.fn(),
    };
  }

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

  function runtimeLifecycleRecords() {
    const records: RuntimeLifecycleRecord[] = [];
    return { records, record: (record: RuntimeLifecycleRecord) => records.push(record) };
  }

  const mebibyte = 1_024 * 1_024;

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
    await growTranscript(largeSlot.sessionFile!, 800 * mebibyte);

    const opened = await fixture.registry.acquire(fixture.manager.getSessionId());
    expect(largeSlot.isDisposed).toBe(true);
    expect(smallSlot.isDisposed).toBe(false);
    const live = await fixture.registry.resourceInventory();
    expect(live.map((entry) => entry.sessionId).sort()).toEqual([opened.id, smallSlot.id].sort());
  });

  it("does not retire idle runtimes for a second open of the session the byte budget already charged", async () => {
    const fixture = await coldFixture("byte-budget-same-session");
    const idle = SessionManager.create(fixture.cwd, dirname(fixture.sessionFile));
    idle.appendMessage(fauxAssistantMessage("idle transcript"));
    const target = SessionManager.create(fixture.cwd, dirname(fixture.sessionFile));
    target.appendMessage(fauxAssistantMessage("target transcript"));
    await settleCatalog(fixture.registry);
    await fixture.registry.catalog("all");
    const idleSlot = await fixture.registry.acquire(idle.getSessionId());
    await growTranscript(idleSlot.sessionFile!, 470 * mebibyte);
    await growTranscript(target.getSessionFile()!, 30 * mebibyte);

    const inventory = fixture.registry.resourceInventory.bind(fixture.registry);
    let targetReserved = () => {};
    const reserved = new Promise<void>((resolve) => { targetReserved = resolve; });
    let resumeOpen = () => {};
    const openResumed = new Promise<void>((resolve) => { resumeOpen = resolve; });
    const realCreate = RuntimeSlot.create.bind(RuntimeSlot);
    vi.spyOn(RuntimeSlot, "create").mockImplementation(async (...args) => {
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

  it("admits a session with no transcript yet beside a protected set already over the budget", async () => {
    const fixture = await coldFixture("byte-budget-zero-charge");
    const protectedSession = SessionManager.create(fixture.cwd, dirname(fixture.sessionFile));
    protectedSession.appendMessage(fauxAssistantMessage("protected transcript"));
    await settleCatalog(fixture.registry);
    await fixture.registry.catalog("all");
    const protectedSlot = await fixture.registry.acquire(protectedSession.getSessionId());
    fixture.registry.subscribe("phone", protectedSlot.id);
    await growTranscript(protectedSlot.sessionFile!, 800 * mebibyte);

    const created = await fixture.registry.create(fixture.cwd);
    expect(protectedSlot.isDisposed).toBe(false);
    expect((await fixture.registry.resourceInventory()).map((entry) => entry.sessionId)).toContain(created.id);
  });

  it("does not retire another session for a runtime larger than the whole byte budget", async () => {
    const fixture = await coldFixture("byte-budget-oversize");
    const idle = SessionManager.create(fixture.cwd, dirname(fixture.sessionFile));
    idle.appendMessage(fauxAssistantMessage("idle transcript"));
    const oversize = SessionManager.create(fixture.cwd, dirname(fixture.sessionFile));
    oversize.appendMessage(fauxAssistantMessage("oversize transcript"));
    await settleCatalog(fixture.registry);
    await fixture.registry.catalog("all");
    const idleSlot = await fixture.registry.acquire(idle.getSessionId());
    await resizeSyntheticTranscript(oversize.getSessionFile()!, 600 * mebibyte);

    await expect(fixture.registry.acquire(oversize.getSessionId())).rejects.toMatchObject({
      code: "busy",
      message: "Session append is still in progress",
    });
    expect(idleSlot.isDisposed).toBe(false);
  });

  it("records runtime.loaded and runtime.evicted with the reason and the bytes the budget charged", async () => {
    const lifecycle = runtimeLifecycleRecords();
    const fixture = await coldFixture("runtime-lifecycle-records", { runtimeLifecycleRecord: lifecycle.record });
    const idle = SessionManager.create(fixture.cwd, dirname(fixture.sessionFile));
    idle.appendMessage(fauxAssistantMessage("idle transcript"));
    await settleCatalog(fixture.registry);
    await fixture.registry.catalog("all");
    const idleSlot = await fixture.registry.acquire(idle.getSessionId());
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

  it("keeps a transported subscription across a closed slot and snapshots the re-acquired session", async () => {
    const fixture = await coldFixture("closed-slot-subscription");
    const sessionId = fixture.manager.getSessionId();
    const slot = await fixture.registry.acquire(sessionId);
    fixture.registry.subscribe("phone", sessionId);

    (slot as unknown as { requestExtensionShutdown: () => void }).requestExtensionShutdown();
    await waitFor(() => fixture.events.some(({ topic }) => topic === "session.closed"), "the session closed event");
    await waitFor(() => slot.isDisposed, "the slot disposal");
    expect(fixture.registry.isSubscribed("phone", sessionId)).toBe(true);

    const reacquired = await fixture.registry.acquire(sessionId);
    const published = fixture.events.length;
    reacquired.publishSnapshot();
    expect(fixture.events.slice(published).some(({ topic }) => topic === "session.snapshot")).toBe(true);
  });

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

  it("counts no request-path walk while the reader joins the owner's cut", async () => {
    const recorded = resourceRecorder();
    const fixture = await coldFixture("request-path-walk", { resources: recorded });
    await settleCatalog(fixture.registry);
    const backgroundWalks = recorded.recordCatalogWalk.mock.calls.length;

    await runInRequestSpan(new RequestSpan(), () => fixture.registry.delete(fixture.manager.getSessionId()));

    const requestWalks = recorded.recordCatalogWalk.mock.calls.slice(backgroundWalks);
    expect(requestWalks).toEqual([]);
    expect(recorded.recordCatalogWalk.mock.calls.every((call) => call[2] === false)).toBe(true);

    const evidenceSeam = fixture.registry as unknown as { catalogStructureEvidence: () => Promise<unknown> };
    await evidenceSeam.catalogStructureEvidence();
    expect(recorded.recordCatalogWalk).toHaveBeenLastCalledWith(expect.any(Number), expect.any(Number), false);
  });

  it("publishes an external append to a catalog row without a walk", async () => {
    const recorded = resourceRecorder();
    let watchRequest: SessionCatalogWatchRequest | undefined;
    const fixture = await coldFixture("external-append", {
      resources: recorded,
      beforeInitialize: async (_sessionFile, registry) => {
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

    expect(catalog.row(child)?.messageCount).toBe(1);
    expect(catalog.row(child)?.size).toBe((await fsPromises.stat(child)).size);
    expect(recorded.recordCatalogWalk.mock.calls.length).toBe(walksBeforeAppend);
  });

  it("queues cold runtime loads and drops a queued one whose client disconnects", async () => {
    const fixture = await coldFixture("cold-load-queue");
    const directory = dirname(fixture.sessionFile);
    const queued = SessionManager.create(fixture.cwd, directory, { id: "40000000-0000-4000-8000-000000000002" });
    queued.appendMessage(fauxAssistantMessage("queued cold load"));
    const abandonedSession = SessionManager.create(fixture.cwd, directory, { id: "40000000-0000-4000-8000-000000000003" });
    abandonedSession.appendMessage(fauxAssistantMessage("abandoned cold load"));
    await settleCatalog(fixture.registry);
    const loads: string[] = [];
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
    await new Promise((resolve) => setTimeout(resolve, 50));
    expect(loads).toHaveLength(2);
    controller.abort(new Error("the client left"));
    await expect(abandoned).rejects.toThrow("the client left");
    for (const release of releaseLoads.splice(0)) release();
    await Promise.all([first, second]);
    expect([...loads].sort()).toEqual([fixture.manager.getSessionId(), queued.getSessionId()].sort());
  });

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
    const releaseLoads: Array<() => void> = [];
    const realCreate = RuntimeSlot.create.bind(RuntimeSlot);
    vi.spyOn(RuntimeSlot, "create").mockImplementation(async (...args) => {
      loads.push(args[0].getSessionId());
      await new Promise<void>((resolve) => { releaseLoads.push(resolve); });
      return await realCreate(...args);
    });
    const tick = (): Promise<void> => new Promise((resolve) => setTimeout(resolve, 50));

    const held = [fixture.registry.acquire(fixture.manager.getSessionId()), fixture.registry.acquire(filler.getSessionId())];
    await waitFor(() => loads.length === 2, "the second catalog load");
    const firstLeaving = new AbortController();
    const secondLeaving = new AbortController();
    const firstWaiter = fixture.registry.acquire(shared.getSessionId(), firstLeaving.signal);
    const secondWaiter = fixture.registry.acquire(shared.getSessionId(), secondLeaving.signal);
    await tick();
    expect(loads).toHaveLength(2);

    firstLeaving.abort(new Error("the first connection left"));
    await tick();
    expect(loads).toHaveLength(2);

    secondLeaving.abort(new Error("the second connection left"));
    await expect(secondWaiter).rejects.toThrow("the second connection left");
    await expect(firstWaiter).rejects.toThrow("the second connection left");

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
    expect([...loads].sort()).toEqual([
      fixture.manager.getSessionId(),
      filler.getSessionId(),
      shared.getSessionId(),
      other.getSessionId(),
    ].sort());
  });

  it("reclaims the largest idle runtime under heap pressure and refuses a cold load when only a protected one is left", async () => {
    const mebibyte = 1_024 * 1_024;
    const records: RuntimeLifecycleRecord[] = [];
    const sheds: CapacityShedRecord[] = [];
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
    subscribeAudience(fixture.registry, fixture.manager.getSessionId());
    await growTranscript(protectedSlot.sessionFile!, 4 * mebibyte);
    await growTranscript(largeSlot.sessionFile!, 100 * mebibyte);
    await growTranscript(survivorSlot.sessionFile!, 10 * mebibyte);

    heapUsedBytes = 900 * mebibyte;
    const admitted = await fixture.registry.acquire(target.getSessionId());
    expect(admitted.id).toBe(target.getSessionId());
    expect(records.filter((record) => record.event === "runtime.evicted").map((record) => [record.sessionId, record.reason])).toEqual([
      [large.getSessionId(), "heap"],
    ]);
    expect(largeSlot.isDisposed).toBe(true);
    expect(survivorSlot.isDisposed).toBe(false);
    expect(protectedSlot.isDisposed).toBe(false);

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
