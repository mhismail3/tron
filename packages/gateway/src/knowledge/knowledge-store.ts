import { createHash, randomBytes, randomUUID } from "node:crypto";
import { AsyncLocalStorage } from "node:async_hooks";
import { constants } from "node:fs";
import { lstat, mkdir, open, rename } from "node:fs/promises";
import { join, dirname } from "node:path";
import type { TronWorkspace } from "../workspace/tron-workspace.js";
import { GatewayError } from "../errors.js";
import { AsyncMutex } from "../util/async-mutex.js";
import { durableAtomicWriteJson, durableRemove, syncDurably } from "../util/durable-json.js";
import { readSecureJson, SecureJsonFileError } from "../util/secure-json.js";
import {
  DEFAULT_KNOWLEDGE_CONFIG, KNOWLEDGE_SCHEMA_VERSION, OBSERVATION_ATTENTION_DISPOSITIONS, OBSERVATION_COVERAGE_DISPOSITIONS, knowledgeScopeEligible, normalizeKnowledgeSourceUrl,
  type KnowledgeConfig, type KnowledgeEvidenceRef, type KnowledgeListRequest, type KnowledgeScope,
  type KnowledgeListResponse, type KnowledgeObjectRef, type KnowledgePreviewBatchRequest,
  type KnowledgePreviewBatchResponse, type KnowledgeRecallRequest,
  type KnowledgeRecallResponse, type KnowledgeRecord, type KnowledgeRecordDraft,
  type KnowledgeSearchRequest, type KnowledgeSearchResponse, type KnowledgeSearchHit,
  type KnowledgeSourceRow, type KnowledgeSourceRowListResponse, type KnowledgeSourceRowSearchResponse, type KnowledgeSourceTakeRequest, type SourceFreshness,
  type SourceAdmission, type SourceContent,
  type KnowledgeCurationItem, type KnowledgeCurationOperation, type KnowledgeCurationStored,
  type KnowledgeRelation, type SourceCurationProducer, type SourceVerdictState, assertKnowledgeTagId,
  KnowledgeCurationRefusal, KNOWLEDGE_CURATION_MAX_SUMMARY_CHARS, KNOWLEDGE_CURATION_MAX_TAGS,
  type KnowledgeNoteMutationRequest, type KnowledgeCoverageDismissRequest,
  type KnowledgeConnectorState, type ObservationCoverage, type ObservationCoverageDisposition, type ObservationRange, type KnowledgeCoveragePage, type KnowledgeCoverageSummary, validateKnowledgeConfig,
  type KnowledgeTagDefinition, type KnowledgeTagEditRequest, type KnowledgeTagReconcileRequest, type KnowledgeTagReconcileResponse, type KnowledgeTagRetagRequest, type KnowledgeTagRetagResponse, type KnowledgeTagVocabularyConfig,
  validateKnowledgeTagVocabulary, validateKnowledgeRecord, validateObjectRef, assertKnowledgeId, assertKnowledgeProjectId,
} from "./knowledge-contract.js";
import { KnowledgeCatalog, type KnowledgeTable } from "./knowledge-catalog.js";
import type { SQLInputValue } from "node:sqlite";
import { jsonNodeCount } from "../protocol/json-budget.js";
import type { ConnectionInstance } from "../integrations/connection-contract.js";

function isDecisionProducer(producer: SourceCurationProducer | undefined): boolean {
  return producer?.actor === "user" || producer?.actor === "agent";
}

function isConnectorProducer(producer: { actor: string } | string | undefined): boolean {
  const actor = typeof producer === "string" ? producer : producer?.actor;
  return actor === "connector" || actor === "system";
}

export function sourceAdmissionIsDecided(source: Pick<KnowledgeRecord & { kind: "source" }, "content">): boolean {
  const admission = source.content.admission;
  if (!admission) return false;
  if (isDecisionProducer(admission.producer)) return true;
  // A non-pending legacy admission without connector ownership is a prior
  // decision; do not infer permission from missing historical metadata.
  return admission.status !== "pending" && admission.producer?.actor !== "connector";
}

function decisionAuthorityRefusal(field: "admission" | "scope", currentRevision: string): KnowledgeCurationRefusal {
  return new KnowledgeCurationRefusal("decision-authority", `Connector/system cannot replace the current authoritative ${field} decision`, currentRevision);
}

const STATE_MAX_BYTES = 4 * 1_048_576;
// One-time rescue also admits legacy states that outgrew their old read ceiling.
const LEGACY_MIGRATION_MAX_BYTES = 64 * 1_048_576;
const RECORD_MAX_BYTES = 2 * 1_048_576;
const OBJECT_MAX_BYTES = 8_000_000;
const RECEIPT_LIMIT = 256;
const OBJECT_HASH = /^[a-f0-9]{64}$/;
export const CATALOG_STORAGE_VERSION = 4 as const;
export const KNOWLEDGE_PREVIEW_BATCH_ITEMS = 16;
export const KNOWLEDGE_PREVIEW_BATCH_BYTES = 4_000_000;
export const KNOWLEDGE_PREVIEW_MAX_BYTES = 512_000;
const ROW_SUMMARY_CHARS = 280;
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
/** Bounded source presentation fields. Readable source text and raw bytes stay
 * in the immutable record bodies, so a Library page is drawn from heads alone. */
type SourceRowFields = {
  title: string; uri?: string; originalUri?: string; mediaType?: string;
  captureDisposition: SourceContent["captureDisposition"];
  sourceSavedAt?: string; sourcePublishedAt?: string;
  preview?: KnowledgeObjectRef; summary?: string;
  tagIds?: string[]; tagVocabularyRevision?: number; tags?: NonNullable<KnowledgeSourceRow["tags"]>;
  ageBasis: "sourceSavedAt" | "capturedAt"; ageSince: string; decayClass: "ages" | "does-not-age" | "unknown";
  verdict?: import("./knowledge-contract.js").SourceVerdict; supersededBy?: string; hasTake: boolean; tagsStale: boolean;
};
type RecordHead = LegacyRecordHead & {
  kind: KnowledgeRecord["kind"]; scope: KnowledgeRecord["scope"];
  sortAt: number; searchFields: Array<[string, string]>;
  createdAt: string; updatedAt: string;
  recordRefs: string[]; objectHashes: string[]; sourceIdentities?: string[];
  /** Mirrors the record body so list/search can partition and render a page
   * without reading it. Derived data: `headFor` is its only writer. */
  admission?: SourceAdmission;
  sessionId?: string; branchId?: string;
  sourceRow?: SourceRowFields;
};
type Suppression = { excluded: boolean; forgotten: boolean; reason?: string; updatedAt: string };
type ScopeExclusion = { sessionId?: string; branchId?: string; projectId?: string; excluded: boolean; reason?: string; updatedAt: string };
type PendingRecordCleanup = { recordId: string; revisionId: string };
type SourceRecordWriteRequest = { commandId: string; expectedRevision?: string; canonicalUri?: string; writer?: "connector"; record: KnowledgeRecordDraft & { kind: "source" }; signal?: AbortSignal };
type SourcePreviewWriteRequest = { commandId: string; recordId: string; expectedRevision: string; preview: KnowledgeObjectRef; signal?: AbortSignal };
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
/** Committed-change notification. `recordIds` lets a client refresh only the
 * rows a mutation touched instead of replaying its first page. */
export interface KnowledgeChange { stateRevision: number; recordIds?: string[] }

function conflict(message: string): GatewayError { return new GatewayError("conflict", message); }
function mergeSourceAttribution(existing: KnowledgeRecord & { kind: "source" }, incoming: KnowledgeRecordDraft & { kind: "source" }): KnowledgeRecordDraft & { kind: "source" } {
  const origins = [...(existing.content.origins ?? [])];
  for (const origin of incoming.content.origins ?? []) if (!origins.some(previous => previous.kind === origin.kind && previous.uri === origin.uri && JSON.stringify(previous.identity) === JSON.stringify(origin.identity))) origins.push(origin);
  if (origins.length > 20) throw conflict("Source redirect provenance bound would discard existing origins");
  const annotations = [...(existing.content.annotations ?? [])];
  for (const annotation of incoming.content.annotations ?? []) if (!annotations.some(previous => previous.text === annotation.text && previous.locator === annotation.locator)) annotations.push(annotation);
  if (annotations.length > 200) throw conflict("Source redirect annotation bound would discard existing annotations");
  return { kind: "source", id: existing.id, createdAt: existing.createdAt, scope: existing.scope, provenance: existing.provenance, relations: existing.relations, ...(existing.temporal ? { temporal: existing.temporal } : {}), content: { ...existing.content, ...(origins.length ? { origins } : {}), ...(annotations.length ? { annotations } : {}) } };
}
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
  return { schemaVersion: KNOWLEDGE_SCHEMA_VERSION, stateRevision: 0, records: {}, coverage: {}, suppressions: {}, scopeExclusions: {}, cleanup: [], recordCleanup: [], receipts: {}, config: structuredClone(DEFAULT_KNOWLEDGE_CONFIG), connectors: {} };
}
function catalogState(control: CatalogControl, catalog?: KnowledgeCatalog): KnowledgeState {
  return { ...control, ...(catalog ? { catalog } : {}),
    records: catalog?.table<RecordHead>("records") ?? new Map(),
    coverage: catalog?.table<ObservationCoverage>("coverage") ?? new Map(),
    suppressions: catalog?.table<Suppression>("suppressions") ?? new Map(),
    scopeExclusions: catalog?.table<ScopeExclusion>("scopeExclusions") ?? new Map(),
    receipts: catalog?.table<StoredReceipt>("receipts") ?? new Map(),
    cleanup: catalog?.table<true>("cleanup") ?? new Map(),
    recordCleanup: catalog?.table<PendingRecordCleanup>("recordCleanup") ?? new Map(),
    sourceIdentities: catalog?.table<string>("sourceIdentities") ?? new Map(),
  };
}
/** sha256 of the Gateway's `JSON.stringify({title, text})`. A stored summary is
 * current evidence interpretation only while its digest still matches. */
export function sourceEvidenceDigest(title: string, text: string): string {
  return createHash("sha256").update(JSON.stringify({ title, text })).digest("hex");
}
/** Digest of the record's own taggable inputs: its saved title, current
 * summary, readable text, verdict, and the user's take. The vocabulary edition
 * is recorded separately on the selection, so taxonomy edits can re-tag without
 * making stored selections unreadable. */
export function curationInputsDigest(content: SourceContent): string {
  return createHash("sha256").update(JSON.stringify({ title: content.title, summary: content.summary?.text ?? null, text: content.text ?? "", verdict: content.verdict?.verdict ?? null, take: content.take?.text ?? null })).digest("hex");
}
/** The fields one curation operation wrote, read back from its committed
 * revision. Bounded by the item bounds, so a batch outcome stays small. */
export function curationStored(record: KnowledgeRecord & { kind: "source" }, operation: KnowledgeCurationOperation): KnowledgeCurationStored {
  const content = record.content;
  switch (operation) {
    case "summary": return content.summary ? { summary: { text: content.summary.text, coverage: content.summary.coverage, sourceRevisionId: content.summary.sourceRevisionId } } : {};
    case "tags": return content.tags ? { tagIds: [...content.tags.tagIds], vocabularyRevision: content.tags.vocabularyRevision } : {};
    case "verdict": return content.verdict ? { verdict: content.verdict.verdict, ...(content.verdict.supersededBy ? { supersededBy: content.verdict.supersededBy } : {}) } : {};
    case "placement": return { scope: record.scope, ...(content.admission ? { admission: content.admission.status } : {}) };
    case "relation": return { relations: record.relations.map(relation => `${relation.type}:${relation.recordId}`).slice(0, 32) };
  }
}
function httpUrl(value: string | undefined): string | undefined {
  if (!value) return undefined;
  try {
    const url = new URL(value);
    return (url.protocol === "http:" || url.protocol === "https:") && !url.username && !url.password ? value : undefined;
  } catch { return undefined; }
}
/** The user-facing original link: the requested URI recorded for this exact
 * saved-item identity, else the canonical capture URI. */
function originalSourceUri(content: SourceContent): string | undefined {
  const identity = content.identity;
  const requested = identity
    ? [...(content.origins ?? [])].reverse().find(origin => origin.uri !== undefined && origin.uri !== content.uri
      && origin.identity?.provider === identity.provider && origin.identity.accountId === identity.accountId && origin.identity.itemId === identity.itemId)?.uri
    : undefined;
  return httpUrl(requested) ?? httpUrl(content.uri);
}
/** The single owner of a Library row's presentation fields. Age-dependent
 * values are projected from stable age anchors when read, not persisted in the
 * head. The canonical Knowledge config supplies both tag labels and decay. */
