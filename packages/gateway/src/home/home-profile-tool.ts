import { createHash } from "node:crypto";
import { Type, type TSchema } from "../kernel/pi/ai.js";
import type { ExtensionToolContext, ToolDefinition } from "../kernel/pi/coding-agent.js";
import { GatewayError } from "../errors.js";
import type { KnowledgeService } from "../knowledge/knowledge-service.js";
import { validProfileFile, type ProfileFile } from "./home-profile-files.js";
import { HOME_PROFILE_ACTIONS, HOME_PROFILE_KINDS, PROFILE_TEXT_MAX, PROFILE_REASON_MAX, readHomeProfile, profileListItem,
  type HomeProfileAction, type HomeProfileAuthor, type HomeProfileKind, type HomeProfileOp, type HomeProfileSaved } from "./home-profile.js";
const SINGLE_LINE = /[\u0000-\u001f\u007f\u2028\u2029]/;

// ---- the profile tool -----------------------------------------------------------

const PROFILE_PARAMETERS = Type.Object({
  action: Type.Union(HOME_PROFILE_ACTIONS.map((action) => Type.Literal(action)), { description: "read a file on demand; learn a new item; refine its text, kind or file; supersede it; retire it." }),
  file: Type.Optional(Type.String({ pattern: "^(core|home|scopes/[a-z][a-z0-9-]{0,47})$", description: "core (every Home turn and brief), home (Home turns only), or scopes/<slug> (contextual facts selected for a brief). Required for read." })),
  contradicts: Type.Optional(Type.Array(Type.String({ minLength: 1, maxLength: 200 }), { maxItems: 16, description: "IDs of existing rules this proposed save contradicts. A flagged save is refused for review; explicitly supersede an obsolete rule instead." })),
  assignments: Type.Optional(Type.Array(Type.Object({ id: Type.String({ minLength: 1, maxLength: 200 }), expectedRevision: Type.String({ minLength: 1, maxLength: 80 }), file: Type.String({ pattern: "^(core|home|scopes/[a-z][a-z0-9-]{0,47})$" }) }, { additionalProperties: false }), { minItems: 1, maxItems: 500, description: "migrate: assign every current profile note exactly once using the approved file mapping; backs up first, changes labels atomically, preserves rule text/history and records undo in Changes." })),
  kind: Type.Optional(Type.Union(HOME_PROFILE_KINDS.map((kind) => Type.Literal(kind)), { description: "learn and supersede: the item's kind. refine: a new kind, when it changes." })),
  text: Type.Optional(Type.String({ minLength: 1, maxLength: PROFILE_TEXT_MAX, description: "learn, refine and supersede: one line of the item's text, as the maintainer states it." })),
  id: Type.Optional(Type.String({ minLength: 1, maxLength: 200, description: "refine, supersede and retire: the profile note ID shown in the Learned profile section." })),
  reason: Type.Optional(Type.String({ minLength: 1, maxLength: PROFILE_REASON_MAX, description: "Why the change is made. Required for retire; recorded in the ledger." })),
}, { additionalProperties: false });

/** Tool-result details: the saved revision, or the typed reason a change was refused. */
export type HomeProfileToolDetails =
  | HomeProfileSaved
  | { status: "read"; file: string; items: ReturnType<typeof profileListItem>[]; diagnostics: string[] }
  | { status: "refused"; action: HomeProfileAction; reason: string }
  | { status: "unavailable"; action: HomeProfileAction };

type ProfileRequest = {
  assignments?: Array<{ id: string; expectedRevision: string; file: ProfileFile }>;
  file?: ProfileFile;
  contradicts?: string[];
  action: HomeProfileAction;
  kind?: HomeProfileKind;
  text?: string;
  id?: string;
  reason?: string;
};

