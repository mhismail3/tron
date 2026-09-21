import { createHash, randomBytes, randomUUID } from "node:crypto";
import { AsyncLocalStorage } from "node:async_hooks";
import { constants } from "node:fs";
import { lstat, mkdir, open, rename } from "node:fs/promises";
import { join, dirname } from "node:path";
import type { TronWorkspace } from "../workspace/tron-workspace.js";
import { GatewayError } from "../errors.js";
import { AsyncMutex } from "../util/async-mutex.js";
import { durableAtomicWriteJson, durableRemove } from "../util/durable-json.js";
import { readSecureJson, SecureJsonFileError } from "../util/secure-json.js";
import {
  DEFAULT_KNOWLEDGE_CONFIG, KNOWLEDGE_SCHEMA_VERSION, OBSERVATION_ATTENTION_DISPOSITIONS, OBSERVATION_COVERAGE_DISPOSITIONS, knowledgeScopeEligible,
  type KnowledgeConfig, type KnowledgeEvidenceRef, type KnowledgeListRequest,
  type KnowledgeListResponse, type KnowledgeObjectRef, type KnowledgeRecallRequest,
  type KnowledgeRecallResponse, type KnowledgeRecord, type KnowledgeRecordDraft,
  type KnowledgeSearchRequest, type KnowledgeSearchResponse, type KnowledgeSearchHit,
  type KnowledgeNoteMutationRequest, type KnowledgeCoverageDismissRequest,
  type KnowledgeConnectorState, type ObservationCoverage, type ObservationCoverageDisposition, type ObservationRange, type KnowledgeCoveragePage, type KnowledgeCoverageSummary, validateKnowledgeConfig,
  validateKnowledgeRecord, validateObjectRef, assertKnowledgeId, assertKnowledgeProjectId,
} from "./knowledge-contract.js";
import { isGatewayTimestamp } from "../util/timestamp.js";
import { KnowledgeCatalog, type KnowledgeTable } from "./knowledge-catalog.js";
import type { SQLInputValue } from "node:sqlite";
import { jsonNodeCount } from "../protocol/json-budget.js";
import type { ConnectionInstance } from "../integrations/connection-contract.js";

const STATE_MAX_BYTES = 4 * 1_048_576;
// One-time rescue also admits legacy states that outgrew their old read ceiling.
const LEGACY_MIGRATION_MAX_BYTES = 64 * 1_048_576;
const RECORD_MAX_BYTES = 2 * 1_048_576;
const OBJECT_MAX_BYTES = 8_000_000;
const RECEIPT_LIMIT = 256;
const OBJECT_HASH = /^[a-f0-9]{64}$/;
const OBJECT_SCHEMA_VERSION = 1 as const;
export const CATALOG_STORAGE_VERSION = 2 as const;
const CATALOG_PAGE_BYTES = 750_000;
const CATALOG_PAGE_NODES = 24_000;

/** Leave room for RPC/tool envelopes and native JSON decoder admission. */
class KnowledgePageBudget {
  private bytes = 0;
  private nodes = 0;
  admit(value: unknown): boolean {
    const bytes = Buffer.byteLength(JSON.stringify(value));
    const nodes = jsonNodeCount(value, CATALOG_PAGE_NODES);
    if (this.bytes === 0 && (bytes > CATALOG_PAGE_BYTES || nodes > CATALOG_PAGE_NODES)) throw invalid("Knowledge entry exceeds its bounded page size; read the exact record separately");
    if (this.bytes + bytes > CATALOG_PAGE_BYTES || this.nodes + nodes > CATALOG_PAGE_NODES) return false;
    this.bytes += bytes; this.nodes += nodes; return true;
  }
}

type LegacyRecordHead = { latestRevisionId: string; revisionIds: string[] };
type RecordHead = LegacyRecordHead & {
  kind: KnowledgeRecord["kind"]; scope: KnowledgeRecord["scope"];
  sortAt: number; searchFields: Array<[string, string]>;
  recordRefs: string[]; objectHashes: string[]; sourceIdentities?: string[];
};
type Suppression = { excluded: boolean; forgotten: boolean; reason?: string; updatedAt: string };
type ScopeExclusion = { sessionId?: string; branchId?: string; projectId?: string; excluded: boolean; reason?: string; updatedAt: string };
type PendingRecordCleanup = { recordId: string; revisionId: string };
type SourceRecordWriteRequest = { commandId: string; expectedRevision?: string; record: KnowledgeRecordDraft & { kind: "source" }; signal?: AbortSignal };
export interface KnowledgeImportCheckpoint {
  planHash: string;
  plannedRecordIds: string[];
  completedRecordIds: string[];
  updatedAt: string;
}
type StoredReceipt = { operation: string; requestHash: string; createdAt: string; result: ReceiptResult; recordIds: string[]; invalidated?: boolean };
type ReceiptResult =
  | { kind: "record"; recordId: string; revisionId: string; stateRevision: number }
  | { kind: "records"; records: Array<{ recordId: string; revisionId: string }>; coverage: ObservationCoverage; stateRevision: number }
  | { kind: "value"; value: unknown };
interface LegacyKnowledgeState {
  schemaVersion: typeof KNOWLEDGE_SCHEMA_VERSION;
  stateRevision: number;
  records: Record<string, LegacyRecordHead>;
  coverage: Record<string, ObservationCoverage>;
  suppressions: Record<string, Suppression>;
  scopeExclusions: Record<string, ScopeExclusion>;
  cleanup: string[];
  /** Forgotten immutable revisions awaiting post-commit removal. */
  recordCleanup?: PendingRecordCleanup[];
  /** Exact import batch membership and resumable progress, owned by the store. */
  imports?: Record<string, KnowledgeImportCheckpoint>;
  receipts: Record<string, StoredReceipt>;
  config: KnowledgeConfig;
  /** Connector checkpoints and pending IDs are canonical operational state; secrets are never stored here. */
  connectors?: Record<string, KnowledgeConnectorState>;
}

interface KnowledgeState {
  schemaVersion: typeof KNOWLEDGE_SCHEMA_VERSION;
  stateRevision: number;
  catalogID?: string;
  catalog?: KnowledgeCatalog;
  records: KnowledgeTable<RecordHead>;
  coverage: KnowledgeTable<ObservationCoverage>;
  suppressions: KnowledgeTable<Suppression>;
  scopeExclusions: KnowledgeTable<ScopeExclusion>;
  cleanup: KnowledgeTable<true>;
  recordCleanup: KnowledgeTable<PendingRecordCleanup>;
  sourceIdentities: KnowledgeTable<string>;
  imports: KnowledgeTable<KnowledgeImportCheckpoint>;
  receipts: KnowledgeTable<StoredReceipt>;
  config: KnowledgeConfig;
  connectors?: Record<string, KnowledgeConnectorState>;
}
type CatalogControl = Pick<KnowledgeState, "schemaVersion" | "stateRevision" | "catalogID" | "config" | "connectors">;

export type KnowledgeStateFailure = "unsafe" | "invalid" | "newer";
export class KnowledgeStoreError extends Error {
  constructor(readonly kind: KnowledgeStateFailure, message: string) { super(message); this.name = "KnowledgeStoreError"; }
}

export interface ObservationGroupInput {
  commandId: string;
  /** Configuration revision captured before model inference. */
  expectedConfigRevision: number;
  expectedCoverageRevision?: string;
  coverage: Omit<ObservationCoverage, "schemaVersion" | "revisionId" | "groupRevisionIds" | "recordedAt"> & { disposition: "observed" | "empty" | "excluded" };
  records: Array<KnowledgeRecordDraft & { kind: "observation" }>;
}
export interface CoverageUpdateInput {
  commandId: string;
  /** Configuration revision captured before background inference. */
  expectedConfigRevision: number;
  expectedRevision?: string;
  coverage: Omit<ObservationCoverage, "schemaVersion" | "revisionId" | "recordedAt">;
}
export interface KnowledgeMutationResult { record: KnowledgeRecord; stateRevision: number; }
export interface KnowledgeForgetResult { forgotten: true; recordId: string; stateRevision: number; }
export interface KnowledgeReconcileResult { removedObjects: string[]; pendingObjects: string[]; stateRevision: number; }

function conflict(message: string): GatewayError { return new GatewayError("conflict", message); }
function invalid(message: string): GatewayError { return new GatewayError("invalid_request", message); }
function requestHash(operation: string, request: unknown): string { return createHash("sha256").update(operation).update("\0").update(JSON.stringify(request)).digest("hex"); }
function now(): string { return new Date().toISOString(); }
function revisionId(): string { return randomUUID(); }
function recordId(): string { return randomUUID(); }
function safeId(value: string, label: string): void { assertKnowledgeId(value, label); if (value === "." || value === "..") throw new Error(`Invalid ${label}`); }
function validTimestamp(value: string): boolean { return /^\d{4}-\d\d-\d\dT/.test(value) && !Number.isNaN(Date.parse(value)); }

async function safeDirectory(path: string, create: boolean): Promise<void> {
  if (create) {
    try { await mkdir(path, { recursive: true, mode: 0o700 }); }
    catch { throw new KnowledgeStoreError("unsafe", `Knowledge directory cannot be created: ${path}`); }
  }
  let info;
  try { info = await lstat(path); }
  catch { throw new KnowledgeStoreError("unsafe", `Knowledge directory is unavailable: ${path}`); }
  if (!info.isDirectory() || info.isSymbolicLink() || info.uid !== process.getuid?.() || (info.mode & 0o777) !== 0o700) throw new KnowledgeStoreError("unsafe", "Knowledge state directory must be an owner-only real directory");
}

