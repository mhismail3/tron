import { afterAll, afterEach, describe, expect, it, vi } from "vitest";
import { mkdir, writeFile } from "node:fs/promises";
import { join } from "node:path";
import { setModelQueue, settingsDependencies } from "../../test-support/settings-dependencies.js";
import { fauxAssistantMessage, fauxProvider, fauxToolCall, type AssistantMessage, type Model, type SimpleStreamOptions, type TranscriptContext } from "@earendil-works/pi-ai";
import { OwnedSessionDispatch } from "../sessions/owned-session-dispatch.js";
import { CHAT_SETTINGS_ENTRY, readChatFixedSettings } from "../sessions/chat-settings.js";
import { disposeFixtures, fixture, reportCall, TASK_REASONING_MODEL_ID, TASK_VIRTUAL_MODEL_ID } from "../../test-support/home-task-fixture.js";
import { waitFor } from "../../test-support/wait-for.js";

afterEach(async () => {
  vi.restoreAllMocks();
  await disposeFixtures();
});

const briefEvidence: unknown[] = [];
afterAll(async () => {
  await mkdir("test-results", { recursive: true });
  await writeFile("test-results/home-worker-brief-model.json", JSON.stringify(briefEvidence, null, 2) + "\n");
});

type ObservedRequest = { model: string; reasoning: string | undefined };

const queueOwners = (f: Awaited<ReturnType<typeof fixture>>) =>
  ({ registry: f.registry, agentDir: f.agentDir, tronHome: f.tronHome, trust: f.trust, modelRuntime: f.gateway });

function installSettings(f: Awaited<ReturnType<typeof fixture>>) {
  return settingsDependencies({ ...f, modelRuntime: f.gateway, home: () => f.registry.homeOwner(), registry: f.registry }).settingsModel;
}

function textOf(message: { content: unknown }): string {
  const content = message.content;
  if (typeof content === "string") return content;
  return Array.isArray(content) ? content.map(part => (part as { text?: unknown }).text ?? "").join("") : "";
}

/** The worker's first request carries the admitted prompt; Home's turns never do. */
const isWorkerTurn = (context: TranscriptContext) =>
  context.messages.some(message => message.role === "user" && textOf(message).includes("This is a finite Home task"));

/** One scripted Home turn that delegates once, then answers the refusal or admission.
 * The worker's request is recorded with the model and thinking level it ran on. Faux
 * serves one shared queue, so every response decides its caller from its context. */
function scriptedHome(delegate: Record<string, unknown>, observed: ObservedRequest[], refusals: string[]) {
  return (context: TranscriptContext, options: SimpleStreamOptions | undefined, _state: unknown, model: Model<string>): AssistantMessage => {
    if (isWorkerTurn(context)) {
      observed.push({ model: model.id, reasoning: options?.reasoning });
      return fauxAssistantMessage([reportCall("model-thinking")], { stopReason: "toolUse" });
    }
    const current = context.messages.slice(context.messages.findLastIndex(message => message.role === "user"));
    const result = current.find(message => message.role === "toolResult" && message.toolName === "delegate");
    if (result?.role === "toolResult" && result.isError) {
      refusals.push(textOf(result));
      return fauxAssistantMessage("Refused.");
    }
    return result ? fauxAssistantMessage("Delegated.")
      : fauxAssistantMessage([fauxToolCall("delegate", delegate, { id: "call-delegate" })], { stopReason: "toolUse" });
  };
}

async function delegateThroughHome(f: Awaited<ReturnType<typeof fixture>>, delegate: Record<string, unknown>) {
  const observed: ObservedRequest[] = [];
  const refusals: string[] = [];
  const homeContexts: string[] = [];
  const workerContexts: string[] = [];
  f.faux.setResponses(Array.from({ length: 4 }, () => {
    const respond = scriptedHome(delegate, observed, refusals);
    return (context, options, state, model) => {
      if (isWorkerTurn(context)) workerContexts.push(context.messages.filter(message => message.role === "user").map(textOf).join("\n"));
      else homeContexts.push(JSON.stringify(context));
      return respond(context, options, state, model);
    };
  }));
  await setModelQueue(queueOwners(f), "background", [f.model]);
  const home = await f.registry.acquire(f.home.sessionId);
  await home.prompt("Delegate the finite work");
  await waitFor(() => home.snapshot().configurationBlocker === null, "Home delegation turn");
  return { observed, refusals, homeContexts, workerContexts };
}

const taskIsTerminal = (f: Awaited<ReturnType<typeof fixture>>, taskId: string) =>
  waitFor(async () => (await f.registry.homeOwner().taskStatus(taskId)).lifecycle === "terminal", `task ${taskId} terminal`);

