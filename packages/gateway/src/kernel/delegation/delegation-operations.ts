import type { HomeTaskReportOwner } from "./task-report.js";
import type { TaskWorkerControl } from "./worker-contract.js";
import { interruptTaskWorker, stopTaskWorker, steerTaskWorker, taskWorkerSteeringInput } from "./worker-control.js";

/** Internal runaway ceiling for callers that explicitly opt into deadline ownership. */
export const OWNED_OPERATION_DEADLINE_MS = 24 * 60 * 60 * 1_000;

type OwnedLease<Session> = { slot: Session; release: () => void };
/** Native session authority: retain its lease and rebind its worker under the
 * existing lane/rebuild operation, never through a second runtime or state copy. */
type OwnedSession = {
  retainLease(): () => void;
  bindTaskWorker(report: HomeTaskReportOwner, exceptWorkToken?: string): Promise<void>;
  readonly taskWorker?: HomeTaskReportOwner | undefined;
  prompt(...input: ReturnType<typeof taskWorkerSteeringInput>): Promise<unknown>;
};
type InterruptWorkerTools<Session> = (slot: Session, by: string, before?: () => Promise<void>) => Promise<string[]>;
/** The session runtime's owned-session operations (RuntimeRegistry implements them). The
 * run owner imports delegation, so the session handle and recovery evidence stay its types. */
export interface OwnedSessions<Session extends OwnedSession, Evidence> {
  acquire(sessionId: string): Promise<Session>;
  create(cwd: string, profile: "ordinary", report: HomeTaskReportOwner): Promise<Session>;
  acquireOwnedSessionLease(sessionId: string): Promise<OwnedLease<Session>>;
  ownedOperationRecoveryEvidence(sessionId: string, operationId: string): Promise<Evidence>;
  clearOwnedOperationMarker(sessionId: string, operationId: string): Promise<void>;
}
/** The dispatch over one implementer, for a field typed before construction. */
export type DelegationOperationsOver<Sessions> = Sessions extends OwnedSessions<infer Session, infer Evidence> ? DelegationOperations<Session, Evidence> : never;
type OperationHandle<T> = {
  operationId: string;
  completion: Promise<T>;
  cancel: (reason?: string) => Promise<void>;
};
/** One armed deadline. Its signal aborts at the fixed ceiling; `disarm` releases the timer. */
export interface OwnedOperationDeadline { readonly signal: AbortSignal; readonly armedAt: number; disarm: () => void }

/** One kernel service owns worker lease/control/deadline orchestration. Native
 * session/run authorities keep their lane, canonical evidence and work tokens. */
export class DelegationOperations<Session extends OwnedSession, Evidence> {
  constructor(private readonly sessions: OwnedSessions<Session, Evidence>,
    private readonly interruptTools: InterruptWorkerTools<Session>) {}

  async steerWorker(sessionId: string, control: TaskWorkerControl, text: string): Promise<void> {
    const slot = await this.sessions.acquire(sessionId);
    await steerTaskWorker(control, text, input => slot.prompt(...input));
  }

  async interruptWorker(sessionId: string, control: TaskWorkerControl, by: string, text?: string): Promise<string[]> {
    const slot = await this.sessions.acquire(sessionId);
    // K5 validates the exact operation before native I/O fixes its tool targets.
    return await interruptTaskWorker(slot.taskWorker, control,
      () => this.interruptTools(slot, by,
        text === undefined ? undefined : async () => { await steerTaskWorker(control, text, input => slot.prompt(...input)); }));
  }

  async stopWorker(sessionId: string, control: TaskWorkerControl): Promise<void> {
    await stopTaskWorker((await this.sessions.acquire(sessionId)).taskWorker, control);
  }

  async createWorker(cwd: string, report: HomeTaskReportOwner): Promise<OwnedLease<Session>> {
    const slot = await this.sessions.create(cwd, "ordinary", report);
    return { slot, release: slot.retainLease() };
  }

  /** Rebinds an existing worker session to a resumed task's report owner (#929). */
  async resumeWorker(sessionId: string, report: HomeTaskReportOwner, exceptWorkToken?: string): Promise<OwnedLease<Session>> {
    const lease = await this.sessions.acquireOwnedSessionLease(sessionId);
    try {
      await lease.slot.bindTaskWorker(report, exceptWorkToken);
      return lease;
    } catch (error) { lease.release(); throw error; }
  }

  lease(sessionId: string): Promise<OwnedLease<Session>> {
    return this.sessions.acquireOwnedSessionLease(sessionId);
  }

  recoveryEvidence(sessionId: string, operationId: string): Promise<Evidence> {
    return this.sessions.ownedOperationRecoveryEvidence(sessionId, operationId);
  }

  admit<Args extends unknown[], Admission>(slot: Session & { prompt(...args: Args): Admission }, ...args: Args): Admission {
    return slot.prompt(...args);
  }

  async acknowledge(sessionId: string, operationId: string, lease: OwnedLease<Session>): Promise<void> {
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
