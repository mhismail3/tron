import { randomUUID } from "node:crypto";
import { GatewayError } from "../errors.js";
import { automationOperationId } from "./automation-contract.js";
import { AutomationStore, settleAutomationRun } from "./automation-store.js";
import { advanceAfterOccurrence, automationOccurrenceId, classifyDueOccurrence } from "./schedule.js";
import type { AutomationRecord, AutomationRun, AutomationRunState } from "./types.js";

const MAXIMUM_CONCURRENT_AUTOMATIONS = 4;
const MAXIMUM_DISPATCHES_PER_SCAN = 64;
const MAXIMUM_TIMER_DELAY_MS = 60_000;
const MAXIMUM_PRE_ADMISSION_ATTEMPTS = 5;
const CANCELLATION_SETTLEMENT_GRACE_MS = 5_000;

export interface AutomationExecutionResult {
  state: Extract<AutomationRunState, "succeeded" | "failed" | "cancelled" | "outcomeUnknown">;
  reason?: string;
  invocationId?: string;
  assistantCompletionId?: string;
  notificationAdmissionStatus?: AutomationRun["notificationAdmissionStatus"];
  error?: AutomationRun["error"];
}

export interface AutomationExecutionHandle {
  operationId?: string;
  invocationId?: string;
  completion: Promise<AutomationExecutionResult>;
  cancel: (reason: "user-cancelled" | "deadline-exceeded" | "gateway-shutdown") => Promise<void>;
  acknowledgeTerminal?: () => Promise<void>;
}

export type AutomationRecoveryResult = AutomationExecutionResult | { state: "requeue"; reason: string };

export interface AutomationExecutor {
  start(record: AutomationRecord, run: AutomationRun): Promise<AutomationExecutionHandle>;
  recover?(record: AutomationRecord, run: AutomationRun): Promise<AutomationRecoveryResult>;
  acknowledgeRecovery?(record: AutomationRecord, run: AutomationRun): Promise<void>;
  reconcileStoredTerminals?(records: readonly AutomationRecord[]): Promise<void>;
}

export class AutomationAdmissionError extends Error {
  constructor(
    message: string,
    readonly retryable: boolean,
    readonly reason: string,
    readonly busy = false,
  ) {
    super(message);
    this.name = "AutomationAdmissionError";
  }
}

export interface AutomationSchedulerOptions {
  now?: () => number;
  hostEpoch: string;
  setTimer?: (callback: () => void, delay: number) => NodeJS.Timeout;
  clearTimer?: (timer: NodeJS.Timeout) => void;
  maximumConcurrent?: number;
  random?: () => number;
  onDiagnostic?: (message: string, automationId: string, runId?: string) => void;
  onBlocked?: (record: AutomationRecord, run: AutomationRun) => Promise<void> | void;
}

interface ActiveExecution {
  automationId: string;
  runId: string;
  handle: AutomationExecutionHandle;
  deadline?: NodeJS.Timeout;
  cancellation?: Promise<void>;
  cancellationReason?: "user-cancelled" | "deadline-exceeded" | "gateway-shutdown";
  settled: Promise<void>;
  resolveSettled: () => void;
}

function clone<T>(value: T): T { return structuredClone(value); }

function terminalRun(
  run: AutomationRun,
  result: AutomationExecutionResult,
  now: string,
): AutomationRun {
  return {
    ...clone(run),
    state: result.state,
    terminalAt: now,
    ...(result.reason === undefined ? {} : { reason: result.reason }),
    ...(result.invocationId === undefined ? {} : { invocationId: result.invocationId }),
    ...(result.assistantCompletionId === undefined ? {} : { assistantCompletionId: result.assistantCompletionId }),
    ...(result.notificationAdmissionStatus === undefined ? {} : { notificationAdmissionStatus: result.notificationAdmissionStatus }),
    ...(result.error === undefined ? {} : { error: result.error }),
  };
}

export class AutomationScheduler {
  private readonly now: () => number;
  private readonly setTimer: NonNullable<AutomationSchedulerOptions["setTimer"]>;
  private readonly clearTimer: NonNullable<AutomationSchedulerOptions["clearTimer"]>;
  private readonly maximumConcurrent: number;
  private readonly random: () => number;
  private readonly onDiagnostic: NonNullable<AutomationSchedulerOptions["onDiagnostic"]>;
  private readonly onBlocked: NonNullable<AutomationSchedulerOptions["onBlocked"]>;
  private readonly active = new Map<string, ActiveExecution>();
  private readonly dispatchReservations = new Map<string, string>();
  private readonly pendingDispatches = new Set<Promise<void>>();
  private readonly cancellationRequests = new Map<string, "user-cancelled" | "gateway-shutdown">();
  private readonly settlementWaiters = new Map<string, { promise: Promise<void>; resolve: () => void }>();
  private timer: NodeJS.Timeout | undefined;
  private scanPromise: Promise<void> | undefined;
  private started = false;
  private admissionOpen = false;

