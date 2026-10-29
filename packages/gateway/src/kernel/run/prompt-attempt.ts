import type { RunOperations } from "./run-operations.js";
import { safeJson } from "../projection/projection.js";
import { makeInvocationReceipt, type InvocationProjection } from "../receipts/invocation-receipts.js";
import type { QueueAdmissionDisposition } from "./queue-input.js";


export interface PromptAttemptInput {
  operationId: string;
  invocationId: string;
  invocationSource: InvocationProjection["source"];
  invocationName: string | undefined;
  invocation: InvocationProjection;
  isExactExtensionCommand: boolean;
  acceptedResolve(accepted: boolean): void;
  resolveQueueDisposition: ((disposition: QueueAdmissionDisposition) => void) | undefined;
}

/** Owns one admitted SDK promise and its exact completion/finalization lifetime. */
export class PromptAttempt {
  runSettled = false;
  commandSettled = false;
  private terminalReceiptPersisted = false;
  admissionAccepted = false;
  finalizeAdmission!: () => void;
  private readonly admissionFinalized: Promise<void>;
  readonly run: Promise<void>;
  private noAgentSettlementStarted!: boolean;
  queueDispositionFailure: unknown;

  constructor(
    private readonly operations: RunOperations<unknown>,
    private readonly input: PromptAttemptInput,
    sdkRun: Promise<void>,
    private readonly queuesIntoActiveRun: () => boolean,
  ) {
    const { operationId, isExactExtensionCommand, acceptedResolve, resolveQueueDisposition } = input;
    this.admissionFinalized = new Promise<void>((resolve) => { this.finalizeAdmission = resolve; });
    const promptRun = operations.lifecycle.trackPrompt(sdkRun, () => {
      this.runSettled = true;
      operations.maybePerformExtensionShutdown();
    });
    this.run = isExactExtensionCommand
      ? operations.lifecycle.trackCommand(promptRun, () => { this.commandSettled = true; operations.maybePerformExtensionShutdown(); })
      : promptRun;
    this.noAgentSettlementStarted = false;

    void this.run.then(
      async () => {
        if (this.operations.runQueue.pendingQueueAdmission?.id === operationId) {
          this.operations.runQueue.pendingQueueAdmission = undefined;
          resolveQueueDisposition?.("handled");
        }
        await this.admissionFinalized;
        if (this.admissionAccepted) await this.settleWithoutAgent();
      },
      async (error) => {
        // Before queue/user disposition, rejection is definitive and wakes
        // that exact admission below. After disposition, canonical/runtime
        // lifecycle remains authoritative for already accepted work.
        if (!this.operations.runAbort.abortedOperations.has(operationId)) this.operations.emit("session.diagnostic", safeJson({
          code: "runtime-prompt-failed",
          operationId,
          message: error instanceof Error ? error.message : String(error),
        }));
        acceptedResolve(false);
        if (this.operations.runQueue.pendingQueueAdmission?.id === operationId) {
          this.operations.runQueue.pendingQueueAdmission = undefined;
          this.queueDispositionFailure = error;
          resolveQueueDisposition?.("failed");
        }
        await this.admissionFinalized;
        if (this.admissionAccepted) await this.settleWithoutAgent("failed");
      },
    ).catch((error) => this.operations.emit("session.diagnostic", safeJson({
      code: "runtime-prompt-settlement-failed",
      operationId,
      message: error instanceof Error ? error.message : String(error),
    })));

  }

