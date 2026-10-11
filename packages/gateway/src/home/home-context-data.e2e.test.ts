import { basename } from "node:path";
import { fauxAssistantMessage, fauxToolCall, type AssistantMessage } from "@earendil-works/pi-ai";
import { afterEach, describe, expect, it, vi } from "vitest";
import { disposeFixtures, dispatch, fixture, reportCall, TASK_REASONING_MODEL_ID } from "../../test-support/home-task-fixture.js";
import { waitFor } from "../../test-support/wait-for.js";
import type { HomeContextBreakdown } from "../protocol/types.js";
import { KnowledgeObservationService } from "../knowledge/knowledge-observation.js";
import { KnowledgeService } from "../knowledge/knowledge-service.js";
import { KnowledgeStore } from "../knowledge/knowledge-store.js";
import { admitHomeMemoryPage } from "./home-memory-browser.js";
import { homeChapterObservationExcluded } from "./home-owner.js";

afterEach(async () => {
  vi.restoreAllMocks();
  await disposeFixtures();
});

type Fixture = Awaited<ReturnType<typeof fixture>>;

const idle = (home: { snapshot(): { configurationBlocker: unknown; operation?: unknown } }) =>
  home.snapshot().configurationBlocker === null && home.snapshot().operation === undefined;

async function configure(f: Fixture): Promise<void> {
  const model = f.faux.getModel();
  await f.registry.homeOwner().configureMemory({ model: { provider: model.provider, id: model.id } });
}

/** The breakdown of the last request the current Home activation prepared. */
function breakdownOf(f: Fixture): HomeContextBreakdown & { effectiveTokens: number } {
  const context = f.registry.homeOwner().contextStatus();
  if (!context.available || !context.breakdown) throw new Error("no request breakdown");
  return context.breakdown;
}

const sectionOf = (breakdown: HomeContextBreakdown, id: string) => {
  const section = breakdown.sections.find(candidate => candidate.id === id);
  if (!section) throw new Error(`no ${id} section`);
  return section;
};

/** Home and its worker share one provider. Each request takes the next reply of its own side. */
function scriptedRequests(f: Fixture, home: AssistantMessage[], worker: AssistantMessage[]): void {
  f.faux.setResponses(Array.from({ length: home.length + worker.length + 4 }, () => (context: { messages: Array<{ role: string; content?: unknown }> }) => {
    const system = context.messages.filter(message => message.role === "system").map(message => String(message.content)).join("\n");
    const queue = system.includes("## Tron Home") ? home : worker;
    return queue.shift() ?? fauxAssistantMessage("unexpected request");
  }));
}

/**
 * A memory read the background summarizer can move: the client contract is to reload, so the
 * test retries exactly that conflict until the memory is still.
 */
function readMemory<T>(read: () => Promise<T>): Promise<T> {
  return waitFor(async () => {
    try { return await read(); }
    catch (error) {
      if ((error as { details?: { reason?: unknown } }).details?.reason === "home-memory-revision-changed") return undefined;
      throw error;
    }
  }, "memory read settled");
}

function gate() {
  let open!: () => void;
  const wait = new Promise<void>(resolve => { open = resolve; });
  return { wait, open };
}

