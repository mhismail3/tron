import { createHash, randomUUID } from "node:crypto";
import { join } from "node:path";
import { lstat, readdir } from "node:fs/promises";
import { GatewayError } from "../../errors.js";
import { assertProfileCapacity, profilePath, type ProfileMetadata } from "./profile-placement.js";
import { durableAtomicWriteJson, durableRemove } from "../../foundation/durable-json.js";
import { readSecureJson } from "../../foundation/secure-json.js";
import { assertProfileNoteId, validateProfileNoteRecord, type ProfileNoteRecord, type NoteContent } from "./profile-note-contract.js";

export type ProfileFile = "core" | "home" | `scopes/${string}`;
export const PROFILE_FILE_TAG = "home-file-";
export const PROFILE_FILE_PATTERN = "^(core|home|scopes/[a-z][a-z0-9-]{0,46})$";
const FILE_NAME = new RegExp(PROFILE_FILE_PATTERN);
export function validProfileFile(file: string): file is ProfileFile { return FILE_NAME.test(file); }
/** undefined is an unlabelled flat note; null is malformed metadata, never Core. */
export function profileFile(tags: readonly string[] = []): ProfileFile | null | undefined {
  const labels = tags.filter(tag => tag.startsWith(PROFILE_FILE_TAG));
  if (!labels.length) return undefined;
  const file = labels[0]!.slice(PROFILE_FILE_TAG.length).replace(/^scopes-/, "scopes/");
  if (labels.length !== 1 || !validProfileFile(file)) return null;
  return file;
}
export function profileFileTags(tags: readonly string[], file?: ProfileFile): string[] {
  return [...tags.filter(tag => !tag.startsWith(PROFILE_FILE_TAG)), ...(file ? [PROFILE_FILE_TAG + file.replace("/", "-")] : [])];
}

/** A native typed edit does not model owner labels/retirement; omission preserves them. */
export function carryNoteMarks(current: ProfileNoteRecord, content: NoteContent): NoteContent {
  if (current.kind !== "note") return storedNoteContent(content);
  const tags = content.tags ?? current.content.tags;
  const retired = content.retired ?? current.content.retired;
  const profile = content.profile ?? current.content.profile;
  const { retired: _named, ...rest } = content;
  return { ...rest, ...(tags ? { tags } : {}), ...(profile ? { profile } : {}), ...(retired ? { retired: true } : {}) };
}
export function storedNoteContent(content: NoteContent): NoteContent {
  if (content.retired !== false) return content;
  const { retired: _cleared, ...rest } = content;
  return rest;
}

type Note = Extract<ProfileNoteRecord, { kind: "note" }>;
/** Complete migration touches active legacy Core/Home only, never inactive or
 * named-scope originals. Reads and recovery do not infer a new destination. */
export function profileMigrationMembers(notes: readonly Note[]): Note[] {
  const superseded = new Set(notes.flatMap(note => note.relations.filter(relation => relation.type === "supersedes").map(relation => relation.recordId)));
  return notes.filter(note => {
    const file = profileFile(note.content.tags);
    return !note.content.profile && !note.content.retired && !superseded.has(note.id) && (file === undefined || file === "core" || file === "home");
  });
}
export interface ProfileLabel { index: number; tag: string }
export const profileLabels = (tags: readonly string[] = []): ProfileLabel[] => tags.flatMap((tag, index) => tag.startsWith(PROFILE_FILE_TAG) ? [{ index, tag }] : []);
export interface ProfileAssignment { id: string; expectedRevision: string; path?: string; profile?: ProfileMetadata; file?: ProfileFile; labels?: ProfileLabel[] }
export interface ProfilePartitionRequest { commandId: string; mode: "migrate" | "reorganize"; assignments: ProfileAssignment[] }
export interface ProfilePartitionResult {
  backup?: string;
  changes: Array<{ id: string; beforeRevision: string; revisionId: string; beforeFile?: ProfileFile; file?: ProfileFile }>;
}
export interface ProfilePartitionAudit {
  /** Only Changes Undo supplies historical placement; never a model parameter. */
  restoring?: boolean;
  create(originals: Note[], prepared: Note[], visibleProfile: Note[]): unknown;
  validate(envelope: unknown, originals: Note[], prepared: Note[]): void;
}
interface PartitionBackup {
  version: 1;
  digest: string;
  assignments: ProfileAssignment[];
  originals: Array<{ record: Note; history: ProfileNoteRecord[] }>;
  prepared: Note[];
  operation?: { commandId: string; mode: ProfilePartitionRequest["mode"]; envelope: unknown };
}
const planDigest = (mode: ProfilePartitionRequest["mode"], assignments: ProfileAssignment[], operation?: PartitionBackup["operation"]) =>
  createHash("sha256").update(JSON.stringify({ mode, assignments, ...(operation ? { operation } : {}) })).digest("hex");
