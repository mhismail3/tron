import { createHash, randomUUID } from "node:crypto";
import { lstat, mkdir, rm } from "node:fs/promises";
import { join } from "node:path";
import type { TronWorkspace } from "../workspace/tron-workspace.js";
import { GatewayError } from "../errors.js";
import { AsyncMutex } from "../util/async-mutex.js";
import { durableAtomicWriteJson, durableRemove } from "../util/durable-json.js";
import { readSecureJson, SecureJsonFileError } from "../util/secure-json.js";
import {
  DEFAULT_KNOWLEDGE_CONFIG,
  KNOWLEDGE_SCHEMA_VERSION,
  type KnowledgeConfig,
  type KnowledgeEvidenceRef,
  type KnowledgeListRequest,
  type KnowledgeListResponse,
  type KnowledgeObjectRef,
  type KnowledgeRecallRequest,
  type KnowledgeRecallResponse,
  type KnowledgeRecord,
  type KnowledgeRecordDraft,
  type KnowledgeSearchRequest,
  type KnowledgeSearchResponse,
  type KnowledgeSearchHit,
  type KnowledgeSourceCaptureRequest,
  type KnowledgeNoteMutationRequest,
  type ObservationCoverage,
  type ObservationRange,
  validateKnowledgeConfig,
  validateKnowledgeRecord,
  validateObjectRef,
  assertKnowledgeId,
} from "./knowledge-contract.js";

const STATE_MAX_BYTES = 32 * 1_048_576;
const OBJECT_MAX_BYTES = 8_000_000;
const RECEIPT_LIMIT = 256;
const OBJECT_SCHEMA_VERSION = 1 as const;

type RecordHistory = { latestRevisionId: string; revisions: Record<string, KnowledgeRecord> };
type Suppression = { excluded: boolean; forgotten: boolean; reason?: string; updatedAt: string };
type MutationReceipt = { operation: string; requestHash: string; result: unknown; createdAt: string };
interface KnowledgeState {
  schemaVersion: typeof KNOWLEDGE_SCHEMA_VERSION;
  stateRevision: number;
  records: Record<string, RecordHistory>;
  coverage: Record<string, ObservationCoverage>;
  suppressions: Record<string, Suppression>;
  cleanup: string[];
  receipts: Record<string, MutationReceipt>;
  config: KnowledgeConfig;
}
interface StoredObject { schemaVersion: typeof OBJECT_SCHEMA_VERSION; hash: string; mediaType: string; bytes: number; data: string; }

export type KnowledgeStateFailure = "unsafe" | "invalid" | "newer";
export class KnowledgeStoreError extends Error {
  constructor(readonly kind: KnowledgeStateFailure, message: string) { super(message); this.name = "KnowledgeStoreError"; }
}

export interface ObservationGroupInput {
  commandId: string;
  expectedCoverageRevision?: string;
  coverage: Omit<ObservationCoverage, "schemaVersion" | "revisionId" | "groupRevisionIds" | "recordedAt"> & { disposition: "observed" | "empty" | "excluded" };
  records: Array<KnowledgeRecordDraft & { kind: "observation" }>;
}

export interface CoverageUpdateInput {
  commandId: string;
  expectedRevision?: string;
  coverage: Omit<ObservationCoverage, "schemaVersion" | "revisionId" | "recordedAt">;
}

export interface KnowledgeMutationResult { record: KnowledgeRecord; stateRevision: number; }
export interface KnowledgeForgetResult { forgotten: true; recordId: string; stateRevision: number; }
export interface KnowledgeReconcileResult { removedObjects: string[]; pendingObjects: string[]; stateRevision: number; }

function conflict(message: string): GatewayError { return new GatewayError("conflict", message); }
function invalid(message: string): GatewayError { return new GatewayError("invalid_request", message); }
function requestHash(operation: string, request: unknown): string {
  return createHash("sha256").update(operation).update("\0").update(JSON.stringify(request)).digest("hex");
}
function now(): string { return new Date().toISOString(); }
function revisionId(): string { return randomUUID(); }
function recordId(): string { return randomUUID(); }

function safeId(value: string, label: string): void {
  assertKnowledgeId(value, label);
}

