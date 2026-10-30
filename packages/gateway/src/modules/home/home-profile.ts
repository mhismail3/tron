import { profileFile, profileLabels, type ProfileLabel, type ProfilePartitionRequest, type ProfileFile } from "../../knowledge/knowledge-notes.js";
import { profileIndex, PROFILE_SECTION_HEADING } from "./home-profile-hierarchy.js";
import { randomUUID } from "node:crypto";
import { profilePath, type ProfileMetadata } from "../../knowledge/knowledge-profile-placement.js";
import { formatProfileValue } from "../../admin/settings-presentation.js";
import type { SettingsChangePath, SubjectContext, SubjectWrite, ChangeContext } from "../../kernel/settings/settings-change.js";
import type { ChangeEntry } from "../../kernel/settings/settings-record.js";
import type { ChangeResult } from "../../kernel/settings/tool-contract.js";
import { GatewayError } from "../../errors.js";
import type { KnowledgeListResponse, KnowledgeProvenance, KnowledgeRecord, KnowledgeRelation, NoteContent } from "../../knowledge/knowledge-contract.js";
import type { KnowledgeService } from "../../knowledge/knowledge-service.js";
import type { KnowledgeMutationResult, ProfileSortingState } from "../../knowledge/knowledge-store.js";

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
export const HOME_PROFILE_KINDS = ["preference", "standing-decision", "delegation-default", "fact", "correction"] as const;
export type HomeProfileKind = (typeof HOME_PROFILE_KINDS)[number];
/** The note role each kind is stored under; the kind label itself is what Home reads back. */
const KIND_ROLE: Record<HomeProfileKind, NoteContent["role"]> = {
  preference: "preference",
  "standing-decision": "decision",
  "delegation-default": "workflow",
  fact: "fact",
  correction: "fact",
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
  path: string;
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

  return classifyProfile(notes);
}

/** Also classifies the already-admitted bounded partition snapshot; never do an
 * unbounded second head load ahead of Knowledge's resource admission. */
function classifyProfile(notes: ProfileNote[]): HomeProfileRead {
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
    items.push({ id: note.id, revisionId: note.revisionId, file, path: note.content.profile?.path.join("/") ?? "prior", kind: kinds[0]!, text: note.content.title, confirmed: note.content.confirmed, status,
      ...(supersedes ? { supersedes } : {}), ...(by ? { supersededBy: by } : {}), record: note });
  }
  items.sort((left, right) => HOME_PROFILE_KINDS.indexOf(left.kind) - HOME_PROFILE_KINDS.indexOf(right.kind)
    || left.record.createdAt.localeCompare(right.record.createdAt) || left.id.localeCompare(right.id));
  return { items, unclassified: diagnostics.filter(item => item.issues.includes("kind")).length, diagnostics: diagnostics.sort((left, right) => left.id.localeCompare(right.id)) };
}

export interface HomeProfileIndexRead {
  sorting: ProfileSortingState;
  items: Array<{ id: string; revisionId: string; path: string; kind: HomeProfileKind; text: string; confirmed: boolean; status: HomeProfileStatus; createdAt: string; updatedAt: string }>;
  unclassified: number;
  diagnostics: HomeProfileRead["diagnostics"];
}
/** Mechanical SQL-head discovery; only the historical reader loads old bodies. */
export async function readHomeProfileIndex(knowledge: KnowledgeService): Promise<HomeProfileIndexRead> {
  const { rows, sorting } = await knowledge.store.profileMetadata();
  const superseded = new Set(rows.flatMap(row => row.supersedes));
  const items: HomeProfileIndexRead["items"] = [], diagnostics: HomeProfileRead["diagnostics"] = [];
  for (const row of rows) {
    const kinds = HOME_PROFILE_KINDS.filter(kind => row.tags.includes(kindTag(kind)));
    const issues: HomeProfileRead["diagnostics"][number]["issues"] = [];
    if (kinds.length !== 1) issues.push("kind");
    if (profileFile(row.tags) === null) issues.push("partition");
    if (issues.length) diagnostics.push({ id: row.id, revisionId: row.revisionId, issues });
    if (kinds.length === 1) items.push({ id: row.id, revisionId: row.revisionId, path: row.profile?.path.join("/") ?? "prior", kind: kinds[0]!, text: row.title,
      confirmed: row.confirmed, status: row.retired ? "retired" : superseded.has(row.id) ? "superseded" : "active", createdAt: row.createdAt, updatedAt: row.updatedAt });
  }
  // SQL key order is storage detail. Both native lists and cursor pages retain
  // the original kind/creation/ID order used by the canonical body reader.
  items.sort((left, right) => HOME_PROFILE_KINDS.indexOf(left.kind) - HOME_PROFILE_KINDS.indexOf(right.kind)
    || left.createdAt.localeCompare(right.createdAt) || left.id.localeCompare(right.id));
  return { items, sorting, diagnostics, unclassified: diagnostics.filter(item => item.issues.includes("kind")).length };
}