  constructor(
    private readonly store: AutomationStore,
    private readonly executor: AutomationExecutor,
    private readonly options: AutomationSchedulerOptions,
  ) {
    this.now = options.now ?? Date.now;
    this.setTimer = options.setTimer ?? ((callback, delay) => setTimeout(callback, delay));
    this.clearTimer = options.clearTimer ?? clearTimeout;
    this.maximumConcurrent = options.maximumConcurrent ?? MAXIMUM_CONCURRENT_AUTOMATIONS;
    this.random = options.random ?? Math.random;
    this.onDiagnostic = options.onDiagnostic ?? (() => {});
    this.onBlocked = options.onBlocked ?? (() => {});
    if (!Number.isSafeInteger(this.maximumConcurrent) || this.maximumConcurrent < 1 || this.maximumConcurrent > 64) {
      throw new Error("Automation concurrency bound is invalid");
    }
  }

  async recover(): Promise<void> {
    if (this.started) throw new Error("Automation recovery must finish before the scheduler starts");
    const records = this.store.snapshot();
    await this.executor.reconcileStoredTerminals?.(records);
    for (const record of records) {
      const run = record.currentRun;
      if (!run || run.state === "queued" || run.state === "waiting") continue;
      let result: AutomationRecoveryResult;
      try {
        result = this.executor.recover
          ? await this.executor.recover(record, run)
          : { state: "outcomeUnknown", reason: "gateway-restarted-without-terminal-evidence" };
      } catch (error) {
        result = {
          state: "outcomeUnknown",
          reason: "recovery-failed",
          error: { code: "recovery-failed", message: error instanceof Error ? error.message.slice(0, 1_024) : "Automation recovery failed", retryable: false },
        };
      }
      if (result.state === "requeue") {
        await this.store.mutateState(record.id, (current) => {
          if (current.currentRun?.runId !== run.runId) return current;
          const queued = clone(current.currentRun);
          queued.state = "queued";
          queued.reason = result.reason;
          delete queued.claimedAt;
          delete queued.claimId;
          delete queued.hostEpoch;
          delete queued.retryAt;
          delete queued.startedAt;
          return { ...current, currentRun: queued };
        });
      } else {
        await this.commitTerminal(record.id, run.runId, result);
        await this.executor.acknowledgeRecovery?.(record, run);
      }
    }
  }

  start(): void {
    if (this.started) return;
    this.started = true;
    this.admissionOpen = true;
    this.wake();
  }

  wake(): void {
    if (!this.started || !this.admissionOpen) return;
    if (this.timer) this.clearTimer(this.timer);
    this.timer = undefined;
    queueMicrotask(() => void this.scan());
  }

  beginDrain(): void {
    this.admissionOpen = false;
    if (this.timer) this.clearTimer(this.timer);
    this.timer = undefined;
  }

  async cancelActiveForShutdown(): Promise<void> {
    this.beginDrain();
    await Promise.allSettled([...this.active.values()].map((active) => this.requestCancellation(active, "gateway-shutdown")));
  }

  async dispose(): Promise<void> {
    this.beginDrain();
    await Promise.allSettled([
      ...this.pendingDispatches,
      ...[...this.active.values()].map((active) => active.handle.completion),
    ]);
  }

  async scan(): Promise<void> {
    if (!this.started || !this.admissionOpen) return;
    if (this.scanPromise) return this.scanPromise;
    this.scanPromise = this.performScan();
    try {
      await this.scanPromise;
    } finally {
      this.scanPromise = undefined;
      this.arm();
    }
  }

  async runNow(automationId: string, expectedRevision: number): Promise<AutomationRun> {
    if (!this.admissionOpen) throw new GatewayError("busy", "Automation dispatch is draining", true);
    let created: AutomationRun | undefined;
    const updated = await this.store.mutateState(automationId, (current) => {
      if (current.revision !== expectedRevision) {
        throw new GatewayError("conflict", "Automation changed. Review it before running it.", true);
      }
      if (current.currentRun) throw new GatewayError("busy", "Automation already has an active run", true);
      if (current.activation === "blocked") throw new GatewayError("conflict", "Resolve the blocked automation before running it");
      const scheduledFor = new Date(this.now()).toISOString();
      created = this.makeRun(current, scheduledFor, `manual:${randomUUID()}`);
      return { ...current, currentRun: created };
    });
    this.wake();
    return clone(created ?? updated.currentRun!);
  }

