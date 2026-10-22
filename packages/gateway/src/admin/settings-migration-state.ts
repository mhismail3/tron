import { GatewayError } from "../errors.js";
import { approvalDigest } from "./settings-approvals.js";
import { KEYS, keyForHome, type KeyDeclaration } from "./settings-schema.js";
import { resolveInstance, type SettingsStores } from "./settings-resolver.js";

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
  if (value === "mac" || value === "builtin" || value === "global") return "global";
  if (value === "profile" || value === "chat" || value === "session") return "session";
  if (value === "project" || (delegated && value === "delegate")) return value;
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
export interface MigrationDefaults { mac: Document; gateway: Document; floors: SettingsStores["floors"] }
function currentGlobal(key: KeyDeclaration, qualifiers: Record<string, string>, defaults: MigrationDefaults): unknown {
  const stores: SettingsStores = { layers: ["mac", "builtin"], ...defaults, trust: {}, macTerminal: {} };
  return resolveInstance(key, qualifiers, stores, { format: { modelName: () => undefined }, options: { clamp: (_source, _dependency, value) => value } }, () => undefined).value;
}

/** Converts only the settings custom entry, never arbitrary message/user data.
 * Entry IDs, parents and unrelated custom fields remain byte-for-byte values. */
export function migrateSessionSettings(value: Document, file: string, defaults: MigrationDefaults,
  notes: Array<{ file: string; key: string; reason: string }>): Document {
  const original = migrationObject(value.data, file);
  const data = { ...original, settings: structuredClone(migrationObject(original.settings, file)) };
  for (const field of ["fixed", "requestPins"] as const) {
    if (original[field] === undefined) continue;
    const snapshots = { ...migrationObject(original[field], file) };
    for (const [id, value] of Object.entries(snapshots)) {
      const old = migrationObject(value, file);
      const converted = fixed(old, file);
      const key = KEYS.find(key => key.id === id);
      if (!key) { notes.push({ file, key: id, reason: "unknown snapshot preserved" }); snapshots[id] = converted; continue; }
      const qualifiers = { ...(key.fixed ?? {}), ...(old.qualifiers === undefined ? {} : migrationObject(old.qualifiers, file)) } as Record<string, string>;
      const global = currentGlobal(key, qualifiers, defaults);
      if (old.from === "project" && !key.projectSettable) {
        // A forbidden inherited permission must not be laundered into a new
        // Session override. This is an approved Project safety delta.
        if (global === undefined) delete snapshots[id];
        else snapshots[id] = { ...converted, from: "global", value: global };
        notes.push({ file, key: id, reason: "ignored inherited Project permission" });
        continue;
      }
      if (["mac", "builtin", "profile"].includes(String(old.from)) && key.sessionOverridable
        && JSON.stringify(old.value) !== JSON.stringify(global)) {
        converted.from = "session";
        const binding = key.layers.chat;
        if (binding?.store === "chat-settings") migrationSetPath(data.settings, binding.path, old.value);
        notes.push({ file, key: id, reason: "preserved differing inherited snapshot as override" });
      }
      snapshots[id] = converted;
    }
    Object.defineProperty(data, field, { value: snapshots, writable: true, enumerable: true, configurable: true });
  }
  return { ...value, data };
}

/** Fold the currently effective chapter's explicit choices into the Profile
 * store. Branch selection is supplied by the canonical parent chain, not audit. */
export function foldHomeChapter(profile: Document, settings: Document | undefined,
  model: unknown, thinking: unknown, file: string): Document {
  const result = structuredClone(profile);
  const fixed = settings?.fixed === undefined ? {} : migrationObject(settings.fixed, file);
  for (const declared of KEYS) {
    const key = keyForHome(declared, true);
    const destination = key.layers.profile;
    const source = key.layers.chat;
    if (!key.sessionOverridable || destination?.store !== "profile" || !source) continue;
    let value: unknown;
    if (source.store === "chat-settings" && settings?.settings !== undefined) {
      value = source.path.reduce<unknown>((current, field) => current && typeof current === "object" && Object.hasOwn(current, field) ? (current as Document)[field] : undefined, settings.settings);
    } else if (source.store === "chat") {
      const snapshot = fixed[key.id] === undefined ? undefined : migrationObject(fixed[key.id], file);
      // A recorded inherited frame is not a user choice. Without provenance,
      // the existing reader treats SDK model/thinking records as legacy choices.
      if (snapshot?.from === "session" || snapshot?.from === "delegate") value = snapshot.value;
      else if (!snapshot) value = source.field === "model" ? model : source.field === "thinking" ? thinking : undefined;
    }
    if (value !== undefined) migrationSetPath(result, destination.path, value);
  }
  return result;
}
