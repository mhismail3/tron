import { randomUUID } from "node:crypto";
import { GatewayError } from "../../errors.js";
import type { SubjectAuditReference, SubjectContext, SubjectWrite } from "../../kernel/settings/settings-change.js";
import { assertProfileCapacity, profilePath, type ProfileMetadata } from "./profile-placement.js";
import { assertProfileNoteId, validateProfileNoteRecord, type ProfileNoteRecord, type NoteContent } from "./profile-note-contract.js";

export type ProfileFile = "core" | "home" | `scopes/${string}`;
export const PROFILE_FILE_TAG = "home-file-";
export const PROFILE_FILE_PATTERN = "^(core|home|scopes/[a-z][a-z0-9-]{0,46})$";
const FILE_NAME = new RegExp(PROFILE_FILE_PATTERN);
export function validProfileFile(file: string): file is ProfileFile { return FILE_NAME.test(file); }
export function profileFile(tags: readonly string[] = []): ProfileFile | null | undefined {
  const labels = tags.filter(tag => tag.startsWith(PROFILE_FILE_TAG));
  if (!labels.length) return undefined;
  const file = labels[0]!.slice(PROFILE_FILE_TAG.length).replace(/^scopes-/, "scopes/");
  return labels.length !== 1 || !validProfileFile(file) ? null : file;
}
export function profileFileTags(tags: readonly string[], file?: ProfileFile): string[] {
  return [...tags.filter(tag => !tag.startsWith(PROFILE_FILE_TAG)), ...(file ? [PROFILE_FILE_TAG + file.replace("/", "-")] : [])];
}
export function carryNoteMarks(current: ProfileNoteRecord, content: NoteContent): NoteContent {
  const tags = content.tags ?? current.content.tags, retired = content.retired ?? current.content.retired, profile = content.profile ?? current.content.profile;
  const { retired: _named, ...rest } = content;
  return { ...rest, ...(tags ? { tags } : {}), ...(profile ? { profile } : {}), ...(retired ? { retired: true } : {}) };
}
export function storedNoteContent(content: NoteContent): NoteContent {
  if (content.retired !== false) return content;
  const { retired: _cleared, ...rest } = content; return rest;
}
export function profileMigrationMembers(notes: readonly ProfileNoteRecord[]): ProfileNoteRecord[] {
  const superseded = new Set(notes.flatMap(note => note.relations.filter(relation => relation.type === "supersedes").map(relation => relation.recordId)));
  return notes.filter(note => { const file = profileFile(note.content.tags); return !note.content.profile && !note.content.retired && !superseded.has(note.id) && (file === undefined || file === "core" || file === "home"); });
}
export interface ProfileLabel { index: number; tag: string }
export const profileLabels = (tags: readonly string[] = []): ProfileLabel[] => tags.flatMap((tag, index) => tag.startsWith(PROFILE_FILE_TAG) ? [{ index, tag }] : []);
export interface ProfileAssignment { id: string; expectedRevision: string; path?: string; profile?: ProfileMetadata; file?: ProfileFile; labels?: ProfileLabel[] }
export interface ProfilePartitionRequest { commandId: string; mode: "migrate" | "reorganize"; assignments: ProfileAssignment[] }
export interface ProfilePartitionResult { audit?: SubjectAuditReference; changes: Array<{ id: string; beforeRevision: string; revisionId: string; beforeFile?: ProfileFile; file?: ProfileFile }> }
export interface ProfilePartitionEnvelope { version: 1; context: SubjectContext; replayAt: string; writes: SubjectWrite[] }
export interface ProfilePartitionAudit {
  restoring?: boolean;
  create(originals: ProfileNoteRecord[], prepared: ProfileNoteRecord[], visibleProfile: ProfileNoteRecord[]): ProfilePartitionEnvelope;
  validate(envelope: unknown, originals: ProfileNoteRecord[], prepared: ProfileNoteRecord[]): void;
  prepare(envelope: ProfilePartitionEnvelope): Promise<SubjectAuditReference>;
}
const refuse = (message: string): never => { throw new GatewayError("conflict", message); };
function assignmentContent(note: ProfileNoteRecord, assignment: ProfileAssignment): NoteContent {
  const { profile: _placement, ...content } = note.content;
  if (assignment.path !== undefined || assignment.profile !== undefined) return { ...content, tags: profileFileTags(content.tags ?? []), profile: assignment.path !== undefined ? profilePath(assignment.path) : assignment.profile! };
  let tags = [...(content.tags ?? [])];
  if (assignment.labels === undefined) { if (profileFile(tags) !== assignment.file) tags = profileFileTags(tags, assignment.file); }
  else {
    tags = tags.filter(tag => !tag.startsWith(PROFILE_FILE_TAG));
    for (const label of assignment.labels) { if (label.index > tags.length) refuse("Invalid profile label position"); tags.splice(label.index, 0, label.tag); }
  }
  return { ...content, tags };
}
/** Prepares only current placement data. No history, backup directory or archive
 * is an input to an admitted transition. The file owner publishes the whole plan. */