export const profileOperationKey = (commandId: string) => createHash("sha256").update(commandId).digest("hex");
function assignmentTags(note: Note, assignment: ProfileAssignment): string[] {
  if (assignment.labels === undefined) return profileFile(note.content.tags) === assignment.file ? [...(note.content.tags ?? [])] : profileFileTags(note.content.tags ?? [], assignment.file);
  const tags = (note.content.tags ?? []).filter(tag => !tag.startsWith(PROFILE_FILE_TAG));
  for (const label of assignment.labels) {
    if (label.index > tags.length) refuse("Invalid profile label position");
    tags.splice(label.index, 0, label.tag);
  }
  return tags;
}
function assignmentContent(note: Note, assignment: ProfileAssignment): NoteContent {
  const { profile: _profile, ...content } = note.content;
  if (assignment.path !== undefined || assignment.profile !== undefined) return { ...content, tags: profileFileTags(content.tags ?? []), profile: assignment.path !== undefined ? profilePath(assignment.path) : assignment.profile! };
  return { ...content, tags: assignmentTags(note, assignment) };
}
/** A recovery read is explicit and carries no domain side effect. */
export async function readProfileOperation(directory: string, commandId: string) {
  // Secure JSON checks its final entry, not its ancestors. A recovery read must
  // enforce the same owner-only real directory as the original backup writer.
  const status = await lstat(directory).catch(error => { if (error.code === "ENOENT") return undefined; throw error; });
  if (status && (!status.isDirectory() || status.isSymbolicLink() || status.uid !== process.getuid?.() || (status.mode & 0o777) !== 0o700)) refuse("Unsafe profile backup directory");
  const saved = await readSecureJson<PartitionBackup>(join(directory, `${profileOperationKey(commandId)}.json`), BACKUP_BYTES);
  const plan = saved.present ? saved.value : refuse("No backed-up profile operation with this command ID");
  if (plan.version !== 1 || plan.operation?.commandId !== commandId || plan.digest !== planDigest(plan.operation.mode, plan.assignments, plan.operation)
    || plan.originals.length !== plan.assignments.length || plan.prepared.length !== plan.assignments.length) refuse("Profile operation was invalidated or its backup changed");
  return plan;
}
interface PartitionAccess {
  backupDirectory(): Promise<string>;
  recordBytes: number;
  notes(): AsyncIterable<ProfileNoteRecord>;
  excluded(note: Note): boolean;
  history(id: string): AsyncIterable<ProfileNoteRecord>;
  write(record: Note, expectedRevision: string): Promise<void>;
}
const BACKUP_BYTES = 64 * 1_048_576;

/** Existing ProfileNote tombstones govern these copies too. A forget invalidates
 * its whole atomic plan; unrelated snapshots stay recoverable, while uncommitted
 * prepared files retire through the existing recordCleanup transaction. */
