import type { RunOperations } from "./run-operations.js";
import { randomUUID } from "node:crypto";
import { GatewayError } from "../../errors.js";
import type { AgentSessionEvent } from "../pi/coding-agent.js";
import type { GatewayWorkHandle } from "./gateway-work-registry.js";

type PendingManualCompaction = {
  instructions?: string;
  operationId: string;
  work: GatewayWorkHandle;
  resolve: () => void;
  reject: (error: unknown) => void;
};

export class ManualCompactionOwner {
  pendingManualCompaction: PendingManualCompaction | undefined;
  private manualCompactionClaim: symbol | undefined;
  queuedManualCompactionInFlight = false;
  adoptedManualCompaction: PendingManualCompaction | undefined;

  constructor(private readonly operations: RunOperations<unknown>) {}

  async compact(instructions?: string): Promise<{ queued: boolean }> {
    this.operations.assertUsable();
    // Refused at admission: Home keeps its own history, and the SDK would only
    // refuse this later, after the command was already accepted.
    if (this.operations.liveProfile().compaction === "disabled") {
      throw new GatewayError("conflict", "Tron Home keeps its own history; manual compaction is unavailable");
    }
    if (this.manualCompactionClaim) {
      throw new GatewayError("busy", "A manual compaction is already pending for this session");
    }
    const claim = Symbol("manual-compaction");
    this.manualCompactionClaim = claim;
    let work: GatewayWorkHandle;
    try {
      work = this.operations.dependencies.workRegistry.begin({
        kind: "compaction-export",
        sessionId: this.operations.id,
        hostEpoch: this.operations.ui.hostEpoch,
      });
    } catch (error) {
      if (this.manualCompactionClaim === claim) this.manualCompactionClaim = undefined;
      throw error;
    }

    const operationId = randomUUID();
    try {
      let queuedCompletion: Promise<void> | undefined;
      const queued = await this.operations.lane.run(async () => {
        this.operations.assertUsable();
        if (this.manualCompactionClaim !== claim) {
          throw new GatewayError("conflict", "Manual compaction ownership changed", true);
        }
        if (this.operations.hasActiveAgentRun) {
          // A run is live, so this hands off behind it rather than starting now.
          // Clears retained archive state only after the ownership rejection
          // above: a compaction that cannot be admitted must not unarchive the
          // session.
          await this.operations.dependencies.beforeRunAdmission(this.operations.id);
          // Accepted maintenance owns its own durable marker, never a prior
          // prompt's. A handoff can be deferred behind more than one run.
          await this.operations.runPersistence.trackOwnershipWrite(
            () => this.operations.runPersistence.retryDurableWrite(`marker:mark:${operationId}`, () => this.operations.dependencies.markers.mark(this.operations.id, operationId)),
            work,
          );
          this.operations.assertUsable();
          queuedCompletion = new Promise<void>((resolve, reject) => {
            this.pendingManualCompaction = {
              ...(instructions === undefined ? {} : { instructions }),
              operationId,
              work,
              resolve,
              reject,
            };
          });
          this.operations.revision += 1;
          this.operations.publishSnapshot();
          // The preceding run may have settled while the marker write awaited.
          this.startPendingManualCompaction();
          return true;
        }

        this.assertIdleForManualCompaction(claim);
        // Only after every rejection above is retained archive state cleared, so
        // a compaction refused here (an export in flight, Bash running) leaves
        // the session archived.
        await this.operations.dependencies.beforeRunAdmission(this.operations.id);
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
    if (!pending || this.operations.shuttingDown) return;
    void this.operations.lane.run(async () => {
      if (this.pendingManualCompaction !== pending || this.operations.shuttingDown) return;
      // Another prompt can enter SDK preflight before this lane handoff runs.
      // Leave the exact compaction pending for that newer run's final settlement.
      if (this.operations.hasActiveAgentRun || this.operations.runAttention.pendingAssistantCompletion || this.operations.runAttention.completionOwnershipQueue.length > 0) return;
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
        this.operations.revision += 1;
        this.operations.publishSnapshot();
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
      await this.operations.runPersistence.trackOwnershipWrite(
        () => this.operations.runPersistence.retryDurableWrite(`marker:mark:${operationId}`, () => this.operations.dependencies.markers.mark(this.operations.id, operationId)),
        work,
      );
    }
    const startedAt = new Date().toISOString();
    this.operations.phase = "compacting";
    this.operations.operation = { id: operationId, kind: "compaction", startedAt, reason: "manual" };
    const compactionOwner = this.operations.operation;
    this.operations.noteDashboardActivity(startedAt);
    if (!this.operations.activityHeartbeat) this.operations.startActivityHeartbeat();
    this.operations.revision += 1;
    this.operations.publishSnapshot();
    try {
      await this.operations.runtime.session.settingsManager.flush();
      this.operations.compactionPolicies.get(this.operations.runtime.session)?.applyBudgets();
      this.operations.contextPolicies.get(this.operations.runtime.session)?.apply();
      await this.operations.runtime.session.compact(instructions);
    } catch (error) {
      operationError = error;
    }

    await this.operations.clearMarkerOwnership(operationId, work);
    if (queued) {
      this.queuedManualCompactionInFlight = false;
      this.operations.hooks.settled(this.operations.id);
    }

    // Stop and a successor can arrive during marker I/O too. Retire the exact
    // cancellation intent after that await, then re-check presentation ownership.
    this.operations.runAbort.abortedOperations.delete(operationId);
    const ownerStillCurrent = this.operations.operationMatches(compactionOwner);
    if (ownerStillCurrent) {
      this.operations.phase = "idle";
      this.operations.operation = undefined;
      this.operations.retry = undefined;
      this.operations.noteDashboardActivity();
      if (!this.operations.hasCurrentDashboardWork()) this.operations.stopActivityHeartbeat();
    }
    this.operations.revision += 1;
    this.operations.publishSnapshot();
    if (operationError !== undefined) throw operationError;
  }

  private assertIdleForManualCompaction(claim: symbol): void {
    this.operations.assertUsable();
    if (this.manualCompactionClaim !== claim) {
      throw new GatewayError("conflict", "Manual compaction ownership changed", true);
    }
    if (this.operations.runtime.session.isStreaming
      || this.operations.activeExports > 0
      || this.queuedManualCompactionInFlight
      || this.operations.effectivePhase === "running"
      || this.operations.effectivePhase === "compacting"
      || this.operations.effectivePhase === "retrying"
      || this.operations.runtime.session.isBashRunning) {
      throw new GatewayError("busy", "Session must be idle for this operation");
    }
  }

  adoptPending(event: Extract<AgentSessionEvent, { type: "compaction_start" }>): PendingManualCompaction | undefined {
    const adoptedManual = this.pendingManualCompaction;
    if (adoptedManual) {
      this.pendingManualCompaction = undefined;
      this.queuedManualCompactionInFlight = true;
      this.adoptedManualCompaction = adoptedManual;
      this.operations.dependencies.manualCompactionAdopted?.({
        sessionId: this.operations.id,
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
          await this.operations.clearMarkerOwnership(adoptedManual.operationId, adoptedManual.work);
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
          if (this.operations.operation?.id === adoptedManual.operationId && !this.operations.hasActiveAgentRun && !this.operations.activeOperationId) {
            this.operations.phase = "idle";
            this.operations.operation = undefined;
          }
          this.operations.hooks.settled(this.operations.id);
          this.operations.publishSnapshot();
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
