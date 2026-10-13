import { dirname } from "node:path";
import { KEYS, SECTIONS, builtinValue, chatLayerApplies, floorFor, floorInstances, schemaKey, type Binding, type FloorOverrides, type KeyDeclaration } from "./settings-schema.js";
import { LAYER_LABELS, type FormatContext, type LayerId, type Qualifiers } from "./settings-types.js";
import type { ProjectGitState } from "./project-settings-writer.js";
import { instanceId } from "./settings-outside.js";

/**
 * The one resolver (docs/settings-model.md section 3, foundation F4).
 *
 * For a target and each key it takes the topmost layer that the target has,
 * that holds a value for the key, that the key allows, and that is applied.
 * It reads stores that were loaded by their owners; it never writes, caches or
 * consults the change record (F2).
 */

export type SettingsTarget =
  | { kind: "mac" }
  | { kind: "project"; cwd: string }
  | { kind: "session"; sessionId: string }
  | { kind: "home" };

export interface FixedSetting {
  value: unknown;
  from: LayerId | "delegate";
  at: string;
  ref: string;
  qualifiers?: Qualifiers;
  /** Delegation-time source, kept with the fixed value rather than inferred from current Home. */
  via?: "home-profile:sameAs:home" | "home-profile" | "home-explicit" | "home-fallback";
  reason?: string;
}

/** The Chat layer as the session record holds it (doc 3.2). */
export interface ChatStore {
  model?: { provider: string; id: string };
  thinking?: string;
  /** `tron.context-window.v1`: the chat's explicit window for its model. */
  contextWindow?: { model: string; value: number };
  tools?: string[];
  /** `tron.settings.v1`: explicit Chat-layer values for the other keys. */
  settings: Record<string, unknown>;
  /** Effective directional request values retained at this branch's boundary. */
  requestPins?: Record<string, FixedSetting>;
  fixed?: Record<string, FixedSetting>;
}

export interface ProjectStore {
  root: string;
  document: Record<string, unknown>;
  /** The file exists but cannot be parsed; its values are unknown. */
  unreadable?: true;
  applied: boolean;
  reason?: "untrusted";
  /** The store's git state, which badges each Project value (doc 5.7). */
  git?: ProjectGitState;
}

/** The latest outside change of a key instance since Tron last wrote it (doc 5.6). */
export interface OutsideMark { changeId: string; applyAgain: boolean; before: string; after: string }

/** Every store the target's layers read, loaded by their owners (doc 3.2). */
export interface SettingsStores {
  /** The layers this target has (doc 3.3). Built-in is always last. */
  layers: readonly LayerId[];
  chat?: ChatStore;
  profile?: Record<string, unknown>;
  homeMemory?: { provider: string; id: string };
  project?: ProjectStore;
  mac: Record<string, unknown>;
  /** Saved trust decisions by canonical project path. */
  trust: Record<string, boolean>;
  /** The maintainer's floor overrides (Mac policy, doc 5.4). */
  floors: FloorOverrides;
  /** Outside-change marks by layer and key instance (doc 5.6). */
  outside?: Partial<Record<"mac" | "project", Record<string, OutsideMark>>>;
}

/** Capability-constrained option sources (doc 3.6, 7.5). */
export interface OptionSources {
  /** The closest supported value, or the value itself when supported. */
  clamp(source: string, dependency: unknown, value: unknown): unknown;
}

export interface Badge { kind: string; label: string; detail?: string; action?: { kind: string; label: string; changeId?: string } }

export interface LayerValue {
  layer: LayerId;
  value?: unknown;
  display?: string;
  /** False when the target has the layer and it holds a value that does not apply. */
  applied: boolean;
  reason?: "untrusted";
}

export interface ResolvedKey {
  key: string;
  qualifiers?: Qualifiers;
  group: string;
  subgroup?: string;
  value: unknown;
  display: string;
  layer: LayerId;
  /** False when the topmost value present is not applied (an untrusted project). */
  applied: boolean;
  reason?: "untrusted";
  badges: Badge[];
  fixedAt?: FixedSetting;
  layers: LayerValue[];
}

export interface Diagnostic { key: string; layer: LayerId; reason: "layer-not-allowed"; path: string }

export interface Resolution {
  target: SettingsTarget;
  layers: readonly LayerId[];
  /** The Project store exists but cannot be parsed (for example merge markers). */
  projectUnreadable?: true;
  keys: ResolvedKey[];
  diagnostics: Diagnostic[];
}

