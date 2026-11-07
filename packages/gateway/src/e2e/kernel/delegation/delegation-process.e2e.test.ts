import { mkdir, writeFile } from "node:fs/promises";
import { join } from "node:path";
import { afterEach, describe, expect, it } from "vitest";
import { startGatewayProcess, type GatewayProcess, type ProcessClient } from "../../../../test-support/gateway-process.js";
import { awaitsWithin, waitFor } from "../../../../test-support/wait-for.js";

/**
 * A delegated child result and its cancellation across the client socket
 * (#2231): a source Gateway process with its real managed pi-subagents install
 * running a foreground child session (its model calls leave the Gateway process
 * itself), the production loopback WebSocket, and a scripted HTTP provider
 * (parent and child models, told apart by model id) as the only scripted party.
 */

const gateways: GatewayProcess[] = [];
afterEach(async () => { await Promise.all(gateways.splice(0).map((gateway) => gateway.dispose())); });

const CHILD_MODEL = "scripted-alternate";
type Snapshot = { phase: string; operation?: unknown; transcript: Array<Record<string, any>>; processActivities?: Array<Record<string, any>> };

async function delegatingGateway(): Promise<GatewayProcess> {
  const gateway = await startGatewayProcess();
  gateways.push(gateway);
  // A user-scope agent: its definition needs no project trust.
  await mkdir(join(gateway.agentDir, "agents"), { recursive: true });
  await writeFile(join(gateway.agentDir, "agents", "task-child.md"),
    `---\nname: task-child\ndescription: Scripted task child\nmodel: scripted/${CHILD_MODEL}\ntools: read\n---\nComplete the scripted task.\n`);
  return gateway;
}

async function openAndSync(client: ProcessClient, sessionId: string): Promise<Snapshot> {
  const opened = await client.request("session.open", { sessionId });
  expect(opened.ok, JSON.stringify(opened)).toBe(true);
  const synced = await client.request("session.sync", { sessionId, syncToken: opened.result.syncToken });
  expect(synced.ok, JSON.stringify(synced)).toBe(true);
  return opened.result.session as Snapshot;
}

async function freshSnapshot(gateway: GatewayProcess, sessionId: string): Promise<Snapshot> {
  const client = await gateway.connect();
  try { return await openAndSync(client, sessionId); } finally { await client.close(); }
}

async function prompt(gateway: GatewayProcess, phone: ProcessClient, label: string): Promise<{ sessionId: string; operationId: string }> {
  const created = await phone.request("session.create", { commandId: `${label}-create`, cwd: gateway.cwd });
  expect(created.ok, JSON.stringify(created)).toBe(true);
  const sessionId = created.result.sessionId as string;
  await openAndSync(phone, sessionId);
  const admitted = await phone.request("session.prompt", { commandId: `${label}-prompt`, sessionId, text: "Delegate the scripted task." });
  expect(admitted.ok, JSON.stringify(admitted)).toBe(true);
  return { sessionId, operationId: admitted.result.operationId as string };
}

const subagentCall = { toolCalls: [{ id: "call-subagent", name: "subagent", arguments: { agent: "task-child", task: "Scripted child task", async: false } }] };
const toolResults = (snapshot: Snapshot) => snapshot.transcript.filter((item) => item.kind === "message" && item.role === "toolResult");
const childRequests = (gateway: GatewayProcess) => gateway.provider.requests.filter((request) => request.model === CHILD_MODEL);
// The protocol's terminal process states (kernel/projection/process-activity.ts).
const TERMINAL_STATES = ["completed", "failed", "stopped", "rejected", "interrupted"];
const subagents = (snapshot: Snapshot) => (snapshot.processActivities ?? []).filter((activity) => activity.kind === "subagent");
const liveSubagents = (snapshot: Snapshot) => subagents(snapshot).filter((activity) => !TERMINAL_STATES.includes(activity.lifecycle?.state));