  async cancel(automationId: string, runId: string): Promise<AutomationRun> {
    const record = this.store.get(automationId);
    const run = record.currentRun;
    if (!run || run.runId !== runId) throw new GatewayError("conflict", "Automation run is no longer active", true);
    const active = this.active.get(runId);
    if (!active && (run.state === "queued" || run.state === "waiting")) {
      await this.commitTerminal(record.id, run.runId, { state: "cancelled", reason: "user-cancelled" });
      this.wake();
      return clone(this.store.get(record.id).lastRun!);
    }
    if (!active) {
      this.cancellationRequests.set(runId, "user-cancelled");
      const settlement = this.settlementFor(runId);
      await this.store.mutateState(record.id, (current) => {
        if (current.currentRun?.runId !== runId) return current;
        return { ...current, currentRun: { ...current.currentRun, state: "cancelling", reason: "user-cancelled" } };
      });
      await settlement.promise;
      const settled = this.store.get(automationId);
      if (settled.lastRun?.runId !== runId) {
        throw new GatewayError("conflict", "Automation cancellation did not reach durable terminal state", true, { outcomeUnknown: true });
      }
      return clone(settled.lastRun);
    }
    const settlement = this.settlementFor(runId);
    await this.store.mutateState(record.id, (current) => {
      if (current.currentRun?.runId !== runId) return current;
      return { ...current, currentRun: { ...current.currentRun, state: "cancelling", reason: "user-cancelled" } };
    });
    await this.requestCancellationWithGrace(active, "user-cancelled");
    await settlement.promise;
    const settled = this.store.get(automationId);
    if (settled.lastRun?.runId !== runId) {
      throw new GatewayError("conflict", "Automation cancellation did not reach durable terminal state", true, { outcomeUnknown: true });
    }
    return clone(settled.lastRun);
  }

  private async performScan(): Promise<void> {
    await this.materializeDueRuns();
    const candidates = this.store.snapshot()
      .filter((record) => record.currentRun
        && (record.activation === "enabled" || record.currentRun.occurrenceId.startsWith("manual:"))
        && (record.currentRun.state === "queued" || record.currentRun.state === "waiting")
        && (record.currentRun.retryAt === undefined || Date.parse(record.currentRun.retryAt) <= this.now()))
      .sort((left, right) => left.currentRun!.scheduledFor.localeCompare(right.currentRun!.scheduledFor) || left.id.localeCompare(right.id));
    const activeSessions = new Set([
      ...[...this.active.values()].map((entry) => this.store.get(entry.automationId).targetSessionId),
      ...this.dispatchReservations.values(),
    ]);
    let dispatched = 0;
    for (const record of candidates) {
      if (!this.admissionOpen
        || this.active.size + this.dispatchReservations.size >= this.maximumConcurrent
        || dispatched >= MAXIMUM_DISPATCHES_PER_SCAN) break;
      const runId = record.currentRun!.runId;
      if (activeSessions.has(record.targetSessionId) || this.dispatchReservations.has(runId)) continue;
      activeSessions.add(record.targetSessionId);
      this.dispatchReservations.set(runId, record.targetSessionId);
      dispatched += 1;
      let task!: Promise<void>;
      task = this.dispatch(record).catch((error) => {
        this.onDiagnostic(error instanceof Error ? error.message : String(error), record.id, record.currentRun?.runId);
      }).finally(() => {
        this.dispatchReservations.delete(runId);
        this.pendingDispatches.delete(task);
        this.wake();
      });
      this.pendingDispatches.add(task);
    }
  }