async function safeDirectory(path: string, create: boolean): Promise<void> {
  if (create) {
    try { await mkdir(path, { recursive: true, mode: 0o700 }); }
    catch { throw new KnowledgeStoreError("unsafe", `Knowledge directory cannot be created: ${path}`); }
  }
  let info;
  try { info = await lstat(path); }
  catch { throw new KnowledgeStoreError("unsafe", `Knowledge directory is unavailable: ${path}`); }
  if (!info.isDirectory() || info.isSymbolicLink() || info.uid !== process.getuid?.() || (info.mode & 0o777) !== 0o700) {
    throw new KnowledgeStoreError("unsafe", "Knowledge state directory must be an owner-only real directory");
  }
}

function emptyState(): KnowledgeState {
  return { schemaVersion: KNOWLEDGE_SCHEMA_VERSION, stateRevision: 0, records: {}, coverage: {}, suppressions: {}, cleanup: [], receipts: {}, config: structuredClone(DEFAULT_KNOWLEDGE_CONFIG) };
}

function validateState(value: unknown): KnowledgeState {
  if (!value || typeof value !== "object" || Array.isArray(value)) throw new KnowledgeStoreError("invalid", "Knowledge state is not an object");
  const state = value as Record<string, unknown>;
  if (state.schemaVersion !== KNOWLEDGE_SCHEMA_VERSION) {
    throw new KnowledgeStoreError(typeof state.schemaVersion === "number" && state.schemaVersion > KNOWLEDGE_SCHEMA_VERSION ? "newer" : "invalid", "Unsupported knowledge state schema");
  }
  if (!Number.isSafeInteger(state.stateRevision) || (state.stateRevision as number) < 0) throw new KnowledgeStoreError("invalid", "Invalid knowledge state revision");
  if (!state.records || typeof state.records !== "object" || Array.isArray(state.records)) throw new KnowledgeStoreError("invalid", "Invalid knowledge records");
  for (const [id, historyValue] of Object.entries(state.records as Record<string, unknown>)) {
    safeId(id, "record id");
    if (!historyValue || typeof historyValue !== "object" || Array.isArray(historyValue)) throw new KnowledgeStoreError("invalid", "Invalid record history");
    const history = historyValue as Record<string, unknown>;
    if (typeof history.latestRevisionId !== "string" || !history.revisions || typeof history.revisions !== "object" || Array.isArray(history.revisions)) throw new KnowledgeStoreError("invalid", "Invalid record revisions");
    const revisions = history.revisions as Record<string, unknown>;
    if (!revisions[history.latestRevisionId]) throw new KnowledgeStoreError("invalid", "Record latest revision is missing");
    for (const revision of Object.values(revisions)) {
      try {
        const record = validateKnowledgeRecord(revision);
        if (record.id !== id) throw new Error("Record history identity mismatch");
        if (record.revisionId !== Object.entries(revisions).find(([, value]) => value === revision)?.[0]) throw new Error("Record revision identity mismatch");
      } catch (error) { throw new KnowledgeStoreError("invalid", error instanceof Error ? error.message : "Invalid knowledge record"); }
    }
  }
  if (!state.coverage || typeof state.coverage !== "object" || Array.isArray(state.coverage)) throw new KnowledgeStoreError("invalid", "Invalid observation coverage");
  for (const coverage of Object.values(state.coverage as Record<string, unknown>)) validateCoverage(coverage);
  if (!state.suppressions || typeof state.suppressions !== "object" || Array.isArray(state.suppressions)) throw new KnowledgeStoreError("invalid", "Invalid knowledge suppressions");
  for (const [id, suppression] of Object.entries(state.suppressions as Record<string, unknown>)) {
    safeId(id, "suppression record id");
    if (!suppression || typeof suppression !== "object" || typeof (suppression as Record<string, unknown>).excluded !== "boolean" || typeof (suppression as Record<string, unknown>).forgotten !== "boolean" || typeof (suppression as Record<string, unknown>).updatedAt !== "string" || !isValidTimestamp((suppression as Record<string, unknown>).updatedAt as string)) throw new KnowledgeStoreError("invalid", "Invalid knowledge suppression");
  }
  if (!Array.isArray(state.cleanup) || state.cleanup.some(hash => typeof hash !== "string" || !/^[a-f0-9]{64}$/.test(hash))) throw new KnowledgeStoreError("invalid", "Invalid knowledge cleanup list");
  if (!state.receipts || typeof state.receipts !== "object" || Array.isArray(state.receipts)) throw new KnowledgeStoreError("invalid", "Invalid knowledge receipts");
  for (const receipt of Object.values(state.receipts as Record<string, unknown>)) {
    if (!receipt || typeof receipt !== "object" || typeof (receipt as Record<string, unknown>).operation !== "string" || typeof (receipt as Record<string, unknown>).requestHash !== "string") throw new KnowledgeStoreError("invalid", "Invalid knowledge mutation receipt");
  }
  try { validateKnowledgeConfig(state.config); } catch (error) { throw new KnowledgeStoreError("invalid", error instanceof Error ? error.message : "Invalid knowledge config"); }
  return value as KnowledgeState;
}

