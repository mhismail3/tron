import type { JsonValue } from "../protocol/types.js";
import { isGatewayTimestamp } from "../util/timestamp.js";

export const KNOWLEDGE_SCHEMA_VERSION = 1 as const;

/** Exact credential query-parameter names refused wherever a source URL is
 * admitted or persisted. Exact matching keeps ordinary keys such as `author`
 * valid, including in already-stored records; X post URLs apply a broader
 * substring rule in `xPostIdentity`. */
export function isCredentialQueryKey(key: string): boolean {
  return /^(?:token|api[_-]?key|key|secret|password|passwd|auth|signature|sig|access[_-]?token|credential|session)$/i.test(key);
}

export function normalizeKnowledgeSourceUrl(value: string): string {
  const url = new URL(value); url.hash = ""; url.hostname = url.hostname.toLowerCase();
  if ((url.protocol === "https:" && url.port === "443") || (url.protocol === "http:" && url.port === "80")) url.port = "";
  return url.toString();
}
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
export type SourceAdmission = "pending" | "retained" | "archived";
export type KnowledgeCaptureDisposition = "complete" | "partial" | "metadata-only" | "inaccessible" | "failed" | "reference-only";

export interface SourceAssessmentUsage {
  inputTokens: number;
  outputTokens: number;
  estimatedCostCents: number;
  pricing: "typesafe-jev-1.13.0-input-0.042-usd-per-million-output-free";
}

export interface SourceAssessment {
  summary: string;
  contribution?: string;
  whyItMatters?: string;
  evidenceQuality: "high" | "medium" | "low" | "none" | "unknown";
  freshness: "current" | "aging" | "stale" | "unknown";
  possibleUse?: string;
  generatedAt: string;
  model?: string;
  recommendation?: SourceAdmission;
  confidence?: number;
  profileVersion?: string;
  rubricVersion?: string;
  /** Digest of the complete captured evidence and interests for this assessment. */
  inputDigest?: string;
  /** Digest of the exact title/text evidence attached to this derivative. */
  evidenceDigest?: string;
  /** Digest of the exact bounded state actually supplied to the model. */
  assessmentInputDigest?: string;
  /** Full evidence was evaluated, or a bounded excerpt was evaluated. */
  coverage?: "full" | "sampled";
  /** Bounded useful-category classification; not an evidence-quality claim. */
  classification?: string;
  /** Provider-reported usage and a local published-price estimate. Absent on legacy assessments. */
  usage?: SourceAssessmentUsage;
}

export interface SourceAdmissionState {
  status: SourceAdmission;
  reason?: string;
  decidedAt: string;
  profileVersion?: string;
  rubricVersion?: string;
}

export interface SourceRepresentation {
  kind: "provider-api" | "linked-article";
  object: KnowledgeObjectRef;
  mediaType?: string;
}

/** Who produced one interpretation. `model` is a caller-supplied label; it is
 * not attestation that a model actually ran. */
export interface SourceCurationProducer {
  actor: "user" | "agent" | "connector" | "import" | "system";
  model?: string;
}

export interface SourceSummary {
  text: string;
  generatedAt: string;
  sourceRevisionId: string;
  /** SHA-256 of this record's `{title, text}`; see `sourceEvidenceDigest`. */
  evidenceDigest: string;
  coverage: "full" | "sampled";
  producer: SourceCurationProducer;
}

/** Vocabulary tag selection. The vocabulary itself belongs to Knowledge
 * configuration; this only records which of its tags were chosen, by whom, and
 * against which inputs. */
export interface SourceTagSelection {
  tagIds: string[];
  /** Vocabulary edition the IDs were validated against. */
  vocabularyRevision: number;
  /** SHA-256 of the record's own taggable inputs at publication; see
   * `curationInputsDigest`. */
  inputsDigest: string;
  assignedAt: string;
  producer: SourceCurationProducer;
}

/** How useful an entry still is. A judgement, never capture evidence. */
export type SourceVerdict = "evergreen" | "dated" | "superseded" | "archive";

export interface SourceTake {
  /** One user-owned, confirmed note. Each replacement is a new record revision. */
  text: string;
  confirmed: true;
  producer: { actor: "user" };
  updatedAt: string;
}

export interface SourceVerdictState {
  verdict: SourceVerdict;
  /** Required for `superseded`: the entry that replaces this one. */
  supersededBy?: string;
  reason?: string;
  decidedAt: string;
  producer: SourceCurationProducer;
}

export interface SourceContent {
  title: string;
  uri?: string;
  /** Provider collection at capture time; provenance, not an admission authority. */
  collectionId?: string;
  /** Readable extraction, not a substitute for the original object. */
  text?: string;
  /** Immutable original bytes, when captured. */
  object?: KnowledgeObjectRef;
  /** Optional bounded OpenGraph/provider preview image; never required for capture. */
  preview?: KnowledgeObjectRef;
  /** Additional retained representations never replace the captured object. */
  representations?: SourceRepresentation[];
  mediaType?: string;
  captureDisposition: KnowledgeCaptureDisposition;
  /** Sanitized capture phase/reason for recoverable provider or safety failures. */
  captureReason?: string;
  /** Bounded provider-declared outbound targets; target sources are separate records. */
  linkedUrls?: string[];
  annotations?: Array<{ text: string; locator?: string; createdAt?: string }>;
  sourcePublishedAt?: string;
  /** Time the originating save service recorded this item, distinct from Tron capture. */
  sourceSavedAt?: string;
  capturedAt: string;
  origin?: SourceOriginKind;
  origins?: SourceOrigin[];
  identity?: SourceIdentity;
  /** Retention and sensitivity are distinct from capture completeness. */
  retention?: { sensitivity: "public" | "restricted" | "private"; usageConstraint?: string; evidenceAvailable: boolean; originalHash?: string };
  /** Intake lifecycle is separate from privacy/suppression and remains recoverable. */
  admission?: SourceAdmissionState;
  assessment?: SourceAssessment;
  /** Explicitly generated content summary, separate from the intake assessment. */
  summary?: SourceSummary;
  /** One editable user-owned note; revisions preserve its history. */
  take?: SourceTake;
  /** Vocabulary tag selection; see `SourceTagSelection`. */
  tags?: SourceTagSelection;
  /** Usefulness verdict; see `SourceVerdictState`. */
  verdict?: SourceVerdictState;
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
  usageConstraint?: string;
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
  disposition: ObservationCoverageDisposition;
  groupRevisionIds: string[];
  recordedAt: string;
  reason?: string;
}

export interface KnowledgeEligibility {
  /** Explicit global grant. Absence retains selected-scope admission; an empty
   * allowlist must never silently become permission to observe every session. */
  allSessions?: true;
  sessionIds: string[];
  projectIds: string[];
  excludedSessionIds: string[];
  excludedProjectIds: string[];
}

/** Shared by inference admission and serialized publication. Scope exclusions
 * in the store remain an additional fence; global selection never overrides them. */
