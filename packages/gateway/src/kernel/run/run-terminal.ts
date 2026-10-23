import type { RunOperations } from "./run-operations.js";
import type { AgentMessage } from "../pi/agent-core.js";
import type { AgentTerminalOutcome } from "../host/module-host.js";
import { GatewayError } from "../../errors.js";
import { TASK_STOP_WAITING, type OwnedOperationTerminal } from "./invocation-receipts.js";
import type { PromptOwnership } from "./prompt-input.js";

interface OperationObservation {
  cursor?: { entryIndex: number };
  observedCompletionId?: string;
  pendingCompletionId?: string;
}

const MAX_COMPLETION_DISPOSITIONS = 16;

/** Terminal observation and held-task dispatch share the exact live run boundary. */
export class RunTerminalOwner {
  readonly ownedTerminalObservers = new Map<string, (terminal: OwnedOperationTerminal) => Promise<void> | void>();
  /** Only an admitted agent_start may own a terminal candidate. Later SDK
   * progress can reconstruct a projection even for a drain-rejected run. */
  notificationRun: { assistant?: AgentMessage } | undefined;
  waitingNotificationEpisode: string | undefined;
  /** One foreground-observation decision is shared by durable attention and
   * automatic completion notification policy for the same canonical entry. */
  private readonly completionDispositions = new Map<string, boolean>();
  /** A task worker's operation between turns: its last turn ended with live owned runs and no
   * report, so the dispatcher's observer is held here instead of settling the task. A provider
   * wake starts the next turn of the same task (`wakeOperationId` set once that turn runs). Only
   * this instance holds it: a restart leaves a waiting task to cold reconciliation. */
  taskWait: { observer: (terminal: OwnedOperationTerminal) => Promise<void> | void; terminal: OwnedOperationTerminal; wakeOperationId?: string } | undefined;

  constructor(private readonly operations: RunOperations<unknown>) {}

  readonly operationObservations = new Map<string, OperationObservation>();

  observationFor(operationId: string): OperationObservation {
    let observation = this.operationObservations.get(operationId);
    if (!observation) {
      observation = {};
      this.operationObservations.set(operationId, observation);
    }
    return observation;
  }

  retireOperationObservation(operationId: string | undefined): void {
    if (operationId) this.operationObservations.delete(operationId);
  }

  completionOperationId(completionId: string): string | undefined {
    for (const [operationId, observation] of this.operationObservations) {
      if (observation.pendingCompletionId === completionId) return operationId;
    }
    return undefined;
  }

  completionObserved(completionId: string): boolean {
    const existing = this.completionDispositions.get(completionId);
    if (existing !== undefined) return existing;
    const observed = this.operations.dependencies.isSessionPresented(this.operations.id);
    this.completionDispositions.set(completionId, observed);
    while (this.completionDispositions.size > MAX_COMPLETION_DISPOSITIONS) {
      const oldest = this.completionDispositions.keys().next().value;
      if (oldest === undefined) break;
      this.completionDispositions.delete(oldest);
    }
    return observed;
  }

  async notifyAgentTerminal(sourceId: string, outcome: AgentTerminalOutcome): Promise<void> {
    // A task's durable result owner, never generic chat completion, decides push.
    if (this.operations.taskWorker) return;
    const runTerminal = this.operations.dependencies.modules.policy("runTerminal")?.();
    if (!runTerminal) return;
    const previousEpisode = this.waitingNotificationEpisode;
    let claimedEpisode: string | undefined;
    try {
      const pendingBackgroundProcesses = this.operations.pendingBackgroundProcesses();
      const waitingEpisode = pendingBackgroundProcesses.join("\0");
      claimedEpisode = waitingEpisode || undefined;
      // Claim before policy admission can suspend: a successor terminal shares
      // this episode even while the first notification is persisting.
      this.waitingNotificationEpisode = claimedEpisode;
      await runTerminal({
        sessionId: this.operations.id,
        sourceId,
        outcome,
        sessionTitle: this.operations.notificationTitle(),
        observed: this.completionObserved(sourceId),
        pendingBackgroundWork: pendingBackgroundProcesses.length,
        waitingEpisode: waitingEpisode !== "" && waitingEpisode === previousEpisode,
      });
    } catch {
      // A failed admission may retry, but cannot roll back a newer episode.
      if (this.waitingNotificationEpisode === claimedEpisode) this.waitingNotificationEpisode = previousEpisode;
      // Push admission is best-effort and must never fail canonical settlement.
      this.operations.emit("session.diagnostic", { code: "terminal-notification-failed" });
    }
  }

