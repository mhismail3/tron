import { existsSync } from "node:fs";
import { mkdir, readFile, writeFile } from "node:fs/promises";
import { basename, dirname, join } from "node:path";
import { fauxAssistantMessage, fauxToolCall } from "@earendil-works/pi-ai";
import { afterEach, describe, expect, it, vi } from "vitest";
import { OWNED_OPERATION_DEADLINE_MS } from "../sessions/owned-session-dispatch.js";
import { dispatch, disposeFixtures, fixture, reportCall } from "../../test-support/home-task-fixture.js";
import { DETACHED_WORKFLOW_SCRIPT, HELD_WORKFLOW_SCRIPT, startScriptedChild, type ChildModelServer } from "../../test-support/home-task-subagent-child.js";
import { HOME_TASK_PRODUCER_REFUSAL_REASON } from "./home-task-worker-extension.js";
import { HOME_TASK_SUBAGENT_STOP_JOIN_MS } from "./home-task-subagents.js";
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
  const server = await startScriptedChild(f);
  servers.push(server);
  return server;
}

/** Captures the timers armed with exactly `ms` so a test fires the latest at a chosen point. */
function captureTimer(ms: number): { expire: () => void; armed: () => boolean } {
  const original = globalThis.setTimeout;
  let fire: (() => void) | undefined;
  vi.spyOn(globalThis, "setTimeout").mockImplementation(((callback: any, delay: number, ...args: any[]) => {
    if (delay === ms) fire = callback;
    return original(callback, delay, ...args);
  }) as typeof setTimeout);
  return { expire: () => { if (!fire) throw new Error(`no ${ms} ms timer is armed`); fire(); }, armed: () => fire !== undefined };
}

/** Captures the one 24-hour deadline timer so a test expires it at a chosen point. */
const captureDeadline = () => captureTimer(OWNED_OPERATION_DEADLINE_MS);

/** Every `subagent` tool result in the worker's canonical session, launches and refusals alike. */
async function launchResults(registry: { readTaskEvidence(sessionId: string): Promise<unknown[]> }, sessionId: string) {
  const rows = await registry.readTaskEvidence(sessionId) as any[];
  return rows.filter(row => row.type === "message" && row.message?.role === "toolResult" && row.message.toolName === "subagent")
    .map(row => row.message as { toolCallId: string; isError: boolean; details?: Record<string, unknown> });
}

async function asyncState(asyncDir: string): Promise<string> {
  return JSON.parse(await readFile(join(asyncDir, "status.json"), "utf8")).state;
}

const holdingWorkflowLaunch = (id: string) =>
  fauxAssistantMessage([fauxToolCall("subagent", { workflow: "./hold-workflow.js", async: true }, { id })], { stopReason: "toolUse" });
/** The run id of a workflow's one async child, from the workflow's own status. */
async function workflowChildRunId(workflowDir: string): Promise<string> {
  const status = JSON.parse(await readFile(join(workflowDir, "status.json"), "utf8")) as { steps: Array<{ runId?: string }> };
  return status.steps[0]!.runId!;
}

const holdingAsyncLaunch = (id: string, task = "HOLD-CHILD background search") =>
  fauxAssistantMessage([fauxToolCall("subagent", { agent: "task-child", task, async: true }, { id })], { stopReason: "toolUse" });

/** The turn has ended and the task holds its operation open between turns, waiting for its live runs.
 * The hold is recorded when the turn's terminal is, so this does not read `isBusy`, which live runs keep set. */
async function waitBetweenTurns(slot: object): Promise<void> {
  await waitFor(() => (slot as { taskWait?: unknown }).taskWait !== undefined, "task waits between turns", bound);
}

/** The model's context as the faux provider passes it to a scripted response. */
type FauxContext = { messages: Array<Record<string, any>> };
/** The reply one tool call received, as the model reads it. */
function toolResultText(context: FauxContext, toolCallId: string): { isError: boolean; text: string } | undefined {
  const result = context.messages.find(message => message.role === "toolResult" && message.toolCallId === toolCallId);
  if (!result) return undefined;
  return { isError: result.isError === true, text: result.content.find((item: { type: string }) => item.type === "text")?.text ?? "" };
}
/** A canonical entry's text, as the model reads it. */
function entryText(entry: { content?: unknown }): string {
  const content = entry.content;
  return typeof content === "string" ? content
    : (content as Array<{ type?: string; text?: string }>).filter(part => part.type === "text").map(part => part.text ?? "").join("\n");
}
/** The async run directory a launch returned. A run's id is its directory name. */
function launchedAsyncDir(context: FauxContext, toolCallId: string): string {
  const result = context.messages.find(message => message.role === "toolResult" && message.toolCallId === toolCallId);
  const asyncDir = (result?.details as { asyncDir?: unknown } | undefined)?.asyncDir;
  if (typeof asyncDir !== "string") throw new Error(`launch ${toolCallId} returned no async run`);
  return asyncDir;
}

