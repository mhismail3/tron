import { GatewayError } from "../errors.js";
import { admitAutomationCreateInput, admitAutomationUpdateInput, admitsAutomationTrigger } from "./automation-contract.js";
import { AutomationScheduler } from "./automation-scheduler.js";
import { AutomationStore } from "./automation-store.js";
import type { AutomationProvenance, AutomationRecord, AutomationRun, AutomationRunSummary, AutomationSummary, AutomationTrigger } from "./types.js";
import { nextAutomationOccurrence } from "./schedule.js";
import { isGatewayTimestamp } from "../util/timestamp.js";
import {
  buildAutomationTimeline,
  type AutomationTimelinePage,
  AutomationTimelinePaginationStore,
  validateTimelineWindow,
} from "./automation-timeline.js";

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
    private readonly timelinePages = new AutomationTimelinePaginationStore(),
  ) {}

  async initialize(): Promise<void> {
    await this.store.initialize();
    await this.reconcileTargets();
    await this.scheduler.recover();
    this.scheduler.start();
  }

  releaseClient(clientId: string): void { this.timelinePages.releaseClient(clientId); }

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

  schedulePreview(rawTrigger: unknown, after: string, limit: number): { occurrences: string[] } {
    if (!admitsAutomationTrigger(rawTrigger)) throw new GatewayError("invalid_request", "Automation trigger is invalid");
    if (!Number.isSafeInteger(limit) || limit < 1 || limit > 20) {
      throw new GatewayError("invalid_request", "Preview limit must be between 1 and 20");
    }
    const afterMs = Date.parse(after);
    if (!isGatewayTimestamp(after) || !Number.isFinite(afterMs)) throw new GatewayError("invalid_request", "Preview after must be a Gateway timestamp");
    const trigger = rawTrigger as AutomationTrigger;
    const occurrences: string[] = [];
    let boundary = afterMs;
    while (occurrences.length < limit) {
      const next = nextAutomationOccurrence(trigger, boundary);
      if (next === undefined) break;
      occurrences.push(next);
      const nextMs = Date.parse(next);
      if (!Number.isFinite(nextMs) || nextMs <= boundary) break;
      boundary = nextMs;
    }
    return { occurrences };
  }

  timelinePage(
    clientId: string,
    from: string,
    through: string,
    displayTimezone: string,
    cursor: string | undefined,
    limit: number,
  ): AutomationTimelinePage {
    validateTimelineWindow(from, through, displayTimezone);
    const sourcePage = this.list();
    const source = buildAutomationTimeline(sourcePage.items, sourcePage.catalogRevision, from, through, displayTimezone);
    return this.timelinePages.page(clientId, source, cursor, limit);
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