export function knowledgeScopeEligible(eligibility: KnowledgeEligibility, scope: { sessionId: string; projectId?: string }): boolean {
  if (eligibility.excludedSessionIds.includes(scope.sessionId)
    || (scope.projectId !== undefined && eligibility.excludedProjectIds.includes(scope.projectId))) return false;
  return eligibility.allSessions === true || eligibility.sessionIds.includes(scope.sessionId)
    || (scope.projectId !== undefined && eligibility.projectIds.includes(scope.projectId));
}

export type KnowledgeTagDecayClass = "ages" | "stable";
export type KnowledgeTagState = "active" | "retired" | "merged";
export interface KnowledgeTagDefinition {
  id: string;
  label: string;
  definition: string;
  category: string;
  decayClass: KnowledgeTagDecayClass;
  state: KnowledgeTagState;
  mergedInto?: string;
}
export interface KnowledgeTagVocabularyConfig {
  /** Advances only when taxonomy or guidelines change, not unrelated settings. */
  revision: number;
  tags: KnowledgeTagDefinition[];
  guidelines: string;
}
export type KnowledgeTagEdit =
  | { kind: "add"; tag: KnowledgeTagDefinition }
  | { kind: "rename"; id: string; label: string }
  | { kind: "redefine"; id: string; definition: string }
  | { kind: "recategorize"; id: string; category: string; decayClass: KnowledgeTagDecayClass }
  | { kind: "retire"; id: string }
  | { kind: "merge"; id: string; mergedInto: string }
  | { kind: "guidelines"; guidelines: string };
export interface KnowledgeTagEditRequest {
  commandId: string;
  expectedConfigRevision: number;
  edit: KnowledgeTagEdit;
}
export interface KnowledgeTagReconcileRequest {
  commandId: string;
  expectedConfigRevision: number;
  cursor?: string;
  limit?: number;
}
export interface KnowledgeTagRetagRequest {
  vocabularyRevision: number;
  cursor?: string;
  limit?: number;
}
export interface KnowledgeTagRetagItem { id: string; revisionId: string; reason: "untagged" | "vocabulary-changed" | "retired-tag" | "stale-inputs"; }
export interface KnowledgeTagRetagResponse { items: KnowledgeTagRetagItem[]; nextCursor?: string; vocabularyRevision: number; }
export interface KnowledgeTagReconcileResponse { applied: number; unchanged: number; outcomes: Array<{ id: string; status: "applied" | "unchanged" | "conflict" | "failed"; revisionId?: string; reason?: string }>; nextCursor?: string; configRevision: number; }
export const KNOWLEDGE_TAG_MAX_COUNT = 256;
export const KNOWLEDGE_TAG_MAX_GUIDELINES_CHARS = 8_000;

/** Resolve just the configured age policy for K6 without coupling retrieval to
 * vocabulary mutation or duplicating taxonomy lookups. */
export function knowledgeTagDecayClass(config: KnowledgeConfig, tagId: string): KnowledgeTagDecayClass | undefined {
  const tag = config.tagVocabulary.tags.find(candidate => candidate.id === tagId);
  return tag?.decayClass;
}

export interface KnowledgeConfig {
  schemaVersion: typeof KNOWLEDGE_SCHEMA_VERSION;
  /** Monotonically increasing revision for optimistic UI/runtime updates. */
  revision: number;
  eligibility: KnowledgeEligibility;
  /** Provider used only for saved-source summaries; never inherits observation.model. */
  enrichment?: { model?: string };
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
  /** User-owned taxonomy. Added to older persisted configurations as empty. */
  tagVocabulary: KnowledgeTagVocabularyConfig;
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
  tagVocabulary: { revision: 0, tags: [], guidelines: "" },
};

/** Every disposition an observation cut can hold. `observed`, `empty`, and
 * `excluded` are terminal; the remaining three still need retry, user action, or
 * evidence recovery, and are what a client asks for when it lists cuts that
 * need attention rather than scanning a mostly settled ledger. */
export type ObservationCoverageDisposition = "observed" | "empty" | "excluded" | "pending" | "failed" | "unavailable";
export const OBSERVATION_COVERAGE_DISPOSITIONS: readonly ObservationCoverageDisposition[] = ["observed", "empty", "excluded", "pending", "failed", "unavailable"];
export const OBSERVATION_ATTENTION_DISPOSITIONS: readonly ObservationCoverageDisposition[] = ["pending", "failed", "unavailable"];

export interface KnowledgeCoverageSummary {
  observedCount: number;
  emptyCount: number;
  excludedCount: number;
  pendingCount: number;
  failedCount: number;
  unavailableCount: number;
  /** Cuts that need a retry, user action, or canonical evidence recovery. */
  remainingCount: number;
}

export interface KnowledgeCoveragePage {
  coverage: ObservationCoverage[];
  stateRevision: number;
  nextCursor?: string;
}

export interface KnowledgeStatus {
  available: boolean;
  state: "uninitialized" | "ready" | "unsafe" | "invalid" | "newer" | "closed";
  stateRevision?: number;
  recordCount: number;
  coverageCount: number;
  coverage: KnowledgeCoverageSummary;
  suppressedCount: number;
  pendingCleanupCount: number;
  config: KnowledgeConfig;
  observationConfigured: boolean;
  detail?: string;
}

export interface KnowledgeCoverageRequest {
  cursor?: string;
  limit?: number;
  /** Narrows the page to these dispositions. A client that lists cuts needing
   * attention asks for `pending`, `failed`, and `unavailable` instead of
   * scanning the whole ledger, which is mostly settled cuts. */
  dispositions?: ObservationCoverageDisposition[];
}

export interface KnowledgeListRequest {
  kind?: KnowledgeRecordKind;
  scope?: KnowledgeScope;
  includeSuppressed?: boolean;
  includeArchived?: boolean;
  /** Explicit intake/audit visibility for connector sources awaiting admission. */
  includePending?: boolean;
  /** Optional server-side partition for source catalogue projections. */
  sourceAdmission?: SourceAdmission;
  cursor?: string;
  limit?: number;
  /** Library row projection: bounded presentation fields instead of full
   * records. Valid only with `kind: "source"`. */
  projection?: "sourceRow";
  /** Exact row identities for a targeted refresh; row projection only. */
  ids?: string[];
}

/** One library row. Source text and raw bytes are never part of a page: they
 * stay behind an exact `knowledge.read`/`knowledge.object.read`. */
export type SourceFreshness = "fresh" | "aging" | "stale" | "unknown";
export type SourceAgeBasis = "sourceSavedAt" | "capturedAt";