  private async materializeDueRuns(): Promise<void> {
    const now = this.now();
    for (const record of this.store.snapshot()) {
      if (record.activation !== "enabled" || !record.nextOccurrenceAt || Date.parse(record.nextOccurrenceAt) > now) continue;
      const classified = classifyDueOccurrence(record.trigger, record.nextOccurrenceAt, now, record.misfirePolicy);
      await this.store.mutateState(record.id, (current) => {
        if (current.stateRevision !== record.stateRevision || current.activation !== "enabled") return current;
        const next = clone(current);
        if (classified.nextOccurrenceAt === undefined) delete next.nextOccurrenceAt;
        else next.nextOccurrenceAt = classified.nextOccurrenceAt;
        const due = classified.dispatchAt ?? classified.skipped[0];
        if (!due) return next;
        if (current.currentRun) {
          if (current.overlapPolicy === "queueLatest" && classified.dispatchAt) next.queuedLatestOccurrence = classified.dispatchAt;
          else {
            const skipped = this.makeRun(current, due, automationOccurrenceId(current.id, current.revision, due));
            skipped.state = "skipped";
            skipped.reason = current.currentRun ? "overlap" : "misfire";
            skipped.terminalAt = new Date(now).toISOString();
            next.lastRun = skipped;
            next.history = [...next.history, skipped];
          }
          return next;
        }
        if (!classified.dispatchAt) {
          const skipped = this.makeRun(current, due, automationOccurrenceId(current.id, current.revision, due));
          skipped.state = "skipped";
          skipped.reason = "misfire";
          skipped.terminalAt = new Date(now).toISOString();
          return settleAutomationRun(next, skipped, skipped.terminalAt);
        }
        next.currentRun = this.makeRun(current, classified.dispatchAt,
          automationOccurrenceId(current.id, current.revision, classified.dispatchAt));
        return next;
      });
    }
  }

  private makeRun(record: AutomationRecord, scheduledFor: string, occurrenceId: string): AutomationRun {
    const runId = randomUUID();
    return {
      runId,
      occurrenceId,
      automationRevision: record.revision,
      scheduledFor,
      triggerSnapshot: clone(record.trigger),
      actionSnapshot: clone(record.action),
      state: "queued",
      createdAt: new Date(this.now()).toISOString(),
      preAdmissionAttemptCount: 0,
      operationId: automationOperationId(runId),
    };
  }

  private async dispatch(candidate: AutomationRecord): Promise<void> {
    const run = candidate.currentRun!;
    const claimId = randomUUID();
    const claimedAt = new Date(this.now()).toISOString();
    const claimed = await this.store.mutateState(candidate.id, (current) => {
      if (current.currentRun?.runId !== run.runId
        || (current.currentRun.state !== "queued" && current.currentRun.state !== "waiting")) return current;
      const next = clone(current);
      next.currentRun = {
        ...current.currentRun,
        state: "admitting",
        claimedAt,
        hostEpoch: this.options.hostEpoch,
        claimId,
      };
      delete next.currentRun.retryAt;
      return next;
    });
    if (claimed.currentRun?.claimId !== claimId) return;

    let handle: AutomationExecutionHandle;
    try {
      handle = await this.executor.start(claimed, claimed.currentRun);
    } catch (error) {
      if (this.cancellationRequests.delete(run.runId)) {
        await this.commitTerminal(claimed.id, run.runId, { state: "cancelled", reason: "user-cancelled" });
      } else {
        await this.handleAdmissionFailure(claimed.id, claimed.currentRun, error);
      }
      this.wake();
      return;
    }

    const running = await this.store.mutateState(claimed.id, (current) => {
      if (current.currentRun?.runId !== run.runId || current.currentRun.claimId !== claimId) return current;
      const cancellation = this.cancellationRequests.get(run.runId);
      return {
        ...current,
        currentRun: {
          ...current.currentRun,
          state: cancellation ? "cancelling" : "running",
          startedAt: new Date(this.now()).toISOString(),
          ...(handle.operationId === undefined ? {} : { operationId: handle.operationId }),
          ...(handle.invocationId === undefined ? {} : { invocationId: handle.invocationId }),
        },
      };
    });
    if (running.currentRun?.runId !== run.runId) {
      // A durable state owner retired this run while admission was suspended.
      // Keep the reservation until the exact runtime owner settles; only then
      // may its marker/lease/work token be acknowledged and released.
      await handle.cancel("gateway-shutdown").catch((error) => {
        this.onDiagnostic(error instanceof Error ? error.message : String(error), claimed.id, run.runId);
      });
      await handle.completion.catch((error) => {
        this.onDiagnostic(error instanceof Error ? error.message : String(error), claimed.id, run.runId);
      });
      if (handle.acknowledgeTerminal) {
        await this.retryTerminalSettlement(handle.acknowledgeTerminal, claimed.id, run.runId, "retired admission acknowledgement");
      }
      const waiter = this.settlementWaiters.get(run.runId);
      if (waiter) {
        this.settlementWaiters.delete(run.runId);
        waiter.resolve();
      }
      return;
    }

    let resolveSettled!: () => void;
    const settled = new Promise<void>((resolve) => { resolveSettled = resolve; });
    const active: ActiveExecution = { automationId: claimed.id, runId: run.runId, handle, settled, resolveSettled };
    const deadlineMs = running.executionDeadlineSeconds * 1_000;
    active.deadline = this.setTimer(() => {
      void this.markCancellingAndCancel(active, "deadline-exceeded");
    }, deadlineMs);
    active.deadline.unref?.();
    this.active.set(run.runId, active);
    this.dispatchReservations.delete(run.runId);
    const pendingCancellation = this.cancellationRequests.get(run.runId);
    if (pendingCancellation) void this.requestCancellationWithGrace(active, pendingCancellation);

    let result: AutomationExecutionResult;
    try {
      result = await handle.completion;
    } catch (error) {
      result = {
        state: "outcomeUnknown",
        reason: "executor-completion-rejected",
        error: { code: "executor-completion-rejected", message: error instanceof Error ? error.message.slice(0, 1_024) : "Execution completion failed", retryable: false },
      };
    }
    if (active.deadline) this.clearTimer(active.deadline);
    if (result.state === "cancelled" && active.cancellationReason === "deadline-exceeded") {
      result = {
        state: "failed",
        reason: "deadline-exceeded",
        ...(result.invocationId === undefined ? {} : { invocationId: result.invocationId }),
        error: { code: "deadline-exceeded", message: "Automation exceeded its execution deadline", retryable: false },
      };
    }
    try {
      await this.retryTerminalSettlement(
        () => this.commitTerminal(claimed.id, run.runId, result),
        claimed.id,
        run.runId,
        "terminal record",
      );
      if (handle.acknowledgeTerminal) {
        await this.retryTerminalSettlement(handle.acknowledgeTerminal, claimed.id, run.runId, "terminal acknowledgement");
      }
    } finally {
      this.active.delete(run.runId);
      this.cancellationRequests.delete(run.runId);
      active.resolveSettled();
    }
    this.wake();
  }

