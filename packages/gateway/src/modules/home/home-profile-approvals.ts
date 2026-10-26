import { GatewayError } from "../../errors.js";
import type { KnowledgeService } from "../../knowledge/knowledge-service.js";
import { profilePath } from "../../knowledge/knowledge-profile-placement.js";
import { profileLabels, profileMigrationMembers } from "../../knowledge/knowledge-notes.js";
import type { SettingsChangePath } from "../../kernel/settings/settings-change.js";
import type { ApprovalActionItem } from "../../kernel/settings/tool-contract.js";
import { HomeProfileItems, PROFILE_APPROVAL_ACTION, profileValue, type HomeProfileRequest, type ProfileChangeContext, type ProfileChangePath } from "./home-profile.js";

interface ReviewIntent { requests: HomeProfileRequest[]; context: ProfileChangeContext }
function intent(raw: unknown): ReviewIntent {
  if (!raw || typeof raw !== "object" || Array.isArray(raw)) throw new GatewayError("invalid_request", "Invalid profile review intent");
  const value = raw as ReviewIntent;
  if (!Array.isArray(value.requests) || !value.requests.length || !value.context || value.context.author?.kind !== "home"
    || value.context.actor?.kind !== "home" || value.context.approved !== undefined || !value.context.commandId?.trim()
    || !value.context.reason?.trim() || value.requests.some(op => !["confirm", "refine", "supersede", "retire", "migrate", "reorganize"].includes(op.action))) {
    throw new GatewayError("invalid_request", "Profile review needs the original Home intent, reason and exact source heads");
  }
  return value;
}

/** One registered action, using the existing approval store/digest/outcomes. No
 * separate profile approval ledger, no authority granted by a model parameter. */
export function registerProfileApprovals(changes: SettingsChangePath, knowledge: () => KnowledgeService | undefined): void {
  const profile = new HomeProfileItems(knowledge);
  const plan = async (raw: unknown) => {
    const value = intent(raw);
    const read = await profile.read();
    const items: ApprovalActionItem[] = [];
    for (const op of value.requests) {
      if (op.action === "migrate" || op.action === "reorganize") {
        if (value.requests.length !== 1 || !Array.isArray(op.assignments) || !op.assignments.length || op.assignments.length > (op.action === "migrate" ? 500 : 8)) throw new GatewayError("invalid_request", "Review holds one migration or at most 8 sorting assignments");
        const members = profileMigrationMembers(read.items.map(item => item.record));
        if (op.action === "migrate" && (read.unclassified || op.assignments.length !== members.length || members.some(note => !op.assignments.some(assignment => assignment.id === note.id)))) throw new GatewayError("conflict", "Migration review needs exactly the active legacy Core/Home notes; inactive and scoped originals stay unchanged");
        const lines: string[] = [];
        for (const assignment of op.assignments) {
          const item = read.items.find(item => item.id === assignment.id);
          if (!item || item.revisionId !== assignment.expectedRevision || assignment.path === undefined) throw new GatewayError("conflict", "Profile changed since this exact organization was proposed");
          const target = profilePath(assignment.path);
          if (item.kind === "correction" && target.path[0] !== "corrections") throw new GatewayError("invalid_request", "Corrections stay in the Corrections area");
          // Text/authority are NOT changed. Exact placement (including malformed
          // legacy labels and their positions) and source revision bind the tap.
          lines.push(JSON.stringify({ id: item.id, revision: item.revisionId,
            before: item.record.content.profile ?? { legacyLabels: profileLabels(item.record.content.tags) }, after: target }));
        }
        let chunk = "";
        for (const line of lines) {
          if (line.length > 1_000) throw new GatewayError("invalid_request", "An exact placement preview exceeds its display bound");
          if (chunk.length + line.length + 1 > 1_000) { items.push({ label: "Exact placement changes", value: chunk }); chunk = ""; }
          chunk += (chunk ? "\n" : "") + line;
        }
        if (chunk) items.push({ label: "Exact placement changes", value: chunk, detail: "Only placement and revision identity change. Text, confirmation, provenance, authority, status and historical revisions remain exact." });
        continue;
      }
      if (!("id" in op) || value.requests.length > 8) throw new GatewayError("invalid_request", "Review holds at most 8 exact profile changes");
      const item = read.items.find(item => item.id === op.id);
      if (!item || op.expectedRevision !== item.revisionId || item.status !== "active") throw new GatewayError("conflict", "Profile changed since this exact edit was proposed");
      const before = profileValue(item)!;
      const after = op.action === "supersede"
        ? { existing: { id: item.id, revisionId: item.revisionId, state: "superseded" }, replacement: { kind: op.kind, text: op.text, confirmed: true, profile: item.record.content.profile, supersedes: { id: item.id, revisionId: item.revisionId } } }
        : { ...before, ...(op.action === "retire" ? { state: "retired" } : { confirmed: true }),
          ...("text" in op && op.text !== undefined ? { text: op.text } : {}), ...("kind" in op && op.kind !== undefined ? { kind: op.kind } : {}) };
      items.push({ label: `${item.id} — before`, value: JSON.stringify(before) }, { label: `${item.id} — ${op.action}`, value: JSON.stringify(after) });
    }
    return { title: "Review exact profile changes", target: { kind: "home" as const }, items };
  };
  changes.registerAction(PROFILE_APPROVAL_ACTION, {
    plan,
    apply: async (raw, approved) => {
      const value = intent(raw);
      // decideAction already owns Home's stripe. Borrow its subject methods,
      // never recursively acquire auditSubject/publishSubjectAudit's mutex.
      const path: ProfileChangePath = { record: changes.record, requestAction: changes.requestAction.bind(changes),
        validateSubjectAudit: changes.validateSubjectAudit.bind(changes), ...approved.subjects };
      const result = await profile.change(path, value.requests, { ...value.context, approved: true });
      return { summary: `${result.changes.length} exact profile changes applied`, result };
    },
  });
}
