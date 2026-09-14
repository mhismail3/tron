import type { JsonValue } from "../protocol/types.js";
import { isGatewayTimestamp } from "../util/timestamp.js";

export const KNOWLEDGE_SCHEMA_VERSION = 1 as const;
export type KnowledgeScope = "personal" | "research";
export type KnowledgeRecordKind = "source" | "observation" | "note";

export interface KnowledgeObjectRef {
  hash: string;
  mediaType: string;
  bytes: number;
}

export interface KnowledgeSessionEntryCitation {
  sessionId: string;
  branchId?: string;
  entryId: string;
  digest?: string;
  startOffset?: number;
  endOffset?: number;
}

export interface KnowledgeEvidenceRef {
  /** A record citation is exact when revisionId is supplied. */
  recordId?: string;
  revisionId?: string;
  sessionEntry?: KnowledgeSessionEntryCitation;
  objectHash?: string;
  locator?: string;
}

export interface KnowledgeProvenance {
  actor: "user" | "agent" | "connector" | "import" | "system";
  source?: string;
  sessionId?: string;
  branchId?: string;
  invocationId?: string;
  evidence: KnowledgeEvidenceRef[];
}

export interface KnowledgeTemporalQualification {
  eventAt?: string;
  validFrom?: string;
  validTo?: string;
  reviewDue?: string;
  timezone?: string;
}

export type KnowledgeRelationType =
  | "supports"
  | "contradicts"
  | "corrects"
  | "supersedes"
  | "derivedFrom"
  | "related";

export interface KnowledgeRelation {
  type: KnowledgeRelationType;
  recordId: string;
  revisionId?: string;
  field?: string;
}

export type SourceOriginKind = "manual" | "connector" | "import" | "conversation";

/** Stable identity supplied by a connector. Values are opaque and never credentials. */
export interface SourceIdentity {
  provider: string;
  accountId: string;
  itemId: string;
}

export interface SourceOrigin {
  kind: SourceOriginKind;
  capturedAt: string;
  uri?: string;
  identity?: SourceIdentity;
  annotation?: string;
}

/** Generated material is deliberately separate from retained source evidence. */
export interface SourceAssessment {
  summary: string;
  contribution?: string;
  whyItMatters?: string;
  evidenceQuality: "high" | "medium" | "low" | "none";
  freshness: "current" | "aging" | "stale" | "unknown";
  possibleUse?: string;
  generatedAt: string;
  model?: string;
}

export interface SourceContent {
  title: string;
  uri?: string;
  /** Readable extraction, not a substitute for the original object. */
  text?: string;
  /** Immutable original bytes, when captured. */
  object?: KnowledgeObjectRef;
  mediaType?: string;
  captureDisposition: "complete" | "partial" | "metadata-only" | "inaccessible" | "failed" | "reference-only";
  annotations?: Array<{ text: string; locator?: string; createdAt?: string }>;
  sourcePublishedAt?: string;
  capturedAt: string;
  origin?: SourceOriginKind;
  origins?: SourceOrigin[];
  identity?: SourceIdentity;
  assessment?: SourceAssessment;
}

export interface ObservationRange {
  sessionId: string;
  branchId?: string;
  fromEntryId: string;
  toEntryId: string;
  /** Ordered canonical entries captured by this observation group. */
  entryIds: string[];
  /** Digest supplied by the canonical session owner for entryIds and bytes. */
  entryDigest: string;
  projectId?: string;
  invocationIds?: string[];
}

export interface ObservationItem {
  text: string;
  attribution: "user" | "assistant" | "tool" | "system" | "unknown";
  observedAt: string;
  certainty: "certain" | "qualified" | "uncertain";
  evidence?: KnowledgeEvidenceRef[];
  field?: string;
}

export interface ObservationContent {
  range: ObservationRange;
  items: ObservationItem[];
  observer?: { model?: string; promptVersion: string };
}

export interface NoteFieldQualification {
  field: string;
  value: JsonValue;
  subject?: string;
  evidence: KnowledgeEvidenceRef[];
  certainty: "confirmed" | "candidate" | "external" | "historical";
  validFrom?: string;
  validTo?: string;
}

