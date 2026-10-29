import { admitPrompt } from "./prompt-admission.js";
import { parsePiLiteralCommand } from "../resources/resource-invocation.js";
import { validateQueue } from "./queue-commands.js";
import type { RunOperations } from "./run-operations.js";
import { randomUUID } from "node:crypto";
import type { ImageContent } from "../pi/ai.js";
import type { QueuedMessageState } from "../../protocol/types.js";
import { GatewayError, isUncertainOutcome } from "../../errors.js";
import { safeJson } from "../projection/projection.js";
import { MAXIMUM_PROMPT_ATTACHMENTS, type HeldPrompt, type QueueBehavior, type PromptQueueDisplay } from "./queue-input.js";


/** Owns accepted pre-admission prompts and the one deferred ordered flush. */
export class HeldPromptQueue {
  /** Messages sent while compaction owns admission, in delivery order. Pi
   * rejects input during manual compaction and its own front end keeps the
   * same "after compaction" queue; here the Gateway is that front end, so every
   * client sees, edits and removes these through the ordinary queue contract. */
  private heldPrompts: HeldPrompt[] = [];
  private heldPromptFlush: Promise<void> | undefined;

  constructor(private readonly operations: RunOperations<unknown>) {}
  get entries(): readonly HeldPrompt[] { return this.heldPrompts; }
  reset(): void { this.heldPrompts = []; }

  holdsPromptsForCompaction(text: string, queueDisplay: PromptQueueDisplay | undefined): boolean {
    // Once any message waits, later ones wait behind it to preserve order even
    // while the flush is admitting the head after compaction ended.
    if (!(this.operations.phase === "compacting") && this.heldPrompts.length === 0) return false;
    this.operations.assertUsable();
    // Extension commands execute rather than wait as a message.
    if (queueDisplay?.resourceInvocations?.[0]?.source === "extension") return false;
    // Skills and prompts make a message whatever its visible text begins with.
    if (queueDisplay?.resourceInvocations !== undefined) return true;
    return this.isMessage(text);
  }

  holdPrompt(
    text: string,
    images: ImageContent[],
    behavior: QueueBehavior | undefined,
    queueDisplay: PromptQueueDisplay | undefined,
    stopRecovery = false,
  ): { operationId: string } {
    this.operations.assertUsable();
    if (this.operations.lifecycle.isDraining) throw new GatewayError("busy", "Session is draining for an administrative restart", true);
    const display = queueDisplay ?? {
      text,
      attachmentEnvelope: "",
      attachmentCount: images.length,
      ...(images.length > 0 ? { photoCount: images.length, fileAttachmentCount: 0 } : {}),
    };
    if (display.attachments !== undefined
      && (display.attachments.length > MAXIMUM_PROMPT_ATTACHMENTS
        || display.attachments.length !== display.attachmentCount)) {
      throw new GatewayError("invalid_request", "Prompt attachment descriptors do not match the bounded attachment count");
    }
    this.operations.runQueue.reconcileQueuedMessages();
    const entry: HeldPrompt = {
      id: randomUUID(),
      // Pi's front end queues compaction-time input as steering by default.
      behavior: behavior ?? "steer",
      text: display.text,
      attachmentCount: display.attachmentCount,
      ...(display.photoCount === undefined ? {} : { photoCount: display.photoCount }),
      ...(display.fileAttachmentCount === undefined ? {} : { fileAttachmentCount: display.fileAttachmentCount }),
      ...(display.attachments === undefined ? {} : { attachments: display.attachments }),
      ...(display.resourceInvocations === undefined ? {} : { resourceInvocations: display.resourceInvocations }),
      runtimeText: text,
      attachmentEnvelope: display.attachmentEnvelope,
      images,
      inputSource: display.inputSource ?? "interactive",
      ...(display.commandId === undefined ? {} : { commandId: display.commandId }),
      ordinal: this.operations.runQueue.nextQueueOrdinal++,
      admitting: false,
    };
    validateQueue([...this.operations.runQueue.queuedMessages, ...this.heldPrompts, entry]);
    // Accepted queued work: an administrative drain and idle eviction wait for
    // it exactly as they wait for Pi's queue.
    this.beginWork(entry.id);
    this.heldPrompts.push(entry);
    if (stopRecovery) this.operations.runAbort.stopRecoveryHoldIDs.add(entry.id);
    (this.operations.runQueue.queueRevision += 1);
    this.operations.publishChanged();
    return { operationId: entry.id };
  }

  scheduleHeldPromptFlush(): void {
    if (this.heldPromptFlush || this.heldPrompts.length === 0 || (this.operations.phase === "compacting")
      || this.operations.runAbort.stopRecoveryQueueClosed || this.operations.disposed || this.operations.shuttingDown) return;
    // Deferred: this runs from snapshot publication, which must finish
    // broadcasting before admission publishes its own transitions.
    this.heldPromptFlush = Promise.resolve()
      .then(() => this.flushHeldPrompts())
      .catch((error) => this.operations.emit("session.diagnostic", safeJson({
        code: "held-prompt-flush-failed",
        message: error instanceof Error ? error.message : String(error),
      })))
      .finally(() => {
        this.heldPromptFlush = undefined;
        this.scheduleHeldPromptFlush();
      });
  }

