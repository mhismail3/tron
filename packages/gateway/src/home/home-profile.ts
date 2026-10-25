import { profileFile, profileFileTags, profileFileBytes, profileFileCap, profileConfirmationTags, renderProfileFiles, validProfileFile, PROFILE_SCOPE_LIMIT, type ProfileFile } from "./home-profile-files.js";
import { GatewayError } from "../errors.js";
import type { KnowledgeProvenance, KnowledgeRecord, KnowledgeRelation, NoteContent } from "../knowledge/knowledge-contract.js";
import type { KnowledgeService } from "../knowledge/knowledge-service.js";
import type { KnowledgeMutationResult } from "../knowledge/knowledge-store.js";

/*
 * Tron Home's learned profile (#731): the maintainer's durable preferences,
 * standing decisions, delegation defaults and facts, kept as personal Knowledge
 * notes. Home writes them through the `profile` tool and reads them back into its
 * own instructions on every activation. The Knowledge owner stays the only
 * authority: this module holds no state of its own.
 *
 * Membership is the `home-profile` tag alone, never provenance: provenance changes
 * when the maintainer edits a note natively. A profile item's kind is its one
 * `kind-*` label, so its order and its brief line never depend on prose.
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

/** The section heading. Stable text: the cached prompt head changes only with the items. */
const HOME_PROFILE_HEADING = "## Learned profile";

export type HomeProfileStatus = "active" | "superseded" | "retired";
export type ProfileNote = KnowledgeRecord & { kind: "note" };

export interface HomeProfileItem {
  file?: ProfileFile;
  why: string;
  lastConfirmedDate: string | null;
  id: string;
  revisionId: string;
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
  diagnostics: string[];
  items: HomeProfileItem[];
  /** Profile-tagged notes that carry no single valid kind label; they are not applied. */
  unclassified: number;
}

/** Every profile note in the personal scope, classified. A pure read through Knowledge's
 * list owner: it never admits a model call. Superseded status is derived, not stored: a
 * profile note is superseded when another profile note's current revision names it in a
 * `supersedes` relation. A superseding note that is itself retired still supersedes. */
export async function readHomeProfile(knowledge: KnowledgeService): Promise<HomeProfileRead> {
  const { notes, diagnostics } = await knowledge.store.readProfileNotes();

  const supersededBy = new Map<string, string>();
  for (const note of notes) {
    for (const relation of note.relations) if (relation.type === "supersedes" && !supersededBy.has(relation.recordId)) supersededBy.set(relation.recordId, note.id);
  }
  const profileIds = new Set(notes.map(note => note.id));
  const items: HomeProfileItem[] = [];
  let unclassified = 0;
  for (const note of notes) {
    const tags = note.content.tags ?? [];
    const kinds = HOME_PROFILE_KINDS.filter((kind) => tags.includes(kindTag(kind)));
    if (kinds.length !== 1) { unclassified += 1; continue; }
    const by = supersededBy.get(note.id);
    const status: HomeProfileStatus = note.content.retired ? "retired" : by ? "superseded" : "active";
    const supersedes = note.relations.find(relation => relation.type === "supersedes" && profileIds.has(relation.recordId))?.recordId;
    let file: ProfileFile | undefined;
    try { file = profileFile(tags); }
    catch { diagnostics.push(`Profile diagnostic: note ${note.id} has corrupt file metadata; its rule remains in core until repaired.`); }
    items.push({ ...(file ? { file } : {}), why: note.provenance.reason ?? "A durable preference stated by the maintainer.",
      lastConfirmedDate: tags.find(tag => /^home-confirmed-\d{4}-\d{2}-\d{2}$/.test(tag))?.slice(15) ?? (note.content.confirmed ? note.updatedAt.slice(0, 10) : null),
      id: note.id, revisionId: note.revisionId, kind: kinds[0]!, text: note.content.title, confirmed: note.content.confirmed, status,
      ...(supersedes ? { supersedes } : {}), ...(by ? { supersededBy: by } : {}), record: note });
  }
  items.sort((left, right) => HOME_PROFILE_KINDS.indexOf(left.kind) - HOME_PROFILE_KINDS.indexOf(right.kind)
    || left.record.createdAt.localeCompare(right.record.createdAt) || left.id.localeCompare(right.id));
  return { items, unclassified, diagnostics };
}

function kindTag(kind: HomeProfileKind): string {
  return `kind-${kind}`;
}

