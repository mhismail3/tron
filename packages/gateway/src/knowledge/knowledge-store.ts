import { createHash, randomBytes, randomUUID } from "node:crypto";
import { constants } from "node:fs";
import { lstat, mkdir, open, rename } from "node:fs/promises";
import { join, dirname } from "node:path";
import type { TronWorkspace } from "../workspace/tron-workspace.js";
import { GatewayError } from "../errors.js";
import { AsyncMutex } from "../util/async-mutex.js";
import { durableAtomicWriteJson, durableRemove } from "../util/durable-json.js";
import { readSecureJson, SecureJsonFileError } from "../util/secure-json.js";
import {
  DEFAULT_KNOWLEDGE_CONFIG, KNOWLEDGE_SCHEMA_VERSION,
  type KnowledgeConfig, type KnowledgeEvidenceRef, type KnowledgeListRequest,
  type KnowledgeListResponse, type KnowledgeObjectRef, type KnowledgeRecallRequest,
  type KnowledgeRecallResponse, type KnowledgeRecord, type KnowledgeRecordDraft,
  type KnowledgeSearchRequest, type KnowledgeSearchResponse, type KnowledgeSearchHit,
  type KnowledgeNoteMutationRequest,
  type KnowledgeConnectorState, type ObservationCoverage, type ObservationRange, validateKnowledgeConfig,
  validateKnowledgeRecord, validateObjectRef, assertKnowledgeId, assertKnowledgeProjectId,
} from "./knowledge-contract.js";
import { isGatewayTimestamp } from "../util/timestamp.js";

const STATE_MAX_BYTES = 4 * 1_048_576;
const RECORD_MAX_BYTES = 2 * 1_048_576;
const OBJECT_MAX_BYTES = 8_000_000;
const RECEIPT_LIMIT = 256;
const OBJECT_HASH = /^[a-f0-9]{64}$/;
const OBJECT_SCHEMA_VERSION = 1 as const;
const MAX_SCAN_RECORDS = 1_000;
const MAX_SCAN_BYTES = 16 * 1_048_576;

type RecordHead = { latestRevisionId: string; revisionIds: string[] };
type Suppression = { excluded: boolean; forgotten: boolean; reason?: string; updatedAt: string };
type ScopeExclusion = { sessionId?: string; branchId?: string; projectId?: string; excluded: boolean; reason?: string; updatedAt: string };
type PendingRecordCleanup = { recordId: string; revisionId: string };
type SourceRecordWriteRequest = { commandId: string; expectedRevision?: string; record: KnowledgeRecordDraft & { kind: "source" } };
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
interface KnowledgeState {
  schemaVersion: typeof KNOWLEDGE_SCHEMA_VERSION;
  stateRevision: number;
  records: Record<string, RecordHead>;
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
  connectors?: Partial<Record<"raindrop" | "x", KnowledgeConnectorState>>;
}

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

function emptyState(): KnowledgeState {
  return { schemaVersion: KNOWLEDGE_SCHEMA_VERSION, stateRevision: 0, records: {}, coverage: {}, suppressions: {}, scopeExclusions: {}, cleanup: [], recordCleanup: [], imports: {}, receipts: {}, config: structuredClone(DEFAULT_KNOWLEDGE_CONFIG), connectors: {} };
}
function validateCoverage(value: unknown): asserts value is ObservationCoverage {
  if (!value || typeof value !== "object" || Array.isArray(value)) throw new KnowledgeStoreError("invalid", "Invalid observation coverage");
  const coverage = value as Record<string, unknown>;
  if (coverage.schemaVersion !== KNOWLEDGE_SCHEMA_VERSION || typeof coverage.id !== "string" || typeof coverage.revisionId !== "string" || !Array.isArray(coverage.groupRevisionIds) || typeof coverage.recordedAt !== "string" || !["observed", "empty", "excluded", "pending", "failed", "unavailable"].includes(coverage.disposition as string)) throw new KnowledgeStoreError("invalid", "Invalid observation coverage");
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
  if (state.connector !== connector || typeof state.enabled !== "boolean" || typeof state.allowWrites !== "boolean" || typeof state.paidAccessApproved !== "boolean" || !Number.isSafeInteger(state.paidBudgetCents) || (state.paidBudgetCents as number) < 0 || (state.paidBudgetCents as number) > 1_000_000 || typeof state.recurringApproved !== "boolean" || !Array.isArray(state.pending) || !Array.isArray(state.capturedIds) || !["unconfigured", "ready", "running", "partial", "rate-limited", "auth-error", "error"].includes(state.health as string) || !Number.isSafeInteger(state.remaining) || (state.remaining as number) < 0 || state.pending.length > 500 || state.capturedIds.length > 2_000) throw new KnowledgeStoreError("invalid", "Invalid connector state");
  for (const item of state.pending) {
    if (!item || typeof item !== "object" || typeof (item as Record<string, unknown>).id !== "string" || typeof (item as Record<string, unknown>).title !== "string" || typeof (item as Record<string, unknown>).url !== "string" || ((item as Record<string, unknown>).apiPayload !== undefined && (typeof (item as Record<string, unknown>).apiPayload !== "string" || ((item as Record<string, unknown>).apiPayload as string).length > 100_000))) throw new KnowledgeStoreError("invalid", "Invalid connector pending item");
  }
  for (const id of state.capturedIds) if (typeof id !== "string" || id.length > 512) throw new KnowledgeStoreError("invalid", "Invalid connector captured ID");
  for (const key of ["accountId", "scope", "destination", "credentialRef", "checkpoint", "lastRunAt", "lastError"]) if (state[key] !== undefined && (typeof state[key] !== "string" || (state[key] as string).length > 4_096)) throw new KnowledgeStoreError("invalid", "Invalid connector state field");
  if (state.pendingRemote !== undefined) {
    const pending = state.pendingRemote as Record<string, unknown>;
    if (!pending || pending.action !== "move" || typeof pending.operationId !== "string" || typeof pending.itemId !== "string" || typeof pending.basisRecordId !== "string" || typeof pending.originalCollectionId !== "string" || typeof pending.destination !== "string" || typeof pending.createdAt !== "string") throw new KnowledgeStoreError("invalid", "Invalid connector remote receipt");
  }
}