function emptyState(): LegacyKnowledgeState {
  return { schemaVersion: KNOWLEDGE_SCHEMA_VERSION, stateRevision: 0, records: {}, coverage: {}, suppressions: {}, scopeExclusions: {}, cleanup: [], recordCleanup: [], imports: {}, receipts: {}, config: structuredClone(DEFAULT_KNOWLEDGE_CONFIG), connectors: {} };
}
function catalogState(control: CatalogControl, catalog?: KnowledgeCatalog): KnowledgeState {
  return { ...control, ...(catalog ? { catalog } : {}),
    records: catalog?.table<RecordHead>("records") ?? new Map(),
    coverage: catalog?.table<ObservationCoverage>("coverage") ?? new Map(),
    suppressions: catalog?.table<Suppression>("suppressions") ?? new Map(),
    scopeExclusions: catalog?.table<ScopeExclusion>("scopeExclusions") ?? new Map(),
    receipts: catalog?.table<StoredReceipt>("receipts") ?? new Map(),
    imports: catalog?.table<KnowledgeImportCheckpoint>("imports") ?? new Map(),
    cleanup: catalog?.table<true>("cleanup") ?? new Map(),
    recordCleanup: catalog?.table<PendingRecordCleanup>("recordCleanup") ?? new Map(),
    sourceIdentities: catalog?.table<string>("sourceIdentities") ?? new Map(),
  };
}
function headFor(record: KnowledgeRecord, revisions: string[], retainedObjects: string[] = []): RecordHead {
  const date = record.kind === "observation" ? record.content.items[0]?.observedAt ?? record.createdAt : record.updatedAt;
  const evidence = [...record.provenance.evidence,
    ...(record.kind === "observation" ? record.content.items.flatMap(item => item.evidence ?? []) : []),
    ...(record.kind === "note" ? [...(record.content.fields ?? []).flatMap(field => field.evidence), ...(record.content.contraryEvidence ?? [])] : []),
  ];
  return { latestRevisionId: record.revisionId, revisionIds: revisions, kind: record.kind, scope: record.scope,
    sortAt: Date.parse(date), searchFields: searchableFields(record).map(([field, value]) => [field, value.toLocaleLowerCase()]),
    recordRefs: [...new Set([...record.relations.map(relation => relation.recordId), ...evidence.flatMap(ref => ref.recordId ? [ref.recordId] : [])])],
    objectHashes: [...new Set([...retainedObjects, ...recordObjectHashes(record)])],
    ...(recordSourceIdentityKeys(record).length > 0 ? { sourceIdentities: recordSourceIdentityKeys(record) } : {}),
  };
}
function cleanupKey(item: PendingRecordCleanup): string { return JSON.stringify([item.recordId, item.revisionId]); }
function sourceIdentityKey(identity: { provider: string; accountId: string; itemId: string }): string {
  return JSON.stringify([identity.provider, identity.accountId, identity.itemId]);
}
function recordSourceIdentityKeys(record: KnowledgeRecord): string[] {
  if (record.kind !== "source") return [];
  const identities = [record.content.identity, ...(record.content.origins ?? []).map(origin => origin.identity)].filter((identity): identity is NonNullable<typeof identity> => Boolean(identity));
  return [...new Set(identities.map(sourceIdentityKey))];
}
function listCursor(scope: string, position: { sortAt: number; id: string }): string {
  return Buffer.from(JSON.stringify({ v: 1, scope, ...position })).toString("base64url");
}
function readListCursor(cursor: string, scope: string): { sortAt: number; id: string } {
  try {
    if (cursor.length > 2_000) throw new Error();
    const value = JSON.parse(Buffer.from(cursor, "base64url").toString("utf8"));
    if (value.v !== 1 || value.scope !== scope || !Number.isFinite(value.sortAt) || typeof value.id !== "string") throw new Error();
    safeId(value.id, "cursor record"); return value;
  } catch { throw invalid("Knowledge cursor is invalid for this query; reload the first page"); }
}
function validateCoverage(value: unknown): asserts value is ObservationCoverage {
  if (!value || typeof value !== "object" || Array.isArray(value)) throw new KnowledgeStoreError("invalid", "Invalid observation coverage");
  const coverage = value as Record<string, unknown>;
  if (coverage.schemaVersion !== KNOWLEDGE_SCHEMA_VERSION || typeof coverage.id !== "string" || typeof coverage.revisionId !== "string" || !Array.isArray(coverage.groupRevisionIds) || typeof coverage.recordedAt !== "string" || !OBSERVATION_COVERAGE_DISPOSITIONS.includes(coverage.disposition as ObservationCoverageDisposition)) throw new KnowledgeStoreError("invalid", "Invalid observation coverage");
  safeId(coverage.id, "coverage id"); safeId(coverage.revisionId, "coverage revision");
  if (!validTimestamp(coverage.recordedAt)) throw new KnowledgeStoreError("invalid", "Invalid coverage timestamp");
  const range = coverage.range as Record<string, unknown>;
  if (!range || typeof range !== "object" || Array.isArray(range)) throw new KnowledgeStoreError("invalid", "Invalid coverage range");
  for (const key of ["sessionId", "fromEntryId", "toEntryId"]) safeId(range[key] as string, `coverage ${key}`);
  if (range.branchId !== undefined) safeId(range.branchId as string, "coverage branchId");
  if (!Array.isArray(range.entryIds) || range.entryIds.length < 1 || range.entryIds[0] !== range.fromEntryId || range.entryIds.at(-1) !== range.toEntryId || typeof range.entryDigest !== "string" || !OBJECT_HASH.test(range.entryDigest)) throw new KnowledgeStoreError("invalid", "Coverage does not identify an exact canonical input");
  range.entryIds.forEach(entry => safeId(entry as string, "coverage entry id"));
  if (range.projectId !== undefined) assertKnowledgeProjectId(range.projectId as string, "coverage projectId");
}
function validateConnectorState(value: unknown, connector: "raindrop" | "x"): asserts value is KnowledgeConnectorState {
  if (!value || typeof value !== "object" || Array.isArray(value)) throw new KnowledgeStoreError("invalid", "Invalid connector state");
  const state = value as Record<string, unknown>;
  if (state.connectionId !== undefined && (typeof state.connectionId !== "string" || !/^[A-Za-z0-9._:-]{1,160}$/.test(state.connectionId))) throw new KnowledgeStoreError("invalid", "Invalid connector connection ID");
  if (state.credentialAvailability !== undefined && !["available", "unavailable", "unknown"].includes(state.credentialAvailability as string)) throw new KnowledgeStoreError("invalid", "Invalid connector credential observation");
  if (state.providerIdentity !== undefined && !["admitted", "mismatch", "unknown"].includes(state.providerIdentity as string)) throw new KnowledgeStoreError("invalid", "Invalid connector provider observation");
  const genericEnvelopePresent = ["enabled", "allowWrites", "paidAccessApproved", "paidBudgetCents", "recurringApproved"].every(key => state[key] !== undefined);
  if (!genericEnvelopePresent && state.connectionId === undefined) throw new KnowledgeStoreError("invalid", "Connector state is missing its connection envelope");
  if (state.connector !== connector || !Array.isArray(state.pending) || !Array.isArray(state.capturedIds) || !["unconfigured", "setup-required", "ready", "running", "partial", "rate-limited", "auth-error", "error"].includes(state.health as string) || !Number.isSafeInteger(state.remaining) || (state.remaining as number) < 0 || state.pending.length > 500 || state.capturedIds.length > 2_000 || (genericEnvelopePresent && (typeof state.enabled !== "boolean" || typeof state.allowWrites !== "boolean" || typeof state.paidAccessApproved !== "boolean" || !Number.isSafeInteger(state.paidBudgetCents) || (state.paidBudgetCents as number) < 0 || (state.paidBudgetCents as number) > 1_000_000 || typeof state.recurringApproved !== "boolean"))) throw new KnowledgeStoreError("invalid", "Invalid connector state");
  for (const item of state.pending) {
    if (!item || typeof item !== "object" || typeof (item as Record<string, unknown>).id !== "string" || typeof (item as Record<string, unknown>).title !== "string" || typeof (item as Record<string, unknown>).url !== "string" || ((item as Record<string, unknown>).apiPayload !== undefined && (typeof (item as Record<string, unknown>).apiPayload !== "string" || ((item as Record<string, unknown>).apiPayload as string).length > 100_000)) || ((item as Record<string, unknown>).metadataComplete !== undefined && typeof (item as Record<string, unknown>).metadataComplete !== "boolean")) throw new KnowledgeStoreError("invalid", "Invalid connector pending item");
  }
  const validateAssessmentAuthority = (value: unknown, label: string): void => {
    const authority = value as Record<string, unknown>;
    const maxItems = typeof authority?.maxItems === "number" ? authority.maxItems : Number.NaN; const budgetCents = typeof authority?.budgetCents === "number" ? authority.budgetCents : Number.NaN; const usedItems = typeof authority?.usedItems === "number" ? authority.usedItems : Number.NaN; const reservedCents = typeof authority?.reservedCents === "number" ? authority.reservedCents : Number.NaN;
    if (!authority || typeof authority !== "object" || typeof authority.id !== "string" || authority.id.length < 1 || authority.id.length > 160 || typeof authority.accountId !== "string" || !/^\d+$/.test(authority.accountId) || typeof authority.sourceCollection !== "string" || !/^-?\d{1,18}$/.test(authority.sourceCollection) || typeof authority.profileVersion !== "string" || authority.profileVersion.length < 1 || authority.profileVersion.length > 256 || !Array.isArray(authority.itemIds) || authority.itemIds.length > 10 || authority.itemIds.some(itemId => typeof itemId !== "string" || itemId.length < 1 || itemId.length > 512) || !Number.isSafeInteger(maxItems) || maxItems < 1 || maxItems > 10 || !Number.isSafeInteger(budgetCents) || budgetCents < 1 || budgetCents > 100 || !Number.isSafeInteger(usedItems) || usedItems < 0 || usedItems > maxItems || !Number.isSafeInteger(reservedCents) || reservedCents < 0 || reservedCents > budgetCents) throw new KnowledgeStoreError("invalid", `Invalid connector ${label}`);
  };
  if (state.assessmentPilot !== undefined) validateAssessmentAuthority(state.assessmentPilot, "assessment pilot");
  if (state.assessmentApprovals !== undefined) {
    if (!Array.isArray(state.assessmentApprovals) || state.assessmentApprovals.length > 32 || new Set(state.assessmentApprovals.map(item => (item as Record<string, unknown>)?.id)).size !== state.assessmentApprovals.length) throw new KnowledgeStoreError("invalid", "Invalid connector assessment approvals");
    state.assessmentApprovals.forEach(item => validateAssessmentAuthority(item, "assessment approval"));
  }
  for (const id of state.capturedIds) if (typeof id !== "string" || id.length > 512) throw new KnowledgeStoreError("invalid", "Invalid connector captured ID");
  if (state.assessmentAttempts !== undefined) {
    if (!state.assessmentAttempts || typeof state.assessmentAttempts !== "object" || Array.isArray(state.assessmentAttempts) || Object.keys(state.assessmentAttempts).length > 500) throw new KnowledgeStoreError("invalid", "Invalid connector assessment attempts");
    for (const [itemId, attempt] of Object.entries(state.assessmentAttempts as Record<string, unknown>)) {
      if (!itemId || !attempt || typeof attempt !== "object" || ((attempt as Record<string, unknown>).itemId !== undefined && (typeof (attempt as Record<string, unknown>).itemId !== "string" || !(attempt as Record<string, unknown>).itemId)) || ((attempt as Record<string, unknown>).cohortId !== undefined && (typeof (attempt as Record<string, unknown>).cohortId !== "string" || !(attempt as Record<string, unknown>).cohortId)) || !["dispatched", "settled"].includes((attempt as Record<string, unknown>).status as string) || !Number.isSafeInteger((attempt as Record<string, unknown>).chargeCents) || ((attempt as Record<string, unknown>).chargeCents as number) < 1 || ((attempt as Record<string, unknown>).inputTokens !== undefined && (!Number.isSafeInteger((attempt as Record<string, unknown>).inputTokens) || (attempt as Record<string, unknown>).inputTokens as number < 0)) || ((attempt as Record<string, unknown>).outputTokens !== undefined && (!Number.isSafeInteger((attempt as Record<string, unknown>).outputTokens) || (attempt as Record<string, unknown>).outputTokens as number < 0)) || ((attempt as Record<string, unknown>).estimatedCostCents !== undefined && (typeof (attempt as Record<string, unknown>).estimatedCostCents !== "number" || !Number.isFinite((attempt as Record<string, unknown>).estimatedCostCents) || (attempt as Record<string, unknown>).estimatedCostCents as number < 0))) throw new KnowledgeStoreError("invalid", "Invalid connector assessment attempt");
    }
  }
  for (const key of ["accountId", "scope", "destination", "credentialRef", "lastRunAt", "lastError"]) if (state[key] !== undefined && (typeof state[key] !== "string" || (state[key] as string).length > 4_096)) throw new KnowledgeStoreError("invalid", "Invalid connector state field");
  if (state.checkpoints !== undefined) {
    if (!state.checkpoints || typeof state.checkpoints !== "object" || Array.isArray(state.checkpoints) || Object.keys(state.checkpoints).length > 32) throw new KnowledgeStoreError("invalid", "Invalid connector checkpoints");
    for (const [key, value] of Object.entries(state.checkpoints as Record<string, unknown>)) if (key.length < 1 || key.length > 256 || typeof value !== "string" || value.length > 4_096) throw new KnowledgeStoreError("invalid", "Invalid connector checkpoint");
  }
  if (state.pendingRemote !== undefined) {
    const pending = state.pendingRemote as Record<string, unknown>;
    if (!pending || pending.action !== "move" || typeof pending.operationId !== "string" || typeof pending.itemId !== "string" || typeof pending.basisRecordId !== "string" || typeof pending.basisRevisionId !== "string" || typeof pending.provider !== "string" || typeof pending.accountId !== "string" || typeof pending.originalCollectionId !== "string" || typeof pending.destination !== "string" || typeof pending.createdAt !== "string") throw new KnowledgeStoreError("invalid", "Invalid connector remote receipt");
  }
}

function validateState(value: unknown): LegacyKnowledgeState {
  if (!value || typeof value !== "object" || Array.isArray(value)) throw new KnowledgeStoreError("invalid", "Knowledge state is not an object");
  const state = value as Record<string, unknown>;
  if (state.schemaVersion !== KNOWLEDGE_SCHEMA_VERSION) throw new KnowledgeStoreError(typeof state.schemaVersion === "number" && state.schemaVersion > KNOWLEDGE_SCHEMA_VERSION ? "newer" : "invalid", "Unsupported knowledge state schema");
  if (!Number.isSafeInteger(state.stateRevision) || (state.stateRevision as number) < 0) throw new KnowledgeStoreError("invalid", "Invalid knowledge state revision");
  if (!state.records || typeof state.records !== "object" || Array.isArray(state.records)) throw new KnowledgeStoreError("invalid", "Invalid knowledge record heads");
  for (const [id, value] of Object.entries(state.records as Record<string, unknown>)) {
    safeId(id, "record id");
    const head = value as Record<string, unknown>;
    if (!head || typeof head !== "object" || typeof head.latestRevisionId !== "string" || !Array.isArray(head.revisionIds) || head.revisionIds.length < 1 || !head.revisionIds.every(item => typeof item === "string" && /^[0-9a-f-]{16,80}$/.test(item)) || !head.revisionIds.includes(head.latestRevisionId)) throw new KnowledgeStoreError("invalid", "Invalid record head");
  }
  if (!state.coverage || typeof state.coverage !== "object" || Array.isArray(state.coverage)) throw new KnowledgeStoreError("invalid", "Invalid observation coverage");
  for (const coverage of Object.values(state.coverage as Record<string, unknown>)) validateCoverage(coverage);
  if (!state.suppressions || typeof state.suppressions !== "object" || Array.isArray(state.suppressions)) throw new KnowledgeStoreError("invalid", "Invalid knowledge suppressions");
  for (const [id, suppression] of Object.entries(state.suppressions as Record<string, unknown>)) {
    safeId(id, "suppression record id"); const item = suppression as Record<string, unknown>;
    if (!item || typeof item !== "object" || typeof item.excluded !== "boolean" || typeof item.forgotten !== "boolean" || typeof item.updatedAt !== "string" || !validTimestamp(item.updatedAt)) throw new KnowledgeStoreError("invalid", "Invalid knowledge suppression");
  }
  if (!state.scopeExclusions || typeof state.scopeExclusions !== "object" || Array.isArray(state.scopeExclusions)) throw new KnowledgeStoreError("invalid", "Invalid scope exclusions");
  if (!Array.isArray(state.cleanup) || state.cleanup.some(hash => typeof hash !== "string" || !OBJECT_HASH.test(hash))) throw new KnowledgeStoreError("invalid", "Invalid knowledge cleanup list");
  if (state.recordCleanup !== undefined && (!Array.isArray(state.recordCleanup) || state.recordCleanup.some(item => !item || typeof item !== "object" || typeof item.recordId !== "string" || typeof item.revisionId !== "string"))) throw new KnowledgeStoreError("invalid", "Invalid record cleanup list");
  if (state.imports !== undefined) {
    if (!state.imports || typeof state.imports !== "object" || Array.isArray(state.imports)) throw new KnowledgeStoreError("invalid", "Invalid knowledge import checkpoints");
    for (const [planHash, checkpoint] of Object.entries(state.imports as Record<string, unknown>)) {
      if (!OBJECT_HASH.test(planHash) || !checkpoint || typeof checkpoint !== "object" || Array.isArray(checkpoint)) throw new KnowledgeStoreError("invalid", "Invalid knowledge import checkpoint");
      const item = checkpoint as Record<string, unknown>;
      const planned = item.plannedRecordIds; const completed = item.completedRecordIds;
      if (item.planHash !== planHash || !Array.isArray(planned) || !Array.isArray(completed) || planned.length > 20_000 || completed.length > planned.length || !completed.every(id => typeof id === "string" && planned.includes(id)) || typeof item.updatedAt !== "string" || !isGatewayTimestamp(item.updatedAt)) throw new KnowledgeStoreError("invalid", "Invalid knowledge import checkpoint");
      (planned as unknown[]).forEach(id => assertKnowledgeId(id, "import record id"));
    }
  }
  if (!state.receipts || typeof state.receipts !== "object" || Array.isArray(state.receipts)) throw new KnowledgeStoreError("invalid", "Invalid knowledge receipts");
  for (const receipt of Object.values(state.receipts as Record<string, unknown>)) {
    const item = receipt as Record<string, unknown>;
    if (!item || typeof item !== "object" || typeof item.operation !== "string" || typeof item.requestHash !== "string" || !item.result || !Array.isArray(item.recordIds) || (item.invalidated !== undefined && typeof item.invalidated !== "boolean")) throw new KnowledgeStoreError("invalid", "Invalid knowledge mutation receipt");
  }
  try { validateKnowledgeConfig(state.config); } catch (error) { throw new KnowledgeStoreError("invalid", error instanceof Error ? error.message : "Invalid knowledge config"); }
  if (state.connectors !== undefined) {
    if (!state.connectors || typeof state.connectors !== "object" || Array.isArray(state.connectors)) throw new KnowledgeStoreError("invalid", "Invalid connector map");
    const connectors = state.connectors as Record<string, unknown>;
    for (const [key, value] of Object.entries(connectors)) {
      if (!/^[A-Za-z0-9._:-]{1,160}$/.test(key)) throw new KnowledgeStoreError("invalid", "Invalid connector state key");
      if (value !== undefined) validateConnectorState(value, (value as Record<string, unknown>)?.connector as "raindrop" | "x");
      if ((value as unknown as Record<string, unknown>)?.connectionId !== undefined && (value as unknown as Record<string, unknown>).connectionId !== key) throw new KnowledgeStoreError("invalid", "Connector state connection ID does not match its key");
    }
  }
  return value as LegacyKnowledgeState;
}
function recordObjectRefs(record: KnowledgeRecord): KnowledgeObjectRef[] {
  if (record.kind !== "source") return [];
  return [
    ...(record.content.object ? [record.content.object] : []),
    ...(record.content.representations ?? []).map(item => item.object),
  ];
}