describe("Home request breakdown (home.context)", () => {
  it("reports a user activation's last request by section, and the sections sum to its effective size", async () => {
    const f = await fixture();
    await configure(f);
    const home = await f.registry.acquire(f.home.sessionId);
    f.faux.setResponses([
      fauxAssistantMessage([fauxToolCall("memory_search", { query: "earlier" }, { id: "call-search" })], { stopReason: "toolUse" }),
      fauxAssistantMessage("first reply"),
    ]);
    await home.prompt("first input");
    await waitFor(() => idle(home), "activation settled");

    const context = f.registry.homeOwner().contextStatus();
    expect(context).toMatchObject({ available: true, activationOpen: false, breakdown: { activation: { state: "settled", kind: "user" } } });
    const breakdown = breakdownOf(f);
    expect(breakdown.sections.map(section => section.id)).toEqual(["instructions", "profile", "memory", "chapter", "results", "input"]);
    // The sections are the request's whole effective size, and the top-level size is the same number.
    expect(breakdown.sections.reduce((total, section) => total + section.tokens, 0)).toBe(breakdown.effectiveTokens);
    expect(breakdown.effectiveTokens).toBe((context as { effectiveTokens: number }).effectiveTokens);
    expect(sectionOf(breakdown, "instructions").tokens).toBeGreaterThan(0);
    expect(sectionOf(breakdown, "input").tokens).toBeGreaterThan(0);
    // The last request carries the tool call and its result: two chapter entries, and no result.
    expect(sectionOf(breakdown, "chapter").count).toBe(2);
    expect(sectionOf(breakdown, "results").count).toBe(0);
    // This fixture has no Knowledge service, so no profile note is listed.
    expect(sectionOf(breakdown, "profile").count).toBe(0);
  }, 30_000);

  it("counts the other results a wake delivered, and treats the trigger result as the input", async () => {
    const f = await fixture();
    await configure(f);
    const hold = gate();
    f.faux.setResponses([
      async () => { await hold.wait; return fauxAssistantMessage("user reply"); },
      fauxAssistantMessage([reportCall("ra", "Result A")], { stopReason: "toolUse" }),
      fauxAssistantMessage([reportCall("rb", "Result B")], { stopReason: "toolUse" }),
      fauxAssistantMessage("Wake reply for both"),
    ]);
    const home = await f.registry.acquire(f.home.sessionId);
    const turn = home.prompt("hello");
    await waitFor(() => f.faux.state.callCount >= 1, "user turn request");
    const a = await dispatch(f, "task-a");
    const b = await dispatch(f, "task-b");
    await a.completion; await b.completion;
    hold.open();
    await turn;
    await waitFor(() => idle(home) && breakdownOf(f).activation.kind === "wake", "wake settled");

    const breakdown = breakdownOf(f);
    expect(breakdown.activation).toMatchObject({ state: "settled", kind: "wake" });
    // Result A is delivered as context; result B wakes Home, so it is the input.
    expect(sectionOf(breakdown, "results").count).toBe(1);
    expect(sectionOf(breakdown, "results").tokens).toBeGreaterThan(0);
    expect(sectionOf(breakdown, "input").tokens).toBeGreaterThan(0);
    expect(breakdown.sections.reduce((total, section) => total + section.tokens, 0)).toBe(breakdown.effectiveTokens);
  }, 30_000);
});

describe("Home learned profile in the breakdown", () => {
  it("counts the active profile notes the section lists, from the next activation on", async () => {
    const f = await fixture();
    await configure(f);
    // A conversation file exists only after its first message, which a cold registry needs to find Home.
    const greeted = await f.registry.acquire(f.home.sessionId);
    f.faux.setResponses([fauxAssistantMessage("Hello.")]);
    await greeted.prompt("Hello");
    await waitFor(() => idle(greeted), "greeting settled");
    // A runtime captures Knowledge when it is built, so the Gateway restarts over the same record with
    // Knowledge installed first, as gateway-main does, and Home's runtime is built after it.
    const registry = await f.restartToReadiness();
    f.registry = registry;
    const store = new KnowledgeStore(registry.knowledgeWorkspace(), () => {});
    registry.setKnowledgeService(new KnowledgeService(store, new KnowledgeObservationService(store, undefined, undefined, undefined,
      homeChapterObservationExcluded(() => registry.homeOwner()))));
    await registry.catalog("all");
    const home = await registry.acquire(f.home.sessionId);
    // The profile section is read once per activation, so the note is learned in one activation and counted in the next.
    f.faux.setResponses([
      fauxAssistantMessage([fauxToolCall("profile", { action: "learn", kind: "preference", text: "I prefer short replies." }, { id: "call-learn" })], { stopReason: "toolUse" }),
      fauxAssistantMessage("Saved."),
      fauxAssistantMessage("Short reply."),
    ]);
    await home.prompt("Please remember: I prefer short replies.");
    await waitFor(() => idle(home), "learning activation settled");
    expect(sectionOf(breakdownOf(f), "profile").count).toBe(0);
    await home.prompt("Next question");
    await waitFor(() => idle(home), "next activation settled");
    expect(sectionOf(breakdownOf(f), "profile").count).toBe(1);
  }, 60_000);
});

