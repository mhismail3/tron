import type { RunOperations } from "./run-operations.js";
import type { GatewayWorkHandle } from "./gateway-work-registry.js";
import { INVOCATION_RECEIPT_TYPE, invocationProjection, invocationReceipts, makeInvocationReceipt, receiptJSON, type InvocationProjection } from "../receipts/invocation-receipts.js";
import type { OwnedOperationTerminal } from "../delegation/owned-operation-terminal.js";

/** Volatile cancellation attribution shares the invocation's receipt lifetime. */
type LiveInvocation = InvocationProjection & { stopReason?: string };

export interface CommandReplacement {
  /** Set once Pi commits the replacement and the command is settled in its origin. */
  settlement?: Promise<void>;
}

export class RunInvocations {
  readonly invocations = new Map<string, LiveInvocation>();
  readonly invocationFailures = new Map<string, string>();
  /** Commands settled in their origin at a replacement; bounded. */
  private readonly handedOffInvocations = new Set<string>();

  constructor(private readonly operations: RunOperations<unknown>) {}

  async persistInvocationReceipt(receipt: ReturnType<typeof makeInvocationReceipt>, owner?: GatewayWorkHandle): Promise<void> {
    if (this.handedOffInvocations.has(receipt.invocationId)) return;
    await this.operations.persistCanonicalCustomEntry(INVOCATION_RECEIPT_TYPE, receiptJSON(receipt), receipt.receiptId, owner);
    if (receipt.receiptKind === "terminal" && this.operations.homeRequestPolicy) {
      this.operations.homeRequestPolicy.responseTiming.terminal(receipt.operationId, receipt.lifecycle as "completed" | "failed" | "interrupted" | "outcomeUnknown");
      // The terminal receipt is already canonical. A failed settlement leaves its
      // delivery admitted for the next activation to re-prove; it must not strand
      // this operation's work entry or its terminal observers.
      await this.operations.dependencies.modules.policy("inputAdmission")?.().settle(this.operations.id, receipt.operationId).catch(error => {
        this.operations.emit("session.diagnostic", { code: "home-inbox-settlement-failed", message: String(error).slice(0, 256) });
      });
    }
  }

  invocationForOperation(operationId: string | undefined): LiveInvocation | undefined {
    if (!operationId) return undefined;
    const live = [...this.invocations.values()]
      .filter(invocation => invocation.operationId === operationId)
      .at(-1);
    if (live) return live;
    const canonical = invocationProjection(invocationReceipts(
      this.operations.sessionManager.getBranch(),
      this.operations.id,
    )).filter(invocation => invocation.operationId === operationId).at(-1);
    if (canonical) this.invocations.set(canonical.invocationId, canonical);
    return canonical;
  }

  async terminalizeInvocation(
    operationId: string | undefined,
    lifecycle: "completed" | "failed" | "interrupted" | "outcomeUnknown",
    errorCode?: string,
    owner?: GatewayWorkHandle,
    assistantCompletionId?: string,
  ): Promise<void> {
    const terminal = await this.persistInvocationTerminal(operationId, lifecycle, errorCode, owner, assistantCompletionId);
    if (terminal) await this.operations.ownedTurns.notifyOwnedTerminal(terminal);
  }

  async persistInvocationTerminal(
    operationId: string | undefined,
    lifecycle: "completed" | "failed" | "interrupted" | "outcomeUnknown",
    errorCode?: string,
    owner?: GatewayWorkHandle,
    assistantCompletionId?: string,
  ): Promise<OwnedOperationTerminal | undefined> {
    if (operationId) this.operations.runQueue.retireTerminalOwnership(operationId);
    this.operations.runPersistence.assertOwnershipPersistence();
    const invocation = this.invocationForOperation(operationId);
    if (!invocation || ["completed", "failed", "interrupted", "outcomeUnknown"].includes(invocation.lifecycle)) return;
    // Stop records attribution before cancellation yields. All terminal
    // observers, including successful completion, publish that same fact.
    if (invocation.stopReason) {
      lifecycle = "interrupted";
      errorCode = invocation.stopReason;
    }
    // SDK append is synchronous, but receipt acknowledgement and live-map
    // retirement yield. A second terminal observer must join the first exact
    // receipt, not manufacture a second timestamp/lifecycle while that live map
    // still looks active. The first observer owns terminal notification.
    const priorTerminal = invocationReceipts(this.operations.sessionManager.getBranch(), this.operations.id)
      .find(receipt => receipt.invocationId === invocation.invocationId && receipt.receiptKind === "terminal");
    if (priorTerminal) {
      await this.persistInvocationReceipt(priorTerminal, owner ?? this.operations.runWork.get(invocation.operationId));
      return;
    }
    await this.persistInvocationReceipt(makeInvocationReceipt({
      version: 1,
      receiptId: `terminal:${invocation.invocationId}`,
      receiptKind: "terminal",
      invocationId: invocation.invocationId,
      operationId: invocation.operationId,
      sessionId: this.operations.id,
      source: invocation.source,
      ...(invocation.name ? { name: invocation.name } : {}),
      lifecycle,
      ...(errorCode ? { errorCode } : {}),
      origin: invocation.origin,
      sequence: this.operations.revision + 1,
      createdAt: new Date().toISOString(),
    }), owner ?? this.operations.runWork.get(invocation.operationId));
    this.invocations.delete(invocation.invocationId);
    return {
      lifecycle,
      operationId: invocation.operationId,
      invocationId: invocation.invocationId,
      ...(errorCode === undefined ? {} : { errorCode }),
      ...(assistantCompletionId === undefined ? {} : { assistantCompletionId }),
    };
  }

