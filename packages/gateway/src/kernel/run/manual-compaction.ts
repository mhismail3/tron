import { randomUUID } from "node:crypto";
import { GatewayError } from "../../errors.js";
import type { AgentSession, AgentSessionEvent } from "../pi/coding-agent.js";
import type { SessionOperationState, SessionPhase, RetryState } from "../../protocol/types.js";
import type { SessionProfile } from "../host/session-profile.js";
import type { AsyncMutex } from "../../util/async-mutex.js";
import type { GatewayWorkHandle, GatewayWorkRegistry } from "./gateway-work-registry.js";
import type { RunPersistence } from "./run-persistence.js";
import type { RunAbortOwner } from "./run-abort-owner.js";
import type { CompactionOperationPolicy } from "./compaction-policy.js";
import type { SessionContextWindowPolicy } from "../../providers/context-window-policy.js";

type PendingManualCompaction = {
  instructions?: string;
  operationId: string;
  work: GatewayWorkHandle;
  resolve: () => void;
  reject: (error: unknown) => void;
};

export interface ManualCompactionContext {
  readonly id: string;
  readonly ui: { hostEpoch: string };
  readonly lane: Pick<AsyncMutex, "run">;
  readonly runtime: { session: AgentSession };
  readonly dependencies: {
    workRegistry: GatewayWorkRegistry;
    markers: { mark(sessionId: string, operationId: string): Promise<void> };
    beforeRunAdmission(sessionId: string): Promise<void>;
    manualCompactionAdopted?: (diagnostic: { sessionId: string; operationId: string; reason: "manual" | "threshold" | "overflow" }) => void;
  };
  readonly hooks: { settled(sessionId: string): void };
  readonly runPersistence: RunPersistence;
  readonly runAbort: Pick<RunAbortOwner, "abortedOperations">;
  readonly compactionPolicies: Pick<WeakMap<AgentSession, CompactionOperationPolicy>, "get">;
  readonly contextPolicies: Pick<WeakMap<AgentSession, SessionContextWindowPolicy>, "get">;
  readonly shuttingDown: boolean;
  readonly hasActiveAgentRun: boolean;
  readonly pendingAssistantCompletion: unknown;
  readonly completionOwnershipQueue: readonly unknown[];
  readonly activeOperationId: string | undefined;
  readonly activeExports: number;
  readonly effectivePhase: SessionPhase;
  readonly activityHeartbeat: unknown;
  phase: SessionPhase;
  operation: SessionOperationState | undefined;
  retry: RetryState | undefined;
  revision: number;
  liveProfile(): Pick<SessionProfile, "compaction">;
  assertUsable(): void;
  clearMarkerOwnership(operationId: string, work: GatewayWorkHandle): Promise<void>;
  operationMatches(operation: SessionOperationState): boolean;
  noteDashboardActivity(startedAt?: string): void;
  startActivityHeartbeat(): void;
  hasCurrentDashboardWork(): boolean;
  stopActivityHeartbeat(): void;
  publishSnapshot(): void;
}

export class ManualCompactionOwner {
  pendingManualCompaction: PendingManualCompaction | undefined;
  private manualCompactionClaim: symbol | undefined;
  queuedManualCompactionInFlight = false;
  adoptedManualCompaction: PendingManualCompaction | undefined;

  constructor(private readonly context: ManualCompactionContext) {}

