import { createHash } from "node:crypto";
import { Type, type TSchema } from "../../kernel/pi/ai.js";
import type { ExtensionToolContext, ToolDefinition } from "../../kernel/pi/coding-agent.js";
import { GatewayError } from "../../errors.js";
import type { KnowledgeService } from "../../knowledge/knowledge-service.js";
import { profilePath } from "../../knowledge/knowledge-profile-placement.js";
import { profileIndex } from "./home-profile-hierarchy.js";
import { HOME_PROFILE_ACTIONS, HOME_PROFILE_KINDS, PROFILE_TEXT_MAX, PROFILE_REASON_MAX, readHomeProfileIndex, type HomeProfileAction, type HomeProfileKind, type HomeProfileSaved, type HomeProfileRequest, type HomeProfileChangeAccess } from "./home-profile.js";
const SINGLE_LINE = /[\u0000-\u001f\u007f\u2028\u2029]/;

// ---- the profile tool -----------------------------------------------------------

const PROFILE_PARAMETERS = Type.Object({
  action: Type.Union([...HOME_PROFILE_ACTIONS, "read" as const, "migrate" as const, "reorganize" as const, "retry" as const, "defer" as const].map((action) => Type.Literal(action)), { description: "read an explicit file or the metadata index; learn, refine, supersede or retire an item." }),
  path: Type.Optional(Type.String({ minLength: 1, maxLength: 131, description: "Explicit personal path or inferred holding bucket; read prior for historical organization. No path reads the metadata index. New notes default to inferred/review." })),
  offset: Type.Optional(Type.Integer({ minimum: 0, maximum: 10_000, description: "Metadata-index offset; record pages use cursor." })),
  includeInactive: Type.Optional(Type.Boolean({ description: "Explicitly include retired and superseded content; omitted reads active notes only." })),
  cursor: Type.Optional(Type.String({ minLength: 1, maxLength: 512, description: "Opaque query-bound continuation returned by a record page. Restart if the snapshot changes." })),
  version: Type.Optional(Type.String({ minLength: 64, maxLength: 64, pattern: "^[a-f0-9]{64}$", description: "defer: exact arrival version from the current metadata index. Receipt-backed Not now applies only on a maintainer turn." })),
  sensitive: Type.Optional(Type.Boolean({ description: "learn: declare sensitive personal information. Never infer it: text must be verbatim in this maintainer message and must wait unsorted for review." })),
  kind: Type.Optional(Type.Union(HOME_PROFILE_KINDS.map((kind) => Type.Literal(kind)), { description: "learn and supersede: the item's kind. refine: a new kind, when it changes." })),
  corrects: Type.Optional(Type.Object({ id: Type.String({ minLength: 16, maxLength: 80 }), revisionId: Type.String({ minLength: 16, maxLength: 80 }) }, { additionalProperties: false, description: "correction: exact wrong claim. Home never invents a claim or confirmation." })),
  text: Type.Optional(Type.String({ minLength: 1, maxLength: PROFILE_TEXT_MAX, description: "learn, refine and supersede: one line of the item's text, as the maintainer states it." })),
  id: Type.Optional(Type.String({ minLength: 1, maxLength: 200, description: "refine, supersede and retire: the exact profile note ID returned by profile read." })),
  assignments: Type.Optional(Type.Array(Type.Object({ id: Type.String({ minLength: 1, maxLength: 200 }), expectedRevision: Type.String({ minLength: 16, maxLength: 80 }), path: Type.String({ minLength: 1, maxLength: 131 }) }, { additionalProperties: false }), { minItems: 1, maxItems: 500, description: "Explicit exact-revision destinations. migrate must include exactly the active legacy Core/Home notes, leaving inactive/scoped originals untouched; reorganize names only the selected notes. Placement only: text, authority and history stay unchanged." })),
  commandId: Type.Optional(Type.String({ minLength: 1, maxLength: 160, description: "retry: the ORIGINAL operation command returned with retry_required; never a new operation identity." })),
  reason: Type.Optional(Type.String({ minLength: 1, maxLength: PROFILE_REASON_MAX, description: "Why the change is made. Required for retire; recorded in the ledger." })),
}, { additionalProperties: false });