const BOTTOM_UP: readonly LayerId[] = ["builtin", "mac", "project", "profile", "chat"];

function readPath(document: Record<string, unknown> | undefined, path: readonly string[]): unknown {
  let current: unknown = document;
  for (const segment of path) {
    if (typeof current !== "object" || current === null || Array.isArray(current)) return undefined;
    if (!Object.prototype.hasOwnProperty.call(current, segment)) return undefined;
    current = (current as Record<string, unknown>)[segment];
  }
  return current;
}

function fill(path: readonly string[], qualifiers: Qualifiers): readonly string[] | undefined {
  if (path.includes("{model}") && !qualifiers.model) return undefined;
  return path.map(segment => segment === "{model}" ? qualifiers.model! : segment);
}

function piDocument(stores: SettingsStores, layer: LayerId): Record<string, unknown> | undefined {
  return layer === "mac" ? stores.mac : layer === "project" ? stores.project?.document : undefined;
}

/** Read one layer's raw value for a key instance from that layer's store. */
export function readBinding(stores: SettingsStores, layer: LayerId, binding: Binding, qualifiers: Qualifiers, qualifiedOnly: boolean, keyId?: string): unknown {
  switch (binding.store) {
    case "pi": {
      const document = piDocument(stores, layer);
      const path = fill(qualifiedOnly ? binding.qualified ?? [] : binding.path, qualifiers);
      if (!path || path.length === 0) return undefined;
      return readPath(document, path);
    }
    case "pi-model-ref": {
      if (qualifiedOnly) return undefined;
      const document = piDocument(stores, layer);
      const provider = document?.defaultProvider;
      const id = document?.defaultModel;
      return typeof provider === "string" && typeof id === "string" ? { provider, id } : undefined;
    }
    case "chat": {
      const chat = stores.chat;
      if (!chat) return undefined;
      if (binding.field === "model") return qualifiedOnly ? undefined : chat.model;
      if (binding.field === "thinking") return chat.thinking;
      if (binding.field === "tools") return qualifiedOnly ? undefined : chat.tools;
      return chat.contextWindow && chat.contextWindow.model === qualifiers.model ? chat.contextWindow.value : undefined;
    }
    case "chat-settings":
      return qualifiedOnly ? undefined : (keyId && stores.chat?.requestPins?.[keyId] !== undefined
        ? stores.chat.requestPins[keyId].value : keyId && stores.chat?.fixed?.[keyId] ? stores.chat.fixed[keyId].value : readPath(stores.chat?.settings, binding.path));
    case "profile":
      return qualifiedOnly ? undefined : readPath(stores.profile, binding.path);
    case "home-memory":
      return qualifiedOnly ? undefined : stores.homeMemory;
    case "trust":
      return qualifiers.project === undefined ? undefined : nearestTrustDecision(stores.trust, qualifiers.project);
    case "floors":
      // A key with one floor keeps both directions equal, so widen reads it.
      return qualifiers.key === undefined ? undefined
        : stores.floors[qualifiers.key]?.[qualifiers.direction === "narrow" ? "narrow" : "widen"];
  }
}

/** pi's trust rule (ProjectTrustStore): the nearest saved decision on the path
 * or one of its parents covers it, so the row shows what actually applies. */
export function nearestTrustDecision(decisions: Record<string, boolean>, project: string): boolean | undefined {
  for (let current = project; ; current = dirname(current)) {
    if (Object.prototype.hasOwnProperty.call(decisions, current)) return decisions[current];
    if (dirname(current) === current) return undefined;
  }
}

/** A composing key's value from the layers below `layer`: what that layer's
 * entries are relative to. */
export function composedBelow(stores: SettingsStores, key: KeyDeclaration, qualifiers: Qualifiers, layer: LayerId): unknown {
  let value = builtinValue(key, qualifiers);
  for (const below of BOTTOM_UP.slice(1, BOTTOM_UP.indexOf(layer))) {
    const binding = key.layers[below as Exclude<LayerId, "builtin">];
    if (!binding || !stores.layers.includes(below) || !layerApplied(stores, below).applied) continue;
    const entry = readBinding(stores, below, binding, qualifiers, false, key.id);
    if (entry !== undefined) value = key.type.compose ? key.type.compose(value, entry) : entry;
  }
  return value;
}

