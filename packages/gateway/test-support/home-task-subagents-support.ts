import { readFile } from "node:fs/promises";
import { join } from "node:path";
import { fauxAssistantMessage, fauxToolCall } from "@earendil-works/pi-ai";
import { vi } from "vitest";
import { OWNED_OPERATION_DEADLINE_MS } from "../src/sessions/owned-session-dispatch.js";
import { disposeFixtures, type fixture } from "./home-task-fixture.js";
import { startScriptedChild, type ChildModelServer } from "./home-task-subagent-child.js";
import { waitFor } from "./wait-for.js";

// Each wait fails with its own label before the 60 s test timeout (the nested pass
// otherwise declares a 240 s wait bound that outlives every case here).
export const bound = { boundMs: 20_000 };

// Real managed-provider children: a foreground run is an in-process child session and
// an async run is a detached runner, both answering from a scripted HTTP model. Like
// the other managed-provider cases, these files run in the nested serial pass
// (home-task-subagents-*.e2e.test.ts, split so each nested gate shard stays under 5 minutes).
const servers: ChildModelServer[] = [];
/** Each home-task-subagents file registers this after each test. */
export async function closeSubagentFixtures(): Promise<void> {
  vi.restoreAllMocks();
  for (const server of servers.splice(0)) await server.close();
  await disposeFixtures();
}

export async function childModel(f: Awaited<ReturnType<typeof fixture>>): Promise<ChildModelServer> {
  const server = await startScriptedChild(f);
  servers.push(server);
  return server;
}

/** Captures the timers armed with exactly `ms` so a test fires the latest at a chosen point. */
export function captureTimer(ms: number): { expire: () => void; armed: () => boolean } {
  const original = globalThis.setTimeout;
  let fire: (() => void) | undefined;
  vi.spyOn(globalThis, "setTimeout").mockImplementation(((callback: any, delay: number, ...args: any[]) => {
    if (delay === ms) fire = callback;
    return original(callback, delay, ...args);
  }) as typeof setTimeout);
  return { expire: () => { if (!fire) throw new Error(`no ${ms} ms timer is armed`); fire(); }, armed: () => fire !== undefined };
}

/** Captures the one 24-hour deadline timer so a test expires it at a chosen point. */
export const captureDeadline = () => captureTimer(OWNED_OPERATION_DEADLINE_MS);

/** Every `subagent` tool result in the worker's canonical session, launches and refusals alike. */
export async function launchResults(registry: { readTaskEvidence(sessionId: string): Promise<unknown[]> }, sessionId: string) {
  const rows = await registry.readTaskEvidence(sessionId) as any[];
  return rows.filter(row => row.type === "message" && row.message?.role === "toolResult" && row.message.toolName === "subagent")
    .map(row => row.message as { toolCallId: string; isError: boolean; details?: Record<string, unknown> });
}

export async function asyncState(asyncDir: string): Promise<string> {
  return JSON.parse(await readFile(join(asyncDir, "status.json"), "utf8")).state;
}

export const holdingWorkflowLaunch = (id: string) =>
  fauxAssistantMessage([fauxToolCall("subagent", { workflow: "./hold-workflow.js", async: true }, { id })], { stopReason: "toolUse" });
/** The run id of a workflow's one async child, from the workflow's own status. */
export async function workflowChildRunId(workflowDir: string): Promise<string> {
  const status = JSON.parse(await readFile(join(workflowDir, "status.json"), "utf8")) as { steps: Array<{ runId?: string }> };
  return status.steps[0]!.runId!;
}

export const holdingAsyncLaunch = (id: string, task = "HOLD-CHILD background search") =>
  fauxAssistantMessage([fauxToolCall("subagent", { agent: "task-child", task, async: true }, { id })], { stopReason: "toolUse" });

/** The turn has ended and the task holds its operation open between turns, waiting for its live runs.
 * The hold is recorded when the turn's terminal is, so this does not read `isBusy`, which live runs keep set. */
export async function waitBetweenTurns(slot: object): Promise<void> {
  await waitFor(() => (slot as { taskWait?: unknown }).taskWait !== undefined, "task waits between turns", bound);
}

/** The model's context as the faux provider passes it to a scripted response. */
export type FauxContext = { messages: Array<Record<string, any>> };
/** The reply one tool call received, as the model reads it. */
export function toolResultText(context: FauxContext, toolCallId: string): { isError: boolean; text: string } | undefined {
  const result = context.messages.find(message => message.role === "toolResult" && message.toolCallId === toolCallId);
  if (!result) return undefined;
  return { isError: result.isError === true, text: result.content.find((item: { type: string }) => item.type === "text")?.text ?? "" };
}
/** A canonical entry's text, as the model reads it. */
export function entryText(entry: { content?: unknown }): string {
  const content = entry.content;
  return typeof content === "string" ? content
    : (content as Array<{ type?: string; text?: string }>).filter(part => part.type === "text").map(part => part.text ?? "").join("\n");
}
/** The async run directory a launch returned. A run's id is its directory name. */
export function launchedAsyncDir(context: FauxContext, toolCallId: string): string {
  const result = context.messages.find(message => message.role === "toolResult" && message.toolCallId === toolCallId);
  const asyncDir = (result?.details as { asyncDir?: unknown } | undefined)?.asyncDir;
  if (typeof asyncDir !== "string") throw new Error(`launch ${toolCallId} returned no async run`);
  return asyncDir;
}