describe("Home chapters, task names and memory pages", () => {
  it("names the delegated worker, lists the task by that name, and reports the chapter's contents and topics", async () => {
    const f = await fixture();
    await configure(f);
    const owner = f.registry.homeOwner();
    const home = await f.registry.acquire(f.home.sessionId);
    scriptedRequests(f, [
      fauxAssistantMessage([fauxToolCall("delegate", { taskId: "task-titled", title: "Count the chapter", intent: "Finite work", target: f.cwd }, { id: "call-delegate" })], { stopReason: "toolUse" }),
      fauxAssistantMessage("Delegated; the report will wake me."),
      fauxAssistantMessage("Wake reply with the report."),
    ], [reportCall("titled-report", "Titled result")]);
    await home.prompt("Delegate the count");
    await waitFor(async () => (await owner.taskList({})).items.some(item => item.taskId === "task-titled"), "task admitted");
    // An early read caches the chapter's counts, so the read after the wake must extend them, not repeat them.
    await owner.chapterList();
    await waitFor(async () => (await owner.taskResult("task-titled")).wake?.state === "acknowledged", "wake acknowledged");
    await waitFor(() => idle(home), "wake settled");

    const task = await owner.taskResult("task-titled");
    expect(task.sessionId).toBeTruthy();
    const worker = await f.registry.acquire(task.sessionId!);
    expect(worker.snapshot().name).toBe("Count the chapter");

    const status = await owner.taskStatus("task-titled");
    expect(status).toMatchObject({ title: "Count the chapter", project: basename(f.cwd), sessionId: task.sessionId });
    const list = await owner.taskList({});
    expect(list.items[0]).toMatchObject({ taskId: "task-titled", title: "Count the chapter", project: basename(f.cwd), sessionId: task.sessionId });
    expect(list.counts).toEqual({ active: 0, finished: 1 });

    // One user message, Home's delegated reply and its wake reply (the tool-call message is not a reply), one delegation.
    const chapter = (await owner.chapterList()).chapters[0]!;
    expect(chapter.contents).toMatchObject({ userMessages: 1, homeReplies: 2, tasksDelegated: 1 });
    expect(chapter.contents?.firstAt).toBeTruthy();
    expect(chapter.contents?.lastAt).toBeTruthy();
    // Memory summaries are built in the background; the chapter's topics appear once they exist.
    await waitFor(async () => ((await owner.chapterList()).chapters[0]?.contents?.topics.length ?? 0) > 0, "chapter topics");
    const topics = (await owner.chapterList()).chapters[0]!.contents!.topics;
    expect(topics.length).toBeLessThanOrEqual(5);
    expect(topics.every(topic => [...topic].length <= 120)).toBe(true);
  }, 60_000);

  it("titles an undelegated-name task by its brief's first line, with its project and worker", async () => {
    const f = await fixture();
    await configure(f);
    const owner = f.registry.homeOwner();
    f.faux.setResponses([reportCall("plain-report", "Plain result"), fauxAssistantMessage("Plain wake reply")]);
    const run = await dispatch(f, "task-plain");
    await run.completion;
    await waitFor(async () => (await owner.taskResult("task-plain")).wake?.state === "acknowledged", "plain wake acknowledged");
    const list = await owner.taskList({});
    expect(list.items[0]).toMatchObject({ taskId: "task-plain", title: "Finite work", project: basename(f.cwd), sessionId: run.sessionId });
  }, 60_000);

  it("refuses a delegated title that is blank or longer than 80 characters, and creates no task", async () => {
    const f = await fixture();
    await configure(f);
    const owner = f.registry.homeOwner();
    await expect(owner.dispatchTask(f.home.sessionId, { taskId: "task-long-title", intent: "Finite work", target: f.cwd, title: "t".repeat(81) }))
      .rejects.toMatchObject({ code: "invalid_request", message: "Invalid task title" });
    await expect(owner.dispatchTask(f.home.sessionId, { taskId: "task-blank-title", intent: "Finite work", target: f.cwd, title: "   " }))
      .rejects.toMatchObject({ code: "invalid_request", message: "Invalid task title" });
    // Refused before any namespace or record exists: the list of an uninitialized namespace is empty.
    expect(await owner.taskList({})).toEqual({ items: [], counts: { active: 0, finished: 0 } });
  }, 30_000);

  it("pages one chapter's memory rows when a sessionId names it, and refuses a session that is not a chapter", async () => {
    const f = await fixture();
    await configure(f);
    const owner = f.registry.homeOwner();
    const first = f.home.sessionId;
    const home = await f.registry.acquire(first);
    f.faux.setResponses([fauxAssistantMessage("first chapter reply")]);
    await home.prompt("first chapter input");
    await waitFor(() => idle(home), "first chapter settled");
    // Seal the first chapter at its soft boundary, then materialize its successor with one prompt.
    const metrics = vi.spyOn((owner as unknown as { options: { sessions: { chapterMetrics: unknown } } }).options.sessions as never, "chapterMetrics")
      .mockResolvedValue({ bytes: 25 * 1024 * 1024, entries: 10, quiescent: true } as never);
    await owner.chapterQuiescent(first);
    metrics.mockRestore();
    const successor = (await owner.chapterList()).chapters.find(chapter => chapter.state === "reserved")!.sessionId;
    await f.registry.materializeReservedHome(successor);
    f.faux.setResponses([fauxAssistantMessage("second chapter reply")]);
    const next = await f.registry.acquire(successor);
    await next.prompt("second chapter input");
    await waitFor(() => idle(next), "second chapter settled");

    const all = await readMemory(() => owner.memoryPage({ limit: 50 }));
    const onlyFirst = await readMemory(() => owner.memoryPage({ limit: 50, sessionId: first }));
    const onlySecond = await readMemory(() => owner.memoryPage({ limit: 50, sessionId: successor }));
    expect(onlyFirst.items.length).toBeGreaterThan(0);
    expect(onlySecond.items.length).toBeGreaterThan(0);
    expect(onlyFirst.items.every(item => item.evidence.sessionId === first)).toBe(true);
    expect(onlySecond.items.every(item => item.evidence.sessionId === successor)).toBe(true);
    expect(onlyFirst.totalItems + onlySecond.totalItems).toBe(all.totalItems);

    // A filtered page continues through its own rows, one row at a time, and no other chapter's row appears.
    // A moved revision refuses a continuation, so the client reloads page one: the whole walk restarts.
    const walked = await readMemory(async () => {
      const rows: string[] = [];
      let cursor: string | undefined;
      do {
        const page = await owner.memoryPage(admitHomeMemoryPage({ limit: 1, sessionId: successor, ...(cursor ? { cursor } : {}) }));
        rows.push(...page.items.map(item => item.evidence.entryId));
        cursor = page.nextCursor;
      } while (cursor);
      return rows;
    });
    expect(walked).toEqual(onlySecond.items.map(item => item.evidence.entryId));

    await expect(owner.memoryPage({ limit: 50, sessionId: "not-a-chapter" })).rejects.toMatchObject({ code: "not_found" });
  }, 60_000);
});