/** Which fields each action takes. Anything else is refused, never silently ignored. */
const ACTION_FIELDS: Record<HomeProfileAction, { required: Array<keyof ProfileRequest>; allowed: Array<keyof ProfileRequest> }> = {
  read: { required: ["file"], allowed: ["file"] },
  migrate: { required: ["assignments"], allowed: ["assignments"] },
  learn: { required: ["kind", "text"], allowed: ["kind", "text", "file", "reason", "contradicts"] },
  refine: { required: ["id"], allowed: ["id", "text", "kind", "reason", "file", "contradicts"] },
  supersede: { required: ["id", "kind", "text"], allowed: ["id", "kind", "text", "reason", "file"] },
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
export function homeProfileTool(access: () => HomeProfileChangeAccess | undefined, webMark: () => boolean, knowledge: () => KnowledgeService | undefined): ToolDefinition<TSchema, HomeProfileToolDetails> {
  return {
    name: "profile",
    // docs/settings-model.md 5.4: declares it reads no open-world content.
    annotations: { openWorldHint: false },
    label: "Profile",
    description: "Read a profile file on demand, or learn/refine/supersede/retire a durable rule in a capped file. Keep every binding rule in core/home; scopes hold contextual facts. Compare existing rules before saving: name semantic contradictions in contradicts so the save is flagged and refused, then seek review or explicitly supersede an obsolete rule. Text edits stay inferred until confirmed. Changes is undoable and edits apply next Home turn and next delegation without restart. migrate atomically labels every existing note using an approved mapping, with an automatic backup and Changes undo; repeated identical migration is a no-op. It never moves or deletes rule text.",
    parameters: PROFILE_PARAMETERS,
    executionMode: "sequential",
    execute: async (toolCallId, parameters, _signal, _update, context) => {
      const request = parameters as ProfileRequest;
      if (request.action === "read") {
        if (!request.file || !validProfileFile(request.file)) return refused("read", "read requires a valid file");
        const owner = knowledge();
        if (!owner) return answer({ status: "unavailable", action: "read" }, "Knowledge is unavailable on this Gateway.");
        const read = await readHomeProfile(owner);
        const items = read.items.filter(item => (item.file ?? "core") === request.file);
        const diagnostics = [...read.diagnostics, ...(!items.length && request.file.startsWith("scopes/") ? [`Profile diagnostic: ${request.file} is unknown or missing; core remains applied.`] : [])];
        return answer({ status: "read", file: request.file, items: items.map(profileListItem), diagnostics }, JSON.stringify({ file: request.file, items: items.map(profileListItem), diagnostics }));
      }
      const changes = access();
      if (!changes) return answer({ status: "unavailable", action: request.action }, "Knowledge is unavailable on this Gateway, so the profile cannot change.");
      const refusal = validateRequest(request);
      if (refusal) return refused(request.action, refusal);
      const citation = triggeringMessage(context);
      if (!citation) return refused(request.action, "no maintainer message in this chat to cite as evidence");
      const op = request.action === "migrate" ? { action: "migrate" as const, assignments: request.assignments! } : request.action === "learn" ? { action: "learn" as const, kind: request.kind!, text: request.text!, ...(request.reason ? { reason: request.reason } : {}) }
        : request.action === "refine" ? { action: "refine" as const, id: request.id!, ...(request.text ? { text: request.text } : {}), ...(request.kind ? { kind: request.kind } : {}), ...(request.file ? { file: request.file } : {}), ...(request.reason ? { reason: request.reason } : {}) }
          : request.action === "supersede" ? { action: "supersede" as const, id: request.id!, kind: request.kind!, text: request.text!, ...(request.reason ? { reason: request.reason } : {}) }
            : { action: "retire" as const, id: request.id!, reason: request.reason! };
      const filedOp = (op.action === "learn" || op.action === "supersede") && request.file ? { ...op, file: request.file } : op;
      let saved: HomeProfileSaved;
      try {
        [saved] = (await changes.change([{ ...filedOp, ...(request.contradicts ? { contradicts: request.contradicts } : {}) }], {
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
    case "migrate": return `Profile file migration saved. Backup: ${saved.backup ?? "already organized; no changes"}. Rule text and history are preserved; undo is in Changes.`;
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
  for (const field of ["kind", "text", "id", "reason", "file", "contradicts", "assignments"] as const) {
    if (request[field] !== undefined && !fields.allowed.includes(field)) return `${request.action} does not take ${field}`;
  }
  if (request.action === "refine" && request.text === undefined && request.kind === undefined && request.file === undefined) return "refine requires text, kind or file";
  if (request.file !== undefined && !validProfileFile(request.file)) return "invalid profile file";
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
