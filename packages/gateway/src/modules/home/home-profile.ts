import { profileFile, profileFileTags, type ProfileFile } from "../../knowledge/knowledge-notes.js";
import { profileIndex, PROFILE_SECTION_HEADING } from "./home-profile-hierarchy.js";
import { randomUUID } from "node:crypto";
import { formatProfileValue } from "../../admin/settings-presentation.js";
import type { SettingsChangePath, SubjectContext, SubjectWrite, ChangeContext } from "../../kernel/settings/settings-change.js";
import type { ChangeEntry } from "../../kernel/settings/settings-record.js";
import type { ChangeResult } from "../../kernel/settings/tool-contract.js";
import { GatewayError } from "../../errors.js";
import type { KnowledgeListResponse, KnowledgeProvenance, KnowledgeRecord, KnowledgeRelation, NoteContent } from "../../knowledge/knowledge-contract.js";
import type { KnowledgeService } from "../../knowledge/knowledge-service.js";
import type { KnowledgeMutationResult } from "../../knowledge/knowledge-store.js";

/*
 * Tron Home's learned profile (#731): the maintainer's durable preferences,
 * standing decisions, delegation defaults and facts, kept as personal Knowledge
 * notes. Home writes them through the `profile` tool. Activations carry a metadata
 * index; explicit reads carry exact content/provenance, never Gateway relevance
 * choices or mandatory worker copying. Knowledge stays the only record authority.
 *
 * Membership is the `home-profile` tag alone, never provenance: provenance changes
 * when the maintainer edits a note natively. A profile item's kind is its one
 * `kind-*` label. File labels are mechanical organization, not binding authority.
 */

/** The label that makes a personal note a Home profile item. */
const HOME_PROFILE_TAG = "home-profile";
export const HOME_PROFILE_KINDS = ["preference", "standing-decision", "delegation-default", "fact"] as const;
export type HomeProfileKind = (typeof HOME_PROFILE_KINDS)[number];
/** The note role each kind is stored under; the kind label itself is what Home reads back. */
const KIND_ROLE: Record<HomeProfileKind, NoteContent["role"]> = {
  preference: "preference",
  "standing-decision": "decision",
  "delegation-default": "workflow",
  fact: "fact",
};

/** Metadata-index admission headroom; note bodies are read explicitly, never inserted here. */
export const HOME_PROFILE_BOUND_BYTES = 8 * 1_024;
const PROFILE_PAGE_LIMIT = 50;
export type HomeProfileStatus = "active" | "superseded" | "retired";
export type ProfileNote = KnowledgeRecord & { kind: "note" };

export interface HomeProfileItem {
  id: string;
  revisionId: string;
  file: ProfileFile | null | undefined;
  kind: HomeProfileKind;
  text: string;
  confirmed: boolean;
  status: HomeProfileStatus;
  /** The profile note this one supersedes, through its own current revision's relation. */
  supersedes?: string;
  /** The profile note that supersedes this one, when it is superseded. */
  supersededBy?: string;
  record: ProfileNote;
}

export interface HomeProfileRead {
  items: HomeProfileItem[];
  /** Existing native-list count: notes without one recognized kind. */
  unclassified: number;
  /** Mechanical metadata failures, with exact canonical references for explicit repair. */
  diagnostics: Array<{ id: string; revisionId: string; issues: Array<"kind" | "partition"> }>;
}

/** Every profile note in the personal scope, classified. A pure read through Knowledge's
 * list owner: it never admits a model call. Superseded status is derived, not stored: a
 * profile note is superseded when another profile note's current revision names it in a
 * `supersedes` relation. A superseding note that is itself retired still supersedes. */
