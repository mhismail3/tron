import { GatewayError } from "../errors.js";
import { admitAutomationCreateInput, admitAutomationUpdateInput } from "./automation-contract.js";
import { AutomationScheduler } from "./automation-scheduler.js";
import { AutomationStore } from "./automation-store.js";
import type { AutomationProvenance, AutomationRecord, AutomationRun, AutomationRunSummary, AutomationSummary } from "./types.js";

export interface AutomationTargetValidator {
  requirePersistedUserSession(sessionId: string): Promise<void>;
}

export interface AutomationPage {
  catalogRevision: number;
  items: AutomationSummary[];
}

export class AutomationService {
  constructor(
    readonly store: AutomationStore,
    readonly scheduler: AutomationScheduler,
    private readonly targets: AutomationTargetValidator,
  ) {}

  async initialize(): Promise<void> {
    await this.store.initialize();
    await this.reconcileTargets();
    await this.scheduler.recover();
    this.scheduler.start();
  }

  beginDrain(): void { this.scheduler.beginDrain(); }
  async requestShutdownCancellation(): Promise<void> { await this.scheduler.cancelActiveForShutdown(); }
  async dispose(): Promise<void> { await this.scheduler.dispose(); }

  status(): ReturnType<AutomationStore["status"]> {
    return this.store.status();
  }

  list(): AutomationPage {
    return { catalogRevision: this.store.status().catalogRevision, items: this.store.list() };
  }

  get(id: string): AutomationRecord { return this.store.get(id); }

  runList(id: string): AutomationRunSummary[] {
    const record = this.store.get(id);
    return [
      ...(record.currentRun ? [record.currentRun] : []),
      ...record.history.slice().reverse(),
    ].map((run) => ({
      runId: run.runId,
      state: run.state,
      scheduledFor: run.scheduledFor,
      createdAt: run.createdAt,
      preAdmissionAttemptCount: run.preAdmissionAttemptCount,
      ...(run.startedAt === undefined ? {} : { startedAt: run.startedAt }),
      ...(run.terminalAt === undefined ? {} : { terminalAt: run.terminalAt }),
      ...(run.reason === undefined ? {} : { reason: run.reason }),
      ...(run.notificationAdmissionStatus === undefined ? {} : { notificationAdmissionStatus: run.notificationAdmissionStatus }),
    }));
  }

  runGet(id: string, runId: string): AutomationRun {
    const record = this.store.get(id);
    const run = [record.currentRun, ...record.history].find((candidate) => candidate?.runId === runId);
    if (!run) throw new GatewayError("not_found", "Automation run was not found");
    return structuredClone(run);
  }

  async create(raw: unknown, provenance: AutomationProvenance): Promise<AutomationRecord> {
    const input = admitAutomationCreateInput(raw, provenance);
    await this.targets.requirePersistedUserSession(input.targetSessionId);
    const record = await this.store.create(input);
    this.scheduler.wake();
    return record;
  }

  async update(id: string, expectedRevision: number, raw: unknown): Promise<AutomationRecord> {
    const input = admitAutomationUpdateInput(raw);
    await this.targets.requirePersistedUserSession(input.targetSessionId);
    const record = await this.store.replace(id, expectedRevision, input);
    this.scheduler.wake();
    return record;
  }

  async enable(id: string, expectedRevision: number): Promise<AutomationRecord> {
    const current = this.store.get(id);
    await this.targets.requirePersistedUserSession(current.targetSessionId);
    const record = await this.store.setActivation(id, expectedRevision, "enabled");
    this.scheduler.wake();
    return record;
  }

  async pause(id: string, expectedRevision: number): Promise<AutomationRecord> {
    const record = await this.store.setActivation(id, expectedRevision, "paused");
    this.scheduler.wake();
    return record;
  }

  async delete(id: string, expectedRevision: number): Promise<void> {
    await this.store.delete(id, expectedRevision);
    this.scheduler.wake();
  }

  async runNow(id: string, expectedRevision: number): Promise<AutomationRun> {
    const current = this.store.get(id);
    if (current.revision !== expectedRevision) throw new GatewayError("conflict", "Automation changed. Review it before running it.", true);
    await this.targets.requirePersistedUserSession(current.targetSessionId);
    return this.scheduler.runNow(id, expectedRevision);
  }

  async cancel(id: string, runId: string): Promise<AutomationRun> {
    return this.scheduler.cancel(id, runId);
  }

  async resolve(
    id: string,
    runId: string,
    expectedRevision: number,
    outcome: "succeeded" | "failed" | "cancelled",
    provenance: AutomationProvenance,
  ): Promise<AutomationRecord> {
    const resolved = await this.store.resolveUnknown(id, expectedRevision, runId, outcome, provenance);
    this.scheduler.wake();
    return resolved;
  }

  async blockSessionTarget(sessionId: string): Promise<void> {
    await this.store.blockTarget(sessionId);
    this.scheduler.wake();
  }

  async rekeySessionTarget(previousSessionId: string, nextSessionId: string): Promise<void> {
    await this.store.rekeyTarget(previousSessionId, nextSessionId);
    this.scheduler.wake();
  }

  private async reconcileTargets(): Promise<void> {
    for (const record of this.store.snapshot()) {
      if (record.activation === "completed") continue;
      try {
        await this.targets.requirePersistedUserSession(record.targetSessionId);
      } catch (error) {
        if (error instanceof GatewayError && (error.code === "busy" || error.code === "internal")) throw error;
        await this.store.blockTarget(record.targetSessionId, "target-session-unavailable");
      }
    }
  }
}
