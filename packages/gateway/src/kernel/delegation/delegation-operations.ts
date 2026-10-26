import type { HomeTaskReportOwner } from "./task-report.js";
import type { OwnedTurnOwner } from "./owned-turn-owner.js";
import { homeTaskSubagentRunsSettled } from "./task-subagents.js";
import type { TaskWorkerControl } from "./worker-contract.js";
import { interruptTaskWorker, stopTaskWorker, steerTaskWorker, taskWorkerSteeringInput } from "./worker-control.js";

/** Internal runaway ceiling for callers that explicitly opt into deadline ownership. */
export const OWNED_OPERATION_DEADLINE_MS = 24 * 60 * 60 * 1_000;

type OwnedLease<Session> = { slot: Session; release: () => void };
/** Native session authority: retain its lease and rebind its worker under the
 * existing lane/rebuild operation, never through a second runtime or state copy. */
type OwnedSession = {
  retainLease(): () => void;
  readonly ownedTurns: Pick<OwnedTurnOwner, "worker" | "bindWorker">;
  prompt(...input: ReturnType<typeof taskWorkerSteeringInput>): Promise<unknown>;
};
type InterruptWorkerTools<Session> = (slot: Session, by: string, before?: () => Promise<void>) => Promise<string[]>;
/** The session runtime's owned-session operations (RuntimeRegistry implements them). The
 * run owner imports delegation, so the session handle stays its type. */
export interface OwnedSessions<Session extends OwnedSession> {
  acquire(sessionId: string): Promise<Session>;
  create(cwd: string, profile: "ordinary", report: HomeTaskReportOwner): Promise<Session>;
  acquireOwnedSessionLease(sessionId: string): Promise<OwnedLease<Session>>;
  clearOwnedOperationMarker(sessionId: string, operationId: string): Promise<void>;
}
type OperationHandle<T> = {
  operationId: string;
  completion: Promise<T>;
  cancel: (reason?: string) => Promise<void>;
};
/** One armed deadline. Its signal aborts at the fixed ceiling; `disarm` releases the timer. */
export interface OwnedOperationDeadline { readonly signal: AbortSignal; readonly armedAt: number; disarm: () => void }

/** One kernel service owns worker lease/control/deadline orchestration. Native
 * session/run authorities keep their lane, canonical evidence and work tokens. */
export class DelegationOperations<Session extends OwnedSession> {
  /** Catalog attribution, not the live report-owner binding. A resumed task keeps
   * the session\'s first attribution; native catalog/attention reads this owner. */
  private readonly workerAttribution = new Map<string, string>();

  hasWorkerAttribution(sessionId: string): boolean { return this.workerAttribution.has(sessionId); }
  workerTaskId(sessionId: string): string | undefined { return this.workerAttribution.get(sessionId); }

  registerWorkerAttribution(sessionId: string, taskId: string): boolean {
    if (this.workerAttribution.has(sessionId)) return false;
    this.workerAttribution.set(sessionId, taskId);
    return true;
  }

  constructor(private readonly sessions: OwnedSessions<Session>,
    private readonly interruptTools: InterruptWorkerTools<Session>,
    private readonly resources: { readonly delegatedArtifactRoot?: string }) {}

  /** Read the admitted resource root at recovery, not at service construction.
   * The structural view is the actual native options object, never a copied root. */
  subagentRunsSettled(asyncDirs: readonly string[]): Promise<boolean> {
    const root = this.resources.delegatedArtifactRoot;
    return root === undefined ? Promise.resolve(asyncDirs.length === 0) : homeTaskSubagentRunsSettled(asyncDirs, root);
  }

  async steerWorker(sessionId: string, control: TaskWorkerControl, text: string): Promise<void> {
    const slot = await this.sessions.acquire(sessionId);
    await steerTaskWorker(control, text, input => slot.prompt(...input));
  }

  async interruptWorker(sessionId: string, control: TaskWorkerControl, by: string, text?: string): Promise<string[]> {
    const slot = await this.sessions.acquire(sessionId);
    // K5 validates the exact operation before native I/O fixes its tool targets.
    return await interruptTaskWorker(slot.ownedTurns.worker, control,
      () => this.interruptTools(slot, by,
        text === undefined ? undefined : async () => { await steerTaskWorker(control, text, input => slot.prompt(...input)); }));
  }

  async stopWorker(sessionId: string, control: TaskWorkerControl): Promise<void> {
    await stopTaskWorker((await this.sessions.acquire(sessionId)).ownedTurns.worker, control);
  }

  async createWorker(cwd: string, report: HomeTaskReportOwner): Promise<OwnedLease<Session>> {
    const slot = await this.sessions.create(cwd, "ordinary", report);
    return { slot, release: slot.retainLease() };
  }

  /** Rebinds an existing worker session to a resumed task's report owner (#929). */
  async resumeWorker(sessionId: string, report: HomeTaskReportOwner, exceptWorkToken?: string): Promise<OwnedLease<Session>> {
    const lease = await this.sessions.acquireOwnedSessionLease(sessionId);
    try {
      await lease.slot.ownedTurns.bindWorker(report, exceptWorkToken);
      return lease;
    } catch (error) { lease.release(); throw error; }
  }

  async acknowledge(sessionId: string, operationId: string, lease: OwnedLease<Session>): Promise<void> {
    await this.sessions.clearOwnedOperationMarker(sessionId, operationId);
    lease.release();
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