export async function readHomeProfile(knowledge: KnowledgeService): Promise<HomeProfileRead> {
  const notes: ProfileNote[] = [];
  let cursor: string | undefined;
  do {
    const page = await knowledge.invoke({ operation: "knowledge.list", request: {
      kind: "note", scope: "personal", limit: PROFILE_PAGE_LIMIT, ...(cursor ? { cursor } : {}),
    } }) as KnowledgeListResponse;
    for (const record of page.records) {
      if (record.kind === "note" && record.content.tags?.includes(HOME_PROFILE_TAG) === true) notes.push(record as ProfileNote);
    }
    cursor = page.nextCursor;
  } while (cursor);

  const supersededBy = new Map<string, string>();
  for (const note of notes) {
    for (const relation of note.relations) if (relation.type === "supersedes" && !supersededBy.has(relation.recordId)) supersededBy.set(relation.recordId, note.id);
  }
  const profileIds = new Set(notes.map(note => note.id));
  const items: HomeProfileItem[] = [];
  const diagnostics: HomeProfileRead["diagnostics"] = [];
  for (const note of notes) {
    const tags = note.content.tags ?? [];
    const kinds = HOME_PROFILE_KINDS.filter((kind) => tags.includes(kindTag(kind)));
    const file = profileFile(tags);
    const issues: HomeProfileRead["diagnostics"][number]["issues"] = [];
    if (kinds.length !== 1) issues.push("kind");
    if (file === null) issues.push("partition");
    if (issues.length) diagnostics.push({ id: note.id, revisionId: note.revisionId, issues });
    if (kinds.length !== 1) continue;
    const by = supersededBy.get(note.id);
    const status: HomeProfileStatus = note.content.retired ? "retired" : by ? "superseded" : "active";
    const supersedes = note.relations.find(relation => relation.type === "supersedes" && profileIds.has(relation.recordId))?.recordId;
    items.push({ id: note.id, revisionId: note.revisionId, file, kind: kinds[0]!, text: note.content.title, confirmed: note.content.confirmed, status,
      ...(supersedes ? { supersedes } : {}), ...(by ? { supersededBy: by } : {}), record: note });
  }
  items.sort((left, right) => HOME_PROFILE_KINDS.indexOf(left.kind) - HOME_PROFILE_KINDS.indexOf(right.kind)
    || left.record.createdAt.localeCompare(right.record.createdAt) || left.id.localeCompare(right.id));
  return { items, unclassified: diagnostics.filter(item => item.issues.includes("kind")).length, diagnostics: diagnostics.sort((left, right) => left.id.localeCompare(right.id)) };
}

function kindTag(kind: HomeProfileKind): string {
  return `kind-${kind}`;
}

export async function homeProfileSection(knowledge: () => KnowledgeService | undefined): Promise<{ text: string; notes: number }> {
  const owner = knowledge();
  if (!owner) return { text: unavailableSection("Knowledge is not available on this Gateway"), notes: 0 };
  try {
    const read = await readHomeProfile(owner);
    return { text: profileIndex(read), notes: read.items.filter((item) => item.status === "active").length };
  } catch (error) {
    return { text: unavailableSection(`reading Knowledge failed (${error instanceof Error ? error.message.slice(0, 200) : "unknown error"})`), notes: 0 };
  }
}

function unavailableSection(reason: string): string {
  return [PROFILE_SECTION_HEADING, `Unavailable: ${reason}. No item is applied in this instruction, and the profile is not known to be empty.`].join("\n");
}

// ---- profile changes: one implementation for Home and the maintainer ------------
//
// Every profile change, Home's `profile` tool and the maintainer's `home.profileChange`
// alike, runs through `HomeProfileItems` inside the settings change path
// (`SettingsChangePath.auditSubject`), which serializes it, records one audit entry per
// note it touched and makes it undoable (docs/settings-model.md 6.4). The actor decides
// only what the note says about confirmation: Home's changes stay inferred until the
// maintainer confirms them, and the maintainer's own edits are confirmed by definition.

/** The record subject of a profile change: one instance per note, qualified by `note`. */
export const HOME_PROFILE_ACTIONS = ["learn", "refine", "supersede", "retire"] as const;
export type HomeProfileAction = (typeof HOME_PROFILE_ACTIONS)[number];
/** The maintainer's actions; `confirm` is his alone. */
export const HOME_PROFILE_MAINTAINER_ACTIONS = ["confirm", "refine", "supersede", "retire"] as const;
export type HomeProfileChangeAction = HomeProfileAction | "confirm";

/** One requested change. `expectedRevision` is the revision the requester read: a note
 * changed since is refused with a conflict rather than overwritten. */
export type HomeProfileOp =
  | { action: "learn"; kind: HomeProfileKind; text: string; file?: ProfileFile }
  | { action: "confirm"; id: string; expectedRevision?: string }
  | { action: "refine"; id: string; text?: string; kind?: HomeProfileKind; reason?: string; expectedRevision?: string }
  | { action: "supersede"; id: string; kind: HomeProfileKind; text: string; reason?: string; expectedRevision?: string }
  | { action: "retire"; id: string; reason?: string; expectedRevision?: string };