function kindTag(kind: HomeProfileKind): string {
  return `kind-${kind}`;
}

export async function homeProfileSection(knowledge: () => KnowledgeService | undefined, activation: "user" | "wake"): Promise<{ text: string; notes: number }> {
  const owner = knowledge();
  if (!owner) return { text: unavailableSection("Knowledge is not available on this Gateway"), notes: 0 };
  try {
    const read = await readHomeProfileIndex(owner);
    return { text: profileIndex(read, 0, activation), notes: read.items.filter((item) => item.status === "active").length };
  } catch (error) {
    return { text: unavailableSection(`reading Knowledge failed (${error instanceof Error ? error.message.slice(0, 200) : "unknown error"})`), notes: 0 };
  }
}

function unavailableSection(reason: string): string {
  return [PROFILE_SECTION_HEADING, `Unavailable: ${reason}. No item is applied in this instruction, and the profile is not known to be empty.`].join("\n");
}

// ---- profile changes: one implementation for Home and the maintainer ------------
//
// Content changes from Home and the maintainer run through HomeProfileItems inside
// SettingsChangePath.auditSubject. Label-only groups preflight and freeze the same
// subject's original snapshots in Knowledge's backup, then publish only committed
// facts through publishSubjectAudit. Both use the existing Changes/Undo surface.
// The actor decides
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
  | { action: "learn"; kind: HomeProfileKind; text: string; path?: string; sensitive?: boolean; corrects?: { id: string; revisionId: string } }
  | { action: "confirm"; id: string; expectedRevision?: string }
  | { action: "refine"; id: string; text?: string; kind?: HomeProfileKind; reason?: string; expectedRevision?: string }
  | { action: "supersede"; id: string; kind: HomeProfileKind; text: string; reason?: string; expectedRevision?: string }
  | { action: "retire"; id: string; reason?: string; expectedRevision?: string };

export type HomeProfileRequest = HomeProfileOp
  | { action: "migrate" | "reorganize"; assignments: ProfilePartitionRequest["assignments"] }
  | { action: "retry"; commandId: string };

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
  /** Exact owner labels AND positions; absent means the original flat note. */
  fileLabels?: ProfileLabel[];
  profile?: ProfileMetadata;
}