export interface NoteContent {
  title: string;
  body?: string;
  fields?: NoteFieldQualification[];
  role: "fact" | "preference" | "concept" | "decision" | "workflow" | "synthesis";
  confirmed: boolean;
  /** Explicitly retained evidence against a candidate or claim. */
  contraryEvidence?: KnowledgeEvidenceRef[];
  /** Review/freshness metadata is descriptive and never an automatic deletion date. */
  freshness?: "current" | "aging" | "stale" | "unknown";
  privacyScope?: "private" | "shared";
}

export interface KnowledgeRecordBase {
  schemaVersion: typeof KNOWLEDGE_SCHEMA_VERSION;
  id: string;
  revisionId: string;
  kind: KnowledgeRecordKind;
  scope: KnowledgeScope;
  createdAt: string;
  updatedAt: string;
  provenance: KnowledgeProvenance;
  temporal?: KnowledgeTemporalQualification;
  relations: KnowledgeRelation[];
}

export type KnowledgeRecord =
  | (KnowledgeRecordBase & { kind: "source"; content: SourceContent })
  | (KnowledgeRecordBase & { kind: "observation"; content: ObservationContent })
  | (KnowledgeRecordBase & { kind: "note"; content: NoteContent });

export type KnowledgeRecordDraft = Omit<KnowledgeRecordBase, "schemaVersion" | "id" | "revisionId" | "createdAt" | "updatedAt"> & {
  id?: string;
  createdAt?: string;
  updatedAt?: string;
} & ({ kind: "source"; content: SourceContent } | { kind: "observation"; content: ObservationContent } | { kind: "note"; content: NoteContent });

export interface ObservationCoverage {
  schemaVersion: typeof KNOWLEDGE_SCHEMA_VERSION;
  id: string;
  revisionId: string;
  range: ObservationRange;
  disposition: "observed" | "empty" | "excluded" | "pending" | "failed" | "unavailable";
  groupRevisionIds: string[];
  recordedAt: string;
  reason?: string;
}

export interface KnowledgeEligibility {
  sessionIds: string[];
  projectIds: string[];
  excludedSessionIds: string[];
  excludedProjectIds: string[];
}

export interface KnowledgeConfig {
  schemaVersion: typeof KNOWLEDGE_SCHEMA_VERSION;
  /** Monotonically increasing revision for optimistic UI/runtime updates. */
  revision: number;
  eligibility: KnowledgeEligibility;
  observation: {
    enabled: boolean;
    model?: string;
    maxInputChars: number;
    maxOutputChars: number;
    timeoutMs: number;
    maxAttempts: number;
  };
  maximumSearchResults: number;
  /** Editable interests used only when an explicit triage operation runs. */
  currentInterests?: string[];
}

export const DEFAULT_KNOWLEDGE_CONFIG: KnowledgeConfig = {
  schemaVersion: KNOWLEDGE_SCHEMA_VERSION,
  revision: 0,
  eligibility: { sessionIds: [], projectIds: [], excludedSessionIds: [], excludedProjectIds: [] },
  observation: {
    enabled: false,
    maxInputChars: 48_000,
    maxOutputChars: 8_000,
    timeoutMs: 30_000,
    maxAttempts: 1,
  },
  maximumSearchResults: 50,
  currentInterests: [],
};

export interface KnowledgeStatus {
  available: boolean;
  state: "uninitialized" | "ready" | "unsafe" | "invalid" | "newer" | "closed";
  stateRevision?: number;
  recordCount: number;
  coverageCount: number;
  suppressedCount: number;
  pendingCleanupCount: number;
  config: KnowledgeConfig;
  observationConfigured: boolean;
  detail?: string;
}

export interface KnowledgeListRequest {
  kind?: KnowledgeRecordKind;
  scope?: KnowledgeScope;
  includeSuppressed?: boolean;
  cursor?: string;
  limit?: number;
}

export interface KnowledgeListResponse {
  records: KnowledgeRecord[];
  nextCursor?: string;
  stateRevision: number;
}

export interface KnowledgeSearchRequest {
  query: string;
  kind?: KnowledgeRecordKind;
  scope?: KnowledgeScope;
  limit?: number;
}

export interface KnowledgeSearchHit {
  record: KnowledgeRecord;
  score: number;
  matchedFields: string[];
}