  async compact(instructions?: string): Promise<{ queued: boolean }> {
    this.context.assertUsable();
    // Refused at admission: Home keeps its own history, and the SDK would only
    // refuse this later, after the command was already accepted.
    if (this.context.liveProfile().compaction === "disabled") {
      throw new GatewayError("conflict", "Tron Home keeps its own history; manual compaction is unavailable");
    }
    if (this.manualCompactionClaim) {
      throw new GatewayError("busy", "A manual compaction is already pending for this session");
    }
    const claim = Symbol("manual-compaction");
    this.manualCompactionClaim = claim;
    let work: GatewayWorkHandle;
    try {
      work = this.context.dependencies.workRegistry.begin({
        kind: "compaction-export",
        sessionId: this.context.id,
        hostEpoch: this.context.ui.hostEpoch,
      });
    } catch (error) {
      if (this.manualCompactionClaim === claim) this.manualCompactionClaim = undefined;
      throw error;
    }

    const operationId = randomUUID();
    try {
      let queuedCompletion: Promise<void> | undefined;
      const queued = await this.context.lane.run(async () => {
        this.context.assertUsable();
        if (this.manualCompactionClaim !== claim) {
          throw new GatewayError("conflict", "Manual compaction ownership changed", true);
        }
        if (this.context.hasActiveAgentRun) {
          // A run is live, so this hands off behind it rather than starting now.
          // Clears retained archive state only after the ownership rejection
          // above: a compaction that cannot be admitted must not unarchive the
          // session.
          await this.context.dependencies.beforeRunAdmission(this.context.id);
          // Accepted maintenance owns its own durable marker, never a prior
          // prompt's. A handoff can be deferred behind more than one run.
          await this.context.runPersistence.trackOwnershipWrite(
            () => this.context.runPersistence.retryDurableWrite(`marker:mark:${operationId}`, () => this.context.dependencies.markers.mark(this.context.id, operationId)),
            work,
          );
          this.context.assertUsable();
          queuedCompletion = new Promise<void>((resolve, reject) => {
            this.pendingManualCompaction = {
              ...(instructions === undefined ? {} : { instructions }),
              operationId,
              work,
              resolve,
              reject,
            };
          });
          this.context.revision += 1;
          this.context.publishSnapshot();
          // The preceding run may have settled while the marker write awaited.
          this.startPendingManualCompaction();
          return true;
        }

        this.assertIdleForManualCompaction(claim);
        // Only after every rejection above is retained archive state cleared, so
        // a compaction refused here (an export in flight, Bash running) leaves
        // the session archived.
        await this.context.dependencies.beforeRunAdmission(this.context.id);
        await this.performManualCompaction(instructions, false, operationId, work);
        return false;
      });

      // Keep the command receipt pending until the exact queued mutation has
      // completed. A disconnected client therefore cannot turn accepted work
      // into an acknowledged-but-unperformed compaction.
      if (queuedCompletion) await queuedCompletion;
      return { queued };
    } finally {
      if (this.manualCompactionClaim === claim) this.manualCompactionClaim = undefined;
      work.settle();
    }
  }

  startPendingManualCompaction(): void {
    const pending = this.pendingManualCompaction;
    if (!pending || this.context.shuttingDown) return;
    void this.context.lane.run(async () => {
      if (this.pendingManualCompaction !== pending || this.context.shuttingDown) return;
      // Another prompt can enter SDK preflight before this lane handoff runs.
      // Leave the exact compaction pending for that newer run's final settlement.
      if (this.context.hasActiveAgentRun || this.context.pendingAssistantCompletion || this.context.completionOwnershipQueue.length > 0) return;
      this.pendingManualCompaction = undefined;
      this.queuedManualCompactionInFlight = true;
      try {
        await this.performManualCompaction(pending.instructions, true, pending.operationId, pending.work);
        pending.resolve();
      } catch (error) {
        pending.reject(error);
      }
    }).catch((error) => {
      if (this.pendingManualCompaction === pending) {
        this.pendingManualCompaction = undefined;
        this.context.revision += 1;
        this.context.publishSnapshot();
      }
      pending.reject(error);
    });
  }