/** Tool-result details: the saved revision, or the typed reason a change was refused. */
export type HomeProfileToolDetails =
  | HomeProfileSaved
  | { status: "deferred"; version: string }
  | { status: "pending"; action: ProfileToolAction; approval: unknown }
  | { status: "refused"; action: ProfileToolAction; reason: string }
  | { status: "unavailable"; action: ProfileToolAction }
  | { status: "organized"; action: "migrate" | "reorganize" | "retry"; commandId: string; changeIds: string[] }
  | { status: "retry_required"; action: ProfileToolAction; commandId: string; reason: string }
  | { status: "read"; path?: string; items: unknown[]; unclassified: number; nextCursor?: string; index?: string; sorting?: { version: string; deferred: boolean } };

type ProfileToolAction = HomeProfileAction | "read" | "migrate" | "reorganize" | "retry" | "defer";
type ProfileRequest = {
  action: ProfileToolAction;
  version?: string;
  sensitive?: boolean;
  path?: string;
  offset?: number;
  cursor?: string;
  includeInactive?: boolean;
  assignments?: Array<{ id: string; expectedRevision: string; path: string }>;
  commandId?: string;
  kind?: HomeProfileKind;
  corrects?: { id: string; revisionId: string };
  text?: string;
  id?: string;
  reason?: string;
};

/** Which fields each action takes. Anything else is refused, never silently ignored. */
const ACTION_FIELDS: Record<ProfileToolAction, { required: Array<keyof ProfileRequest>; allowed: Array<keyof ProfileRequest> }> = {
  read: { required: [], allowed: ["path", "offset", "cursor", "includeInactive"] },
  defer: { required: ["version"], allowed: ["version"] },
  migrate: { required: ["assignments", "reason"], allowed: ["assignments", "reason"] },
  reorganize: { required: ["assignments", "reason"], allowed: ["assignments", "reason"] },
  retry: { required: ["commandId"], allowed: ["commandId"] },
  learn: { required: ["kind", "text"], allowed: ["kind", "text", "path", "corrects", "sensitive"] },
  refine: { required: ["id"], allowed: ["id", "text", "kind", "reason"] },
  supersede: { required: ["id", "kind", "text"], allowed: ["id", "kind", "text", "reason"] },
  retire: { required: ["id", "reason"], allowed: ["id", "reason"] },
};

/**
 * Content and placement use the existing Changes owner. Not now is a Knowledge
 * control decision with that owner's ordinary command receipt, not a note edit.
 * The tool owns no parallel note, decision or receipt store.
 */