/** Who writes. Home cites the maintainer message its turn answers. */
export type HomeProfileAuthor =
  | { kind: "home"; sessionId: string; entryId: string }
  | { kind: "maintainer" };

/** A profile note's state as the change record holds it: `before` and `after` of every
 * profile change, and what undo restores. `null` is a note that did not exist. */
export interface HomeProfileValue {
  kind: HomeProfileKind;
  text: string;
  confirmed: boolean;
  state: HomeProfileStatus;
  revisionId: string;
  supersedes?: string;
  supersededBy?: string;
}

export interface HomeProfileWrite { id: string; before: HomeProfileValue | null; after: HomeProfileValue | null }

/** What one change saved, as the tool result and the RPC answer state it. */
export interface HomeProfileSaved {
  status: "saved";
  action: HomeProfileChangeAction;
  id: string;
  revisionId: string;
  kind?: HomeProfileKind;
  supersededId?: string;
  previousRevisionId?: string;
  /** refine, supersede and retire: the changed item's text before this change, so a reader sees what was replaced. */
  previousText?: string;
}

export function profileValue(item: HomeProfileItem | undefined): HomeProfileValue | null {
  if (!item) return null;
  return { kind: item.kind, text: item.text, confirmed: item.confirmed, state: item.status, revisionId: item.revisionId,
    ...(item.supersedes ? { supersedes: item.supersedes } : {}), ...(item.supersededBy ? { supersededBy: item.supersededBy } : {}) };
}

/** The list projection of an item (`home.profileList` and the change answer). */
export function profileListItem(item: HomeProfileItem) {
  return { id: item.id, revisionId: item.revisionId, kind: item.kind, text: item.text, confirmed: item.confirmed,
    status: item.status, createdAt: item.record.createdAt, updatedAt: item.record.updatedAt };
}

const SINGLE_LINE = /[\u0000-\u001f\u007f\u2028\u2029]/;
export const PROFILE_TEXT_MAX = 512;
export const PROFILE_REASON_MAX = 2_000;

/** The one validation every actor's request passes. */
function validateProfileOp(op: HomeProfileOp, author: HomeProfileAuthor["kind"]): string | undefined {
  if (op.action === "confirm" && author !== "maintainer") return "only the maintainer confirms an item";
  if (op.action === "refine" && op.text === undefined && op.kind === undefined) return "refine requires text or kind";
  if (op.action === "retire" && author === "home" && op.reason === undefined) return "retire requires reason";
  const text = "text" in op ? op.text : undefined;
  if (text !== undefined && (typeof text !== "string" || text.trim() === "" || text.length > PROFILE_TEXT_MAX || SINGLE_LINE.test(text))) return "text must be one non-empty line";
  const reason = "reason" in op ? op.reason : undefined;
  if (reason !== undefined && (typeof reason !== "string" || reason.trim() === "" || reason.length > PROFILE_REASON_MAX || SINGLE_LINE.test(reason))) return "reason must be one non-empty line";
  const kind = "kind" in op ? op.kind : undefined;
  if (kind !== undefined && !HOME_PROFILE_KINDS.includes(kind)) return "kind is not a profile kind";
  return undefined;
}

function provenance(author: HomeProfileAuthor, reason?: string): KnowledgeProvenance {
  if (author.kind === "maintainer") return { actor: "user", source: "home-profile", evidence: [], ...(reason ? { reason } : {}) };
  return {
    actor: "agent",
    source: "home",
    sessionId: author.sessionId,
    evidence: [{ sessionEntry: { sessionId: author.sessionId, entryId: author.entryId } }],
    ...(reason ? { reason } : {}),
  };
}

/** The note's labels with its one kind label set to `kind`; other labels are kept. */
function kindTags(tags: readonly string[] | undefined, kind: HomeProfileKind): string[] {
  const kept = (tags ?? []).filter(tag => tag !== HOME_PROFILE_TAG && !HOME_PROFILE_KINDS.some(candidate => tag === kindTag(candidate)));
  return [HOME_PROFILE_TAG, kindTag(kind), ...kept];
}

function staleConflict(error: unknown, current: HomeProfileItem | undefined): unknown {
  if (error instanceof GatewayError && error.code === "conflict" && /stale/u.test(error.message)) {
    return new GatewayError("conflict", "This profile item changed since it was read; review it and try again", false,
      current ? { current: profileListItem(current) } : undefined);
  }
  return error;
}