function recordObjectHashes(record: KnowledgeRecord): string[] {
  const hashes = recordObjectRefs(record).map(object => object.hash);
  for (const evidence of record.provenance.evidence) if (evidence.objectHash) hashes.push(evidence.objectHash);
  if (record.kind === "observation") for (const item of record.content.items) for (const evidence of item.evidence ?? []) if (evidence.objectHash) hashes.push(evidence.objectHash);
  if (record.kind === "note") for (const field of record.content.fields ?? []) for (const evidence of field.evidence) if (evidence.objectHash) hashes.push(evidence.objectHash);
  return [...new Set(hashes)];
}
function searchableFields(record: KnowledgeRecord): Array<[string, string]> {
  if (record.kind === "source") return [
    ["title", record.content.title], ["text", record.content.text ?? ""], ["uri", record.content.uri ?? ""],
    ["assessment", record.content.assessment ? [record.content.assessment.summary, record.content.assessment.contribution, record.content.assessment.whyItMatters, record.content.assessment.possibleUse].filter(Boolean).join(" ") : ""],
    ["identity", record.content.identity ? `${record.content.identity.provider} ${record.content.identity.accountId} ${record.content.identity.itemId}` : ""],
  ];
  if (record.kind === "observation") return [["observation", record.content.items.map(item => item.text).join(" ")], ["session", record.content.range.sessionId]];
  return [["title", record.content.title], ["body", record.content.body ?? ""], ["fields", (record.content.fields ?? []).map(field => `${field.field} ${String(field.value)}`).join(" ")]];
}
function sameRange(left: ObservationRange, right: ObservationRange): boolean {
  return left.sessionId === right.sessionId && left.branchId === right.branchId && left.projectId === right.projectId && left.fromEntryId === right.fromEntryId && left.toEntryId === right.toEntryId && left.entryDigest === right.entryDigest && left.entryIds.length === right.entryIds.length && left.entryIds.every((entry, index) => entry === right.entryIds[index]);
}
function coverageSummary(coverage: Iterable<ObservationCoverage>): KnowledgeCoverageSummary {
  const summary: KnowledgeCoverageSummary = { observedCount: 0, emptyCount: 0, excludedCount: 0, pendingCount: 0, failedCount: 0, unavailableCount: 0, remainingCount: 0 };
  for (const item of coverage) {
    switch (item.disposition) {
      case "observed": summary.observedCount += 1; break;
      case "empty": summary.emptyCount += 1; break;
      case "excluded": summary.excludedCount += 1; break;
      case "pending": summary.pendingCount += 1; break;
      case "failed": summary.failedCount += 1; break;
      case "unavailable": summary.unavailableCount += 1; break;
    }
  }
  summary.remainingCount = summary.pendingCount + summary.failedCount + summary.unavailableCount;
  return summary;
}
function scopeKey(range: ObservationRange): string[] { return [`session:${range.sessionId}`, ...(range.branchId ? [`branch:${range.sessionId}:${range.branchId}`] : []), ...(range.projectId ? [`project:${range.projectId}`] : [])]; }

interface StorePaths { root: string; state: string; objects: string; records: string; present: boolean; fresh: boolean; }

async function durableAtomicWriteBytes(path: string, bytes: Uint8Array, mode = 0o600): Promise<void> {
  const directory = dirname(path); await mkdir(directory, { recursive: true, mode: 0o700 });
  const temporary = `${path}.${process.pid}.${randomBytes(6).toString("hex")}.tmp`;
  let exists = false;
  try {
    const handle = await open(temporary, "wx", mode); exists = true;
    try { await handle.writeFile(bytes); await handle.sync(); } finally { await handle.close(); }
    await rename(temporary, path); exists = false;
    const directoryHandle = await open(directory, "r"); try { await directoryHandle.sync(); } finally { await directoryHandle.close(); }
  } catch (error) { if (exists) await import("node:fs/promises").then(fs => fs.rm(temporary, { force: true })).catch(() => {}); throw error; }
}

async function readSecureBytes(path: string, maximumBytes: number): Promise<Uint8Array | null> {
  const ownerUid = process.getuid?.();
  if (ownerUid === undefined || typeof constants.O_NOFOLLOW !== "number") throw new KnowledgeStoreError("unsafe", "Object ownership or symlink safety cannot be verified");
  let entry;
  try { entry = await lstat(path); } catch (error) { if ((error as NodeJS.ErrnoException).code === "ENOENT") return null; throw new KnowledgeStoreError("unsafe", "Object could not be securely inspected"); }
  if (!entry.isFile() || entry.uid !== ownerUid || (entry.mode & 0o077) !== 0 || entry.size > maximumBytes) throw new KnowledgeStoreError("unsafe", "Object is not a bounded owner-only regular file");
  let handle;
  try {
    handle = await open(path, constants.O_RDONLY | constants.O_NOFOLLOW); const metadata = await handle.stat();
    if (!metadata.isFile() || metadata.uid !== ownerUid || (metadata.mode & 0o077) !== 0 || metadata.size !== entry.size || metadata.size > maximumBytes || metadata.dev !== entry.dev || metadata.ino !== entry.ino) throw new KnowledgeStoreError("unsafe", "Object changed its secure boundary during read");
    const bytes = Buffer.alloc(metadata.size); let offset = 0;
    while (offset < bytes.length) { const read = await handle.read(bytes, offset, bytes.length - offset, offset); if (!read.bytesRead) break; offset += read.bytesRead; }
    if (offset !== bytes.length) throw new KnowledgeStoreError("unsafe", "Object changed during bounded read");
    return bytes;
  } finally { await handle?.close(); }
}

/** Canonical owner: immutable record/object files are data; the catalog is the
 * transactional authority for heads, coverage, suppression and receipts. */
export type KnowledgeConnectorEnvelopeResolver = (connectionId: string) => Promise<Pick<ConnectionInstance, "providerAccountId" | "scope" | "credentialRef" | "policy"> | undefined>;

export class KnowledgeStore {
  private static readonly workspaceLocks = new WeakMap<TronWorkspace, AsyncMutex>();
  private readonly mutex: AsyncMutex;
  private readonly connectorContext = new AsyncLocalStorage<string | undefined>();
  constructor(private readonly workspace: TronWorkspace, private readonly onChanged?: () => void, private readonly connectorEnvelope?: KnowledgeConnectorEnvelopeResolver) {
    this.mutex = KnowledgeStore.workspaceLocks.get(workspace) ?? new AsyncMutex(); KnowledgeStore.workspaceLocks.set(workspace, this.mutex);
  }

  private async paths(create: boolean): Promise<StorePaths> {
    const descriptor = await this.workspace.describe();
    if (!descriptor.available) throw new KnowledgeStoreError("unsafe", descriptor.reason === "closed" ? "Tron workspace is closed" : "Tron workspace is unavailable");
    const stateRoot = join(descriptor.root, "state");
    let stateRootPresent = true;
    try { await safeDirectory(stateRoot, false); } catch (error) {
      if (!(error instanceof KnowledgeStoreError) || !error.message.includes("unavailable")) throw error;
      stateRootPresent = false;
      if (create) { await safeDirectory(stateRoot, true); stateRootPresent = true; }
    }
    const root = join(stateRoot, "knowledge");
    if (!stateRootPresent) return { root, state: join(root, "state.json"), objects: join(root, "objects"), records: join(root, "records"), present: false, fresh: !(await this.workspace.featureInitialized("knowledge")) };
    let present = true;
    let fresh = false;
    try { await safeDirectory(root, false); } catch (error) {
      if (!(error instanceof KnowledgeStoreError) || !error.message.includes("unavailable")) throw error;
      present = false;
      fresh = !(await this.workspace.featureInitialized("knowledge"));
      if (create) { await safeDirectory(root, true); present = true; }
    }
    const paths = { root, state: join(root, "state.json"), objects: join(root, "objects"), records: join(root, "records"), present, fresh };
    if (!present) return paths;
    const marker = join(root, "initialized.json");
    const markerRead = await readSecureJson<unknown>(marker, 128);
    if (!markerRead.present) {
      if (!create) throw new KnowledgeStoreError("invalid", "Knowledge namespace exists without initialization evidence");
      // A namespace created by this owner is marked before its first state commit.
      await safeDirectory(paths.objects, true); await safeDirectory(paths.records, true);
      await durableAtomicWriteJson(marker, { version: 1 }, 0o600);
      await this.workspace.markFeatureInitialized("knowledge");
    } else if (JSON.stringify(markerRead.value) !== JSON.stringify({ version: 1 })) throw new KnowledgeStoreError("invalid", "Invalid knowledge initialization record");
    await safeDirectory(paths.objects, false); await safeDirectory(paths.records, false);
    return { ...paths, fresh };
  }
  private async load(paths: StorePaths, writable: boolean): Promise<{ state: KnowledgeState; present: boolean }> {
    let read;
    try { read = await readSecureJson<unknown>(paths.state, STATE_MAX_BYTES); }
    catch (error) { if (error instanceof SecureJsonFileError) throw new KnowledgeStoreError(error.kind === "unsafe" ? "unsafe" : "invalid", error.message); throw error; }
    if (!read.present) {
      if (!paths.fresh) throw new KnowledgeStoreError("invalid", "Initialized knowledge state is missing");
      if (!writable) return { state: catalogState(emptyState()), present: false };
      await this.createCatalog(paths, emptyState());
      return this.load(paths, true);
    }
    if (!read.value || typeof read.value !== "object" || Array.isArray(read.value)) throw new KnowledgeStoreError("invalid", "Invalid Knowledge state manifest");
    const manifest = read.value as { storageVersion?: number; schemaVersion?: number; catalogID?: string };
    if (manifest.storageVersion === undefined) {
      validateState(read.value);
      throw new KnowledgeStoreError("invalid", "Knowledge storage requires its one-time catalog upgrade before use");
    }
    if (manifest.storageVersion !== CATALOG_STORAGE_VERSION || manifest.schemaVersion !== KNOWLEDGE_SCHEMA_VERSION
      || typeof manifest.catalogID !== "string" || !/^[0-9a-f-]{36}$/.test(manifest.catalogID)) {
      throw new KnowledgeStoreError(manifest.storageVersion > CATALOG_STORAGE_VERSION ? "newer" : "invalid", "Unsupported Knowledge catalog manifest");
    }
    const path = join(paths.root, `catalog-${manifest.catalogID}.sqlite`);
    const before = await this.catalogFile(path);
    await this.catalogFile(`${path}-journal`, true);
    let catalog: KnowledgeCatalog | undefined;
    try {
      catalog = new KnowledgeCatalog(path, !writable);
      const after = await this.catalogFile(path);
      if (before!.ino !== after!.ino || before!.dev !== after!.dev) throw new KnowledgeStoreError("unsafe", "Knowledge catalog changed while opening");
      const control = catalog.control<CatalogControl>();
      if (control.catalogID !== manifest.catalogID || control.schemaVersion !== KNOWLEDGE_SCHEMA_VERSION || !Number.isSafeInteger(control.stateRevision) || control.stateRevision < 0) throw new KnowledgeStoreError("invalid", "Invalid Knowledge catalog control");
      validateKnowledgeConfig(control.config);
      for (const [key, value] of Object.entries(control.connectors ?? {})) { if (!/^[A-Za-z0-9._:-]{1,160}$/.test(key)) throw new KnowledgeStoreError("invalid", "Invalid connector state key"); if (value) validateConnectorState(value, value.connector); }
      return { state: catalogState(control, catalog), present: true };
    } catch (error) {
      catalog?.close();
      if (error instanceof KnowledgeStoreError) throw error;
      throw new KnowledgeStoreError("invalid", error instanceof Error ? error.message : "Knowledge catalog is unavailable");
    }
  }
  private async catalogFile(path: string, optional = false) {
    let info;
    try { info = await lstat(path); }
    catch (error) {
      if (optional && (error as NodeJS.ErrnoException).code === "ENOENT") return undefined;
      throw new KnowledgeStoreError("invalid", "Initialized Knowledge catalog is missing");
    }
    if (!info.isFile() || info.isSymbolicLink() || info.uid !== process.getuid?.() || (info.mode & 0o077) !== 0) throw new KnowledgeStoreError("unsafe", "Knowledge catalog must be an owner-only regular file");
    return info;
  }
  private control(state: KnowledgeState): CatalogControl {
    return { schemaVersion: state.schemaVersion, stateRevision: state.stateRevision, ...(state.catalogID ? { catalogID: state.catalogID } : {}),
      config: state.config, ...(state.connectors ? { connectors: state.connectors } : {}) };
  }
  private async save(_paths: StorePaths, state: KnowledgeState): Promise<void> {
    if (!state.catalog) throw new KnowledgeStoreError("invalid", "Knowledge catalog was not initialized");
    state.catalog.setControl(this.control(state));
    state.catalog.commit();
  }
  private async inspect<T>(action: (state: KnowledgeState, paths: StorePaths, present: boolean) => Promise<T>): Promise<T> {
    return this.mutex.run(async () => {
      const paths = await this.paths(false);
      const loaded = await this.load(paths, false);
      try { return await action(loaded.state, paths, loaded.present); }
      finally { loaded.state.catalog?.close(); }
    });
  }