async function refusalOf(attempt: Promise<unknown>): Promise<Error> {
  const refusal = await attempt.then(() => undefined, (error: Error) => error);
  expect(refusal).toBeInstanceOf(Error);
  return refusal as Error;
}
/** The references a refusal names after "Valid models: ", in any order. */
function validModelList(refusal: Error): string[] {
  const listed = refusal.message.split("Valid models: ")[1]?.replace(/\.$/, "").split(", ") ?? [];
  return listed.sort();
}

describe("Home delegation chooses the worker's model and thinking level", () => {
  it("runs the worker's provider request on the delegated model and thinking level", async () => {
    const f = await fixture();
    const { observed } = await delegateThroughHome(f, { taskId: "model-thinking", intent: "Finite work", target: f.cwd,
      model: { provider: f.model.provider, id: TASK_REASONING_MODEL_ID }, thinking: "high", reason: "Reasoning is needed for this task" });
    await taskIsTerminal(f, "model-thinking");
    expect(observed).toEqual([{ model: TASK_REASONING_MODEL_ID, reasoning: "high" }]);
    expect((await f.registry.homeOwner().taskStatus("model-thinking")).workerModel)
      .toEqual({ provider: f.model.provider, id: TASK_REASONING_MODEL_ID });
  });

  it.each([true, false])("keeps explicit eligible child choice authoritative and the queue conditional (explicit=%s)", async explicit => {
    const f = await fixture();
    const first = `${f.model.provider}/${f.model.id}`;
    const chosen = `${f.model.provider}/${TASK_REASONING_MODEL_ID}`;
    await setModelQueue(queueOwners(f), "subagent", [first, chosen]);
    const intent = explicit ? `Use ${chosen} for subagents; do not select the first queue model.` : "Use subagents for the finite lookup.";
    const { workerContexts, refusals } = await delegateThroughHome(f, { taskId: "brief-model", intent, target: f.cwd });
    expect(refusals).toEqual([]);
    await taskIsTerminal(f, "brief-model");
    const task = await f.registry.homeOwner().taskStatus("brief-model");
    briefEvidence.push({ explicit, intent: task.intent.text, providerContext: workerContexts[0] });
    expect(workerContexts).toHaveLength(1);
    const prompt = workerContexts[0]!;
    expect(prompt).toContain(intent);
    expect(prompt).toContain(`${first} (available), ${chosen} (available)`);
    expect(prompt).toContain("Explicit eligible subagent model choices in this brief take precedence over the default queue");
    expect(prompt).toContain("Otherwise, launch subagents with model tron/subagent");
    expect(prompt).toContain("disclose the reason and the chosen fallback");
    expect(prompt).not.toMatch(/\. Launch subagents with model tron\/subagent/u);
  });

  it("resolves typed worker profile fields at delegation and freezes their source on the worker", async () => {
    const f = await fixture();
    const settings = installSettings(f);
    await writeFile(settings.profilePath, JSON.stringify({ modelQueue: { worker: [`${f.model.provider}/${TASK_REASONING_MODEL_ID}`] }, thinking: { worker: "max" } }));
    const { observed } = await delegateThroughHome(f, { taskId: "profile-model", intent: "Finite work", target: f.cwd });
    await taskIsTerminal(f, "profile-model");
    expect(observed).toEqual([{ model: TASK_REASONING_MODEL_ID, reasoning: "high" }]);
    const task = await f.registry.homeOwner().taskStatus("profile-model");
    expect(task.intent.text).toContain("Worker choice: model");
    expect(task.intent.text).toContain("worker queue");
    expect(task.intent.text).toContain("max clamped to high");
    // The delegate tool's details carry the same resolved choice for its detail sheet (#957).
    const home = await f.registry.acquire(f.home.sessionId);
    const admission = home.canonicalSessionEntries().flatMap(entry => entry.type === "message" && entry.message.role === "toolResult"
      && entry.message.toolName === "delegate" ? [entry.message] : [])[0];
    expect(admission?.details).toMatchObject({ taskId: "profile-model", worker: {
      model: `${f.model.provider}/${TASK_REASONING_MODEL_ID}`, thinking: "high", modelSource: "worker queue", thinkingSource: "Home profile",
      note: "max clamped to high", queue: [{ model: `${f.model.provider}/${TASK_REASONING_MODEL_ID}`, available: true }] } });
    const entries = await f.registry.readTaskEvidence(task.sessionId!);
    const settingsEntry = entries.findLast(entry => entry.type === "custom" && entry.customType === CHAT_SETTINGS_ENTRY);
    expect(settingsEntry?.type === "custom" ? settingsEntry.data : undefined).toMatchObject({ fixed: {
      "model.ref[role=chat]": { from: "delegate", value: { provider: f.model.provider, id: TASK_REASONING_MODEL_ID } },
      "model.thinking[role=chat]": { from: "delegate", value: "high" },
    } });
  });

  it("lets an explicit model override only its field while profile thinking remains", async () => {
    const f = await fixture();
    installSettings(f);
    await writeFile(join(f.tronHome, "gateway", "home", "profile.json"), JSON.stringify({ thinking: { worker: "low" } }));
    const { observed } = await delegateThroughHome(f, { taskId: "fieldwise", intent: "Finite work", target: f.cwd,
      model: { provider: f.model.provider, id: TASK_REASONING_MODEL_ID }, reason: "This task needs reasoning" });
    await taskIsTerminal(f, "fieldwise");
    expect(observed).toEqual([{ model: TASK_REASONING_MODEL_ID, reasoning: "low" }]);
  });

  it("starts an explicit model that lacks Home's thinking at the closest supported level, and the brief says so (Q23)", async () => {
    const f = await fixture();
    const home = await f.registry.acquire(f.home.sessionId);
    await home.setModel(f.model.provider, TASK_REASONING_MODEL_ID);
    await home.setThinking("high");
    // Explicit model only: thinking stays same as Home (high), which this model cannot do.
    const { observed, refusals } = await delegateThroughHome(f, { taskId: "explicit-clamp", intent: "Finite work", target: f.cwd,
      model: { provider: f.model.provider, id: f.model.id }, reason: "A lookup needs no reasoning" });
    expect(refusals).toEqual([]);
    await taskIsTerminal(f, "explicit-clamp");
    expect(observed).toEqual([{ model: f.model.id, reasoning: undefined }]);
    const task = await f.registry.homeOwner().taskStatus("explicit-clamp");
    expect(task.intent.text).toContain("Worker choice: model");
    expect(task.intent.text).toContain("high clamped to off");
    expect(readChatFixedSettings(await f.registry.readTaskEvidence(task.sessionId!))["model.thinking[role=chat]"]).toMatchObject({ from: "delegate", value: "off" });
  });

  it("skips an unregistered model and a provider at 95% usage in the worker queue, and tells Home and the worker why", async () => {
    // A second provider whose fresh usage read shows a 97% weekly window; it is never called.
    const usage = { providers: { "usage-full": { baseUrl: "http://127.0.0.1:9/v1", api: "openai-completions", apiKey: "fixture-only",
      models: [{ id: "full", name: "Full", reasoning: false, input: ["text"], contextWindow: 128000, maxTokens: 4096, cost: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0 } }] } } };
    const read = vi.fn(async (_runtime: unknown, provider: string | undefined) => ({ providers: [provider === "usage-full"
      ? { providerId: provider, status: "available" as const, source: "fixture", scope: "account" as const, updatedAt: new Date().toISOString(), retryAt: null, stale: false, message: null,
        windows: [{ id: "weekly", label: "Weekly", usedPercent: 97, used: null, limit: null, remaining: null, unit: null, resetsAt: null, windowSeconds: null }], balances: [] }
      : { providerId: provider!, status: "unsupported" as const, source: null, scope: null, updatedAt: null, retryAt: null, stale: false, message: null, windows: [], balances: [] }] }));
    const f = await fixture(false, false, undefined, false, usage, { providerUsage: { read } });
    const settings = installSettings(f);
    await writeFile(settings.profilePath, JSON.stringify({ modelQueue: { worker: [`${f.model.provider}/removed-model`, "usage-full/full", `${f.model.provider}/${f.model.id}`] } }));
    const { observed } = await delegateThroughHome(f, { taskId: "queue-skips", intent: "Finite work", target: f.cwd });
    await taskIsTerminal(f, "queue-skips");
    expect(observed).toEqual([{ model: f.model.id, reasoning: undefined }]);
    const task = await f.registry.homeOwner().taskStatus("queue-skips");
    expect(task.intent.text).toContain(`${f.model.provider}/removed-model skipped: not registered`);
    expect(task.intent.text).toContain("usage-full/full skipped: Weekly usage 97%");
    const home = await f.registry.acquire(f.home.sessionId);
    const admission = home.canonicalSessionEntries().flatMap(entry => entry.type === "message" && entry.message.role === "toolResult"
      && entry.message.toolName === "delegate" ? [entry.message] : [])[0];
    expect(textOf(admission!)).toContain("Worker models: tron-task-faux/removed-model skipped (not registered); usage-full/full skipped (Weekly usage 97%); tron-task-faux/faux-1 available.");
  });

  it("refuses a delegation whose worker queue has no available model, naming each model and why", async () => {
    const f = await fixture();
    const settings = installSettings(f);
    await writeFile(settings.profilePath, JSON.stringify({ modelQueue: { worker: [`${f.model.provider}/gone-a`, `${f.model.provider}/gone-b`] } }));
    const { refusals } = await delegateThroughHome(f, { taskId: "queue-exhausted", intent: "Finite work", target: f.cwd });
    expect(refusals).toEqual([expect.stringContaining(`All worker models are unavailable: ${f.model.provider}/gone-a — not registered; ${f.model.provider}/gone-b — not registered.`)]);
    await expect(f.registry.homeOwner().taskStatus("queue-exhausted")).rejects.toThrow();
  });

  it("moves a worker to the next queue model on a usage-limit error and retries the same request there", async () => {
    const f = await fixture();
    const settings = installSettings(f);
    await writeFile(settings.profilePath, JSON.stringify({ modelQueue: { worker: [`${f.model.provider}/${f.model.id}`, `${f.model.provider}/${TASK_REASONING_MODEL_ID}`] } }));
    const observed: ObservedRequest[] = [];
    const refusals: string[] = [];
    f.faux.setResponses(Array.from({ length: 6 }, () => (context: TranscriptContext, options: SimpleStreamOptions | undefined, state: unknown, model: Model<string>) => {
      if (isWorkerTurn(context) && model.id === f.model.id) {
        observed.push({ model: model.id, reasoning: options?.reasoning });
        // OpenCode Go's plan limit, as pi-ai reports it: non-retryable, so Pi settles on it.
        return fauxAssistantMessage("", { stopReason: "error", errorMessage: '429 {"type":"error","error":{"type":"GoUsageLimitError","message":"Monthly usage limit reached"}}' });
      }
      return scriptedHome({ taskId: "usage-limit", intent: "Finite work", target: f.cwd }, observed, refusals)(context, options, state, model);
    }));
    await setModelQueue(queueOwners(f), "background", [f.model]);
    const home = await f.registry.acquire(f.home.sessionId);
    await home.prompt("Delegate the finite work");
    await waitFor(() => home.snapshot().configurationBlocker === null, "Home delegation turn");
    expect(refusals).toEqual([]);
    await taskIsTerminal(f, "usage-limit");
    const task = await f.registry.homeOwner().taskStatus("usage-limit");
    expect(task.terminalEvidence?.outcome).toBe("final");
    // The same request ran again, on the next model of the queue.
    expect(observed.map(request => request.model)).toEqual([f.model.id, TASK_REASONING_MODEL_ID]);
    expect(task.workerModel).toEqual({ provider: f.model.provider, id: TASK_REASONING_MODEL_ID });
    const entries = await f.registry.readTaskEvidence(task.sessionId!);
    expect(entries.filter(entry => entry.type === "custom" && entry.customType === "tron.model-queue").map(entry => entry.type === "custom" ? entry.data : undefined))
      .toEqual([{ role: "worker", skipped: `${f.model.provider}/${f.model.id}`, reason: expect.stringContaining("usage-limit error: 429"), next: `${f.model.provider}/${TASK_REASONING_MODEL_ID}` }]);
    // The next delegation skips the model that just hit its limit.
    const queue = await f.registry.modelQueue!.availability("worker");
    expect(queue.models[0]).toMatchObject({ available: false, reason: expect.stringContaining("GoUsageLimitError") });
  });

  it("uses the live Home model for tool and direct Home dispatch while ordinary chats keep their own default", async () => {
    const f = await fixture();
    installSettings(f);
    const home = await f.registry.acquire(f.home.sessionId);
    await home.setModel(f.model.provider, TASK_REASONING_MODEL_ID);
    const { observed } = await delegateThroughHome(f, { taskId: "live-home-model", intent: "Finite work", target: f.cwd });
    await taskIsTerminal(f, "live-home-model");
    expect(observed).toEqual([{ model: TASK_REASONING_MODEL_ID, reasoning: undefined }]);
    const direct = await f.registry.homeOwner().dispatchTask(f.home.sessionId, { taskId: "ordinary-default-control", intent: "Finite work", target: f.cwd });
    await direct.completion;
    const worker = await f.registry.acquire(direct.sessionId);
    expect(worker.snapshot().model).toEqual({ provider: f.model.provider, id: TASK_REASONING_MODEL_ID });
    const ordinary = await f.registry.create(f.cwd);
    expect(ordinary.snapshot().model).toEqual({ provider: f.model.provider, id: f.model.id });
  });

  it("beats the repo default for workers, freezes the first choice, and leaves ordinary chats profile-free", async () => {
    const f = await fixture();
    const settings = installSettings(f);
    await mkdir(join(f.cwd, ".pi"), { recursive: true });
    await writeFile(join(f.cwd, ".pi", "settings.json"), JSON.stringify({ defaultProvider: f.model.provider, defaultModel: f.model.id }));
    const home = await f.registry.acquire(f.home.sessionId);
    await home.setModel(f.model.provider, TASK_REASONING_MODEL_ID);
    await home.setThinking("high");
    const first = await delegateThroughHome(f, { taskId: "before-home-change", intent: "Finite work", target: f.cwd });
    await taskIsTerminal(f, "before-home-change");
    expect(first.observed).toEqual([{ model: TASK_REASONING_MODEL_ID, reasoning: "high" }]);
    const task = await f.registry.homeOwner().taskStatus("before-home-change");
    const worker = await f.registry.acquire(task.sessionId!);
    expect(readChatFixedSettings(await f.registry.readTaskEvidence(task.sessionId!))["model.ref[role=chat]"]).toMatchObject({ via: "home-profile:sameAs:home" });
    await waitFor(() => {
      const context = f.registry.homeOwner().contextStatus();
      return context.available && context.breakdown?.activation.kind === "wake" && !context.activationOpen
        && home.snapshot().configurationBlocker === null;
    }, "first worker wake settled");
    await home.setModel(f.model.provider, f.model.id);
    expect(worker.snapshot().model?.id).toBe(TASK_REASONING_MODEL_ID);
    const second = await delegateThroughHome(f, { taskId: "after-home-change", intent: "Finite work", target: f.cwd });
    await taskIsTerminal(f, "after-home-change");
    expect(second.observed).toEqual([{ model: f.model.id, reasoning: undefined }]);
    const ordinary = await f.registry.create(f.cwd);
    expect(ordinary.snapshot().model?.id).toBe(f.model.id);
    const resolved = await settings.resolve({ kind: "session", sessionId: ordinary.id }, {
      cwd: f.cwd, home: false, chat: ordinary.settingsChatLayer(), modelRuntime: ordinary.modelRuntime,
    });
    expect(resolved.keys.flatMap(key => key.layers).some(layer => layer.layer === "profile")).toBe(false);
  });

  it("defaults a worker to Home's live model and thinking, and tells Home that identity", async () => {
    const f = await fixture();
    const home = await f.registry.acquire(f.home.sessionId);
    await home.setModel(f.model.provider, TASK_REASONING_MODEL_ID);
    await home.setThinking("high");
    const { observed, homeContexts } = await delegateThroughHome(f, { taskId: "default-model", intent: "Finite work", target: f.cwd });
    await taskIsTerminal(f, "default-model");
    expect(observed).toEqual([{ model: TASK_REASONING_MODEL_ID, reasoning: "high" }]);
    expect((await f.registry.homeOwner().taskStatus("default-model")).workerModel)
      .toEqual({ provider: f.model.provider, id: TASK_REASONING_MODEL_ID });
    expect(homeContexts[0]).toContain(`Current Home chat model: ${f.model.provider}/${TASK_REASONING_MODEL_ID}`);
    expect(homeContexts[0]).toContain("Current Home thinking level: high");
  });

  it("accepts thinking alone for Home's current model", async () => {
    const f = await fixture();
    const home = await f.registry.acquire(f.home.sessionId);
    await home.setModel(f.model.provider, TASK_REASONING_MODEL_ID);
    await home.setThinking("high");
    const { observed, refusals } = await delegateThroughHome(f, { taskId: "thinking-only", intent: "Finite work", target: f.cwd, thinking: "low", reason: "Keep this finite task light" });
    expect(refusals).toEqual([]);
    await taskIsTerminal(f, "thinking-only");
    expect(observed).toEqual([{ model: TASK_REASONING_MODEL_ID, reasoning: "low" }]);
  });

  it("distinguishes an unknown task from a changed identity", async () => {
    const f = await fixture();
    await expect(f.registry.homeOwner().taskTool(f.home.sessionId, { action: "status", taskId: "unknown-task" }))
      .rejects.toMatchObject({ code: "not_found", message: expect.stringMatching(/^task status: no task "unknown-task"\./u) });
  });

  it("refuses each invalid choice before any task record or worker session exists", async () => {
    const f = await fixture();
    const owner = f.registry.homeOwner();
    const create = vi.spyOn(f.registry, "create");
    const cases: Array<{ name: string; choice: Record<string, unknown>; reason: string; message: string }> = [
      { name: "unregistered model", choice: { model: { provider: f.model.provider, id: "no-such-model" } },
        reason: "unregistered-model", message: "is not registered" },
      { name: "virtual model", choice: { model: { provider: f.model.provider, id: TASK_VIRTUAL_MODEL_ID } },
        reason: "virtual-model", message: "is virtual" },
      { name: "thinking the non-reasoning default does not support", choice: { model: { provider: f.model.provider, id: f.model.id }, thinking: "high" },
        reason: "unsupported-thinking", message: "does not support thinking level \"high\"" },
      { name: "xhigh on a reasoning model without a mapping", choice: { model: { provider: f.model.provider, id: TASK_REASONING_MODEL_ID }, thinking: "xhigh" },
        reason: "unsupported-thinking", message: "does not support thinking level \"xhigh\"" },
      { name: "thinking unsupported by Home's default model", choice: { thinking: "high" },
        reason: "unsupported-thinking", message: "does not support thinking level" },
    ];
    for (const [index, { name, choice, reason, message }] of cases.entries()) {
      const taskId = `refused-${index}`;
      await expect(owner.dispatchTask(f.home.sessionId, { taskId, intent: "Finite work", target: f.cwd, ...choice }), name)
        .rejects.toMatchObject({ code: "invalid_request", details: { reason }, message: expect.stringContaining(message) });
      expect(await owner.taskStatus(taskId).catch(() => "absent"), name).toBe("absent");
    }
    expect((await owner.taskList({})).items).toEqual([]);
    expect(create, "a refused choice creates no worker session").not.toHaveBeenCalled();
  });

  it("names only fixed, usable models when the named model is unregistered", async () => {
    const f = await fixture();
    const error = await refusalOf(f.registry.homeOwner().dispatchTask(f.home.sessionId, { taskId: "fixed-list", intent: "Finite work", target: f.cwd,
      model: { provider: f.model.provider, id: "no-such-model" } }));
    // The fixture's usable models are the default and reasoning models; its virtual router is usable but never a worker choice.
    expect(validModelList(error)).toEqual([`${f.model.provider}/${f.model.id}`, `${f.model.provider}/${TASK_REASONING_MODEL_ID}`].sort());
  });

  it("refuses a registered model without usable credentials before any task or session exists", async () => {
    const f = await fixture();
    const bulk = fauxProvider({ provider: "tron-task-bulk", models: [{ id: "bulk-0" }] });
    f.gateway.registerNativeProvider(bulk.provider);
    vi.spyOn(f.gateway, "checkAuth").mockImplementation(async provider => provider === "tron-task-bulk" ? undefined : { type: "api_key" });
    const create = vi.spyOn(f.registry, "create");
    await expect(f.registry.homeOwner().dispatchTask(f.home.sessionId, { taskId: "no-credentials", intent: "Finite work", target: f.cwd,
      model: { provider: "tron-task-bulk", id: "bulk-0" } })).rejects.toMatchObject({ code: "invalid_request", details: { reason: "unavailable-model" } });
    expect((await f.registry.homeOwner().taskList({})).items).toEqual([]);
    expect(create).not.toHaveBeenCalled();
  });

  it("lists at most twenty valid models when many are usable", async () => {
    const f = await fixture();
    const bulk = fauxProvider({ provider: "tron-task-bulk", models: Array.from({ length: 22 }, (_, index) => ({ id: `bulk-${index}` })) });
    f.gateway.registerNativeProvider(bulk.provider);
    const listed = validModelList(await refusalOf(f.registry.homeOwner().dispatchTask(f.home.sessionId, { taskId: "bounded-list", intent: "Finite work", target: f.cwd,
      model: { provider: f.model.provider, id: "no-such-model" } })));
    expect(listed).toHaveLength(20);
    for (const reference of listed) {
      const [provider, ...id] = reference.split("/");
      expect(f.gateway.getModel(provider!, id.join("/")), reference).toBeDefined();
    }
  });

  it("returns the refusal to Home as a delegate error and creates no task", async () => {
    const f = await fixture();
    const { refusals } = await delegateThroughHome(f, { taskId: "refused-by-home", intent: "Finite work", target: f.cwd,
      model: { provider: f.model.provider, id: TASK_VIRTUAL_MODEL_ID }, reason: "Testing invalid routing refusal" });
    expect(refusals).toEqual([expect.stringContaining("is virtual")]);
    expect((await f.registry.homeOwner().taskList({})).items).toEqual([]);
  });

  it("shows the worker's chosen model in status while the worker is still running", async () => {
    const f = await fixture();
    let release!: () => void;
    const gate = new Promise<void>(resolve => { release = resolve; });
    f.faux.setResponses([async () => { await gate; return fauxAssistantMessage([reportCall()], { stopReason: "toolUse" }); }]);
    const owner = f.registry.homeOwner();
    try {
      const { completion } = await owner.dispatchTask(f.home.sessionId, { taskId: "live-status", intent: "Finite work", target: f.cwd,
        model: { provider: f.model.provider, id: TASK_REASONING_MODEL_ID }, thinking: "medium" });
      await waitFor(async () => (await owner.taskStatus("live-status")).lifecycle === "active", "live task status");
      expect((await owner.taskStatus("live-status")).workerModel).toEqual({ provider: f.model.provider, id: TASK_REASONING_MODEL_ID });
      release();
      await completion;
    } finally {
      release();
    }
  });

  it("reports no worker model, not an error, when the worker never wrote a conversation", async () => {
    const f = await fixture();
    const create = OwnedSessionDispatch.prototype.createWorker;
    vi.spyOn(OwnedSessionDispatch.prototype, "createWorker").mockImplementation(async function(cwd, reports) {
      const lease = await create.call(this, cwd, reports);
      vi.spyOn((lease.slot as any).runtime.session, "prompt").mockRejectedValue(new Error("preflight refused"));
      return lease;
    });
    const { completion } = await f.registry.homeOwner().dispatchTask(f.home.sessionId, { taskId: "no-conversation", intent: "Finite work", target: f.cwd,
      model: { provider: f.model.provider, id: TASK_REASONING_MODEL_ID }, thinking: "low" });
    await expect(completion).resolves.toMatchObject({ lifecycle: "terminal", terminalEvidence: { reason: "evidence-unavailable" } });
    vi.restoreAllMocks();
    const cold = await f.restart();
    await expect(cold.homeOwner().taskStatus("no-conversation")).resolves.toMatchObject({ lifecycle: "terminal", workerModel: null });
  });

  it("keeps the worker's chosen model in status after it settles and the Gateway restarts", async () => {
    const f = await fixture();
    f.faux.setResponses([fauxAssistantMessage([reportCall("settled-model")], { stopReason: "toolUse" })]);
    const { completion } = await f.registry.homeOwner().dispatchTask(f.home.sessionId, { taskId: "settled-model", intent: "Finite work", target: f.cwd,
      model: { provider: f.model.provider, id: TASK_REASONING_MODEL_ID }, thinking: "low" });
    await completion;
    const cold = await f.restart();
    expect((await cold.homeOwner().taskStatus("settled-model")).workerModel)
      .toEqual({ provider: f.model.provider, id: TASK_REASONING_MODEL_ID });
  });
});

