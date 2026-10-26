import { createHash } from "node:crypto";
import { Type, type TSchema } from "../../kernel/pi/ai.js";
import type { ExtensionToolContext, ToolDefinition } from "../../kernel/pi/coding-agent.js";
import { GatewayError } from "../../errors.js";
import type { KnowledgeService } from "../../knowledge/knowledge-service.js";
import { validProfileFile, PROFILE_FILE_PATTERN, type ProfileFile } from "../../knowledge/knowledge-notes.js";
import { profileIndex } from "./home-profile-hierarchy.js";
import { HOME_PROFILE_ACTIONS, HOME_PROFILE_KINDS, PROFILE_TEXT_MAX, PROFILE_REASON_MAX, readHomeProfile, profileListItem, type HomeProfileAction, type HomeProfileKind, type HomeProfileSaved, type HomeProfileChangeAccess } from "./home-profile.js";
const SINGLE_LINE = /[\u0000-\u001f\u007f\u2028\u2029]/;

// ---- the profile tool -----------------------------------------------------------

const PROFILE_PARAMETERS = Type.Object({
  action: Type.Union([...HOME_PROFILE_ACTIONS, "read" as const].map((action) => Type.Literal(action)), { description: "read an explicit file or the metadata index; learn, refine, supersede or retire an item." }),
  file: Type.Optional(Type.String({ pattern: PROFILE_FILE_PATTERN, description: "Explicit partition; read with no file returns the index. New items default to core, not automatic insertion." })),
  offset: Type.Optional(Type.Integer({ minimum: 0, maximum: 10_000, description: "read: note offset within this explicit file." })),
  kind: Type.Optional(Type.Union(HOME_PROFILE_KINDS.map((kind) => Type.Literal(kind)), { description: "learn and supersede: the item's kind. refine: a new kind, when it changes." })),
  text: Type.Optional(Type.String({ minLength: 1, maxLength: PROFILE_TEXT_MAX, description: "learn, refine and supersede: one line of the item's text, as the maintainer states it." })),
  id: Type.Optional(Type.String({ minLength: 1, maxLength: 200, description: "refine, supersede and retire: the exact profile note ID returned by profile read." })),
  reason: Type.Optional(Type.String({ minLength: 1, maxLength: PROFILE_REASON_MAX, description: "Why the change is made. Required for retire; recorded in the ledger." })),
}, { additionalProperties: false });

/** Tool-result details: the saved revision, or the typed reason a change was refused. */
export type HomeProfileToolDetails =
  | HomeProfileSaved
  | { status: "refused"; action: ProfileToolAction; reason: string }
  | { status: "unavailable"; action: ProfileToolAction }
  | { status: "read"; file?: ProfileFile; items: unknown[]; unclassified: number; nextOffset?: number; index?: string };

type ProfileToolAction = HomeProfileAction | "read";
type ProfileRequest = {
  action: ProfileToolAction;
  file?: string;
  offset?: number;
  kind?: HomeProfileKind;
  text?: string;
  id?: string;
  reason?: string;
};

/** Which fields each action takes. Anything else is refused, never silently ignored. */
const ACTION_FIELDS: Record<ProfileToolAction, { required: Array<keyof ProfileRequest>; allowed: Array<keyof ProfileRequest> }> = {
  read: { required: [], allowed: ["file", "offset"] },
  learn: { required: ["kind", "text"], allowed: ["kind", "text", "file"] },
  refine: { required: ["id"], allowed: ["id", "text", "kind", "reason"] },
  supersede: { required: ["id", "kind", "text"], allowed: ["id", "kind", "text", "reason"] },
  retire: { required: ["id", "reason"], allowed: ["id", "reason"] },
};

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
    description: "Read the structured profile index or an explicit core, home or scopes/<name> file. Home decides relevance and worker brief content; no note text is automatically inserted. Learn/refine/supersede/retire only durable statements with evidence, using the existing logged undoable change path. Home writes remain inferred, never binding by inference. Existing explicit standing/safety rules retain their authority; confirmation and provenance must not be silently weakened.",
    parameters: PROFILE_PARAMETERS,
    executionMode: "sequential",
    execute: async (toolCallId, parameters, _signal, _update, context) => {
      const request = parameters as ProfileRequest;
      const refusal = validateRequest(request);
      if (refusal) return refused(request.action, refusal);
      if (request.action === "read") {
        const owner = knowledge();
        if (!owner) return answer({ status: "unavailable", action: "read" }, "Knowledge is unavailable; no profile content was selected.");
        const read = await readHomeProfile(owner);
        if (!request.file) return answer({ status: "read", items: [], unclassified: read.diagnostics.length, index: profileIndex(read, request.offset) }, profileIndex(read, request.offset));
        const file = request.file as ProfileFile;
        const offset = request.offset ?? 0;
        const all = read.items.filter(item => item.file === file || (item.file === undefined && file === "core"));
        const items = all.slice(offset, offset + 16).map(item => ({ ...profileListItem(item), file, provenance: item.record.provenance, content: item.record.content }));
        const details = { status: "read" as const, file, items, unclassified: read.diagnostics.length, ...(offset + items.length < all.length ? { nextOffset: offset + items.length } : {}) };
        return answer(details, JSON.stringify(details));
      }
      const changes = access();
      if (!changes) return answer({ status: "unavailable", action: request.action }, "Knowledge is unavailable on this Gateway, so the profile cannot change.");
      const citation = triggeringMessage(context);
      if (!citation) return refused(request.action, "no maintainer message in this chat to cite as evidence");
      const op = request.action === "learn" ? { action: "learn" as const, kind: request.kind!, text: request.text!, ...(request.file ? { file: request.file as ProfileFile } : {}) }
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

function refused(action: ProfileToolAction, reason: string) {
  const trimmed = reason.replace(/\.$/u, "");
  return answer({ status: "refused", action, reason: trimmed }, `Profile ${action} refused: ${trimmed}.`);
}

function validateRequest(request: ProfileRequest): string | undefined {
  const fields = ACTION_FIELDS[request.action];
  if (!fields) return "unknown profile action";
  if (request.file !== undefined && !validProfileFile(request.file)) return "invalid profile file";
  for (const field of fields.required) if (request[field] === undefined) return `${request.action} requires ${field}`;
  for (const field of ["kind", "text", "id", "reason", "file", "offset"] as const) {
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