  /** Explicit startup upgrade, before observation recovery/admission. Ordinary
   * reads never migrate. The old manifest stays authoritative until all exact
   * committed revisions have been validated and the new catalog is durable.
   */
  async upgradeStorage(): Promise<void> {
    await this.mutex.run(async () => {
      const paths = await this.paths(false);
      if (!paths.present) return;
      const read = await readSecureJson<unknown>(paths.state, LEGACY_MIGRATION_MAX_BYTES);
      if (!read.present) throw new KnowledgeStoreError("invalid", "Initialized knowledge state is missing");
      if (!read.value || typeof read.value !== "object" || Array.isArray(read.value)) throw new KnowledgeStoreError("invalid", "Invalid Knowledge state manifest");
      if ((read.value as { storageVersion?: unknown }).storageVersion !== undefined) {
        const loaded = await this.load(paths, false); loaded.state.catalog?.close(); return;
      }
      await this.createCatalog(paths, validateState(read.value));
    });
  }
  private async createCatalog(paths: StorePaths, legacy: LegacyKnowledgeState): Promise<void> {
    const catalogID = randomUUID();
    const path = join(paths.root, `catalog-${catalogID}.sqlite`);
    const file = await open(path, "wx", 0o600); await file.close();
    let catalog: KnowledgeCatalog | undefined;
    let prepared = false;
    try {
      catalog = new KnowledgeCatalog(path, false, true);
      catalog.begin();
      const state = catalogState({ schemaVersion: legacy.schemaVersion, stateRevision: legacy.stateRevision,
        catalogID, config: legacy.config, ...(legacy.connectors ? { connectors: legacy.connectors } : {}) }, catalog);
      for (const [id, head] of Object.entries(legacy.records)) {
        let latest: KnowledgeRecord | undefined;
        const objects = new Set<string>();
        for (const revision of head.revisionIds) {
          const record = await this.readRecord(paths, id, revision);
          for (const object of recordObjectRefs(record)) await this.assertObject(paths, object);
          for (const hash of recordObjectHashes(record)) objects.add(hash);
          if (revision === head.latestRevisionId) latest = record;
        }
        if (!latest) throw new KnowledgeStoreError("invalid", "Migration is missing a committed record head");
        const migratedHead = headFor(latest, head.revisionIds, [...objects]);
        state.records.set(id, migratedHead);
        for (const identity of migratedHead.sourceIdentities ?? []) state.sourceIdentities.set(identity, id);
        catalog.setRevisions(id, head.revisionIds);
      }
      for (const [id, value] of Object.entries(legacy.coverage)) state.coverage.set(id, value);
      for (const [id, value] of Object.entries(legacy.suppressions)) state.suppressions.set(id, value);
      for (const [id, value] of Object.entries(legacy.scopeExclusions)) state.scopeExclusions.set(id, value);
      for (const [id, value] of Object.entries(legacy.receipts)) state.receipts.set(id, value);
      for (const [id, value] of Object.entries(legacy.imports ?? {})) state.imports.set(id, value);
      for (const hash of legacy.cleanup) state.cleanup.set(hash, true);
      for (const item of legacy.recordCleanup ?? []) state.recordCleanup.set(cleanupKey(item), item);
      catalog.setControl(this.control(state));
      catalog.commit();
      prepared = true;
    } finally {
      catalog?.close();
      if (!prepared) await durableRemove(path).catch(() => {});
    }
    const durable = await open(path, constants.O_RDONLY | constants.O_NOFOLLOW);
    try { await durable.sync(); } finally { await durable.close(); }
    // A failure here may leave an ignored catalog, never half-migrate a corpus.
    // Do not delete it after an uncertain manifest rename/fsync outcome.
    await durableAtomicWriteJson(paths.state, { schemaVersion: KNOWLEDGE_SCHEMA_VERSION, storageVersion: CATALOG_STORAGE_VERSION, catalogID }, 0o600);
  }
  private recordPath(paths: StorePaths, id: string, revision: string): string { safeId(id, "record id"); safeId(revision, "record revision"); return join(paths.records, id, `${revision}.json`); }
  private async readRecord(paths: StorePaths, id: string, revision: string): Promise<KnowledgeRecord> {
    try { await safeDirectory(join(paths.records, id), false); }
    catch (error) { if (error instanceof KnowledgeStoreError && error.message.includes("unavailable")) throw new KnowledgeStoreError("invalid", `Record revision is missing: ${id}/${revision}`); throw error; }
    let value;
    try { value = await readSecureJson<unknown>(this.recordPath(paths, id, revision), RECORD_MAX_BYTES); }
    catch (error) { if (error instanceof SecureJsonFileError) throw new KnowledgeStoreError(error.kind === "unsafe" ? "unsafe" : "invalid", error.message); throw error; }
    if (!value.present) throw new KnowledgeStoreError("invalid", `Record revision is missing: ${id}/${revision}`);
    try { const record = validateKnowledgeRecord(value.value); if (record.id !== id || record.revisionId !== revision) throw new Error("Record identity does not match its path"); return record; }
    catch (error) { throw new KnowledgeStoreError("invalid", error instanceof Error ? error.message : "Invalid record revision"); }
  }
  private recordScope(record: KnowledgeRecord): { sessionId?: string; branchId?: string; projectId?: string } {
    if (record.kind === "observation") return {
      sessionId: record.content.range.sessionId,
      ...(record.content.range.branchId ? { branchId: record.content.range.branchId } : {}),
      ...(record.content.range.projectId ? { projectId: record.content.range.projectId } : {}),
    };
    return {
      ...(record.provenance.sessionId ? { sessionId: record.provenance.sessionId } : {}),
      ...(record.provenance.branchId ? { branchId: record.provenance.branchId } : {}),
    };
  }

  /** One predicate guards every read boundary, including derivatives and
   * object authorization. Scope exclusion is stronger than record kind. */
  private recordHardErased(state: KnowledgeState, record: KnowledgeRecord): boolean {
    if (state.suppressions.get(record.id)?.forgotten) return true;
    const forgotten = (id: string | undefined): boolean => id !== undefined && state.suppressions.get(id)?.forgotten === true;
    // Forget is a hard evidence fence, including historical revisions and
    // includeSuppressed reads. A derivative that still cites a forgotten
    // record is unavailable until its owning revision is scrubbed.
    if (record.provenance.evidence.some(evidence => forgotten(evidence.recordId)) || record.relations.some(relation => forgotten(relation.recordId))) return true;
    if (record.kind === "observation" && record.content.items.some(item => item.evidence?.some(evidence => forgotten(evidence.recordId)))) return true;
    if (record.kind === "note" && (record.content.fields?.some(field => field.evidence.some(evidence => forgotten(evidence.recordId))) || record.content.contraryEvidence?.some(evidence => forgotten(evidence.recordId)))) return true;
    return false;
  }

  private recordArchived(record: KnowledgeRecord): boolean {
    return record.kind === "source" && record.content.admission?.status === "archived";
  }
  private recordPending(record: KnowledgeRecord): boolean {
    return record.kind === "source" && record.content.admission?.status === "pending";
  }
  private recordExcluded(state: KnowledgeState, record: KnowledgeRecord): boolean {
    const suppression = state.suppressions.get(record.id);
    if (suppression?.excluded || suppression?.forgotten) return true;
    if (this.recordHardErased(state, record)) return true;
    const scope = this.recordScope(record);
    if (scope.sessionId && state.config.eligibility.excludedSessionIds.includes(scope.sessionId)) return true;
    if (scope.projectId && state.config.eligibility.excludedProjectIds.includes(scope.projectId)) return true;
    const keys = [
      ...(scope.sessionId ? [`session:${scope.sessionId}`] : []),
      ...(scope.sessionId && scope.branchId ? [`branch:${scope.sessionId}:${scope.branchId}`] : []),
      ...(scope.projectId ? [`project:${scope.projectId}`] : []),
    ];
    return keys.some(key => state.scopeExclusions.get(key)?.excluded);
  }
  private async receiptResult(paths: StorePaths, state: KnowledgeState, result: ReceiptResult): Promise<unknown> {
    if (result.kind === "value") return result.value;
    if (result.kind === "record") {
      if (state.suppressions.get(result.recordId)?.forgotten) throw conflict("Knowledge mutation result was forgotten");
      return { record: await this.readRecord(paths, result.recordId, result.revisionId), stateRevision: result.stateRevision } satisfies KnowledgeMutationResult;
    }
    if (result.records.some(item => state.suppressions.get(item.recordId)?.forgotten)) throw conflict("Knowledge mutation result was forgotten");
    const records = await Promise.all(result.records.map(item => this.readRecord(paths, item.recordId, item.revisionId)));
    return { records, coverage: result.coverage, stateRevision: result.stateRevision };
  }
  private receipt(result: unknown, stateRevision: number): { stored: ReceiptResult; recordIds: string[] } {
    if (result && typeof result === "object" && "record" in result && (result as { record?: unknown }).record && typeof (result as { record: KnowledgeRecord }).record === "object") {
      const record = (result as { record: KnowledgeRecord }).record;
      return { stored: { kind: "record", recordId: record.id, revisionId: record.revisionId, stateRevision }, recordIds: [record.id] };
    }
    if (result && typeof result === "object" && "records" in result && Array.isArray((result as { records?: unknown }).records)) {
      const records = (result as { records: KnowledgeRecord[] }).records;
      if (records.every(record => record && typeof record.id === "string" && typeof record.revisionId === "string")) {
        const coverage = (result as { coverage?: ObservationCoverage }).coverage;
        if (coverage) return { stored: { kind: "records", records: records.map(record => ({ recordId: record.id, revisionId: record.revisionId })), coverage, stateRevision }, recordIds: records.map(record => record.id) };
      }
    }
    return { stored: { kind: "value", value: result }, recordIds: [] };
  }
  private async mutate<T>(operation: string, commandId: string, request: unknown, action: (state: KnowledgeState, paths: StorePaths) => Promise<T>, afterCommit?: (state: KnowledgeState, paths: StorePaths, result: T) => Promise<void>, signal?: AbortSignal): Promise<T> {
    if (!/^[A-Za-z0-9._:-]{8,160}$/.test(commandId)) throw invalid("Mutating requests require a stable commandId");
    return this.mutex.run(async () => {
      if (signal?.aborted) throw new GatewayError("busy", "Knowledge mutation was cancelled", true);
      const paths = await this.paths(true); const { state } = await this.load(paths, true);
      try {
        const key = `${operation}\0${commandId}`; const hash = requestHash(operation, request); const prior = state.receipts.get(key);
        if (prior) { if (prior.operation !== operation || prior.requestHash !== hash) throw conflict("Command ID was already used for a different knowledge mutation"); if (prior.invalidated) throw conflict("Knowledge mutation result was forgotten"); return await this.receiptResult(paths, state, prior.result) as T; }
        if (signal?.aborted) throw new GatewayError("busy", "Knowledge mutation was cancelled", true);
        // This is mutation admission. Once action starts it can durably write
        // record bodies: cancellation must not abandon their catalog/receipt
        // transaction and strand inaccessible private data. Join the commit.
        state.catalog!.begin();
        const result = await action(state, paths);
        state.stateRevision += 1;
        const stored = this.receipt(result, state.stateRevision);
        state.receipts.set(key, { operation, requestHash: hash, result: stored.stored, recordIds: stored.recordIds, createdAt: now(), invalidated: false });
        const entries = [...state.receipts.entries()].sort(([, a], [, b]) => a.createdAt.localeCompare(b.createdAt));
        for (const [receiptKey] of entries.slice(0, Math.max(0, entries.length - RECEIPT_LIMIT))) state.receipts.delete(receiptKey);
        await this.save(paths, state);
        // Publish only after the authoritative commit, across RPC, agent tools,
        // connectors and autonomous observations. Receipt replays bypass this.
        // A disposable notification must never turn a committed write into failure.
        try { this.onChanged?.(); } catch { /* Reconnect reads canonical state. */ }
        // The tombstone/head transaction commits before physical cleanup. A
        // failed cleanup is durable pending work, never a resurrected record.
        if (afterCommit) {
          state.catalog!.begin();
          await afterCommit(state, paths, result).catch(() => {});
          await this.save(paths, state);
        }
        return result;
      } finally { state.catalog?.close(); }
    });
  }

