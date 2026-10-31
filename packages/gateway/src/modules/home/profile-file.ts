import { lstat, mkdir, readdir } from "node:fs/promises";
import { dirname, join } from "node:path";
import { GatewayError } from "../../errors.js";
import type { ResourceRoot } from "../../kernel/resources/resource-root.js";
import { durablePublishBoundedJson, durableRemove } from "../../foundation/durable-json.js";
import { readSecureJson } from "../../foundation/secure-json.js";
import { PROFILE_AREAS, profilePath } from "./profile-placement.js";
import { DEFAULT_PROFILE_NOTE_CONFIG, validateProfileNoteConfig, validateProfileNoteRecord, type ProfileNoteConfig, type ProfileNoteRecord } from "./profile-note-contract.js";
import type { SubjectAuditReference, SubjectContext } from "../../kernel/settings/settings-change.js";
import type { ProfilePartitionRequest } from "./profile-notes.js";

export const PROFILE_FILE_BYTES = 64 * 1_048_576;
const ROOTS = [...Object.keys(PROFILE_AREAS), "inferred", "prior"];
type FileNote = Omit<ProfileNoteRecord, "content"> & { content: Omit<ProfileNoteRecord["content"], "profile"> };
export interface ProfileSection { notes: FileNote[]; children: Record<string, ProfileSection> }
export interface ProfileSuppression { excluded: boolean; forgotten: boolean; reason?: string; updatedAt: string }
export interface ProfileScopeExclusion { sessionId?: string; branchId?: string; projectId?: string; excluded: boolean; reason?: string; updatedAt: string }
export interface ProfileFileCommand {
  operation: string; requestHash: string; createdAt: string; recordIds: string[]; invalidated?: boolean;
  result?: { kind: "record"; recordId: string; revisionId: string; stateRevision: number } | { kind: "value"; value: unknown };
  partition?: { request: ProfilePartitionRequest; context: SubjectContext; replayAt: string; revisions: Record<string, string>; undoOf: Record<string, string> };
  audit?: SubjectAuditReference;
  auditPending?: boolean;
}
export interface ProfileFileControl {
  config: ProfileNoteConfig;
  suppressions: Record<string, ProfileSuppression>;
  scopeExclusions: Record<string, ProfileScopeExclusion>;
  commands: Record<string, ProfileFileCommand>;
}
export const emptyProfileControl = (): ProfileFileControl => ({ config: structuredClone(DEFAULT_PROFILE_NOTE_CONFIG), suppressions: {}, scopeExclusions: {}, commands: {} });
/** The hierarchy owns current placement; it is not duplicated inside its notes.
 * Anchors are immutable claim evidence, never another current-value projection. */
export interface ProfileFile {
  format: "tron-profile";
  version: 2;
  stateRevision: number;
  sections: Record<string, ProfileSection>;
  anchors: ProfileNoteRecord[];
  deferred?: string;
  control: ProfileFileControl;
}
const key = (id: string, revisionId: string) => JSON.stringify([id, revisionId]);
const fail = (message: string): never => { throw new GatewayError("conflict", message, false, { kind: "profile_file_invalid" }); };
function object(value: unknown): value is Record<string, unknown> { return !!value && typeof value === "object" && !Array.isArray(value); }
function note(value: unknown): ProfileNoteRecord {
  let record: ProfileNoteRecord;
  try {
    if (!object(value) || Object.keys(value).some(field => !["kind", "scope", "provenance", "relations", "content", "schemaVersion", "id", "revisionId", "createdAt", "updatedAt", "temporal"].includes(field))) fail("Unknown Profile record field");
    record = validateProfileNoteRecord(value);
  } catch { return fail("Invalid Profile record"); }
  if (record.scope !== "personal" || !record.content.tags?.includes("home-profile")) fail("The Profile file accepts only personal Profile notes");
  return record;
}
function claims(records: readonly ProfileNoteRecord[]): Set<string> {
  return new Set(records.flatMap(record => record.relations.filter(relation => relation.type === "corrects")
    .map(relation => key(relation.recordId, relation.revisionId ?? fail("A correction requires its exact wrong-claim revision")))));
}
function references(record: ProfileNoteRecord): string { return key(record.id, record.revisionId); }