export interface KnowledgeSearchResponse {
  hits: KnowledgeSearchHit[];
  stateRevision: number;
  indexState: "canonical";
}

export interface KnowledgeRecallRequest {
  query?: string;
  sessionId?: string;
  entryId?: string;
  scope?: KnowledgeScope;
  limit?: number;
}

export interface KnowledgeRecallResponse {
  records: KnowledgeRecord[];
  citations: KnowledgeEvidenceRef[];
  stateRevision: number;
  availability: "available" | "no-match";
}

export interface KnowledgeSourceRecordCaptureRequest {
  commandId: string;
  expectedRevision?: string;
  record: KnowledgeRecordDraft & { kind: "source" };
}

/** URL capture is fetched by the Gateway source owner; callers never submit
 * fetched text as if it were canonical evidence. */
export interface KnowledgeSourceURLCaptureRequest {
  commandId: string;
  url: string;
  scope: KnowledgeScope;
  title?: string;
  annotations?: SourceContent["annotations"];
  identity?: SourceIdentity;
  origin?: SourceOriginKind;
  expectedRevision?: string;
}

export type KnowledgeSourceCaptureRequest = KnowledgeSourceRecordCaptureRequest | KnowledgeSourceURLCaptureRequest;

export interface KnowledgeNoteMutationRequest {
  commandId: string;
  recordId?: string;
  expectedRevision?: string;
  record: KnowledgeRecordDraft & { kind: "note" };
}

export interface KnowledgeCorrectionRequest {
  commandId: string;
  recordId: string;
  expectedRevision: string;
  replacement: KnowledgeRecordDraft;
  relation: KnowledgeRelation;
}

export interface KnowledgeForgetRequest {
  commandId: string;
  recordId: string;
  expectedRevision?: string;
  reason: string;
}

export interface KnowledgeExclusionRequest {
  commandId: string;
  recordId?: string;
  sessionId?: string;
  branchId?: string;
  projectId?: string;
  expectedRevision?: string;
  excluded: boolean;
  reason?: string;
}

export interface KnowledgeReflectRequest {
  commandId: string;
  sessionId: string;
  sourceRevisionIds: string[];
  expectedConfigRevision?: number;
}

export interface KnowledgeTriageRequest {
  commandId: string;
  sourceId: string;
  expectedRevision: string;
}

export interface KnowledgeConnectorConfigurationRequest {
  commandId: string;
  connector: "raindrop" | "x";
  enabled: boolean;
  scope?: string;
  destination?: string;
}

export interface KnowledgeConnectorStatusRequest { connector: "raindrop" | "x"; }
export interface KnowledgeConnectorRunRequest { commandId: string; connector: "raindrop" | "x"; dryRun: boolean; limit?: number; }
export interface KnowledgeImportDryRunRequest { commandId: string; source: string; limit?: number; }
export interface KnowledgeImportRunRequest { commandId: string; source: string; expectedPlanHash: string; limit?: number; }

export type KnowledgeAction =
  | { operation: "knowledge.status"; request: Record<string, never> }
  | { operation: "knowledge.config"; request: { commandId: string; config: KnowledgeConfig } }
  | { operation: "knowledge.list"; request: KnowledgeListRequest }
  | { operation: "knowledge.read"; request: { id: string; revisionId?: string; includeSuppressed?: boolean } }
  | { operation: "knowledge.search"; request: KnowledgeSearchRequest }
  | { operation: "knowledge.recall"; request: KnowledgeRecallRequest }
  | { operation: "knowledge.source.capture"; request: KnowledgeSourceCaptureRequest }
  | { operation: "knowledge.note.create"; request: KnowledgeNoteMutationRequest & { recordId?: never } }
  | { operation: "knowledge.note.update"; request: KnowledgeNoteMutationRequest & { recordId: string } }
  | { operation: "knowledge.reflect"; request: KnowledgeReflectRequest }
  | { operation: "knowledge.source.triage"; request: KnowledgeTriageRequest }
  | { operation: "knowledge.correction"; request: KnowledgeCorrectionRequest }
  | { operation: "knowledge.forget"; request: KnowledgeForgetRequest }
  | { operation: "knowledge.exclusion"; request: KnowledgeExclusionRequest }
  | { operation: "knowledge.connector.configure"; request: KnowledgeConnectorConfigurationRequest }
  | { operation: "knowledge.connector.status"; request: KnowledgeConnectorStatusRequest }
  | { operation: "knowledge.connector.run"; request: KnowledgeConnectorRunRequest }
  | { operation: "knowledge.import.dry-run"; request: KnowledgeImportDryRunRequest }
  | { operation: "knowledge.import.run"; request: KnowledgeImportRunRequest };

