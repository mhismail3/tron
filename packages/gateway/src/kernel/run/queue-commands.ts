import { randomUUID } from "node:crypto";
import type { AgentSession } from "../pi/coding-agent.js";
import { GatewayError } from "../../errors.js";
import type { CommandInfo, QueuedMessageState, ResourceInvocation } from "../../protocol/types.js";
import { admitPromptText, admitResourceInvocations, canonicalResourceName, composeResourcePrompt, parsePiLiteralCommand, type ResourceExpansionCatalog } from "../../sessions/resource-invocation.js";
import { makeInvocationReceipt, type InvocationProjection, type InvokedResource } from "./invocation-receipts.js";
import type { GatewayWorkHandle } from "./gateway-work-registry.js";
import type { RunWorkOwner } from "./run-work-owner.js";
import type { RunQueueOwner } from "./run-queue-owner.js";
import type { HeldPromptQueue } from "./held-prompt-queue.js";
import type { QueueBehavior, RuntimeQueuedMessage } from "./queue-input.js";

const MAXIMUM_QUEUED_MESSAGES = 32;
export const MAXIMUM_QUEUED_MESSAGE_BYTES = 64 * 1_024;
const MAXIMUM_QUEUED_TOTAL_BYTES = 256 * 1_024;

export interface RunQueueCommandsContext {
  assertUsable(): void;
  queue(): RunQueueOwner;
  held(): HeldPromptQueue;
  session(): AgentSession;
  runWork(): RunWorkOwner;
  run<T>(operation: () => Promise<T>): Promise<T>;
  commands(): CommandInfo[];
  resourceExpansionCatalog(): ResourceExpansionCatalog;
  invocationForOperation(id: string): InvocationProjection | undefined;
  terminalizeInvocation(id: string, lifecycle: "completed" | "interrupted", errorCode?: string): Promise<void>;
  persistInvocationReceipt(receipt: ReturnType<typeof makeInvocationReceipt>, owner?: GatewayWorkHandle): Promise<void>;
  setInvocation(id: string, invocation: InvocationProjection): void;
  sessionId(): string;
  revision(): number;
  publishChanged(): void;
}

export function queueText(text: string, attachmentEnvelope: string): string {
  return [text.trim(), attachmentEnvelope].filter(Boolean).join("\n\n");
}

export function validateQueue(items: Array<Pick<QueuedMessageState, "text" | "attachmentCount"> & { resourceInvocations?: ResourceInvocation[] | undefined }>): void {
  if (items.length > MAXIMUM_QUEUED_MESSAGES) {
    throw new GatewayError("invalid_request", `At most ${MAXIMUM_QUEUED_MESSAGES} messages may be queued`);
  }
  let totalBytes = 0;
  for (const item of items) {
    admitPromptText(item.text, MAXIMUM_QUEUED_MESSAGE_BYTES);
    if (item.resourceInvocations !== undefined) admitResourceInvocations(item.resourceInvocations, item.text);
    const bytes = Buffer.byteLength(item.text);
    if (bytes > MAXIMUM_QUEUED_MESSAGE_BYTES) {
      throw new GatewayError("invalid_request", "A queued message is too large to manage safely");
    }
    if (item.text.trim().length === 0 && item.attachmentCount === 0 && item.resourceInvocations === undefined) {
      throw new GatewayError("invalid_request", "Queued messages cannot be empty");
    }
    totalBytes += bytes;
  }
  if (totalBytes > MAXIMUM_QUEUED_TOTAL_BYTES) {
    throw new GatewayError("invalid_request", "The queued message total is too large to manage safely");
  }
}

/** The receipt form of a composed message's skills and prompts. */
export function invocationResources(resources: readonly ResourceInvocation[] | undefined): InvokedResource[] | undefined {
  return resources?.map(({ source, name }) => {
    if (source === "extension") throw new Error("An extension command is not a composed resource");
    return { source, name };
  });
}

export function resourceIsInvocable(commands: readonly CommandInfo[], resource: ResourceInvocation): boolean {
  const catalogName = canonicalResourceName(resource.source, resource.name);
  const matches = commands.filter(command => command.source === resource.source && command.name === catalogName);
  // A skill or prompt sharing an extension command's name is ambiguous to pick.
  const shadowed = resource.source !== "extension"
    && commands.some(command => command.source === "extension" && command.name === catalogName);
  return matches.length === 1 && !shadowed;
}

/** Serialized edits retain the one queue owner's identities and SDK effect order. */
export class RunQueueCommands {
  constructor(private readonly context: RunQueueCommandsContext) {}