function validateCoverage(value: unknown): asserts value is ObservationCoverage {
  if (!value || typeof value !== "object" || Array.isArray(value)) throw new KnowledgeStoreError("invalid", "Invalid observation coverage");
  const coverage = value as Record<string, unknown>;
  if (coverage.schemaVersion !== KNOWLEDGE_SCHEMA_VERSION || typeof coverage.id !== "string" || typeof coverage.revisionId !== "string" || !Array.isArray(coverage.groupRevisionIds) || typeof coverage.recordedAt !== "string" || !["observed", "empty", "excluded", "pending", "failed", "unavailable"].includes(coverage.disposition as string)) throw new KnowledgeStoreError("invalid", "Invalid observation coverage");
  safeId(coverage.id, "coverage id");
  safeId(coverage.revisionId, "coverage revision");
  if (!isValidTimestamp(coverage.recordedAt)) throw new KnowledgeStoreError("invalid", "Invalid coverage timestamp");
  const range = coverage.range as Record<string, unknown>;
  if (!range || typeof range !== "object" || Array.isArray(range)) throw new KnowledgeStoreError("invalid", "Invalid coverage range");
  for (const key of ["sessionId", "fromEntryId", "toEntryId"]) safeId(range[key] as string, `coverage ${key}`);
}
function isValidTimestamp(value: string): boolean { return /^\d{4}-\d\d-\d\dT/.test(value) && !Number.isNaN(Date.parse(value)); }
function recordObjectHashes(record: KnowledgeRecord): string[] {
  const hashes: string[] = [];
  if (record.kind === "source" && record.content.object) hashes.push(record.content.object.hash);
  for (const evidence of record.provenance.evidence) if (evidence.objectHash) hashes.push(evidence.objectHash);
  if (record.kind === "observation") for (const item of record.content.items) for (const evidence of item.evidence ?? []) if (evidence.objectHash) hashes.push(evidence.objectHash);
  if (record.kind === "note") for (const field of record.content.fields ?? []) for (const evidence of field.evidence) if (evidence.objectHash) hashes.push(evidence.objectHash);
  return [...new Set(hashes)];
}
function searchableFields(record: KnowledgeRecord): Array<[string, string]> {
  if (record.kind === "source") return [["title", record.content.title], ["text", record.content.text ?? ""], ["uri", record.content.uri ?? ""]];
  if (record.kind === "observation") return [["observation", record.content.items.map(item => item.text).join(" ")], ["session", record.content.range.sessionId]];
  return [["title", record.content.title], ["body", record.content.body ?? ""], ["fields", (record.content.fields ?? []).map(field => `${field.field} ${String(field.value)}`).join(" ")]];
}

/**
 * Canonical knowledge owner. Construction is side-effect free; the workspace
 * namespace is created only by an intentional mutation or object capture.
 */
export class KnowledgeStore {
  private static readonly workspaceLocks = new WeakMap<TronWorkspace, AsyncMutex>();
  private readonly mutex: AsyncMutex;
  private readonly stateName = "state.json";

  constructor(private readonly workspace: TronWorkspace) {
    this.mutex = KnowledgeStore.workspaceLocks.get(workspace) ?? new AsyncMutex();
    KnowledgeStore.workspaceLocks.set(workspace, this.mutex);
  }

