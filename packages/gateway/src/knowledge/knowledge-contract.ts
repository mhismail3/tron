import type { JsonValue } from "../protocol/types.js";
import { isGatewayTimestamp } from "../util/timestamp.js";
import { validateProfileMetadata } from "./knowledge-profile-placement.js";

export const KNOWLEDGE_SCHEMA_VERSION = 1 as const;

export type KnowledgeScope = "personal" | "research";
export type KnowledgeRecordKind = "note";

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
  /** Why this revision was written, when its writer records one (Home's profile changes do). Bounded text; ledger metadata, never evidence. */
  reason?: string;
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
  /** Sole current placement; absent only in pre-hierarchy revisions/Undo. */
  profile?: import("./knowledge-profile-placement.js").ProfileMetadata;
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
  /** Note labels that name an owner's role for the note, such as Home's `home-profile`
   * and `kind-*` labels. Not the source tag vocabulary: a note's labels are free, bounded by
   * `NOTE_TAG_PATTERN` and `NOTE_TAGS_MAX`, and an owner alone decides what they mean. */
  tags?: string[];
  /** Set on a note that has left active use. Its earlier revisions stay in the ledger.
   * A draft may name `false` to return a retired note to use (an owner's undo); a stored
   * revision never holds `false`, only `true` or nothing. */
  retired?: boolean;
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

export type KnowledgeRecord = KnowledgeRecordBase & { kind: "note"; content: NoteContent };
export type KnowledgeRecordDraft = Omit<KnowledgeRecordBase, "schemaVersion" | "id" | "revisionId" | "createdAt" | "updatedAt"> & {
  id?: string; createdAt?: string; updatedAt?: string; kind: "note"; content: NoteContent;
};

export interface KnowledgeConfig {
  schemaVersion: typeof KNOWLEDGE_SCHEMA_VERSION;
  revision: number;
  eligibility: { excludedSessionIds: string[]; excludedProjectIds: string[] };
  maximumSearchResults: number;
}
export const DEFAULT_KNOWLEDGE_CONFIG: KnowledgeConfig = { schemaVersion: 1, revision: 0, eligibility: { excludedSessionIds: [], excludedProjectIds: [] }, maximumSearchResults: 50 };
export interface KnowledgeListRequest {
  kind?: "note"; scope?: KnowledgeScope; limit?: number; cursor?: string; includeSuppressed?: boolean;
}
export interface KnowledgeListResponse {
  records: KnowledgeRecord[]; stateRevision: number; nextCursor?: string; incomplete?: boolean;
}
export interface KnowledgeNoteMutationRequest {
  commandId: string; record: KnowledgeRecordDraft; confirmedByUser?: boolean;
}
export type KnowledgeAction =
  | { operation: "knowledge.list"; request: KnowledgeListRequest }
  | { operation: "knowledge.read"; request: { id: string; revisionId?: string; includeSuppressed?: boolean } }
  | { operation: "knowledge.note.create"; request: KnowledgeNoteMutationRequest }
  | { operation: "knowledge.note.update"; request: KnowledgeNoteMutationRequest & { recordId: string; expectedRevision: string } };

const ID = /^[A-Za-z0-9._:-]{1,200}$/;
const REVISION = /^[0-9a-f-]{16,80}$/;
const HASH = /^[a-f0-9]{64}$/;
const NOTE_TAG_PATTERN = /^[a-z][a-z0-9-]{0,47}$/;
const NOTE_TAGS_MAX = 8;

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

