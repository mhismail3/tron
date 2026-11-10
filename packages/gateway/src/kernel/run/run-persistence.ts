import type { RunOperations } from "./run-operations.js";
import { asUncertainOutcome, isUncertainOutcome, uncertainOutcome } from "../../errors.js";
import type { GatewayWorkHandle } from "./gateway-work-registry.js";
import { RunMarkerCompletionConflictError } from "./run-markers.js";
import { StallTolerantDeadline } from "../../util/stall-tolerant-deadline.js";

export const DEFAULT_OWNERSHIP_WRITE_RETRY_WINDOW_MS = 20_000;
export class CanonicalCustomEntryConflictError extends Error {}


export class RunPersistence {
  readonly pendingReceiptWrites = new Set<Promise<void>>();
  readonly durableWrites = new Map<string, { waiter: Promise<void>; blocked: boolean; admittedAt: string }>();

  constructor(private readonly operations: RunOperations<unknown>) {}

  trackSettlementChain(chain: Promise<void>): void {
    this.pendingReceiptWrites.add(chain);
    void chain.finally(() => {
      this.pendingReceiptWrites.delete(chain);
      this.operations.releaseSettleWaiters();
    });
  }

  trackOwnershipWrite(
    startWrite: () => Promise<void>,
    existingOwner?: GatewayWorkHandle,
  ): Promise<void> {
    if (this.hasBlockedOwnershipWrite) {
      return Promise.reject(uncertainOutcome("Canonical ownership persistence is unresolved; no additional write may be admitted"));
    }
    const derived = existingOwner === undefined;
    const work = existingOwner ?? this.operations.dependencies.workRegistry.beginDerived({
      kind: "terminal-receipt-persistence", sessionId: this.operations.id, hostEpoch: this.operations.ui.hostEpoch,
    });
    work.progress();
    let write: Promise<void>;
    try {
      write = startWrite();
    } catch (error) {
      if (derived) work.settle();
      throw error;
    }
    this.pendingReceiptWrites.add(write);
    void write.then(() => {
      this.pendingReceiptWrites.delete(write);
      this.operations.releaseSettleWaiters();
      if (derived) work.settle();
    }, error => {
      this.pendingReceiptWrites.delete(write);
      this.operations.releaseSettleWaiters();
      if (derived && !isUncertainOutcome(error)) work.settle();
    });
    return write;
  }

  get hasBlockedOwnershipWrite(): boolean {
    return [...this.durableWrites.values()].some(write => write.blocked);
  }

  assertOwnershipPersistence(): void {
    if (this.hasBlockedOwnershipWrite) {
      throw uncertainOutcome("Canonical ownership persistence is unresolved; this runtime remains retained and cannot admit mutations, reload, or dispose");
    }
  }

  retryDurableWrite(key: string, operation: () => Promise<void>): Promise<void> {
    const existing = this.durableWrites.get(key);
    if (existing) return existing.waiter;
    this.assertOwnershipPersistence();
    const owner = { blocked: false, admittedAt: new Date().toISOString(), waiter: undefined as unknown as Promise<void> };
    let deadline!: StallTolerantDeadline;
    const expired = new Promise<never>((_, reject) => {
      deadline = new StallTolerantDeadline(DEFAULT_OWNERSHIP_WRITE_RETRY_WINDOW_MS, () => {
        owner.blocked = true;
        reject(uncertainOutcome("Canonical ownership persistence exceeded its wait deadline; the exact write remains unresolved"));
      });
    });
    const completion = (async () => {
      let attempt = 0;
      for (;;) {
        try {
          await operation();
          return;
        } catch (error) {
          if (owner.blocked || deadline.expired
            || error instanceof RunMarkerCompletionConflictError
            || error instanceof CanonicalCustomEntryConflictError
            || this.operations.dependencies.modules.policy("appendGuard")?.(this.operations.canonicalAppendContext).isPreAppendRefusal(error)
            || isUncertainOutcome(error)) throw error;
          attempt += 1;
          if (attempt === 1) this.diagnostic("canonical-ownership-persistence-retrying");
          await new Promise<void>(resolve => setTimeout(resolve, Math.min(1_000, 25 * attempt)));
          if (owner.blocked) throw uncertainOutcome("Canonical ownership persistence remains unresolved");
        }
      }
    })();
    owner.waiter = Promise.race([completion, expired]).then(() => {
      if (this.durableWrites.get(key) === owner) this.durableWrites.delete(key);
    }, error => {
      if (!owner.blocked && (error instanceof RunMarkerCompletionConflictError
        || error instanceof CanonicalCustomEntryConflictError || this.operations.dependencies.modules.policy("appendGuard")?.(this.operations.canonicalAppendContext).isPreAppendRefusal(error))) {
        if (this.durableWrites.get(key) === owner) this.durableWrites.delete(key);
        throw error;
      }
      owner.blocked = true;
      this.block();
      this.diagnostic("canonical-ownership-persistence-blocked");
      throw asUncertainOutcome(error, "Canonical ownership persistence could not be proven");
    }).finally(() => deadline.cancel());
    this.durableWrites.set(key, owner);
    return owner.waiter;
  }

  async waitForReceiptWrites(): Promise<void> {
    this.assertOwnershipPersistence();
    let expire!: () => void;
    const expiry = new Promise<"expired">((resolve) => { expire = () => resolve("expired"); });
    const deadline = new StallTolerantDeadline(DEFAULT_OWNERSHIP_WRITE_RETRY_WINDOW_MS, expire);
    try {
      while (this.pendingReceiptWrites.size > 0 && !deadline.expired) {
        const settled = await Promise.race([
          Promise.allSettled([...this.pendingReceiptWrites]).then(() => "joined" as const),
          expiry,
        ]);
        if (settled === "expired") break;
      }
    } finally {
      deadline.cancel();
    }
    this.assertOwnershipPersistence();
    if (this.pendingReceiptWrites.size > 0) {
      throw uncertainOutcome(
        `Canonical ownership persistence did not settle within its bounded disposal window (${this.pendingReceiptWrites.size} pending write(s))`,
      );
    }
  }

  private block(): void {
    this.operations.lifecycle.beginDrain();
    const session = this.operations.runtime?.session;
    if (session) {
      for (const cancel of [() => session.abortCompaction(), () => session.abortRetry(), () => session.abortBranchSummary(), () => session.abortBash()]) {
        try { cancel(); } catch { }
      }
      void session.abort().catch(() => {});
      void this.operations.directBashProcesses?.abortAll().catch(() => {});
    }
  }

  private diagnostic(code: string): void {
    this.operations.dependencies.persistenceDiagnostic?.(this.operations.id, code);
    this.operations.emit("session.diagnostic", { code, message: "Canonical ownership persistence requires attention" });
  }

}