  async settleWithoutAgent(
    terminalLifecycle: "completed" | "failed" = "completed",
  ): Promise<void> {
    const { operationId, invocationId, isExactExtensionCommand } = this.input;
    if (this.operations.shuttingDown || this.operations.hasActiveAgentRun || this.queuesIntoActiveRun()) return;
    const owned = this.operations.activeOperationId === operationId || this.operations.operation?.id === operationId;
    if (!owned || (this.operations.manualCompaction.queuedManualCompactionInFlight && !this.operations.manualCompaction.adoptedManualCompaction) || this.noAgentSettlementStarted) return;
    this.noAgentSettlementStarted = true;
    if (terminalLifecycle === "failed") this.operations.runTerminal.completionObserved(`terminal:${invocationId}`);
    if (this.operations.pendingPrompt?.id === operationId) {
      this.operations.clearPendingPrompt();
    }
    // A handled input creates no canonical user/assistant entry. Persist its
    // terminal outcome for every invocation, not only Automation callers.
    // A rejected Pi call uses the same no-agent cleanup but remains failed.
    await this.operations.runInvocations.terminalizeInvocation(
      operationId,
      terminalLifecycle,
      terminalLifecycle === "failed" ? "runtime-prompt-failed" : undefined,
    );
    this.operations.lifecycle.cancelPreflight(operationId);
    if (!operationId.startsWith("automation:") && operationId !== this.operations.ownedTurns.worker?.identity.operationId) {
      await this.operations.clearMarkerOwnership(operationId);
    }
    // Marker I/O may suspend behind a newer run. Clear only this run's live
    // projection; conditional marker deletion already protects its successor.
    if (this.operations.activeOperationId === operationId) (this.operations.activeOperationId = undefined);
    if (this.operations.activeOperationId === undefined) this.operations.homeRequestPolicy?.settle(operationId);
    if (this.operations.operation?.id === operationId) (this.operations.operation = undefined);
    this.operations.runWork.settleOperationWork(operationId);
    if (terminalLifecycle === "failed") {
      this.operations.emit("session.operationFailed", {
        operationId,
        message: "The agent runtime failed before creating canonical input",
      });
      if (!isExactExtensionCommand && !this.operations.shuttingDown) await this.operations.runTerminal.notifyAgentTerminal(`terminal:${invocationId}`, "failed");
    }
    if (this.operations.activeOperationId !== undefined || this.operations.hasActiveAgentRun) return;
    (this.operations.phase = "idle");
    this.operations.noteHomeIdle();
    if (this.operations.manualCompaction.pendingManualCompaction) {
      this.operations.publishSnapshot();
      this.operations.manualCompaction.startPendingManualCompaction();
    } else {
      this.operations.hooks.settled(this.operations.id);
      this.operations.publishChanged();
    }
  }

  async finishCommand(): Promise<void> {
    const { operationId, invocationId, invocationSource, invocationName, invocation } = this.input;
    if (this.operations.pendingExtensionCommand?.id !== operationId) return;
    // Latch the terminal fact before marker transfer or attention
    // settlement. Those branches may return early while a continuation
    // owns the assistant completion; the invocation must already be
    // durably terminal in that overlap window.
    if (!this.terminalReceiptPersisted) {
      const terminalLifecycle = this.operations.runInvocations.invocationFailures.delete(invocationId)
        ? "failed"
        : this.commandSettled ? "completed" : "outcomeUnknown";
      await this.operations.runInvocations.persistInvocationReceipt(makeInvocationReceipt({
        version: 1,
        receiptId: `terminal:${invocationId}`,
        receiptKind: "terminal",
        invocationId,
        operationId,
        sessionId: this.operations.id,
        source: invocationSource,
        ...(invocationName ? { name: invocationName } : {}),
        lifecycle: terminalLifecycle,
        origin: invocation.origin,
        sequence: this.operations.revision + 1,
        createdAt: new Date().toISOString(),
      }), this.operations.runWork.get(operationId));
      this.terminalReceiptPersisted = true;
      this.operations.runInvocations.invocations.delete(invocationId);
    }
    if (this.operations.hasActiveAgentRun && this.operations.activeOperationId !== undefined) {
      // Transfer marker ownership back to the foreground/new agent run:
      // commit its record before retiring the command's provisional one.
      await this.operations.enqueueMarkerOwnership(this.operations.activeOperationId!);
      await this.operations.clearMarkerOwnership(operationId);
    } else if (this.operations.activeOperationId === undefined) {
      if (this.operations.runAttention.pendingAssistantCompletion) {
        // No continuation claimed the final assistant entry. Retire the
        // command owner, then let the same durable attention barrier own
        // marker cleanup and truthful settlement.
        (this.operations.pendingExtensionCommand = undefined);
        await this.operations.runAttention.beginAttentionSettlement(this.operations.runAttention.pendingAssistantCompletion!);
        this.operations.maybePerformExtensionShutdown();
        return;
      }
      await this.operations.clearMarkerOwnership(operationId);
      this.operations.hooks.settled(this.operations.id);
    }
    if (this.operations.pendingExtensionCommand?.id !== operationId) return;
    (this.operations.pendingExtensionCommand = undefined);
    this.operations.runWork.settleOperationWork(operationId);
    this.operations.publishChanged();
    this.operations.maybePerformExtensionShutdown();
  }
}
