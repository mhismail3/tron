import type { RunOperations } from "./run-operations.js";
import type { AgentMessage } from "../pi/agent-core.js";
import type { AgentTerminalOutcome } from "../host/module-host.js";

interface OperationObservation {
  cursor?: { entryIndex: number };
  observedCompletionId?: string;
  pendingCompletionId?: string;
}

const MAX_COMPLETION_DISPOSITIONS = 16;

export class RunTerminalOwner {
  notificationRun: { assistant?: AgentMessage } | undefined;
  waitingNotificationEpisode: string | undefined;
  private readonly completionDispositions = new Map<string, boolean>();

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
    if (this.operations.ownedTurns.worker) return;
    const runTerminal = this.operations.dependencies.modules.policy("runTerminal")?.();
    if (!runTerminal) return;
    const previousEpisode = this.waitingNotificationEpisode;
    let claimedEpisode: string | undefined;
    try {
      const pendingBackgroundProcesses = this.operations.pendingBackgroundProcesses();
      const waitingEpisode = pendingBackgroundProcesses.join("\0");
      claimedEpisode = waitingEpisode || undefined;
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
      if (this.waitingNotificationEpisode === claimedEpisode) this.waitingNotificationEpisode = previousEpisode;
      this.operations.emit("session.diagnostic", { code: "terminal-notification-failed" });
    }
  }

  takeAgentTerminal(operationId: string | undefined): { sourceId: string; outcome: AgentTerminalOutcome } | undefined {
    const run = this.notificationRun;
    this.notificationRun = undefined;
    if (!run || !operationId) return;
    const { assistant } = run;
    const entry = assistant && this.operations.sessionManager.getBranch().findLast((candidate) =>
      candidate.type === "message" && candidate.message === assistant);
    const invocation = this.operations.runInvocations.invocationForOperation(operationId);
    const sourceId = entry?.id ?? (invocation ? `terminal:${invocation.invocationId}` : operationId);
    const reason = assistant?.role === "assistant" ? assistant.stopReason : undefined;
    const reportCompleted = reason === "toolUse" && this.operations.ownedTurns.worker?.reportSealed === true
      && this.operations.ownedTurns.worker.identity.operationId === operationId;
    const outcome: AgentTerminalOutcome = this.operations.runAbort.abortedOperations.has(operationId) || reason === "aborted" ? "stopped"
      : reason === "error" ? "failed"
      : reason === "length" ? "limited"
      : reason === "stop" || reportCompleted ? "completed"
      : "unknown";
    this.completionObserved(sourceId);
    return { sourceId, outcome };
  }

}