/**
 * The Home profile's task budget (settings-model.md 6.1) at the real dispatcher,
 * worker runtime and canonical transcript: tokens are the record's own spend
 * projection, the budget is fixed at start, a lower applies live at the next turn
 * boundary, a raise never reaches a running task, and no turn runs after the stop.
 */
describe("Background model queue", () => {
  it("summarizes Home memory on the next background model after a usage-limit error, and skips the limited model afterward", async () => {
    const f = await fixture(false, false, undefined, false, undefined, { queueSummarizer: true });
    installSettings(f);
    await setModelQueue(queueOwners(f), "background", [f.model, `${f.model.provider}/${TASK_REASONING_MODEL_ID}`]);
    const summaries: string[] = [];
    f.faux.setResponses(Array.from({ length: 40 }, () => (_context: TranscriptContext, options: SimpleStreamOptions | undefined, _state: unknown, model: Model<string>) => {
      // The memory compactor's calls carry its cache key; Home's own turns do not.
      if (options?.sessionId?.startsWith("tron-episodic:")) {
        summaries.push(model.id);
        return model.id === f.model.id
          ? fauxAssistantMessage("", { stopReason: "error", errorMessage: "429 You have hit your ChatGPT usage limit (usage_limit_reached). Try again in 3 days." })
          : fauxAssistantMessage("A short summary of the turn.");
      }
      return fauxAssistantMessage("Home answered.");
    }));
    const home = await f.registry.acquire(f.home.sessionId);
    // A message over the memory's node size is summarized; a short one is kept verbatim.
    await home.prompt(`Remember this first turn: ${"first detail ".repeat(200)}`);
    await waitFor(() => home.snapshot().configurationBlocker === null && summaries.includes(TASK_REASONING_MODEL_ID), "a summary on the next model");
    await home.prompt(`Remember this second turn: ${"second detail ".repeat(200)}`);
    await waitFor(() => home.snapshot().configurationBlocker === null && summaries.filter(id => id === TASK_REASONING_MODEL_ID).length >= 2, "later summaries");
    // One failed request on the limited model; every later summary went straight to the next one.
    expect(summaries[0]).toBe(f.model.id);
    expect(summaries.filter(id => id === f.model.id)).toHaveLength(1);
    expect((await f.registry.homeOwner().memoryStatus()).blocked).toBeUndefined();
  });
});

