import { randomUUID } from "node:crypto";
import type { ChatSemanticMetadata, QueuedMessageState, SessionOperationState } from "../../protocol/types.js";
import type { InvocationProjection } from "./invocation-receipts.js";
import type { AgentSession } from "../pi/coding-agent.js";
import type { RequestPolicy } from "../host/request-policy.js";
import type { RunWorkOwner } from "./run-work-owner.js";
import type { RunAbortOwner } from "./run-abort-owner.js";
import type { HeldPrompt, PendingQueueAdmission, QueueBehavior, RuntimeQueuedMessage, PromptQueueDisplay, QueueAdmissionDisposition } from "./queue-input.js";
import type { ImageContent } from "../pi/ai.js";
import { GatewayError } from "../../errors.js";
import { validateQueue } from "./queue-commands.js";

interface RunQueueContext {
  session(): AgentSession;
  runWork(): RunWorkOwner;
  runAbort(): RunAbortOwner;
  homeRequestPolicy(): Pick<RequestPolicy, "transferOperation"> | undefined;
  hasActiveAgentRun(): boolean;
  activeOperationId(): string | undefined;
  setActiveOperationId(id: string): void;
  setOperation(operation: SessionOperationState): void;
  ensureAgentProjection(): void;
  invocationForOperation(id: string): InvocationProjection | undefined;
  terminalizeTransferredOperation(id: string | undefined): void;
  retireOperationObservation(id: string | undefined): void;
  enqueueMarkerOwnership(id: string): Promise<void>;
  clearMarkerOwnership(id: string): Promise<void>;
  internalWakeSemantic(id: string): ChatSemanticMetadata | undefined;
  held(): readonly HeldPrompt[];
}

/** Per-runtime accepted SDK queue identities and shared presentation clock.
 * Pi owns its message text; reconciliation retains exact receipt/work owners
 * across queue_update and message_start/agent_start callback gaps. */
export class RunQueueOwner {
  queueRevision = 0;
  nextQueueOrdinal = 0;
  queuedMessages: RuntimeQueuedMessage[] = [];
  pendingQueueAdmission: PendingQueueAdmission | undefined;
  readonly sdkQueuedSteeringIDs = new Set<string>();
  suppressQueueEvents = false;
  /** Follow-up queue owners removed by Pi immediately before their agent_start. */
  readonly dequeuedFollowUpOwners: string[] = [];
  /** Steering queue owners removed immediately before Pi emits message_start.
   * Steering remains inside the current agent run, so it needs a separate
   * callback-turn latch rather than follow-up's agent_start transfer. */
  readonly dequeuedSteeringOwners: string[] = [];
  /** Steering owners whose exact user message has crossed message_start and
   * still needs its canonical binding/terminal receipt persisted. */
  readonly consumedSteeringOperationIDs = new Set<string>();

  constructor(private readonly context: RunQueueContext) {}

  validateAdmission(display: PromptQueueDisplay, redelivery?: RuntimeQueuedMessage): void {
    this.reconcileQueuedMessages();
    if (this.pendingQueueAdmission) {
      throw new GatewayError(
        "busy",
        "The prior queued prompt is still publishing its authoritative identity",
        true,
      );
    }
    validateQueue([...this.queuedMessages.filter((item) => item.id !== redelivery?.id), {
      text: display.text,
      attachmentCount: display.attachmentCount,
      ...(display.resourceInvocations === undefined
        ? {}
        : { resourceInvocations: display.resourceInvocations }),
    }]);
  }

  recordPendingAdmission(
    operationId: string, behavior: QueueBehavior, display: PromptQueueDisplay,
    images: ImageContent[], redelivery: RuntimeQueuedMessage | undefined,
    resolveDisposition: (disposition: QueueAdmissionDisposition) => void,
  ): void {
  this.pendingQueueAdmission = {
    // The returned operation identity is also the stable projected queue
    // identity, giving clients an exact settlement receipt.
    id: operationId,
    behavior,
    text: display.text,
    attachmentCount: display.attachmentCount,
    ...(display.resourceInvocations === undefined
    ? {}
    : { resourceInvocations: display.resourceInvocations }),
    ...(display.photoCount === undefined
      ? {}
      : { photoCount: display.photoCount }),
    ...(display.fileAttachmentCount === undefined
      ? {}
      : { fileAttachmentCount: display.fileAttachmentCount }),
    ...(display.attachments === undefined
      ? {}
      : { attachments: display.attachments }),
    inputSource: display.inputSource ?? "interactive",
    ...(display.commandId === undefined ? {} : { commandId: display.commandId }),
    attachmentEnvelope: display.attachmentEnvelope,
    images,
    ...(redelivery === undefined ? {} : { redelivery: true }),
    resolveDisposition,
  };
  }