  private async paths(create: boolean): Promise<{ root: string; state: string; objects: string }> {
    const descriptor = await this.workspace.describe();
    if (!descriptor.available) throw new KnowledgeStoreError("unsafe", descriptor.reason === "closed" ? "Tron workspace is closed" : "Tron workspace is unavailable");
    const stateRoot = join(descriptor.root, "state");
    const root = join(stateRoot, "knowledge");
    if (create) await safeDirectory(stateRoot, true);
    else {
      try { await safeDirectory(stateRoot, false); } catch (error) { if (error instanceof KnowledgeStoreError && error.message.includes("unavailable")) return { root, state: join(root, this.stateName), objects: join(root, "objects") }; throw error; }
    }
    try { await safeDirectory(root, create); } catch (error) {
      if (!create && error instanceof KnowledgeStoreError && error.message.includes("unavailable")) return { root, state: join(root, this.stateName), objects: join(root, "objects") };
      throw error;
    }
    const objects = join(root, "objects");
    if (create) await safeDirectory(objects, true);
    return { root, state: join(root, this.stateName), objects };
  }

  private async load(paths: { state: string }, create: boolean): Promise<{ state: KnowledgeState; present: boolean }> {
    let read;
    try { read = await readSecureJson<unknown>(paths.state, STATE_MAX_BYTES); }
    catch (error) {
      if (error instanceof SecureJsonFileError) throw new KnowledgeStoreError(error.kind === "unsafe" ? "unsafe" : "invalid", error.message);
      throw error;
    }
    if (!read.present) {
      if (!create) return { state: emptyState(), present: false };
      return { state: emptyState(), present: false };
    }
    return { state: validateState(read.value), present: true };
  }

  private async save(paths: { state: string }, state: KnowledgeState): Promise<void> { await durableAtomicWriteJson(paths.state, state, 0o600); }

  private async mutate<T>(operation: string, commandId: string, request: unknown, action: (state: KnowledgeState, paths: { root: string; state: string; objects: string }) => Promise<T>): Promise<T> {
    if (!/^[A-Za-z0-9._:-]{8,160}$/.test(commandId)) throw invalid("Mutating requests require a stable commandId");
    return this.mutex.run(async () => {
      const paths = await this.paths(true);
      const loaded = await this.load(paths, true);
      const state = loaded.state;
      const key = `${operation}\0${commandId}`;
      const hash = requestHash(operation, request);
      const prior = state.receipts[key];
      if (prior) {
        if (prior.operation !== operation || prior.requestHash !== hash) throw conflict("Command ID was already used for a different knowledge mutation");
        return prior.result as T;
      }
      const result = await action(state, paths);
      state.stateRevision += 1;
      state.receipts[key] = { operation, requestHash: hash, result, createdAt: now() };
      const entries = Object.entries(state.receipts).sort(([, left], [, right]) => left.createdAt.localeCompare(right.createdAt));
      for (const [receiptKey] of entries.slice(0, Math.max(0, entries.length - RECEIPT_LIMIT))) delete state.receipts[receiptKey];
      await this.save(paths, state);
      return result;
    });
  }

  async status(): Promise<import("./knowledge-contract.js").KnowledgeStatus> {
    try {
      const paths = await this.paths(false);
      const loaded = await this.load(paths, false);
      if (!loaded.present) return { available: true, state: "uninitialized", recordCount: 0, coverageCount: 0, suppressedCount: 0, pendingCleanupCount: 0, config: structuredClone(DEFAULT_KNOWLEDGE_CONFIG), observationConfigured: false };
      const state = loaded.state;
      const config = state.config;
      return { available: true, state: "ready", stateRevision: state.stateRevision, recordCount: Object.keys(state.records).length, coverageCount: Object.keys(state.coverage).length, suppressedCount: Object.values(state.suppressions).filter(item => item.excluded || item.forgotten).length, pendingCleanupCount: state.cleanup.length, config, observationConfigured: config.observation.enabled && config.observation.model !== undefined };
    } catch (error) {
      const kind = error instanceof KnowledgeStoreError ? error.kind : "unsafe";
      return { available: false, state: kind, recordCount: 0, coverageCount: 0, suppressedCount: 0, pendingCleanupCount: 0, config: structuredClone(DEFAULT_KNOWLEDGE_CONFIG), observationConfigured: false, detail: error instanceof Error ? error.message : String(error) };
    }
  }