  async clearQueue(): Promise<void> {
    // Waiting prompts are not admitted yet, so they clear immediately instead
    // of behind the compaction that owns the session lane.
    this.context.assertUsable();
    this.context.held().clearWaiting();
    this.context.queue().reconcileQueuedMessages();
    if (this.context.queue().queuedMessages.length === 0 && !this.context.queue().pendingQueueAdmission) return;
    return this.context.run(async () => {
      this.context.assertUsable();
      const removed = this.context.queue().queuedMessages;
      this.context.queue().suppressQueueEvents = true;
      try {
        this.context.session().clearQueue();
      } finally {
        this.context.queue().suppressQueueEvents = false;
      }
      this.context.queue().sdkQueuedSteeringIDs.clear();
      for (const item of removed) {
        await this.context.terminalizeInvocation(item.id, "interrupted", "queue-cleared");
        this.context.runWork().settleOperationWork(item.id);
      }
      this.context.queue().queuedMessages = [];
      this.context.queue().queueRevision += 1;
      this.context.publishChanged();
    });
  }

  /** A held prompt keeps its visible runtime text (admission composes it); a
   * message in Pi's queue is recomposed with its skills and prompts. */
  editedQueueItem<T extends RuntimeQueuedMessage>(
    previous: T,
    item: Pick<QueuedMessageState, "behavior" | "text">,
    composed: boolean,
  ): T {
    const text = item.text.trim();
    const visibleRuntimeText = queueText(text, previous.attachmentEnvelope);
    return {
      ...previous,
      behavior: item.behavior,
      text,
      runtimeText: text === previous.text
        ? previous.runtimeText
        : composed && previous.resourceInvocations !== undefined
          ? composeResourcePrompt(previous.resourceInvocations, visibleRuntimeText, this.context.resourceExpansionCatalog())
          : visibleRuntimeText,
    };
  }

  assertQueueableResources(items: readonly RuntimeQueuedMessage[]): void {
    const commands = this.context.commands();
    const extensionCommands = new Set(
      commands.filter((command) => command.source === "extension").map((command) => command.name),
    );
    for (const item of items) {
      if (item.resourceInvocations !== undefined) {
        if (!item.resourceInvocations.every(resource => resourceIsInvocable(commands, resource))) {
          throw new GatewayError("conflict", "A queued resource is no longer unambiguous for this session", true);
        }
        // A composed message is never a command, whatever its text begins with.
        continue;
      }
      if (!item.runtimeText.startsWith("/")) continue;
      const command = parsePiLiteralCommand(item.runtimeText)?.name ?? "";
      if (extensionCommands.has(command)) {
        throw new GatewayError("invalid_request", `Extension command "/${command}" cannot be queued`);
      }
    }
  }