  private async handleAdmissionFailure(automationId: string, run: AutomationRun, error: unknown): Promise<void> {
    const admission = error instanceof AutomationAdmissionError
      ? error
      : new AutomationAdmissionError(error instanceof Error ? error.message : "Automation admission failed", false, "admission-failed");
    const attempt = run.preAdmissionAttemptCount + (admission.busy ? 0 : 1);
    if (admission.retryable && (admission.busy || attempt < MAXIMUM_PRE_ADMISSION_ATTEMPTS)) {
      const nominal = admission.busy ? 5_000 : Math.min(5 * 60_000, 5_000 * 2 ** Math.max(0, attempt - 1));
      const backoff = Math.round(nominal * (0.8 + Math.min(1, Math.max(0, this.random())) * 0.4));
      await this.store.mutateState(automationId, (current) => {
        if (current.currentRun?.runId !== run.runId) return current;
        const waiting = { ...current.currentRun, state: "waiting" as const, reason: admission.reason,
          preAdmissionAttemptCount: attempt, retryAt: new Date(this.now() + backoff).toISOString() };
        delete waiting.claimId;
        delete waiting.claimedAt;
        delete waiting.hostEpoch;
        return { ...current, currentRun: waiting };
      });
      return;
    }
    await this.commitTerminal(automationId, run.runId, {
      state: "failed",
      reason: admission.reason,
      error: { code: admission.reason, message: admission.message.slice(0, 1_024), retryable: admission.retryable },
    });
  }

  private async commitTerminal(automationId: string, runId: string, result: AutomationExecutionResult): Promise<void> {
    const now = new Date(this.now()).toISOString();
    try {
      const settled = await this.store.mutateState(automationId, (current) => {
        if (current.currentRun?.runId !== runId) return current;
        const terminal = terminalRun(current.currentRun, result, now);
        const next = settleAutomationRun(current, terminal, now);
        if (terminal.state === "outcomeUnknown") {
          next.activation = "blocked";
          next.blockedReason = "outcome-unknown";
          delete next.nextOccurrenceAt;
          delete next.queuedLatestOccurrence;
          return next;
        }
        if (next.queuedLatestOccurrence && next.activation === "enabled") {
          const scheduledFor = next.queuedLatestOccurrence;
          delete next.queuedLatestOccurrence;
          next.currentRun = this.makeRun(next, scheduledFor, automationOccurrenceId(next.id, next.revision, scheduledFor));
        } else if (next.trigger.kind === "once" && !next.currentRun) {
          next.activation = "completed";
        }
        return next;
      });
      if (settled.activation === "blocked" && settled.lastRun?.runId === runId) {
        void Promise.resolve(this.onBlocked(settled, settled.lastRun)).catch((error) => {
          this.onDiagnostic(error instanceof Error ? error.message : String(error), automationId, runId);
        });
      }
    } finally {
      const waiter = this.settlementWaiters.get(runId);
      if (waiter) {
        this.settlementWaiters.delete(runId);
        waiter.resolve();
      }
    }
  }

