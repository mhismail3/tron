import { readFile } from "node:fs/promises";
import { join } from "node:path";
import { fauxAssistantMessage, fauxToolCall } from "@earendil-works/pi-ai";
import { vi } from "vitest";
import { OWNED_OPERATION_DEADLINE_MS } from "../src/kernel/delegation/delegation-operations.js";
import { disposeFixtures, type fixture } from "./home-task-fixture.js";
import { startScriptedChild, type ChildModelServer } from "./home-task-subagent-child.js";
import { waitFor } from "./wait-for.js";

export const bound = { boundMs: 20_000 };

const servers: ChildModelServer[] = [];
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

export function captureTimer(ms: number): { expire: () => void; armed: () => boolean } {
  const original = globalThis.setTimeout;
  let fire: (() => void) | undefined;
  vi.spyOn(globalThis, "setTimeout").mockImplementation(((callback: any, delay: number, ...args: any[]) => {
    if (delay === ms) fire = callback;
    return original(callback, delay, ...args);
  }) as typeof setTimeout);
  return { expire: () => { if (!fire) throw new Error(`no ${ms} ms timer is armed`); fire(); }, armed: () => fire !== undefined };
}

export const captureDeadline = () => captureTimer(OWNED_OPERATION_DEADLINE_MS);

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
export async function workflowChildRunId(workflowDir: string): Promise<string> {
  const status = JSON.parse(await readFile(join(workflowDir, "status.json"), "utf8")) as { steps: Array<{ runId?: string }> };
  return status.steps[0]!.runId!;
}

export const holdingAsyncLaunch = (id: string, task = "HOLD-CHILD background search") =>
  fauxAssistantMessage([fauxToolCall("subagent", { agent: "task-child", task, async: true }, { id })], { stopReason: "toolUse" });

export async function waitBetweenTurns(slot: object): Promise<void> {
  await waitFor(() => (slot as { ownedTurns: { waitingTask?: unknown } }).ownedTurns.waitingTask !== undefined, "task waits between turns", bound);
}

export type FauxContext = { messages: Array<Record<string, any>> };
export function toolResultText(context: FauxContext, toolCallId: string): { isError: boolean; text: string } | undefined {
  const result = context.messages.find(message => message.role === "toolResult" && message.toolCallId === toolCallId);
  if (!result) return undefined;
  return { isError: result.isError === true, text: result.content.find((item: { type: string }) => item.type === "text")?.text ?? "" };
}
export function entryText(entry: { content?: unknown }): string {
  const content = entry.content;
  return typeof content === "string" ? content
    : (content as Array<{ type?: string; text?: string }>).filter(part => part.type === "text").map(part => part.text ?? "").join("\n");
}
export function launchedAsyncDir(context: FauxContext, toolCallId: string): string {
  const result = context.messages.find(message => message.role === "toolResult" && message.toolCallId === toolCallId);
  const asyncDir = (result?.details as { asyncDir?: unknown } | undefined)?.asyncDir;
  if (typeof asyncDir !== "string") throw new Error(`launch ${toolCallId} returned no async run`);
  return asyncDir;
}
