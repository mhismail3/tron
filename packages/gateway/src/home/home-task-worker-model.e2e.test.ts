import { afterEach, describe, expect, it, vi } from "vitest";
import { mkdir, writeFile } from "node:fs/promises";
import { join } from "node:path";
import { settingsDependencies } from "../../test-support/settings-dependencies.js";
import { fauxAssistantMessage, fauxProvider, fauxToolCall, type AssistantMessage, type Model, type SimpleStreamOptions, type TranscriptContext } from "@earendil-works/pi-ai";
import { OwnedSessionDispatch } from "../sessions/owned-session-dispatch.js";
import { CHAT_SETTINGS_ENTRY, readChatFixedSettings } from "../sessions/chat-settings.js";
import { disposeFixtures, fixture, reportCall, TASK_REASONING_MODEL_ID, TASK_VIRTUAL_MODEL_ID } from "../../test-support/home-task-fixture.js";
import { waitFor } from "../../test-support/wait-for.js";

afterEach(async () => {
  vi.restoreAllMocks();
  await disposeFixtures();
});

type ObservedRequest = { model: string; reasoning: string | undefined };

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
  f.faux.setResponses(Array.from({ length: 4 }, () => {
    const respond = scriptedHome(delegate, observed, refusals);
    return (context, options, state, model) => {
      if (!isWorkerTurn(context)) homeContexts.push(JSON.stringify(context));
      return respond(context, options, state, model);
    };
  }));
  await f.registry.homeOwner().configureMemory({ model: { provider: f.model.provider, id: f.model.id } });
  const home = await f.registry.acquire(f.home.sessionId);
  await home.prompt("Delegate the finite work");
  await waitFor(() => home.snapshot().configurationBlocker === null, "Home delegation turn");
  return { observed, refusals, homeContexts };
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

  it("resolves typed worker profile fields at delegation and freezes their source on the worker", async () => {
    const f = await fixture();
    const settings = installSettings(f);
    await writeFile(settings.profilePath, JSON.stringify({ model: { worker: { provider: f.model.provider, id: TASK_REASONING_MODEL_ID } }, thinking: { worker: "max" } }));
    const { observed } = await delegateThroughHome(f, { taskId: "profile-model", intent: "Finite work", target: f.cwd });
    await taskIsTerminal(f, "profile-model");
    expect(observed).toEqual([{ model: TASK_REASONING_MODEL_ID, reasoning: "high" }]);
    const task = await f.registry.homeOwner().taskStatus("profile-model");
    expect(task.intent.text).toContain("Worker choice: model");
    expect(task.intent.text).toContain("Home profile");
    expect(task.intent.text).toContain("max clamped to high");
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

  it("clamps profile thinking to the selected model and records an unavailable profile model fallback", async () => {
    const f = await fixture();
    const settings = installSettings(f);
    await writeFile(settings.profilePath, JSON.stringify({
      model: { worker: { provider: f.model.provider, id: "removed-profile-model" } }, thinking: { worker: "max" },
    }));
    const { observed } = await delegateThroughHome(f, { taskId: "profile-fallback", intent: "Finite work", target: f.cwd });
    await taskIsTerminal(f, "profile-fallback");
    expect(observed).toEqual([{ model: f.model.id, reasoning: undefined }]);
    const task = await f.registry.homeOwner().taskStatus("profile-fallback");
    expect(task.intent.text).toContain("unavailable; worker default used");
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

  it("falls back from an unavailable same-as-Home model without losing explicit thinking", async () => {
    const f = await fixture();
    const settings = installSettings(f);
    const home = await f.registry.acquire(f.home.sessionId);
    await home.setModel(f.model.provider, TASK_REASONING_MODEL_ID);
    await home.setThinking("high");
    // Fault-inject admission's credential loss while the real Home/worker
    // runtimes and provider requests remain active. This must not become an
    // explicit-choice refusal or discard the independent thinking field.
    vi.spyOn(f.gateway, "checkAuth").mockResolvedValue(undefined);
    const { observed, refusals } = await delegateThroughHome(f, { taskId: "same-home-fallback", intent: "Finite work", target: f.cwd,
      thinking: "high", reason: "Use deliberate reasoning where supported" });
    expect(refusals).toEqual([]);
    await taskIsTerminal(f, "same-home-fallback");
    expect(observed).toEqual([{ model: f.model.id, reasoning: undefined }]);
    const task = await f.registry.homeOwner().taskStatus("same-home-fallback");
    expect(task.intent.text).toContain("unavailable-model");
    const worker = await f.registry.acquire(task.sessionId!);
    const resolved = await settings.resolve({ kind: "session", sessionId: worker.id }, {
      cwd: f.cwd, home: false, chat: worker.settingsChatLayer(), modelRuntime: worker.modelRuntime,
    });
    expect(resolved.keys.find(key => key.key === "model.ref[role=chat]")?.badges).toContainEqual(expect.objectContaining({
      label: expect.stringContaining("From Home at start: worker default"), detail: expect.stringContaining("unavailable-model"),
    }));
    expect(worker.settingsChatLayer().fixed?.["model.thinking[role=chat]"]).toMatchObject({ value: "off", via: "home-explicit", reason: expect.stringContaining("high clamped to off") });
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
      .rejects.toMatchObject({ code: "not_found", message: "No task with this id" });
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
    await expect(completion).rejects.toThrow("Task canonical evidence is unavailable");
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
