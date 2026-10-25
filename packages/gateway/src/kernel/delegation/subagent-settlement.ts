import { basename } from "node:path";
import { GatewayError } from "../../errors.js";
import type { JsonValue } from "../../protocol/types.js";
import type { AgentSession, FileEntry, ToolDefinition } from "../pi/coding-agent.js";
import type { HomeTaskReportOwner } from "./task-report.js";
import type { WorkerSettlement } from "./worker-settlement.js";
import { controlSubagentRun } from "./subagent-control.js";
import { HOME_TASK_SUBAGENTS, homeTaskSubagentLaunches, subagentsReceiptId, HOME_TASK_SUBAGENT_STOP_JOIN_MS, undeliveredSubagentNotices } from "./task-subagents.js";

/** A read/I/O view of the actual native runtime, not a copied context. Native
 * activity projection, canonical append and work-token ownership remain there.
 * Work is opaque: settlement passes the exact existing operation owner to append. */
export interface SubagentSettlementRuntime<Work> {
  readonly taskWorker?: HomeTaskReportOwner | undefined;
  readonly runtime: { readonly session: AgentSession };
  readonly workerSettlement: WorkerSettlement;
  readonly runWork: { get(operationId: string): Work | undefined };
  canonicalSessionEntries(): FileEntry[];
  asyncStopTargets(): string[];
  trustedSubagentController(): ToolDefinition | undefined;
  hasDetachedDashboardWork(): boolean;
  persistCanonicalCustomEntry(customType: string, data: JsonValue, identity: string, owner?: Work): Promise<void>;
}

/** Task-end settlement of this worker's async subagent runs. Every live async run is
 * stopped through the provider's own stop control, then the join waits until no run
 * is live, bounded by the operation deadline or the stop-join bound, whichever comes
 * first, and one disposal grace after it. The
 * fact is appended only when the task launched async runs, so an absent fact proves
 * zero Gateway stops. `stoppedAtEnd` is null unless every stop was accepted and the
 * join completed. Before the fact, the join also waits for each async run's completion
 * notice to be recorded, bounded the same way; `noticesUndelivered` counts those still
 * missing at the bound, which never changes the outcome (the run itself is terminal). */
export async function settleTaskSubagents<Work>(worker: SubagentSettlementRuntime<Work>, operationId: string, deadline: AbortSignal): Promise<{ stoppedAtEnd: number | null; noticesUndelivered: number }> {
  if (worker.taskWorker?.identity.operationId !== operationId) throw new GatewayError("conflict", "Task operation changed before settlement");
  const launched = homeTaskSubagentLaunches(worker.canonicalSessionEntries());
  const targets = worker.asyncStopTargets();
  if (targets.length === 0 && launched.every(launch => launch.asyncDir === undefined)) return { stoppedAtEnd: 0, noticesUndelivered: 0 };
  const tool = worker.trustedSubagentController();
  const stops = await Promise.allSettled(targets.map(async runId => {
    if (!tool) throw new GatewayError("unsupported", "The installed subagent controller is unavailable");
    await controlSubagentRun(worker.runtime.session, tool, { action: "stop", id: runId });
  }));
  // The join is also bounded once stops are requested: a run whose stop never lands
  // must not hold the sealed task open for the rest of its 24-hour deadline.
  const stopJoin = new AbortController();
  const stopJoinTimer = setTimeout(() => stopJoin.abort(), HOME_TASK_SUBAGENT_STOP_JOIN_MS);
  const bound = AbortSignal.any([deadline, stopJoin.signal]);
  let joined: boolean;
  let noticesUndelivered: number;
  try {
    joined = await worker.workerSettlement.until("detached", () => !worker.hasDetachedDashboardWork(), bound);
    // A run's completion notice is written after the run is terminal, so it can land after
    // the report. It is canonical evidence of the run, so settlement records it before the fact
    // and the evidence cut. A notice still missing at the bound is counted, not waited for.
    const runIds = launched.flatMap(launch => launch.asyncDir ? [basename(launch.asyncDir)] : []);
    const undelivered = (): string[] => undeliveredSubagentNotices(worker.canonicalSessionEntries(), runIds);
    await worker.workerSettlement.until("delivery", () => undelivered().length === 0, bound);
    noticesUndelivered = undelivered().length;
  } finally {
    clearTimeout(stopJoinTimer);
  }
  const stoppedAtEnd = joined && stops.every(stop => stop.status === "fulfilled") ? stops.length : null;
  await worker.persistCanonicalCustomEntry(HOME_TASK_SUBAGENTS,
    { receiptId: subagentsReceiptId(operationId), operationId, stoppedAtEnd }, subagentsReceiptId(operationId), worker.runWork.get(operationId));
  return { stoppedAtEnd, noticesUndelivered };
}