  /** Admits waiting prompts in order through the ordinary path: the first
   * starts a run when the session is idle, later ones join Pi's queue with
   * their requested behavior. A new compaction pauses the flush. */
  private async flushHeldPrompts(): Promise<void> {
    while (this.heldPrompts.length > 0 && !(this.operations.phase === "compacting") && !this.operations.disposed && !this.operations.shuttingDown) {
      const entry = this.heldPrompts[0]!;
      entry.admitting = true;
      try {
        await this.admitHeld(entry);
      } catch (error) {
        if (error instanceof GatewayError && error.code === "busy" && error.retryable
          && !this.operations.lifecycle.isDraining && !this.operations.disposed) {
          // A prior response is still committing: accepted work waits for it
          // rather than failing a message whose RPC already succeeded.
          entry.admitting = false;
          await this.operations.waitForStateChange();
          continue;
        }
        this.operations.runWork.settleOperationWork(entry.id);
        const message = error instanceof Error ? error.message : String(error);
        // Only a proven non-start lets clients restore the draft.
        if (isUncertainOutcome(error)) {
          this.operations.emit("session.diagnostic", safeJson({ code: "held-prompt-outcome-unknown", operationId: entry.id, message }));
        } else {
          this.operations.emit("session.operationFailed", { operationId: entry.id, message });
        }
      }
      if (this.removeHeldPrompt(entry.id)) {
        this.operations.publishChanged();
      }
    }
  }

  removeHeldPrompt(id: string): boolean {
    const index = this.heldPrompts.findIndex((item) => item.id === id);
    if (index < 0) return false;
    this.heldPrompts.splice(index, 1);
    (this.operations.runQueue.queueRevision += 1);
    return true;
  }

  clearWaiting(): void {
    const dropped = this.heldPrompts.filter((item) => !item.admitting);
    if (dropped.length > 0) {
      this.heldPrompts = this.heldPrompts.filter((item) => item.admitting);
      for (const item of dropped) this.operations.runWork.settleOperationWork(item.id);
      (this.operations.runQueue.queueRevision += 1);
      this.operations.publishChanged();
    }
  }

  /** Edits, reorders and removes waiting prompts synchronously: they have no
   * invocation receipt or Pi queue entry yet, and the lane may belong to the
   * compaction they are waiting for. The head entry already being admitted is
   * immutable and stays first. */
  replaceHeldPrompts(
    expectedRevision: number,
    items: Array<Pick<QueuedMessageState, "id" | "behavior" | "text">>,
  ): { queueRevision: number; items: QueuedMessageState[] } {
    if (expectedRevision !== this.operations.runQueue.queueRevision) {
      throw new GatewayError("conflict", "The message queue changed. Review the latest queue and try again.", true);
    }
    const previousByID = new Map(this.heldPrompts.map((item) => [item.id, item]));
    const seen = new Set<string>();
    const next = items.map((item) => {
      const previous = previousByID.get(item.id);
      if (!previous || !seen.add(item.id)) {
        throw new GatewayError("conflict", "The message queue changed. Review the latest queue and try again.", true);
      }
      return this.operations.queueCommands.editedQueueItem(previous, item, false);
    });
    const admitting = this.heldPrompts.find((item) => item.admitting);
    if (admitting) {
      const retained = next[0];
      if (retained?.id !== admitting.id
        || retained.text !== admitting.text
        || retained.behavior !== admitting.behavior) {
        throw new GatewayError("conflict", "That message is already being sent.", true);
      }
    }
    validateQueue(next);
    this.operations.queueCommands.assertQueueableResources(next);
    const retainedIDs = new Set(next.map((item) => item.id));
    for (const item of this.heldPrompts) {
      if (!retainedIDs.has(item.id)) this.operations.runWork.settleOperationWork(item.id);
    }
    this.heldPrompts = next;
    (this.operations.runQueue.queueRevision += 1);
    this.operations.publishChanged();
    return { queueRevision: this.operations.runQueue.queueRevision, items: this.operations.runQueue.projectedQueue() };
  }
  private isMessage(text: string): boolean {
    const command = parsePiLiteralCommand(text)?.name;
    return command === undefined || this.operations.runtime.session.extensionRunner.getCommand(command) === undefined;
  }

  private beginWork(id: string): void { this.operations.runWork.beginOperationWork(id, "queued-mutation"); }

  private admitHeld(entry: HeldPrompt): Promise<unknown> {
    return admitPrompt(this.operations, entry.runtimeText, entry.images, entry.behavior, {
          text: entry.text,
          attachmentEnvelope: entry.attachmentEnvelope,
          attachmentCount: entry.attachmentCount,
          ...(entry.photoCount === undefined ? {} : { photoCount: entry.photoCount }),
          ...(entry.fileAttachmentCount === undefined ? {} : { fileAttachmentCount: entry.fileAttachmentCount }),
          ...(entry.attachments === undefined ? {} : { attachments: entry.attachments }),
          ...(entry.resourceInvocations === undefined ? {} : { resourceInvocations: entry.resourceInvocations }),
        }, undefined, undefined, entry.id, entry);
  }

}