  async config(): Promise<KnowledgeConfig> {
    const paths = await this.paths(false);
    return (await this.load(paths, false)).state.config;
  }

  async configure(commandId: string, config: KnowledgeConfig): Promise<KnowledgeConfig> {
    try { validateKnowledgeConfig(config); } catch (error) { throw invalid(error instanceof Error ? error.message : "Invalid knowledge config"); }
    return this.mutate("knowledge.config", commandId, config, async state => { state.config = structuredClone(config); return state.config; });
  }

  async list(request: KnowledgeListRequest = {}): Promise<KnowledgeListResponse> {
    const paths = await this.paths(false);
    const { state } = await this.load(paths, false);
    const limit = Math.min(request.limit ?? 50, state.config.maximumSearchResults);
    if (!Number.isSafeInteger(limit) || limit < 1) throw invalid("Invalid knowledge list limit");
    const records = Object.values(state.records).map(history => history.revisions[history.latestRevisionId]).filter((record): record is KnowledgeRecord => record !== undefined).filter(record => (!request.kind || record.kind === request.kind) && (!request.scope || record.scope === request.scope) && (request.includeSuppressed || !state.suppressions[record.id]?.excluded));
    records.sort((a, b) => b.updatedAt.localeCompare(a.updatedAt) || a.id.localeCompare(b.id));
    const start = request.cursor ? Math.max(0, records.findIndex(record => record.id === request.cursor) + 1) : 0;
    const page = records.slice(start, start + limit);
    return { records: page, ...(start + limit < records.length ? { nextCursor: page.at(-1)!.id } : {}), stateRevision: state.stateRevision };
  }

  async read(id: string, revision?: string, includeSuppressed = false): Promise<KnowledgeRecord | null> {
    safeId(id, "record id");
    if (revision !== undefined && !/^[0-9a-f-]{16,80}$/.test(revision)) throw invalid("Invalid knowledge revision");
    const paths = await this.paths(false);
    const { state } = await this.load(paths, false);
    if (!includeSuppressed && state.suppressions[id]?.excluded) return null;
    const history = state.records[id];
    return revision ? history?.revisions[revision] ?? null : history?.revisions[history.latestRevisionId] ?? null;
  }

  async search(request: KnowledgeSearchRequest): Promise<KnowledgeSearchResponse> {
    if (typeof request.query !== "string" || request.query.trim().length === 0 || request.query.length > 512) throw invalid("Search query must be non-empty and bounded");
    const listed = await this.list({ ...(request.kind === undefined ? {} : { kind: request.kind }), ...(request.scope === undefined ? {} : { scope: request.scope }), limit: request.limit ?? 50 });
    const terms = request.query.toLocaleLowerCase().split(/\s+/).filter(Boolean);
    const hits: KnowledgeSearchHit[] = [];
    for (const record of listed.records) {
      const matchedFields: string[] = [];
      let score = 0;
      for (const [field, value] of searchableFields(record)) {
        const lower = value.toLocaleLowerCase();
        const count = terms.reduce((sum, term) => sum + (lower.includes(term) ? 1 : 0), 0);
        if (count) { matchedFields.push(field); score += count; }
      }
      if (score) hits.push({ record, score, matchedFields });
    }
    hits.sort((a, b) => b.score - a.score || b.record.updatedAt.localeCompare(a.record.updatedAt));
    return { hits: hits.slice(0, request.limit ?? 50), stateRevision: listed.stateRevision, indexState: "canonical" };
  }

