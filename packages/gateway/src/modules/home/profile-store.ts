import { createHash, randomBytes, randomUUID } from "node:crypto";
import { constants } from "node:fs";
import { lstat, mkdir, open, rename, rm } from "node:fs/promises";
import { join } from "node:path";
import type { ResourceRoot } from "../../kernel/resources/resource-root.js";
import { GatewayError } from "../../errors.js";
import { AsyncMutex } from "../../util/async-mutex.js";
import { durableAtomicWriteJson, durableRemove, syncDurably } from "../../foundation/durable-json.js";
import { readSecureJson, SecureJsonFileError } from "../../foundation/secure-json.js";
import { DEFAULT_PROFILE_NOTE_CONFIG, PROFILE_NOTE_SCHEMA_VERSION, type ProfileNoteConfig, type ProfileNoteListRequest, type ProfileNoteListResponse, type ProfileNoteEvidenceRef, type ProfileNoteRecord, type ProfileNoteRecordDraft, type ProfileNoteNoteMutationRequest, validateProfileNoteConfig, validateProfileNoteRecord, assertProfileNoteId } from "./profile-note-contract.js";
import { ProfileCatalog, type ProfileTable } from "./profile-catalog.js";
import type { SQLInputValue } from "node:sqlite";
import { jsonNodeCount } from "../../protocol/json-budget.js";
import { profileNoteRow, type ProfileNoteRow, type ProfileRecordRow, assertProfileCapacity } from "./profile-placement.js";
import { carryNoteMarks, storedNoteContent, partitionProfileNotes, profileBackupRetirements, redactProfileBackups, readProfileOperation, type ProfilePartitionAudit, type ProfilePartitionRequest, type ProfilePartitionResult } from "./profile-notes.js";

const STATE_MAX_BYTES = 4 * 1_048_576;
const RECORD_MAX_BYTES = 2 * 1_048_576;
const RECEIPT_LIMIT = 256;
export const PROFILE_STORAGE_VERSION = 1 as const;
const CATALOG_PAGE_BYTES = 750_000;
const CATALOG_PAGE_NODES = 24_000;

/** Leave room for RPC/tool envelopes and native JSON decoder admission. */
class ProfilePageBudget {
  private bytes = 0;
  private nodes = 0;
  admit(value: unknown): boolean {
    const bytes = Buffer.byteLength(JSON.stringify(value));
    const nodes = jsonNodeCount(value, CATALOG_PAGE_NODES);
    if (this.bytes === 0 && (bytes > CATALOG_PAGE_BYTES || nodes > CATALOG_PAGE_NODES)) throw invalid("Profile entry exceeds its bounded page size; read the exact record separately");
    if (this.bytes + bytes > CATALOG_PAGE_BYTES || this.nodes + nodes > CATALOG_PAGE_NODES) return false;
    this.bytes += bytes; this.nodes += nodes; return true;
  }
}

type RecordHead = {
  latestRevisionId: string; revisionIds: string[];
  kind: ProfileNoteRecord["kind"]; scope: ProfileNoteRecord["scope"];
  sortAt: number;
  createdAt: string; updatedAt: string;
  recordRefs: string[]; objectHashes: string[];
  sessionId?: string; branchId?: string;
  profileRow?: ProfileNoteRow | null;
};
type Suppression = { excluded: boolean; forgotten: boolean; reason?: string; updatedAt: string };
type ScopeExclusion = { sessionId?: string; branchId?: string; projectId?: string; excluded: boolean; reason?: string; updatedAt: string };
type PendingRecordCleanup = { recordId: string; revisionId: string };
type StoredReceipt = { operation: string; requestHash: string; createdAt: string; result: ReceiptResult; recordIds: string[]; invalidated?: boolean };
type ReceiptResult = { kind: "record"; recordId: string; revisionId: string; stateRevision: number } | { kind: "value"; value: unknown };
interface ProfileState {
  schemaVersion: typeof PROFILE_NOTE_SCHEMA_VERSION;
  stateRevision: number;
  catalogID?: string;
  catalog?: ProfileCatalog;
  records: ProfileTable<RecordHead>;
  suppressions: ProfileTable<Suppression>;
  scopeExclusions: ProfileTable<ScopeExclusion>;
  cleanup: ProfileTable<true>;
  recordCleanup: ProfileTable<PendingRecordCleanup>;
  receipts: ProfileTable<StoredReceipt>;
  config: ProfileNoteConfig;
  profileSorting?: string;
}
type CatalogControl = Pick<ProfileState, "schemaVersion" | "stateRevision" | "catalogID" | "config" | "profileSorting">;
export interface ProfileSortingState { version: string; deferred: boolean }
function profileSortingVersion(rows: ReadonlyArray<{ id: string }>): string {
  return createHash("sha256").update(rows.map(row => row.id).sort().join("\n")).digest("hex");
}

export type ProfileStateFailure = "unsafe" | "invalid" | "newer";
export class ProfileStoreError extends Error {
  constructor(readonly kind: ProfileStateFailure, message: string) { super(message); this.name = "ProfileStoreError"; }
}

export interface ProfileMutationResult { record: ProfileNoteRecord; stateRevision: number; }
export interface ProfileForgetResult { forgotten: true; recordId: string; stateRevision: number; }
export interface ProfileReconcileResult { removedObjects: string[]; pendingObjects: string[]; stateRevision: number; }
/** Committed-change notification. `recordIds` lets a client refresh only the
 * rows a mutation touched instead of replaying its first page. */
export interface ProfileChange { stateRevision: number; recordIds?: string[] }