/**
 * The profile's applier: the Knowledge note writes behind every profile change and
 * undo. It holds no state: each call reads the profile through `readHomeProfile`, writes
 * notes through the Knowledge owner with its revision fence, and reads back what it wrote.
 */
export interface ProfileChangeContext extends SubjectContext { author: HomeProfileAuthor }
export interface ProfileChangeResult extends ChangeResult {
  status: "applied";
  saved: HomeProfileSaved[];
  items: ReturnType<typeof profileListItem>[];
}

export class HomeProfileItems {
  constructor(private readonly knowledge: () => KnowledgeService | undefined) {}

  available(): boolean {
    return this.knowledge() !== undefined;
  }

  /** Domain operations stay here; the settings engine owns their stripe and audit. */
  async change(changes: SettingsChangePath, ops: readonly HomeProfileOp[], context: ProfileChangeContext): Promise<ProfileChangeResult> {
    if (!this.available()) throw new GatewayError("unsupported", "Knowledge is not available on this Gateway");
    if (ops.length === 0 || ops.length > 50) throw new GatewayError("invalid_request", "A profile change holds 1 to 50 changes");
    return changes.auditSubject(async () => {
      const applied: Array<{ saved: HomeProfileSaved; writes: HomeProfileWrite[] }> = [];
      const audited = (write: HomeProfileWrite): SubjectWrite => ({
        ...write, direction: ops[applied.findIndex(done => done.writes.includes(write))]?.action === "retire" ? "narrow" : "widen",
      });
      try {
        for (const [index, op] of ops.entries()) applied.push(await this.apply(op, context.author, `${context.commandId}:${index}`));
      } catch (error) {
        for (const [index, done] of [...applied].reverse().entries()) {
          await this.restore(done.writes.map(write => ({ id: write.id, value: write.before })), context.author, `${context.commandId}:rollback:${index}`)
            .catch(() => undefined);
        }
        const failure = applied.length ? `Rolled back: ${error instanceof Error ? error.message : String(error)}` : "";
        return { status: "failed", context, writes: applied.flatMap(done => done.writes).map(audited), error, failure };
      }
      const writes = applied.flatMap(done => done.writes);
      return { status: "applied", context, writes: writes.map(audited), result: { writes, saved: applied.map(done => done.saved) } };
    }, async (result, audit) => {
      const read = await this.read();
      const items = result.writes.flatMap(write => read.items.filter(item => item.id === write.id)).map(profileListItem);
      return { ...audit, status: "applied", saved: result.saved, items };
    });
  }

  /** Group/value fencing, restoration and projection all remain under the Home stripe. */
  async undo(changes: SettingsChangePath, entry: ChangeEntry, context: Omit<ChangeContext, "undoOf">): Promise<ProfileChangeResult> {
    if (!this.available()) throw new GatewayError("unsupported", "Knowledge is not available on this Gateway");
    if (context.actor.kind !== "ui") throw new GatewayError("invalid_request", "Only the maintainer undoes a profile change");
    return changes.auditSubject(async () => {
      const members = entry.group ? await changes.record.group(entry.group.id, entry.group.size) : [entry];
      if (members.some(member => member.status !== "applied")) throw new GatewayError("conflict", "Only an applied change can be undone");
      const ids = members.map(member => member.qualifiers?.note ?? "");
      const current = await this.values(ids);
      for (const member of members) {
        const now = current.get(member.qualifiers?.note ?? "") ?? null;
        const after = member.after ?? null;
        if (JSON.stringify(now) !== JSON.stringify(after)) {
          throw new GatewayError("conflict", "The profile item changed since; undo would overwrite a newer change", false,
            { current: now as never, after: after as never, display: { current: formatProfileValue(now), after: formatProfileValue(after) } });
        }
      }
      const commandId = context.commandId ?? randomUUID();
      const writes = await this.restore(members.map(member => ({ id: member.qualifiers!.note!, value: (member.before ?? null) as never })),
        { kind: "maintainer" }, commandId, "Undo");
      const undoOf = new Map(members.map(member => [member.qualifiers!.note!, member.changeId]));
      return { status: "applied", context: { actor: context.actor, commandId },
        writes: writes.map(write => ({ ...write, direction: "widen" as const, ...(undoOf.get(write.id) ? { undoOf: undoOf.get(write.id)! } : {}) })), result: writes };
    }, async (writes, audit) => {
      const read = await this.read();
      const items = writes.flatMap(write => read.items.filter(item => item.id === write.id)).map(profileListItem);
      return { ...audit, status: "applied", saved: [], items };
    });
  }