  async recall(request: KnowledgeRecallRequest): Promise<KnowledgeRecallResponse> {
    const listed = await this.list({ ...(request.scope === undefined ? {} : { scope: request.scope }), limit: request.limit ?? 20 });
    const terms = request.query?.toLocaleLowerCase().split(/\s+/).filter(Boolean) ?? [];
    const records = listed.records.filter(record => {
      if (record.kind === "observation" && request.sessionId && record.content.range.sessionId !== request.sessionId) return false;
      if (record.kind === "observation" && request.entryId && record.content.range.fromEntryId !== request.entryId && record.content.range.toEntryId !== request.entryId) return false;
      if (!terms.length) return true;
      return searchableFields(record).some(([, value]) => terms.every(term => value.toLocaleLowerCase().includes(term)));
    }).slice(0, request.limit ?? 20);
    const citations: KnowledgeEvidenceRef[] = [];
    for (const record of records) citations.push(...record.provenance.evidence, ...(record.kind === "observation" ? record.content.items.flatMap(item => item.evidence ?? []) : []));
    return { records, citations, stateRevision: listed.stateRevision, availability: records.length ? "available" : "no-match" };
  }

  async captureSource(request: KnowledgeSourceCaptureRequest): Promise<KnowledgeMutationResult> {
    return this.mutate("knowledge.source.capture", request.commandId, request, async (state, paths) => this.putRecord(state, paths, request.record, request.expectedRevision));
  }

  async createNote(request: KnowledgeNoteMutationRequest & { recordId?: never }): Promise<KnowledgeMutationResult> {
    return this.mutate("knowledge.note.create", request.commandId, request, async (state, paths) => this.putRecord(state, paths, request.record));
  }

  async updateNote(request: KnowledgeNoteMutationRequest & { recordId: string }): Promise<KnowledgeMutationResult> {
    return this.mutate("knowledge.note.update", request.commandId, request, async (state, paths) => {
      const current = state.records[request.recordId]?.revisions[state.records[request.recordId]?.latestRevisionId ?? ""];
      if (!current || current.kind !== "note") throw conflict("Knowledge note does not exist");
      if (request.expectedRevision !== current.revisionId) throw conflict("Knowledge note revision is stale");
      return this.putRecord(state, paths, { ...request.record, id: request.recordId, createdAt: current.createdAt }, request.expectedRevision);
    });
  }

  private async putRecord(state: KnowledgeState, paths: { root: string; state: string; objects: string }, draft: KnowledgeRecordDraft, expectedRevision?: string): Promise<KnowledgeMutationResult> {
    const id = draft.id ?? recordId();
    safeId(id, "record id");
    const existing = state.records[id];
    if (state.suppressions[id]?.forgotten) throw conflict("Knowledge record was forgotten and cannot be recreated");
    const current = existing?.revisions[existing.latestRevisionId];
    if (expectedRevision !== undefined && current?.revisionId !== expectedRevision) throw conflict("Knowledge record revision is stale");
    if (expectedRevision === undefined && current) throw conflict("Knowledge record already exists; supply its expected revision");
    if (draft.kind === "source" && draft.content.object) await this.assertObject(paths, draft.content.object);
    const timestamp = now();
    const record = { ...draft, schemaVersion: KNOWLEDGE_SCHEMA_VERSION, id, revisionId: revisionId(), createdAt: draft.createdAt ?? current?.createdAt ?? timestamp, updatedAt: draft.updatedAt ?? timestamp } as KnowledgeRecord;
    try { validateKnowledgeRecord(record); } catch (error) { throw invalid(error instanceof Error ? error.message : "Invalid knowledge record"); }
    const history: RecordHistory = existing ?? { latestRevisionId: record.revisionId, revisions: {} };
    history.revisions[record.revisionId] = record;
    history.latestRevisionId = record.revisionId;
    state.records[id] = history;
    return { record, stateRevision: state.stateRevision + 1 };
  }

