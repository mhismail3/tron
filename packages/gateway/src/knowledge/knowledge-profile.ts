import { createHash } from "node:crypto";
import { join } from "node:path";
import { GatewayError } from "../errors.js";
import { durableAtomicWriteJson } from "../util/durable-json.js";
import type { KnowledgeRecord, KnowledgeRecordDraft, NoteContent } from "./knowledge-contract.js";

/** A note's labels and retirement are owner state that a native client's typed draft
 * does not model. An edit that omits them keeps the current revision's, so a confirmation
 * or edit cannot silently remove a note from the owner's role; an edit that names them
 * replaces them. `retired: false` clears retirement and is never stored. */
export function carryNoteMarks(current: KnowledgeRecord, content: NoteContent): NoteContent {
  if (current.kind !== "note") return storedNoteContent(content);
  const tags = content.tags ?? current.content.tags;
  const retired = content.retired ?? current.content.retired;
  const { retired: _named, ...rest } = content;
  return { ...rest, ...(tags ? { tags } : {}), ...(retired ? { retired: true } : {}) };
}
/** A stored note revision holds `retired: true` or nothing. */
export function storedNoteContent(content: NoteContent): NoteContent {
  if (content.retired !== false) return content;
  const { retired: _cleared, ...rest } = content;
  return rest;
}

type ProfileHead = { kind: KnowledgeRecord["kind"]; scope: KnowledgeRecord["scope"]; latestRevisionId: string; revisionIds: string[] };
export type ProfileAssignment = { id: string; expectedRevision: string; file: string };
function invalid(message: string): GatewayError { return new GatewayError("invalid_request", message); }
function conflict(message: string): GatewayError { return new GatewayError("conflict", message); }

/** Store-owned catalog reads isolate a bad body without weakening record visibility. */
export async function readProfileRecords(heads: Iterable<[string, ProfileHead]>, read: (id: string, revision: string) => Promise<KnowledgeRecord | undefined>, visible: (record: KnowledgeRecord) => boolean) {
      const notes: Array<KnowledgeRecord & { kind: "note" }> = [];
      const diagnostics: string[] = [];
      for (const [id, head] of heads) {
        if (head.kind !== "note" || head.scope !== "personal") continue;
        try {
          const note = await read(id, head.latestRevisionId);
          if (!note || !visible(note)) continue;
          if (note.kind === "note" && note.content.tags?.includes("home-profile")) notes.push(note);
        } catch {
          // A damaged immutable body must not suppress unrelated accepted rules.
          diagnostics.push(`Profile diagnostic: Knowledge file records/${id}/${head.latestRevisionId}.json is missing or corrupt; other profile files remain loaded.`);
        }
      }
      return { notes, diagnostics };
}

/** Caller holds the Knowledge transaction; helper owns only profile-note labels/backup. */
export async function organizeProfileRecords(commandId: string, assignments: readonly ProfileAssignment[], port: {
  root: string; heads: Iterable<[string, ProfileHead]>;
  read(id: string): Promise<KnowledgeRecord | null>;
  write(record: KnowledgeRecordDraft, expectedRevision: string): Promise<{ record: KnowledgeRecord }>;
}): Promise<{ records: KnowledgeRecord[]; backup: string | null }> {
  const heads = new Map(port.heads);
      if (!assignments.length || assignments.length > 500 || new Set(assignments.map(item => item.id)).size !== assignments.length) throw invalid("Profile migration requires distinct assignments for 1..500 notes");
      const notes: KnowledgeRecord[] = [];
      for (const [id, head] of heads.entries()) {
        if (head.kind !== "note" || head.scope !== "personal") continue;
        const note = await port.read(id);
        if (note?.kind === "note" && note.content.tags?.includes("home-profile")) notes.push(note);
      }
      if (notes.length !== assignments.length || notes.some(note => !assignments.some(item => item.id === note.id))) throw conflict("Profile changed: migration must assign every profile note exactly once");
      for (const item of assignments) {
        const note = notes.find(note => note.id === item.id)!;
        if (note.revisionId !== item.expectedRevision) throw conflict("Profile revision is stale");
        if (!/^(core|home|scopes\/[a-z][a-z0-9-]{0,47})$/.test(item.file)) throw invalid("Invalid profile file");
      }
      const changed = assignments.filter(item => {
        const note = notes.find(note => note.id === item.id)!;
        return note.kind === "note" && JSON.stringify(note.content.tags?.filter(tag => tag.startsWith("home-file-"))) !== JSON.stringify([`home-file-${item.file.replace("/", "-")}`]);
      });
      if (!changed.length) return { records: [], backup: null };
      if (notes.every(note => note.kind === "note" && note.content.tags?.some(tag => tag.startsWith("home-file-")))) throw conflict("Profile is already organized; use refine to move an item between files");
      const backup = `profile-backup-${createHash("sha256").update(commandId).digest("hex")}.json`;
      await durableAtomicWriteJson(join(port.root, backup), { version: 1, notes, histories: notes.map(note => ({ id: note.id, revisions: heads.get(note.id)!.revisionIds })) }, 0o600);
      const records: KnowledgeRecord[] = [];
      for (const item of changed) {
        const note = notes.find(note => note.id === item.id)!;
        if (note.kind !== "note") throw invalid("Profile member is not a note");
        const tags = [...(note.content.tags ?? []).filter(tag => !tag.startsWith("home-file-")), `home-file-${item.file.replace("/", "-")}`];
        const result = await port.write({ ...note, content: { ...note.content, tags } }, note.revisionId);
        records.push(result.record);
      }
      return { records, backup }
}
