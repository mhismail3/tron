import * as fileSystem from "node:fs/promises";
import { existsSync } from "node:fs";
import { chmod, cp, mkdir, mkdtemp, readFile, rename, rm, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { dirname, join } from "node:path";
import { ModelRuntime } from "@earendil-works/pi-coding-agent";
import { fauxAssistantMessage, fauxProvider, fauxToolCall } from "@earendil-works/pi-ai";
import { afterAll, afterEach, describe, expect, it, vi } from "vitest";
import { TrustService } from "../admin/trust-service.js";
import type { NotificationService } from "../notifications/notification-service.js";
import { HomeTaskStore } from "./home-task-store.js";
import { RuntimeRegistry } from "../sessions/runtime-registry.js";
import { SessionCatalog } from "../sessions/session-catalog.js";
import { OWNED_OPERATION_DEADLINE_MS, OwnedSessionDispatch } from "../sessions/owned-session-dispatch.js";
import { GatewayService, type ClientContext, type GatewayServiceDependencies } from "../transport/gateway-service.js";
import { CommandReceiptStore } from "../transport/command-receipts.js";
import { runHomeInput } from "../client/terminal-chat.js";
import { waitFor } from "../../test-support/wait-for.js";
import { freezeHomeLedgerWriter } from "../../test-support/home-ledger-crash-frozen-owner.js";

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
  const createRegistry = () => new RuntimeRegistry({ agentDir, tronHome, trust, machineId: "machine-task-test",
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
  const registry = createRegistry();
  const owned = { registry, root };
  fixtures.push(owned);
  await registry.initialize();
  await (registry as any).sessionCatalog.whenPublished();
  const home = await registry.homeOwner().designate({ model: { provider: model.provider, id: model.id } });
  return { root, registry, faux, cwd, tronHome, home, signals, notifications, agentDir, trust,
    restart: async () => {
      await owned.registry.dispose();
      await owned.registry.administrativeWorkRegistry.waitUntilSettled();
      owned.registry = createRegistry();
      await owned.registry.initialize();
      await (owned.registry as any).sessionCatalog.whenPublished();
      return owned.registry;
    } };
}
const reportCall = (id = "report-one", text = "Verified result") => fauxToolCall("report", { resultId: id, outcome: "final", text, evidence: ["focused check passed"] }, { id: `call-${id}` });
async function dispatch(f: Awaited<ReturnType<typeof fixture>>, taskId = "task-one") {
  return f.registry.homeOwner().dispatchTask(f.home.sessionId, { taskId, intent: "Finite work", target: f.cwd });
}

describe("Home task cold reconciliation", () => {
  it.each(["before-report", "after-report", "after-terminal"])("recovers %s without replay and keeps terminal outbox/authorization", async cut => {
    const f = await fixture();
    const store = (f.registry.homeOwner() as any).tasks.store as HomeTaskStore;
    const authorization = (f.registry.homeOwner() as any).tasks.authorization;
    await store.initialize();
    await authorization.enableInitialScope(await store.restoreEpoch());
    await authorization.recordDecisionAndGrant({ intentRevision: 1, intentDigest: "a".repeat(64), target: f.cwd,
      authorizationScope: "full-work", workerProfile: "home-task-v1", policyRevision: 1, restoreEpoch: await store.restoreEpoch() },
      { decisionId: "unspent", expiresAt: Date.now() + 60_000 });
    const authorizationPath = join(f.tronHome, "gateway/home/tasks/authorization.json");
    const beforeAuthority = await readFile(authorizationPath, "utf8");
    let providers = 0;
    const effect = join(f.cwd, "effect");
    f.faux.setResponses([() => { providers++; return fauxAssistantMessage([fauxToolCall("write", { path: effect, content: "once" })], { stopReason: "toolUse" }); },
      () => { providers++; return fauxAssistantMessage(cut === "before-report" ? "No report" : [reportCall()], { stopReason: cut === "before-report" ? "stop" : "toolUse" }); }]);
    const update = store.update.bind(store);
    if (cut === "after-terminal") {
      vi.spyOn(store, "update").mockImplementation(freezeHomeLedgerWriter(update, task => task.lifecycle === "terminal"));
    } else {
      vi.spyOn(store, "update").mockImplementation(async (id, change) => {
        if (change((await store.read(id))!).lifecycle === "terminal") throw new Error("frozen before terminal publication");
        return update(id, change);
      });
    }
    const run = await dispatch(f);
    await expect(run.completion).rejects.toThrow(/frozen/);
    expect(await readFile(effect, "utf8")).toBe("once");
    const frozen = await store.read(run.taskId);
    expect(frozen?.lifecycle).toBe(cut === "after-terminal" ? "terminal" : "active");
    expect(f.notifications).toHaveLength(0);
    vi.restoreAllMocks();
    const recovered = await f.restart();
    const task = await recovered.homeOwner().taskResult(run.taskId);
    expect(task).toMatchObject({ lifecycle: "terminal", terminalEvidence: { outcome: cut === "before-report" ? "unknown" : "final" }, wake: { state: "pending", push: "decided" } });
    expect(await readFile(authorizationPath, "utf8")).toBe(beforeAuthority);
    expect(providers).toBe(2);
    expect(f.notifications).toHaveLength(1);
    await expect(recovered.homeOwner().dispatchTask(f.home.sessionId, { taskId: run.taskId, intent: "Finite work", target: f.cwd })).rejects.toThrow(/already exists/);
    const again = await f.restart();
    expect(await again.homeOwner().taskResult(run.taskId)).toEqual(task);
    expect(f.notifications).toHaveLength(1);
    expect(providers).toBe(2);
    evidence.push({ case: `cold-${cut}`, frozen, task, providers, effect: await readFile(effect, "utf8"), authorizationUnchanged: true });
  }, 20_000);

  it.each(["missing-marker", "duplicate-marker", "wrong-marker", "missing-report", "malformed-report", "wrong-report", "duplicate-report", "torn", "interrupted", "off-branch", "report-without-terminal", "missing-session", "bad-header", "old-format", "bad-graph", "sync-refused"])("reconciles %s evidence conservatively without constructing a worker", async mode => {
    const f = await fixture();
    const store = (f.registry.homeOwner() as any).tasks.store as HomeTaskStore;
    const update = store.update.bind(store);
    vi.spyOn(store, "update").mockImplementation(async (id, change) => {
      if (change((await store.read(id))!).lifecycle === "terminal") throw new Error("frozen before terminal publication");
      return update(id, change);
    });
    f.faux.setResponses([fauxAssistantMessage([reportCall()], { stopReason: "toolUse" })]);
    const run = await dispatch(f);
    await expect(run.completion).rejects.toThrow(/frozen/);
    const worker = await f.registry.acquire(run.sessionId);
    const path = worker.sessionFile!;
    const rows = (await readFile(path, "utf8")).trimEnd().split("\n").map(line => JSON.parse(line));
    const marker = rows.find(row => row.customType === "tron-home-task");
    const report = rows.find(row => row.customType === "tron-home-task-report");
    expect(report).toBeDefined();
    if (mode === "missing-marker") rows.splice(rows.indexOf(marker), 1);
    if (mode === "duplicate-marker") rows.push({ ...marker, id: "duplicate-marker", parentId: rows.at(-1).id });
    if (mode === "wrong-marker") marker.data.operationId = "other-operation";
    if (mode === "bad-header") rows[0].id = "other-session";
    if (mode === "old-format") rows[0].version = 2;
    if (mode === "bad-graph") report.parentId = report.id;
    if (mode === "interrupted") expect(rows).toContainEqual(expect.objectContaining({ customType: "tron.chat-invocation.v1", data: expect.objectContaining({ receiptKind: "terminal", lifecycle: "interrupted", operationId: run.operationId }) }));
    if (mode === "missing-report" || mode === "interrupted") {
      for (const row of rows) if (row.parentId === report.id) row.parentId = report.parentId;
      rows.splice(rows.indexOf(report), 1);
    }
    if (mode === "malformed-report") report.data.outcome = "invented-success";
    if (mode === "wrong-report") report.data.receiptId = "report:other-operation";
    if (mode === "duplicate-report") rows.push({ ...report, id: "duplicate-report", parentId: rows.at(-1).id });
    if (mode === "off-branch") rows.push({ type: "custom", id: "view-other-branch", parentId: marker.id, timestamp: new Date().toISOString(), customType: "view-only", data: {} });
    if (mode === "report-without-terminal") {
      for (let index = rows.length - 1; index >= 0; index--) {
        const row = rows[index];
        if (row.customType !== "tron.chat-invocation.v1" || row.data.receiptKind !== "terminal") continue;
        for (const child of rows) if (child.parentId === row.id) child.parentId = row.parentId;
        rows.splice(index, 1);
      }
    }
    vi.restoreAllMocks();
    // Retire the old process owner before changing its frozen canonical cut.
    await f.registry.dispose();
    await f.registry.administrativeWorkRegistry.waitUntilSettled();
    if (mode === "missing-session") await rm(path);
    else await writeFile(path, rows.map(row => JSON.stringify(row)).join("\n") + "\n" + (mode === "torn" ? '{"partial":' : ""));
    if (mode === "sync-refused") {
      const anchor = await fileSystem.open(f.cwd, "r");
      const prototype = Object.getPrototypeOf(anchor); const sync = prototype.sync; await anchor.close();
      const target = await fileSystem.stat(path);
      vi.spyOn(prototype, "sync").mockImplementation(async function(this: import("node:fs/promises").FileHandle) {
        const current = await this.stat();
        if (current.dev === target.dev && current.ino === target.ino) throw new Error("task evidence sync refused");
        return sync.call(this);
      });
    }
    const frozenCanonical = mode === "missing-session" ? undefined : await readFile(path, "utf8");
    const open = vi.spyOn(RuntimeRegistry.prototype, "acquire");
    const recovered = await f.restart();
    expect(open).not.toHaveBeenCalled();
    const task = await (recovered.homeOwner() as any).tasks.store.read(run.taskId);
    const reportProven = mode === "off-branch" || mode === "report-without-terminal";
    expect(task).toMatchObject({ lifecycle: "terminal", terminalEvidence: { outcome: reportProven ? "final" : "unknown" }, wake: { state: "pending", push: "decided" } });
    expect(f.notifications).toHaveLength(1);
    if (frozenCanonical !== undefined) expect(await readFile(path, "utf8")).toBe(frozenCanonical);
    expect(f.signals).toContainEqual(expect.objectContaining({ event: "home.task.transition", transition: "terminal", reason: reportProven ? "cold-explicit-report" : expect.stringMatching(/^cold-/) }));
    evidence.push({ case: `cold-evidence-${mode}`, task, runtimeConstructed: false });
  }, 20_000);

  it("confines a typed recovery refusal to every task surface until the next start", async () => {
    const f = await fixture();
    f.faux.setResponses([fauxAssistantMessage([reportCall()], { stopReason: "toolUse" })]);
    const run = await dispatch(f); await run.completion;
    const taskPath = join(f.tronHome, "gateway/home/tasks", `${run.taskId}.json`);
    const authPath = join(f.tronHome, "gateway/home/tasks/authorization.json");
    const taskBytes = await readFile(taskPath, "utf8"); const authBytes = await readFile(authPath, "utf8");
    await f.registry.dispose(); await f.registry.administrativeWorkRegistry.waitUntilSettled();
    await chmod(f.tronHome, 0o755);
    const cold = await f.restart();
    const owner = cold.homeOwner();
    expect(await owner.status()).toMatchObject({ taskRecovery: { available: false, reason: "unsafe-state" } });
    const control = { taskId: run.taskId, operationId: run.operationId, controllerGeneration: 1, text: "Steer" };
    const operations: Array<[string, () => Promise<unknown>]> = [
      ["dispatch", () => owner.dispatchTask(f.home.sessionId, { taskId: "new-task", intent: "Finite", target: f.cwd })],
      ["status", () => owner.taskResult(run.taskId)],
      ["task-tool", () => owner.taskTool(f.home.sessionId, { action: "status", taskId: run.taskId })],
      ["home-steer", () => owner.steerTask(f.home.sessionId, control)],
      ["maintainer-steer", () => owner.maintainTask(control)],
      ["stop", () => owner.stopTask(control)],
      ["reconfirm", () => owner.reconfirmTaskPermissions()],
      ["redelivery", () => owner.redeliverTaskResult(run.taskId, { homeId: f.home.homeId, routeGeneration: 1 })],
      ["inbox-admit", () => owner.admitTaskResults(f.home.sessionId, "activation", async () => { throw new Error("delivery while fenced"); })],
      ["inbox-ack", () => owner.settleTaskResults(f.home.sessionId, "activation")],
      ["worker-open", () => cold.acquire(run.sessionId)],
    ];
    const result: string[] = [];
    // Repair does not lift the per-process refusal or re-attempt recovery.
    await chmod(f.tronHome, 0o700);
    for (const [name, operation] of operations) {
      await expect(operation(), name).rejects.toMatchObject({ code: "conflict", details: { reason: "unsafe-state" } });
      result.push(name);
    }
    expect(f.signals.filter(signal => signal.event === "home.task.store-refused" && signal.reason === "unsafe-state")).toHaveLength(1);
    const ordinary = await cold.create(f.cwd);
    f.faux.setResponses([fauxAssistantMessage("Ordinary sessions still work")]);
    await ordinary.prompt("ordinary input"); await waitFor(() => !ordinary.isBusy, "ordinary fenced-owner prompt");
    expect(ordinary.canonicalSessionEntries()).toContainEqual(expect.objectContaining({ type: "message", message: expect.objectContaining({ role: "assistant", content: expect.arrayContaining([expect.objectContaining({ text: "Ordinary sessions still work" })]) }) }));
    expect(await readFile(taskPath, "utf8")).toBe(taskBytes); expect(await readFile(authPath, "utf8")).toBe(authBytes);
    const again = await f.restart();
    expect(await again.homeOwner().status()).toMatchObject({ taskRecovery: { available: true } });
    expect(await again.homeOwner().taskResult(run.taskId)).toMatchObject({ lifecycle: "terminal", terminalEvidence: { outcome: "final" } });
    evidence.push({ case: "task-recovery-fence", operations: result, ordinaryPrompt: true, bytesPreserved: true, restartAvailable: true });
  }, 20_000);

  it("joins the fresh catalog cut before irreversibly qualifying a cold report", async () => {
    const f = await fixture();
    const store = (f.registry.homeOwner() as any).tasks.store as HomeTaskStore;
    vi.spyOn(store, "update").mockRejectedValue(new Error("frozen terminal owner"));
    f.faux.setResponses([fauxAssistantMessage([reportCall()], { stopReason: "toolUse" })]);
    const run = await dispatch(f); await expect(run.completion).rejects.toThrow(/frozen/);
    vi.restoreAllMocks();
    let release!: () => void;
    const gate = new Promise<void>(resolve => { release = resolve; });
    const ready = SessionCatalog.prototype.whenReconciled;
    const barrier = vi.spyOn(SessionCatalog.prototype, "whenReconciled").mockImplementation(async function(this: SessionCatalog) {
      await gate; await ready.call(this);
    });
    const starting = f.restart(); void starting.catch(() => {});
    try {
      await waitFor(() => barrier.mock.calls.length > 0, "cold task joins catalog readiness", { boundMs: 1000 });
      expect(JSON.parse(await readFile(join(f.tronHome, "gateway/home/tasks", `${run.taskId}.json`), "utf8")).lifecycle).toBe("active");
    } finally { release(); await starting; }
    const recovered = await starting;
    expect(await recovered.homeOwner().taskResult(run.taskId)).toMatchObject({ lifecycle: "terminal", terminalEvidence: { outcome: "final" } });
    evidence.push({ case: "cold-catalog-readiness", task: await recovered.homeOwner().taskResult(run.taskId) });
  }, 20_000);

  it.each(["pending", "grant-consumed", "worker-created", "operation-bound"])("retires the %s admission cut without replay or renewing grants", async cut => {
    const f = await fixture();
    const tasks = (f.registry.homeOwner() as any).tasks;
    const store = tasks.store as HomeTaskStore;
    await store.initialize();
    const epoch = await store.restoreEpoch();
    const intent = { revision: 1, text: "Finite work" };
    const { createHash } = await import("node:crypto");
    await tasks.authorization.recordDecisionAndGrant({ intentRevision: 1, intentDigest: createHash("sha256").update(JSON.stringify(intent)).digest("hex"),
      target: f.cwd, authorizationScope: "full-work", workerProfile: "home-task-v1", policyRevision: 1, restoreEpoch: epoch },
      { decisionId: "single-use", expiresAt: Date.now() + 60_000 });
    const put = store.put.bind(store);
    let frozen = false;
    vi.spyOn(store, "put").mockImplementation(async (task, expected) => {
      if (frozen) throw new Error("frozen admission owner");
      if (cut === "worker-created" && task.lifecycle === "active") { frozen = true; throw new Error("frozen admission owner"); }
      await put(task, expected);
      if (task.lifecycle === (cut === "pending" ? "pending" : "active") && cut !== "grant-consumed" && cut !== "worker-created") { frozen = true; throw new Error("frozen admission owner"); }
    });
    if (cut === "grant-consumed") {
      const save = store.authorization.save;
      vi.spyOn(store.authorization, "save").mockImplementation(async state => {
        await save(state); frozen = true; throw new Error("frozen admission owner");
      });
    }
    const calls = vi.fn(() => fauxAssistantMessage("Never replay")); f.faux.setResponses([calls]);
    await expect(dispatch(f)).rejects.toThrow(/frozen/);
    const authorizationPath = join(f.tronHome, "gateway/home/tasks/authorization.json");
    const before = await readFile(authorizationPath, "utf8");
    vi.restoreAllMocks();
    const recovered = await f.restart();
    const task = await (recovered.homeOwner() as any).tasks.store.read("task-one");
    expect(task).toMatchObject({ lifecycle: "terminal", terminalEvidence: { outcome: "unknown" }, wake: { state: "pending", push: "decided" } });
    expect(await readFile(authorizationPath, "utf8")).toBe(before);
    expect(JSON.parse(before).grants[0].state).toBe(cut === "pending" ? "available" : "consumed");
    expect(calls).not.toHaveBeenCalled();
    expect(f.notifications).toHaveLength(1);
    evidence.push({ case: `cold-admission-${cut}`, task, authorityPreserved: true, providers: calls.mock.calls.length });
  }, 20_000);
});

describe("Home task production dispatch", () => {
  it.each(["file", "directory"] as const)("refuses live settlement before canonical %s sync and recovers without replay", async target => {
    const f = await fixture();
    const store = (f.registry.homeOwner() as any).tasks.store as HomeTaskStore;
    let release!: () => void;
    const gate = new Promise<void>(resolve => { release = resolve; });
    let providers = 0;
    f.faux.setResponses([async () => { providers++; await gate; return fauxAssistantMessage([reportCall()], { stopReason: "toolUse" }); }]);
    try {
      const run = await dispatch(f);
      const worker = await f.registry.acquire(run.sessionId);
      const anchor = await fileSystem.open(f.cwd, "r");
      const prototype = Object.getPrototypeOf(anchor); const sync = prototype.sync;
      await anchor.close();
      let failedSync = false;
      vi.spyOn(prototype, "sync").mockImplementation(async function(this: import("node:fs/promises").FileHandle) {
        const path = worker.sessionFile;
        const expected = path ? await fileSystem.stat(target === "file" ? path : dirname(path)).catch(() => undefined) : undefined;
        const current = await this.stat();
        if (expected && current.dev === expected.dev && current.ino === expected.ino) { failedSync = true; throw new Error("live canonical sync refused"); }
        return sync.call(this);
      });
      const acknowledge = vi.spyOn(f.registry, "clearOwnedOperationMarker");
      release();
      const completion = await run.completion.then(() => "published", error => String(error));
      const frozen = await store.read(run.taskId);
      expect(frozen).toMatchObject({ lifecycle: "active", reportRefs: null, terminalEvidence: null, wake: null });
      expect(completion).toContain("live canonical sync refused");
      expect(failedSync).toBe(true);
      expect(acknowledge).not.toHaveBeenCalled();
      expect(f.notifications).toHaveLength(0);
      vi.restoreAllMocks();
      const recovered = await f.restart();
      const task = await recovered.homeOwner().taskResult(run.taskId);
      expect(task).toMatchObject({ lifecycle: "terminal", terminalEvidence: { outcome: "final" }, wake: { state: "pending", push: "decided" } });
      expect(task.reportRefs).toHaveLength(1);
      expect(providers).toBe(1);
      expect(f.notifications).toHaveLength(1);
      evidence.push({ case: `live-canonical-${target}-sync-before-settlement`, frozen, completion, task, providers });
    } finally { release(); }
  }, 20_000);

  it("leaves absent canonical evidence without a durable Stop intent unqualified until cold recovery", async () => {
    const f = await fixture();
    const create = OwnedSessionDispatch.prototype.createWorker;
    vi.spyOn(OwnedSessionDispatch.prototype, "createWorker").mockImplementation(async function(cwd, reports) {
      const lease = await create.call(this, cwd, reports);
      vi.spyOn((lease.slot as any).runtime.session, "prompt").mockRejectedValue(new Error("preflight refused"));
      return lease;
    });
    let providers = 0;
    f.faux.setResponses([() => { providers++; return fauxAssistantMessage("must not start"); }]);
    const run = await dispatch(f);
    await expect(run.completion).rejects.toThrow("Task canonical evidence is unavailable");
    const store = (f.registry.homeOwner() as any).tasks.store as HomeTaskStore;
    const frozen = await store.read(run.taskId);
    expect(frozen).toMatchObject({ lifecycle: "active", stopIntent: null, terminalEvidence: null, reportRefs: null, wake: null });
    expect(f.notifications).toHaveLength(0);
    vi.restoreAllMocks();
    const recovered = await f.restart();
    const task = await recovered.homeOwner().taskResult(run.taskId);
    expect(task.terminalEvidence).toMatchObject({ outcome: "unknown", entryIds: [] });
    expect(providers).toBe(0);
    evidence.push({ case: "absent-without-stop", frozen, task, providers });
  });

  it("commits one push plus pending wake and consumes the immutable report only on the next Home message", async () => {
    const f = await fixture();
    const model = f.faux.getModel();
    await f.registry.homeOwner().configureMemory({ model: { provider: model.provider, id: model.id } });
    let calls = 0;
    f.faux.setResponses([() => { calls++; return fauxAssistantMessage([reportCall()], { stopReason: "toolUse" }); }]);
    const run = await dispatch(f);
    const task = await run.completion;
    expect(task).toMatchObject({ wake: { state: "pending", push: "decided" } });
    expect(calls).toBe(1);
    expect(f.notifications).toHaveLength(1);
    expect(f.notifications[0]).toMatchObject({ sourceId: (task as any).wake.eventId, route: { sessionId: "home" } });
    const home = await f.registry.acquire(f.home.sessionId);
    expect(JSON.stringify(home.canonicalSessionEntries())).not.toContain("Verified result");
    let request = "";
    let instructions = "";
    f.faux.setResponses([(context) => { request = JSON.stringify(context); instructions = JSON.stringify(context.messages.filter(message => message.role === "system")); return fauxAssistantMessage("Result consumed"); }]);
    await home.prompt("What happened?");
    await waitFor(() => !home.isBusy, "Home inbox terminal");
    const consumed = await f.registry.homeOwner().taskResult(run.taskId);
    expect(consumed).toMatchObject({ wake: { state: "acknowledged" } });
    expect(request).toContain("Verified result");
    // The actual provider instructions must explain the delivery happening in
    // this activation, rather than telling Home the result is unavailable.
    expect(instructions).toMatch(/attributed work messages on the next maintainer message/);
    expect(instructions).toMatch(/advisory push.*does not wake Home/);
    expect(instructions).toContain("do not assume task success from admission");
    expect(instructions).not.toContain("not yet delivered into Home");
    const attributed = home.canonicalSessionEntries().filter(entry => entry.type === "custom_message" && entry.customType === "tron.home-task-result.v1");
    expect(attributed).toHaveLength(1);
    expect(home.canonicalSessionEntries()).toContainEqual(expect.objectContaining({ type: "custom", customType: "tron.context-delivery.v4",
      data: expect.objectContaining({ targetEntryId: attributed[0]!.id, origin: { source: "gateway:home-task", owner: { id: task.taskId, title: "Home task", source: "gateway:home-task" } } }) }));
    expect(f.signals.filter(record => record.event === "home.task.inbox")).toEqual(expect.arrayContaining([
      expect.objectContaining({ state: "admitted", reason: "canonical-admission" }), expect.objectContaining({ state: "acknowledged", reason: "canonical-consumed" })]));
    expect(JSON.stringify(f.signals.filter(record => record.event === "home.task.inbox"))).not.toMatch(/Verified result|task-one|Finite work/);
    f.faux.setResponses([fauxAssistantMessage("No duplicate")]);
    await home.prompt("Again"); await waitFor(() => !home.isBusy, "second Home terminal");
    expect(home.canonicalSessionEntries().filter(entry => entry.type === "custom_message" && entry.customType === "tron.home-task-result.v1")).toHaveLength(1);
    expect(f.notifications.filter(input => input.sourceId === (task as any).wake.eventId)).toHaveLength(1);
    evidence.push({ case: "input-task-report-push-pending-consumption", task, consumed, attributed, request });
  }, 20_000);

  it("refuses inbox acknowledgement until canonical message and terminal receipt are durably synced", async () => {
    const f = await fixture(); const owner = f.registry.homeOwner(); const model = f.faux.getModel();
    await owner.configureMemory({ model: { provider: model.provider, id: model.id } });
    f.faux.setResponses([fauxAssistantMessage([reportCall()], { stopReason: "toolUse" })]);
    const task = await (await dispatch(f)).completion;
    const home = await f.registry.acquire(f.home.sessionId);
    const path = (home as any).sessionManager.getSessionFile();
    const anchor = await fileSystem.open(f.cwd, "r");
    const prototype = Object.getPrototypeOf(anchor);
    const sync = prototype.sync;
    await anchor.close();
    let failedSync = false;
    vi.spyOn(prototype, "sync").mockImplementation(async function(this: import("node:fs/promises").FileHandle) {
      const target = await fileSystem.stat(path).catch(() => undefined);
      const current = await this.stat();
      if (target && current.dev === target.dev && current.ino === target.ino) { failedSync = true; throw new Error("canonical sync refused"); }
      return sync.call(this);
    });
    f.faux.setResponses([fauxAssistantMessage("result received")]);
    await home.prompt("Read the result").catch(() => {});
    await waitFor(() => !home.isBusy, "failed sync Home terminal");
    expect((await owner.taskResult(task.taskId)).wake?.state).not.toBe("acknowledged");
    expect(failedSync).toBe(true);
    vi.restoreAllMocks();
    f.faux.setResponses([fauxAssistantMessage("reconciled")]);
    await home.prompt("Continue"); await waitFor(() => !home.isBusy, "reconciled sync terminal");
    expect((await owner.taskResult(task.taskId)).wake?.state).toBe("acknowledged");
    expect(home.canonicalSessionEntries().filter(entry => entry.type === "custom_message" && entry.customType === "tron.home-task-result.v1")).toHaveLength(1);
    evidence.push({ case: "canonical-fsync-before-ack", failedSync, recovered: await owner.taskResult(task.taskId) });
  }, 20_000);

  it("keeps one logical inbox route through repeated disable and re-enable", async () => {
    const f = await fixture();
    f.faux.setResponses([fauxAssistantMessage([reportCall()], { stopReason: "toolUse" })]);
    const task = await (await dispatch(f)).completion;
    const before = (await f.registry.homeOwner().status()) as any;
    for (let i = 0; i < 3; i++) {
      await f.registry.homeOwner().disable();
      expect(await f.registry.homeOwner().taskResult(task.taskId)).toMatchObject({ wake: { state: "pending" } });
      await f.registry.homeOwner().designate({});
    }
    const after = (await f.registry.homeOwner().status()) as any;
    expect(after.routeGeneration).toBe(before.routeGeneration);
    const model = f.faux.getModel();
    await f.registry.homeOwner().configureMemory({ model: { provider: model.provider, id: model.id } });
    f.faux.setResponses([fauxAssistantMessage([fauxToolCall("task", { action: "status", taskId: task.taskId })], { stopReason: "toolUse" }), fauxAssistantMessage("consumed once")]);
    const home = await f.registry.acquire(f.home.sessionId);
    await home.prompt("Continue"); await waitFor(() => !home.isBusy, "reenabled inbox terminal");
    expect(await f.registry.homeOwner().taskResult(task.taskId)).toMatchObject({ wake: { state: "acknowledged" } });
    expect(home.canonicalSessionEntries().filter(entry => entry.type === "message" && entry.message.role === "toolResult" && entry.message.toolName === "task")).toContainEqual(expect.objectContaining({ message: expect.objectContaining({ isError: false }) }));
    evidence.push({ case: "inbox-disable-reenable", before, after });
  }, 20_000);
  it("blocks replacement until receipted maintainer redelivery and follows the logical route across chapter rollover", async () => {
    const f = await fixture();
    const owner = f.registry.homeOwner(); const model = f.faux.getModel();
    await owner.configureMemory({ model: { provider: model.provider, id: model.id } });
    let home = await f.registry.acquire(f.home.sessionId);
    f.faux.setResponses([fauxAssistantMessage("Initial Home conversation")]);
    await home.prompt("Start Home"); await waitFor(() => !home.isBusy, "initial Home terminal");
    f.faux.setResponses([fauxAssistantMessage([reportCall()], { stopReason: "toolUse" })]);
    const task = await (await dispatch(f)).completion;
    const port = (owner as any).options.sessions;
    const present = port.sessionPresent.bind(port);
    const missing = vi.spyOn(port, "sessionPresent").mockImplementation((id: string) => id === f.home.sessionId ? Promise.resolve(false) : present(id));
    const replacement = await owner.designate({ model: { provider: model.provider, id: model.id } }); missing.mockRestore();
    expect(replacement.sessionId).not.toBe(f.home.sessionId);
    expect((await owner.status() as any).routeGeneration).toBe(task.routeGeneration + 1);
    home = await f.registry.acquire(replacement.sessionId);
    f.faux.setResponses([fauxAssistantMessage("replacement sees no old result")]);
    await home.prompt("Continue after replacement"); await waitFor(() => !home.isBusy, "replacement terminal");
    expect(await owner.taskResult(task.taskId)).toMatchObject({ wake: { state: "blocked" } });
    expect(JSON.stringify(home.canonicalSessionEntries())).not.toContain("Verified result");
    const service = new GatewayService({ config: { tronHome: f.tronHome }, sessions: f.registry, home: owner,
      receipts: new CommandReceiptStore(join(f.root, "redelivery-receipts")) } as unknown as GatewayServiceDependencies);
    const client = { id: "inbox-terminal", identity: "device:inbox-test", isLocal: true } as unknown as ClientContext;
    let command: unknown;
    const terminal = { request: async (method: string, params: unknown) => { if (method === "home.redeliverTaskResult") command = params; return service.invoke(client, method, params); } };
    const output = vi.spyOn(process.stdout, "write").mockImplementation(() => true);
    await runHomeInput(terminal as any, `/home redeliver ${task.taskId}`);
    expect(output).toHaveBeenCalledWith(expect.stringContaining("redelivery accepted")); output.mockRestore();
    expect(await service.invoke(client, "home.redeliverTaskResult", command)).toEqual({ accepted: true });
    const pending = await owner.taskResult(task.taskId);
    expect(pending).toMatchObject({ wake: { state: "pending", redeliveries: [{ from: task.routeGeneration, to: task.routeGeneration + 1 }] } });
    const oldPath = (await port.sessionFile(replacement.sessionId))!;
    const metrics = vi.spyOn(port, "chapterMetrics").mockResolvedValue({ bytes: 25 * 1024 * 1024, entries: 10, quiescent: true });
    await owner.chapterQuiescent(replacement.sessionId); metrics.mockRestore();
    const sealed = await readFile(oldPath);
    f.faux.setResponses([fauxAssistantMessage("current chapter receives result")]);
    const accepted = await service.invoke(client, "home.prompt", { commandId: "next-chapter-message", text: "Review the task" }) as any;
    expect(accepted.sessionId).not.toBe(replacement.sessionId);
    const current = await f.registry.acquire(accepted.sessionId);
    await waitFor(() => !current.isBusy, "rollover result terminal");
    expect(await owner.taskResult(task.taskId)).toMatchObject({ wake: { state: "acknowledged" } });
    // Once consumed, redelivery is ineligible. Only the original command's
    // receipt may still return its accepted result without invoking the owner.
    const consumed = await owner.taskResult(task.taskId);
    expect(await service.invoke(client, "home.redeliverTaskResult", command)).toEqual({ accepted: true });
    expect(await owner.taskResult(task.taskId)).toEqual(consumed);
    expect(current.canonicalSessionEntries().filter(entry => entry.type === "custom_message" && entry.customType === "tron.home-task-result.v1")).toHaveLength(1);
    expect(await readFile(oldPath)).toEqual(sealed);
    evidence.push({ case: "replacement-redelivery-rollover", pending, accepted, consumed: await owner.taskResult(task.taskId), sealedBytesUnchanged: true });
  }, 20_000);

  it("wires Home's real task tool to exact-operation shared steering", async () => {
    const f = await fixture();
    const model = f.faux.getModel();
    await f.registry.homeOwner().configureMemory({ model: { provider: model.provider, id: model.id } });
    let release!: () => void;
    let entered = false;
    const gate = new Promise<void>(resolve => { release = resolve; });
    f.faux.setResponses([async () => { entered = true; await gate; return fauxAssistantMessage([reportCall()], { stopReason: "toolUse" }); }]);
    const run = await dispatch(f);
    const slot = await f.registry.acquire(run.sessionId);
    const home = await f.registry.acquire(f.home.sessionId);
    try {
      await waitFor(() => entered, "worker provider barrier");
      f.faux.setResponses([fauxAssistantMessage([fauxToolCall("task", { action: "steer", taskId: run.taskId, operationId: run.operationId, controllerGeneration: 1, text: "Home tool instruction" })], { stopReason: "toolUse" }), fauxAssistantMessage("shared steering accepted")]);
      await home.prompt("Steer the active task");
      await waitFor(() => !home.isBusy, "Home task tool terminal");
      expect((slot as any).runtime.session.getSteeringMessages()).toEqual(["Home tool instruction"]);
      release(); await run.completion;
      evidence.push({ case: "home-task-tool", steering: "accepted" });
    } finally { release(); await slot.abort("agent").catch(() => {}); await run.completion.catch(() => {}); }
  }, 20_000);

  it("orders Home and maintainer steering in the same lane and refuses stale or post-report work", async () => {
    const f = await fixture();
    let entered = false;
    let release!: () => void;
    let releaseSteer: (() => void) | undefined;
    let firstSteer: Promise<unknown> | undefined;
    let secondSteer: Promise<unknown> | undefined;
    const gate = new Promise<void>(resolve => { release = resolve; });
    f.faux.setResponses([async () => { entered = true; await gate; return fauxAssistantMessage([fauxToolCall("read", { path: "missing" })], { stopReason: "toolUse" }); },
      fauxAssistantMessage([reportCall()], { stopReason: "toolUse" })]);
    const run = await dispatch(f);
    const slot = await f.registry.acquire(run.sessionId);
    try {
      await waitFor(() => entered, "task provider active");
      const control = { taskId: run.taskId, operationId: run.operationId, controllerGeneration: 1 };
      const session = (slot as any).runtime.session;
      const prompt = session.prompt.bind(session);
      let steeringEntered = false;
      const steeringGate = new Promise<void>(resolve => { releaseSteer = resolve; });
      const called: string[] = [];
      vi.spyOn(session, "prompt").mockImplementation(async (text: string, options: unknown) => {
        called.push(text);
        if (text === "Home first") { steeringEntered = true; await steeringGate; }
        return prompt(text, options);
      });
      const first = firstSteer = f.registry.homeOwner().steerTask(f.home.sessionId, { ...control, text: "Home first" });
      void first.catch(() => {});
      await waitFor(() => steeringEntered, "Home steering in session lane");
      const second = secondSteer = slot.prompt("Maintainer second", [], "steer");
      void second.catch(() => {});
      let observationTimer: ReturnType<typeof setTimeout> | undefined;
      try {
        // Observe non-admission while the SDK gate is held, rather than testing
        // before the second command's asynchronous persistence can run.
        const admittedWhileHeld = await Promise.race([second.then(() => true),
          new Promise<false>(resolve => { observationTimer = setTimeout(() => resolve(false), 100); })]);
        expect(admittedWhileHeld).toBe(false);
        expect(called).toEqual(["Home first"]);
      } finally { if (observationTimer) clearTimeout(observationTimer); releaseSteer?.(); }
      await Promise.all([first, second]);
      expect(called).toEqual(["Home first", "Maintainer second"]);
      expect(f.signals.filter(record => record.event === "home.task.control" && record.action === "steer")).toHaveLength(2);
      expect((slot as any).runtime.session.getSteeringMessages()).toEqual(["Home first", "Maintainer second"]);
      await expect(f.registry.homeOwner().steerTask(f.home.sessionId, { ...control, controllerGeneration: 2, text: "stale" })).rejects.toThrow(/stale|changed|conflict/i);
      await expect(slot.steerHomeTask({ ...control, controllerGeneration: 2 }, "stale slot control")).rejects.toThrow(/stale|changed|conflict/i);
      release();
      const result = await run.completion;
      expect(result.terminalEvidence?.outcome).toBe("final");
      const canonicalUser = JSON.stringify(slot.canonicalSessionEntries().filter(entry => entry.type === "message" && entry.message.role === "user"));
      expect(canonicalUser).toContain("Home first");
      expect(canonicalUser.indexOf("Maintainer second")).toBeGreaterThan(canonicalUser.indexOf("Home first"));
      await expect(f.registry.homeOwner().steerTask(f.home.sessionId, { ...control, text: "late" })).rejects.toThrow(/active|stale|settled|terminal/i);
      evidence.push({ case: "shared-control-order", order: ["Home first", "Maintainer second"], staleRefused: true, afterReportRefused: true });
    } finally { releaseSteer?.(); release(); await Promise.allSettled([firstSteer, secondSteer]); await slot.abort("agent").catch(() => {}); await run.completion.catch(() => {}); }
  }, 20_000);

  it.each([
    { owner: "prompt", surface: "taskRPC" },
    { owner: "automatic-compaction", surface: "taskRPC" },
    { owner: "automatic-compaction", surface: "sessionStop" },
  ] as const)("persists exact task Stop outside blocked SDK preflight ($owner/$surface) and reconciles interrupted evidence", async ({ owner, surface }) => {
    const f = await fixture();
    let release!: () => void;
    let entered = false;
    let cancelled = false;
    let providerCalls = 0;
    const gate = new Promise<void>(resolve => { release = resolve; });
    f.faux.setResponses([() => { providerCalls += 1; return fauxAssistantMessage("must not start"); }]);
    const create = OwnedSessionDispatch.prototype.createWorker;
    vi.spyOn(OwnedSessionDispatch.prototype, "createWorker").mockImplementation(async function(cwd, reports) {
      const lease = await create.call(this, cwd, reports);
      const session = (lease.slot as any).runtime.session;
      const prompt = session.prompt.bind(session);
      vi.spyOn(session, "prompt").mockImplementation(async (...args: any[]) => {
        if (owner === "automatic-compaction") (lease.slot as any).onEvent({ type: "compaction_start", reason: "threshold" });
        entered = true; await gate; return prompt(...args);
      });
      const abortCompaction = session.abortCompaction.bind(session);
      vi.spyOn(session, "abortCompaction").mockImplementation(() => {
        if (owner === "automatic-compaction") (lease.slot as any).onEvent({ type: "compaction_end", reason: "threshold", result: undefined, aborted: true, willRetry: false });
        abortCompaction();
      });
      const abort = session.abort.bind(session);
      vi.spyOn(session, "abort").mockImplementation(async () => { cancelled = true; release(); await abort(); });
      return lease;
    });
    const run = await dispatch(f);
    const slot = await f.registry.acquire(run.sessionId);
    try {
      await waitFor(() => entered, "SDK preflight barrier");
      const control = { taskId: run.taskId, operationId: run.operationId, controllerGeneration: 1 };
      await expect(f.registry.homeOwner().stopTask({ ...control, operationId: "stale-operation" })).rejects.toThrow(/changed|stale|conflict/i);
      await expect(slot.stopHomeTask({ ...control, operationId: "stale-operation" })).rejects.toThrow(/changed|stale|conflict/i);
      expect(cancelled).toBe(false);
      const service = new GatewayService({ config: { tronHome: f.tronHome }, sessions: f.registry, home: f.registry.homeOwner(),
        receipts: new CommandReceiptStore(join(f.root, "control-receipts")) } as unknown as GatewayServiceDependencies);
      // A draining transport must keep status/exact Stop available; this is an
      // isolated service flag, never a live Gateway restart.
      (service as any).restartRequested = true;
      const client = { id: "control-terminal", identity: "device:control-test", isLocal: true } as unknown as ClientContext;
      let stopParams: unknown;
      const terminal = { request: async (method: string, params: unknown) => { if (method === "home.stopTask") stopParams = params; return service.invoke(client, method, params); } };
      const output = vi.spyOn(process.stdout, "write").mockImplementation(() => true);
      const stopping = surface === "sessionStop" ? slot.abort("compaction", slot.snapshot().operation!.id)
        : runHomeInput(terminal as any, `/home stop ${run.taskId}`);
      void stopping.catch(() => {});
      await waitFor(() => cancelled, "task Stop bypasses blocked admission lane");
      await stopping;
      if (surface === "taskRPC") expect(output).toHaveBeenCalledWith(expect.stringContaining("Stop joined"));
      output.mockRestore();
      expect(cancelled).toBe(true);
      const result = await run.completion.catch(() => undefined);
      const store = (f.registry.homeOwner() as any).tasks.store as HomeTaskStore;
      expect(await store.read(run.taskId)).toMatchObject({ lifecycle: "terminal", terminalEvidence: { outcome: "interrupted", reason: "stopped-before-conversation" } });
      if (!result) throw new Error("Live Stop did not settle");
      if (surface === "taskRPC") expect(await service.invoke(client, "home.stopTask", stopParams)).toEqual({ accepted: true });
      expect(await f.registry.homeOwner().taskResult(run.taskId)).toEqual(result);
      expect(providerCalls).toBe(0);
      expect(result.stopIntent).toMatchObject({ operationId: run.operationId, controllerGeneration: 1 });
      expect(result.terminalEvidence).toMatchObject({ outcome: "interrupted", reason: "stopped-before-conversation", entryIds: [] });
      expect(result.reportRefs).toBeNull();
      expect(result.wake).toMatchObject({ state: "pending", push: "decided" });
      expect(f.notifications).toHaveLength(1);
      await expect(fileSystem.stat(slot.sessionFile!)).rejects.toMatchObject({ code: "ENOENT" });
      expect(slot.isBusy).toBe(false);
      expect(f.signals).toContainEqual(expect.objectContaining({ event: "home.task.control", action: "stop", disposition: "persisted" }));
      evidence.push({ case: `task-preflight-stop-${owner}-${surface}`, providerCalls, intent: result.stopIntent, evidence: result.terminalEvidence });
    } finally { release(); await slot.abort("agent").catch(() => {}); await run.completion.catch(() => {}); }
  }, 20_000);

  it("refuses steering whose SDK preflight resumes after an immutable report", async () => {
    const f = await fixture();
    let releaseWorker!: () => void;
    let releaseSteer!: () => void;
    let workerEntered = false;
    let steerEntered = false;
    const workerGate = new Promise<void>(resolve => { releaseWorker = resolve; });
    const steerGate = new Promise<void>(resolve => { releaseSteer = resolve; });
    let afterReportCalls = 0;
    f.faux.setResponses([async () => { workerEntered = true; await workerGate; return fauxAssistantMessage([reportCall()], { stopReason: "toolUse" }); },
      () => { afterReportCalls += 1; return fauxAssistantMessage("forbidden successor"); }]);
    const run = await dispatch(f);
    const slot = await f.registry.acquire(run.sessionId);
    const anchor = await fileSystem.open(f.cwd, "r");
    const prototype = Object.getPrototypeOf(anchor); const sync = prototype.sync; await anchor.close();
    let canonicalSynced = false;
    vi.spyOn(prototype, "sync").mockImplementation(async function(this: import("node:fs/promises").FileHandle) {
      const target = slot.sessionFile ? await fileSystem.stat(slot.sessionFile).catch(() => undefined) : undefined;
      const current = await this.stat();
      if (target && current.dev === target.dev && current.ino === target.ino) canonicalSynced = true;
      return sync.call(this);
    });
    let inspectionRequested = false;
    const inspect = f.registry.readLiveTaskEvidence.bind(f.registry);
    vi.spyOn(f.registry, "readLiveTaskEvidence").mockImplementation((...args) => { inspectionRequested = true; return inspect(...args); });
    let steer: Promise<unknown> | undefined;
    try {
      await waitFor(() => workerEntered, "worker report gate");
      const session = (slot as any).runtime.session;
      const prompt = session.prompt.bind(session);
      vi.spyOn(session, "prompt").mockImplementation(async (...args: any[]) => { steerEntered = true; await steerGate; return prompt(...args); });
      steer = slot.prompt("racing maintainer", [], "steer");
      void steer.catch(() => {});
      await waitFor(() => steerEntered, "steer SDK preflight gate");
      releaseWorker();
      await waitFor(() => slot.canonicalSessionEntries().some(entry => entry.type === "custom" && entry.customType === "tron-home-task-report"), "immutable report append");
      await waitFor(() => inspectionRequested, "live settlement queued behind steer");
      // The existing lane still owns SDK preflight/refusal receipt publication.
      // A bounded observation proves durability cannot race that canonical write.
      for (let attempt = 0; attempt < 20; attempt++) {
        await new Promise(resolve => setTimeout(resolve, 5));
        expect(canonicalSynced).toBe(false);
      }
      releaseSteer();
      await expect(steer).rejects.toThrow(/cancel|stopped|outcome|admission/i);
      const result = await run.completion;
      expect(result.terminalEvidence?.outcome).toBe("final");
      expect(canonicalSynced).toBe(true);
      expect(afterReportCalls).toBe(0);
      evidence.push({ case: "report-steer-race", afterReportCalls, serializedCanonicalSync: canonicalSynced });
    } finally { releaseWorker(); releaseSteer(); await steer?.catch(() => {}); await slot.abort("agent").catch(() => {}); await run.completion.catch(() => {}); }
  }, 20_000);

  it("publishes deduplicated live usage before status and retains the same tokens at settlement", async () => {
    const f = await fixture();
    let entered = false;
    let release!: () => void;
    const gate = new Promise<void>(resolve => { release = resolve; });
    f.faux.setResponses([fauxAssistantMessage([fauxToolCall("read", { path: "missing" })], { stopReason: "toolUse", usage: { input: 7, output: 3, cacheRead: 2, cacheWrite: 1 } }),
      async () => { entered = true; await gate; return fauxAssistantMessage([reportCall()], { stopReason: "toolUse" }); }]);
    const run = await dispatch(f);
    const slot = await f.registry.acquire(run.sessionId);
    try {
      await waitFor(() => entered, "second provider turn");
      const entries = slot.canonicalSessionEntries.bind(slot);
      vi.spyOn(slot, "canonicalSessionEntries").mockImplementation(() => { const values = entries(); const usage = values.find(value => value.type === "message" && value.message.role === "assistant"); return usage ? [...values, usage] : values; });
      const one = await f.registry.homeOwner().taskResult(run.taskId);
      const two = await f.registry.homeOwner().taskResult(run.taskId);
      const canonical = entries().find(value => value.type === "message" && value.message.role === "assistant")!;
      const usage = (canonical as any).message.usage;
      expect(one.spend).toMatchObject({ inputTokens: usage.input + usage.cacheRead + usage.cacheWrite, outputTokens: usage.output, knownCostUSD: null, unpriced: true });
      expect(two).toEqual(one);
      const output = vi.spyOn(process.stdout, "write").mockImplementation(() => true);
      const terminal = { request: (_method: string, params: any) => f.registry.homeOwner().taskResult(params.taskId) };
      await runHomeInput(terminal as any, `/home task ${run.taskId}`);
      expect(output).toHaveBeenCalledWith(expect.stringContaining(`${one.spend!.inputTokens} input/cache + ${one.spend!.outputTokens} output tokens; unpriced`));
      output.mockRestore();
      release();
      const final = await run.completion;
      expect(final.spend!.inputTokens).toBeGreaterThanOrEqual(one.spend!.inputTokens);
      expect(final.spend!.outputTokens).toBeGreaterThanOrEqual(one.spend!.outputTokens);
      expect(final.spend!.unpriced).toBe(true);
      evidence.push({ case: "live-spend", live: one.spend, final: final.spend });
    } finally { release(); await slot.abort("agent").catch(() => {}); await run.completion.catch(() => {}); }
  }, 20_000);

  it("reconfirms copied-namespace scopes only through explicit RPC and terminal control", async () => {
    const f = await fixture();
    f.faux.setResponses([fauxAssistantMessage([reportCall()], { stopReason: "toolUse" })]);
    await (await dispatch(f)).completion;
    const namespace = join(f.tronHome, "gateway/home/tasks");
    const copy = join(f.root, "restored-tasks");
    await cp(namespace, copy, { recursive: true, preserveTimestamps: true });
    await rm(namespace, { recursive: true }); await rename(copy, namespace);
    await expect(dispatch(f, "before-confirmation")).rejects.toThrow(/reconfirmation/);
    const service = new GatewayService({ config: { tronHome: f.tronHome }, sessions: f.registry, home: f.registry.homeOwner(),
      receipts: new CommandReceiptStore(join(f.root, "receipts")) } as unknown as GatewayServiceDependencies);
    const client = { id: "terminal-test", identity: "device:task-test", isLocal: true } as unknown as ClientContext;
    await expect(service.invoke(client, "home.reconfirmPermissions", { commandId: "confirm-permissions", unexpected: true })).rejects.toThrow(/unexpected|unknown/i);
    const terminal = { request: (method: string, params: unknown) => service.invoke(client, method, params) };
    const output = vi.spyOn(process.stdout, "write").mockImplementation(() => true);
    expect(await runHomeInput(terminal as any, "/home reconfirm-permissions")).toBe(true);
    expect(output).toHaveBeenCalledWith(expect.stringContaining("reconfirmed"));
    output.mockRestore();
    f.faux.setResponses([fauxAssistantMessage([reportCall("after-confirmation")], { stopReason: "toolUse" })]);
    expect((await (await dispatch(f, "after-confirmation")).completion).terminalEvidence?.outcome).toBe("final");
    evidence.push({ case: "explicit-permission-reconfirmation", refusedBefore: true, admittedAfter: true });
  }, 20_000);
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
    expect(result.terminalEvidence?.outcome).toBe("interrupted");
    expect(result.stopIntent).toMatchObject({ operationId: run.operationId });
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
    const worker = await f.registry.acquire(run.sessionId);
    const path = worker.sessionFile!;
    const original = await readFile(path, "utf8");
    const changed = original.trimEnd().split("\n").map(line => JSON.parse(line));
    changed.find(entry => entry.id === ref.entryId).data.text = "edited evidence";
    try {
      await writeFile(path, changed.map(entry => JSON.stringify(entry)).join("\n") + "\n");
      await expect(f.registry.homeOwner().taskResult("task-one")).rejects.toThrow(/contradictory|changed/);
    } finally { await writeFile(path, original); }
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
    try {
      const before = slot.canonicalSessionEntries().length;
      await expect((slot as any).taskWorker.accept(slot.id, run.operationId,
        { resultId: "late-result", outcome: "final", text: "late report", evidence: [] },
        (data: unknown) => (slot as any).persistCanonicalCustomEntry("tron-home-task-report", data, "late-report"))).rejects.toThrow(/retired/);
      expect(slot.canonicalSessionEntries()).toHaveLength(before);
    } finally { await slot.abort("agent", run.operationId); }
    evidence.push({ case: "deadline-join-failed", injectedFailure: true, outcome: "unknown", lateReportRefused: true, actualStopCleanedUp: true });
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