  async replaceQueue(
    expectedRevision: number,
    items: Array<Pick<QueuedMessageState, "id" | "behavior" | "text">>,
  ): Promise<{ queueRevision: number; items: QueuedMessageState[] }> {
    if (this.context.held().entries.length > 0) {
      this.context.assertUsable();
      this.context.queue().reconcileQueuedMessages();
      // Pi's queue and the held queue have different owners and admission
      // states; one atomic edit across both is not offered.
      if (this.context.queue().queuedMessages.length > 0 || this.context.queue().pendingQueueAdmission) {
        throw new GatewayError("conflict", "Messages are still moving into the active queue. Try again in a moment.", true);
      }
      return this.context.held().replaceHeldPrompts(expectedRevision, items);
    }
    return this.context.run(async () => {
      this.context.assertUsable();
      const session = this.context.session();
      this.context.queue().reconcileQueuedMessages();
      if (expectedRevision !== this.context.queue().queueRevision) {
        throw new GatewayError("conflict", "The message queue changed. Review the latest queue and try again.", true);
      }
      if (!session.isStreaming && items.length > 0) {
        throw new GatewayError("conflict", "The active run finished before the queue could be updated.", true);
      }

      const previousByID = new Map(this.context.queue().queuedMessages.map((item) => [item.id, item]));
      const seen = new Set<string>();
      const next = items.map((item) => {
        const previous = previousByID.get(item.id);
        if (!previous || !seen.add(item.id)) {
          throw new GatewayError("conflict", "The message queue changed. Review the latest queue and try again.", true);
        }
        return { ...this.editedQueueItem(previous, item, true), ordinal: this.context.queue().nextQueueOrdinal++ };
      });
      validateQueue(next);
      this.assertQueueableResources(next);

      const replacementInvocations = new Map<string, InvocationProjection>();
      for (const item of next) {
        const previous = previousByID.get(item.id);
        if (previous?.resourceInvocations === undefined || previous.text === item.text) continue;
        const invocation = this.context.invocationForOperation(item.id);
        if (!invocation || invocation.source === "plain" || invocation.name === undefined
          || item.resourceInvocations === undefined) {
          throw new GatewayError("conflict", "Queued resource invocation ownership changed", true);
        }
        replacementInvocations.set(item.id, invocation);
      }

      let rebuildError: unknown;
      let handledItems = new Set<string>();
      this.context.queue().suppressQueueEvents = true;
      try {
        session.clearQueue();
        // Publish in requested order: each item is prepared (images may need resizing) and queued before the
        // next starts, so a slow photo cannot let a later item of the same behavior enter Pi's queue first.
        const dispositions: Array<"handled" | "queued"> = [];
        for (const item of next) {
          dispositions.push(item.behavior === "steer"
            ? await session.steer(item.runtimeText, item.images)
            : await session.followUp(item.runtimeText, item.images));
        }
        handledItems = new Set(next.flatMap((item, index) =>
          dispositions[index] === "handled" ? [item.id] : []));
      } catch (error) {
        rebuildError = error;
        // Queue replacement is one mutation. Do not retain a partially rebuilt
        // queue whose items have no coherent invocation ownership.
        session.clearQueue();
      } finally {
        this.context.queue().suppressQueueEvents = false;
      }
      if (rebuildError !== undefined) {
        const removed = this.context.queue().queuedMessages;
        for (const item of removed) {
          await this.context.terminalizeInvocation(item.id, "interrupted", "queue-rebuild-failed");
          this.context.runWork().settleOperationWork(item.id);
        }
        this.context.queue().queuedMessages = [];
        this.context.queue().queueRevision += 1;
        this.context.publishChanged();
        throw rebuildError;
      }

      const actual: Record<QueueBehavior, readonly string[]> = {
        steer: session.getSteeringMessages(),
        followUp: session.getFollowUpMessages(),
      };
      const survivors: RuntimeQueuedMessage[] = [];
      for (const behavior of ["steer", "followUp"] as const) {
        const desired = next.filter((item) => item.behavior === behavior && !handledItems.has(item.id));
        const texts = actual[behavior];
        const retained = desired.slice(Math.max(0, desired.length - texts.length));
        const aligned = retained.slice(Math.max(0, retained.length - texts.length));
        for (let index = 0; index < aligned.length; index += 1) {
          survivors.push({ ...aligned[index]!, runtimeText: texts[texts.length - aligned.length + index]! });
        }
      }
      const removed = this.context.queue().queuedMessages.filter(item => !survivors.some(candidate => candidate.id === item.id));
      const revised = survivors.filter(item => {
        const previous = previousByID.get(item.id);
        return previous?.resourceInvocations !== undefined && previous.text !== item.text;
      });
      for (const item of revised) {
        const previousInvocation = replacementInvocations.get(item.id)!;
        const resourceInvocations = item.resourceInvocations;
        const invocationName = previousInvocation.name;
        if (!resourceInvocations || !invocationName) throw new Error("revised resource invocation is unavailable");
        // Start receipts are immutable. Editing a queued message's text terminalizes
        // the prior intent and starts a replacement invocation while retaining
        // the queue operation ID used by native row identity.
        await this.context.terminalizeInvocation(item.id, "interrupted", "queue-edited");
        const invocationId = randomUUID();
        const createdAt = new Date().toISOString();
        await this.context.persistInvocationReceipt(makeInvocationReceipt({
          version: 1,
          receiptId: `start:${invocationId}`,
          receiptKind: "start",
          invocationId,
          operationId: item.id,
          sessionId: this.context.sessionId(),
          source: previousInvocation.source,
          name: invocationName,
          resources: invocationResources(resourceInvocations)!,
          submittedText: item.text,
          lifecycle: "staged",
          origin: previousInvocation.origin,
          sequence: this.context.revision() + 1,
          createdAt,
        }), this.context.runWork().get(item.id));
        await this.context.persistInvocationReceipt(makeInvocationReceipt({
          version: 1,
          receiptId: `accepted:${invocationId}`,
          receiptKind: "transition",
          invocationId,
          operationId: item.id,
          sessionId: this.context.sessionId(),
          source: previousInvocation.source,
          lifecycle: "accepted",
          sequence: this.context.revision() + 1,
          createdAt: new Date().toISOString(),
        }), this.context.runWork().get(item.id));
        this.context.setInvocation(invocationId, {
          version: 1,
          invocationId,
          operationId: item.id,
          source: previousInvocation.source,
          name: invocationName,
          submittedText: item.text,
          resourceInvocations,
          lifecycle: "queued",
          origin: previousInvocation.origin,
          sequence: this.context.revision() + 1,
          updatedAt: createdAt,
        });
      }
      for (const item of removed) {
        await this.context.terminalizeInvocation(
          item.id,
          handledItems.has(item.id) ? "completed" : "interrupted",
          handledItems.has(item.id) ? undefined : "queue-replaced",
        );
        this.context.runWork().settleOperationWork(item.id);
      }
      this.context.queue().queuedMessages = survivors.sort((left, right) => left.behavior === right.behavior
        ? left.ordinal - right.ordinal
        : left.behavior === "steer" ? -1 : 1);
      this.context.queue().sdkQueuedSteeringIDs.clear();
      for (const item of survivors) if (item.behavior === "steer") this.context.queue().sdkQueuedSteeringIDs.add(item.id);
      this.context.queue().queueRevision += 1;
      this.context.publishChanged();
      return { queueRevision: this.context.queue().queueRevision, items: this.context.queue().projectedQueue() };
    });
  }

}
