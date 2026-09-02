import { randomUUID } from "node:crypto";
import { lstat, mkdir, readdir, rm } from "node:fs/promises";
import { join } from "node:path";
import { GatewayError } from "../errors.js";
import { AsyncMutex } from "../util/async-mutex.js";
import { durableAtomicWriteJson, durableRemove } from "../util/durable-json.js";
import { readSecureJson, SecureJsonFileError } from "../util/secure-json.js";
import {
  AUTOMATION_FAILURE_CIRCUIT_LIMIT,
  MAXIMUM_AUTOMATION_AGGREGATE_BYTES,
  MAXIMUM_AUTOMATION_HISTORY,
  MAXIMUM_AUTOMATION_RECORD_BYTES,
  MAXIMUM_AUTOMATIONS,
  admitsAutomationRecord,
} from "./automation-contract.js";
import { firstAutomationOccurrence, nextAutomationOccurrence } from "./schedule.js";
import type {
  AutomationCreateInput,
  AutomationRecord,
  AutomationRun,
  AutomationSummary,
  AutomationUpdateInput,
} from "./types.js";

const canonicalName = /^([0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12})\.json$/iu;
const ownedTemporaryName = /^[0-9a-f-]{36}\.json\.\d+\.[0-9a-f]{12}\.tmp$/iu;
const MAINTENANCE_INTENT = "maintenance-intent.json";
const MAXIMUM_MAINTENANCE_INTENT_BYTES = 128 * 1_024;

interface TargetRekeyIntent {
  version: 1;
  kind: "target-rekey";
  previousSessionId: string;
  nextSessionId: string;
  automationIds: string[];
}

interface TargetBlockIntent {
  version: 1;
  kind: "target-block";
  sessionId: string;
  reason: string;
  automationIds: string[];
}

type MaintenanceIntent = TargetRekeyIntent | TargetBlockIntent;

export interface AutomationStoreStatus {
  ready: boolean;
  degraded: boolean;
  automationCount: number;
  aggregateBytes: number;
  malformedRecordCount: number;
  catalogRevision: number;
}

export interface AutomationStoreOptions {
  now?: () => number;
  changed?: (automationId?: string) => void;
}

function clone<T>(value: T): T {
  return structuredClone(value);
}

function serializedBytes(value: unknown): number {
  return Buffer.byteLength(`${JSON.stringify(value, null, 2)}\n`);
}

function boundedHistory(history: AutomationRun[]): AutomationRun[] {
  return history.slice(-MAXIMUM_AUTOMATION_HISTORY);
}

function summarizeRun(run: AutomationRun | undefined): AutomationSummary["currentRun"] | undefined {
  if (!run) return undefined;
  return {
    runId: run.runId,
    state: run.state,
    scheduledFor: run.scheduledFor,
    ...(run.startedAt === undefined ? {} : { startedAt: run.startedAt }),
    ...(run.reason === undefined ? {} : { reason: run.reason }),
  };
}

export function automationSummary(record: AutomationRecord): AutomationSummary {
  const currentRun = summarizeRun(record.currentRun);
  const last = summarizeRun(record.lastRun);
  return {
    id: record.id,
    revision: record.revision,
    stateRevision: record.stateRevision,
    name: record.name,
    activation: record.activation,
    actionKind: record.action.kind,
    targetSessionId: record.targetSessionId,
    trigger: clone(record.trigger),
    ...(record.nextOccurrenceAt === undefined ? {} : { nextOccurrenceAt: record.nextOccurrenceAt }),
    ...(currentRun === undefined ? {} : { currentRun }),
    ...(last === undefined ? {} : { lastRun: { ...last, ...(record.lastRun?.terminalAt ? { terminalAt: record.lastRun.terminalAt } : {}) } }),
    consecutiveFailureCount: record.consecutiveFailureCount,
    ...(record.blockedReason === undefined ? {} : { blockedReason: record.blockedReason }),
    createdAt: record.createdAt,
    updatedAt: record.updatedAt,
  };
}

function isAutomationIdList(value: unknown): value is string[] {
  return Array.isArray(value) && value.length <= MAXIMUM_AUTOMATIONS
    && value.every((id) => typeof id === "string" && canonicalName.test(`${id}.json`));
}