function layerApplied(stores: SettingsStores, layer: LayerId): { applied: boolean; reason?: "untrusted" } {
  if (layer === "project" && stores.project && !stores.project.applied) return { applied: false, reason: "untrusted" };
  return { applied: true };
}

/** Pi-file paths a key does not allow, used to report values set where they are ignored. */
function disallowedPiPaths(key: KeyDeclaration, layer: "project" | "mac"): readonly (readonly string[])[] {
  if (key.layers[layer]) return [];
  const other = key.layers[layer === "project" ? "mac" : "project"];
  if (other?.store === "pi") return [other.path];
  if (other?.store === "pi-model-ref") return [["defaultProvider"], ["defaultModel"]];
  return [];
}

export interface ResolveOptions {
  format: FormatContext;
  options: OptionSources;
  keys?: readonly string[];
}

/** Resolve every key (or the requested ones) for a target. */
export function resolveSettings(target: SettingsTarget, stores: SettingsStores, options: ResolveOptions): Resolution {
  const diagnostics: Diagnostic[] = [];
  const keys = options.keys ? KEYS.filter(key => options.keys!.includes(key.id)) : KEYS;
  const resolved: ResolvedKey[] = [];
  // Model-qualified keys resolve for the target's effective chat model, which
  // is itself an ordinary key; resolve it first.
  const chatModelKey = KEYS.find(key => key.id === "model.ref[role=chat]")!;
  const noDependencies = () => undefined;
  const chatModel = resolveInstance(chatModelKey, chatModelKey.fixed ?? {}, stores, options, noDependencies).value as { provider: string; id: string } | undefined;
  // Dependencies are ordinary keys resolved for the same target (doc 7.5).
  const dependencyValue = (id: string) => id === chatModelKey.id ? chatModel
    : resolveInstance(schemaKey(id), schemaKey(id).fixed ?? {}, stores, options, noDependencies).value;
  const modelQualifier = chatModel ? `${chatModel.provider}/${chatModel.id}` : undefined;

  for (const key of keys) {
    // A key belongs to a target that has at least one of its allowed layers
    // (doc 3.3): Home-only profile keys never appear on an ordinary chat.
    if (!Object.keys(key.layers).some(layer => stores.layers.includes(layer as LayerId))) continue;
    for (const layer of ["project", "mac"] as const) {
      if (!stores.layers.includes(layer)) continue;
      const document = piDocument(stores, layer);
      for (const path of disallowedPiPaths(key, layer)) {
        if (readPath(document, path) !== undefined) diagnostics.push({ key: key.id, layer, reason: "layer-not-allowed", path: path.join(".") });
      }
    }
    for (const qualifiers of instances(key, target, stores, modelQualifier)) {
      resolved.push(resolveInstance(key, qualifiers, stores, options, dependencyValue));
    }
  }
  return { target, layers: stores.layers, ...(stores.project?.unreadable ? { projectUnreadable: true as const } : {}), keys: resolved, diagnostics };
}

function instances(key: KeyDeclaration, target: SettingsTarget, stores: SettingsStores, model: string | undefined): Qualifiers[] {
  const fixed = { ...(key.fixed ?? {}) } as Qualifiers;
  if (key.qualifier === "model") {
    const onlyQualified = Object.values(key.layers).some(binding => binding.store === "pi" && binding.path.includes("{model}"));
    return model ? [{ ...fixed, model }] : onlyQualified ? [] : [fixed];
  }
  if (key.qualifier === "key") {
    // Floors are Mac policy only the maintainer's tap writes; they appear on the Mac target.
    return target.kind === "mac" ? floorInstances().map(instance => ({ ...fixed, ...instance })) : [];
  }
  if (key.qualifier === "project") {
    if (target.kind === "project" || target.kind === "session") return stores.project ? [{ ...fixed, project: stores.project.root }] : [];
    return Object.keys(stores.trust).sort().map(project => ({ ...fixed, project }));
  }
  return [fixed];
}

