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
};
/** One armed deadline. Its signal aborts at the fixed ceiling; `disarm` releases the timer. */
export interface OwnedOperationDeadline { readonly signal: AbortSignal; readonly armedAt: number; disarm: () => void }

/** The shared owned-session boundary: session lease, exact operation evidence,
 * and settlement acknowledgement remain with RuntimeRegistry / RuntimeSlot. */
export class OwnedSessionDispatch {
  constructor(private readonly sessions: RuntimeRegistry) {}

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

  /** Arms the fixed deadline of one opted-in operation. The caller disarms it only
   * after settlement, so every bounded step of that operation (including the
   * subagent join) shares the same 24-hour ceiling. The deadline is intentionally
   * not configurable in production; tests advance the timer by the fixed value. */
  armDeadline(): OwnedOperationDeadline {
    const controller = new AbortController();
    const armedAt = Date.now();
    const timer = setTimeout(() => controller.abort(), OWNED_OPERATION_DEADLINE_MS);
    return {
      signal: controller.signal,
      armedAt,
      disarm: () => clearTimeout(timer),
    };
  }

  /** Applies the armed deadline to the opted-in task operation. `elapsedMs` is the
   * wall time from arming to the stop's join or failure, so the caller reports the
   * stop with the outcome it already holds. */
  async enforceDeadline<T>(handle: OperationHandle<T>, deadline: OwnedOperationDeadline): Promise<
    | { state: "terminal"; terminal: T }
    | { state: "deadline-stopped"; terminal: T; elapsedMs: number }
    | { state: "deadline-stop-failed"; elapsedMs: number }
  > {
    const expired = new Promise<"deadline">((resolve) => {
      if (deadline.signal.aborted) resolve("deadline");
      else deadline.signal.addEventListener("abort", () => resolve("deadline"), { once: true });
    });
    const first = await Promise.race([
      handle.completion.then((terminal) => ({ kind: "terminal" as const, terminal })),
      expired,
    ]);
    if (first !== "deadline") return { state: "terminal", terminal: first.terminal };
    try {
      await handle.cancel("deadline");
      const terminal = await handle.completion;
      return { state: "deadline-stopped", terminal, elapsedMs: Math.max(0, Date.now() - deadline.armedAt) };
    } catch {
      return { state: "deadline-stop-failed", elapsedMs: Math.max(0, Date.now() - deadline.armedAt) };
    }
  }
}
