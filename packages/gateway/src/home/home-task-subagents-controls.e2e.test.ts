import assert from "node:assert/strict";
import { readFile, writeFile } from "node:fs/promises";
import { basename, dirname, join } from "node:path";
import { fauxAssistantMessage, fauxToolCall } from "@earendil-works/pi-ai";
import { afterEach, describe, expect, it, vi } from "vitest";
import { dispatch, fixture, reportCall } from "../../test-support/home-task-fixture.js";
import { HELD_WORKFLOW_SCRIPT, STEERED_WORKFLOW_SCRIPT } from "../../test-support/home-task-subagent-child.js";
import { HOME_TASK_PRODUCER_REFUSAL_REASON } from "./home-task-worker-extension.js";
import { HOME_TASK_SUBAGENT_STOP_JOIN_MS } from "./home-task-subagents.js";
import { waitFor } from "../../test-support/wait-for.js";
import { closeSubagentFixtures, bound, childModel, captureTimer, captureDeadline, launchResults, asyncState, holdingWorkflowLaunch, workflowChildRunId, holdingAsyncLaunch, waitBetweenTurns, toolResultText, launchedAsyncDir, type FauxContext } from "../../test-support/home-task-subagents-support.js";

afterEach(closeSubagentFixtures);

describe("Home task subagents: waiting, wakes and run controls", () => {
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

  it("continues the waiting task from Home's steering and the maintainer's message in one ordered lane (#929)", async () => {
    const f = await fixture(false, false, undefined, true);
    const child = await childModel(f);
    const turns: string[] = [];
    const lastUser = (context: FauxContext) => {
      const content = context.messages.findLast(message => message.role === "user")?.content;
      return typeof content === "string" ? content : (content ?? []).map((part: { type: string; text?: string }) => part.text ?? "").join("");
    };
    f.faux.setResponses([
      holdingAsyncLaunch("async-launch"),
      fauxAssistantMessage("Launched the background check; waiting for it."),
      (context: FauxContext) => { turns.push(lastUser(context)); return fauxAssistantMessage("Noted Home's instruction."); },
      (context: FauxContext) => { turns.push(lastUser(context)); return fauxAssistantMessage("Noted the maintainer's message."); },
      async () => fauxAssistantMessage([reportCall("report-after-shared-lane")], { stopReason: "toolUse" }),
    ]);
    const run = await dispatch(f);
    const slot = await f.registry.acquire(run.sessionId);
    await waitFor(() => child.heldRequests() === 1, "async child live", bound);
    await waitBetweenTurns(slot);
    await f.registry.homeOwner().steerTask(f.home.sessionId, { taskId: run.taskId, operationId: run.operationId, text: "Home between turns" });
    await waitFor(() => turns.length === 1, "Home's steering starts the task's next turn", bound);
    await waitFor(() => (slot as unknown as { taskWait?: { wakeOperationId?: string } }).taskWait?.wakeOperationId === undefined
      && (slot as unknown as { taskWait?: unknown }).taskWait !== undefined, "task waits again", bound);
    // The maintainer's composer sends an ordinary prompt; it joins the same lane, not refused.
    await slot.prompt("Maintainer between turns");
    await waitFor(() => turns.length === 2, "the maintainer's message starts the task's next turn", bound);
    await waitBetweenTurns(slot);
    child.releaseHeld();
    const result = await run.completion;
    expect(result.terminalEvidence).toMatchObject({ outcome: "final", reason: "explicit-report" });
    expect(turns).toEqual(["Home between turns", "Maintainer between turns"]);
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

  it("steers and interrupts a long bash command inside a provider wake's turn, and seals its report over a queued steer (#1251)", async () => {
    const f = await fixture(false, false, undefined, true);
    const child = await childModel(f);
    const pidFile = join(f.cwd, "wake-command.pid");
    const alive = (pid: number) => { try { process.kill(pid, 0); return true; } catch { return false; } };
    const pid = async () => { try { return Number(await readFile(pidFile, "utf8")); } catch { return 0; } };
    let openReportTurn!: () => void;
    const reportTurnOpen = new Promise<void>(resolve => { openReportTurn = resolve; });
    const seen: string[] = [];
    let reportTurnStarted = false;
    f.faux.setResponses([
      holdingAsyncLaunch("async-launch"),
      fauxAssistantMessage("Launched the background check; waiting for it."),
      // The provider wake starts the task's next turn, which runs a long command.
      () => fauxAssistantMessage([fauxToolCall("bash", { command: `echo $$ > ${pidFile}; exec sleep 600` }, { id: "wake-stuck" })], { stopReason: "toolUse" }),
      // The turn after the interrupt reads Home's steering, then is held while a second steer queues.
      async (context: FauxContext, options?: { signal?: AbortSignal }) => {
        seen.push(...context.messages.filter(message => message.role === "user").map(message => typeof message.content === "string"
          ? message.content : (message.content as Array<{ text?: string }>).map(part => part.text ?? "").join("")));
        reportTurnStarted = true;
        await new Promise<void>((resolve, reject) => {
          void reportTurnOpen.then(resolve);
          options?.signal?.addEventListener("abort", () => reject(new Error("stopped")), { once: true });
        });
        return fauxAssistantMessage([reportCall("wake-steered", "Steered and interrupted in the wake turn")], { stopReason: "toolUse" });
      },
    ]);
    const run = await dispatch(f);
    const slot = await f.registry.acquire(run.sessionId);
    await waitFor(() => child.heldRequests() === 1, "async child live", bound);
    await waitBetweenTurns(slot);
    child.releaseHeld();
    await waitFor(async () => { const value = await pid(); return value > 0 && alive(value); }, "the wake turn's command running", bound);
    const commandPid = await pid();

    const steered = await f.registry.homeOwner().taskTool(f.home.sessionId, { action: "steer", taskId: run.taskId, text: "STEER-DURING-WAKE" });
    expect(steered).toMatchObject({ accepted: true, taskId: run.taskId });
    const interrupted = await f.registry.homeOwner().taskTool(f.home.sessionId, { action: "interrupt", taskId: run.taskId });
    expect(interrupted).toMatchObject({ accepted: true, interrupted: ["bash"] });
    await waitFor(() => !alive(commandPid), "the wake turn's command to end", bound);
    await waitFor(() => reportTurnStarted, "the turn that reads the steer", bound);
    expect(seen.join("\n")).toMatch(/STEER-DURING-WAKE/u);
    // A control the owner refuses is recorded with its reason, and only hashed identifiers leave the Gateway.
    await expect(f.registry.homeOwner().steerTask(f.home.sessionId, { taskId: run.taskId, operationId: "stale-operation", text: "late" })).rejects.toThrow(/Stale or terminal task operation/u);
    const refused = f.signals.filter(record => record.event === "home.task.control" && record.disposition === "refused");
    expect(refused).toEqual([expect.objectContaining({ action: "steer", reason: "stale-operation" })]);
    expect(JSON.stringify(refused)).not.toContain(run.taskId);

    // A steer queued while the report's turn streams is still undelivered when the report seals the task.
    await f.registry.homeOwner().taskTool(f.home.sessionId, { action: "steer", taskId: run.taskId, text: "STEER-AFTER-REPORT" });
    openReportTurn();
    const result = await run.completion;
    expect(result.terminalEvidence).toMatchObject({ outcome: "final", reason: "explicit-report" });
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
    const seen: { resume?: ReturnType<typeof toolResultText> } = {};
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
    const seen: { stop?: ReturnType<typeof toolResultText>; workflowDir?: string } = {};
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

  it("steers a workflow child by its own run id, and the steer reaches the child's model", async () => {
    const f = await fixture(false, false, undefined, true);
    const child = await childModel(f);
    await writeFile(join(f.cwd, "steered-workflow.js"), STEERED_WORKFLOW_SCRIPT);
    const seen: { workflowDir?: string; childRunId?: string; steer?: ReturnType<typeof toolResultText> } = {};
    f.faux.setResponses([
      fauxAssistantMessage([fauxToolCall("subagent", { workflow: "./steered-workflow.js", async: true }, { id: "workflow-launch" })], { stopReason: "toolUse" }),
      async (context: FauxContext) => {
        await waitFor(() => child.heldRequests() === 1, "workflow child live", bound);
        seen.workflowDir = launchedAsyncDir(context, "workflow-launch");
        seen.childRunId = await workflowChildRunId(seen.workflowDir);
        // The provider's guidance names the child's own run id, so the worker steers that id.
        return fauxAssistantMessage([fauxToolCall("subagent", { action: "steer", id: seen.childRunId, message: "STEER-PROBE change course" }, { id: "steer-child" })], { stopReason: "toolUse" });
      },
      async (context: FauxContext) => {
        seen.steer = toolResultText(context, "steer-child");
        // The held child answers with a tool call; its next request carries the steer.
        child.releaseHeld();
        const slot = await f.registry.acquire(run.sessionId);
        await waitFor(() => child.steerProbeRequests() === 1, "steer reached the child's model", bound);
        await waitFor(() => !slot.catalogHasActiveSubagents, "steered workflow child ended before the report", bound);
        return fauxAssistantMessage([reportCall()], { stopReason: "toolUse" });
      },
    ]);
    const run = await dispatch(f);
    const result = await run.completion;
    expect(seen.steer).toMatchObject({ isError: false });
    expect(seen.steer?.text).not.toBe(HOME_TASK_PRODUCER_REFUSAL_REASON);
    expect(result.terminalEvidence).toMatchObject({ outcome: "final", reason: "explicit-report" });
    expect(child.steerProbeRequests()).toBe(1);
    expect(await asyncState(join(dirname(seen.workflowDir!), seen.childRunId!))).toBe("complete");
  }, 60_000);

  it("refuses a control of a workflow child that another task's workflow owns, and of an unknown run id", async () => {
    const f = await fixture(false, false, undefined, true);
    const child = await childModel(f);
    await writeFile(join(f.cwd, "hold-workflow.js"), HELD_WORKFLOW_SCRIPT);
    const seen: { foreignChildRunId?: string; results?: Record<string, { isError: boolean; text: string }> } = {};
    f.faux.setResponses([
      // The first task launches a held workflow, then waits for it between turns.
      holdingWorkflowLaunch("workflow-launch"),
      fauxAssistantMessage("Launched the search; waiting for it."),
      // The second task controls the first task's workflow child, and an id no task owns.
      () => {
        assert.ok(seen.foreignChildRunId, "the first task must publish its workflow child ID before the foreign control");
        return fauxAssistantMessage([
          fauxToolCall("subagent", { action: "steer", id: seen.foreignChildRunId, message: "STEER-PROBE" }, { id: "foreign-steer" }),
          fauxToolCall("subagent", { action: "stop", id: "unknown-run-id" }, { id: "unknown-stop" }),
        ], { stopReason: "toolUse" });
      },
      (context: FauxContext) => {
        for (const id of ["foreign-steer", "unknown-stop"]) seen.results = { ...seen.results, [id]: toolResultText(context, id)! };
        return fauxAssistantMessage([reportCall()], { stopReason: "toolUse" });
      },
    ]);
    const first = await dispatch(f, "task-one");
    const firstSlot = await f.registry.acquire(first.sessionId);
    await waitFor(() => child.heldRequests() === 1, "first task's workflow child live", bound);
    await waitBetweenTurns(firstSlot);
    const [launch] = (await launchResults(f.registry, first.sessionId)).filter(item => item.toolCallId === "workflow-launch");
    seen.foreignChildRunId = await workflowChildRunId(launch!.details!.asyncDir as string);
    const second = await dispatch(f, "task-two");
    const secondResult = await second.completion;
    expect(secondResult.terminalEvidence).toMatchObject({ outcome: "final", reason: "explicit-report" });
    for (const id of ["foreign-steer", "unknown-stop"]) {
      expect(seen.results?.[id]).toMatchObject({ isError: true, text: HOME_TASK_PRODUCER_REFUSAL_REASON });
    }
    expect(child.steerProbeRequests()).toBe(0);
    // The workflow's launch of its stopped child notices the stop at its next status poll
    // (the provider's waitForImportedAsyncRoot), then records the child's outcome in the
    // workflow's mission. Stretching only that poll widens the window in which the launch
    // settles after the stop: the stopped workflow must still publish its outcome, and the
    // task settle, only after that record, so nothing writes the mission after the task settled and its fixture was
    // disposed (#1078: ENOTEMPTY on agent/missions).
    const setTimer = globalThis.setTimeout;
    vi.spyOn(globalThis, "setTimeout").mockImplementation(((callback: (...args: unknown[]) => void, delay?: number, ...args: unknown[]) =>
      setTimer(callback, new Error().stack?.includes("waitForImportedAsyncRoot") ? 3_000 : delay, ...args)) as typeof setTimeout);
    await f.registry.homeOwner().stopTask({ taskId: first.taskId, operationId: first.operationId });
    expect((await first.completion).terminalEvidence).toMatchObject({ outcome: "interrupted", reason: "task-stop" });
    const mission = JSON.parse(await readFile(launch!.details!.missionPath as string, "utf8")) as { workflowChildren?: Array<{ key: string; status: string }> };
    expect(mission.workflowChildren?.find(entry => entry.key === "hold")?.status).not.toBe("running");
    expect(await asyncState(join(dirname(launch!.details!.asyncDir as string), seen.foreignChildRunId!))).toBe("stopped");
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
    const seen: { requestId?: string; answer?: ReturnType<typeof toolResultText> } = {};
    f.faux.setResponses([
      holdingAsyncLaunch("async-launch", "ASK-SUPERVISOR which branch should the search take?"),
      fauxAssistantMessage("Launched the search; waiting for its question."),
      // The child's question wakes the task: the worker replies to that exact request.
      async () => {
        const slot = await f.registry.acquire(run.sessionId);
        const request = slot.canonicalSessionEntries().findLast(entry => entry.type === "custom_message"
          && entry.customType === "subagent_supervisor_request");
        assert.ok(request?.type === "custom_message", "the wake must retain its canonical supervisor request");
        const details = request.details;
        assert.ok(details && typeof details === "object" && "requestId" in details);
        assert.ok(typeof details.requestId === "string", "the supervisor reply must target the recorded request ID");
        seen.requestId = details.requestId;
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