function sourceRowFields(record: KnowledgeRecord & { kind: "source" }, config: KnowledgeConfig): SourceRowFields {
  const content = record.content;
  const ageBasis = content.sourceSavedAt ? "sourceSavedAt" : "capturedAt";
  const ageSince = content.sourceSavedAt ?? content.capturedAt;
  // Retired and merged selections remain visible until re-tagging, but cannot
  // claim a current freshness policy. Only active vocabulary entries govern it.
  const selectedTags = content.tags?.tagIds.map(id => config.tagVocabulary.tags.find(candidate => candidate.id === id));
  const decayClass = !selectedTags?.length || selectedTags.some(tag => !tag || tag.state !== "active")
    ? "unknown" : selectedTags.some(tag => tag!.decayClass === "ages") ? "ages" : "does-not-age";
  const summary = content.summary?.text.trim();
  const current = content.summary && summary && content.summary.evidenceDigest === sourceEvidenceDigest(content.title, content.text ?? "") ? summary : undefined;
  const originalUri = originalSourceUri(content);
  return {
    title: content.title,
    ...(content.uri ? { uri: content.uri } : {}),
    ...(originalUri ? { originalUri } : {}),
    ...(content.mediaType ? { mediaType: content.mediaType } : {}),
    captureDisposition: content.captureDisposition,
    ...(content.sourceSavedAt ? { sourceSavedAt: content.sourceSavedAt } : {}),
    ...(content.sourcePublishedAt && content.identity?.provider.toLowerCase() !== "raindrop" ? { sourcePublishedAt: content.sourcePublishedAt } : {}),
    ...(content.preview ? { preview: content.preview } : {}),
    ageBasis, ageSince, decayClass,
    ...(content.verdict ? { verdict: content.verdict.verdict, ...(content.verdict.supersededBy ? { supersededBy: content.verdict.supersededBy } : {}) } : {}),
    hasTake: Boolean(content.take?.text), tagsStale: Boolean(content.tags && content.tags.inputsDigest !== curationInputsDigest(content)),
    ...(current ? { summary: current.slice(0, ROW_SUMMARY_CHARS) } : {}),
    ...(content.tags ? { tagIds: [...content.tags.tagIds], tagVocabularyRevision: content.tags.vocabularyRevision } : {}),
    ...(content.tags ? { tags: content.tags.tagIds.flatMap(id => { const tag = config.tagVocabulary.tags.find(candidate => candidate.id === id); return tag ? [{ id: tag.id, label: tag.label, category: tag.category, decayClass: tag.decayClass, state: tag.state }] : []; }) } : {}),
  };
}
function headScopeFields(record: KnowledgeRecord): { sessionId?: string; branchId?: string } {
  const sessionId = record.kind === "observation" ? record.content.range.sessionId : record.provenance.sessionId;
  const branchId = record.kind === "observation" ? record.content.range.branchId : record.provenance.branchId;
  return { ...(sessionId ? { sessionId } : {}), ...(branchId ? { branchId } : {}) };
}
function headFor(record: KnowledgeRecord, revisions: string[], retainedObjects: string[] = [], config: KnowledgeConfig): RecordHead {
  const date = record.kind === "observation" ? record.content.items[0]?.observedAt ?? record.createdAt : record.updatedAt;
  const evidence = [...record.provenance.evidence,
    ...(record.kind === "observation" ? record.content.items.flatMap(item => item.evidence ?? []) : []),
    ...(record.kind === "note" ? [...(record.content.fields ?? []).flatMap(field => field.evidence), ...(record.content.contraryEvidence ?? [])] : []),
  ];
  return { latestRevisionId: record.revisionId, revisionIds: revisions, kind: record.kind, scope: record.scope,
    createdAt: record.createdAt, updatedAt: record.updatedAt, sortAt: Date.parse(date), searchFields: [...searchableFields(record), ...(record.kind === "source" && record.content.tags ? [["tags", (record.content.tags.tagIds.flatMap(id => { const tag = config.tagVocabulary.tags.find(candidate => candidate.id === id); return tag ? [tag.label] : []; }).join(" "))] as [string, string]] : [])].map(([field, value]) => [field, value.toLocaleLowerCase()]),
    recordRefs: [...new Set([...record.relations.map(relation => relation.recordId), ...evidence.flatMap(ref => ref.recordId ? [ref.recordId] : [])])],
    objectHashes: [...new Set([...retainedObjects, ...recordObjectHashes(record)])],
    ...(recordSourceIdentityKeys(record).length > 0 ? { sourceIdentities: recordSourceIdentityKeys(record) } : {}),
    ...(record.kind === "source" && record.content.admission ? { admission: record.content.admission.status } : {}),
    ...headScopeFields(record),
    ...(record.kind === "source" ? { sourceRow: sourceRowFields(record, config) } : {}),
  };
}
/** Cursor identity for one page of Library rows. Every input that changes which
 * rows a page contains belongs to it. */
function sourceRowScope(request: Pick<KnowledgeListRequest, "scope" | "includeArchived" | "includePending" | "sourceAdmission" | "excludePersonalSources">): string {
  return JSON.stringify(["sourceRow", request.scope ?? null, request.includeArchived === true, request.includePending === true, request.sourceAdmission ?? null, request.excludePersonalSources === true]);
}
type SearchPosition = { score: number; freshnessRank: number; sortAt: number; id: string; freshnessNowMs: number };
function searchScope(request: KnowledgeSearchRequest): string {
  return JSON.stringify(["records", request.query, request.kind ?? null, request.scope ?? null, request.excludePersonalSources === true, request.includeArchived === true, request.includePending === true, request.sourceAdmission ?? null]);
}
function sourceRowSearchScope(request: KnowledgeSearchRequest): string {
  return JSON.stringify(["sourceRow", request.query, request.scope ?? null, request.excludePersonalSources === true, request.includeArchived === true, request.includePending === true, request.sourceAdmission ?? null]);
}
/** Admission lives in the head, so the library partition is one SQL predicate
 * for both the paged and the identity-refresh paths. */
function admissionFilter(request: Pick<KnowledgeListRequest, "includeArchived" | "includePending" | "sourceAdmission">): { clauses: string[]; parameters: SQLInputValue[] } {
  const clauses: string[] = []; const parameters: SQLInputValue[] = [];
  if (request.includeArchived !== true) clauses.push("json_extract(value, '$.admission') IS NOT 'archived'");
  if (request.includePending !== true) clauses.push("json_extract(value, '$.admission') IS NOT 'pending'");
  if (request.sourceAdmission !== undefined) { clauses.push("json_extract(value, '$.admission') = ?"); parameters.push(request.sourceAdmission); }
  return { clauses, parameters };
}
function searchScoreSQL(terms: string[]): string {
  return `(SELECT coalesce(sum(${terms.map(() => "(instr(json_extract(field.value, '$[1]'), ?) > 0)").join(" + ")}), 0) FROM json_each(entries.value, '$.searchFields') AS field)`;
}
function searchFreshnessRankSQL(nowMs = Date.now()): string {
  const now = new Date(nowMs).toISOString();
  const ageDays = `CAST(julianday('${now}') - julianday(json_extract(value, '$.sourceRow.ageSince')) + 0.00000002 AS INTEGER)`;
  return `(CASE WHEN json_extract(value, '$.sourceRow.verdict') = 'evergreen' THEN 3
    WHEN json_extract(value, '$.sourceRow.verdict') = 'superseded' THEN 0
    WHEN json_extract(value, '$.sourceRow.verdict') = 'dated' THEN CASE WHEN ${ageDays} >= 180 THEN 0 ELSE 2 END
    WHEN json_extract(value, '$.sourceRow.decayClass') = 'does-not-age' THEN 3
    WHEN json_extract(value, '$.sourceRow.decayClass') = 'ages' THEN CASE WHEN ${ageDays} >= 180 THEN 0 WHEN ${ageDays} >= 120 THEN 2 ELSE 3 END
    WHEN json_extract(value, '$.sourceRow.decayClass') = 'unknown' THEN 1 ELSE 0 END)`;
}
function headFreshnessRank(head: RecordHead, nowMs: number): number {
  return head.sourceRow ? projectFreshness(head.sourceRow, nowMs).freshnessRank : 0;
}
/** Ordering-preserving keyset for a scored search page. The score is carried
 * exactly as the statement's own ordering key computed it. */
function readSearchCursor(cursor: string, scope: string, stateRevision: number): SearchPosition {
  let value: Record<string, unknown>;
  try {
    if (cursor.length > 2_000) throw new Error();
    value = JSON.parse(Buffer.from(cursor, "base64url").toString("utf8")) as Record<string, unknown>;
    if (value.v !== 2 || value.scope !== scope || !Number.isFinite(value.score) || !Number.isFinite(value.freshnessRank) || !Number.isFinite(value.sortAt) || !Number.isSafeInteger(value.freshnessNowMs) || typeof value.id !== "string") throw new Error();
    safeId(value.id, "cursor record");
  } catch { throw invalid("Knowledge cursor is invalid for this query; reload the first page"); }
  // Results are ordered by the exact corpus revision that produced them; a
  // stale page would silently skip or repeat rows.
  if (value.stateRevision !== stateRevision) throw conflict("Search results changed; reload the first page");
  return { score: value.score as number, freshnessRank: value.freshnessRank as number, sortAt: value.sortAt as number, id: value.id, freshnessNowMs: value.freshnessNowMs as number };
}
function searchCursor(scope: string, stateRevision: number, position: SearchPosition): string {
  return Buffer.from(JSON.stringify({ v: 2, scope, stateRevision, ...position })).toString("base64url");
}
function afterSearchPosition(score: number, freshnessRank: number, sortAt: number, id: string, cursor: SearchPosition): boolean {
  if (score !== cursor.score) return score < cursor.score;
  if (freshnessRank !== cursor.freshnessRank) return freshnessRank < cursor.freshnessRank;
  if (sortAt !== cursor.sortAt) return sortAt < cursor.sortAt;
  return id > cursor.id;
}
/** Score a stored head exactly as the SQL ordering expression scores it: one
 * point per (search field, term) pair the term appears in. */