export function prepareProfilePartition(request: ProfilePartitionRequest, notes: ProfileNoteRecord[], excluded: (note: ProfileNoteRecord) => boolean,
  restoring = false, revisions: Readonly<Record<string, string>> = {}): { originals: ProfileNoteRecord[]; prepared: ProfileNoteRecord[]; result: ProfilePartitionResult } {
  if (!["migrate", "reorganize"].includes(request.mode) || request.assignments.length < 1 || request.assignments.length > 500) refuse("Partition requires 1 to 500 explicit assignments");
  const assignments = [...request.assignments].sort((a, b) => a.id.localeCompare(b.id));
  if (new Set(assignments.map(item => item.id)).size !== assignments.length) refuse("Duplicate profile assignment");
  const current = new Map(notes.map(note => [note.id, note]));
  const members = profileMigrationMembers(notes);
  const originals: ProfileNoteRecord[] = [], prepared: ProfileNoteRecord[] = [];
  for (const item of assignments) {
    assertProfileNoteId(item.id, "profile note"); assertProfileNoteId(item.expectedRevision, "profile revision");
    if (item.file !== undefined && !validProfileFile(item.file)) refuse("Invalid explicit profile partition");
    if (item.labels !== undefined && (item.file !== undefined || request.mode !== "reorganize" || !Array.isArray(item.labels) || item.labels.some((label, index) => typeof label.tag !== "string" || !label.tag.startsWith(PROFILE_FILE_TAG) || !Number.isInteger(label.index) || label.index < 0 || (index > 0 && label.index <= item.labels![index - 1]!.index)))) refuse("Invalid profile label restoration");
    if ([item.path !== undefined, item.profile !== undefined, item.file !== undefined, item.labels !== undefined].filter(Boolean).length !== 1) refuse("Exactly one profile placement is required");
    if (!restoring && item.path === undefined) refuse("New profile organization requires a v2 path; Prior is read-only except exact Changes Undo");
    const original = current.get(item.id);
    if (!original || original.revisionId !== item.expectedRevision) refuse("Profile assignment revision is stale or unavailable");
    if (excluded(original!)) refuse("An excluded profile note needs an explicit eligibility decision before partitioning");
    const content = assignmentContent(original!, item);
    const next = JSON.stringify(original!.content) === JSON.stringify(content) ? original! : { ...original!, revisionId: revisions[item.id] ?? randomUUID(), content };
    validateProfileNoteRecord(next);
    if (Buffer.byteLength(JSON.stringify(next)) > 2 * 1_048_576) refuse("Partitioned note exceeds its record byte bound");
    originals.push(original!); prepared.push(next);
  }
  if (request.mode === "migrate" && (members.length !== assignments.length || members.some(note => !assignments.some(item => item.id === note.id)))) refuse("Migration must assign exactly the active legacy Core/Home notes; inactive and scoped originals stay unchanged");
  if (!restoring) { const replacements = new Map(prepared.map(note => [note.id, note])); assertProfileCapacity(notes, notes.map(note => replacements.get(note.id) ?? note)); }
  const changes = prepared.flatMap((next, index) => {
    const before = originals[index]!;
    if (next.revisionId === before.revisionId) return [];
    const oldFile = profileFile(before.content.tags), file = profileFile(next.content.tags);
    return [{ id: next.id, beforeRevision: before.revisionId, revisionId: next.revisionId, ...(oldFile ? { beforeFile: oldFile } : {}), ...(file ? { file } : {}) }];
  });
  return { originals, prepared, result: { changes } };
}