function isMaintenanceIntent(value: unknown): value is MaintenanceIntent {
  if (!value || typeof value !== "object" || Array.isArray(value)) return false;
  const intent = value as Record<string, unknown>;
  if (intent.version !== 1 || !isAutomationIdList(intent.automationIds)) return false;
  if (intent.kind === "target-rekey") {
    const keys = Object.keys(intent);
    return keys.length === 5 && keys.every((key) => ["version", "kind", "previousSessionId", "nextSessionId", "automationIds"].includes(key))
      && typeof intent.previousSessionId === "string" && Buffer.byteLength(intent.previousSessionId) > 0 && Buffer.byteLength(intent.previousSessionId) <= 200
      && typeof intent.nextSessionId === "string" && Buffer.byteLength(intent.nextSessionId) > 0 && Buffer.byteLength(intent.nextSessionId) <= 200;
  }
  if (intent.kind === "target-block") {
    const keys = Object.keys(intent);
    return keys.length === 5 && keys.every((key) => ["version", "kind", "sessionId", "reason", "automationIds"].includes(key))
      && typeof intent.sessionId === "string" && Buffer.byteLength(intent.sessionId) > 0 && Buffer.byteLength(intent.sessionId) <= 200
      && typeof intent.reason === "string" && Buffer.byteLength(intent.reason) > 0 && Buffer.byteLength(intent.reason) <= 256;
  }
  return false;
}

export class AutomationStore {
  private readonly directory: string;
  private readonly mutex = new AsyncMutex();
  private readonly records = new Map<string, AutomationRecord>();
  private readonly bytes = new Map<string, number>();
  private readonly occupiedIds = new Set<string>();
  private readonly terminalReservations = new Map<string, number>();
  private unavailableBytes = 0;
  private readonly now: () => number;
  private readonly changed: (automationId?: string) => void;
  private initialized = false;
  private degraded = false;
  private malformedRecordCount = 0;
  private catalogRevision = 0;

  constructor(tronHome: string, options: AutomationStoreOptions = {}) {
    this.directory = join(tronHome, "gateway", "automations");
    this.now = options.now ?? Date.now;
    this.changed = options.changed ?? (() => {});
  }

  async initialize(): Promise<void> {
    await this.mutex.run(async () => {
      if (this.initialized) return;
      await mkdir(this.directory, { recursive: true, mode: 0o700 });
      const directory = await lstat(this.directory);
      const ownerUid = process.getuid?.();
      if (!directory.isDirectory() || ownerUid === undefined || directory.uid !== ownerUid || (directory.mode & 0o077) !== 0) {
        throw new GatewayError("conflict", "Automation storage is not an owner-only directory");
      }
      const names = await readdir(this.directory);
      for (const name of names) {
        if (ownedTemporaryName.test(name)) {
          await rm(join(this.directory, name), { force: true });
          continue;
        }
        const match = canonicalName.exec(name);
        if (!match) continue;
        const id = match[1]!;
        this.occupiedIds.add(id);
        let physicalBytes = 0;
        try { physicalBytes = (await lstat(join(this.directory, name))).size; } catch {}
        try {
          const stored = await readSecureJson<unknown>(join(this.directory, name), MAXIMUM_AUTOMATION_RECORD_BYTES);
          if (!stored.present || !admitsAutomationRecord(stored.value) || stored.value.id !== id) {
            this.malformedRecordCount += 1;
            this.degraded = true;
            continue;
          }
          if (this.records.has(id)) {
            this.malformedRecordCount += 1;
            this.degraded = true;
            continue;
          }
          this.records.set(id, clone(stored.value));
          const bytes = serializedBytes(stored.value);
          this.bytes.set(id, bytes);
          this.terminalReservations.set(id, this.terminalReservation(stored.value, bytes));
        } catch (error) {
          if (error instanceof SecureJsonFileError || error instanceof RangeError) {
            this.malformedRecordCount += 1;
            this.degraded = true;
            continue;
          }
          throw error;
        } finally {
          if (!this.records.has(id)) this.unavailableBytes += physicalBytes;
        }
      }
      if (this.occupiedIds.size > MAXIMUM_AUTOMATIONS || this.aggregateBytes() + this.reservedTerminalBytes() > MAXIMUM_AUTOMATION_AGGREGATE_BYTES) {
        throw new GatewayError("conflict", "Automation storage exceeds its bounded capacity");
      }
      await this.resumeMaintenanceIntent();
      this.catalogRevision += 1;
      this.initialized = true;
    });
  }