const ID = /^[A-Za-z0-9._:-]{1,200}$/;
const REVISION = /^[0-9a-f-]{16,80}$/;
const HASH = /^[a-f0-9]{64}$/;

export function assertKnowledgeId(value: unknown, label = "knowledge id"): asserts value is string {
  if (typeof value !== "string" || !ID.test(value) || value === "." || value === "..") throw new Error(`Invalid ${label}`);
}

function assertTimestamp(value: unknown, label: string): asserts value is string {
  if (typeof value !== "string" || !isGatewayTimestamp(value)) throw new Error(`Invalid ${label}`);
}

function boundedString(value: unknown, label: string, maximum: number): asserts value is string {
  if (typeof value !== "string" || value.length === 0 || value.length > maximum) throw new Error(`Invalid ${label}`);
}

function isJsonValue(value: unknown, depth = 0): value is JsonValue {
  if (depth > 8 || value === null || typeof value === "string" || typeof value === "boolean" || typeof value === "number") return value === null || typeof value !== "number" || Number.isFinite(value);
  if (Array.isArray(value)) return value.length <= 100 && value.every(item => isJsonValue(item, depth + 1));
  if (typeof value !== "object") return false;
  return Object.keys(value).length <= 100 && Object.values(value).every(item => isJsonValue(item, depth + 1));
}

function assertEvidence(value: unknown): asserts value is KnowledgeEvidenceRef {
  if (!value || typeof value !== "object" || Array.isArray(value)) throw new Error("Invalid evidence reference");
  const item = value as Record<string, unknown>;
  if (item.recordId === undefined && item.sessionEntry === undefined) throw new Error("Evidence must cite a record or session entry");
  if (item.recordId !== undefined) assertKnowledgeId(item.recordId, "evidence record id");
  if (item.revisionId !== undefined && item.recordId === undefined) throw new Error("Evidence revision requires a record citation");
  if (item.revisionId !== undefined && (typeof item.revisionId !== "string" || !REVISION.test(item.revisionId))) throw new Error("Invalid evidence revision");
  if (item.sessionEntry !== undefined) {
    const entry = item.sessionEntry as Record<string, unknown>;
    assertKnowledgeId(entry.sessionId, "evidence session id");
    assertKnowledgeId(entry.entryId, "evidence entry id");
    if (entry.branchId !== undefined) assertKnowledgeId(entry.branchId, "evidence branch id");
    if (entry.digest !== undefined && (typeof entry.digest !== "string" || !HASH.test(entry.digest))) throw new Error("Invalid evidence entry digest");
    for (const key of ["startOffset", "endOffset"]) if (entry[key] !== undefined && (!Number.isSafeInteger(entry[key]) || (entry[key] as number) < 0)) throw new Error("Invalid evidence entry span");
  }
  if (item.objectHash !== undefined && (typeof item.objectHash !== "string" || !HASH.test(item.objectHash))) throw new Error("Invalid evidence object hash");
  if (item.locator !== undefined && (typeof item.locator !== "string" || item.locator.length > 512)) throw new Error("Invalid evidence locator");
}