/** The section for one activation's system prompt. Unavailability is said, never shown as
 * an empty profile: Home must not assume it has no preferences when it could not read them. */
/** The learned-profile section and how many active notes it lists (`notes` is 0 when the
 * section could not be read: no item is applied then). */
export async function homeProfileSection(knowledge: () => KnowledgeService | undefined): Promise<{ text: string; notes: number; diagnostics: string[] }> {
  const owner = knowledge();
  if (!owner) return { text: unavailableSection("Knowledge is not available on this Gateway"), notes: 0, diagnostics: ["Profile diagnostic: Knowledge is not available on this Gateway."] };
  try {
    const read = await readHomeProfile(owner);
    return renderProfileFiles(read);
  } catch (error) {
    return { text: unavailableSection(`reading Knowledge failed (${error instanceof Error ? error.message.slice(0, 200) : "unknown error"})`), notes: 0, diagnostics: ["Profile diagnostic: Knowledge could not be read; the profile is unavailable, not empty."] };
  }
}

export async function homeDelegationProfile(knowledge: KnowledgeService, scopes: readonly string[]) {
  return renderProfileFiles(await readHomeProfile(knowledge), scopes);
}

function unavailableSection(reason: string): string {
  return [HOME_PROFILE_HEADING, `Unavailable: ${reason}. No item is applied in this instruction, and the profile is not known to be empty.`].join("\n");
}

// ---- profile changes: one implementation for Home and the maintainer ------------
//
// Every profile change, Home's `profile` tool and the maintainer's `home.profileChange`
// alike, runs through `HomeProfileItems` inside the settings change path
// (`SettingsChangePath.changeProfile`), which serializes it, records one audit entry per
// note it touched and makes it undoable (docs/settings-model.md 6.4). The actor decides
// only what the note says about confirmation: Home's changes stay inferred until the
// maintainer confirms them, and the maintainer's own edits are confirmed by definition.

/** The record subject of a profile change: one instance per note, qualified by `note`. */
export const HOME_PROFILE_ACTIONS = ["learn", "refine", "supersede", "retire", "read", "migrate"] as const;
export type HomeProfileAction = (typeof HOME_PROFILE_ACTIONS)[number];
/** The maintainer's actions; `confirm` is his alone. */
export const HOME_PROFILE_MAINTAINER_ACTIONS = ["confirm", "refine", "supersede", "retire", "migrate"] as const;
export type HomeProfileChangeAction = HomeProfileAction | "confirm" | "migrate";

/** One requested change. `expectedRevision` is the revision the requester read: a note
 * changed since is refused with a conflict rather than overwritten. */
export type HomeProfileOp = (
  | { action: "migrate"; assignments: Array<{ id: string; expectedRevision: string; file: ProfileFile }> }
  | { action: "learn"; kind: HomeProfileKind; text: string; file?: ProfileFile; reason?: string }
  | { action: "confirm"; id: string; expectedRevision?: string }
  | { action: "refine"; id: string; text?: string; kind?: HomeProfileKind; file?: ProfileFile; reason?: string; expectedRevision?: string }
  | { action: "supersede"; id: string; kind: HomeProfileKind; text: string; file?: ProfileFile; reason?: string; expectedRevision?: string }
  | { action: "retire"; id: string; reason?: string; expectedRevision?: string }) & { contradicts?: string[] };

/** Who writes. Home cites the maintainer message its turn answers. */
export type HomeProfileAuthor =
  | { kind: "home"; sessionId: string; entryId: string }
  | { kind: "maintainer" };

/** A profile note's state as the change record holds it: `before` and `after` of every
 * profile change, and what undo restores. `null` is a note that did not exist. */
export interface HomeProfileValue {
  file?: ProfileFile;
  lastConfirmedDate?: string | null;
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
  backup?: string | null;
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
  const date = item.record.content.tags?.find(tag => tag.startsWith("home-confirmed-"))?.slice(15);
  return { ...(item.file ? { file: item.file } : {}), ...(date ? { lastConfirmedDate: date } : {}), kind: item.kind, text: item.text, confirmed: item.confirmed, state: item.status, revisionId: item.revisionId,
    ...(item.supersedes ? { supersedes: item.supersedes } : {}), ...(item.supersededBy ? { supersededBy: item.supersededBy } : {}) };
}