export function homeProfileTool(access: () => HomeProfileChangeAccess | undefined, webMark: () => boolean, knowledge: () => KnowledgeService | undefined): ToolDefinition<TSchema, HomeProfileToolDetails> {
  return {
    name: "profile",
    // docs/settings-model.md 5.4: declares it reads no open-world content.
    annotations: { openWorldHint: false },
    label: "Profile",
    description: "Read the seven-area personal profile index, an explicit path, inferred holding notes or prior organization. Home decides relevance and worker brief content; no note text is automatically inserted. Learn/refine/supersede/retire only durable statements with evidence. Explicit migrate/reorganize assign only placement with a backed-up, logged, undoable group; retry uses its original command after an unacknowledged result. Use defer with the exact index arrival version for receipt-backed Not now, only on a maintainer turn. Declare sensitive capture with sensitive=true: never infer it, quote this maintainer message verbatim, and keep it unsorted for exact review. Home writes remain inferred, never binding by inference. Existing explicit standing/safety rules retain their authority; confirmation and provenance must not be silently weakened.",
    parameters: PROFILE_PARAMETERS,
    executionMode: "sequential",
    execute: async (toolCallId, parameters, _signal, _update, context) => {
      const request = parameters as ProfileRequest;
      const refusal = validateRequest(request);
      if (refusal) return refused(request.action, refusal);
      if (request.action === "read") {
        const owner = knowledge();
        if (!owner) return answer({ status: "unavailable", action: "read" }, "Knowledge is unavailable; no profile content was selected.");
        const read = await readHomeProfileIndex(owner);
        if (!request.path) return answer({ status: "read", items: [], unclassified: read.diagnostics.length, sorting: read.sorting, index: profileIndex(read, request.offset) }, profileIndex(read, request.offset));
        const path = request.path;
        if (path !== "prior" && path !== "inferred") { try { profilePath(path); } catch (error) { return refused("read", error instanceof Error ? error.message : String(error)); } }
        const all = read.items.filter(item => (request.includeInactive || item.status === "active") && (item.path === path || item.path.startsWith(`${path}/`)));
        const snapshot = createHash("sha256").update(JSON.stringify([read.items.map(item => [item.id, item.revisionId]), read.diagnostics])).digest("hex");
        let offset = request.offset ?? 0;
        if (request.cursor) {
          try {
            const cursor = JSON.parse(Buffer.from(request.cursor, "base64url").toString("utf8")) as { path: string; snapshot: string; offset: number; includeInactive: boolean };
            if (cursor.includeInactive !== (request.includeInactive === true) || cursor.path !== path || cursor.snapshot !== snapshot || !Number.isInteger(cursor.offset) || cursor.offset < 0 || cursor.offset > all.length) throw new Error("stale");
            offset = cursor.offset;
          } catch { return refused("read", "Profile page query or snapshot changed; restart the read"); }
        } else if (offset !== 0) return refused("read", "Continue profile record pages with the returned cursor, not a raw offset");
        const items: unknown[] = [];
        for (const item of all.slice(offset, offset + 16)) {
          const canonical = await owner.store.read(item.id, item.revisionId);
          if (!canonical || canonical.kind !== "note") throw new GatewayError("conflict", "Profile record is unavailable; restart this read");
          const record = { ...item, provenance: canonical.provenance, content: canonical.content };
          if (Buffer.byteLength(JSON.stringify({ path, items: [...items, record] })) > 32 * 1024 - 512) {
            if (items.length) break;
            items.push({ id: item.id, revisionId: item.revisionId, path: item.path, contentReference: { operation: "knowledge.read", id: item.id, revisionId: item.revisionId }, bytes: Buffer.byteLength(JSON.stringify(record)), reason: "Exact record exceeds this page; read the canonical reference. No content was truncated." });
          } else items.push(record);
        }
        const nextCursor = offset + items.length < all.length ? Buffer.from(JSON.stringify({ path, snapshot, offset: offset + items.length, includeInactive: request.includeInactive === true })).toString("base64url") : undefined;
        const details = { status: "read" as const, path, items, unclassified: read.diagnostics.length, ...(nextCursor === undefined ? {} : { nextCursor }) };
        return answer(details, JSON.stringify(details));
      }
      const changes = access();
      if (!changes) return answer({ status: "unavailable", action: request.action }, "Knowledge is unavailable on this Gateway, so the profile cannot change.");
      const citation = triggeringMessage(context);
      if (!citation) return refused(request.action, "no maintainer message in this chat to cite as evidence");
      if (request.action === "defer") {
        try {
          const result = await changes.deferSorting(commandId(citation.sessionId, toolCallId), request.version!);
          return answer(result, "Not now recorded. Sorting offers stay suppressed until a new profile note arrives; edits, moves, time and receipt replay do not reset it.");
        } catch (error) {
          if (error instanceof GatewayError && ["conflict", "invalid_request"].includes(error.code)) return refused("defer", error.message);
          throw error;
        }
      }
      if (request.action === "learn" && request.sensitive && !triggeringStatement(context, citation.entryId).includes(request.text!.trim())) return refused("learn", "Never infer sensitive information: capture only its verbatim statement in this maintainer message, unsorted for review");
      if (request.action === "migrate" || request.action === "reorganize" || request.action === "retry") {
        const original = request.action === "retry" ? request.commandId! : commandId(citation.sessionId, toolCallId);
        const op: HomeProfileRequest = request.action === "retry" ? { action: "retry", commandId: original } : { action: request.action, assignments: request.assignments! };
        try {
          const result = await changes.change([op], { toolCallId, web: webMark(), author: { kind: "home", ...citation }, commandId: original, ...(request.reason ? { reason: request.reason.trim() } : {}) });
          if (result.status === "pending") return answer({ status: "pending", action: request.action, approval: result.approval }, "Waiting for the maintainer tap on the exact before/after. Original notes remain unchanged.");
          return answer({ status: "organized", action: request.action, commandId: original, changeIds: result.changes.map(change => change.changeId) },
            `Profile ${request.action} acknowledged through Changes. Original command ${original}; ${result.changes.length} label-only changes. No content or authority was inferred.`);
        } catch (error) {
          // Publication may have failed AFTER the domain committed. Never call it
          // saved, mint another identity, or invite an unqualified second apply.
          const reason = error instanceof Error ? error.message : String(error);
          return answer({ status: "retry_required", action: request.action, commandId: original, reason },
            `Profile ${request.action} is not acknowledged: ${reason}. Use retry with original command ${original}; it proves committed identities before repairing the audit, or resumes only the backed-up precommit intent. No success is assumed.`);
        }
      }
      const op = request.action === "learn" ? { action: "learn" as const, kind: request.kind!, text: request.text!, ...(request.sensitive ? { sensitive: true } : {}), ...(request.path ? { path: request.path } : {}), ...(request.corrects ? { corrects: request.corrects } : {}) }
        : request.action === "refine" ? { action: "refine" as const, id: request.id!, ...(request.text ? { text: request.text } : {}), ...(request.kind ? { kind: request.kind } : {}), ...(request.reason ? { reason: request.reason } : {}) }
          : request.action === "supersede" ? { action: "supersede" as const, id: request.id!, kind: request.kind!, text: request.text!, ...(request.reason ? { reason: request.reason } : {}) }
            : { action: "retire" as const, id: request.id!, reason: request.reason! };
      let saved: HomeProfileSaved;
      try {
        const result = await changes.change([op], {
          toolCallId, web: webMark(), author: { kind: "home", ...citation }, commandId: commandId(citation.sessionId, toolCallId),
          ...(request.reason ? { reason: request.reason.trim() } : {}),
        });
        if (result.status === "pending") return answer({ status: "pending", action: request.action, approval: result.approval }, "Waiting for the maintainer tap on the exact before/after. Original notes remain unchanged.");
        [saved] = result.saved as [HomeProfileSaved];
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

function refused(action: ProfileToolAction, reason: string) {
  const trimmed = reason.replace(/\.$/u, "");
  return answer({ status: "refused", action, reason: trimmed }, `Profile ${action} refused: ${trimmed}.`);
}

function validateRequest(request: ProfileRequest): string | undefined {
  const fields = ACTION_FIELDS[request.action];
  if (!fields) return "unknown profile action";
  if (request.path !== undefined && !(request.action === "read" && ["prior", "inferred"].includes(request.path))) {
    try { profilePath(request.path); } catch (error) { return error instanceof Error ? error.message : String(error); }
  }
  for (const field of fields.required) if (request[field] === undefined) return `${request.action} requires ${field}`;
  for (const field of Object.keys(request) as Array<keyof ProfileRequest>) {
    if (field !== "action" && request[field] !== undefined && !fields.allowed.includes(field)) return `${request.action} does not take ${field}`;
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

function triggeringStatement(context: ExtensionToolContext, entryId: string): string {
  const entry = context.sessionManager.getBranch().find(candidate => candidate.id === entryId);
  if (entry?.type !== "message" || entry.message.role !== "user") return "";
  const content = entry.message.content;
  return typeof content === "string" ? content : content.filter(block => block.type === "text").map(block => block.text).join("\n");
}

/** Idempotency: a replayed tool call maps to the same command, and so to the same receipt. */
function commandId(sessionId: string, toolCallId: string): string {
  return `profile-${createHash("sha256").update(`${sessionId}\0${toolCallId}`).digest("hex").slice(0, 48)}`;
}