  async status(): Promise<import("./knowledge-contract.js").KnowledgeStatus> {
    try {
      return await this.inspect(async (state, _paths, present) => {
        if (!present) return { available: true, state: "uninitialized", recordCount: 0, coverageCount: 0, coverage: coverageSummary([]), suppressedCount: 0, pendingCleanupCount: 0, config: structuredClone(DEFAULT_KNOWLEDGE_CONFIG), observationConfigured: false };
        const counts = state.catalog!.coverageCounts();
        const coverage = { observedCount: counts.observed ?? 0, emptyCount: counts.empty ?? 0, excludedCount: counts.excluded ?? 0,
          pendingCount: counts.pending ?? 0, failedCount: counts.failed ?? 0, unavailableCount: counts.unavailable ?? 0,
          remainingCount: OBSERVATION_ATTENTION_DISPOSITIONS.reduce((total, disposition) => total + (counts[disposition] ?? 0), 0) };
        return { available: true, state: "ready", stateRevision: state.stateRevision, recordCount: state.records.size, coverageCount: state.coverage.size, coverage,
          suppressedCount: state.catalog!.count("suppressions", "json_extract(value, '$.excluded') = 1 OR json_extract(value, '$.forgotten') = 1"),
          pendingCleanupCount: state.cleanup.size, config: state.config, observationConfigured: state.config.observation.enabled && state.config.observation.model !== undefined };
      });
    } catch (error) {
      const kind = error instanceof KnowledgeStoreError ? error.kind : "unsafe";
      return { available: false, state: kind, recordCount: 0, coverageCount: 0, coverage: coverageSummary([]), suppressedCount: 0, pendingCleanupCount: 0, config: structuredClone(DEFAULT_KNOWLEDGE_CONFIG), observationConfigured: false, detail: error instanceof Error ? error.message : String(error) };
    }
  }
  async config(): Promise<KnowledgeConfig> { return this.inspect(async state => state.config); }
  async configure(commandId: string, config: KnowledgeConfig): Promise<KnowledgeConfig> {
    try { validateKnowledgeConfig(config); } catch (error) { throw invalid(error instanceof Error ? error.message : "Invalid knowledge config"); }
    return this.mutate("knowledge.config", commandId, config, async state => { if (config.revision !== state.config.revision) throw conflict("Knowledge configuration revision is stale"); const next = structuredClone(config); next.revision += 1; state.config = next; return next; });
  }

  async withConnectorContext<T>(connectionId: string | undefined, task: () => Promise<T>): Promise<T> {
    return this.connectorContext.run(connectionId, task);
  }

  async connectorState(connector: "raindrop" | "x", connectionId?: string): Promise<KnowledgeConnectorState | undefined> {
    return this.inspect(async state => {
      const contextConnectionId = this.connectorContext.getStore();
      const key = connectionId ?? contextConnectionId;
      if (this.connectorEnvelope && !key) throw conflict("Connector state requires an admitted connection instance");
      const stateKey = key ?? connector;
      const value = state.connectors?.[stateKey];
      if (!value) return undefined;
      const next = structuredClone(value);
      const envelope = this.connectorEnvelope && key ? await this.connectorEnvelope(key) : undefined;
      if (this.connectorEnvelope && !envelope) throw conflict("Connector connection authority is unavailable");
      if (envelope) Object.assign(next, { enabled: envelope.policy.enabled, accountId: envelope.providerAccountId, ...(envelope.scope ? { scope: envelope.scope } : {}), credentialRef: envelope.credentialRef, allowWrites: envelope.policy.allowWrites, paidAccessApproved: envelope.policy.paidAccessApproved, paidBudgetCents: envelope.policy.paidBudgetCents, recurringApproved: envelope.policy.recurringApproved });
      return next;
    });
  }

  /** Resolve a provider identity through the canonical catalog index. The index
   * stores only opaque identity tuples and record IDs; source bodies remain
   * owner-only files and no corpus scan is needed for connector deduplication. */
  async sourceByIdentity(identity: { provider: string; accountId: string; itemId: string }): Promise<(KnowledgeRecord & { kind: "source" }) | undefined> {
    for (const [value, label] of [[identity.provider, "provider"], [identity.accountId, "accountId"], [identity.itemId, "itemId"]] as const) {
      if (typeof value !== "string" || value.length < 1 || value.length > 512) throw invalid(`Source ${label} identity is invalid`);
    }
    return this.inspect(async (state, paths) => {
      const recordId = state.sourceIdentities.get(sourceIdentityKey(identity));
      if (!recordId) return undefined;
      const record = await this.currentRecord(state, paths, recordId);
      if (!record || record.kind !== "source") return undefined;
      const matches = recordSourceIdentityKeys(record).includes(sourceIdentityKey(identity));
      return matches ? record : undefined;
    });
  }

  /** Connector operational state shares the knowledge owner’s serialized state;
   * this update never accepts or persists a credential value. */
  async updateConnectorState(commandId: string, connector: "raindrop" | "x", update: (current: KnowledgeConnectorState | undefined) => KnowledgeConnectorState, payload: unknown = { connector }, connectionId?: string): Promise<KnowledgeConnectorState> {
    const contextConnectionId = this.connectorContext.getStore();
    const key = connectionId ?? contextConnectionId;
    if (this.connectorEnvelope && !key) throw conflict("Connector state requires an admitted connection instance");
    const stateKey = key ?? connector;
    // Command receipts are scoped to the connection instance. Reusing a
    // command ID for another account must never replay this account's progress
    // or paid reservation.
    const receiptOperation = `knowledge.connector.state:${stateKey}`;
    const receiptPayload = { ...(payload && typeof payload === "object" && !Array.isArray(payload) ? payload as Record<string, unknown> : { payload }), connectionId: stateKey };
    return this.mutate(receiptOperation, commandId, receiptPayload, async state => {
      const current = state.connectors?.[stateKey] ? structuredClone(state.connectors[stateKey]) : undefined;
      const envelope = this.connectorEnvelope && key ? await this.connectorEnvelope(key) : undefined;
      if (this.connectorEnvelope && !envelope) throw conflict("Connector connection authority is unavailable");
      if (current && envelope) Object.assign(current, { enabled: envelope.policy.enabled, accountId: envelope.providerAccountId, ...(envelope.scope ? { scope: envelope.scope } : {}), credentialRef: envelope.credentialRef, allowWrites: envelope.policy.allowWrites, paidAccessApproved: envelope.policy.paidAccessApproved, paidBudgetCents: envelope.policy.paidBudgetCents, recurringApproved: envelope.policy.recurringApproved });
      const next = update(current);
      if (key) next.connectionId = key;
      validateConnectorState(next, connector);
      const persisted = structuredClone(next);
      if (envelope) for (const field of ["enabled", "accountId", "scope", "credentialRef", "allowWrites", "paidAccessApproved", "paidBudgetCents", "recurringApproved", "credentialAvailability", "providerIdentity"]) delete (persisted as unknown as Record<string, unknown>)[field];
      state.connectors = { ...(state.connectors ?? {}), [stateKey]: persisted };
      return next;
    });
  }

  async list(request: KnowledgeListRequest = {}): Promise<KnowledgeListResponse> {
    return this.inspect(async (state, paths) => {
      const limit = this.pageLimit(state, request.limit ?? 50);
      const scope = JSON.stringify([request.kind ?? null, request.scope ?? null, request.includeSuppressed === true, request.includeArchived === true]);
      const filter = this.catalogFilter(request);
      if (request.cursor) {
        const cursor = readListCursor(request.cursor, scope);
        filter.clauses.push("json_extract(value, '$.sortAt') <= ? AND (json_extract(value, '$.sortAt') < ? OR key > json_quote(?))");
        filter.parameters.push(cursor.sortAt, cursor.sortAt, cursor.id);
      }
      const records: KnowledgeRecord[] = []; const budget = new KnowledgePageBudget(); let nextCursor: string | undefined;
      let last: { id: string; sortAt: number } | undefined;
      for (const { key: id, value: head } of state.catalog?.scan<RecordHead>("records", filter.clauses.join(" AND "), filter.parameters, "json_extract(value, '$.sortAt') DESC, key") ?? []) {
        const record = await this.readRecord(paths, id, head.latestRevisionId);
        if (this.recordHardErased(state, record) || (!request.includeSuppressed && this.recordExcluded(state, record)) || (!request.includeArchived && this.recordArchived(record)) || (!request.includePending && this.recordPending(record))) continue;
        if (records.length >= limit || !budget.admit(record)) { nextCursor = listCursor(scope, last!); break; }
        records.push(record); last = { id, sortAt: head.sortAt };
      }
      return { records, stateRevision: state.stateRevision, ...(nextCursor ? { nextCursor } : {}) };
    });
  }
  private pageLimit(state: KnowledgeState, requested: number): number {
    const limit = Math.min(requested, state.config.maximumSearchResults);
    if (!Number.isSafeInteger(limit) || limit < 1) throw invalid("Invalid Knowledge page limit");
    return limit;
  }
  private catalogFilter(request: Pick<KnowledgeListRequest, "kind" | "scope">): { clauses: string[]; parameters: SQLInputValue[] } {
    const clauses: string[] = []; const parameters: SQLInputValue[] = [];
    if (request.kind) { clauses.push("json_extract(value, '$.kind') = ?"); parameters.push(request.kind); }
    if (request.scope) { clauses.push("json_extract(value, '$.scope') = ?"); parameters.push(request.scope); }
    return { clauses, parameters };
  }
  async read(id: string, revision?: string, includeSuppressed = false, includeArchived = false, includePending = false): Promise<KnowledgeRecord | null> {
    safeId(id, "record id"); if (revision !== undefined) safeId(revision, "knowledge revision");
    return this.inspect(async (state, paths) => {
      const head = state.records.get(id);
      if (!head) return null;
      const selected = revision ?? head.latestRevisionId;
      if (!head.revisionIds.includes(selected)) throw new KnowledgeStoreError("invalid", "Requested revision is not committed for this record");
      const record = await this.readRecord(paths, id, selected);
      const latest = await this.readRecord(paths, id, head.latestRevisionId);
      // Visibility is governed by the current head even when an audit caller
      // asks for an older immutable revision.
      if (this.recordHardErased(state, record) || this.recordHardErased(state, latest)) return null;
      if (!includeSuppressed && (this.recordExcluded(state, record) || this.recordExcluded(state, latest))) return null;
      if (!includeArchived && (this.recordArchived(record) || this.recordArchived(latest))) return null;
      if (!includePending && (this.recordPending(record) || this.recordPending(latest))) return null;
      return record;
    });
  }
  async search(request: KnowledgeSearchRequest): Promise<KnowledgeSearchResponse> {
    if (typeof request.query !== "string" || request.query.trim().length === 0 || request.query.length > 512) throw invalid("Search query must be non-empty and bounded");
    return this.inspect(async (state, paths) => {
      const terms = request.query.toLocaleLowerCase().split(/\s+/).filter(Boolean);
      const hits: KnowledgeSearchHit[] = []; const budget = new KnowledgePageBudget();
      const filter = this.catalogFilter(request); const limit = this.pageLimit(state, request.limit ?? 50);
      // Keep lexical substring semantics, including negation/exact values. SQL
      // scans canonical search fields, not thousands of immutable body files;
      // only selected, privacy-admitted hits are loaded into the response.
      const scoreSQL = `(SELECT coalesce(sum(${terms.map(() => "(instr(json_extract(field.value, '$[1]'), ?) > 0)").join(" + ")}), 0) FROM json_each(entries.value, '$.searchFields') AS field)`;
      filter.clauses.push(`${scoreSQL} > 0`); filter.parameters.push(...terms, ...terms);
      for (const { key: id } of state.catalog?.scan<RecordHead>("records", filter.clauses.join(" AND "), filter.parameters, `${scoreSQL} DESC, json_extract(value, '$.sortAt') DESC, key`) ?? []) {
        const record = await this.currentRecord(state, paths, id);
        if (!record || this.recordExcluded(state, record) || (!request.includeArchived && this.recordArchived(record)) || (!request.includePending && this.recordPending(record))) continue;
        if (hits.length >= limit) break;
        const matchedFields: string[] = []; let score = 0;
        for (const [field, value] of searchableFields(record)) {
          const lower = value.toLocaleLowerCase(); const count = terms.reduce((sum, term) => sum + (lower.includes(term) ? 1 : 0), 0);
          if (count) { matchedFields.push(field); score += count; }
        }
        const hit = { record, score, matchedFields };
        if (!budget.admit(hit)) break;
        hits.push(hit);
      }
      return { hits, stateRevision: state.stateRevision, indexState: "canonical" };
    });
  }
  async recall(request: KnowledgeRecallRequest): Promise<KnowledgeRecallResponse> {
    if (request.query !== undefined && (typeof request.query !== "string" || request.query.length > 512)) throw invalid("Recall query must be bounded");
    return this.inspect(async (state, paths) => {
      const terms = request.query?.toLocaleLowerCase().split(/\s+/).filter(Boolean) ?? [];
      const filter = this.catalogFilter(request); const limit = this.pageLimit(state, request.limit ?? 20);
      if (terms.length) {
        filter.clauses.push(`EXISTS (SELECT 1 FROM json_each(entries.value, '$.searchFields') AS field WHERE ${terms.map(() => "instr(json_extract(field.value, '$[1]'), ?) > 0").join(" AND ")})`);
        filter.parameters.push(...terms);
      }
      const records: KnowledgeRecord[] = []; const budget = new KnowledgePageBudget();
      for (const { key: id } of state.catalog?.scan<RecordHead>("records", filter.clauses.join(" AND "), filter.parameters, "json_extract(value, '$.sortAt') DESC, key") ?? []) {
        const record = await this.currentRecord(state, paths, id);
        if (!record || this.recordExcluded(state, record) || (!request.includeArchived && this.recordArchived(record)) || (!request.includePending && this.recordPending(record))) continue;
        if (record.kind === "observation" && request.sessionId && record.content.range.sessionId !== request.sessionId) continue;
        if (record.kind === "observation" && request.entryId && !record.content.range.entryIds.includes(request.entryId)) continue;
        const citations = [...record.provenance.evidence, ...(record.kind === "observation" ? record.content.items.flatMap(item => item.evidence ?? []) : [])];
        if (records.length >= limit || !budget.admit({ record, citations })) break;
        records.push(record);
      }
      const citations = records.flatMap(record => [...record.provenance.evidence, ...(record.kind === "observation" ? record.content.items.flatMap(item => item.evidence ?? []) : [])]);
      return { records, citations, stateRevision: state.stateRevision, availability: records.length ? "available" : "no-match" };
    });
  }
  /** Resolve exact revisions for generation without exposing a second search
   * authority. Every returned revision is still revalidated by synthesize at
   * the publication boundary. */
  async synthesisRevisions(sessionId: string, revisionIds: string[]): Promise<KnowledgeRecord[]> {
    safeId(sessionId, "session id");
    if (revisionIds.length === 0 || revisionIds.length > 100 || new Set(revisionIds).size !== revisionIds.length) throw invalid("Synthesis requires distinct source revisions");
    return this.inspect(async (state, paths) => {
      const records: KnowledgeRecord[] = [];
      for (const revision of revisionIds) {
        safeId(revision, "knowledge revision");
        const id = state.catalog?.revisionOwner(revision);
        if (!id) throw conflict("Synthesis source revision is unavailable");
        const record = await this.readRecord(paths, id, revision);
        if (record.kind === "observation" && record.content.range.sessionId !== sessionId) throw conflict("Synthesis observation is outside the requested session");
        if (record.kind !== "observation" && record.provenance.sessionId !== undefined && record.provenance.sessionId !== sessionId) throw conflict("Synthesis record is outside the requested session");
        if (this.recordExcluded(state, record) || this.recordArchived(record) || this.recordPending(record)) throw conflict("Synthesis source is unavailable or excluded");
        records.push(record);
      }
      return records;
    });
  }