async function* profileBackups(root: string): AsyncGenerator<{ path: string; plan: PartitionBackup }> {
  const directory = join(root, "profile-backups");
  const status = await lstat(directory).catch(error => { if (error.code === "ENOENT") return undefined; throw error; });
  if (!status) return;
  if (!status.isDirectory() || status.isSymbolicLink()) refuse("Unsafe profile backup directory");
  for (const name of await readdir(directory)) {
    const path = join(directory, name);
    // The sole writer holds the ProfileNote mutex. Unpublished temp files cannot
    // own staged revisions: bodies only start after the canonical backup rename.
    if (/^[a-f0-9]{64}\.json\.\d+\.[a-f0-9]{12}\.tmp$/.test(name)) { await durableRemove(path); continue; }
    if (!/^[a-f0-9]{64}\.json$/.test(name)) refuse("Unknown profile backup file");
    const saved = await readSecureJson<PartitionBackup>(path, BACKUP_BYTES);
    const plan = saved.present ? saved.value : refuse("Profile backup disappeared during cleanup");
    // An added opaque Home envelope must bring its owned privacy contract here;
    // never silently carry unknown copies through forget.
    if (plan.version !== 1 || Object.keys(plan).some(key => !["version", "digest", "assignments", "originals", "prepared", "operation"].includes(key))) refuse("Unsupported profile backup cleanup shape");
    for (const record of [...plan.prepared, ...plan.originals.flatMap(item => [item.record, ...item.history])]) validateProfileNoteRecord(record);
    if (plan.prepared.some(record => record.kind !== "note") || plan.originals.some(item => item.record.kind !== "note" || item.history.some(record => record.id !== item.record.id))) refuse("Invalid profile backup history ownership");
    yield { path, plan };
  }
}
function affectedBackupMembers(plan: PartitionBackup, affected: (record: ProfileNoteRecord) => boolean): Set<string> {
  return new Set([...plan.prepared, ...plan.originals.flatMap(item => [item.record, ...item.history])].filter(affected).map(record => record.id));
}
export async function* profileBackupRetirements(root: string, forgottenId: string, affected: (record: ProfileNoteRecord) => boolean, committed: (id: string, revision: string) => boolean) {
  for await (const { plan } of profileBackups(root)) if (affectedBackupMembers(plan, affected).size) {
    for (const record of plan.prepared) if (record.id === forgottenId || !committed(record.id, record.revisionId)) yield { recordId: record.id, revisionId: record.revisionId };
  }
}
export async function redactProfileBackups(root: string, affected: (record: ProfileNoteRecord) => boolean): Promise<void> {
  for await (const { path, plan } of profileBackups(root)) {
    const removed = affectedBackupMembers(plan, affected);
    if (!removed.size) continue;
    // Keep original assignment identities: missing members make this operation
    // non-replayable. Do not mint a new intent or erase unrelated recovery data.
    // The opaque envelope may quote any member, including in free-form context.
    // Forget invalidates the whole atomic intent: drop the ENTIRE envelope rather
    // than attempt field-wise redaction or retain an unrelated copy of its text.
    const { operation: _operation, ...retained } = plan;
    await durableAtomicWriteJson(path, { ...retained, assignments: retained.assignments.map(item => removed.has(item.id) ? { id: item.id, expectedRevision: item.expectedRevision } : item), originals: plan.originals.filter(item => !removed.has(item.record.id)), prepared: plan.prepared.filter(item => !removed.has(item.id)) });
  }
}
const refuse = (message: string): never => { throw new GatewayError("conflict", message); };

/** Runs INSIDE ProfileNoteStore's admitted SQL transaction. The backup is a bounded
 * immutable recovery manifest, not another catalog: canonical heads stay in SQL.
 * Prepared revision identities are durable before any body write, so a retry adopts
 * every staged body instead of silently leaking precommit immutable revisions.
 * Explicit recovery retries the same assignments; opening the store never migrates.
 */