  status(): AutomationStoreStatus {
    return {
      ready: this.initialized,
      degraded: this.degraded,
      automationCount: this.records.size,
      aggregateBytes: this.aggregateBytes() + this.reservedTerminalBytes(),
      malformedRecordCount: this.malformedRecordCount,
      catalogRevision: this.catalogRevision,
    };
  }

  list(): AutomationSummary[] {
    this.assertInitialized();
    return [...this.records.values()].map(automationSummary)
      .sort((left, right) => left.createdAt.localeCompare(right.createdAt) || left.id.localeCompare(right.id));
  }

  get(id: string): AutomationRecord {
    this.assertInitialized();
    const value = this.records.get(id);
    if (!value) throw new GatewayError("not_found", "Automation was not found");
    return clone(value);
  }

  snapshot(): AutomationRecord[] {
    this.assertInitialized();
    return [...this.records.values()].map(clone);
  }

  async create(input: AutomationCreateInput): Promise<AutomationRecord> {
    return this.mutex.run(async () => {
      this.assertInitialized();
      if (this.occupiedIds.size >= MAXIMUM_AUTOMATIONS) throw new GatewayError("busy", "Automation capacity is full", true);
      let id = randomUUID();
      while (this.occupiedIds.has(id)) id = randomUUID();
      const now = new Date(this.now()).toISOString();
      const record: AutomationRecord = {
        schemaVersion: 1,
        id,
        revision: 1,
        stateRevision: 1,
        name: input.name,
        ...(input.description === undefined ? {} : { description: input.description }),
        activation: input.activation ?? "draft",
        createdAt: now,
        updatedAt: now,
        provenance: clone(input.provenance),
        targetSessionId: input.targetSessionId,
        trigger: clone(input.trigger),
        misfirePolicy: input.misfirePolicy ?? "latest",
        overlapPolicy: input.overlapPolicy ?? "skip",
        executionDeadlineSeconds: input.executionDeadlineSeconds ?? 60 * 60,
        action: clone(input.action),
        consecutiveFailureCount: 0,
        history: [],
      };
      if (record.activation === "enabled") {
        const nextOccurrenceAt = firstAutomationOccurrence(input.trigger, this.now());
        if (nextOccurrenceAt !== undefined) record.nextOccurrenceAt = nextOccurrenceAt;
      }
      await this.publishNew(record);
      return clone(record);
    });
  }

  async replace(id: string, expectedRevision: number, input: AutomationUpdateInput): Promise<AutomationRecord> {
    return this.definitionMutation(id, expectedRevision, (current) => {
      const next = clone(current);
      next.name = input.name;
      if (input.description === undefined) delete next.description;
      else next.description = input.description;
      next.targetSessionId = input.targetSessionId;
      next.trigger = clone(input.trigger);
      next.misfirePolicy = input.misfirePolicy;
      next.overlapPolicy = input.overlapPolicy;
      next.executionDeadlineSeconds = input.executionDeadlineSeconds;
      next.action = clone(input.action);
      if (current.activation === "enabled") {
        const occurrence = firstAutomationOccurrence(input.trigger, this.now());
        if (occurrence === undefined) delete next.nextOccurrenceAt;
        else next.nextOccurrenceAt = occurrence;
      }
      return next;
    });
  }

  async setActivation(id: string, expectedRevision: number, activation: "enabled" | "paused"): Promise<AutomationRecord> {
    return this.definitionMutation(id, expectedRevision, (current) => {
      const next = clone(current);
      next.activation = activation;
      delete next.blockedReason;
      delete next.queuedLatestOccurrence;
      if (activation === "enabled") {
        if (current.blockedReason === "outcome-unknown") {
          throw new GatewayError("conflict", "Resolve the uncertain run before enabling this automation");
        }
        next.consecutiveFailureCount = 0;
        const occurrence = firstAutomationOccurrence(current.trigger, this.now());
        if (occurrence === undefined) delete next.nextOccurrenceAt;
        else next.nextOccurrenceAt = occurrence;
      } else {
        delete next.nextOccurrenceAt;
      }
      return next;
    });
  }

