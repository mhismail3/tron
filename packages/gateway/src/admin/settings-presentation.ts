import { KEYS, SECTIONS, recordSubject, schemaKey, type KeyDeclaration } from "./settings-schema.js";
import type { ResolvedKey, Resolution } from "./settings-resolver.js";
import type { Actor, ChangeEntry } from "./settings-record.js";
import { formatStoredSetting, LAYER_LABELS, RENDERER_CONTRACT_VERSION, type Control, type ValueType } from "./settings-types.js";

/**
 * What a client is shown for each resolved key and section (docs/settings-model.md
 * 7.2, 7.5). The resolver holds values; this module holds how they are presented,
 * and it reads every key's declaration generically: no per-key code.
 */

export const UPDATE_TRON_NOTE = "Update Tron to edit";

/** The control a key renders with for a client (doc 7.5): the declared control
 * when the client has it, else the declared fallback, else read-only. A client
 * that names no controls gets every editable key read-only, with its display. */
export function negotiateControl(key: KeyDeclaration, clientControls: readonly string[] | undefined): { control: Control; note?: string } {
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
  control: Control;
  note?: string;
  valueKind: string;
  /** The static choices, for a `choice` control. Dynamic options come from `settings.options`. */
  options?: readonly { value: unknown; label: string }[];
  range?: NonNullable<ValueType["range"]>;
  optionsSource?: { name: string; dependsOn: readonly string[] };
  confirm?: string;
  redacted?: true;
}

export function presentKey(key: KeyDeclaration, clientControls: readonly string[] | undefined): KeyPresentation {
  const { control, note } = negotiateControl(key, clientControls);
  return {
    label: key.label,
    help: key.help,
    order: key.order,
    importance: key.importance,
    control,
    ...(note ? { note } : {}),
    valueKind: key.type.kind,
    ...(key.type.options ? { options: key.type.options } : {}),
    ...(key.type.range ? { range: key.type.range } : {}),
    ...(key.optionsSource ? { optionsSource: key.optionsSource } : {}),
    ...(key.confirm ? { confirm: key.confirm } : {}),
    ...(key.redacted ? { redacted: true as const } : {}),
  };
}

export interface SettingsSectionPresentation {
  id: string;
  title: string;
  order: number;
  description: string;
  note?: string;
}

export type PresentedKey = ResolvedKey & { presentation: KeyPresentation };

export interface PresentedResolution extends Omit<Resolution, "keys"> {
  renderer: { version: number };
  keys: PresentedKey[];
  sections: SettingsSectionPresentation[];
}

export interface PresentationInput {
  /** The controls the client names (`renderer.controls`); absent without a renderer. */
  controls?: readonly string[];
}

/** Who asked, as the iPhone's approval row names it. */
export function requesterLabel(actor: Actor): string {
  return actor.kind === "worker" && actor.taskId ? `Home task ${actor.taskId}` : actorLabel(actor);
}

export function actorLabel(actor: Actor): string {
  return actor.kind === "home" ? "Home" : actor.kind === "worker" ? "A Home task worker" : actor.kind === "agent" ? "A chat's agent" : actor.kind === "outside" ? "Outside Tron" : "You";
}

/** A key's declaration by id, or undefined for an id this Gateway no longer declares
 * (an old record entry or approval may name one). */
function declaredKey(id: string): KeyDeclaration | undefined {
  return KEYS.find(key => key.id === id);
}

/** History is a disposable projection of permanent audit, not another schema or
 * value store. Retired keys keep their recorded values; known keys reuse their
 * declared formatter. Neither labels nor formatted values are written to audit. */
export function presentHistoryEntry(entry: ChangeEntry) {
  const key = declaredKey(entry.key);
  const subject = key ? undefined : recordSubject(entry.key);
  const redacted = entry.redacted || key?.redacted;
  const { before, after, fixedAt: _fixedAt, ...redactedEntry } = entry;
  const format = (value: unknown): string => formatStoredSetting(key?.type, value);
  // A record subject's definition is never recorded: show what happened to it, by name.
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

export function presentResolution(resolution: Resolution, input: PresentationInput): PresentedResolution {
  const keys: PresentedKey[] = resolution.keys.map(key => ({
    ...key,
    presentation: presentKey(schemaKey(key.key), input.controls),
  }));
  const sections = SECTIONS.flatMap((section): SettingsSectionPresentation[] =>
    keys.some(key => key.group === section.id) ? [{
      id: section.id, title: section.title, description: section.description, order: section.order,
      ...(section.note ? { note: section.note } : {}),
    }] : []);
  return { ...resolution, renderer: { version: RENDERER_CONTRACT_VERSION }, keys, sections };
}