function conflict(message: string): GatewayError { return new GatewayError("conflict", message); }
function invalid(message: string): GatewayError { return new GatewayError("invalid_request", message); }
function requestHash(operation: string, request: unknown): string { return createHash("sha256").update(operation).update("\0").update(JSON.stringify(request)).digest("hex"); }
function now(): string { return new Date().toISOString(); }
function revisionId(): string { return randomUUID(); }
function cleanupKey(item: PendingRecordCleanup): string { return JSON.stringify([item.recordId, item.revisionId]); }
function recordId(): string { return randomUUID(); }
function safeId(value: string, label: string): void { assertProfileNoteId(value, label); if (value === "." || value === "..") throw new Error(`Invalid ${label}`); }

async function safeDirectory(path: string, create: boolean): Promise<void> {
  if (create) {
    try { await mkdir(path, { recursive: true, mode: 0o700 }); }
    catch { throw new ProfileStoreError("unsafe", `Profile directory cannot be created: ${path}`); }
  }
  let info;
  try { info = await lstat(path); }
  catch { throw new ProfileStoreError("unsafe", `Profile directory is unavailable: ${path}`); }
  if (!info.isDirectory() || info.isSymbolicLink() || info.uid !== process.getuid?.() || (info.mode & 0o777) !== 0o700) throw new ProfileStoreError("unsafe", "Profile state directory must be an owner-only real directory");
}

function emptyState(): CatalogControl {
  return { schemaVersion: PROFILE_NOTE_SCHEMA_VERSION, stateRevision: 0, config: structuredClone(DEFAULT_PROFILE_NOTE_CONFIG) };
}
function catalogState(control: CatalogControl, catalog?: ProfileCatalog): ProfileState {
  return { ...control, ...(catalog ? { catalog } : {}),
    records: catalog?.table<RecordHead>("records") ?? new Map(),
    suppressions: catalog?.table<Suppression>("suppressions") ?? new Map(),
    scopeExclusions: catalog?.table<ScopeExclusion>("scopeExclusions") ?? new Map(),
    receipts: catalog?.table<StoredReceipt>("receipts") ?? new Map(),
    cleanup: catalog?.table<true>("cleanup") ?? new Map(),
    recordCleanup: catalog?.table<PendingRecordCleanup>("recordCleanup") ?? new Map(),
  };
}
function headFor(record: ProfileNoteRecord, revisions: string[], retainedObjects: string[] = []): RecordHead {
  const evidence = [...record.provenance.evidence, ...(record.content.fields ?? []).flatMap(field => field.evidence), ...(record.content.contraryEvidence ?? [])];
  return { latestRevisionId: record.revisionId, revisionIds: revisions, kind: record.kind, scope: record.scope,
    createdAt: record.createdAt, updatedAt: record.updatedAt, sortAt: Date.parse(record.updatedAt),
    recordRefs: [...new Set([...record.relations.map(relation => relation.recordId), ...evidence.flatMap(ref => ref.recordId ? [ref.recordId] : [])])],
    objectHashes: [...new Set([...retainedObjects, ...recordObjectHashes(record)])],
    ...(record.provenance.sessionId ? { sessionId: record.provenance.sessionId } : {}),
    ...(record.provenance.branchId ? { branchId: record.provenance.branchId } : {}),
    profileRow: profileNoteRow(record),
  };
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
  } catch { throw invalid("Profile cursor is invalid for this query; reload the first page"); }
}
function recordObjectHashes(record: ProfileNoteRecord): string[] {
  return [...record.provenance.evidence, ...(record.content.fields ?? []).flatMap(field => field.evidence), ...(record.content.contraryEvidence ?? [])].flatMap(evidence => evidence.objectHash ? [evidence.objectHash] : []);
}
interface StorePaths { root: string; state: string; objects: string; records: string; present: boolean; fresh: boolean; }

/** Canonical owner: immutable record/object files are data; the catalog is the
 * transactional authority for heads, coverage, suppression and receipts. */
interface ProfileWorkspace extends Pick<ResourceRoot, "describe"> {
  featureInitialized(feature: "profile"): Promise<boolean>;
  markFeatureInitialized(feature: "profile"): Promise<void>;
}

export class ProfileStore {
  private static readonly workspaceLocks = new WeakMap<ProfileWorkspace, AsyncMutex>();
  private readonly mutex: AsyncMutex;
  /** Command-scoped summary generations that are already in flight. */
  constructor(private readonly workspace: ProfileWorkspace) {
    this.mutex = ProfileStore.workspaceLocks.get(workspace) ?? new AsyncMutex(); ProfileStore.workspaceLocks.set(workspace, this.mutex);
  }

  private async paths(create: boolean): Promise<StorePaths> {
    const descriptor = await this.workspace.describe();
    if (!descriptor.available) throw new ProfileStoreError("unsafe", descriptor.reason === "closed" ? "Tron workspace is closed" : "Tron workspace is unavailable");
    const stateRoot = join(descriptor.root, "state");
    for (const retired of ["knowledge", "knowledge.retiring"]) {
      if (await lstat(join(stateRoot, retired)).catch(error => { if (error.code === "ENOENT") return undefined; throw error; })) throw new ProfileStoreError("invalid", "Offline Knowledge retirement is required before Profile can open");
    }
    let stateRootPresent = true;
    try { await safeDirectory(stateRoot, false); } catch (error) {
      if (!(error instanceof ProfileStoreError) || !error.message.includes("unavailable")) throw error;
      stateRootPresent = false;
      if (create) { await safeDirectory(stateRoot, true); stateRootPresent = true; }
    }
    const root = join(stateRoot, "profile");
    if (!stateRootPresent) return { root, state: join(root, "state.json"), objects: join(root, "objects"), records: join(root, "records"), present: false, fresh: !(await this.workspace.featureInitialized("profile")) };
    let present = true;
    let fresh = false;
    try { await safeDirectory(root, false); } catch (error) {
      if (!(error instanceof ProfileStoreError) || !error.message.includes("unavailable")) throw error;
      present = false;
      fresh = !(await this.workspace.featureInitialized("profile"));
      if (create) {
        // A namespace that was initialized once and is gone now is lost state,
        // never permission to create an empty corpus in its place.
        if (!fresh) throw new ProfileStoreError("invalid", "Initialized knowledge state is missing");
        return await this.initializeNamespace(stateRoot, root);
      }
    }
    const paths = { root, state: join(root, "state.json"), objects: join(root, "objects"), records: join(root, "records"), present, fresh };
    if (!present) return paths;
    const marker = join(root, "initialized.json");
    const markerRead = await readSecureJson<unknown>(marker, 128);
    if (!markerRead.present) {
      if (!create) throw new ProfileStoreError("invalid", "Profile namespace exists without initialization evidence");
      // Only a namespace this owner never published (foreign or damaged) reaches
      // here: initialization publishes the marker with the whole namespace, so a
      // writer that can already see a state manifest restores its evidence.
      await safeDirectory(paths.objects, true); await safeDirectory(paths.records, true);
      await durableAtomicWriteJson(marker, { version: 1 }, 0o600);
      await this.workspace.markFeatureInitialized("profile");
    } else if (JSON.stringify(markerRead.value) !== JSON.stringify({ version: 1 })) throw new ProfileStoreError("invalid", "Invalid knowledge initialization record");
    await safeDirectory(paths.objects, false); await safeDirectory(paths.records, false);
    return { ...paths, fresh };
  }