  async resolveUnknown(
    id: string,
    expectedRevision: number,
    runId: string,
    outcome: "succeeded" | "failed" | "cancelled",
    provenance: AutomationRecord["provenance"],
  ): Promise<AutomationRecord> {
    return this.definitionMutation(id, expectedRevision, (current) => {
      const uncertain = current.lastRun?.runId === runId && current.lastRun.state === "outcomeUnknown"
        ? current.lastRun : current.history.find((run) => run.runId === runId && run.state === "outcomeUnknown");
      if (!uncertain) throw new GatewayError("conflict", "Automation run is not awaiting an outcome resolution");
      const resolvedAt = new Date(this.now()).toISOString();
      const resolveRun = (run: AutomationRun): AutomationRun => run.runId !== runId ? run : {
        ...run,
        state: outcome,
        resolution: { outcome, resolvedAt, provenance: clone(provenance) },
      };
      const next = clone(current);
      if (next.lastRun) next.lastRun = resolveRun(next.lastRun);
      next.history = next.history.map(resolveRun);
      next.activation = "enabled";
      next.consecutiveFailureCount = outcome === "failed" ? 1 : 0;
      delete next.blockedReason;
      if (next.trigger.kind === "once") {
        delete next.nextOccurrenceAt;
        next.activation = "completed";
      } else {
        const occurrence = nextAutomationOccurrence(next.trigger, this.now());
        if (occurrence === undefined) throw new Error("Recurring automation did not produce a future occurrence");
        next.nextOccurrenceAt = occurrence;
      }
      return next;
    });
  }

  async delete(id: string, expectedRevision: number): Promise<void> {
    await this.mutex.run(async () => {
      this.assertInitialized();
      const current = this.requireCurrent(id);
      this.assertRevision(current, expectedRevision);
      if (current.currentRun) throw new GatewayError("conflict", "Cancel the active automation run before deleting it", true);
      await durableRemove(this.path(id));
      this.records.delete(id);
      this.bytes.delete(id);
      this.terminalReservations.delete(id);
      this.occupiedIds.delete(id);
      this.didChange(id);
    });
  }

  /** Internal scheduler mutation. Definition revision remains stable. */
  async mutateState(id: string, update: (current: AutomationRecord) => AutomationRecord): Promise<AutomationRecord> {
    return this.mutex.run(async () => {
      this.assertInitialized();
      const current = this.requireCurrent(id);
      const next = update(clone(current));
      if (next.id !== id || next.revision !== current.revision || next.schemaVersion !== 1) {
        throw new Error("Automation state mutation changed immutable definition identity");
      }
      next.stateRevision = current.stateRevision + 1;
      next.updatedAt = new Date(this.now()).toISOString();
      next.history = boundedHistory(next.history);
      await this.publishReplacement(current, next);
      return clone(next);
    });
  }

  async blockTarget(sessionId: string, reason = "target-session-deleted"): Promise<string[]> {
    return this.mutex.run(async () => {
      this.assertInitialized();
      const automationIds = [...this.records.values()]
        .filter((record) => record.targetSessionId === sessionId && record.activation !== "completed")
        .map((record) => record.id);
      if (automationIds.length === 0) return [];
      const intent: TargetBlockIntent = { version: 1, kind: "target-block", sessionId, reason, automationIds };
      await durableAtomicWriteJson(join(this.directory, MAINTENANCE_INTENT), intent);
      await this.applyBlockIntent(intent);
      await durableRemove(join(this.directory, MAINTENANCE_INTENT));
      this.didChange();
      return automationIds;
    });
  }

  async rekeyTarget(previousSessionId: string, nextSessionId: string): Promise<void> {
    await this.mutex.run(async () => {
      this.assertInitialized();
      const ids = [...this.records.values()].filter((record) => record.targetSessionId === previousSessionId).map((record) => record.id);
      if (ids.length === 0) return;
      const intent: TargetRekeyIntent = { version: 1, kind: "target-rekey", previousSessionId, nextSessionId, automationIds: ids };
      await durableAtomicWriteJson(join(this.directory, MAINTENANCE_INTENT), intent);
      await this.applyRekeyIntent(intent);
      await durableRemove(join(this.directory, MAINTENANCE_INTENT));
      this.didChange();
    });
  }

