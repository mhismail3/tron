import type { ImageContent } from "../pi/ai.js";
import type { SessionPhase } from "../../protocol/types.js";
import { GatewayError, asUncertainOutcome } from "../../errors.js";
import { count, wait } from "../../transport/request-span.js";
import { withInvocationContext } from "../../extensions/owner-attribution.js";
import { safeJson } from "../projection/projection.js";
import type { InputTrigger } from "../host/input-admission.js";
import type { GatewayWorkHandle } from "./gateway-work-registry.js";
import type { QueueBehavior, PromptQueueDisplay, HeldPrompt, RuntimeQueuedMessage, QueueAdmissionDisposition } from "./queue-input.js";
import { makeInvocationReceipt } from "./invocation-receipts.js";
import { deliverPromptInput } from "./context-delivery-receipts.js";
import { preparePromptInput, preparePromptIntent, promptStartReceipt, type PromptAdmissionContext, type PromptOwnership } from "./prompt-input.js";

export async function admitPrompt<TaskFence extends { taskId: string; operationId: string }, Completion>(
context: PromptAdmissionContext<TaskFence, Completion>,
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
    context.assertUsable();
    context.assertHomePromptAdmission();
    if (!ownership && context.runAbort.stopRecoveryQueueClosed && !held && !redelivery) {
      const heldAdmission = context.heldQueue.holdPrompt(text, images, behavior, queueDisplay, true);
      onAdmitted?.(heldAdmission);
      return heldAdmission;
    }
    try {
      if (context.attentionBarrier) await context.attentionBarrier;
    } catch {
      throw context.attentionPendingError();
    }
    if (context.completionOwnershipQueue.length > 0 || context.pendingAssistantCompletion) {
      throw context.attentionPendingError();
    }
    if (context.lifecycle.isDraining) throw new GatewayError("busy", "Session is draining for an administrative restart", true);
    const session = context.runtime.session;
    if (ownership?.kind === "homeWake") await context.assertHomeWakeAdmissible(session);
    if (context.taskWorker) {
      const trust = await context.dependencies.trust.requireResolved(context.cwd);
      if (!trust.trusted) throw new GatewayError("trust_required", "Home task target is no longer trusted");
      if (ownership?.operationId === context.taskWorker.identity.operationId) {
        await context.persistTaskMarker(operationId);
      } else if ((ownership?.kind === "subagentWake" || context.sharedTaskSteering(ownership)) && context.taskWait && context.taskWait.wakeOperationId === undefined
        && context.taskWorker.acceptsSteering && context.activeOperationId === undefined && context.operation === undefined && !session.isStreaming) {
        // The provider's wake, or the maintainer's or Home's message (#929), continues the task this
        // operation holds open between turns; its marker stays the first one.
      } else {
        const fence = ownership?.taskFence;
        // The maintainer and Home share one ordered steering lane per worker (#929): a maintainer
        // message to a running task joins that lane whatever behavior the composer chose.
        if (!ownership && context.taskWorker.acceptsSteering) behavior = "steer";
        if (behavior !== "steer" || context.liveTaskOperationId() !== context.taskWorker.identity.operationId
          || !session.isStreaming || !context.taskWorker.acceptsSteering
          || (fence && (fence.taskId !== context.taskWorker.identity.taskId || fence.operationId !== context.taskWorker.identity.operationId))) {
          throw new GatewayError("conflict", "Stale or settled task operation cannot accept steering");
        }
      }
    }
    while (context.isAgentAdmissionSettling) {
      await context.waitForStateChange();
      context.assertUsable();
    }
    const prepared = preparePromptInput(context, session, text, images, queueDisplay, ownership);
    text = prepared.text;
    const { composedResources, isExactExtensionCommand } = prepared;
    if (!session.isStreaming) {
      await session.settingsManager.flush();
      await context.applyLiveRunSettings(session);
      context.compactionPolicies.get(session)?.applyBudgets();
      context.contextPolicies.get(session)?.apply();
    }
    let queuesIntoActiveRun = session.isStreaming && behavior !== undefined && !isExactExtensionCommand;
    if (ownership && context.ownedTerminalObservers.has(operationId)) {
      throw new GatewayError("conflict", "Automation operation is already registered", true);
    }
    const intent = preparePromptIntent(context, session, text, images, behavior, queueDisplay, ownership, operationId, redelivery, prepared);
    const { invocationId, invocationSource, invocationName, invocation, queueAdmissionDisplay } = intent;
    if (queuesIntoActiveRun) context.runQueue.validateAdmission(queueAdmissionDisplay, redelivery);

    if (ownership && ownership.kind !== "subagentWake" && ownership.kind !== "homeWake") context.ownedTerminalObservers.set(operationId, ownership.onTerminal);
    let operationWork!: GatewayWorkHandle;
    let preflightStarted = false;
    // Whether Pi had no run (starting or live) when this input was admitted; a
    // command can then own only a start that its own handler began.
    const runIdleAtAdmission = !context.runtime.session.isStreaming;
    let acceptedResolve!: (accepted: boolean) => void;
    const accepted = new Promise<boolean>((resolve) => { acceptedResolve = resolve; });
    let sdkRun: Promise<void>;
    let preflightFailure: GatewayError | undefined;
    let handledWithoutAgent = false;
    let queueDisposition: Promise<QueueAdmissionDisposition> | undefined;
    let resolveQueueDisposition: ((disposition: QueueAdmissionDisposition) => void) | undefined;
    let startPersisted = false;
    /** The phase this admission replaced when it marked the session running. */
    let phaseBeforeAdmission: SessionPhase | undefined;
    try {
      // Retained archive state is cleared here, inside the same lane critical
      // section that admits this run and after every synchronous rejection
      // above. A prompt can therefore never start while the session is hidden
      // from the dashboard, and a store failure rejects the prompt retryably.
      await context.dependencies.beforeRunAdmission(context.id);
      // Attention, settings and archive I/O can yield to canonical writes or
      // a seal. Recheck the physical target before invocation/SDK effects.
      context.assertHomePromptAdmission();
      context.invocations.set(invocationId, invocation);
      while (context.invocations.size > 128) context.invocations.delete(context.invocations.keys().next().value!);
      operationWork = context.runWork.beginOperationWork(operationId);
      if (redelivery) context.lifecycle.cancelPreflight(operationId);
      // Exact preflight ownership begins synchronously before marker I/O, so a
      // drain that starts while the marker is pending snapshots this owner.
      context.lifecycle.beginPreflight(operationId);
      preflightStarted = true;

      // Canonical invocation ownership must precede every extension side
      // effect. This custom entry is intentionally hidden from model context
      // and ordinary transcript projection, but survives runtime restart.
      const startReceipt = promptStartReceipt(context, operationId, intent);
      // Durable staging precedes the Pi call so an extension handler can
      // never emit output before Gateway has recorded its invocation owner.
      if (!redelivery) await context.persistInvocationReceipt(startReceipt, operationWork);
      startPersisted = true;
      context.assertHomePromptAdmission();

      // Receipt persistence and extension hooks may outlive the run that was
      // active at RPC entry. Re-evaluate at the last Gateway-owned boundary,
      // then let queue_update/message_start provide the exact disposition if
      // Pi crosses from streaming to idle inside its asynchronous input hook.
      queuesIntoActiveRun = session.isStreaming && behavior !== undefined && !isExactExtensionCommand;
      if (session.isStreaming && !behavior && !isExactExtensionCommand) {
        throw new GatewayError("busy", "Session is running; choose steer or follow-up");
      }
      if (queuesIntoActiveRun) {
        context.runQueue.validateAdmission(queueAdmissionDisplay, redelivery);
        let dispositionResolved = false;
        queueDisposition = new Promise<QueueAdmissionDisposition>((resolve) => {
          resolveQueueDisposition = (disposition) => {
            if (dispositionResolved) return;
            dispositionResolved = true;
            resolve(disposition);
          };
        });
        context.runQueue.recordPendingAdmission(operationId, behavior!, queueAdmissionDisplay, images, redelivery,
          (disposition) => resolveQueueDisposition?.(disposition));
      }

      let homeWakeTrigger: InputTrigger | undefined;
      if (isExactExtensionCommand) {
        context.pendingExtensionCommand = { id: operationId, kind: "command", startedAt: new Date().toISOString(), invocationId, lifecycle: "staged" };
        // Exact commands run before Pi's preflight callback and can wait on UI
        // indefinitely. Persist the provisional admission before invoking Pi.
        await context.enqueueMarkerOwnership(operationId);
        context.revision += 1;
        context.publishSnapshot();
      } else if (!queuesIntoActiveRun) {
        context.activeOperationId = operationId;
        if ((ownership?.kind === "subagentWake" || context.sharedTaskSteering(ownership)) && context.taskWait && context.taskWait.wakeOperationId === undefined) {
          context.taskWait.wakeOperationId = operationId;
        }
        // The canonical leaf immediately before Pi sees the input is the exact
        // activation start: the input's own entry is appended inside
        // `session.prompt` below, and steering later inserts entries after it,
        // never before it.
        // Gateway owns preflight even before Pi creates an Agent controller
        // (including auth and compaction preparation). It is not idle work.
        phaseBeforeAdmission = context.phase;
        context.phase = "running";
        context.operation = { id: operationId, kind: "prompt", startedAt: new Date().toISOString(), invocationId, lifecycle: "staged" };
        context.pendingPromptMessage = undefined;
        context.pendingPrompt = ownership?.kind === "homeWake" ? undefined : context.promptDisplay(operationId, text, images, queueDisplay);
        // A waiting message becomes this pending prompt in the same
        // publication, so it is never shown twice or not at all.
        if (held) context.heldQueue.removeHeldPrompt(held.id);
        context.revision += 1;
        // Publish before entering Pi preflight. Automatic compaction can begin
        // inside that call before the RPC receives its admission result.
        context.publishSnapshot();
        context.homeRequestPolicy?.admit(operationId, session.sessionManager.getLeafId() ?? null, session.systemPrompt, ownership?.kind === "homeWake" ? "wake" : "user");
        context.operationWasHomeWake = ownership?.kind === "homeWake";
        if (context.homeRequestPolicy) {
          // Inbox admission runs on this session's lane: every later prompt waits
          // for it. A slow one is the first thing to name when Home stops answering (#906).
          const inboxAdmissionStarted = performance.now();
          try {
          homeWakeTrigger = await context.dependencies.modules.policy("inputAdmission")?.().admit(context.id, operationId, ownership?.kind === "homeWake" ? "wake" : "user", message => deliverPromptInput(context, session, message)
          , () => context.dependencies.modules.policy("inputAdmission")!().envelope({
            session, policy: context.homeRequestPolicy!, text, images, signal: ownership?.signal,
            sessionFile: () => context.sessionFile, entries: () => context.canonicalEntryCount,
          }));
          } finally {
            context.dependencies.modules.policy("inputAdmission")?.().finished(inboxAdmissionStarted, ownership?.kind === "homeWake" ? "wake" : "user");
          }
        }
      }

      if (ownership?.kind === "homeWake") ownership.onDelivered(homeWakeTrigger !== undefined);
      ownership?.signal?.throwIfAborted();
      sdkRun = ownership?.kind === "homeWake"
        ? context.startHomeWake(session, operationId, homeWakeTrigger, acceptedResolve)
        : withInvocationContext({ invocationId, operationId }, () => session.prompt(text, {
        images,
        ...(queuesIntoActiveRun ? { streamingBehavior: behavior! } : {}),
        source: ownership?.kind === "subagentWake" ? "extension" : queueDisplay?.inputSource ?? "rpc",
        ...(ownership?.kind === "subagentWake" ? { expandPromptTemplates: ownership.expandPromptTemplates }
          : composedResources !== undefined ? { expandPromptTemplates: false } : {}),
        preflightResult: (disposition) => {
          // Pi calls back only after it has handled, queued, or started the
          // prompt. Rejections do not call this hook; the SDK promise's
          // rejection handler below resolves admission as false.
          handledWithoutAgent = disposition === "handled";
          // Pi has no active Agent signal during pre-prompt compaction. Stop
          // must also revoke this exact pending prompt at SDK admission; an
          // aborted summary alone does not prevent Agent.prompt() starting.
          if (ownership?.signal?.aborted || context.runAbort.abortedOperations.has(operationId)
            || (context.taskWorker && operationId !== context.taskWorker.identity.operationId && context.taskWait?.wakeOperationId !== operationId
              && (!context.taskWorker.acceptsSteering || context.liveTaskOperationId() !== context.taskWorker.identity.operationId))) {
            preflightFailure = new GatewayError("cancelled", "Prompt stopped before agent admission");
          } else if (!isExactExtensionCommand && !queuesIntoActiveRun && context.activeOperationId !== operationId) {
            preflightFailure = new GatewayError("busy", "An extension started a turn during prompt preparation; retry after it settles", true);
          }
          if (preflightFailure) {
            acceptedResolve(false);
            throw preflightFailure;
          }
          // agent_start can fire synchronously before this Gateway promise
          // resumes. Record the SDK's disposition now, not one turn later.
          invocation.lifecycle = "accepted";
          context.invocations.set(invocationId, invocation);
          context.noteAcceptedSteering(operationId);
          acceptedResolve(true);
        },
      }));
      // Pi awaits an extension command handler before invoking its preflight
      // callback. The Gateway has already durably admitted the exact command
      // and started its SDK promise, so release the RPC response while this
      // session lane continues to serialize the handler and its side effects.
      if (isExactExtensionCommand) {
        ownership?.onAdmitted?.(invocationId);
        onAdmitted?.({ operationId });
      }
    } catch (error) {
      if (preflightStarted) context.lifecycle.cancelPreflight(operationId);
      context.runQueue.pendingQueueAdmission = undefined;
      if (context.activeOperationId === operationId) context.activeOperationId = undefined;
      if (context.activeOperationId === undefined) context.homeRequestPolicy?.settle(operationId);
      if (context.operation?.id === operationId) context.operation = undefined;
      if (context.pendingPrompt?.id === operationId) {
        context.pendingPrompt = undefined;
        context.pendingPromptMessage = undefined;
      }
      if (context.pendingExtensionCommand?.id === operationId) context.pendingExtensionCommand = undefined;
      // An admission that failed before any run started gives back the phase it
      // took (#881): a "running" session with nothing running admits nothing.
      if (phaseBeforeAdmission !== undefined && context.phase === "running" && !context.hasActiveAgentRun
        && context.activeOperationId === undefined && context.operation === undefined) {
        context.phase = phaseBeforeAdmission;
        context.revision += 1;
        context.publishSnapshot();
      }
      if (startPersisted) {
        await context.persistInvocationReceipt(makeInvocationReceipt({
          version: 1,
          receiptId: `terminal:${invocationId}`,
          receiptKind: "terminal",
          invocationId,
          operationId,
          sessionId: context.id,
          source: invocationSource,
          ...(invocationName ? { name: invocationName } : {}),
          lifecycle: "outcomeUnknown",
          origin: invocation.origin,
          sequence: context.revision + 1,
          createdAt: new Date().toISOString(),
        }), operationWork);
        await context.notifyOwnedTerminal({
          lifecycle: "outcomeUnknown",
          operationId,
          invocationId,
        });
      }
      context.invocations.delete(invocationId);
      context.runWork.settleOperationWork(operationId);
      if (!startPersisted) context.ownedTerminalObservers.delete(operationId);
      // Once the canonical start receipt is durable the prompt may already
      // have reached extension hooks or the provider. Report its failure as an
      // unknown outcome so the idempotency receipt cannot be replayed, matching
      // the outcome-unknown terminal receipt recorded above.
      // A Home refusal names its own cause, so the client reads it first. It stays an
      // unknown outcome: the start receipt is durable, so the prompt must not replay.
      throw startPersisted
        ? asUncertainOutcome(context.dependencies.modules.policy("requestPolicy")?.().isRefusal(error) ? new GatewayError("conflict", error.message) : error,
          "Prompt admission failed after its canonical start receipt was accepted; refresh session state instead of replaying")
        : error;
    }
    const attempt = context.createAttempt(sdkRun, {
      operationId, invocationId, invocationSource, invocationName, invocation,
      isExactExtensionCommand, acceptedResolve, resolveQueueDisposition,
    }, () => queuesIntoActiveRun);

    // Successful Pi dispositions are reported by the callback; rejected
    // prompts do not call it and are resolved by the SDK promise rejection
    // handler. A local timeout could reject while an input handler later
    // accepts canonical work, so admission remains callback/rejection-owned.
    const admitted = await accepted;
    if (queuesIntoActiveRun && admitted) {
      context.runQueue.reconcileQueuedMessages();
      const disposition = await queueDisposition!;
      queuesIntoActiveRun = disposition === "queued";
      if (disposition === "queued" && held) context.heldQueue.removeHeldPrompt(held.id);
      if (disposition === "queued" && preflightStarted) {
        // Queued input has an accepted queue owner, not an active preflight.
        // Releasing this exact owner lets a later Stop-redelivery reuse the
        // same operation identity through ordinary admission.
        context.lifecycle.cancelPreflight(operationId);
        preflightStarted = false;
      }
      handledWithoutAgent = disposition === "handled";
      if (disposition === "failed") {
        context.lifecycle.resolvePreflight(operationId, true);
        attempt.admissionAccepted = true;
        context.completionObserved(`terminal:${invocationId}`);
        await context.terminalizeInvocation(
          operationId,
          "failed",
          "runtime-prompt-failed",
          operationWork,
        );
        if (!context.shuttingDown) await context.notifyAgentTerminal(`terminal:${invocationId}`, "failed");
        context.lifecycle.cancelPreflight(operationId);
        context.runWork.settleOperationWork(operationId);
        attempt.finalizeAdmission();
        throw attempt.queueDispositionFailure instanceof Error
          ? attempt.queueDispositionFailure
          : new GatewayError("internal", "The agent runtime failed after prompt admission");
      }
    }
    if ((!queuesIntoActiveRun || !admitted) && context.runQueue.pendingQueueAdmission?.id === operationId) {
      context.runQueue.pendingQueueAdmission = undefined;
    }
    // Pi >= 1.2 counts a run busy from the moment it prepares (through
    // before_agent_start), so a turn an extension command triggered can still
    // be starting, with no Agent run yet, when Pi reports the command handled.
    // That start is the command's own: admit it once. A start already
    // observed consumed its admission; a command admitted while a run was
    // live or settling owns no start.
    const commandTurnStarting = isExactExtensionCommand && handledWithoutAgent && runIdleAtAdmission
      && context.runtime.session.isStreaming && !context.runtime.session.state.isStreaming;
    context.lifecycle.resolvePreflight(operationId, admitted && !queuesIntoActiveRun && (!handledWithoutAgent || commandTurnStarting));
    attempt.admissionAccepted = admitted;
    if (!admitted) {
      // A preflight callback is a disposition, not SDK settlement. Join the
      // exact promise before retiring its marker or publishing idle.
      await attempt.run.catch(() => {});
      const stopped = context.runAbort.abortedOperations.has(operationId);
      const terminalLifecycle = stopped ? "interrupted" : "failed";
      const errorCode = stopped ? "user-abort" : "preflight-rejected";
      context.completionObserved(`terminal:${invocationId}`);
      await context.persistInvocationReceipt(makeInvocationReceipt({
        version: 1,
        receiptId: `terminal:${invocationId}`,
        receiptKind: "terminal",
        invocationId,
        operationId,
        sessionId: context.id,
        source: invocationSource,
        ...(invocationName ? { name: invocationName } : {}),
        lifecycle: terminalLifecycle,
        errorCode,
        origin: invocation.origin,
        sequence: context.revision + 1,
        createdAt: new Date().toISOString(),
      }), operationWork);
      await context.notifyOwnedTerminal({
        lifecycle: terminalLifecycle,
        operationId,
        invocationId,
        errorCode,
      });
      context.invocations.delete(invocationId);
      if (context.activeOperationId === operationId) context.activeOperationId = undefined;
      if (context.activeOperationId === undefined) context.homeRequestPolicy?.settle(operationId);
      if (context.operation?.id === operationId) context.operation = undefined;
      if (context.pendingPrompt?.id === operationId) {
        context.pendingPrompt = undefined;
        context.pendingPromptMessage = undefined;
      }
      if (context.pendingExtensionCommand?.id === operationId) context.pendingExtensionCommand = undefined;
      await context.clearMarkerOwnership(operationId);
      context.runWork.settleOperationWork(operationId);
      context.runAbort.abortedOperations.delete(operationId);
      if (context.activeOperationId === undefined && !context.hasActiveAgentRun && !context.queuedManualCompactionInFlight) context.phase = "idle";
      context.hooks.settled(context.id);
      context.revision += 1;
      context.publishSnapshot();
      attempt.finalizeAdmission();
      if (!isExactExtensionCommand && !context.shuttingDown) await context.notifyAgentTerminal(`terminal:${invocationId}`, stopped ? "stopped" : "failed");
      if (preflightFailure) throw preflightFailure;
      throw new GatewayError(stopped ? "cancelled" : "invalid_request", stopped
        ? "Prompt stopped before agent admission"
        : "The agent runtime rejected the prompt before admission");
    }

    try {
      await context.persistInvocationReceipt(makeInvocationReceipt({
        version: 1,
        receiptId: `accepted:${invocationId}`,
        receiptKind: "transition",
        invocationId,
        operationId,
        sessionId: context.id,
        source: invocationSource,
        lifecycle: "accepted",
        sequence: context.revision + 1,
        createdAt: new Date().toISOString(),
      }), operationWork);
    } catch (error) {
      // Admission has already been accepted by Pi. A receipt write failure is
      // a durability diagnostic, never evidence that execution was rejected.
      context.emit("session.diagnostic", safeJson({
        code: "invocation-acceptance-receipt-failed",
        operationId,
        message: error instanceof Error ? error.message : String(error),
      }));
    }
    // Admission and Stop retain the same invocation object across receipt
    // awaits; a late accepted transition cannot replace its recorded reason.
    invocation.lifecycle = queuesIntoActiveRun ? "queued" : "accepted";
    invocation.updatedAt = new Date().toISOString();
    context.invocations.set(invocationId, invocation);
    attempt.finalizeAdmission();
    if (isExactExtensionCommand) operationWork.transition("extension-command-prompt-ui");
    else if (queuesIntoActiveRun) operationWork.transition("queued-mutation");
    else if (handledWithoutAgent) {
      await attempt.settleWithoutAgent();
    } else if (!attempt.runSettled) {
      operationWork.transition("foreground-agent-operation");
      const markerWrite = context.enqueueMarkerOwnership(operationId);
      count("session.prompt.marker-persist");
      // Prompt admission is already authoritative in Pi. Keep the marker owner
      // tracked for drain and later settlement, but do not hold the response on
      // its fsync; observing the rejection also prevents a detached write from
      // becoming an unhandled rejection.
      void markerWrite.catch(() => {});
    }
    context.revision += 1;
    context.publishSnapshot();
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
      // Handles input action:"handled" and rejected accepted calls without
      // touching a newer operation. `finally` can mark runSettled one
      // microtask before `run` exposes its outcome, so join it explicitly.
      const terminalLifecycle = await attempt.run.then(
        () => "completed" as const,
        () => "failed" as const,
      );
      await attempt.settleWithoutAgent(terminalLifecycle);
    }
    return { operationId };
    };
    return laneOwned ? run() : context.lane.run(run);
  });
}