  /** Publish one fresh namespace atomically: build it beside its final name and
   * rename it into place. Reads project state without the store mutex, so a
   * namespace that became visible before its own evidence did is
   * indistinguishable from a damaged corpus, and `paths(false)` refuses exactly
   * that. Nothing is published until the whole namespace is durable, so a failure
   * while building it leaves no namespace and the next deliberate mutation can
   * initialize one. */
  private async initializeNamespace(stateRoot: string, root: string): Promise<StorePaths> {
    const staging = `${root}.${process.pid}.${randomBytes(6).toString("hex")}.tmp`;
    const staged: StorePaths = { root: staging, state: join(staging, "state.json"), objects: join(staging, "objects"), records: join(staging, "records"), present: true, fresh: true };
    try {
      await safeDirectory(staged.objects, true); await safeDirectory(staged.records, true);
      await durableAtomicWriteJson(join(staging, "initialized.json"), { version: 1 }, 0o600);
      await this.createCatalog(staged);
      await rename(staging, root);
    } catch (error) { await rm(staging, { recursive: true, force: true }).catch(() => {}); throw error; }
    const stateDirectory = await open(stateRoot, "r");
    try { await syncDurably(stateDirectory); } finally { await stateDirectory.close(); }
    await this.workspace.markFeatureInitialized("profile");
    return { root, state: join(root, "state.json"), objects: join(root, "objects"), records: join(root, "records"), present: true, fresh: true };
  }
  private async load(paths: StorePaths, writable: boolean): Promise<{ state: ProfileState; present: boolean }> {
    let read;
    try { read = await readSecureJson<unknown>(paths.state, STATE_MAX_BYTES); }
    catch (error) { if (error instanceof SecureJsonFileError) throw new ProfileStoreError(error.kind === "unsafe" ? "unsafe" : "invalid", error.message); throw error; }
    if (!read.present) {
      if (!paths.fresh) throw new ProfileStoreError("invalid", "Initialized knowledge state is missing");
      if (!writable) return { state: catalogState(emptyState()), present: false };
      await this.createCatalog(paths);
      return this.load(paths, true);
    }
    if (!read.value || typeof read.value !== "object" || Array.isArray(read.value)) throw new ProfileStoreError("invalid", "Invalid Profile state manifest");
    const manifest = read.value as { storageVersion?: number; schemaVersion?: number; catalogID?: string };
    if (manifest.storageVersion !== PROFILE_STORAGE_VERSION || manifest.schemaVersion !== PROFILE_NOTE_SCHEMA_VERSION
      || typeof manifest.catalogID !== "string" || !/^[0-9a-f-]{36}$/.test(manifest.catalogID)) {
      throw new ProfileStoreError("invalid", "Unsupported Profile catalog manifest");
    }
    const { catalog, control } = await this.openCatalog(paths, manifest.catalogID, !writable);
    return { state: catalogState(control, catalog), present: true };
  }