const KIND_LABELS: Record<HomeProfileKind, string> = {
  preference: "preference", "standing-decision": "standing decision", "delegation-default": "delegation default", fact: "fact",
};

/** How Changes shows a recorded profile value. Read-only presentation of audit. */
export function formatProfileValue(value: unknown): string {
  if (value === null || value === undefined) return "Not in the profile";
  const item = value as Partial<HomeProfileValue>;
  if (item.state === "retired") return `Retired: ${item.text ?? ""}`.trim();
  if (item.state === "superseded") return `Superseded: ${item.text ?? ""}`.trim();
  const kind = item.kind && KIND_LABELS[item.kind] ? KIND_LABELS[item.kind] : "item";
  return `${item.confirmed ? "Confirmed" : "Inferred"} ${kind}: ${item.text ?? ""}`;
}

/** The list projection of an item (`home.profileList` and the change answer). */
export function profileListItem(item: HomeProfileItem) {
  return { id: item.id, revisionId: item.revisionId, file: item.file ?? "core", why: item.why, lastConfirmedDate: item.lastConfirmedDate, kind: item.kind, text: item.text, confirmed: item.confirmed,
    status: item.status, createdAt: item.record.createdAt, updatedAt: item.record.updatedAt };
}

const SINGLE_LINE = /[\u0000-\u001f\u007f\u2028\u2029]/;
export const PROFILE_TEXT_MAX = 512;
export const PROFILE_REASON_MAX = 2_000;

