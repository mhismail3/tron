import { createHash } from "node:crypto";
import { Type, type TSchema } from "@earendil-works/pi-ai";
import type { ExtensionToolContext, ToolDefinition } from "@earendil-works/pi-coding-agent";
import { GatewayError } from "../errors.js";
import type { KnowledgeListResponse, KnowledgeProvenance, KnowledgeRecord, KnowledgeRelation, NoteContent } from "../knowledge/knowledge-contract.js";
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
export const HOME_PROFILE_TAG = "home-profile";
export const HOME_PROFILE_KINDS = ["preference", "standing-decision", "delegation-default", "fact"] as const;
export type HomeProfileKind = (typeof HOME_PROFILE_KINDS)[number];
/** The note role each kind is stored under; the kind label itself is what Home reads back. */
const KIND_ROLE: Record<HomeProfileKind, NoteContent["role"]> = {
  preference: "preference",
  "standing-decision": "decision",
  "delegation-default": "workflow",
  fact: "fact",
};

/** The profile's injected size bound, in UTF-8 bytes of its item lines. Eight KiB is about
 * two thousand tokens, paid on every Home turn, and holds several dozen one-sentence items.
 * Past it Home must consolidate the profile instead of carrying a truncated or growing one. */
export const HOME_PROFILE_BOUND_BYTES = 8 * 1_024;
const PROFILE_PAGE_LIMIT = 50;
/** The section heading. Stable text: the cached prompt head changes only with the items. */
export const HOME_PROFILE_HEADING = "## Learned profile";

export type HomeProfileStatus = "active" | "superseded" | "retired";
export type ProfileNote = KnowledgeRecord & { kind: "note" };

export interface HomeProfileItem {
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
  items: HomeProfileItem[];
  /** Profile-tagged notes that carry no single valid kind label; they are not applied. */
  unclassified: number;
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
  let unclassified = 0;
  for (const note of notes) {
    const tags = note.content.tags ?? [];
    const kinds = HOME_PROFILE_KINDS.filter((kind) => tags.includes(kindTag(kind)));
    if (kinds.length !== 1) { unclassified += 1; continue; }
    const by = supersededBy.get(note.id);
    const status: HomeProfileStatus = note.content.retired ? "retired" : by ? "superseded" : "active";
    const supersedes = note.relations.find(relation => relation.type === "supersedes" && profileIds.has(relation.recordId))?.recordId;
    items.push({ id: note.id, revisionId: note.revisionId, kind: kinds[0]!, text: note.content.title, confirmed: note.content.confirmed, status,
      ...(supersedes ? { supersedes } : {}), ...(by ? { supersededBy: by } : {}), record: note });
  }
  items.sort((left, right) => HOME_PROFILE_KINDS.indexOf(left.kind) - HOME_PROFILE_KINDS.indexOf(right.kind)
    || left.record.createdAt.localeCompare(right.record.createdAt) || left.id.localeCompare(right.id));
  return { items, unclassified };
}

function kindTag(kind: HomeProfileKind): string {
  return `kind-${kind}`;
}

const INTRO = [
  "Learned from the maintainer's messages to Home and saved as Knowledge notes. A confirmed item is binding; an inferred item is your default until the maintainer confirms it. Apply every item to each turn and to each delegated brief, and list the note IDs you applied under \"Preferences applied\" in the brief.",
  "Change an item with profile refine, supersede or retire; never learn a duplicate. Profile changes apply from the next activation.",
].join("\n");

/** The section Home's instructions carry for the current profile. It depends only on the
 * Knowledge owner's state, so an unchanged profile yields byte-identical text. */