export function profileFileRecords(file: ProfileFile): ProfileNoteRecord[] {
  const result: ProfileNoteRecord[] = [];
  const visit = (section: ProfileSection, path: string[]) => {
    if (!object(section) || Object.keys(section).some(field => !["notes", "children"].includes(field))
      || !Array.isArray(section.notes) || !object(section.children)) fail("Invalid Profile section");
    if (path[0] === "prior") {
      if (path.length !== 1 || Object.keys(section.children).length) fail("Prior organization cannot infer a destination");
    } else {
      if (path[0] === "inferred" && path.length === 1 && section.notes.length) fail("Unsorted notes need an explicit holding bucket");
      try { if (path[0] !== "inferred" || path.length > 1) profilePath(path.join("/")); }
      catch { fail("Invalid Profile section placement"); }
    }
    for (const stored of section.notes) {
      if (!object(stored) || !object(stored.content) || Object.hasOwn(stored.content, "profile")) fail("Current placement belongs only to its Profile section");
      const record = note({ ...stored, content: { ...stored.content,
        ...(path[0] === "prior" ? {} : { profile: profilePath(path.join("/")) }) } });
      result.push(record);
    }
    for (const [part, child] of Object.entries(section.children)) {
      if (!/^[a-z][a-z0-9-]{0,31}$/.test(part) || path.length >= 4) fail("Invalid Profile sub-area");
      visit(child, [...path, part]);
    }
  };
  if (!object(file.sections) || ROOTS.some(root => !Object.hasOwn(file.sections, root))
    || Object.keys(file.sections).some(root => !ROOTS.includes(root))) fail("Profile must retain its seven roots, Unsorted and Prior organization");
  for (const root of ROOTS) visit(file.sections[root]!, [root]);
  if (new Set(result.map(record => record.id)).size !== result.length) fail("Duplicate current Profile identity");
  return result;
}

export function validateProfileFile(value: unknown): ProfileFile {
  if (!object(value) || Object.keys(value).some(field => !["format", "version", "stateRevision", "sections", "anchors", "deferred", "control"].includes(field))
    || value.format !== "tron-profile" || value.version !== 2 || !Number.isSafeInteger(value.stateRevision) || (value.stateRevision as number) < 0
    || !Array.isArray(value.anchors) || (value.deferred !== undefined && (typeof value.deferred !== "string" || !/^[a-f0-9]{64}$/.test(value.deferred)))) fail("Unsupported Profile file format");
  const file = value as unknown as ProfileFile;
  if (!object(file.control) || Object.keys(file.control).some(field => !["config", "suppressions", "scopeExclusions", "commands"].includes(field))
    || !object(file.control.suppressions) || !object(file.control.scopeExclusions) || !object(file.control.commands)) fail("Invalid Profile control metadata");
  try { validateProfileNoteConfig(file.control.config); } catch { fail("Invalid Profile configuration"); }
  for (const command of Object.values(file.control.commands)) {
    if (!object(command) || typeof command.operation !== "string" || !/^[a-f0-9]{64}$/.test(command.requestHash) || !Number.isFinite(Date.parse(command.createdAt)) || !Array.isArray(command.recordIds)) fail("Invalid Profile command receipt");
    const checkMetadata = (value: unknown): void => {
      if (!value || typeof value !== "object") return;
      for (const [field, nested] of Object.entries(value)) {
        if (["body", "content", "history", "record", "originals", "prepared", "text"].includes(field)) fail("Profile command metadata cannot retain historical bodies");
        checkMetadata(nested);
      }
    };
    checkMetadata(command);
  }
  const records = profileFileRecords(file);
  const current = new Set(records.map(references));
  const needed = claims(records);
  const anchors = new Set<string>();
  for (const raw of file.anchors) {
    const record = note(raw), identity = references(record);
    if (!needed.has(identity) || current.has(identity) || file.control.suppressions[record.id]?.forgotten || anchors.has(identity)) fail("Profile cannot retain an unreferenced, duplicated or current claim as historical data");
    anchors.add(identity);
  }
  for (const record of records) if (file.control.suppressions[record.id]?.forgotten) fail("A forgotten Profile body cannot remain current");
  for (const identity of needed) if (!current.has(identity) && !anchors.has(identity) && !file.control.suppressions[JSON.parse(identity)[0]]?.forgotten) fail("A linked correction has no exact claim anchor");
  return file;
}

/** Construction may receive prior current heads as anchor candidates. Only exact
 * claims still linked by current Corrections survive; no history list is copied. */