  private owner(): KnowledgeService {
    const owner = this.knowledge();
    if (!owner) throw new GatewayError("unsupported", "Knowledge is not available on this Gateway");
    return owner;
  }

  async read(): Promise<HomeProfileRead> {
    return readHomeProfile(this.owner());
  }

  /** One change. `commandId` keys Knowledge's idempotency receipts for its writes. */
  async apply(op: HomeProfileOp, author: HomeProfileAuthor, commandId: string): Promise<{ saved: HomeProfileSaved; writes: HomeProfileWrite[] }> {
    const refusal = validateProfileOp(op, author.kind);
    if (refusal) throw new GatewayError("invalid_request", refusal);
    const owner = this.owner();
    const confirmed = author.kind === "maintainer";
    const before = await readHomeProfile(owner);
    const existing = "id" in op ? before.items.find(item => item.id === op.id) : undefined;
    // The previous contract made confirmed standing rules binding. Home may propose
    // a new inferred item, but cannot rewrite or retire that existing authority.
    if (author.kind === "home" && existing?.confirmed && existing.kind !== "fact") {
      throw new GatewayError("invalid_request", "An existing confirmed standing rule needs maintainer review; Home cannot weaken or rewrite it");
    }
    const result = await this.write(owner, op, author, confirmed, before, commandId);
    const after = await readHomeProfile(owner);
    const ids = result.supersededId ? [result.supersededId, result.id] : [result.id];
    return { saved: result, writes: ids.map(id => ({
      id, before: profileValue(before.items.find(item => item.id === id)), after: profileValue(after.items.find(item => item.id === id)),
    })) };
  }

  private async write(owner: KnowledgeService, op: HomeProfileOp, author: HomeProfileAuthor, confirmed: boolean, profile: HomeProfileRead, commandId: string): Promise<HomeProfileSaved> {
    const create = async (kind: HomeProfileKind, text: string, relations: KnowledgeRelation[], reason?: string) => {
      const { record } = await owner.invoke({ operation: "knowledge.note.create", request: {
        commandId, ...(confirmed ? { confirmedByUser: true } : {}),
        record: { kind: "note", scope: "personal", provenance: provenance(author, reason), relations,
          content: { title: text, role: KIND_ROLE[kind], confirmed, tags: profileFileTags([HOME_PROFILE_TAG, kindTag(kind)], op.action === "learn" ? op.file ?? "core" : "core") } },
      } }) as KnowledgeMutationResult;
      return record;
    };
    if (op.action === "learn") {
      const record = await create(op.kind, op.text.trim(), []);
      return { status: "saved", action: "learn", id: record.id, revisionId: record.revisionId, kind: op.kind };
    }
    const item = profile.items.find(candidate => candidate.id === op.id);
    if (!item) throw new GatewayError("invalid_request", `note ${op.id} is not a Home profile item`);
    if (item.status !== "active") throw new GatewayError("conflict", `profile item ${item.id} is ${item.status}; only an active item can change`, false, { current: profileListItem(item) });
    if (op.expectedRevision !== undefined && op.expectedRevision !== item.revisionId) {
      throw new GatewayError("conflict", "This profile item changed since it was read; review it and try again", false, { current: profileListItem(item) });
    }
    if (op.action === "confirm" && item.confirmed) throw new GatewayError("conflict", `profile item ${item.id} is already confirmed`, false, { current: profileListItem(item) });
    const current = item.record;
    const update = async (content: NoteContent, reason?: string) => {
      try {
        const { record } = await owner.invoke({ operation: "knowledge.note.update", request: {
          commandId, recordId: current.id, expectedRevision: current.revisionId, ...(content.confirmed ? { confirmedByUser: true } : {}),
          record: { kind: "note", scope: "personal", provenance: provenance(author, reason), relations: current.relations, content },
        } }) as KnowledgeMutationResult;
        return record;
      } catch (error) {
        throw staleConflict(error, (await readHomeProfile(owner)).items.find(candidate => candidate.id === current.id));
      }
    };
    if (op.action === "confirm") {
      const record = await update({ ...current.content, confirmed: true });
      return { status: "saved", action: "confirm", id: record.id, revisionId: record.revisionId, previousRevisionId: current.revisionId, kind: item.kind };
    }
    if (op.action === "refine") {
      const kind = op.kind ?? item.kind;
      const record = await update({ ...current.content, title: op.text?.trim() ?? item.text, role: KIND_ROLE[kind], tags: kindTags(current.content.tags, kind), confirmed }, op.reason?.trim());
      return { status: "saved", action: "refine", id: record.id, revisionId: record.revisionId, previousRevisionId: current.revisionId, kind, previousText: item.text };
    }
    if (op.action === "supersede") {
      const record = await create(op.kind, op.text.trim(), [{ type: "supersedes", recordId: current.id, revisionId: current.revisionId }], op.reason?.trim());
      return { status: "saved", action: "supersede", id: record.id, revisionId: record.revisionId, kind: op.kind, supersededId: current.id, previousText: item.text };
    }
    const record = await update({ ...current.content, retired: true }, op.reason?.trim());
    return { status: "saved", action: "retire", id: record.id, revisionId: record.revisionId, previousRevisionId: current.revisionId, kind: item.kind, previousText: item.text };
  }

