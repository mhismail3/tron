import { open } from "node:fs/promises";
import { basename, dirname, join } from "node:path";
import type { FileEntry } from "@earendil-works/pi-coding-agent";
import { GatewayError } from "../errors.js";
import type { ExtensionRunLifecycleState } from "../protocol/types.js";
import { CONTEXT_DELIVERY_RECEIPT_TYPE } from "../sessions/context-delivery-receipts.js";
import { delegatedArtifactPathAllowed, DELEGATED_PROVIDER_TOOL_NAME } from "../sessions/delegated-provider.js";
import { MAX_EXTENSION_ARTIFACT_BYTES, observedPausedProcessTerminalAt } from "../sessions/extension-run-projection.js";
import { homeTaskOperationSpan } from "./home-task-report.js";
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

/** A live subagent run of a task's worker, as task status shows it. Projected from the live
 * slot on each read and never persisted with the task. */
export interface HomeTaskSubagentRun {
  runId: string;
  agent: string;
  state: ExtensionRunLifecycleState;
  startedAt: string;
  lastActivityAt: string | null;
}
/** The live runs in task status: at most `HOME_TASK_STATUS_RUN_LIMIT` of them, newest first,
 * with `total` counting every live run. Empty once the task has settled. */
export interface HomeTaskSubagentRuns { total: number; runs: HomeTaskSubagentRun[] }
export const HOME_TASK_STATUS_RUN_LIMIT = 20;

/** How long task-end settlement waits for the runs it stopped to become terminal. A
 * stopped runner aborts its request and writes its terminal status within seconds; a
 * run still live after this bound (a refused stop, an unreadable status) keeps the
 * detached outcome instead of holding the sealed task open until its 24-hour deadline. */
export const HOME_TASK_SUBAGENT_STOP_JOIN_MS = 60_000;

export const subagentsReceiptId = (operationId: string) => `subagents:${operationId}`;

/** The provider's completion notice for an async run: a `subagent-notify` custom message. It has
 * no structured run identity; its text names the run (the async directory line, or the workflow
 * run and child lines), so a run is matched by its run id in that text. */
const HOME_TASK_SUBAGENT_NOTICE = "subagent-notify";

/** The async run ids whose completion notice is not yet canonical evidence: no recorded notice
 * names the run. A notice is recorded once the Gateway's delivery receipt for it exists. */
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

/** Terminal outcomes need no process proof; paused history needs the same exact
 * runner-exit proof used by live report admission, not a fabricated outcome. */
const SETTLED_RUN_STATES = new Set(["complete", "failed", "partial", "stopped", "rejected"]);

/** A launch is a `subagent` call with no `action` that the task admitted, or a `resume`
 * the task admitted (on its own run, which starts a new run the task then owns): the gate
 * blocked the others before the provider saw them. A provider that then rejects an admitted
 * call before creating a run still counts as admitted, because its result carries no run
 * identity to tell the two apart. Other management calls never count. */
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

/** The operation's subagent facts from one canonical cut. Entries after the
 * operation's marker are the only ones that belong to it. */
export function homeTaskSubagentsProjection(entries: readonly FileEntry[], operationId: string): HomeTaskSubagents {
  const runEntries = homeTaskOperationSpan(entries, operationId).run;
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
 * from the provider's own status file under the admitted artifact root, and from the
 * status of each async workflow child the run launched: a workflow can complete while
 * those children run on. Anything it cannot prove is treated as live, never as ended. */
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

/** Cold and live readers share the full-status bound. Bound the actual read,
 * not just a stat before a provider's atomic replacement or append. */
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
