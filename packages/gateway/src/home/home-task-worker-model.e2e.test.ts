import { afterEach, describe, expect, it, vi } from "vitest";
import { fauxAssistantMessage, fauxProvider, fauxToolCall, type AssistantMessage, type Model, type SimpleStreamOptions, type TranscriptContext } from "@earendil-works/pi-ai";
import { OwnedSessionDispatch } from "../sessions/owned-session-dispatch.js";
import { disposeFixtures, fixture, reportCall, TASK_REASONING_MODEL_ID, TASK_VIRTUAL_MODEL_ID } from "../../test-support/home-task-fixture.js";
import { waitFor } from "../../test-support/wait-for.js";

afterEach(async () => {
  vi.restoreAllMocks();
  await disposeFixtures();
});

type ObservedRequest = { model: string; reasoning: string | undefined };

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
    const result = context.messages.find(message => message.role === "toolResult" && message.toolName === "delegate");
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
  f.faux.setResponses(Array.from({ length: 4 }, () => scriptedHome(delegate, observed, refusals)));
  await f.registry.homeOwner().configureMemory({ model: { provider: f.model.provider, id: f.model.id } });
  const home = await f.registry.acquire(f.home.sessionId);
  await home.prompt("Delegate the finite work");
  await waitFor(() => home.snapshot().configurationBlocker === null, "Home delegation turn");
  return { observed, refusals };
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
      model: { provider: f.model.provider, id: TASK_REASONING_MODEL_ID }, thinking: "high" });
    await taskIsTerminal(f, "model-thinking");
    expect(observed).toEqual([{ model: TASK_REASONING_MODEL_ID, reasoning: "high" }]);
    expect((await f.registry.homeOwner().taskStatus("model-thinking")).workerModel)
      .toEqual({ provider: f.model.provider, id: TASK_REASONING_MODEL_ID });
  });

  it("keeps the Gateway default model when the delegation names none", async () => {
    const f = await fixture();
    const { observed } = await delegateThroughHome(f, { taskId: "default-model", intent: "Finite work", target: f.cwd });
    await taskIsTerminal(f, "default-model");
    expect(observed).toEqual([{ model: f.model.id, reasoning: undefined }]);
    expect((await f.registry.homeOwner().taskStatus("default-model")).workerModel)
      .toEqual({ provider: f.model.provider, id: f.model.id });
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
      { name: "thinking without a model", choice: { thinking: "high" },
        reason: "thinking-requires-model", message: "thinking needs a model" },
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
      model: { provider: f.model.provider, id: TASK_VIRTUAL_MODEL_ID } });
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