function resolveInstance(
  key: KeyDeclaration,
  qualifiers: Qualifiers,
  stores: SettingsStores,
  options: ResolveOptions,
  dependencyValue: (id: string) => unknown,
): ResolvedKey {
  const format = (value: unknown) => key.redacted ? (value === undefined || value === "" ? "Not set" : "Set")
    : value === undefined ? "Not set" : key.type.format(value, options.format);
  const layerValues: LayerValue[] = [];
  const read = (qualifiedOnly: boolean) => {
    const found: Array<{ layer: LayerId; value: unknown; applied: boolean; reason?: "untrusted" }> = [];
    for (const layer of BOTTOM_UP) {
      if (layer === "builtin" || !stores.layers.includes(layer)) continue;
      const binding = key.layers[layer as Exclude<LayerId, "builtin">];
      if (!binding || (layer === "chat" && !chatLayerApplies(key, stores.layers.includes("profile")))) continue;
      const value = readBinding(stores, layer, binding, qualifiers, qualifiedOnly, key.id);
      if (value === undefined) continue;
      found.push({ layer, value, ...layerApplied(stores, layer) });
    }
    return found;
  };
  // A qualified instance read across every layer wins over the unqualified key.
  const qualified = read(true);
  const unqualified = read(false);
  const present = qualified.some(entry => entry.applied) ? qualified : unqualified;
  // Each layer shows what it holds for this instance: its qualified value, or else its plain one.
  const shown = BOTTOM_UP.flatMap(layerId => {
    const entry = qualified.find(candidate => candidate.layer === layerId) ?? unqualified.find(candidate => candidate.layer === layerId);
    return entry ? [entry] : [];
  });

  const builtin = builtinValue(key, qualifiers);
  let value: unknown = builtin;
  let layer: LayerId = "builtin";
  for (const entry of present) {
    if (!entry.applied) continue;
    value = key.type.compose ? key.type.compose(value, entry.value) : entry.value;
    layer = entry.layer;
  }
  const top = shown[shown.length - 1];
  const notApplied = top && !top.applied ? top : undefined;

  for (const layerId of [...BOTTOM_UP].reverse()) {
    if (!stores.layers.includes(layerId) && layerId !== "builtin") continue;
    if (layerId === "builtin") {
      layerValues.push({ layer: "builtin", ...(builtin === undefined ? {} : { value: builtin, display: format(builtin) }), applied: true });
      continue;
    }
    if (!key.layers[layerId as Exclude<LayerId, "builtin">]) continue;
    // Only the Home chat has the Profile layer (doc 3.3); it has no Chat compaction layer.
    if (layerId === "chat" && !chatLayerApplies(key, stores.layers.includes("profile"))) continue;
    const entry = shown.find(candidate => candidate.layer === layerId);
    layerValues.push(entry
      ? { layer: layerId, value: entry.value, display: format(entry.value), applied: entry.applied, ...(entry.reason ? { reason: entry.reason } : {}) }
      : { layer: layerId, applied: true });
  }

  const badges: Badge[] = [{ kind: "layer", label: LAYER_LABELS[layer] }];
  if (qualifiers.model && key.qualifier === "model") badges.push({ kind: "scope", label: qualifiers.model });
  if (qualifiers.project && key.qualifier === "project") badges.push({ kind: "scope", label: qualifiers.project });
  if (qualifiers.key && key.qualifier === "key") {
    // A directional approval level names what the agent's change does to the setting.
    badges.push({ kind: "scope", label: qualifiers.direction
      ? `${schemaKey(qualifiers.key).label}: ${qualifiers.direction === "widen" ? "loosening" : "tightening"}` : schemaKey(qualifiers.key).label });
  }
  if (notApplied) {
    badges.push({ kind: "state", label: "Not applied (untrusted)", detail: `${LAYER_LABELS[notApplied.layer]}: ${format(notApplied.value)}`,
      action: { kind: "reviewTrust", label: "Review trust" } });
  }
  badges.push(...storeStateBadges(key, qualifiers, stores, format));
  // Capability clamping (doc 3.6): a value its dependency does not support
  // resolves to the closest supported one, named by a Clamped badge.
  if (key.optionsSource && value !== undefined && layer !== "chat") {
    const dependency = key.optionsSource.dependsOn.length ? dependencyValue(key.optionsSource.dependsOn[0]!) : undefined;
    if (dependency !== undefined) {
      const clamped = options.options.clamp(key.optionsSource.name, dependency, value);
      if (clamped !== value) {
        badges.push({ kind: "state", label: "Clamped", detail: `${format(value)} is not supported; using ${format(clamped)}` });
        value = clamped;
      }
    }
  }
  if (key.redacted) badges.push({ kind: "state", label: "Not undoable" });
  const candidate = stores.chat?.fixed?.[key.id] ?? stores.chat?.requestPins?.[key.id];
  const fixedAt = layer === "chat" && candidate && JSON.stringify(candidate.value) === JSON.stringify(value)
    && (!candidate.qualifiers?.model || candidate.qualifiers.model === qualifiers.model) ? candidate : undefined;
  if (fixedAt) {
    const binding = key.layers.chat;
    const requested = binding?.store === "chat-settings" ? readPath(stores.chat?.settings, binding.path) : undefined;
    if (requested !== undefined && JSON.stringify(requested) !== JSON.stringify(value)) {
      badges.push({ kind: "state", label: "Applies to a new chat", detail: `Requested: ${format(requested)}` });
    }
    badges.push({ kind: "source", label: fixedAt.from === "chat" ? "Explicit choice" : fixedAt.from === "delegate"
      ? `From Home at start: ${fixedAt.via === "home-profile:sameAs:home" ? "same as Home" : fixedAt.via === "home-profile" ? "Home profile" : fixedAt.via === "home-fallback" ? "worker default" : "chosen for this task"} (${format(fixedAt.value)})`
      : `From default at start: ${format(fixedAt.value)} (${LAYER_LABELS[fixedAt.from]})`,
      ...(fixedAt.reason ? { detail: fixedAt.reason } : {}),
      action: { kind: "useCurrentDefault", label: "Use the current default" } });
  }

  return {
    key: key.id,
    ...(Object.keys(qualifiers).length ? { qualifiers } : {}),
    group: key.group,
    ...(key.subgroup ? { subgroup: key.subgroup } : {}),
    value: key.redacted ? undefined : value,
    display: format(value),
    layer,
    applied: !notApplied,
    ...(notApplied ? { reason: notApplied.reason } : {}),
    badges,
    ...(fixedAt ? { fixedAt } : {}),
    layers: key.redacted ? layerValues.map(({ value: _value, ...rest }) => rest) : layerValues,
  };
}