  /** Resolve exact observation revisions for the Reflector without exposing a
   * second search/index authority. The caller still publishes through reflect,
   * which revalidates session, branch, suppression, and revision identity. */
  async observationRevisions(sessionId: string, revisionIds: string[]): Promise<KnowledgeRecord[]> {
    safeId(sessionId, "session id");
    if (revisionIds.length > 100) throw invalid("Observation revisions must be bounded");
    return this.inspect(async (state, paths) => {
      const records: KnowledgeRecord[] = [];
      for (const revision of new Set(revisionIds)) {
        safeId(revision, "knowledge revision");
        const id = state.catalog?.revisionOwner(revision);
        if (!id) continue;
        const record = await this.readRecord(paths, id, revision);
        if (record.kind === "observation" && record.content.range.sessionId === sessionId && !this.recordExcluded(state, record)) records.push(record);
      }
      return records;
    });
  }

  /** Internal source/import owner write. The transport action accepts URLs only. */
  async setSourceAdmission(request: { commandId: string; recordId: string; expectedRevision: string; status: import("./knowledge-contract.js").SourceAdmission; reason?: string; profileVersion?: string; rubricVersion?: string }): Promise<KnowledgeMutationResult> {
    return this.mutate("knowledge.source.admission", request.commandId, request, async (state, paths) => {
      const head = state.records.get(request.recordId);
      if (!head || head.latestRevisionId !== request.expectedRevision) throw conflict("Source revision is stale or unavailable");
      const current = await this.readRecord(paths, request.recordId, head.latestRevisionId);
      if (current.kind !== "source") throw conflict("Source revision is unavailable");
      const admission = { status: request.status, ...(request.reason ? { reason: request.reason } : {}), decidedAt: now(), ...(request.profileVersion ? { profileVersion: request.profileVersion } : {}), ...(request.rubricVersion ? { rubricVersion: request.rubricVersion } : {}) };
      return this.putRecord(state, paths, { kind: "source", id: current.id, createdAt: current.createdAt, scope: current.scope, provenance: current.provenance, relations: current.relations, ...(current.temporal ? { temporal: current.temporal } : {}), content: { ...current.content, admission } }, request.expectedRevision);
    });
  }
  async captureSource(request: SourceRecordWriteRequest): Promise<KnowledgeMutationResult> {
    const { signal, ...receiptRequest } = request;
    return this.mutate("knowledge.source.record-write", request.commandId, receiptRequest, async (state, paths) => this.putRecord(state, paths, request.record as KnowledgeRecordDraft, request.expectedRevision), undefined, signal);
  }
  async createNote(request: KnowledgeNoteMutationRequest & { recordId?: never }): Promise<KnowledgeMutationResult> { return this.mutate("knowledge.note.create", request.commandId, request, async (state, paths) => this.putRecord(state, paths, request.record)); }
  async updateNote(request: KnowledgeNoteMutationRequest & { recordId: string }): Promise<KnowledgeMutationResult> { return this.mutate("knowledge.note.update", request.commandId, request, async (state, paths) => { const current = await this.currentRecord(state, paths, request.recordId); if (!current || current.kind !== "note") throw conflict("Knowledge note does not exist"); if (request.expectedRevision !== current.revisionId) throw conflict("Knowledge note revision is stale"); return this.putRecord(state, paths, { ...request.record, id: request.recordId, createdAt: current.createdAt }, request.expectedRevision); }); }
  private async currentRecord(state: KnowledgeState, paths: StorePaths, id: string): Promise<KnowledgeRecord | null> { const head = state.records.get(id); return head ? this.readRecord(paths, id, head.latestRevisionId) : null; }
  private async putRecord(state: KnowledgeState, paths: StorePaths, draft: KnowledgeRecordDraft, expectedRevision?: string): Promise<KnowledgeMutationResult> {
    const id = draft.id ?? recordId(); safeId(id, "record id"); const existing = state.records.get(id); if (state.suppressions.get(id)?.forgotten) throw conflict("Knowledge record was forgotten and cannot be recreated");
    const current = existing ? await this.currentRecord(state, paths, id) : null; if (expectedRevision !== undefined && current?.revisionId !== expectedRevision) throw conflict("Knowledge record revision is stale"); if (expectedRevision === undefined && current) throw conflict("Knowledge record already exists; supply its expected revision");
    if (draft.kind === "source" && draft.content.object) await this.assertObject(paths, draft.content.object);
    if (draft.kind === "source" && draft.content.representations) for (const representation of draft.content.representations) await this.assertObject(paths, representation.object);
    const timestamp = now(); const record = { ...draft, schemaVersion: KNOWLEDGE_SCHEMA_VERSION, id, revisionId: revisionId(), createdAt: draft.createdAt ?? current?.createdAt ?? timestamp, updatedAt: draft.updatedAt ?? timestamp } as KnowledgeRecord;
    try { validateKnowledgeRecord(record); } catch (error) { throw invalid(error instanceof Error ? error.message : "Invalid knowledge record"); }
    if (Buffer.byteLength(`${JSON.stringify(record, null, 2)}\n`, "utf8") > RECORD_MAX_BYTES) throw invalid("Knowledge record exceeds its byte limit");
    await safeDirectory(join(paths.records, id), true);
    await durableAtomicWriteJson(this.recordPath(paths, id, record.revisionId), record, 0o600);
    const revisions = [...(existing?.revisionIds ?? []), record.revisionId];
    const nextHead = headFor(record, revisions, existing?.objectHashes);
    for (const identity of existing?.sourceIdentities ?? []) if (nextHead.sourceIdentities?.includes(identity) !== true) state.sourceIdentities.delete(identity);
    for (const identity of nextHead.sourceIdentities ?? []) state.sourceIdentities.set(identity, id);
    state.records.set(id, nextHead);
    state.catalog!.setRevisions(id, revisions);
    return { record, stateRevision: state.stateRevision + 1 };
  }
  private excludedRange(state: KnowledgeState, range: ObservationRange): boolean {
    return !knowledgeScopeEligible(state.config.eligibility, range)
      || scopeKey(range).some(key => state.scopeExclusions.get(key)?.excluded);
  }

  /** Shared privacy predicate for recall/display owners. A historical record
   * remains stored for audit until forgotten, but excluded scope is not usable
   * evidence and must be filtered before presentation or model boundaries. */
  async scopeExcluded(scope: { sessionId?: string; branchId?: string; projectId?: string }): Promise<boolean> {
    return this.inspect(async state => {
      const keys = [
        ...(scope.sessionId ? [`session:${scope.sessionId}`] : []),
        ...(scope.sessionId && scope.branchId ? [`branch:${scope.sessionId}:${scope.branchId}`] : []),
        ...(scope.projectId ? [`project:${scope.projectId}`] : []),
      ];
      return keys.some(key => state.scopeExclusions.get(key)?.excluded)
        || (scope.sessionId ? state.config.eligibility.excludedSessionIds.includes(scope.sessionId) : false)
        || (scope.projectId ? state.config.eligibility.excludedProjectIds.includes(scope.projectId) : false);
    });
  }
  async publishObservationGroup(input: ObservationGroupInput, signal?: AbortSignal): Promise<{ records: KnowledgeRecord[]; coverage: ObservationCoverage; stateRevision: number }> {
    return this.mutate("knowledge.observation.publish", input.commandId, input, async (state, paths) => {
      if (signal?.aborted) throw new GatewayError("busy", "Observation publication was cancelled", true);
      if (input.expectedConfigRevision !== undefined && state.config.revision !== input.expectedConfigRevision) throw conflict("Observation configuration changed while inference was running");
      if (this.excludedRange(state, input.coverage.range)) throw conflict("Observation range is excluded"); const prior = state.coverage.get(input.coverage.id);
      if (prior && !sameRange(prior.range, input.coverage.range)) throw conflict("Observation coverage identity changed");
      if (prior && input.expectedCoverageRevision !== prior.revisionId) throw conflict("Observation coverage revision is stale"); if (!prior && input.expectedCoverageRevision !== undefined) throw conflict("Observation coverage does not exist");
      if (prior && ["observed", "empty", "excluded"].includes(prior.disposition)) throw conflict("Terminal observation coverage cannot be replaced");
      const records: KnowledgeRecord[] = [];
      for (const draft of input.records) { if (!sameRange(draft.content.range, input.coverage.range)) throw invalid("Observation record range does not match coverage"); const result = await this.putRecord(state, paths, draft); records.push(result.record); }
      if (input.coverage.disposition === "observed" && records.length === 0) throw invalid("Observed coverage requires an observation record");
      const coverage: ObservationCoverage = { ...input.coverage, schemaVersion: KNOWLEDGE_SCHEMA_VERSION, revisionId: revisionId(), groupRevisionIds: records.map(record => record.revisionId), recordedAt: now() }; validateCoverage(coverage);
      // Record bodies are durable first; one catalog transaction admits all
      // heads and coverage together. No growing group-manifest journal is needed.
      state.coverage.set(coverage.id, coverage); return { records, coverage, stateRevision: state.stateRevision + 1 };
    });
  }
  async dismissCoverage(request: KnowledgeCoverageDismissRequest): Promise<{ coverage: ObservationCoverage; stateRevision: number }> {
    safeId(request.coverageId, "coverage id"); safeId(request.expectedRevision, "coverage revision");
    return this.mutate("knowledge.observation.dismiss", request.commandId, request, async state => {
      const current = state.coverage.get(request.coverageId);
      if (!current || current.revisionId !== request.expectedRevision) throw conflict("Observation coverage changed; reload before clearing it");
      if (!["failed", "unavailable"].includes(current.disposition) || current.groupRevisionIds.length) throw conflict("Only failed or unavailable observation cuts can be cleared");
      // Keep the exact cut as a terminal skip, not a deletion that would allow
      // recovery to re-admit it. This never excludes its session or project.
      const coverage: ObservationCoverage = { ...current, disposition: "excluded", revisionId: revisionId(),
        reason: `dismissed-by-user: ${current.reason ?? current.disposition}` };
      state.coverage.set(coverage.id, coverage);
      return { coverage, stateRevision: state.stateRevision + 1 };
    });
  }
  async setCoverage(input: CoverageUpdateInput, signal?: AbortSignal): Promise<{ coverage: ObservationCoverage; stateRevision: number }> {
    return this.mutate("knowledge.observation.coverage", input.commandId, input, async (state, paths) => {
      if (input.expectedConfigRevision !== undefined && state.config.revision !== input.expectedConfigRevision) throw conflict("Observation configuration changed while inference was running");
      if (this.excludedRange(state, input.coverage.range) && input.coverage.disposition !== "excluded") throw conflict("Observation range is excluded"); const current = state.coverage.get(input.coverage.id);
      if (current && !sameRange(current.range, input.coverage.range)) throw conflict("Observation coverage identity changed");
      if (input.expectedRevision !== undefined && current?.revisionId !== input.expectedRevision) throw conflict("Observation coverage revision is stale");
      if (current && ["observed", "empty", "excluded", "unavailable"].includes(current.disposition)) {
        if (current.disposition !== input.coverage.disposition || current.groupRevisionIds.join("\0") !== input.coverage.groupRevisionIds.join("\0")) throw conflict("Terminal observation coverage cannot be replaced");
        return { coverage: current, stateRevision: state.stateRevision };
      }
      if (input.coverage.disposition === "observed") {
        if (!input.coverage.groupRevisionIds.length) throw invalid("Observed coverage requires committed group records");
        for (const revision of input.coverage.groupRevisionIds) {
          const found = state.catalog!.revisionOwner(revision);
          if (!found) throw invalid("Observed coverage references an unknown record revision");
          const record = await this.readRecord(paths, found, revision);
          if (record.kind !== "observation" || !sameRange(record.content.range, input.coverage.range)) throw invalid("Observed coverage references a record from another input range");
        }
      }
      const coverage: ObservationCoverage = { ...input.coverage, schemaVersion: KNOWLEDGE_SCHEMA_VERSION, revisionId: revisionId(), recordedAt: now() }; validateCoverage(coverage); state.coverage.set(coverage.id, coverage); return { coverage, stateRevision: state.stateRevision + 1 };
    }, undefined, signal);
  }
  /** Publish a bounded SOURCE/NOTE/OBSERVATION synthesis as an unconfirmed
   * derived note. The expected configuration and exact revision set are
   * checked inside the serialized mutation, so late cancellation/config or
   * privacy changes cannot publish stale generated content. */
  async synthesize(commandId: string, sessionId: string, sourceRevisionIds: string[], text: string, expectedConfigRevision: number, signal?: AbortSignal): Promise<KnowledgeMutationResult> {
    safeId(sessionId, "session id");
    if (!text || text.length > 30_000 || sourceRevisionIds.length === 0 || sourceRevisionIds.length > 100 || new Set(sourceRevisionIds).size !== sourceRevisionIds.length) throw invalid("Synthesis is bounded and requires distinct source revisions");
    return this.mutate("knowledge.synthesis", commandId, { sessionId, sourceRevisionIds, text, expectedConfigRevision }, async (state, paths) => {
      if (signal?.aborted) throw new GatewayError("busy", "Knowledge synthesis was cancelled", true);
      if (state.config.revision !== expectedConfigRevision) throw conflict("Knowledge configuration changed while synthesis was running");
      const sources: KnowledgeRecord[] = [];
      for (const revision of sourceRevisionIds) {
        const id = state.catalog!.revisionOwner(revision);
        const source = id ? await this.readRecord(paths, id, revision) : undefined;
        if (!source || this.recordExcluded(state, source)) throw conflict("Synthesis source changed or became unavailable");
        if (source.kind === "observation" && source.content.range.sessionId !== sessionId) throw conflict("Synthesis observation is outside the requested session");
        if (source.kind !== "observation" && source.provenance.sessionId !== undefined && source.provenance.sessionId !== sessionId) throw conflict("Synthesis record is outside the requested session");
        sources.push(source);
      }
      const scopes = new Set(sources.map(source => source.scope));
      if (scopes.size !== 1) throw conflict("Synthesis sources must share one privacy scope");
      if (signal?.aborted) throw new GatewayError("busy", "Knowledge synthesis was cancelled", true);
      const evidence = sources.map(source => ({ recordId: source.id, revisionId: source.revisionId }));
      const contraryEvidence = sources.flatMap(source => source.kind === "note" ? (source.content.contraryEvidence ?? []) : []);
      const relations = sources.map(source => ({ type: "derivedFrom" as const, recordId: source.id, revisionId: source.revisionId }));
      const sourceSetDigest = createHash("sha256").update(JSON.stringify(sourceRevisionIds.map((revision, index) => `${sources[index]!.id}:${revision}`))).digest("hex");
      const synthesisId = `synthesis-${createHash("sha256").update(`${sessionId}\\0${sourceSetDigest}`).digest("hex").slice(0, 48)}`;
      const existing = await this.currentRecord(state, paths, synthesisId);
      if (existing && existing.kind !== "note") throw conflict("Synthesis identity is occupied by another record kind");
      const record: KnowledgeRecordDraft & { kind: "note" } = {
        id: synthesisId, ...(existing ? { createdAt: existing.createdAt } : {}), kind: "note", scope: sources[0]!.scope,
        provenance: { actor: "agent", source: `synthesis:${sourceSetDigest}`, sessionId, evidence }, relations,
        content: { title: "Knowledge synthesis", body: text, role: "synthesis", confirmed: false, ...(contraryEvidence.length ? { contraryEvidence } : {}) },
      };
      return this.putRecord(state, paths, record, existing?.revisionId);
    });
  }

