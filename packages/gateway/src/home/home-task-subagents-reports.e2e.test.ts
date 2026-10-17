import { existsSync } from "node:fs";
import { mkdir, readFile, stat, writeFile } from "node:fs/promises";
import { basename, dirname, join } from "node:path";
import { fauxAssistantMessage, fauxToolCall } from "@earendil-works/pi-ai";
import { afterEach, describe, expect, it, vi } from "vitest";
import { dispatch, fixture, reportCall } from "../../test-support/home-task-fixture.js";
import { DETACHED_WORKFLOW_SCRIPT, HELD_WORKFLOW_SCRIPT } from "../../test-support/home-task-subagent-child.js";
import { HOME_TASK_PRODUCER_REFUSAL_REASON } from "./home-task-worker-extension.js";
import { waitFor } from "../../test-support/wait-for.js";
import { closeSubagentFixtures, bound, childModel, launchResults, asyncState, holdingWorkflowLaunch, workflowChildRunId, holdingAsyncLaunch, waitBetweenTurns, toolResultText, entryText, launchedAsyncDir, type FauxContext } from "../../test-support/home-task-subagents-support.js";

afterEach(closeSubagentFixtures);

describe("Home task subagents: refusals, restarts and reports", () => {
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
    // The settlement's join fails before any stop: the task reconciles from its canonical file at once (#1166).
    vi.spyOn(slot, "settleTaskSubagents").mockRejectedValue(new Error("injected settlement interruption"));
    await f.registry.homeOwner().stopTask({ taskId: run.taskId, operationId: run.operationId });
    await expect(run.completion).resolves.toMatchObject({ lifecycle: "terminal",
      terminalEvidence: { outcome: "unknown", reason: "detached-work-outlived-task", detail: "injected settlement interruption" } });
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
    // The settlement fails before any stop: the task reconciles from its canonical file at once (#1166).
    vi.spyOn(slot, "settleTaskSubagents").mockRejectedValue(new Error("injected settlement interruption"));
    await f.registry.homeOwner().stopTask({ taskId: run.taskId, operationId: run.operationId });
    await expect(run.completion).resolves.toMatchObject({ lifecycle: "terminal",
      terminalEvidence: { outcome: "unknown", reason: "detached-work-outlived-task", detail: "injected settlement interruption" } });
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
    const seen: { refusal?: ReturnType<typeof toolResultText>; runDir?: string } = {};
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
    const seen: { stop?: ReturnType<typeof toolResultText>; runDir?: string } = {};
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
    const seen: { refusal?: ReturnType<typeof toolResultText>; workflowDir?: string } = {};
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

  it.each(["report", "stop"] as const)("settles a completed workflow's process-exited paused child through %s", async ending => {
    const f = await fixture(false, false, undefined, true);
    const child = await childModel(f);
    await writeFile(join(f.cwd, "detached-workflow.js"), DETACHED_WORKFLOW_SCRIPT);
    const seen: { workflowDir?: string; childDir?: string; interrupt?: ReturnType<typeof toolResultText>; stop?: ReturnType<typeof toolResultText>; completedRootStop?: ReturnType<typeof toolResultText>; refusal?: ReturnType<typeof toolResultText>; liveChildRunId?: string } = {};
    f.faux.setResponses([
      fauxAssistantMessage([fauxToolCall("subagent", { workflow: "./detached-workflow.js", async: true }, { id: "workflow-launch" })], { stopReason: "toolUse" }),
      async (context: FauxContext) => {
        await waitFor(() => child.heldRequests() === 1, "detached child live", bound);
        seen.workflowDir = launchedAsyncDir(context, "workflow-launch");
        const childId = await workflowChildRunId(seen.workflowDir);
        seen.childDir = join(dirname(seen.workflowDir), childId);
        const slot = await f.registry.acquire(run.sessionId);
        await waitFor(() => slot.liveSubagentRuns().length === 1, "detached execution is live", bound);
        seen.liveChildRunId = slot.liveSubagentRuns()[0]?.runId;
        return fauxAssistantMessage([fauxToolCall("subagent", { action: "interrupt", id: childId }, { id: "pause-child" })], { stopReason: "toolUse" });
      },
      async (context: FauxContext) => {
        seen.interrupt = toolResultText(context, "pause-child");
        await waitFor(async () => {
          try { return (await asyncState(seen.childDir!)) === "paused"
            && JSON.parse(await readFile(join(seen.childDir!, "process-terminal.json"), "utf8")).state === "observed"; }
          catch { return false; }
        }, "paused child runner has exited", bound);
        expect(await asyncState(seen.workflowDir!)).toBe("complete");
        if (ending === "stop") return fauxAssistantMessage([fauxToolCall("subagent", { action: "stop", id: basename(seen.childDir!) }, { id: "stop-paused-child" })], { stopReason: "toolUse" });
        return fauxAssistantMessage([fauxToolCall("subagent", { action: "stop", id: basename(seen.workflowDir!) }, { id: "stop-completed-workflow" })], { stopReason: "toolUse" });
      },
      async (context: FauxContext) => {
        if (ending === "stop") seen.stop = toolResultText(context, "stop-paused-child");
        else seen.completedRootStop = toolResultText(context, "stop-completed-workflow");
        const slot = await f.registry.acquire(run.sessionId);
        if (ending === "stop") await waitFor(() => !slot.catalogHasActiveSubagents, "paused child stop joined", bound);
        else await waitFor(() => slot.liveSubagentRuns().every(row => row.state !== "running" && row.state !== "queued"), "paused child artifact frame observed", bound);
        return fauxAssistantMessage([reportCall("report-paused")], { stopReason: "toolUse" });
      },
      async (context: FauxContext) => {
        // Known-bad control: preserve the real refusal, then stop the exact child
        // so even a RED run releases all work instead of timing out in cleanup.
        seen.refusal = toolResultText(context, "call-report-paused");
        return fauxAssistantMessage([fauxToolCall("subagent", { action: "stop", id: basename(seen.childDir!) }, { id: "cleanup-paused-child" })], { stopReason: "toolUse" });
      },
      async () => {
        const slot = await f.registry.acquire(run.sessionId);
        await waitFor(() => !slot.catalogHasActiveSubagents, "known-bad control cleanup joined", bound);
        return fauxAssistantMessage([reportCall("report-after-cleanup")], { stopReason: "toolUse" });
      },
    ]);
    const run = await dispatch(f);
    const result = await run.completion;
    await mkdir("test-results", { recursive: true });
    await writeFile(`test-results/paused-workflow-${ending}.json`, JSON.stringify({ ending, terminalEvidence: result.terminalEvidence,
      interrupt: seen.interrupt, stop: seen.stop, completedRootStop: seen.completedRootStop, refusal: seen.refusal,
      workflowState: await asyncState(seen.workflowDir!), childState: await asyncState(seen.childDir!) }, null, 2));
    expect(seen.refusal).toBeUndefined();
    expect(seen.liveChildRunId).toBe(basename(seen.childDir!));
    expect(seen.interrupt).toMatchObject({ isError: false });
    if (ending === "stop") expect(seen.stop).toMatchObject({ isError: false, text: expect.stringContaining("Stopped paused async run") });
    else expect(seen.completedRootStop).toMatchObject({ isError: true, text: expect.stringContaining("No running or queued async run") });
    expect(await asyncState(seen.childDir!)).toBe(ending === "stop" ? "stopped" : "paused");
    expect(result.terminalEvidence).toMatchObject({ outcome: "final", reason: "explicit-report" });
    expect(await f.registry.homeOwner().taskStatus(run.taskId)).toMatchObject({ subagentRuns: { total: 0, runs: [] }, subagents: { started: 1, stoppedAtEnd: 0 } });
    // Reconciliation must agree with the live report gate, including paused process proof.
    expect(await f.registry.taskSubagentRunsSettled([seen.workflowDir!])).toBe(true);
  }, 60_000);

  it("cold settlement accepts a real completed workflow status larger than 64KiB", async () => {
    const f = await fixture(false, false, undefined, true);
    await childModel(f);
    await writeFile(join(f.cwd, "large-workflow.js"), 'await runs.run("done", { agent: "task-child", task: "CHILD-DONE size probe" });\nreturn "x".repeat(170_000);\n');
    let workflowDir = "";
    f.faux.setResponses([
      fauxAssistantMessage([fauxToolCall("subagent", { workflow: "./large-workflow.js", async: true }, { id: "large-launch" })], { stopReason: "toolUse" }),
      async (context: FauxContext) => {
        workflowDir = launchedAsyncDir(context, "large-launch");
        const slot = await f.registry.acquire(run.sessionId);
        await waitFor(() => !slot.catalogHasActiveSubagents, "large workflow complete", bound);
        return fauxAssistantMessage([reportCall("report-large")], { stopReason: "toolUse" });
      },
    ]);
    const run = await dispatch(f);
    expect((await run.completion).terminalEvidence).toMatchObject({ outcome: "final", reason: "explicit-report" });
    const bytes = (await stat(join(workflowDir, "status.json"))).size;
    expect(bytes).toBeGreaterThan(64 * 1024);
    expect(bytes).toBeLessThan(256 * 1024);
    await f.registry.dispose();
    await f.registry.administrativeWorkRegistry.waitUntilSettled();
    const cold = await f.restart();
    expect(await cold.taskSubagentRunsSettled([workflowDir])).toBe(true);
    expect((await cold.homeOwner().taskResult(run.taskId)).terminalEvidence).toMatchObject({ outcome: "final", reason: "explicit-report" });
    await mkdir("test-results", { recursive: true });
    await writeFile("test-results/large-workflow-cold-settlement.json", JSON.stringify({ bytes, settled: true }, null, 2));
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
});