  private async performManualCompaction(
    instructions: string | undefined,
    queued: boolean,
    operationId: string,
    work: GatewayWorkHandle,
  ): Promise<void> {
    let operationError: unknown;
    if (!queued) {
      await this.context.runPersistence.trackOwnershipWrite(
        () => this.context.runPersistence.retryDurableWrite(`marker:mark:${operationId}`, () => this.context.dependencies.markers.mark(this.context.id, operationId)),
        work,
      );
    }
    const startedAt = new Date().toISOString();
    this.context.phase = "compacting";
    this.context.operation = { id: operationId, kind: "compaction", startedAt, reason: "manual" };
    const compactionOwner = this.context.operation;
    this.context.noteDashboardActivity(startedAt);
    if (!this.context.activityHeartbeat) this.context.startActivityHeartbeat();
    this.context.revision += 1;
    this.context.publishSnapshot();
    try {
      await this.context.runtime.session.settingsManager.flush();
      this.context.compactionPolicies.get(this.context.runtime.session)?.applyBudgets();
      this.context.contextPolicies.get(this.context.runtime.session)?.apply();
      await this.context.runtime.session.compact(instructions);
    } catch (error) {
      operationError = error;
    }

    await this.context.clearMarkerOwnership(operationId, work);
    if (queued) {
      this.queuedManualCompactionInFlight = false;
      this.context.hooks.settled(this.context.id);
    }

    // Stop and a successor can arrive during marker I/O too. Retire the exact
    // cancellation intent after that await, then re-check presentation ownership.
    this.context.runAbort.abortedOperations.delete(operationId);
    const ownerStillCurrent = this.context.operationMatches(compactionOwner);
    if (ownerStillCurrent) {
      this.context.phase = "idle";
      this.context.operation = undefined;
      this.context.retry = undefined;
      this.context.noteDashboardActivity();
      if (!this.context.hasCurrentDashboardWork()) this.context.stopActivityHeartbeat();
    }
    this.context.revision += 1;
    this.context.publishSnapshot();
    if (operationError !== undefined) throw operationError;
  }

  private assertIdleForManualCompaction(claim: symbol): void {
    this.context.assertUsable();
    if (this.manualCompactionClaim !== claim) {
      throw new GatewayError("conflict", "Manual compaction ownership changed", true);
    }
    if (this.context.runtime.session.isStreaming
      || this.context.activeExports > 0
      || this.queuedManualCompactionInFlight
      || this.context.effectivePhase === "running"
      || this.context.effectivePhase === "compacting"
      || this.context.effectivePhase === "retrying"
      || this.context.runtime.session.isBashRunning) {
      throw new GatewayError("busy", "Session must be idle for this operation");
    }
  }

  adoptPending(event: Extract<AgentSessionEvent, { type: "compaction_start" }>): PendingManualCompaction | undefined {
    const adoptedManual = this.pendingManualCompaction;
    if (adoptedManual) {
      this.pendingManualCompaction = undefined;
      this.queuedManualCompactionInFlight = true;
      this.adoptedManualCompaction = adoptedManual;
      this.context.dependencies.manualCompactionAdopted?.({
        sessionId: this.context.id,
        operationId: adoptedManual.operationId,
        reason: event.reason,
      });
    }
    return adoptedManual;
  }

  settleAdopted(outcome: "success" | "cancelled" | "failure", errorMessage: string | undefined): void {
    const adoptedManual = this.adoptedManualCompaction;
    if (adoptedManual) {
      void (async () => {
        try {
          await this.context.clearMarkerOwnership(adoptedManual.operationId, adoptedManual.work);
          // The accepted command owns the first compaction after it queued;
          // if that compaction fails or is cancelled, settle it as failed
          // rather than launching a second manual compaction.
          if (outcome === "success") adoptedManual.resolve();
          else adoptedManual.reject(new GatewayError(
            outcome === "cancelled" ? "conflict" : "internal",
            errorMessage ?? (outcome === "cancelled" ? "Adopted compaction was cancelled" : "Adopted compaction failed"),
            outcome === "cancelled",
          ));
        } catch (error) {
          adoptedManual.reject(error);
        } finally {
          if (this.adoptedManualCompaction === adoptedManual) this.adoptedManualCompaction = undefined;
          this.queuedManualCompactionInFlight = false;
          if (this.context.operation?.id === adoptedManual.operationId && !this.context.hasActiveAgentRun && !this.context.activeOperationId) {
            this.context.phase = "idle";
            this.context.operation = undefined;
          }
          this.context.hooks.settled(this.context.id);
          this.context.publishSnapshot();
          adoptedManual.work.settle();
        }
      })();
    }
  }

  cancelPending(error: unknown): void {
    const pending = this.pendingManualCompaction;
    if (pending) {
      this.pendingManualCompaction = undefined;
      pending.reject(error);
    }
  }

  finishShutdown(cancellation: unknown): void {
    this.cancelPending(cancellation);
    this.queuedManualCompactionInFlight = false;
  }
}