export function renderHomeProfileSection(read: HomeProfileRead): string {
  const active = read.items.filter((item) => item.status === "active");
  const lines = active.map((item) => `- ${itemLabel(item)}: ${item.text}`);
  const unclassified = read.unclassified > 0
    ? `${read.unclassified} profile note(s) without exactly one kind label are not applied; refine or retire them.`
    : undefined;
  const bytes = lines.reduce((total, line) => total + Buffer.byteLength(`${line}\n`, "utf8"), 0);
  if (active.length === 0) {
    const empty = read.items.length === 0
      ? "No items yet. Save a durable preference, standing decision, delegation default or fact the maintainer states with profile learn."
      : "No active items: every item is superseded or retired.";
    return [HOME_PROFILE_HEADING, INTRO, empty, ...(unclassified ? [unclassified] : [])].join("\n");
  }
  if (bytes > HOME_PROFILE_BOUND_BYTES) {
    // Over the bound no item text is injected, whole or partial: a truncated preference
    // is worse than none. The notice names items by ID so Home can consolidate them.
    const listed: string[] = [];
    let listedBytes = 0;
    for (const item of active) {
      const line = `- note ${item.id} (${item.kind}, ${item.confirmed ? "confirmed" : "inferred"})`;
      const cost = Buffer.byteLength(`${line}\n`, "utf8");
      if (listedBytes + cost > HOME_PROFILE_BOUND_BYTES) break;
      listed.push(line);
      listedBytes += cost;
    }
    const omitted = active.length - listed.length;
    return [
      HOME_PROFILE_HEADING,
      `The profile holds ${active.length} active items (${bytes} bytes), over its ${HOME_PROFILE_BOUND_BYTES}-byte bound, so none is applied in this instruction. Home must consolidate it before relying on it: read the items with knowledge, then use profile refine, supersede or retire to merge duplicates and retire what no longer holds.`,
      ...listed,
      ...(omitted > 0 ? [`- and ${omitted} more`] : []),
      ...(unclassified ? [unclassified] : []),
    ].join("\n");
  }
  return [HOME_PROFILE_HEADING, INTRO, ...lines, ...(unclassified ? [unclassified] : [])].join("\n");
}

function itemLabel(item: HomeProfileItem): string {
  return `note ${item.id} (${item.kind}, ${item.confirmed ? "confirmed" : "inferred"})`;
}

/** The section for one activation's system prompt. Unavailability is said, never shown as
 * an empty profile: Home must not assume it has no preferences when it could not read them. */
/** The learned-profile section and how many active notes it lists (`notes` is 0 when the
 * section could not be read: no item is applied then). */
export async function homeProfileSection(knowledge: () => KnowledgeService | undefined): Promise<{ text: string; notes: number }> {
  const owner = knowledge();
  if (!owner) return { text: unavailableSection("Knowledge is not available on this Gateway"), notes: 0 };
  try {
    const read = await readHomeProfile(owner);
    return { text: renderHomeProfileSection(read), notes: read.items.filter((item) => item.status === "active").length };
  } catch (error) {
    return { text: unavailableSection(`reading Knowledge failed (${error instanceof Error ? error.message.slice(0, 200) : "unknown error"})`), notes: 0 };
  }
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
export const HOME_PROFILE_ACTIONS = ["learn", "refine", "supersede", "retire"] as const;
export type HomeProfileAction = (typeof HOME_PROFILE_ACTIONS)[number];
/** The maintainer's actions; `confirm` is his alone. */
export const HOME_PROFILE_MAINTAINER_ACTIONS = ["confirm", "refine", "supersede", "retire"] as const;
export type HomeProfileChangeAction = HomeProfileAction | "confirm";

/** One requested change. `expectedRevision` is the revision the requester read: a note
 * changed since is refused with a conflict rather than overwritten. */
export type HomeProfileOp =
  | { action: "learn"; kind: HomeProfileKind; text: string }
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
  return { id: item.id, revisionId: item.revisionId, kind: item.kind, text: item.text, confirmed: item.confirmed,
    status: item.status, createdAt: item.record.createdAt, updatedAt: item.record.updatedAt };
}

const SINGLE_LINE = /[\u0000-\u001f\u007f\u2028\u2029]/;
const TEXT_MAX = 512;
const REASON_MAX = 2_000;