describe("delegation across the client socket of a real Gateway process", () => {
  it("returns a foreground child's answer to the parent (#2231)", async () => {
    const gateway = await delegatingGateway();
    gateway.provider.script([
      () => subagentCall,
      () => ({ chunks: ["CHILD-ANSWER-7"] }),
      () => ({ chunks: ["The parent read the child's answer."] }),
    ]);
    const phone = await gateway.connect();
    const { sessionId } = await prompt(gateway, phone, "delegate-result");
    const settled = await waitFor(async () => {
      const snapshot = await freshSnapshot(gateway, sessionId);
      return snapshot.phase === "idle" && !snapshot.operation
        && JSON.stringify(snapshot.transcript).includes("The parent read the child's answer.") ? snapshot : undefined;
    }, "the parent settled after its child");
    const results = toolResults(settled);
    expect(results).toHaveLength(1);
    expect(results[0]).toMatchObject({ toolName: "subagent", toolCallId: "call-subagent", isError: false });
    expect(JSON.stringify(results[0]!.content)).toContain("CHILD-ANSWER-7");
    expect(subagents(settled)).toHaveLength(1);
    expect(subagents(settled)[0]).toMatchObject({ toolCallId: "call-subagent", lifecycle: { state: "completed" } });
    expect(subagents(settled)[0]!.lifecycle.terminalAt).toEqual(expect.any(String));
    expect(gateway.provider.requests.map((request) => request.model)).toEqual(["scripted-model", CHILD_MODEL, "scripted-model"]);
    // The parent's second request carries the child's answer bytes as the tool result.
    const toolMessage = gateway.provider.requests[2]!.messages.find((message) => message.role === "tool");
    expect(toolMessage?.tool_call_id).toBe("call-subagent");
    expect(JSON.stringify(toolMessage?.content)).toContain("CHILD-ANSWER-7");
    expect(gateway.provider.errors).toEqual([]);
    await phone.close();
  });

  it("cancels a live child when the phone aborts the parent operation (#2231)", async () => {
    const gateway = await delegatingGateway();
    let reach = (): void => {};
    let childAborted = (): void => {};
    const reached = new Promise<void>((resolve) => { reach = resolve; });
    const aborted = new Promise<void>((resolve) => { childAborted = resolve; });
    gateway.provider.script([
      () => subagentCall,
      // The child's model call is held until the child session drops it.
      (_request, signal) => new Promise((_resolve, reject) => {
        signal.addEventListener("abort", () => { childAborted(); reject(new Error("child request aborted")); });
        reach();
      }),
    ]);
    const phone = await gateway.connect();
    const { sessionId, operationId } = await prompt(gateway, phone, "delegate-abort");
    await awaitsWithin(reached, "the child's held model request");
    await waitFor(async () => {
      const live = await freshSnapshot(gateway, sessionId);
      return live.phase === "running" && liveSubagents(live).length === 1 || undefined;
    }, "the running parent projects one live child row");

    const abort = await phone.request("session.abort", { commandId: "delegate-abort-command", sessionId, operationId });
    expect(abort.ok, JSON.stringify(abort)).toBe(true);
    await awaitsWithin(aborted, "the child dropped its model request");
    const settled = await waitFor(async () => {
      const snapshot = await freshSnapshot(gateway, sessionId);
      return snapshot.phase === "idle" && !snapshot.operation && liveSubagents(snapshot).length === 0 ? snapshot : undefined;
    }, "the parent settled with no live child");
    const results = toolResults(settled);
    expect(results).toHaveLength(1);
    expect(results[0]).toMatchObject({ toolName: "subagent", toolCallId: "call-subagent", isError: true });
    expect(JSON.stringify(results[0]!.content)).toContain("Request aborted");
    // The aborted child is terminal and did not complete. Which terminal state a
    // user cancel should read (today `failed`) is the open decision in #2238.
    const activities = subagents(settled);
    expect(activities).toHaveLength(1);
    expect(activities[0]!.toolCallId).toBe("call-subagent");
    expect(TERMINAL_STATES.filter((state) => state !== "completed")).toContain(activities[0]!.lifecycle.state);
    expect(activities[0]!.lifecycle.terminalAt).toEqual(expect.any(String));
    expect(settled.transcript.at(-1)).toMatchObject({ kind: "message", role: "assistant", stopReason: "aborted" });
    expect(childRequests(gateway)).toHaveLength(1);
    expect(gateway.provider.requests).toHaveLength(2);
    expect(gateway.provider.errors).toEqual([]);
    await phone.close();
  });

  it("reports a child cancelled by the phone's abort as stopped, on the child and on its parent run (#2238)", async () => {
    const gateway = await delegatingGateway();
    let reach = (): void => {};
    let childAborted = (): void => {};
    const reached = new Promise<void>((resolve) => { reach = resolve; });
    const aborted = new Promise<void>((resolve) => { childAborted = resolve; });
    gateway.provider.script([
      () => subagentCall,
      (_request, signal) => new Promise((_resolve, reject) => {
        signal.addEventListener("abort", () => { childAborted(); reject(new Error("child request aborted")); });
        reach();
      }),
    ]);
    const phone = await gateway.connect();
    const { sessionId, operationId } = await prompt(gateway, phone, "delegate-stopped");
    await awaitsWithin(reached, "the child's held model request");
    await waitFor(async () => liveSubagents(await freshSnapshot(gateway, sessionId)).length === 1 || undefined,
      "the running parent projects one live child row");
    const abort = await phone.request("session.abort", { commandId: "delegate-stopped-abort", sessionId, operationId });
    expect(abort.ok, JSON.stringify(abort)).toBe(true);
    await awaitsWithin(aborted, "the child dropped its model request");
    const settled = await waitFor(async () => {
      const snapshot = await freshSnapshot(gateway, sessionId);
      return snapshot.phase === "idle" && !snapshot.operation && liveSubagents(snapshot).length === 0 ? snapshot : undefined;
    }, "the parent settled with no live child");
    // A user's cancel is a stop, as it is for the parent turn: the child's process
    // row and the parent's delegated run both read stopped, and neither is a problem.
    expect(subagents(settled).map((activity) => [activity.toolCallId, activity.lifecycle.state])).toEqual([["call-subagent", "stopped"]]);
    const run = ((settled as Record<string, any>).extensionActivities as Array<Record<string, any>>).find((activity) => activity.toolCallId === "call-subagent");
    expect(run?.lifecycle?.state).toBe("stopped");
    expect(run?.children?.map((child: Record<string, unknown>) => child.lifecycle)).toEqual(["stopped"]);
    expect((settled as Record<string, any>).processOverview?.problemCount).toBe(0);
    expect(childRequests(gateway)).toHaveLength(1);
    expect(gateway.provider.errors).toEqual([]);
    await phone.close();
  });
});
