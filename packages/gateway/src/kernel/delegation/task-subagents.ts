import { open } from "node:fs/promises";
import { basename, dirname, join } from "node:path";
import type { FileEntry } from "../pi/coding-agent.js";
import { GatewayError } from "../../errors.js";
import type { ExtensionRunLifecycleState } from "../../protocol/types.js";
import { CONTEXT_DELIVERY_RECEIPT_TYPE } from "../receipts/delivery-tags.js";
import { delegatedArtifactPathAllowed, DELEGATED_PROVIDER_TOOL_NAME } from "./delegated-provider.js";
import { MAX_EXTENSION_ARTIFACT_BYTES, observedPausedProcessTerminalAt } from "../projection/extension-run-projection.js";
import { homeTaskOperationSpan } from "./task-report.js";
import { HOME_TASK_PRODUCER_REFUSAL_REASON, HOME_TASK_SEALED_REASON } from "./task-worker-extension.js";

export const HOME_TASK_SUBAGENTS = "tron-home-task-subagents";

export interface HomeTaskSubagents {
  started: number;
  stoppedAtEnd: number | null;
}

interface HomeTaskSubagentsEntry { receiptId: string; operationId: string; stoppedAtEnd: number | null }

export interface HomeTaskSubagentRun {
  runId: string;
  agent: string;
  state: ExtensionRunLifecycleState;
  startedAt: string;
  lastActivityAt: string | null;
}
export interface HomeTaskSubagentRuns { total: number; runs: HomeTaskSubagentRun[] }
export const HOME_TASK_STATUS_RUN_LIMIT = 20;

export const HOME_TASK_SUBAGENT_STOP_JOIN_MS = 60_000;

export const subagentsReceiptId = (operationId: string) => `subagents:${operationId}`;

const HOME_TASK_SUBAGENT_NOTICE = "subagent-notify";

export function undeliveredSubagentNotices(entries: readonly FileEntry[], runIds: readonly string[]): string[] {
  const receipted = new Set<string>();
  for (const entry of entries) {
    if (entry.type !== "custom" || entry.customType !== CONTEXT_DELIVERY_RECEIPT_TYPE) continue;
    const target = (entry.data as { targetEntryId?: unknown } | null | undefined)?.targetEntryId;
    if (typeof target === "string") receipted.add(target);
  }
  const notices = entries.flatMap(entry => entry.type === "custom_message" && entry.customType === HOME_TASK_SUBAGENT_NOTICE && receipted.has(entry.id)
    ? [customMessageText(entry.content)] : []);
  return runIds.filter(runId => !notices.some(text => text.includes(runId)));
}

function customMessageText(content: unknown): string {
  if (typeof content === "string") return content;
  return Array.isArray(content) ? content.flatMap(part => part?.type === "text" && typeof part.text === "string" ? [part.text] : []).join("\n") : "";
}

const SETTLED_RUN_STATES = new Set(["complete", "failed", "partial", "stopped", "rejected"]);

export function homeTaskSubagentLaunches(runEntries: readonly FileEntry[]): Array<{ toolCallId: string; asyncDir: string | undefined }> {
  const launchCalls = new Set<string>();
  for (const entry of runEntries) {
    if (entry.type !== "message" || entry.message.role !== "assistant") continue;
    for (const block of entry.message.content as unknown as Array<Record<string, unknown>>) {
      if (block.type !== "toolCall" || block.name !== DELEGATED_PROVIDER_TOOL_NAME || typeof block.id !== "string") continue;
      const args = block.arguments as Record<string, unknown> | null;
      if (args && typeof args === "object" && (args.action === undefined || args.action === "resume")) launchCalls.add(block.id);
    }
  }
  const launches: Array<{ toolCallId: string; asyncDir: string | undefined }> = [];
  for (const entry of runEntries) {
    if (entry.type !== "message" || entry.message.role !== "toolResult") continue;
    const message = entry.message as unknown as { toolName?: unknown; toolCallId?: unknown; content?: unknown; details?: unknown };
    if (message.toolName !== DELEGATED_PROVIDER_TOOL_NAME || typeof message.toolCallId !== "string"
      || !launchCalls.has(message.toolCallId) || gateBlocked(message.content)) continue;
    const details = message.details as { asyncDir?: unknown } | null | undefined;
    launches.push({ toolCallId: message.toolCallId, asyncDir: typeof details?.asyncDir === "string" ? details.asyncDir : undefined });
  }
  return launches;
}