  async reflect(commandId: string, sessionId: string, sourceRevisionIds: string[], text: string, expectedConfigRevision: number, signal?: AbortSignal): Promise<KnowledgeMutationResult> {
    safeId(sessionId, "session id");
    if (!text || text.length > 30_000 || sourceRevisionIds.length === 0 || sourceRevisionIds.length > 100 || new Set(sourceRevisionIds).size !== sourceRevisionIds.length) throw invalid("Reflection is bounded and requires distinct source revisions");
    return this.mutate("knowledge.reflect", commandId, { sessionId, sourceRevisionIds, text, expectedConfigRevision }, async (state, paths) => {
      // Configuration and cancellation are checked after waiting for the real
      // store mutex: queued work has not yet become an accepted mutation.
      if (signal?.aborted) throw new GatewayError("busy", "Knowledge reflection was cancelled", true);
      if (state.config.revision !== expectedConfigRevision) throw conflict("Knowledge configuration changed while reflection was running");
      const evidence: KnowledgeEvidenceRef[] = []; const relations: KnowledgeRecord["relations"] = []; let branchId: string | null = null; let branchInitialized = false;
      const sources: KnowledgeRecord[] = [];
      for (const revision of sourceRevisionIds) {
        const id = state.catalog!.revisionOwner(revision);
        const source = id ? await this.readRecord(paths, id, revision) : undefined;
        if (!source || source.kind !== "observation" || source.content.range.sessionId !== sessionId) throw invalid("Reflection source is not an observation in this session");
        if (state.suppressions.get(source.id)?.excluded || this.excludedRange(state, source.content.range)) throw conflict("Reflection source is excluded");
        const sourceBranchId = source.content.range.branchId ?? null;
        if (branchInitialized && branchId !== sourceBranchId) throw invalid("Reflection sources must share a branch");
        branchId = sourceBranchId;
        branchInitialized = true;
        sources.push(source);
        evidence.push({ recordId: source.id, revisionId: source.revisionId });
        relations.push({ type: "derivedFrom", recordId: source.id, revisionId: source.revisionId });
      }
      // The derivative identity is session/branch-local, while its provenance
      // digest changes with the exact captured record/revision set. Replacing
      // the derivative therefore preserves history and never absorbs later
      // observations that were not in this request.
      const sourceSet = sources.map(source => `${source.id}:${source.revisionId}`).sort();
      const sourceSetDigest = createHash("sha256").update(JSON.stringify(sourceSet)).digest("hex");
      const reflectionId = `reflection-${createHash("sha256").update(`${sessionId}\0${branchId ?? ""}`).digest("hex").slice(0, 48)}`;
      const existing = await this.currentRecord(state, paths, reflectionId);
      if (existing && existing.kind !== "note") throw conflict("Reflection identity is occupied by another record kind");
      const record: KnowledgeRecordDraft & { kind: "note" } = { id: reflectionId, ...(existing ? { createdAt: existing.createdAt } : {}), kind: "note", scope: "personal", provenance: { actor: "agent", source: `reflection:${sourceSetDigest}`, sessionId, ...(branchId === null ? {} : { branchId }), evidence }, relations, content: { title: "Session reflection", body: text, role: "synthesis", confirmed: false } };
      return this.putRecord(state, paths, record, existing?.revisionId);
    });
  }
  async correct(commandId: string, recordId: string, expectedRevision: string, replacement: KnowledgeRecordDraft, relation: KnowledgeRecord["relations"][number]): Promise<KnowledgeMutationResult> { return this.mutate("knowledge.correction", commandId, { recordId, expectedRevision, replacement, relation }, async (state, paths) => { const current = await this.currentRecord(state, paths, recordId); if (!current || current.revisionId !== expectedRevision) throw conflict("Knowledge record revision is stale"); if (relation.recordId !== recordId || relation.revisionId !== expectedRevision || (relation.type !== "corrects" && relation.type !== "supersedes")) throw invalid("Correction relation must identify the replaced revision"); return this.putRecord(state, paths, { ...replacement, id: recordId, createdAt: current.createdAt, relations: [...replacement.relations, relation] }, expectedRevision); }); }
  async setScopeExclusion(commandId: string, scope: { sessionId?: string; branchId?: string; projectId?: string }, excluded: boolean, reason?: string): Promise<{ excluded: boolean; stateRevision: number }> {
    if (!scope.sessionId && !scope.projectId) throw invalid("Scope exclusion requires a session or project"); return this.mutate("knowledge.scope-exclusion", commandId, { scope, excluded, reason }, async state => { const key = scope.sessionId ? (scope.branchId ? `branch:${scope.sessionId}:${scope.branchId}` : `session:${scope.sessionId}`) : `project:${scope.projectId}`; state.scopeExclusions.set(key, { ...scope, excluded, ...(reason === undefined ? {} : { reason }), updatedAt: now() }); return { excluded, stateRevision: state.stateRevision + 1 }; });
  }
  async setExclusion(commandId: string, recordId: string, excluded: boolean, expectedRevision?: string, reason?: string): Promise<{ recordId: string; excluded: boolean; stateRevision: number }> { return this.mutate("knowledge.exclusion", commandId, { recordId, excluded, expectedRevision, reason }, async (state, paths) => { const current = await this.currentRecord(state, paths, recordId); if (!current) throw conflict("Knowledge record does not exist"); if (expectedRevision !== undefined && expectedRevision !== current.revisionId) throw conflict("Knowledge record revision is stale"); state.suppressions.set(recordId, { excluded, forgotten: false, ...(reason === undefined ? {} : { reason }), updatedAt: now() }); return { recordId, excluded, stateRevision: state.stateRevision + 1 }; }); }
  async forget(commandId: string, recordId: string, reason: string, expectedRevision?: string): Promise<KnowledgeForgetResult> {
    if (!reason || reason.length > 1_000) throw invalid("Forget reason is required and bounded");
    return this.mutate("knowledge.forget", commandId, { recordId, reason, expectedRevision }, async (state, paths) => {
      const history = state.records.get(recordId); const current = history ? await this.currentRecord(state, paths, recordId) : null; if (!current) throw conflict("Knowledge record does not exist"); if (expectedRevision !== undefined && expectedRevision !== current.revisionId) throw conflict("Knowledge record revision is stale");
      // The tombstone, object cleanup intent, and derivative redactions are
      // published atomically before any canonical revision is removed.
      for (const revision of history!.revisionIds) {
        const item = { recordId, revisionId: revision }; state.recordCleanup.set(cleanupKey(item), item);
        const record = await this.readRecord(paths, recordId, revision);
        for (const identity of recordSourceIdentityKeys(record)) state.sourceIdentities.delete(identity);
        for (const hash of recordObjectHashes(record)) state.cleanup.set(hash, true);
      }
      state.records.delete(recordId); state.catalog!.setRevisions(recordId, []);
      state.suppressions.set(recordId, { excluded: true, forgotten: true, reason, updatedAt: now() });
      for (const [key, receipt] of state.receipts.entries()) if (receipt.recordIds.includes(recordId)) {
        state.receipts.set(key, { ...receipt, recordIds: [], result: { kind: "value", value: null }, invalidated: true });
      }
      // Derivative references are redacted and hidden, rather than leaving a
      // current unsupported claim available after its evidence is forgotten.
      const scrubbedRecordIds = new Set<string>();
      for (const { key: id, value: head } of state.catalog!.scan<RecordHead>("records",
        "EXISTS (SELECT 1 FROM json_each(entries.value, '$.recordRefs') AS ref WHERE ref.value = ?)", [recordId], "key")) {
        const derivative = await this.readRecord(paths, id, head.latestRevisionId);
        const scrubbed = scrubReferences(derivative, recordId);
        if (scrubbed) {
          // Historical derivative revisions are replay/object routes too. Queue
          // every pre-scrub revision for durable removal, not only the latest
          // head, while retaining the scrubbed tombstone until cleanup runs.
          for (const revisionId of head.revisionIds) {
            const item = { recordId: id, revisionId }; state.recordCleanup.set(cleanupKey(item), item);
          }
          await durableAtomicWriteJson(this.recordPath(paths, id, scrubbed.revisionId), scrubbed, 0o600);
          state.records.set(id, headFor(scrubbed, [scrubbed.revisionId]));
          state.catalog!.setRevisions(id, [scrubbed.revisionId]);
          state.suppressions.set(id, { excluded: true, forgotten: false, reason: "Dependent evidence was forgotten", updatedAt: now() });
          scrubbedRecordIds.add(id);
        }
      }
      // A receipt is another replay path. Invalidate receipts for every
      // derivative rewritten by the forget, not only the forgotten source.
      for (const [key, receipt] of state.receipts.entries()) if (receipt.recordIds.some(id => scrubbedRecordIds.has(id))) {
        state.receipts.set(key, { ...receipt, recordIds: [], result: { kind: "value", value: null }, invalidated: true });
      }
      return { forgotten: true, recordId, stateRevision: state.stateRevision + 1 };
    }, async (state, paths) => {
      // A failed post-commit deletion is safe: the state no longer references
      // these files. Pending paths remain durable for reconcile() to retry.
      let changed = false;
      for (const [key, item] of state.recordCleanup.entries()) {
        try { await durableRemove(this.recordPath(paths, item.recordId, item.revisionId)); state.recordCleanup.delete(key); changed = true; }
        catch { /* The committed cleanup row remains available for reconcile. */ }
      }
      if (changed) state.stateRevision += 1;
    });
  }
  async importCheckpoint(planHash: string): Promise<KnowledgeImportCheckpoint | null> {
    if (!OBJECT_HASH.test(planHash)) throw invalid("Invalid import plan hash");
    return this.inspect(async state => state.imports.get(planHash) ?? null);
  }
  async beginImport(commandId: string, planHash: string, plannedRecordIds: string[]): Promise<KnowledgeImportCheckpoint> {
    if (!OBJECT_HASH.test(planHash) || plannedRecordIds.length > 20_000 || plannedRecordIds.some(id => { try { assertKnowledgeId(id, "import record id"); return false; } catch { return true; } })) throw invalid("Invalid import batch");
    const unique = [...new Set(plannedRecordIds)]; if (unique.length !== plannedRecordIds.length) throw invalid("Import batch contains duplicate record IDs");
    return this.mutate("knowledge.import.begin", commandId, { planHash, plannedRecordIds: unique }, async state => {
      const existing = state.imports.get(planHash);
      if (existing && (existing.plannedRecordIds.length !== unique.length || existing.plannedRecordIds.some((id, index) => id !== unique[index]))) throw conflict("Import plan membership changed");
      const checkpoint = existing ?? { planHash, plannedRecordIds: unique, completedRecordIds: [], updatedAt: now() };
      state.imports.set(planHash, checkpoint); return structuredClone(checkpoint);
    });
  }
  async markImportRecord(commandId: string, planHash: string, recordId: string): Promise<KnowledgeImportCheckpoint> {
    if (!OBJECT_HASH.test(planHash)) throw invalid("Invalid import plan hash"); assertKnowledgeId(recordId, "import record id");
    return this.mutate("knowledge.import.progress", commandId, { planHash, recordId }, async state => {
      const checkpoint = state.imports.get(planHash); if (!checkpoint || !checkpoint.plannedRecordIds.includes(recordId)) throw conflict("Import record is outside the planned batch");
      if (!checkpoint.completedRecordIds.includes(recordId)) checkpoint.completedRecordIds.push(recordId);
      checkpoint.updatedAt = now(); state.imports.set(planHash, checkpoint); return structuredClone(checkpoint);
    });
  }