  reconcileQueuedMessages(): void {
    const session = this.context.session();
    const actual: Record<QueueBehavior, readonly string[]> = {
      steer: session.getSteeringMessages(),
      followUp: session.getFollowUpMessages(),
    };
    const previous = this.queuedMessages;
    const reconciled: RuntimeQueuedMessage[] = [];

    for (const behavior of ["steer", "followUp"] as const) {
      const old = previous.filter((item) => item.behavior === behavior);
      const nextTexts = actual[behavior];
      let overlap = Math.min(old.length, nextTexts.length);
      while (overlap > 0) {
        const oldStart = old.length - overlap;
        let matches = true;
        for (let index = 0; index < overlap; index += 1) {
          if (old[oldStart + index]?.runtimeText !== nextTexts[index]) {
            matches = false;
            break;
          }
        }
        if (matches) break;
        overlap -= 1;
      }

      reconciled.push(...old.slice(old.length - overlap));
      for (const runtimeText of nextTexts.slice(overlap)) {
        const admission = this.pendingQueueAdmission?.behavior === behavior
          ? this.pendingQueueAdmission
          : undefined;
        if (admission) {
          this.pendingQueueAdmission = undefined;
          admission.resolveDisposition("queued");
        }
        reconciled.push({
          id: admission?.id ?? randomUUID(),
          behavior,
          text: admission?.text ?? runtimeText,
          attachmentCount: admission?.attachmentCount ?? 0,
          ...(admission?.resourceInvocations === undefined ? {} : { resourceInvocations: admission.resourceInvocations }),
          ...(admission?.photoCount === undefined ? {} : { photoCount: admission.photoCount }),
          ...(admission?.fileAttachmentCount === undefined ? {} : { fileAttachmentCount: admission.fileAttachmentCount }),
          ...(admission?.attachments === undefined ? {} : { attachments: admission.attachments }),
          runtimeText,
          attachmentEnvelope: admission?.attachmentEnvelope ?? "",
          images: admission?.images ?? [],
          inputSource: admission?.inputSource ?? "interactive",
          ...(admission?.commandId === undefined ? {} : { commandId: admission.commandId }),
          ordinal: this.nextQueueOrdinal++,
        });
      }
    }

    const sdkPresentIDs = new Set(reconciled.map((item) => item.id));
    const sdkPresentSteeringIDs = new Set(reconciled.filter((item) => item.behavior === "steer").map((item) => item.id));
    const reconciledIDs = new Set(sdkPresentIDs);
    for (const item of previous) {
      if (this.context.runAbort().stopSteeringRecoveryIDs.has(item.id) && !reconciledIDs.has(item.id)) {
        if (this.sdkQueuedSteeringIDs.has(item.id) && item.behavior === "steer"
          && !this.dequeuedSteeringOwners.includes(item.id)) {
          this.dequeuedSteeringOwners.push(item.id);
        }
        reconciled.push(item);
        reconciledIDs.add(item.id);
      }
    }
    reconciled.sort((left, right) => left.behavior === right.behavior
      ? left.ordinal - right.ordinal
      : left.behavior === "steer" ? -1 : 1);
    for (const item of reconciled) {
      if (!this.context.runWork().has(item.id)) this.context.runWork().beginDerivedOperationWork(item.id, "queued-mutation");
    }
    const removed = previous.filter((item) => !reconciled.some((candidate) => candidate.id === item.id));
    if (removed.length > 0 && this.context.hasActiveAgentRun()) {
      this.context.ensureAgentProjection();
      if (this.context.activeOperationId()) this.context.runWork().beginDerivedOperationWork(this.context.activeOperationId()!, "foreground-agent-operation");
    }
    for (const item of removed) {
      if (item.behavior === "steer" && this.context.invocationForOperation(item.id)) {
        // Agent-core's queue_update precedes message_start for steering. Do
        // not settle this operation or let the enclosing activeOperationId
        // impersonate it during that exact callback window.
        if (!this.dequeuedSteeringOwners.includes(item.id)) {
          this.dequeuedSteeringOwners.push(item.id);
        }
        const work = this.context.runWork().get(item.id)
          ?? this.context.runWork().beginDerivedOperationWork(item.id, "queued-mutation");
        work.transition("foreground-agent-operation");
        continue;
      }
      if (item.behavior === "followUp" && this.context.runWork().has(item.id)) {
        if (!this.context.hasActiveAgentRun()) {
          // Pi can remove a follow-up immediately before emitting its next
          // agent_start. Retain the exact accepted owner across that event gap;
          // the start consumes this FIFO latch instead of deriving new work.
          if (!this.dequeuedFollowUpOwners.includes(item.id)) this.dequeuedFollowUpOwners.push(item.id);
          this.context.runWork().get(item.id)?.transition("foreground-agent-operation");
          continue;
        }
        if (this.context.activeOperationId() !== item.id) {
          // Pi can emit agent_start before queue_update. The exact removed
          // follow-up then retrospectively transfers its pre-cutoff token into
          // the already-started foreground run; retire only the synthetic owner.
          const syntheticOwner = this.context.activeOperationId();
          this.context.terminalizeTransferredOperation(syntheticOwner);
          if (syntheticOwner !== item.id) this.context.retireOperationObservation(syntheticOwner);
          this.context.setActiveOperationId(item.id);
          // The follow-up is part of the same activation: its boundary entry and
          // its frozen memory view must not change, only the operation identity
          // Tron now reports.
          this.context.homeRequestPolicy()?.transferOperation(syntheticOwner, item.id);
          this.context.setOperation({
            id: item.id,
            kind: "prompt",
            startedAt: new Date().toISOString(),
            ...(this.context.invocationForOperation(item.id)?.invocationId
              ? { invocationId: this.context.invocationForOperation(item.id)!.invocationId }
              : {}),
          });
          // Queue removal can follow agent_start. Durably transfer the marker
          // before retiring the synthetic event-time owner, so completion stamps
          // cannot race a missing exact marker.
          void this.context.enqueueMarkerOwnership(item.id).then(async () => {
            if (syntheticOwner) await this.context.clearMarkerOwnership(syntheticOwner);
            this.context.runWork().settleOperationWork(syntheticOwner);
          }).catch(() => this.context.session().abort());
        }
        this.context.runWork().get(item.id)?.transition("foreground-agent-operation");
        const pendingIndex = this.dequeuedFollowUpOwners.indexOf(item.id);
        if (pendingIndex >= 0) this.dequeuedFollowUpOwners.splice(pendingIndex, 1);
      } else {
        this.context.runWork().settleOperationWork(item.id);
      }
    }
    const changed = previous.length !== reconciled.length || previous.some((item, index) => {
      const next = reconciled[index];
      return next === undefined
        || item.id !== next.id
        || item.behavior !== next.behavior
        || item.text !== next.text
        || item.runtimeText !== next.runtimeText
        || JSON.stringify(item.resourceInvocations) !== JSON.stringify(next.resourceInvocations)
        || item.attachmentCount !== next.attachmentCount
        || item.photoCount !== next.photoCount
        || item.fileAttachmentCount !== next.fileAttachmentCount
        || JSON.stringify(item.attachments) !== JSON.stringify(next.attachments);
    });
    this.queuedMessages = reconciled;
    this.sdkQueuedSteeringIDs.clear();
    for (const id of sdkPresentSteeringIDs) this.sdkQueuedSteeringIDs.add(id);
    if (changed) this.queueRevision += 1;
    const redeliveryAdmission = this.pendingQueueAdmission;
    if (redeliveryAdmission?.redelivery && reconciled.some((item) => item.id === redeliveryAdmission.id)) {
      this.pendingQueueAdmission = undefined;
      redeliveryAdmission.resolveDisposition("queued");
    }
  }

  projectedQueue(): QueuedMessageState[] {
    this.reconcileQueuedMessages();
    // Held prompts follow Pi's queue: they are delivered after it. An entry
    // that Pi has just enqueued is projected once, by Pi's queue.
    const piQueued = new Set(this.queuedMessages.map((item) => item.id));
    return [
      ...this.queuedMessages,
      ...this.context.held().filter((item) => !piQueued.has(item.id)),
    ].map(({
      id, behavior, text, attachmentCount, photoCount, fileAttachmentCount, attachments, resourceInvocations,
    }) => {
      const semantic = this.context.internalWakeSemantic(id);
      return {
        id,
        ...(semantic ? { semantic } : {}),
        behavior,
        text,
        attachmentCount,
        ...(photoCount === undefined ? {} : { photoCount }),
        ...(fileAttachmentCount === undefined ? {} : { fileAttachmentCount }),
        ...(attachments === undefined ? {} : { attachments }),
        ...(resourceInvocations === undefined ? {} : { resourceInvocations }),
      };
    });
  }
}