export interface HomeProfileWrite { id: string; before: HomeProfileValue | null; after: HomeProfileValue | null }
export type ProfileChangePath = Pick<SettingsChangePath, "record" | "auditSubject" | "publishSubjectAudit" | "validateSubjectAudit">;
interface PartitionEnvelope {
  version: 1;
  replayAt: string;
  context: SubjectContext;
  writes: SubjectWrite[];
}
function labelOnlyWrite(before: unknown, after: unknown): boolean {
  if (!before || !after || typeof before !== "object" || typeof after !== "object") return false;
  const { revisionId: _before, fileLabels: labelsBefore, profile: profileBefore, ...one } = before as HomeProfileValue;
  const { revisionId: _after, fileLabels: labelsAfter, profile: profileAfter, ...two } = after as HomeProfileValue;
  return JSON.stringify(one) === JSON.stringify(two) && JSON.stringify({ labels: labelsBefore ?? [], profile: profileBefore }) !== JSON.stringify({ labels: labelsAfter ?? [], profile: profileAfter });
}
function validatePartitionEnvelope(changes: ProfileChangePath, raw: unknown, commandId: string, originals: ProfileNote[], prepared: ProfileNote[]): PartitionEnvelope {
  const fail = (): never => { throw new GatewayError("conflict", "Original profile audit envelope is invalid"); };
  if (!raw || typeof raw !== "object") fail();
  const envelope = raw as PartitionEnvelope;
  if (envelope.version !== 1 || !envelope.context || envelope.context.commandId !== commandId || !["home", "ui"].includes(envelope.context.actor?.kind)
    || !Array.isArray(envelope.writes) || Object.keys(envelope).some(key => !["version", "replayAt", "context", "writes"].includes(key))) fail();
  const changed = originals.flatMap((before, index) => before.revisionId !== prepared[index]?.revisionId ? [{ before, after: prepared[index]! }] : []);
  if (!changed.length || changed.length !== envelope.writes.length) fail();
  for (const [index, pair] of changed.entries()) {
    const write = envelope.writes[index]!;
    const before = write.before as HomeProfileValue | null;
    const after = write.after as HomeProfileValue | null;
    if (write.id !== pair.before.id || pair.after.id !== pair.before.id || !before || !after || write.direction !== "widen" || !labelOnlyWrite(before, after)) fail();
    for (const [value, record] of [[before!, pair.before], [after!, pair.after]] as const) {
      const kinds = HOME_PROFILE_KINDS.filter(kind => record.content.tags?.includes(kindTag(kind)));
      const expected = { kind: kinds[0], text: record.content.title, confirmed: record.content.confirmed, state: value.state, revisionId: record.revisionId,
        ...(value.supersedes ? { supersedes: value.supersedes } : {}), ...(value.supersededBy ? { supersededBy: value.supersededBy } : {}),
        ...(profileLabels(record.content.tags).length ? { fileLabels: profileLabels(record.content.tags) } : {}),
        ...(record.content.profile ? { profile: record.content.profile } : {}) };
      if (kinds.length !== 1 || JSON.stringify(expected) !== JSON.stringify(value) || !["active", "retired", "superseded"].includes(value.state)
        || (record.content.retired === true) !== (value.state === "retired")) fail();
    }
  }
  changes.validateSubjectAudit(envelope.writes, envelope.context, envelope.replayAt);
  return envelope;
}

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
    ...(item.supersedes ? { supersedes: item.supersedes } : {}), ...(item.supersededBy ? { supersededBy: item.supersededBy } : {}),
    ...(profileLabels(item.record.content.tags).length ? { fileLabels: profileLabels(item.record.content.tags) } : {}),
    ...(item.record.content.profile ? { profile: item.record.content.profile } : {}) };
}

/** The list projection of an item (`home.profileList` and the change answer). */
export function profileListItem(item: HomeProfileItem) {
  return { id: item.id, revisionId: item.revisionId, path: item.path, kind: item.kind, text: item.text, confirmed: item.confirmed,
    status: item.status, createdAt: item.record.createdAt, updatedAt: item.record.updatedAt };
}

const SINGLE_LINE = /[\u0000-\u001f\u007f\u2028\u2029]/;
export const PROFILE_TEXT_MAX = 512;
export const PROFILE_REASON_MAX = 2_000;