describe("Home task subagents", () => {
  it("joins a foreground and an async run before a reported task settles, and counts both", async () => {
    const f = await fixture(false, false, undefined, true);
    const child = await childModel(f);
    const seen: { refusal?: { isError: boolean; text: string } } = {};
    f.faux.setResponses([
      fauxAssistantMessage([fauxToolCall("subagent", { agent: "task-child", task: "CHILD-DONE foreground check", async: false }, { id: "fg-launch" })], { stopReason: "toolUse" }),
      holdingAsyncLaunch("async-launch"),
      async () => {
        await waitFor(() => child.heldRequests() === 1, "async child live before the report", bound);
        return fauxAssistantMessage([reportCall("report-early")], { stopReason: "toolUse" });
      },
      async (context: FauxContext) => {
        // The report waits for the live async run: it is refused, and the run ends before the report is retried.
        seen.refusal = toolResultText(context, "call-report-early");
        child.releaseHeld();
        const slot = await f.registry.acquire(run.sessionId);
        await waitFor(() => !slot.catalogHasActiveSubagents, "async run ended before the report", bound);
        return fauxAssistantMessage([reportCall()], { stopReason: "toolUse" });
      },
    ]);
    const run = await dispatch(f);
    const result = await run.completion;
    expect(seen.refusal).toMatchObject({ isError: true });
    expect(result.terminalEvidence).toMatchObject({ outcome: "final", reason: "explicit-report" });
    const launches = await launchResults(f.registry, run.sessionId);
    const background = launches.find(launch => launch.toolCallId === "async-launch");
    expect(launches.find(launch => launch.toolCallId === "fg-launch")).toMatchObject({ isError: false });
    expect(background?.details?.asyncDir).toEqual(expect.any(String));
    expect(await asyncState(background!.details!.asyncDir as string)).toBe("complete");
    expect(child.abortedRequests()).toBe(0);
    const slot = await f.registry.acquire(run.sessionId);
    expect(slot.catalogHasActiveSubagents).toBe(false);
    expect(await f.registry.homeOwner().taskStatus(run.taskId)).toMatchObject({ subagents: { started: 2, stoppedAtEnd: 0 } });
    expect(f.signals).toContainEqual(expect.objectContaining({ event: "home.task.subagents", started: 2, stoppedAtEnd: 0 }));
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

  it("waits for an async workflow and the child it holds before a reported task settles, and counts the workflow", async () => {
    const f = await fixture(false, false, undefined, true);
    const child = await childModel(f);
    await writeFile(join(f.cwd, "hold-workflow.js"), HELD_WORKFLOW_SCRIPT);
    const seen: { refusal?: { isError: boolean; text: string } } = {};
    f.faux.setResponses([
      holdingWorkflowLaunch("workflow-launch"),
      async () => {
        await waitFor(() => child.heldRequests() === 1, "workflow child live before the report", bound);
        return fauxAssistantMessage([reportCall("report-early")], { stopReason: "toolUse" });
      },
      async (context: FauxContext) => {
        seen.refusal = toolResultText(context, "call-report-early");
        child.releaseHeld();
        const slot = await f.registry.acquire(run.sessionId);
        await waitFor(() => !slot.catalogHasActiveSubagents, "workflow ended before the report", bound);
        return fauxAssistantMessage([reportCall()], { stopReason: "toolUse" });
      },
    ]);
    const run = await dispatch(f);
    const result = await run.completion;
    expect(seen.refusal).toMatchObject({ isError: true });
    expect(result.terminalEvidence).toMatchObject({ outcome: "final", reason: "explicit-report" });
    const [launch] = (await launchResults(f.registry, run.sessionId)).filter(item => item.toolCallId === "workflow-launch");
    const workflowDir = launch!.details!.asyncDir as string;
    expect(await asyncState(workflowDir)).toBe("complete");
    expect(await asyncState(join(dirname(workflowDir), await workflowChildRunId(workflowDir)))).toBe("complete");
    expect(child.abortedRequests()).toBe(0);
    expect(await f.registry.homeOwner().taskStatus(run.taskId)).toMatchObject({ subagents: { started: 1, stoppedAtEnd: 0 } });
  }, 60_000);

  it("stops a running async workflow when the task is stopped, and its held child with it", async () => {
    const f = await fixture(false, false, undefined, true);
    const child = await childModel(f);
    await writeFile(join(f.cwd, "hold-workflow.js"), HELD_WORKFLOW_SCRIPT);
    f.faux.setResponses([
      holdingWorkflowLaunch("workflow-launch"),
      (_context, options) => new Promise((_resolve, reject) => {
        options?.signal?.addEventListener("abort", () => reject(new Error("parent stopped")), { once: true });
      }),
    ]);
    const run = await dispatch(f);
    await waitFor(() => child.heldRequests() === 1, "workflow child live", bound);
    await f.registry.homeOwner().stopTask({ taskId: run.taskId, operationId: run.operationId });
    const result = await run.completion;
    expect(result.terminalEvidence).toMatchObject({ outcome: "interrupted", reason: "task-stop" });
    const [launch] = (await launchResults(f.registry, run.sessionId)).filter(item => item.toolCallId === "workflow-launch");
    expect(await asyncState(launch!.details!.asyncDir as string)).toBe("stopped");
    await waitFor(() => child.abortedRequests() === 1, "stopped workflow child request closed", bound);
    expect(await f.registry.homeOwner().taskStatus(run.taskId)).toMatchObject({ subagents: { started: 1, stoppedAtEnd: 1 } });
  }, 60_000);

  it("stops a workflow's async child that outlives its completed workflow when the task is stopped while it waits", async () => {
    const f = await fixture(false, false, undefined, true);
    const child = await childModel(f);
    await writeFile(join(f.cwd, "detached-workflow.js"), DETACHED_WORKFLOW_SCRIPT);
    f.faux.setResponses([
      fauxAssistantMessage([fauxToolCall("subagent", { workflow: "./detached-workflow.js", async: true }, { id: "workflow-launch" })], { stopReason: "toolUse" }),
      // A turn that ends with its detached child live and no report waits for the child, so the task is held until Stop.
      // The turn ends only once the child is a live run of the task, as the report gate and the hold read it.
      async () => {
        await waitFor(() => child.heldRequests() === 1, "detached child live before the final reply", bound);
        const slot = await f.registry.acquire(run.sessionId);
        await waitFor(() => slot.liveSubagentRuns().length === 1, "detached child visible as live", bound);
        return fauxAssistantMessage("Finished without a report.");
      },
      // The workflow completed at once, so its completion notice can start a follow-up turn of the same task: that turn holds too.
      () => fauxAssistantMessage("Finished without a report."),
    ]);
    const run = await dispatch(f);
    const slot = await f.registry.acquire(run.sessionId);
    await waitFor(() => child.heldRequests() === 1, "detached child live", bound);
    await waitBetweenTurns(slot);
    await f.registry.homeOwner().stopTask({ taskId: run.taskId, operationId: run.operationId });
    const result = await run.completion;
    expect(result.terminalEvidence).toMatchObject({ outcome: "interrupted", reason: "task-stop" });
    const [launch] = (await launchResults(f.registry, run.sessionId)).filter(item => item.toolCallId === "workflow-launch");
    const workflowDir = launch!.details!.asyncDir as string;
    // The workflow itself had completed; its child was stopped by run id and joined before settlement.
    expect(await asyncState(workflowDir)).toBe("complete");
    expect(await asyncState(join(dirname(workflowDir), await workflowChildRunId(workflowDir)))).toBe("stopped");
    await waitFor(() => child.abortedRequests() === 1, "stopped workflow child request closed", bound);
    expect(await f.registry.homeOwner().taskStatus(run.taskId)).toMatchObject({ subagents: { started: 1, stoppedAtEnd: 1 } });
  }, 60_000);

  it("starts no turn when an async run completes before its task reports", async () => {
    const f = await fixture(false, false, undefined, true);
    const child = await childModel(f);
    // The async child finishes while the worker is still working. Its completion is
    // producer context: it must not wake the sealed task into another model request.
    let reports = 0;
    let unexpectedTurns = 0;
    f.faux.setResponses([
      holdingAsyncLaunch("async-launch"),
      async () => {
        await waitFor(() => child.heldRequests() === 1, "async child live before the report", bound);
        child.releaseHeld();
        const slot = await f.registry.acquire(run.sessionId);
        await waitFor(() => !slot.catalogHasActiveSubagents, "async run ended before the report", bound);
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

  it("records unknown with detached-work-outlived-task once the stop join is bounded, without waiting for the deadline", async () => {
    const f = await fixture(false, false, undefined, true);
    const child = await childModel(f);
    const stopJoin = captureTimer(HOME_TASK_SUBAGENT_STOP_JOIN_MS);
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
    // stays live, so the join ends at its own bound, well before the 24-hour deadline,
    // and the task is not allowed to settle as clean. The provider's tool is untouched.
    let stopRefusals = 0;
    const control = vi.spyOn(slot as any, "controlSubagentRun").mockImplementation(async () => {
      stopRefusals += 1;
      throw new Error("injected stop refusal");
    });
    await f.registry.homeOwner().stopTask({ taskId: run.taskId, operationId: run.operationId });
    await waitFor(() => stopRefusals === 1, "stop refused", bound);
    await waitFor(() => stopJoin.armed(), "stop join bounded", bound);
    stopJoin.expire();
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
    f.faux.setResponses([
      holdingAsyncLaunch("async-launch"),
      fauxAssistantMessage("Finished without a report."),
    ]);
    const run = await dispatch(f);
    const slot = await f.registry.acquire(run.sessionId);
    await waitFor(() => child.heldRequests() === 1, "async child live", bound);
    await waitBetweenTurns(slot);
    // The settlement's join fails before any stop: the task stays active, as after a crash.
    vi.spyOn(slot, "settleTaskSubagents").mockRejectedValue(new Error("injected settlement interruption"));
    await f.registry.homeOwner().stopTask({ taskId: run.taskId, operationId: run.operationId });
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

  it("reports unknown after a restart finds a workflow child still running under its completed workflow", async () => {
    const f = await fixture(false, false, undefined, true);
    const child = await childModel(f);
    await writeFile(join(f.cwd, "detached-workflow.js"), DETACHED_WORKFLOW_SCRIPT);
    f.faux.setResponses([
      fauxAssistantMessage([fauxToolCall("subagent", { workflow: "./detached-workflow.js", async: true }, { id: "workflow-launch" })], { stopReason: "toolUse" }),
      async () => {
        await waitFor(() => child.heldRequests() === 1, "detached child live before the final reply", bound);
        const slot = await f.registry.acquire(run.sessionId);
        await waitFor(() => slot.liveSubagentRuns().length === 1, "detached child visible as live", bound);
        return fauxAssistantMessage("Finished without a report.");
      },
      // The workflow completed at once, so its completion notice can start a follow-up turn of the same task: that turn holds too.
      () => fauxAssistantMessage("Finished without a report."),
    ]);
    const run = await dispatch(f);
    const slot = await f.registry.acquire(run.sessionId);
    await waitFor(() => child.heldRequests() === 1, "detached child live", bound);
    await waitBetweenTurns(slot);
    // The settlement fails before any stop, as after a crash: the task stays active.
    vi.spyOn(slot, "settleTaskSubagents").mockRejectedValue(new Error("injected settlement interruption"));
    await f.registry.homeOwner().stopTask({ taskId: run.taskId, operationId: run.operationId });
    await expect(run.completion).rejects.toThrow("injected settlement interruption");
    await f.registry.dispose();
    await f.registry.administrativeWorkRegistry.waitUntilSettled();
    const cold = await f.restart();
    // The workflow's own status is complete, but its child's status is not: the task is not clean.
    expect(await cold.homeOwner().taskResult(run.taskId)).toMatchObject({ lifecycle: "terminal",
      terminalEvidence: { outcome: "unknown", reason: "detached-work-outlived-task" } });
    const [launch] = (await launchResults(cold, run.sessionId)).filter(item => item.toolCallId === "workflow-launch");
    const workflowDir = launch!.details!.asyncDir as string;
    const childDir = join(dirname(workflowDir), await workflowChildRunId(workflowDir));
    child.releaseHeld();
    await waitFor(async () => (await asyncState(childDir)) === "complete", "orphaned workflow child finishes", bound);
  }, 60_000);

  it("refuses a report while an async run is live, keeps the task active, and accepts the report once the run has completed", async () => {
    const f = await fixture(false, false, undefined, true);
    const child = await childModel(f);
    const seen: { refusal?: { isError: boolean; text: string }; runDir?: string } = {};
    f.faux.setResponses([
      holdingAsyncLaunch("async-launch"),
      async () => {
        await waitFor(() => child.heldRequests() === 1, "async child live before the report", bound);
        return fauxAssistantMessage([reportCall("report-early")], { stopReason: "toolUse" });
      },
      async (context: FauxContext) => {
        // The refusal is an ordinary tool error, and the turn continues to this request.
        seen.refusal = toolResultText(context, "call-report-early");
        seen.runDir = launchedAsyncDir(context, "async-launch");
        expect(await f.registry.homeOwner().taskStatus(run.taskId)).toMatchObject({ lifecycle: "active" });
        child.releaseHeld();
        const slot = await f.registry.acquire(run.sessionId);
        await waitFor(() => !slot.catalogHasActiveSubagents, "async run ended before the late report", bound);
        return fauxAssistantMessage([reportCall("report-late")], { stopReason: "toolUse" });
      },
    ]);
    const run = await dispatch(f);
    const result = await run.completion;
    expect(seen.refusal).toMatchObject({ isError: true, text: expect.stringMatching(/^Report refused: 1 subagent run .* still live/) });
    expect(await asyncState(seen.runDir!)).toBe("complete");
    expect(result.terminalEvidence).toMatchObject({ outcome: "final", reason: "explicit-report" });
    expect(result.reportRef).toMatchObject({ resultId: "report-late" });
    // The run ended on its own before the report, so the Gateway stopped nothing at settlement.
    expect(await f.registry.homeOwner().taskStatus(run.taskId)).toMatchObject({ subagents: { started: 1, stoppedAtEnd: 0 } });
    expect(child.abortedRequests()).toBe(0);
  }, 60_000);

  it("accepts a report once the worker has stopped its own async run", async () => {
    const f = await fixture(false, false, undefined, true);
    const child = await childModel(f);
    const seen: { stop?: { isError: boolean; text: string }; runDir?: string } = {};
    f.faux.setResponses([
      holdingAsyncLaunch("async-launch"),
      async (context: FauxContext) => {
        await waitFor(() => child.heldRequests() === 1, "async child live", bound);
        seen.runDir = launchedAsyncDir(context, "async-launch");
        return fauxAssistantMessage([fauxToolCall("subagent", { action: "stop", id: basename(seen.runDir) }, { id: "own-stop" })], { stopReason: "toolUse" });
      },
      async (context: FauxContext) => {
        seen.stop = toolResultText(context, "own-stop");
        // A stop request returns before the run has ended. The run is live until its status is terminal, so the
        // worker waits for it, then reports.
        const slot = await f.registry.acquire(run.sessionId);
        await waitFor(() => !slot.catalogHasActiveSubagents, "stopped run ended before the report", bound);
        return fauxAssistantMessage([reportCall("report-after-stop")], { stopReason: "toolUse" });
      },
    ]);
    const run = await dispatch(f);
    const result = await run.completion;
    expect(seen.stop).toMatchObject({ isError: false });
    expect(await asyncState(seen.runDir!)).toBe("stopped");
    expect(result.terminalEvidence).toMatchObject({ outcome: "final", reason: "explicit-report" });
    expect(result.reportRef).toMatchObject({ resultId: "report-after-stop" });
    // The worker's own stop is not a Gateway stop: settlement had no live run to stop.
    expect(await f.registry.homeOwner().taskStatus(run.taskId)).toMatchObject({ subagents: { started: 1, stoppedAtEnd: 0 } });
  }, 60_000);

  it("refuses a report while a completed workflow's async child is live, and accepts it once the child has ended", async () => {
    const f = await fixture(false, false, undefined, true);
    const child = await childModel(f);
    await writeFile(join(f.cwd, "detached-workflow.js"), DETACHED_WORKFLOW_SCRIPT);
    const seen: { refusal?: { isError: boolean; text: string }; workflowDir?: string } = {};
    f.faux.setResponses([
      fauxAssistantMessage([fauxToolCall("subagent", { workflow: "./detached-workflow.js", async: true }, { id: "workflow-launch" })], { stopReason: "toolUse" }),
      async () => {
        await waitFor(() => child.heldRequests() === 1, "detached child live before the report", bound);
        return fauxAssistantMessage([reportCall("report-early")], { stopReason: "toolUse" });
      },
      async (context: FauxContext) => {
        seen.refusal = toolResultText(context, "call-report-early");
        seen.workflowDir = launchedAsyncDir(context, "workflow-launch");
        child.releaseHeld();
        const slot = await f.registry.acquire(run.sessionId);
        await waitFor(() => !slot.catalogHasActiveSubagents, "workflow child ended before the late report", bound);
        return fauxAssistantMessage([reportCall("report-late")], { stopReason: "toolUse" });
      },
    ]);
    const run = await dispatch(f);
    const result = await run.completion;
    expect(seen.refusal).toMatchObject({ isError: true, text: expect.stringMatching(/^Report refused: 1 subagent run .* still live/) });
    // The workflow had completed, so only its child kept the run live.
    expect(await asyncState(seen.workflowDir!)).toBe("complete");
    expect(await asyncState(join(dirname(seen.workflowDir!), await workflowChildRunId(seen.workflowDir!)))).toBe("complete");
    expect(result.terminalEvidence).toMatchObject({ outcome: "final", reason: "explicit-report" });
    expect(result.reportRef).toMatchObject({ resultId: "report-late" });
    expect(await f.registry.homeOwner().taskStatus(run.taskId)).toMatchObject({ subagents: { started: 1, stoppedAtEnd: 0 } });
  }, 60_000);

  it("records a run's late completion notice before the settlement fact, and nothing follows the fact", async () => {
    const f = await fixture(false, false, undefined, true);
    const child = await childModel(f);
    await writeFile(join(f.cwd, "hold-workflow.js"), HELD_WORKFLOW_SCRIPT);
    const seen: { workflowDir?: string } = {};
    f.faux.setResponses([
      holdingWorkflowLaunch("workflow-launch"),
      async (context: FauxContext) => {
        await waitFor(() => child.heldRequests() === 1, "workflow child live", bound);
        seen.workflowDir = launchedAsyncDir(context, "workflow-launch");
        // The workflow completes with its child. Its completion notice is written after the run became
        // terminal, so the report races it unless settlement records the notice first.
        child.releaseHeld();
        const slot = await f.registry.acquire(run.sessionId);
        await waitFor(() => !slot.catalogHasActiveSubagents, "workflow ended before the report", bound);
        return fauxAssistantMessage([reportCall()], { stopReason: "toolUse" });
      },
    ]);
    const run = await dispatch(f);
    const result = await run.completion;
    expect(result.terminalEvidence).toMatchObject({ outcome: "final", reason: "explicit-report" });
    const slot = await f.registry.acquire(run.sessionId);
    const entries = slot.canonicalSessionEntries();
    const runId = basename(seen.workflowDir!);
    const notice = entries.findIndex(entry => entry.type === "custom_message" && entry.customType === "subagent-notify" && entryText(entry).includes(runId));
    const receipt = entries.findIndex(entry => entry.type === "custom" && entry.customType === "tron.context-delivery.v4"
      && (entry.data as { targetEntryId?: string })?.targetEntryId === entries[notice]?.id);
    const fact = entries.findIndex(entry => entry.type === "custom" && entry.customType === "tron-home-task-subagents");
    expect(notice).toBeGreaterThanOrEqual(0);
    // Settlement recorded the notice and its delivery before its fact and evidence cut.
    expect(receipt).toBeGreaterThan(notice);
    expect(fact).toBeGreaterThan(receipt);
    expect(fact).toBe(entries.length - 1);
    // A canonical read after settlement sees no further append from the run.
    await new Promise(resolve => setTimeout(resolve, 1500));
    expect(slot.canonicalSessionEntries()).toHaveLength(entries.length);
    expect(await f.registry.homeOwner().taskStatus(run.taskId)).toMatchObject({ subagents: { started: 1, stoppedAtEnd: 0 } });
  }, 60_000);

  it("settles without a completion notice the bound never records, counts it, and keeps the outcome", async () => {
    const f = await fixture(false, false, undefined, true);
    const child = await childModel(f);
    let stopJoin: ReturnType<typeof captureTimer> | undefined;
    f.faux.setResponses([
      holdingAsyncLaunch("async-launch"),
      async () => {
        await waitFor(() => child.heldRequests() === 1, "async child live", bound);
        child.releaseHeld();
        const slot = await f.registry.acquire(run.sessionId);
        await waitFor(() => !slot.catalogHasActiveSubagents, "async run ended before the report", bound);
        // The provider's notice never reaches canonical evidence: settlement sees no notice for the run.
        const canonical = slot.canonicalSessionEntries.bind(slot);
        vi.spyOn(slot, "canonicalSessionEntries").mockImplementation(() =>
          canonical().filter(entry => !(entry.type === "custom_message" && entry.customType === "subagent-notify")));
        // Captured from the report on, so the armed 60 s timer is the settlement's own stop-join bound.
        stopJoin = captureTimer(HOME_TASK_SUBAGENT_STOP_JOIN_MS);
        return fauxAssistantMessage([reportCall()], { stopReason: "toolUse" });
      },
    ]);
    const run = await dispatch(f);
    await waitFor(() => stopJoin?.armed() === true, "notice join bounded", bound);
    stopJoin!.expire();
    const result = await run.completion;
    expect(result.terminalEvidence).toMatchObject({ outcome: "final", reason: "explicit-report" });
    expect(f.signals).toContainEqual(expect.objectContaining({ event: "home.task.subagents", started: 1, stoppedAtEnd: 0, noticesUndelivered: 1 }));
    expect(await f.registry.homeOwner().taskStatus(run.taskId)).toMatchObject({ subagents: { started: 1, stoppedAtEnd: 0 } });
  }, 60_000);

  it("lists a live subagent run in task status until settlement, then lists none", async () => {
    const f = await fixture(false, false, undefined, true);
    const child = await childModel(f);
    const seen: { live?: any; runId?: string } = {};
    f.faux.setResponses([
      holdingAsyncLaunch("async-launch"),
      async (context: FauxContext) => {
        await waitFor(() => child.heldRequests() === 1, "async child live", bound);
        seen.runId = basename(launchedAsyncDir(context, "async-launch"));
        seen.live = await f.registry.homeOwner().taskStatus("task-one");
        child.releaseHeld();
        const slot = await f.registry.acquire(run.sessionId);
        await waitFor(() => !slot.catalogHasActiveSubagents, "async run ended before the report", bound);
        return fauxAssistantMessage([reportCall()], { stopReason: "toolUse" });
      },
    ]);
    const run = await dispatch(f);
    await run.completion;
    expect(seen.live).toMatchObject({ subagentRuns: { total: 1, runs: [
      { runId: seen.runId, agent: "task-child", state: "running", startedAt: expect.any(String) },
    ] } });
    expect(await f.registry.homeOwner().taskStatus(run.taskId)).toMatchObject({ subagentRuns: { total: 0, runs: [] } });
  }, 60_000);
  it("waits between turns for a live async run, and the run's completion starts the task's next turn", async () => {
    const f = await fixture(false, false, undefined, true);
    const child = await childModel(f);
    f.faux.setResponses([
      holdingAsyncLaunch("async-launch"),
      // The turn ends with the run live and no report: the task waits instead of settling.
      fauxAssistantMessage("Launched the background check; waiting for it."),
      // The run's completion wakes the same task into its next turn, which reports.
      async () => fauxAssistantMessage([reportCall("report-after-wake")], { stopReason: "toolUse" }),
    ]);
    const run = await dispatch(f);
    const slot = await f.registry.acquire(run.sessionId);
    await waitFor(() => child.heldRequests() === 1, "async child live", bound);
    await waitBetweenTurns(slot);
    child.releaseHeld();
    const result = await run.completion;
    expect(result.terminalEvidence).toMatchObject({ outcome: "final", reason: "explicit-report" });
    const [launch] = (await launchResults(f.registry, run.sessionId)).filter(item => item.toolCallId === "async-launch");
    expect(await asyncState(launch!.details!.asyncDir as string)).toBe("complete");
    expect(child.abortedRequests()).toBe(0);
    expect(await f.registry.homeOwner().taskStatus(run.taskId)).toMatchObject({ subagents: { started: 1, stoppedAtEnd: 0 } });
  }, 60_000);

  it("stops the turn a provider wake starts when the task is stopped during that turn", async () => {
    const f = await fixture(false, false, undefined, true);
    const child = await childModel(f);
    let wakeTurnStarted = false;
    f.faux.setResponses([
      holdingAsyncLaunch("async-launch"),
      fauxAssistantMessage("Launched the background check; waiting for it."),
      (_context, options) => {
        wakeTurnStarted = true;
        return new Promise((_resolve, reject) => {
          options?.signal?.addEventListener("abort", () => reject(new Error("wake turn stopped")), { once: true });
        });
      },
    ]);
    const run = await dispatch(f);
    const slot = await f.registry.acquire(run.sessionId);
    await waitFor(() => child.heldRequests() === 1, "async child live", bound);
    await waitBetweenTurns(slot);
    child.releaseHeld();
    await waitFor(() => wakeTurnStarted, "the completion wake starts a turn", bound);
    await f.registry.homeOwner().stopTask({ taskId: run.taskId, operationId: run.operationId });
    const result = await run.completion;
    expect(result.terminalEvidence).toMatchObject({ outcome: "interrupted", reason: "task-stop" });
    expect(await f.registry.homeOwner().taskStatus(run.taskId)).toMatchObject({ subagents: { started: 1, stoppedAtEnd: 0 } });
  }, 60_000);

  it("expires the 24-hour deadline while a task waits between turns, and stops its live async run", async () => {
    const f = await fixture(false, false, undefined, true);
    const child = await childModel(f);
    const deadline = captureDeadline();
    f.faux.setResponses([
      holdingAsyncLaunch("async-launch"),
      fauxAssistantMessage("Launched the background check; waiting for it."),
    ]);
    const run = await dispatch(f);
    const slot = await f.registry.acquire(run.sessionId);
    await waitFor(() => child.heldRequests() === 1 && deadline.armed(), "async child live under the deadline", bound);
    await waitBetweenTurns(slot);
    deadline.expire();
    const result = await run.completion;
    expect(result.terminalEvidence).toMatchObject({ outcome: "limited", reason: "deadline" });
    const [launch] = (await launchResults(f.registry, run.sessionId)).filter(item => item.toolCallId === "async-launch");
    expect(await asyncState(launch!.details!.asyncDir as string)).toBe("stopped");
    await waitFor(() => child.abortedRequests() === 1, "stopped async child request closed", bound);
    expect(await f.registry.homeOwner().taskStatus(run.taskId)).toMatchObject({ subagents: { started: 1, stoppedAtEnd: 1 } });
  }, 60_000);

  it("settles at once a turn that ends with no live run and no report, starting no further turn", async () => {
    const f = await fixture(false, false, undefined, true);
    let unexpectedTurns = 0;
    f.faux.setResponses([
      fauxAssistantMessage("Finished without a report and without any run."),
      () => { unexpectedTurns += 1; return fauxAssistantMessage("a turn after settlement"); },
    ]);
    const run = await dispatch(f);
    const result = await run.completion;
    expect(result.terminalEvidence).toMatchObject({ outcome: "unknown", reason: "no-report" });
    await new Promise(resolve => setTimeout(resolve, 200));
    expect(unexpectedTurns).toBe(0);
  }, 60_000);

  it("admits a resume of its own completed async run, and counts the resumed run as a launch", async () => {
    const f = await fixture(false, false, undefined, true);
    await childModel(f);
    const seen: { resume?: { isError: boolean; text: string } } = {};
    let run!: Awaited<ReturnType<typeof dispatch>>;
    f.faux.setResponses([
      fauxAssistantMessage([fauxToolCall("subagent", { agent: "task-child", task: "CHILD-DONE first pass", async: true }, { id: "async-launch" })], { stopReason: "toolUse" }),
      async (context: FauxContext) => {
        const firstRun = basename(launchedAsyncDir(context, "async-launch"));
        const slot = await f.registry.acquire(run.sessionId);
        await waitFor(() => !slot.catalogHasActiveSubagents, "first run ended before the resume", bound);
        return fauxAssistantMessage([fauxToolCall("subagent", { action: "resume", id: firstRun, message: "CHILD-DONE second pass" }, { id: "resume" })], { stopReason: "toolUse" });
      },
      async (context: FauxContext) => {
        seen.resume = toolResultText(context, "resume");
        const slot = await f.registry.acquire(run.sessionId);
        await waitFor(() => !slot.catalogHasActiveSubagents, "resumed run ended before the report", bound);
        return fauxAssistantMessage([reportCall()], { stopReason: "toolUse" });
      },
    ]);
    run = await dispatch(f);
    const result = await run.completion;
    expect(seen.resume).toMatchObject({ isError: false });
    expect(seen.resume?.text).not.toBe(HOME_TASK_PRODUCER_REFUSAL_REASON);
    expect(result.terminalEvidence).toMatchObject({ outcome: "final", reason: "explicit-report" });
    expect(await f.registry.homeOwner().taskStatus(run.taskId)).toMatchObject({ subagents: { started: 2, stoppedAtEnd: 0 } });
  }, 60_000);

  it("stops a child of its owned workflow through the workflow's run, and the workflow's child ends", async () => {
    const f = await fixture(false, false, undefined, true);
    const child = await childModel(f);
    await writeFile(join(f.cwd, "hold-workflow.js"), HELD_WORKFLOW_SCRIPT);
    const seen: { stop?: { isError: boolean; text: string }; workflowDir?: string } = {};
    f.faux.setResponses([
      holdingWorkflowLaunch("workflow-launch"),
      async (context: FauxContext) => {
        await waitFor(() => child.heldRequests() === 1, "workflow child live", bound);
        seen.workflowDir = launchedAsyncDir(context, "workflow-launch");
        return fauxAssistantMessage([fauxToolCall("subagent", { action: "stop", id: basename(seen.workflowDir), index: 0 }, { id: "stop-child" })], { stopReason: "toolUse" });
      },
      async (context: FauxContext) => {
        seen.stop = toolResultText(context, "stop-child");
        const slot = await f.registry.acquire(run.sessionId);
        await waitFor(() => !slot.catalogHasActiveSubagents, "stopped workflow ended before the report", bound);
        return fauxAssistantMessage([reportCall()], { stopReason: "toolUse" });
      },
    ]);
    const run = await dispatch(f);
    const result = await run.completion;
    expect(seen.stop).toMatchObject({ isError: false });
    expect(seen.stop?.text).not.toBe(HOME_TASK_PRODUCER_REFUSAL_REASON);
    expect(result.terminalEvidence).toMatchObject({ outcome: "final", reason: "explicit-report" });
    expect(await asyncState(join(dirname(seen.workflowDir!), await workflowChildRunId(seen.workflowDir!)))).toBe("stopped");
    expect(child.abortedRequests()).toBe(1);
  }, 60_000);

  it("refuses a supervisor reply that does not name a request of the task's own run, and admits its reads", async () => {
    const f = await fixture(false, false, undefined, true);
    const seen: { results?: Record<string, { isError: boolean; text: string }> } = {};
    f.faux.setResponses([
      fauxAssistantMessage([
        fauxToolCall("subagent_supervisor", { action: "reply", replyTo: "foreign-request", message: "Proceed" }, { id: "foreign-reply" }),
        fauxToolCall("subagent_supervisor", { action: "reply", message: "Proceed" }, { id: "implicit-reply" }),
        fauxToolCall("subagent_supervisor", { action: "pending" }, { id: "pending" }),
        fauxToolCall("subagent_supervisor", { action: "list" }, { id: "list" }),
      ], { stopReason: "toolUse" }),
      (context: FauxContext) => {
        seen.results = {};
        for (const id of ["foreign-reply", "implicit-reply", "pending", "list"]) seen.results[id] = toolResultText(context, id)!;
        return fauxAssistantMessage([reportCall()], { stopReason: "toolUse" });
      },
    ]);
    const run = await dispatch(f);
    const result = await run.completion;
    expect(result.terminalEvidence).toMatchObject({ outcome: "final", reason: "explicit-report" });
    for (const id of ["foreign-reply", "implicit-reply"]) {
      expect(seen.results?.[id]).toMatchObject({ isError: true, text: HOME_TASK_PRODUCER_REFUSAL_REASON });
    }
    for (const id of ["pending", "list"]) expect(seen.results?.[id]?.text).not.toBe(HOME_TASK_PRODUCER_REFUSAL_REASON);
    expect(f.signals).toContainEqual(expect.objectContaining({ event: "home.task.producer-refused", reason: "subagent-mutation" }));
  }, 60_000);

  it("answers a supervisor request from its own run, and the request wakes the waiting task", async () => {
    const f = await fixture(false, false, undefined, true);
    const child = await childModel(f);
    const seen: { requestId?: string; answer?: { isError: boolean; text: string } } = {};
    f.faux.setResponses([
      holdingAsyncLaunch("async-launch", "ASK-SUPERVISOR which branch should the search take?"),
      fauxAssistantMessage("Launched the search; waiting for its question."),
      // The child's question wakes the task: the worker replies to that exact request.
      async () => {
        const slot = await f.registry.acquire(run.sessionId);
        const request = slot.canonicalSessionEntries().findLast(entry => entry.type === "custom_message"
          && entry.customType === "subagent_supervisor_request") as { details?: { requestId?: string } } | undefined;
        seen.requestId = request?.details?.requestId;
        return fauxAssistantMessage([fauxToolCall("subagent_supervisor", { action: "reply", replyTo: seen.requestId, message: "Proceed" }, { id: "answer" })], { stopReason: "toolUse" });
      },
      async (context: FauxContext) => {
        seen.answer = toolResultText(context, "answer");
        const slot = await f.registry.acquire(run.sessionId);
        await waitFor(() => !slot.catalogHasActiveSubagents, "answered run ended before the report", bound);
        return fauxAssistantMessage([reportCall()], { stopReason: "toolUse" });
      },
    ]);
    const run = await dispatch(f);
    const slot = await f.registry.acquire(run.sessionId);
    await waitFor(() => child.heldRequests() === 1, "child live before its question", bound);
    await waitBetweenTurns(slot);
    child.releaseHeld();
    const result = await run.completion;
    expect(seen.requestId).toEqual(expect.any(String));
    expect(seen.answer).toMatchObject({ isError: false });
    expect(seen.answer?.text).not.toBe(HOME_TASK_PRODUCER_REFUSAL_REASON);
    expect(result.terminalEvidence).toMatchObject({ outcome: "final", reason: "explicit-report" });
    expect(child.abortedRequests()).toBe(0);
  }, 60_000);
});