describe("Home task counts", () => {
  it("counts every task exactly, active and finished, whatever the page cap", async () => {
    const f = await fixture();
    await configure(f);
    const owner = f.registry.homeOwner();
    const hold = gate();
    const home: AssistantMessage[] = Array.from({ length: 6 }, (_, index) => fauxAssistantMessage(`wake ${index}`));
    // Worker requests take their replies in order; the third waits until the gate opens, so it stays active.
    const worker: Array<AssistantMessage | (() => Promise<AssistantMessage>)> = [
      fauxAssistantMessage([reportCall("count-one", "One")], { stopReason: "toolUse" }),
      fauxAssistantMessage([reportCall("count-two", "Two")], { stopReason: "toolUse" }),
      async () => { await hold.wait; return fauxAssistantMessage([reportCall("count-three", "Three")], { stopReason: "toolUse" }); },
    ];
    f.faux.setResponses(Array.from({ length: 16 }, () => (context: { messages: Array<{ role: string; content?: unknown }> }) => {
      const system = context.messages.filter(message => message.role === "system").map(message => String(message.content)).join("\n");
      if (system.includes("## Tron Home")) return home.shift() ?? fauxAssistantMessage("unexpected Home request");
      const next = worker.shift();
      return typeof next === "function" ? next() : next ?? fauxAssistantMessage("unexpected worker request");
    }));
    const dispatched = (taskId: string) => owner.dispatchTask(f.home.sessionId, { taskId, intent: `Count ${taskId}`, target: f.cwd });
    await dispatched("count-one");
    await dispatched("count-two");
    await waitFor(async () => (await owner.taskList({})).counts.finished === 2, "two tasks finished");
    await dispatched("count-three");
    await waitFor(async () => (await owner.taskList({})).counts.active === 1, "third task active");

    // One row per page, yet the counts cover the whole store.
    const capped = await owner.taskList({ limit: 1 });
    expect(capped.items).toHaveLength(1);
    expect(capped.nextCursor).toBeDefined();
    expect(capped.counts).toEqual({ active: 1, finished: 2 });

    hold.open();
    await waitFor(async () => (await owner.taskList({ limit: 1 })).counts.finished === 3, "third task finished");
    expect((await owner.taskList({ limit: 1 })).counts).toEqual({ active: 0, finished: 3 });
    const everything = await owner.taskList({ limit: 50 });
    expect(everything.items.every(item => typeof item.sessionId === "string")).toBe(true);
  }, 60_000);
});

