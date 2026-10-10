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

  const superseded = new Set(notes.flatMap((note) => note.relations.filter((relation) => relation.type === "supersedes").map((relation) => relation.recordId)));
  const items: HomeProfileItem[] = [];
  let unclassified = 0;
  for (const note of notes) {
    const tags = note.content.tags ?? [];
    const kinds = HOME_PROFILE_KINDS.filter((kind) => tags.includes(kindTag(kind)));
    if (kinds.length !== 1) { unclassified += 1; continue; }
    const status: HomeProfileStatus = note.content.retired ? "retired" : superseded.has(note.id) ? "superseded" : "active";
    items.push({ id: note.id, revisionId: note.revisionId, kind: kinds[0]!, text: note.content.title, confirmed: note.content.confirmed, status, record: note });
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
export async function homeProfileSection(knowledge: () => KnowledgeService | undefined): Promise<string> {
  const owner = knowledge();
  if (!owner) return unavailableSection("Knowledge is not available on this Gateway");
  try {
    return renderHomeProfileSection(await readHomeProfile(owner));
  } catch (error) {
    return unavailableSection(`reading Knowledge failed (${error instanceof Error ? error.message.slice(0, 200) : "unknown error"})`);
  }
}

function unavailableSection(reason: string): string {
  return [HOME_PROFILE_HEADING, `Unavailable: ${reason}. No item is applied in this instruction, and the profile is not known to be empty.`].join("\n");
}

// ---- the profile tool -----------------------------------------------------------

export const HOME_PROFILE_ACTIONS = ["learn", "refine", "supersede", "retire"] as const;
export type HomeProfileAction = (typeof HOME_PROFILE_ACTIONS)[number];

const PROFILE_PARAMETERS = Type.Object({
  action: Type.Union(HOME_PROFILE_ACTIONS.map((action) => Type.Literal(action)), { description: "learn a new item; refine an item's text; supersede an item with a replacement; retire an item." }),
  kind: Type.Optional(Type.Union(HOME_PROFILE_KINDS.map((kind) => Type.Literal(kind)), { description: "learn and supersede: the item's kind." })),
  text: Type.Optional(Type.String({ minLength: 1, maxLength: 512, description: "learn, refine and supersede: one line of the item's text, as the maintainer states it." })),
  id: Type.Optional(Type.String({ minLength: 1, maxLength: 200, description: "refine, supersede and retire: the profile note ID shown in the Learned profile section." })),
  reason: Type.Optional(Type.String({ minLength: 1, maxLength: 2_000, description: "Why the change is made. Required for retire; recorded in the ledger." })),
}, { additionalProperties: false });

/** Tool-result details: the saved revision, or the typed reason a change was refused. */
export type HomeProfileToolDetails =
  | { status: "saved"; action: HomeProfileAction; id: string; revisionId: string; kind?: HomeProfileKind; supersededId?: string; previousRevisionId?: string }
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
  refine: { required: ["id", "text"], allowed: ["id", "text", "reason"] },
  supersede: { required: ["id", "kind", "text"], allowed: ["id", "kind", "text", "reason"] },
  retire: { required: ["id", "reason"], allowed: ["id", "reason"] },
};

const SINGLE_LINE = /[\u0000-\u001f\u007f\u2028\u2029]/;

/**
 * The `profile` tool, closed over the Knowledge owner resolved at every call. The
 * tool writes nothing itself: each successful action is one Knowledge note mutation,
 * and each result states exactly what was saved.
 */
export function homeProfileTool(knowledge: () => KnowledgeService | undefined): ToolDefinition<TSchema, HomeProfileToolDetails> {
  return {
    name: "profile",
    label: "Profile",
    description: "Change the learned profile of the maintainer: learn a durable preference, standing decision, delegation default or fact; refine an item's text; supersede an item with a replacement; or retire an item with a reason. Every change is saved unconfirmed (inferred) until the maintainer confirms it, and applies from the next activation. Learn only what the maintainer stated durably.",
    parameters: PROFILE_PARAMETERS,
    executionMode: "sequential",
    execute: async (toolCallId, parameters, _signal, _update, context) => {
      const request = parameters as ProfileRequest;
      const owner = knowledge();
      if (!owner) return answer({ status: "unavailable", action: request.action }, "Knowledge is unavailable on this Gateway, so the profile cannot change.");
      const refusal = validateRequest(request);
      if (refusal) return answer({ status: "refused", action: request.action, reason: refusal }, `Profile ${request.action} refused: ${refusal}`);
      const citation = triggeringMessage(context);
      if (!citation) return answer({ status: "refused", action: request.action, reason: "no maintainer message in this chat to cite as evidence" }, `Profile ${request.action} refused: no maintainer message in this chat to cite as evidence.`);
      try {
        return await apply(owner, request, citation, commandId(citation.sessionId, toolCallId));
      } catch (error) {
        if (error instanceof GatewayError && (error.code === "conflict" || error.code === "invalid_request")) {
          return answer({ status: "refused", action: request.action, reason: error.message }, `Profile ${request.action} refused: ${error.message}`);
        }
        throw error;
      }
    },
  };
}