  private async definitionMutation(
    id: string,
    expectedRevision: number,
    update: (current: AutomationRecord) => AutomationRecord,
  ): Promise<AutomationRecord> {
    return this.mutex.run(async () => {
      this.assertInitialized();
      const current = this.requireCurrent(id);
      this.assertRevision(current, expectedRevision);
      const next = update(clone(current));
      next.revision = current.revision + 1;
      next.stateRevision = current.stateRevision + 1;
      next.updatedAt = new Date(this.now()).toISOString();
      const normalized = JSON.parse(JSON.stringify(next)) as AutomationRecord;
      await this.publishReplacement(current, normalized);
      return clone(normalized);
    });
  }

  private async publishNew(record: AutomationRecord): Promise<void> {
    this.trimHistoryToRecordBound(record);
    if (!admitsAutomationRecord(record)) throw new Error("Automation record failed its canonical contract");
    const bytes = serializedBytes(record);
    this.requireCapacity(record, bytes);
    await durableAtomicWriteJson(this.path(record.id), record);
    this.records.set(record.id, clone(record));
    this.bytes.set(record.id, bytes);
    this.terminalReservations.set(record.id, this.terminalReservation(record, bytes));
    this.occupiedIds.add(record.id);
    this.didChange(record.id);
  }

  private async publishReplacement(current: AutomationRecord, next: AutomationRecord, notify = true): Promise<void> {
    this.trimHistoryToRecordBound(next);
    if (!admitsAutomationRecord(next)) throw new Error("Automation record failed its canonical contract");
    const bytes = serializedBytes(next);
    this.requireCapacity(next, bytes);
    await durableAtomicWriteJson(this.path(next.id), next);
    this.records.set(next.id, clone(next));
    this.bytes.set(next.id, bytes);
    this.terminalReservations.set(next.id, this.terminalReservation(next, bytes));
    if (notify) this.didChange(next.id);
  }

  private requireCapacity(record: AutomationRecord, recordBytes: number): void {
    const currentBytes = this.bytes.get(record.id) ?? 0;
    const currentReservation = this.terminalReservations.get(record.id) ?? 0;
    const reservation = this.terminalReservation(record, recordBytes);
    const total = this.aggregateBytes() - currentBytes + recordBytes
      + this.reservedTerminalBytes() - currentReservation + reservation;
    if (recordBytes > MAXIMUM_AUTOMATION_RECORD_BYTES || total > MAXIMUM_AUTOMATION_AGGREGATE_BYTES) {
      throw new GatewayError("busy", "Automation storage capacity is full", true);
    }
  }

  private trimHistoryToRecordBound(record: AutomationRecord): void {
    record.history = boundedHistory(record.history);
    while (record.history.length > 0 && serializedBytes(record) > MAXIMUM_AUTOMATION_RECORD_BYTES) {
      record.history.shift();
    }
  }

  private terminalReservation(record: AutomationRecord, recordBytes: number): number {
    const run = record.currentRun;
    if (!run) return 0;
    const projected = clone(record);
    const terminal: AutomationRun = {
      ...clone(run),
      state: "outcomeUnknown",
      terminalAt: run.terminalAt ?? new Date(this.now()).toISOString(),
      reason: run.reason ?? "reserved-terminal-settlement",
    };
    delete projected.currentRun;
    projected.lastRun = terminal;
    projected.history = [...projected.history, terminal];
    this.trimHistoryToRecordBound(projected);
    return Math.max(0, serializedBytes(projected) - recordBytes);
  }

  private reservedTerminalBytes(): number {
    let total = 0;
    for (const bytes of this.terminalReservations.values()) total += bytes;
    return total;
  }

  private aggregateBytes(): number {
    let total = this.unavailableBytes;
    for (const bytes of this.bytes.values()) total += bytes;
    return total;
  }

  private didChange(id?: string): void {
    this.catalogRevision += 1;
    this.changed(id);
  }