  /** Open only the current Profile format. The offline converter, never this
   * runtime, publishes the namespace. Callers own the returned catalog's close. */
  private async openCatalog(paths: StorePaths, catalogID: string, readOnly: boolean): Promise<{ catalog: ProfileCatalog; control: CatalogControl }> {
    const path = join(paths.root, `catalog-${catalogID}.sqlite`);
    const before = await this.catalogFile(path);
    await this.catalogFile(`${path}-journal`, true);
    let catalog: ProfileCatalog | undefined;
    try {
      catalog = new ProfileCatalog(path, readOnly);
      const after = await this.catalogFile(path);
      if (before!.ino !== after!.ino || before!.dev !== after!.dev) throw new ProfileStoreError("unsafe", "Profile catalog changed while opening");
      const control = catalog.control<CatalogControl>();
      if (control.catalogID !== catalogID || control.schemaVersion !== PROFILE_NOTE_SCHEMA_VERSION || !Number.isSafeInteger(control.stateRevision) || control.stateRevision < 0) throw new ProfileStoreError("invalid", "Invalid Profile catalog control");
      if (control.profileSorting !== undefined && (typeof control.profileSorting !== "string" || !/^[a-f0-9]{64}$/.test(control.profileSorting))) throw new ProfileStoreError("invalid", "Invalid profile sorting decision");
      control.config = validateProfileNoteConfig(control.config);
      return { catalog, control };
    } catch (error) {
      catalog?.close();
      if (error instanceof ProfileStoreError) throw error;
      throw new ProfileStoreError("invalid", error instanceof Error ? error.message : "Profile catalog is unavailable");
    }
  }
  private async catalogFile(path: string, optional = false) {
    let info;
    try { info = await lstat(path); }
    catch (error) {
      if (optional && (error as NodeJS.ErrnoException).code === "ENOENT") return undefined;
      throw new ProfileStoreError("invalid", "Initialized Profile catalog is missing");
    }
    if (!info.isFile() || info.isSymbolicLink() || info.uid !== process.getuid?.() || (info.mode & 0o077) !== 0) throw new ProfileStoreError("unsafe", "Profile catalog must be an owner-only regular file");
    return info;
  }
  private control(state: ProfileState): CatalogControl {
    return { schemaVersion: state.schemaVersion, stateRevision: state.stateRevision, ...(state.catalogID ? { catalogID: state.catalogID } : {}),
      config: state.config, ...(state.profileSorting ? { profileSorting: state.profileSorting } : {}) };
  }
  private async save(_paths: StorePaths, state: ProfileState): Promise<void> {
    if (!state.catalog) throw new ProfileStoreError("invalid", "Profile catalog was not initialized");
    state.catalog.setControl(this.control(state));
    state.catalog.commit();
  }
  /** Mutex-free read projection. Each catalog query sees committed state, and
   * the connection closes as soon as the action settles, so a reader never
   * holds a lock a mutation would have to wait for. Page selection resolves its
   * heads synchronously, before any body read. Privacy checks made after a body
   * read can observe a newer commit than those heads; that can only hide a
   * record excluded or forgotten meanwhile, never reveal one. Callers that read
   * revision bodies use `readRecordOrRemoved`, which reports a body a concurrent
   * forget removed as unavailable instead of as a damaged corpus. */
  private async readState<T>(action: (state: ProfileState, paths: StorePaths, present: boolean) => T | Promise<T>): Promise<T> {
    const paths = await this.paths(false);
    const loaded = await this.load(paths, false);
    try { return await action(loaded.state, paths, loaded.present); }
    finally { loaded.state.catalog?.close(); }
  }

  /** Revision bodies are immutable, and a forget deletes the head in its
   * tombstone transaction before its files. A reader holding an older snapshot
   * can therefore meet a revision that is no longer committed; that is removal.
   * A revision its own snapshot still commits is a damaged corpus and fails. */
  private async readRecordOrRemoved(paths: StorePaths, state: ProfileState, id: string, revision: string): Promise<ProfileNoteRecord | undefined> {
    try { return await this.readRecord(paths, id, revision); }
    catch (error) {
      if (!(error instanceof ProfileStoreError) || !error.message.startsWith("Record revision is missing")) throw error;
      const committed = await this.readState(fresh => fresh.records.get(id)?.revisionIds.includes(revision) ?? false);
      if (committed) throw error;
      return undefined;
    }
  }

  private async createCatalog(paths: StorePaths): Promise<void> {
    const catalogID = randomUUID();
    const path = join(paths.root, `catalog-${catalogID}.sqlite`);
    const file = await open(path, "wx", 0o600); await file.close();
    let catalog: ProfileCatalog | undefined;
    let prepared = false;
    try {
      catalog = new ProfileCatalog(path, false, true);
      catalog.begin();
      catalog.setControl({ ...emptyState(), catalogID });
      catalog.commit();
      prepared = true;
    } finally {
      catalog?.close();
      if (!prepared) await durableRemove(path).catch(() => {});
    }
    const durable = await open(path, constants.O_RDONLY | constants.O_NOFOLLOW);
    try { await syncDurably(durable); } finally { await durable.close(); }
    await durableAtomicWriteJson(paths.state, { schemaVersion: PROFILE_NOTE_SCHEMA_VERSION, storageVersion: PROFILE_STORAGE_VERSION, catalogID }, 0o600);
  }
  private recordPath(paths: StorePaths, id: string, revision: string): string { safeId(id, "record id"); safeId(revision, "record revision"); return join(paths.records, id, `${revision}.json`); }
  private async readRecord(paths: StorePaths, id: string, revision: string): Promise<ProfileNoteRecord> {
    try { await safeDirectory(join(paths.records, id), false); }
    catch (error) { if (error instanceof ProfileStoreError && error.message.includes("unavailable")) throw new ProfileStoreError("invalid", `Record revision is missing: ${id}/${revision}`); throw error; }
    let value;
    try { value = await readSecureJson<unknown>(this.recordPath(paths, id, revision), RECORD_MAX_BYTES); }
    catch (error) { if (error instanceof SecureJsonFileError) throw new ProfileStoreError(error.kind === "unsafe" ? "unsafe" : "invalid", error.message); throw error; }
    if (!value.present) throw new ProfileStoreError("invalid", `Record revision is missing: ${id}/${revision}`);
    try { const record = validateProfileNoteRecord(value.value); if (record.id !== id || record.revisionId !== revision) throw new Error("Record identity does not match its path"); return record; }
    catch (error) { throw new ProfileStoreError("invalid", error instanceof Error ? error.message : "Invalid record revision"); }
  }
  private recordScope(record: ProfileNoteRecord): { sessionId?: string; branchId?: string; projectId?: string } {
    return {
      ...(record.provenance.sessionId ? { sessionId: record.provenance.sessionId } : {}),
      ...(record.provenance.branchId ? { branchId: record.provenance.branchId } : {}),
    };
  }