  private async retryTerminalSettlement(
    operation: () => Promise<void>,
    automationId: string,
    runId: string,
    label: string,
  ): Promise<void> {
    let delay = 250;
    while (true) {
      try {
        await operation();
        return;
      } catch (error) {
        this.onDiagnostic(
          `Automation ${label} failed and will retry: ${error instanceof Error ? error.message : String(error)}`,
          automationId,
          runId,
        );
        await new Promise<void>((resolve) => { const timer = setTimeout(resolve, delay); timer.unref(); });
        delay = Math.min(30_000, delay * 2);
      }
    }
  }

  private settlementFor(runId: string): { promise: Promise<void>; resolve: () => void } {
    const existing = this.settlementWaiters.get(runId);
    if (existing) return existing;
    let resolve!: () => void;
    const promise = new Promise<void>((settled) => { resolve = settled; });
    const created = { promise, resolve };
    this.settlementWaiters.set(runId, created);
    return created;
  }

  private async markCancellingAndCancel(active: ActiveExecution, reason: "deadline-exceeded"): Promise<void> {
    await this.store.mutateState(active.automationId, (current) => {
      if (current.currentRun?.runId !== active.runId) return current;
      return { ...current, currentRun: { ...current.currentRun, state: "cancelling", reason } };
    }).catch(() => {});
    await this.requestCancellationWithGrace(active, reason);
  }

  private async requestCancellationWithGrace(
    active: ActiveExecution,
    reason: "user-cancelled" | "deadline-exceeded" | "gateway-shutdown",
  ): Promise<void> {
    try {
      await this.requestCancellation(active, reason);
    } catch (error) {
      await this.commitTerminal(active.automationId, active.runId, {
        state: "outcomeUnknown",
        reason: `${reason}-cancellation-failed`,
        error: {
          code: "cancellation-failed",
          message: error instanceof Error ? error.message.slice(0, 1_024) : "Automation cancellation failed",
          retryable: false,
        },
      });
      return;
    }
    let timer: NodeJS.Timeout | undefined;
    const graceExpired = new Promise<false>((resolve) => {
      timer = this.setTimer(() => resolve(false), CANCELLATION_SETTLEMENT_GRACE_MS);
      timer.unref?.();
    });
    const completionSettled = active.handle.completion.then(() => true as const, () => true as const);
    const settled = await Promise.race([completionSettled, graceExpired]);
    if (timer) this.clearTimer(timer);
    if (!settled) {
      await this.commitTerminal(active.automationId, active.runId, {
        state: "outcomeUnknown",
        reason: `${reason}-settlement-timeout`,
        error: {
          code: "cancellation-settlement-timeout",
          message: "Automation cancellation did not settle within its bounded grace period",
          retryable: false,
        },
      });
    }
  }

  private requestCancellation(
    active: ActiveExecution,
    reason: "user-cancelled" | "deadline-exceeded" | "gateway-shutdown",
  ): Promise<void> {
    active.cancellationReason ??= reason;
    active.cancellation ??= Promise.resolve().then(() => active.handle.cancel(reason));
    return active.cancellation;
  }

  private arm(): void {
    if (!this.started || !this.admissionOpen || this.timer) return;
    const retryTimes = this.store.snapshot().flatMap((record) => record.currentRun?.retryAt ? [Date.parse(record.currentRun.retryAt)] : []);
    const dueTimes = this.store.snapshot().flatMap((record) => record.activation === "enabled" && record.nextOccurrenceAt
      ? [Date.parse(record.nextOccurrenceAt)] : []);
    const nearest = [...retryTimes, ...dueTimes].sort((left, right) => left - right)[0];
    const delay = nearest === undefined ? MAXIMUM_TIMER_DELAY_MS : Math.max(0, Math.min(MAXIMUM_TIMER_DELAY_MS, nearest - this.now()));
    this.timer = this.setTimer(() => {
      this.timer = undefined;
      void this.scan();
    }, delay);
    this.timer.unref?.();
  }
}