  async publishObservationGroup(input: ObservationGroupInput): Promise<{ records: KnowledgeRecord[]; coverage: ObservationCoverage; stateRevision: number }> {
    return this.mutate("knowledge.observation.publish", input.commandId, input, async (state, paths) => {
      const prior = state.coverage[input.coverage.id];
      if (prior && input.expectedCoverageRevision !== prior.revisionId) throw conflict("Observation coverage revision is stale");
      if (!prior && input.expectedCoverageRevision !== undefined) throw conflict("Observation coverage does not exist");
      const records: KnowledgeRecord[] = [];
      for (const draft of input.records) {
        if (draft.content.range.sessionId !== input.coverage.range.sessionId || draft.content.range.fromEntryId !== input.coverage.range.fromEntryId || draft.content.range.toEntryId !== input.coverage.range.toEntryId) throw invalid("Observation record range does not match coverage");
        const result = await this.putRecord(state, paths, draft, draft.id ? undefined : undefined);
        records.push(result.record);
      }
      const coverage: ObservationCoverage = { ...input.coverage, schemaVersion: KNOWLEDGE_SCHEMA_VERSION, revisionId: revisionId(), groupRevisionIds: records.map(record => record.revisionId), recordedAt: now() };
      validateCoverage(coverage);
      state.coverage[coverage.id] = coverage;
      return { records, coverage, stateRevision: state.stateRevision + 1 };
    });
  }

  async setCoverage(input: CoverageUpdateInput): Promise<{ coverage: ObservationCoverage; stateRevision: number }> {
    return this.mutate("knowledge.observation.coverage", input.commandId, input, async state => {
      const current = state.coverage[input.coverage.id];
      if (input.expectedRevision !== undefined && current?.revisionId !== input.expectedRevision) throw conflict("Observation coverage revision is stale");
      const coverage: ObservationCoverage = { ...input.coverage, schemaVersion: KNOWLEDGE_SCHEMA_VERSION, revisionId: revisionId(), recordedAt: now() };
      validateCoverage(coverage);
      state.coverage[coverage.id] = coverage;
      return { coverage, stateRevision: state.stateRevision + 1 };
    });
  }

  async reflect(commandId: string, sessionId: string, sourceRevisionIds: string[], text: string): Promise<KnowledgeMutationResult> {
    if (!text || text.length > 30_000 || sourceRevisionIds.length > 100) throw invalid("Reflection is bounded");
    const record: KnowledgeRecordDraft & { kind: "note" } = { kind: "note", scope: "personal", provenance: { actor: "agent", sessionId, evidence: [] }, relations: sourceRevisionIds.map(recordRevision => ({ type: "derivedFrom" as const, recordId: recordRevision })), content: { title: "Session reflection", body: text, role: "synthesis", confirmed: false } };
    return this.mutate("knowledge.reflect", commandId, { sessionId, sourceRevisionIds, text }, async (state, paths) => this.putRecord(state, paths, record));
  }

  async correct(commandId: string, recordId: string, expectedRevision: string, replacement: KnowledgeRecordDraft, relation: KnowledgeRecord["relations"][number]): Promise<KnowledgeMutationResult> {
    return this.mutate("knowledge.correction", commandId, { recordId, expectedRevision, replacement, relation }, async (state, paths) => {
      const current = state.records[recordId]?.revisions[state.records[recordId]?.latestRevisionId ?? ""];
      if (!current || current.revisionId !== expectedRevision) throw conflict("Knowledge record revision is stale");
      if (relation.recordId !== recordId || relation.revisionId !== expectedRevision || (relation.type !== "corrects" && relation.type !== "supersedes")) throw invalid("Correction relation must identify the replaced revision");
      return this.putRecord(state, paths, { ...replacement, id: recordId, createdAt: current.createdAt, relations: [...replacement.relations, relation] }, expectedRevision);
    });
  }

  async setExclusion(commandId: string, recordId: string, excluded: boolean, expectedRevision?: string, reason?: string): Promise<{ recordId: string; excluded: boolean; stateRevision: number }> {
    return this.mutate("knowledge.exclusion", commandId, { recordId, excluded, expectedRevision, reason }, async state => {
      const current = state.records[recordId]?.revisions[state.records[recordId]?.latestRevisionId ?? ""];
      if (!current) throw conflict("Knowledge record does not exist");
      if (expectedRevision !== undefined && expectedRevision !== current.revisionId) throw conflict("Knowledge record revision is stale");
      state.suppressions[recordId] = { excluded, forgotten: false, ...(reason === undefined ? {} : { reason }), updatedAt: now() };
      return { recordId, excluded, stateRevision: state.stateRevision + 1 };
    });
  }