export function validateKnowledgeRecord(value: unknown): KnowledgeRecord {
  if (!value || typeof value !== "object" || Array.isArray(value)) throw new Error("Invalid knowledge record");
  const item = value as Record<string, unknown>;
  if (item.schemaVersion !== KNOWLEDGE_SCHEMA_VERSION) throw new Error("Unsupported knowledge record schema");
  assertKnowledgeId(item.id);
  if (typeof item.revisionId !== "string" || !REVISION.test(item.revisionId)) throw new Error("Invalid knowledge revision");
  if (item.kind !== "source" && item.kind !== "observation" && item.kind !== "note") throw new Error("Invalid knowledge kind");
  if (item.scope !== "personal" && item.scope !== "research") throw new Error("Invalid knowledge scope");
  assertTimestamp(item.createdAt, "createdAt");
  assertTimestamp(item.updatedAt, "updatedAt");
  const provenance = item.provenance as Record<string, unknown>;
  if (!provenance || typeof provenance !== "object" || Array.isArray(provenance)) throw new Error("Invalid provenance");
  if (!["user", "agent", "connector", "import", "system"].includes(provenance.actor as string)) throw new Error("Invalid provenance actor");
  if (!Array.isArray(provenance.evidence)) throw new Error("Invalid provenance evidence");
  provenance.evidence.forEach(assertEvidence);
  if (!Array.isArray(item.relations)) throw new Error("Invalid relations");
  for (const relation of item.relations) {
    if (!relation || typeof relation !== "object" || !["supports", "contradicts", "corrects", "supersedes", "derivedFrom", "related"].includes((relation as Record<string, unknown>).type as string)) throw new Error("Invalid relation");
    assertKnowledgeId((relation as Record<string, unknown>).recordId, "relation record id");
  }
  const temporal = item.temporal;
  if (temporal !== undefined) {
    if (!temporal || typeof temporal !== "object" || Array.isArray(temporal)) throw new Error("Invalid temporal qualification");
    for (const key of ["eventAt", "validFrom", "validTo", "reviewDue"]) if ((temporal as Record<string, unknown>)[key] !== undefined) assertTimestamp((temporal as Record<string, unknown>)[key], `temporal ${key}`);
  }
  validateKindContent(item.kind, item.content);
  return value as KnowledgeRecord;
}