export async function partitionProfileNotes(request: ProfilePartitionRequest, access: PartitionAccess, audit?: ProfilePartitionAudit): Promise<ProfilePartitionResult> {
  if (request.mode !== "migrate" && request.mode !== "reorganize") refuse("Unknown profile partition operation");
  if (request.assignments.length < 1 || request.assignments.length > 500) refuse("Partition requires 1 to 500 explicit assignments");
  const assignments = request.assignments.map(item => ({ id: item.id, expectedRevision: item.expectedRevision, ...(item.path !== undefined ? { path: item.path } : {}), ...(item.profile !== undefined ? { profile: item.profile } : {}), ...(item.file !== undefined ? { file: item.file } : {}), ...(item.labels !== undefined ? { labels: item.labels } : {}) })).sort((a, b) => a.id.localeCompare(b.id));
  if (new Set(assignments.map(item => item.id)).size !== assignments.length) refuse("Duplicate profile assignment");
  for (const item of assignments) {
    assertProfileNoteId(item.id, "profile note"); assertProfileNoteId(item.expectedRevision, "profile revision");
    if (item.file !== undefined && !validProfileFile(item.file)) refuse("Invalid explicit profile partition");
    if (item.labels !== undefined && (item.file !== undefined || request.mode !== "reorganize" || !Array.isArray(item.labels) || item.labels.some((label, index) => typeof label.tag !== "string" || !label.tag.startsWith(PROFILE_FILE_TAG) || !Number.isInteger(label.index) || label.index < 0 || (index > 0 && label.index <= item.labels![index - 1]!.index)))) refuse("Invalid profile label restoration");
    if (item.path !== undefined) { try { profilePath(item.path); } catch (error) { refuse(String(error)); } }
    if ([item.path !== undefined, item.profile !== undefined, item.file !== undefined, item.labels !== undefined].filter(Boolean).length !== 1) refuse("Exactly one profile placement is required");
  }
  const digest = planDigest(request.mode, assignments);
  // Audited operations are addressed by the ORIGINAL command, not assignment
  // equivalence: separate intents never collide, even for identical assignments.
  const backup = join(await access.backupDirectory(), `${audit ? profileOperationKey(request.commandId) : digest}.json`);
  const saved = await readSecureJson<PartitionBackup>(backup, BACKUP_BYTES);
  if (!saved.present && !audit?.restoring && assignments.some(item => item.path === undefined)) refuse("New profile organization requires a v2 path; legacy placement is read-only except exact Changes Undo");
  const notes: Note[] = [];
  let activeBytes = 0;
  for await (const note of access.notes()) {
    if (note.kind !== "note" || note.scope !== "personal" || !note.content.tags?.includes("home-profile")) continue;
    activeBytes += Buffer.byteLength(JSON.stringify(note));
    if (activeBytes > BACKUP_BYTES || notes.length >= 500) refuse("Profile partition exceeds its bounded snapshot; no note was changed");
    notes.push(note);
  }
  if (notes.some(note => assignments.some(item => item.id === note.id) && access.excluded(note))) refuse("An excluded profile note needs an explicit eligibility decision before partitioning");
  const current = new Map(notes.map(note => [note.id, note]));
  const members = profileMigrationMembers(notes);
  if (!saved.present && request.mode === "migrate" && (members.length !== assignments.length || members.some(note => !assignments.some(item => item.id === note.id)))) refuse("Migration must assign exactly the active legacy Core/Home notes; inactive and scoped originals stay unchanged");
  let plan: PartitionBackup;
  if (saved.present) {
    plan = saved.value;
    if (plan.version !== 1 || plan.digest !== planDigest(request.mode, assignments, plan.operation) || (audit && plan.operation?.commandId !== request.commandId) || JSON.stringify(plan.assignments) !== JSON.stringify(assignments)) refuse("Profile backup does not match this migration");
    for (const record of [...plan.prepared, ...plan.originals.flatMap(item => [item.record, ...item.history])]) validateProfileNoteRecord(record);
    if (plan.prepared.length !== assignments.length || plan.originals.length !== assignments.length || plan.prepared.some((note, index) => note.id !== assignments[index]!.id || plan.originals[index]!.record.id !== note.id)) refuse("Incomplete profile backup");
  } else {
    if (assignments.every(item => current.has(item.id) && JSON.stringify(current.get(item.id)!.content) === JSON.stringify(assignmentContent(current.get(item.id)!, item)))) {
      if (assignments.some(item => current.get(item.id)!.revisionId !== item.expectedRevision)) refuse("Profile assignment revision is stale");
      return { changes: [] };
    }
    const originals = [];
    const prepared = [];
    let planBytes = 4_096 + Buffer.byteLength(JSON.stringify(assignments, null, 8));
    const admit = (value: unknown) => {
      planBytes += 256 + Buffer.byteLength(JSON.stringify(value, null, 8));
      if (planBytes > BACKUP_BYTES) refuse("Profile backup exceeds its bound; no note was changed");
    };
    for (const item of assignments) {
      const note = current.get(item.id);
      if (!note || note.revisionId !== item.expectedRevision) refuse("Profile assignment revision is stale or unavailable");
      const content = assignmentContent(note!, item);
      const next = JSON.stringify(note!.content) === JSON.stringify(content) ? note! : { ...note!, revisionId: randomUUID(), content };
      validateProfileNoteRecord(next);
      if (Buffer.byteLength(JSON.stringify(next, null, 2) + "\n") > access.recordBytes) refuse("Partitioned note exceeds its record byte bound");
      admit({ record: note, prepared: next });
      if (request.mode === "migrate" && note!.content.profile) refuse("An already migrated note needs explicit reorganization");
      const history = [];
      for await (const record of access.history(item.id)) { admit(record); history.push(record); }
      originals.push({ record: note!, history });
      prepared.push(next);
    }
    if (!audit?.restoring) {
      try { const replacements = new Map(prepared.map(note => [note.id, note])); assertProfileCapacity(notes, notes.map(note => replacements.get(note.id) ?? note)); }
      catch (error) { refuse(error instanceof Error ? error.message : String(error)); }
    }
    const operation = audit ? { commandId: request.commandId, mode: request.mode, envelope: audit.create(originals.map(item => item.record), prepared, notes.filter(note => !access.excluded(note))) } : undefined;
    plan = { version: 1, digest: planDigest(request.mode, assignments, operation), assignments, originals, prepared, ...(operation ? { operation } : {}) };
    if (operation) audit!.validate(operation.envelope, originals.map(item => item.record), prepared);
    if (Buffer.byteLength(JSON.stringify(plan, null, 2) + "\n") > BACKUP_BYTES) refuse("Profile backup exceeds its bound; no note was changed");
    await durableAtomicWriteJson(backup, plan);
  }
  if (audit) audit.validate(plan.operation!.envelope, plan.originals.map(item => item.record), plan.prepared);
  // Validate the ENTIRE plan against canonical heads before writing any body.
  for (const [index, next] of plan.prepared.entries()) {
    const now = current.get(next.id);
    const before = plan.originals[index]!.record;
    if (Buffer.byteLength(JSON.stringify(next, null, 2) + "\n") > access.recordBytes) refuse("Partitioned note exceeds its record byte bound");
    const expected = next.revisionId === before.revisionId ? before : { ...before, revisionId: next.revisionId, content: assignmentContent(before, assignments[index]!) };
    if (before.revisionId !== assignments[index]!.expectedRevision || JSON.stringify(expected) !== JSON.stringify(next)) refuse("Backup would change more than profile placement");
    if (!now || (now.revisionId !== before.revisionId && now.revisionId !== next.revisionId)) refuse("Profile changed since the backed-up partition plan");
    if (now!.revisionId === before.revisionId && JSON.stringify(now) !== JSON.stringify(before)) refuse("Original profile revision differs from its backup");
    if (now!.revisionId === next.revisionId && JSON.stringify(now) !== JSON.stringify(next)) refuse("Prepared profile revision was changed");
    let position = 0;
    for await (const record of access.history(next.id)) {
      if (next.revisionId !== before.revisionId && record.revisionId === next.revisionId) continue;
      if (JSON.stringify(record) !== JSON.stringify(plan.originals[index]!.history[position++])) refuse("Profile history differs from its complete backup");
    }
    if (position !== plan.originals[index]!.history.length) refuse("Profile history differs from its complete backup");
  }
  if (!audit?.restoring) {
    try { const replacements = new Map(plan.prepared.map(note => [note.id, note])); assertProfileCapacity(notes, notes.map(note => replacements.get(note.id) ?? note)); }
    catch (error) { refuse(error instanceof Error ? error.message : String(error)); }
  }
  for (const [index, next] of plan.prepared.entries()) if (current.get(next.id)!.revisionId !== next.revisionId) await access.write(next, plan.originals[index]!.record.revisionId);
  // Return only references, never note bodies in generic command receipts. The
  // Home change owner must recover/deduplicate its undo audit before success.
  return { backup, changes: plan.prepared.map((next, index) => {
    const oldFile = profileFile(plan.originals[index]!.record.content.tags), file = profileFile(next.content.tags);
    return { id: next.id, beforeRevision: plan.originals[index]!.record.revisionId, revisionId: next.revisionId, ...(oldFile ? { beforeFile: oldFile } : {}), ...(file ? { file } : {}) };
  }).filter(change => change.beforeRevision !== change.revisionId) };
}