/** The one validation every actor's request passes. */
export function validateProfileOp(op: HomeProfileOp, author: HomeProfileAuthor["kind"]): string | undefined {
  if (op.action === "confirm" && author !== "maintainer") return "only the maintainer confirms an item";
  if (op.action === "refine" && op.text === undefined && op.kind === undefined) return "refine requires text or kind";
  if (op.action === "retire" && author === "home" && op.reason === undefined) return "retire requires reason";
  const text = "text" in op ? op.text : undefined;
  if (text !== undefined && (typeof text !== "string" || text.trim() === "" || text.length > TEXT_MAX || SINGLE_LINE.test(text))) return "text must be one non-empty line";
  const reason = "reason" in op ? op.reason : undefined;
  if (reason !== undefined && (typeof reason !== "string" || reason.trim() === "" || reason.length > REASON_MAX || SINGLE_LINE.test(reason))) return "reason must be one non-empty line";
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
          content: { title: text, role: KIND_ROLE[kind], confirmed, tags: [HOME_PROFILE_TAG, kindTag(kind)] } },
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

// ---- the profile tool -----------------------------------------------------------

const PROFILE_PARAMETERS = Type.Object({
  action: Type.Union(HOME_PROFILE_ACTIONS.map((action) => Type.Literal(action)), { description: "learn a new item; refine an item's text or kind; supersede an item with a replacement; retire an item." }),
  kind: Type.Optional(Type.Union(HOME_PROFILE_KINDS.map((kind) => Type.Literal(kind)), { description: "learn and supersede: the item's kind. refine: a new kind, when it changes." })),
  text: Type.Optional(Type.String({ minLength: 1, maxLength: TEXT_MAX, description: "learn, refine and supersede: one line of the item's text, as the maintainer states it." })),
  id: Type.Optional(Type.String({ minLength: 1, maxLength: 200, description: "refine, supersede and retire: the profile note ID shown in the Learned profile section." })),
  reason: Type.Optional(Type.String({ minLength: 1, maxLength: REASON_MAX, description: "Why the change is made. Required for retire; recorded in the ledger." })),
}, { additionalProperties: false });

/** Tool-result details: the saved revision, or the typed reason a change was refused. */
export type HomeProfileToolDetails =
  | HomeProfileSaved
  | { status: "refused"; action: HomeProfileAction; reason: string }
  | { status: "unavailable"; action: HomeProfileAction };

type ProfileRequest = {
  action: HomeProfileAction;
  kind?: HomeProfileKind;
  text?: string;
  id?: string;
  reason?: string;
};

/** Which fields each action takes. Anything else is refused, never silently ignored. */
const ACTION_FIELDS: Record<HomeProfileAction, { required: Array<keyof ProfileRequest>; allowed: Array<keyof ProfileRequest> }> = {
  learn: { required: ["kind", "text"], allowed: ["kind", "text"] },
  refine: { required: ["id"], allowed: ["id", "text", "kind", "reason"] },
  supersede: { required: ["id", "kind", "text"], allowed: ["id", "kind", "text", "reason"] },
  retire: { required: ["id", "reason"], allowed: ["id", "reason"] },
};

/** What the Home runtime gives the tool: the change path, as Home. */
export interface HomeProfileChangeAccess {
  change(ops: HomeProfileOp[], input: { toolCallId: string; web: boolean; author: HomeProfileAuthor; commandId: string; reason?: string }): Promise<{ saved: HomeProfileSaved[] }>;
}

/**
 * The `profile` tool. It writes nothing itself: each call is one change through the
 * settings change path, which applies it with `HomeProfileItems` and records it.
 */