  takeAgentTerminal(operationId: string | undefined): { sourceId: string; outcome: AgentTerminalOutcome } | undefined {
    const run = this.notificationRun;
    this.notificationRun = undefined;
    if (!run || !operationId) return;
    const { assistant } = run;
    // Match the exact final run object, not the latest successful history row.
    // Retry errors remain canonical even when Pi removes them from model context.
    const entry = assistant && this.operations.sessionManager.getBranch().findLast((candidate) =>
      candidate.type === "message" && candidate.message === assistant);
    const invocation = this.operations.runInvocations.invocationForOperation(operationId);
    const sourceId = entry?.id ?? (invocation ? `terminal:${invocation.invocationId}` : operationId);
    const reason = assistant?.role === "assistant" ? assistant.stopReason : undefined;
    // A task operation whose report is sealed ended at the report's tool boundary
    // by design: that is its completion, not an unknown outcome.
    const reportCompleted = reason === "toolUse" && this.operations.taskWorker?.reportSealed === true
      && this.operations.taskWorker.identity.operationId === operationId;
    const outcome: AgentTerminalOutcome = this.operations.runAbort.abortedOperations.has(operationId) || reason === "aborted" ? "stopped"
      : reason === "error" ? "failed"
      : reason === "length" ? "limited"
      : reason === "stop" || reportCompleted ? "completed"
      : "unknown";
    // Observation belongs to the terminal boundary, before receipt I/O can
    // suspend and a phone can open/close the chat or a successor can start.
    this.completionObserved(sourceId);
    return { sourceId, outcome };
  }

  async notifyOwnedTerminal(terminal: OwnedOperationTerminal): Promise<void> {
    // A held task's next turn reports to the task, even when Home's steering started that turn;
    // the steering's own observer still learns its terminal.
    const own = this.ownedTerminalObservers.get(terminal.operationId);
    const wake = this.taskWait?.wakeOperationId === terminal.operationId ? this.taskWait.observer : undefined;
    const observer = wake ?? own;
    if (!observer) return;
    this.ownedTerminalObservers.delete(terminal.operationId);
    if (wake && own) await own(terminal);
    // Only the task's own turns (its first operation, then each wake) hold or settle it; a steer
    // or other owned operation reports to its own observer and never touches the wait.
    if (this.operations.taskWorker && (terminal.operationId === this.operations.taskWorker.identity.operationId || this.taskWait?.wakeOperationId === terminal.operationId)) {
      if (this.taskTurnAwaitsWake(terminal)) {
        this.taskWait = { observer, terminal };
        return;
      }
      this.taskWait = undefined;
    }
    await observer(terminal);
  }

  /** A message the maintainer sent, or Home's exact-operation steering, to this worker's task. */
  sharedTaskSteering(ownership: PromptOwnership<{ taskId: string; operationId: string }> | undefined): boolean {
    if (!this.operations.taskWorker) return false;
    if (!ownership) return true;
    const fence = ownership.taskFence;
    return !!fence && fence.taskId === this.operations.taskWorker.identity.taskId && fence.operationId === this.operations.taskWorker.identity.operationId;
  }

  /** The task operation a turn reports under. A wake that continues the held task is the task's
   * next turn, so its report seals the task's operation, not the wake's own. */
  taskTurnOperationId(operationId: string): string {
    return this.taskWait?.wakeOperationId === operationId && this.operations.taskWorker ? this.operations.taskWorker.identity.operationId : operationId;
  }

  /** The task operation the live turn belongs to, or undefined when no turn runs. Task controls
   * target the task's operation, so a provider wake's turn (its own operation) is the live task turn (#1251). */
  liveTaskOperationId(): string | undefined {
    return this.operations.activeOperationId === undefined ? undefined : this.taskTurnOperationId(this.operations.activeOperationId);
  }

  /** A task turn that completed normally, without a report, while owned runs are live. The
   * provider's completion or supervisor request wakes the same task for its next turn. A sealed or
   * stopping task, a length, error or aborted turn, and a task with no live run settle now. */
  private taskTurnAwaitsWake(terminal: OwnedOperationTerminal): boolean {
    if (terminal.lifecycle !== "completed" || !this.operations.taskWorker?.acceptsSteering) return false;
    const last = this.operations.sessionManager.getBranch().findLast(entry => entry.type === "message" && entry.message.role === "assistant");
    return last?.type === "message" && last.message.role === "assistant" && last.message.stopReason === "stop"
      && this.operations.hasDetachedDashboardWork();
  }

  /** Task cancellation follows the root prompt owner, not its disposable
   * presentation primitive (automatic compaction/retry may have another ID). */
  async cancelHomeTaskOperation(operationId: string, reason: string): Promise<void> {
    if (!this.operations.taskWorker || this.operations.taskWorker.identity.operationId !== operationId) throw new GatewayError("conflict", "Task cancellation owner changed");
    // Between turns no turn runs to abort: the held observer settles the waiting task now. The
    // runs it still owns are stopped and joined by settlement, as for an interrupted turn.
    if (this.taskWait && this.taskWait.wakeOperationId === undefined) {
      const { observer, terminal } = this.taskWait;
      this.taskWait = undefined;
      await observer({ lifecycle: "interrupted", operationId, invocationId: terminal.invocationId, errorCode: TASK_STOP_WAITING });
      return;
    }
    // A provider wake's turn is the task's running turn: its abort is the task's Stop.
    const turnOperationId = this.taskWait?.wakeOperationId ?? operationId;
    if (this.operations.activeOperationId !== turnOperationId && this.operations.operation?.id !== turnOperationId) return;
    await this.operations.abort("agent", turnOperationId, reason);
  }

}
