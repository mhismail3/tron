import { KEYS, SECTIONS, schemaKey, type KeyDeclaration, type SectionDeclaration } from "./settings-schema.js";
import type { ResolvedKey, Resolution, SettingsTarget } from "./settings-resolver.js";
import type { Actor, ChangeEntry } from "./settings-record.js";
import type { ApprovalRequest } from "./settings-approvals.js";
import { LAYER_LABELS, RENDERER_CONTRACT_VERSION, type Control, type LayerId, type Qualifiers, type ValueType } from "./settings-types.js";

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

/** The most recent agent changes a section lists; the rest count as `moreRecent`. */
export const RECENT_SUMMARY_LIMIT = 3;
/** The newest record entries a section summary scans for recent changes. */
export const RECENT_SCAN_LIMIT = 200;

export interface SettingsSectionSummary {
  /** Keys whose importance is essential, by order. */
  essential: Array<{ key: string; qualifiers?: Qualifiers; label: string; display: string }>;
  /** Applied values set above Built-in. A value fixed at start from a default
   * is not an override; marking it apart is slice 7 (#765). */
  overrides: Array<{ key: string; qualifiers?: Qualifiers; label: string; display: string; layer: LayerId; layerLabel: string }>;
  pending: Array<{ requestId: string; requester: string; labels: string[] }>;
  recent: Array<{ changeId: string; key: string; label: string; actor: string; reason?: string; at: string }>;
  moreRecent: number;
}

export interface SettingsSectionPresentation {
  id: string;
  title: string;
  order: number;
  note?: string;
  summary: SettingsSectionSummary;
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
  /** The keys the request named, when it named some: sections cover only those. */
  keys?: readonly string[];
  /** Open approvals, as the approval store holds them. */
  approvals: readonly ApprovalRequest[];
  /** The newest record entries first, at most RECENT_SCAN_LIMIT of them. */
  history: readonly ChangeEntry[];
}

/** Who asked, as the iPhone's approval row names it. */
export function requesterLabel(actor: Actor): string {
  return actor.kind === "worker" && actor.taskId ? `Home task ${actor.taskId}` : actorLabel(actor);
}

export function actorLabel(actor: Actor): string {
  return actor.kind === "home" ? "Home" : actor.kind === "worker" ? "A Home task worker" : actor.kind === "agent" ? "A chat's agent" : "You";
}

export function sameSettingsTarget(left: SettingsTarget, right: SettingsTarget): boolean {
  if (left.kind !== right.kind) return false;
  if (left.kind === "project" && right.kind === "project") return left.cwd === right.cwd;
  if (left.kind === "session" && right.kind === "session") return left.sessionId === right.sessionId;
  return true;
}

/** A key's declaration by id, or undefined for an id this Gateway no longer declares
 * (an old record entry or approval may name one). */
function declaredKey(id: string): KeyDeclaration | undefined {
  return KEYS.find(key => key.id === id);
}

export function presentResolution(resolution: Resolution, input: PresentationInput): PresentedResolution {
  const keys: PresentedKey[] = resolution.keys.map(key => ({
    ...key,
    presentation: presentKey(schemaKey(key.key), input.controls),
  }));
  const named = input.keys ? new Set(input.keys) : undefined;
  const covered = (keyId: string) => named === undefined || named.has(keyId);
  const sections = SECTIONS.flatMap((section): SettingsSectionPresentation[] => {
    const sectionKeys = keys.filter(key => key.group === section.id);
    if (sectionKeys.length === 0) return [];
    return [{
      id: section.id, title: section.title, order: section.order, ...(section.note ? { note: section.note } : {}),
      summary: summarize(section, sectionKeys, resolution.target, input, covered),
    }];
  });
  return { ...resolution, renderer: { version: RENDERER_CONTRACT_VERSION }, keys, sections };
}

function summarize(section: SectionDeclaration, sectionKeys: readonly PresentedKey[], target: SettingsTarget, input: PresentationInput,
  covered: (keyId: string) => boolean): SettingsSectionSummary {
  const inSection = (keyId: string) => declaredKey(keyId)?.group === section.id && covered(keyId);
  const essential = sectionKeys
    .filter(key => key.presentation.importance === "essential")
    .sort((left, right) => left.presentation.order - right.presentation.order)
    .map(key => ({ key: key.key, ...(key.qualifiers ? { qualifiers: key.qualifiers } : {}), label: key.presentation.label, display: key.display }));
  const overrides = sectionKeys
    .filter(key => key.applied && key.layer !== "builtin")
    .map(key => ({
      key: key.key, ...(key.qualifiers ? { qualifiers: key.qualifiers } : {}), label: key.presentation.label, display: key.display,
      layer: key.layer, layerLabel: LAYER_LABELS[key.layer],
    }));
  const pending = input.approvals
    .filter(request => sameSettingsTarget(request.target, target))
    .flatMap(request => {
      const changes = request.changes.filter(change => inSection(change.key));
      return changes.length === 0 ? [] : [{
        requestId: request.requestId, requester: requesterLabel(request.actor),
        labels: changes.map(change => declaredKey(change.key)!.label),
      }];
    });
  const applied = input.history.filter(entry => entry.actor.kind !== "ui" && entry.status === "applied"
    && sameSettingsTarget(entry.target, target) && inSection(entry.key));
  const recent = applied.slice(0, RECENT_SUMMARY_LIMIT).map(entry => ({
    changeId: entry.changeId, key: entry.key, label: declaredKey(entry.key)!.label, actor: requesterLabel(entry.actor),
    ...(entry.reason ? { reason: entry.reason } : {}), at: entry.at,
  }));
  return { essential, overrides, pending, recent, moreRecent: Math.max(0, applied.length - RECENT_SUMMARY_LIMIT) };
}
