import { createHash } from "node:crypto";
import type { RuntimeRegistry } from "./runtime-registry.js";
import type { RuntimeSlot } from "./runtime-slot.js";
import type { HomeTaskReportOwner } from "../home/home-task-report.js";

/** Internal runaway ceiling for callers that explicitly opt into deadline ownership. */
export const OWNED_OPERATION_DEADLINE_MS = 24 * 60 * 60 * 1_000;

type OwnedLease = { slot: RuntimeSlot; release: () => void };
type OperationHandle<T> = {
  operationId: string;
  completion: Promise<T>;
  cancel: (reason?: string) => Promise<void>;
  acknowledgeTerminal?: () => Promise<void>;
};

export type OwnedOperationDeadlineDiagnostic = {
  event: "owned-operation.deadline-stop";
  level: "warning";
  operationHash: string;
  elapsedMs: number;
  cancelAndJoin: "joined" | "failed";
};

export interface OwnedSessionDispatchOptions {
  diagnostic?: (record: OwnedOperationDeadlineDiagnostic) => void;
}

function opaqueHash(value: string): string {
  return createHash("sha256").update(value).digest("hex").slice(0, 16);
}

/** The shared owned-session boundary: session lease, exact operation evidence,
 * and settlement acknowledgement remain with RuntimeRegistry / RuntimeSlot. */
export class OwnedSessionDispatch {
  private readonly now: () => number;

  constructor(
    private readonly sessions: RuntimeRegistry,
    private readonly options: OwnedSessionDispatchOptions = {},
    now: () => number = Date.now,
  ) {
    this.now = now;
  }

  async createWorker(cwd: string, report: HomeTaskReportOwner): Promise<OwnedLease> {
    const slot = await this.sessions.create(cwd, "ordinary", report);
    return { slot, release: slot.retainLease() };
  }

  lease(sessionId: string): Promise<OwnedLease> {
    return this.sessions.acquireOwnedSessionLease(sessionId);
  }

  recoveryEvidence(sessionId: string, operationId: string) {
    return this.sessions.ownedOperationRecoveryEvidence(sessionId, operationId);
  }

  admit(slot: RuntimeSlot, ...args: Parameters<RuntimeSlot["prompt"]>): ReturnType<RuntimeSlot["prompt"]> {
    return slot.prompt(...args);
  }

  async acknowledge(sessionId: string, operationId: string, lease: OwnedLease): Promise<void> {
    await this.sessions.clearOwnedOperationMarker(sessionId, operationId);
    lease.release();
  }

  clearRecoveryMarker(sessionId: string, operationId: string): Promise<void> {
    return this.sessions.clearOwnedOperationMarker(sessionId, operationId);
  }

  /** Apply only to the opted-in task operation. The deadline is intentionally
   * not configurable in production; tests advance the timer by the fixed value. */
  async enforceDeadline<T>(handle: OperationHandle<T>): Promise<
    | { state: "terminal"; terminal: T }
    | { state: "deadline-stopped"; terminal: T }
    | { state: "deadline-stop-failed" }
  > {
    const startedAt = this.now();
    let timer: ReturnType<typeof setTimeout> | undefined;
    const deadline = new Promise<"deadline">((resolve) => {
      timer = setTimeout(() => resolve("deadline"), OWNED_OPERATION_DEADLINE_MS);
    });
    try {
      const first = await Promise.race([
        handle.completion.then((terminal) => ({ kind: "terminal" as const, terminal })),
        deadline,
      ]);
      if (first !== "deadline") return { state: "terminal", terminal: first.terminal };
      let joined = false;
      try {
        await handle.cancel("deadline");
        const terminal = await handle.completion;
        await handle.acknowledgeTerminal?.();
        joined = true;
        return { state: "deadline-stopped", terminal };
      } catch {
        return { state: "deadline-stop-failed" };
      } finally {
        this.options.diagnostic?.({
          event: "owned-operation.deadline-stop", level: "warning",
          operationHash: opaqueHash(handle.operationId),
          elapsedMs: Math.max(0, this.now() - startedAt),
          cancelAndJoin: joined ? "joined" : "failed",
        });
      }
    } finally {
      if (timer !== undefined) clearTimeout(timer);

    }
  }
}
