import { lstat, readFile } from "node:fs/promises";
import { join } from "node:path";
import type { FileEntry } from "@earendil-works/pi-coding-agent";
import { GatewayError } from "../errors.js";
import { delegatedArtifactPathAllowed, DELEGATED_PROVIDER_TOOL_NAME } from "../sessions/delegated-provider.js";
import { HOME_TASK_MARKER } from "./home-task-report.js";
import { HOME_TASK_PRODUCER_REFUSAL_REASON, HOME_TASK_SEALED_REASON } from "./home-task-worker-extension.js";

/** The worker's canonical settlement fact: the Gateway's own task-end stops of its
 * async subagent runs. Written at most once per operation, and only when the task
 * had async runs to account for; its absence proves zero stops. */
export const HOME_TASK_SUBAGENTS = "tron-home-task-subagents";

export interface HomeTaskSubagents {
  /** `subagent` launches the task admitted (foreground or async) in this operation. */
  started: number;
  /** Async runs the Gateway stopped at settlement, or null when that is not proven. */
  stoppedAtEnd: number | null;
}

export interface HomeTaskSubagentsEntry { receiptId: string; operationId: string; stoppedAtEnd: number | null }

export const subagentsReceiptId = (operationId: string) => `subagents:${operationId}`;

/** Provider states that cannot change again. `paused` may still resume, so it is live. */
const SETTLED_RUN_STATES = new Set(["complete", "failed", "partial", "stopped", "rejected"]);
const MAXIMUM_STATUS_BYTES = 64 * 1024;

/** A launch is a `subagent` call with no `action` that the task admitted: the gate
 * blocked the others before the provider saw them. A provider that then rejects the
 * launch before creating a run still counts as admitted, because its result carries
 * no run identity to tell the two apart. Management calls never count. */
export function homeTaskSubagentLaunches(runEntries: readonly FileEntry[]): Array<{ toolCallId: string; asyncDir: string | undefined }> {
  const launchCalls = new Set<string>();
  for (const entry of runEntries) {
    if (entry.type !== "message" || entry.message.role !== "assistant") continue;
    for (const block of entry.message.content as unknown as Array<Record<string, unknown>>) {
      if (block.type !== "toolCall" || block.name !== DELEGATED_PROVIDER_TOOL_NAME || typeof block.id !== "string") continue;
      const args = block.arguments as Record<string, unknown> | null;
      if (args && typeof args === "object" && args.action === undefined) launchCalls.add(block.id);
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

/** The operation's subagent facts from one canonical cut. Entries after the
 * operation's marker are the only ones that belong to it. */
export function homeTaskSubagentsProjection(entries: readonly FileEntry[], operationId: string): HomeTaskSubagents {
  const marker = entries.findIndex(entry => entry.type === "custom" && entry.customType === HOME_TASK_MARKER
    && (entry.data as { operationId?: unknown } | undefined)?.operationId === operationId);
  const runEntries = marker < 0 ? [] : entries.slice(marker + 1);
  const launches = homeTaskSubagentLaunches(runEntries);
  const facts = runEntries.filter(entry => entry.type === "custom" && entry.customType === HOME_TASK_SUBAGENTS);
  if (facts.length > 1) throw new GatewayError("conflict", "Conflicting task subagent evidence");
  const fact = facts[0];
  if (fact?.type === "custom") return { started: launches.length, stoppedAtEnd: parseHomeTaskSubagentsEntry(fact.data, operationId).stoppedAtEnd };
  // No settlement fact: the Gateway stops runs only at settlement, so zero stops is
  // proven exactly when the task launched no async run.
  return { started: launches.length, stoppedAtEnd: launches.some(launch => launch.asyncDir !== undefined) ? null : 0 };
}

/** Cold reconciliation has no runtime to stop a run through. It proves a run ended
 * from the provider's own status file under the admitted artifact root. Anything it
 * cannot prove is treated as live, never as ended. */
export async function homeTaskSubagentRunsSettled(asyncDirs: readonly string[], artifactRoot: string): Promise<boolean> {
  for (const asyncDir of asyncDirs) {
    if (!delegatedArtifactPathAllowed(asyncDir, artifactRoot, artifactRoot)) return false;
    try {
      const statusPath = join(asyncDir, "status.json");
      const metadata = await lstat(statusPath);
      if (!metadata.isFile() || metadata.size > MAXIMUM_STATUS_BYTES) return false;
      const status = JSON.parse(await readFile(statusPath, "utf8")) as { state?: unknown };
      if (typeof status.state !== "string" || !SETTLED_RUN_STATES.has(status.state)) return false;
    } catch {
      return false;
    }
  }
  return true;
}
