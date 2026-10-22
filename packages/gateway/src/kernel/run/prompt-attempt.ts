import type { SessionOperationState, PendingPromptState, JsonValue } from "../../protocol/types.js";
import type { ExtensionLifecycleCoordinator } from "../../sessions/extension-lifecycle-coordinator.js";
import type { RequestPolicy } from "../host/request-policy.js";
import { safeJson } from "../projection/projection.js";
import { makeInvocationReceipt, type InvocationProjection } from "./invocation-receipts.js";
import type { GatewayWorkHandle } from "./gateway-work-registry.js";
import type { RunWorkOwner } from "./run-work-owner.js";
import type { RunQueueOwner } from "./run-queue-owner.js";
import type { RunAbortOwner } from "./run-abort-owner.js";
import type { QueueAdmissionDisposition } from "./queue-input.js";

export interface PromptAttemptContext<Completion> {
  lifecycle: ExtensionLifecycleCoordinator;
  runQueue: RunQueueOwner;
  runAbort: RunAbortOwner;
  runWork: RunWorkOwner;
  invocations: Pick<Map<string, InvocationProjection>, "delete">;
  invocationFailures: Pick<Map<string, unknown>, "delete">;
  shuttingDown(): boolean;
  hasActiveAgentRun(): boolean;
  activeOperationId(): string | undefined;
  clearActiveOperation(): void;
  operation(): SessionOperationState | undefined;
  clearOperation(): void;
  queuedManualCompactionInFlight(): boolean;
  adoptedManualCompaction(): object | undefined;
  pendingPrompt(): PendingPromptState | undefined;
  clearPendingPrompt(): void;
  taskOperationId(): string | undefined;
  requestPolicy(): RequestPolicy | undefined;
  pendingManualCompaction(): object | undefined;
  pendingExtensionCommand(): SessionOperationState | undefined;
  clearPendingExtensionCommand(): void;
  pendingAssistantCompletion(): Completion | undefined;
  beginAttentionSettlement(completion: Completion): Promise<void>;
  queuesIntoActiveRun(): boolean;
  completionObserved(id: string): void;
  terminalizeInvocation(id: string, lifecycle: "completed" | "failed", errorCode?: string): Promise<void>;
  clearMarkerOwnership(id: string): Promise<void>;
  enqueueMarkerOwnership(id: string): Promise<void>;
  notifyAgentTerminal(id: string, outcome: "failed"): Promise<void>;
  persistInvocationReceipt(receipt: ReturnType<typeof makeInvocationReceipt>, owner?: GatewayWorkHandle): Promise<void>;
  setIdle(): void;
  noteHomeIdle(): void;
  publishSnapshot(): void;
  publishChanged(): void;
  startPendingManualCompaction(): void;
  maybePerformExtensionShutdown(): void;
  settled(): void;
  sessionId(): string;
  revision(): number;
  emit(topic: string, data: JsonValue): void;
}

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
export class PromptAttempt<Completion> {
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
    private readonly context: PromptAttemptContext<Completion>,
    private readonly input: PromptAttemptInput,
    sdkRun: Promise<void>,
  ) {
    const { operationId, isExactExtensionCommand, acceptedResolve, resolveQueueDisposition } = input;
    this.admissionFinalized = new Promise<void>((resolve) => { this.finalizeAdmission = resolve; });
    const promptRun = context.lifecycle.trackPrompt(sdkRun, () => {
      this.runSettled = true;
      context.maybePerformExtensionShutdown();
    });
    this.run = isExactExtensionCommand
      ? context.lifecycle.trackCommand(promptRun, () => { this.commandSettled = true; context.maybePerformExtensionShutdown(); })
      : promptRun;
    this.noAgentSettlementStarted = false;

    void this.run.then(
      async () => {
        if (this.context.runQueue.pendingQueueAdmission?.id === operationId) {
          this.context.runQueue.pendingQueueAdmission = undefined;
          resolveQueueDisposition?.("handled");
        }
        await this.admissionFinalized;
        if (this.admissionAccepted) await this.settleWithoutAgent();
      },
      async (error) => {
        // Before queue/user disposition, rejection is definitive and wakes
        // that exact admission below. After disposition, canonical/runtime
        // lifecycle remains authoritative for already accepted work.
        if (!this.context.runAbort.abortedOperations.has(operationId)) this.context.emit("session.diagnostic", safeJson({
          code: "runtime-prompt-failed",
          operationId,
          message: error instanceof Error ? error.message : String(error),
        }));
        acceptedResolve(false);
        if (this.context.runQueue.pendingQueueAdmission?.id === operationId) {
          this.context.runQueue.pendingQueueAdmission = undefined;
          this.queueDispositionFailure = error;
          resolveQueueDisposition?.("failed");
        }
        await this.admissionFinalized;
        if (this.admissionAccepted) await this.settleWithoutAgent("failed");
      },
    ).catch((error) => this.context.emit("session.diagnostic", safeJson({
      code: "runtime-prompt-settlement-failed",
      operationId,
      message: error instanceof Error ? error.message : String(error),
    })));

  }

  async settleWithoutAgent(
    terminalLifecycle: "completed" | "failed" = "completed",
  ): Promise<void> {
    const { operationId, invocationId, isExactExtensionCommand } = this.input;
    if (this.context.shuttingDown() || this.context.hasActiveAgentRun() || this.context.queuesIntoActiveRun()) return;
    const owned = this.context.activeOperationId() === operationId || this.context.operation()?.id === operationId;
    if (!owned || (this.context.queuedManualCompactionInFlight() && !this.context.adoptedManualCompaction()) || this.noAgentSettlementStarted) return;
    this.noAgentSettlementStarted = true;
    if (terminalLifecycle === "failed") this.context.completionObserved(`terminal:${invocationId}`);
    if (this.context.pendingPrompt()?.id === operationId) {
      this.context.clearPendingPrompt();
    }
    // A handled input creates no canonical user/assistant entry. Persist its
    // terminal outcome for every invocation, not only Automation callers.
    // A rejected Pi call uses the same no-agent cleanup but remains failed.
    await this.context.terminalizeInvocation(
      operationId,
      terminalLifecycle,
      terminalLifecycle === "failed" ? "runtime-prompt-failed" : undefined,
    );
    this.context.lifecycle.cancelPreflight(operationId);
    if (!operationId.startsWith("automation:") && operationId !== this.context.taskOperationId()) {
      await this.context.clearMarkerOwnership(operationId);
    }
    // Marker I/O may suspend behind a newer run. Clear only this run's live
    // projection; conditional marker deletion already protects its successor.
    if (this.context.activeOperationId() === operationId) this.context.clearActiveOperation();
    if (this.context.activeOperationId() === undefined) this.context.requestPolicy()?.settle(operationId);
    if (this.context.operation()?.id === operationId) this.context.clearOperation();
    this.context.runWork.settleOperationWork(operationId);
    if (terminalLifecycle === "failed") {
      this.context.emit("session.operationFailed", {
        operationId,
        message: "The agent runtime failed before creating canonical input",
      });
      if (!isExactExtensionCommand && !this.context.shuttingDown()) await this.context.notifyAgentTerminal(`terminal:${invocationId}`, "failed");
    }
    if (this.context.activeOperationId() !== undefined || this.context.hasActiveAgentRun()) return;
    this.context.setIdle();
    this.context.noteHomeIdle();
    if (this.context.pendingManualCompaction()) {
      this.context.publishSnapshot();
      this.context.startPendingManualCompaction();
    } else {
      this.context.settled();
      this.context.publishChanged();
    }
  }

  async finishCommand(): Promise<void> {
    const { operationId, invocationId, invocationSource, invocationName, invocation } = this.input;
    if (this.context.pendingExtensionCommand()?.id !== operationId) return;
    // Latch the terminal fact before marker transfer or attention
    // settlement. Those branches may return early while a continuation
    // owns the assistant completion; the invocation must already be
    // durably terminal in that overlap window.
    if (!this.terminalReceiptPersisted) {
      const terminalLifecycle = this.context.invocationFailures.delete(invocationId)
        ? "failed"
        : this.commandSettled ? "completed" : "outcomeUnknown";
      await this.context.persistInvocationReceipt(makeInvocationReceipt({
        version: 1,
        receiptId: `terminal:${invocationId}`,
        receiptKind: "terminal",
        invocationId,
        operationId,
        sessionId: this.context.sessionId(),
        source: invocationSource,
        ...(invocationName ? { name: invocationName } : {}),
        lifecycle: terminalLifecycle,
        origin: invocation.origin,
        sequence: this.context.revision() + 1,
        createdAt: new Date().toISOString(),
      }), this.context.runWork.get(operationId));
      this.terminalReceiptPersisted = true;
      this.context.invocations.delete(invocationId);
    }
    if (this.context.hasActiveAgentRun() && this.context.activeOperationId() !== undefined) {
      // Transfer marker ownership back to the foreground/new agent run:
      // commit its record before retiring the command's provisional one.
      await this.context.enqueueMarkerOwnership(this.context.activeOperationId()!);
      await this.context.clearMarkerOwnership(operationId);
    } else if (this.context.activeOperationId() === undefined) {
      if (this.context.pendingAssistantCompletion()) {
        // No continuation claimed the final assistant entry. Retire the
        // command owner, then let the same durable attention barrier own
        // marker cleanup and truthful settlement.
        this.context.clearPendingExtensionCommand();
        await this.context.beginAttentionSettlement(this.context.pendingAssistantCompletion()!);
        this.context.maybePerformExtensionShutdown();
        return;
      }
      await this.context.clearMarkerOwnership(operationId);
      this.context.settled();
    }
    if (this.context.pendingExtensionCommand()?.id !== operationId) return;
    this.context.clearPendingExtensionCommand();
    this.context.runWork.settleOperationWork(operationId);
    this.context.publishChanged();
    this.context.maybePerformExtensionShutdown();
  }
}