describe("Home task budget", () => {
  const ui = { actor: { kind: "ui" as const, id: "device:phone" } };
  const turn = (output: number, id: string) => fauxAssistantMessage([fauxToolCall("read", { path: "missing" }, { id })],
    { stopReason: "toolUse", usage: { input: 2, output, cacheRead: 0, cacheWrite: 0 } } as never);
  const install = (f: Awaited<ReturnType<typeof fixture>>) =>
    settingsDependencies({ ...f, modelRuntime: f.gateway, home: () => f.registry.homeOwner(), registry: f.registry }).settingsChanges;
  const setBudget = (changes: ReturnType<typeof install>, value: Record<string, number> | undefined, context: Parameters<ReturnType<typeof install>["change"]>[2] = ui) =>
    changes.change({ kind: "home" }, [{ key: "permissions.budget.task", layer: "profile", op: value ? "set" : "unset", ...(value ? { value } : {}) }], context);

  it("stops a task at the turn boundary that reaches its budget: limited, budget, no further model request", async () => {
    const f = await fixture();
    const changes = install(f);
    expect((await setBudget(changes, { outputTokens: 10 })).status).toBe("applied");
    let calls = 0;
    f.faux.setResponses([() => { calls++; return turn(6, "one"); }, () => { calls++; return turn(6, "two"); },
      () => { calls++; return fauxAssistantMessage("must never be requested"); }]);
    const { completion } = await f.registry.homeOwner().dispatchTask(f.home.sessionId, { taskId: "budgeted", intent: "Finite work", target: f.cwd });
    const task = await completion;
    expect(task).toMatchObject({ budget: { outputTokens: 10 }, spend: { outputTokens: 12 },
      terminalEvidence: { outcome: "limited", reason: "budget" } });
    expect(calls).toBe(2);
    // Negative control: the same work without a budget runs to its report.
    await setBudget(changes, undefined);
    f.faux.setResponses([turn(6, "three"), turn(6, "four"), fauxAssistantMessage([reportCall("unbudgeted")], { stopReason: "toolUse" })]);
    const free = await (await f.registry.homeOwner().dispatchTask(f.home.sessionId, { taskId: "unbudgeted", intent: "Finite work", target: f.cwd })).completion;
    expect(free.budget).toBeUndefined();
    expect(free.terminalEvidence).toMatchObject({ outcome: "final", reason: "explicit-report" });
  });

  it("applies a lowered budget at the next boundary, never a raised one, and gates Home's raise for approval", async () => {
    const f = await fixture();
    const changes = install(f);
    await setBudget(changes, { outputTokens: 100 });
    let entered = false;
    let release!: () => void;
    let gate = new Promise<void>(resolve => { release = resolve; });
    let calls = 0;
    f.faux.setResponses([() => { calls++; return turn(6, "a"); }, async () => { calls++; entered = true; await gate; return turn(6, "b"); },
      () => { calls++; return fauxAssistantMessage("must never be requested"); }]);
    const lowered = await f.registry.homeOwner().dispatchTask(f.home.sessionId, { taskId: "lowered", intent: "Finite work", target: f.cwd });
    await waitFor(() => entered, "second worker turn");
    // Lowering narrows: the maintainer's tap applies quietly and reaches the running task.
    expect((await setBudget(changes, { outputTokens: 5 })).status).toBe("applied");
    release();
    expect(await lowered.completion).toMatchObject({ budget: { outputTokens: 100 }, terminalEvidence: { outcome: "limited", reason: "budget" } });
    expect(calls).toBe(2);

    // Home asking to raise it widens spending: it waits for the maintainer's tap.
    const held = await setBudget(changes, { outputTokens: 1_000 }, { actor: { kind: "home", id: "home" }, reason: "Longer research tasks" });
    expect(held).toMatchObject({ status: "pending", tier: "approve" });

    // A raise after start never reaches the running task: it still stops at its start budget.
    entered = false; calls = 0;
    gate = new Promise<void>(resolve => { release = resolve; });
    f.faux.setResponses([async () => { calls++; entered = true; await gate; return turn(6, "c"); }, () => { calls++; return turn(6, "d"); },
      () => { calls++; return fauxAssistantMessage("must never be requested"); }]);
    const raised = await f.registry.homeOwner().dispatchTask(f.home.sessionId, { taskId: "raised", intent: "Finite work", target: f.cwd });
    await waitFor(() => entered, "first worker turn");
    expect((await setBudget(changes, { outputTokens: 1_000 })).status).toBe("applied");
    release();
    expect(await raised.completion).toMatchObject({ budget: { outputTokens: 5 }, terminalEvidence: { outcome: "limited", reason: "budget" } });
    expect(calls).toBe(1);
  });
});