export interface KnowledgeSourceRow {
  id: string;
  revisionId: string;
  scope: KnowledgeScope;
  createdAt: string;
  updatedAt: string;
  title: string;
  /** Canonical captured URI. */
  uri?: string;
  /** User-facing original link: the requested URI recorded for this exact
   * saved-item identity in origin provenance, else the canonical URI. */
  originalUri?: string;
  mediaType?: string;
  captureDisposition: KnowledgeCaptureDisposition;
  admission?: SourceAdmission;
  sourceSavedAt?: string;
  ageBasis: SourceAgeBasis;
  ageDays: number;
  freshness: SourceFreshness;
  verdict?: SourceVerdict;
  supersededBy?: string;
  hasTake: boolean;
  tagsStale: boolean;
  /** Never present for connector providers whose legacy save time was once
   * misfiled as publication time. */
  sourcePublishedAt?: string;
  preview?: KnowledgeObjectRef;
  /** Generated summary text, present only while its evidence digest still
   * matches the record's title and readable text. Bounded for row display. */
  summary?: string;
  /** Current vocabulary labels projected from the catalog head, never the body. */
  tags?: Array<Pick<KnowledgeTagDefinition, "id" | "label" | "category" | "decayClass" | "state">>;
}

export interface KnowledgeListResponse {
  records: KnowledgeRecord[];
  nextCursor?: string;
  stateRevision: number;
  incomplete?: boolean;
}

/** `knowledge.list` with `projection: "sourceRow"`. */
export interface KnowledgeSourceRowListResponse {
  rows: KnowledgeSourceRow[];
  nextCursor?: string;
  stateRevision: number;
}

/** `knowledge.search` with `projection: "sourceRow"`. */
export interface KnowledgeSourceRowSearchResponse {
  rows: KnowledgeSourceRow[];
  nextCursor?: string;
  stateRevision: number;
}

export interface KnowledgeSearchRequest {
  query: string;
  kind?: KnowledgeRecordKind;
  scope?: KnowledgeScope;
  /** Agent retrieval may hide personal sources without hiding personal notes or observations. */
  excludePersonalSources?: boolean;
  includeArchived?: boolean;
  includePending?: boolean;
  /** Optional server-side partition for source search projections. */
  sourceAdmission?: SourceAdmission;
  limit?: number;
  /** Library row projection; see `KnowledgeListRequest.projection`. */
  projection?: "sourceRow";
  cursor?: string;
}

export interface KnowledgeSearchHit {
  record: KnowledgeRecord;
  score: number;
  matchedFields: string[];
}

export interface KnowledgeSearchResponse {
  hits: KnowledgeSearchHit[];
  nextCursor?: string;
  stateRevision: number;
  indexState: "canonical";
  incomplete?: boolean;
}

export interface KnowledgeRecallRequest {
  query?: string;
  sessionId?: string;
  entryId?: string;
  scope?: KnowledgeScope;
  /** Agent retrieval may hide personal sources without hiding personal notes or observations. */
  excludePersonalSources?: boolean;
  includeArchived?: boolean;
  includePending?: boolean;
  limit?: number;
}

export interface KnowledgeSourceTakeRequest {
  commandId: string;
  recordId: string;
  expectedRevision: string;
  /** Empty explicitly clears Your take. */
  text: string;
}

export interface KnowledgeRecallResponse {
  records: KnowledgeRecord[];
  citations: KnowledgeEvidenceRef[];
  stateRevision: number;
  availability: "available" | "no-match";
  incomplete?: boolean;
}

/** URL capture is fetched by the Gateway source owner; callers never submit
 * fetched text as if it were canonical evidence. */
export interface KnowledgeSourceURLCaptureRequest {
  commandId: string;
  url: string;
  scope: KnowledgeScope;
  title?: string;
  /** Disclose this public X post ID to the free public lookup providers. */
  publicPostLookup?: boolean;
  /** Explicit bounded thread/conversation refresh; root reuse never short-circuits it. */
  publicPostCoverage?: "root" | "conversation" | "thread";
  annotations?: SourceContent["annotations"];
  identity?: SourceIdentity;
  origin?: SourceOriginKind;
  expectedRevision?: string;
}

/** Transport callers may request only URL capture. Record writes are owned by
 * source/import implementations and are not part of the Gateway action. */
export type KnowledgeSourceCaptureRequest = KnowledgeSourceURLCaptureRequest;

export interface KnowledgeSourcePreviewRefreshRequest {
  commandId: string;
  sourceId: string;
  expectedRevision: string;
}
export interface KnowledgeSourcePreviewRefreshResult {
  sourceId: string;
  expectedRevision: string;
  status: "updated" | "unchanged" | "no-image" | "unavailable";
  reason: string;
  record?: KnowledgeRecord;
}

export interface KnowledgeNoteMutationRequest {
  commandId: string;
  /** Set only by the trusted native explicit-confirmation owner. */
  confirmedByUser?: boolean;
  recordId?: string;
  expectedRevision?: string;
  record: KnowledgeRecordDraft & { kind: "note" };
}

