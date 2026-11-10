import { randomUUID } from "node:crypto";
import type { AgentSessionEvent } from "../pi/coding-agent.js";
import type { SessionOperationState } from "../../protocol/types.js";
import { safeJson } from "../projection/projection.js";
import { redactProcessText } from "../projection/process-activity.js";
import type { RunOperations } from "./run-operations.js";

export class RunEventsOwner {
  constructor(private readonly operations: RunOperations<unknown>) {}

  onEvent(event: AgentSessionEvent): void {
    switch (event.type) {
      case "agent_start": {
        const precedingAssistant = this.operations.runTerminal.notificationRun?.assistant;
        this.operations.runTerminal.notificationRun = undefined;
        const continuationFromSettlement = this.operations.runAttention.pendingAssistantCompletion !== undefined
          || this.operations.runAttention.hasPendingAssistantBinding;
        const dequeuedOwner = this.operations.runQueue.dequeuedFollowUpOwners[0];
        const queuedOwner = dequeuedOwner
          ?? this.operations.runQueue.queuedMessages.find((item) => item.behavior === "followUp")?.id;
        if (this.operations.compactionOperation && this.operations.pendingPrompt?.id === this.operations.activeOperationId
          && this.operations.runInvocations.invocationForOperation(this.operations.activeOperationId)?.lifecycle === "staged") {
          this.operations.activeOperationId = undefined;
          this.operations.operation = undefined;
        }
        const preflightOwner = this.operations.pendingExtensionCommand?.id
          ?? queuedOwner
          ?? this.operations.activeOperationId
          ?? this.operations.runQueue.pendingQueueAdmission?.id;
        const continuesToolSegment = continuationFromSettlement
          && queuedOwner === undefined
          && this.operations.pendingExtensionCommand === undefined
          && this.operations.activeToolSegmentOwnerId !== undefined
          && !this.operations.toolSegmentAwaitsAssistantOwner;
        const beginsWithUserInput = queuedOwner !== undefined
          || this.operations.pendingPrompt?.id === preflightOwner
          || this.operations.runQueue.pendingQueueAdmission?.id === preflightOwner;
        const requiresDistinctAgentOwner = queuedOwner === undefined
          && (continuationFromSettlement || this.operations.pendingExtensionCommand !== undefined);
        if (continuationFromSettlement) {
          if (this.operations.runAttention.pendingAssistantCompletion) {
            if (!this.operations.runAttention.pendingAssistantCompletion.operationId && this.operations.activeOperationId) {
              this.operations.runAttention.pendingAssistantCompletion = { ...this.operations.runAttention.pendingAssistantCompletion, operationId: this.operations.activeOperationId };
            }
            if (this.operations.activeOperationId) this.operations.runTerminal.observationFor(this.operations.activeOperationId).pendingCompletionId = this.operations.runAttention.pendingAssistantCompletion.id;
            const completion = this.operations.runAttention.pendingAssistantCompletion;
            void this.operations.runAttention.beginAttentionSettlement(completion).catch((error) => this.operations.runAttention.settleCompletionPersistenceFailure(completion, error));
          }
          this.operations.runInvocations.terminalizeTransferredOperation(this.operations.activeOperationId);
          this.operations.activeOperationId = undefined;
          this.operations.operation = undefined;
        }
        if (!this.operations.lifecycle.admitAgentStartDuringDrain(preflightOwner)) {
          const rejectedOperationId = preflightOwner;
          if (dequeuedOwner && rejectedOperationId === dequeuedOwner) this.operations.runQueue.dequeuedFollowUpOwners.shift();
          this.operations.phase = "interrupted";
          this.operations.operation = undefined;
          this.operations.activeOperationId = undefined;
          if (this.operations.pendingExtensionCommand?.id === rejectedOperationId) this.operations.pendingExtensionCommand = undefined;
          this.operations.emit("session.operationFailed", {
            message: "Extension continuation was rejected after the administrative drain cutoff",
          });
          const rejectedInvocation = this.operations.runInvocations.invocationForOperation(rejectedOperationId);
          const precedingEntry = continuationFromSettlement && precedingAssistant
            ? this.operations.sessionManager.getBranch().findLast((entry) => entry.type === "message" && entry.message === precedingAssistant)
            : undefined;
          const rejectedSource = precedingEntry?.id
            ?? (rejectedInvocation ? `terminal:${rejectedInvocation.invocationId}` : rejectedOperationId);
          if (rejectedSource) this.operations.runTerminal.completionObserved(rejectedSource);
          void this.operations.runtime.session.abort().then(async () => {
            if (continuationFromSettlement) await this.operations.reconcileAttention();
            else await this.operations.runInvocations.terminalizeInvocation(rejectedOperationId, "interrupted", "drain-cutoff");
            if (rejectedSource) await this.operations.runTerminal.notifyAgentTerminal(rejectedSource, "stopped");
          }).catch(() => {
            this.operations.emit("session.diagnostic", { code: "drain-cutoff-settlement-failed" });
          }).finally(() => this.operations.runWork.settleOperationWork(rejectedOperationId));
          this.operations.publishSnapshot();
          break;
        }
        this.operations.runTerminal.notificationRun = {};
        if (dequeuedOwner && preflightOwner === dequeuedOwner) this.operations.runQueue.dequeuedFollowUpOwners.shift();
        if (queuedOwner && preflightOwner === queuedOwner && this.operations.activeOperationId !== queuedOwner) {
          this.operations.runInvocations.terminalizeTransferredOperation(this.operations.activeOperationId);
          this.operations.runTerminal.retireOperationObservation(this.operations.activeOperationId);
          this.operations.activeOperationId = undefined;
          this.operations.operation = undefined;
        }
        this.operations.phase = "running";
        this.operations.resetToolExecutionProjection();
        this.operations.activeOperationId ??= requiresDistinctAgentOwner ? randomUUID() : (preflightOwner ?? randomUUID());
        this.operations.runTerminal.observationFor(this.operations.activeOperationId).cursor = { entryIndex: this.operations.canonicalSessionEntries().length };
        if (!continuesToolSegment) {
          if (beginsWithUserInput) {
            this.operations.ownToolSegment(this.operations.activeOperationId);
            const usedModel = this.operations.runtime.session.model;
            if (usedModel) this.operations.dependencies.modules.policy("modelUsed")?.(this.operations.id, { provider: usedModel.provider, id: usedModel.id });
          } else this.operations.prepareAssistantOwnedToolSegment();
        }
        this.operations.homeRequestPolicy?.responseTiming.started(this.operations.activeOperationId);
        const activeInvocation = this.operations.runInvocations.invocationForOperation(this.operations.activeOperationId);
        if (this.operations.operation?.kind === "compaction") this.operations.operation = undefined;
        this.operations.operation ??= {
          id: this.operations.activeOperationId,
          kind: "prompt",
          startedAt: new Date().toISOString(),
          ...(activeInvocation ? { invocationId: activeInvocation.invocationId } : {}),
        };
        this.operations.runWork.beginDerivedOperationWork(this.operations.activeOperationId, "foreground-agent-operation");
        void this.operations.enqueueMarkerOwnership(this.operations.activeOperationId)
          .catch(() => this.operations.runtime.session.abort());
        if (!this.operations.activityHeartbeat) this.operations.startActivityHeartbeat();
        this.operations.publishSnapshot();
        break;
      }
      case "agent_end":
        if (this.operations.runTerminal.notificationRun) {
          const assistant = event.messages.findLast((message) => message.role === "assistant");
          this.operations.runTerminal.notificationRun = assistant ? { assistant } : {};
        }
        break;
      case "agent_settled":
        if (this.operations.shuttingDown) break;
        if (this.operations.hasActiveAgentRun) {
          this.operations.runAttention.ensureAgentProjection();
          this.operations.publishSnapshot();
          break;
        }
        if (this.operations.manualCompaction.queuedManualCompactionInFlight && !this.operations.manualCompaction.adoptedManualCompaction) {
          this.operations.publishSnapshot();
          break;
        }
        this.operations.resetStreamingProjection();
        this.operations.phase = this.operations.compactionOperation ? "compacting" : "idle";
        const settledOperationId = this.operations.activeOperationId;
        const terminalNotification = this.operations.runTerminal.takeAgentTerminal(settledOperationId);
        const terminalLifecycle = terminalNotification?.outcome === "stopped" ? "interrupted" as const
          : terminalNotification?.outcome === "failed" ? "failed" as const
          : terminalNotification?.outcome === "unknown" ? "outcomeUnknown" as const
          : "completed" as const;
        const terminalErrorCode = terminalLifecycle === "interrupted"
          ? (settledOperationId && this.operations.runAbort.abortedOperations.has(settledOperationId) ? "user-abort" : "agent-aborted")
          : terminalLifecycle === "failed" ? "agent-error" : undefined;
        this.operations.runAbort.completeContinuation(terminalLifecycle);
        this.operations.activeOperationId = undefined;
        this.operations.homeRequestPolicy?.settle(settledOperationId);
        this.operations.ownToolSegment(undefined);
        this.operations.operation = this.operations.compactionOperation;
        this.operations.retry = undefined;
        this.operations.resetToolExecutionProjection();
        if (!this.operations.hasCurrentDashboardWork()) this.operations.stopActivityHeartbeat();
        this.operations.clearToolProgressTimers();
        if (this.operations.pendingExtensionCommand === undefined
          || this.operations.pendingExtensionCommand.id !== settledOperationId) {
          if (this.operations.runAttention.pendingAssistantCompletion) {
            this.operations.runWork.get(settledOperationId ?? "")?.transition("terminal-receipt-persistence");
            this.operations.phase = "running";
            this.operations.publishSnapshot();
            const completion = this.operations.runAttention.pendingAssistantCompletion;
            this.operations.runPersistence.trackSettlementChain((async () => {
              const terminal = await this.operations.runInvocations.persistInvocationTerminal(
                settledOperationId, terminalLifecycle, terminalErrorCode, undefined,
                settledOperationId === completion.operationId ? completion.id : undefined,
              );
              await this.operations.runAttention.beginAttentionSettlement(completion);
              if (terminal) await this.operations.ownedTurns.notifyOwnedTerminal(terminal);
              const completionOperationId = completion.operationId ?? this.operations.runTerminal.completionOperationId(completion.id);
              if (completionOperationId) this.operations.runTerminal.retireOperationObservation(completionOperationId);
              this.operations.runTerminal.retireOperationObservation(settledOperationId);
              if (settledOperationId && settledOperationId !== completion.operationId) {
                await this.operations.clearMarkerOwnership(settledOperationId);
                this.operations.runWork.settleOperationWork(settledOperationId);
              }
              if (settledOperationId) this.operations.runAbort.abortedOperations.delete(settledOperationId);
              if (terminalNotification) await this.operations.runTerminal.notifyAgentTerminal(terminalNotification.sourceId, terminalNotification.outcome);
            })().catch(() => {}));
            break;
          }
          if (settledOperationId) {
            this.operations.runWork.get(settledOperationId)?.transition("terminal-receipt-persistence");
            const markerClear = this.operations.runInvocations.terminalizeInvocation(
              settledOperationId,
              terminalLifecycle,
              terminalErrorCode,
              undefined,
              this.operations.runTerminal.operationObservations.get(settledOperationId)?.observedCompletionId,
            ).then(async () => {
              this.operations.runTerminal.retireOperationObservation(settledOperationId);
              if (terminalNotification) await this.operations.runTerminal.notifyAgentTerminal(terminalNotification.sourceId, terminalNotification.outcome);
              await this.operations.clearMarkerOwnership(settledOperationId);
            });
            this.operations.runPersistence.trackSettlementChain(markerClear.then(
              () => this.operations.manualCompaction.startPendingManualCompaction(),
              (error) => {
                this.operations.manualCompaction.cancelPending(error);
                this.operations.emit("session.diagnostic", safeJson({
                  code: "terminal-receipt-persistence-failed",
                  operationId: settledOperationId,
                  message: error instanceof Error ? error.message : String(error),
                }));
              },
            ).finally(() => {
              this.operations.runAbort.abortedOperations.delete(settledOperationId);
              this.operations.runWork.settleOperationWork(settledOperationId);
              this.operations.hooks.settled(this.operations.id);
              this.operations.publishSnapshot();
            }));
          } else {
            this.operations.hooks.settled(this.operations.id);
          }
        }
        this.operations.publishSnapshot();
        break;
      case "compaction_start": {
        const adoptedManual = this.operations.manualCompaction.adoptPending(event);
        this.operations.phase = "compacting";
        this.operations.prepareAssistantOwnedToolSegment();
        this.operations.compactionBaselineEntryId = [...this.operations.sessionManager.getBranch()]
          .reverse()
          .find((entry) => entry.type === "compaction")?.id;
        const compactionOperation: SessionOperationState = {
          id: adoptedManual?.operationId ?? (this.operations.operation?.kind === "compaction"
            ? (this.operations.operation.id ?? randomUUID())
            : randomUUID()),
          kind: "compaction",
          startedAt: this.operations.operation?.kind === "compaction" && event.reason === "manual"
            ? this.operations.operation.startedAt : new Date().toISOString(),
          reason: event.reason,
        };
        this.operations.operation = compactionOperation;
        this.operations.compactionOperation = compactionOperation;
        this.operations.publishSnapshot();
        break;
      }
      case "compaction_end": {
        const completedOperation = this.operations.compactionOperation;
        const ownerStillCurrent = completedOperation !== undefined && this.operations.operationMatches(completedOperation);
        const outcome = event.aborted ? "cancelled" : event.result ? "success" : "failure";
        const errorMessage = event.errorMessage
          ? redactProcessText(event.errorMessage).slice(0, 512)
          : undefined;
        this.operations.dependencies.compactionDiagnostic?.({
          sessionId: this.operations.id,
          ...(completedOperation?.id ? { operationId: completedOperation.id } : {}),
          reason: event.reason,
          outcome,
          ...(errorMessage ? { errorMessage } : {}),
        });
        if (ownerStillCurrent) this.operations.retry = undefined;
        if (completedOperation?.kind === "compaction" && completedOperation.id) {
          const canonicalCompaction = [...this.operations.sessionManager.getBranch()]
            .reverse()
            .find((entry) => entry.type === "compaction");
          if (canonicalCompaction && canonicalCompaction.id !== this.operations.compactionBaselineEntryId) {
            this.operations.rememberPresentationID(canonicalCompaction.id, completedOperation.id);
          }
        }
        this.operations.compactionBaselineEntryId = undefined;
        this.operations.compactionOperation = undefined;
        this.operations.manualCompaction.settleAdopted(outcome, errorMessage);
        if (completedOperation?.id) this.operations.runAbort.abortedOperations.delete(completedOperation.id);
        if (outcome === "failure" && event.reason !== "manual"
          && (ownerStillCurrent || completedOperation === undefined)) {
          this.operations.emit("session.operationFailed", {
            ...(completedOperation?.id ? { operationId: completedOperation.id } : {}),
            message: errorMessage
              ? `Automatic compaction failed: ${errorMessage}`
              : "Automatic compaction failed. Check Gateway logs for details.",
          });
        }
        if (!ownerStillCurrent) {
          this.operations.publishSnapshot();
          break;
        }
        if (this.operations.pendingPrompt) {
          this.operations.phase = "running";
          this.operations.operation = {
            id: this.operations.pendingPrompt.id,
            kind: "prompt",
            startedAt: this.operations.pendingPrompt.createdAt ?? new Date().toISOString(),
          };
        } else if (this.operations.hasActiveAgentRun) {
          this.operations.phase = "running";
          this.operations.activeOperationId ??= randomUUID();
          this.operations.operation = {
            id: this.operations.activeOperationId,
            kind: "prompt",
            startedAt: new Date().toISOString(),
          };
        } else if (completedOperation.kind === "compaction"
          && completedOperation.reason === "manual" && !this.operations.manualCompaction.adoptedManualCompaction) {
          this.operations.phase = "compacting";
          this.operations.operation = completedOperation;
        } else {
          this.operations.phase = "idle";
          this.operations.operation = undefined;
        }
        this.operations.publishSnapshot();
        break;
      }
      case "auto_retry_start":
        this.operations.phase = "retrying";
        this.operations.retry = {
          source: "agent",
          attempt: event.attempt,
          maxAttempts: event.maxAttempts,
          delayMs: event.delayMs,
          errorMessage: event.errorMessage,
        };
        this.operations.operation = { kind: "retry", startedAt: new Date().toISOString() };
        this.operations.publishSnapshot();
        break;
      case "summarization_retry_scheduled":
        this.operations.phase = "retrying";
        this.operations.retry = {
          source: this.operations.operation?.kind === "branchSummary" ? "branchSummary" : "compaction",
          attempt: event.attempt,
          maxAttempts: event.maxAttempts,
          delayMs: event.delayMs,
          errorMessage: event.errorMessage,
        };
        this.operations.publishSnapshot();
        break;
      case "summarization_retry_attempt_start":
        this.operations.retry = this.operations.retry ? { ...this.operations.retry, source: event.source } : { source: event.source, attempt: 1 };
        this.operations.publishSnapshot();
        break;
      case "summarization_retry_finished":
        this.operations.retry = undefined;
        this.operations.scheduleSnapshot();
        break;
      case "auto_retry_end":
        this.operations.emit("session.retry", safeJson(event));
        this.operations.runAttention.ensureAgentProjection();
        this.operations.retry = undefined;
        this.operations.scheduleSnapshot();
        break;
    }
  }
}