  async putObject(bytes: Uint8Array, mediaType: string): Promise<KnowledgeObjectRef> {
    if (bytes.byteLength > OBJECT_MAX_BYTES || !mediaType || mediaType.length > 160) throw invalid("Content object is too large or has an invalid media type"); const hash = createHash("sha256").update(bytes).digest("hex");
    return this.mutex.run(async () => {
      const paths = await this.paths(true); const loaded = await this.load(paths, true);
      try {
        const path = join(paths.objects, hash); const existing = await readSecureBytes(path, OBJECT_MAX_BYTES);
        if (existing) {
          if (existing.byteLength !== bytes.byteLength || createHash("sha256").update(existing).digest("hex") !== hash) throw new KnowledgeStoreError("invalid", "Existing knowledge object bytes do not match their identity");
        } else { await durableAtomicWriteBytes(path, bytes); }
        return { hash, mediaType, bytes: bytes.byteLength };
      } finally { loaded.state.catalog?.close(); }
    });
  }
  private async assertObject(paths: StorePaths, ref: KnowledgeObjectRef): Promise<void> { validateObjectRef(ref); const bytes = await readSecureBytes(join(paths.objects, ref.hash), OBJECT_MAX_BYTES); if (!bytes || bytes.byteLength !== ref.bytes || createHash("sha256").update(bytes).digest("hex") !== ref.hash) throw conflict("Referenced knowledge object bytes are not durably captured"); }
  private async exactObjectAuthority(paths: StorePaths, state: KnowledgeState, ref: KnowledgeObjectRef, recordId: string, revisionId: string, includeArchived = false): Promise<boolean> {
    const head = state.records.get(recordId);
    if (!head || !head.revisionIds.includes(revisionId)) return false;
    const record = await this.readRecord(paths, recordId, revisionId);
    const latest = await this.readRecord(paths, recordId, head.latestRevisionId);
    if (this.recordExcluded(state, latest) || (!includeArchived && this.recordArchived(latest)) || this.recordPending(latest)) return false;
    // The caller's exact revision is the authority. Do not fall back to a
    // corpus scan or an evidence hash, since either can authorize an object
    // after its source has been excluded or replaced.
    return recordObjectRefs(record).some(candidate => candidate.hash === ref.hash
      && candidate.bytes === ref.bytes && candidate.mediaType === ref.mediaType);
  }

  async readObject(ref: KnowledgeObjectRef, authority: { recordId: string; revisionId: string; includeArchived?: boolean }): Promise<Uint8Array | null> {
    validateObjectRef(ref);
    assertKnowledgeId(authority.recordId, "object authority record id");
    assertKnowledgeId(authority.revisionId, "object authority revision");
    const admittedPath = await this.inspect(async (state, paths, present) =>
      present && await this.exactObjectAuthority(paths, state, ref, authority.recordId, authority.revisionId, authority.includeArchived === true) ? join(paths.objects, ref.hash) : null);
    if (!admittedPath) return null;
    // Release the catalog while reading bytes, then recheck exact authority.
    // A concurrent forget/exclusion must win over the initial admission.
    const bytes = await readSecureBytes(admittedPath, OBJECT_MAX_BYTES);
    if (!bytes) return null;
    if (bytes.byteLength !== ref.bytes || createHash("sha256").update(bytes).digest("hex") !== ref.hash) throw new KnowledgeStoreError("invalid", "Knowledge object failed hash or size verification");
    return this.inspect(async (state, paths, present) =>
      present && await this.exactObjectAuthority(paths, state, ref, authority.recordId, authority.revisionId, authority.includeArchived === true) ? bytes : null);
  }
  async reconcile(): Promise<KnowledgeReconcileResult> {
    return this.mutex.run(async () => {
      const paths = await this.paths(false);
      const inspected = await this.load(paths, false);
      inspected.state.catalog?.close();
      if (!inspected.present) return { removedObjects: [], pendingObjects: [], stateRevision: 0 };
      const { state } = await this.load(paths, true);
      try {
        state.catalog!.begin();
        const removedObjects: string[] = []; const pendingObjects: string[] = []; let changed = false;
        for (const hash of state.cleanup.keys()) {
          const referenced = state.catalog!.rows<RecordHead>("records", "EXISTS (SELECT 1 FROM json_each(entries.value, '$.objectHashes') AS ref WHERE ref.value = ?)", [hash], "key", 1).length > 0;
          if (referenced) continue;
          try { await durableRemove(join(paths.objects, hash)); removedObjects.push(hash); state.cleanup.delete(hash); changed = true; }
          catch { pendingObjects.push(hash); }
        }
        for (const [key, item] of state.recordCleanup.entries()) {
          try { await durableRemove(this.recordPath(paths, item.recordId, item.revisionId)); state.recordCleanup.delete(key); changed = true; }
          catch { /* Keep the exact pending cleanup row. */ }
        }
        if (changed) state.stateRevision += 1;
        await this.save(paths, state);
        return { removedObjects, pendingObjects, stateRevision: state.stateRevision };
      } finally { state.catalog?.close(); }
    });
  }
  async coverage(id: string): Promise<ObservationCoverage | null> {
    safeId(id, "coverage id"); return this.inspect(async state => state.coverage.get(id) ?? null);
  }

  /** Coverage pages seek through the canonical date index. A missing cursor
   * fails explicitly rather than silently replaying the first page. An optional
   * disposition filter lets a client list the cuts that need attention without
   * scanning a ledger whose rows are mostly settled. */
  async observationCoveragePage(limit = 100, cursor?: string, dispositions?: ObservationCoverageDisposition[]): Promise<KnowledgeCoveragePage> {
    if (!Number.isSafeInteger(limit) || limit < 1 || limit > 100) throw new KnowledgeStoreError("invalid", "Invalid observation coverage page limit");
    if (cursor !== undefined) safeId(cursor, "observation coverage cursor");
    if (dispositions !== undefined && (dispositions.length === 0 || dispositions.length > OBSERVATION_COVERAGE_DISPOSITIONS.length
      || new Set(dispositions).size !== dispositions.length
      || dispositions.some(disposition => !OBSERVATION_COVERAGE_DISPOSITIONS.includes(disposition)))) {
      throw invalid("Invalid observation coverage disposition filter");
    }
    return this.inspect(async state => {
      const anchor = cursor ? state.coverage.get(cursor) : undefined;
      if (cursor && !anchor) throw invalid("Observation coverage cursor is unavailable; reload coverage");
      const conditions: string[] = []; const parameters: SQLInputValue[] = [];
      // A cut's recordedAt only ever moves forward (new and re-recorded cuts are
      // stamped with now()), so a filtered page keeps one coherent cursor.
      if (anchor) { conditions.push("json_extract(value, '$.recordedAt') >= ? AND (json_extract(value, '$.recordedAt') > ? OR key > json_quote(?))"); parameters.push(anchor.recordedAt, anchor.recordedAt, anchor.id); }
      if (dispositions) { conditions.push(`json_extract(value, '$.disposition') IN (${dispositions.map(() => "?").join(", ")})`); parameters.push(...dispositions); }
      const rows = state.catalog?.scan<ObservationCoverage>("coverage", conditions.join(" AND "), parameters, "json_extract(value, '$.recordedAt'), key") ?? [];
      const coverage: ObservationCoverage[] = []; const budget = new KnowledgePageBudget(); let nextCursor: string | undefined;
      for (const { value } of rows) {
        validateCoverage(value);
        if (coverage.length >= limit || !budget.admit(value)) { nextCursor = coverage.at(-1)!.id; break; }
        coverage.push(value);
      }
      return { coverage, stateRevision: state.stateRevision, ...(nextCursor ? { nextCursor } : {}) };
    });
  }

  /** Pending/failed cuts are recovery inputs, not a second journal. */
  async pendingObservationCoverage(limit = 100): Promise<ObservationCoverage[]> {
    if (!Number.isSafeInteger(limit) || limit < 1 || limit > 100) throw new KnowledgeStoreError("invalid", "Invalid observation recovery limit");
    return this.inspect(async state => (state.catalog?.rows<ObservationCoverage>("coverage",
      "json_extract(value, '$.disposition') IN ('pending', 'failed')", [], "json_extract(value, '$.recordedAt'), key", limit) ?? [])
      .map(({ value }) => { validateCoverage(value); return value; }));
  }

  /** Only cuts whose start lies in the incoming canonical entries are needed
   * to advance that exact prefix. Old turns must not grow per-turn read work. */
  async observationCoverageForScope(sessionId: string, branchId?: string, projectId?: string, entryIds?: readonly string[]): Promise<ObservationCoverage[]> {
    safeId(sessionId, "session id");
    if (branchId !== undefined) safeId(branchId, "branch id");
    if (projectId !== undefined) assertKnowledgeProjectId(projectId, "project id");
    if (entryIds && entryIds.length > 10_000) throw invalid("Observation coverage input is unbounded");
    return this.inspect(async state => (state.catalog?.rows<ObservationCoverage>("coverage",
      "json_extract(value, '$.range.sessionId') = ? AND json_extract(value, '$.range.branchId') IS ? AND json_extract(value, '$.range.projectId') IS ? AND json_extract(value, '$.disposition') IN ('observed', 'empty', 'excluded', 'unavailable')"
        + (entryIds ? " AND json_extract(value, '$.range.fromEntryId') IN (SELECT value FROM json_each(?))" : ""),
      [sessionId, branchId ?? null, projectId ?? null, ...(entryIds ? [JSON.stringify(entryIds)] : [])], "key") ?? [])
      .map(({ value }) => { validateCoverage(value); return value; }));
  }
}

function scrubReferences(record: KnowledgeRecord, forgottenId: string): KnowledgeRecord | null {
  const keep = (e: KnowledgeEvidenceRef): boolean => e.recordId !== forgottenId;
  const hadProvenance = record.provenance.evidence.some(evidence => evidence.recordId === forgottenId);
  const hadRelation = record.relations.some(relation => relation.recordId === forgottenId);
  const provenance = { ...record.provenance, evidence: record.provenance.evidence.filter(keep) };
  const relations = record.relations.filter(relation => relation.recordId !== forgottenId);
  let content = record.content;
  let hadNestedEvidence = false;
  if (record.kind === "observation") {
    const items = record.content.items.map(item => {
      const removed = item.evidence?.some(evidence => evidence.recordId === forgottenId) ?? false;
      hadNestedEvidence ||= removed;
      return removed ? { ...item, text: "[Redacted: supporting evidence was forgotten.]", certainty: "uncertain" as const, evidence: [] } : item;
    });
    content = { ...record.content, items };
  }
  if (record.kind === "note") {
    const fields = record.content.fields ?? [];
    const keptFields = fields.filter(field => {
      const removed = field.evidence.some(evidence => evidence.recordId === forgottenId);
      hadNestedEvidence ||= removed;
      return !removed;
    });
    const contraryEvidence = record.content.contraryEvidence?.filter(keep);
    hadNestedEvidence ||= (record.content.contraryEvidence?.length ?? 0) !== (contraryEvidence?.length ?? 0);
    content = {
      ...record.content,
      ...(record.content.fields ? { fields: keptFields } : {}),
      ...(record.content.body !== undefined ? { body: "[Redacted: supporting evidence was forgotten.]" } : {}),
      confirmed: false,
      ...(contraryEvidence ? { contraryEvidence } : {}),
    };
  }
  if (!hadProvenance && !hadRelation && !hadNestedEvidence) return null;
  const scrubbed = { ...record, revisionId: revisionId(), updatedAt: now(), provenance, relations, content } as KnowledgeRecord; validateKnowledgeRecord(scrubbed); return scrubbed;
}