describe("Home session controls", () => {
  it("applies the Home session's model, thinking and context window, and status reports the model in use", async () => {
    const f = await fixture();
    await configure(f);
    const owner = f.registry.homeOwner();
    const home = await f.registry.acquire(f.home.sessionId);
    expect((await owner.status()).model).toEqual({ provider: f.model.provider, id: f.model.id });

    await home.setModel(f.model.provider, TASK_REASONING_MODEL_ID);
    // The record is the model a re-enable restores, so status must follow a session.setModel.
    expect((await owner.status()).model).toEqual({ provider: f.model.provider, id: TASK_REASONING_MODEL_ID });

    await home.setThinking("low");
    expect(home.snapshot().thinkingLevel).toBe("low");

    // The request policy measures against the window the session's model reports. The control's floor
    // is 37,408 tokens, so the override is above it and below the model's own 128,000.
    const snapshot = home.snapshot();
    await home.setContextWindow(f.model.provider, TASK_REASONING_MODEL_ID, 40000, snapshot.revision, snapshot.runtimeGeneration);
    f.faux.setResponses([fauxAssistantMessage("reply on the reasoning model")]);
    await home.prompt("check the window");
    await waitFor(() => idle(home), "activation settled");
    expect(f.registry.homeOwner().contextStatus()).toMatchObject({ contextWindow: 40000 });
  }, 60_000);
});