function validateKindContent(kind: KnowledgeRecordKind, value: unknown): void {
  if (!value || typeof value !== "object" || Array.isArray(value)) throw new Error("Invalid knowledge content");
  const content = value as Record<string, unknown>;
  if (kind === "source") {
    if (typeof content.title !== "string" || content.title.length > 512) throw new Error("Invalid source title");
    if (content.text !== undefined && (typeof content.text !== "string" || content.text.length > 2_000_000)) throw new Error("Invalid source text");
    if (content.uri !== undefined) {
      boundedString(content.uri, "source uri", 4_096);
      try { const uri = new URL(content.uri); if (!["http:", "https:"].includes(uri.protocol) || uri.username || uri.password) throw new Error(); } catch { throw new Error("Source URI must be an http(s) URL without credentials"); }
    }
    if (!["complete", "partial", "metadata-only", "inaccessible", "failed", "reference-only"].includes(content.captureDisposition as string)) throw new Error("Invalid capture disposition");
    if (content.origin !== undefined && !["manual", "connector", "import", "conversation"].includes(content.origin as string)) throw new Error("Invalid source origin");
    assertTimestamp(content.capturedAt, "capturedAt");
    if (content.sourcePublishedAt !== undefined) assertTimestamp(content.sourcePublishedAt, "sourcePublishedAt");
    if (content.mediaType !== undefined) boundedString(content.mediaType, "source media type", 160);
    if (content.identity !== undefined) {
      const identity = content.identity as Record<string, unknown>;
      if (!identity || typeof identity !== "object" || Array.isArray(identity)) throw new Error("Invalid source identity");
      boundedString(identity.provider, "source identity provider", 160);
      boundedString(identity.accountId, "source identity account", 256);
      boundedString(identity.itemId, "source identity item", 512);
    }
    if (content.origins !== undefined) {
      if (!Array.isArray(content.origins) || content.origins.length > 20) throw new Error("Invalid source origins");
      for (const origin of content.origins) {
        const item = origin as Record<string, unknown>;
        if (!item || typeof item !== "object" || !["manual", "connector", "import", "conversation"].includes(item.kind as string)) throw new Error("Invalid source origin kind");
        assertTimestamp(item.capturedAt, "source origin capturedAt");
        if (item.uri !== undefined) { boundedString(item.uri, "source origin uri", 4_096); try { const uri = new URL(item.uri); if (!["http:", "https:"].includes(uri.protocol) || uri.username || uri.password) throw new Error(); } catch { throw new Error("Source origin URI must be an http(s) URL without credentials"); } }
        if (item.identity !== undefined) { const identity = item.identity as Record<string, unknown>; boundedString(identity.provider, "source origin provider", 160); boundedString(identity.accountId, "source origin account", 256); boundedString(identity.itemId, "source origin item", 512); }
        if (item.annotation !== undefined) boundedString(item.annotation, "source origin annotation", 2_000);
      }
    }
    if (content.assessment !== undefined) {
      const assessment = content.assessment as Record<string, unknown>;
      if (!assessment || typeof assessment !== "object" || Array.isArray(assessment)) throw new Error("Invalid source assessment");
      boundedString(assessment.summary, "source assessment summary", 20_000);
      for (const key of ["contribution", "whyItMatters", "possibleUse"]) if (assessment[key] !== undefined) boundedString(assessment[key], `source assessment ${key}`, 10_000);
      if (!["high", "medium", "low", "none"].includes(assessment.evidenceQuality as string) || !["current", "aging", "stale", "unknown"].includes(assessment.freshness as string)) throw new Error("Invalid source assessment quality");
      assertTimestamp(assessment.generatedAt, "source assessment generatedAt");
      if (assessment.model !== undefined) boundedString(assessment.model, "source assessment model", 200);
    }
    if (content.annotations !== undefined) {
      if (!Array.isArray(content.annotations) || content.annotations.length > 200) throw new Error("Invalid source annotations");
      for (const annotation of content.annotations) { const item = annotation as Record<string, unknown>; boundedString(item.text, "annotation", 20_000); if (item.locator !== undefined) boundedString(item.locator, "annotation locator", 512); if (item.createdAt !== undefined) assertTimestamp(item.createdAt, "annotation createdAt"); }
    }
    if (content.object !== undefined) validateObjectRef(content.object);
  } else if (kind === "observation") {
    const range = content.range as Record<string, unknown>;
    if (!range || typeof range !== "object" || Array.isArray(range)) throw new Error("Invalid observation range");
    for (const key of ["sessionId", "fromEntryId", "toEntryId"]) assertKnowledgeId(range[key], `observation ${key}`);
    if (range.branchId !== undefined) assertKnowledgeId(range.branchId, "observation branchId");
    if (!Array.isArray(range.entryIds) || range.entryIds.length < 1 || range.entryIds.length > 10_000) throw new Error("Invalid observation entry ids");
    range.entryIds.forEach(entry => assertKnowledgeId(entry, "observation entry id"));
    if (range.entryIds[0] !== range.fromEntryId || range.entryIds.at(-1) !== range.toEntryId || typeof range.entryDigest !== "string" || !HASH.test(range.entryDigest)) throw new Error("Observation range does not identify its canonical input");
    if (!Array.isArray(content.items) || content.items.length > 200) throw new Error("Invalid observation items");
    for (const observation of content.items) {
      const item = observation as Record<string, unknown>;
      if (!item || typeof item.text !== "string" || item.text.length > 20_000 || !["user", "assistant", "tool", "system", "unknown"].includes(item.attribution as string) || !["certain", "qualified", "uncertain"].includes(item.certainty as string)) throw new Error("Invalid observation item");
      assertTimestamp(item.observedAt, "observedAt");
      if (item.evidence !== undefined) { if (!Array.isArray(item.evidence)) throw new Error("Invalid observation evidence"); item.evidence.forEach(assertEvidence); }
    }
  } else {
    if (typeof content.title !== "string" || content.title.length > 512 || !["fact", "preference", "concept", "decision", "workflow", "synthesis"].includes(content.role as string) || typeof content.confirmed !== "boolean") throw new Error("Invalid note content");
    if (content.body !== undefined && (typeof content.body !== "string" || content.body.length > 100_000)) throw new Error("Invalid note body");
    if (content.contraryEvidence !== undefined) { if (!Array.isArray(content.contraryEvidence) || content.contraryEvidence.length > 100) throw new Error("Invalid contrary evidence"); content.contraryEvidence.forEach(assertEvidence); }
    if (content.freshness !== undefined && !["current", "aging", "stale", "unknown"].includes(content.freshness as string)) throw new Error("Invalid note freshness");
    if (content.privacyScope !== undefined && !["private", "shared"].includes(content.privacyScope as string)) throw new Error("Invalid note privacy scope");
    if (content.fields !== undefined) {
      if (!Array.isArray(content.fields) || content.fields.length > 100) throw new Error("Invalid note fields");
      for (const field of content.fields) {
        const item = field as Record<string, unknown>;
        boundedString(item.field, "note field", 200);
        if (!isJsonValue(item.value)) throw new Error("Invalid note field value");
        if (item.subject !== undefined) boundedString(item.subject, "note subject", 200);
        if (!Array.isArray(item.evidence)) throw new Error("Invalid note field evidence");
        item.evidence.forEach(assertEvidence);
        if (!["confirmed", "candidate", "external", "historical"].includes(item.certainty as string)) throw new Error("Invalid note field certainty");
        if (item.validFrom !== undefined) assertTimestamp(item.validFrom, "note validFrom");
        if (item.validTo !== undefined) assertTimestamp(item.validTo, "note validTo");
      }
    }
  }
}

