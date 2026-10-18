import { mkdir, readFile, writeFile } from "node:fs/promises";
import { dirname, join } from "node:path";
import { fauxAssistantMessage, fauxToolCall } from "@earendil-works/pi-ai";
import { afterEach, expect, it } from "vitest";
import { disposeFixtures, fixture } from "../../test-support/home-task-fixture.js";
import { DETACHED_WORKFLOW_SCRIPT, startScriptedChild, type ChildModelServer } from "../../test-support/home-task-subagent-child.js";
import { waitFor } from "../../test-support/wait-for.js";

// Real managed-provider children, as in the Home task subagent cases: this file runs in the nested serial pass.
type WorkflowStatus = { runId: string; state: string; steps: Array<{ label?: string; runId?: string; sessionFile?: string; sessionOwnerId?: string }> };
const bound = { boundMs: 20_000 };
const servers: ChildModelServer[] = [];
afterEach(async () => {
  for (const server of servers.splice(0)) await server.close();
  await disposeFixtures();
});

it("opens a resumed workflow child's canonical transcript while running and completed", async () => {
  const f = await fixture(false, false, undefined, true);
  const server = await startScriptedChild(f);
  servers.push(server);
  await writeFile(join(f.cwd, "resume-workflow.js"), `
const initial = await runs.run("initial", { agent: "task-child", task: "Initial transcript", acceptance: { level: "none", reason: "Read-only transcript probe" } });
return await runs.run("resumed", { resume: initial.runId, task: "HOLD-CHILD resumed transcript", acceptance: { level: "none", reason: "Read-only transcript probe" } });
`);
  f.faux.setResponses([
    fauxAssistantMessage([fauxToolCall("subagent", { workflow: "./resume-workflow.js", async: true, mission: false }, { id: "resume-workflow-launch" })], { stopReason: "toolUse" }),
    ...Array.from({ length: 12 }, () => fauxAssistantMessage("Parent idle.")),
  ]);
  const slot = await f.registry.create(f.cwd);
  const report: Record<string, unknown> = { passed: false };
  let workflowDir: string | undefined;
  try {
    await slot.prompt("launch the resume workflow");
    await waitFor(() => server.heldRequests() === 1, "the resumed child is live", bound);
    const launch = slot.canonicalSessionEntries().find(entry => entry.type === "message" && entry.message.role === "toolResult" && entry.message.toolCallId === "resume-workflow-launch");
    if (launch?.type !== "message" || launch.message.role !== "toolResult") throw new Error("Missing workflow launch");
    const details = launch.message.details as { asyncDir: string };
    workflowDir = details.asyncDir;
    const workflow = JSON.parse(await readFile(join(workflowDir, "status.json"), "utf8")) as WorkflowStatus;
    report.workflow = workflow;
    const resumed = workflow.steps[1];
    if (!resumed?.runId) throw new Error("Missing resumed execution");
    const execution = JSON.parse(await readFile(join(dirname(workflowDir), resumed.runId, "status.json"), "utf8")) as WorkflowStatus;
    report.execution = execution;
    const sessionFile = execution.steps[0]?.sessionFile;
    if (!sessionFile) throw new Error("Resumed execution does not publish its canonical session file");
    const row = await waitFor(() => slot.snapshot().processActivities?.find(item => item.kind === "subagent" && item.lifecycle.state === "running" && item.childSessionRef), "the resumed transcript binding is published", bound);
    const ref = row.childSessionRef!;
    const admission = await f.registry.resolveReadOnlySubagentPath(ref, sessionFile, slot.id, row.processId, workflow.runId);
    const live = await f.registry.readOnlySubagentTranscriptPage(ref, admission.path, slot.id, row.processId, workflow.runId);
    expect(JSON.stringify(live)).toContain("HOLD-CHILD resumed transcript");
    expect(JSON.stringify(live)).toContain("CHILD-DONE");
    report.live = { processId: row.processId, sessionRef: ref, entries: live.total };
    server.releaseHeld();
    await waitFor(() => !slot.catalogHasActiveSubagents, "the resumed workflow completes", bound);
    const completed = await f.registry.readOnlySubagentTranscriptPage(ref, admission.path, slot.id, row.processId, workflow.runId);
    expect(JSON.stringify(completed)).toContain("HOLD-CHILD resumed transcript");
    expect(completed.total).toBeGreaterThan(live.total);
    report.completed = { entries: completed.total };
    report.passed = true;
  } finally {
    // Keep the model server available while the accepted child finishes; closing
    // its socket instead can trigger SDK retries and outlive fixture teardown.
    server.releaseHeld();
    await waitFor(() => !slot.catalogHasActiveSubagents, "the test-owned workflow settles before cleanup", bound);
    report.snapshot = slot.snapshot().processActivities;
    if (workflowDir) report.finalStatus = JSON.parse(await readFile(join(workflowDir, "status.json"), "utf8"));
    await mkdir("test-results", { recursive: true });
    await writeFile("test-results/managed-workflow-resume.json", JSON.stringify(report, null, 2) + "\n");
  }
}, 60_000);

it("keeps an ordinary session showing a workflow child that outlives its completed workflow, until the child ends", async () => {
  const f = await fixture(false, false, undefined, true);
  const server = await startScriptedChild(f);
  servers.push(server);
  await writeFile(join(f.cwd, "detached-workflow.js"), DETACHED_WORKFLOW_SCRIPT);
  f.faux.setResponses([
    fauxAssistantMessage([fauxToolCall("subagent", { workflow: "./detached-workflow.js", async: true }, { id: "workflow-launch" })], { stopReason: "toolUse" }),
    fauxAssistantMessage("Launched the detached workflow."),
  ]);
  const slot = await f.registry.create(f.cwd);
  await slot.prompt("launch the detached workflow");
  await waitFor(() => server.heldRequests() === 1, "workflow child live after the turn", bound);
  // The turn has settled, but the child it launched is still running, so the session is still active.
  expect(slot.catalogHasActiveSubagents).toBe(true);
  server.releaseHeld();
  await waitFor(() => !slot.catalogHasActiveSubagents, "workflow child ends and the session settles", bound);
}, 60_000);
