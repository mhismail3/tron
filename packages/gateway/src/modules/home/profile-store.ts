import { createHash, randomUUID } from "node:crypto";
import { lstat } from "node:fs/promises";
import { join } from "node:path";
import type { ResourceRoot } from "../../kernel/resources/resource-root.js";
import type { SubjectAuditReference } from "../../kernel/settings/settings-change.js";
import { GatewayError } from "../../errors.js";
import { AsyncMutex } from "../../util/async-mutex.js";
import { jsonNodeCount } from "../../protocol/json-budget.js";
import { PROFILE_NOTE_SCHEMA_VERSION, type ProfileNoteNoteMutationRequest, type ProfileNoteRecord, type ProfileNoteRecordDraft, type ProfileNoteListRequest, type ProfileNoteListResponse, assertProfileNoteId, validateProfileNoteRecord } from "./profile-note-contract.js";
import { createProfileFile, emptyProfileControl, profileFileRecords, readProfileFile, readProfileFileRecord, unavailableProfileRevision, writeProfileFile, discardProfileFileStages, type ProfileFile, type ProfileFileCommand, type ProfileFileControl } from "./profile-file.js";
import { assertProfileCapacity, profileNoteRow, type ProfileRecordRow } from "./profile-placement.js";
import { carryNoteMarks, storedNoteContent, prepareProfilePartition, type ProfilePartitionAudit, type ProfilePartitionEnvelope, type ProfilePartitionRequest, type ProfilePartitionResult } from "./profile-notes.js";

const RECEIPT_LIMIT = 256;
export type ProfileStateFailure = "unsafe" | "invalid";
export class ProfileStoreError extends Error {
  constructor(readonly kind: ProfileStateFailure, message: string) { super(message); this.name = "ProfileStoreError"; }
}
export interface ProfileMutationResult { record: ProfileNoteRecord; stateRevision: number }
export interface ProfileForgetResult { forgotten: true; recordId: string; stateRevision: number }
export interface ProfileSortingState { version: string; deferred: boolean }
interface ProfileWorkspace extends Pick<ResourceRoot, "describe"> {
  featureInitialized(feature: "profile"): Promise<boolean>;
  markFeatureInitialized(feature: "profile"): Promise<void>;
}
interface State { file: ProfileFile; records: Map<string, ProfileNoteRecord>; control: ProfileFileControl }
const conflict = (message: string) => new GatewayError("conflict", message);
const invalid = (message: string) => new GatewayError("invalid_request", message);
const now = () => new Date().toISOString();
const hash = (value: unknown) => createHash("sha256").update(JSON.stringify(value)).digest("hex");
const commandKey = (operation: string, id: string) => `${operation}\0${id}`;
const requestDigest = (operation: string, request: unknown) => createHash("sha256").update(operation).update("\0").update(JSON.stringify(request)).digest("hex");
const sortingVersion = (rows: ReadonlyArray<{ id: string }>) => createHash("sha256").update(rows.map(row => row.id).sort().join("\n")).digest("hex");
function commandId(id: string): void { if (!/^[A-Za-z0-9._:-]{8,160}$/.test(id)) throw invalid("Mutating requests require a stable commandId"); }

/** One whole-file authority. Current heads and live correction anchors are the
 * only bodies; command receipts contain references/intent metadata, never editions.
 * No namespace conversion, archive lookup or operation replay runs during open. */