export function validateObjectRef(value: unknown): asserts value is KnowledgeObjectRef {
  if (!value || typeof value !== "object" || Array.isArray(value)) throw new Error("Invalid object reference");
  const object = value as Record<string, unknown>;
  if (typeof object.hash !== "string" || !HASH.test(object.hash) || typeof object.mediaType !== "string" || object.mediaType.length > 160 || typeof object.bytes !== "number" || !Number.isSafeInteger(object.bytes) || object.bytes < 0 || object.bytes > 8_000_000) throw new Error("Invalid object reference");
}

export function validateKnowledgeConfig(value: unknown): KnowledgeConfig {
  if (!value || typeof value !== "object" || Array.isArray(value)) throw new Error("Invalid knowledge configuration");
  const config = value as Record<string, unknown>;
  const observation = config.observation as Record<string, unknown>;
  const maxInputChars = observation?.maxInputChars;
  const maxOutputChars = observation?.maxOutputChars;
  const timeoutMs = observation?.timeoutMs;
  const maxAttempts = observation?.maxAttempts;
  const maximumSearchResults = config.maximumSearchResults;
  const eligibility = config.eligibility as Record<string, unknown>;
  if (config.schemaVersion !== KNOWLEDGE_SCHEMA_VERSION || typeof config.revision !== "number" || !Number.isSafeInteger(config.revision) || config.revision < 0 || !eligibility || typeof eligibility !== "object" || !Array.isArray(eligibility.sessionIds) || !Array.isArray(eligibility.projectIds) || !Array.isArray(eligibility.excludedSessionIds) || !Array.isArray(eligibility.excludedProjectIds) || ![...eligibility.sessionIds, ...eligibility.projectIds, ...eligibility.excludedSessionIds, ...eligibility.excludedProjectIds].every(item => typeof item === "string" && ID.test(item)) || !observation || typeof observation !== "object" || typeof observation.enabled !== "boolean" || typeof maxInputChars !== "number" || !Number.isSafeInteger(maxInputChars) || maxInputChars < 1_000 || maxInputChars > 200_000 || typeof maxOutputChars !== "number" || !Number.isSafeInteger(maxOutputChars) || maxOutputChars < 100 || maxOutputChars > 50_000 || typeof timeoutMs !== "number" || !Number.isSafeInteger(timeoutMs) || timeoutMs < 1_000 || timeoutMs > 300_000 || typeof maxAttempts !== "number" || !Number.isSafeInteger(maxAttempts) || maxAttempts < 1 || maxAttempts > 3 || typeof maximumSearchResults !== "number" || !Number.isSafeInteger(maximumSearchResults) || maximumSearchResults < 1 || maximumSearchResults > 100) throw new Error("Invalid knowledge configuration");
  if (observation.model !== undefined && (typeof observation.model !== "string" || observation.model.length === 0 || observation.model.length > 200)) throw new Error("Invalid observation model");
  if (config.currentInterests !== undefined && (!Array.isArray(config.currentInterests) || config.currentInterests.length > 50 || !config.currentInterests.every(item => typeof item === "string" && item.length > 0 && item.length <= 500))) throw new Error("Invalid current interests");
  return value as KnowledgeConfig;
}