function answer(details: HomeProfileToolDetails, text: string) {
  return { content: [{ type: "text" as const, text }], details };
}

function validateRequest(request: ProfileRequest): string | undefined {
  const fields = ACTION_FIELDS[request.action];
  for (const field of fields.required) if (request[field] === undefined) return `${request.action} requires ${field}`;
  for (const field of ["kind", "text", "id", "reason"] as const) {
    if (request[field] !== undefined && !fields.allowed.includes(field)) return `${request.action} does not take ${field}`;
  }
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

function provenance(citation: { sessionId: string; entryId: string }, reason?: string): KnowledgeProvenance {
  return {
    actor: "agent",
    source: "home",
    sessionId: citation.sessionId,
    evidence: [{ sessionEntry: { sessionId: citation.sessionId, entryId: citation.entryId } }],
    ...(reason ? { reason } : {}),
  };
}

function noteDraft(citation: { sessionId: string; entryId: string }, kind: HomeProfileKind, text: string, relations: KnowledgeRelation[], reason?: string) {
  return {
    kind: "note" as const,
    scope: "personal" as const,
    provenance: provenance(citation, reason),
    relations,
    content: { title: text, role: KIND_ROLE[kind], confirmed: false, tags: [HOME_PROFILE_TAG, kindTag(kind)] },
  };
}

async function apply(owner: KnowledgeService, request: ProfileRequest, citation: { sessionId: string; entryId: string }, command: string): Promise<{ content: Array<{ type: "text"; text: string }>; details: HomeProfileToolDetails }> {
  if (request.action === "learn") {
    const kind = request.kind!;
    const text = request.text!.trim();
    const { record } = await owner.invoke({ operation: "knowledge.note.create", request: { commandId: command, record: noteDraft(citation, kind, text, []) } }) as KnowledgeMutationResult;
    return answer({ status: "saved", action: "learn", id: record.id, revisionId: record.revisionId, kind },
      `Saved profile item note ${record.id} (${kind}, inferred until you confirm it): ${text}`);
  }

  const profile = await readHomeProfile(owner);
  const item = profile.items.find((candidate) => candidate.id === request.id);
  if (!item) return refusedAnswer(request.action, `note ${request.id} is not a Home profile item`);
  if (item.status !== "active") return refusedAnswer(request.action, `profile item ${item.id} is ${item.status}; only an active item can change`);
  const current = item.record;

  if (request.action === "refine") {
    const text = request.text!.trim();
    const content: NoteContent = { ...current.content, title: text, confirmed: false };
    const { record } = await owner.invoke({ operation: "knowledge.note.update", request: {
      commandId: command, recordId: current.id, expectedRevision: current.revisionId,
      record: { kind: "note", scope: "personal", provenance: provenance(citation), relations: current.relations, content },
    } }) as KnowledgeMutationResult;
    return answer({ status: "saved", action: "refine", id: record.id, revisionId: record.revisionId, previousRevisionId: current.revisionId, kind: item.kind },
      `Refined profile item note ${record.id} (${item.kind}, inferred until you confirm it): ${text}. Revision ${current.revisionId} is kept in its history.`);
  }

  if (request.action === "supersede") {
    const kind = request.kind!;
    const text = request.text!.trim();
    const relations: KnowledgeRelation[] = [{ type: "supersedes", recordId: current.id, revisionId: current.revisionId }];
    const { record } = await owner.invoke({ operation: "knowledge.note.create", request: {
      commandId: command, record: noteDraft(citation, kind, text, relations, request.reason?.trim()),
    } }) as KnowledgeMutationResult;
    return answer({ status: "saved", action: "supersede", id: record.id, revisionId: record.revisionId, kind, supersededId: current.id },
      `Superseded profile item note ${current.id} with note ${record.id} (${kind}, inferred until you confirm it): ${text}.`);
  }

  const reason = request.reason!.trim();
  const content: NoteContent = { ...current.content, retired: true };
  const { record } = await owner.invoke({ operation: "knowledge.note.update", request: {
    commandId: command, recordId: current.id, expectedRevision: current.revisionId,
    record: { kind: "note", scope: "personal", provenance: provenance(citation, reason), relations: current.relations, content },
  } }) as KnowledgeMutationResult;
  return answer({ status: "saved", action: "retire", id: record.id, revisionId: record.revisionId, previousRevisionId: current.revisionId, kind: item.kind },
    `Retired profile item note ${record.id}: ${item.text}. It no longer applies. Reason: ${reason}`);
}

function refusedAnswer(action: HomeProfileAction, reason: string) {
  return answer({ status: "refused", action, reason }, `Profile ${action} refused: ${reason}.`);
}