const GATE_REASONS = new Set([HOME_TASK_PRODUCER_REFUSAL_REASON, HOME_TASK_SEALED_REASON]);
function gateBlocked(content: unknown): boolean {
  const text = (content as Array<{ type?: unknown; text?: unknown }> | undefined)?.find(item => item.type === "text")?.text;
  return typeof text === "string" && GATE_REASONS.has(text);
}

export function parseHomeTaskSubagentsEntry(data: unknown, operationId: string): HomeTaskSubagentsEntry {
  const value = data as Record<string, unknown> | null;
  if (!value || typeof value !== "object" || Array.isArray(value)
    || Object.keys(value).sort().join(",") !== "operationId,receiptId,stoppedAtEnd"
    || value.receiptId !== subagentsReceiptId(operationId) || value.operationId !== operationId
    || !(value.stoppedAtEnd === null || Number.isSafeInteger(value.stoppedAtEnd) && (value.stoppedAtEnd as number) >= 0)) {
    throw new GatewayError("conflict", "Task subagent evidence is invalid");
  }
  return value as unknown as HomeTaskSubagentsEntry;
}

export function homeTaskSubagentsProjection(entries: readonly FileEntry[], operationId: string): HomeTaskSubagents {
  const runEntries = homeTaskOperationSpan(entries, operationId).run;
  const launches = homeTaskSubagentLaunches(runEntries);
  const facts = runEntries.filter(entry => entry.type === "custom" && entry.customType === HOME_TASK_SUBAGENTS);
  if (facts.length > 1) throw new GatewayError("conflict", "Conflicting task subagent evidence");
  const fact = facts[0];
  if (fact?.type === "custom") return { started: launches.length, stoppedAtEnd: parseHomeTaskSubagentsEntry(fact.data, operationId).stoppedAtEnd };
  return { started: launches.length, stoppedAtEnd: launches.some(launch => launch.asyncDir !== undefined) ? null : 0 };
}

export async function homeTaskSubagentRunsSettled(asyncDirs: readonly string[], artifactRoot: string): Promise<boolean> {
  for (const asyncDir of asyncDirs) {
    if (!delegatedArtifactPathAllowed(asyncDir, artifactRoot, artifactRoot)) return false;
    const status = await runStatus(asyncDir);
    if (!status || !await runSettled(asyncDir, status)) return false;
    for (const step of Array.isArray(status.steps) ? status.steps : []) {
      const edge = step as Record<string, unknown> | null;
      if (edge?.async !== true) continue;
      if (typeof edge.runId !== "string" || !edge.runId || Buffer.byteLength(edge.runId) > 256 || /[\\/\0]/u.test(edge.runId)) return false;
      const childDir = join(dirname(asyncDir), edge.runId);
      if (!delegatedArtifactPathAllowed(childDir, artifactRoot, artifactRoot)) return false;
      const child = await runStatus(childDir);
      if (!child || !await runSettled(childDir, child)) return false;
    }
  }
  return true;
}

async function runSettled(asyncDir: string, status: Record<string, unknown>): Promise<boolean> {
  const runId = basename(asyncDir);
  if (status.runId !== runId) return false;
  if (SETTLED_RUN_STATES.has(status.state as string)) return true;
  if (status.state !== "paused") return false;
  const processTerminal = await runArtifact(asyncDir, "process-terminal.json");
  return observedPausedProcessTerminalAt({ ...status, processTerminal }, runId) !== undefined;
}

const runStatus = (asyncDir: string) => runArtifact(asyncDir, "status.json");

async function runArtifact(asyncDir: string, name: "status.json" | "process-terminal.json"): Promise<Record<string, unknown> | undefined> {
  let handle;
  try {
    const path = join(asyncDir, name);
    if (!delegatedArtifactPathAllowed(path, dirname(asyncDir), dirname(dirname(asyncDir)))) return undefined;
    handle = await open(path, "r");
    if (!(await handle.stat()).isFile()) return undefined;
    const bytes = Buffer.alloc(MAX_EXTENSION_ARTIFACT_BYTES + 1);
    const { bytesRead } = await handle.read(bytes, 0, bytes.length, 0);
    if (bytesRead > MAX_EXTENSION_ARTIFACT_BYTES) return undefined;
    const value: unknown = JSON.parse(bytes.subarray(0, bytesRead).toString("utf8"));
    return value && typeof value === "object" && !Array.isArray(value) ? value as Record<string, unknown> : undefined;
  } catch {
    return undefined;
  } finally {
    await handle?.close();
  }
}
