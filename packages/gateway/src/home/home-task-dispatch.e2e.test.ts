import { existsSync } from "node:fs";
import { cp, mkdir, mkdtemp, readFile, rename, rm, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { ModelRuntime } from "@earendil-works/pi-coding-agent";
import { fauxAssistantMessage, fauxProvider, fauxToolCall } from "@earendil-works/pi-ai";
import { afterAll, afterEach, describe, expect, it, vi } from "vitest";
import { TrustService } from "../admin/trust-service.js";
import type { NotificationService } from "../notifications/notification-service.js";
import { HomeTaskStore } from "./home-task-store.js";
import { RuntimeRegistry } from "../sessions/runtime-registry.js";
import { OWNED_OPERATION_DEADLINE_MS } from "../sessions/owned-session-dispatch.js";
import { waitFor } from "../../test-support/wait-for.js";

const evidence: Array<Record<string, unknown>> = [];
const fixtures: Array<{ registry: RuntimeRegistry; root: string }> = [];
afterEach(async () => {
  vi.restoreAllMocks();
  for (const fixture of fixtures.splice(0)) {
    await fixture.registry.dispose();
    await fixture.registry.administrativeWorkRegistry.waitUntilSettled();
    await rm(fixture.root, { recursive: true, force: true });
  }
});
afterAll(async () => {
  if (process.env.HOME_TASK_REPORT) await writeFile(process.env.HOME_TASK_REPORT, JSON.stringify({ suite: "home-task-dispatch", evidence }, null, 2));
});

async function fixture(providerVersion?: string, codemode = false) {
  const root = await mkdtemp(join(tmpdir(), "tron-task-dispatch-"));
  const agentDir = join(root, "agent");
  const cwd = join(root, "project");
  const tronHome = join(root, "tron");
  await mkdir(agentDir); await mkdir(cwd);
  const faux = fauxProvider({ provider: "tron-task-faux", tokensPerSecond: 100_000 });
  const model = faux.getModel();
  const settings: Record<string, unknown> = { sessionDir: join(root, "sessions"), defaultProvider: model.provider, defaultModel: model.id };
  if (codemode) {
    settings.defaultTools = ["+codemode"];
    const extensionDir = join(cwd, ".pi", "extensions");
    await mkdir(extensionDir, { recursive: true });
    await writeFile(join(extensionDir, "codemode.ts"), `import { createCodemodeExtension } from ${JSON.stringify(import.meta.resolve("@earendil-works/pi-coding-agent"))}; export default createCodemodeExtension({ mode: "on" });`);
  }
  if (providerVersion) {
    const packageRoot = join(agentDir, "npm/node_modules/pi-subagents");
    await mkdir(packageRoot, { recursive: true });
    await writeFile(join(packageRoot, "package.json"), JSON.stringify({ name: "pi-subagents", version: providerVersion, pi: { extensions: ["index.ts"] } }));
    await writeFile(join(packageRoot, "index.ts"), `import { writeFileSync } from 'node:fs'; export default function(pi) {
      pi.registerTool({name:'subagent',label:'Subagent',description:'Test producer boundary',parameters:{type:'object',properties:{}},
        execute:async (_id,input) => { writeFileSync(${JSON.stringify(join(cwd, "subagent-effect.json"))}, JSON.stringify(input)); return {content:[{type:'text',text:'producer admitted'}]}; }});
      pi.registerTool({name:'bg_wait',label:'Background Wait',description:'Test versioned wait boundary',parameters:{type:'object',properties:{}},
        execute:async (_id,input,signal) => {
          writeFileSync(${JSON.stringify(join(cwd, "wait-effect.json"))}, JSON.stringify(input));
          if (!input.nonBlocking && ${JSON.stringify(providerVersion)} === '0.76.1-tron.4') await new Promise(resolve => { const stop = () => { writeFileSync(${JSON.stringify(join(cwd, "wait-aborted"))}, 'aborted'); resolve(); }; if (signal?.aborted) stop(); else signal?.addEventListener('abort', stop, {once:true}); });
          return {content:[{type:'text',text:'wait finished'}]}; }});
    }`);
    settings.packages = [`npm:pi-subagents@${providerVersion}`];
  }
  await writeFile(join(agentDir, "settings.json"), JSON.stringify(settings));
  const trust = new TrustService(agentDir);
  await trust.set(cwd, true);
  const signals: Array<Record<string, unknown>> = [];
  const notifications: Array<Record<string, unknown>> = [];
  const registry = new RuntimeRegistry({ agentDir, tronHome, trust, machineId: "machine-task-test",
    modelRuntimeFactory: async () => {
      const runtime = await ModelRuntime.create({ modelsPath: null, refreshOnCreate: false });
      runtime.registerNativeProvider(faux.provider); return runtime;
    },
    broadcast: () => {}, sessionSummaryChanged: () => {}, sessionListChanged: () => {},
    notifications: { enqueue: async (input: Record<string, unknown>) => { notifications.push(input); return "queued"; },
      suppressAutomatic: async () => "suppressed", markSessionInboxRead: async () => {} } as unknown as NotificationService,
    homeTaskDiagnostic: (record) => signals.push(record),
    scheduleToolOperations: { execute: async () => {
      await writeFile(join(cwd, "schedule-effect"), "producer called");
      return { message: "schedule read", details: { status: "ok" } };
    } },
    homeMemorySummarizer: () => ({ summarizer: async () => fauxAssistantMessage("bounded summary") }),
  });
  fixtures.push({ registry, root });
  await registry.initialize();
  await (registry as any).sessionCatalog.whenPublished();
  const home = await registry.homeOwner().designate({ model: { provider: model.provider, id: model.id } });
  return { root, registry, faux, cwd, tronHome, home, signals, notifications, agentDir, trust };
}
const reportCall = (id = "report-one", text = "Verified result") => fauxToolCall("report", { resultId: id, outcome: "final", text, evidence: ["focused check passed"] }, { id: `call-${id}` });
async function dispatch(f: Awaited<ReturnType<typeof fixture>>, taskId = "task-one") {
  return f.registry.homeOwner().dispatchTask(f.home.sessionId, { taskId, intent: "Finite work", target: f.cwd });
}

describe("Home task production dispatch", () => {
  it.each([
    { label: "async", version: "0.76.1-tron.4", input: { agent: "worker", task: "work", async: true }, allowed: false },
    { label: "foreground", version: "0.76.1-tron.4", input: { agent: "worker", task: "work", async: false }, allowed: false },
    { label: "implicit-async", version: "0.76.1-tron.4", input: { agent: "worker", task: "work" }, allowed: false },
    { label: "workflow", version: "0.76.1-tron.4", input: { workflow: true, async: false }, allowed: false },
    { label: "resume", version: "0.76.1-tron.4", input: { action: "resume", id: "run" }, allowed: false },
    { label: "scheduled", version: "0.76.1-tron.4", input: { action: "schedule.create", at: "later" }, allowed: false },
    { label: "read-only", version: "0.76.1-tron.4", input: { action: "guide" }, allowed: true },
    { label: "unknown-version", version: "0.76.1-tron.5", input: { action: "guide" }, allowed: false },
  ])("gates task producer $label at the actual tool-call boundary", async ({ version, input, allowed, label }) => {
    const f = await fixture(version);
    f.faux.setResponses([fauxAssistantMessage([fauxToolCall("subagent", input)], { stopReason: "toolUse" }), fauxAssistantMessage([reportCall()], { stopReason: "toolUse" })]);
    const result = await (await dispatch(f)).completion;
    expect(existsSync(join(f.cwd, "subagent-effect.json"))).toBe(allowed);
    expect(result.terminalEvidence?.outcome).toBe("final");
    evidence.push({ case: `producer-${label}`, allowed, version, injectedProducer: true });
  }, 20_000);

  it.each([
    { version: "0.76.1-tron.4", input: { id: "run", nonBlocking: true }, label: "subscription" },
    { version: "0.76.1-tron.5", input: { id: "run", nonBlocking: false }, label: "unknown wait provider" },
  ])("refuses $label before bg_wait can install later work", async ({ version, input, label }) => {
    const f = await fixture(version);
    f.faux.setResponses([fauxAssistantMessage([fauxToolCall("bg_wait", input)], { stopReason: "toolUse" }), fauxAssistantMessage([reportCall()], { stopReason: "toolUse" })]);
    const result = await (await dispatch(f)).completion;
    expect(existsSync(join(f.cwd, "wait-effect.json"))).toBe(false);
    expect(result.terminalEvidence?.outcome).toBe("final");
    evidence.push({ case: `wait-${label}`, executed: false, version });
  }, 20_000);

  it("owns the known blocking bg_wait through exact Stop and join", async () => {
    const f = await fixture("0.76.1-tron.4");
    f.faux.setResponses([fauxAssistantMessage([fauxToolCall("bg_wait", { id: "run", nonBlocking: false })], { stopReason: "toolUse" })]);
    const run = await dispatch(f);
    await waitFor(() => existsSync(join(f.cwd, "wait-effect.json")), "signal-owned blocking wait");
    const slot = await f.registry.acquire(run.sessionId);
    await slot.abort("agent", run.operationId);
    const result = await run.completion;
    expect(existsSync(join(f.cwd, "wait-aborted"))).toBe(true);
    expect(result.terminalEvidence?.outcome).toBe("unknown");
    expect(slot.isBusy).toBe(false);
    evidence.push({ case: "wait-owned-stop", joined: true });
  }, 20_000);

  it("applies the same producer refusal to nested codemode calls", async () => {
    const f = await fixture("0.76.1-tron.4", true);
    f.faux.setResponses([fauxAssistantMessage([fauxToolCall("codemode", { code: 'await tools.subagent({agent:"worker",task:"work",async:false});' })], { stopReason: "toolUse" }), fauxAssistantMessage([reportCall()], { stopReason: "toolUse" })]);
    const result = await (await dispatch(f)).completion;
    expect(existsSync(join(f.cwd, "subagent-effect.json"))).toBe(false);
    expect(result.terminalEvidence?.outcome).toBe("final");
    expect(f.signals).toContainEqual(expect.objectContaining({ event: "home.task.producer-refused", reason: "subagent-execution" }));
    evidence.push({ case: "nested-producer-gate", executed: false });
  }, 20_000);

  it("seals a nested report before codemode can start later effects", async () => {
    const f = await fixture(undefined, true);
    const later = join(f.cwd, "after-report.txt");
    f.faux.setResponses([fauxAssistantMessage([fauxToolCall("codemode", { code: `await tools.report({resultId:"nested-result",outcome:"final",text:"Verified",evidence:[]}); await tools.write({path:${JSON.stringify(later)},content:"forbidden"});` })], { stopReason: "toolUse" }), fauxAssistantMessage("must not continue")]);
    const result = await (await dispatch(f)).completion;
    expect(result.terminalEvidence?.outcome).toBe("final");
    expect(result.reportRefs?.[0]?.resultId).toBe("nested-result");
    expect(existsSync(later)).toBe(false);
    evidence.push({ case: "nested-report-stop", postReportEffect: false });
  }, 20_000);

  it("refuses Tron's schedule tool before its producer executes", async () => {
    const f = await fixture();
    f.faux.setResponses([fauxAssistantMessage([fauxToolCall("schedule", { action: "list" })], { stopReason: "toolUse" }), fauxAssistantMessage([reportCall()], { stopReason: "toolUse" })]);
    const result = await (await dispatch(f)).completion;
    expect(existsSync(join(f.cwd, "schedule-effect"))).toBe(false);
    expect(result.terminalEvidence?.outcome).toBe("final");
    evidence.push({ case: "schedule-gate", producerExecuted: false });
  }, 20_000);

  it("does not apply the task producer gate to ordinary async subagent calls", async () => {
    const f = await fixture("0.76.1-tron.4");
    f.faux.setResponses([fauxAssistantMessage([fauxToolCall("subagent", { agent: "worker", task: "work", async: true })], { stopReason: "toolUse" }), fauxAssistantMessage("ordinary completion")]);
    const slot = await f.registry.create(f.cwd); await slot.prompt("ordinary delegation");
    await waitFor(() => existsSync(join(f.cwd, "subagent-effect.json")), "ordinary async producer invocation");
    await waitFor(() => !slot.isBusy, "ordinary producer terminal");
    evidence.push({ case: "ordinary-async-negative-control", admitted: true, injectedProducer: true });
  }, 20_000);

  it("records unknown rather than final when tracked detached work outlives an explicit report", async () => {
    const f = await fixture();
    let release!: () => void;
    const gate = new Promise<void>(resolve => { release = resolve; });
    f.faux.setResponses([async () => { await gate; return fauxAssistantMessage([reportCall()], { stopReason: "toolUse" }); }]);
    const run = await dispatch(f);
    const slot = await f.registry.acquire(run.sessionId);
    // Inject the existing tracking projection, not a real leaked child process.
    const tracked = vi.spyOn(slot, "catalogHasActiveSubagents", "get").mockReturnValue(true);
    release();
    const result = await run.completion;
    tracked.mockRestore();
    expect(result.terminalEvidence).toMatchObject({ outcome: "unknown", reason: "detached-work-outlived-task" });
    expect(f.signals).toContainEqual(expect.objectContaining({ event: "home.task.detached-work", taskHash: expect.any(String) }));
    evidence.push({ case: "unknown-detached-backstop", injectedTracking: true, outcome: "unknown" });
  }, 20_000);

  it("dispatches through Home's real delegate tool, not an unwired internal API", async () => {
    const f = await fixture();
    const model = f.faux.getModel();
    await f.registry.homeOwner().configureMemory({ model: { provider: model.provider, id: model.id } });
    let homeCalls = 0;
    const response = (context: unknown) => {
      if (JSON.stringify(context).includes("This is a finite Home task")) return fauxAssistantMessage([reportCall()], { stopReason: "toolUse" });
      homeCalls += 1;
      return homeCalls === 1 ? fauxAssistantMessage([fauxToolCall("delegate", { taskId: "task-via-tool", intent: "Finite work", target: f.cwd })], { stopReason: "toolUse" }) : fauxAssistantMessage("Task admitted, not yet consumed");
    };
    f.faux.setResponses([response, response, response, response]);
    const home = await f.registry.acquire(f.home.sessionId);
    await home.prompt("Delegate this finite work");
    await waitFor(async () => {
      try { return (await f.registry.homeOwner().taskResult("task-via-tool")).lifecycle === "terminal"; }
      catch { return false; }
    }, "delegate task terminal");
    expect((await f.registry.homeOwner().taskResult("task-via-tool")).terminalEvidence?.outcome).toBe("final");
    await waitFor(() => !home.isBusy, "Home tool activation terminal");
    evidence.push({ case: "production-delegate", taskOutcome: "final", noAutomaticWake: homeCalls === 2 });
  }, 20_000);
  it("admits once, seals exact canonical report evidence and refuses replay or conflicting reports", async () => {
    const f = await fixture();
    let postReport = 0;
    f.faux.setResponses([
      fauxAssistantMessage([reportCall(), reportCall("report-two", "conflict")], { stopReason: "toolUse" }),
      () => { postReport += 1; return fauxAssistantMessage("must never execute after report"); },
    ]);
    const run = await dispatch(f);
    const result = await run.completion;
    expect(result.terminalEvidence.outcome).toBe("final");
    expect(result.reportRefs).toHaveLength(1);
    const entries = (await f.registry.acquire(run.sessionId)).canonicalSessionEntries();
    const ref = result.reportRefs![0];
    const canonical = entries.find(entry => entry.id === ref.entryId) as any;
    expect(canonical).toMatchObject({ type: "custom", customType: "tron-home-task-report", data: {
      resultId: "report-one", taskId: "task-one", intentRevision: 1,
      homeId: f.home.homeId, generation: f.home.generation, sessionId: run.sessionId,
      operationId: run.operationId, outcome: "final", text: "Verified result", evidence: ["focused check passed"],
    } });
    expect(entries.filter((entry: any) => entry.customType === "tron-home-task-report")).toHaveLength(1);
    expect(postReport).toBe(0);
    expect(f.notifications.filter(record => record.sessionId === run.sessionId)).toEqual([]);
    await expect(dispatch(f)).rejects.toThrow(/already|conflict/i);
    expect(await f.registry.homeOwner().taskResult("task-one")).toEqual(result);
    const originalText = canonical.data.text;
    canonical.data.text = "edited evidence";
    await expect(f.registry.homeOwner().taskResult("task-one")).rejects.toThrow(/contradictory|changed/);
    canonical.data.text = originalText;
    const worker = await f.registry.acquire(run.sessionId);
    const inputEntry = entries.find((entry: any) => entry.type === "message" && entry.message.role === "user")!;
    await worker.navigate(inputEntry.id, { summarize: false });
    expect(await f.registry.homeOwner().taskResult("task-one")).toEqual(result);
    await expect(worker.fork(inputEntry.id)).rejects.toThrow(/task|identity/);
    expect(f.signals.filter(record => record.event === "home.task.transition").map(record => record.transition)).toEqual(["pending", "active", "terminal"]);
    expect(f.signals.find(record => record.event === "home.task.spend")).toMatchObject({ inputTokens: expect.any(Number), unpriced: true });
    evidence.push({ case: "explicit-report", ref, canonicalReport: canonical.data, outcome: result.terminalEvidence.outcome, postReport });
  }, 20_000);

  it("refuses a missing task referenced by a cold worker marker before executable runtime construction", async () => {
    const f = await fixture();
    f.faux.setResponses([fauxAssistantMessage([reportCall()], { stopReason: "toolUse" })]);
    const run = await dispatch(f); await run.completion;
    await f.registry.dispose();
    await rm(join(f.tronHome, "gateway/home/tasks/task-one.json"));
    let constructions = 0;
    const cold = new RuntimeRegistry({ agentDir: f.agentDir, tronHome: f.tronHome, trust: f.trust,
      broadcast: () => {}, sessionSummaryChanged: () => {}, sessionListChanged: () => {},
      modelRuntimeFactory: async () => {
        constructions += 1;
        throw new Error("Executable runtime constructed before task reference check");
      },
    });
    try {
      await cold.initialize(); await (cold as any).sessionCatalog.whenPublished();
      await expect(cold.acquire(run.sessionId)).rejects.toThrow(/Referenced task/);
      expect(constructions).toBe(0);
      evidence.push({ case: "cold-missing-task", constructions, refused: true });
    } finally { await cold.dispose(); }
  }, 20_000);

  it.each(["stop", "length"] as const)("never substitutes the last %s reply for a report", async stopReason => {
    const f = await fixture();
    f.faux.setResponses([fauxAssistantMessage("I claim everything succeeded", { stopReason })]);
    const run = await dispatch(f);
    const result = await run.completion;
    expect(result.terminalEvidence.outcome).toBe(stopReason === "length" ? "limited" : "unknown");
    expect(result.reportRefs).toBeNull();
    const entries = (await f.registry.acquire(run.sessionId)).canonicalSessionEntries();
    const last = entries.find(entry => entry.id === result.terminalEvidence.entryIds[0]) as any;
    expect(last.message.role).toBe("assistant");
    expect(last.message.stopReason).toBe(stopReason);
    evidence.push({ case: `no-report-${stopReason}`, outcome: result.terminalEvidence.outcome, entryIds: result.terminalEvidence.entryIds, assistantEvidence: { stopReason: last.message.stopReason, content: last.message.content } });
  }, 20_000);

  it("keeps ordinary chat capabilities and completion unchanged without delegate or report", async () => {
    const f = await fixture();
    const ordinary = await f.registry.create(f.cwd);
    const requests: unknown[] = [];
    f.faux.setResponses([(context) => { requests.push(context); return fauxAssistantMessage("Ordinary reply"); }]);
    await ordinary.prompt("hello");
    await waitFor(() => !ordinary.isBusy, "ordinary terminal");
    const tools = JSON.stringify((await ordinary.context() as any).availableTools);
    expect(requests).toHaveLength(1);
    expect(tools).not.toMatch(/"name":"(?:report|delegate)"/);
    expect(ordinary.canonicalSessionEntries().some((entry: any) => entry.customType?.startsWith("tron-home-task"))).toBe(false);
    expect(f.signals).toEqual([]);
    await waitFor(() => f.notifications.some(record => record.sessionId === ordinary.id), "ordinary terminal notification");
    evidence.push({ case: "ordinary-negative-control", taskTools: false, taskSignals: 0, ordinaryNotification: true });
  }, 20_000);

  it.each(["no-effect", "successful-read", "blocked-provider", "foreground-process"] as const)("task deadline cancels and joins %s with spend-correlated diagnostic", async scenario => {
    const f = await fixture();
    const originalTimer = globalThis.setTimeout;
    let expire: (() => void) | undefined;
    // Test-only deadline seam: expire after the adversary is demonstrably live,
    // rather than making cancellation proof depend on this shared Mac's speed.
    vi.spyOn(globalThis, "setTimeout").mockImplementation(((callback: any, ms: number, ...args: any[]) => {
      if (ms === OWNED_OPERATION_DEADLINE_MS) expire = callback;
      return originalTimer(callback, ms, ...args);
    }) as typeof setTimeout);
    let turns = 0;
    let aborted = false;
    let providerStarted = false;
    const pidPath = join(f.cwd, "child.pid");
    await writeFile(join(f.cwd, "readable.txt"), "real tool effect\n");
    if (scenario === "blocked-provider") {
      f.faux.setResponses([(_context, options) => new Promise((_resolve, reject) => {
        providerStarted = true;
        options?.signal?.addEventListener("abort", () => { aborted = true; reject(new Error("faux aborted")); }, { once: true });
      })]);
    } else if (scenario === "foreground-process") {
      f.faux.setResponses([fauxAssistantMessage([fauxToolCall("bash", { command: `sleep 120 & echo $! > ${JSON.stringify(pidPath)}; wait` })], { stopReason: "toolUse" })]);
    } else {
      const response = () => {
        turns += 1;
        if (turns < 256) f.faux.appendResponses([response]);
        return fauxAssistantMessage([fauxToolCall("read", { path: join(f.cwd, scenario === "no-effect" ? "missing" : "readable.txt") }, { id: `read-${turns}` })], { stopReason: "toolUse" });
      };
      f.faux.setResponses([response]);
    }
    const run = await dispatch(f);
    expect(expire).toBeDefined();
    await waitFor(() => scenario === "blocked-provider" ? providerStarted : scenario === "foreground-process" ? existsSync(pidPath) : turns >= 3, "task adversary live");
    expire!();
    const result = await run.completion;
    expect(result.terminalEvidence).toMatchObject({ outcome: "limited", reason: "deadline" });
    const slot = await f.registry.acquire(run.sessionId);
    expect(slot.isBusy).toBe(false);
    const entriesAtStop = slot.canonicalSessionEntries().length;
    const turnsAtStop = turns;
    await new Promise(resolve => originalTimer(resolve, 40));
    expect(turns).toBe(turnsAtStop); expect(slot.canonicalSessionEntries()).toHaveLength(entriesAtStop);
    if (scenario === "blocked-provider") expect(aborted).toBe(true);
    if (scenario === "foreground-process") {
      expect(existsSync(pidPath)).toBe(true);
      const pid = Number(await readFile(pidPath, "utf8"));
      expect(() => process.kill(pid, 0)).toThrow();
    } else if (scenario !== "blocked-provider") expect(turns).toBeGreaterThanOrEqual(3);
    const signal = f.signals.find(record => record.event === "home.task.runaway-stop");
    expect(signal).toMatchObject({ taskHash: expect.stringMatching(/^[a-f0-9]{16}$/), spendReference: expect.any(String), cancelAndJoin: "joined" });
    expect(JSON.stringify(signal)).not.toContain(f.cwd);
    expect(result.spend!.inputTokens + result.spend!.outputTokens).toBeGreaterThanOrEqual(scenario === "blocked-provider" ? 0 : 1);
    evidence.push({ case: scenario, turnsAtStop, entriesAtStop, spend: result.spend, signal, noFurtherEffects: true });
  }, 20_000);

  it("records a failed exact deadline join as unknown with durable correlated evidence", async () => {
    const f = await fixture();
    let expire: (() => void) | undefined;
    const originalTimer = globalThis.setTimeout;
    vi.spyOn(globalThis, "setTimeout").mockImplementation(((callback: any, ms: number, ...args: any[]) => {
      if (ms === OWNED_OPERATION_DEADLINE_MS) expire = callback;
      return originalTimer(callback, ms, ...args);
    }) as typeof setTimeout);
    let started = false;
    f.faux.setResponses([(_context, options) => new Promise((_resolve, reject) => {
      started = true;
      options?.signal?.addEventListener("abort", () => reject(new Error("faux stopped")), { once: true });
    })]);
    const run = await dispatch(f);
    const slot = await f.registry.acquire(run.sessionId);
    await waitFor(() => started, "failed join provider live");
    const stop = vi.spyOn(slot, "abort").mockRejectedValue(new Error("injected exact join failure"));
    expire!();
    const result = await run.completion;
    stop.mockRestore();
    expect(result.terminalEvidence).toMatchObject({ outcome: "unknown", reason: "deadline-stop-failed" });
    expect(f.signals).toContainEqual(expect.objectContaining({ event: "home.task.runaway-stop", cancelAndJoin: "failed", spendReference: expect.any(String) }));
    await slot.abort("agent", run.operationId);
    evidence.push({ case: "deadline-join-failed", injectedFailure: true, outcome: "unknown", actualStopCleanedUp: true });
  }, 20_000);

  it("preserves authority on restart/file replacement but requires reconfirmation after copying a namespace", async () => {
    const f = await fixture();
    f.faux.setResponses([fauxAssistantMessage("no report")]);
    await (await dispatch(f)).completion;
    const store = new HomeTaskStore(f.tronHome, (f.registry as any).workspace);
    const before = await store.restoreEpoch();
    const taskPath = join(f.tronHome, "gateway/home/tasks/task-one.json");
    const tempPath = `${taskPath}.tmp`;
    await writeFile(tempPath, await readFile(taskPath), { mode: 0o600 }); await rename(tempPath, taskPath);
    expect(await store.restoreEpoch()).toBe(before);
    const source = join(f.tronHome, "gateway/home/tasks");
    const backup = join(f.root, "copied-tasks");
    await cp(source, backup, { recursive: true, preserveTimestamps: true });
    await rm(source, { recursive: true }); await rename(backup, source);
    expect(await store.restoreEpoch()).not.toBe(before);
    await expect(dispatch(f, "task-after-restore")).rejects.toMatchObject({ code: "scope-reconfirmation-required" });
    evidence.push({ case: "restore-directory", preservedOnFileReplacement: true, refusedAfterCopy: true });
  }, 20_000);
});
