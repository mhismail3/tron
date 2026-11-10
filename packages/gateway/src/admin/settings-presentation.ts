import { HOME_PROFILE_SUBJECT, SECTIONS, keyForHome, recordSubject, type SettingsSchema, type EntryGuidance, type KeyDeclaration } from "../kernel/settings/settings-schema.js";
import type { ResolvedKey, Resolution } from "../kernel/settings/tool-contract.js";
import type { Actor, ChangeEntry } from "../kernel/settings/settings-record.js";
import { formatStoredSetting, LAYER_LABELS, RENDERER_CONTRACT_VERSION, type Control, type ValueType } from "../kernel/settings/settings-types.js";
import { scopeAdmitted } from "../kernel/settings/scope-resolution.js";

export const UPDATE_TRON_NOTE = "Update Tron to edit";

function negotiateControl(key: KeyDeclaration, clientControls: readonly string[] | undefined): { control?: Control; note?: string } {
  if (key.control === undefined) return {};
  if (key.control === "readOnly") return { control: "readOnly" };
  const supports = (control: Control) => clientControls?.includes(control) === true;
  if (supports(key.control)) return { control: key.control };
  if (key.fallback !== undefined && key.fallback !== "readOnly" && supports(key.fallback)) return { control: key.fallback };
  return { control: "readOnly", note: UPDATE_TRON_NOTE };
}

export interface KeyPresentation {
  label: string;
  help: string;
  order: number;
  importance: "essential" | "advanced";
  control?: Control;
  note?: string;
  valueKind: string;
  options?: readonly { value: unknown; label: string; detail?: string }[];
  range?: NonNullable<ValueType["range"]>;
  optionsSource?: { name: string; dependsOn: readonly string[] };
  confirm?: string;
  redacted?: true;
  entry?: EntryGuidance;
  sessionOverridable: boolean;
  projectSettable: boolean;
  editable: boolean;
  timing: KeyDeclaration["timing"];
  effect: KeyDeclaration["effect"];
}

function presentKey(key: KeyDeclaration, clientControls: readonly string[] | undefined, layer: "global" | "session" | "home" | "project"): KeyPresentation {
  const binding = key.layers[layer];
  const { control, note } = negotiateControl(key, clientControls);
  return {
    label: key.label,
    help: key.help,
    order: key.order,
    importance: key.importance,
    ...(control ? { control } : {}),
    ...(note ? { note } : {}),
    valueKind: key.type.kind,
    sessionOverridable: key.sessionOverridable,
    projectSettable: key.projectSettable,
    editable: layer !== "project" && scopeAdmitted(key, layer) && key.writers.includes("ui") && binding !== undefined && binding.store !== "session-launch",
    timing: key.timing,
    effect: key.effect,
    ...(control && key.type.options ? { options: key.type.options } : {}),
    ...(control && key.type.range ? { range: key.type.range } : {}),
    ...(control && key.optionsSource ? { optionsSource: key.optionsSource } : {}),
    ...(key.confirm ? { confirm: key.confirm } : {}),
    ...(key.redacted ? { redacted: true as const } : {}),
    ...(key.entry ? { entry: key.entry } : {}),
  };
}

export interface SettingsSectionPresentation {
  id: string;
  title: string;
  order: number;
  description: string;
  note?: string;
  chatInline?: boolean;
}

export type PresentedKey = ResolvedKey & { presentation: KeyPresentation };

export interface PresentedResolution extends Omit<Resolution, "keys"> {
  renderer: { version: number };
  keys: PresentedKey[];
  sections: SettingsSectionPresentation[];
}

interface PresentationInput {
  controls?: readonly string[];
}

function requesterLabel(actor: Actor): string {
  return actor.kind === "worker" && actor.taskId ? `Home task ${actor.taskId}` : actorLabel(actor);
}

function actorLabel(actor: Actor): string {
  return actor.kind === "home" ? "Home" : actor.kind === "worker" ? "A Home task worker" : actor.kind === "agent" ? "A chat's agent" : actor.kind === "outside" ? "Outside Tron" : "You";
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
  const redacted = entry.redacted || key?.redacted;
  const { before, after, fixedAt: _fixedAt, ...redactedEntry } = entry;
  const format = (value: unknown): string => formatStoredSetting(key?.type, value);
  const name = subject ? entry.qualifiers?.[subject.qualifier] : undefined;
  const display = subject ? entry.op === "unset" ? { before: "Configured", after: "Removed" }
    : entry.added ? { before: "Not configured", after: "Added" } : { before: "Configured", after: "Changed" }
    : redacted ? { before: "Hidden", after: "Changed" } : { before: format(before), after: format(after) };
  return {
    ...(redacted ? { ...redactedEntry, changed: true as const, redacted: true as const } : entry),
    presentation: {
      label: key?.label ?? (subject ? `${subject.label}${name ? ` ${name}` : ""}` : entry.key),
      ...(key ? { section: key.group } : subject ? { section: subject.group } : {}),
      actor: requesterLabel(entry.actor), layer: LAYER_LABELS[entry.layer],
      display,
    },
  };
}

export function presentResolution(schema: SettingsSchema, resolution: Resolution, input: PresentationInput): PresentedResolution {
  const layer = resolution.target.kind === "global" ? "global" : resolution.target.kind === "project" ? "project"
    : resolution.target.kind === "home" ? "home" : "session";
  const keys: PresentedKey[] = resolution.keys.filter(key => {
    if (input.controls === undefined) return true;
    const declaration = schema.schemaKey(key.key);
    return declaration.writers.length > 0 && (declaration.control !== undefined
      || key.overridden === true || key.projectSetting !== undefined || layer === "project");
  }).map(key => {
    const declaration = keyForHome(schema.schemaKey(key.key), resolution.target.kind === "home");
    return {
      ...key,
      presentation: presentKey(declaration, input.controls, layer),
    };
  });
  const sections = SECTIONS.flatMap((section): SettingsSectionPresentation[] =>
    keys.some(key => key.group === section.id) ? [{
      id: section.id, title: section.title, description: section.description, order: section.order,
      ...(section.note ? { note: section.note } : {}),
      ...(section.chatInline ? { chatInline: true } : {}),
    }] : []);
  return { ...resolution, renderer: { version: RENDERER_CONTRACT_VERSION }, keys, sections };
}
