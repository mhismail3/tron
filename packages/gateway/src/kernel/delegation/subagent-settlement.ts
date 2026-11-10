import { basename } from "node:path";
import { GatewayError } from "../../errors.js";
import type { JsonValue } from "../../protocol/types.js";
import type { AgentSession, FileEntry } from "../pi/coding-agent.js";
import type { OwnedTurnOwner } from "./owned-turn-owner.js";
import type { WorkerSettlement } from "./worker-settlement.js";
import { controlSubagentRun } from "./subagent-control.js";
import { HOME_TASK_SUBAGENTS, homeTaskSubagentLaunches, subagentsReceiptId, HOME_TASK_SUBAGENT_STOP_JOIN_MS, undeliveredSubagentNotices } from "./task-subagents.js";

export interface SubagentSettlementRuntime<Work> {
  readonly ownedTurns: Pick<OwnedTurnOwner, "worker" | "asyncStopTargets" | "trustedSubagentController">;
  readonly runtime: { readonly session: AgentSession };
  readonly workerSettlement: WorkerSettlement;
  readonly runWork: { get(operationId: string): Work | undefined };
  canonicalSessionEntries(): FileEntry[];
  hasDetachedDashboardWork(): boolean;
  persistCanonicalCustomEntry(customType: string, data: JsonValue, identity: string, owner?: Work): Promise<void>;
}

export async function settleTaskSubagents<Work>(worker: SubagentSettlementRuntime<Work>, operationId: string, deadline: AbortSignal): Promise<{ stoppedAtEnd: number | null; noticesUndelivered: number }> {
  if (worker.ownedTurns.worker?.identity.operationId !== operationId) throw new GatewayError("conflict", "Task operation changed before settlement");
  const launched = homeTaskSubagentLaunches(worker.canonicalSessionEntries());
  const targets = worker.ownedTurns.asyncStopTargets();
  if (targets.length === 0 && launched.every(launch => launch.asyncDir === undefined)) return { stoppedAtEnd: 0, noticesUndelivered: 0 };
  const tool = worker.ownedTurns.trustedSubagentController();
  const stops = await Promise.allSettled(targets.map(async runId => {
    if (!tool) throw new GatewayError("unsupported", "The installed subagent controller is unavailable");
    await controlSubagentRun(worker.runtime.session, tool, { action: "stop", id: runId });
  }));
  const stopJoin = new AbortController();
  const stopJoinTimer = setTimeout(() => stopJoin.abort(), HOME_TASK_SUBAGENT_STOP_JOIN_MS);
  const bound = AbortSignal.any([deadline, stopJoin.signal]);
  let joined: boolean;
  let noticesUndelivered: number;
  try {
    joined = await worker.workerSettlement.until("detached", () => !worker.hasDetachedDashboardWork(), bound);
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
