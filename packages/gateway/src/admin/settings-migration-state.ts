import { GatewayError } from "../errors.js";
import { RETIRED_SCOPES } from "../sessions/session-settings.js";
import { approvalDigest } from "./settings-approvals.js";

type Document = Record<string, unknown>;
export const migrationRefusal = (file: string, reason: string): never => {
  throw new GatewayError("conflict", `Settings migration refused ${file}: ${reason}`);
};
export function migrationObject(value: unknown, file: string): Document {
  if (!value || typeof value !== "object" || Array.isArray(value)) return migrationRefusal(file, "expected a JSON object");
  return value as Document;
}
export function parseMigrationObject(text: string, file: string): Document {
  try { return migrationObject(JSON.parse(text), file); } catch { return migrationRefusal(file, "invalid JSON object"); }
}
function scope(value: unknown, file: string, delegated = false): string {
  if (typeof value === "string" && Object.hasOwn(RETIRED_SCOPES, value)) return RETIRED_SCOPES[value]!;
  if (value === "global" || value === "session" || value === "project" || (delegated && value === "delegate")) return value;
  return migrationRefusal(file, "unrecognized settings scope");
}
function target(value: unknown, file: string): Document {
  const data = { ...migrationObject(value, file) };
  if (data.kind === "mac") data.kind = "global";
  if (!["global", "home", "session", "project"].includes(String(data.kind))) return migrationRefusal(file, "unrecognized settings target");
  if (data.kind === "session" && typeof data.sessionId !== "string") return migrationRefusal(file, "session target has no identity");
  if (data.kind === "project" && typeof data.cwd !== "string") return migrationRefusal(file, "Project target has no path");
  return data;
}
function fixed(value: unknown, file: string): Document {
  const data = { ...migrationObject(value, file) };
  if (typeof data.ref !== "string" || !data.ref || typeof data.at !== "string" || !Number.isFinite(Date.parse(data.at))) return migrationRefusal(file, "invalid snapshot identity");
  data.from = scope(data.from, file, true);
  return data;
}
export function migrateAuditEntry(value: unknown, file: string): Document {
  const data = { ...migrationObject(value, file) };
  if (typeof data.changeId !== "string" || typeof data.key !== "string") return migrationRefusal(file, "audit entry has no identity");
  data.target = target(data.target, file); data.layer = scope(data.layer, file);
  if (data.fixedAt !== undefined) data.fixedAt = fixed(data.fixedAt, file);
  return data;
}
export function migrateApprovals(value: Document, file: string): Document {
  if (value.version !== 1 || !Array.isArray(value.requests)) return migrationRefusal(file, "invalid approvals document");
  return { ...value, requests: value.requests.map(value => {
    const request = { ...migrationObject(value, file) };
    if (typeof request.requestId !== "string" || typeof request.expiresAt !== "string" || typeof request.createdAt !== "string"
      || !["pending", "approved", "declined", "expired", "superseded", "failed"].includes(String(request.status)) || !Array.isArray(request.changes)) return migrationRefusal(file, "invalid approval identity or status");
    const originalChanges = request.changes.map(value => {
      const change = migrationObject(value, file);
      if (typeof change.key !== "string" || typeof change.layer !== "string" || typeof change.op !== "string") return migrationRefusal(file, "invalid pending diff");
      return { ...change, key: change.key, layer: change.layer, op: change.op };
    });
    if (typeof request.digest !== "string" || request.digest !== approvalDigest(request.target, originalChanges)) return migrationRefusal(file, "pending approval digest does not match its diff");
    const changes = originalChanges.map(value => {
      const change = { ...migrationObject(value, file) };
      if (typeof change.key !== "string" || typeof change.changeId !== "string" || !["set", "unset"].includes(String(change.op))) return migrationRefusal(file, "invalid pending diff");
      return { ...change, key: change.key, op: String(change.op), layer: scope(change.layer, file),
        ...(change.fixedAt !== undefined ? { fixedAt: fixed(change.fixedAt, file) } : {}) };
    });
    request.target = target(request.target, file); request.changes = changes;
    // The same owner algorithm used for new requests. No status, expiry,
    // decision, actor or request identity changes as a side effect of migration.
    request.digest = approvalDigest(request.target, changes);
    return request;
  }) };
}
export function migrateObserved(value: Document, file: string): Document {
  if (value.version !== 1) return migrationRefusal(file, "invalid observed-store version");
  migrationObject(value.stores, file);
  // These are persistence-store IDs, not public scopes. Keep outside-write
  // baselines and their receipt links stable to avoid inventing outside edits.
  return value;
}
export function migrationSetPath(document: Document, path: readonly string[], value: unknown): void {
  let current = document;
  for (const field of path.slice(0, -1)) {
    if (!Object.hasOwn(current, field)) Object.defineProperty(current, field, { value: {}, writable: true, enumerable: true, configurable: true });
    current = migrationObject(current[field], path.join("."));
  }
  Object.defineProperty(current, path.at(-1)!, { value: structuredClone(value), writable: true, enumerable: true, configurable: true });
}