export class ProfileStore {
  private static readonly locks = new WeakMap<ProfileWorkspace, AsyncMutex>();
  private readonly mutex: AsyncMutex;
  constructor(private readonly workspace: ProfileWorkspace) {
    this.mutex = ProfileStore.locks.get(workspace) ?? new AsyncMutex();
    ProfileStore.locks.set(workspace, this.mutex);
  }
  private async load(discardStages = false): Promise<State> {
    const descriptor = await this.workspace.describe();
    if (!descriptor.available) throw new ProfileStoreError("unsafe", "Tron workspace is unavailable or closed");
    for (const retired of ["profile", "knowledge", "knowledge.retiring"]) {
      const present = await lstat(join(descriptor.root, "state", retired)).catch(error => { if (error.code === "ENOENT") return undefined; throw error; });
      if (present) throw new ProfileStoreError("invalid", "Maintainer-approved offline Profile cutover is required; no live storage was converted");
    }
    let file = await readProfileFile(this.workspace);
    if (!file) {
      if (await this.workspace.featureInitialized("profile")) throw new ProfileStoreError("invalid", "Initialized Profile file is missing; restore it explicitly");
      file = createProfileFile([], { control: emptyProfileControl() });
    }
    if (discardStages) await discardProfileFileStages(this.workspace);
    return { file, records: new Map(profileFileRecords(file).map(record => [record.id, record])), control: file.control };
  }
  private async save(state: State): Promise<void> {
    const next = createProfileFile([...state.records.values()], { stateRevision: state.file.stateRevision + 1,
      anchorCandidates: [...state.file.anchors, ...profileFileRecords(state.file)], control: state.control,
      ...(state.file.deferred !== undefined ? { deferred: state.file.deferred } : {}) });
    await writeProfileFile(this.workspace, next);
    state.file = next;
    await this.workspace.markFeatureInitialized("profile");
  }
  private excluded(state: State, record: ProfileNoteRecord, includeSuppressed = false): boolean {
    const suppression = state.control.suppressions[record.id];
    if (suppression?.forgotten) return true;
    const evidence = [...record.provenance.evidence, ...(record.content.fields ?? []).flatMap(field => field.evidence), ...(record.content.contraryEvidence ?? [])];
    if ([...record.relations.map(relation => relation.recordId), ...evidence.flatMap(ref => ref.recordId ? [ref.recordId] : [])].some(id => state.control.suppressions[id]?.forgotten)) return true;
    if (includeSuppressed) return false;
    if (suppression?.excluded) return true;
    const sessionId = record.provenance.sessionId, branchId = record.provenance.branchId;
    if (sessionId && state.control.config.eligibility.excludedSessionIds.includes(sessionId)) return true;
    return [sessionId ? `session:${sessionId}` : "", sessionId && branchId ? `branch:${sessionId}:${branchId}` : ""].some(key => state.control.scopeExclusions[key]?.excluded);
  }
  private rows(state: State, visible = true): ProfileRecordRow[] {
    const records = [...state.records.values()].filter(record => !visible || !this.excluded(state, record));
    if (records.length > 500) throw invalid("Profile metadata exceeds its bounded snapshot; no records were omitted as success");
    return records.flatMap(record => { const row = profileNoteRow(record); return row ? [{ ...row, id: record.id, revisionId: record.revisionId, createdAt: record.createdAt, updatedAt: record.updatedAt }] : []; });
  }
  private replay<T>(state: State, id: string, operation: string, requestHash: string): { found: boolean; result?: T } {
    const prior = state.control.commands[commandKey(operation, id)];
    if (!prior) return { found: false };
    if (prior.operation !== operation || prior.requestHash !== requestHash) throw conflict("Command ID was already used for a different Profile mutation");
    if (prior.invalidated) throw conflict("Profile mutation result was forgotten");
    if (!prior.result) return { found: false };
    if (prior.result.kind === "value") return { found: true, result: prior.result.value as T };
    const record = readProfileFileRecord(state.file, prior.result.recordId, prior.result.revisionId);
    if (!record) throw unavailableProfileRevision(prior.result.recordId, prior.result.revisionId);
    return { found: true, result: { record, stateRevision: prior.result.stateRevision } as T };
  }
  private remember(state: State, id: string, receipt: ProfileFileCommand): void {
    state.control.commands[commandKey(receipt.operation, id)] = receipt;
    const entries = Object.entries(state.control.commands).sort(([, a], [, b]) => a.createdAt.localeCompare(b.createdAt));
    for (const [key, value] of entries) {
      if (Object.keys(state.control.commands).length <= RECEIPT_LIMIT) break;
      if (!value.partition && !value.auditPending) delete state.control.commands[key];
    }
    if (Object.keys(state.control.commands).length > RECEIPT_LIMIT) throw conflict("Profile has too many unsettled audit commands; explicitly repair their Changes publication first");
  }
  private async mutate<T>(operation: string, id: string, request: unknown, recordIds: string[], action: (state: State) => T | Promise<T>): Promise<T> {
    commandId(id);
    return this.mutex.run(async () => {
      const state = await this.load(true), requestHash = requestDigest(operation, request);
      const prior = this.replay<T>(state, id, operation, requestHash);
      if (prior.found) return prior.result!;
      const result = await action(state);
      const record = result && typeof result === "object" && "record" in result ? (result as { record: ProfileNoteRecord }).record : undefined;
      this.remember(state, id, { operation, requestHash, createdAt: now(), recordIds: record ? [record.id] : recordIds,
        result: record ? { kind: "record", recordId: record.id, revisionId: record.revisionId, stateRevision: state.file.stateRevision + 1 } : { kind: "value", value: result } });
      await this.save(state);
      return result;
    });
  }
  async read(id: string, revision?: string, includeSuppressed = false): Promise<ProfileNoteRecord | null> {
    assertProfileNoteId(id, "record id"); if (revision !== undefined) assertProfileNoteId(revision, "Profile revision");
    const state = await this.load(), record = readProfileFileRecord(state.file, id, revision);
    if (!record) return null;
    const current = state.records.get(id) ?? record;
    return this.excluded(state, current, includeSuppressed) || this.excluded(state, record, includeSuppressed) ? null : record;
  }
  async list(request: ProfileNoteListRequest = {}): Promise<ProfileNoteListResponse> {
    const state = await this.load(), limit = request.limit ?? 50;
    if (!Number.isSafeInteger(limit) || limit < 1 || limit > state.control.config.maximumSearchResults) throw invalid("Invalid Profile page limit");
    const scope = hash([state.file.stateRevision, request.kind, request.scope, request.includeSuppressed]);
    let offset = 0;
    if (request.cursor) {
      try { const cursor = JSON.parse(Buffer.from(request.cursor, "base64url").toString()); if (cursor.scope !== scope || !Number.isSafeInteger(cursor.offset) || cursor.offset < 0) throw new Error(); offset = cursor.offset; }
      catch { throw invalid("Profile cursor is stale or invalid; reload the first page"); }
    }
    const records = [...state.records.values()].filter(record => (!request.kind || record.kind === request.kind) && (!request.scope || record.scope === request.scope) && !this.excluded(state, record, request.includeSuppressed))
      .sort((a, b) => Date.parse(b.updatedAt) - Date.parse(a.updatedAt) || a.id.localeCompare(b.id));
    const items: ProfileNoteRecord[] = []; let bytes = 0, nodes = 0;
    for (const record of records.slice(offset, offset + limit)) {
      const size = Buffer.byteLength(JSON.stringify(record)), count = jsonNodeCount(record, 24_000);
      if (size > 750_000 || count > 24_000) { if (!items.length) throw invalid("Profile entry exceeds its bounded page size; read the exact record separately"); break; }
      if (bytes + size > 750_000 || nodes + count > 24_000) break;
      items.push(record); bytes += size; nodes += count;
    }
    const next = offset + items.length;
    return { records: items, stateRevision: state.file.stateRevision, ...(next < records.length ? { nextCursor: Buffer.from(JSON.stringify({ scope, offset: next })).toString("base64url") } : {}) };
  }
  async profileMetadata(): Promise<{ rows: ProfileRecordRow[]; sorting: ProfileSortingState }> {
    const state = await this.load(), rows = this.rows(state);
    return { rows, sorting: { version: sortingVersion(rows), deferred: state.file.deferred !== undefined } };
  }
  async deferProfileSorting(id: string, version: string): Promise<{ status: "deferred"; version: string }> {
    if (!/^[a-f0-9]{64}$/.test(version)) throw invalid("Profile sorting needs its exact arrival version");
    return this.mutate("knowledge.profile.defer", id, { version }, [], state => {
      if (sortingVersion(this.rows(state)) !== version) throw conflict("New profile notes arrived or the visible snapshot changed; read the index before Not now");
      state.file.deferred = version; return { status: "deferred", version };
    });
  }
  private put(state: State, draft: ProfileNoteRecordDraft, expectedRevision?: string): ProfileMutationResult {
    const id = draft.id ?? randomUUID(), current = state.records.get(id);
    assertProfileNoteId(id, "record id");
    if (state.control.suppressions[id]?.forgotten) throw conflict("Profile record was forgotten and cannot be recreated");
    if (expectedRevision !== undefined ? current?.revisionId !== expectedRevision : current !== undefined) throw conflict("Profile record revision is stale");
    const timestamp = now(), record = validateProfileNoteRecord({ ...draft, schemaVersion: PROFILE_NOTE_SCHEMA_VERSION, id, revisionId: randomUUID(), createdAt: current?.createdAt ?? draft.createdAt ?? timestamp, updatedAt: draft.updatedAt ?? timestamp });
    if (Buffer.byteLength(JSON.stringify(record)) > 2 * 1_048_576) throw invalid("Profile record exceeds its byte limit");
    if (!record.content.profile) throw invalid("New Profile writes require v2 placement; Prior is read-only except exact Changes Undo");
    assertProfileCapacity([...state.records.values()], [...state.records.values()].filter(note => note.id !== id).concat(record));
    if (!current && !this.excluded(state, record)) delete state.file.deferred;
    state.records.set(id, record);
    return { record, stateRevision: state.file.stateRevision + 1 };
  }
  async createNote(request: ProfileNoteNoteMutationRequest & { recordId?: never }): Promise<ProfileMutationResult> {
    return this.mutate("knowledge.note.create", request.commandId, request, [], state => this.put(state, { ...request.record, content: storedNoteContent(request.record.content) }));
  }
  async updateNote(request: ProfileNoteNoteMutationRequest & { recordId: string; expectedRevision: string }): Promise<ProfileMutationResult> {
    return this.mutate("knowledge.note.update", request.commandId, request, [request.recordId], state => {
      const current = state.records.get(request.recordId); if (!current) throw conflict("Profile note does not exist");
      return this.put(state, { ...request.record, id: request.recordId, createdAt: current.createdAt, content: carryNoteMarks(current, request.record.content) }, request.expectedRevision);
    });
  }
  async partitionProfile(request: ProfilePartitionRequest, audit?: ProfilePartitionAudit): Promise<ProfilePartitionResult> {
    commandId(request.commandId);
    return this.mutex.run(async () => {
      const state = await this.load(true), requestHash = requestDigest("knowledge.profile.partition", request);
      const replay = this.replay<ProfilePartitionResult>(state, request.commandId, "knowledge.profile.partition", requestHash);
      if (replay.found) return replay.result!;
      const prior = state.control.commands[commandKey("knowledge.profile.partition", request.commandId)];
      const pending = prior?.partition;
      const plan = prepareProfilePartition(request, [...state.records.values()], note => this.excluded(state, note), audit?.restoring, pending?.revisions);
      if (!plan.result.changes.length) return plan.result;
      let envelope: ProfilePartitionEnvelope | undefined;
      if (audit) {
        envelope = audit.create(plan.originals, plan.prepared, [...state.records.values()].filter(note => !this.excluded(state, note)));
        audit.validate(envelope, plan.originals, plan.prepared);
        if (pending && (JSON.stringify(pending.context) !== JSON.stringify(envelope.context) || pending.replayAt !== envelope.replayAt)) throw conflict("Profile retry must retain its original audit identity");
        if (!pending) {
          this.remember(state, request.commandId, { operation: "knowledge.profile.partition", requestHash, createdAt: now(), recordIds: plan.originals.map(note => note.id),
            partition: { request, context: envelope.context, replayAt: envelope.replayAt, revisions: Object.fromEntries(plan.prepared.map(note => [note.id, note.revisionId])), undoOf: Object.fromEntries(envelope.writes.flatMap(write => write.undoOf ? [[write.id, write.undoOf]] : [])) } });
          // Body-free accepted intent precedes shared audit preparation and effects.
          await this.save(state);
        }
        plan.result.audit = await audit.prepare(envelope);
      }
      for (const record of plan.prepared) state.records.set(record.id, record);
      this.remember(state, request.commandId, { operation: "knowledge.profile.partition", requestHash, createdAt: prior?.createdAt ?? now(), recordIds: plan.originals.map(note => note.id),
        result: { kind: "value", value: plan.result }, ...(plan.result.audit ? { audit: plan.result.audit, auditPending: true } : {}) });
      await this.save(state);
      return plan.result;
    });
  }
  async profilePartitionRecovery(id: string) {
    const state = await this.load(), receipt = state.control.commands[commandKey("knowledge.profile.partition", id)];
    if (!receipt || receipt.operation !== "knowledge.profile.partition") throw new GatewayError("not_found", "No prepared Profile operation with this command ID");
    if (receipt.invalidated) throw conflict("Profile operation was invalidated by Forget");
    if (receipt.partition) return { committed: false as const, ...receipt.partition };
    if (!receipt.audit || receipt.result?.kind !== "value") throw conflict("Profile operation has no shared Changes preparation");
    return { committed: true as const, reference: receipt.audit, result: receipt.result.value as ProfilePartitionResult };
  }
  /** Called only inside the Changes stripe. Keep invalidation ordered with the
   * journal append, but release the file mutex before Changes runs observers. */
  async withProfileAuditProof(id: string, reference: SubjectAuditReference, publish: () => Promise<void>): Promise<void> {
    await this.mutex.run(async () => {
      const state = await this.load(true), receipt = state.control.commands[commandKey("knowledge.profile.partition", id)];
      if (!receipt || receipt.invalidated || !receipt.result || JSON.stringify(receipt.audit) !== JSON.stringify(reference)) throw conflict("Profile operation proof was invalidated before publication");
      await publish();
    });
  }
  async settleProfileAudit(id: string): Promise<void> {
    await this.mutex.run(async () => { const state = await this.load(true), receipt = state.control.commands[commandKey("knowledge.profile.partition", id)]; if (receipt?.auditPending) { delete receipt.auditPending; await this.save(state); } });
  }
  async correct(id: string, recordId: string, expectedRevision: string, replacement: ProfileNoteRecordDraft, relation: ProfileNoteRecord["relations"][number]): Promise<ProfileMutationResult> {
    if (relation.recordId !== recordId || relation.revisionId !== expectedRevision || !["corrects", "supersedes"].includes(relation.type)) throw invalid("Correction relation must identify the replaced revision");
    return this.mutate("knowledge.correction", id, { recordId, expectedRevision, replacement, relation }, [recordId], state => {
      const current = state.records.get(recordId); if (!current) throw conflict("Profile record does not exist");
      return this.put(state, { ...replacement, id: recordId, content: carryNoteMarks(current, replacement.content), relations: [...replacement.relations, relation] }, expectedRevision);
    });
  }
  async setExclusion(id: string, recordId: string, excluded: boolean, expectedRevision?: string, reason?: string) {
    return this.mutate("knowledge.exclusion", id, { recordId, excluded, expectedRevision, reason }, [recordId], state => {
      const current = state.records.get(recordId); if (!current || expectedRevision !== undefined && current.revisionId !== expectedRevision) throw conflict("Profile record revision is stale");
      state.control.suppressions[recordId] = { excluded, forgotten: false, updatedAt: now(), ...(reason ? { reason } : {}) };
      return { recordId, excluded, stateRevision: state.file.stateRevision + 1 };
    });
  }
  async setScopeExclusion(id: string, scope: { sessionId?: string; branchId?: string; projectId?: string }, excluded: boolean, reason?: string) {
    if (!scope.sessionId && !scope.projectId) throw invalid("Scope exclusion requires a session or project");
    return this.mutate("knowledge.scope-exclusion", id, { scope, excluded, reason }, [], state => {
      const key = scope.sessionId ? scope.branchId ? `branch:${scope.sessionId}:${scope.branchId}` : `session:${scope.sessionId}` : `project:${scope.projectId}`;
      state.control.scopeExclusions[key] = { ...scope, excluded, updatedAt: now(), ...(reason ? { reason } : {}) };
      return { excluded, stateRevision: state.file.stateRevision + 1 };
    });
  }
  async forget(id: string, recordId: string, reason: string, expectedRevision?: string): Promise<ProfileForgetResult> {
    if (!reason.trim()) throw invalid("Forget needs an explicit reason");
    return this.mutate("knowledge.forget", id, { recordId, reason, expectedRevision }, [recordId], state => {
      const current = state.records.get(recordId);
      if (expectedRevision !== undefined && current?.revisionId !== expectedRevision) throw conflict("Profile record revision is stale");
      state.records.delete(recordId);
      state.control.suppressions[recordId] = { excluded: true, forgotten: true, reason, updatedAt: now() };
      for (const receipt of Object.values(state.control.commands)) if (receipt.recordIds.includes(recordId)) { receipt.invalidated = true; delete receipt.partition; delete receipt.audit; delete receipt.auditPending; delete receipt.result; }
      // A forgotten claim cannot remain in any current derivative or anchor.
      for (const [key, record] of state.records) {
        const evidence = record.provenance.evidence.filter(ref => ref.recordId !== recordId);
        const correctedForgottenClaim = record.relations.some(ref => ref.type === "corrects" && ref.recordId === recordId);
        // An unavailable corrects link is a privacy tombstone, not permission to
        // resurrect its anchor. Other references can be scrubbed outright.
        const relations = record.relations.filter(ref => ref.recordId !== recordId || ref.type === "corrects");
        const fields = record.content.fields?.filter(field => !field.evidence.some(ref => ref.recordId === recordId));
        const contraryEvidence = record.content.contraryEvidence?.filter(ref => ref.recordId !== recordId);
        if (correctedForgottenClaim || JSON.stringify([evidence, relations, fields, contraryEvidence]) !== JSON.stringify([record.provenance.evidence, record.relations, record.content.fields, record.content.contraryEvidence])) {
          const next = { ...record, revisionId: randomUUID(), updatedAt: now(), provenance: { ...record.provenance, evidence }, relations, content: { ...record.content, confirmed: false,
            ...(correctedForgottenClaim ? { title: "[Unavailable: corrected claim was forgotten.]" } : {}),
            ...(record.content.body !== undefined ? { body: "[Redacted: supporting evidence was forgotten.]" } : {}), ...(fields ? { fields } : {}), ...(contraryEvidence ? { contraryEvidence } : {}) } };
          state.records.set(key, next);
          for (const receipt of Object.values(state.control.commands)) if (receipt.recordIds.includes(key)) { receipt.invalidated = true; delete receipt.partition; delete receipt.audit; delete receipt.auditPending; delete receipt.result; }
        }
      }
      return { forgotten: true, recordId, stateRevision: state.file.stateRevision + 1 };
    });
  }
}