export interface KnowledgeCorrectionRequest {
  commandId: string;
  /** Set only by the trusted native confirmation owner. */
  confirmedByUser?: boolean;
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

export interface KnowledgeSourceReextractRequest {
  commandId: string;
  sourceId: string;
  expectedRevision: string;
}

export interface KnowledgeSourceSummaryRequest {
  commandId: string;
  sourceId: string;
  expectedRevision: string;
}

export interface KnowledgeTriageRequest {
  commandId: string;
  sourceId: string;
  expectedRevision: string;
}

export interface KnowledgeSourceAdmissionRequest {
  commandId: string;
  recordId: string;
  expectedRevision: string;
  status: SourceAdmission;
  reason?: string;
}

/** One bounded batch of interpretation writes. Every item carries its own
 * expected revision; the owner derives each item's evidence binding itself and
 * never accepts a caller-supplied digest or revision binding. */
export type KnowledgeCurationOperation = "summary" | "tags" | "verdict" | "placement" | "relation";

/** Typed, actionable refusal of one curation item. It never aborts the batch;
 * the caller records the code and continues with the next item. */
export type KnowledgeCurationCode =
  | "stale-revision"
  | "stale-vocabulary"
  | "unknown-record"
  | "excluded"
  | "forgotten"
  | "invalid-input"
  | "unknown-tag"
  | "command-id-reuse"
  | "budget-exhausted"
  | "model-not-configured"
  | "unavailable"
  | "cancelled";

export class KnowledgeCurationRefusal extends Error {
  constructor(readonly code: KnowledgeCurationCode, message: string, readonly currentRevision?: string) {
    super(message);
    this.name = "KnowledgeCurationRefusal";
  }
}

export const KNOWLEDGE_CURATION_MAX_ITEMS = 25;
export const KNOWLEDGE_CURATION_MAX_TAGS = 24;
/** One summary, matching the generation bound. */
export const KNOWLEDGE_CURATION_MAX_SUMMARY_CHARS = 8_000;
/** A batch's combined summary text, so one response stays bounded. */
export const KNOWLEDGE_CURATION_MAX_BATCH_SUMMARY_CHARS = 32_000;

export interface KnowledgeCurationItem {
  recordId: string;
  expectedRevision: string;
  /** `summary` only: text the caller produced. */
  summary?: { text: string; coverage: "full" | "sampled" };
  /** `tags` only. */
  tagIds?: string[];
  /** Optional tager fence: rejects publication if the taxonomy edition changed while Jev ran. */
  vocabularyRevision?: number;
  /** `verdict` only. */
  verdict?: { verdict: SourceVerdict; supersededBy?: string; reason?: string };
  /** `placement` only; at least one of scope or admission. */
  placement?: { scope?: KnowledgeScope; admission?: SourceAdmission; reason?: string };
  /** `relation` only. */
  relation?: { type: KnowledgeRelation["type"]; recordId: string; action: "add" | "remove" };
}

export interface KnowledgeCurationRequest {
  commandId: string;
  operation: KnowledgeCurationOperation;
  producer: SourceCurationProducer;
  items: KnowledgeCurationItem[];
}

/** What one curation item wrote, read back from its committed revision. */
export interface KnowledgeCurationStored {
  summary?: { text: string; coverage: "full" | "sampled"; sourceRevisionId: string };
  tagIds?: string[];
  vocabularyRevision?: number;
  verdict?: SourceVerdict;
  supersededBy?: string;
  scope?: KnowledgeScope;
  admission?: SourceAdmission;
  relations?: string[];
}

export interface KnowledgeCurationOutcome {
  recordId: string;
  status: "applied" | "unchanged" | "conflict" | "failed" | "skipped";
  /** The revision this item wrote, or the unchanged committed one. */
  revisionId?: string;
  /** Present on `conflict`: the committed revision to re-read before retrying. */
  currentRevision?: string;
  code?: KnowledgeCurationCode;
  reason?: string;
  stored?: KnowledgeCurationStored;
}

export interface KnowledgeCurationResponse {
  commandId: string;
  operation: KnowledgeCurationOperation;
  applied: number;
  outcomes: KnowledgeCurationOutcome[];
  stateRevision: number;
}

/** Owned background interpretation work. State is process-local; the durable
 * outcome is the committed revision, so a restart loses only `running`. */
export interface KnowledgeCurationJob {
  commandId: string;
  operation: "summary" | "tags";
  sourceId: string;
  status: "running" | "done" | "failed";
  startedAt: string;
  finishedAt?: string;
  revisionId?: string;
  code?: KnowledgeCurationCode;
  reason?: string;
}

/** `connectionId` names the Jev connection that pays; when omitted the single
 * enabled, approved Jev connection is used, and none or several is refused. */
export interface KnowledgeTagRequest { commandId: string; sourceId: string; expectedRevision: string; connectionId?: string; }
export interface KnowledgeTagRunRequest { commandId: string; connectionId: string; limit?: number; }
export interface KnowledgeTagBudgetRequest { connectionId: string; }
export interface KnowledgeTagBudgetReconcileRequest { connectionId: string; attemptId: string; }
export interface KnowledgeTagCostEstimateRequest { connectionId: string; limit?: number; }

export interface KnowledgeCurationJobRequest {
  commandId?: string;
  sourceId?: string;
  status?: KnowledgeCurationJob["status"];
  limit?: number;
}

export interface KnowledgeCurationJobResponse {
  jobs: KnowledgeCurationJob[];
  running: number;
  failed: number;
}

/** Starting a summary replaces nothing: the job is accepted, this reply carries
 * its current state, and `knowledge.curation.jobs` reports later state. */
export interface KnowledgeSourceSummaryStart {
  job: KnowledgeCurationJob;
  record: KnowledgeRecord;
}

export interface KnowledgeRaindropIntakeRequest {
  commandId: string;
  connectionId?: string;
  dryRun: boolean;
  limit?: number;
  /** Explicit provider collection for this bounded intake; never persisted as a source default. */
  sourceCollection?: string;
  /** Existing approval identity. The first pilot is bounded to 10 items/$1. */
  pilot?: { id: string; maxItems: number; budgetCents: number };
}

/** Owner operation for a later, explicitly renewed assessment cohort. It never
 * changes an earlier cohort or its paid-attempt receipts. */
export interface KnowledgeAssessmentApprovalRequest {
  commandId: string;
  connectionId?: string;
  connector: "raindrop";
  id: string;
  maxItems: number;
  budgetCents: number;
  /** Mapped provider collection for the cohort; required when the connection maps several. */
  sourceCollection?: string;
  /** Explicit pending identities for renewed attempts; omitted selects only new work. */
  itemIds?: string[];
}

export interface KnowledgeConnectorConfigurationRequest {
  commandId: string;
  connector: "raindrop" | "x";
  /** Required once ConnectionOwner is active; identifies one account instance. */
  connectionId?: string;
  enabled: boolean;
  /** Stable provider account identifier; never a token. */
  accountId?: string;
  /** Provider-owned collection/user scope; never a token or URL with credentials. */
  scope?: string;
  /** Optional Raindrop destination collection. Writes remain disabled unless explicitly approved. */
  destination?: string;
  /** Opaque reference resolved only by the Mac-owned credential adapter. */
  credentialRef?: string;
  allowWrites?: boolean;
  paidAccessApproved?: boolean;
  /** Explicit maximum spend in cents; no connector currently spends when unset/zero. */
  paidBudgetCents?: number;
  recurringApproved?: boolean;
}

export interface KnowledgeConnectorStatusRequest { connector: "raindrop" | "x"; connectionId?: string; }
export interface KnowledgeConnectorRunRequest { commandId: string; connector: "raindrop" | "x"; connectionId?: string; dryRun: boolean; limit?: number; sourceCollection?: string; }

/** Read-only Raindrop API access. Every request revalidates the authenticated
 * user against the configured accountId; returned provider objects are raw
 * metadata and are never treated as captured article content. */
export type KnowledgeRaindropReadRequest =
  | { operation: "user" }
  | { operation: "collections"; children?: boolean }
  | { operation: "collection"; collectionId: string }
  | { operation: "bookmarks"; collectionId?: string; page?: number; perpage?: number; search?: string; sort?: string; nested?: boolean }
  | { operation: "item"; itemId: string }
  | { operation: "highlights"; page?: number; perpage?: number; collectionId?: string }
  | { operation: "tags" };

export interface KnowledgeRaindropRequest {
  commandId: string;
  connectionId?: string;
  read: KnowledgeRaindropReadRequest;
}

export interface KnowledgeTaggingLedger {
  month: string;
  spentCents: number;
  reservedCents: number;
  attempts: Record<string, { month: string; reservedCents: number; status: "reserved" | "settled" | "uncertain"; actualCostCents?: number; inputTokens?: number; outputTokens?: number }>;
}

export interface KnowledgeConnectorState {
  connector: "raindrop" | "x" | "jev";
  /** Adapter state key. Generic account authority remains ConnectionOwner. */
  connectionId?: string;
  enabled: boolean;
  accountId?: string;
  scope?: string;
  destination?: string;
  credentialRef?: string;
  allowWrites: boolean;
  paidAccessApproved: boolean;
  paidBudgetCents: number;
  recurringApproved: boolean;
  /** Per-provider-collection pagination checkpoints; never a complete remote snapshot. */
  checkpoints?: Record<string, string>;
  pending: Array<{ id: string; title: string; url: string; excerpt?: string; annotation?: string; publishedAt?: string; savedAt?: string; collectionId?: string; apiPayload?: string; metadataComplete?: boolean }>;
  capturedIds: string[];
  /** Last mapped collection observed for processed Raindrop item identities. */
  capturedCollections?: Record<string, string>;
  assessmentPilot?: { id: string; maxItems: number; budgetCents: number; usedItems: number; reservedCents: number; accountId: string; sourceCollection: string; profileVersion: string; itemIds: string[] };
  /** Initial intake cohorts are isolated by source collection. */
  assessmentPilots?: Record<string, { id: string; maxItems: number; budgetCents: number; usedItems: number; reservedCents: number; accountId: string; sourceCollection: string; profileVersion: string; itemIds: string[] }>;
  /** Append-only later cohorts. The first pilot remains frozen in assessmentPilot. */
  assessmentApprovals?: Array<{ id: string; maxItems: number; budgetCents: number; usedItems: number; reservedCents: number; accountId: string; sourceCollection: string; profileVersion: string; itemIds: string[] }>;
  /** Durable per-cohort/item paid-attempt fence; legacy item-only keys remain valid. */
  assessmentAttempts?: Record<string, { itemId?: string; cohortId?: string; status: "dispatched" | "settled"; chargeCents: number; inputTokens?: number; outputTokens?: number; estimatedCostCents?: number }>;
  /** Durable tagger dispatch reservations; uncertain attempts are never blindly retried. */
  taggingBudget?: KnowledgeTaggingLedger;
  health: "unconfigured" | "setup-required" | "ready" | "running" | "partial" | "rate-limited" | "auth-error" | "error";
  /** Adapter observations are bounded; unknown is the pre-admission state. */
  credentialAvailability?: "available" | "unavailable" | "unknown";
  providerIdentity?: "admitted" | "mismatch" | "unknown";
  lastRunAt?: string;
  lastError?: string;
  remaining: number;
  pendingRemote?: {
    operationId: string;
    itemId: string;
    action: "move";
    basisRecordId: string;
    basisRevisionId: string;
    provider: string;
    accountId: string;
    originalCollectionId: string;
    destination: string;
    createdAt: string;
  };
}

export interface KnowledgeConnectorStatus {
  connector: "raindrop" | "x";
  connectionId?: string;
  configured: boolean;
  enabled: boolean;
  health: KnowledgeConnectorState["health"];
  credentialAvailability: "available" | "unavailable" | "unknown";
  providerIdentity: "admitted" | "mismatch" | "unknown";
  accountId?: string;
  scope?: string;
  raindropCollections?: Array<{ collectionId: string; scope: "research" | "personal"; destination?: string }>;
  destination?: string;
  lastRunAt?: string;
  lastError?: string;
  remaining: number;
  pending: number;
  paidBudgetCents: number;
  allowWrites: boolean;
  recurringApproved: boolean;
  paidAccessApproved: boolean;
  assessmentPilot?: { id: string; maxItems: number; budgetCents: number; usedItems: number; reservedCents: number; accountId: string; sourceCollection: string; profileVersion: string; itemIds: string[] };
  assessmentPilots?: Record<string, { id: string; maxItems: number; budgetCents: number; usedItems: number; reservedCents: number; accountId: string; sourceCollection: string; profileVersion: string; itemIds: string[] }>;
  assessmentApprovals?: Array<{ id: string; maxItems: number; budgetCents: number; reservedCents: number; usedItems: number; accountId: string; sourceCollection: string; profileVersion: string; itemIds: string[] }>;
}
/** Object bytes are authorized by the exact committed record revision that
 * supplied the object or representation reference. Hashes alone are never a
 * readable authority. */
export interface KnowledgeObjectReadRequest {
  recordId: string;
  revisionId: string;
  hash: string;
  bytes: number;
  mediaType: string;
  includeArchived?: boolean;
  offset?: number;
}
export interface KnowledgeCoverageDismissRequest { commandId: string; coverageId: string; expectedRevision: string; }

/** Bounded batch of exact preview references. Each item is authorized by its
 * own record revision; one item's failure never fails the batch. */
export interface KnowledgePreviewBatchRequest {
  items: Array<Pick<KnowledgeObjectReadRequest, "recordId" | "revisionId" | "hash" | "mediaType" | "bytes">>;
  includeArchived?: boolean;
}
export interface KnowledgePreviewBatchItem {
  recordId: string;
  hash: string;
  base64?: string;
  unavailable?: "forbidden" | "missing" | "too-large";
}
export interface KnowledgePreviewBatchResponse { items: KnowledgePreviewBatchItem[] }

export type KnowledgeAction =
  | { operation: "knowledge.status"; request: Record<string, never> }
  | { operation: "knowledge.observation.coverage"; request: KnowledgeCoverageRequest }
  | { operation: "knowledge.observation.dismiss"; request: KnowledgeCoverageDismissRequest }
  | { operation: "knowledge.object.read"; request: KnowledgeObjectReadRequest }
  | { operation: "knowledge.previews.read"; request: KnowledgePreviewBatchRequest }
  | { operation: "knowledge.config"; request: { commandId: string; config: KnowledgeConfig } }
  | { operation: "knowledge.tags.configure"; request: KnowledgeTagEditRequest }
  | { operation: "knowledge.tags.reconcile"; request: KnowledgeTagReconcileRequest }
  | { operation: "knowledge.tags.retag-needed"; request: KnowledgeTagRetagRequest }
  | { operation: "knowledge.list"; request: KnowledgeListRequest }
  | { operation: "knowledge.read"; request: { id: string; revisionId?: string; includeSuppressed?: boolean; includeArchived?: boolean; includePending?: boolean; offset?: number } }
  | { operation: "knowledge.search"; request: KnowledgeSearchRequest }
  | { operation: "knowledge.recall"; request: KnowledgeRecallRequest }
  | { operation: "knowledge.source.capture"; request: KnowledgeSourceCaptureRequest }
  | { operation: "knowledge.source.preview.refresh"; request: KnowledgeSourcePreviewRefreshRequest }
  | { operation: "knowledge.note.create"; request: KnowledgeNoteMutationRequest & { recordId?: never } }
  | { operation: "knowledge.note.update"; request: KnowledgeNoteMutationRequest & { recordId: string } }
  | { operation: "knowledge.reflect"; request: KnowledgeReflectRequest }
  | { operation: "knowledge.source.triage"; request: KnowledgeTriageRequest }
  | { operation: "knowledge.source.summarize"; request: KnowledgeSourceSummaryRequest }
  | { operation: "knowledge.source.reextract"; request: KnowledgeSourceReextractRequest }
  | { operation: "knowledge.source.admission"; request: KnowledgeSourceAdmissionRequest }
  | { operation: "knowledge.source.curate"; request: KnowledgeCurationRequest }
  | { operation: "knowledge.source.take"; request: KnowledgeSourceTakeRequest }
  | { operation: "knowledge.curation.jobs"; request: KnowledgeCurationJobRequest }
  | { operation: "knowledge.source.tag"; request: KnowledgeTagRequest }
  | { operation: "knowledge.tags.run"; request: KnowledgeTagRunRequest }
  | { operation: "knowledge.tags.budget"; request: KnowledgeTagBudgetRequest }
  | { operation: "knowledge.tags.budget.reconcile"; request: KnowledgeTagBudgetReconcileRequest }
  | { operation: "knowledge.tags.estimate"; request: KnowledgeTagCostEstimateRequest }
  | { operation: "knowledge.correction"; request: KnowledgeCorrectionRequest }
  | { operation: "knowledge.forget"; request: KnowledgeForgetRequest }
  | { operation: "knowledge.exclusion"; request: KnowledgeExclusionRequest }
  | { operation: "knowledge.connector.configure"; request: KnowledgeConnectorConfigurationRequest }
  | { operation: "knowledge.connector.assessment.approve"; request: KnowledgeAssessmentApprovalRequest }
  | { operation: "knowledge.connector.status"; request: KnowledgeConnectorStatusRequest }
  | { operation: "knowledge.connector.run"; request: KnowledgeConnectorRunRequest }
  | { operation: "knowledge.raindrop.intake"; request: KnowledgeRaindropIntakeRequest }
  | { operation: "knowledge.raindrop.read"; request: KnowledgeRaindropRequest };

const ID = /^[A-Za-z0-9._:-]{1,200}$/;
const REVISION = /^[0-9a-f-]{16,80}$/;
const HASH = /^[a-f0-9]{64}$/;

export function assertKnowledgeId(value: unknown, label = "knowledge id"): asserts value is string {
  if (typeof value !== "string" || !ID.test(value) || value === "." || value === "..") throw new Error(`Invalid ${label}`);
}

/** Project identity is a bounded workspace reference, not a record ID. */
export function assertKnowledgeProjectId(value: unknown, label = "project id"): asserts value is string {
  if (typeof value !== "string" || value.length < 1 || value.length > 4_096 || /[\u0000-\u001f\u007f]/.test(value)) throw new Error(`Invalid ${label}`);
  if (value.startsWith("/")) {
    if (value.includes("\\") || value.split("/").some(component => component === "..")) throw new Error(`Invalid ${label}`);
    return;
  }
  if (!ID.test(value) || value === "." || value === "..") throw new Error(`Invalid ${label}`);
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

function assertCurationProducer(value: unknown): asserts value is SourceCurationProducer {
  if (!value || typeof value !== "object" || Array.isArray(value)) throw new Error("Invalid curation producer");
  const producer = value as Record<string, unknown>;
  if (!["user", "agent", "connector", "import", "system"].includes(producer.actor as string)) throw new Error("Invalid curation producer actor");
  if (producer.model !== undefined) boundedString(producer.model, "curation producer model", 200);
}

/** Tag IDs are opaque vocabulary identifiers; the vocabulary decides which of
 * them are active, not their spelling here. */
export function assertKnowledgeTagId(value: unknown, label = "tag id"): asserts value is string {
  if (typeof value !== "string" || !/^[A-Za-z0-9._:-]{1,64}$/.test(value) || value === "." || value === "..") throw new Error(`Invalid ${label}`);
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
    if (content.collectionId !== undefined) boundedString(content.collectionId, "source collection id", 256);
    if (!["complete", "partial", "metadata-only", "inaccessible", "failed", "reference-only"].includes(content.captureDisposition as string)) throw new Error("Invalid capture disposition");
    if (content.origin !== undefined && !["manual", "connector", "import", "conversation"].includes(content.origin as string)) throw new Error("Invalid source origin");
    assertTimestamp(content.capturedAt, "capturedAt");
    if (content.sourcePublishedAt !== undefined) assertTimestamp(content.sourcePublishedAt, "sourcePublishedAt");
    if (content.sourceSavedAt !== undefined) assertTimestamp(content.sourceSavedAt, "sourceSavedAt");
    if (content.take !== undefined) {
      const take = content.take as Record<string, unknown>;
      if (!take || typeof take !== "object" || Array.isArray(take) || Object.keys(take).some(key => !["text", "confirmed", "producer", "updatedAt"].includes(key)) || take.confirmed !== true || !take.producer || (take.producer as Record<string, unknown>).actor !== "user" || Object.keys(take.producer as Record<string, unknown>).length !== 1) throw new Error("Your take must be a confirmed user-authored note");
      boundedString(take.text, "Your take", 4_000); if (!take.text) throw new Error("Your take cannot be empty; omit it to clear explicitly");
      assertTimestamp(take.updatedAt, "Your take updatedAt");
    }
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
    if (content.summary !== undefined) {
      const summary = content.summary as Record<string, unknown>;
      if (!summary || typeof summary !== "object" || Array.isArray(summary)) throw new Error("Invalid source summary");
      boundedString(summary.text, "source summary", 8_000);
      assertCurationProducer(summary.producer);
      assertTimestamp(summary.generatedAt, "source summary generatedAt");
      if (typeof summary.sourceRevisionId !== "string" || !REVISION.test(summary.sourceRevisionId)) throw new Error("Invalid source summary revision");
      if (typeof summary.evidenceDigest !== "string" || !HASH.test(summary.evidenceDigest)) throw new Error("Invalid source summary evidence digest");
      if (!["full", "sampled"].includes(summary.coverage as string)) throw new Error("Invalid source summary coverage");
    }
    if (content.tags !== undefined) {
      const tags = content.tags as Record<string, unknown>;
      if (!tags || typeof tags !== "object" || Array.isArray(tags)) throw new Error("Invalid source tags");
      if (!Array.isArray(tags.tagIds) || tags.tagIds.length > 24) throw new Error("Invalid source tag selection");
      const seen = new Set<string>();
      for (const id of tags.tagIds) {
        assertKnowledgeTagId(id);
        if (seen.has(id)) throw new Error("Duplicate source tag id");
        seen.add(id);
      }
      if (!Number.isSafeInteger(tags.vocabularyRevision) || (tags.vocabularyRevision as number) < 0) throw new Error("Invalid source tag vocabulary revision");
      if (typeof tags.inputsDigest !== "string" || !HASH.test(tags.inputsDigest)) throw new Error("Invalid source tag inputs digest");
      assertTimestamp(tags.assignedAt, "source tags assignedAt");
      assertCurationProducer(tags.producer);
    }
    if (content.verdict !== undefined) {
      const verdict = content.verdict as Record<string, unknown>;
      if (!verdict || typeof verdict !== "object" || Array.isArray(verdict)) throw new Error("Invalid source verdict");
      if (!["evergreen", "dated", "superseded", "archive"].includes(verdict.verdict as string)) throw new Error("Invalid source verdict value");
      if (verdict.supersededBy !== undefined) {
        assertKnowledgeId(verdict.supersededBy, "verdict replacement id");
        if (verdict.verdict !== "superseded") throw new Error("Only a superseded verdict names a replacement");
      }
      if (verdict.verdict === "superseded" && verdict.supersededBy === undefined) throw new Error("A superseded verdict requires the replacement record");
      if (verdict.reason !== undefined) boundedString(verdict.reason, "source verdict reason", 2_000);
      assertTimestamp(verdict.decidedAt, "source verdict decidedAt");
      assertCurationProducer(verdict.producer);
    }
    if (content.assessment !== undefined) {
      const assessment = content.assessment as Record<string, unknown>;
      if (!assessment || typeof assessment !== "object" || Array.isArray(assessment)) throw new Error("Invalid source assessment");
      boundedString(assessment.summary, "source assessment summary", 20_000);
      for (const key of ["contribution", "whyItMatters", "possibleUse"]) if (assessment[key] !== undefined) boundedString(assessment[key], `source assessment ${key}`, 10_000);
      if (!["high", "medium", "low", "none", "unknown"].includes(assessment.evidenceQuality as string) || !["current", "aging", "stale", "unknown"].includes(assessment.freshness as string)) throw new Error("Invalid source assessment quality");
      assertTimestamp(assessment.generatedAt, "source assessment generatedAt");
      if (assessment.model !== undefined) boundedString(assessment.model, "source assessment model", 200);
      if (assessment.inputDigest !== undefined && !/^[a-f0-9]{64}$/.test(String(assessment.inputDigest))) throw new Error("Invalid source assessment input digest");
      if (assessment.evidenceDigest !== undefined && !/^[a-f0-9]{64}$/.test(String(assessment.evidenceDigest))) throw new Error("Invalid source assessment evidence digest");
      if (assessment.assessmentInputDigest !== undefined && !/^[a-f0-9]{64}$/.test(String(assessment.assessmentInputDigest))) throw new Error("Invalid source assessment state digest");
      if (assessment.coverage !== undefined && !["full", "sampled"].includes(String(assessment.coverage))) throw new Error("Invalid source assessment coverage");
      if (assessment.usage !== undefined) {
        const usage = assessment.usage as Record<string, unknown>;
        if (!usage || typeof usage !== "object" || Array.isArray(usage) || !Number.isSafeInteger(usage.inputTokens) || (usage.inputTokens as number) < 0 || !Number.isSafeInteger(usage.outputTokens) || (usage.outputTokens as number) < 0 || typeof usage.estimatedCostCents !== "number" || !Number.isFinite(usage.estimatedCostCents) || usage.estimatedCostCents < 0) throw new Error("Invalid source assessment usage");
        boundedString(usage.pricing, "source assessment pricing", 200);
      }
      if (assessment.recommendation !== undefined && !["pending", "retained", "archived"].includes(assessment.recommendation as string)) throw new Error("Invalid source assessment recommendation");
      if (assessment.confidence !== undefined && (typeof assessment.confidence !== "number" || !Number.isFinite(assessment.confidence) || assessment.confidence < 0 || assessment.confidence > 1)) throw new Error("Invalid source assessment confidence");
      for (const key of ["profileVersion", "rubricVersion"] as const) if (assessment[key] !== undefined) boundedString(assessment[key], `source assessment ${key}`, 200);
    }
    if (content.captureReason !== undefined) boundedString(content.captureReason, "source capture reason", 2_000);
    if (content.linkedUrls !== undefined) {
      if (!Array.isArray(content.linkedUrls) || content.linkedUrls.length > 8) throw new Error("Invalid linked source URLs");
      for (const value of content.linkedUrls) {
        boundedString(value, "linked source URL", 4_096);
        try {
          const url = new URL(value);
          if (!(url.protocol === "https:" || url.protocol === "http:") || url.username || url.password || url.port) throw new Error();
          for (const key of url.searchParams.keys()) if (isCredentialQueryKey(key)) throw new Error();
        } catch { throw new Error("Linked source URL must be an http(s) URL without credentials"); }
      }
    }
    if (content.annotations !== undefined) {
      if (!Array.isArray(content.annotations) || content.annotations.length > 200) throw new Error("Invalid source annotations");
      for (const annotation of content.annotations) { const item = annotation as Record<string, unknown>; boundedString(item.text, "annotation", 20_000); if (item.locator !== undefined) boundedString(item.locator, "annotation locator", 512); if (item.createdAt !== undefined) assertTimestamp(item.createdAt, "annotation createdAt"); }
    }
    if (content.object !== undefined) validateObjectRef(content.object);
    if (content.representations !== undefined) {
      if (!Array.isArray(content.representations) || content.representations.length > 20) throw new Error("Invalid source representations");
      for (const representation of content.representations) {
        const item = representation as Record<string, unknown>;
        if (!item || typeof item !== "object" || !["provider-api", "linked-article"].includes(item.kind as string)) throw new Error("Invalid source representation kind");
        validateObjectRef(item.object);
        if (item.mediaType !== undefined) boundedString(item.mediaType, "source representation media type", 160);
      }
    }
    if (content.admission !== undefined) {
      const admission = content.admission as Record<string, unknown>;
      if (!admission || typeof admission !== "object" || Array.isArray(admission) || !["pending", "retained", "archived"].includes(admission.status as string)) throw new Error("Invalid source admission");
      assertTimestamp(admission.decidedAt, "source admission decidedAt");
      if (admission.reason !== undefined) boundedString(admission.reason, "source admission reason", 2_000);
      for (const key of ["profileVersion", "rubricVersion"] as const) if (admission[key] !== undefined) boundedString(admission[key], `source admission ${key}`, 200);
    }
    if (content.retention !== undefined) {
      const retention = content.retention as Record<string, unknown>;
      if (!retention || typeof retention !== "object" || Array.isArray(retention) || !["public", "restricted", "private"].includes(retention.sensitivity as string) || typeof retention.evidenceAvailable !== "boolean") throw new Error("Invalid source retention");
      if (retention.usageConstraint !== undefined) boundedString(retention.usageConstraint, "source usage constraint", 20_000);
      if (retention.originalHash !== undefined && (typeof retention.originalHash !== "string" || !HASH.test(retention.originalHash))) throw new Error("Invalid source original hash");
    }
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
    if (content.usageConstraint !== undefined) boundedString(content.usageConstraint, "note usage constraint", 20_000);
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
  if (config.schemaVersion !== KNOWLEDGE_SCHEMA_VERSION || typeof config.revision !== "number" || !Number.isSafeInteger(config.revision) || config.revision < 0 || !eligibility || typeof eligibility !== "object" || !Array.isArray(eligibility.sessionIds) || !Array.isArray(eligibility.projectIds) || !Array.isArray(eligibility.excludedSessionIds) || !Array.isArray(eligibility.excludedProjectIds) || !eligibility.sessionIds.every(item => typeof item === "string" && ID.test(item)) || !eligibility.projectIds.every(item => { try { assertKnowledgeProjectId(item, "project id"); return true; } catch { return false; } }) || !eligibility.excludedSessionIds.every(item => typeof item === "string" && ID.test(item)) || !eligibility.excludedProjectIds.every(item => { try { assertKnowledgeProjectId(item, "excluded project id"); return true; } catch { return false; } }) || !observation || typeof observation !== "object" || typeof observation.enabled !== "boolean" || typeof maxInputChars !== "number" || !Number.isSafeInteger(maxInputChars) || maxInputChars < 1_000 || maxInputChars > 200_000 || typeof maxOutputChars !== "number" || !Number.isSafeInteger(maxOutputChars) || maxOutputChars < 100 || maxOutputChars > 50_000 || typeof timeoutMs !== "number" || !Number.isSafeInteger(timeoutMs) || timeoutMs < 1_000 || timeoutMs > 300_000 || typeof maxAttempts !== "number" || !Number.isSafeInteger(maxAttempts) || maxAttempts < 1 || maxAttempts > 3 || typeof maximumSearchResults !== "number" || !Number.isSafeInteger(maximumSearchResults) || maximumSearchResults < 1 || maximumSearchResults > 100) throw new Error("Invalid knowledge configuration");
  if (eligibility.allSessions !== undefined && eligibility.allSessions !== true) throw new Error("Invalid global observation grant");
  if (observation.model !== undefined && (typeof observation.model !== "string" || observation.model.length === 0 || observation.model.length > 200)) throw new Error("Invalid observation model");
  if (config.enrichment !== undefined) {
    const enrichment = config.enrichment as Record<string, unknown>;
    if (!enrichment || typeof enrichment !== "object" || Array.isArray(enrichment) || Object.keys(enrichment).some(key => key !== "model") || (enrichment.model !== undefined && (typeof enrichment.model !== "string" || enrichment.model.length === 0 || enrichment.model.length > 200))) throw new Error("Invalid Knowledge enrichment model");
  }
  if (config.currentInterests !== undefined && (!Array.isArray(config.currentInterests) || config.currentInterests.length > 50 || !config.currentInterests.every(item => typeof item === "string" && item.length > 0 && item.length <= 500))) throw new Error("Invalid current interests");
  const tagVocabulary = config.tagVocabulary ?? { revision: 0, tags: [], guidelines: "" };
  validateKnowledgeTagVocabulary(tagVocabulary);
  // The config was persisted before K3 introduced its vocabulary. This additive
  // default preserves every existing setting while establishing an empty owner.
  return { ...(value as KnowledgeConfig), tagVocabulary };
}

const TAG_ID = /^[a-z][a-z0-9-]{0,47}$/;
const TAG_CATEGORY = /^[a-z][a-z0-9-]{0,47}$/;
export function validateKnowledgeTagVocabulary(value: unknown): asserts value is KnowledgeTagVocabularyConfig {
  if (!value || typeof value !== "object" || Array.isArray(value)) throw new Error("Invalid Knowledge tag vocabulary");
  const vocabulary = value as Record<string, unknown>;
  if (Object.keys(vocabulary).some(key => !["revision", "tags", "guidelines"].includes(key)) || !Number.isSafeInteger(vocabulary.revision) || (vocabulary.revision as number) < 0 || !Array.isArray(vocabulary.tags) || vocabulary.tags.length > KNOWLEDGE_TAG_MAX_COUNT || typeof vocabulary.guidelines !== "string" || vocabulary.guidelines.length > KNOWLEDGE_TAG_MAX_GUIDELINES_CHARS) throw new Error(`Knowledge tag vocabulary revision must be non-negative; it carries at most ${KNOWLEDGE_TAG_MAX_COUNT} tags and ${KNOWLEDGE_TAG_MAX_GUIDELINES_CHARS} guideline characters`);
  const ids = new Set<string>();
  const labels = new Set<string>();
  const byId = new Map<string, KnowledgeTagDefinition>();
  for (const item of vocabulary.tags) {
    if (!item || typeof item !== "object" || Array.isArray(item)) throw new Error("Invalid Knowledge tag definition");
    const tag = item as Record<string, unknown>;
    if (Object.keys(tag).some(key => !["id", "label", "definition", "category", "decayClass", "state", "mergedInto"].includes(key)) || typeof tag.id !== "string" || !TAG_ID.test(tag.id) || typeof tag.label !== "string" || tag.label !== tag.label.trim() || tag.label.length < 1 || tag.label.length > 80 || /[\r\n\u0000-\u001f]/.test(tag.label) || typeof tag.definition !== "string" || tag.definition !== tag.definition.trim() || tag.definition.length < 1 || tag.definition.length > 512 || /[\r\n\u0000-\u001f]/.test(tag.definition) || typeof tag.category !== "string" || !TAG_CATEGORY.test(tag.category) || (tag.decayClass !== "ages" && tag.decayClass !== "stable") || !["active", "retired", "merged"].includes(tag.state as string)) throw new Error("Invalid Knowledge tag definition: IDs and categories use lowercase slugs; labels and one-line definitions are bounded");
    if (ids.has(tag.id)) throw new Error(`Duplicate Knowledge tag ID ${tag.id}`);
    const labelKey = tag.label.trim().normalize("NFKC").toLocaleLowerCase();
    if (labels.has(labelKey)) throw new Error(`Duplicate Knowledge tag label ${tag.label.trim()}`);
    ids.add(tag.id); labels.add(labelKey); byId.set(tag.id, item as KnowledgeTagDefinition);
    if (tag.state === "merged") {
      if (typeof tag.mergedInto !== "string" || !TAG_ID.test(tag.mergedInto) || tag.mergedInto === tag.id) throw new Error(`Merged tag ${tag.id} requires a distinct target`);
    } else if (tag.mergedInto !== undefined) throw new Error(`Only merged tags may name mergedInto (${tag.id})`);
  }
  for (const tag of byId.values()) {
    if (tag.state !== "merged") continue;
    const seen = new Set<string>([tag.id]);
    let target: KnowledgeTagDefinition | undefined = tag;
    while (target?.state === "merged") {
      if (seen.has(target.mergedInto!)) throw new Error(`Knowledge tag merge cycle at ${target.mergedInto}`);
      seen.add(target.mergedInto!);
      target = byId.get(target.mergedInto!);
    }
    if (!target || target.state !== "active") throw new Error(`Merged tag ${tag.id} must resolve to an active tag`);
  }
}