function headScore(head: RecordHead, terms: string[]): number {
  let score = 0;
  for (const [, value] of head.searchFields) score += terms.reduce((sum, term) => sum + (value.includes(term) ? 1 : 0), 0);
  return score;
}
function projectFreshness(source: SourceRowFields, nowMs = Date.now()): { freshness: SourceFreshness; freshnessRank: number; ageDays: number } {
  const parsed = Date.parse(source.ageSince);
  const ageDays = Number.isFinite(parsed) ? Math.max(0, Math.floor((nowMs - parsed) / 86_400_000)) : 0;
  const age: SourceFreshness = ageDays >= 180 ? "stale" : ageDays >= 120 ? "aging" : "fresh";
  let freshness: SourceFreshness;
  if (source.verdict === "evergreen") freshness = "fresh";
  else if (source.verdict === "superseded") freshness = "stale";
  else if (source.verdict === "dated") freshness = age === "fresh" ? "aging" : age;
  else if (source.decayClass === "unknown") freshness = "unknown";
  else if (source.decayClass === "does-not-age") freshness = "fresh";
  else freshness = age;
  return { freshness, ageDays, freshnessRank: freshness === "fresh" ? 3 : freshness === "aging" ? 2 : freshness === "unknown" ? 1 : 0 };
}
function sourceRow(id: string, head: RecordHead & { sourceRow: SourceRowFields }): KnowledgeSourceRow {
  const { tagIds: _tagIds, tagVocabularyRevision: _tagVocabularyRevision, ...fields } = head.sourceRow;
  const { freshnessRank: _rank, ageDays, freshness } = projectFreshness(head.sourceRow);
  delete (fields as Partial<SourceRowFields>).ageSince;
  delete (fields as Partial<SourceRowFields>).decayClass;
  return { id, revisionId: head.latestRevisionId, scope: head.scope, createdAt: head.createdAt, updatedAt: head.updatedAt, ...fields, ageDays, freshness, ...(head.admission ? { admission: head.admission } : {}) };
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
function validateConnectorState(value: unknown, connector: "raindrop" | "x" | "jev"): asserts value is KnowledgeConnectorState {
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
  if (state.assessmentPilots !== undefined) {
    if (!state.assessmentPilots || typeof state.assessmentPilots !== "object" || Array.isArray(state.assessmentPilots) || Object.keys(state.assessmentPilots).length > 64) throw new KnowledgeStoreError("invalid", "Invalid connector collection pilots");
    for (const [collectionId, pilot] of Object.entries(state.assessmentPilots as Record<string, unknown>)) {
      validateAssessmentAuthority(pilot, "collection assessment pilot");
      if (!/^-?\d{1,18}$/.test(collectionId) || (pilot as Record<string, unknown>).sourceCollection !== collectionId) throw new KnowledgeStoreError("invalid", "Connector collection pilot does not match its collection");
    }
  }
  if (state.assessmentApprovals !== undefined) {
    if (!Array.isArray(state.assessmentApprovals) || state.assessmentApprovals.length > 32 || new Set(state.assessmentApprovals.map(item => (item as Record<string, unknown>)?.id)).size !== state.assessmentApprovals.length) throw new KnowledgeStoreError("invalid", "Invalid connector assessment approvals");
    state.assessmentApprovals.forEach(item => validateAssessmentAuthority(item, "assessment approval"));
  }
  if (state.processedItems !== undefined) {
    if (!Array.isArray(state.processedItems) || state.processedItems.length > 2_000) throw new KnowledgeStoreError("invalid", "Invalid connector processed items");
    for (const item of state.processedItems) {
      const processed = item as Record<string, unknown>;
      if (!processed || typeof processed.id !== "string" || processed.id.length < 1 || processed.id.length > 512 || !["processed", "skipped"].includes(processed.disposition as string) || typeof processed.reason !== "string" || processed.reason.length < 1 || processed.reason.length > 500 || typeof processed.processedAt !== "string" || (processed.collectionId !== undefined && (typeof processed.collectionId !== "string" || !/^-?\d{1,18}$/.test(processed.collectionId)))) throw new KnowledgeStoreError("invalid", "Invalid connector processed item");
    }
  }
  for (const id of state.capturedIds) if (typeof id !== "string" || id.length > 512) throw new KnowledgeStoreError("invalid", "Invalid connector captured ID");
  if (state.capturedCollections !== undefined) {
    if (!state.capturedCollections || typeof state.capturedCollections !== "object" || Array.isArray(state.capturedCollections) || Object.keys(state.capturedCollections).length > 2_000) throw new KnowledgeStoreError("invalid", "Invalid connector collection progress");
    for (const [itemId, collectionId] of Object.entries(state.capturedCollections as Record<string, unknown>)) if (!itemId || itemId.length > 512 || typeof collectionId !== "string" || !/^-?\d{1,18}$/.test(collectionId)) throw new KnowledgeStoreError("invalid", "Invalid connector collection progress");
  }
  if (state.assessmentAttempts !== undefined) {
    if (!state.assessmentAttempts || typeof state.assessmentAttempts !== "object" || Array.isArray(state.assessmentAttempts) || Object.keys(state.assessmentAttempts).length > 500) throw new KnowledgeStoreError("invalid", "Invalid connector assessment attempts");
    for (const [itemId, attempt] of Object.entries(state.assessmentAttempts as Record<string, unknown>)) {
      if (!itemId || !attempt || typeof attempt !== "object" || ((attempt as Record<string, unknown>).itemId !== undefined && (typeof (attempt as Record<string, unknown>).itemId !== "string" || !(attempt as Record<string, unknown>).itemId)) || ((attempt as Record<string, unknown>).cohortId !== undefined && (typeof (attempt as Record<string, unknown>).cohortId !== "string" || !(attempt as Record<string, unknown>).cohortId)) || !["dispatched", "settled"].includes((attempt as Record<string, unknown>).status as string) || !Number.isSafeInteger((attempt as Record<string, unknown>).chargeCents) || ((attempt as Record<string, unknown>).chargeCents as number) < 1 || ((attempt as Record<string, unknown>).inputTokens !== undefined && (!Number.isSafeInteger((attempt as Record<string, unknown>).inputTokens) || (attempt as Record<string, unknown>).inputTokens as number < 0)) || ((attempt as Record<string, unknown>).outputTokens !== undefined && (!Number.isSafeInteger((attempt as Record<string, unknown>).outputTokens) || (attempt as Record<string, unknown>).outputTokens as number < 0)) || ((attempt as Record<string, unknown>).estimatedCostCents !== undefined && (typeof (attempt as Record<string, unknown>).estimatedCostCents !== "number" || !Number.isFinite((attempt as Record<string, unknown>).estimatedCostCents) || (attempt as Record<string, unknown>).estimatedCostCents as number < 0))) throw new KnowledgeStoreError("invalid", "Invalid connector assessment attempt");
    }
  }
  if (state.taggingBudget !== undefined) {
    const ledger = state.taggingBudget as Record<string, unknown>;
    if (!ledger || typeof ledger !== "object" || !/^[0-9]{4}-[0-9]{2}$/.test(ledger.month as string) || !Number.isFinite(ledger.spentCents) || (ledger.spentCents as number) < 0 || !Number.isFinite(ledger.reservedCents) || (ledger.reservedCents as number) < 0 || !ledger.attempts || typeof ledger.attempts !== "object" || Array.isArray(ledger.attempts) || Object.keys(ledger.attempts).length > 4_096) throw new KnowledgeStoreError("invalid", "Invalid Knowledge Jev tagging budget");
    for (const [id, raw] of Object.entries(ledger.attempts as Record<string, unknown>)) {
      const attempt = raw as Record<string, unknown>;
      if (!id || id.length > 200 || !attempt || !/^[0-9]{4}-[0-9]{2}$/.test(attempt.month as string) || !["reserved", "settled", "uncertain"].includes(attempt.status as string) || !Number.isFinite(attempt.reservedCents) || (attempt.reservedCents as number) <= 0 || ((attempt.actualCostCents !== undefined) && (!Number.isFinite(attempt.actualCostCents) || (attempt.actualCostCents as number) < 0)) || ((attempt.inputTokens !== undefined) && (!Number.isSafeInteger(attempt.inputTokens) || (attempt.inputTokens as number) < 0)) || ((attempt.outputTokens !== undefined) && (!Number.isSafeInteger(attempt.outputTokens) || (attempt.outputTokens as number) < 0))) throw new KnowledgeStoreError("invalid", "Invalid Jev tagging reservation");
    }
  }
  for (const key of ["accountId", "scope", "credentialRef", "lastRunAt", "lastError"]) if (state[key] !== undefined && (typeof state[key] !== "string" || (state[key] as string).length > 4_096)) throw new KnowledgeStoreError("invalid", "Invalid connector state field");
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
  if (!state.receipts || typeof state.receipts !== "object" || Array.isArray(state.receipts)) throw new KnowledgeStoreError("invalid", "Invalid knowledge receipts");
  for (const receipt of Object.values(state.receipts as Record<string, unknown>)) {
    const item = receipt as Record<string, unknown>;
    if (!item || typeof item !== "object" || typeof item.operation !== "string" || typeof item.requestHash !== "string" || !item.result || !Array.isArray(item.recordIds) || (item.invalidated !== undefined && typeof item.invalidated !== "boolean")) throw new KnowledgeStoreError("invalid", "Invalid knowledge mutation receipt");
  }
  try { state.config = validateKnowledgeConfig(state.config); } catch (error) { throw new KnowledgeStoreError("invalid", error instanceof Error ? error.message : "Invalid knowledge config"); }
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
    ...(record.content.preview ? [record.content.preview] : []),
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
    try { await handle.writeFile(bytes); await syncDurably(handle); } finally { await handle.close(); }
    await rename(temporary, path); exists = false;
    const directoryHandle = await open(directory, "r"); try { await syncDurably(directoryHandle); } finally { await directoryHandle.close(); }
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
  /** Command-scoped summary generations that are already in flight. */
  private readonly summaryInFlight = new Map<string, Promise<KnowledgeMutationResult>>();
  constructor(private readonly workspace: TronWorkspace, private readonly onChanged?: (change: KnowledgeChange) => void, private readonly connectorEnvelope?: KnowledgeConnectorEnvelopeResolver) {
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
      if (typeof manifest.storageVersion === "number" && manifest.storageVersion > CATALOG_STORAGE_VERSION) throw new KnowledgeStoreError("newer", "Unsupported Knowledge catalog manifest");
      if (manifest.storageVersion !== CATALOG_STORAGE_VERSION) throw new KnowledgeStoreError("invalid", "Knowledge catalog requires its one-time row-projection upgrade before use");
      throw new KnowledgeStoreError("invalid", "Unsupported Knowledge catalog manifest");
    }
    const { catalog, control } = await this.openCatalog(paths, manifest.catalogID, !writable);
    return { state: catalogState(control, catalog), present: true };
  }

  /** Open and validate one manifest's catalog file. Ordinary reads never
   * migrate: an older manifest failed above, and only `upgradeStorage` rebuilds
   * an existing corpus. Callers own the returned catalog's close. */
  private async openCatalog(paths: StorePaths, catalogID: string, readOnly: boolean): Promise<{ catalog: KnowledgeCatalog; control: CatalogControl }> {
    const path = join(paths.root, `catalog-${catalogID}.sqlite`);
    const before = await this.catalogFile(path);
    await this.catalogFile(`${path}-journal`, true);
    let catalog: KnowledgeCatalog | undefined;
    try {
      catalog = new KnowledgeCatalog(path, readOnly);
      const after = await this.catalogFile(path);
      if (before!.ino !== after!.ino || before!.dev !== after!.dev) throw new KnowledgeStoreError("unsafe", "Knowledge catalog changed while opening");
      const control = catalog.control<CatalogControl>();
      if (control.catalogID !== catalogID || control.schemaVersion !== KNOWLEDGE_SCHEMA_VERSION || !Number.isSafeInteger(control.stateRevision) || control.stateRevision < 0) throw new KnowledgeStoreError("invalid", "Invalid Knowledge catalog control");
      control.config = validateKnowledgeConfig(control.config);
      for (const [key, value] of Object.entries(control.connectors ?? {})) { if (!/^[A-Za-z0-9._:-]{1,160}$/.test(key)) throw new KnowledgeStoreError("invalid", "Invalid connector state key"); if (value) validateConnectorState(value, value.connector); }
      return { catalog, control };
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

  /** Mutex-free read projection. Each catalog query sees committed state, and
   * the connection closes as soon as the action settles, so a reader never
   * holds a lock a mutation would have to wait for. Page selection resolves its
   * heads synchronously, before any body read. Privacy checks made after a body
   * read can observe a newer commit than those heads; that can only hide a
   * record excluded or forgotten meanwhile, never reveal one. Callers that read
   * revision bodies use `readRecordOrRemoved`, which reports a body a concurrent
   * forget removed as unavailable instead of as a damaged corpus. */
  private async readState<T>(action: (state: KnowledgeState, paths: StorePaths, present: boolean) => T | Promise<T>): Promise<T> {
    const paths = await this.paths(false);
    const loaded = await this.load(paths, false);
    try { return await action(loaded.state, paths, loaded.present); }
    finally { loaded.state.catalog?.close(); }
  }

  /** Revision bodies are immutable, and a forget deletes the head in its
   * tombstone transaction before its files. A reader holding an older snapshot
   * can therefore meet a revision that is no longer committed; that is removal.
   * A revision its own snapshot still commits is a damaged corpus and fails. */
  private async readRecordOrRemoved(paths: StorePaths, state: KnowledgeState, id: string, revision: string): Promise<KnowledgeRecord | undefined> {
    try { return await this.readRecord(paths, id, revision); }
    catch (error) {
      if (!(error instanceof KnowledgeStoreError) || !error.message.startsWith("Record revision is missing")) throw error;
      const committed = await this.readState(fresh => fresh.records.get(id)?.revisionIds.includes(revision) ?? false);
      if (committed) throw error;
      return undefined;
    }
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
      const manifest = read.value as { storageVersion?: unknown; schemaVersion?: unknown; catalogID?: unknown };
      if (manifest.storageVersion === CATALOG_STORAGE_VERSION) { const loaded = await this.load(paths, false); loaded.state.catalog?.close(); return; }
      if (manifest.storageVersion === undefined) { await this.createCatalog(paths, validateState(read.value)); return; }
      if (manifest.storageVersion !== 2 && manifest.storageVersion !== 3) throw new KnowledgeStoreError(typeof manifest.storageVersion === "number" && manifest.storageVersion > CATALOG_STORAGE_VERSION ? "newer" : "invalid", "Unsupported Knowledge catalog manifest");
      if (manifest.schemaVersion !== KNOWLEDGE_SCHEMA_VERSION || typeof manifest.catalogID !== "string" || !/^[0-9a-f-]{36}$/.test(manifest.catalogID)) throw new KnowledgeStoreError("invalid", "Unsupported Knowledge catalog manifest");
      await this.rebuildCatalogHeads(paths, manifest.catalogID);
    });
  }

  /** One-time upgrade from the pre-row-projection catalog. Heads are derived
   * data, so rebuilding them from the latest committed revision of every record
   * is idempotent; the manifest that admits them is written last and a failure
   * leaves the previous manifest authoritative. */
  private async rebuildCatalogHeads(paths: StorePaths, catalogID: string): Promise<void> {
    const { catalog } = await this.openCatalog(paths, catalogID, false);
    try {
      const config = catalog.control<CatalogControl>().config;
      catalog.begin();
      const records = catalog.table<RecordHead>("records");
      // Read the previous shape raw: it predates the projection this rebuild
      // derives, so it cannot satisfy the current head contract yet.
      for (const row of catalog.rawEntries("records")) {
        if (!row.value || typeof row.value !== "object") throw new KnowledgeStoreError("invalid", "Invalid Knowledge record head");
        const legacy = row.value as LegacyRecordHead & { objectHashes?: string[] };
        const latest = await this.readRecord(paths, row.key, legacy.latestRevisionId);
        records.set(row.key, headFor(latest, legacy.revisionIds, legacy.objectHashes ?? [], config));
      }
      catalog.commit();
    } finally { catalog.close(); }
    const durable = await open(join(paths.root, `catalog-${catalogID}.sqlite`), constants.O_RDONLY | constants.O_NOFOLLOW);
    try { await durable.sync(); } finally { await durable.close(); }
    await durableAtomicWriteJson(paths.state, { schemaVersion: KNOWLEDGE_SCHEMA_VERSION, storageVersion: CATALOG_STORAGE_VERSION, catalogID }, 0o600);
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
        const migratedHead = headFor(latest, head.revisionIds, [...objects], state.config);
        state.records.set(id, migratedHead);
        for (const identity of migratedHead.sourceIdentities ?? []) state.sourceIdentities.set(identity, id);
        catalog.setRevisions(id, head.revisionIds);
      }
      for (const [id, value] of Object.entries(legacy.coverage)) state.coverage.set(id, value);
      for (const [id, value] of Object.entries(legacy.suppressions)) state.suppressions.set(id, value);
      for (const [id, value] of Object.entries(legacy.scopeExclusions)) state.scopeExclusions.set(id, value);
      for (const [id, value] of Object.entries(legacy.receipts)) state.receipts.set(id, value);
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
    try { await syncDurably(durable); } finally { await durable.close(); }
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
  /** Command-ID replay fence, shared by the serialized mutation path and the
   * summary pre-check that must not call a model before it discovers a
   * committed replay. */
  private async replayReceipt(paths: StorePaths, state: KnowledgeState, key: string, operation: string, hash: string): Promise<{ found: boolean; result?: unknown }> {
    const prior = state.receipts.get(key);
    if (!prior) return { found: false };
    if (prior.operation !== operation || prior.requestHash !== hash) throw conflict("Command ID was already used for a different knowledge mutation");
    if (prior.invalidated) throw conflict("Knowledge mutation result was forgotten");
    return { found: true, result: await this.receiptResult(paths, state, prior.result) };
  }
  private async mutate<T>(operation: string, commandId: string, request: unknown, action: (state: KnowledgeState, paths: StorePaths) => Promise<T>, afterCommit?: (state: KnowledgeState, paths: StorePaths, result: T) => Promise<void>, signal?: AbortSignal): Promise<T> {
    if (!/^[A-Za-z0-9._:-]{8,160}$/.test(commandId)) throw invalid("Mutating requests require a stable commandId");
    return this.mutex.run(async () => {
      if (signal?.aborted) throw new GatewayError("busy", "Knowledge mutation was cancelled", true);
      const paths = await this.paths(true); const { state } = await this.load(paths, true);
      try {
        const key = `${operation}\0${commandId}`; const hash = requestHash(operation, request);
        const replayed = await this.replayReceipt(paths, state, key, operation, hash);
        if (replayed.found) return replayed.result as T;
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
        try { this.onChanged?.({ stateRevision: state.stateRevision, recordIds: stored.recordIds }); } catch { /* Reconnect reads canonical state. */ }
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
      return await this.readState((state, _paths, present) => {
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
  async config(): Promise<KnowledgeConfig> { return this.readState(state => state.config); }
  /** Derive tool metadata from the exact record retrieval already returned, not
   * from a second row query whose admission filter could omit that record. */
  async sourceRowForRecord(record: KnowledgeRecord): Promise<KnowledgeSourceRow | undefined> {
    if (record.kind !== "source") return undefined;
    const config = await this.config();
    const head = headFor(record, [record.revisionId], [], config);
    return sourceRow(record.id, head as RecordHead & { sourceRow: SourceRowFields });
  }
  async configureTags(request: KnowledgeTagEditRequest): Promise<KnowledgeConfig> {
    return this.mutate("knowledge.tags.configure", request.commandId, request, async state => {
      if (!Number.isSafeInteger(request.expectedConfigRevision) || request.expectedConfigRevision !== state.config.revision) throw conflict(`Knowledge configuration revision is stale; current revision is ${state.config.revision}`);
      const nextVocabulary = this.applyTagEdit(state.config.tagVocabulary, request.edit);
      nextVocabulary.revision += 1;
      try { validateKnowledgeTagVocabulary(nextVocabulary); } catch (error) { throw invalid(error instanceof Error ? error.message : "Invalid Knowledge tag vocabulary"); }
      const next = structuredClone(state.config);
      next.tagVocabulary = nextVocabulary;
      next.revision += 1;
      state.config = next;
      if (request.edit.kind !== "guidelines" && request.edit.kind !== "redefine") this.reprojectTagHeads(state);
      return next;
    });
  }
  async tagsNeedingRetag(request: KnowledgeTagRetagRequest): Promise<KnowledgeTagRetagResponse> {
    if (!Number.isSafeInteger(request.vocabularyRevision) || request.vocabularyRevision < 0) throw invalid("A re-tag query requires a vocabulary revision");
    if (request.limit !== undefined && (!Number.isSafeInteger(request.limit) || request.limit < 1 || request.limit > 64)) throw invalid("A re-tag page carries 1..64 items");
    const cursor = this.parseTagCursor(request.cursor, request.vocabularyRevision);
    return this.readState(state => {
      if (request.vocabularyRevision !== state.config.tagVocabulary.revision) throw conflict(`Knowledge vocabulary revision changed; current revision is ${state.config.tagVocabulary.revision}`);
      const limit = request.limit ?? 25;
      const retiredIds = state.config.tagVocabulary.tags.filter(tag => tag.state !== "active").map(tag => tag.id);
      const where = "json_extract(entries.value, '$.kind') = 'source' AND key > ? AND (json_extract(entries.value, '$.sourceRow.tagIds') IS NULL OR json_extract(entries.value, '$.sourceRow.tagVocabularyRevision') != ? OR json_extract(entries.value, '$.sourceRow.tagsStale') = 1 OR EXISTS (SELECT 1 FROM json_each(json_extract(entries.value, '$.sourceRow.tagIds')) AS selected WHERE selected.value IN (SELECT value FROM json_each(?))))";
      const rows = state.catalog?.rows<RecordHead>("records", where, [JSON.stringify(cursor ?? ""), request.vocabularyRevision, JSON.stringify(retiredIds)], "key", limit + 1) ?? [];
      const items = rows.slice(0, limit).map(({ key, value: head }) => {
        const ids = head.sourceRow?.tagIds ?? [];
        const hasRetired = ids.some(id => state.config.tagVocabulary.tags.find(tag => tag.id === id)?.state !== "active");
        const tagsStale = Boolean(head.sourceRow?.tagsStale);
        return { id: key, revisionId: head.latestRevisionId, reason: ids.length === 0 ? "untagged" as const : tagsStale && !hasRetired ? "stale-inputs" as const : hasRetired ? "retired-tag" as const : "vocabulary-changed" as const };
      });
      const last = items.at(-1)?.id;
      const nextCursor = rows.length > limit && last ? this.tagCursor(last, request.vocabularyRevision) : undefined;
      return { items, ...(nextCursor ? { nextCursor } : {}), vocabularyRevision: request.vocabularyRevision };
    });
  }
  async reconcileTagMerges(request: KnowledgeTagReconcileRequest): Promise<KnowledgeTagReconcileResponse> {
    if (request.limit !== undefined && (!Number.isSafeInteger(request.limit) || request.limit < 1 || request.limit > 25)) throw invalid("A merge re-point batch carries 1..25 items");
    const cursor = this.parseTagCursor(request.cursor, request.expectedConfigRevision);
    return this.mutate("knowledge.tags.reconcile", request.commandId, request, async (state, paths) => {
      if (request.expectedConfigRevision !== state.config.revision) throw conflict(`Knowledge configuration revision is stale; current revision is ${state.config.revision}`);
      const merged = new Map(state.config.tagVocabulary.tags.filter(tag => tag.state === "merged").map(tag => [tag.id, tag.mergedInto!]));
      const limit = request.limit ?? 25;
      if (!merged.size) return { applied: 0, unchanged: 0, outcomes: [], configRevision: state.config.revision };
      const mergeIds = [...merged.keys()];
      const where = "json_extract(entries.value, '$.kind') = 'source' AND key > ? AND EXISTS (SELECT 1 FROM json_each(json_extract(entries.value, '$.sourceRow.tagIds')) AS selected WHERE selected.value IN (SELECT value FROM json_each(?)))";
      const rows = state.catalog?.rows<RecordHead>("records", where, [JSON.stringify(cursor ?? ""), JSON.stringify(mergeIds)], "key", limit + 1) ?? [];
      const selected = rows.slice(0, limit).map(({ key, value }) => ({ id: key, head: value }));
      const outcomes: KnowledgeTagReconcileResponse["outcomes"] = [];
      for (const { id, head } of selected) {
        try {
          const current = await this.readRecord(paths, id, head.latestRevisionId);
          if (current.kind !== "source") { outcomes.push({ id, status: "failed", reason: "Tag merge applies to source records only" }); continue; }
          const active = new Set(state.config.tagVocabulary.tags.filter(tag => tag.state === "active").map(tag => tag.id));
          const tagIds = [...new Set((current.content.tags?.tagIds ?? []).map(tagId => merged.get(tagId) ?? tagId).filter(tagId => active.has(tagId)))];
          if (JSON.stringify(tagIds) === JSON.stringify(current.content.tags?.tagIds ?? [])) { outcomes.push({ id, status: "unchanged", revisionId: current.revisionId }); continue; }
          const result = await this.putRecord(state, paths, { kind: "source", id: current.id, createdAt: current.createdAt, scope: current.scope, provenance: current.provenance, relations: current.relations, ...(current.temporal ? { temporal: current.temporal } : {}), content: { ...current.content, tags: { tagIds, vocabularyRevision: state.config.tagVocabulary.revision, inputsDigest: curationInputsDigest(current.content), assignedAt: now(), producer: { actor: "system" } } } }, current.revisionId);
          outcomes.push({ id, status: "applied", revisionId: result.record.revisionId });
        } catch (error) {
          outcomes.push({ id, status: error instanceof GatewayError && error.code === "conflict" ? "conflict" : "failed", reason: error instanceof Error ? error.message : "Tag merge re-point failed" });
        }
      }
      const hasMore = rows.length > limit;
      const last = selected.at(-1)?.id;
      return { applied: outcomes.filter(item => item.status === "applied").length, unchanged: outcomes.filter(item => item.status === "unchanged").length, outcomes, ...(hasMore && last ? { nextCursor: this.tagCursor(last, request.expectedConfigRevision) } : {}), configRevision: request.expectedConfigRevision };
    });
  }
  private tagCursor(id: string, revision: number): string { return Buffer.from(JSON.stringify({ id, revision }), "utf8").toString("base64url"); }
  private parseTagCursor(cursor: string | undefined, revision: number): string | undefined {
    if (cursor === undefined) return undefined;
    try { const parsed = JSON.parse(Buffer.from(cursor, "base64url").toString("utf8")) as { id?: unknown; revision?: unknown }; if (typeof parsed.id !== "string" || parsed.revision !== revision || this.tagCursor(parsed.id, revision) !== cursor) throw new Error(); return parsed.id; } catch { throw invalid("Knowledge tag cursor is invalid or belongs to another vocabulary revision"); }
  }
  private tagRewriteCommand(commandId: string, recordId: string): string { return `${commandId.slice(0, 96)}:${createHash("sha256").update(`${commandId}\\0${recordId}`).digest("hex").slice(0, 32)}`.slice(0, 160); }
  private applyTagEdit(current: KnowledgeTagVocabularyConfig, edit: KnowledgeTagEditRequest["edit"]): KnowledgeTagVocabularyConfig {
    if (!edit || typeof edit !== "object") throw invalid("A typed Knowledge tag edit is required");
    const next = structuredClone(current);
    const find = (id: string): KnowledgeTagDefinition => { const tag = next.tags.find(item => item.id === id); if (!tag) throw invalid(`Unknown Knowledge tag ${id}`); if (tag.state !== "active") throw invalid(`Knowledge tag ${id} is not active`); return tag; };
    switch (edit.kind) {
      case "add": if (edit.tag?.state !== "active" || edit.tag.mergedInto !== undefined) throw invalid("A new Knowledge tag must be active and cannot name a merge target"); next.tags.push(structuredClone(edit.tag)); break;
      case "rename": find(edit.id).label = edit.label.trim(); break;
      case "redefine": find(edit.id).definition = edit.definition.trim(); break;
      case "recategorize": { const tag = find(edit.id); tag.category = edit.category; tag.decayClass = edit.decayClass; break; }
      case "retire": { const tag = find(edit.id); tag.state = "retired"; break; }
      case "merge": { const tag = find(edit.id); const target = find(edit.mergedInto); if (tag.id === target.id) throw invalid("A tag cannot be merged into itself"); tag.state = "merged"; tag.mergedInto = target.id; break; }
      case "guidelines": next.guidelines = edit.guidelines; break;
      default: throw invalid("Unsupported Knowledge tag edit");
    }
    return next;
  }
  private reprojectTagHeads(state: KnowledgeState): void {
    const activeById = new Map(state.config.tagVocabulary.tags.map(tag => [tag.id, tag]));
    for (const { key, value: head } of state.catalog?.rows<RecordHead>("records", "json_extract(value, '$.kind') = 'source'", [], "key") ?? []) {
      const row = head.sourceRow;
      if (!row) continue;
      const labels = (row.tagIds ?? []).flatMap(id => { const tag = activeById.get(id); return tag ? [tag.label] : []; }).join(" ").toLocaleLowerCase();
      head.searchFields = head.searchFields.filter(([field]) => field !== "tags");
      if (labels) head.searchFields.push(["tags", labels]);
      if (row.tagIds?.length) row.tags = row.tagIds.flatMap(id => { const tag = activeById.get(id); return tag ? [{ id: tag.id, label: tag.label, category: tag.category, decayClass: tag.decayClass, state: tag.state }] : []; });
      const selectedTags = row.tagIds?.map(id => state.config.tagVocabulary.tags.find(tag => tag.id === id));
      row.decayClass = !selectedTags?.length || selectedTags.some(tag => !tag || tag.state !== "active") ? "unknown" : selectedTags.some(tag => tag!.decayClass === "ages") ? "ages" : "does-not-age";
      state.records.set(key, head);
    }
  }
  async configure(commandId: string, config: KnowledgeConfig): Promise<KnowledgeConfig> {
    try { validateKnowledgeConfig(config); } catch (error) { throw invalid(error instanceof Error ? error.message : "Invalid knowledge config"); }
    return this.mutate("knowledge.config", commandId, config, async state => { if (config.revision !== state.config.revision) throw conflict("Knowledge configuration revision is stale"); if (JSON.stringify(config.tagVocabulary) !== JSON.stringify(state.config.tagVocabulary)) throw invalid("Tag taxonomy changes require the typed knowledge.tags.configure operation"); const next = structuredClone(config); next.tagVocabulary = structuredClone(state.config.tagVocabulary); next.revision += 1; state.config = next; return next; });
  }
  async setKnowledgeModel(commandId: string, expectedConfigRevision: number, model?: string): Promise<KnowledgeConfig> {
    if (!Number.isSafeInteger(expectedConfigRevision) || expectedConfigRevision < 0 || (model !== undefined && (typeof model !== "string" || model.length === 0 || model.length > 200))) throw invalid("Knowledge model requires an exact config revision and a bounded provider/model string");
    return this.mutate("knowledge.config", commandId, { expectedConfigRevision, knowledgeModel: model ?? null }, async state => {
      if (state.config.revision !== expectedConfigRevision) throw conflict(`Knowledge configuration revision is stale; current revision is ${state.config.revision}`);
      const { knowledgeModel: _previous, ...withoutKnowledgeModel } = state.config;
      const next = { ...withoutKnowledgeModel, ...(model ? { knowledgeModel: { model, maxInputChars: state.config.knowledgeModel?.maxInputChars ?? 48_000, maxOutputChars: state.config.knowledgeModel?.maxOutputChars ?? 8_000 } } : {}), revision: state.config.revision + 1 };
      validateKnowledgeConfig(next);
      state.config = next;
      return next;
    });
  }

  async withConnectorContext<T>(connectionId: string | undefined, task: () => Promise<T>): Promise<T> {
    return this.connectorContext.run(connectionId, task);
  }

  async connectorState(connector: "raindrop" | "x" | "jev", connectionId?: string): Promise<KnowledgeConnectorState | undefined> {
    return this.readState(async state => {
      const contextConnectionId = this.connectorContext.getStore();
      const key = connectionId ?? contextConnectionId;
      if (this.connectorEnvelope && !key) throw conflict("Connector state requires an admitted connection instance");
      const stateKey = key ?? connector;
      const value = state.connectors?.[stateKey];
      if (!value) return undefined;
      const next = structuredClone(value);
      const envelope = await this.connectorAuthority(connector, key);
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
    return this.readState(async (state, paths) => {
      const recordId = state.sourceIdentities.get(sourceIdentityKey(identity));
      const head = recordId ? state.records.get(recordId) : undefined;
      if (!head) return undefined;
      const record = await this.readRecordOrRemoved(paths, state, recordId!, head.latestRevisionId);
      if (!record || record.kind !== "source") return undefined;
      const matches = recordSourceIdentityKeys(record).includes(sourceIdentityKey(identity));
      return matches ? record : undefined;
    });
  }

  /** Raindrop and X state belongs to a ConnectionOwner account envelope. The
   * Jev ledger is keyed by the `typesafe` provider identity and its authority
   * (configured key, fixed monthly cap) is checked by KnowledgeTaggingBudget,
   * so it has no connection envelope to resolve. */
  private async connectorAuthority(connector: "raindrop" | "x" | "jev", key: string | undefined) {
    if (!this.connectorEnvelope || connector === "jev") return undefined;
    const envelope = key ? await this.connectorEnvelope(key) : undefined;
    if (!envelope) throw conflict("Connector connection authority is unavailable");
    return envelope;
  }

  /** Connector operational state shares the knowledge owner’s serialized state;
   * this update never accepts or persists a credential value. */
  async updateConnectorState(commandId: string, connector: "raindrop" | "x" | "jev", update: (current: KnowledgeConnectorState | undefined) => KnowledgeConnectorState, payload: unknown = { connector }, connectionId?: string): Promise<KnowledgeConnectorState> {
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
      let current = state.connectors?.[stateKey] ? structuredClone(state.connectors[stateKey]) : undefined;
      const envelope = await this.connectorAuthority(connector, key);
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
    return this.readState(async (state, paths) => {
      const limit = this.pageLimit(state, request.limit ?? 50);
      // Every visibility input belongs to cursor identity. A cursor from the
      // retained view must never be replayed against pending or archived
      // projection state, where skipped rows can otherwise make pagination
      // appear stalled or omit the first admitted row.
      const scope = JSON.stringify([request.kind ?? null, request.scope ?? null, request.includeSuppressed === true, request.includeArchived === true, request.includePending === true, request.sourceAdmission ?? null, request.excludePersonalSources === true]);
      const filter = this.pageFilter(request);
      if (request.cursor) {
        const cursor = readListCursor(request.cursor, scope);
        filter.clauses.push("json_extract(value, '$.sortAt') <= ? AND (json_extract(value, '$.sortAt') < ? OR key > json_quote(?))");
        filter.parameters.push(cursor.sortAt, cursor.sortAt, cursor.id);
      }
      const heads = this.visibleHeadPage(state, filter, scope, limit, request.cursor, request.includeSuppressed === true);
      const records: KnowledgeRecord[] = []; const budget = new KnowledgePageBudget();
      for (const { id, head } of heads.page) {
        const record = await this.readRecordOrRemoved(paths, state, id, head.latestRevisionId);
        if (!record) continue;
        // The body stays the authority: a head can only ever be derived from it.
        if (this.recordHardErased(state, record) || (!request.includeSuppressed && this.recordExcluded(state, record)) || (!request.includeArchived && this.recordArchived(record)) || (!request.includePending && this.recordPending(record))) continue;
        if (request.sourceAdmission !== undefined && (record.kind !== "source" || record.content.admission?.status !== request.sourceAdmission)) continue;
        if (records.length >= limit || !budget.admit(record)) break;
        records.push(record);
      }
      const nextCursor = this.pageCursor(scope, heads.page, records.length, heads.nextCursor);
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
  async sourceAssessmentReceipt(commandId: string): Promise<KnowledgeMutationResult | undefined> {
    return this.readState(async (state, paths) => {
      const receipt = state.receipts.get(`knowledge.source.record-write\0${commandId}`);
      if (!receipt) return undefined;
      if (receipt.operation !== "knowledge.source.record-write" || receipt.invalidated) throw conflict("Source assessment receipt is unavailable");
      const result = await this.receiptResult(paths, state, receipt.result);
      if (!result || typeof result !== "object" || !("record" in result) || !result.record || typeof result.record !== "object" || (result.record as KnowledgeRecord).kind !== "source") throw conflict("Command ID belongs to a different Knowledge mutation");
      return result as KnowledgeMutationResult;
    });
  }
  async read(id: string, revision?: string, includeSuppressed = false, includeArchived = false, includePending = false): Promise<KnowledgeRecord | null> {
    safeId(id, "record id"); if (revision !== undefined) safeId(revision, "knowledge revision");
    return this.readState(async (state, paths) => {
      const head = state.records.get(id);
      if (!head) return null;
      const selected = revision ?? head.latestRevisionId;
      if (!head.revisionIds.includes(selected)) throw new KnowledgeStoreError("invalid", "Requested revision is not committed for this record");
      const record = await this.readRecordOrRemoved(paths, state, id, selected);
      const latest = await this.readRecordOrRemoved(paths, state, id, head.latestRevisionId);
      if (!record || !latest) return null;
      // Visibility is governed by the current head even when an audit caller
      // asks for an older immutable revision.
      if (this.recordHardErased(state, record) || this.recordHardErased(state, latest)) return null;
      if (!includeSuppressed && (this.recordExcluded(state, record) || this.recordExcluded(state, latest))) return null;
      if (!includeArchived && (this.recordArchived(record) || this.recordArchived(latest))) return null;
      if (!includePending && (this.recordPending(record) || this.recordPending(latest))) return null;
      return record;
    });
  }
  /** One scored search page: the statement's own ordering key plus the keyset
   * that continues it. A scored page binds the query, filters, projection and
   * the exact state revision, because it cannot be resumed across a corpus
   * change without skipping or repeating rows. */
  private searchPage(request: KnowledgeSearchRequest, terms: string[], filter: { clauses: string[]; parameters: SQLInputValue[] }, scope: string, stateRevision: number): { clauses: string[]; parameters: SQLInputValue[]; order: string; freshnessNowMs: number; cursor?: SearchPosition } {
    const cursor = request.cursor === undefined ? undefined : readSearchCursor(request.cursor, scope, stateRevision);
    const freshnessNowMs = cursor?.freshnessNowMs ?? Date.now();
    const score = searchScoreSQL(terms);
    const freshness = searchFreshnessRankSQL(freshnessNowMs);
    const clauses = [...filter.clauses, `${score} > 0`];
    const where = [...filter.parameters, ...terms];
    if (cursor) {
      clauses.push(`(${score} < ? OR (${score} = ? AND (${freshness} < ? OR (${freshness} = ? AND (json_extract(value, '$.sortAt') < ? OR (json_extract(value, '$.sortAt') = ? AND key > ?))))))`);
      where.push(...terms, ...terms, cursor.score, cursor.score, cursor.freshnessRank, cursor.freshnessRank, cursor.sortAt, cursor.sortAt, JSON.stringify(cursor.id));
    }
    // The statement binds ORDER BY placeholders after every WHERE placeholder.
    return { clauses, parameters: [...where, ...terms], order: `${score} DESC, ${freshness} DESC, json_extract(value, '$.sortAt') DESC, key`, freshnessNowMs, ...(cursor ? { cursor } : {}) };
  }

  /** One page of scored, visible heads, resolved synchronously. The score is the
   * statement's own ordering key, so the cursor continues that exact order. */
  private scoredHeadPage(state: KnowledgeState, page: { clauses: string[]; parameters: SQLInputValue[]; order: string; freshnessNowMs: number; cursor?: SearchPosition }, terms: string[], scope: string, limit: number, stateRevision: number): { page: Array<{ id: string; head: RecordHead; score: number }>; nextCursor?: string } {
    const scored: Array<{ id: string; head: RecordHead; score: number }> = [];
    let nextCursor: string | undefined; let last: SearchPosition | undefined;
    for (const { key: id, value: head } of state.catalog?.scan<RecordHead>("records", page.clauses.join(" AND "), page.parameters, page.order) ?? []) {
      if (!this.headVisible(state, id, head)) continue;
      const score = headScore(head, terms);
      const freshnessRank = headFreshnessRank(head, page.freshnessNowMs);
      // SQLite's Julian-day arithmetic has sub-millisecond rounding. Recheck
      // the keyset in JS against the same clock snapshot so a boundary rounding
      // cannot repeat or skip a row on a scored page.
      if (page.cursor && !afterSearchPosition(score, freshnessRank, head.sortAt, id, page.cursor)) continue;
      if (scored.length >= limit) { nextCursor = searchCursor(scope, stateRevision, last!); break; }
      scored.push({ id, head, score }); last = { score, freshnessRank, sortAt: head.sortAt, id, freshnessNowMs: page.freshnessNowMs };
    }
    return { page: scored, ...(nextCursor ? { nextCursor } : {}) };
  }

  private scoredPageCursor(candidates: { page: Array<{ id: string; head: RecordHead; score: number }>; nextCursor?: string }, admitted: number, scope: string, stateRevision: number, freshnessNowMs: number): string | undefined {
    if (admitted >= candidates.page.length) return candidates.nextCursor;
    const last = admitted > 0 ? candidates.page[admitted - 1] : undefined;
    return last ? searchCursor(scope, stateRevision, { score: last.score, freshnessRank: headFreshnessRank(last.head, freshnessNowMs), sortAt: last.head.sortAt, id: last.id, freshnessNowMs }) : undefined;
  }

  /** The page's kind/scope/admission partition. Admission lives in the head, so
   * this is the same predicate the body checks apply, evaluated before a body is
   * read; the body remains the authority for the rows it admits. */
  private pageFilter(request: Pick<KnowledgeListRequest, "kind" | "scope" | "includeArchived" | "includePending" | "sourceAdmission" | "excludePersonalSources">): { clauses: string[]; parameters: SQLInputValue[] } {
    const base = this.catalogFilter(request); const admission = admissionFilter(request);
    const privacy = request.excludePersonalSources ? ["NOT (json_extract(value, '$.kind') = 'source' AND json_extract(value, '$.scope') = 'personal')"] : [];
    return { clauses: [...base.clauses, ...admission.clauses, ...privacy], parameters: [...base.parameters, ...admission.parameters] };
  }
  private headVisible(state: KnowledgeState, id: string, head: RecordHead, includeSuppressed = false): boolean {
    const suppression = state.suppressions.get(id);
    if (suppression?.forgotten) return false;
    if (head.recordRefs.some(reference => state.suppressions.get(reference)?.forgotten)) return false;
    if (includeSuppressed) return true;
    if (suppression?.excluded) return false;
    if (head.sessionId && state.config.eligibility.excludedSessionIds.includes(head.sessionId)) return false;
    const keys = [
      ...(head.sessionId ? [`session:${head.sessionId}`] : []),
      ...(head.sessionId && head.branchId ? [`branch:${head.sessionId}:${head.branchId}`] : []),
    ];
    return !keys.some(key => state.scopeExclusions.get(key)?.excluded);
  }

  /** Collect one page of visible heads. The whole scan is synchronous, so no
   * SQLite statement stays open across the body reads that follow and a reader
   * never blocks a committing writer. Visible heads are chosen here, so the
   * page is full even when most candidates are excluded. */
  private visibleHeadPage(state: KnowledgeState, filter: { clauses: string[]; parameters: SQLInputValue[] }, scope: string, limit: number, cursor?: string, includeSuppressed = false): { page: Array<{ id: string; head: RecordHead }>; nextCursor?: string } {
    const clauses = [...filter.clauses]; const parameters = [...filter.parameters];
    if (cursor !== undefined) {
      const anchor = readListCursor(cursor, scope);
      clauses.push("json_extract(value, '$.sortAt') <= ? AND (json_extract(value, '$.sortAt') < ? OR key > json_quote(?))");
      parameters.push(anchor.sortAt, anchor.sortAt, anchor.id);
    }
    const page: Array<{ id: string; head: RecordHead }> = [];
    let nextCursor: string | undefined; let last: { sortAt: number; id: string } | undefined;
    for (const { key: id, value: head } of state.catalog?.scan<RecordHead>("records", clauses.join(" AND "), parameters, "json_extract(value, '$.sortAt') DESC, key") ?? []) {
      if (!this.headVisible(state, id, head, includeSuppressed)) continue;
      if (page.length >= limit) { nextCursor = listCursor(scope, last!); break; }
      page.push({ id, head }); last = { sortAt: head.sortAt, id };
    }
    return { page, ...(nextCursor ? { nextCursor } : {}) };
  }

  /** The continuation for a page whose bodies no longer all qualify: it resumes
   * strictly after the last surviving head, so no row is skipped or repeated. */
  private pageCursor(scope: string, page: Array<{ id: string; head: RecordHead }>, admitted: number, scanned: string | undefined): string | undefined {
    if (admitted >= page.length) return scanned;
    const last = admitted > 0 ? page[admitted - 1] : undefined;
    return last ? listCursor(scope, { sortAt: last.head.sortAt, id: last.id }) : undefined;
  }

  /** Library rows. Every field comes from the catalog head, so a page of any
   * size reads no record body and no source text. `ids` refreshes only the rows
   * a change named, in the requested order. */
  async listSourceRows(request: KnowledgeListRequest): Promise<KnowledgeSourceRowListResponse> {
    if (request.kind !== "source") throw invalid("The row projection is available for sources only");
    if (request.includeSuppressed === true) throw invalid("The row projection always excludes suppressed records");
    const ids = request.ids;
    if (ids) {
      if (request.cursor !== undefined) throw invalid("A row identity refresh has no cursor");
      if (ids.length < 1 || ids.length > 64 || new Set(ids).size !== ids.length) throw invalid("A row identity refresh is bounded to 64 distinct ids");
      try { for (const id of ids) assertKnowledgeId(id, "row id"); } catch { throw invalid("A row identity refresh requires valid record ids"); }
    }
    return this.readState((state, _paths, present) => {
      if (!present) return { rows: [], stateRevision: 0 };
      const limit = this.pageLimit(state, request.limit ?? 50);
      const filter = this.pageFilter(request);
      const rows: KnowledgeSourceRow[] = [];
      const asRow = (id: string, head: RecordHead): KnowledgeSourceRow => sourceRow(id, head as RecordHead & { sourceRow: SourceRowFields });
      if (ids) {
        const clauses = [...filter.clauses, "key IN (SELECT json_quote(value) FROM json_each(?))"];
        const found = new Map<string, KnowledgeSourceRow>();
        for (const { key: id, value: head } of state.catalog?.scan<RecordHead>("records", clauses.join(" AND "), [...filter.parameters, JSON.stringify(ids)], "json_extract(value, '$.sortAt') DESC, key") ?? []) {
          if (head.kind !== "source" || !head.sourceRow || !this.headVisible(state, id, head)) continue;
          found.set(id, asRow(id, head));
        }
        // A single SQL scan cannot preserve a requested identity order.
        return { rows: ids.map(id => found.get(id)).filter((row): row is KnowledgeSourceRow => row !== undefined), stateRevision: state.stateRevision };
      }
      const scope = sourceRowScope(request);
      const heads = this.visibleHeadPage(state, filter, scope, limit, request.cursor);
      const budget = new KnowledgePageBudget();
      for (const { id, head } of heads.page) {
        if (head.kind !== "source" || !head.sourceRow) continue;
        const row = asRow(id, head);
        if (rows.length >= limit || !budget.admit(row)) break;
        rows.push(row);
      }
      const nextCursor = this.pageCursor(scope, heads.page, rows.length, heads.nextCursor);
      return { rows, stateRevision: state.stateRevision, ...(nextCursor ? { nextCursor } : {}) };
    });
  }

  async search(request: KnowledgeSearchRequest): Promise<KnowledgeSearchResponse> {
    if (typeof request.query !== "string" || request.query.trim().length === 0 || request.query.length > 512) throw invalid("Search query must be non-empty and bounded");
    return this.readState(async (state, paths) => {
      const terms = request.query.toLocaleLowerCase().split(/\s+/).filter(Boolean);
      const hits: KnowledgeSearchHit[] = []; const budget = new KnowledgePageBudget();
      const filter = this.pageFilter(request); const limit = this.pageLimit(state, request.limit ?? 50);
      const scope = searchScope(request);
      const page = this.searchPage(request, terms, filter, scope, state.stateRevision);
      const candidates = this.scoredHeadPage(state, page, terms, scope, limit, state.stateRevision);
      for (const { id, head, score } of candidates.page) {
        const record = await this.readRecordOrRemoved(paths, state, id, head.latestRevisionId);
        if (!record || this.recordExcluded(state, record) || (!request.includeArchived && this.recordArchived(record)) || (!request.includePending && this.recordPending(record))) continue;
        if (request.sourceAdmission !== undefined && (record.kind !== "source" || record.content.admission?.status !== request.sourceAdmission)) continue;
        const matchedFields = head.searchFields.filter(([, value]) => terms.some(term => value.includes(term))).map(([field]) => field);
        const hit = { record, score, matchedFields };
        if (!budget.admit(hit)) break;
        hits.push(hit);
      }
      const nextCursor = this.scoredPageCursor(candidates, hits.length, scope, state.stateRevision, page.freshnessNowMs);
      return { hits, stateRevision: state.stateRevision, indexState: "canonical", ...(nextCursor ? { nextCursor } : {}) };
    });
  }

  /** Library rows for a search. Scoring, ordering and continuation use the
   * stored search fields, so a page never reads a record body. */
  async searchSourceRows(request: KnowledgeSearchRequest): Promise<KnowledgeSourceRowSearchResponse> {
    if (request.kind !== "source") throw invalid("The row projection is available for sources only");
    if (typeof request.query !== "string" || request.query.trim().length === 0 || request.query.length > 512) throw invalid("Search query must be non-empty and bounded");
    return this.readState((state, _paths, present) => {
      if (!present) return { rows: [], stateRevision: 0 };
      const terms = request.query.toLocaleLowerCase().split(/\s+/).filter(Boolean);
      const filter = this.pageFilter(request); const limit = this.pageLimit(state, request.limit ?? 50);
      const scope = sourceRowSearchScope(request);
      const page = this.searchPage(request, terms, filter, scope, state.stateRevision);
      const candidates = this.scoredHeadPage(state, page, terms, scope, limit, state.stateRevision);
      const rows: KnowledgeSourceRow[] = [];
      for (const { id, head } of candidates.page) {
        if (head.kind !== "source" || !head.sourceRow) continue;
        rows.push(sourceRow(id, head as RecordHead & { sourceRow: SourceRowFields }));
      }
      const nextCursor = this.scoredPageCursor(candidates, rows.length, scope, state.stateRevision, page.freshnessNowMs);
      return { rows, stateRevision: state.stateRevision, ...(nextCursor ? { nextCursor } : {}) };
    });
  }

  async recall(request: KnowledgeRecallRequest): Promise<KnowledgeRecallResponse> {
    if (request.query !== undefined && (typeof request.query !== "string" || request.query.length > 512)) throw invalid("Recall query must be bounded");
    return this.readState(async (state, paths) => {
      const terms = request.query?.toLocaleLowerCase().split(/\s+/).filter(Boolean) ?? [];
      const filter = this.pageFilter(request); const limit = this.pageLimit(state, request.limit ?? 20);
      if (terms.length) {
        filter.clauses.push(`EXISTS (SELECT 1 FROM json_each(entries.value, '$.searchFields') AS field WHERE ${terms.map(() => "instr(json_extract(field.value, '$[1]'), ?) > 0").join(" AND ")})`);
        filter.parameters.push(...terms);
      }
      const score = terms.length ? searchScoreSQL(terms) : "CASE WHEN 1 = 1 THEN 0 ELSE 1 END";
      const freshness = searchFreshnessRankSQL();
      const orderedHeads: Array<{ id: string; head: RecordHead }> = [];
      const parameters = [...filter.parameters, ...terms];
      for (const { key: id, value: head } of state.catalog?.scan<RecordHead>("records", filter.clauses.join(" AND "), parameters, `${score} DESC, ${freshness} DESC, json_extract(value, '$.sortAt') DESC, key`) ?? []) {
        if (!this.headVisible(state, id, head)) continue;
        if (orderedHeads.length >= limit) break;
        orderedHeads.push({ id, head });
      }
      const records: KnowledgeRecord[] = []; const budget = new KnowledgePageBudget();
      for (const { id, head } of orderedHeads) {
        const record = await this.readRecordOrRemoved(paths, state, id, head.latestRevisionId);
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
    return this.readState(async (state, paths) => {
      const records: KnowledgeRecord[] = [];
      for (const revision of revisionIds) {
        safeId(revision, "knowledge revision");
        const id = state.catalog?.revisionOwner(revision);
        if (!id) throw conflict("Synthesis source revision is unavailable");
        const record = await this.readRecordOrRemoved(paths, state, id, revision);
        if (!record) throw conflict("Synthesis source revision is unavailable");
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
    return this.readState(async (state, paths) => {
      const records: KnowledgeRecord[] = [];
      for (const revision of new Set(revisionIds)) {
        safeId(revision, "knowledge revision");
        const id = state.catalog?.revisionOwner(revision);
        if (!id) continue;
        const record = await this.readRecordOrRemoved(paths, state, id, revision);
        if (!record) continue;
        if (record.kind === "observation" && record.content.range.sessionId === sessionId && !this.recordExcluded(state, record)) records.push(record);
      }
      return records;
    });
  }

  /** Internal source/import owner write. The transport action accepts URLs only. */
  async setSourceAdmission(request: { commandId: string; recordId: string; expectedRevision: string; status: import("./knowledge-contract.js").SourceAdmission; reason?: string; producer?: SourceCurationProducer; profileVersion?: string; rubricVersion?: string }): Promise<KnowledgeMutationResult> {
    return this.mutate("knowledge.source.admission", request.commandId, request, async (state, paths) => {
      const head = state.records.get(request.recordId);
      if (!head || head.latestRevisionId !== request.expectedRevision) throw conflict("Source revision is stale or unavailable");
      const current = await this.readRecord(paths, request.recordId, head.latestRevisionId);
      if (current.kind !== "source") throw conflict("Source revision is unavailable");
      if (isConnectorProducer(request.producer) && sourceAdmissionIsDecided(current)) {
        throw decisionAuthorityRefusal("admission", current.revisionId);
      }
      const admission = { status: request.status, ...(request.reason ? { reason: request.reason } : {}), decidedAt: now(), ...(request.producer ? { producer: request.producer } : {}), ...(request.profileVersion ? { profileVersion: request.profileVersion } : {}), ...(request.rubricVersion ? { rubricVersion: request.rubricVersion } : {}) };
      return this.putRecord(state, paths, { kind: "source", id: current.id, createdAt: current.createdAt, scope: current.scope, provenance: current.provenance, relations: current.relations, ...(current.temporal ? { temporal: current.temporal } : {}), content: { ...current.content, admission } }, request.expectedRevision);
    });
  }
  /** The user-owned take has its own fast, typed write path: no model work,
   * no agent-supplied producer, and the stale response includes the current
   * note so a client can preserve and reconcile its local draft. */
  async setSourceTake(request: KnowledgeSourceTakeRequest): Promise<KnowledgeMutationResult> {
    if (typeof request.text !== "string" || request.text.length > 4_000) throw invalid("Your take must be at most 4000 characters");
    return this.mutate("knowledge.source.take", request.commandId, request, async (state, paths) => {
      const head = state.records.get(request.recordId);
      const current = head ? await this.readRecord(paths, request.recordId, head.latestRevisionId) : null;
      if (!current || current.kind !== "source" || this.recordExcluded(state, current)) throw conflict("Source is unavailable for Your take");
      if (current.revisionId !== request.expectedRevision) throw new GatewayError("conflict", "Source revision changed; keep the draft and reconcile with the current take", false, {
        currentRevision: current.revisionId, currentTake: current.content.take?.text ?? "",
      });
      const text = request.text.trim();
      const take = text ? { text, confirmed: true as const, producer: { actor: "user" as const }, updatedAt: now() } : undefined;
      if (current.content.take?.text === take?.text) return { record: current, stateRevision: state.stateRevision };
      const { take: _previousTake, ...content } = current.content;
      return this.putRecord(state, paths, { kind: "source", id: current.id, createdAt: current.createdAt, scope: current.scope,
        provenance: current.provenance, relations: current.relations, ...(current.temporal ? { temporal: current.temporal } : {}),
        content: { ...content, ...(take ? { take } : {}) },
      }, current.revisionId);
    });
  }
  /** One agent- or user-authored interpretation on a source. Each item is its
   * own receipted mutation, so a batch is not atomic: one refusal or conflict
   * never rolls back another item, and a replay returns exactly the revision
   * that item wrote. The owner derives every evidence binding itself; a caller
   * can never supply the digest or revision a stored interpretation claims. */
  async curateSource(input: { commandId: string; operation: KnowledgeCurationOperation; producer: SourceCurationProducer; item: KnowledgeCurationItem }): Promise<KnowledgeMutationResult> {
    const request = { operation: input.operation, producer: input.producer, item: input.item };
    try {
      return await this.mutate("knowledge.source.curate", input.commandId, request, async (state, paths) => {
        const head = state.records.get(input.item.recordId);
        // A forgotten record keeps its tombstone but loses its head. Report the
        // erasure rather than a generic "unknown record", so a caller never
        // retries work the user deliberately destroyed.
        if (state.suppressions.get(input.item.recordId)?.forgotten) throw new KnowledgeCurationRefusal("forgotten", "Knowledge record was forgotten and cannot be curated");
        if (!head) throw new KnowledgeCurationRefusal("unknown-record", `Knowledge record ${input.item.recordId} is not available`);
        if (head.latestRevisionId !== input.item.expectedRevision) throw new KnowledgeCurationRefusal("stale-revision", `Knowledge record revision changed; expected ${input.item.expectedRevision} but ${head.latestRevisionId} is committed`, head.latestRevisionId);
        if (input.operation === "tags" && input.item.vocabularyRevision !== undefined && input.item.vocabularyRevision !== state.config.tagVocabulary.revision) throw new KnowledgeCurationRefusal("stale-vocabulary", `Tag vocabulary changed while Jev was deciding; re-read edition ${state.config.tagVocabulary.revision}`, head.latestRevisionId);
        if (input.operation !== "tags" && input.item.vocabularyRevision !== undefined) throw new KnowledgeCurationRefusal("invalid-input", "Only a tag operation may fence its vocabulary revision");
        const current = await this.readRecord(paths, input.item.recordId, head.latestRevisionId);
        if (current.kind !== "source") throw new KnowledgeCurationRefusal("invalid-input", "Knowledge curation applies to source records only");
        if (this.recordExcluded(state, current)) throw new KnowledgeCurationRefusal("excluded", "Knowledge record is excluded from retrieval");
        if (input.operation === "placement" && isConnectorProducer(input.producer)) {
          const placement = input.item.placement;
          if (placement?.scope !== undefined && current.content.scopeProducer && isDecisionProducer(current.content.scopeProducer)) throw decisionAuthorityRefusal("scope", current.revisionId);
          if (placement?.admission !== undefined && sourceAdmissionIsDecided(current)) throw decisionAuthorityRefusal("admission", current.revisionId);
        }
        const next = this.curatedSource(state, input.operation, input.producer, input.item, current);
        if (next.scope === current.scope && JSON.stringify(next.content) === JSON.stringify(current.content) && JSON.stringify(next.relations) === JSON.stringify(current.relations)) {
          return { record: current, stateRevision: state.stateRevision } satisfies KnowledgeMutationResult;
        }
        return this.putRecord(state, paths, {
          kind: "source", id: current.id, createdAt: current.createdAt, scope: next.scope,
          provenance: current.provenance, relations: next.relations,
          ...(current.temporal ? { temporal: current.temporal } : {}), content: next.content,
        }, current.revisionId);
      });
    } catch (error) {
      // The receipt fence refuses a changed payload under a reused command ID.
      // Report that as its own action, so an agent knows to start a new command
      // instead of retrying a payload the owner will never accept.
      if (error instanceof GatewayError && error.code === "conflict" && error.message.includes("already used for a different knowledge mutation")) {
        throw new KnowledgeCurationRefusal("command-id-reuse", "This command ID already recorded a different curation payload; start a new command ID instead of changing it");
      }
      throw error;
    }
  }
  /** The one place that builds curated content from a caller's item. Every
   * operation rejects the other operations' fields, so a payload is never
   * partially understood. */
  private curatedSource(state: KnowledgeState, operation: KnowledgeCurationOperation, producer: SourceCurationProducer, item: KnowledgeCurationItem, current: KnowledgeRecord & { kind: "source" }): { scope: KnowledgeScope; content: SourceContent; relations: KnowledgeRelation[] } {
    const content = current.content;
    const only = (allowed: keyof KnowledgeCurationItem) => {
      for (const field of ["summary", "tagIds", "verdict", "placement", "relation"] as const) {
        if (field !== allowed && item[field] !== undefined) throw new KnowledgeCurationRefusal("invalid-input", `The ${operation} operation does not accept ${field}`);
      }
    };
    const id = (value: unknown, label: string): string => { try { assertKnowledgeId(value as string, label); return value as string; } catch (error) { throw new KnowledgeCurationRefusal("invalid-input", error instanceof Error ? error.message : `Invalid ${label}`); } };
    const decided = now();
    switch (operation) {
      case "summary": {
        only("summary");
        const input = item.summary;
        if (!input || typeof input.text !== "string" || typeof input.coverage !== "string") throw new KnowledgeCurationRefusal("invalid-input", "A summary operation requires summary text and its coverage");
        const text = input.text.trim();
        if (!text || input.text.length > KNOWLEDGE_CURATION_MAX_SUMMARY_CHARS) throw new KnowledgeCurationRefusal("invalid-input", `Summary text must be 1..${KNOWLEDGE_CURATION_MAX_SUMMARY_CHARS} characters`);
        if (input.coverage !== "full" && input.coverage !== "sampled") throw new KnowledgeCurationRefusal("invalid-input", "Summary coverage must be full or sampled");
        return { scope: current.scope, relations: current.relations, content: { ...content, summary: { text, coverage: input.coverage, generatedAt: decided, sourceRevisionId: current.revisionId, evidenceDigest: sourceEvidenceDigest(content.title, content.text ?? ""), producer } } };
      }
      case "tags": {
        only("tagIds");
        if (!Array.isArray(item.tagIds) || item.tagIds.length > KNOWLEDGE_CURATION_MAX_TAGS) throw new KnowledgeCurationRefusal("invalid-input", `A tag selection carries at most ${KNOWLEDGE_CURATION_MAX_TAGS} tag IDs`);
        const ids = item.tagIds.map(value => id(value, "tag id"));
        if (new Set(ids).size !== ids.length) throw new KnowledgeCurationRefusal("invalid-input", "A tag selection repeats a tag ID");
        const configured = state.config.tagVocabulary;
        const vocabularyRevision = configured.revision;
        if (!Number.isSafeInteger(vocabularyRevision) || vocabularyRevision < 0) throw new KnowledgeCurationRefusal("unavailable", "The Knowledge tag vocabulary is unavailable");
        for (const value of ids) {
          const active = configured.tags.some(tag => tag.id === value && tag.state === "active");
          if (!active) throw new KnowledgeCurationRefusal("unknown-tag", vocabularyRevision === 0 ? `Unknown tag ${value}: no tag vocabulary is installed` : `Unknown tag ${value}: it is not in vocabulary revision ${vocabularyRevision}`);
        }
        return { scope: current.scope, relations: current.relations, content: { ...content, tags: { tagIds: ids, vocabularyRevision, inputsDigest: curationInputsDigest(content), assignedAt: decided, producer } } };
      }
      case "verdict": {
        only("verdict");
        const input = item.verdict;
        if (!input || (input.clear !== true && input.verdict === undefined)) throw new KnowledgeCurationRefusal("invalid-input", "A verdict operation requires a verdict or explicit clear");
        if (input.clear === true) {
          if (input.verdict !== undefined || input.supersededBy !== undefined || input.reason !== undefined) throw new KnowledgeCurationRefusal("invalid-input", "A clear verdict operation accepts no verdict, replacement, or reason");
          const { verdict: _verdict, ...withoutVerdict } = content;
          return { scope: current.scope, relations: current.relations, content: withoutVerdict };
        }
        if (input.verdict === "archive") throw new KnowledgeCurationRefusal("invalid-input", "Archive is source admission; use placement with admission archived");
        if (!input.verdict || !["evergreen", "dated", "superseded"].includes(input.verdict)) throw new KnowledgeCurationRefusal("invalid-input", "A verdict operation requires evergreen, dated, superseded, or explicit clear");
        if (input.reason !== undefined && (typeof input.reason !== "string" || input.reason.length > 2_000)) throw new KnowledgeCurationRefusal("invalid-input", "A verdict reason is at most 2000 characters");
        let supersededBy: string | undefined;
        if (input.supersededBy !== undefined) {
          supersededBy = id(input.supersededBy, "verdict replacement id");
          if (input.verdict !== "superseded") throw new KnowledgeCurationRefusal("invalid-input", "Only a superseded verdict names a replacement");
          if (supersededBy === current.id) throw new KnowledgeCurationRefusal("invalid-input", "An entry cannot supersede itself");
          if (!state.records.get(supersededBy) || state.suppressions.get(supersededBy)?.forgotten) throw new KnowledgeCurationRefusal("invalid-input", `Replacement entry ${supersededBy} is unavailable`);
        } else if (input.verdict === "superseded") {
          throw new KnowledgeCurationRefusal("invalid-input", "A superseded verdict requires the entry that replaces this one");
        }
        const verdict: SourceVerdictState = { verdict: input.verdict, ...(supersededBy ? { supersededBy } : {}), ...(input.reason ? { reason: input.reason } : {}), decidedAt: decided, producer };
        return { scope: current.scope, relations: current.relations, content: { ...content, verdict } };
      }
      case "placement": {
        only("placement");
        const input = item.placement;
        if (!input || (input.scope === undefined && input.admission === undefined)) throw new KnowledgeCurationRefusal("invalid-input", "A placement operation requires scope, admission, or both");
        if (input.scope !== undefined && input.scope !== "personal" && input.scope !== "research") throw new KnowledgeCurationRefusal("invalid-input", "Scope must be personal or research");
        if (input.admission !== undefined && !["pending", "retained", "archived"].includes(input.admission as string)) throw new KnowledgeCurationRefusal("invalid-input", "Admission must be pending, retained, or archived");
        if (input.reason !== undefined && (typeof input.reason !== "string" || input.reason.length > 2_000)) throw new KnowledgeCurationRefusal("invalid-input", "A placement reason is at most 2000 characters");
        return {
          scope: input.scope ?? current.scope, relations: current.relations,
          content: { ...content, ...(input.scope === undefined ? {} : { scopeProducer: producer }), ...(input.admission === undefined ? {} : { admission: { status: input.admission, ...(input.reason ? { reason: input.reason } : {}), decidedAt: decided, producer } }) },
        };
      }
      case "relation": {
        only("relation");
        const input = item.relation;
        if (!input || (input.action !== "add" && input.action !== "remove")) throw new KnowledgeCurationRefusal("invalid-input", "A relation operation requires add or remove");
        if (!["supports", "contradicts", "corrects", "supersedes", "derivedFrom", "related"].includes(input.type as string)) throw new KnowledgeCurationRefusal("invalid-input", "Invalid relation type");
        const target = id(input.recordId, "relation record id");
        if (target === current.id) throw new KnowledgeCurationRefusal("invalid-input", "An entry cannot relate to itself");
        if (!state.records.get(target) || state.suppressions.get(target)?.forgotten) throw new KnowledgeCurationRefusal("invalid-input", `Related entry ${target} is unavailable`);
        const present = current.relations.some(relation => relation.type === input.type && relation.recordId === target);
        // Relations are identity-qualified by type and target, so an add of an
        // existing edge and a remove of an absent one are both no-ops.
        const relations = input.action === "add"
          ? (present ? current.relations : [...current.relations, { type: input.type, recordId: target }])
          : current.relations.filter(relation => !(relation.type === input.type && relation.recordId === target));
        return { scope: current.scope, relations, content };
      }
    }
  }
  async captureSource(request: SourceRecordWriteRequest): Promise<KnowledgeMutationResult> {
    if (request.record.content.take !== undefined) throw invalid("Your take is user-owned and can only be written with knowledge.source.take");
    const { signal, ...receiptRequest } = request;
    const { canonicalUri } = request;
    return this.mutate("knowledge.source.record-write", request.commandId, receiptRequest, async (state, paths) => {
      if (canonicalUri) {
        const normalized = normalizeKnowledgeSourceUrl(canonicalUri);
        const matches: Array<KnowledgeRecord & { kind: "source" }> = [];
        for (const id of state.records.keys()) {
          const current = await this.currentRecord(state, paths, id);
          if (current?.kind === "source" && current.scope === request.record.scope && current.content.uri && normalizeKnowledgeSourceUrl(current.content.uri) === normalized) matches.push(current);
        }
        if (matches.length > 1) throw conflict("Multiple sources match the validated redirect target");
        const existing = matches[0];
        if (existing && existing.id !== request.record.id) {
          if (existing.content.captureDisposition === "complete") {
            const merged = mergeSourceAttribution(existing, request.record);
            if (JSON.stringify(merged.content) !== JSON.stringify(existing.content)) return this.putRecord(state, paths, merged, existing.revisionId);
            return { record: existing, stateRevision: state.stateRevision + 1 };
          }
          throw conflict("Redirect target changed while source capture was publishing");
        }
      }
      const current = request.record.id ? await this.currentRecord(state, paths, request.record.id) : null;
      if (request.writer === "connector" && current?.kind === "source" && request.record.kind === "source") this.assertSourceDecisionAuthority(current, request.record, "connector");
      return this.putRecord(state, paths, request.record as KnowledgeRecordDraft, request.expectedRevision);
    }, undefined, signal);
  }
  async publishSourcePreview(request: SourcePreviewWriteRequest): Promise<KnowledgeMutationResult> {
    const { signal, ...receiptRequest } = request;
    return this.mutate("knowledge.source.preview.refresh", request.commandId, receiptRequest, async (state, paths) => {
      const head = state.records.get(request.recordId);
      if (!head || head.latestRevisionId !== request.expectedRevision) throw conflict("Source revision is stale or unavailable");
      const current = await this.currentRecord(state, paths, request.recordId);
      if (!current || current.kind !== "source") throw conflict("Source revision is unavailable");
      if (this.recordExcluded(state, current) || this.recordArchived(current) || this.recordPending(current)) throw conflict("Source is unavailable for preview refresh");
      if (current.content.preview?.hash === request.preview.hash && current.content.preview.bytes === request.preview.bytes && current.content.preview.mediaType === request.preview.mediaType) return { record: current, stateRevision: state.stateRevision + 1 };
      return this.putRecord(state, paths, { kind: "source", id: current.id, createdAt: current.createdAt, scope: current.scope, provenance: current.provenance, relations: current.relations, ...(current.temporal ? { temporal: current.temporal } : {}), content: { ...current.content, preview: request.preview } }, request.expectedRevision);
    }, undefined, signal);
  }
  async createNote(request: KnowledgeNoteMutationRequest & { recordId?: never }): Promise<KnowledgeMutationResult> { return this.mutate("knowledge.note.create", request.commandId, request, async (state, paths) => this.putRecord(state, paths, request.record)); }
  async updateNote(request: KnowledgeNoteMutationRequest & { recordId: string }): Promise<KnowledgeMutationResult> { return this.mutate("knowledge.note.update", request.commandId, request, async (state, paths) => { const current = await this.currentRecord(state, paths, request.recordId); if (!current || current.kind !== "note") throw conflict("Knowledge note does not exist"); if (request.expectedRevision !== current.revisionId) throw conflict("Knowledge note revision is stale"); return this.putRecord(state, paths, { ...request.record, id: request.recordId, createdAt: current.createdAt }, request.expectedRevision); }); }
  private assertSourceDecisionAuthority(current: KnowledgeRecord & { kind: "source" }, next: KnowledgeRecordDraft & { kind: "source" }, producer: string | undefined): void {
    if (!isConnectorProducer(producer)) return;
    if (next.scope !== current.scope && current.content.scopeProducer && isDecisionProducer(current.content.scopeProducer)) throw decisionAuthorityRefusal("scope", current.revisionId);
    if (JSON.stringify(next.content.admission) !== JSON.stringify(current.content.admission) && sourceAdmissionIsDecided(current)) throw decisionAuthorityRefusal("admission", current.revisionId);
  }
  private async currentRecord(state: KnowledgeState, paths: StorePaths, id: string): Promise<KnowledgeRecord | null> { const head = state.records.get(id); return head ? this.readRecord(paths, id, head.latestRevisionId) : null; }
  private async currentRecordForRead(state: KnowledgeState, paths: StorePaths, id: string): Promise<KnowledgeRecord | null> { const head = state.records.get(id); return head ? await this.readRecordOrRemoved(paths, state, id, head.latestRevisionId) ?? null : null; }
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
    const nextHead = headFor(record, revisions, existing?.objectHashes, state.config);
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
    return this.readState(state => {
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
  async generateSourceSummary(commandId: string, sourceId: string, expectedRevision: string, expectedConfigRevision: number, generate: (source: KnowledgeRecord & { kind: "source" }) => Promise<import("./knowledge-contract.js").SourceSummary>, signal?: AbortSignal): Promise<KnowledgeMutationResult> {
    const operation = "knowledge.source.summarize";
    const request = { sourceId, expectedRevision, expectedConfigRevision };
    // One process-wide in-flight owner per command, so a duplicate call shares
    // its result instead of charging the configured model twice. The request is
    // part of the key: a different request reusing the command ID still reaches
    // the receipt fence and conflicts there.
    const receiptKey = `${operation}\0${commandId}`;
    const inFlightKey = `${receiptKey}\0${requestHash(operation, request)}`;
    const inFlight = this.summaryInFlight.get(inFlightKey);
    if (inFlight) return inFlight;
    const run = this.runSourceSummary(operation, commandId, receiptKey, request, generate, signal);
    this.summaryInFlight.set(inFlightKey, run);
    try { return await run; } finally { this.summaryInFlight.delete(inFlightKey); }
  }

  /** The model call runs outside the store mutex: a long generation must not
   * stall reads or unrelated mutations. Both the preflight and the commit
   * revalidate the exact source revision, config revision and privacy fence. */
  private async runSourceSummary(operation: string, commandId: string, key: string, request: { sourceId: string; expectedRevision: string; expectedConfigRevision: number }, generate: (source: KnowledgeRecord & { kind: "source" }) => Promise<import("./knowledge-contract.js").SourceSummary>, signal?: AbortSignal): Promise<KnowledgeMutationResult> {
    const replayed = await this.readState(async (state, paths) => this.replayReceipt(paths, state, key, operation, requestHash(operation, request)));
    if (replayed.found) return replayed.result as KnowledgeMutationResult;
    if (signal?.aborted) throw new GatewayError("busy", "Source summary was cancelled", true);
    const current = await this.readState(async (state, paths) => {
      if (state.config.revision !== request.expectedConfigRevision) throw conflict("Knowledge configuration changed while the summary was generated");
      const found = await this.currentRecordForRead(state, paths, request.sourceId);
      if (!found || found.kind !== "source" || found.revisionId !== request.expectedRevision || this.recordExcluded(state, found)) throw conflict("Source changed or became unavailable while the summary was generated");
      if (!found.content.text?.trim()) throw new GatewayError("unsupported", "A readable source extraction is required to generate a summary");
      return found;
    });
    const summary = await generate(current);
    if (signal?.aborted) throw new GatewayError("busy", "Source summary was cancelled", true);
    return this.mutate(operation, commandId, request, async (state, paths) => {
      if (signal?.aborted) throw new GatewayError("busy", "Source summary was cancelled", true);
      if (state.config.revision !== request.expectedConfigRevision) throw conflict("Knowledge configuration changed while the summary was generated");
      const latest = await this.currentRecord(state, paths, request.sourceId);
      if (!latest || latest.kind !== "source" || latest.revisionId !== request.expectedRevision || this.recordExcluded(state, latest)) throw conflict("Source changed or became unavailable while the summary was generated");
      if (summary.sourceRevisionId !== latest.revisionId) throw conflict("Source summary evidence revision is stale");
      return this.putRecord(state, paths, { kind: "source", id: latest.id, createdAt: latest.createdAt, scope: latest.scope, provenance: latest.provenance, relations: latest.relations, ...(latest.temporal ? { temporal: latest.temporal } : {}), content: { ...latest.content, summary } }, latest.revisionId);
    }, undefined, signal);
  }
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
  async correct(commandId: string, recordId: string, expectedRevision: string, replacement: KnowledgeRecordDraft, relation: KnowledgeRecord["relations"][number]): Promise<KnowledgeMutationResult> { return this.mutate("knowledge.correction", commandId, { recordId, expectedRevision, replacement, relation }, async (state, paths) => { const current = await this.currentRecord(state, paths, recordId); if (!current || current.revisionId !== expectedRevision) throw conflict("Knowledge record revision is stale"); if (relation.recordId !== recordId || relation.revisionId !== expectedRevision || (relation.type !== "corrects" && relation.type !== "supersedes")) throw invalid("Correction relation must identify the replaced revision"); const next = { ...replacement, id: recordId, createdAt: current.createdAt, relations: [...replacement.relations, relation] }; if (current.kind === "source" && next.kind === "source") this.assertSourceDecisionAuthority(current, next, next.provenance.actor); return this.putRecord(state, paths, next, expectedRevision); }); }
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
          state.records.set(id, headFor(scrubbed, [scrubbed.revisionId], [], state.config));
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
  /** The one object-authorization predicate: the exact committed revision of a
   * record whose current head is visible must itself reference this object. Do
   * not fall back to a corpus scan or an evidence hash, since either can
   * authorize an object after its source was excluded or replaced. */
  private async authorizedObjectPath(paths: StorePaths, state: KnowledgeState, ref: KnowledgeObjectRef, recordId: string, revisionId: string, includeArchived: boolean): Promise<string | undefined> {
    const head = state.records.get(recordId);
    if (!head || !head.revisionIds.includes(revisionId)) return undefined;
    const record = await this.readRecordOrRemoved(paths, state, recordId, revisionId);
    if (!record) return undefined;
    const latest = await this.readRecordOrRemoved(paths, state, recordId, head.latestRevisionId);
    if (!latest) return undefined;
    if (this.recordExcluded(state, latest) || (!includeArchived && this.recordArchived(latest)) || this.recordPending(latest)) return undefined;
    return recordObjectRefs(record).some(candidate => candidate.hash === ref.hash
      && candidate.bytes === ref.bytes && candidate.mediaType === ref.mediaType) ? join(paths.objects, ref.hash) : undefined;
  }

  async readObject(ref: KnowledgeObjectRef, authority: { recordId: string; revisionId: string; includeArchived?: boolean }): Promise<Uint8Array | null> {
    validateObjectRef(ref);
    assertKnowledgeId(authority.recordId, "object authority record id");
    assertKnowledgeId(authority.revisionId, "object authority revision");
    const admittedPath = await this.readState(async (state, paths, present) =>
      present ? await this.authorizedObjectPath(paths, state, ref, authority.recordId, authority.revisionId, authority.includeArchived === true) : undefined);
    if (!admittedPath) return null;
    // The catalog is closed while bytes are read. A concurrent forget/exclusion
    // must win over the initial admission, so authority is rechecked against a
    // fresh snapshot rather than the one that admitted it.
    const bytes = await readSecureBytes(admittedPath, OBJECT_MAX_BYTES);
    if (!bytes) return null;
    if (bytes.byteLength !== ref.bytes || createHash("sha256").update(bytes).digest("hex") !== ref.hash) throw new KnowledgeStoreError("invalid", "Knowledge object failed hash or size verification");
    return this.readState(async (state, paths, present) =>
      present ? await this.authorizedObjectPath(paths, state, ref, authority.recordId, authority.revisionId, authority.includeArchived === true) ? bytes : null : null);
  }

  /** One bounded batch of exact preview references for the library grid. Each
   * item is authorized independently, so one missing or over-budget preview
   * never fails the page, and each is rechecked after its bytes are read. */
  async readPreviewsBatch(request: KnowledgePreviewBatchRequest): Promise<KnowledgePreviewBatchResponse> {
    const items = request.items;
    if (!Array.isArray(items) || items.length < 1 || items.length > KNOWLEDGE_PREVIEW_BATCH_ITEMS) throw invalid(`A preview batch is bounded to ${KNOWLEDGE_PREVIEW_BATCH_ITEMS} items`);
    const seen = new Set<string>();
    for (const item of items) {
      if (!item || typeof item !== "object") throw invalid("A preview batch item is invalid");
      try { validateObjectRef({ hash: item.hash, mediaType: item.mediaType, bytes: item.bytes }); assertKnowledgeId(item.recordId, "preview record id"); assertKnowledgeId(item.revisionId, "preview revision"); }
      catch { throw invalid("A preview batch item requires an exact committed preview reference"); }
      const key = `${item.recordId}\u0000${item.revisionId}\u0000${item.hash}`;
      if (seen.has(key)) throw invalid("Preview batch items must be distinct");
      seen.add(key);
    }
    const includeArchived = request.includeArchived === true;
    const admitted = await this.readState(async (state, paths, present) => present
      ? await Promise.all(items.map(async item => {
        const head = state.records.get(item.recordId);
        if (!head || !head.revisionIds.includes(item.revisionId)) return undefined;
        const record = await this.readRecordOrRemoved(paths, state, item.recordId, item.revisionId);
        const preview = record?.kind === "source" ? record.content.preview : undefined;
        if (!preview || preview.hash !== item.hash || preview.bytes !== item.bytes || preview.mediaType !== item.mediaType) return undefined;
        return await this.authorizedObjectPath(paths, state, { hash: item.hash, mediaType: item.mediaType, bytes: item.bytes }, item.recordId, item.revisionId, includeArchived);
      }))
      : items.map(() => undefined));
    const results: KnowledgePreviewBatchResponse["items"] = [];
    let total = 0;
    for (const [index, item] of items.entries()) {
      const path = admitted[index];
      if (!path) { results.push({ recordId: item.recordId, hash: item.hash, unavailable: "forbidden" }); continue; }
      if (item.bytes > KNOWLEDGE_PREVIEW_MAX_BYTES || total + item.bytes > KNOWLEDGE_PREVIEW_BATCH_BYTES) { results.push({ recordId: item.recordId, hash: item.hash, unavailable: "too-large" }); continue; }
      const bytes = await readSecureBytes(path, KNOWLEDGE_PREVIEW_MAX_BYTES);
      if (!bytes) { results.push({ recordId: item.recordId, hash: item.hash, unavailable: "missing" }); continue; }
      if (bytes.byteLength !== item.bytes || createHash("sha256").update(bytes).digest("hex") !== item.hash) throw new KnowledgeStoreError("invalid", "Knowledge preview failed hash or size verification");
      // A concurrent forget or exclusion must not be outrun by the read.
      const still = await this.readState(async (state, paths, present) => present ? await this.authorizedObjectPath(paths, state, { hash: item.hash, mediaType: item.mediaType, bytes: item.bytes }, item.recordId, item.revisionId, includeArchived) !== undefined : false);
      if (!still) { results.push({ recordId: item.recordId, hash: item.hash, unavailable: "forbidden" }); continue; }
      total += bytes.byteLength;
      results.push({ recordId: item.recordId, hash: item.hash, base64: Buffer.from(bytes).toString("base64") });
    }
    return { items: results };
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
    safeId(id, "coverage id"); return this.readState(state => state.coverage.get(id) ?? null);
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
    return this.readState(state => {
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
    return this.readState(state => (state.catalog?.rows<ObservationCoverage>("coverage",
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
    return this.readState(state => (state.catalog?.rows<ObservationCoverage>("coverage",
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
