import { GatewayError } from "../../errors.js";
import type { JsonValue } from "../../protocol/types.js";
import type { FileEntry, SessionManager } from "../pi/coding-agent.js";
import { HOME_TASK_MARKER, type HomeTaskReportOwner } from "./task-report.js";
import { TASK_STOP_WAITING, type OwnedOperationTerminal } from "./owned-operation-terminal.js";
import type { TaskWorkerControl } from "./worker-contract.js";

/** The actual native run frame. Canonical branch/abort/admission I/O stays K2;
 * K5 keeps the single worker binding, owned-turn observer and held-task continuation state.
 * This is the same frame, not a copied context or a constructed binding object. */
interface OwnedTurnRuntime {
  readonly activeOperationId: string | undefined;
  readonly operation: { readonly id?: string } | undefined;
  readonly sessionManager: Pick<SessionManager, "getBranch">;
  readonly id: string;
  readonly lane: { run<T>(operation: () => T | Promise<T>): Promise<T> };
  readonly runtime: { readonly session: { readonly isStreaming: boolean } };
  readonly dependencies: {
    readonly workRegistry: {
      sessionWorkKinds(sessionId: string, exceptWorkToken?: string): readonly string[];
      begin(input: { kind: "administrative-provider-package-operation"; sessionId: string; hostEpoch: string }): { settle(): void };
    };
    sessionLineage(): { state(sessionId: string): { lineageId?: string | undefined } };
  };
  readonly ui: { readonly hostEpoch: string };
  readonly catalogHasActiveSubagents: boolean;
  readonly isAgentAdmissionSettling: boolean;
  revision: number;
  assertUsable(): void;
  assertChapterWritable(): void;
  administrativeDrainBlockers(): readonly { readonly category: string }[];
  liveProfile(): { readonly chapter: boolean };
  canonicalTaskEvidence(): FileEntry[];
  replaceRuntime(): Promise<void>;
  emit(topic: string, data: JsonValue): void;
  publishSnapshot(): void;
  hasDetachedDashboardWork(): boolean;
  abort(kind: "agent", operationId: string, reason: string): Promise<void>;
}

export class OwnedTurnOwner {
  /** The live report-owner binding. Creation seeds it once; only an idle rebind replaces it. */
  worker: HomeTaskReportOwner | undefined;
  readonly observers = new Map<string, (terminal: OwnedOperationTerminal) => Promise<void> | void>();
  /** A task worker's operation between turns: its last turn ended with live owned runs and no
   * report, so the dispatcher's observer is held here instead of settling the task. A provider
   * wake starts the next turn of the same task (`wakeOperationId` set once that turn runs). Only
   * this instance holds it: a restart leaves a waiting task to cold reconciliation. */
  waitingTask: { observer: (terminal: OwnedOperationTerminal) => Promise<void> | void; terminal: OwnedOperationTerminal; wakeOperationId?: string } | undefined;

  constructor(private readonly operations: OwnedTurnRuntime) {}

  /** Resume the settled worker in its actual native lane. State and validation belong
   * here; SDK reconstruction, canonical evidence and publication use the same frame. */
  async bindWorker(report: HomeTaskReportOwner, exceptWorkToken?: string): Promise<void> {
    await this.operations.lane.run(async () => {
      this.operations.assertUsable();
      this.operations.assertChapterWritable();
      // Any live work in this session refuses the rebind, named.
      const blocking = this.operations.dependencies.workRegistry.sessionWorkKinds(this.operations.id, exceptWorkToken);
      const drain = this.operations.administrativeDrainBlockers().map(fact => fact.category);
      if (this.operations.runtime.session.isStreaming || blocking.length || drain.length) {
        throw new GatewayError("busy", `The worker session is busy (${[...new Set([...blocking, ...drain])].join(", ") || "streaming"}); resume it when that finishes`, true);
      }
      if (this.operations.liveProfile().chapter || this.operations.dependencies.sessionLineage().state(this.operations.id).lineageId) {
        throw new GatewayError("conflict", "A Home chapter cannot run a task");
      }
      if (this.worker?.controlsActive || this.waitingTask || this.operations.activeOperationId !== undefined || this.operations.operation !== undefined
        || this.operations.catalogHasActiveSubagents || this.operations.isAgentAdmissionSettling) {
        throw new GatewayError("conflict", "The worker session is still running; stop it before resuming");
      }
      const markers = this.operations.canonicalTaskEvidence().filter(entry => entry.type === "custom" && entry.customType === HOME_TASK_MARKER);
      if (!markers.length) throw new GatewayError("conflict", "Only a Home task worker session can resume a task");
      const work = this.operations.dependencies.workRegistry.begin({
        kind: "administrative-provider-package-operation",
        sessionId: this.operations.id,
        hostEpoch: this.operations.ui.hostEpoch,
      });
      try {
        this.worker = report;
        await this.operations.replaceRuntime();
        this.operations.revision += 1;
        this.operations.emit("session.resourcesChanged", {});
        this.operations.publishSnapshot();
      } finally {
        work.settle();
      }
    });
  }

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
    if (this.worker && (terminal.operationId === this.worker.identity.operationId || this.waitingTask?.wakeOperationId === terminal.operationId)) {
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
    if (!this.worker) return false;
    if (!ownership) return true;
    const fence = ownership.taskFence;
    return !!fence && fence.taskId === this.worker.identity.taskId && fence.operationId === this.worker.identity.operationId;
  }

  /** The task operation a turn reports under. A wake that continues the held task is the task's
   * next turn, so its report seals the task's operation, not the wake's own. */
  taskTurnOperationId(operationId: string): string {
    return this.waitingTask?.wakeOperationId === operationId && this.worker ? this.worker.identity.operationId : operationId;
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
    if (terminal.lifecycle !== "completed" || !this.worker?.acceptsSteering) return false;
    const last = this.operations.sessionManager.getBranch().findLast(entry => entry.type === "message" && entry.message.role === "assistant");
    return last?.type === "message" && last.message.role === "assistant" && last.message.stopReason === "stop"
      && this.operations.hasDetachedDashboardWork();
  }

  /** Task cancellation follows the root prompt owner, not its disposable
   * presentation primitive (automatic compaction/retry may have another ID). */
  async cancelHomeTaskOperation(operationId: string, reason: string): Promise<void> {
    if (!this.worker || this.worker.identity.operationId !== operationId) throw new GatewayError("conflict", "Task cancellation owner changed");
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