export function homeProfileTool(access: () => HomeProfileChangeAccess | undefined, webMark: () => boolean): ToolDefinition<TSchema, HomeProfileToolDetails> {
  return {
    name: "profile",
    // docs/settings-model.md 5.4: declares it reads no open-world content.
    annotations: { openWorldHint: false },
    label: "Profile",
    description: "Change the learned profile of the maintainer: learn a durable preference, standing decision, delegation default or fact; refine an item's text or kind; supersede an item with a replacement; or retire an item with a reason. Every change is saved unconfirmed (inferred) until the maintainer confirms it, is shown in Changes where he can undo it, and applies from the next activation. Learn only what the maintainer stated durably.",
    parameters: PROFILE_PARAMETERS,
    executionMode: "sequential",
    execute: async (toolCallId, parameters, _signal, _update, context) => {
      const request = parameters as ProfileRequest;
      const changes = access();
      if (!changes) return answer({ status: "unavailable", action: request.action }, "Knowledge is unavailable on this Gateway, so the profile cannot change.");
      const refusal = validateRequest(request);
      if (refusal) return refused(request.action, refusal);
      const citation = triggeringMessage(context);
      if (!citation) return refused(request.action, "no maintainer message in this chat to cite as evidence");
      const op = request.action === "learn" ? { action: "learn" as const, kind: request.kind!, text: request.text! }
        : request.action === "refine" ? { action: "refine" as const, id: request.id!, ...(request.text ? { text: request.text } : {}), ...(request.kind ? { kind: request.kind } : {}), ...(request.reason ? { reason: request.reason } : {}) }
          : request.action === "supersede" ? { action: "supersede" as const, id: request.id!, kind: request.kind!, text: request.text!, ...(request.reason ? { reason: request.reason } : {}) }
            : { action: "retire" as const, id: request.id!, reason: request.reason! };
      let saved: HomeProfileSaved;
      try {
        [saved] = (await changes.change([op], {
          toolCallId, web: webMark(), author: { kind: "home", ...citation }, commandId: commandId(citation.sessionId, toolCallId),
          ...(request.reason ? { reason: request.reason.trim() } : {}),
        })).saved as [HomeProfileSaved];
      } catch (error) {
        if (error instanceof GatewayError && error.code === "unsupported") return answer({ status: "unavailable", action: request.action }, "Knowledge is unavailable on this Gateway, so the profile cannot change.");
        if (error instanceof GatewayError && (error.code === "conflict" || error.code === "invalid_request")) return refused(request.action, error.message);
        throw error;
      }
      return answer(saved, savedText(saved, request));
    },
  };
}

function savedText(saved: HomeProfileSaved, request: ProfileRequest): string {
  const text = request.text?.trim();
  switch (saved.action) {
    case "learn": return `Saved profile item note ${saved.id} (${saved.kind}, inferred until you confirm it): ${text}`;
    case "refine": return `Refined profile item note ${saved.id} (${saved.kind}, inferred until you confirm it): ${text ?? saved.previousText}. Revision ${saved.previousRevisionId} is kept in its history.`;
    case "supersede": return `Superseded profile item note ${saved.supersededId} with note ${saved.id} (${saved.kind}, inferred until you confirm it): ${text}.`;
    default: return `Retired profile item note ${saved.id}: ${saved.previousText}. It no longer applies. Reason: ${request.reason?.trim()}`;
  }
}

function answer(details: HomeProfileToolDetails, text: string) {
  return { content: [{ type: "text" as const, text }], details };
}

function refused(action: HomeProfileAction, reason: string) {
  const trimmed = reason.replace(/\.$/u, "");
  return answer({ status: "refused", action, reason: trimmed }, `Profile ${action} refused: ${trimmed}.`);
}

function validateRequest(request: ProfileRequest): string | undefined {
  const fields = ACTION_FIELDS[request.action];
  for (const field of fields.required) if (request[field] === undefined) return `${request.action} requires ${field}`;
  for (const field of ["kind", "text", "id", "reason"] as const) {
    if (request[field] !== undefined && !fields.allowed.includes(field)) return `${request.action} does not take ${field}`;
  }
  if (request.action === "refine" && request.text === undefined && request.kind === undefined) return "refine requires text or kind";
  if (request.text !== undefined && (request.text.trim() === "" || SINGLE_LINE.test(request.text))) return "text must be one non-empty line";
  if (request.reason !== undefined && (request.reason.trim() === "" || SINGLE_LINE.test(request.reason))) return "reason must be one non-empty line";
  return undefined;
}

/** The maintainer message the current turn answers: the last user message on this chat's
 * branch. Its canonical entry is the evidence every profile revision cites. */
function triggeringMessage(context: ExtensionToolContext): { sessionId: string; entryId: string } | undefined {
  const entry = context.sessionManager.getBranch().filter((candidate) => candidate.type === "message" && candidate.message.role === "user").at(-1);
  return entry ? { sessionId: context.sessionManager.getSessionId(), entryId: entry.id } : undefined;
}

/** Idempotency: a replayed tool call maps to the same command, and so to the same receipt. */
function commandId(sessionId: string, toolCallId: string): string {
  return `profile-${createHash("sha256").update(`${sessionId}\0${toolCallId}`).digest("hex").slice(0, 48)}`;
}