export function createProfileFile(records: readonly ProfileNoteRecord[], input: {
  anchorCandidates?: readonly ProfileNoteRecord[]; stateRevision?: number; deferred?: string; control?: ProfileFileControl;
} = {}): ProfileFile {
  const file: ProfileFile = { format: "tron-profile", version: 2, stateRevision: input.stateRevision ?? 0,
    sections: Object.fromEntries(ROOTS.map(root => [root, { notes: [], children: {} }])), anchors: [], control: input.control ?? emptyProfileControl(),
    ...(input.deferred !== undefined ? { deferred: input.deferred } : {}) };
  for (const raw of records) {
    const record = note(raw), path = record.content.profile?.path ?? ["prior"];
    let section = file.sections[path[0]!] ?? fail("Unknown Profile area");
    for (const part of path.slice(1)) {
      if (!Object.hasOwn(section.children, part)) section.children[part] = { notes: [], children: {} };
      section = section.children[part]!;
    }
    const { profile: _placement, ...content } = record.content;
    section.notes.push({ ...record, content });
  }
  const current = new Set(records.map(references));
  const needed = claims(records);
  const candidates = new Map<string, ProfileNoteRecord>();
  for (const raw of input.anchorCandidates ?? []) {
    const identity = references(raw);
    if (!needed.has(identity) || current.has(identity)) continue;
    const record = note(raw);
    const previous = candidates.get(identity);
    if (previous && JSON.stringify(previous) !== JSON.stringify(record)) fail("Conflicting bodies for one correction claim identity");
    candidates.set(identity, record);
  }
  for (const identity of needed) if (!current.has(identity) && !file.control.suppressions[JSON.parse(identity)[0]]?.forgotten) file.anchors.push(candidates.get(identity) ?? fail("A linked correction has no exact claim anchor"));
  return validateProfileFile(file);
}

export function unavailableProfileRevision(id: string, revisionId: string): GatewayError {
  return new GatewayError("conflict", "This Profile revision is neither the current head nor a retained correction claim anchor", false,
    { kind: "profile_revision_unavailable", id, revisionId });
}

/** A missing explicit revision is a refusal, never an empty or archive-backed read. */
export function readProfileFileRecord(file: ProfileFile, id: string, revisionId?: string): ProfileNoteRecord | null {
  const records = profileFileRecords(file);
  const current = records.find(record => record.id === id);
  if (current && (revisionId === undefined || revisionId === current.revisionId)) return current;
  if (revisionId !== undefined) {
    const anchor = file.anchors.find(record => record.id === id && record.revisionId === revisionId);
    if (anchor && !file.control.suppressions[id]?.forgotten && claims(records).has(key(id, revisionId))) return anchor;
    throw unavailableProfileRevision(id, revisionId);
  }
  return null;
}

async function location(workspace: Pick<ResourceRoot, "describe">, create: boolean): Promise<string | undefined> {
  const descriptor = await workspace.describe();
  if (!descriptor.available) throw new GatewayError("conflict", "Tron workspace is unavailable");
  const directory = join(descriptor.root, "files");
  if (create) await mkdir(directory, { recursive: true, mode: 0o700 });
  const info = await lstat(directory).catch(error => { if (error.code === "ENOENT") return undefined; throw error; });
  if (!info) return undefined;
  if (!info.isDirectory() || info.isSymbolicLink() || info.uid !== process.getuid?.() || (info.mode & 0o022)) fail("Profile files directory must be an owned real directory without shared write access");
  return join(directory, "Profile.json");
}
export async function readProfileFile(workspace: Pick<ResourceRoot, "describe">): Promise<ProfileFile | undefined> {
  const path = await location(workspace, false);
  if (!path) return undefined;
  const read = await readSecureJson<unknown>(path, PROFILE_FILE_BYTES);
  return read.present ? validateProfileFile(read.value) : undefined;
}
/** Only the serialized file owner calls this after admitting a valid canonical
 * snapshot. Stages are discarded, never alternate data or recovery inputs. */
export async function discardProfileFileStages(workspace: Pick<ResourceRoot, "describe">): Promise<void> {
  const path = await location(workspace, false);
  if (!path) return;
  for (const name of await readdir(dirname(path))) if (/^Profile\.json\.\d+\.[a-f0-9]{12}\.tmp$/.test(name)) {
    const stage = join(dirname(path), name), info = await lstat(stage);
    if (!info.isFile() || info.isSymbolicLink() || info.uid !== process.getuid?.() || (info.mode & 0o777) !== 0o600) fail("Unsafe Profile publication stage");
    await durableRemove(stage);
  }
}
export async function writeProfileFile(workspace: Pick<ResourceRoot, "describe">, file: ProfileFile): Promise<void> {
  validateProfileFile(file);
  await durablePublishBoundedJson((await location(workspace, true))!, file, PROFILE_FILE_BYTES);
}
