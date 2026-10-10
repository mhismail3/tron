import { existsSync } from "node:fs";
import { mkdir, readFile, writeFile } from "node:fs/promises";
import { join } from "node:path";
import { fauxAssistantMessage, fauxToolCall } from "@earendil-works/pi-ai";
import { afterEach, describe, expect, it, vi } from "vitest";
import { OWNED_OPERATION_DEADLINE_MS } from "../sessions/owned-session-dispatch.js";
import { dispatch, disposeFixtures, fixture, reportCall } from "../../test-support/home-task-fixture.js";
import { startChildModelServer, type ChildModelServer } from "../../test-support/home-task-subagent-child.js";
import { HOME_TASK_PRODUCER_REFUSAL_REASON } from "./home-task-worker-extension.js";
import { waitFor } from "../../test-support/wait-for.js";

// Each wait fails with its own label before the 60 s test timeout (the nested pass
// otherwise declares a 240 s wait bound that outlives every case here).
const bound = { boundMs: 20_000 };

// Real managed-provider children: a foreground run is an in-process child session and
// an async run is a detached runner, both answering from a scripted HTTP model. Like
// the other managed-provider cases, this file runs in the nested serial pass.
const servers: ChildModelServer[] = [];
afterEach(async () => {
  vi.restoreAllMocks();
  for (const server of servers.splice(0)) await server.close();
  await disposeFixtures();
});

async function childModel(f: Awaited<ReturnType<typeof fixture>>): Promise<ChildModelServer> {
  const server = await startChildModelServer();
  servers.push(server);
  await writeFile(join(f.agentDir, "models.json"), JSON.stringify({ providers: { "task-child": {
    baseUrl: `http://127.0.0.1:${server.port}/v1`, api: "openai-completions", apiKey: "fixture-only",
    models: [{ id: "child", name: "Task child", reasoning: false, input: ["text"], contextWindow: 128000, maxTokens: 4096,
      cost: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0 } }],
  } } }));
  await mkdir(join(f.cwd, ".pi", "agents"), { recursive: true });
  await writeFile(join(f.cwd, ".pi", "agents", "task-child.md"),
    "---\nname: task-child\ndescription: Scripted task child\nmodel: task-child/child\ntools: read\n---\nComplete the scripted task.\n");
  return server;
}

/** Captures the one 24-hour deadline timer so a test expires it at a chosen point. */
function captureDeadline(): { expire: () => void; armed: () => boolean } {
  const original = globalThis.setTimeout;
  let fire: (() => void) | undefined;
  vi.spyOn(globalThis, "setTimeout").mockImplementation(((callback: any, ms: number, ...args: any[]) => {
    if (ms === OWNED_OPERATION_DEADLINE_MS) fire = callback;
    return original(callback, ms, ...args);
  }) as typeof setTimeout);
  return { expire: () => { if (!fire) throw new Error("deadline is not armed"); fire(); }, armed: () => fire !== undefined };
}

/** Every `subagent` tool result in the worker's canonical session, launches and refusals alike. */
async function launchResults(registry: { readTaskEvidence(sessionId: string): Promise<unknown[]> }, sessionId: string) {
  const rows = await registry.readTaskEvidence(sessionId) as any[];
  return rows.filter(row => row.type === "message" && row.message?.role === "toolResult" && row.message.toolName === "subagent")
    .map(row => row.message as { toolCallId: string; isError: boolean; details?: Record<string, unknown> });
}

async function asyncState(asyncDir: string): Promise<string> {
  return JSON.parse(await readFile(join(asyncDir, "status.json"), "utf8")).state;
}

const holdingAsyncLaunch = (id: string, task = "HOLD-CHILD background search") =>
  fauxAssistantMessage([fauxToolCall("subagent", { agent: "task-child", task, async: true }, { id })], { stopReason: "toolUse" });

