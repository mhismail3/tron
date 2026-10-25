import { createHash } from "node:crypto";
import type { AgentSession, FileEntry } from "../pi/coding-agent.js";
import type { AgentTurnDecision } from "../pi/agent-core.js";
import type { AgentPipelineStages } from "../pi/adapters.js";
import type { HomeTaskReportOwner } from "./task-report.js";
import type { TaskWorkerDiagnostic } from "./worker-contract.js";

/** The actual native frame, not a copied context: run state and canonical I/O
 * stay native. The optional sink is read only when a reminder was sent. */
interface WorkerTurnRuntime {
  readonly runQueue: { readonly queuedMessages: { readonly length: number } };
  readonly dependencies: { homeTaskDiagnostic?: (record: TaskWorkerDiagnostic) => void };
  canonicalSessionEntries(): FileEntry[];
  hasDetachedDashboardWork(): boolean;
  abort(kind: "agent", operationId: string, reason: "task-report" | "task-budget"): Promise<void>;
}

/** SDK boundary handling runs first. A sealed report/budget ends the exact task;
 * queued input takes Stop instead of being stranded by a quiet end. The created
 * runtime object and report owner are the same ones captured at installation. */
export function workerFinishTurn(worker: WorkerTurnRuntime, created: { readonly session: AgentSession },
  taskWorker: HomeTaskReportOwner): NonNullable<AgentPipelineStages["finishTurn"]> {
  return (finishTurn) => async (turn, signal): Promise<AgentTurnDecision | undefined> => {
    const decision = await finishTurn?.(turn, signal);
    // A task that reached its budget ends here the same way (settings-model.md 6.1).
    const ending = taskWorker.reportSealed || await taskWorker.exceedsBudget(worker.canonicalSessionEntries());
    if (!ending) {
      // A plain reply is not an immutable task result. Repair that omission
      // once inside the same invocation, before any terminal receipt. Live
      // children/queued input retain their own continuation and Stop wins.
      if (!decision && turn.message.stopReason === "stop" && !signal?.aborted
        && !created.session.agent.hasQueuedMessages() && !worker.hasDetachedDashboardWork()
        && taskWorker.takeReportReminder()) {
        await created.session.sendCustomMessage({ customType: "tron.home-task-report-reminder.v1",
          content: "Call report now with the current outcome and partial evidence. Do not continue implementation or validation. Use progress for unfinished work or needs-input for a blocker; do not claim final success without acceptance evidence. If you cannot report, the task will settle with no report.",
          display: false }, { triggerTurn: true });
        worker.dependencies.homeTaskDiagnostic?.({ event: "home.task.report-reminder",
          taskHash: createHash("sha256").update(taskWorker.identity.taskId).digest("hex").slice(0, 16),
          operationHash: createHash("sha256").update(taskWorker.identity.operationId).digest("hex").slice(0, 16) });
        return { action: "continue" };
      }
      return decision ?? undefined;
    }
    if (worker.runQueue.queuedMessages.length > 0) {
      taskWorker.requestStop(() => worker.abort("agent", taskWorker.identity.operationId, taskWorker.reportSealed ? "task-report" : "task-budget"));
    }
    return { action: "end" };
  };
}