/** Store-state badges (doc 5.6, 5.7): a Project value's git state, and a value
 * changed outside Tron with Apply again where it replaced a value Tron wrote. */
function storeStateBadges(key: KeyDeclaration, qualifiers: Qualifiers, stores: SettingsStores, format: (value: unknown) => string): Badge[] {
  const badges: Badge[] = [];
  const projectBinding = key.layers.project;
  const git = stores.project?.git;
  if (projectBinding && git && stores.layers.includes("project")) {
    const at = (document: Record<string, unknown>) => {
      const view = { ...stores, project: { ...stores.project!, document } };
      return readBinding(view, "project", projectBinding, qualifiers, true, key.id) ?? readBinding(view, "project", projectBinding, qualifiers, false, key.id);
    };
    const working = at(stores.project!.document);
    if (git.kind === "local") {
      if (working !== undefined) badges.push({ kind: "state", label: "Local only", detail: `Project: ${git.reason}` });
    } else {
      const committed = at(git.head ?? {});
      if (JSON.stringify(working ?? null) !== JSON.stringify(committed ?? null)) {
        const staged = JSON.stringify(at(git.index ?? {}) ?? null) === JSON.stringify(working ?? null);
        badges.push({ kind: "state", label: staged ? "Staged" : "Uncommitted", detail: `Project: ${format(working)}; committed: ${format(committed)}` });
      }
    }
  }
  for (const layer of ["project", "mac"] as const) {
    if (!stores.layers.includes(layer) || !key.layers[layer]) continue;
    const marks = stores.outside?.[layer];
    const mark = marks?.[instanceId(key.id, qualifiers)] ?? marks?.[instanceId(key.id, key.fixed ?? {})];
    if (!mark) continue;
    badges.push({ kind: "state", label: "Changed outside Tron", detail: `${LAYER_LABELS[layer]}: ${mark.before} → ${mark.after}`,
      ...(mark.applyAgain ? { action: { kind: "applyAgain", label: "Apply again", changeId: mark.changeId } } : {}) });
  }
  return badges;
}

/** The layers a target has (doc 3.3): a target has a layer when it has its store. */
export function targetLayers(target: SettingsTarget, options: { home?: boolean; project?: boolean }): readonly LayerId[] {
  switch (target.kind) {
    case "mac": return ["mac", "builtin"];
    case "project": return ["project", "mac", "builtin"];
    case "home": return ["profile", "mac", "builtin"];
    case "session": return options.home
      ? ["chat", "profile", "mac", "builtin"]
      : options.project === false ? ["chat", "mac", "builtin"] : ["chat", "project", "mac", "builtin"];
  }
}

export function sectionDeclarations() {
  return SECTIONS;
}

export { floorFor };