describe("Home task subagents", () => {
  it("joins a foreground and an async run before a reported task settles, and counts both", async () => {
    const f = await fixture(false, false, undefined, true);
    const child = await childModel(f);
    f.faux.setResponses([
      fauxAssistantMessage([fauxToolCall("subagent", { agent: "task-child", task: "CHILD-DONE foreground check", async: false }, { id: "fg-launch" })], { stopReason: "toolUse" }),
      holdingAsyncLaunch("async-launch"),
      // The report waits until the async child is live, so the stop has a run to join.
      async () => { await waitFor(() => child.heldRequests() === 1, "async child live before the report", bound); return fauxAssistantMessage([reportCall()], { stopReason: "toolUse" }); },
    ]);
    const run = await dispatch(f);
    const result = await run.completion;
    expect(result.terminalEvidence).toMatchObject({ outcome: "final", reason: "explicit-report" });
    const launches = await launchResults(f.registry, run.sessionId);
    const background = launches.find(launch => launch.toolCallId === "async-launch");
    expect(launches.find(launch => launch.toolCallId === "fg-launch")).toMatchObject({ isError: false });
    expect(background?.details?.asyncDir).toEqual(expect.any(String));
    // The Gateway stopped the still-running async run through the provider and joined it
    // before the task settled: its terminal status is on disk when the result is read.
    expect(await asyncState(background!.details!.asyncDir as string)).toBe("stopped");
    await waitFor(() => child.abortedRequests() === 1, "stopped async child request closed", bound);
    const slot = await f.registry.acquire(run.sessionId);
    expect(slot.catalogHasActiveSubagents).toBe(false);
    expect(await f.registry.homeOwner().taskStatus(run.taskId)).toMatchObject({ subagents: { started: 2, stoppedAtEnd: 1 } });
    expect(f.signals).toContainEqual(expect.objectContaining({ event: "home.task.subagents", started: 2, stoppedAtEnd: 1 }));
  }, 60_000);

  it("stops a running async run when the task is stopped, and no turn starts after settlement", async () => {
    const f = await fixture(false, false, undefined, true);
    const child = await childModel(f);
    // Any model request after the first is a turn the task must not start; the catch-all counts it.
    let parentRequests = 0;
    let unexpectedTurns = 0;
    f.faux.setResponses([
      holdingAsyncLaunch("async-launch"),
      (_context, options) => { parentRequests += 1; return new Promise((_resolve, reject) => {
        options?.signal?.addEventListener("abort", () => reject(new Error("parent stopped")), { once: true });
      }); },
      () => { unexpectedTurns += 1; return fauxAssistantMessage("a turn after settlement"); },
    ]);
    const run = await dispatch(f);
    await waitFor(() => child.heldRequests() === 1, "async child live", bound);
    await f.registry.homeOwner().stopTask({ taskId: run.taskId, operationId: run.operationId });
    const result = await run.completion;
    expect(result.terminalEvidence).toMatchObject({ outcome: "interrupted", reason: "task-stop" });
    const [launch] = (await launchResults(f.registry, run.sessionId)).filter(item => item.toolCallId === "async-launch");
    expect(await asyncState(launch!.details!.asyncDir as string)).toBe("stopped");
    await waitFor(() => child.abortedRequests() === 1, "stopped async child request closed", bound);
    expect(await f.registry.homeOwner().taskStatus(run.taskId)).toMatchObject({ subagents: { started: 1, stoppedAtEnd: 1 } });
    // Nothing follows settlement: no model request and no canonical entry after it.
    const slot = await f.registry.acquire(run.sessionId);
    const entries = slot.canonicalSessionEntries().length;
    await new Promise(resolve => setTimeout(resolve, 200));
    expect(parentRequests).toBe(1);
    expect(unexpectedTurns).toBe(0);
    expect(slot.canonicalSessionEntries()).toHaveLength(entries);
    expect(slot.isBusy).toBe(false);
  }, 60_000);

  it("starts no turn when an async run completes while its task reports", async () => {
    const f = await fixture(false, false, undefined, true);
    const child = await childModel(f);
    // The async child finishes on its own just as the task reports. Its completion is
    // producer context: it must not wake the sealed task into another model request.
    let reports = 0;
    let unexpectedTurns = 0;
    f.faux.setResponses([
      holdingAsyncLaunch("async-launch"),
      async () => {
        await waitFor(() => child.heldRequests() === 1, "async child live before the report", bound);
        child.releaseHeld();
        reports += 1;
        return fauxAssistantMessage([reportCall()], { stopReason: "toolUse" });
      },
      () => { unexpectedTurns += 1; return fauxAssistantMessage("a turn after the report"); },
    ]);
    const run = await dispatch(f);
    const result = await run.completion;
    expect(result.terminalEvidence).toMatchObject({ outcome: "final", reason: "explicit-report" });
    const slot = await f.registry.acquire(run.sessionId);
    const entries = slot.canonicalSessionEntries().length;
    await new Promise(resolve => setTimeout(resolve, 200));
    expect(reports).toBe(1);
    expect(unexpectedTurns).toBe(0);
    expect(slot.canonicalSessionEntries()).toHaveLength(entries);
  }, 60_000);

  it("stops a running async run at the 24-hour deadline before the task settles", async () => {
    const f = await fixture(false, false, undefined, true);
    const child = await childModel(f);
    const deadline = captureDeadline();
    f.faux.setResponses([
      holdingAsyncLaunch("async-launch"),
      (_context, options) => new Promise((_resolve, reject) => {
        options?.signal?.addEventListener("abort", () => reject(new Error("parent deadline")), { once: true });
      }),
    ]);
    const run = await dispatch(f);
    await waitFor(() => child.heldRequests() === 1 && deadline.armed(), "async child live under the deadline", bound);
    deadline.expire();
    const result = await run.completion;
    expect(result.terminalEvidence).toMatchObject({ outcome: "limited", reason: "deadline" });
    const [launch] = (await launchResults(f.registry, run.sessionId)).filter(item => item.toolCallId === "async-launch");
    expect(await asyncState(launch!.details!.asyncDir as string)).toBe("stopped");
    expect(await f.registry.homeOwner().taskStatus(run.taskId)).toMatchObject({ subagents: { started: 1, stoppedAtEnd: 1 } });
  }, 60_000);

  it("records unknown with detached-work-outlived-task when the provider cannot stop a run", async () => {
    const f = await fixture(false, false, undefined, true);
    const child = await childModel(f);
    const deadline = captureDeadline();
    f.faux.setResponses([
      holdingAsyncLaunch("async-launch"),
      (_context, options) => new Promise((_resolve, reject) => {
        options?.signal?.addEventListener("abort", () => reject(new Error("parent stopped")), { once: true });
      }),
    ]);
    const run = await dispatch(f);
    const slot = await f.registry.acquire(run.sessionId);
    await waitFor(() => child.heldRequests() === 1, "async child live", bound);
    // The Gateway's stop of the run is refused (an injected control failure): the run
    // stays live, so the join can end only at the task's deadline, and the task is not
    // allowed to settle as clean. The provider's tool itself is left untouched.
    let stopRefusals = 0;
    const control = vi.spyOn(slot as any, "controlSubagentRun").mockImplementation(async () => {
      stopRefusals += 1;
      throw new Error("injected stop refusal");
    });
    await f.registry.homeOwner().stopTask({ taskId: run.taskId, operationId: run.operationId });
    await waitFor(() => stopRefusals === 1, "stop refused", bound);
    deadline.expire();
    const result = await run.completion;
    expect(result.terminalEvidence).toMatchObject({ outcome: "unknown", reason: "detached-work-outlived-task" });
    expect(f.signals).toContainEqual(expect.objectContaining({ event: "home.task.detached-work", reason: "detached-work-outlived-task" }));
    expect(await f.registry.homeOwner().taskStatus(run.taskId)).toMatchObject({ subagents: { started: 1, stoppedAtEnd: null } });
    // The run is not dropped: it is still live, and it finishes once its child is released.
    const [launch] = (await launchResults(f.registry, run.sessionId)).filter(item => item.toolCallId === "async-launch");
    expect(await asyncState(launch!.details!.asyncDir as string)).toBe("running");
    control.mockRestore();
    child.releaseHeld();
    await waitFor(async () => (await asyncState(launch!.details!.asyncDir as string)) === "complete", "unjoined run finishes on its own", bound);
  }, 60_000);

  it("aborts a foreground run through the operation's tool signal when the task is stopped", async () => {
    const f = await fixture(false, false, undefined, true);
    const child = await childModel(f);
    f.faux.setResponses([
      fauxAssistantMessage([fauxToolCall("subagent", { agent: "task-child", task: "HOLD-CHILD foreground search", async: false }, { id: "fg-launch" })], { stopReason: "toolUse" }),
    ]);
    const run = await dispatch(f);
    await waitFor(() => child.heldRequests() === 1, "foreground child live", bound);
    await f.registry.homeOwner().stopTask({ taskId: run.taskId, operationId: run.operationId });
    const result = await run.completion;
    expect(result.terminalEvidence).toMatchObject({ outcome: "interrupted", reason: "task-stop" });
    // The foreground child's model request was cut off by the operation abort, not by a Gateway stop.
    expect(child.abortedRequests()).toBe(1);
    expect(await f.registry.homeOwner().taskStatus(run.taskId)).toMatchObject({ subagents: { started: 1, stoppedAtEnd: 0 } });
  }, 60_000);

  it("keeps the refusals for scheduling, wake subscriptions, and mutation of runs the task did not start", async () => {
    const f = await fixture(false, false, undefined, true);
    const child = await childModel(f);
    f.faux.setResponses([
      fauxAssistantMessage([
        fauxToolCall("schedule", { action: "list" }, { id: "schedule" }),
        fauxToolCall("bg_wait", { nonBlocking: true }, { id: "wake" }),
        fauxToolCall("subagent", { action: "stop", id: "foreign-run" }, { id: "foreign-stop" }),
        fauxToolCall("subagent", { action: "steer", id: "foreign-run", message: "change course" }, { id: "foreign-steer" }),
        fauxToolCall("subagent", { agent: "task-child", task: "HOLD-CHILD mission", async: true, mission: true }, { id: "mission" }),
      ], { stopReason: "toolUse" }),
      fauxAssistantMessage([reportCall()], { stopReason: "toolUse" }),
    ]);
    const run = await dispatch(f);
    await run.completion;
    const results = await launchResults(f.registry, run.sessionId);
    // Each refused call returns the gate's own reason, never the provider's error for it.
    for (const id of ["foreign-stop", "foreign-steer", "mission"]) {
      expect(results.find(item => item.toolCallId === id)).toMatchObject({ isError: true, content: [{ type: "text", text: HOME_TASK_PRODUCER_REFUSAL_REASON }] });
    }
    expect(f.signals).toEqual(expect.arrayContaining([
      expect.objectContaining({ event: "home.task.producer-refused", reason: "subagent-mutation" }),
      expect.objectContaining({ event: "home.task.producer-refused", reason: "wake-subscription" }),
    ]));
    expect(existsSync(join(f.cwd, "schedule-effect"))).toBe(false);
    expect(child.heldRequests()).toBe(0);
    expect(await f.registry.homeOwner().taskStatus(run.taskId)).toMatchObject({ subagents: { started: 0, stoppedAtEnd: 0 } });
  }, 60_000);

  it("reports unknown with detached-work-outlived-task after a restart finds a run still live", async () => {
    const f = await fixture(false, false, undefined, true);
    const child = await childModel(f);
    let release!: () => void;
    const gate = new Promise<void>(resolve => { release = resolve; });
    f.faux.setResponses([
      holdingAsyncLaunch("async-launch"),
      async () => { await gate; return fauxAssistantMessage([reportCall()], { stopReason: "toolUse" }); },
    ]);
    const run = await dispatch(f);
    const slot = await f.registry.acquire(run.sessionId);
    await waitFor(() => child.heldRequests() === 1, "async child live", bound);
    // The settlement's join fails before any stop: the task stays active, as after a crash.
    vi.spyOn(slot, "settleTaskSubagents").mockRejectedValue(new Error("injected settlement interruption"));
    release();
    await expect(run.completion).rejects.toThrow("injected settlement interruption");
    await f.registry.dispose();
    await f.registry.administrativeWorkRegistry.waitUntilSettled();
    const cold = await f.restart();
    expect(await cold.homeOwner().taskResult(run.taskId)).toMatchObject({ lifecycle: "terminal",
      terminalEvidence: { outcome: "unknown", reason: "detached-work-outlived-task" } });
    // Release the orphaned child and let its runner finish before the fixture is removed.
    const [launch] = (await launchResults(cold, run.sessionId)).filter(item => item.toolCallId === "async-launch");
    child.releaseHeld();
    await waitFor(async () => (await asyncState(launch!.details!.asyncDir as string)) === "complete", "orphaned run finishes", bound);
  }, 60_000);
});

