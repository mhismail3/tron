import { GatewayError } from "../../errors.js";
import type { KnowledgeService } from "../../knowledge/knowledge-service.js";
import { PROFILE_AREAS, profilePath, type ProfileMetadata } from "../../knowledge/knowledge-profile-placement.js";
import { profileLabels, profileMigrationMembers } from "../../knowledge/knowledge-notes.js";
import type { SettingsChangePath } from "../../kernel/settings/settings-change.js";
import type { ApprovalActionItem } from "../../kernel/settings/tool-contract.js";
import { HomeProfileItems, PROFILE_APPROVAL_ACTION, profileValue, type HomeProfileRequest, type ProfileChangeContext, type ProfileChangePath } from "./home-profile.js";

/** The note as the maintainer knows it: its own words, within the row's label bound. */
function excerpt(text: string): string {
  const line = text.replace(/\s+/gu, " ").trim();
  return line.length <= 80 ? line : `${line.slice(0, 79).trimEnd()}…`;
}

/** A placement in the profile's own area names: "Communication › Questions". */
function placement(profile: ProfileMetadata | undefined): string {
  if (!profile) return "Prior organization";
  const [root, ...rest] = profile.path;
  const area = root === "inferred" ? "Unsorted" : PROFILE_AREAS[root as keyof typeof PROFILE_AREAS] ?? root!;
  return [area, ...rest.map(segment => segment.charAt(0).toUpperCase() + segment.slice(1).replace(/-/gu, " "))].join(" › ");
}

function kindLabel(kind: string): string {
  return kind.charAt(0).toUpperCase() + kind.slice(1).replace(/-/gu, " ");
}

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
        for (const assignment of op.assignments) {
          const item = read.items.find(item => item.id === assignment.id);
          if (!item || item.revisionId !== assignment.expectedRevision || assignment.path === undefined) throw new GatewayError("conflict", "Profile changed since this exact organization was proposed");
          const target = profilePath(assignment.path);
          if (item.kind === "correction" && target.path[0] !== "corrections") throw new GatewayError("invalid_request", "Corrections stay in the Corrections area");
          // Text/authority are NOT changed. Exact placement (including malformed
          // legacy labels and their positions) and source revision bind the tap.
          const before = item.record.content.profile ?? { legacyLabels: profileLabels(item.record.content.tags) };
          items.push({ label: excerpt(item.text), value: `${placement(item.record.content.profile)} → ${placement(target)}`,
            exact: JSON.stringify({ id: item.id, revision: item.revisionId, before, after: target }) });
        }
        items.at(-1)!.detail = "Only placement and revision identity change. Text, confirmation, provenance, authority, status and historical revisions remain exact.";
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
      const text = "text" in op && op.text !== undefined ? `“${op.text}”` : undefined;
      const change = op.action === "retire" ? "Retire this note"
        : op.action === "supersede" ? `Replace with ${text}`
          : text ? `Confirm as ${text}` : "Confirm as written";
      items.push({ label: excerpt(item.text), value: change, ...("kind" in op && op.kind !== undefined && op.kind !== item.kind ? { detail: `Kind: ${kindLabel(item.kind)} → ${kindLabel(op.kind)}` } : {}),
        exact: JSON.stringify({ id: item.id, revision: item.revisionId, before, after }) });
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