  /** Each note's current value, for undo's "unchanged since" check. */
  async values(ids: readonly string[]): Promise<Map<string, HomeProfileValue | null>> {
    const read = await readHomeProfile(this.owner());
    return new Map(ids.map(id => [id, profileValue(read.items.find(item => item.id === id))]));
  }

  /**
   * Writes each note back to a recorded value: its text, kind and confirmation, its
   * retirement, and the profile note it supersedes. A note recorded as absent is retired.
   * A superseded value needs nothing of its own: its superseding note, restored in the
   * same call, carries the relation. Notes already equal to their target are not written.
   */
  async restore(targets: ReadonlyArray<{ id: string; value: HomeProfileValue | null }>, author: HomeProfileAuthor, commandId: string, reason?: string): Promise<HomeProfileWrite[]> {
    const owner = this.owner();
    const before = await readHomeProfile(owner);
    for (const [index, target] of targets.entries()) {
      const item = before.items.find(candidate => candidate.id === target.id);
      if (!item) throw new GatewayError("conflict", `note ${target.id} is no longer a Home profile item`);
      const note = item.record;
      const value = target.value;
      const kind = value?.kind ?? item.kind;
      const content: NoteContent = {
        ...note.content,
        ...(value ? { title: value.text, role: KIND_ROLE[kind], tags: kindTags(note.content.tags, kind), confirmed: value.confirmed } : {}),
        retired: value === null || value.state === "retired",
      };
      const otherRelations = note.relations.filter(relation => relation.type !== "supersedes"
        || !before.items.some(candidate => candidate.id === relation.recordId));
      const partner = value?.supersedes ? before.items.find(candidate => candidate.id === value.supersedes) : undefined;
      if (value?.supersedes && !partner) throw new GatewayError("conflict", `note ${value.supersedes} is no longer a Home profile item`);
      const relations = partner ? [...otherRelations, { type: "supersedes" as const, recordId: partner.id, revisionId: partner.revisionId }] : otherRelations;
      const unchanged = note.content.title === content.title && note.content.role === content.role && note.content.confirmed === content.confirmed
        && JSON.stringify(note.content.tags ?? []) === JSON.stringify(content.tags ?? []) && (note.content.retired === true) === (content.retired === true)
        && JSON.stringify(note.relations.filter(relation => relation.type === "supersedes").map(relation => relation.recordId))
          === JSON.stringify(relations.filter(relation => relation.type === "supersedes").map(relation => relation.recordId));
      if (unchanged) continue;
      try {
        await owner.invoke({ operation: "knowledge.note.update", request: {
          commandId: `${commandId}:${index}`, recordId: note.id, expectedRevision: note.revisionId, ...(content.confirmed ? { confirmedByUser: true } : {}),
          record: { kind: "note", scope: "personal", provenance: provenance(author, reason), relations, content },
        } });
      } catch (error) {
        throw staleConflict(error, item);
      }
    }
    const after = await readHomeProfile(owner);
    return targets.map(target => ({
      id: target.id, before: profileValue(before.items.find(item => item.id === target.id)), after: profileValue(after.items.find(item => item.id === target.id)),
    }));
  }
}

/** What the Home runtime gives the tool: the change path, as Home. */
export interface HomeProfileChangeAccess {
  change(ops: HomeProfileOp[], input: { toolCallId: string; web: boolean; author: HomeProfileAuthor; commandId: string; reason?: string }): Promise<{ saved: HomeProfileSaved[] }>;
}