/** The one validation every actor's request passes. */
function validateProfileOp(op: HomeProfileOp, author: HomeProfileAuthor["kind"]): string | undefined {
  if (op.action === "migrate") return undefined;
  if (op.action === "confirm" && author !== "maintainer") return "only the maintainer confirms an item";
  if (op.action === "refine" && op.text === undefined && op.kind === undefined && op.file === undefined) return "refine requires text, kind or file";
  if ("file" in op && op.file !== undefined && !validProfileFile(op.file)) return "file must be core, home or scopes/<slug>";
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
export class HomeProfileItems {
  constructor(private readonly knowledge: () => KnowledgeService | undefined) {}

  available(): boolean {
    return this.knowledge() !== undefined;
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
    if (op.contradicts?.length) throw new GatewayError("conflict", `Proposed rule contradicts ${op.contradicts.join(", ")}; review these items and explicitly supersede an obsolete rule instead`);
    if (op.action === "learn" && before.items.some(item => item.status === "active" && item.text.toLocaleLowerCase() === op.text.trim().toLocaleLowerCase())) throw new GatewayError("conflict", "An active profile item already states this rule; refine it instead of learning a duplicate");
    if (op.action === "migrate") {
      const projected = before.items.map(item => ({ ...item, file: op.assignments.find(assignment => assignment.id === item.id)?.file ?? item.file ?? "core" }));
      if (new Set(projected.map(item => item.file).filter(file => file.startsWith("scopes/"))).size > PROFILE_SCOPE_LIMIT) throw new GatewayError("invalid_request", `Profile index exceeds ${PROFILE_SCOPE_LIMIT} scopes`);
      for (const item of projected) if (item.file.startsWith("scopes/") && item.kind !== "fact") throw new GatewayError("invalid_request", "Binding rules must stay in core or home");
      for (const file of new Set(projected.map(item => item.file))) {
        const bytes = profileFileBytes(projected, file);
        if (bytes > profileFileCap(file)) throw new GatewayError("invalid_request", `${file} would be ${bytes} bytes, over its ${profileFileCap(file)}-byte cap`);
      }
      const result = await owner.store.organizeProfile(commandId, op.assignments);
      const after = await readHomeProfile(owner);
      return { saved: { status: "saved", action: "migrate", id: result.records[0]?.id ?? before.items[0]?.id ?? "", revisionId: result.records[0]?.revisionId ?? before.items[0]?.revisionId ?? "", backup: result.backup },
        writes: result.records.map(record => ({ id: record.id, before: profileValue(before.items.find(item => item.id === record.id)), after: profileValue(after.items.find(item => item.id === record.id)) })) };
    }
    if (op.action === "learn" || op.action === "refine" || op.action === "supersede" || op.action === "confirm") {
      const active = before.items.filter(item => item.status === "active");
      const projected = active.filter(item => op.action === "learn" || item.id !== op.id);
      const existing = op.action === "learn" ? undefined : active.find(item => item.id === op.id);
      const text = "text" in op ? op.text?.trim() ?? existing?.text : existing?.text;
      const kind = "kind" in op ? op.kind ?? existing?.kind : existing?.kind;
      const file = ("file" in op ? op.file : undefined) ?? existing?.file ?? "core";
      const scopedFiles = new Set(active.map(item => item.file).filter(candidate => candidate?.startsWith("scopes/")));
      if (file.startsWith("scopes/") && !scopedFiles.has(file) && scopedFiles.size >= PROFILE_SCOPE_LIMIT) throw new GatewayError("invalid_request", `Profile index already has ${PROFILE_SCOPE_LIMIT} scopes; consolidate before adding ${file}`);
      if (file.startsWith("scopes/") && kind !== "fact") throw new GatewayError("invalid_request", "Binding rules must stay in core or home; scopes hold contextual facts only");
      if (text !== undefined && kind !== undefined) projected.push({ ...existing, id: op.action === "learn" || op.action === "supersede" ? "00000000-0000-0000-0000-000000000000" : op.id,
        file, status: "active", kind, text, confirmed } as HomeProfileItem);
      const bytes = profileFileBytes(projected, file);
      const cap = profileFileCap(file);
      if (bytes > cap) throw new GatewayError("invalid_request",
        `${file} would be ${bytes} bytes, over its ${cap}-byte cap; shorten or reorganize this file first`);
    }
    const result = await this.write(owner, op, author, confirmed, before, commandId);
    const after = await readHomeProfile(owner);
    const ids = result.supersededId ? [result.supersededId, result.id] : [result.id];
    return { saved: result, writes: ids.map(id => ({
      id, before: profileValue(before.items.find(item => item.id === id)), after: profileValue(after.items.find(item => item.id === id)),
    })) };
  }

  private async write(owner: KnowledgeService, op: Exclude<HomeProfileOp, { action: "migrate" }>,  author: HomeProfileAuthor, confirmed: boolean, profile: HomeProfileRead, commandId: string): Promise<HomeProfileSaved> {
    const create = async (kind: HomeProfileKind, text: string, relations: KnowledgeRelation[], reason?: string) => {
      const { record } = await owner.invoke({ operation: "knowledge.note.create", request: {
        commandId, ...(confirmed ? { confirmedByUser: true } : {}),
        record: { kind: "note", scope: "personal", provenance: provenance(author, reason), relations,
          content: { title: text, role: KIND_ROLE[kind], confirmed, tags: profileConfirmationTags(profileFileTags([HOME_PROFILE_TAG, kindTag(kind)], ("file" in op ? op.file : undefined) ?? ("id" in op ? profile.items.find(item => item.id === op.id)?.file : undefined) ?? "core"), confirmed ? new Date().toISOString().slice(0, 10) : null) } },
      } }) as KnowledgeMutationResult;
      return record;
    };
    if (op.action === "learn") {
      const record = await create(op.kind, op.text.trim(), [], op.reason?.trim());
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
          record: { kind: "note", scope: "personal", provenance: provenance(author, reason ?? current.provenance.reason), relations: current.relations, content },
        } }) as KnowledgeMutationResult;
        return record;
      } catch (error) {
        throw staleConflict(error, (await readHomeProfile(owner)).items.find(candidate => candidate.id === current.id));
      }
    };
    if (op.action === "confirm") {
      const record = await update({ ...current.content, confirmed: true, tags: profileConfirmationTags(current.content.tags ?? [], new Date().toISOString().slice(0, 10)) });
      return { status: "saved", action: "confirm", id: record.id, revisionId: record.revisionId, previousRevisionId: current.revisionId, kind: item.kind };
    }
    if (op.action === "refine") {
      const kind = op.kind ?? item.kind;
      const record = await update({ ...current.content, title: op.text?.trim() ?? item.text, role: KIND_ROLE[kind], tags: profileConfirmationTags(profileFileTags(kindTags(current.content.tags, kind), op.file ?? item.file ?? "core"), confirmed ? new Date().toISOString().slice(0, 10) : item.lastConfirmedDate), confirmed }, op.reason?.trim());
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
        ...(value ? { title: value.text, role: KIND_ROLE[kind], tags: profileConfirmationTags(profileFileTags(kindTags(note.content.tags, kind), value.file), value.lastConfirmedDate ?? null), confirmed: value.confirmed } : {}),
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