  private path(id: string): string {
    if (!canonicalName.test(`${id}.json`)) throw new GatewayError("invalid_request", "Automation identity is invalid");
    return join(this.directory, `${id}.json`);
  }

  private requireCurrent(id: string): AutomationRecord {
    const current = this.records.get(id);
    if (!current) throw new GatewayError("not_found", "Automation was not found");
    return current;
  }

  private assertRevision(current: AutomationRecord, expected: number): void {
    if (!Number.isSafeInteger(expected) || current.revision !== expected) {
      throw new GatewayError("conflict", "Automation changed. Review the latest definition and try again.", true, {
        expectedRevision: expected,
        currentRevision: current.revision,
      });
    }
  }

  private assertInitialized(): void {
    if (!this.initialized) throw new GatewayError("busy", "Automation storage is still recovering", true);
  }

  private async resumeMaintenanceIntent(): Promise<void> {
    const path = join(this.directory, MAINTENANCE_INTENT);
    const stored = await readSecureJson<unknown>(path, MAXIMUM_MAINTENANCE_INTENT_BYTES);
    if (!stored.present) return;
    if (!isMaintenanceIntent(stored.value)) throw new GatewayError("conflict", "Automation maintenance intent is malformed");
    if (stored.value.kind === "target-rekey") await this.applyRekeyIntent(stored.value);
    else await this.applyBlockIntent(stored.value);
    await durableRemove(path);
  }

  private async applyBlockIntent(intent: TargetBlockIntent): Promise<void> {
    for (const id of intent.automationIds) {
      const current = this.records.get(id);
      if (!current || current.activation === "blocked" && current.blockedReason === intent.reason) continue;
      if (current.targetSessionId !== intent.sessionId) {
        throw new GatewayError("conflict", "Automation target changed during target-block recovery");
      }
      const next = clone(current);
      next.revision = current.revision + 1;
      next.stateRevision = current.stateRevision + 1;
      next.activation = "blocked";
      next.blockedReason = intent.reason;
      delete next.nextOccurrenceAt;
      delete next.queuedLatestOccurrence;
      if (next.currentRun) {
        const uncertain = next.currentRun.state === "admitting" || next.currentRun.state === "running"
          || next.currentRun.state === "cancelling";
        const terminal: AutomationRun = {
          ...next.currentRun,
          state: uncertain ? "outcomeUnknown" : "cancelled",
          reason: intent.reason,
          terminalAt: new Date(this.now()).toISOString(),
        };
        delete next.currentRun;
        next.lastRun = terminal;
        next.history = boundedHistory([...next.history, terminal]);
      }
      next.updatedAt = new Date(this.now()).toISOString();
      await this.publishReplacement(current, next, false);
    }
  }

  private async applyRekeyIntent(intent: TargetRekeyIntent): Promise<void> {
    for (const id of intent.automationIds) {
      const current = this.records.get(id);
      if (!current || current.targetSessionId === intent.nextSessionId) continue;
      if (current.targetSessionId !== intent.previousSessionId) {
        throw new GatewayError("conflict", "Automation target changed during session rekey recovery");
      }
      const next: AutomationRecord = {
        ...clone(current),
        targetSessionId: intent.nextSessionId,
        revision: current.revision + 1,
        stateRevision: current.stateRevision + 1,
        updatedAt: new Date(this.now()).toISOString(),
      };
      await this.publishReplacement(current, next, false);
    }
  }
}

export function settleAutomationRun(
  record: AutomationRecord,
  run: AutomationRun,
  now: string,
): AutomationRecord {
  const terminal = { ...clone(run), terminalAt: run.terminalAt ?? now };
  const failure = terminal.state === "failed";
  const consecutiveFailureCount = failure ? record.consecutiveFailureCount + 1 : 0;
  const circuitOpen = consecutiveFailureCount >= AUTOMATION_FAILURE_CIRCUIT_LIMIT;
  const next = clone(record);
  delete next.currentRun;
  next.lastRun = terminal;
  next.history = boundedHistory([...record.history, terminal]);
  next.consecutiveFailureCount = consecutiveFailureCount;
  if (circuitOpen) {
    next.activation = "blocked";
    next.blockedReason = "consecutive-failures";
    delete next.nextOccurrenceAt;
    delete next.queuedLatestOccurrence;
  }
  return next;
}
