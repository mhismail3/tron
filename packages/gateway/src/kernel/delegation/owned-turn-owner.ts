import { GatewayError } from "../../errors.js";
import type { SessionManager } from "../pi/coding-agent.js";
import { TASK_STOP_WAITING, type OwnedOperationTerminal } from "./owned-operation-terminal.js";
import type { TaskWorkerControl } from "./worker-contract.js";

/** The actual native run frame. Canonical branch/abort/admission I/O stays K2;
 * K5 keeps the single live owned-turn observer and held-task continuation state. */
interface OwnedTurnRuntime {
  readonly taskWorker?: { readonly identity: TaskWorkerControl; readonly acceptsSteering: boolean } | undefined;
  readonly activeOperationId: string | undefined;
  readonly operation: { readonly id?: string } | undefined;
  readonly sessionManager: Pick<SessionManager, "getBranch">;
  hasDetachedDashboardWork(): boolean;
  abort(kind: "agent", operationId: string, reason: string): Promise<void>;
}

export class OwnedTurnOwner {
  readonly observers = new Map<string, (terminal: OwnedOperationTerminal) => Promise<void> | void>();
  /** A task worker's operation between turns: its last turn ended with live owned runs and no
   * report, so the dispatcher's observer is held here instead of settling the task. A provider
   * wake starts the next turn of the same task (`wakeOperationId` set once that turn runs). Only
   * this instance holds it: a restart leaves a waiting task to cold reconciliation. */
  waitingTask: { observer: (terminal: OwnedOperationTerminal) => Promise<void> | void; terminal: OwnedOperationTerminal; wakeOperationId?: string } | undefined;

  constructor(private readonly operations: OwnedTurnRuntime) {}

  async notifyOwnedTerminal(terminal: OwnedOperationTerminal): Promise<void> {
    // A held task's next turn reports to the task, even when Home's steering started that turn;
    // the steering's own observer still learns its terminal.
    const own = this.observers.get(terminal.operationId);
    const wake = this.waitingTask?.wakeOperationId === terminal.operationId ? this.waitingTask.observer : undefined;
    const observer = wake ?? own;
    if (!observer) return;
    this.observers.delete(terminal.operationId);
    if (wake && own) await own(terminal);
    // Only the task's own turns (its first operation, then each wake) hold or settle it; a steer
    // or other owned operation reports to its own observer and never touches the wait.
    if (this.operations.taskWorker && (terminal.operationId === this.operations.taskWorker.identity.operationId || this.waitingTask?.wakeOperationId === terminal.operationId)) {
      if (this.taskTurnAwaitsWake(terminal)) {
        this.waitingTask = { observer, terminal };
        return;
      }
      this.waitingTask = undefined;
    }
    await observer(terminal);
  }

  /** A message the maintainer sent, or Home's exact-operation steering, to this worker's task. */
  sharedTaskSteering(ownership: { readonly taskFence?: TaskWorkerControl } | undefined): boolean {
    if (!this.operations.taskWorker) return false;
    if (!ownership) return true;
    const fence = ownership.taskFence;
    return !!fence && fence.taskId === this.operations.taskWorker.identity.taskId && fence.operationId === this.operations.taskWorker.identity.operationId;
  }

  /** The task operation a turn reports under. A wake that continues the held task is the task's
   * next turn, so its report seals the task's operation, not the wake's own. */
  taskTurnOperationId(operationId: string): string {
    return this.waitingTask?.wakeOperationId === operationId && this.operations.taskWorker ? this.operations.taskWorker.identity.operationId : operationId;
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
    if (this.waitingTask && this.waitingTask.wakeOperationId === undefined) {
      const { observer, terminal } = this.waitingTask;
      this.waitingTask = undefined;
      await observer({ lifecycle: "interrupted", operationId, invocationId: terminal.invocationId, errorCode: TASK_STOP_WAITING });
      return;
    }
    // A provider wake's turn is the task's running turn: its abort is the task's Stop.
    const turnOperationId = this.waitingTask?.wakeOperationId ?? operationId;
    if (this.operations.activeOperationId !== turnOperationId && this.operations.operation?.id !== turnOperationId) return;
    await this.operations.abort("agent", turnOperationId, reason);
  }

}
