import { mkdir, readFile, readdir, writeFile } from "node:fs/promises";
import { basename, dirname, join } from "node:path";
import { fauxAssistantMessage, fauxToolCall } from "@earendil-works/pi-ai";
import { afterEach, describe, expect, it, vi } from "vitest";
import { dispatch, fixture, reportCall } from "../../test-support/home-task-fixture.js";
import { DETACHED_WORKFLOW_SCRIPT, HELD_WORKFLOW_SCRIPT } from "../../test-support/home-task-subagent-child.js";
import { HOME_TASK_SUBAGENT_STOP_JOIN_MS } from "./home-task-subagents.js";
import { waitFor } from "../../test-support/wait-for.js";
import { closeSubagentFixtures, bound, childModel, captureTimer, captureDeadline, launchResults, asyncState, holdingWorkflowLaunch, workflowChildRunId, holdingAsyncLaunch, waitBetweenTurns, toolResultText, type FauxContext } from "../../test-support/home-task-subagents-support.js";

afterEach(closeSubagentFixtures);

describe("Home task subagents: settlement and stop", () => {
  it.each(["error", "stop"] as const)("proves no-report owner settlement after %s from bound canonical receipts, not terminal zero runs", async ending => {
    const f = await fixture(false, false, undefined, true);
    const child = await childModel(f);
    f.faux.setResponses([
      holdingAsyncLaunch("async-launch"),
      async () => {
        await waitFor(() => child.heldRequests() === 1, "child live before parent error", bound);
        if (ending === "stop") {
          child.releaseHeld();
          const slot = await f.registry.acquire(run.sessionId);
          await waitFor(() => !slot.catalogHasActiveSubagents, "child completed before no-report parent", bound);
        }
        return fauxAssistantMessage("Parent ended without a report", { stopReason: ending,
          ...(ending === "error" ? { errorMessage: "fixture failure" } : {}) });
      },
    ]);
    const run = await f.registry.homeOwner().dispatchTask(f.home.sessionId, {
      taskId: "owner-no-report", intent: "Finite work", target: f.cwd,
      model: { provider: f.model.provider, id: f.model.id },
    });
    const result = await run.completion;
    expect(result.terminalEvidence).toMatchObject({ outcome: "unknown", reason: "no-report" });
    const status = await f.registry.homeOwner().taskStatus(run.taskId);
    const stoppedAtEnd = ending === "error" ? 1 : 0;
    expect(status).toMatchObject({ subagents: { started: 1, stoppedAtEnd }, subagentRuns: { total: 0, runs: [] },
      ownerSettlement: { taskId: run.taskId, sessionId: run.sessionId, operationId: run.operationId, stoppedAtEnd,
        markerEntryId: expect.any(String), terminalEntryId: expect.any(String), settlementEntryId: expect.any(String) } });
    const [launch] = (await launchResults(f.registry, run.sessionId)).filter(item => item.toolCallId === "async-launch");
    expect(await asyncState(launch!.details!.asyncDir as string)).toBe(ending === "error" ? "stopped" : "complete");
    if (ending === "error") await waitFor(() => child.abortedRequests() === 1, "joined child request closed", bound);

    // Corrupt real fixture transcript bytes, not a mock proof object. The status
    // consumer must refuse despite the terminal task's synthetic zero-run list.
    const slot = await f.registry.acquire(run.sessionId);
    const path = slot.sessionFile!;
    const original = await readFile(path, "utf8");
    const rows = original.trimEnd().split("\n").map(line => JSON.parse(line));
    const markerId = status.ownerSettlement!.markerEntryId;
    const terminalId = status.ownerSettlement!.terminalEntryId;
    const settlementId = status.ownerSettlement!.settlementEntryId;
    const cases: Array<[string, (entries: any[]) => void]> = [
      ["missing settlement", entries => entries.splice(entries.findIndex(row => row.id === settlementId), 1)],
      ["missing terminal", entries => entries.splice(entries.findIndex(row => row.id === terminalId), 1)],
      ["missing start", entries => entries.splice(entries.findIndex(row => row.data?.receiptKind === "start"), 1)],
      ["start invocation mismatch", entries => { entries.find(row => row.data?.receiptKind === "start").data.invocationId = "other"; }],
      ["marker generation mismatch", entries => { entries.find(row => row.id === markerId).data.generation += 1; }],
      ["settlement before terminal", entries => {
        const index = entries.findIndex(row => row.id === settlementId);
        const [settlement] = entries.splice(index, 1); entries.splice(entries.findIndex(row => row.id === terminalId), 0, settlement);
      }],
      ["failed settlement", entries => { entries.find(row => row.id === settlementId).data.stoppedAtEnd = null; }],
      ["malformed settlement", entries => { entries.find(row => row.id === settlementId).data.stoppedAtEnd = "1"; }],
      ["settlement operation mismatch", entries => { entries.find(row => row.id === settlementId).data.operationId = "other"; }],
      ["marker task mismatch", entries => { entries.find(row => row.id === markerId).data.taskId = "other"; }],
      ["marker session mismatch", entries => { entries.find(row => row.id === markerId).data.sessionId = "other"; }],
      ["marker operation mismatch", entries => { entries.find(row => row.id === markerId).data.operationId = "other"; }],
      ["terminal operation mismatch", entries => { entries.find(row => row.id === terminalId).data.operationId = "other"; }],
      ["terminal session mismatch", entries => { entries.find(row => row.id === terminalId).data.sessionId = "other"; }],
      ["terminal task mismatch", entries => { entries.find(row => row.id === terminalId).data.origin.ownerId = "other"; }],
      ["unknown invocation lifecycle", entries => { entries.find(row => row.id === terminalId).data.lifecycle = "outcomeUnknown"; }],
      ["malformed invocation", entries => { entries.find(row => row.id === terminalId).data.sequence = "2"; }],
      ["duplicate settlement", entries => { entries.push({ ...entries.find(row => row.id === settlementId), id: "duplicate" }); }],
      ["work after settlement", entries => { entries.push({ ...entries.find(row => row.id === terminalId), id: "late-work" }); }],
    ];
    try {
      for (const [name, corrupt] of cases) {
        const changed = structuredClone(rows); corrupt(changed);
        await writeFile(path, changed.map(row => JSON.stringify(row)).join("\n") + "\n");
        expect((await f.registry.homeOwner().taskStatus(run.taskId)).ownerSettlement, name).toBeNull();
      }
    } finally { await writeFile(path, original); }
    expect((await f.registry.homeOwner().taskStatus(run.taskId)).ownerSettlement).toEqual(status.ownerSettlement);

    // Replace the durable task identity while the canonical read is in flight.
    const taskDir = join(f.tronHome, "gateway/home/tasks");
    const taskPath = join(taskDir, (await readdir(taskDir)).find(name => name.endsWith(`-${run.taskId}.json`))!);
    const taskBytes = await readFile(taskPath, "utf8");
    const read = f.registry.readTaskEvidence.bind(f.registry);
    const gate = vi.spyOn(f.registry, "readTaskEvidence").mockImplementationOnce(async sessionId => {
      const entries = await read(sessionId);
      await writeFile(taskPath, JSON.stringify({ ...JSON.parse(taskBytes), operationId: "replacement-operation" }));
      return entries;
    });
    try { await expect(f.registry.homeOwner().taskStatus(run.taskId)).rejects.toThrow(/changed during status inspection/); }
    finally { gate.mockRestore(); await writeFile(taskPath, taskBytes); }
  }, 60_000);

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
    // Default launches create provider-owned missions. Task settlement must join
    // the exact run's mission update too, or active records escape terminal retention.
    const runId = basename(launch!.details!.asyncDir as string);
    const missionRoot = join(f.agentDir, "missions", "projects");
    const missionFiles = (await readdir(missionRoot, { recursive: true })).filter(path => path.endsWith(".json"));
    const missionRows = await Promise.all(missionFiles.map(async path => JSON.parse(await readFile(join(missionRoot, path), "utf8")) as {
      status: string; runs: Array<{ runId: string; status: string }>;
    }));
    const linkedMissions = missionRows.filter(row => row.runs.some(run => run.runId === runId));
    const evidence = { runState: await asyncState(launch!.details!.asyncDir as string),
      missions: linkedMissions.map(row => ({ status: row.status, run: row.runs.find(run => run.runId === runId)?.status })) };
    await mkdir("test-results", { recursive: true });
    await writeFile("test-results/stopped-subagent-mission.json", JSON.stringify(evidence, null, 2));
    expect(evidence).toEqual({ runState: "stopped", missions: [{ status: "cancelled", run: "stopped" }] });
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

  it.each(["ordinary", "refresh during selection"])("stops a workflow's async child that outlives its completed workflow when the task is stopped while it waits (%s)", async (interleaving) => {
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
    // Force the real artifact publisher into the suspended stop-target read.
    // It reorders the activity map; neither the provider result nor its run
    // state is mocked. A live Map iterator must not revisit that same child.
    const boundary = slot as unknown as {
      liveWorkflowChildRunIds(directory: string, children: readonly unknown[]): Promise<string[]>;
      refreshExtensionActivityFromArtifact(toolCallId: string, directory: string): Promise<void>;
    };
    const readChildren = boundary.liveWorkflowChildRunIds.bind(boundary);
    let refreshed = false;
    if (interleaving === "refresh during selection") {
      vi.spyOn(boundary, "liveWorkflowChildRunIds").mockImplementation(async (directory, children) => {
        const ids = await readChildren(directory, children);
        if (!refreshed) {
          refreshed = true;
          await boundary.refreshExtensionActivityFromArtifact("workflow-launch", directory);
        }
        return ids;
      });
    }
    await f.registry.homeOwner().stopTask({ taskId: run.taskId, operationId: run.operationId });
    const result = await run.completion;
    expect(refreshed).toBe(interleaving === "refresh during selection");
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
});