/** The one validation every actor's request passes. */
function validateProfileOp(op: HomeProfileOp, author: HomeProfileAuthor["kind"]): string | undefined {
  if (op.action === "learn" && op.sensitive && (op.kind === "correction" || (op.path !== undefined && !op.path.startsWith("inferred/")))) return "Sensitive statements must wait unsorted for exact review; do not infer a correction or personal destination";
  if (op.action === "learn" && ((op.kind === "correction") !== (op.corrects !== undefined))) return "a correction requires an exact wrong-claim ID and revision; other kinds do not take corrects";
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

  /** Domain effects stay here. Content uses the engine's stripe; partition effects
   * use Knowledge's atomic revision fences and the engine's group publisher. */
  async change(changes: ProfileChangePath, requests: readonly HomeProfileRequest[], context: ProfileChangeContext): Promise<ProfileChangeResult | (ChangeResult & { saved: []; items: [] })> {
    if (!this.available()) throw new GatewayError("unsupported", "Knowledge is not available on this Gateway");
    if (requests.some(op => op.action === "reorganize" && op.assignments.length > 8)) throw new GatewayError("invalid_request", "Sort at most 8 profile notes per batch");
    const partition = requests.find(op => op.action === "migrate" || op.action === "reorganize" || op.action === "retry");
    if (partition && (partition.action === "migrate" || partition.action === "reorganize" || partition.action === "retry")) {
      if (requests.length !== 1) throw new GatewayError("invalid_request", "Organization is one explicit Home operation");
      return partition.action === "retry" ? this.retryPartition(changes, partition.commandId, context.actor.kind)
        : this.partition(changes, { commandId: context.commandId, mode: partition.action, assignments: partition.assignments }, context);
    }
    const ops = requests as readonly HomeProfileOp[];
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

  /** Freeze the ORIGINAL audit before effects, then publish only proven committed
   * identities. The existing backup owns recovery; no domain replay runs on open. */
  async partition(changes: ProfileChangePath, request: ProfilePartitionRequest, context: SubjectContext, undoOf?: ReadonlyMap<string, string>): Promise<ProfileChangeResult> {
    if (request.commandId !== context.commandId || !["home", "ui"].includes(context.actor.kind)) throw new GatewayError("invalid_request", "Profile partition needs its original Home or maintainer command");
    const result = await this.owner().store.partitionProfile(request, {
      restoring: undoOf !== undefined,
      create: (originals, prepared, visibleProfile) => {
        const read = classifyProfile(visibleProfile);
        if (!undoOf && context.actor.kind === "home" && originals.some(note => !homeMayOrganize(note))) throw new GatewayError("invalid_request", "Home may organize only its unconfirmed proposals; original notes remain unchanged");
        if (!undoOf && !context.reason?.trim()) throw new GatewayError("invalid_request", "Profile organization requires a reason");
        return { version: 1, replayAt: new Date().toISOString(), context: { commandId: context.commandId, actor: context.actor,
        ...(context.reason !== undefined ? { reason: context.reason } : {}) },
        writes: originals.flatMap((record, index) => {
          const next = prepared[index]!;
          if (record.revisionId === next.revisionId) return [];
          const item = read.items.find(item => item.id === record.id);
          if (!item) throw new GatewayError("conflict", "Unclassified profile kind needs an explicit eligibility decision");
          const value = (record: ProfileNote) => profileValue({ ...item, revisionId: record.revisionId, record });
          return [{ id: record.id, before: value(record), after: value(next), direction: "widen", ...(undoOf?.has(record.id) ? { undoOf: undoOf.get(record.id) } : {}) }];
        }) };
      },
      validate: (raw, originals, prepared) => { validatePartitionEnvelope(changes, raw, request.commandId, originals, prepared); },
    });
    if (!result.backup) return { status: "applied", changes: [], saved: [], items: [] };
    return this.retryPartition(changes, request.commandId, context.actor.kind);
  }

  /** An explicit retry either resumes the backed-up precommit domain intent or
   * repairs ONLY its audit, even after a later canonical edit. */
  async retryPartition(changes: ProfileChangePath, commandId: string, actor: SubjectContext["actor"]["kind"]): Promise<ProfileChangeResult> {
    const recovery = await this.owner().store.profilePartitionRecovery(commandId);
    const envelope = validatePartitionEnvelope(changes, recovery.envelope, commandId, recovery.originals, recovery.prepared);
    if (!recovery.committed) {
      if (envelope.context.actor.kind === "ui" && actor !== "ui") throw new GatewayError("invalid_request", "Only the maintainer resumes an uncommitted Undo");
      await this.owner().store.partitionProfile(recovery.request, {
        restoring: envelope.writes.every(write => write.undoOf !== undefined),
        create: () => { throw new GatewayError("conflict", "The original profile backup is missing"); },
        validate: (raw, originals, prepared) => { validatePartitionEnvelope(changes, raw, commandId, originals, prepared); },
      });
      return this.retryPartition(changes, commandId, actor);
    }
    const audit = await changes.publishSubjectAudit(envelope.writes, envelope.context, envelope.replayAt);
    const read = await this.read();
    return { ...audit, status: "applied", saved: [], items: read.items.filter(item => envelope.writes.some(write => write.id === item.id)).map(profileListItem) };
  }

  /** Group/value fencing, restoration and projection all remain under the Home stripe. */
  async undo(changes: ProfileChangePath, entry: ChangeEntry, context: Omit<ChangeContext, "undoOf">): Promise<ProfileChangeResult> {
    if (!this.available()) throw new GatewayError("unsupported", "Knowledge is not available on this Gateway");
    if (context.actor.kind !== "ui") throw new GatewayError("invalid_request", "Only the maintainer undoes a profile change");
    const group = entry.group ? await changes.record.group(entry.group.id, entry.group.size) : [entry];
    if (group.every(member => labelOnlyWrite(member.before, member.after))) {
      const commandId = context.commandId ?? randomUUID();
      // A retry after a committed domain/failed audit must not apply Undo twice.
      try {
        const recovery = await this.owner().store.profilePartitionRecovery(commandId);
        const envelope = validatePartitionEnvelope(changes, recovery.envelope, commandId, recovery.originals, recovery.prepared);
        if (!envelope.writes.some(write => write.undoOf === entry.changeId)) throw new GatewayError("conflict", "Command ID belongs to a different profile Undo");
        return this.retryPartition(changes, commandId, "ui");
      } catch (error) {
        if (!(error instanceof GatewayError && error.message === "No backed-up profile operation with this command ID")) throw error;
      }
      const current = await this.values(group.map(member => member.qualifiers?.note ?? ""));
      for (const member of group) if (member.status !== "applied" || JSON.stringify(current.get(member.qualifiers?.note ?? "") ?? null) !== JSON.stringify(member.after ?? null)) {
        throw new GatewayError("conflict", "The profile item changed since; undo would overwrite a newer change");
      }
      return this.partition(changes, { commandId, mode: "reorganize", assignments: group.map(member => ({
        id: member.qualifiers!.note!, expectedRevision: (member.after as HomeProfileValue).revisionId,
        ...((member.before as HomeProfileValue).profile ? { profile: (member.before as HomeProfileValue).profile! } : { labels: (member.before as HomeProfileValue).fileLabels ?? [] }),
      })) }, { commandId, actor: context.actor, ...(context.reason ? { reason: context.reason } : {}) },
      new Map(group.map(member => [member.qualifiers!.note!, member.changeId])));
    }
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
    if (op.action === "learn" && op.kind === "correction" && op.path !== undefined && !op.path.startsWith("corrections")) throw new GatewayError("invalid_request", "Corrections belong in the Corrections area");
    const before = await readHomeProfile(owner);
    const existing = "id" in op ? before.items.find(item => item.id === op.id) : undefined;
    // The previous contract made confirmed standing rules binding. Home may propose
    // a new inferred item, but cannot rewrite or retire that existing authority.
    if (author.kind === "home" && existing && (existing.confirmed || existing.record.content.privacyScope === "private" || existing.record.provenance.actor !== "agent" || existing.record.provenance.source !== "home")) {
      throw new GatewayError("invalid_request", "Only the maintainer may edit confirmed, private or non-Home-owned profile items; Home edits stay inferred");
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
      const privacyScope = op.action === "learn" ? op.sensitive ? "private" : undefined : profile.items.find(item => item.id === op.id)?.record.content.privacyScope;
      const { record } = await owner.invoke({ operation: "knowledge.note.create", request: {
        commandId, ...(confirmed ? { confirmedByUser: true } : {}),
        record: { kind: "note", scope: "personal", provenance: provenance(author, reason), relations,
          content: { title: text, role: KIND_ROLE[kind], confirmed, tags: [HOME_PROFILE_TAG, kindTag(kind)], ...(privacyScope ? { privacyScope } : {}),
            profile: op.action === "learn" ? profilePath(op.path ?? (kind === "correction" ? "corrections" : "inferred/review")) : profile.items.find(item => item.id === op.id)!.record.content.profile! } },
      } }) as KnowledgeMutationResult;
      return record;
    };
    if (op.action === "learn") {
      if (op.corrects) {
        const claim = await owner.store.read(op.corrects.id, op.corrects.revisionId);
        if (!claim) throw new GatewayError("invalid_request", "The correction must link an available exact wrong claim");
      }
      const record = await create(op.kind, op.text.trim(), op.corrects ? [{ type: "corrects", recordId: op.corrects.id, revisionId: op.corrects.revisionId }] : []);
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
    if (!current.content.profile) throw new GatewayError("conflict", "Prior organization is read-only; review an explicit v2 placement before a new content edit");
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
function homeMayOrganize(note: Extract<KnowledgeRecord, { kind: "note" }>): boolean {
  return !note.content.confirmed && note.content.privacyScope !== "private"
    && note.provenance.actor === "agent" && note.provenance.source === "home"
    && !note.content.tags?.some(tag => ["kind-standing-decision", "kind-delegation-default", "kind-correction"].includes(tag));
}
export interface HomeProfileChangeAccess {
  deferSorting(commandId: string, version: string): Promise<{ status: "deferred"; version: string }>;
  change(ops: HomeProfileRequest[], input: { toolCallId: string; author: HomeProfileAuthor; commandId: string; reason?: string }): Promise<ProfileChangeResult | (ChangeResult & { saved: []; items: [] })>;
}