  /** One predicate guards every read boundary, including derivatives and
   * object authorization. Scope exclusion is stronger than record kind. */
  private recordHardErased(state: ProfileState, record: ProfileNoteRecord): boolean {
    if (state.suppressions.get(record.id)?.forgotten) return true;
    const forgotten = (id: string | undefined): boolean => id !== undefined && state.suppressions.get(id)?.forgotten === true;
    // Forget is a hard evidence fence, including historical revisions and
    // includeSuppressed reads. A derivative that still cites a forgotten
    // record is unavailable until its owning revision is scrubbed.
    if (record.provenance.evidence.some(evidence => forgotten(evidence.recordId)) || record.relations.some(relation => forgotten(relation.recordId))) return true;
    if (record.kind === "note" && (record.content.fields?.some(field => field.evidence.some(evidence => forgotten(evidence.recordId))) || record.content.contraryEvidence?.some(evidence => forgotten(evidence.recordId)))) return true;
    return false;
  }

  private recordExcluded(state: ProfileState, record: ProfileNoteRecord): boolean {
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
  private async receiptResult(paths: StorePaths, state: ProfileState, result: ReceiptResult): Promise<unknown> {
    if (result.kind === "value") return result.value;
    if (result.kind === "record") {
      if (state.suppressions.get(result.recordId)?.forgotten) throw conflict("Profile mutation result was forgotten");
      return { record: await this.readRecord(paths, result.recordId, result.revisionId), stateRevision: result.stateRevision } satisfies ProfileMutationResult;
    }
    throw invalid("Unsupported Profile receipt kind");
  }
  private receipt(result: unknown, stateRevision: number, changedRecordIds: string[] = []): { stored: ReceiptResult; recordIds: string[] } {
    if (result && typeof result === "object" && "record" in result && (result as { record?: unknown }).record && typeof (result as { record: ProfileNoteRecord }).record === "object") {
      const record = (result as { record: ProfileNoteRecord }).record;
      return { stored: { kind: "record", recordId: record.id, revisionId: record.revisionId, stateRevision }, recordIds: [record.id] };
    }
    return { stored: { kind: "value", value: result }, recordIds: changedRecordIds };
  }
  /** Command-ID replay fence, shared by the serialized mutation path and the
   * summary pre-check that must not call a model before it discovers a
   * committed replay. */
  private async replayReceipt(paths: StorePaths, state: ProfileState, key: string, operation: string, hash: string): Promise<{ found: boolean; result?: unknown }> {
    const prior = state.receipts.get(key);
    if (!prior) return { found: false };
    if (prior.operation !== operation || prior.requestHash !== hash) throw conflict("Command ID was already used for a different knowledge mutation");
    if (prior.invalidated) throw conflict("Profile mutation result was forgotten");
    return { found: true, result: await this.receiptResult(paths, state, prior.result) };
  }
  private async mutate<T>(operation: string, commandId: string, request: unknown, action: (state: ProfileState, paths: StorePaths) => Promise<T>, afterCommit?: (state: ProfileState, paths: StorePaths, result: T) => Promise<void>, signal?: AbortSignal, changedRecordIds: string[] = []): Promise<T> {
    if (!/^[A-Za-z0-9._:-]{8,160}$/.test(commandId)) throw invalid("Mutating requests require a stable commandId");
    return this.mutex.run(async () => {
      if (signal?.aborted) throw new GatewayError("busy", "Profile mutation was cancelled", true);
      const paths = await this.paths(true); const { state } = await this.load(paths, true);
      try {
        const key = `${operation}\0${commandId}`; const hash = requestHash(operation, request);
        const replayed = await this.replayReceipt(paths, state, key, operation, hash);
        if (replayed.found) return replayed.result as T;
        if (signal?.aborted) throw new GatewayError("busy", "Profile mutation was cancelled", true);
        // This is mutation admission. Once action starts it can durably write
        // record bodies: cancellation must not abandon their catalog/receipt
        // transaction and strand inaccessible private data. Join the commit.
        state.catalog!.begin();
        const result = await action(state, paths);
        state.stateRevision += 1;
        const stored = this.receipt(result, state.stateRevision, changedRecordIds);
        state.receipts.set(key, { operation, requestHash: hash, result: stored.stored, recordIds: stored.recordIds, createdAt: now(), invalidated: false });
        const entries = [...state.receipts.entries()].sort(([, a], [, b]) => a.createdAt.localeCompare(b.createdAt));
        for (const [receiptKey] of entries.slice(0, Math.max(0, entries.length - RECEIPT_LIMIT))) state.receipts.delete(receiptKey);
        await this.save(paths, state);
        // Publish only after the authoritative commit, across RPC, agent tools,
        // connectors and autonomous observations. Receipt replays bypass this.
        // A disposable notification must never turn a committed write into failure.
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

  async list(request: ProfileNoteListRequest = {}): Promise<ProfileNoteListResponse> {
    return this.readState(async (state, paths) => {
      const limit = this.pageLimit(state, request.limit ?? 50);
      // Every visibility input belongs to cursor identity. A cursor from the
      // retained view must never be replayed against pending or archived
      // projection state, where skipped rows can otherwise make pagination
      // appear stalled or omit the first admitted row.
      const scope = JSON.stringify([request.kind ?? null, request.scope ?? null, request.includeSuppressed === true]);
      const filter = this.pageFilter(request);
      if (request.cursor) {
        const cursor = readListCursor(request.cursor, scope);
        filter.clauses.push("json_extract(value, '$.sortAt') <= ? AND (json_extract(value, '$.sortAt') < ? OR key > json_quote(?))");
        filter.parameters.push(cursor.sortAt, cursor.sortAt, cursor.id);
      }
      const heads = this.visibleHeadPage(state, filter, scope, limit, request.cursor, request.includeSuppressed === true);
      const records: ProfileNoteRecord[] = []; const budget = new ProfilePageBudget();
      for (const { id, head } of heads.page) {
        const record = await this.readRecordOrRemoved(paths, state, id, head.latestRevisionId);
        if (!record) continue;
        // The body stays the authority: a head can only ever be derived from it.
        if (this.recordHardErased(state, record) || (!request.includeSuppressed && this.recordExcluded(state, record))) continue;
        if (records.length >= limit || !budget.admit(record)) break;
        records.push(record);
      }
      const nextCursor = this.pageCursor(scope, heads.page, records.length, heads.nextCursor);
      return { records, stateRevision: state.stateRevision, ...(nextCursor ? { nextCursor } : {}) };
    });
  }
  private pageLimit(state: ProfileState, requested: number): number {
    const limit = Math.min(requested, state.config.maximumSearchResults);
    if (!Number.isSafeInteger(limit) || limit < 1) throw invalid("Invalid Profile page limit");
    return limit;
  }
  private catalogFilter(request: Pick<ProfileNoteListRequest, "kind" | "scope">): { clauses: string[]; parameters: SQLInputValue[] } {
    const clauses: string[] = []; const parameters: SQLInputValue[] = [];
    if (request.kind) { clauses.push("json_extract(value, '$.kind') = ?"); parameters.push(request.kind); }
    if (request.scope) { clauses.push("json_extract(value, '$.scope') = ?"); parameters.push(request.scope); }
    return { clauses, parameters };
  }
  async read(id: string, revision?: string, includeSuppressed = false): Promise<ProfileNoteRecord | null> {
    safeId(id, "record id"); if (revision !== undefined) safeId(revision, "knowledge revision");
    return this.readState(async (state, paths) => {
      const head = state.records.get(id);
      if (!head) return null;
      const selected = revision ?? head.latestRevisionId;
      if (!head.revisionIds.includes(selected)) throw new ProfileStoreError("invalid", "Requested revision is not committed for this record");
      const record = await this.readRecordOrRemoved(paths, state, id, selected);
      const latest = await this.readRecordOrRemoved(paths, state, id, head.latestRevisionId);
      if (!record || !latest) return null;
      // Visibility is governed by the current head even when an audit caller
      // asks for an older immutable revision.
      if (this.recordHardErased(state, record) || this.recordHardErased(state, latest)) return null;
      if (!includeSuppressed && (this.recordExcluded(state, record) || this.recordExcluded(state, latest))) return null;
      return record;
    });
  }
  /** One scored search page: the statement's own ordering key plus the keyset
   * that continues it. A scored page binds the query, filters, projection and
   * the exact state revision, because it cannot be resumed across a corpus
   * change without skipping or repeating rows. */
  private pageFilter(request: Pick<ProfileNoteListRequest, "kind" | "scope">): { clauses: string[]; parameters: SQLInputValue[] } {
    return this.catalogFilter(request);
  }
  private headVisible(state: ProfileState, id: string, head: RecordHead, includeSuppressed = false): boolean {
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
  private visibleHeadPage(state: ProfileState, filter: { clauses: string[]; parameters: SQLInputValue[] }, scope: string, limit: number, cursor?: string, includeSuppressed = false): { page: Array<{ id: string; head: RecordHead }>; nextCursor?: string } {
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
  async createNote(request: ProfileNoteNoteMutationRequest & { recordId?: never }): Promise<ProfileMutationResult> { return this.mutate("knowledge.note.create", request.commandId, request, async (state, paths) => this.putRecord(state, paths, { ...request.record, content: storedNoteContent(request.record.content) })); }
  async updateNote(request: ProfileNoteNoteMutationRequest & { recordId: string; expectedRevision: string }): Promise<ProfileMutationResult> { return this.mutate("knowledge.note.update", request.commandId, request, async (state, paths) => { const current = await this.currentRecord(state, paths, request.recordId); if (!current || current.kind !== "note") throw conflict("Profile note does not exist"); if (request.expectedRevision !== current.revisionId) throw conflict("Profile note revision is stale"); return this.putRecord(state, paths, { ...request.record, content: carryNoteMarks(current, request.record.content), id: request.recordId, createdAt: current.createdAt }, request.expectedRevision); }); }
  /** Metadata-only discovery reads the committed projection, never note bodies. */
  async profileMetadata(): Promise<{ rows: ProfileRecordRow[]; sorting: ProfileSortingState }> {
    return this.readState(async (state, paths) => {
      const rows = await this.profileRowsInState(state, paths, true);
      return { rows, sorting: { version: profileSortingVersion(rows), deferred: state.profileSorting !== undefined } };
    });
  }
  /** The ordinary Profile command receipt and SQL transaction own this decision.
   * A replay returns its original acknowledgement, never re-suppresses newer notes. */
  async deferProfileSorting(commandId: string, version: string): Promise<{ status: "deferred"; version: string }> {
    if (!/^[a-f0-9]{64}$/.test(version)) throw invalid("Profile sorting needs its exact arrival version");
    return this.mutate("knowledge.profile.defer", commandId, { version }, async (state, paths) => {
      const visible = await this.profileRowsInState(state, paths, true);
      if (profileSortingVersion(visible) !== version) throw conflict("New profile notes arrived or the visible snapshot changed; read the index before Not now");
      state.profileSorting = version;
      return { status: "deferred" as const, version };
    });
  }
  private async profileRowsInState(state: ProfileState, paths: StorePaths, visibleOnly: boolean): Promise<ProfileRecordRow[]> {
    const heads = state.catalog?.rows<RecordHead>("records", "json_extract(value, '$.kind') = 'note' AND json_extract(value, '$.scope') = 'personal' AND json_type(value, '$.profileRow') = 'object'", [], "key", 501) ?? [];
    if (heads.length > 500) throw invalid("Profile metadata exceeds its bounded snapshot; no records were omitted as success");
    const rows: ProfileRecordRow[] = [];
    for (const { key: id, value: head } of heads) {
      if (visibleOnly && !this.headVisible(state, id, head)) continue;
      const row = head.profileRow;
      if (row) rows.push({ ...row, id, revisionId: head.latestRevisionId, createdAt: head.createdAt, updatedAt: head.updatedAt });
    }
    return rows;
  }
  /** One SQL commit publishes a fully backed-up partition; staged identities are recoverable. */
  async partitionProfile(request: ProfilePartitionRequest, audit?: ProfilePartitionAudit): Promise<ProfilePartitionResult> {
    return this.mutate("knowledge.profile.partition", request.commandId, request, async (state, paths) => {
      const read = (id: string, revision: string) => this.readRecord(paths, id, revision);
      return partitionProfileNotes(request, {
        backupDirectory: async () => { const path = join(paths.root, "profile-backups"); await safeDirectory(path, true); return path; },
        recordBytes: RECORD_MAX_BYTES,
        notes: async function* () { for (const [id, head] of state.records.entries()) if (head.kind === "note" && head.scope === "personal") yield await read(id, head.latestRevisionId); },
        excluded: note => this.recordExcluded(state, note),
        history: async function* (id) { for (const revision of state.records.get(id)!.revisionIds) yield await read(id, revision); },
        write: async (record, expectedRevision) => { await this.putRecord(state, paths, record, expectedRevision, record.revisionId); },
      }, audit);
    }, undefined, undefined, request.assignments.map(item => item.id));
  }
  /** Explicit recovery proves immutable committed identities, not merely current
   * heads: later edits cannot erase the original facts owed to Changes. No replay
   * occurs here or during open. Forget invalidates the complete atomic envelope. */
  async profilePartitionRecovery(commandId: string) {
    return this.readState(async (state, paths) => {
      const plan = await readProfileOperation(join(paths.root, "profile-backups"), commandId);
      let committed = true;
      for (const [index, prepared] of plan.prepared.entries()) {
        const original = plan.originals[index]!.record;
        const assignment = plan.assignments[index]!;
        const head = state.records.get(prepared.id);
        if (!head || state.suppressions.get(prepared.id)?.forgotten || assignment.id !== prepared.id || original.id !== prepared.id || assignment.expectedRevision !== original.revisionId) throw conflict("Profile recovery is unavailable");
        for (const record of [original, prepared]) {
          if (!head.revisionIds.includes(record.revisionId)) {
            if (record === original) throw conflict("Original profile revision is not committed");
            committed = false; continue;
          }
          if (JSON.stringify(await this.readRecord(paths, record.id, record.revisionId)) !== JSON.stringify(record)) throw conflict("Profile recovery differs from committed history");
        }
      }
      return { request: { commandId, mode: plan.operation!.mode, assignments: plan.assignments }, envelope: plan.operation!.envelope,
        originals: plan.originals.map(item => item.record), prepared: plan.prepared, committed };
    });
  }
  private async currentRecord(state: ProfileState, paths: StorePaths, id: string): Promise<ProfileNoteRecord | null> { const head = state.records.get(id); return head ? this.readRecord(paths, id, head.latestRevisionId) : null; }
  private async putRecord(state: ProfileState, paths: StorePaths, draft: ProfileNoteRecordDraft, expectedRevision?: string, preparedRevision?: string): Promise<ProfileMutationResult> {
    const id = draft.id ?? recordId(); safeId(id, "record id"); const existing = state.records.get(id); if (state.suppressions.get(id)?.forgotten) throw conflict("Profile record was forgotten and cannot be recreated");
    const current = existing ? await this.currentRecord(state, paths, id) : null; if (expectedRevision !== undefined && current?.revisionId !== expectedRevision) throw conflict("Profile record revision is stale"); if (expectedRevision === undefined && current) throw conflict("Profile record already exists; supply its expected revision");
    const timestamp = now(); const record = { ...draft, schemaVersion: PROFILE_NOTE_SCHEMA_VERSION, id, revisionId: preparedRevision ?? revisionId(), createdAt: draft.createdAt ?? current?.createdAt ?? timestamp, updatedAt: draft.updatedAt ?? timestamp } as ProfileNoteRecord;
    try { validateProfileNoteRecord(record); } catch (error) { throw invalid(error instanceof Error ? error.message : "Invalid knowledge record"); }
    if (Buffer.byteLength(`${JSON.stringify(record, null, 2)}\n`, "utf8") > RECORD_MAX_BYTES) throw invalid("Profile record exceeds its byte limit");
    if (!preparedRevision && record.kind === "note" && record.content.tags?.includes("home-profile") && !record.content.profile) throw invalid("New profile writes require v2 placement; historical placement is read-only except exact Changes Undo");
    if (!preparedRevision && record.kind === "note" && record.scope === "personal" && record.content.tags?.includes("home-profile")
      && (record.content.profile !== undefined || (current?.kind === "note" && current.content.profile !== undefined)
        || current?.relations.some(relation => relation.type === "supersedes" && !record.relations.some(next => next.type === "supersedes" && next.recordId === relation.recordId)))) {
      const notes = (await this.profileRowsInState(state, paths, false)).map(row => ({ id: row.id, content: { ...(row.profile ? { profile: row.profile } : {}), retired: row.retired }, relations: row.supersedes.map(recordId => ({ type: "supersedes" as const, recordId })) }));
      try { assertProfileCapacity(notes, [...notes.filter(note => note.id !== id), record]); }
      catch (error) { throw invalid(error instanceof Error ? error.message : String(error)); }
    }
    await safeDirectory(join(paths.records, id), true);
    await durableAtomicWriteJson(this.recordPath(paths, id, record.revisionId), record, 0o600);
    const revisions = [...(existing?.revisionIds ?? []), record.revisionId];
    const nextHead = headFor(record, revisions, existing?.objectHashes);
    // Consume the decision with creation, not when presentation notices a new
    // set. Later retirement/Forget cannot reinstate an old Not now.
    if (state.profileSorting !== undefined && existing === undefined && nextHead.profileRow
      && this.headVisible(state, id, nextHead)) delete state.profileSorting;
    state.records.set(id, nextHead);
    state.catalog!.setRevisions(id, revisions);
    return { record, stateRevision: state.stateRevision + 1 };
  }
  async correct(commandId: string, recordId: string, expectedRevision: string, replacement: ProfileNoteRecordDraft, relation: ProfileNoteRecord["relations"][number]): Promise<ProfileMutationResult> { return this.mutate("knowledge.correction", commandId, { recordId, expectedRevision, replacement, relation }, async (state, paths) => { const current = await this.currentRecord(state, paths, recordId); if (!current || current.revisionId !== expectedRevision) throw conflict("Profile record revision is stale"); if (relation.recordId !== recordId || relation.revisionId !== expectedRevision || (relation.type !== "corrects" && relation.type !== "supersedes")) throw invalid("Correction relation must identify the replaced revision"); const next = { ...replacement, id: recordId, createdAt: current.createdAt, relations: [...replacement.relations, relation] }; const marked = next.kind === "note" ? { ...next, content: carryNoteMarks(current, next.content) } : next; return this.putRecord(state, paths, marked, expectedRevision); }); }
  async setScopeExclusion(commandId: string, scope: { sessionId?: string; branchId?: string; projectId?: string }, excluded: boolean, reason?: string): Promise<{ excluded: boolean; stateRevision: number }> {
    if (!scope.sessionId && !scope.projectId) throw invalid("Scope exclusion requires a session or project"); return this.mutate("knowledge.scope-exclusion", commandId, { scope, excluded, reason }, async state => { const key = scope.sessionId ? (scope.branchId ? `branch:${scope.sessionId}:${scope.branchId}` : `session:${scope.sessionId}`) : `project:${scope.projectId}`; state.scopeExclusions.set(key, { ...scope, excluded, ...(reason === undefined ? {} : { reason }), updatedAt: now() }); return { excluded, stateRevision: state.stateRevision + 1 }; });
  }
  async setExclusion(commandId: string, recordId: string, excluded: boolean, expectedRevision?: string, reason?: string): Promise<{ recordId: string; excluded: boolean; stateRevision: number }> { return this.mutate("knowledge.exclusion", commandId, { recordId, excluded, expectedRevision, reason }, async (state, paths) => { const current = await this.currentRecord(state, paths, recordId); if (!current) throw conflict("Profile record does not exist"); if (expectedRevision !== undefined && expectedRevision !== current.revisionId) throw conflict("Profile record revision is stale"); state.suppressions.set(recordId, { excluded, forgotten: false, ...(reason === undefined ? {} : { reason }), updatedAt: now() }); return { recordId, excluded, stateRevision: state.stateRevision + 1 }; }); }
  async forget(commandId: string, recordId: string, reason: string, expectedRevision?: string): Promise<ProfileForgetResult> {
    if (!reason || reason.length > 1_000) throw invalid("Forget reason is required and bounded");
    return this.mutate("knowledge.forget", commandId, { recordId, reason, expectedRevision }, async (state, paths) => {
      const history = state.records.get(recordId); const current = history ? await this.currentRecord(state, paths, recordId) : null; if (!current) throw conflict("Profile record does not exist"); if (expectedRevision !== undefined && expectedRevision !== current.revisionId) throw conflict("Profile record revision is stale");
      for await (const item of profileBackupRetirements(paths.root, recordId,
        record => record.id === recordId || headFor(record, [record.revisionId]).recordRefs.includes(recordId),
        (id, revision) => state.records.get(id)?.revisionIds.includes(revision) === true)) state.recordCleanup.set(cleanupKey(item), item);
      // The tombstone, object cleanup intent, and derivative redactions are
      // published atomically before any canonical revision is removed.
      for (const revision of history!.revisionIds) {
        const item = { recordId, revisionId: revision }; state.recordCleanup.set(cleanupKey(item), item);
        const record = await this.readRecord(paths, recordId, revision);
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
      // Replacement links already live in source heads and need not have a
      // relation/evidence edge. Use that projection, not a new derived index.
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
      await cleanupProfileBackups(state, paths);
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
  async reconcile(): Promise<ProfileReconcileResult> {
    return this.mutex.run(async () => {
      const paths = await this.paths(false);
      const inspected = await this.load(paths, false);
      inspected.state.catalog?.close();
      if (!inspected.present) return { removedObjects: [], pendingObjects: [], stateRevision: 0 };
      const { state } = await this.load(paths, true);
      try {
        state.catalog!.begin();
        await cleanupProfileBackups(state, paths);
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
}

async function cleanupProfileBackups(state: ProfileState, paths: StorePaths): Promise<void> {
  const forgotten = new Set([...state.suppressions.entries()].filter(([, item]) => item.forgotten).map(([id]) => id));
  if (!forgotten.size) return;
  await redactProfileBackups(paths.root, record => forgotten.has(record.id)
    || headFor(record, [record.revisionId]).recordRefs.some(id => forgotten.has(id)));
}

function scrubReferences(record: ProfileNoteRecord, forgottenId: string): ProfileNoteRecord | null {
  const keep = (e: ProfileNoteEvidenceRef): boolean => e.recordId !== forgottenId;
  const hadProvenance = record.provenance.evidence.some(evidence => evidence.recordId === forgottenId);
  const hadRelation = record.relations.some(relation => relation.recordId === forgottenId);
  const provenance = { ...record.provenance, evidence: record.provenance.evidence.filter(keep) };
  const relations = record.relations.filter(relation => relation.recordId !== forgottenId);
  let content = record.content;
  let hadNestedEvidence = false;
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
  const scrubbed = { ...record, revisionId: revisionId(), updatedAt: now(), provenance, relations, content } as ProfileNoteRecord; validateProfileNoteRecord(scrubbed); return scrubbed;
}
