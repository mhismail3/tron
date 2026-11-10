import type { RunOperations } from "./run-operations.js";
import { PromptAttempt } from "./prompt-attempt.js";
import type { ImageContent } from "../pi/ai.js";
import type { SessionPhase } from "../../protocol/types.js";
import { GatewayError, asUncertainOutcome } from "../../errors.js";
import { count, wait } from "../../util/request-span.js";
import { withInvocationContext } from "../host/extension-execution-context.js";
import { safeJson } from "../projection/projection.js";
import type { InputTrigger } from "../host/input-admission.js";
import type { GatewayWorkHandle } from "./gateway-work-registry.js";
import type { QueueBehavior, PromptQueueDisplay, HeldPrompt, RuntimeQueuedMessage, QueueAdmissionDisposition } from "./queue-input.js";
import { makeInvocationReceipt } from "../receipts/invocation-receipts.js";
import { deliverPromptInput } from "./context-delivery.js";
import { preparePromptInput, preparePromptIntent, promptStartReceipt, type PromptOwnership } from "./prompt-input.js";

export async function admitPrompt<TaskFence extends { taskId: string; operationId: string }>(
operations: RunOperations<unknown>,
  text: string,
  images: ImageContent[],
  behavior: QueueBehavior | undefined,
  queueDisplay: PromptQueueDisplay | undefined,
  onAdmitted: ((result: { operationId: string }) => void) | undefined,
  ownership: PromptOwnership<TaskFence> | undefined,
  operationId: string,
  held?: HeldPrompt,
  redelivery?: RuntimeQueuedMessage,
  laneOwned = false,
): Promise<{ operationId: string }> {
  return wait("session.prompt.runtime-lane", (acquired) => {
    const run = async () => {
    acquired();
    ownership?.signal?.throwIfAborted();
    operations.assertUsable();
    operations.assertHomePromptAdmission();
    if (ownership?.kind === "homeWake" && (ownership.inputCancellation !== operations.runAbort.inputCancellation
      || ownership.cancellationEpoch !== ownership.inputCancellation.epoch)) {
      throw new GatewayError("cancelled", "Home wake stopped before admission");
    }
    if (!ownership && operations.runAbort.stopRecoveryQueueClosed && !held && !redelivery) {
      const heldAdmission = operations.heldQueue.holdPrompt(text, images, behavior, queueDisplay, true);
      onAdmitted?.(heldAdmission);
      return heldAdmission;
    }
    try {
      if (operations.runAttention.attentionBarrier) await operations.runAttention.attentionBarrier;
    } catch {
      throw operations.attentionPendingError();
    }
    if (operations.runAttention.completionOwnershipQueue.length > 0 || operations.runAttention.pendingAssistantCompletion) {
      throw operations.attentionPendingError();
    }
    if (operations.lifecycle.isDraining) throw new GatewayError("busy", "Session is draining for an administrative restart", true);
    const session = operations.runtime.session;
    if (ownership?.kind === "homeWake") await operations.assertHomeWakeAdmissible(session);
    if (operations.ownedTurns.worker) {
      const trust = await operations.dependencies.trust.requireResolved(operations.cwd);
      if (!trust.trusted) throw new GatewayError("trust_required", "Home task target is no longer trusted");
      if (ownership?.operationId === operations.ownedTurns.worker.identity.operationId) {
        await operations.persistTaskMarker(operationId);
      } else if ((ownership?.kind === "subagentWake" || operations.ownedTurns.sharedTaskSteering(ownership)) && operations.ownedTurns.waitingTask && operations.ownedTurns.waitingTask.wakeOperationId === undefined
        && operations.ownedTurns.worker.acceptsSteering && operations.activeOperationId === undefined && operations.operation === undefined && !session.isStreaming) {
      } else {
        const fence = ownership?.taskFence;
        if (!ownership && operations.ownedTurns.worker.acceptsSteering) behavior = "steer";
        if (behavior !== "steer" || operations.ownedTurns.liveTaskOperationId() !== operations.ownedTurns.worker.identity.operationId
          || !session.isStreaming || !operations.ownedTurns.worker.acceptsSteering
          || (fence && (fence.taskId !== operations.ownedTurns.worker.identity.taskId || fence.operationId !== operations.ownedTurns.worker.identity.operationId))) {
          throw new GatewayError("conflict", "Stale or settled task operation cannot accept steering");
        }
      }
    }
    while (operations.isAgentAdmissionSettling) {
      await operations.waitForStateChange();
      operations.assertUsable();
    }
    const prepared = preparePromptInput(operations, session, text, images, queueDisplay, ownership);
    text = prepared.text;
    const { composedResources, isExactExtensionCommand } = prepared;
    const homeDelivery = ownership ? "wake" : "user";
    if (!session.isStreaming) {
      await session.settingsManager.flush();
      await operations.applyLiveRunSettings(session);
      operations.compactionPolicies.get(session)?.applyBudgets();
      operations.contextPolicies.get(session)?.apply();
    }
    let queuesIntoActiveRun = session.isStreaming && behavior !== undefined && !isExactExtensionCommand;
    if (ownership && operations.ownedTurns.observers.has(operationId)) {
      throw new GatewayError("conflict", "Automation operation is already registered", true);
    }
    const intent = preparePromptIntent(operations, session, text, images, behavior, queueDisplay, ownership, operationId, redelivery, prepared);
    const { invocationId, invocationSource, invocationName, invocation, queueAdmissionDisplay } = intent;
    if (queuesIntoActiveRun) operations.runQueue.validateAdmission(queueAdmissionDisplay, redelivery);

    if (ownership && ownership.kind !== "subagentWake" && ownership.kind !== "homeWake") operations.ownedTurns.observers.set(operationId, ownership.onTerminal);
    let operationWork!: GatewayWorkHandle;
    let preflightStarted = false;
    const runIdleAtAdmission = !operations.runtime.session.isStreaming;
    let acceptedResolve!: (accepted: boolean) => void;
    const accepted = new Promise<boolean>((resolve) => { acceptedResolve = resolve; });
    let sdkRun: Promise<void>;
    let preflightFailure: GatewayError | undefined;
    let handledWithoutAgent = false;
    let queueDisposition: Promise<QueueAdmissionDisposition> | undefined;
    let resolveQueueDisposition: ((disposition: QueueAdmissionDisposition) => void) | undefined;
    let startPersisted = false;
    let phaseBeforeAdmission: SessionPhase | undefined;
    try {
      await operations.dependencies.beforeRunAdmission(operations.id);
      operations.assertHomePromptAdmission();
      operations.runInvocations.invocations.set(invocationId, invocation);
      while (operations.runInvocations.invocations.size > 128) operations.runInvocations.invocations.delete(operations.runInvocations.invocations.keys().next().value!);
      operationWork = operations.runWork.beginOperationWork(operationId);
      if (redelivery) operations.lifecycle.cancelPreflight(operationId);
      operations.lifecycle.beginPreflight(operationId);
      preflightStarted = true;

      const startReceipt = promptStartReceipt(operations, operationId, intent);
      if (!redelivery) await operations.runInvocations.persistInvocationReceipt(startReceipt, operationWork);
      startPersisted = true;
      operations.assertHomePromptAdmission();

      queuesIntoActiveRun = session.isStreaming && behavior !== undefined && !isExactExtensionCommand;
      if (session.isStreaming && !behavior && !isExactExtensionCommand) {
        throw new GatewayError("busy", "Session is running; choose steer or follow-up");
      }
      if (queuesIntoActiveRun) {
        operations.runQueue.validateAdmission(queueAdmissionDisplay, redelivery);
        let dispositionResolved = false;
        queueDisposition = new Promise<QueueAdmissionDisposition>((resolve) => {
          resolveQueueDisposition = (disposition) => {
            if (dispositionResolved) return;
            dispositionResolved = true;
            resolve(disposition);
          };
        });
        operations.runQueue.recordPendingAdmission(operationId, behavior!, queueAdmissionDisplay, images, redelivery,
          (disposition) => resolveQueueDisposition?.(disposition));
      }

      let homeWakeTrigger: InputTrigger | undefined;
      if (isExactExtensionCommand) {
        operations.pendingExtensionCommand = { id: operationId, kind: "command", startedAt: new Date().toISOString(), invocationId, lifecycle: "staged" };
        await operations.enqueueMarkerOwnership(operationId);
        operations.revision += 1;
        operations.publishSnapshot();
      } else if (!queuesIntoActiveRun) {
        operations.activeOperationId = operationId;
        if ((ownership?.kind === "subagentWake" || operations.ownedTurns.sharedTaskSteering(ownership)) && operations.ownedTurns.waitingTask && operations.ownedTurns.waitingTask.wakeOperationId === undefined) {
          operations.ownedTurns.waitingTask.wakeOperationId = operationId;
        }
        phaseBeforeAdmission = operations.phase;
        operations.phase = "running";
        operations.operation = { id: operationId, kind: "prompt", startedAt: new Date().toISOString(), invocationId, lifecycle: "staged" };
        operations.pendingPromptMessage = undefined;
        operations.pendingPrompt = ownership?.kind === "homeWake" ? undefined : operations.promptDisplay(operationId, text, images, queueDisplay);
        if (held) operations.heldQueue.removeHeldPrompt(held.id);
        operations.revision += 1;
        operations.publishSnapshot();
        operations.homeRequestPolicy?.admit(operationId, session.sessionManager.getLeafId() ?? null, session.systemPrompt, homeDelivery);
        operations.operationWasHomeWake = ownership?.kind === "homeWake";
        if (operations.homeRequestPolicy) {
          const inboxAdmissionStarted = performance.now();
          try {
          homeWakeTrigger = await operations.dependencies.modules.policy("inputAdmission")?.().admit(operations.id, operationId, homeDelivery, message => deliverPromptInput(operations, session, message,
            async () => { await operations.dependencies.modules.policy("inputAdmission")?.().committed?.(operations.id, operationId); })
          , () => operations.dependencies.modules.policy("inputAdmission")!().envelope({
            session, policy: operations.homeRequestPolicy!, text, images, signal: ownership?.signal,
            sessionFile: () => operations.sessionFile, entries: () => operations.canonicalEntryCount,
          }));
          } finally {
            operations.dependencies.modules.policy("inputAdmission")?.().finished(inboxAdmissionStarted, homeDelivery);
          }
        }
      }

      ownership?.signal?.throwIfAborted();
      sdkRun = ownership?.kind === "homeWake"
        ? withInvocationContext({ invocationId, operationId, trigger: homeWakeTrigger?.message.details.trigger }, () =>
          operations.startHomeWake(session, operationId, homeWakeTrigger, acceptedResolve, ownership.inputCancellation, ownership.cancellationEpoch, ownership.onDelivered))
        : withInvocationContext({ invocationId, operationId }, () => session.prompt(text, {
        images,
        ...(queuesIntoActiveRun ? { streamingBehavior: behavior! } : {}),
        source: ownership?.kind === "subagentWake" ? "extension" : queueDisplay?.inputSource ?? "rpc",
        ...(ownership?.kind === "subagentWake" ? { expandPromptTemplates: ownership.expandPromptTemplates }
          : composedResources !== undefined ? { expandPromptTemplates: false } : {}),
        preflightResult: (disposition) => {
          handledWithoutAgent = disposition === "handled";
          if (ownership?.signal?.aborted || operations.runAbort.abortedOperations.has(operationId)
            || (operations.ownedTurns.worker && operationId !== operations.ownedTurns.worker.identity.operationId && operations.ownedTurns.waitingTask?.wakeOperationId !== operationId
              && (!operations.ownedTurns.worker.acceptsSteering || operations.ownedTurns.liveTaskOperationId() !== operations.ownedTurns.worker.identity.operationId))) {
            preflightFailure = new GatewayError("cancelled", "Prompt stopped before agent admission");
          } else if (!isExactExtensionCommand && !queuesIntoActiveRun && operations.activeOperationId !== operationId) {
            preflightFailure = new GatewayError("busy", "An extension started a turn during prompt preparation; retry after it settles", true);
          }
          if (preflightFailure) {
            acceptedResolve(false);
            throw preflightFailure;
          }
          invocation.lifecycle = "accepted";
          operations.runInvocations.invocations.set(invocationId, invocation);
          operations.noteAcceptedSteering(operationId);
          if (!ownership) operations.homeRequestPolicy?.responseTiming.accepted(operationId);
          acceptedResolve(true);
        },
      }));
      if (isExactExtensionCommand) {
        if (!ownership) operations.homeRequestPolicy?.responseTiming.accepted(operationId);
        ownership?.onAdmitted?.(invocationId);
        onAdmitted?.({ operationId });
      }
    } catch (error) {
      if (preflightStarted) operations.lifecycle.cancelPreflight(operationId);
      operations.runQueue.pendingQueueAdmission = undefined;
      if (operations.activeOperationId === operationId) operations.activeOperationId = undefined;
      if (operations.activeOperationId === undefined) operations.homeRequestPolicy?.settle(operationId);
      if (operations.operation?.id === operationId) operations.operation = undefined;
      if (operations.pendingPrompt?.id === operationId) {
        operations.pendingPrompt = undefined;
        operations.pendingPromptMessage = undefined;
      }
      if (operations.pendingExtensionCommand?.id === operationId) operations.pendingExtensionCommand = undefined;
      if (phaseBeforeAdmission !== undefined && operations.phase === "running" && !operations.hasActiveAgentRun
        && operations.activeOperationId === undefined && operations.operation === undefined) {
        operations.phase = phaseBeforeAdmission;
        operations.revision += 1;
        operations.publishSnapshot();
      }
      if (startPersisted) {
        await operations.runInvocations.persistInvocationReceipt(makeInvocationReceipt({
          version: 1,
          receiptId: `terminal:${invocationId}`,
          receiptKind: "terminal",
          invocationId,
          operationId,
          sessionId: operations.id,
          source: invocationSource,
          ...(invocationName ? { name: invocationName } : {}),
          lifecycle: "outcomeUnknown",
          origin: invocation.origin,
          sequence: operations.revision + 1,
          createdAt: new Date().toISOString(),
        }), operationWork);
        await operations.ownedTurns.notifyOwnedTerminal({
          lifecycle: "outcomeUnknown",
          operationId,
          invocationId,
        });
      }
      operations.runInvocations.invocations.delete(invocationId);
      operations.runWork.settleOperationWork(operationId);
      if (!startPersisted) operations.ownedTurns.observers.delete(operationId);
      throw startPersisted
        ? asUncertainOutcome(operations.dependencies.modules.policy("requestPolicy")?.().isRefusal(error) ? new GatewayError("conflict", error.message) : error,
          "Prompt admission failed after its canonical start receipt was accepted; refresh session state instead of replaying")
        : error;
    }
    const attempt = new PromptAttempt(operations, {
      operationId, invocationId, invocationSource, invocationName, invocation,
      isExactExtensionCommand, acceptedResolve, resolveQueueDisposition,
    }, sdkRun, () => queuesIntoActiveRun);

    const admitted = await accepted;
    if (queuesIntoActiveRun && admitted) {
      operations.runQueue.reconcileQueuedMessages();
      const disposition = await queueDisposition!;
      queuesIntoActiveRun = disposition === "queued";
      if (disposition === "queued" && held) operations.heldQueue.removeHeldPrompt(held.id);
      if (disposition === "queued" && preflightStarted) {
        operations.lifecycle.cancelPreflight(operationId);
        preflightStarted = false;
      }
      handledWithoutAgent = disposition === "handled";
      if (disposition === "failed") {
        operations.lifecycle.resolvePreflight(operationId, true);
        attempt.admissionAccepted = true;
        operations.runTerminal.completionObserved(`terminal:${invocationId}`);
        await operations.runInvocations.terminalizeInvocation(
          operationId,
          "failed",
          "runtime-prompt-failed",
          operationWork,
        );
        if (!operations.shuttingDown) await operations.runTerminal.notifyAgentTerminal(`terminal:${invocationId}`, "failed");
        operations.lifecycle.cancelPreflight(operationId);
        operations.runWork.settleOperationWork(operationId);
        attempt.finalizeAdmission();
        throw attempt.queueDispositionFailure instanceof Error
          ? attempt.queueDispositionFailure
          : new GatewayError("internal", "The agent runtime failed after prompt admission");
      }
    }
    if ((!queuesIntoActiveRun || !admitted) && operations.runQueue.pendingQueueAdmission?.id === operationId) {
      operations.runQueue.pendingQueueAdmission = undefined;
    }
    const commandTurnStarting = isExactExtensionCommand && handledWithoutAgent && runIdleAtAdmission
      && operations.runtime.session.isStreaming && !operations.runtime.session.state.isStreaming;
    operations.lifecycle.resolvePreflight(operationId, admitted && !queuesIntoActiveRun && (!handledWithoutAgent || commandTurnStarting));
    attempt.admissionAccepted = admitted;
    if (!admitted) {
      await attempt.run.catch(() => {});
      const stopped = operations.runAbort.abortedOperations.has(operationId);
      const terminalLifecycle = stopped ? "interrupted" : "failed";
      const errorCode = stopped ? "user-abort" : "preflight-rejected";
      operations.runTerminal.completionObserved(`terminal:${invocationId}`);
      await operations.runInvocations.persistInvocationReceipt(makeInvocationReceipt({
        version: 1,
        receiptId: `terminal:${invocationId}`,
        receiptKind: "terminal",
        invocationId,
        operationId,
        sessionId: operations.id,
        source: invocationSource,
        ...(invocationName ? { name: invocationName } : {}),
        lifecycle: terminalLifecycle,
        errorCode,
        origin: invocation.origin,
        sequence: operations.revision + 1,
        createdAt: new Date().toISOString(),
      }), operationWork);
      await operations.ownedTurns.notifyOwnedTerminal({
        lifecycle: terminalLifecycle,
        operationId,
        invocationId,
        errorCode,
      });
      operations.runInvocations.invocations.delete(invocationId);
      if (operations.activeOperationId === operationId) operations.activeOperationId = undefined;
      if (operations.activeOperationId === undefined) operations.homeRequestPolicy?.settle(operationId);
      if (operations.operation?.id === operationId) operations.operation = undefined;
      if (operations.pendingPrompt?.id === operationId) {
        operations.pendingPrompt = undefined;
        operations.pendingPromptMessage = undefined;
      }
      if (operations.pendingExtensionCommand?.id === operationId) operations.pendingExtensionCommand = undefined;
      await operations.clearMarkerOwnership(operationId);
      operations.runWork.settleOperationWork(operationId);
      operations.runAbort.abortedOperations.delete(operationId);
      if (operations.activeOperationId === undefined && !operations.hasActiveAgentRun && !operations.manualCompaction.queuedManualCompactionInFlight) operations.phase = "idle";
      operations.hooks.settled(operations.id);
      operations.revision += 1;
      operations.publishSnapshot();
      attempt.finalizeAdmission();
      if (!isExactExtensionCommand && !operations.shuttingDown) await operations.runTerminal.notifyAgentTerminal(`terminal:${invocationId}`, stopped ? "stopped" : "failed");
      if (preflightFailure) throw preflightFailure;
      throw new GatewayError(stopped ? "cancelled" : "invalid_request", stopped
        ? "Prompt stopped before agent admission"
        : "The agent runtime rejected the prompt before admission");
    }

    try {
      await operations.runInvocations.persistInvocationReceipt(makeInvocationReceipt({
        version: 1,
        receiptId: `accepted:${invocationId}`,
        receiptKind: "transition",
        invocationId,
        operationId,
        sessionId: operations.id,
        source: invocationSource,
        lifecycle: "accepted",
        sequence: operations.revision + 1,
        createdAt: new Date().toISOString(),
      }), operationWork);
    } catch (error) {
      operations.emit("session.diagnostic", safeJson({
        code: "invocation-acceptance-receipt-failed",
        operationId,
        message: error instanceof Error ? error.message : String(error),
      }));
    }
    invocation.lifecycle = queuesIntoActiveRun ? "queued" : "accepted";
    invocation.updatedAt = new Date().toISOString();
    operations.runInvocations.invocations.set(invocationId, invocation);
    attempt.finalizeAdmission();
    if (isExactExtensionCommand) operationWork.transition("extension-command-prompt-ui");
    else if (queuesIntoActiveRun) operationWork.transition("queued-mutation");
    else if (handledWithoutAgent) {
      await attempt.settleWithoutAgent();
    } else if (!attempt.runSettled) {
      operationWork.transition("foreground-agent-operation");
      const markerWrite = operations.enqueueMarkerOwnership(operationId);
      count("session.prompt.marker-persist");
      void markerWrite.catch(() => {});
    }
    operations.revision += 1;
    operations.publishSnapshot();
    if (!isExactExtensionCommand) {
      ownership?.onAdmitted?.(invocationId);
      onAdmitted?.({ operationId });
    }

    if (isExactExtensionCommand) {
      if (!attempt.commandSettled) {
        try { await attempt.run; } finally { await attempt.finishCommand(); }
      } else {
        await attempt.finishCommand();
      }
    } else if (attempt.runSettled) {
      const terminalLifecycle = await attempt.run.then(
        () => "completed" as const,
        () => "failed" as const,
      );
      await attempt.settleWithoutAgent(terminalLifecycle);
    }
    return { operationId };
    };
    return laneOwned ? run() : operations.lane.run(run);
  });
}