  /** A distinct successor ends the predecessor; another assistant turn or
   * automatic compaction does not. Capture exact completion evidence before
   * the transfer retires its operation observation. */
  terminalizeTransferredOperation(operationId: string | undefined): void {
    if (!operationId) return;
    const completionId = this.operations.runAttention.completionOwnershipQueue.findLast(item => item.completion.operationId === operationId)?.completion.id
      ?? this.operations.runTerminal.operationObservations.get(operationId)?.observedCompletionId;
    if (!completionId) return;
    const interrupted = this.operations.runAbort.abortedOperations.has(operationId);
    const attention = this.operations.runAttention.attentionBarrier;
    void this.persistInvocationTerminal(
      operationId, interrupted ? "interrupted" : "completed", interrupted ? "user-abort" : undefined,
      this.operations.runWork.get(operationId), completionId,
    ).then(async terminal => {
      if (attention) await attention;
      if (terminal) await this.operations.ownedTurns.notifyOwnedTerminal(terminal);
      this.operations.runAbort.abortedOperations.delete(operationId);
    }).catch(() => {});
  }

  async joinTerminalReceiptWrites(): Promise<void> {
    // Guarantees receipt order against the next admitted user input, not
    // SDK-owned between-turn entries (such as tool-loadout system messages)
    // emitted before that exact boundary. Their relative order proves nothing.
    const prefix = `canonical:${INVOCATION_RECEIPT_TYPE}:terminal:`;
    await Promise.all([...this.operations.runPersistence.durableWrites.entries()]
      .filter(([key]) => key.startsWith(prefix))
      .map(([, write]) => write.waiter));
    this.operations.runPersistence.assertOwnershipPersistence();
  }

  handOffReplacedCommand(): void {
    const replacement = this.operations.commandReplacement;
    const command = this.operations.pendingExtensionCommand;
    const operationId = command?.id;
    const invocation = command?.invocationId ? this.invocations.get(command.invocationId) : undefined;
    if (!replacement || replacement.settlement || !operationId || !invocation) return;
    // Only the durable facts move here, while the origin is still bound: its
    // terminal receipt and its marker. The live command state still settles
    // through the command's own completion, now under the replacement identity,
    // which is why every later receipt for it is refused.
    this.handedOffInvocations.add(invocation.invocationId);
    while (this.handedOffInvocations.size > 32) this.handedOffInvocations.delete(this.handedOffInvocations.values().next().value!);
    const terminal = this.operations.persistCanonicalCustomEntry(INVOCATION_RECEIPT_TYPE, receiptJSON(makeInvocationReceipt({
      version: 1,
      receiptId: `terminal:${invocation.invocationId}`,
      receiptKind: "terminal",
      invocationId: invocation.invocationId,
      operationId,
      sessionId: this.operations.id,
      source: invocation.source,
      ...(invocation.name ? { name: invocation.name } : {}),
      lifecycle: "completed",
      origin: invocation.origin,
      sequence: this.operations.revision + 1,
      createdAt: new Date().toISOString(),
    })), `terminal:${invocation.invocationId}`, this.operations.runWork.get(operationId));
    replacement.settlement = Promise.all([terminal, this.operations.clearMarkerOwnership(operationId)]).then(() => {});
  }

}
