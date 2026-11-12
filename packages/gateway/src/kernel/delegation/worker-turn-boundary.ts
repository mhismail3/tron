import { createHash } from "node:crypto";
import { injectedText } from "../host/injected-text.js";
import type { AgentSession, FileEntry } from "../pi/coding-agent.js";
import type { AgentMessage, AgentTurnDecision } from "../pi/agent-core.js";
import type { AgentPipelineStages } from "../pi/adapters.js";
import type { HomeTaskReportOwner } from "./task-report.js";
import type { TaskWorkerDiagnostic } from "./worker-contract.js";

interface WorkerTurnRuntime {
  readonly runQueue: { readonly queuedMessages: { readonly length: number } };
  readonly dependencies: { homeTaskDiagnostic?: (record: TaskWorkerDiagnostic) => void };
  canonicalSessionEntries(): FileEntry[];
  hasDetachedDashboardWork(): boolean;
  abort(kind: "agent", operationId: string, reason: "task-report" | "task-budget"): Promise<void>;
}

export function workerFinishTurn(worker: WorkerTurnRuntime, created: { readonly session: AgentSession },
  taskWorker: HomeTaskReportOwner): NonNullable<AgentPipelineStages["finishTurn"]> {
  return (finishTurn) => async (turn, signal): Promise<AgentTurnDecision | undefined> => {
    const decision = await finishTurn?.(turn, signal);
    const ending = taskWorker.reportSealed || await taskWorker.exceedsBudget(worker.canonicalSessionEntries());
    if (!ending) {
      if (!decision && turn.message.stopReason === "stop" && !signal?.aborted
        && !created.session.agent.hasQueuedMessages() && !worker.hasDetachedDashboardWork()
        && taskWorker.takeReportReminder()) {
        await created.session.sendCustomMessage({ customType: "tron.home-task-report-reminder.v1",
          content: injectedText("Call report now with the current outcome and partial evidence. Do not continue implementation or validation. Use progress for unfinished work or needs-input for a blocker; do not claim final success without acceptance evidence. If you cannot report, the task will settle with no report.", "gateway", "reminder", "task"),
          display: false }, { triggerTurn: true });
        worker.dependencies.homeTaskDiagnostic?.({ event: "home.task.report-reminder",
          taskHash: createHash("sha256").update(taskWorker.identity.taskId).digest("hex").slice(0, 16),
          operationHash: createHash("sha256").update(taskWorker.identity.operationId).digest("hex").slice(0, 16) });
        return { action: "continue" };
      }
      return decision ?? undefined;
    }
    if (worker.runQueue.queuedMessages.length > 0 || !(await keepQueuedNoticesAsContext(created.session))) {
      taskWorker.requestStop(() => worker.abort("agent", taskWorker.identity.operationId, taskWorker.reportSealed ? "task-report" : "task-budget"));
    }
    return { action: "end" };
  };
}

async function keepQueuedNoticesAsContext(session: AgentSession): Promise<boolean> {
  const agent = session.agent;
  if (!agent.hasQueuedMessages()) return true;
  const modes = { steering: agent.steeringMode, followUp: agent.followUpMode };
  agent.steeringMode = "all"; agent.followUpMode = "all";
  let queued: AgentMessage[];
  try {
    const first = agent.peekQueuedMessages();
    agent.clearSteeringQueue();
    const followUp = agent.peekQueuedMessages();
    const steering = first.every((message, index) => followUp[index] === message) && first.length === followUp.length ? [] : first;
    queued = [...steering, ...followUp];
    if (queued.some(message => message.role !== "custom")) {
      for (const message of steering) agent.steer(message);
      return false;
    }
    agent.clearFollowUpQueue();
  } finally {
    agent.steeringMode = modes.steering; agent.followUpMode = modes.followUp;
  }
  for (const message of queued as Array<Extract<AgentMessage, { role: "custom" }>>) {
    await session.sendCustomMessage({ customType: message.customType, content: message.content, display: message.display, details: message.details }, { triggerTurn: false });
  }
  return true;
}