function validateState(value: unknown): KnowledgeState {
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
    const connectors = state.connectors as Partial<Record<"raindrop" | "x", unknown>>;
    for (const connector of ["raindrop", "x"] as const) if (connectors[connector] !== undefined) validateConnectorState(connectors[connector], connector);
  }
  return value as KnowledgeState;
}
function recordObjectHashes(record: KnowledgeRecord): string[] {
  const hashes: string[] = [];
  if (record.kind === "source" && record.content.object) hashes.push(record.content.object.hash);
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
function scopeKey(range: ObservationRange): string[] { return [`session:${range.sessionId}`, ...(range.branchId ? [`branch:${range.sessionId}:${range.branchId}`] : []), ...(range.projectId ? [`project:${range.projectId}`] : [])]; }

interface StorePaths { root: string; state: string; objects: string; records: string; groups: string; present: boolean; fresh: boolean; }

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

/** Canonical owner: immutable record/object files are data; state.json is only
 * the small atomic set of heads, coverage, suppression and receipts. */
export class KnowledgeStore {
  private static readonly workspaceLocks = new WeakMap<TronWorkspace, AsyncMutex>();
  private readonly mutex: AsyncMutex;
  constructor(private readonly workspace: TronWorkspace) {
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
    if (!stateRootPresent) return { root, state: join(root, "state.json"), objects: join(root, "objects"), records: join(root, "records"), groups: join(root, "groups"), present: false, fresh: !(await this.workspace.featureInitialized("knowledge")) };
    let present = true;
    let fresh = false;
    try { await safeDirectory(root, false); } catch (error) {
      if (!(error instanceof KnowledgeStoreError) || !error.message.includes("unavailable")) throw error;
      present = false;
      fresh = !(await this.workspace.featureInitialized("knowledge"));
      if (create) { await safeDirectory(root, true); present = true; }
    }
    const paths = { root, state: join(root, "state.json"), objects: join(root, "objects"), records: join(root, "records"), groups: join(root, "groups"), present, fresh };
    if (!present) return paths;
    const marker = join(root, "initialized.json");
    const markerRead = await readSecureJson<unknown>(marker, 128);
    if (!markerRead.present) {
      if (!create) throw new KnowledgeStoreError("invalid", "Knowledge namespace exists without initialization evidence");
      // A namespace created by this owner is marked before its first state commit.
      await safeDirectory(paths.objects, true); await safeDirectory(paths.records, true); await safeDirectory(paths.groups, true);
      await durableAtomicWriteJson(marker, { version: 1 }, 0o600);
      await this.workspace.markFeatureInitialized("knowledge");
    } else if (JSON.stringify(markerRead.value) !== JSON.stringify({ version: 1 })) throw new KnowledgeStoreError("invalid", "Invalid knowledge initialization record");
    await safeDirectory(paths.objects, false); await safeDirectory(paths.records, false); await safeDirectory(paths.groups, false);
    return { ...paths, fresh };
  }
  private async load(paths: StorePaths, allowEmpty: boolean): Promise<{ state: KnowledgeState; present: boolean }> {
    let read;
    try { read = await readSecureJson<unknown>(paths.state, STATE_MAX_BYTES); }
    catch (error) { if (error instanceof SecureJsonFileError) throw new KnowledgeStoreError(error.kind === "unsafe" ? "unsafe" : "invalid", error.message); throw error; }
    if (!read.present) {
      if (!paths.fresh) throw new KnowledgeStoreError("invalid", "Initialized knowledge state is missing");
      return { state: emptyState(), present: false };
    }
    return { state: validateState(read.value), present: true };
  }
  private async save(paths: StorePaths, state: KnowledgeState): Promise<void> {
    if (Buffer.byteLength(`${JSON.stringify(state, null, 2)}\n`, "utf8") > STATE_MAX_BYTES) throw invalid("Knowledge control state exceeds its byte limit");
    await durableAtomicWriteJson(paths.state, state, 0o600);
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
    if (state.suppressions[record.id]?.forgotten) return true;
    const forgotten = (id: string | undefined): boolean => id !== undefined && state.suppressions[id]?.forgotten === true;
    // Forget is a hard evidence fence, including historical revisions and
    // includeSuppressed reads. A derivative that still cites a forgotten
    // record is unavailable until its owning revision is scrubbed.
    if (record.provenance.evidence.some(evidence => forgotten(evidence.recordId)) || record.relations.some(relation => forgotten(relation.recordId))) return true;
    if (record.kind === "observation" && record.content.items.some(item => item.evidence?.some(evidence => forgotten(evidence.recordId)))) return true;
    if (record.kind === "note" && (record.content.fields?.some(field => field.evidence.some(evidence => forgotten(evidence.recordId))) || record.content.contraryEvidence?.some(evidence => forgotten(evidence.recordId)))) return true;
    return false;
  }

  private recordExcluded(state: KnowledgeState, record: KnowledgeRecord): boolean {
    if (state.suppressions[record.id]?.excluded || state.suppressions[record.id]?.forgotten) return true;
    if (this.recordHardErased(state, record)) return true;
    const scope = this.recordScope(record);
    if (scope.sessionId && state.config.eligibility.excludedSessionIds.includes(scope.sessionId)) return true;
    if (scope.projectId && state.config.eligibility.excludedProjectIds.includes(scope.projectId)) return true;
    const keys = [
      ...(scope.sessionId ? [`session:${scope.sessionId}`] : []),
      ...(scope.sessionId && scope.branchId ? [`branch:${scope.sessionId}:${scope.branchId}`] : []),
      ...(scope.projectId ? [`project:${scope.projectId}`] : []),
    ];
    return keys.some(key => state.scopeExclusions[key]?.excluded);
  }

  private async allRecords(paths: StorePaths, state: KnowledgeState, includeSuppressed = false): Promise<{ records: KnowledgeRecord[]; incomplete: boolean }> {
    const records: KnowledgeRecord[] = [];
    let scannedBytes = 0;
    let incomplete = false;
    for (const [id, head] of Object.entries(state.records)) {
      if (records.length >= MAX_SCAN_RECORDS || scannedBytes >= MAX_SCAN_BYTES) { incomplete = true; break; }
      const record = await this.readRecord(paths, id, head.latestRevisionId);
      scannedBytes += Buffer.byteLength(JSON.stringify(record), "utf8");
      if (includeSuppressed || !this.recordExcluded(state, record)) records.push(record);
    }
    if (Object.keys(state.records).length > records.length && records.length >= MAX_SCAN_RECORDS) incomplete = true;
    return { records, incomplete };
  }
  private async receiptResult(paths: StorePaths, state: KnowledgeState, result: ReceiptResult): Promise<unknown> {
    if (result.kind === "value") return result.value;
    if (result.kind === "record") {
      if (state.suppressions[result.recordId]?.forgotten) throw conflict("Knowledge mutation result was forgotten");
      return { record: await this.readRecord(paths, result.recordId, result.revisionId), stateRevision: result.stateRevision } satisfies KnowledgeMutationResult;
    }
    if (result.records.some(item => state.suppressions[item.recordId]?.forgotten)) throw conflict("Knowledge mutation result was forgotten");
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
  private async mutate<T>(operation: string, commandId: string, request: unknown, action: (state: KnowledgeState, paths: StorePaths) => Promise<T>, afterCommit?: (state: KnowledgeState, paths: StorePaths, result: T) => Promise<void>): Promise<T> {
    if (!/^[A-Za-z0-9._:-]{8,160}$/.test(commandId)) throw invalid("Mutating requests require a stable commandId");
    return this.mutex.run(async () => {
      const paths = await this.paths(true); const loaded = await this.load(paths, true); const state = loaded.state;
      // Establish control state before validation/action can fail, so a
      // rejected first mutation cannot leave a permanently half-initialized namespace.
      if (!loaded.present) await this.save(paths, state);
      const key = `${operation}\0${commandId}`; const hash = requestHash(operation, request); const prior = state.receipts[key];
      if (prior) { if (prior.operation !== operation || prior.requestHash !== hash) throw conflict("Command ID was already used for a different knowledge mutation"); if (prior.invalidated) throw conflict("Knowledge mutation result was forgotten"); return await this.receiptResult(paths, state, prior.result) as T; }
      const result = await action(state, paths); state.stateRevision += 1;
      const stored = this.receipt(result, state.stateRevision);
      state.receipts[key] = { operation, requestHash: hash, result: stored.stored, recordIds: stored.recordIds, createdAt: now(), invalidated: false };
      const entries = Object.entries(state.receipts).sort(([, a], [, b]) => a.createdAt.localeCompare(b.createdAt));
      for (const [receiptKey] of entries.slice(0, Math.max(0, entries.length - RECEIPT_LIMIT))) delete state.receipts[receiptKey];
      await this.save(paths, state);
      // Cleanup runs only after the control document is durable. A failed
      // cleanup leaves an ignored orphan for a later maintenance pass rather
      // than losing the committed suppression/tombstone.
      if (afterCommit) await afterCommit(state, paths, result).catch(() => {});
      return result;
    });
  }

  async status(): Promise<import("./knowledge-contract.js").KnowledgeStatus> {
    try {
      const paths = await this.paths(false); const loaded = await this.load(paths, false);
      if (!loaded.present) return { available: true, state: "uninitialized", recordCount: 0, coverageCount: 0, suppressedCount: 0, pendingCleanupCount: 0, config: structuredClone(DEFAULT_KNOWLEDGE_CONFIG), observationConfigured: false };
      const state = loaded.state;
      return { available: true, state: "ready", stateRevision: state.stateRevision, recordCount: Object.keys(state.records).length, coverageCount: Object.keys(state.coverage).length, suppressedCount: Object.values(state.suppressions).filter(item => item.excluded || item.forgotten).length, pendingCleanupCount: state.cleanup.length, config: state.config, observationConfigured: state.config.observation.enabled && state.config.observation.model !== undefined };
    } catch (error) {
      const kind = error instanceof KnowledgeStoreError ? error.kind : "unsafe";
      return { available: false, state: kind, recordCount: 0, coverageCount: 0, suppressedCount: 0, pendingCleanupCount: 0, config: structuredClone(DEFAULT_KNOWLEDGE_CONFIG), observationConfigured: false, detail: error instanceof Error ? error.message : String(error) };
    }
  }
  async config(): Promise<KnowledgeConfig> { const paths = await this.paths(false); return (await this.load(paths, false)).state.config; }
  async configure(commandId: string, config: KnowledgeConfig): Promise<KnowledgeConfig> {
    try { validateKnowledgeConfig(config); } catch (error) { throw invalid(error instanceof Error ? error.message : "Invalid knowledge config"); }
    return this.mutate("knowledge.config", commandId, config, async state => { if (config.revision !== state.config.revision) throw conflict("Knowledge configuration revision is stale"); const next = structuredClone(config); next.revision += 1; state.config = next; return next; });
  }

  async connectorState(connector: "raindrop" | "x"): Promise<KnowledgeConnectorState | undefined> {
    const paths = await this.paths(false); const state = (await this.load(paths, false)).state;
    const value = state.connectors?.[connector];
    return value ? structuredClone(value) : undefined;
  }

  /** Connector operational state shares the knowledge owner’s serialized state;
   * this update never accepts or persists a credential value. */
  async updateConnectorState(commandId: string, connector: "raindrop" | "x", update: (current: KnowledgeConnectorState | undefined) => KnowledgeConnectorState): Promise<KnowledgeConnectorState> {
    return this.mutate("knowledge.connector.state", commandId, { connector }, async state => {
      const next = update(state.connectors?.[connector] ? structuredClone(state.connectors[connector]) : undefined);
      validateConnectorState(next, connector);
      state.connectors = { ...(state.connectors ?? {}), [connector]: next };
      return next;
    });
  }

  async list(request: KnowledgeListRequest = {}): Promise<KnowledgeListResponse> {
    const paths = await this.paths(false); const loaded = await this.load(paths, false); const state = loaded.state;
    const limit = Math.min(request.limit ?? 50, state.config.maximumSearchResults); if (!Number.isSafeInteger(limit) || limit < 1) throw invalid("Invalid knowledge list limit");
    const scanned = await this.allRecords(paths, state, request.includeSuppressed === true);
    const records = scanned.records.filter(record => (!request.kind || record.kind === request.kind) && (!request.scope || record.scope === request.scope));
    records.sort((a, b) => b.updatedAt.localeCompare(a.updatedAt) || a.id.localeCompare(b.id)); const start = request.cursor ? Math.max(0, records.findIndex(record => record.id === request.cursor) + 1) : 0; const page = records.slice(start, start + limit);
    return { records: page, ...(start + limit < records.length ? { nextCursor: page.at(-1)!.id } : {}), stateRevision: state.stateRevision, ...(scanned.incomplete ? { incomplete: true } : {}) };
  }
  async read(id: string, revision?: string, includeSuppressed = false): Promise<KnowledgeRecord | null> {
    safeId(id, "record id"); if (revision !== undefined) safeId(revision, "knowledge revision"); const paths = await this.paths(false); const state = (await this.load(paths, false)).state;
    const head = state.records[id];
    if (!head) return null;
    const selected = revision ?? head.latestRevisionId;
    if (!head.revisionIds.includes(selected)) throw new KnowledgeStoreError("invalid", "Requested revision is not committed for this record");
    const record = await this.readRecord(paths, id, selected);
    // includeSuppressed is an audit visibility option, not an erasure bypass.
    if (this.recordHardErased(state, record)) return null;
    if (!includeSuppressed && this.recordExcluded(state, record)) return null;
    return record;
  }
  async search(request: KnowledgeSearchRequest): Promise<KnowledgeSearchResponse> {
    if (typeof request.query !== "string" || request.query.trim().length === 0 || request.query.length > 512) throw invalid("Search query must be non-empty and bounded");
    const paths = await this.paths(false); const state = (await this.load(paths, false)).state; const terms = request.query.toLocaleLowerCase().split(/\s+/).filter(Boolean); const hits: KnowledgeSearchHit[] = [];
    // Search the complete bounded canonical corpus first; list() pagination is a presentation limit.
    const scanned = await this.allRecords(paths, state);
    for (const record of scanned.records) {
      if ((request.kind && record.kind !== request.kind) || (request.scope && record.scope !== request.scope)) continue;
      const matchedFields: string[] = []; let score = 0;
      for (const [field, value] of searchableFields(record)) { const lower = value.toLocaleLowerCase(); const count = terms.reduce((sum, term) => sum + (lower.includes(term) ? 1 : 0), 0); if (count) { matchedFields.push(field); score += count; } }
      if (score) hits.push({ record, score, matchedFields });
    }
    hits.sort((a, b) => b.score - a.score || b.record.updatedAt.localeCompare(a.record.updatedAt)); const limit = Math.min(request.limit ?? 50, state.config.maximumSearchResults);
    return { hits: hits.slice(0, limit), stateRevision: state.stateRevision, indexState: "canonical", ...(scanned.incomplete ? { incomplete: true } : {}) };
  }
  async recall(request: KnowledgeRecallRequest): Promise<KnowledgeRecallResponse> {
    const paths = await this.paths(false); const state = (await this.load(paths, false)).state; const terms = request.query?.toLocaleLowerCase().split(/\s+/).filter(Boolean) ?? []; const records: KnowledgeRecord[] = [];
    const scanned = await this.allRecords(paths, state);
    for (const record of scanned.records) {
      if ((request.scope && record.scope !== request.scope)) continue;
      if (record.kind === "observation" && request.sessionId && record.content.range.sessionId !== request.sessionId) continue;
      if (record.kind === "observation" && request.entryId && !record.content.range.entryIds.includes(request.entryId)) continue;
      if (terms.length && !searchableFields(record).some(([, value]) => terms.every(term => value.toLocaleLowerCase().includes(term)))) continue;
      records.push(record);
    }
    records.sort((a, b) => b.updatedAt.localeCompare(a.updatedAt) || a.id.localeCompare(b.id)); const limit = Math.min(request.limit ?? 20, state.config.maximumSearchResults); const selected = records.slice(0, limit); const citations: KnowledgeEvidenceRef[] = [];
    for (const record of selected) citations.push(...record.provenance.evidence, ...(record.kind === "observation" ? record.content.items.flatMap(item => item.evidence ?? []) : []));
    return { records: selected, citations, stateRevision: state.stateRevision, availability: selected.length ? "available" : "no-match", ...(scanned.incomplete ? { incomplete: true } : {}) };
  }
  /** Resolve exact observation revisions for the Reflector without exposing a
   * second search/index authority. The caller still publishes through reflect,
   * which revalidates session, branch, suppression, and revision identity. */
  async observationRevisions(sessionId: string, revisionIds: string[]): Promise<KnowledgeRecord[]> {
    safeId(sessionId, "session id");
    const paths = await this.paths(false);
    const state = (await this.load(paths, false)).state;
    const wanted = new Set(revisionIds);
    const records: KnowledgeRecord[] = [];
    for (const [id, head] of Object.entries(state.records)) {
      for (const revisionId of head.revisionIds) {
        if (!wanted.has(revisionId)) continue;
        const record = await this.readRecord(paths, id, revisionId);
        if (record.kind === "observation" && record.content.range.sessionId === sessionId && !this.recordExcluded(state, record)) records.push(record);
      }
    }
    return records;
  }

  /** Internal source/import owner write. The transport action accepts URLs only. */
  async captureSource(request: SourceRecordWriteRequest): Promise<KnowledgeMutationResult> {
    return this.mutate("knowledge.source.record-write", request.commandId, request, async (state, paths) => this.putRecord(state, paths, request.record as KnowledgeRecordDraft, request.expectedRevision));
  }
  async createNote(request: KnowledgeNoteMutationRequest & { recordId?: never }): Promise<KnowledgeMutationResult> { return this.mutate("knowledge.note.create", request.commandId, request, async (state, paths) => this.putRecord(state, paths, request.record)); }
  async updateNote(request: KnowledgeNoteMutationRequest & { recordId: string }): Promise<KnowledgeMutationResult> { return this.mutate("knowledge.note.update", request.commandId, request, async (state, paths) => { const current = await this.currentRecord(state, paths, request.recordId); if (!current || current.kind !== "note") throw conflict("Knowledge note does not exist"); if (request.expectedRevision !== current.revisionId) throw conflict("Knowledge note revision is stale"); return this.putRecord(state, paths, { ...request.record, id: request.recordId, createdAt: current.createdAt }, request.expectedRevision); }); }
  private async currentRecord(state: KnowledgeState, paths: StorePaths, id: string): Promise<KnowledgeRecord | null> { const head = state.records[id]; return head ? this.readRecord(paths, id, head.latestRevisionId) : null; }
  private async putRecord(state: KnowledgeState, paths: StorePaths, draft: KnowledgeRecordDraft, expectedRevision?: string): Promise<KnowledgeMutationResult> {
    const id = draft.id ?? recordId(); safeId(id, "record id"); const existing = state.records[id]; if (state.suppressions[id]?.forgotten) throw conflict("Knowledge record was forgotten and cannot be recreated");
    const current = existing ? await this.currentRecord(state, paths, id) : null; if (expectedRevision !== undefined && current?.revisionId !== expectedRevision) throw conflict("Knowledge record revision is stale"); if (expectedRevision === undefined && current) throw conflict("Knowledge record already exists; supply its expected revision");
    if (draft.kind === "source" && draft.content.object) await this.assertObject(paths, draft.content.object);
    const timestamp = now(); const record = { ...draft, schemaVersion: KNOWLEDGE_SCHEMA_VERSION, id, revisionId: revisionId(), createdAt: draft.createdAt ?? current?.createdAt ?? timestamp, updatedAt: draft.updatedAt ?? timestamp } as KnowledgeRecord;
    try { validateKnowledgeRecord(record); } catch (error) { throw invalid(error instanceof Error ? error.message : "Invalid knowledge record"); }
    if (Buffer.byteLength(`${JSON.stringify(record, null, 2)}\n`, "utf8") > RECORD_MAX_BYTES) throw invalid("Knowledge record exceeds its byte limit");
    await safeDirectory(join(paths.records, id), true);
    await durableAtomicWriteJson(this.recordPath(paths, id, record.revisionId), record, 0o600);
    state.records[id] = { latestRevisionId: record.revisionId, revisionIds: [...(existing?.revisionIds ?? []), record.revisionId] };
    return { record, stateRevision: state.stateRevision + 1 };
  }
  private excludedRange(state: KnowledgeState, range: ObservationRange): boolean {
    const eligibility = state.config.eligibility;
    // An empty allowlist is intentionally unconfigured, never an all-session
    // grant. Session or project selection admits the range; exclusions win.
    if (eligibility.sessionIds.length === 0 && eligibility.projectIds.length === 0) return true;
    if (eligibility.excludedSessionIds.includes(range.sessionId) || !eligibility.sessionIds.includes(range.sessionId)
      && (!range.projectId || !eligibility.projectIds.includes(range.projectId))) return true;
    if (range.projectId && eligibility.excludedProjectIds.includes(range.projectId)) return true;
    return scopeKey(range).some(key => state.scopeExclusions[key]?.excluded);
  }

  /** Shared privacy predicate for recall/display owners. A historical record
   * remains stored for audit until forgotten, but excluded scope is not usable
   * evidence and must be filtered before presentation or model boundaries. */
  async scopeExcluded(scope: { sessionId?: string; branchId?: string; projectId?: string }): Promise<boolean> {
    const paths = await this.paths(false);
    const state = (await this.load(paths, false)).state;
    const keys = [
      ...(scope.sessionId ? [`session:${scope.sessionId}`] : []),
      ...(scope.sessionId && scope.branchId ? [`branch:${scope.sessionId}:${scope.branchId}`] : []),
      ...(scope.projectId ? [`project:${scope.projectId}`] : []),
    ];
    return keys.some(key => state.scopeExclusions[key]?.excluded)
      || (scope.sessionId ? state.config.eligibility.excludedSessionIds.includes(scope.sessionId) : false)
      || (scope.projectId ? state.config.eligibility.excludedProjectIds.includes(scope.projectId) : false);
  }
  async publishObservationGroup(input: ObservationGroupInput): Promise<{ records: KnowledgeRecord[]; coverage: ObservationCoverage; stateRevision: number }> {
    return this.mutate("knowledge.observation.publish", input.commandId, input, async (state, paths) => {
      if (input.expectedConfigRevision !== undefined && state.config.revision !== input.expectedConfigRevision) throw conflict("Observation configuration changed while inference was running");
      if (this.excludedRange(state, input.coverage.range)) throw conflict("Observation range is excluded"); const prior = state.coverage[input.coverage.id];
      if (prior && !sameRange(prior.range, input.coverage.range)) throw conflict("Observation coverage identity changed");
      if (prior && input.expectedCoverageRevision !== prior.revisionId) throw conflict("Observation coverage revision is stale"); if (!prior && input.expectedCoverageRevision !== undefined) throw conflict("Observation coverage does not exist");
      if (prior && ["observed", "empty", "excluded"].includes(prior.disposition)) throw conflict("Terminal observation coverage cannot be replaced");
      const records: KnowledgeRecord[] = [];
      for (const draft of input.records) { if (!sameRange(draft.content.range, input.coverage.range)) throw invalid("Observation record range does not match coverage"); const result = await this.putRecord(state, paths, draft); records.push(result.record); }
      if (input.coverage.disposition === "observed" && records.length === 0) throw invalid("Observed coverage requires an observation record");
      const coverage: ObservationCoverage = { ...input.coverage, schemaVersion: KNOWLEDGE_SCHEMA_VERSION, revisionId: revisionId(), groupRevisionIds: records.map(record => record.revisionId), recordedAt: now() }; validateCoverage(coverage);
      const groupPath = join(paths.groups, `${coverage.id}-${coverage.revisionId}.json`); await durableAtomicWriteJson(groupPath, { schemaVersion: KNOWLEDGE_SCHEMA_VERSION, coverage, records: records.map(record => ({ id: record.id, revisionId: record.revisionId })) }, 0o600);
      state.coverage[coverage.id] = coverage; return { records, coverage, stateRevision: state.stateRevision + 1 };
    });
  }
  async setCoverage(input: CoverageUpdateInput): Promise<{ coverage: ObservationCoverage; stateRevision: number }> {
    return this.mutate("knowledge.observation.coverage", input.commandId, input, async (state, paths) => {
      if (input.expectedConfigRevision !== undefined && state.config.revision !== input.expectedConfigRevision) throw conflict("Observation configuration changed while inference was running");
      if (this.excludedRange(state, input.coverage.range) && input.coverage.disposition !== "excluded") throw conflict("Observation range is excluded"); const current = state.coverage[input.coverage.id];
      if (current && !sameRange(current.range, input.coverage.range)) throw conflict("Observation coverage identity changed");
      if (input.expectedRevision !== undefined && current?.revisionId !== input.expectedRevision) throw conflict("Observation coverage revision is stale");
      if (current && ["observed", "empty", "excluded", "unavailable"].includes(current.disposition)) {
        if (current.disposition !== input.coverage.disposition || current.groupRevisionIds.join("\0") !== input.coverage.groupRevisionIds.join("\0")) throw conflict("Terminal observation coverage cannot be replaced");
        return { coverage: current, stateRevision: state.stateRevision };
      }
      if (input.coverage.disposition === "observed") {
        if (!input.coverage.groupRevisionIds.length) throw invalid("Observed coverage requires committed group records");
        for (const revision of input.coverage.groupRevisionIds) {
          const found = Object.entries(state.records).find(([, head]) => head.revisionIds.includes(revision));
          if (!found) throw invalid("Observed coverage references an unknown record revision");
          const record = await this.readRecord(paths, found[0], revision);
          if (record.kind !== "observation" || !sameRange(record.content.range, input.coverage.range)) throw invalid("Observed coverage references a record from another input range");
        }
      }
      const coverage: ObservationCoverage = { ...input.coverage, schemaVersion: KNOWLEDGE_SCHEMA_VERSION, revisionId: revisionId(), recordedAt: now() }; validateCoverage(coverage); state.coverage[coverage.id] = coverage; return { coverage, stateRevision: state.stateRevision + 1 };
    });
  }
  async reflect(commandId: string, sessionId: string, sourceRevisionIds: string[], text: string): Promise<KnowledgeMutationResult> {
    safeId(sessionId, "session id");
    if (!text || text.length > 30_000 || sourceRevisionIds.length === 0 || sourceRevisionIds.length > 100 || new Set(sourceRevisionIds).size !== sourceRevisionIds.length) throw invalid("Reflection is bounded and requires distinct source revisions");
    return this.mutate("knowledge.reflect", commandId, { sessionId, sourceRevisionIds, text }, async (state, paths) => {
      const evidence: KnowledgeEvidenceRef[] = []; const relations: KnowledgeRecord["relations"] = []; let branchId: string | undefined;
      const sources: KnowledgeRecord[] = [];
      for (const revision of sourceRevisionIds) {
        let source: KnowledgeRecord | undefined;
        for (const [id, head] of Object.entries(state.records)) if (head.revisionIds.includes(revision)) { source = await this.readRecord(paths, id, revision); break; }
        if (!source || source.kind !== "observation" || source.content.range.sessionId !== sessionId) throw invalid("Reflection source is not an observation in this session");
        if (state.suppressions[source.id]?.excluded || this.excludedRange(state, source.content.range)) throw conflict("Reflection source is excluded");
        if (branchId !== undefined && branchId !== source.content.range.branchId) throw invalid("Reflection sources must share a branch");
        branchId = source.content.range.branchId;
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
      const existing = state.records[reflectionId] ? await this.currentRecord(state, paths, reflectionId) : null;
      if (existing && existing.kind !== "note") throw conflict("Reflection identity is occupied by another record kind");
      const record: KnowledgeRecordDraft & { kind: "note" } = { id: reflectionId, ...(existing ? { createdAt: existing.createdAt } : {}), kind: "note", scope: "personal", provenance: { actor: "agent", source: `reflection:${sourceSetDigest}`, sessionId, ...(branchId === undefined ? {} : { branchId }), evidence }, relations, content: { title: "Session reflection", body: text, role: "synthesis", confirmed: false } };
      return this.putRecord(state, paths, record, existing?.revisionId);
    });
  }
  async correct(commandId: string, recordId: string, expectedRevision: string, replacement: KnowledgeRecordDraft, relation: KnowledgeRecord["relations"][number]): Promise<KnowledgeMutationResult> { return this.mutate("knowledge.correction", commandId, { recordId, expectedRevision, replacement, relation }, async (state, paths) => { const current = await this.currentRecord(state, paths, recordId); if (!current || current.revisionId !== expectedRevision) throw conflict("Knowledge record revision is stale"); if (relation.recordId !== recordId || relation.revisionId !== expectedRevision || (relation.type !== "corrects" && relation.type !== "supersedes")) throw invalid("Correction relation must identify the replaced revision"); return this.putRecord(state, paths, { ...replacement, id: recordId, createdAt: current.createdAt, relations: [...replacement.relations, relation] }, expectedRevision); }); }
  async setScopeExclusion(commandId: string, scope: { sessionId?: string; branchId?: string; projectId?: string }, excluded: boolean, reason?: string): Promise<{ excluded: boolean; stateRevision: number }> {
    if (!scope.sessionId && !scope.projectId) throw invalid("Scope exclusion requires a session or project"); return this.mutate("knowledge.scope-exclusion", commandId, { scope, excluded, reason }, async state => { const key = scope.sessionId ? (scope.branchId ? `branch:${scope.sessionId}:${scope.branchId}` : `session:${scope.sessionId}`) : `project:${scope.projectId}`; state.scopeExclusions[key] = { ...scope, excluded, ...(reason === undefined ? {} : { reason }), updatedAt: now() }; return { excluded, stateRevision: state.stateRevision + 1 }; });
  }
  async setExclusion(commandId: string, recordId: string, excluded: boolean, expectedRevision?: string, reason?: string): Promise<{ recordId: string; excluded: boolean; stateRevision: number }> { return this.mutate("knowledge.exclusion", commandId, { recordId, excluded, expectedRevision, reason }, async (state, paths) => { const current = await this.currentRecord(state, paths, recordId); if (!current) throw conflict("Knowledge record does not exist"); if (expectedRevision !== undefined && expectedRevision !== current.revisionId) throw conflict("Knowledge record revision is stale"); state.suppressions[recordId] = { excluded, forgotten: false, ...(reason === undefined ? {} : { reason }), updatedAt: now() }; return { recordId, excluded, stateRevision: state.stateRevision + 1 }; }); }
  async forget(commandId: string, recordId: string, reason: string, expectedRevision?: string): Promise<KnowledgeForgetResult> {
    if (!reason || reason.length > 1_000) throw invalid("Forget reason is required and bounded");
    let forgottenRevisions: string[] = [];
    return this.mutate("knowledge.forget", commandId, { recordId, reason, expectedRevision }, async (state, paths) => {
      const history = state.records[recordId]; const current = history ? await this.currentRecord(state, paths, recordId) : null; if (!current) throw conflict("Knowledge record does not exist"); if (expectedRevision !== undefined && expectedRevision !== current.revisionId) throw conflict("Knowledge record revision is stale");
      forgottenRevisions = [...history!.revisionIds];
      state.recordCleanup = [...(state.recordCleanup ?? []), ...forgottenRevisions.map(revisionId => ({ recordId, revisionId }))];
      // The tombstone, object cleanup intent, and derivative redactions are
      // published atomically before any canonical revision is removed.
      for (const revision of history!.revisionIds) { const record = await this.readRecord(paths, recordId, revision); state.cleanup.push(...recordObjectHashes(record)); }
      delete state.records[recordId]; state.suppressions[recordId] = { excluded: true, forgotten: true, reason, updatedAt: now() }; state.cleanup = [...new Set(state.cleanup)];
      for (const receipt of Object.values(state.receipts)) if (receipt.recordIds.includes(recordId)) { receipt.recordIds = []; receipt.result = { kind: "value", value: null }; receipt.invalidated = true; }
      // Derivative references are redacted and hidden, rather than leaving a
      // current unsupported claim available after its evidence is forgotten.
      const scrubbedRecordIds = new Set<string>();
      for (const [id, head] of Object.entries(state.records)) { const derivative = await this.readRecord(paths, id, head.latestRevisionId); const scrubbed = scrubReferences(derivative, recordId); if (scrubbed) { await durableAtomicWriteJson(this.recordPath(paths, id, scrubbed.revisionId), scrubbed, 0o600); state.records[id] = { latestRevisionId: scrubbed.revisionId, revisionIds: [...head.revisionIds, scrubbed.revisionId] }; state.suppressions[id] = { excluded: true, forgotten: false, reason: "Dependent evidence was forgotten", updatedAt: now() }; scrubbedRecordIds.add(id); } }
      // A receipt is another replay path. Invalidate receipts for every
      // derivative rewritten by the forget, not only the forgotten source.
      for (const receipt of Object.values(state.receipts)) if (receipt.recordIds.some(id => scrubbedRecordIds.has(id))) { receipt.recordIds = []; receipt.result = { kind: "value", value: null }; receipt.invalidated = true; }
      return { forgotten: true, recordId, stateRevision: state.stateRevision + 1 };
    }, async (state, paths) => {
      // A failed post-commit deletion is safe: the state no longer references
      // these files. Pending paths remain durable for reconcile() to retry.
      const pending = [...(state.recordCleanup ?? [])];
      const remaining: PendingRecordCleanup[] = [];
      for (const item of pending) {
        try { await durableRemove(this.recordPath(paths, item.recordId, item.revisionId)); }
        catch { remaining.push(item); }
      }
      state.recordCleanup = remaining;
      if (remaining.length !== pending.length) { state.stateRevision += 1; await this.save(paths, state); }
    });
  }
  async importCheckpoint(planHash: string): Promise<KnowledgeImportCheckpoint | null> {
    if (!OBJECT_HASH.test(planHash)) throw invalid("Invalid import plan hash");
    const paths = await this.paths(false); const loaded = await this.load(paths, false);
    return loaded.state.imports?.[planHash] ? structuredClone(loaded.state.imports[planHash]) : null;
  }
  async beginImport(commandId: string, planHash: string, plannedRecordIds: string[]): Promise<KnowledgeImportCheckpoint> {
    if (!OBJECT_HASH.test(planHash) || plannedRecordIds.length > 20_000 || plannedRecordIds.some(id => { try { assertKnowledgeId(id, "import record id"); return false; } catch { return true; } })) throw invalid("Invalid import batch");
    const unique = [...new Set(plannedRecordIds)]; if (unique.length !== plannedRecordIds.length) throw invalid("Import batch contains duplicate record IDs");
    return this.mutate("knowledge.import.begin", commandId, { planHash, plannedRecordIds: unique }, async state => {
      state.imports ??= {};
      const existing = state.imports[planHash];
      if (existing && (existing.plannedRecordIds.length !== unique.length || existing.plannedRecordIds.some((id, index) => id !== unique[index]))) throw conflict("Import plan membership changed");
      const checkpoint = existing ?? { planHash, plannedRecordIds: unique, completedRecordIds: [], updatedAt: now() };
      state.imports[planHash] = checkpoint; return structuredClone(checkpoint);
    });
  }
  async markImportRecord(commandId: string, planHash: string, recordId: string): Promise<KnowledgeImportCheckpoint> {
    if (!OBJECT_HASH.test(planHash)) throw invalid("Invalid import plan hash"); assertKnowledgeId(recordId, "import record id");
    return this.mutate("knowledge.import.progress", commandId, { planHash, recordId }, async state => {
      const checkpoint = state.imports?.[planHash]; if (!checkpoint || !checkpoint.plannedRecordIds.includes(recordId)) throw conflict("Import record is outside the planned batch");
      if (!checkpoint.completedRecordIds.includes(recordId)) checkpoint.completedRecordIds.push(recordId); checkpoint.updatedAt = now(); return structuredClone(checkpoint);
    });
  }

  async putObject(bytes: Uint8Array, mediaType: string): Promise<KnowledgeObjectRef> {
    if (bytes.byteLength > OBJECT_MAX_BYTES || !mediaType || mediaType.length > 160) throw invalid("Content object is too large or has an invalid media type"); const hash = createHash("sha256").update(bytes).digest("hex");
    return this.mutex.run(async () => { const paths = await this.paths(true); const initialized = await this.load(paths, true); if (!initialized.present) await this.save(paths, initialized.state); const path = join(paths.objects, hash); const existing = await readSecureBytes(path, OBJECT_MAX_BYTES); if (existing) { if (existing.byteLength !== bytes.byteLength || createHash("sha256").update(existing).digest("hex") !== hash) throw new KnowledgeStoreError("invalid", "Existing knowledge object bytes do not match their identity"); return { hash, mediaType, bytes: bytes.byteLength }; } await durableAtomicWriteBytes(path, bytes); return { hash, mediaType, bytes: bytes.byteLength }; });
  }
  private async assertObject(paths: StorePaths, ref: KnowledgeObjectRef): Promise<void> { validateObjectRef(ref); const bytes = await readSecureBytes(join(paths.objects, ref.hash), OBJECT_MAX_BYTES); if (!bytes || bytes.byteLength !== ref.bytes || createHash("sha256").update(bytes).digest("hex") !== ref.hash) throw conflict("Referenced knowledge object bytes are not durably captured"); }
  async readObject(ref: KnowledgeObjectRef): Promise<Uint8Array | null> {
    validateObjectRef(ref); const paths = await this.paths(false); const loaded = await this.load(paths, false); if (!loaded.present) return null;
    // Object hashes are not a public directory index. Require a citation from
    // a retained, unsuppressed record before exposing bytes.
    let authorized = false;
    let scannedRevisions = 0;
    let scannedBytes = 0;
    for (const [id, head] of Object.entries(loaded.state.records)) {
      if (scannedRevisions >= MAX_SCAN_RECORDS || scannedBytes >= MAX_SCAN_BYTES) break;
      const candidate = await this.readRecord(paths, id, head.latestRevisionId);
      scannedBytes += Buffer.byteLength(JSON.stringify(candidate), "utf8");
      if (this.recordExcluded(loaded.state, candidate)) continue;
      for (const revision of head.revisionIds) {
        if (scannedRevisions >= MAX_SCAN_RECORDS || scannedBytes >= MAX_SCAN_BYTES) break;
        const revisionRecord = await this.readRecord(paths, id, revision);
        scannedRevisions += 1;
        scannedBytes += Buffer.byteLength(JSON.stringify(revisionRecord), "utf8");
        if (this.recordExcluded(loaded.state, revisionRecord)) continue;
        if (recordObjectHashes(revisionRecord).includes(ref.hash)) { authorized = true; break; }
      }
      if (authorized) break;
    }
    const bytes = await readSecureBytes(join(paths.objects, ref.hash), OBJECT_MAX_BYTES); if (!bytes) return null;
    if (bytes.byteLength !== ref.bytes || createHash("sha256").update(bytes).digest("hex") !== ref.hash) throw new KnowledgeStoreError("invalid", "Knowledge object failed hash or size verification");
    return authorized ? bytes : null;
  }
  async reconcile(): Promise<KnowledgeReconcileResult> {
    return this.mutex.run(async () => {
      const paths = await this.paths(false); const loaded = await this.load(paths, false);
      if (!loaded.present) return { removedObjects: [], pendingObjects: [], stateRevision: 0 };
      const state = loaded.state;
      const referenced = new Set<string>();
      for (const [id, head] of Object.entries(state.records)) for (const revision of head.revisionIds) for (const hash of await this.recordObjectHashes(paths, id, revision)) referenced.add(hash);
      const removedObjects: string[] = []; const pendingObjects: string[] = [];
      for (const hash of state.cleanup) {
        if (referenced.has(hash)) continue;
        try { await durableRemove(join(paths.objects, hash)); removedObjects.push(hash); } catch { pendingObjects.push(hash); }
      }
      const pendingRecords: PendingRecordCleanup[] = [];
      for (const item of state.recordCleanup ?? []) {
        try { await durableRemove(this.recordPath(paths, item.recordId, item.revisionId)); } catch { pendingRecords.push(item); }
      }
      if (removedObjects.length || pendingRecords.length !== (state.recordCleanup?.length ?? 0)) {
        state.cleanup = pendingObjects; state.recordCleanup = pendingRecords; state.stateRevision += 1; await this.save(paths, state);
      }
      return { removedObjects, pendingObjects, stateRevision: state.stateRevision };
    });
  }
  private async recordObjectHashes(paths: StorePaths, id: string, revision: string): Promise<string[]> { return recordObjectHashes(await this.readRecord(paths, id, revision)); }
  async coverage(id: string): Promise<ObservationCoverage | null> { safeId(id, "coverage id"); const paths = await this.paths(false); return (await this.load(paths, false)).state.coverage[id] ?? null; }

  /** Read committed coverage identities for recovery. The observation owner
   * uses these manifests to advance only beyond an exact covered prefix after
   * restart or changed coalescing boundaries. */
  async observationCoverageForScope(sessionId: string, branchId?: string, projectId?: string): Promise<ObservationCoverage[]> {
    safeId(sessionId, "session id");
    if (branchId !== undefined) safeId(branchId, "branch id");
    if (projectId !== undefined) assertKnowledgeProjectId(projectId, "project id");
    const paths = await this.paths(false); const state = (await this.load(paths, false)).state;
    return Object.values(state.coverage).filter(coverage => coverage.range.sessionId === sessionId
      && coverage.range.branchId === branchId && coverage.range.projectId === projectId
      && ["observed", "empty", "excluded", "unavailable"].includes(coverage.disposition));
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