  async forget(commandId: string, recordId: string, reason: string, expectedRevision?: string): Promise<KnowledgeForgetResult> {
    if (!reason || reason.length > 1_000) throw invalid("Forget reason is required and bounded");
    return this.mutate("knowledge.forget", commandId, { recordId, reason, expectedRevision }, async state => {
      const history = state.records[recordId];
      const current = history?.revisions[history.latestRevisionId ?? ""];
      if (!current) throw conflict("Knowledge record does not exist");
      if (expectedRevision !== undefined && expectedRevision !== current.revisionId) throw conflict("Knowledge record revision is stale");
      for (const record of Object.values(history.revisions)) state.cleanup.push(...recordObjectHashes(record));
      delete state.records[recordId];
      state.suppressions[recordId] = { excluded: true, forgotten: true, reason, updatedAt: now() };
      state.cleanup = [...new Set(state.cleanup)];
      return { forgotten: true, recordId, stateRevision: state.stateRevision + 1 };
    });
  }

  async putObject(bytes: Uint8Array, mediaType: string): Promise<KnowledgeObjectRef> {
    if (bytes.byteLength > OBJECT_MAX_BYTES || !mediaType || mediaType.length > 160) throw invalid("Content object is too large or has an invalid media type");
    const hash = createHash("sha256").update(bytes).digest("hex");
    return this.mutex.run(async () => {
      const paths = await this.paths(true);
      const ref = { hash, mediaType, bytes: bytes.byteLength } satisfies KnowledgeObjectRef;
      const path = join(paths.objects, `${hash}.json`);
      try {
        const existing = await readSecureJson<StoredObject>(path, OBJECT_MAX_BYTES * 2);
        if (existing.present) {
          if (existing.value.hash !== hash || existing.value.bytes !== bytes.byteLength) throw new KnowledgeStoreError("unsafe", "Existing knowledge object does not match its identity");
          return ref;
        }
      } catch (error) { if (error instanceof SecureJsonFileError) throw new KnowledgeStoreError(error.kind === "unsafe" ? "unsafe" : "invalid", error.message); throw error; }
      const object: StoredObject = { schemaVersion: OBJECT_SCHEMA_VERSION, hash, mediaType, bytes: bytes.byteLength, data: Buffer.from(bytes).toString("base64") };
      await durableAtomicWriteJson(path, object, 0o600);
      return ref;
    });
  }

  private async assertObject(paths: { objects: string }, ref: KnowledgeObjectRef): Promise<void> {
    validateObjectRef(ref);
    const path = join(paths.objects, `${ref.hash}.json`);
    const read = await readSecureJson<StoredObject>(path, OBJECT_MAX_BYTES * 2);
    if (!read.present || read.value.hash !== ref.hash || read.value.bytes !== ref.bytes || read.value.mediaType !== ref.mediaType) throw conflict("Referenced knowledge object is not durably captured");
  }

  async reconcile(): Promise<KnowledgeReconcileResult> {
    return this.mutex.run(async () => {
      const paths = await this.paths(false);
      const loaded = await this.load(paths, false);
      if (!loaded.present || loaded.state.cleanup.length === 0) return { removedObjects: [], pendingObjects: loaded.state.cleanup, stateRevision: loaded.state.stateRevision };
      const state = loaded.state;
      const referenced = new Set(Object.values(state.records).flatMap(history => Object.values(history.revisions).flatMap(recordObjectHashes)));
      const removedObjects: string[] = [];
      const pendingObjects: string[] = [];
      for (const hash of state.cleanup) {
        if (referenced.has(hash)) continue;
        try { await durableRemove(join(paths.objects, `${hash}.json`)); removedObjects.push(hash); }
        catch { pendingObjects.push(hash); }
      }
      if (removedObjects.length) {
        state.cleanup = pendingObjects;
        state.stateRevision += 1;
        await this.save(paths, state);
      }
      return { removedObjects, pendingObjects, stateRevision: state.stateRevision };
    });
  }

  /** Useful to tests and maintenance owners; it never creates missing state. */
  async coverage(id: string): Promise<ObservationCoverage | null> {
    safeId(id, "coverage id");
    const paths = await this.paths(false);
    return (await this.load(paths, false)).state.coverage[id] ?? null;
  }
}
