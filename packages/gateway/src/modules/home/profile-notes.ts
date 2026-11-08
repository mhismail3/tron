import { randomUUID } from "node:crypto";
import { GatewayError } from "../../errors.js";
import type { SubjectAuditReference, SubjectContext, SubjectWrite } from "../../kernel/settings/settings-change.js";
import { assertProfileCapacity, profilePath, type ProfileMetadata } from "./profile-placement.js";
import { assertProfileNoteId, validateProfileNoteRecord, type ProfileNoteRecord, type NoteContent } from "./profile-note-contract.js";

export function carryNoteMarks(current: ProfileNoteRecord, content: NoteContent): NoteContent {
  const tags = content.tags ?? current.content.tags, retired = content.retired ?? current.content.retired, profile = content.profile ?? current.content.profile;
  const { retired: _named, ...rest } = content;
  return { ...rest, ...(tags ? { tags } : {}), ...(profile ? { profile } : {}), ...(retired ? { retired: true } : {}) };
}
export function storedNoteContent(content: NoteContent): NoteContent {
  if (content.retired !== false) return content;
  const { retired: _cleared, ...rest } = content; return rest;
}
/** One placement: a v2 `path`, exact `profile` metadata, or (Changes Undo only) `prior`. */
export interface ProfileAssignment { id: string; expectedRevision: string; path?: string; profile?: ProfileMetadata; prior?: true }
export interface ProfilePartitionRequest { commandId: string; mode: "reorganize"; assignments: ProfileAssignment[] }
export interface ProfilePartitionResult { audit?: SubjectAuditReference; changes: Array<{ id: string; beforeRevision: string; revisionId: string }> }
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
  if (assignment.prior) return content;
  return { ...content, profile: assignment.path !== undefined ? profilePath(assignment.path) : assignment.profile! };
}
/** Prepares only current placement data. No history, backup directory or archive
 * is an input to an admitted transition. The file owner publishes the whole plan. */
export function prepareProfilePartition(request: ProfilePartitionRequest, notes: ProfileNoteRecord[], excluded: (note: ProfileNoteRecord) => boolean,
  restoring = false, revisions: Readonly<Record<string, string>> = {}): { originals: ProfileNoteRecord[]; prepared: ProfileNoteRecord[]; result: ProfilePartitionResult } {
  if (request.mode !== "reorganize" || request.assignments.length < 1 || request.assignments.length > 500) refuse("Partition requires 1 to 500 explicit assignments");
  const assignments = [...request.assignments].sort((a, b) => a.id.localeCompare(b.id));
  if (new Set(assignments.map(item => item.id)).size !== assignments.length) refuse("Duplicate profile assignment");
  const current = new Map(notes.map(note => [note.id, note]));
  const originals: ProfileNoteRecord[] = [], prepared: ProfileNoteRecord[] = [];
  for (const item of assignments) {
    assertProfileNoteId(item.id, "profile note"); assertProfileNoteId(item.expectedRevision, "profile revision");
    if (item.prior !== undefined && item.prior !== true) refuse("Invalid profile Prior restoration");
    if ([item.path !== undefined, item.profile !== undefined, item.prior !== undefined].filter(Boolean).length !== 1) refuse("Exactly one profile placement is required");
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
  if (!restoring) { const replacements = new Map(prepared.map(note => [note.id, note])); assertProfileCapacity(notes, notes.map(note => replacements.get(note.id) ?? note)); }
  const changes = prepared.flatMap((next, index) => {
    const before = originals[index]!;
    if (next.revisionId === before.revisionId) return [];
    return [{ id: next.id, beforeRevision: before.revisionId, revisionId: next.revisionId }];
  });
  return { originals, prepared, result: { changes } };
}