export function validateKnowledgeRecord(value: unknown): KnowledgeRecord {
  if (!value || typeof value !== "object" || Array.isArray(value)) throw new Error("Invalid knowledge record");
  const item = value as Record<string, unknown>;
  if (item.schemaVersion !== KNOWLEDGE_SCHEMA_VERSION) throw new Error("Unsupported knowledge record schema");
  assertKnowledgeId(item.id);
  if (typeof item.revisionId !== "string" || !REVISION.test(item.revisionId)) throw new Error("Invalid knowledge revision");
  if (item.kind !== "note") throw new Error("Invalid knowledge kind");
  if (item.scope !== "personal" && item.scope !== "research") throw new Error("Invalid knowledge scope");
  assertTimestamp(item.createdAt, "createdAt");
  assertTimestamp(item.updatedAt, "updatedAt");
  const provenance = item.provenance as Record<string, unknown>;
  if (!provenance || typeof provenance !== "object" || Array.isArray(provenance)) throw new Error("Invalid provenance");
  if (!["user", "agent", "connector", "import", "system"].includes(provenance.actor as string)) throw new Error("Invalid provenance actor");
  if (provenance.reason !== undefined) boundedString(provenance.reason, "provenance reason", 2_000);
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
  validateNoteContent(item.content);
  if (item.kind === "note") {
    const note = item.content as NoteContent;
    if (note.profile && item.scope !== "personal") throw new Error("Profile metadata belongs only to personal notes");
    if (note.profile && note.tags?.includes("kind-correction") && !item.relations.some(relation => relation.type === "corrects" && typeof relation.revisionId === "string")) throw new Error("A correction requires an exact wrong-claim relation");
  }
  return value as KnowledgeRecord;
}

function validateNoteContent(value: unknown): void {
  if (!value || typeof value !== "object" || Array.isArray(value)) throw new Error("Invalid knowledge content");
  const content = value as Record<string, unknown>;
    if (typeof content.title !== "string" || content.title.length > 512 || !["fact", "preference", "concept", "decision", "workflow", "synthesis"].includes(content.role as string) || typeof content.confirmed !== "boolean") throw new Error("Invalid note content");
    if (content.body !== undefined && (typeof content.body !== "string" || content.body.length > 100_000)) throw new Error("Invalid note body");
    if (content.contraryEvidence !== undefined) { if (!Array.isArray(content.contraryEvidence) || content.contraryEvidence.length > 100) throw new Error("Invalid contrary evidence"); content.contraryEvidence.forEach(assertEvidence); }
    if (content.freshness !== undefined && !["current", "aging", "stale", "unknown"].includes(content.freshness as string)) throw new Error("Invalid note freshness");
    if (content.tags !== undefined) {
      if (!Array.isArray(content.tags) || content.tags.length > NOTE_TAGS_MAX) throw new Error("Invalid note tags");
      if (new Set(content.tags).size !== content.tags.length || !content.tags.every(tag => typeof tag === "string" && NOTE_TAG_PATTERN.test(tag))) throw new Error("Invalid note tags");
    }
    if (content.profile !== undefined) {
      validateProfileMetadata(content.profile);
      if ((content.tags as string[] | undefined)?.includes("kind-correction") && content.profile.path[0] !== "corrections") throw new Error("Corrections stay in the Corrections area");
      if (!(content.tags as string[] | undefined)?.includes("home-profile") || (content.tags as string[]).some(tag => tag.startsWith("home-file-"))) throw new Error("Profile placement must have membership and no legacy file labels");
    }
    if (content.retired !== undefined && typeof content.retired !== "boolean") throw new Error("Invalid note retirement");
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
export function validateKnowledgeConfig(value: unknown): KnowledgeConfig {
  if (!value || typeof value !== "object" || Array.isArray(value)) throw new Error("Invalid Profile note configuration");
  const config = value as Record<string, unknown>;
  const eligibility = config.eligibility as Record<string, unknown>;
  const maximumSearchResults = config.maximumSearchResults;
  if (config.schemaVersion !== KNOWLEDGE_SCHEMA_VERSION || typeof config.revision !== "number" || !Number.isSafeInteger(config.revision) || config.revision < 0 || !eligibility || typeof eligibility !== "object" || Object.keys(eligibility).some(key => !["excludedSessionIds", "excludedProjectIds"].includes(key)) || !Array.isArray(eligibility.excludedSessionIds) || !Array.isArray(eligibility.excludedProjectIds) || !eligibility.excludedSessionIds.every(item => typeof item === "string" && ID.test(item)) || !eligibility.excludedProjectIds.every(item => { try { assertKnowledgeProjectId(item, "excluded project id"); return true; } catch { return false; } }) || typeof maximumSearchResults !== "number" || !Number.isSafeInteger(maximumSearchResults) || maximumSearchResults < 1 || maximumSearchResults > 100) throw new Error("Invalid Profile note configuration");
  return { schemaVersion: 1, revision: config.revision, eligibility: { excludedSessionIds: eligibility.excludedSessionIds as string[], excludedProjectIds: eligibility.excludedProjectIds as string[] }, maximumSearchResults };
}
