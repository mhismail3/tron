import { HOME_PROFILE_SUBJECT, recordSubject, type SettingsSchema } from "../kernel/settings/settings-schema.js";
import type { Actor, ChangeEntry } from "../kernel/settings/settings-record.js";
import { formatStoredSetting, LAYER_LABELS } from "../kernel/settings/settings-types.js";

function requesterLabel(actor: Actor): string {
  return actor.kind === "worker" && actor.taskId ? `Home task ${actor.taskId}`
    : actor.kind === "home" ? "Home" : actor.kind === "worker" ? "A Home task worker" : actor.kind === "agent" ? "A chat's agent" : actor.kind === "outside" ? "Outside Tron" : "You";
}

const KIND_LABELS = {
  preference: "preference", "standing-decision": "standing decision", "delegation-default": "delegation default", fact: "fact",
} as const;

export function formatProfileValue(value: unknown): string {
  if (value === null || value === undefined) return "Not in the profile";
  const item = value as Record<string, unknown> & { kind?: keyof typeof KIND_LABELS };
  if (item.state === "retired") return `Retired: ${item.text ?? ""}`.trim();
  if (item.state === "superseded") return `Superseded: ${item.text ?? ""}`.trim();
  const kind = item.kind && KIND_LABELS[item.kind] ? KIND_LABELS[item.kind] : "item";
  return `${item.confirmed ? "Confirmed" : "Inferred"} ${kind}: ${item.text ?? ""}`;
}

export function presentHistoryEntry(schema: SettingsSchema, entry: ChangeEntry) {
  if (entry.key === HOME_PROFILE_SUBJECT.id) {
    return { ...entry, presentation: {
      label: HOME_PROFILE_SUBJECT.label, section: HOME_PROFILE_SUBJECT.group,
      actor: requesterLabel(entry.actor), layer: LAYER_LABELS[entry.layer],
      display: { before: formatProfileValue(entry.before), after: formatProfileValue(entry.after) },
    } };
  }
  if (entry.action) {
    const title = (entry.after as { title?: unknown } | undefined)?.title;
    return { ...entry, presentation: {
      label: typeof title === "string" ? title : entry.key, actor: requesterLabel(entry.actor), layer: LAYER_LABELS[entry.layer],
      display: { before: "Requested", after: entry.status[0]!.toUpperCase() + entry.status.slice(1) },
    } };
  }
  const key = schema.KEYS.find(key => key.id === entry.key);
  const subject = key ? undefined : recordSubject(entry.key);
  const format = (value: unknown): string => formatStoredSetting(key?.type, value);
  const name = subject ? entry.qualifiers?.[subject.qualifier] : undefined;
  const display = subject ? entry.op === "unset" ? { before: "Configured", after: "Removed" }
    : entry.added ? { before: "Not configured", after: "Added" } : { before: "Configured", after: "Changed" }
    : entry.redacted ? { before: "Hidden", after: "Changed" } : { before: format(entry.before), after: format(entry.after) };
  return {
    ...entry,
    presentation: {
      label: key?.label ?? (subject ? `${subject.label}${name ? ` ${name}` : ""}` : entry.key),
      ...(key ? { section: key.group } : subject ? { section: subject.group } : {}),
      actor: requesterLabel(entry.actor), layer: LAYER_LABELS[entry.layer],
      display,
    },
  };
}
