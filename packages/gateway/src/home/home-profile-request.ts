import { GatewayError } from "../errors.js";
import { object, oneOf, rejectUnknownFields, string } from "../util/validation.js";
import { HOME_PROFILE_KINDS, HOME_PROFILE_MAINTAINER_ACTIONS, type HomeProfileOp } from "./home-profile.js";

/** One `home.profileChange` op, typed: only the maintainer's actions, each with the
 * revision he read, and nothing an action does not take. */
export function profileChangeOp(raw: unknown, label: string): HomeProfileOp {
  if (!raw || typeof raw !== "object" || Array.isArray(raw)) throw new GatewayError("invalid_request", `${label} must be an object`);
  const value = raw as Record<string, unknown>;
  const action = oneOf(value.action, `${label}.action`, HOME_PROFILE_MAINTAINER_ACTIONS);
  if (action === "migrate") {
    rejectUnknownFields(value, ["action", "assignments"], label);
    if (!Array.isArray(value.assignments) || value.assignments.length < 1 || value.assignments.length > 500) throw new GatewayError("invalid_request", "migration requires 1..500 assignments");
    const assignments = value.assignments.map((raw, index) => {
      const item = object(raw, `${label}.assignments[${index}]`);
      rejectUnknownFields(item, ["id", "expectedRevision", "file"], label);
      const file = string(item.file, "file", { max: 55 });
      if (!/^(core|home|scopes\/[a-z][a-z0-9-]{0,47})$/.test(file)) throw new GatewayError("invalid_request", "Invalid profile file");
      return { id: string(item.id, "id", { max: 200 }), expectedRevision: string(item.expectedRevision, "expectedRevision", { max: 80 }), file: file as "core" | "home" | `scopes/${string}` };
    });
    return { action, assignments };
  }
  const allowed: Record<typeof action, string[]> = {
    confirm: ["action", "id", "expectedRevision"],
    refine: ["action", "id", "expectedRevision", "text", "kind", "reason", "file"],
    supersede: ["action", "id", "expectedRevision", "text", "kind", "reason", "file"],
    retire: ["action", "id", "expectedRevision", "reason"],
  };
  rejectUnknownFields(value, allowed[action], label);
  const id = string(value.id, `${label}.id`, { max: 200 });
  const expectedRevision = string(value.expectedRevision, `${label}.expectedRevision`, { max: 80 });
  const text = value.text === undefined ? undefined : string(value.text, `${label}.text`, { max: 512 });
  const kind = value.kind === undefined ? undefined : oneOf(value.kind, `${label}.kind`, HOME_PROFILE_KINDS);
  const reason = value.reason === undefined ? undefined : string(value.reason, `${label}.reason`, { max: 2_000 });
  const file = value.file === undefined ? undefined : string(value.file, `${label}.file`, { max: 55 });
  if (file !== undefined && !/^(core|home|scopes\/[a-z][a-z0-9-]{0,47})$/.test(file)) throw new GatewayError("invalid_request", "Invalid profile file");
  const filed = file ? { file: file as "core" | "home" | `scopes/${string}` } : {};
  switch (action) {
    case "confirm": return { action, id, expectedRevision };
    case "retire": return { action, id, expectedRevision, ...(reason ? { reason } : {}) };
    case "supersede":
      if (text === undefined || kind === undefined) throw new GatewayError("invalid_request", `${label}: supersede requires text and kind`);
      return { action, id, expectedRevision, text, kind, ...filed, ...(reason ? { reason } : {}) };
    default:
      return { action, id, expectedRevision, ...filed, ...(text === undefined ? {} : { text }), ...(kind ? { kind } : {}), ...(reason ? { reason } : {}) };
  }
}

